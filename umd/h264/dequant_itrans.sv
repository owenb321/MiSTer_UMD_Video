// umd/h264/dequant_itrans.sv -- inverse scan, scaling and inverse transform of one
// residual block (ITU-T H.264 8.5.6 inverse scanning, Table 8-13; 8.5.10 Intra16x16 luma
// DC; 8.5.11 chroma DC (4:2:0); 8.5.12.1 scaling with flat scaling lists; 8.5.12.2 the
// 4x4 inverse transform)
//
// Bit-exact against tools/h264_recon_ref.py (dequant4x4 + itrans4x4, luma_dc,
// chroma_dc -- proven pixel-exact vs ffmpeg and the H.264.1 reference YUVs), scored by
// bench/umd/run_dequant_itrans.sh over fixtures from tools/itrans_golden.py: every
// QP x both scans x every kind, sparse and zero blocks, and real x264 blocks.
// docs/h264_recon.md S2.4.
//
// One block per `start` (a pulse, taken while !busy):
//   kind 0 L4   16 coefficients in scan order -> 16 residual samples r_ij, raster 4i+j
//   kind 1 LAC  15 AC coefficients of an Intra16x16 luma block (scan positions 1..15),
//               d00 = dc_in (the dcY value 8.5.10 produced)         -> 16 samples
//   kind 2 CAC  15 chroma AC coefficients, d00 = dc_in (the dcC of 8.5.11) -> 16 samples
//   kind 3 LDC  16 Intra16x16 DC levels in scan order -> the 16 scaled dcY_ij, raster 4i+j
//   kind 4 CDC  4 chroma DC levels c0..c3 -> the 4 scaled dcC in order dc00 dc01 dc10 dc11
//   kinds 5..7  not defined; decoded as kind 0 (the parent never issues them)
// `qp` is QP'Y (kinds 0, 1, 3) or QP'C (kinds 2, 4), 0..51. `field_scan` selects the
// field scan of Table 8-13 (field pictures) over the zig-zag. `kind`, `qp`, `field_scan`
// and `dc_in` are sampled with `start`.
//
// Datapath (serial: one coefficient in per cycle, one sample out per cycle):
//   intake  -- each coefficient is placed by the scan ROM at its raster position and, for
//              kinds 0..2, scaled on the way in: d = (c * LevelScale4x4(qp%6, i, j)) with
//              the shift of 8.5.12.1, LevelScale4x4 = 16 * normAdjust4x4 (flat lists,
//              the only ones this core admits -- scaling matrices are refused upstream).
//              The rounding term of eq. 8-338 (qp < 24) is NOT built: with LevelScale a
//              multiple of 16 the product c * LevelScale is a multiple of 2^4 >=
//              2^(4 - qp/6), and adding 2^(3 - qp/6) < 2^(4 - qp/6) can never carry into
//              the bits that survive the right shift, so (c*LS + 2^(3-qp/6)) >> (4-qp/6)
//              == (c*LS) >> (4-qp/6) exactly, for either sign (tools/itrans_golden.py
//              checks the identity exhaustively over every 16-bit level, every qp%6 and
//              every position class before it writes a fixture). Kinds 3, 4 store the
//              raw levels (the DC transforms come before their scaling: 8.5.10, 8.5.11).
//   rows    -- 4 cycles, one 4-point butterfly per cycle, in place (8.5.12.2 e/f for
//              kinds 0..2; the Hadamard for kind 3 -- exact integer sums, so rows before
//              columns gives the same f as the spec's H c H).
//   columns -- 4 cycles into the output buffer (g/h, or the second Hadamard pass); kind 4
//              is the one 2x2 Hadamard cycle (eq. 8-328) straight into the output buffer.
//   output  -- one sample per cycle from the output buffer: r = (h + 32) >> 6 (kinds
//              0..2), the DC scaling of 8.5.10 (kind 3, both branches, with its rounding
//              term -- that one is real below qp 12) or of 8.5.11.2 (kind 4).
// The output buffer is separate from the work buffer, so the next block's intake and
// transform overlap this block's output stream: `busy` drops when the column pass has
// handed the block to the output buffer, and the parent may `start` the next block then
// (its column pass waits if the output stream has not drained the buffer yet). Steady
// state with a ready consumer and a coefficient every cycle: 26 cycles per
// 16-coefficient block (1 start + 16 intake + 1 drain + 4 rows + 4 columns), 25 per
// AC block, 7 per chroma DC block, plus one when the parent registers `start` off
// `busy` instead of presenting it in the cycle `busy` drops (the bench measures 28.1 /
// 27.1 / 8.0 -- a cycle more than this sum for the 16- and 15-coefficient kinds, not yet
// accounted; 2026-09-28, unchanged by the LevelScale register); the output stream
// (16 / 4 samples) hides under the next block's intake.
//
// Widths. The spec bounds a conforming stream's d_ij, f_ij, h_ij (8.5.12), dcY (8.5.10)
// and dcC (8.5.11.2) to 16 bits signed at 8-bit depth (-2^15 .. 2^15-1); the butterfly
// intermediates e_ij and g_ij may legally reach 17 bits. Both buffers are 20 bits wide:
// the transform path has 3 bits of headroom above the widest legal intermediate, and the
// Intra16x16 DC Hadamard is exact for ANY 16-bit levels (16 sums: 16 + 4 = 20 bits). The
// butterfly itself computes in 22 bits. Scaling products are formed at full width (16 x
// 10 -> 26 bits on the way in, 20 x 10 -> 30 bits on the way out; two multipliers, one
// per stage, because the two stages run in the same cycle when blocks overlap) and the
// shifted result is truncated to the buffer / output width: a non-conforming stream that
// overflows wraps, it is never clamped (the spec says the bitstream shall not do it; the
// parent counts errors elsewhere). Every right shift is arithmetic (the spec's >> on
// signed values).
//
// Quartus 17 (CLAUDE.md): tables are `case` ROMs, no `function automatic` helpers, no
// N'() casts; the butterfly operands are sign-extended explicitly before any shift so no
// context-width rule is relied on. The two 16-entry buffers are register arrays: the work
// buffer is read by three fixed 4:1 patterns (a row, a column, the first four entries),
// the output buffer by one 16:1 mux -- 640 flops, no LUT-RAM explosion possible.

`default_nettype none

module dequant_itrans (
    input  wire         clk,
    input  wire         rst_n,

    // one block
    input  wire         start,
    input  wire  [2:0]  kind,
    input  wire  [5:0]  qp,
    input  wire         field_scan,
    input  wire signed [15:0] dc_in,

    // the coefficients in scan order
    input  wire         coef_valid,
    input  wire signed [15:0] coef,
    output logic        coef_ready,

    // the residual samples (or scaled DC values) in raster order
    output logic        res_valid,
    output logic signed [15:0] res,
    output logic        res_last,
    input  wire         res_ready,

    output logic        busy
);

    // kind 0 (L4) is the default of every kind test below, so it needs no name
    localparam [2:0] K_LAC = 3'd1, K_CAC = 3'd2, K_LDC = 3'd3, K_CDC = 3'd4;

    typedef enum logic [2:0] {S_IDLE, S_IN, S_DRAIN, S_ROW, S_ROWW, S_COL, S_CDC} state_t;
    state_t state;

    // ---- the block's parameters ----------------------------------------------------
    logic [2:0]  b_kind;
    logic [3:0]  b_q6;                  // qp / 6, 0..8
    logic [2:0]  b_m;                   // qp % 6
    logic        b_field;
    logic [4:0]  b_ncoef;               // 16, 15 or 4
    logic [4:0]  cnt;                   // coefficients accepted so far

    wire is_ac  = (b_kind == K_LAC) || (b_kind == K_CAC);
    wire is_dc  = (b_kind == K_LDC) || (b_kind == K_CDC);

    // qp -> (qp / 6, qp % 6) at start: a comparator chain, no divider
    logic [3:0] q6_w;
    logic [5:0] six_q6;
    always_comb begin
        if      (qp >= 6'd48) q6_w = 4'd8;
        else if (qp >= 6'd42) q6_w = 4'd7;
        else if (qp >= 6'd36) q6_w = 4'd6;
        else if (qp >= 6'd30) q6_w = 4'd5;
        else if (qp >= 6'd24) q6_w = 4'd4;
        else if (qp >= 6'd18) q6_w = 4'd3;
        else if (qp >= 6'd12) q6_w = 4'd2;
        else if (qp >= 6'd6)  q6_w = 4'd1;
        else                  q6_w = 4'd0;
        six_q6 = {1'b0, q6_w, 1'b0} + {q6_w, 2'b00};
    end
    wire [5:0] m_w = qp - six_q6;

    // ---- the work buffer (d / f, or the DC levels / their first Hadamard pass) ---------
    logic signed [19:0] A [0:15];
    // ---- the output buffer (h, or the transformed DC values before scaling) ------------
    logic signed [19:0] O [0:15];

    // ---- intake: scan position -> raster (Table 8-13) and its LevelScale class ---------
    // k is the scan index of the coefficient being accepted: cnt for a 16-coefficient
    // block, cnt + 1 for an AC block (scan positions 1..15)
    wire [4:0] k_full = cnt + (is_ac ? 5'd1 : 5'd0);
    wire [3:0] k_idx  = k_full[3:0];
    logic [3:0] scan_r;
    always_comb begin
        case ({b_field, k_idx})
            // zig-zag (frame macroblocks): raster 4i+j
            5'h00: scan_r = 4'd0;  5'h01: scan_r = 4'd1;  5'h02: scan_r = 4'd4;  5'h03: scan_r = 4'd8;
            5'h04: scan_r = 4'd5;  5'h05: scan_r = 4'd2;  5'h06: scan_r = 4'd3;  5'h07: scan_r = 4'd6;
            5'h08: scan_r = 4'd9;  5'h09: scan_r = 4'd12; 5'h0A: scan_r = 4'd13; 5'h0B: scan_r = 4'd10;
            5'h0C: scan_r = 4'd7;  5'h0D: scan_r = 4'd11; 5'h0E: scan_r = 4'd14; 5'h0F: scan_r = 4'd15;
            // field scan (field pictures)
            5'h10: scan_r = 4'd0;  5'h11: scan_r = 4'd4;  5'h12: scan_r = 4'd1;  5'h13: scan_r = 4'd8;
            5'h14: scan_r = 4'd12; 5'h15: scan_r = 4'd5;  5'h16: scan_r = 4'd9;  5'h17: scan_r = 4'd13;
            5'h18: scan_r = 4'd2;  5'h19: scan_r = 4'd6;  5'h1A: scan_r = 4'd10; 5'h1B: scan_r = 4'd14;
            5'h1C: scan_r = 4'd3;  5'h1D: scan_r = 4'd7;  5'h1E: scan_r = 4'd11; 5'h1F: scan_r = 4'd15;
            default: scan_r = 4'd0;
        endcase
    end
    // chroma DC levels go to positions 0..3 as given (c0..c3 of eq. 8-328)
    wire [3:0] in_r = (b_kind == K_CDC) ? cnt[3:0] : scan_r;
    // 8.5.9: normAdjust4x4 class of (i, j): 0 both even, 1 both odd, 2 mixed;
    // raster r = 4i + j, so i odd is r[2] and j odd is r[0]
    logic [1:0] in_cls;
    always_comb begin
        case ({in_r[2], in_r[0]})
            2'b00:   in_cls = 2'd0;
            2'b11:   in_cls = 2'd1;
            default: in_cls = 2'd2;
        endcase
    end

    // stage 1: the accepted coefficient with its raster position and LevelScale
    logic               p1_valid;
    logic signed [15:0] p1_coef;
    logic [3:0]         p1_r;
    logic signed [9:0]  p1_ls;

    // LevelScale4x4(m, i, j) = 16 * normAdjust4x4(m, i, j) (8.5.9, Table 8-14 values
    // 10 16 13 / 11 18 14 / 13 20 16 / 14 23 18 / 16 25 20 / 18 29 23), for the coefficient
    // being accepted (registered with it: b_m / the class -> the table -> the product -> the
    // shift -> A's write decode in one cycle was one of clk_dec's four binding clusters; b_m
    // is set at start, a cycle before the first coefficient can be accepted) and, class 0,
    // for the DC scaling of the block being handed to the output
    logic signed [9:0] ls_in, ls_dc;
    always_comb begin
        case ({b_m, in_cls})
            5'b000_00: ls_in = 10'sd160; 5'b000_01: ls_in = 10'sd256; 5'b000_10: ls_in = 10'sd208;
            5'b001_00: ls_in = 10'sd176; 5'b001_01: ls_in = 10'sd288; 5'b001_10: ls_in = 10'sd224;
            5'b010_00: ls_in = 10'sd208; 5'b010_01: ls_in = 10'sd320; 5'b010_10: ls_in = 10'sd256;
            5'b011_00: ls_in = 10'sd224; 5'b011_01: ls_in = 10'sd368; 5'b011_10: ls_in = 10'sd288;
            5'b100_00: ls_in = 10'sd256; 5'b100_01: ls_in = 10'sd400; 5'b100_10: ls_in = 10'sd320;
            5'b101_00: ls_in = 10'sd288; 5'b101_01: ls_in = 10'sd464; 5'b101_10: ls_in = 10'sd368;
            default:   ls_in = 10'sd160;
        endcase
        case (b_m)
            3'd0: ls_dc = 10'sd160;
            3'd1: ls_dc = 10'sd176;
            3'd2: ls_dc = 10'sd208;
            3'd3: ls_dc = 10'sd224;
            3'd4: ls_dc = 10'sd256;
            3'd5: ls_dc = 10'sd288;
            default: ls_dc = 10'sd160;
        endcase
    end

    // stage 2: 8.5.12.1 (flat lists) -- d = (c * LevelScale) << (qp/6 - 4) for qp >= 24,
    // (c * LevelScale) >> (4 - qp/6) below (the vacuous rounding term omitted, see header)
    logic signed [25:0] dq_prod;
    logic signed [29:0] dq_ext, dq_sh;
    always_comb begin
        dq_prod = p1_coef * p1_ls;
        dq_ext  = {{4{dq_prod[25]}}, dq_prod};
        case (b_q6)
            4'd0: dq_sh = dq_ext >>> 4;
            4'd1: dq_sh = dq_ext >>> 3;
            4'd2: dq_sh = dq_ext >>> 2;
            4'd3: dq_sh = dq_ext >>> 1;
            4'd4: dq_sh = dq_ext;
            4'd5: dq_sh = dq_ext <<< 1;
            4'd6: dq_sh = dq_ext <<< 2;
            4'd7: dq_sh = dq_ext <<< 3;
            default: dq_sh = dq_ext <<< 4;
        endcase
    end
    wire signed [19:0] a_din = is_dc ? {{4{p1_coef[15]}}, p1_coef} : dq_sh[19:0];

    // ---- the 4-point butterfly (8.5.12.2 eq. 8-339..8-346 / the Hadamard rows of 8.5.10)
    // mode 0: e0 = x0 + x2, e1 = x0 - x2, e2 = (x1 >> 1) - x3, e3 = x1 + (x3 >> 1)
    //         y = [e0 + e3, e1 + e2, e1 - e2, e0 - e3]
    // mode 1: e0 = x0 + x1, e1 = x0 - x1, e2 = x2 - x3, e3 = x2 + x3
    //         y = [e0 + e3, e0 - e3, e1 - e2, e1 + e2]  (H = [1 1 1 1; 1 1 -1 -1; 1 -1 -1 1; 1 -1 1 -1])
    // the four output sums are the same set; only their order differs, resolved at the
    // write (kind 4's 2x2 transform, eq. 8-328, is mode 1 with the order [s03 a12 m03 m12])
    logic [1:0] ri, ci;
    logic signed [19:0] bx0, bx1, bx2, bx3;
    always_comb begin
        case (state)
            S_COL: begin
                bx0 = A[{2'd0, ci}]; bx1 = A[{2'd1, ci}]; bx2 = A[{2'd2, ci}]; bx3 = A[{2'd3, ci}];
            end
            S_CDC: begin
                bx0 = A[0]; bx1 = A[1]; bx2 = A[2]; bx3 = A[3];
            end
            default: begin
                bx0 = A[{ri, 2'd0}]; bx1 = A[{ri, 2'd1}]; bx2 = A[{ri, 2'd2}]; bx3 = A[{ri, 2'd3}];
            end
        endcase
    end
    wire had = is_dc;                    // the Hadamard butterfly for kinds 3 and 4
    // sign-extended to the butterfly width first, then the halves (arithmetic shifts)
    wire signed [21:0] x0  = {{2{bx0[19]}}, bx0};
    wire signed [21:0] x1  = {{2{bx1[19]}}, bx1};
    wire signed [21:0] x2  = {{2{bx2[19]}}, bx2};
    wire signed [21:0] x3  = {{2{bx3[19]}}, bx3};
    wire signed [21:0] x1h = x1 >>> 1;
    wire signed [21:0] x3h = x3 >>> 1;
    logic signed [21:0] e0, e1, e2, e3, s03, m03, a12, m12;
    always_comb begin
        if (had) begin
            e0 = x0 + x1;
            e1 = x0 - x1;
            e2 = x2 - x3;
            e3 = x2 + x3;
        end else begin
            e0 = x0 + x2;
            e1 = x0 - x2;
            e2 = x1h - x3;
            e3 = x1 + x3h;
        end
    end
    // two stages (the selection, the two adder levels and the write in one cycle missed
    // clk_dec): the issue registers e0..e3 (bq*) and where the result goes, the second
    // stage forms the outputs and writes them -- rows back to back into A, one bubble
    // (S_ROWW) before the columns read A, the columns / the 2x2 into O
    logic               bf_v, bf_had;
    logic [1:0]         bf_dst, bf_idx;      // dst 0 row of A, 1 column of O, 2 the 2x2 into O
    logic signed [21:0] bq0, bq1, bq2, bq3;
    always_comb begin
        s03 = bq0 + bq3;
        m03 = bq0 - bq3;
        a12 = bq1 + bq2;
        m12 = bq1 - bq2;
    end
    // mode 0: y = [s03 a12 m12 m03]; mode 1: y = [s03 m03 m12 a12]
    wire signed [21:0] y0 = s03;
    wire signed [21:0] y1 = bf_had ? m03 : a12;
    wire signed [21:0] y2 = m12;
    wire signed [21:0] y3 = bf_had ? a12 : m03;

    // ---- the output stream --------------------------------------------------------
    logic        o_active;               // the output buffer holds a block not yet fetched
    logic [4:0]  o_cnt, o_n;
    logic [2:0]  o_kind;
    logic [3:0]  o_q6;
    logic signed [9:0] o_ls;
    // the pipeline: fetch (p_*) then compute into res; it moves as a whole when the
    // output is free or being taken, so a stalled consumer holds every stage
    logic               p_valid, p_last;
    logic signed [19:0] p_val;
    logic [2:0]         p_kind;
    logic [3:0]         p_q6;
    logic signed [9:0]  p_ls;
    wire adv = !res_valid || res_ready;

    logic signed [29:0] o_prod;
    logic signed [31:0] o_ext, o_val;
    always_comb begin
        o_prod = p_val * p_ls;
        o_ext  = {{2{o_prod[29]}}, o_prod};
        case (p_kind)
            K_LDC:   // 8.5.10 eq. 8-326/8-327: qp >= 36 shifts left by qp/6 - 6, below it
                     // rounds by 2^(5 - qp/6) and shifts right by 6 - qp/6
                case (p_q6)
                    4'd0: o_val = (o_ext + 32) >>> 6;
                    4'd1: o_val = (o_ext + 16) >>> 5;
                    4'd2: o_val = (o_ext + 8) >>> 4;
                    4'd3: o_val = (o_ext + 4) >>> 3;
                    4'd4: o_val = (o_ext + 2) >>> 2;
                    4'd5: o_val = (o_ext + 1) >>> 1;
                    4'd6: o_val = o_ext;
                    4'd7: o_val = o_ext <<< 1;
                    default: o_val = o_ext <<< 2;
                endcase
            K_CDC:   // 8.5.11.2 eq. 8-330: ((f * LevelScale) << (qp/6)) >> 5
                case (p_q6)
                    4'd0: o_val = o_ext >>> 5;
                    4'd1: o_val = o_ext >>> 4;
                    4'd2: o_val = o_ext >>> 3;
                    4'd3: o_val = o_ext >>> 2;
                    4'd4: o_val = o_ext >>> 1;
                    4'd5: o_val = o_ext;
                    4'd6: o_val = o_ext <<< 1;
                    4'd7: o_val = o_ext <<< 2;
                    default: o_val = o_ext <<< 3;
                endcase
            default: // 8.5.12.2 eq. 8-347: r_ij = (h_ij + 32) >> 6
                o_val = ({{12{p_val[19]}}, p_val} + 32) >>> 6;
        endcase
    end

    // ---- control -----------------------------------------------------------------
    wire   in_acc     = coef_valid && coef_ready;
    wire   o_free     = !o_active;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;
            coef_ready <= 1'b0; busy <= 1'b0;
            b_kind <= 3'd0; b_q6 <= 4'd0; b_m <= 3'd0; b_field <= 1'b0; b_ncoef <= 5'd16;
            cnt <= 5'd0; ri <= 2'd0; ci <= 2'd0;
            p1_valid <= 1'b0; p1_coef <= 16'sd0; p1_r <= 4'd0; p1_ls <= 10'sd0;
            o_active <= 1'b0; o_cnt <= 5'd0; o_n <= 5'd16; o_kind <= 3'd0; o_q6 <= 4'd0; o_ls <= 10'sd0;
            p_valid <= 1'b0; p_last <= 1'b0; p_val <= 20'sd0; p_kind <= 3'd0; p_q6 <= 4'd0; p_ls <= 10'sd0;
            res_valid <= 1'b0; res <= 16'sd0; res_last <= 1'b0;
            bf_v <= 1'b0; bf_had <= 1'b0; bf_dst <= 2'd0; bf_idx <= 2'd0; bq0 <= '0; bq1 <= '0; bq2 <= '0; bq3 <= '0;
        end else begin
            // ---- intake stage 1 -> stage 2 (the buffer write)
            p1_valid <= in_acc;
            if (in_acc) begin
                p1_coef <= coef;
                p1_r    <= in_r;
                p1_ls   <= ls_in;
            end
            if (p1_valid) A[p1_r] <= a_din;

            // ---- the butterfly's second stage
            bf_v <= 1'b0;
            if (bf_v) begin
                case (bf_dst)
                    2'd0: begin
                        A[{bf_idx, 2'd0}] <= y0[19:0]; A[{bf_idx, 2'd1}] <= y1[19:0];
                        A[{bf_idx, 2'd2}] <= y2[19:0]; A[{bf_idx, 2'd3}] <= y3[19:0];
                    end
                    2'd1: begin
                        O[{2'd0, bf_idx}] <= y0[19:0]; O[{2'd1, bf_idx}] <= y1[19:0];
                        O[{2'd2, bf_idx}] <= y2[19:0]; O[{2'd3, bf_idx}] <= y3[19:0];
                        if (bf_idx == 2'd3) begin o_active <= 1'b1; o_cnt <= 5'd0; end
                    end
                    default: begin
                        O[0] <= s03[19:0]; O[1] <= a12[19:0]; O[2] <= m03[19:0]; O[3] <= m12[19:0];
                        o_active <= 1'b1; o_cnt <= 5'd0;
                    end
                endcase
            end

            // ---- the block sequencer
            case (state)
                S_IDLE: if (start) begin
                    b_kind  <= kind;
                    b_q6    <= q6_w;
                    b_m     <= m_w[2:0];
                    b_field <= field_scan;
                    b_ncoef <= (kind == K_CDC) ? 5'd4 : ((kind == K_LAC || kind == K_CAC) ? 5'd15 : 5'd16);
                    cnt     <= 5'd0;
                    ri      <= 2'd0;
                    ci      <= 2'd0;
                    // an AC block's d00 is the DC value the DC path produced (8.5.10 / 8.5.11)
                    if (kind == K_LAC || kind == K_CAC) A[0] <= {{4{dc_in[15]}}, dc_in};
                    coef_ready <= 1'b1;
                    busy    <= 1'b1;
                    state   <= S_IN;
                end
                S_IN: if (in_acc) begin
                    cnt <= cnt + 5'd1;
                    if (cnt == b_ncoef - 5'd1) begin
                        coef_ready <= 1'b0;
                        state <= S_DRAIN;
                    end
                end
                S_DRAIN: begin                       // the last coefficient lands in A this cycle
                    if (b_kind == K_CDC) state <= S_CDC;
                    else                 state <= S_ROW;
                end
                S_ROW: begin                         // row ri issued (written in place next cycle)
                    bf_v <= 1'b1; bf_dst <= 2'd0; bf_idx <= ri; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    ri <= ri + 2'd1;
                    if (ri == 2'd3) state <= S_ROWW;
                end
                S_ROWW: state <= S_COL;              // row 3 lands in A
                S_COL: if (ci != 2'd0 || o_free) begin   // column ci issued (into O next cycle)
                    bf_v <= 1'b1; bf_dst <= 2'd1; bf_idx <= ci; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    ci <= ci + 2'd1;
                    if (ci == 2'd0) begin
                        o_kind <= b_kind; o_q6 <= b_q6; o_ls <= ls_dc; o_n <= 5'd16;
                    end
                    if (ci == 2'd3) begin
                        busy  <= 1'b0;
                        state <= S_IDLE;
                    end
                end
                S_CDC: if (o_free) begin             // eq. 8-328: f = [c0+c1+c2+c3, c0-c1+c2-c3, c0+c1-c2-c3, c0-c1-c2+c3]
                    bf_v <= 1'b1; bf_dst <= 2'd2; bf_idx <= 2'd0; bf_had <= had;
                    bq0 <= e0; bq1 <= e1; bq2 <= e2; bq3 <= e3;
                    o_kind <= b_kind; o_q6 <= b_q6; o_ls <= ls_dc; o_n <= 5'd4;
                    busy  <= 1'b0;
                    state <= S_IDLE;
                end
                default: begin
                    busy <= 1'b0; coef_ready <= 1'b0;
                    state <= S_IDLE;
                end
            endcase

            // ---- the output pipeline
            if (adv) begin
                res_valid <= p_valid;
                res_last  <= p_last;
                res       <= o_val[15:0];
                p_valid   <= o_active;
                if (o_active) begin
                    p_val  <= O[o_cnt[3:0]];
                    p_last <= (o_cnt == o_n - 5'd1);
                    p_kind <= o_kind; p_q6 <= o_q6; p_ls <= o_ls;
                    o_cnt  <= o_cnt + 5'd1;
                    if (o_cnt == o_n - 5'd1) o_active <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
