// umd/h264/intra_pred.sv -- intra sample prediction (ITU-T H.264 8.3)
//
//   8.3.1.2   Intra_4x4: the nine modes (8.3.1.2.1 Vertical .. 8.3.1.2.9 Horizontal_Up)
//   8.3.3     Intra_16x16: Vertical, Horizontal, DC, Plane (8.3.3.1-4)
//   8.3.4     Intra chroma for 4:2:0: DC (8.3.4.1-3 per 4x4 chroma block), Horizontal,
//             Vertical, Plane (8.3.4.4)
//
// Bit-exact against tools/h264_recon_ref.py (intra4x4_pred, intra16x16_pred,
// intra_chroma_pred -- the model proven pixel-exact vs ffmpeg), scored by
// bench/umd/run_intra_pred.sh over random neighbours in every legal availability
// combination and the recorded calls of a real x264 intra clip. docs/h264_recon.md S2.4.
//
// Neighbour store (33 bytes of registers, written by the caller BEFORE start, read live
// while the block streams -- never write it while busy):
//   nb[0..15]  p[x, -1]  x = 0..15   (Intra_4x4 uses 0..7; the caller has already put
//                                     p[3,-1] into p[4..7,-1] when the above-right samples
//                                     are not available, 8.3.1.2)
//   nb[16..31] p[-1, y]  y = 0..15   (Intra_4x4 uses 0..3, chroma 0..7)
//   nb[32]     p[-1, -1]
// avail_top / avail_left say whether the p[x,-1] / p[-1,y] runs exist; only the DC modes
// read them (8.3.1.2.3, 8.3.3.3, 8.3.4.1-3). Every other mode may only be selected when
// the samples it uses are available (the encoder's obligation, stated in each clause),
// so the unit reads them without looking at the flags.
//
// start (one pulse, ignored while busy) with kind / mode / avail_*:
//   kind 0  luma 4x4    mode = Intra4x4PredMode 0..8 (Table 8-2)        16 samples
//   kind 1  luma 16x16  mode = Intra16x16PredMode 0 V 1 H 2 DC 3 Plane  256 samples
//   kind 2  chroma 8x8  mode = intra_chroma_pred_mode 0 DC 1 H 2 V 3 Plane  64 samples
// The samples leave in raster order on pred_valid/pred/pred_last with pred_ready as the
// consumer's throttle: one per cycle when the consumer is ready. busy rises with start
// and drops when the last sample is taken.
//
// Datapath. Every sample is one of three shapes of the same 3-tap sum from the store:
//   COPY  t0                          AVG2  (t0 + t1 + 1) >> 1
//   AVG3  (t0 + 2 t1 + t2 + 2) >> 2   (the "(a + 3 b + 2) >> 2" corners are AVG3(a, b, b))
// The stream is a two-stage pipeline gated by one enable (the output register free or
// being taken): stage A fetches the taps of position pos (four 33:1 muxes over the
// register store; the tap indices come from the spec's case analysis on (x, y) --
// zVR, zHD, zHU -- written as one pattern (m-2, m-1, m) / (m-1, m) / (m, m+1, m+2) /
// (m, m+1) / (m, m+1, m+1) / the corner (p[-1,0], p[-1,-1], p[0,-1]) / a copy, on one
// side T or L; a negative offset is p[-1,-1]), stage B adds. Before the stream:
//   DC     the store summed four samples a cycle (the same tap muxes), the mean(s)
//          registered with the spec's rounding and availability rules: 2 + 2 cycles for
//          a 4x4, 8 + 2 for 16x16, 4 + 2 for chroma (its four quadrant means at once)
//   Plane  H and V (8-70 / 8-121) by nested accumulation instead of multiplies:
//          sum_k k d_k = sum_j (sum_{k>=j} d_k), the d_k walked from the last one down
//          (N cycles + 1), then a / b / c (a cycle; 5 H and 34 H are shift-adds), then
//          the first sample's a + b (x-7) + c (y-7) + 16 (a cycle); per sample the
//          accumulator moves by b along a row and by c to the next row, Clip1 at the
//          register. No multipliers anywhere.
// busy cycles per block, measured (samples + 2 pipeline stages + the prep: DC N+2 cycles,
// Plane N+3, N = groups of four summed / plane taps): 4x4 V/H/directional 18, 4x4 DC 22;
// 16x16 V/H 258, DC 268, Plane 269; chroma H/V 66, DC 72, Plane 73. The next start is
// accepted the cycle after busy falls.
//
// Quartus 17 caveats observed (CLAUDE.md): no `function automatic`, no N'(expr) casts;
// case blocks and part-selects throughout.

`default_nettype none

module intra_pred (
    input  wire        clk,
    input  wire        rst_n,

    // the neighbour store's write port
    input  wire        nb_we,
    input  wire  [5:0] nb_idx,
    input  wire  [7:0] nb_val,

    // the block request
    input  wire        start,
    input  wire  [1:0] kind,
    input  wire  [3:0] mode,
    input  wire        avail_top,
    input  wire        avail_left,

    // the prediction samples, raster order
    output logic       pred_valid,
    output logic [7:0] pred,
    output logic       pred_last,
    input  wire        pred_ready,

    output logic       busy
);

    localparam [1:0] K_L4 = 2'd0, K_L16 = 2'd1, K_CH = 2'd2;
    // the operation decoded from (kind, mode) at start
    localparam [2:0] OP_V = 3'd0, OP_H = 3'd1, OP_DC = 3'd2, OP_PLANE = 3'd3, OP_DIR = 3'd4;
    // the sum shapes
    localparam [1:0] F_COPY = 2'd0, F_AVG2 = 2'd1, F_AVG3 = 2'd2;
    // the tap patterns of the 4x4 case analysis
    localparam [2:0] P_M12 = 3'd0,      // (m-2, m-1, m)   AVG3
                     P_M01 = 3'd1,      // (m-1, m)        AVG2
                     P_P12 = 3'd2,      // (m, m+1, m+2)   AVG3
                     P_P01 = 3'd3,      // (m, m+1)        AVG2
                     P_P11 = 3'd4,      // (m, m+1, m+1)   AVG3: the (a + 3b + 2) >> 2 corners
                     P_CNR = 3'd5,      // (p[-1,0], p[-1,-1], p[0,-1]) AVG3
                     P_CPY = 3'd6;      // (m)             COPY
    localparam [5:0] I_CORNER = 6'd32;

    // ---- the neighbour store ----------------------------------------------------------
    // 33 bytes of registers, read through four 33:1 tap muxes (t0..t3 below): pinned to
    // logic so Quartus never tries a RAM with four asynchronous read ports (CLAUDE.md:
    // async-read arrays at many sites explode into LUT-RAM)
    (* ramstyle = "logic" *) logic [7:0] nb [0:32];
    always_ff @(posedge clk) begin
        if (nb_we && nb_idx <= 6'd32) nb[nb_idx] <= nb_val;
    end

    // ---- the request, latched at start ---------------------------------------------------
    typedef enum logic [2:0] {S_IDLE, S_SUM, S_DC, S_PLB0, S_PLB, S_PLA, S_STREAM} state_t;
    state_t     state;
    logic [1:0] k_kind;
    logic [3:0] k_mode;
    logic       av_t, av_l;
    logic [2:0] op;
    logic [3:0] pc;                     // the prep counter
    logic [7:0] pos;                    // the stream position
    logic       gen_done;

    // decode of the request on the input pins (registered into op at start)
    logic [2:0] op_in;
    always_comb begin
        case (kind)
            K_L4:    case (mode)
                         4'd0:    op_in = OP_V;
                         4'd1:    op_in = OP_H;
                         4'd2:    op_in = OP_DC;
                         default: op_in = OP_DIR;
                     endcase
            K_L16:   case (mode[1:0])
                         2'd0:    op_in = OP_V;
                         2'd1:    op_in = OP_H;
                         2'd2:    op_in = OP_DC;
                         default: op_in = OP_PLANE;
                     endcase
            default: case (mode[1:0])
                         2'd0:    op_in = OP_DC;
                         2'd1:    op_in = OP_H;
                         2'd2:    op_in = OP_V;
                         default: op_in = OP_PLANE;
                     endcase
        endcase
    end

    // per-kind geometry
    logic [3:0] x, y;                   // the position in the block
    logic       x_end;                  // last column
    logic [7:0] n_last;                 // last position
    logic [3:0] n_grp;                  // DC: groups of four to sum; Plane: N (8 or 4)
    logic [5:0] i_top_end, i_left_end;  // p[2N-1,-1] and p[-1,2N-1] for the plane's a
    always_comb begin
        case (k_kind)
            K_L4: begin
                x = {2'b00, pos[1:0]}; y = {2'b00, pos[3:2]}; x_end = (pos[1:0] == 2'd3);
                n_last = 8'd15; n_grp = 4'd2; i_top_end = 6'd3; i_left_end = 6'd19;
            end
            K_L16: begin
                x = pos[3:0]; y = pos[7:4]; x_end = (pos[3:0] == 4'd15);
                n_last = 8'd255; n_grp = 4'd8; i_top_end = 6'd15; i_left_end = 6'd31;
            end
            default: begin
                x = {1'b0, pos[2:0]}; y = {1'b0, pos[5:3]}; x_end = (pos[2:0] == 3'd7);
                n_last = 8'd63; n_grp = 4'd4; i_top_end = 6'd7; i_left_end = 6'd23;
            end
        endcase
    end

    // ---- the 4x4 case analysis (8.3.1.2.4 .. 8.3.1.2.9) -> side, m, pattern ---------------
    logic signed [4:0] sx, sy, m, mm1, mm2, mp1, mp2;
    logic signed [4:0] z_vr, z_hd, z_hu;
    logic              side;            // 0 = the row above (T), 1 = the column left (L)
    logic [2:0]        pat;
    always_comb begin
        sx = {3'b000, x[1:0]};
        sy = {3'b000, y[1:0]};
        z_vr = (sx <<< 1) - sy;         // zVR = 2x - y   (8.3.1.2.6)
        z_hd = (sy <<< 1) - sx;         // zHD = 2y - x   (8.3.1.2.7)
        z_hu = sx + (sy <<< 1);         // zHU = x + 2y   (8.3.1.2.9)
        side = 1'b0; m = 5'sd0; pat = P_CPY;
        case (k_mode)
            4'd3: begin                                     // Diagonal_Down_Left (8.3.1.2.4)
                side = 1'b0;
                if (x[1:0] == 2'd3 && y[1:0] == 2'd3) begin m = 5'sd6; pat = P_P11; end
                else begin m = sx + sy; pat = P_P12; end
            end
            4'd4: begin                                     // Diagonal_Down_Right (8.3.1.2.5)
                if (sx > sy)      begin side = 1'b0; m = sx - sy; pat = P_M12; end
                else if (sx < sy) begin side = 1'b1; m = sy - sx; pat = P_M12; end
                else              begin pat = P_CNR; end
            end
            4'd5: begin                                     // Vertical_Right (8.3.1.2.6)
                if (z_vr >= 5'sd0) begin
                    side = 1'b0; m = sx - {4'b0000, y[1]};
                    pat = y[0] ? P_M12 : P_M01;             // zVR odd / even
                end
                else if (z_vr == -5'sd1) pat = P_CNR;
                else begin side = 1'b1; m = sy - 5'sd1; pat = P_M12; end   // (p[-1,y-1], p[-1,y-2], p[-1,y-3])
            end
            4'd6: begin                                     // Horizontal_Down (8.3.1.2.7)
                if (z_hd >= 5'sd0) begin
                    side = 1'b1; m = sy - {4'b0000, x[1]};
                    pat = x[0] ? P_M12 : P_M01;             // zHD odd / even
                end
                else if (z_hd == -5'sd1) pat = P_CNR;
                else begin side = 1'b0; m = sx - 5'sd1; pat = P_M12; end   // (p[x-1,-1], p[x-2,-1], p[x-3,-1])
            end
            4'd7: begin                                     // Vertical_Left (8.3.1.2.8)
                side = 1'b0; m = sx + {4'b0000, y[1]};
                pat = y[0] ? P_P12 : P_P01;
            end
            4'd8: begin                                     // Horizontal_Up (8.3.1.2.9)
                side = 1'b1;
                if (z_hu < 5'sd5)       begin m = sy + {4'b0000, x[1]}; pat = x[0] ? P_P12 : P_P01; end
                else if (z_hu == 5'sd5) begin m = 5'sd2; pat = P_P11; end
                else                    begin m = 5'sd3; pat = P_CPY; end
            end
            default: pat = P_CPY;
        endcase
        mm1 = m - 5'sd1;
        mm2 = m - 5'sd2;
        mp1 = m + 5'sd1;
        mp2 = m + 5'sd2;
    end

    // an offset on the chosen side -> store index; a negative offset is p[-1,-1]
    logic [5:0] i_mm2, i_mm1, i_m, i_mp1, i_mp2;
    always_comb begin
        i_mm2 = mm2[4] ? I_CORNER : {1'b0, side, mm2[3:0]};
        i_mm1 = mm1[4] ? I_CORNER : {1'b0, side, mm1[3:0]};
        i_m   = m[4]   ? I_CORNER : {1'b0, side, m[3:0]};
        i_mp1 = mp1[4] ? I_CORNER : {1'b0, side, mp1[3:0]};
        i_mp2 = mp2[4] ? I_CORNER : {1'b0, side, mp2[3:0]};
    end

    // ---- the tap indices of this cycle --------------------------------------------------
    logic [5:0] i0, i1, i2, i3;
    logic [1:0] f_sel;
    logic [5:0] grp_base;               // DC: the first of this cycle's four samples
    logic [3:0] pl_x;                   // Plane: x' walked from N-1 down to 0 = N-1-pc
    always_comb begin
        // the group's first index: 4x4 groups are p[0..3,-1], p[-1,0..3]; 16x16 the eight
        // runs of four in store order; chroma p[0..3], p[4..7], p[-1,0..3], p[-1,4..7]
        case (k_kind)
            K_L4:    grp_base = pc[0] ? 6'd16 : 6'd0;
            K_L16:   grp_base = {1'b0, pc[2:0], 2'b00};
            default: grp_base = {1'b0, pc[1], 1'b0, pc[0], 2'b00};
        endcase
        pl_x = n_grp - 4'd1 - pc;
        i0 = 6'd0; i1 = 6'd0; i2 = 6'd0; i3 = 6'd0; f_sel = F_COPY;
        case (state)
            S_SUM: begin
                if (op == OP_DC) begin
                    i0 = grp_base; i1 = grp_base + 6'd1; i2 = grp_base + 6'd2; i3 = grp_base + 6'd3;
                end else begin
                    // d_x' = p[N+x',-1] - p[N-2-x',-1]; N-2-x' = pc-1 (p[-1,-1] when x' = N-1)
                    i0 = {2'b00, n_grp + pl_x};
                    i1 = (pc == 4'd0) ? I_CORNER : {2'b00, pc - 4'd1};
                    i2 = {2'b01, n_grp + pl_x};
                    i3 = (pc == 4'd0) ? I_CORNER : {2'b01, pc - 4'd1};
                end
            end
            S_PLB0: begin i0 = i_top_end; i1 = i_left_end; end
            S_STREAM: begin
                case (op)
                    OP_V:   begin i0 = {2'b00, x}; f_sel = F_COPY; end
                    OP_H:   begin i0 = {2'b01, y}; f_sel = F_COPY; end
                    OP_DIR: begin
                        case (pat)
                            P_M12:   begin i0 = i_mm2;  i1 = i_mm1;    i2 = i_m;   f_sel = F_AVG3; end
                            P_M01:   begin i0 = i_mm1;  i1 = i_m;                  f_sel = F_AVG2; end
                            P_P12:   begin i0 = i_m;    i1 = i_mp1;    i2 = i_mp2; f_sel = F_AVG3; end
                            P_P01:   begin i0 = i_m;    i1 = i_mp1;                f_sel = F_AVG2; end
                            P_P11:   begin i0 = i_m;    i1 = i_mp1;    i2 = i_mp1; f_sel = F_AVG3; end
                            P_CNR:   begin i0 = 6'd16;  i1 = I_CORNER; i2 = 6'd0;  f_sel = F_AVG3; end
                            default: begin i0 = i_m;                               f_sel = F_COPY; end
                        endcase
                    end
                    default: f_sel = F_COPY;        // DC / Plane: the value is registered already
                endcase
            end
            default: ;
        endcase
    end

    wire [7:0] t0 = nb[i0];
    wire [7:0] t1 = nb[i1];
    wire [7:0] t2 = nb[i2];
    wire [7:0] t3 = nb[i3];

    // ---- DC: four samples a cycle into per-side and per-group sums ---------------------------
    logic [9:0]  gs_r;                  // the group sum, registered
    logic        gs_valid, gs_top;
    logic [1:0]  gs_slot;
    logic [11:0] acc_t, acc_l;          // 16 samples each at most
    logic [9:0]  gs [0:3];              // 4x4: T, L; chroma: T lo, T hi, L lo, L hi
    // the sums and differences take the samples one cycle after their fetch (tq*: the index,
    // the 33:1 selection and the adds in one cycle missed clk_dec); S_SUM runs to n_grp + 1
    logic [7:0]  tq0, tq1, tq2, tq3;
    logic        tq_v, tq_top;
    logic [1:0]  tq_slot;
    always_ff @(posedge clk) begin tq0 <= t0; tq1 <= t1; tq2 <= t2; tq3 <= t3; end
    wire  [9:0]  gsum = {2'b00, tq0} + {2'b00, tq1} + {2'b00, tq2} + {2'b00, tq3};

    // the means (8.3.1.2.3, 8.3.3.3, 8.3.4.1-3), from the registered sums
    logic [7:0]  dc_l4, dc_l16;
    logic [7:0]  dc_q0, dc_q1, dc_q2, dc_q3;
    wire  [10:0] s4_both  = {1'b0, gs[0]} + {1'b0, gs[1]} + 11'd4;
    wire  [12:0] s16_both = {1'b0, acc_t} + {1'b0, acc_l} + 13'd16;
    wire  [11:0] s16_t    = acc_t + 12'd8;
    wire  [11:0] s16_l    = acc_l + 12'd8;
    wire  [9:0]  s4_t     = gs[0] + 10'd2;
    wire  [9:0]  s4_l     = gs[1] + 10'd2;
    always_comb begin
        // Intra_4x4 DC: p[0..3,-1] in gs[0], p[-1,0..3] in gs[1]
        if (av_t && av_l)   dc_l4 = s4_both[10:3];
        else if (av_l)      dc_l4 = s4_l[9:2];
        else if (av_t)      dc_l4 = s4_t[9:2];
        else                dc_l4 = 8'd128;
        // Intra_16x16 DC
        if (av_t && av_l)   dc_l16 = s16_both[12:5];
        else if (av_l)      dc_l16 = s16_l[11:4];
        else if (av_t)      dc_l16 = s16_t[11:4];
        else                dc_l16 = 8'd128;
    end
    // chroma DC per 4x4 chroma block (xO, yO): the (0,0) and (4,4) blocks use both runs,
    // (4,0) prefers the run above, (0,4) prefers the run left (8.3.4.1-3)
    wire [10:0] cq0_both = {1'b0, gs[0]} + {1'b0, gs[2]} + 11'd4;
    wire [10:0] cq3_both = {1'b0, gs[1]} + {1'b0, gs[3]} + 11'd4;
    wire [9:0]  cq_t0 = (gs[0] + 10'd2) >> 2, cq_t1 = (gs[1] + 10'd2) >> 2;
    wire [9:0]  cq_l0 = (gs[2] + 10'd2) >> 2, cq_l1 = (gs[3] + 10'd2) >> 2;
    always_comb begin
        if (av_t && av_l)   dc_q0 = cq0_both[10:3];
        else if (av_l)      dc_q0 = cq_l0[7:0];
        else if (av_t)      dc_q0 = cq_t0[7:0];
        else                dc_q0 = 8'd128;
        if (av_t)           dc_q1 = cq_t1[7:0];          // xO > 0, yO == 0
        else if (av_l)      dc_q1 = cq_l0[7:0];
        else                dc_q1 = 8'd128;
        if (av_l)           dc_q2 = cq_l1[7:0];          // xO == 0, yO > 0
        else if (av_t)      dc_q2 = cq_t0[7:0];
        else                dc_q2 = 8'd128;
        if (av_t && av_l)   dc_q3 = cq3_both[10:3];
        else if (av_l)      dc_q3 = cq_l1[7:0];
        else if (av_t)      dc_q3 = cq_t1[7:0];
        else                dc_q3 = 8'd128;
    end
    logic [7:0]  dcq [0:3];             // the registered mean(s); [0] for 4x4 and 16x16
    wire  [1:0]  quad = {y[2], x[2]};   // the chroma 4x4 block of position (x, y)

    // ---- Plane: H, V by nested accumulation; a, b, c; the walking accumulator -------------
    logic signed [8:0]  d_t, d_l;       // p[N+x',-1] - p[N-2-x',-1] and the left one
    logic               d_valid;
    logic signed [11:0] s_t, s_l;       // the running suffix sums
    logic signed [14:0] h_acc, v_acc;   // H, V: |.| <= 36 * 255
    logic signed [17:0] hx, vx;         // sign-extended for the shift-adds
    logic signed [17:0] h5, v5;         // 5 H + 32, 34 H + 32 (16x16 / chroma)
    logic signed [17:0] h5_sh, v5_sh;   // ... >> 6 (arithmetic: a part-select would be unsigned)
    logic signed [12:0] b_r, c_r;       // |b| <= 1355
    logic [12:0]        a_r;            // 16 (p[-1,2N-1] + p[2N-1,-1]) <= 8160
    logic signed [17:0] pl_acc, pl_row; // a + b (x - N+1) + c (y - N+1) + 16 for this position / this row's start
    logic signed [17:0] bc, bc_k;       // b + c and its (N-1) multiple: 7 (b+c) or 3 (b+c)
    logic signed [17:0] pl_first;
    logic signed [17:0] pl_sh;
    logic [7:0]         pl_clip;
    always_comb begin
        hx = {{3{h_acc[14]}}, h_acc};
        vx = {{3{v_acc[14]}}, v_acc};
        if (k_kind == K_L16) begin
            h5 = (hx <<< 2) + hx + 18'sd32;                       // b = (5 H + 32) >> 6   (8-72)
            v5 = (vx <<< 2) + vx + 18'sd32;
        end else begin
            h5 = (hx <<< 5) + (hx <<< 1) + 18'sd32;               // b = (34 H + 32) >> 6  (8-124), 4:2:0
            v5 = (vx <<< 5) + (vx <<< 1) + 18'sd32;
        end
        h5_sh = h5 >>> 6;
        v5_sh = v5 >>> 6;
        bc = {{5{b_r[12]}}, b_r} + {{5{c_r[12]}}, c_r};
        if (k_kind == K_L16) bc_k = (bc <<< 3) - bc;             // 7 (b + c)
        else                 bc_k = (bc <<< 1) + bc;             // 3 (b + c)
        pl_first = {5'b00000, a_r} + 18'sd16 - bc_k;
        // Clip1 of the accumulator >> 5
        pl_sh = pl_acc >>> 5;
        if (pl_sh[17])                      pl_clip = 8'd0;
        else if (pl_sh[16:8] != 9'd0)       pl_clip = 8'd255;
        else                                pl_clip = pl_sh[7:0];
    end

    // ---- the stream pipeline --------------------------------------------------------------
    logic [7:0] a_t0, a_t1, a_t2;
    logic [1:0] a_f;
    logic       a_valid, a_last;
    wire        adv = !pred_valid || pred_ready;
    wire  [8:0] sum2 = {1'b0, a_t0} + {1'b0, a_t1} + 9'd1;
    wire  [9:0] sum3 = {2'b00, a_t0} + {1'b0, a_t1, 1'b0} + {2'b00, a_t2} + 10'd2;
    logic [7:0] b_val;
    always_comb begin
        case (a_f)
            F_AVG2:  b_val = sum2[8:1];
            F_AVG3:  b_val = sum3[9:2];
            default: b_val = a_t0;
        endcase
    end
    // stage A's t0 for the registered-value modes
    logic [7:0] a_t0_in;
    always_comb begin
        case (op)
            OP_DC:    a_t0_in = (k_kind == K_CH) ? dcq[quad] : dcq[0];
            OP_PLANE: a_t0_in = pl_clip;
            default:  a_t0_in = t0;
        endcase
    end

    integer gi;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE; busy <= 1'b0;
            k_kind <= 2'd0; k_mode <= 4'd0; av_t <= 1'b0; av_l <= 1'b0; op <= OP_V;
            pc <= 4'd0; pos <= 8'd0; gen_done <= 1'b0;
            gs_r <= 10'd0; gs_valid <= 1'b0; gs_top <= 1'b0; gs_slot <= 2'd0;
            acc_t <= 12'd0; acc_l <= 12'd0;
            for (gi = 0; gi < 4; gi = gi + 1) begin gs[gi] <= 10'd0; dcq[gi] <= 8'd0; end
            d_t <= 9'sd0; d_l <= 9'sd0; d_valid <= 1'b0; tq_v <= 1'b0; tq_top <= 1'b0; tq_slot <= 2'd0;
            s_t <= 12'sd0; s_l <= 12'sd0; h_acc <= 15'sd0; v_acc <= 15'sd0;
            b_r <= 13'sd0; c_r <= 13'sd0; a_r <= 13'd0;
            pl_acc <= 18'sd0; pl_row <= 18'sd0;
            a_t0 <= 8'd0; a_t1 <= 8'd0; a_t2 <= 8'd0; a_f <= F_COPY; a_valid <= 1'b0; a_last <= 1'b0;
            pred_valid <= 1'b0; pred <= 8'd0; pred_last <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (start) begin
                    k_kind <= kind; k_mode <= mode; av_t <= avail_top; av_l <= avail_left; op <= op_in;
                    busy <= 1'b1;
                    pc <= 4'd0; pos <= 8'd0; gen_done <= 1'b0;
                    gs_valid <= 1'b0; d_valid <= 1'b0; tq_v <= 1'b0;
                    acc_t <= 12'd0; acc_l <= 12'd0;
                    s_t <= 12'sd0; s_l <= 12'sd0; h_acc <= 15'sd0; v_acc <= 15'sd0;
                    a_valid <= 1'b0; pred_valid <= 1'b0;
                    if (op_in == OP_DC || op_in == OP_PLANE) state <= S_SUM;
                    else                                     state <= S_STREAM;
                end

                S_SUM: begin
                    // fetch (this cycle) then accumulate (the next): pc walks 0..n_grp, the
                    // cycle pc == n_grp only retires the last fetch
                    tq_v <= (pc < n_grp); tq_top <= !grp_base[4]; tq_slot <= pc[1:0];
                    gs_valid <= tq_v;
                    gs_r <= gsum; gs_top <= tq_top; gs_slot <= tq_slot;
                    if (gs_valid) begin
                        if (gs_top) acc_t <= acc_t + {2'b00, gs_r};
                        else        acc_l <= acc_l + {2'b00, gs_r};
                        gs[gs_slot] <= gs_r;        // 4x4: T, L; chroma: T lo, T hi, L lo, L hi
                    end
                    d_valid <= tq_v;
                    d_t <= {1'b0, tq0} - {1'b0, tq1};
                    d_l <= {1'b0, tq2} - {1'b0, tq3};
                    if (d_valid) begin
                        s_t <= s_t + {{3{d_t[8]}}, d_t};
                        s_l <= s_l + {{3{d_l[8]}}, d_l};
                        h_acc <= h_acc + {{3{s_t[11]}}, s_t} + {{6{d_t[8]}}, d_t};
                        v_acc <= v_acc + {{3{s_l[11]}}, s_l} + {{6{d_l[8]}}, d_l};
                    end
                    pc <= pc + 4'd1;
                    if (pc == n_grp + 4'd1) begin
                        if (op == OP_DC) state <= S_DC;
                        else             state <= S_PLB0;
                    end
                end

                S_DC: begin
                    dcq[0] <= (k_kind == K_L4) ? dc_l4 : (k_kind == K_L16) ? dc_l16 : dc_q0;
                    dcq[1] <= dc_q1; dcq[2] <= dc_q2; dcq[3] <= dc_q3;
                    state <= S_STREAM;
                end

                S_PLB0: state <= S_PLB;             // the two corner samples fetched
                S_PLB: begin
                    a_r <= {{1'b0, tq0} + {1'b0, tq1}, 4'b0000};                // a = 16 (p[-1,2N-1] + p[2N-1,-1])
                    b_r <= h5_sh[12:0];                                        // (5 H + 32) >> 6, arithmetic
                    c_r <= v5_sh[12:0];
                    state <= S_PLA;
                end

                S_PLA: begin
                    pl_acc <= pl_first;
                    pl_row <= pl_first;
                    state <= S_STREAM;
                end

                S_STREAM: if (adv) begin
                    // stage B
                    pred_valid <= a_valid;
                    pred <= b_val;
                    pred_last <= a_last;
                    // stage A
                    if (!gen_done) begin
                        a_t0 <= a_t0_in; a_t1 <= t1; a_t2 <= t2; a_f <= f_sel;
                        a_valid <= 1'b1; a_last <= (pos == n_last);
                        pos <= pos + 8'd1;
                        if (pos == n_last) gen_done <= 1'b1;
                        if (x_end) begin pl_acc <= pl_row + {{5{c_r[12]}}, c_r}; pl_row <= pl_row + {{5{c_r[12]}}, c_r}; end
                        else       pl_acc <= pl_acc + {{5{b_r[12]}}, b_r};
                    end else a_valid <= 1'b0;
                    // the last sample taken: done
                    if (pred_valid && pred_ready && pred_last) begin
                        busy <= 1'b0;
                        state <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
