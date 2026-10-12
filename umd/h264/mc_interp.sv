// umd/h264/mc_interp.sv -- the fractional sample interpolator (ITU-T H.264 8.4.2.2)
//
// Luma (8.4.2.2.1): the 6-tap (1, -5, 20, 20, -5, 1) half-sample filter, b/h/m/s as
// Clip1((x + 16) >> 5), the centre j = Clip1((j1 + 512) >> 10) from the UNclipped
// intermediates, the quarter positions as the rounded averages of Table 8-12.
// Chroma (8.4.2.2.2, 4:2:0): ((8-xF)(8-yF)A + xF(8-yF)B + (8-xF)yF C + xF yF D + 32) >> 6.
// Bit-exact against tools/h264_recon_ref.py's mc_luma / mc_chroma (proven against
// ffmpeg), scored by bench/umd/run_mc.sh. docs/h264_recon.md S2.4.
//
// The window RAM (a synchronous read port, ONE cycle of latency, one sample per cycle)
// holds the reference samples the caller fetched, row-major:
//   luma:   (w+5) columns x (h+5) rows, stride w+5, window (0,0) = reference (xInt-2,
//           yInt-2): output sample (x, y) has its integer sample G at window (x+2, y+2)
//   chroma: (w+1) x (h+1), stride w+1, window (0,0) = (xInt, yInt).
// (w+5 suffices: the 6 taps of b reach columns x..x+5, m one column right of h is
// x+3, s one row below b is y+3 -- the model over-fetches w+6 for convenience.)
//
// The design: ONE raster sweep of a sub-window with every intermediate derived from
// the sample just read plus a per-column history of the five samples above it (a
// 32 x 40-bit RAM indexed by the window column: the line buffer of SAMPLES, which is
// cheaper than a line buffer of 16-bit intermediates and lets every filter be recomputed
// from bytes), so the window is read exactly once:
//   h1  vertical 6-tap  of history(rows r-5..r-1) + sample(row r)     -> the h/m column
//   b1  horizontal 6-tap over a 6-deep shift register of row r-3      (= output row y+2)
//   s1  horizontal 6-tap over a shift register of row r-2             (= y+3)
//   j1  horizontal 6-tap over a 6-deep shift register of h1 (8-245 allows either
//       order: j1 = aa - 5bb + 20b1 + 20s1 - 5gg + hh or from the vertical ones; the
//       36-product sum is the same integer)
//   G/H/M are taps of the same shift registers.
// The sweep is narrowed per position class so a partition costs what it needs (the
// issued reads, plus a fixed 11 cycles from start to the last sample taken):
//   G (0,0)          rows 2..h+1, cols 2..w+1    w*h reads
//   a b c (yF = 0)   rows 2..h+1, cols 0..w+4    h*(w+5)     the 6-tap on the row read
//   d h n (xF = 0)   rows 0..h+4, cols 2..w+1    (h+5)*w
//   e..r (both)      rows 0..h+4, cols 0..w+4    (h+5)*(w+5)
//   chroma           rows 0..h-1+(yF!=0), cols 0..w-1+(xF!=0): w*h .. (w+1)*(h+1)
// Measured by mc_interp_tb (start to the last sample consumed, always-ready consumer;
// bench/umd/run_mc.sh prints the whole table), cycles per partition (samples/cycle):
//   luma 16x16: G 267 (0.95), a/b/c 347 (0.73), d/h/n 347 (0.73), e..r 452 (0.56)
//   luma  8x8:     75 (0.85)        115 (0.55)        115 (0.55)        180 (0.35)
//   luma  4x4:     27 (0.59)         47 (0.34)         47 (0.34)         92 (0.17)
//   chroma 8x8:    75 (0.85)         83 (0.77)         83 (0.77)         92 (0.69)
//   chroma 4x4:    27 (0.59)         31 (0.51)         31 (0.51)         36 (0.44)
//   chroma 2x2:    15 (0.26)         17 (0.23)         17 (0.23)         20 (0.20)
// One sample per cycle is reached only where the window has no more samples than the
// output (G); every other class is BOUND BY THE 8-BIT WINDOW READ PORT, which delivers
// one sample per cycle and must deliver (w+5)(h+5) of them for a whole-fractional
// partition of w*h samples -- no arrangement of the filters changes that with this
// port. What would: a wider port (two samples a cycle from a 16-bit window RAM), or
// not fetching the four (2..3)x(2..3) corners that only j / the diagonals need (16-36
// of 81 reads at 4x4). Neither is built: a bi-predicted macroblock in sixteen 4x4
// partitions at those positions is the one shape over the 2,500-cycle budget
// (docs/h264_recon.md), and inter_pred can weigh the wider port against the fetch it
// already owes.
//
// Flow control: the front of the pipeline never stalls (the window RAM output cannot be
// held), the samples land in a 16-deep output FIFO and the sweep issues an output-
// producing read only while fewer than 16 are in flight (issued, not yet taken by the
// consumer); the prologue reads (no output) are never gated. win_addr is a registered
// output; a read is 9 register stages from its address to the FIFO (RAM, S1..S7),
// then the output register. The two shift-register rows and the h1 row only advance
// on a real read, so a credit bubble shifts nothing in.
//
// start (one pulse, while !busy) latches every parameter; busy holds until the last
// sample is taken. Every filter sum is a stage of its own (partial pair sums, then the
// 1/-5/20 weighting as shifts and adds -- no multipliers in the luma path; the chroma
// path is the separable bilinear ((8-yF)*((8-xF)A + xF B) + yF*((8-xF)C + xF D) + 32)
// >> 6, four 8x4 and two 12x4 products, the same integer as the spec's four-term sum).
// Widths: h1 / b1 / s1 in -2550..10710 (16-bit signed), j1 in -214200..475320 (21-bit
// signed); the Clip1 at each site tests the sign bit and the bits above the byte.
// Estimate: ~900 registers, one M10K/MLAB for the history (32 x 40), an MLAB for the
// FIFO (16 x 9), the six small chroma products, no DSP needed. Written without
// function helpers or N'() casts (Quartus 17, CLAUDE.md).

`default_nettype none

module mc_interp (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        start,
    input  wire        is_chroma,
    input  wire  [2:0] frac_x,       // luma 0..3 (quarter), chroma 0..7 (eighth)
    input  wire  [2:0] frac_y,
    input  wire  [4:0] w,            // the partition size in samples of THIS plane
    input  wire  [4:0] h,

    // the window RAM read port: synchronous, one cycle of latency
    output logic [8:0] win_addr,
    input  wire  [7:0] win_data,

    // the prediction samples in raster order, w*h of them
    output logic       pred_valid,
    output logic [7:0] pred,
    output logic       pred_last,
    input  wire        pred_ready,

    output logic       busy
);

    localparam [2:0] C_FULL = 3'd0, C_H = 3'd1, C_V = 3'd2, C_GEN = 3'd3, C_CHR = 3'd4;

    // ---- the partition's parameters, latched at start -------------------------------
    logic [2:0] cls;
    logic [1:0] fx, fy;               // the luma quarter position
    logic       xnz, ynz;             // chroma: a fractional x / y at all
    logic [3:0] wx0, wx1, wy0, wy1;   // chroma weights 8-xF, xF, 8-yF, yF
    logic [4:0] c0, c1, r0, r1;       // the sub-window swept, inclusive
    logic [4:0] c_thr, r_thr;         // the first column / row that yields an output
    logic [4:0] stride;
    logic       active;               // reads still to issue
    logic [4:0] c, r;                 // the next read
    logic [8:0] row_base;             // r * stride, accumulated
    logic [4:0] inflight;             // output samples issued and not yet taken (<= 16)

    wire [4:0] wp5 = w + 5'd5;
    wire [4:0] wp1 = w + 5'd1;
    wire       in_xnz = |frac_x;
    wire       in_ynz = |frac_y;

    // ---- the output FIFO and the consumer handshake --------------------------------
    logic [8:0] fmem [0:15];
    logic [3:0] wptr, rptr;
    logic [4:0] fcnt;
    wire        pop  = pred_valid && pred_ready;
    wire        load = (fcnt != 5'd0) && (!pred_valid || pred_ready);
    wire        fpush;                // an output sample leaves the pipeline (S7)
    wire  [7:0] res;

    // ---- the sweep --------------------------------------------------------------------
    wire ov_now   = (c >= c_thr) && (r >= r_thr);          // this read yields an output
    wire last_now = (c == c1) && (r == r1);
    wire issue    = active && (!ov_now || (inflight < 5'd16));

    // tags: a = the address just registered, b = the RAM output, 1..6 = the stages
    logic       ta_iss, ta_ov, ta_last, tb_iss, tb_ov, tb_last;
    logic [4:0] ta_c, tb_c;
    logic       t1_iss, t1_ov, t1_last, t2_iss, t2_ov, t2_last, t3_iss, t3_ov, t3_last;
    logic       t4_iss, t4_ov, t4_last, t5_ov, t5_last, t6_ov, t6_last;

    // ---- the column history: 5 samples above the one being read ---------------------
    logic [39:0] hist_mem [0:31];
    logic [4:0]  hist_raddr;
    logic [39:0] hist_q;
    always_ff @(posedge clk) begin
        hist_q <= hist_mem[hist_raddr];
        if (tb_iss) hist_mem[tb_c] <= {hist_q[31:0], win_data};
    end
    // hist_q at S1 for a read of row r: [7:0] row r-1, [15:8] r-2, [23:16] r-3, [31:24] r-4, [39:32] r-5

    // ---- S1: the sample and its column history ---------------------------------------
    logic [7:0]  smp;
    logic [39:0] hst;

    // ---- S2: the row shift registers (6 deep) and the vertical partial sums ----------
    logic [7:0]  gr0, gr1, gr2, gr3, gr4, gr5;    // the G row (y+2), or the row read
    logic [7:0]  mr0, mr1, mr2, mr3, mr4, mr5;    // the M / s row (y+3), or the row above (chroma)
    logic [8:0]  vp0, vp1, vp2;
    wire  [7:0]  gr_in = (cls == C_V || cls == C_GEN) ? hst[23:16] : smp;
    wire  [7:0]  mr_in = (cls == C_CHR) ? hst[7:0] : hst[15:8];

    // ---- S3: h1, the horizontal partial sums, the integer taps ------------------------
    logic signed [15:0] h1;
    logic [8:0]  bp0, bp1, bp2, sp0, sp1, sp2;
    logic [7:0]  g3, hh3, m3;                     // G, H, M
    logic [7:0]  ca3, cb3, cc3, cd3;              // chroma A, B, C, D (0 where the weight is 0)
    wire signed [15:0] vp0s = {7'd0, vp0};
    wire signed [15:0] vp1s = {7'd0, vp1};
    wire signed [15:0] vp2s = {7'd0, vp2};

    // ---- S4: the h1 shift register (6 deep), b1, s1, the chroma horizontal products --
    logic signed [15:0] jr0, jr1, jr2, jr3, jr4, jr5;
    logic signed [15:0] bsum, ssum;
    logic [7:0]  g4, hh4, m4;
    logic [11:0] cha, chc;
    wire signed [15:0] bp0s = {7'd0, bp0};
    wire signed [15:0] bp1s = {7'd0, bp1};
    wire signed [15:0] bp2s = {7'd0, bp2};
    wire signed [15:0] sp0s = {7'd0, sp0};
    wire signed [15:0] sp1s = {7'd0, sp1};
    wire signed [15:0] sp2s = {7'd0, sp2};

    // ---- S5: the j partial sums, the h / m taps, the chroma vertical sum -------------
    logic signed [16:0] jp0, jp1, jp2;
    logic signed [15:0] hsel5, msel5, bsum5, ssum5;
    logic [7:0]  g5, hh5, m5;
    logic [15:0] cv;
    wire signed [20:0] jp0s = {{4{jp0[16]}}, jp0};
    wire signed [20:0] jp1s = {{4{jp1[16]}}, jp1};
    wire signed [20:0] jp2s = {{4{jp2[16]}}, jp2};

    // ---- S6: j1, the clipped half-samples, the chroma result -------------------------
    logic signed [20:0] jsum;
    logic [7:0]  b6, s6, h6, m6, g6, hh6, m6i, cr6;
    // Clip1((x + 16) >> 5) for the half-samples (8-241..8-244), Clip1((j1 + 512) >> 10)
    // for the centre (8-246): the rounded value is negative when its sign bit is set,
    // above 255 when any bit above the low byte is
    wire signed [15:0] bt = (bsum5 + 16'sd16) >>> 5;
    wire signed [15:0] st = (ssum5 + 16'sd16) >>> 5;
    wire signed [15:0] ht = (hsel5 + 16'sd16) >>> 5;
    wire signed [15:0] mt = (msel5 + 16'sd16) >>> 5;
    wire signed [20:0] jt = (jsum + 21'sd512) >>> 10;
    wire  [7:0]  b_clip = bt[15] ? 8'd0 : (|bt[14:8])  ? 8'd255 : bt[7:0];
    wire  [7:0]  s_clip = st[15] ? 8'd0 : (|st[14:8])  ? 8'd255 : st[7:0];
    wire  [7:0]  h_clip = ht[15] ? 8'd0 : (|ht[14:8])  ? 8'd255 : ht[7:0];
    wire  [7:0]  m_clip = mt[15] ? 8'd0 : (|mt[14:8])  ? 8'd255 : mt[7:0];
    wire  [7:0]  j_clip = jt[20] ? 8'd0 : (|jt[19:8])  ? 8'd255 : jt[7:0];

    // ---- S7: Table 8-12, into the FIFO -----------------------------------------------
    logic [7:0] opa, opb;
    logic       single;
    always_comb begin
        single = 1'b0;
        opa = g6; opb = g6;
        case ({fy, fx})
            4'b00_00: begin opa = g6;  single = 1'b1; end          // G
            4'b00_01: begin opa = g6;  opb = b6;  end              // a = (G + b + 1) >> 1
            4'b00_10: begin opa = b6;  single = 1'b1; end          // b
            4'b00_11: begin opa = hh6; opb = b6;  end              // c = (H + b + 1) >> 1
            4'b01_00: begin opa = g6;  opb = h6;  end              // d = (G + h + 1) >> 1
            4'b01_01: begin opa = b6;  opb = h6;  end              // e = (b + h + 1) >> 1
            4'b01_10: begin opa = b6;  opb = j_clip; end           // f = (b + j + 1) >> 1
            4'b01_11: begin opa = b6;  opb = m6;  end              // g = (b + m + 1) >> 1
            4'b10_00: begin opa = h6;  single = 1'b1; end          // h
            4'b10_01: begin opa = h6;  opb = j_clip; end           // i = (h + j + 1) >> 1
            4'b10_10: begin opa = j_clip; single = 1'b1; end       // j
            4'b10_11: begin opa = j_clip; opb = m6; end            // k = (j + m + 1) >> 1
            4'b11_00: begin opa = m6i; opb = h6;  end              // n = (M + h + 1) >> 1
            4'b11_01: begin opa = h6;  opb = s6;  end              // p = (h + s + 1) >> 1
            4'b11_10: begin opa = j_clip; opb = s6; end            // q = (j + s + 1) >> 1
            default:  begin opa = m6;  opb = s6;  end              // r = (m + s + 1) >> 1
        endcase
    end
    wire [8:0] avg9 = {1'b0, opa} + {1'b0, opb} + 9'd1;
    assign res   = (cls == C_CHR) ? cr6 : single ? opa : avg9[8:1];
    assign fpush = t6_ov;
    always_ff @(posedge clk) if (fpush) fmem[wptr] <= {t6_last, res};

    // ---- registers ----------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cls <= C_FULL; fx <= 2'd0; fy <= 2'd0; xnz <= 1'b0; ynz <= 1'b0;
            wx0 <= 4'd0; wx1 <= 4'd0; wy0 <= 4'd0; wy1 <= 4'd0;
            c0 <= 5'd0; c1 <= 5'd0; r0 <= 5'd0; r1 <= 5'd0; c_thr <= 5'd0; r_thr <= 5'd0;
            stride <= 5'd0; active <= 1'b0; c <= 5'd0; r <= 5'd0; row_base <= 9'd0;
            inflight <= 5'd0; busy <= 1'b0;
            win_addr <= 9'd0; hist_raddr <= 5'd0;
            ta_iss <= 1'b0; ta_ov <= 1'b0; ta_last <= 1'b0; ta_c <= 5'd0;
            tb_iss <= 1'b0; tb_ov <= 1'b0; tb_last <= 1'b0; tb_c <= 5'd0;
            t1_iss <= 1'b0; t1_ov <= 1'b0; t1_last <= 1'b0;
            t2_iss <= 1'b0; t2_ov <= 1'b0; t2_last <= 1'b0;
            t3_iss <= 1'b0; t3_ov <= 1'b0; t3_last <= 1'b0;
            t4_iss <= 1'b0; t4_ov <= 1'b0; t4_last <= 1'b0;
            t5_ov <= 1'b0; t5_last <= 1'b0; t6_ov <= 1'b0; t6_last <= 1'b0;
            wptr <= 4'd0; rptr <= 4'd0; fcnt <= 5'd0;
            pred_valid <= 1'b0; pred <= 8'd0; pred_last <= 1'b0;
        end else begin
            // -- start: the class and the sub-window
            if (start && !busy) begin
                busy <= 1'b1; active <= 1'b1; inflight <= 5'd0;
                fx <= frac_x[1:0]; fy <= frac_y[1:0];
                xnz <= in_xnz; ynz <= in_ynz;
                wx0 <= 4'd8 - {1'b0, frac_x}; wx1 <= {1'b0, frac_x};
                wy0 <= 4'd8 - {1'b0, frac_y}; wy1 <= {1'b0, frac_y};
                stride <= is_chroma ? wp1 : wp5;
                if (is_chroma) begin
                    cls <= C_CHR;
                    c0 <= 5'd0; c1 <= w - 5'd1 + {4'd0, in_xnz}; c_thr <= {4'd0, in_xnz};
                    r0 <= 5'd0; r1 <= h - 5'd1 + {4'd0, in_ynz}; r_thr <= {4'd0, in_ynz};
                    c <= 5'd0; r <= 5'd0; row_base <= 9'd0;
                end else if (!in_xnz && !in_ynz) begin
                    cls <= C_FULL;
                    c0 <= 5'd2; c1 <= wp1; c_thr <= 5'd2;
                    r0 <= 5'd2; r1 <= h + 5'd1; r_thr <= 5'd2;
                    c <= 5'd2; r <= 5'd2; row_base <= {3'd0, wp5, 1'b0};
                end else if (!in_ynz) begin
                    cls <= C_H;
                    c0 <= 5'd0; c1 <= w + 5'd4; c_thr <= 5'd5;
                    r0 <= 5'd2; r1 <= h + 5'd1; r_thr <= 5'd2;
                    c <= 5'd0; r <= 5'd2; row_base <= {3'd0, wp5, 1'b0};
                end else if (!in_xnz) begin
                    cls <= C_V;
                    c0 <= 5'd2; c1 <= wp1; c_thr <= 5'd2;
                    r0 <= 5'd0; r1 <= h + 5'd4; r_thr <= 5'd5;
                    c <= 5'd2; r <= 5'd0; row_base <= 9'd0;
                end else begin
                    cls <= C_GEN;
                    c0 <= 5'd0; c1 <= w + 5'd4; c_thr <= 5'd5;
                    r0 <= 5'd0; r1 <= h + 5'd4; r_thr <= 5'd5;
                    c <= 5'd0; r <= 5'd0; row_base <= 9'd0;
                end
            end else begin
                // -- the sweep
                if (issue) begin
                    win_addr   <= row_base + {4'd0, c};
                    hist_raddr <= c;
                    if (c == c1) begin
                        c <= c0; r <= r + 5'd1; row_base <= row_base + {4'd0, stride};
                    end else c <= c + 5'd1;
                    if (last_now) active <= 1'b0;
                end
                inflight <= inflight + {4'd0, (issue && ov_now)} - {4'd0, pop};
                if (pop && pred_last) busy <= 1'b0;
            end

            // -- the tags
            ta_iss <= issue; ta_ov <= issue && ov_now; ta_last <= issue && last_now; ta_c <= c;
            tb_iss <= ta_iss; tb_ov <= ta_ov; tb_last <= ta_last; tb_c <= ta_c;
            t1_iss <= tb_iss; t1_ov <= tb_ov; t1_last <= tb_last;
            t2_iss <= t1_iss; t2_ov <= t1_ov; t2_last <= t1_last;
            t3_iss <= t2_iss; t3_ov <= t2_ov; t3_last <= t2_last;
            t4_iss <= t3_iss; t4_ov <= t3_ov; t4_last <= t3_last;
            t5_ov <= t4_ov; t5_last <= t4_last;
            t6_ov <= t5_ov; t6_last <= t5_last;

            // -- S1
            smp <= win_data;
            hst <= hist_q;

            // -- S2 (the shift registers only move on a real read: a credit bubble must
            //       not shift garbage into a row)
            if (t1_iss) begin
                gr0 <= gr1; gr1 <= gr2; gr2 <= gr3; gr3 <= gr4; gr4 <= gr5; gr5 <= gr_in;
                mr0 <= mr1; mr1 <= mr2; mr2 <= mr3; mr3 <= mr4; mr4 <= mr5; mr5 <= mr_in;
            end
            vp0 <= {1'b0, hst[39:32]} + {1'b0, smp};        // rows r-5 and r     (taps 1)
            vp1 <= {1'b0, hst[31:24]} + {1'b0, hst[7:0]};   // rows r-4 and r-1   (taps -5)
            vp2 <= {1'b0, hst[23:16]} + {1'b0, hst[15:8]};  // rows r-3 and r-2   (taps 20)

            // -- S3
            h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4) + (vp2s <<< 2);
            bp0 <= {1'b0, gr0} + {1'b0, gr5};
            bp1 <= {1'b0, gr1} + {1'b0, gr4};
            bp2 <= {1'b0, gr2} + {1'b0, gr3};
            sp0 <= {1'b0, mr0} + {1'b0, mr5};
            sp1 <= {1'b0, mr1} + {1'b0, mr4};
            sp2 <= {1'b0, mr2} + {1'b0, mr3};
            g3  <= (cls == C_H || cls == C_GEN) ? gr2 : gr5;
            hh3 <= gr3;
            m3  <= (cls == C_GEN) ? mr2 : mr5;
            // chroma: D = (x+1, y+1) is the sample read, C its left neighbour, A / B the row
            // above; where a weight is 0 the operand is 0 (an X times 0 is X in simulation)
            ca3 <= ynz ? (xnz ? mr4 : mr5) : (xnz ? gr4 : gr5);
            cb3 <= xnz ? (ynz ? mr5 : gr5) : 8'd0;
            cc3 <= ynz ? (xnz ? gr4 : gr5) : 8'd0;
            cd3 <= (xnz && ynz) ? gr5 : 8'd0;

            // -- S4
            if (t3_iss) begin
                jr0 <= jr1; jr1 <= jr2; jr2 <= jr3; jr3 <= jr4; jr4 <= jr5; jr5 <= h1;
            end
            bsum <= bp0s - (bp1s <<< 2) - bp1s + (bp2s <<< 4) + (bp2s <<< 2);
            ssum <= sp0s - (sp1s <<< 2) - sp1s + (sp2s <<< 4) + (sp2s <<< 2);
            g4 <= g3; hh4 <= hh3; m4 <= m3;
            cha <= wx0 * ca3 + wx1 * cb3;
            chc <= wx0 * cc3 + wx1 * cd3;

            // -- S5
            jp0 <= {jr0[15], jr0} + {jr5[15], jr5};
            jp1 <= {jr1[15], jr1} + {jr4[15], jr4};
            jp2 <= {jr2[15], jr2} + {jr3[15], jr3};
            hsel5 <= (cls == C_GEN) ? jr2 : jr5;
            msel5 <= jr3;
            bsum5 <= bsum; ssum5 <= ssum;
            g5 <= g4; hh5 <= hh4; m5 <= m4;
            cv <= wy0 * cha + wy1 * chc + 16'd32;

            // -- S6
            jsum <= jp0s - (jp1s <<< 2) - jp1s + (jp2s <<< 4) + (jp2s <<< 2);
            b6 <= b_clip; s6 <= s_clip; h6 <= h_clip; m6 <= m_clip;
            g6 <= g5; hh6 <= hh5; m6i <= m5;
            cr6 <= cv[13:6];

            // -- S7: into the FIFO, and the output register
            if (t6_ov) wptr <= wptr + 4'd1;
            if (load) begin
                {pred_last, pred} <= fmem[rptr];
                rptr <= rptr + 4'd1;
                pred_valid <= 1'b1;
            end else if (pop) pred_valid <= 1'b0;
            fcnt <= fcnt + {4'd0, t6_ov} - {4'd0, load};
        end
    end

endmodule


`default_nettype wire
