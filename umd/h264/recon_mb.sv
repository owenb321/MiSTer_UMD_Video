// umd/h264/recon_mb.sv -- one macroblock at a time, from its descriptor to final samples
// in the DPB (docs/h264_recon.md S2.3)
//
//   LOAD      the neighbours: the line memories' entries of the macroblocks above and
//             above-right (motion / modes / QPs at 4x4 granularity, the unfiltered bottom
//             row for intra prediction), the left macroblock's (registers), the corner
//   QP        QPY = (QPY,PRED + mb_qp_delta + 52) % 52 (7.4.5), QPC per plane (8.5.8)
//   PREDICT   I_PCM: the samples; intra: Intra_4x4 block by block with its residual
//             (8.3.1), Intra_16x16 (8.3.3), chroma (8.3.4); inter: the co-located side
//             info for direct (Table 8-6 / 8-8), mv_pred, recon_inter
//   RESIDUAL  dequant_itrans per coded block, added and clipped into the sample bank
//   SAVE      the unfiltered right column / bottom row (the next macroblocks' intra
//             neighbours), this macroblock's motion into the line memory and the left
//             registers, its side info (the co-located data of later B pictures) to DDR3
//   DEBLOCK   recon_deblock over this macroblock, its left neighbour's right columns and
//             the above neighbour's bottom rows
//   WRITE     the samples that are final now (docs/h264_recon.md S2.3 step 6): the
//             above macroblock's bottom rows (13..15, chroma 7), the left macroblock's
//             rows 0..12 (0..6) -- all 16 (8) on the last row -- and, at the right
//             picture edge, this macroblock's; the rows left pending into the deblock
//             line memory
// then the descriptor is released and the banks swap (this macroblock becomes "left").
//
// Sample banks: two 48-word memories of 64-bit words (8 samples, byte 0 leftmost): luma
// row y word w at 2y + w, Cb row y at 32 + y, Cr at 40 + y. Line memories, indexed by the
// macroblock column: LM_INFO (429 bits per entry, below), LM_SAMP (the unfiltered bottom
// row: luma 2 words, Cb 1, Cr 1), LM_DBK (the filtered rows 12..15 / 6..7: 12 words).
// Availability (6.4.9): a neighbour is available when it is in this slice (every entry
// carries the slice id of the macroblock that wrote it; ids never repeat in a picture).
//
// LM_INFO / left entry layout (437 bits):
//   [15:0] slice id  [16] intra  [17] Intra_4x4  [18] I_PCM  [24:19] QPY  [30:25] QPC Cb
//   [36:31] QPC Cr  [42:37] I_PCM QPC Cb  [48:43] I_PCM QPC Cr, then 4 blocks (the bottom
//   row left to right, or the right column top to bottom) of 97 bits at 49 + 97 j:
//   [3:0] Intra4x4PredMode [4] nz [5] predL0 [10:6] refIdxL0 [18:11] code L0 [34:19] mvx L0
//   [50:35] mvy L0 [51] predL1 [56:52] refIdxL1 [64:57] code L1 [80:65] mvx L1 [96:81] mvy L1
// A code is a reference picture's identity {valid, store[4:0], parity[1:0]} (20 stores,
// h264_pkg NSTORE).
//
// This first version is sequential and correctness-first (a macroblock is one pass
// through the states, no overlap); docs/h264_recon.md records its measured cycle counts
// and what the throughput work will change.

`default_nettype none

module recon_mb (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         clear,

    // ---- the slice (held from slice_go) ---------------------------------------------------
    input  wire         slice_go,          // a new slice's parameters are valid
    input  wire  [1:0]  slice_type,        // 0 P, 1 B, 2 I
    input  wire  [5:0]  slice_qp,
    input  wire  [1:0]  disable_deblock,
    input  wire signed [4:0] alpha_off,
    input  wire signed [4:0] beta_off,
    input  wire         direct_spatial,
    input  wire  [5:0]  num_ref_l0,
    input  wire  [5:0]  num_ref_l1,
    input  wire  [2:0]  luma_log2_wd,
    input  wire  [2:0]  chroma_log2_wd,
    input  wire         weighted_pred,
    input  wire  [1:0]  weighted_bipred_idc,
    input  wire         constrained_intra,
    input  wire signed [4:0] cb_qp_off,
    input  wire signed [4:0] cr_qp_off,
    input  wire  [7:0]  width_mbs,
    input  wire  [7:0]  frame_height_mbs,
    input  wire         direct_8x8_inf,
    input  wire         field_pic,
    input  wire         bottom,
    input  wire  [4:0]  cur_store,
    input  wire signed [31:0] cur_poc,
    input  wire  [28:0] dpb_base,
    input  wire  [20:0] plane_mbs,

    // the slice tables (recon_slice_tab)
    // recon_slice_tab's code RAMs: {valid, store, parity} of list entry code_ra (data the
    // cycle after)
    output logic [4:0]  code_ra0,
    output logic [4:0]  code_ra1,
    input  wire  [7:0]  code_q0,
    input  wire  [7:0]  code_q1,
    output logic [4:0]  poc_ra0,
    output logic [4:0]  poc_ra1,
    input  wire  [31:0] poc_q0,
    input  wire  [31:0] poc_q1,
    input  wire  [31:0] lng0,
    input  wire  [31:0] lng1,
    input  wire  [4:0]  col_store,
    input  wire  [1:0]  col_half,
    input  wire  [1:0]  vert_scale,
    input  wire         l1_0_short,
    output logic [4:0]  dsf_ra,            // recon_slice_tab's temporal tables (mv_pred's ports)
    input  wire  [10:0] dsf_q,
    input  wire  [31:0] tdir_raw,
    output logic [6:0]  map_ra,
    input  wire  [5:0]  map_q,
    output logic [5:0]  wt_addr,
    input  wire  [47:0] wt_data,

    // ---- the descriptor (mb_intake) ----------------------------------------------------------
    input  wire         mb_valid,
    output logic        mb_release,
    input  wire  [13:0] mb_addr,
    input  wire         mb_skip,
    input  wire  [5:0]  mb_type,
    input  wire  [15:0] mb_sub_types,
    input  wire         mb_is_intra,
    input  wire  [4:0]  mb_itype,
    input  wire  [5:0]  mb_cbp,
    input  wire signed [7:0] mb_qp_delta,
    input  wire  [1:0]  mb_chroma_mode,
    input  wire  [15:0] mb_prev_flag,
    input  wire  [47:0] mb_rem_mode,
    input  wire  [39:0] mb_refs,
    output logic [4:0]  mvd_ra,            // mb_intake's mvd RAM ({lx, blk}), data the cycle after
    input  wire  [31:0] mvd_q,             // {x, y}
    input  wire  [3:0]  mb_direct8,
    input  wire  [26:0] mb_coded,
    input  wire  [15:0] mb_nz,
    input  wire         mb_pcm,
    output logic [8:0]  coef_addr,
    input  wire signed [15:0] coef_data,

    // ---- DDR3 (dpb_mem) ---------------------------------------------------------------------
    output logic        cmd_valid,
    input  wire         cmd_ready,
    output logic        cmd_write,
    output logic [28:0] cmd_addr,
    output logic [3:0]  cmd_len,
    output logic        wd_valid,
    input  wire         wd_ready,
    output logic [63:0] wd_data,
    output logic [7:0]  wd_be,
    input  wire         rd_valid,
    input  wire  [63:0] rd_data,
    output logic        rd_ready,

    // ---- status -------------------------------------------------------------------------------
    output logic        idle,              // no macroblock in flight, every write issued
    output logic        mb_done,           // one pulse per macroblock (the bench scores here)
    output logic [13:0] mb_done_addr,
    output logic [31:0] mb_count,
    output logic [31:0] err_count,
    output logic [3:0]  err_code,
    output logic        dbg_pre_db,        // (benches) the bank holds this MB's pre-deblock samples
    output logic [1:0]  dbg_bank           //           ... in bank dbg_bank (0..2)
);

    // =====================================================================================
    // geometry
    // =====================================================================================
    wire  [7:0]  pic_h_mbs = field_pic ? {1'b0, frame_height_mbs[7:1]} : frame_height_mbs;
    logic [6:0]  mbx, mby;                 // the current macroblock
    wire  [1:0]  cur_struct = field_pic ? (bottom ? 2'd2 : 2'd1) : 2'd0;
    wire  [28:0] cur_base = dpb_base + {7'd0, cur_store, 17'd0};
    wire  [28:0] off_cb = {3'd0, plane_mbs, 5'd0};                              // 32 * W * HF
    wire  [28:0] off_cr = {3'd0, plane_mbs, 5'd0} + {5'd0, plane_mbs, 3'd0};    // 40 * W * HF
    wire  [28:0] off_side = {3'd0, plane_mbs, 5'd0} + {4'd0, plane_mbs, 4'd0};  // 48 * W * HF
    wire  [20:0] half_mbs = {1'b0, plane_mbs[20:1]};

    // =====================================================================================
    // the sample banks (two) and the line memories
    // =====================================================================================
    // THREE banks (the MB overlap, docs/h264_recon.md S6): macroblock k builds in bank
    // k mod 3; the back engine deblocks macroblock n in fb(n) with its left neighbour in
    // fb(n - 1) and writes n - 1 back, while macroblock n + 1 builds in the third
    logic [1:0]  fb, fb_prev;              // the front's bank, the previous macroblock's
    logic [63:0] bank0 [0:63];             // 48 used: a 48-deep byte-enabled array stays in registers (Quartus 17, silently)
    logic [63:0] bank1 [0:63];
    logic [63:0] bank2 [0:63];
    logic        bk_we [0:2];
    logic [5:0]  bk_waddr [0:2];
    logic [63:0] bk_wdata [0:2];
    logic [7:0]  bk_wbe [0:2];
    logic [5:0]  bk_raddr [0:2];
    logic [63:0] bk_q [0:2];
    // one memory per process, scalar ports: the two in one block were flattened to
    // 6,144 registers by Quartus 17 (neither inferred nor reported uninferred)
    wire         bk0_we = bk_we[0], bk1_we = bk_we[1], bk2_we = bk_we[2];
    wire  [5:0]  bk0_wa = bk_waddr[0], bk1_wa = bk_waddr[1], bk2_wa = bk_waddr[2];
    wire  [5:0]  bk0_ra = bk_raddr[0], bk1_ra = bk_raddr[1], bk2_ra = bk_raddr[2];
    wire  [63:0] bk0_wd = bk_wdata[0], bk1_wd = bk_wdata[1], bk2_wd = bk_wdata[2];
    wire  [7:0]  bk0_be = bk_wbe[0], bk1_be = bk_wbe[1], bk2_be = bk_wbe[2];
    logic [63:0] bk0_q, bk1_q, bk2_q;
    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) if (bk0_we && bk0_be[i]) bank0[bk0_wa][8*i +: 8] <= bk0_wd[8*i +: 8];
        bk0_q <= bank0[bk0_ra];
    end
    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) if (bk1_we && bk1_be[i]) bank1[bk1_wa][8*i +: 8] <= bk1_wd[8*i +: 8];
        bk1_q <= bank1[bk1_ra];
    end
    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) if (bk2_we && bk2_be[i]) bank2[bk2_wa][8*i +: 8] <= bk2_wd[8*i +: 8];
        bk2_q <= bank2[bk2_ra];
    end
    always_comb begin bk_q[0] = bk0_q; bk_q[1] = bk1_q; bk_q[2] = bk2_q; end

    // LM_DBK: 128 x 16 words (12 used): {mbx, idx}
    logic [63:0] lm_dbk [0:2047];
    logic        dbk_we;
    logic [10:0] dbk_waddr, dbk_raddr;
    logic [63:0] dbk_wdata, dbk_q;
    logic [7:0]  dbk_wbe;
    always_ff @(posedge clk) begin
        for (int i = 0; i < 8; i++) if (dbk_we && dbk_wbe[i]) lm_dbk[dbk_waddr][8*i +: 8] <= dbk_wdata[8*i +: 8];
        dbk_q <= lm_dbk[dbk_raddr];
    end

    // LM_SAMP: 128 x 4 words: luma row 15 (2), Cb row 7, Cr row 7
    logic [63:0] lm_samp [0:511];
    logic        smp_we;
    logic [8:0]  smp_waddr, smp_raddr;
    logic [63:0] smp_wdata, smp_q;
    always_ff @(posedge clk) begin
        if (smp_we) lm_samp[smp_waddr] <= smp_wdata;
        smp_q <= lm_samp[smp_raddr];
    end

    // LM_INFO: 128 x 437 bits, as five RAMs read together: the header (49 bits) and the four
    // bottom blocks (97 each), each block written on its own as the motion RAM is walked
    // (M_SAVE) -- one 437-bit word would need the whole record registered to write it
    logic [48:0] lm_info_h [0:127];
    logic [96:0] lm_info_b0 [0:127];
    logic [96:0] lm_info_b1 [0:127];
    logic [96:0] lm_info_b2 [0:127];
    logic [96:0] lm_info_b3 [0:127];
    logic        inf_we;               // the header (the end walk)
    logic        ib_we;                // block ib_j
    logic [1:0]  ib_j;
    logic [6:0]  ib_wa;
    logic [96:0] ib_wd;
    logic [6:0]  inf_waddr, inf_raddr;
    logic [48:0] inf_wdata;
    logic [436:0] inf_q;
    always_ff @(posedge clk) begin
        if (inf_we) lm_info_h[inf_waddr] <= inf_wdata;
        inf_q[48:0] <= lm_info_h[inf_raddr];
    end
    always_ff @(posedge clk) begin
        if (ib_we && ib_j == 2'd0) lm_info_b0[ib_wa] <= ib_wd;
        inf_q[49 +: 97] <= lm_info_b0[inf_raddr];
    end
    always_ff @(posedge clk) begin
        if (ib_we && ib_j == 2'd1) lm_info_b1[ib_wa] <= ib_wd;
        inf_q[146 +: 97] <= lm_info_b1[inf_raddr];
    end
    always_ff @(posedge clk) begin
        if (ib_we && ib_j == 2'd2) lm_info_b2[ib_wa] <= ib_wd;
        inf_q[243 +: 97] <= lm_info_b2[inf_raddr];
    end
    always_ff @(posedge clk) begin
        if (ib_we && ib_j == 2'd3) lm_info_b3[ib_wa] <= ib_wd;
        inf_q[340 +: 97] <= lm_info_b3[inf_raddr];
    end

    // =====================================================================================
    // neighbours
    // =====================================================================================
    logic [15:0] slice_id;
    logic [436:0] nb_left;
    wire  [436:0] nb_above = inf_q;        // LM_INFO[mbx], held by the RAM's port (M_LOAD)
    // the diagonal neighbours keep only what is read from them: {block, intra, slice id}
    // -- the above-right macroblock's bottom-left block (C), the above-left's bottom-right
    // (D); prev_above is the above entry of the previous macroblock (the next D)
    logic [113:0] nb_aright, nb_aleft, prev_above;
    logic        av_above, av_aright, av_aleft, av_left;     // in this slice (6.4.9)
    // the row above is read in place from LM_SAMP ({mbx, word}: luma 0, 1, Cb 2, Cr 3); the left
    // column (luma rows 0..15, Cb 16..23, Cr 24..31) is a 32-byte RAM written as M_SAVE walks
    // the right column. Both are read one sample a cycle by the gather pipeline (as registers
    // they were 512 flip-flops and a 32:1 selection per reader)
    logic [7:0]  upr_samp [0:3];           // above-right luma 0..3
    logic [7:0]  ls_m [0:31];
    logic        ls_we;
    logic [4:0]  ls_wa, ls_raddr;
    logic [7:0]  ls_wd, ls_q;
    always_ff @(posedge clk) begin
        if (ls_we) ls_m[ls_wa] <= ls_wd;
        ls_q <= ls_m[ls_raddr];
    end
    logic [7:0]  corner [0:2];             // above-left: luma, Cb, Cr
    logic [7:0]  next_corner [0:2];

    // =====================================================================================
    // the current macroblock's side info
    // =====================================================================================
    logic [5:0]  qp, qp_pred;
    logic [5:0]  qpc0, qpc1, pcm_qpc0, pcm_qpc1;
    logic [3:0]  modes [0:15];             // Intra4x4PredMode (2 when not Intra_4x4)
    // the motion of the 16 blocks (mv_pred's result, written in M_MV_READ): one RAM, read one
    // block at a time by recon_inter (the group's first block), the side-word walk and the
    // LM_INFO / nb_left walks (bottom row, right column). Record (LM_INFO's block above
    // {nz, mode}): {mvy1, mvx1, code1, ref1, pred1, mvy0, mvx0, code0, ref0, pred0}, the codes
    // looked up once as the block is written (0 for a list the block does not use). As
    // registers (m_* [0:1][0:15]) it was 1,472 flip-flops and 16:1 selectors at every reader.
    // An intra macroblock writes nothing: the reads are zeroed (mot_qm) instead.
    logic [91:0] mot_m [0:15];
    logic        mot_we;
    logic [3:0]  mot_wa, mot_ra;
    logic [91:0] mot_wd, mot_q;
    always_ff @(posedge clk) begin
        if (mot_we) mot_m[mot_wa] <= mot_wd;
        mot_q <= mot_m[mot_ra];
    end
    logic        cur_intra, cur_i4, cur_pcm;

    // QPY of this macroblock (7-37, wrapping) and the chroma QPs (8-311 + Table 8-15), as
    // combinational lookups the QP state registers (umd/h264/recon_mb.sv qpc_lookup; no
    // `function automatic`: Quartus 17, CLAUDE.md). pcm: qP 0 for I_PCM's deblocking.
    logic [5:0]  qp_new, qpc_n0, qpc_n1, qpc_p0, qpc_p1;
    logic signed [7:0] qp_sum;
    always_comb begin
        qp_sum = $signed({2'b00, qp_pred}) + mb_qp_delta;
        if (qp_sum < 0) qp_sum = qp_sum + 8'sd52; else if (qp_sum > 51) qp_sum = qp_sum - 8'sd52;
        qp_new = qp_sum[5:0];
    end
    qpc_lookup u_qpc_n0 (.q(qp_new), .off(cb_qp_off), .qpc(qpc_n0));
    qpc_lookup u_qpc_n1 (.q(qp_new), .off(cr_qp_off), .qpc(qpc_n1));
    qpc_lookup u_qpc_p0 (.q(6'd0),   .off(cb_qp_off), .qpc(qpc_p0));
    qpc_lookup u_qpc_p1 (.q(6'd0),   .off(cr_qp_off), .qpc(qpc_p1));

    // =====================================================================================
    // the units
    // =====================================================================================
    // ---- mv_pred ----
    logic        mvp_start, mvp_busy, mvp_done, mvp_err;
    logic [3:0]  mvp_blk;
    logic        mvp_pred0, mvp_pred1;
    logic [4:0]  mvp_ref0, mvp_ref1;
    logic [15:0] mvp_mvx0, mvp_mvy0, mvp_mvx1, mvp_mvy1;
    logic [799:0] nb_data;
    logic [9:0]  nb_av, nb_in;
    logic [3:0]  col_ra;
    logic [47:0] col_q;
    always_comb begin
    end
    mv_pred u_mvp (
        .clk(clk), .rst_n(rst_n), .start(mvp_start), .busy(mvp_busy), .done(mvp_done), .err(mvp_err),
        .slice_type(slice_type), .direct_spatial(direct_spatial), .direct_8x8_inf(direct_8x8_inf),
        .num_ref_l0(num_ref_l0), .num_ref_l1(num_ref_l1), .list1_0_is_short(l1_0_short), .vert_scale(vert_scale),
        .map_ra(map_ra), .map_q(map_q), .dsf_ra(dsf_ra), .dsf_q(dsf_q), .tdir_raw(tdir_raw),
        .skip(mb_skip), .mb_type(mb_type), .sub_mb_type(mb_sub_types), .refs(mb_refs), .mvd_ra(mvd_ra), .mvd_q({mvd_q[15:0], mvd_q[31:16]}),
        .nb_data(nb_data), .nb_avail(nb_av), .nb_intra(nb_in), .col_ra(col_ra), .col_q(col_q),
        .out_blk(mvp_blk), .out_pred0(mvp_pred0), .out_ref0(mvp_ref0), .out_mvx0(mvp_mvx0), .out_mvy0(mvp_mvy0),
        .out_pred1(mvp_pred1), .out_ref1(mvp_ref1), .out_mvx1(mvp_mvx1), .out_mvy1(mvp_mvy1));

    // the neighbour entries mv_pred reads: A = left right column rows 0..3, B = above bottom
    // row columns 0..3, C = above-right column 0, D = above-left column 3
    // (an entry's 95-bit block j -> mv_pred's 80-bit neighbour word, by part-selects)
    logic [96:0] nbe [0:9];
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            nbe[j] = nb_left[49 + 97*j +: 97];
            nbe[4 + j] = nb_above[49 + 97*j +: 97];
        end
        nbe[8] = nb_aright[113:17];
        nbe[9] = nb_aleft[113:17];
        for (int k = 0; k < 10; k++)
            nb_data[80*k +: 80] = {1'b0, nbe[k][51], 1'b0, nbe[k][56:52], nbe[k][96:81], nbe[k][80:65],
                                   1'b0, nbe[k][5], 1'b0, nbe[k][10:6], nbe[k][50:35], nbe[k][34:19]};
        nb_av = {av_aleft, av_aright, {4{av_above}}, {4{av_left}}};
        nb_in = {nb_aleft[16], nb_aright[16], {4{nb_above[16]}}, {4{nb_left[16]}}};
    end

    // ---- recon_inter ----
    logic        int_start, int_busy, int_done, int_err;
    // the block being read back from mv_pred, in the motion bus's layout; the uniformity
    // flags recon_inter groups by (computed in M_MV_READ)
    wire  [75:0] rd_key = {mvp_pred1, mvp_pred1 ? mvp_ref1 : 5'd0, mvp_mvx1, mvp_mvy1,
                           mvp_pred0, mvp_pred0 ? mvp_ref0 : 5'd0, mvp_mvx0, mvp_mvy0};
    logic [75:0] key0, keyq;
    logic        all16;
    logic [3:0]  all8;
    logic        int_cmd_valid, int_rd_ready, int_out_we;
    logic [28:0] int_cmd_addr;
    logic [3:0]  int_cmd_len;
    logic [8:0]  int_out_addr;
    logic [7:0]  int_out_data;
    logic [5:0]  int_wt_addr;
    logic [3:0]  int_mot_ra;
    logic        f_cmd_rdy;                // the front's command ready from the DDR arbiter (the include)
    recon_inter u_inter (
        .clk(clk), .rst_n(rst_n), .start(int_start), .busy(int_busy), .done(int_done), .err(int_err),
        .mb_x(mbx), .mb_y(mby), .width_mbs(width_mbs), .frame_height_mbs(frame_height_mbs),
        .field_pic(field_pic), .bottom(bottom), .dpb_base(dpb_base), .plane_mbs(plane_mbs),
        .mot_ra(int_mot_ra), .mot_q(mot_q), .all16(all16), .all8(all8), .slice_type(slice_type), .weighted_pred(weighted_pred),
        .weighted_bipred_idc(weighted_bipred_idc), .luma_log2_wd(luma_log2_wd), .chroma_log2_wd(chroma_log2_wd),
        .poc_ra0(poc_ra0), .poc_ra1(poc_ra1), .poc_q0(poc_q0), .poc_q1(poc_q1), .lng0(lng0), .lng1(lng1), .cur_poc(cur_poc),
        .wt_addr(int_wt_addr), .wt_data(wt_data),
        .cmd_valid(int_cmd_valid), .cmd_ready(f_cmd_rdy), .cmd_addr(int_cmd_addr), .cmd_len(int_cmd_len),
        .rd_valid(rd_valid), .rd_data(rd_data), .rd_ready(int_rd_ready),
        .out_we(int_out_we), .out_addr(int_out_addr), .out_data(int_out_data));
    assign wt_addr = int_wt_addr;

    // ---- intra_pred ----
    logic        ip_nb_we, ip_start, ip_valid, ip_last, ip_busy;
    logic [5:0]  ip_nb_idx;
    logic [7:0]  ip_nb_val, ip_pred;
    logic [1:0]  ip_kind;
    logic [3:0]  ip_mode;
    logic        ip_av_top, ip_av_left;
    intra_pred u_ip (
        .clk(clk), .rst_n(rst_n), .nb_we(ip_nb_we), .nb_idx(ip_nb_idx), .nb_val(ip_nb_val),
        .start(ip_start), .kind(ip_kind), .mode(ip_mode), .avail_top(ip_av_top), .avail_left(ip_av_left),
        .pred_valid(ip_valid), .pred(ip_pred), .pred_last(ip_last), .pred_ready(1'b1), .busy(ip_busy));

    // ---- dequant_itrans ----
    logic        dq_start, dq_coef_valid, dq_coef_ready, dq_res_valid, dq_res_last, dq_busy;
    logic [2:0]  dq_kind;
    logic [5:0]  dq_qp;
    logic signed [15:0] dq_dc, dq_coef, dq_res;
    dequant_itrans u_dq (
        .clk(clk), .rst_n(rst_n), .start(dq_start), .kind(dq_kind), .qp(dq_qp), .field_scan(field_pic),
        .dc_in(dq_dc), .coef_valid(dq_coef_valid), .coef(dq_coef), .coef_ready(dq_coef_ready),
        .res_valid(dq_res_valid), .res(dq_res), .res_last(dq_res_last), .res_ready(1'b1), .busy(dq_busy));

    // ---- recon_deblock ----
    logic        db_start, db_done, db_busy, db_wr_en, db_pre_done;
    logic [1:0]  db_rd_region, db_wr_region;
    logic [5:0]  db_rd_addr, db_wr_addr;
    logic [63:0] db_rd_data, db_wr_data;
    logic [7:0]  db_wr_be;
    logic        db_left_en, db_top_en, db_int_en;
    logic [31:0] q_mbw, l_mbw, t_mbw;
    logic [4*83-1:0]  l_blkw, t_blkw;
    // {mvy1, mvx1, code1, pred1, mvy0, mvx0, code0, pred0, nz} from a 97-bit entry block
    logic [96:0] lbe [0:3];
    logic [96:0] tbe [0:3];
    always_comb begin
        q_mbw = {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, cur_pcm, cur_intra};
        l_mbw = {nb_left[48:43], nb_left[42:37], nb_left[36:31], nb_left[30:25], nb_left[24:19], nb_left[18], nb_left[16]};
        t_mbw = {nb_above[48:43], nb_above[42:37], nb_above[36:31], nb_above[30:25], nb_above[24:19], nb_above[18], nb_above[16]};
        for (int j = 0; j < 4; j++) begin
            lbe[j] = nb_left[49 + 97*j +: 97];
            tbe[j] = nb_above[49 + 97*j +: 97];
            l_blkw[83*j +: 83] = {lbe[j][96:81], lbe[j][80:65], lbe[j][64:57], lbe[j][51], lbe[j][50:35],
                                  lbe[j][34:19], lbe[j][18:11], lbe[j][5], lbe[j][4]};
            t_blkw[83*j +: 83] = {tbe[j][96:81], tbe[j][80:65], tbe[j][64:57], tbe[j][51], tbe[j][50:35],
                                  tbe[j][34:19], tbe[j][18:11], tbe[j][5], tbe[j][4]};
        end
    end
    // the deblocker's block records, written as mv_pred's motion is read back (M_MV_READ:
    // block cnt - 1's words are on mvp_*): {mvy1, mvx1, code1, pred1, mvy0, mvx0, code0,
    // pred0, nz}. An intra macroblock writes none: its edges are bS 3 / 4 from the intra
    // flag alone.
    logic        rec_we;
    logic [3:0]  rec_wa;
    logic [82:0] rec_wd;
    // (driven in recon_mb_fsm.svh, after the state and the counter are declared)
    recon_deblock u_db (
        .clk(clk), .rst_n(rst_n), .start(db_start), .pre_done(db_pre_done), .done(db_done), .busy(db_busy),
        .left_en(db_left_en), .top_en(db_top_en), .int_en(db_int_en), .field_pic(field_pic),
        .alpha_off(alpha_off), .beta_off(beta_off),
        .q_mb_in(q_mbw), .l_mb_in(l_mbw), .t_mb_in(t_mbw), .rec_we(rec_we), .rec_wa(rec_wa), .rec_wd(rec_wd), .l_blk(l_blkw), .t_blk(t_blkw),
        .rd_region(db_rd_region), .rd_addr(db_rd_addr), .rd_data(db_rd_data),
        .wr_en(db_wr_en), .wr_region(db_wr_region), .wr_addr(db_wr_addr), .wr_data(db_wr_data), .wr_be(db_wr_be));

    // =====================================================================================
    // the per-macroblock FSM
    // =====================================================================================
    typedef enum logic [6:0] {
        M_IDLE, M_DIV, M_LOAD0, M_LOAD1, M_LOAD2, M_LOAD3, M_LOAD4, M_LOAD5, M_LOAD6, M_QP,
        M_PCM,
        M_I4_BLK, M_I4_NB, M_I4_NBW, M_I4_GO, M_I4_PRED,
        M_I16_NB, M_I16_GO, M_I16_PRED,
        M_CI_NB, M_CI_GO, M_CI_PRED,
        M_COL_CMD, M_COL_DATA, M_MV_GO, M_MV_WAIT, M_MV_READ, M_INTER_GO, M_INTER_WAIT,
        M_RES_LUMA, M_RES_CHROMA, M_RES_NEXT, M_RES_FEED, M_RES_ADD_RD, M_RES_ADD_WR, M_RES_RET,
        M_SAVE, M_SAVE_SIDE_CMD, M_SAVE_SIDE_DATA,
        M_DB_GO, M_DB_WAIT,
        M_WB_PLAN, M_WB_CMD, M_WB_ADDR, M_WB_ADDR2, M_WB_ISSUE, M_WB_DATA, M_WB_NEXT, M_WB_KEEP,
        M_DONE
    } mstate_t;
    mstate_t ms;

    // generic counters and the residual walk
    logic [8:0]  cnt;
    logic [5:0]  step;
    logic [4:0]  rblk;                     // residual walk: 0..15 luma, 16..23 chroma AC, 24..25 chroma DC first
    logic [1:0]  rphase;                   // 0 luma DC (Intra16x16), 1 luma blocks, 2 chroma
    logic [4:0]  res_n;                    // residuals collected
    logic [3:0]  i4;                       // the Intra_4x4 block
    logic [3:0]  i4_mode;
    logic [5:0]  rd_pend;                  // bank reads in flight bookkeeping
    logic [1:0]  cplane;                   // chroma plane being predicted (0 Cb, 1 Cr)
    logic        after_pred;               // the residual walk follows a prediction

    // the Intra_4x4 block's position
    wire [3:0]  bx4 = {i4[2], i4[0], 2'b00};
    wire [3:0]  by4 = {i4[3], i4[1], 2'b00};

    // intra availability of a neighbouring macroblock (8.3.1.2 / 8.3.3 / 8.3.4): in the
    // slice, and intra when constrained_intra_pred_flag
    wire ia_left  = av_left  && (!constrained_intra || nb_left[16]);
    wire ia_above = av_above && (!constrained_intra || nb_above[16]);
    wire ia_aright = av_aright && (!constrained_intra || nb_aright[16]);
    wire ia_aleft = av_aleft && (!constrained_intra || nb_aleft[16]);

    // =====================================================================================
    // (the FSM body is split into recon_mb_fsm.svh for readability)
    // =====================================================================================
`include "umd/h264/recon_mb_fsm.svh"

endmodule

// qPI = Clip3(0, 51, q + off) (8-311; 8-bit video, QpBdOffsetC 0) -> QPC (Table 8-15)
module qpc_lookup (
    input  wire  [5:0]        q,
    input  wire  signed [4:0] off,
    output logic [5:0]        qpc
);
    logic signed [7:0] v;
    logic [5:0] qpi;
    always_comb begin
        v = $signed({2'b00, q}) + off;
        qpi = (v < 0) ? 6'd0 : (v > 51) ? 6'd51 : v[5:0];
        case (qpi)
            6'd30: qpc = 6'd29; 6'd31: qpc = 6'd30; 6'd32: qpc = 6'd31; 6'd33: qpc = 6'd32;
            6'd34: qpc = 6'd32; 6'd35: qpc = 6'd33; 6'd36: qpc = 6'd34; 6'd37: qpc = 6'd34;
            6'd38: qpc = 6'd35; 6'd39: qpc = 6'd35; 6'd40: qpc = 6'd36; 6'd41: qpc = 6'd36;
            6'd42: qpc = 6'd37; 6'd43: qpc = 6'd37; 6'd44: qpc = 6'd37; 6'd45: qpc = 6'd38;
            6'd46: qpc = 6'd38; 6'd47: qpc = 6'd38; 6'd48: qpc = 6'd39; 6'd49: qpc = 6'd39;
            6'd50: qpc = 6'd39; 6'd51: qpc = 6'd39;
            default: qpc = qpi;
        endcase
    end
endmodule

`default_nettype wire
