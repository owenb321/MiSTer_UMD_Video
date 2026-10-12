// umd/h264/recon_inter.sv -- the inter prediction samples of one macroblock (8.4.2):
// reference windows from the DPB in DDR3, mc_interp, wpred, into the macroblock's
// sample RAM (docs/h264_recon.md S2.3)
//
// The motion of the sixteen 4x4 blocks (mv_pred's result) is grouped by uniformity:
// the whole macroblock when all sixteen agree, else per 8x8 quadrant when its four
// agree, else per 4x4 block -- grouping changes the work, never the samples (every
// sample is interpolated from its own position with its block's vector). Per group and
// per plane (Y, Cb, Cr):
//   for each list the group predicts from:
//     FETCH  the reference window (luma (w+5)x(h+5) from (xInt-2, yInt-2), chroma
//            (w/2+1)x(h/2+1) from (xInt, yInt)), every coordinate clamped into the
//            reference picture (8-228 / 8-229 / 8-230 / 8-231): per window row one
//            burst over the 64-bit words its clamped columns span (<= 4), then four
//            bytes a cycle into the window RAM, the clamped column picking its byte; up
//            to sixteen rows in flight (the memory client pipelines them);
//     MC     mc_interp over the window: list 0 of a bi-predicted group into pbuf0, the
//            last list streaming through
//   WEIGHT wpred (default, explicit, implicit: 8.4.2.3 / 8.4.3) into the sample RAM.
// FETCH and MC / WEIGHT are two machines over a double-buffered window: item n + 1 is
// fetched while item n is interpolated (the fetch / interpolation overlap).
// A reference field is every other line of its frame store (a field picture's lines,
// 7.4.1.2.4); the chroma vector of a field picture referencing the opposite parity is
// offset by +-2 (Table 8-10). Implicit weights: dsf_calc per bi-predicted group.
//
// Addressing (docs/h264_recon.md S2.2): store s at word BASE + s << 17; luma plane rows
// of 2W words, Cb at 32*W*HF, Cr at 40*W*HF words (rows of W words); a picture row r of
// a field is store row 2r + parity.

`default_nettype none

module recon_inter (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         start,
    output logic        busy,
    output logic        done,
    output logic        err,               // a list entry with no picture was named

    // the macroblock and the picture
    input  wire  [6:0]  mb_x,
    input  wire  [6:0]  mb_y,              // in the current picture's macroblock rows
    input  wire  [7:0]  width_mbs,
    input  wire  [7:0]  frame_height_mbs,  // FrameHeightInMbs
    input  wire         field_pic,
    input  wire         bottom,            // the current field's parity
    input  wire  [28:0] dpb_base,          // word address of store 0
    input  wire  [20:0] plane_mbs,         // W * FrameHeightInMbs (<= 1620)

    // the motion of the 16 blocks: recon_mb's motion RAM, one block per read (registered:
    // the record of mot_ra's block the cycle after). Record: {mvy1, mvx1, code1, ref1, pred1,
    // mvy0, mvx0, code0, ref0, pred0}, the codes {valid, store, parity} of the list entries
    // (0 for a list the block does not use) -- LM_INFO's block layout above {nz, mode}
    output logic [3:0]  mot_ra,
    input  wire  [91:0] mot_q,
    // uniformity, computed by the caller as the blocks arrive: all sixteen alike, each 8x8
    input  wire         all16,
    input  wire  [3:0]  all8,

    // slice: the references and the weights
    input  wire  [1:0]  slice_type,        // 0 P, 1 B
    input  wire         weighted_pred,
    input  wire  [1:0]  weighted_bipred_idc,
    input  wire  [2:0]  luma_log2_wd,
    input  wire  [2:0]  chroma_log2_wd,
    output logic [4:0]  poc_ra0,           // recon_slice_tab's POC RAMs: the group's references,
    output logic [4:0]  poc_ra1,           // the weighted item's; stable from its bank's take, read in K_WT_RD2
    input  wire  [31:0] poc_q0,
    input  wire  [31:0] poc_q1,
    input  wire  [31:0] lng0,
    input  wire  [31:0] lng1,
    input  wire signed [31:0] cur_poc,
    output logic [5:0]  wt_addr,           // recon_hdr's weight table
    input  wire  [47:0] wt_data,

    // DDR3 reads (dpb_mem, owned while busy)
    output logic        cmd_valid,
    input  wire         cmd_ready,
    output logic [28:0] cmd_addr,
    output logic [3:0]  cmd_len,
    input  wire         rd_valid,
    input  wire  [63:0] rd_data,
    output logic        rd_ready,

    // the macroblock's sample RAM: luma 0..255 (y*16+x), Cb 256..319, Cr 320..383
    output logic        out_we,
    output logic [8:0]  out_addr,
    output logic [7:0]  out_data
);

    // ---- the FSM -----------------------------------------------------------------------------
    // Two machines over a double-buffered window RAM (the fetch / interpolation overlap,
    // docs/h264_recon.md S6): the FETCH side (st) walks the (group, plane, list) items --
    // geometry, the reference rows, the copy into window bank fb -- marks the bank full with
    // the item's descriptor and goes straight on to the next item, waiting only for a full
    // bank; the INTERPOLATION side (k) takes the banks in order: list 0 of a bi-predicted
    // group into pbuf0, else the weights and the interpolation streaming through wpred into
    // the sample RAM, then frees the bank. The interpolation side stays serial, so pbuf0
    // (written by list 0, read by list 1 of the same group) has one user at a time.
    typedef enum logic [4:0] {
        I_IDLE, I_GROUP, I_PLANE, I_LIST, I_LIST2, I_LIST3, I_LIST4, I_FETCH, I_NEXT_PLANE, I_NEXT_GROUP, I_DRAIN, I_DONE
    } istate_t;
    istate_t st;
    typedef enum logic [3:0] {
        K_IDLE, K_MC, K_MC_WAIT, K_WT_RD, K_WT_RD1, K_WT_RD2, K_IMPL, K_IMPL2, K_IMPL_WAIT, K_WEIGHT, K_WEIGHT_WAIT
    } kstate_t;
    kstate_t k;
    logic [1:0]  bank_full;                // a window bank holds a fetched item
    logic        fb, kb;                   // the bank the fetch fills / the interpolation sweeps
    // the item descriptor, per bank
    logic [1:0]  d_plane [0:1];
    logic [2:0]  d_fx [0:1];
    logic [2:0]  d_fy [0:1];
    logic [4:0]  d_bw [0:1];
    logic [4:0]  d_bh [0:1];
    logic [4:0]  d_gx [0:1];
    logic [4:0]  d_gy [0:1];
    logic [4:0]  d_gref0 [0:1];
    logic [4:0]  d_gref1 [0:1];
    logic        d_bi [0:1];
    logic        d_lx [0:1];
    logic        d_gp0 [0:1];
    wire  [1:0]  kd_plane = d_plane[kb];
    wire         kd_c = (kd_plane != 2'd0);
    wire  [2:0]  kd_fx = d_fx[kb];
    wire  [2:0]  kd_fy = d_fy[kb];
    wire  [4:0]  kd_bw = d_bw[kb];
    wire  [4:0]  kd_bh = d_bh[kb];
    wire  [4:0]  kd_gx = d_gx[kb];
    wire  [4:0]  kd_gy = d_gy[kb];
    wire  [4:0]  kd_gref0 = d_gref0[kb];
    wire  [4:0]  kd_gref1 = d_gref1[kb];
    wire         kd_bi = d_bi[kb];
    wire         kd_lx = d_lx[kb];
    wire         kd_gp0 = d_gp0[kb];

    // fetch bookkeeping
    logic [4:0]  req_row;                  // next row to request
    logic [4:0]  rx_row;                   // row whose words are being received
    logic [2:0]  rx_word;                  // word within the row
    // SIXTEEN row buffers: sixteen reference rows in flight (the fetch is DDR3-latency
    // bound: two in flight left it waiting on each round trip; four -> eight -> sixteen
    // took The Office Disc 01's window from 2,237 to 1,974 to 1,907 cycles a macroblock,
    // docs/h264_recon.md S6). Sixteen rows of <= 4 words fill dpb_mem's 64-beat read
    // buffer exactly; a luma window has at most 21 rows.
    // (the row buffers are eight byte-lane LUT-RAMs, below the copy: 1,024 registers and a
    // word / byte selection per copied byte as a register file)
    logic [15:0] rb_full;                  // a row buffer holds a complete row
    logic [4:0]  cp_row;                   // row being copied
    logic [4:0]  cp_col;
    logic        copying;
    logic [8:0]  cp_base;                  // window RAM address of row cp_row

    logic [8:0]  w_first_q;                // the (per-window constant) first word
    logic [3:0]  row_len_q;
    logic [11:0] xs_q;                     // unclamped window start column (as 16-bit signed)
    logic signed [15:0] xi_q;
    logic [11:0] pw_q;
    logic [4:0]  ww_q, wh_q;
    assign rd_ready = (st == I_FETCH) && !rb_full[rx_row[3:0]] && (rx_row < wh_q);


    // ---- the group being predicted --------------------------------------------------------
    logic [3:0]  g_blk;                    // its first 4x4 block (luma4x4BlkIdx)
    logic [4:0]  g_x, g_y, g_w, g_h;       // luma rectangle in the macroblock
    logic [1:0]  g_q;                      // quadrant being walked
    logic [2:0]  g_sub;                    // block inside the quadrant (4 = quadrant done)
    logic [1:0]  plane;                    // 0 Y, 1 Cb, 2 Cr
    logic        lx;                       // the list being fetched
    logic        g_bi;
    // block (x, y) of luma4x4BlkIdx b (6.4.3): x = {b[2], b[0]} * 4, y = {b[3], b[1]} * 4

    // the group's first block: its record is read the cycle g_blk is set (I_GROUP addresses
    // the RAM with the value it registers) and holds while the group is predicted
    logic [3:0]  g_blk_n;
    always_comb begin
        if (all16) g_blk_n = 4'd0;
        else if (all8[g_q]) g_blk_n = {g_q, 2'b00};
        else g_blk_n = {g_q, g_sub[1:0]};
    end
    assign mot_ra = (st == I_GROUP) ? g_blk_n : g_blk;
    // the group's motion for list lx
    wire        gp0 = mot_q[0], gp1 = mot_q[46];
    wire [4:0]  gref0 = mot_q[5:1], gref1 = mot_q[51:47];
    wire signed [15:0] gmvx = lx ? mot_q[75:60] : mot_q[29:14];
    wire signed [15:0] gmvy = lx ? mot_q[91:76] : mot_q[45:30];
    wire [7:0]  gcode = lx ? mot_q[59:52] : mot_q[13:6];   // {valid, store[4:0], parity[1:0]}

    assign poc_ra0 = kd_gref0;             // the item being weighted (read from K_WT_RD2 on,
    assign poc_ra1 = kd_gref1;             // >= 2 cycles after its bank is taken)

    // ---- window geometry ------------------------------------------------------------------
    wire        is_c = (plane != 2'd0);
    // the chroma vector's vertical component (Table 8-10)
    logic signed [15:0] cmvy;
    always_comb begin
        cmvy = gmvy;
        if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;     // ref top, current bottom
        if (field_pic && gcode[1:0] == 2'd2 && !bottom) cmvy = gmvy - 16'sd2;     // ref bottom, current top
    end
    // integer sample position and fraction
    logic signed [15:0] xi, yi;
    logic [2:0]  fx, fy;
    logic [4:0]  ww, wh;                   // window size
    logic [4:0]  bw, bh;                   // prediction block size in this plane
    logic [11:0] pw, ph;                   // reference plane size
    always_comb begin
        if (!is_c) begin
            xi = $signed({2'b0, mb_x, 4'b0}) + $signed({11'b0, g_x}) + (gmvx >>> 2) - 16'sd2;
            yi = $signed({2'b0, mb_y, 4'b0}) + $signed({11'b0, g_y}) + (gmvy >>> 2) - 16'sd2;
            fx = {1'b0, gmvx[1:0]}; fy = {1'b0, gmvy[1:0]};
            bw = g_w; bh = g_h;
            ww = g_w + 5'd5; wh = g_h + 5'd5;
            pw = {width_mbs, 4'b0};
            ph = (gcode[1:0] == 2'd0) ? {frame_height_mbs, 4'b0} : {1'b0, frame_height_mbs, 3'b0};
        end else begin
            xi = $signed({3'b0, mb_x, 3'b0}) + $signed({12'b0, g_x[4:1]}) + (gmvx >>> 3);
            yi = $signed({3'b0, mb_y, 3'b0}) + $signed({12'b0, g_y[4:1]}) + (cmvy >>> 3);
            fx = gmvx[2:0]; fy = cmvy[2:0];
            bw = {1'b0, g_w[4:1]}; bh = {1'b0, g_h[4:1]};
            ww = {1'b0, g_w[4:1]} + 5'd1; wh = {1'b0, g_h[4:1]} + 5'd1;
            pw = {1'b0, width_mbs, 3'b0};
            ph = (gcode[1:0] == 2'd0) ? {1'b0, frame_height_mbs, 3'b0} : {2'b0, frame_height_mbs, 2'b0};
        end
    end
    // the clamped column span of the window, in 64-bit words
    // (from the registered xi_q / ww_q / pw_q: computed in I_LIST2)
    wire signed [15:0] x_last = xi_q + $signed({11'b0, ww_q}) - 16'sd1;
    wire [11:0] xs_c = (xi_q < 0) ? 12'd0 : (xi_q >= $signed({4'b0, pw_q})) ? pw_q - 12'd1 : xi_q[11:0];
    wire [11:0] xe_c = (x_last < 0) ? 12'd0 : (x_last >= $signed({4'b0, pw_q})) ? pw_q - 12'd1 : x_last[11:0];
    wire [8:0]  w_first = xs_c[11:3];
    wire [8:0]  w_lastw = xe_c[11:3];
    wire [3:0]  row_len = w_lastw - w_first + 1'b1;        // 1..4 words

    // the store rows of the window: row r is picture row clamp(yi + r) (T: 2r, B: 2r + 1 in
    // the frame store), word address base + srow * stride. Built over I_LIST .. I_LIST4 from
    // registered geometry (the motion RAM's output -> clamp -> multiply -> adds was one
    // 17.8 ns cycle); each request then steps by the row stride while the clamped row still
    // advances (addr_cur, y_cur)
    logic signed [15:0] yi_q, y_cur;
    logic [11:0] ph_q;
    logic [7:0]  gcode_q;
    logic [28:0] base_q, addr_cur;
    logic [12:0] srow0_q;
    logic [8:0]  stride_q;
    logic [9:0]  rstep_q;
    wire  [11:0] y0_c = (yi_q < 0) ? 12'd0 : (yi_q >= $signed({4'b0, ph_q})) ? ph_q - 12'd1 : yi_q[11:0];
    wire  [28:0] plane_off = (plane == 2'd0) ? 29'd0 :
                             (plane == 2'd1) ? {3'd0, plane_mbs, 5'd0} : ({3'd0, plane_mbs, 5'd0} + {5'd0, plane_mbs, 3'd0});
    wire  [8:0]  stride = is_c ? {1'b0, width_mbs} : {width_mbs, 1'b0};
    wire         y_adv = (y_cur >= 0) && (y_cur < $signed({4'b0, ph_q}) - 16'sd1);

    // ---- the window RAM and mc_interp ---------------------------------------------------------
    // Four byte-wide lanes (address mod 4): the copy writes four consecutive window bytes a
    // cycle (one byte a cycle was half the macroblock's inter time, docs/h264_recon.md S6),
    // mc_interp still reads one byte a cycle with the same one-cycle latency. Each lane holds
    // two windows (the fetch writes bank fb, mc_interp reads bank kb).
    logic [7:0]  win0 [0:255];
    logic [7:0]  win1 [0:255];
    logic [7:0]  win2 [0:255];
    logic [7:0]  win3 [0:255];
    logic [3:0]  wb_we;                    // per bank
    logic [7:0]  wb_addr [0:3];               // {bank, word}
    logic [7:0]  wb_data [0:3];
    logic [8:0]  win_raddr;
    logic [7:0]  win_rdata;
    logic [7:0]  wq [0:3];
    logic [1:0]  wq_sel;
    always_ff @(posedge clk) begin
        if (wb_we[0]) win0[wb_addr[0]] <= wb_data[0];
        if (wb_we[1]) win1[wb_addr[1]] <= wb_data[1];
        if (wb_we[2]) win2[wb_addr[2]] <= wb_data[2];
        if (wb_we[3]) win3[wb_addr[3]] <= wb_data[3];
        wq[0] <= win0[{kb, win_raddr[8:2]}];
        wq[1] <= win1[{kb, win_raddr[8:2]}];
        wq[2] <= win2[{kb, win_raddr[8:2]}];
        wq[3] <= win3[{kb, win_raddr[8:2]}];
        wq_sel <= win_raddr[1:0];
    end
    assign win_rdata = wq[wq_sel];

    logic        mc_start, mc_busy, mc_valid, mc_last, mc_ready;
    logic [7:0]  mc_pred;
    mc_interp u_mc (
        .clk(clk), .rst_n(rst_n), .start(mc_start), .is_chroma(kd_c), .frac_x(kd_fx), .frac_y(kd_fy),
        .w(kd_bw), .h(kd_bh), .win_addr(win_raddr), .win_data(win_rdata),
        .pred_valid(mc_valid), .pred(mc_pred), .pred_last(mc_last), .pred_ready(mc_ready), .busy(mc_busy));

    // the two lists' prediction buffers (w*h samples, raster)
    logic [7:0]  pbuf0 [0:255];

    logic [7:0]  pb_widx;
    logic [7:0]  pb_ridx;
    logic [7:0]  pb_q0, pb_q1;
    // list 0's prediction of a bi-predicted group (K_MC_WAIT); the LAST list's interpolation
    // streams straight into wpred (K_WEIGHT_WAIT: the weighting folded into it, no second
    // pass over a buffer), list 0's buffered samples joining through a prefetch FIFO
    wire         pb_we = (k == K_MC_WAIT) && mc_valid;          // mc_ready is 1 there
    always_ff @(posedge clk) begin
        if (pb_we) pbuf0[pb_widx] <= mc_pred;
        pb_q0 <= pbuf0[pb_ridx];
    end
    // the prefetch: pbuf0 read in order (pb_ridx registered, pb_q0 the edge after), up to
    // four samples held or in flight ahead of wpred's take
    logic [7:0]  pf [0:3];
    logic [1:0]  pf_h, pf_t;
    logic [2:0]  pf_n;
    logic        pf_i1, pf_i2;
    logic [8:0]  pf_rd;
    wire         wt_st = (k == K_WEIGHT_WAIT);

    // ---- weighting ----------------------------------------------------------------------------
    logic        wp_start, wp_busy, wp_a_valid, wp_a_ready, wp_b_valid, wp_b_ready, wp_valid, wp_last;
    logic [7:0]  wp_a, wp_b, wp_out;
    logic [1:0]  wp_mode;
    logic [2:0]  wp_logwd;
    logic signed [8:0] wp_w0, wp_w1;
    logic signed [7:0] wp_o0, wp_o1;
    logic [8:0]  wp_n;
    wpred u_wp (
        .clk(clk), .rst_n(rst_n), .start(wp_start), .bi(kd_bi), .mode(wp_mode), .logwd(wp_logwd),
        .w0(wp_w0), .w1(wp_w1), .o0(wp_o0), .o1(wp_o1), .n(wp_n),
        .a_valid(wp_a_valid), .a(wp_a), .a_ready(wp_a_ready), .b_valid(wp_b_valid), .b(wp_b), .b_ready(wp_b_ready),
        .out_valid(wp_valid), .out(wp_out), .out_last(wp_last), .out_ready(1'b1), .busy(wp_busy));

    // implicit weights (8.4.3): DistScaleFactor from the two references' POCs
    logic        ds_start, ds_done, ds_zero;
    logic signed [10:0] ds_dsf;
    logic signed [31:0] ds_b, ds_d;
    dsf_calc u_ds (.clk(clk), .rst_n(rst_n), .start(ds_start), .diff_b(ds_b), .diff_d(ds_d),
                   .done(ds_done), .dsf(ds_dsf), .td_zero(ds_zero));
    logic signed [8:0] imp_w0, imp_w1;


    // the copy, two stages: (1) window columns cp_col .. cp_col + 3 of the row being copied,
    // clamped to the picture (8.4.2.2's Clip3), with where they land (a = cp_base + cp_col,
    // bank (a + k) mod 4); (2) their bytes from the row buffer into the window banks. The
    // row buffer stage 2 reads is refilled no earlier than the edge that ends stage 2.
    logic [11:0] cp_xc [0:3];
    logic [8:0]  cp_a;
    logic [4:0]  cp_n;                     // bytes this cycle (1..4)
    always_comb begin
        for (int k = 0; k < 4; k++) begin
            logic signed [15:0] xu;
            xu = xi_q + $signed({11'b0, cp_col}) + k;
            cp_xc[k] = (xu < 0) ? 12'd0 : (xu >= $signed({4'b0, pw_q})) ? pw_q - 12'd1 : xu[11:0];
        end
        cp_a = cp_base + {4'd0, cp_col};
        cp_n = (ww_q - cp_col > 5'd4) ? 5'd4 : ww_q - cp_col;
    end
    // stage 0 (the clk_dec wall, ported from the H264 fork): the step's columns registered
    // before the lane addresses are formed
    // (cp_col -> clamp -> lane match -> the lane RAMs' address registers was 11.6 ns)
    logic        x0_v;
    logic [4:0]  x0_row;
    logic        x0_fb;
    logic [11:0] x0_xc [0:3];
    logic [8:0]  x0_a;
    logic [4:0]  x0_n;
    logic        x0_clr;                   // x0_row's last step: its buffer is freed a stage late
    logic        c1_v;
    logic [3:0]  c1_rb;
    logic        c1_fb;                    // the bank stage 1 copied for
    logic [11:0] c1_xc [0:3];
    logic [8:0]  c1_a;
    logic [4:0]  c1_n;
    logic [7:0]  cp_byte [0:3];
    // the row buffers as byte lanes: lane L holds byte L of every word (64 words: 16 rows x 4).
    // The four columns a copy step takes sit in four different lanes (consecutive samples,
    // or one sample repeated where clamped -- the same lane and address), so each lane is
    // read once, addressed in stage 1 and landing for stage 2 (a received word writes all
    // eight lanes; its buffer is refilled no earlier than the edge after that read)
    logic [5:0]  ln_addr [0:7];
    logic [7:0]  lane_q [0:7];
    always_comb begin
        for (int l = 0; l < 8; l++) begin
            ln_addr[l] = {x0_row[3:0], 2'd0};
            for (int k = 0; k < 4; k++) begin
                logic [8:0] xw;
                xw = x0_xc[k][11:3] - w_first_q;
                if (x0_xc[k][2:0] == l[2:0]) ln_addr[l] = {x0_row[3:0], xw[1:0]};
            end
        end
    end
    wire         rx_we = (st == I_FETCH) && rd_valid && rd_ready;
    genvar gl;
    generate for (gl = 0; gl < 8; gl++) begin : RL
        logic [7:0] m [0:63];
        always_ff @(posedge clk) begin
            if (rx_we) m[{rx_row[3:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];
            lane_q[gl] <= m[ln_addr[gl]];
        end
    end endgenerate
    always_comb for (int k = 0; k < 4; k++) cp_byte[k] = lane_q[c1_xc[k][2:0]];

    // weighting read-out: the wpred streams come from the prediction buffers
    logic [8:0]  wr_idx;                   // next sample to read from the buffers
    logic [4:0]  wo_x, wo_y;               // next sample written out (in the block)
    logic        pb_iss;                   // a buffer address was issued last cycle
    logic        pb_q_valid;               // pb_q0 / pb_q1 hold a sample this cycle
    logic [4:0]  bw_q;
    // the streams into wpred: combinational from the buffer outputs
    assign wp_a_valid = wt_st && (kd_bi ? (pf_n != 3'd0) : mc_valid);
    assign wp_b_valid = wt_st && kd_bi && mc_valid;
    assign wp_a = kd_bi ? pf[pf_h] : mc_pred;
    assign wp_b = mc_pred;
    assign mc_ready = !wt_st ? 1'b1 : (kd_bi ? wp_b_ready : wp_a_ready);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= I_IDLE; busy <= 1'b0; done <= 1'b0; err <= 1'b0;
            g_blk <= '0; g_x <= '0; g_y <= '0; g_w <= '0; g_h <= '0; g_q <= '0; g_sub <= '0;
            plane <= '0; lx <= 1'b0; g_bi <= 1'b0;
            k <= K_IDLE; bank_full <= '0; fb <= 1'b0; kb <= 1'b0; c1_fb <= 1'b0;
            for (int b = 0; b < 2; b++) begin
                d_plane[b] <= '0; d_fx[b] <= '0; d_fy[b] <= '0; d_bw[b] <= '0; d_bh[b] <= '0; d_gx[b] <= '0; d_gy[b] <= '0;
                d_gref0[b] <= '0; d_gref1[b] <= '0; d_bi[b] <= 1'b0; d_lx[b] <= 1'b0; d_gp0[b] <= 1'b0;
            end
            cmd_valid <= 1'b0; cmd_addr <= '0; cmd_len <= 4'd1; cp_base <= '0;
            out_we <= 1'b0; out_addr <= '0; out_data <= '0;
            wb_we <= '0; for (int b = 0; b < 4; b++) begin wb_addr[b] <= '0; wb_data[b] <= '0; end
            mc_start <= 1'b0; pb_widx <= '0; pb_ridx <= '0;
            wp_start <= 1'b0; wp_mode <= '0; wp_logwd <= '0; wp_w0 <= '0; wp_w1 <= '0; wp_o0 <= '0; wp_o1 <= '0; wp_n <= '0;
            wt_addr <= '0;
            ds_start <= 1'b0; ds_b <= '0; ds_d <= '0; imp_w0 <= 9'sd32; imp_w1 <= 9'sd32;
            req_row <= '0; rx_row <= '0; rx_word <= '0; rb_full <= '0; cp_row <= '0; cp_col <= '0; copying <= 1'b0;
            w_first_q <= '0; row_len_q <= 4'd1; xs_q <= '0; xi_q <= '0; pw_q <= '0; ww_q <= '0; wh_q <= '0;
            yi_q <= '0; y_cur <= '0; ph_q <= '0; gcode_q <= '0; base_q <= '0; addr_cur <= '0; srow0_q <= '0;
            stride_q <= '0; rstep_q <= '0; c1_v <= 1'b0; c1_rb <= 4'd0; c1_a <= '0; c1_n <= '0;
            for (int k = 0; k < 4; k++) c1_xc[k] <= '0;
            x0_v <= 1'b0; x0_row <= '0; x0_fb <= 1'b0; x0_a <= '0; x0_n <= '0; x0_clr <= 1'b0;
            for (int k = 0; k < 4; k++) x0_xc[k] <= '0;
            wr_idx <= '0; wo_x <= '0; wo_y <= '0; pb_q_valid <= 1'b0; pb_iss <= 1'b0; bw_q <= '0;
            pf_h <= '0; pf_t <= '0; pf_n <= '0; pf_i1 <= 1'b0; pf_i2 <= 1'b0; pf_rd <= '0;
        end else begin
            done <= 1'b0; err <= 1'b0; mc_start <= 1'b0; wp_start <= 1'b0; ds_start <= 1'b0;
            out_we <= 1'b0; wb_we <= '0; c1_v <= 1'b0; x0_v <= 1'b0; x0_clr <= 1'b0;
            // the copy's stage 1: the lane RAMs are read at x0's addresses (above); the step
            // moves on to stage 2 with them, and a row's last step frees its buffer now
            if (x0_v) begin
                c1_v <= 1'b1; c1_rb <= x0_row[3:0]; c1_fb <= x0_fb; c1_a <= x0_a; c1_n <= x0_n;
                for (int k = 0; k < 4; k++) c1_xc[k] <= x0_xc[k];
                if (x0_clr) rb_full[x0_row[3:0]] <= 1'b0;
            end
            // the copy's stage 2
            if (c1_v) begin
                for (int b = 0; b < 4; b++) begin
                    logic [1:0] kb;
                    logic [8:0] ab;
                    kb = b[1:0] - c1_a[1:0];
                    ab = c1_a + {7'd0, kb};
                    wb_we[b] <= ({3'd0, kb} < c1_n);
                    wb_addr[b] <= {c1_fb, ab[8:2]};
                    wb_data[b] <= cp_byte[kb];
                end
            end
            case (st)
                I_IDLE: if (start) begin
                    busy <= 1'b1;
                    g_q <= 2'd0; g_sub <= 3'd0;
                    st <= I_GROUP;
                end
                // ---- the next group: whole MB, a quadrant, or a 4x4 block ------------------
                I_GROUP: begin
                    g_blk <= g_blk_n;
                    if (all16) begin
                        g_x <= 5'd0; g_y <= 5'd0; g_w <= 5'd16; g_h <= 5'd16;
                        g_q <= 2'd3; g_sub <= 3'd4;          // the last group
                    end else if (all8[g_q]) begin
                        g_x <= {1'b0, g_q[0], 3'b0}; g_y <= {1'b0, g_q[1], 3'b0};
                        g_w <= 5'd8; g_h <= 5'd8; g_sub <= 3'd4;
                    end else begin
                        g_x <= {1'b0, g_q[0], g_sub[0], 2'b00}; g_y <= {1'b0, g_q[1], g_sub[1], 2'b00};
                        g_w <= 5'd4; g_h <= 5'd4; g_sub <= g_sub + 3'd1;
                    end
                    plane <= 2'd0;
                    st <= I_PLANE;
                end
                I_PLANE: begin
                    g_bi <= gp0 && gp1;
                    lx <= gp0 ? 1'b0 : 1'b1;
                    st <= I_LIST;
                end
                // ---- fetch one list's window ------------------------------------------------
                I_LIST: if (!bank_full[fb]) begin      // the bank the fetch fills is free
                    if (!gcode[7]) err <= 1'b1;
                    xi_q <= xi; pw_q <= pw;
                    ww_q <= ww; wh_q <= wh;
                    yi_q <= yi; ph_q <= ph; gcode_q <= gcode;
                    req_row <= '0; rx_row <= '0; rx_word <= '0; rb_full <= '0; cp_row <= '0; cp_col <= '0; copying <= 1'b0;
                    cp_base <= '0;
                    st <= I_LIST2;
                end
                I_LIST2: begin
                    w_first_q <= w_first; row_len_q <= row_len;
                    base_q <= dpb_base + {7'd0, gcode_q[6:2], 17'd0} + plane_off;
                    srow0_q <= (gcode_q[1:0] == 2'd0) ? {1'b0, y0_c} : {y0_c, gcode_q[1]};
                    stride_q <= stride;
                    rstep_q <= (gcode_q[1:0] == 2'd0) ? {1'b0, stride} : {stride, 1'b0};
                    st <= I_LIST3;
                end
                I_LIST3: begin
                    base_q <= base_q + {20'd0, w_first_q};
                    st <= I_LIST4;
                end
                I_LIST4: begin
                    addr_cur <= base_q + srow0_q * stride_q;
                    y_cur <= yi_q;
                    st <= I_FETCH;
                end
                I_FETCH: begin
                    // requests: one row per accepted command, a row buffer's worth ahead at most
                    if (cmd_valid && cmd_ready) cmd_valid <= 1'b0;
                    if ((!cmd_valid || cmd_ready) && req_row < wh_q && (req_row - cp_row) < 5'd16) begin
                        cmd_valid <= 1'b1; cmd_addr <= addr_cur; cmd_len <= row_len_q;
                        req_row <= req_row + 1'b1;
                        addr_cur <= addr_cur + (y_adv ? {19'd0, rstep_q} : 29'd0);
                        y_cur <= y_cur + 16'sd1;
                    end
                    // receive: into the row buffer of rx_row when it is free (rd_ready below)
                    if (rd_valid && rd_ready) begin
                        if (rx_word == row_len_q[2:0] - 3'd1) begin
                            rb_full[rx_row[3:0]] <= 1'b1; rx_word <= '0; rx_row <= rx_row + 1'b1;
                        end else rx_word <= rx_word + 1'b1;
                    end
                    // copy: four bytes a cycle from the full row buffer of cp_row
                    if (cp_row < wh_q && rb_full[cp_row[3:0]]) begin
                        x0_v <= 1'b1; x0_row <= cp_row; x0_fb <= fb; x0_a <= cp_a; x0_n <= cp_n;
                        for (int k = 0; k < 4; k++) x0_xc[k] <= cp_xc[k];
                        if (cp_n != 5'd4 || cp_col + 5'd4 == ww_q) begin
                            cp_col <= '0; cp_row <= cp_row + 1'b1; cp_base <= cp_base + {4'd0, ww_q};
                            x0_clr <= 1'b1;
                        end else cp_col <= cp_col + 5'd4;
                    end
                    // the window is in: its bank and descriptor to the interpolation side, and
                    // the next item (list 1 of a bi-predicted group, else the next plane)
                    if (cp_row == wh_q) begin
                        bank_full[fb] <= 1'b1;
                        d_plane[fb] <= plane; d_fx[fb] <= fx; d_fy[fb] <= fy; d_bw[fb] <= bw; d_bh[fb] <= bh;
                        d_gx[fb] <= g_x; d_gy[fb] <= g_y; d_gref0[fb] <= gref0; d_gref1[fb] <= gref1;
                        d_bi[fb] <= g_bi; d_lx[fb] <= lx; d_gp0[fb] <= gp0;
                        fb <= !fb;
                        if (g_bi && !lx) begin lx <= 1'b1; st <= I_LIST; end
                        else st <= I_NEXT_PLANE;
                    end
                end
                I_NEXT_PLANE: begin
                    if (plane == 2'd2) st <= I_NEXT_GROUP;
                    else begin plane <= plane + 1'b1; st <= I_PLANE; end
                end
                I_NEXT_GROUP: begin
                    if (all16 || (g_q == 2'd3 && g_sub == 3'd4)) st <= I_DRAIN;
                    else if (g_sub == 3'd4) begin g_q <= g_q + 1'b1; g_sub <= 3'd0; st <= I_GROUP; end
                    else st <= I_GROUP;
                end
                // every item fetched: done once the interpolation side has emptied both banks
                I_DRAIN: if (bank_full == 2'b00 && k == K_IDLE) st <= I_DONE;
                I_DONE: begin busy <= 1'b0; done <= 1'b1; st <= I_IDLE; end
                default: st <= I_IDLE;
            endcase

            // ---- the interpolation side: the full banks in order --------------------------------
            case (k)
                K_IDLE: if (bank_full[kb]) begin
                    if (kd_bi && !kd_lx) k <= K_MC;       // list 0 of a bi-predicted group: into pbuf0
                    else k <= K_WT_RD;                     // the last list: the weights, then wpred
                end
                K_MC: begin
                    mc_start <= 1'b1; pb_widx <= '0;
                    k <= K_MC_WAIT;
                end
                K_MC_WAIT: begin
                    if (mc_valid) pb_widx <= pb_widx + 1'b1;
                    if (mc_valid && mc_last) begin bank_full[kb] <= 1'b0; kb <= !kb; k <= K_IDLE; end   // (bi: list 1 next)
                end
                // ---- weighting -----------------------------------------------------------------
                K_WT_RD: begin
                    // the explicit weight entries: list 0 first (the single list's otherwise)
                    wt_addr <= {1'b0, kd_gref0};
                    k <= K_WT_RD1;
                end
                K_WT_RD1: k <= K_WT_RD2;        // the table registers the address, then the data
                K_WT_RD2: begin
                    logic explicit, implicit;
                    logic [47:0] wt0;
                    explicit = (slice_type == 2'd0 && weighted_pred) || (slice_type == 2'd1 && weighted_bipred_idc == 2'd1);
                    implicit = (slice_type == 2'd1 && weighted_bipred_idc == 2'd2 && kd_bi);
                    if (implicit) begin
                        ds_b <= cur_poc - $signed(poc_q0);
                        ds_d <= $signed(poc_q1) - $signed(poc_q0);
                        ds_start <= 1'b1;
                        k <= K_IMPL_WAIT;
                    end else begin
                        wp_mode <= explicit ? 2'd1 : 2'd0;
                        k <= K_WEIGHT;
                        if (explicit) begin
                            // wt_data: {cr_o, cr_w, cb_o, cb_w, luma_o, luma_w} of the entry addressed
                            // last cycle (list 0 when the group uses it, else list 1: re-read below)
                            if (kd_gp0) begin
                                wp_w0 <= $signed(wt_data[8*(2*kd_plane) +: 8]);
                                wp_o0 <= $signed(wt_data[8*(2*kd_plane + 1) +: 8]);
                                if (kd_bi) begin wt_addr <= {1'b1, kd_gref1}; k <= K_IMPL; end
                            end else begin
                                wt_addr <= {1'b1, kd_gref1};
                                k <= K_IMPL;                // read list 1's entry as the single list
                            end
                            wp_logwd <= kd_c ? chroma_log2_wd : luma_log2_wd;
                        end
                    end
                end
                K_IMPL: k <= K_IMPL2;           // (explicit list-1 entry: address -> RAM -> data)
                K_IMPL2: k <= K_IMPL_WAIT;
                K_IMPL_WAIT: begin
                    logic explicit;
                    explicit = (slice_type == 2'd0 && weighted_pred) || (slice_type == 2'd1 && weighted_bipred_idc == 2'd1);
                    if (explicit) begin
                        if (kd_gp0) begin
                            wp_w1 <= $signed(wt_data[8*(2*kd_plane) +: 8]);
                            wp_o1 <= $signed(wt_data[8*(2*kd_plane + 1) +: 8]);
                        end else begin
                            wp_w0 <= $signed(wt_data[8*(2*kd_plane) +: 8]);
                            wp_o0 <= $signed(wt_data[8*(2*kd_plane + 1) +: 8]);
                        end
                        k <= K_WEIGHT;
                    end else if (ds_done) begin
                        // 8.4.3: 32/32 when td is 0, either picture is long-term, or DSF >> 2
                        // is outside -64..128
                        wp_mode <= 2'd1; wp_logwd <= 3'd5; wp_o0 <= '0; wp_o1 <= '0;
                        if (ds_zero || lng0[kd_gref0] || lng1[kd_gref1] ||
                            (ds_dsf >>> 2) < -11'sd64 || (ds_dsf >>> 2) > 11'sd128) begin
                            wp_w0 <= 9'sd32; wp_w1 <= 9'sd32;
                        end else begin
                            wp_w0 <= 9'sd64 - (ds_dsf >>> 2);
                            wp_w1 <= ds_dsf >>> 2;
                        end
                        k <= K_WEIGHT;
                    end
                end
                K_WEIGHT: begin
                    // the weights are set: wpred and the last list's interpolation start together
                    wp_n <= {4'd0, kd_bw} * {4'd0, kd_bh};           // 4..256 (a product of powers of two)
                    wp_start <= 1'b1; mc_start <= 1'b1;
                    pf_h <= '0; pf_t <= '0; pf_n <= '0; pf_i1 <= 1'b0; pf_i2 <= 1'b0; pf_rd <= '0; bw_q <= kd_bw;
                    wo_x <= '0; wo_y <= '0;
                    k <= K_WEIGHT_WAIT;
                end
                K_WEIGHT_WAIT: begin
                    // bi: list 0's samples prefetched from pbuf0 (address, then data an edge
                    // later, then into the FIFO), taken with list 1's by wpred
                    begin
                        logic issue;
                        issue = kd_bi && (pf_rd < wp_n) && ({1'b0, pf_n} + {3'd0, pf_i1} + {3'd0, pf_i2} < 4'd4);
                        if (issue) begin pb_ridx <= pf_rd[7:0]; pf_rd <= pf_rd + 1'b1; end
                        pf_i1 <= issue; pf_i2 <= pf_i1;
                        if (pf_i2) begin pf[pf_t] <= pb_q0; pf_t <= pf_t + 1'b1; end
                        pf_n <= pf_n + {2'd0, pf_i2} - {2'd0, kd_bi && wp_a_ready};
                        if (kd_bi && wp_a_ready) pf_h <= pf_h + 1'b1;
                    end
                    // results into the sample RAM, raster over the block
                    if (wp_valid) begin
                        logic [4:0] ox, oy;
                        ox = (kd_c ? {1'b0, kd_gx[4:1]} : kd_gx) + wo_x;
                        oy = (kd_c ? {1'b0, kd_gy[4:1]} : kd_gy) + wo_y;
                        out_we <= 1'b1;
                        out_data <= wp_out;
                        case (kd_plane)
                            2'd0: out_addr <= {1'b0, oy[3:0], ox[3:0]};
                            2'd1: out_addr <= 9'd256 + {3'd0, oy[2:0], ox[2:0]};
                            default: out_addr <= 9'd320 + {3'd0, oy[2:0], ox[2:0]};
                        endcase
                        if (wo_x == bw_q - 5'd1) begin wo_x <= '0; wo_y <= wo_y + 1'b1; end
                        else wo_x <= wo_x + 1'b1;
                        if (wp_last) begin bank_full[kb] <= 1'b0; kb <= !kb; k <= K_IDLE; end
                    end
                end
                default: k <= K_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
