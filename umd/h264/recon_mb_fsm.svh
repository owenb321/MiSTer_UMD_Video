// umd/h264/recon_mb_fsm.svh -- the state machine of umd/h264/recon_mb.sv (included there;
// every signal is declared in recon_mb.sv). One macroblock per pass: see that header.

    // ---- the front's own memory requests (registered) ----------------------------------
    // (the front builds the macroblock in bank fb; the back engine below deblocks and writes
    // back the previous one -- the MB overlap, docs/h264_recon.md S6)
    logic        f_bk_we;
    logic [5:0]  f_bk_waddr, f_bk_raddr;
    logic        f_bk_rbank;               // (always 0: the front reads its own bank)
    logic [63:0] f_bk_wdata;
    logic [7:0]  f_bk_wbe;
    logic        f_cmd_valid, f_cmd_write;
    logic [28:0] f_cmd_addr;
    logic [3:0]  f_cmd_len;
    logic        f_rd_ready;
    logic        f_wd_valid;               // the side words' write data
    logic [63:0] f_wd_data;
    logic [7:0]  f_wd_be;
    logic        db_rd_is0, db_rd_is1;     // the region of the deblocker's read in flight
    logic        f_idle;                   // the front (idle = the front and the engine)


    // ---- the residual engine's state (its always_ff is at the end of this file) --------
    // It walks the macroblock's residual as soon as M_QP has the QPs (r_go): the luma DC
    // (Intra_16x16), the 16 luma blocks, per chroma plane the DC then the four AC blocks,
    // through dequant_itrans into a residual RAM (block id 0..15 luma, 16..23 chroma AC; a
    // row of four 16-bit samples a word), res_rdy / res_zero per block. The front only
    // waits for a block and adds it: the transforms run under the inter prediction and
    // ahead of the Intra_4x4 chain (docs/h264_recon.md S6).
    typedef enum logic [1:0] {R_IDLE, R_SETUP, R_DC, R_FEED} rstate_t;
    rstate_t     rs;
    logic        r_go;                     // the front's start pulse (M_QP)
    logic [4:0]  r_blk;                    // 0 luma DC, 1..16 luma, 17 Cb DC, 18..21 Cb AC, 22 Cr DC, 23..26 Cr AC, 27 done
    logic        r_i16;
    logic        r_dcc_c;                  // the chroma plane of a chroma DC block
    logic        r_dcnz;                   // this block's DC is nonzero (dc_q is its value in R_DC)
    logic [4:0]  r_id;                     // the residual RAM block of the block being fed
    logic [23:0] res_rdy, res_zero;
    logic [8:0]  r_coef_addr, f_coef_addr;
    logic [4:0]  f_rid;                    // the front's block being added
    logic [63:0] res_m [0:127];
    logic        res_we;
    logic [6:0]  res_wa, res_raddr;
    logic [63:0] res_wd, res_q, r_row;
    always_ff @(posedge clk) begin
        if (res_we) res_m[res_wa] <= res_wd;
        res_q <= res_m[res_raddr];
    end
    always_comb coef_addr = (rs == R_IDLE) ? f_coef_addr : r_coef_addr;
    // ---- the back engine's state (its always_ff is at the end of this file) ------------
    // E_DB: recon_deblock on macroblock n (bank e_cur, its left neighbour in e_left, the
    // above rows in LM_DBK); then the writeback items of the old E_ states: the above
    // macroblock's pending rows, the left macroblock, this one at the right edge
    typedef enum logic [3:0] {E_IDLE, E_DB, E_PLAN, E_CMD, E_ADDR, E_ADDR2, E_ISSUE, E_DATA, E_NEXT, E_KEEP} estate_t;
    estate_t     es;
    logic        e_go;                     // the front's start pulse (with db_start)
    logic [6:0]  e_mbx, e_mby;
    logic [1:0]  e_cur, e_left;
    logic [4:0]  e_cnt;
    logic        e_cmd_valid;
    logic [28:0] e_cmd_addr;
    logic [3:0]  e_cmd_len;
    logic        e_wd_valid;
    logic [63:0] e_wd_data;
    logic [5:0]  e_bk_raddr;
    logic        e_rbank;                  // 0 e_cur, 1 e_left
    logic [10:0] e_dbk_raddr;
    logic        e_dbk_we;
    logic [10:0] e_dbk_waddr;
    logic [63:0] e_dbk_wdata;
    wire         e_busy = (es != E_IDLE) || e_go;

    // ---- the DDR3 port: the front (its reads, recon_inter's, its side-word writes) and the
    // engine (writeback writes). A write burst is granted whole: once a write command is
    // taken, only its owner's data words go until w_left reaches 0 (dpb_mem pairs write data
    // with write commands in order). The front has priority for commands.
    logic        w_owner;                  // 0 front, 1 engine
    logic [3:0]  w_left;                   // data words still owed to the accepted write
    wire         fq_valid = (ms == M_INTER_WAIT) ? int_cmd_valid : f_cmd_valid;
    wire         fq_write = (ms == M_INTER_WAIT) ? 1'b0 : f_cmd_write;
    wire         grant_f = fq_valid && (!fq_write || w_left == 4'd0);
    wire         grant_e = !fq_valid && e_cmd_valid && (w_left == 4'd0);
    assign       f_cmd_rdy = cmd_ready && grant_f;   // (declared in recon_mb.sv: recon_inter's port)
    wire         e_cmd_rdy = cmd_ready && grant_e;
    wire         f_wd_rdy = wd_ready && (w_left != 4'd0) && !w_owner;
    wire         e_wd_rdy = wd_ready && (w_left != 4'd0) && w_owner;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin w_owner <= 1'b0; w_left <= '0; end
        else begin
            if (cmd_valid && cmd_ready && cmd_write) begin w_owner <= grant_e; w_left <= cmd_len; end
            else if (wd_valid && wd_ready) w_left <= w_left - 4'd1;
        end
    end

    // bank ports: the front on fb (recon_inter while predicting, else its own requests);
    // the engine on e_cur / e_left (the deblocker while filtering, else the writeback)
    wire  [5:0]  iw_word = (int_out_addr < 9'd256) ? {1'b0, int_out_addr[7:4], int_out_addr[3]} :
                           (int_out_addr < 9'd320) ? 6'd32 + {3'd0, int_out_addr[5:3]} : 6'd40 + {3'd0, int_out_addr[5:3]};
    wire  [2:0]  iw_byte = int_out_addr[2:0];
    always_comb begin
        for (int b = 0; b < 3; b++) begin
            bk_we[b] = 1'b0; bk_waddr[b] = f_bk_waddr; bk_wdata[b] = f_bk_wdata; bk_wbe[b] = f_bk_wbe;
            bk_raddr[b] = f_bk_raddr;
        end
        // the front, then the engine over it: between the hand-off and M_DONE's bank
        // rotation fb is still e_cur, and the front does not touch its bank then
        if (ms == M_INTER_WAIT) begin
            bk_we[fb] = int_out_we; bk_waddr[fb] = iw_word; bk_wdata[fb] = {8{int_out_data}};
            bk_wbe[fb] = 8'd1 << iw_byte;
        end else begin
            bk_we[fb] = f_bk_we; bk_waddr[fb] = f_bk_waddr; bk_wdata[fb] = f_bk_wdata; bk_wbe[fb] = f_bk_wbe;
        end
        bk_raddr[fb] = f_bk_raddr;
        // the engine
        if (es == E_DB) begin
            if (db_wr_en && db_wr_region == 2'd0) begin
                bk_we[e_cur] = 1'b1; bk_waddr[e_cur] = db_wr_addr; bk_wdata[e_cur] = db_wr_data; bk_wbe[e_cur] = db_wr_be;
            end
            if (db_wr_en && db_wr_region == 2'd1) begin
                bk_we[e_left] = 1'b1; bk_waddr[e_left] = db_wr_addr; bk_wdata[e_left] = db_wr_data; bk_wbe[e_left] = db_wr_be;
            end
            bk_raddr[e_cur] = db_rd_addr; bk_raddr[e_left] = db_rd_addr;
        end else if (es != E_IDLE) begin
            bk_raddr[e_cur] = e_bk_raddr; bk_raddr[e_left] = e_bk_raddr;
        end
        // LM_DBK: the engine's alone
        dbk_raddr = e_dbk_raddr; dbk_we = e_dbk_we; dbk_waddr = e_dbk_waddr; dbk_wdata = e_dbk_wdata; dbk_wbe = 8'hFF;
        if (es == E_DB) begin
            dbk_raddr = {e_mbx, db_rd_addr[3:0]};
            dbk_we = db_wr_en && db_wr_region == 2'd2;
            dbk_waddr = {e_mbx, db_wr_addr[3:0]}; dbk_wdata = db_wr_data; dbk_wbe = db_wr_be;
        end
        // the deblocker's read data: by the region of the read the RAMs served
        db_rd_data = db_rd_is0 ? bk_q[e_cur] : db_rd_is1 ? bk_q[e_left] : dbk_q;
        // DDR3: the arbiter above
        if (grant_f) begin
            cmd_valid = fq_valid; cmd_write = fq_write;
            cmd_addr = (ms == M_INTER_WAIT) ? int_cmd_addr : f_cmd_addr;
            cmd_len = (ms == M_INTER_WAIT) ? int_cmd_len : f_cmd_len;
        end else begin
            cmd_valid = grant_e; cmd_write = 1'b1; cmd_addr = e_cmd_addr; cmd_len = e_cmd_len;
        end
        rd_ready = (ms == M_INTER_WAIT) ? int_rd_ready : f_rd_ready;
        if (w_owner) begin wd_valid = e_wd_valid && (w_left != 4'd0); wd_data = e_wd_data; wd_be = 8'hFF; end
        else         begin wd_valid = f_wd_valid && (w_left != 4'd0); wd_data = f_wd_data; wd_be = f_wd_be; end
    end
    assign dbg_pre_db = (ms == M_DB_GO) && !f_wd_valid && !e_busy;
    assign dbg_bank = fb;

    // the bank words read back (a read issued two edges ago): the front's, the engine's
    wire  [63:0] bq_cur = bk_q[fb];
    wire  [63:0] bq_e = e_rbank ? bk_q[e_left] : bk_q[e_cur];

    // ---- Intra_4x4 mode derivation (8.3.1.1) -------------------------------------------------
    // neighbour A (left) and B (above) of block i4
    logic [3:0] mode_a, mode_b;
    // the neighbour macroblock's mode of block row / column by4 / bx4 (a case: an index
    // times 97 into the 437-bit word synthesised as a ~200-LUT shifter per use)
    logic [3:0] nbl_mode, nba_mode;
    always_comb begin
        case (by4[3:2])
            2'd0: nbl_mode = nb_left[49 +: 4];
            2'd1: nbl_mode = nb_left[146 +: 4];
            2'd2: nbl_mode = nb_left[243 +: 4];
            default: nbl_mode = nb_left[340 +: 4];
        endcase
        case (bx4[3:2])
            2'd0: nba_mode = nb_above[49 +: 4];
            2'd1: nba_mode = nb_above[146 +: 4];
            2'd2: nba_mode = nb_above[243 +: 4];
            default: nba_mode = nb_above[340 +: 4];
        endcase
    end
    logic       dc_pred;
    always_comb begin
        logic [3:0] ax, ay, bxx, byy;
        logic       av_a, av_b, inter_a, inter_b;
        ax = bx4 - 4'd1; ay = by4;
        bxx = bx4; byy = by4 - 4'd1;
        if (bx4 != 4'd0) begin
            av_a = 1'b1; inter_a = 1'b0;
            mode_a = modes[{ay[3], ax[3], ay[2], ax[2]}];
        end else begin
            av_a = av_left; inter_a = !nb_left[16];
            mode_a = (nb_left[16] && nb_left[17]) ? nbl_mode : 4'd2;
        end
        if (by4 != 4'd0) begin
            av_b = 1'b1; inter_b = 1'b0;
            mode_b = modes[{byy[3], bxx[3], byy[2], bxx[2]}];
        end else begin
            av_b = av_above; inter_b = !nb_above[16];
            mode_b = (nb_above[16] && nb_above[17]) ? nba_mode : 4'd2;
        end
        dc_pred = !av_a || !av_b || (constrained_intra && (inter_a || inter_b));
    end
    wire [3:0] pred_i4 = dc_pred ? 4'd2 : ((mode_a < mode_b) ? mode_a : mode_b);
    logic [2:0] rem_i4;
    always_comb begin
        rem_i4 = 3'd0;
        for (int k = 0; k < 16; k++) if (i4 == k[3:0]) rem_i4 = mb_rem_mode[3*k +: 3];
    end
    logic [3:0] i4_pred_q;                 // M_I4_BLK's registered predIntra4x4PredMode

    // ---- the Intra_4x4 neighbour gather: sample s (0..7 top, 8..11 left, 12 corner) ----------
    // source: 0 = the bank (word, byte), 1 = a register value, 2 = unavailable, 3 = the row
    // above (LM_SAMP word {mbx, g_word[1:0]}, byte), 4 = the left column (its RAM, g_word[4:0])
    logic [2:0]  g_src;
    logic [5:0]  g_word;
    logic [2:0]  g_byte;
    logic [7:0]  g_val;
    logic [5:0]  g_idx;                    // intra_pred's neighbour index
    always_comb begin
        logic [3:0] cx, cy;
        logic       in_mb_up, in_mb_left;
        g_src = 3'd2; g_word = '0; g_byte = '0; g_val = '0; g_idx = '0;
        if (step < 6'd8) begin                               // top: p[k, -1], k = step
            g_idx = {3'd0, step[2:0]};
            cx = bx4 + {1'b0, step[2:0]};
            if (by4 != 4'd0) begin
                cy = by4 - 4'd1;
                if (step < 6'd4) begin
                    g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
                end else if (bx4 != 4'd12 && {cy[3], cx[3], cy[2], cx[2]} < i4) begin
                    g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];   // decoded earlier in this MB
                end
            end else begin
                if (step < 6'd4 || bx4 != 4'd12) begin
                    if (ia_above) begin g_src = 3'd3; g_word = {5'd0, cx[3]}; g_byte = cx[2:0]; end
                end else begin
                    if (ia_aright) begin g_src = 3'd1; g_val = upr_samp[step[1:0]]; end
                end
            end
        end else if (step < 6'd12) begin                     // left: p[-1, k]
            g_idx = 6'd16 + {4'd0, step[1:0]};
            cy = by4 + {2'd0, step[1:0]};
            if (bx4 != 4'd0) begin
                cx = bx4 - 4'd1;
                g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
            end else if (ia_left) begin
                g_src = 3'd4; g_word = {2'd0, cy};
            end
        end else begin                                       // the corner p[-1, -1]
            g_idx = 6'd32;
            cx = bx4 - 4'd1; cy = by4 - 4'd1;
            if (bx4 != 4'd0 && by4 != 4'd0) begin
                g_src = 3'd0; g_word = {1'b0, cy, cx[3]}; g_byte = cx[2:0];
            end else if (bx4 == 4'd0 && by4 != 4'd0) begin
                if (ia_left) begin g_src = 3'd4; g_word = {2'd0, cy}; end
            end else if (bx4 != 4'd0 && by4 == 4'd0) begin
                if (ia_above) begin g_src = 3'd3; g_word = {5'd0, cx[3]}; g_byte = cx[2:0]; end
            end else begin
                if (ia_aleft) begin g_src = 3'd1; g_val = corner[0]; end
            end
        end
    end
    // the neighbour issued this cycle by M_I4_NB (the gather above), M_I16_NB (step 0..15
    // the row above, 16..31 the left column, 32 the corner) or M_CI_NB (0..7, 8..15, 16):
    // one a cycle through the gather pipeline; an unavailable row / column goes as 0
    logic [2:0]  n_src;
    logic [5:0]  n_word, n_idx;
    logic [2:0]  n_byte;
    logic [7:0]  n_val;
    always_comb begin
        n_src = g_src; n_word = g_word; n_byte = g_byte; n_val = g_val; n_idx = g_idx;
        if (ms == M_I16_NB) begin
            n_idx = step; n_byte = step[2:0]; n_val = 8'd0;
            if (step < 6'd16)      begin n_src = ia_above ? 3'd3 : 3'd1; n_word = {5'd0, step[3]}; end
            else if (step < 6'd32) begin n_src = ia_left ? 3'd4 : 3'd1;  n_word = {2'd0, step[3:0]}; end
            else                   begin n_src = 3'd1; n_val = corner[0]; n_idx = 6'd32; end
        end else if (ms == M_CI_NB) begin
            n_byte = step[2:0]; n_val = 8'd0;
            if (step < 6'd8)       begin n_src = ia_above ? 3'd3 : 3'd1; n_word = {4'd0, 1'b1, cplane[0]}; n_idx = step; end
            else if (step < 6'd16) begin n_src = ia_left ? 3'd4 : 3'd1;  n_word = {1'b0, 1'b1, cplane[0], step[2:0]}; n_idx = 6'd16 + {3'd0, step[2:0]}; end
            else                   begin n_src = 3'd1; n_val = corner[1 + cplane[0]]; n_idx = 6'd32; end
        end
    end
    // availability of the top 4, the top-right 4, the left 4 of block i4
    wire top_av  = (by4 != 4'd0) ? 1'b1 : ia_above;
    wire left_av = (bx4 != 4'd0) ? 1'b1 : ia_left;
    logic tr_av;
    always_comb begin
        logic [3:0] cx, cy;
        cx = bx4 + 4'd4; cy = by4 - 4'd1;
        if (by4 != 4'd0) tr_av = (bx4 != 4'd12) && ({cy[3], cx[3], cy[2], cx[2]} < i4);
        else tr_av = (bx4 != 4'd12) ? ia_above : ia_aright;
    end
    logic [7:0] top3;                      // p[3, -1] for the substitution (8.3.1.2)

    // gather pipeline: a bank read's tag travels two stages
    // (every neighbour travels it, register-sourced ones too, so exactly one lands per cycle)
    logic       gt1_v, gt2_v;
    logic [5:0] gt1_idx, gt2_idx;
    logic [2:0] gt1_byte, gt2_byte;
    logic [1:0] gt1_src, gt2_src;          // 0 a bank byte, 1 gtN_val, 2 an LM_SAMP byte, 3 the left RAM
    logic [7:0] gt1_val, gt2_val;
    logic [7:0] gt2_nb;                    // the neighbour landing at gt2
    always_comb begin
        case (gt2_src)
            2'd0:    gt2_nb = bq_cur[8*gt2_byte +: 8];
            2'd1:    gt2_nb = gt2_val;
            2'd2:    gt2_nb = smp_q[8*gt2_byte +: 8];
            default: gt2_nb = ls_q;
        endcase
    end
    // the left column's RAM: written by M_SAVE (cnt 6..37: byte 7 of the right-column words)
    always_comb begin
        ls_we = (ms == M_SAVE) && (cnt >= 9'd6) && (cnt < 9'd38);
        ls_wa = cnt[4:0] - 5'd6;
        ls_wd = bq_cur[63:56];
    end

    // ---- the residual walk -----------------------------------------------------------------------
    logic [2:0]  r_kind;
    logic [4:0]  r_slot;
    logic [4:0]  r_n;                      // coefficients to stream
    logic [4:0]  r_pos;                    // next coefficient address
    logic        r_rq1, r_rq2;             // a coefficient read in flight (address -> data two edges)
    // the coefficient queue in front of dequant_itrans: reads issue one a cycle while
    // queued + in flight < 4, so the transform takes a coefficient every cycle (it waited
    // out each read before: ~4 cycles a coefficient, docs/h264_recon.md S6)
    logic signed [15:0] cq [0:3];
    logic [1:0]  cq_h, cq_t;
    logic [2:0]  cq_n;
    logic        r_zpush;                  // an uncoded block's zero joins the queue this cycle
    wire         cq_push = r_rq2 || r_zpush;
    wire         cq_out_free = !dq_coef_valid || dq_coef_ready;
    wire         cq_pop = cq_out_free && (cq_n != 3'd0);
    wire  [2:0]  cq_used = cq_n + {2'd0, r_rq1} + {2'd0, r_rq2} + {2'd0, r_zpush};
    logic [1:0]  r_plane;                  // 0 Y, 1 Cb, 2 Cr (where the block lands)
    logic [3:0]  r_x, r_y;                 // the block's top-left sample in its plane
    logic [4:0]  r_ret;                    // where to go after the block (encoded)
    logic        r_coded;
    logic [2:0]  add_row;
    logic        add_pend;                 // (unused since the pipelined add)
    logic        a_v;                      // the residual add's summed row, written next cycle
    logic [5:0]  a_w;
    logic [63:0] a_nw;
    logic [7:0]  a_be;

    // chroma walk: c (0 Cb, 1 Cr), b (0..3)
    logic        cw_c;
    logic [2:0]  cw_b;                     // 4 = the DC stage

    // mv_pred's read-back one cycle late: the reference codes come from recon_slice_tab's
    // RAMs, addressed with the block's refIdx (M_MV_READ: block cnt - 1 on mv_pred's outputs,
    // its codes and these registers at cnt; written at cnt, block cnt - 2)
    assign code_ra0 = mvp_ref0;
    assign code_ra1 = mvp_ref1;
    logic        d_pred0, d_pred1;
    logic [4:0]  d_ref0, d_ref1;
    logic [15:0] d_mvx0, d_mvy0, d_mvx1, d_mvy1;
    always_ff @(posedge clk) begin
        d_pred0 <= mvp_pred0; d_ref0 <= mvp_ref0; d_mvx0 <= mvp_mvx0; d_mvy0 <= mvp_mvy0;
        d_pred1 <= mvp_pred1; d_ref1 <= mvp_ref1; d_mvx1 <= mvp_mvx1; d_mvy1 <= mvp_mvy1;
    end
    wire  [7:0]  d_code0 = d_pred0 ? code_q0 : 8'd0;
    wire  [7:0]  d_code1 = d_pred1 ? code_q1 : 8'd0;
    // the deblocker's block records (see recon_mb.sv, recon_deblock's rec_* port)
    always_comb begin
        rec_we = (ms == M_MV_READ) && (cnt >= 9'd2);
        rec_wa = cnt[3:0] - 4'd2;
        rec_wd = {d_mvy1, d_mvx1, d_code1, d_pred1, d_mvy0, d_mvx0, d_code0, d_pred0, mb_nz[rec_wa]};
    end

    // ---- the co-located fetch -----------------------------------------------------------------------
    logic [63:0] colbuf [0:31];
    logic        col_we;
    logic [4:0]  col_wa;
    logic [63:0] col_wd;
    logic [5:0]  col_i;                    // words received
    logic [2:0]  col_bursts;               // bursts issued
    logic        col_two;                  // two co-located macroblocks (Frm_To_Fld)
    wire  [28:0] col_base_w = dpb_base + {7'd0, col_store, 17'd0} + off_side;
    // the co-located macroblock address(es) (Table 8-8, non-MBAFF)
    logic [20:0] col_mb0, col_mb1;
    always_comb begin
        logic [7:0] row0;
        case (vert_scale)
            2'd1: row0 = {mby, 1'b0};                        // Frm_To_Fld: frame rows 2y, 2y + 1
            2'd2: row0 = {2'b0, mby[6:1]};                   // Fld_To_Frm: field row y / 2
            default: row0 = {1'b0, mby};
        endcase
        col_mb0 = {13'd0, row0} * {13'd0, width_mbs} + {14'd0, mbx};
        col_mb1 = col_mb0 + {13'd0, width_mbs};
        if (col_half == 2'd2) begin col_mb0 = col_mb0 + half_mbs; col_mb1 = col_mb1 + half_mbs; end
    end

    // the co-located entry of block col_ra (8.4.1.2.1): (xCol, yCol) = the block's corner,
    // yM per Table 8-8, read from the co-located buffer (a RAM: 2,048 registers and sixteen
    // 32:1 x 64-bit muxes as registers, docs/h264_recon.md S6.1)
    logic [4:0]  col_addr;
    logic [63:0] col_w;
    always_comb begin
        logic [3:0] xc, yc, ym;
        logic [4:0] src;
        xc = {col_ra[2], col_ra[0], 2'b00}; yc = {col_ra[3], col_ra[1], 2'b00};
        case (vert_scale)
            2'd1: begin ym = {yc[2:0], 1'b0}; src = {yc[3], 4'd0}; end                   // (2 yCol) % 16
            2'd2: begin ym = {mby[0], yc[3], 2'b00}; src = 5'd0; end                     // 8 (y % 2) + 4 (yCol / 8)
            default: begin ym = yc; src = 5'd0; end
        endcase
        col_addr = src + {1'b0, ym[3], xc[3], ym[2], xc[2]};
    end
    always_ff @(posedge clk) begin
        if (col_we) colbuf[col_wa] <= col_wd;
        col_w <= colbuf[col_addr];
    end
    // side word: [15:0] mvy [31:16] mvx [39:32] code [44:40] refIdx [45] pred [46] intra
    assign col_q = {2'b00, col_w[46], col_w[39:32], col_w[44:40], col_w[15:0], col_w[31:16]};

    // ---- the writeback plan ----------------------------------------------------------------------
    // items: 0 = the above MB's pending rows (from LM_DBK), 1 = the left MB (prev bank),
    // 2 = this MB at the right edge (current bank); each row: luma 2 words, chroma 1
    logic [1:0]  wb_item;
    logic [4:0]  wb_row;                   // luma rows then Cb then Cr (0..15 / 16..23 / 24..31)
    logic [4:0]  wb_row_end;
    logic        wb_w;                     // the word within a luma row
    logic        wb_rd_v1, wb_rd_v2;
    wire         e_last_row = (e_mby == pic_h_mbs[6:0] - 7'd1);   // the engine's macroblock
    // the DDR address of a row of macroblock column x0 at picture row pr (plane p)
    logic [6:0]  wb_x;
    logic [10:0] wb_prow;                  // the picture row within its plane
    logic [1:0]  wb_plane;
    wire  [11:0] wb_srow = field_pic ? {wb_prow, bottom} : {1'b0, wb_prow};
    // two register steps (M_WB_ADDR, M_WB_ADDR2): the row product, then the sums (the product
    // and the adds in the command cycle missed clk_dec)
    // (the plane bases are per-picture constants, registered: cur_base + the plane offset +
    // the product + the column in one cycle was 10.3 ns -- the clk_dec wall, from the H264
    // fork)
    logic [28:0] wb_prod_q, wb_addr_q;
    logic [28:0] pbase_y, pbase_cb, pbase_cr;
    always_ff @(posedge clk) begin
        pbase_y <= cur_base; pbase_cb <= cur_base + off_cb; pbase_cr <= cur_base + off_cr;
        wb_prod_q <= (wb_plane == 2'd0) ? {17'd0, wb_srow} * {21'd0, width_mbs, 1'b0} : {17'd0, wb_srow} * {21'd0, width_mbs};
        wb_addr_q <= ((wb_plane == 2'd0) ? pbase_y : (wb_plane == 2'd1) ? pbase_cb : pbase_cr) + wb_prod_q
                   + ((wb_plane == 2'd0) ? {21'd0, wb_x, 1'b0} : {22'd0, wb_x});
    end

    // ---- the motion RAM's port ---------------------------------------------------------------
    // writes: mv_pred's read-back, a cycle late with the codes (block cnt - 2, above)
    always_comb begin
        mot_we = (ms == M_MV_READ) && (cnt >= 9'd2);
        mot_wa = cnt[3:0] - 4'd2;
        mot_wd = {d_mvy1, d_mvx1, d_code1, d_ref1, d_pred1, d_mvy0, d_mvx0, d_code0, d_ref0, d_pred0};
    end
    // the record read (an intra macroblock's motion is all zeros)
    wire  [91:0] mot_qm = cur_intra ? 92'd0 : mot_q;
    // the end walk, after the deblocker (the last reader of nb_above = LM_INFO[mbx] and of
    // nb_left): nl_k 0..3 read the bottom row (blocks 10, 11, 14, 15) into LM_INFO[mbx]
    // (landing at 1..4, the header at 0), 4..7 the right column (5, 7, 13, 15) into nb_left
    // (landing at 5..8)
    logic        nl_run;
    logic [3:0]  nl_k;
    // reads: recon_inter while it runs; the side words (the block the next data cycle
    // sends); the end walk
    wire        sd_adv = (ms == M_SAVE_SIDE_DATA) && (!f_wd_valid || f_wd_rdy);
    always_comb begin
        if (ms == M_INTER_WAIT) mot_ra = int_mot_ra;
        else if (ms == M_SAVE_SIDE_CMD || ms == M_SAVE_SIDE_DATA) mot_ra = sd_adv ? cnt[3:0] + 4'd1 : cnt[3:0];
        else if (!nl_k[2]) mot_ra = (nl_k[1:0] == 2'd0) ? 4'd10 : (nl_k[1:0] == 2'd1) ? 4'd11 : (nl_k[1:0] == 2'd2) ? 4'd14 : 4'd15;
        else mot_ra = (nl_k[1:0] == 2'd0) ? 4'd5 : (nl_k[1:0] == 2'd1) ? 4'd7 : (nl_k[1:0] == 2'd2) ? 4'd13 : 4'd15;
    end
    // LM_INFO's writes (the end walk): the header, the bottom blocks as they are read
    always_comb begin
        logic [3:0] bb;
        inf_we = nl_run && (nl_k == 4'd0); inf_waddr = mbx;
        inf_wdata = {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, cur_pcm, cur_i4, cur_intra, slice_id};
        ib_we = nl_run && (nl_k >= 4'd1) && (nl_k <= 4'd4);
        ib_j = nl_k[1:0] - 2'd1; ib_wa = mbx;
        bb = (ib_j == 2'd0) ? 4'd10 : (ib_j == 2'd1) ? 4'd11 : (ib_j == 2'd2) ? 4'd14 : 4'd15;
        ib_wd = {mot_qm, mb_nz[bb], modes[bb]};
    end
    // the side word of the block read: the list-0 vector when predFlagL0, else list 1's (8.4.1.2.1)
    logic [63:0] side_w;
    always_comb begin
        if (cur_intra) side_w = {17'd0, 1'b1, 46'd0};
        else if (mot_q[0]) side_w = {17'd0, 1'b0, 1'b1, mot_q[5:1], mot_q[13:6], mot_q[29:14], mot_q[45:30]};
        else side_w = {17'd0, 1'b0, 1'b1, mot_q[51:47], mot_q[59:52], mot_q[75:60], mot_q[91:76]};
    end
    wire  [28:0] side_addr_w = cur_base + off_side
                           + {4'd0, ((cur_struct == 2'd2) ? half_mbs : 21'd0) + {7'd0, mb_addr}, 4'd0};
    // registered (their inputs hold for the whole macroblock; the product and adds in the
    // command cycle missed clk_dec): the co-located side words' and this macroblock's
    // (stages: the product, the second row's +W, the sums; >= 8 cycles pass between the
    // macroblock's position change and M_COL_CMD)
    logic [28:0] col_base, col_a0, col_a1, side_addr;
    logic [20:0] col_mb0_q, col_mb1_q;
    always_ff @(posedge clk) begin
        col_base <= col_base_w;
        col_mb0_q <= col_mb0; col_mb1_q <= col_mb0_q + {13'd0, width_mbs};   // (col_mb1 = col_mb0 + W)
        col_a0 <= col_base + {4'd0, col_mb0_q, 4'd0};
        col_a1 <= col_base + {4'd0, col_mb1_q, 4'd0};
        side_addr <= side_addr_w;
    end

    // ---- divisions of the macroblock address by the width -----------------------------------
    logic [13:0] div_rem;
    logic [6:0]  div_q;
    logic [13:0] last_addr;
    logic        last_valid;
    logic        rel_pending;              // a released descriptor not yet dropped by the intake

    // =====================================================================================
    // the sequential part
    // =====================================================================================
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ms <= M_IDLE; fb <= 2'd0; fb_prev <= 2'd2; mbx <= '0; mby <= '0; slice_id <= '0; qp <= '0; qp_pred <= '0;
            qpc0 <= '0; qpc1 <= '0; pcm_qpc0 <= '0; pcm_qpc1 <= '0; cur_intra <= 1'b0; cur_i4 <= 1'b0; cur_pcm <= 1'b0;
            key0 <= '0; keyq <= '0; all16 <= 1'b0; all8 <= '0;
            nb_aright <= '0; nb_aleft <= '0; nb_left <= '0; prev_above <= '0;
            av_above <= 1'b0; av_aright <= 1'b0; av_aleft <= 1'b0; av_left <= 1'b0;
            for (int i = 0; i < 4; i++) upr_samp[i] <= '0;
            for (int i = 0; i < 3; i++) begin corner[i] <= '0; next_corner[i] <= '0; end
            for (int b = 0; b < 16; b++) begin
                modes[b] <= 4'd2;
            end
            nl_run <= 1'b0; nl_k <= '0;
            col_we <= 1'b0; col_wa <= '0; col_wd <= '0;
            mb_release <= 1'b0; mb_done <= 1'b0; mb_done_addr <= '0; mb_count <= '0; err_count <= '0; err_code <= '0;
            f_idle <= 1'b1;
            mvp_start <= 1'b0; mvp_blk <= '0; int_start <= 1'b0; ip_nb_we <= 1'b0; ip_nb_idx <= '0; ip_nb_val <= '0;
            ip_start <= 1'b0; ip_kind <= '0; ip_mode <= '0; ip_av_top <= 1'b0; ip_av_left <= 1'b0;
            r_go <= 1'b0; f_rid <= '0; res_raddr <= '0;
            db_start <= 1'b0; db_left_en <= 1'b0; db_top_en <= 1'b0; db_int_en <= 1'b0;
            f_bk_we <= 1'b0; f_bk_waddr <= '0; f_bk_raddr <= '0; f_bk_rbank <= 1'b0;
            f_bk_wdata <= '0; f_bk_wbe <= '0; f_cmd_valid <= 1'b0; f_cmd_write <= 1'b0; f_cmd_addr <= '0; f_cmd_len <= 4'd1;
            f_rd_ready <= 1'b0;
            db_rd_is0 <= 1'b0; db_rd_is1 <= 1'b0;
            f_wd_valid <= 1'b0; f_wd_data <= '0; f_wd_be <= 8'hFF; e_go <= 1'b0;
            inf_raddr <= '0;
            smp_we <= 1'b0; smp_waddr <= '0; smp_raddr <= '0; smp_wdata <= '0; f_coef_addr <= '0;
            cnt <= '0; step <= '0; rblk <= '0; rphase <= '0; i4 <= '0; i4_mode <= '0; rd_pend <= '0;
            cplane <= '0; after_pred <= 1'b0; top3 <= '0;
            gt1_v <= 1'b0; gt2_v <= 1'b0; gt1_idx <= '0; gt2_idx <= '0; gt1_byte <= '0; gt2_byte <= '0;
            gt1_src <= 2'd0; gt2_src <= 2'd0; gt1_val <= '0; gt2_val <= '0; ls_raddr <= '0;
            r_plane <= '0; r_x <= '0; r_y <= '0; r_ret <= '0; add_row <= '0; add_pend <= 1'b0; a_v <= 1'b0; a_w <= '0; a_nw <= '0; a_be <= '0;
            cw_c <= 1'b0; cw_b <= '0; col_i <= '0; col_bursts <= '0; col_two <= 1'b0;
            div_rem <= '0; div_q <= '0; last_addr <= '0; last_valid <= 1'b0; rel_pending <= 1'b0;
        end else begin
            // pulses
            col_we <= 1'b0; mb_release <= 1'b0; mb_done <= 1'b0; mvp_start <= 1'b0; int_start <= 1'b0; ip_nb_we <= 1'b0;
            ip_start <= 1'b0; r_go <= 1'b0; db_start <= 1'b0; f_bk_we <= 1'b0; e_go <= 1'b0;
            smp_we <= 1'b0; a_v <= 1'b0;
            // the residual add's registered row (M_RES_ADD_RD)
            if (a_v) begin f_bk_we <= 1'b1; f_bk_waddr <= a_w; f_bk_wdata <= a_nw; f_bk_wbe <= a_be; end
            db_rd_is0 <= (db_rd_region == 2'd0); db_rd_is1 <= (db_rd_region == 2'd1);
            if (f_cmd_valid && f_cmd_rdy && ms != M_INTER_WAIT) f_cmd_valid <= 1'b0;
            if (f_wd_valid && f_wd_rdy) f_wd_valid <= 1'b0;
            if (mvp_err || int_err) begin err_count <= err_count + 1'b1; err_code <= mvp_err ? 4'd1 : 4'd2; end
            // the end walk (the writeback states leave the motion port to it): the right
            // column's motion lands in nb_left at nl_k 5..8
            if (nl_run) begin
                case (nl_k)
                    4'd5: nb_left[54 +: 92] <= mot_qm;
                    4'd6: nb_left[151 +: 92] <= mot_qm;
                    4'd7: nb_left[248 +: 92] <= mot_qm;
                    4'd8: nb_left[345 +: 92] <= mot_qm;
                    default: ;
                endcase
                if (nl_k == 4'd8) nl_run <= 1'b0;
                nl_k <= nl_k + 1'b1;
            end
            // the gather pipeline (intra neighbours from the bank)
            gt2_v <= gt1_v; gt2_idx <= gt1_idx; gt2_byte <= gt1_byte; gt2_src <= gt1_src; gt2_val <= gt1_val;
            gt1_v <= 1'b0;
            if (gt2_v) begin
                ip_nb_we <= 1'b1; ip_nb_idx <= gt2_idx;
                ip_nb_val <= gt2_nb;
                if (gt2_idx == 6'd3) top3 <= gt2_nb;
            end
            // a neighbour issued (the three states' selection above): the read addressed now,
            // its data two edges later at gt2
            if ((ms == M_I4_NB && step <= 6'd12) || (ms == M_I16_NB && step <= 6'd32) || (ms == M_CI_NB && step <= 6'd16)) begin
                gt1_idx <= n_idx; gt1_byte <= n_byte; gt1_val <= n_val;
                case (n_src)
                    3'd0: begin f_bk_raddr <= n_word; f_bk_rbank <= 1'b0; gt1_v <= 1'b1; gt1_src <= 2'd0; end
                    3'd1: begin gt1_v <= 1'b1; gt1_src <= 2'd1; end
                    3'd3: begin smp_raddr <= {mbx, n_word[1:0]}; gt1_v <= 1'b1; gt1_src <= 2'd2; end
                    3'd4: begin ls_raddr <= n_word[4:0]; gt1_v <= 1'b1; gt1_src <= 2'd3; end
                    default: ;                                        // unavailable: nothing
                endcase
            end

            if (clear) begin
                ms <= M_IDLE; f_idle <= 1'b1; last_valid <= 1'b0;
            end else case (ms)
                // ---------------------------------------------------------------------------
                M_IDLE: begin
                    f_idle <= !mb_valid || rel_pending;
                    if (rel_pending) begin
                        // the released descriptor stays valid for one more cycle (mb_intake)
                        if (!mb_valid) rel_pending <= 1'b0;
                    end else if (slice_go) begin
                        qp_pred <= slice_qp;
                        slice_id <= slice_id + 1'b1;
                    end else if (mb_valid) begin
                        f_idle <= 1'b0;
                        if (last_valid && mb_addr == last_addr + 14'd1) begin
                            if ({1'b0, mbx} == width_mbs - 8'd1) begin mbx <= '0; mby <= mby + 1'b1; end
                            else mbx <= mbx + 1'b1;
                            ms <= M_LOAD0;
                        end else begin
                            div_rem <= mb_addr; div_q <= '0;
                            ms <= M_DIV;
                        end
                        last_addr <= mb_addr; last_valid <= 1'b1;
                    end
                end
                M_DIV: begin                                     // mb_addr / PicWidthInMbs
                    if (div_rem >= {6'd0, width_mbs}) begin div_rem <= div_rem - {6'd0, width_mbs}; div_q <= div_q + 1'b1; end
                    else begin mbx <= div_rem[6:0]; mby <= div_q; ms <= M_LOAD0; end
                end
                // ---- the neighbours ----------------------------------------------------------
                // LM_INFO: the above-right macroblock first, then the above one, whose word the
                // RAM's output then holds for the whole macroblock (nb_above: nothing else reads
                // LM_INFO, and this macroblock's own write waits for the end walk)
                M_LOAD0: begin inf_raddr <= mbx + 7'd1; smp_raddr <= {mbx, 2'd0}; ms <= M_LOAD1; end
                M_LOAD1: begin inf_raddr <= mbx; smp_raddr <= {mbx, 2'd1}; ms <= M_LOAD2; end
                M_LOAD2: begin
                    nb_aright <= {inf_q[49 +: 97], inf_q[16], inf_q[15:0]};
                    for (int i = 0; i < 3; i++) corner[i] <= next_corner[i];   // the previous row-above's last samples
                    smp_raddr <= {mbx, 2'd2}; ms <= M_LOAD3;
                end
                M_LOAD3: begin
                    next_corner[0] <= smp_q[63:56];              // (the row above is read in place)
                    smp_raddr <= {mbx, 2'd3}; ms <= M_LOAD4;
                end
                M_LOAD4: begin
                    next_corner[1] <= smp_q[63:56];
                    smp_raddr <= {mbx + 7'd1, 2'd0}; ms <= M_LOAD5;
                end
                M_LOAD5: begin
                    next_corner[2] <= smp_q[63:56];
                    ms <= M_LOAD6;
                end
                M_LOAD6: begin
                    for (int i = 0; i < 4; i++) upr_samp[i] <= smp_q[8*i +: 8];
                    av_above <= (mby != 7'd0) && (nb_above[15:0] == slice_id);
                    av_aright <= (mby != 7'd0) && ({1'b0, mbx} != width_mbs - 8'd1) && (nb_aright[15:0] == slice_id);
                    av_aleft <= (mby != 7'd0) && (mbx != 7'd0) && (prev_above[15:0] == slice_id);
                    av_left <= (mbx != 7'd0) && (nb_left[15:0] == slice_id);
                    nb_aleft <= prev_above; prev_above <= {nb_above[49 + 97*3 +: 97], nb_above[16], nb_above[15:0]};
                    ms <= M_QP;
                end
                // ---- QP and the branch --------------------------------------------------------
                M_QP: begin
                    qp <= qp_new; qp_pred <= qp_new;
                    qpc0 <= qpc_n0; qpc1 <= qpc_n1;
                    pcm_qpc0 <= qpc_p0; pcm_qpc1 <= qpc_p1;
                    cur_intra <= mb_is_intra && !mb_skip; cur_pcm <= mb_pcm;
                    cur_i4 <= mb_is_intra && !mb_skip && mb_itype == 5'd0;
                    for (int b = 0; b < 16; b++) modes[b] <= 4'd2;
                    cnt <= '0; step <= '0; i4 <= '0;
                    r_go <= !mb_pcm;                  // the residual engine walks this macroblock
                    if (mb_pcm) ms <= M_PCM;
                    else if (mb_is_intra && !mb_skip) begin
                        if (mb_itype == 5'd0) begin step <= '0; ms <= M_I4_BLK; end else ms <= M_I16_NB;
                    end
                    else if (slice_type == 2'd1 && mb_direct8 != 4'd0) begin col_i <= '0; col_bursts <= '0; ms <= M_COL_CMD; end
                    else ms <= M_MV_GO;
                end
                // ---- I_PCM: 384 samples, word = sample >> 3, byte = sample & 7 ---------------------
                M_PCM: begin
                    // the address of sample cnt now; its byte arrives two edges later
                    if (cnt < 9'd384) f_coef_addr <= cnt;
                    if (cnt >= 9'd2) begin
                        logic [8:0] sidx;
                        sidx = cnt - 9'd2;
                        f_bk_we <= 1'b1; f_bk_waddr <= sidx[8:3];
                        f_bk_wdata <= {8{coef_data[7:0]}}; f_bk_wbe <= 8'd1 << sidx[2:0];
                    end
                    if (cnt == 9'd385) begin cnt <= '0; ms <= M_SAVE; end
                    else cnt <= cnt + 1'b1;
                end
                // ---- Intra_4x4 ------------------------------------------------------------------------
                M_I4_BLK: begin
                    // two cycles: the predicted mode registered (the neighbour selection and
                    // the min in one cycle with the write missed clk_dec), then 8-13's rule
                    if (step == 6'd0) begin i4_pred_q <= pred_i4; step <= 6'd1; end
                    else begin
                        logic [3:0] m;
                        m = mb_prev_flag[i4] ? i4_pred_q : (({1'b0, rem_i4} < i4_pred_q) ? {1'b0, rem_i4} : {1'b0, rem_i4} + 4'd1);
                        i4_mode <= m; modes[i4] <= m;
                        step <= '0; ms <= M_I4_NB;
                    end
                end
                M_I4_NB: begin
                    // one neighbour per cycle: bank reads through the gather pipeline, the rest now
                    if (step <= 6'd12) step <= step + 1'b1;      // (issued above)
                    else if (!gt1_v && !gt2_v) begin
                        step <= '0; ms <= M_I4_NBW;
                    end
                end
                M_I4_NBW: begin
                    // the top-right substitution: p[4..7, -1] = p[3, -1] when unavailable
                    if (!tr_av && top_av) begin
                        if (step < 6'd4) begin
                            ip_nb_we <= 1'b1; ip_nb_idx <= 6'd4 + step; ip_nb_val <= top3; step <= step + 1'b1;
                        end else begin step <= '0; ms <= M_I4_GO; end
                    end else ms <= M_I4_GO;
                end
                M_I4_GO: begin
                    ip_start <= 1'b1; ip_kind <= 2'd0; ip_mode <= i4_mode; ip_av_top <= top_av; ip_av_left <= left_av;
                    cnt <= '0; ms <= M_I4_PRED;
                end
                M_I4_PRED: begin
                    if (ip_valid) begin
                        logic [3:0] px, py;
                        px = bx4 + {2'd0, cnt[1:0]}; py = by4 + {2'd0, cnt[3:2]};
                        f_bk_we <= 1'b1; f_bk_waddr <= {1'b0, py, px[3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << px[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            // this block's residual (the engine's), then the next block (r_ret 1)
                            r_plane <= 2'd0; r_x <= bx4; r_y <= by4; r_ret <= 5'd1; f_rid <= {1'b0, i4};
                            ms <= M_RES_NEXT;
                        end
                    end
                end
                // ---- Intra_16x16 ---------------------------------------------------------------------
                M_I16_NB: begin
                    // 33 neighbours through the gather pipeline: top 0..15, left 16..31, corner 32
                    if (step <= 6'd32) step <= step + 1'b1;
                    else if (!gt1_v && !gt2_v) begin step <= '0; ms <= M_I16_GO; end
                end
                M_I16_GO: begin
                    logic [4:0] t;
                    t = mb_itype - 5'd1;
                    ip_start <= 1'b1; ip_kind <= 2'd1; ip_mode <= {2'b00, t[1:0]};   // Intra16x16PredMode = t % 4
                    ip_av_top <= ia_above; ip_av_left <= ia_left;
                    cnt <= '0; ms <= M_I16_PRED;
                end
                M_I16_PRED: begin
                    if (ip_valid) begin
                        f_bk_we <= 1'b1; f_bk_waddr <= {1'b0, cnt[7:4], cnt[3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << cnt[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            // the luma blocks (the engine did the DC transform first)
                            rblk <= '0; ms <= M_RES_LUMA;
                        end
                    end
                end
                // ---- intra chroma ---------------------------------------------------------------------
                M_CI_NB: begin
                    // 17 neighbours through the gather pipeline: top 0..7, left 16..23, corner 32
                    if (step <= 6'd16) step <= step + 1'b1;
                    else if (!gt1_v && !gt2_v) begin step <= '0; ms <= M_CI_GO; end
                end
                M_CI_GO: begin
                    ip_start <= 1'b1; ip_kind <= 2'd2; ip_mode <= {2'b00, mb_chroma_mode};
                    ip_av_top <= ia_above; ip_av_left <= ia_left;
                    cnt <= '0; ms <= M_CI_PRED;
                end
                M_CI_PRED: begin
                    if (ip_valid) begin
                        f_bk_we <= 1'b1;
                        f_bk_waddr <= (cplane[0] ? 6'd40 : 6'd32) + {3'd0, cnt[5:3]};
                        f_bk_wdata <= {8{ip_pred}}; f_bk_wbe <= 8'd1 << cnt[2:0];
                        cnt <= cnt + 1'b1;
                        if (ip_last) begin
                            if (!cplane[0]) begin cplane <= 2'd1; step <= '0; ms <= M_CI_NB; end
                            else begin cw_c <= 1'b0; cw_b <= 3'd0; ms <= M_RES_CHROMA; end
                        end
                    end
                end
                // ---- inter: the co-located side info, mv_pred, recon_inter -------------------------
                M_COL_CMD: begin
                    // bursts of 8 words: macroblock 0 (two bursts), then macroblock 1 for Frm_To_Fld
                    if (!f_cmd_valid) begin
                        f_cmd_valid <= 1'b1; f_cmd_write <= 1'b0; f_cmd_len <= 4'd8;
                        f_cmd_addr <= (col_bursts[1] ? col_a1 : col_a0) + {25'd0, col_bursts[0], 3'd0};
                        col_bursts <= col_bursts + 1'b1;
                        if (col_bursts == ((vert_scale == 2'd1) ? 3'd3 : 3'd1)) begin f_rd_ready <= 1'b1; ms <= M_COL_DATA; end
                    end
                end
                M_COL_DATA: begin
                    if (rd_valid && f_rd_ready) begin
                        col_we <= 1'b1; col_wa <= col_i[4:0]; col_wd <= rd_data;
                        col_i <= col_i + 1'b1;
                        if (col_i == ((vert_scale == 2'd1) ? 6'd31 : 6'd15)) begin f_rd_ready <= 1'b0; ms <= M_MV_GO; end
                    end
                end
                M_MV_GO: begin mvp_start <= 1'b1; ms <= M_MV_WAIT; end
                M_MV_WAIT: if (mvp_done) begin mvp_blk <= 4'd0; cnt <= '0; ms <= M_MV_READ; end
                M_MV_READ: begin
                    // out_blk is a registered read: block cnt - 1's words are on the outputs now
                    if (cnt != 9'd0 && cnt <= 9'd16) begin
                        logic [3:0] b;
                        b = cnt[3:0] - 4'd1;
                        // (the motion RAM is written from the same words a cycle later: mot_we)
                        // recon_inter's uniformity tests, one block at a time (a 16-way compare
                        // of 76-bit keys cost ~840 LUTs): every block alike, each 8x8 alike
                        if (b == 4'd0) begin key0 <= rd_key; all16 <= 1'b1; end
                        else if (rd_key != key0) all16 <= 1'b0;
                        if (b[1:0] == 2'd0) begin keyq <= rd_key; all8[b[3:2]] <= 1'b1; end
                        else if (rd_key != keyq) all8[b[3:2]] <= 1'b0;
                    end
                    if (cnt == 9'd17) ms <= M_INTER_GO;      // block 15 written a cycle late
                    else begin mvp_blk <= cnt[3:0] + 4'd1; end
                    cnt <= cnt + 1'b1;
                end
                M_INTER_GO: begin int_start <= 1'b1; ms <= M_INTER_WAIT; end
                M_INTER_WAIT: if (int_done) begin
                    // the luma residual: block 0 of 16 (r_ret 3), then chroma
                    rblk <= '0; ms <= M_RES_LUMA;
                end
                // ---- the luma residual walk (inter, and Intra_16x16's AC) ----------------------------
                M_RES_LUMA: begin
                    if (rblk == 5'd16) begin
                        cw_c <= 1'b0; cw_b <= 3'd0;
                        if (cur_intra) begin cplane <= 2'd0; step <= '0; ms <= M_CI_NB; end   // chroma prediction first
                        else ms <= M_RES_CHROMA;
                    end else begin
                        logic [3:0] b;
                        b = rblk[3:0];
                        r_plane <= 2'd0; r_x <= {b[2], b[0], 2'b00}; r_y <= {b[3], b[1], 2'b00};
                        f_rid <= {1'b0, b}; r_ret <= 5'd3;
                        ms <= M_RES_NEXT;
                    end
                end
                // ---- the chroma residual adds: Cb AC 0..3, then Cr (the engine did each DC first) --------
                M_RES_CHROMA: begin
                    r_plane <= cw_c ? 2'd2 : 2'd1; r_x <= {1'b0, cw_b[0], 2'b00}; r_y <= {1'b0, cw_b[1], 2'b00};
                    f_rid <= 5'd16 + {2'd0, cw_c, cw_b[1:0]}; r_ret <= 5'd5;
                    ms <= M_RES_NEXT;
                end
                // ---- wait for the engine's block (f_rid): add it, or nothing for an all-zero one -------
                M_RES_NEXT: if (res_rdy[f_rid]) begin
                    if (res_zero[f_rid]) ms <= M_RES_RET;
                    else begin add_row <= '0; add_pend <= 1'b0; ms <= M_RES_ADD_RD; end
                end
                // ---- add the residual to the prediction in the bank, row by row ---------------------------
                M_RES_ADD_RD: begin
                    // pipelined over the four rows: add_row 0..3 addresses row add_row, 2..5 has
                    // row add_row - 2's word landed: the sum registered (a_*), written the cycle
                    // after (a 3-cycle row loop with the add and clip in the write cycle missed
                    // clk_dec)
                    logic [5:0] w;
                    logic [3:0] yy;
                    logic [2:0] ar;
                    yy = r_y + {1'b0, add_row};
                    w = (r_plane == 2'd0) ? {1'b0, yy, r_x[3]} : ((r_plane == 2'd1) ? 6'd32 : 6'd40) + {3'd0, yy[2:0]};
                    if (add_row < 3'd4) begin f_bk_raddr <= w; f_bk_rbank <= 1'b0; res_raddr <= {f_rid, add_row[1:0]}; end
                    if (add_row >= 3'd2) begin
                        logic [63:0] nw;
                        logic [7:0]  be;
                        logic [5:0]  wl;
                        logic [3:0]  yl;
                        ar = add_row - 3'd2;
                        yl = r_y + {1'b0, ar};
                        wl = (r_plane == 2'd0) ? {1'b0, yl, r_x[3]} : ((r_plane == 2'd1) ? 6'd32 : 6'd40) + {3'd0, yl[2:0]};
                        nw = bq_cur; be = '0;
                        for (int j = 0; j < 4; j++) begin
                            logic [2:0] by;
                            logic signed [17:0] v;
                            by = r_x[2:0] + j[2:0];
                            v = $signed({10'd0, bq_cur[8*by +: 8]}) + $signed(res_q[16*j +: 16]);
                            nw[8*by +: 8] = (v < 0) ? 8'd0 : (v > 255) ? 8'd255 : v[7:0];
                            be[by] = 1'b1;
                        end
                        a_v <= 1'b1; a_w <= wl; a_nw <= nw; a_be <= be;
                    end
                    if (add_row == 3'd5) ms <= M_RES_RET;
                    add_row <= add_row + 1'b1;
                end
                M_RES_RET: begin
                    case (r_ret)
                        5'd1: begin                                  // Intra_4x4: the next block
                            if (i4 == 4'd15) begin cplane <= 2'd0; step <= '0; ms <= M_CI_NB; end
                            else begin i4 <= i4 + 1'b1; step <= '0; ms <= M_I4_BLK; end
                        end
                        5'd3: begin rblk <= rblk + 1'b1; ms <= M_RES_LUMA; end
                        default: begin                               // a chroma AC block done
                            if (cw_b == 3'd3) begin
                                if (!cw_c) begin cw_c <= 1'b1; cw_b <= 3'd0; ms <= M_RES_CHROMA; end
                                else begin cnt <= '0; ms <= M_SAVE; end
                            end else begin cw_b <= cw_b + 1'b1; ms <= M_RES_CHROMA; end
                        end
                    endcase
                end
                // ---- save the unfiltered lines, the info, the side words ----------------------------------
                M_SAVE: begin
                    // LM_SAMP[mbx] <- words 30, 31, 39, 47; the left RAM <- byte 7 of the right words
                    // (cnt: 0..3 the bottom row words, 4..35 the right column bytes; reads land 2 later)
                    if (cnt < 9'd36) begin
                        f_bk_rbank <= 1'b0;
                        case (cnt)
                            9'd0: f_bk_raddr <= 6'd30; 9'd1: f_bk_raddr <= 6'd31;
                            9'd2: f_bk_raddr <= 6'd39; 9'd3: f_bk_raddr <= 6'd47;
                            default: begin
                                logic [5:0] k;
                                k = cnt[5:0] - 6'd4;
                                f_bk_raddr <= (k < 6'd16) ? {1'b0, k[3:0], 1'b1} : (k < 6'd24) ? 6'd32 + {3'd0, k[2:0]} : 6'd40 + {3'd0, k[2:0]};
                            end
                        endcase
                    end
                    if (cnt >= 9'd2 && cnt < 9'd6) begin
                        smp_we <= 1'b1; smp_waddr <= {mbx, cnt[1:0] - 2'd2}; smp_wdata <= bq_cur;
                    end
                    if (cnt == 9'd38) begin
                        cnt <= '0; ms <= M_SAVE_SIDE_CMD;
                    end else cnt <= cnt + 1'b1;
                end
                M_SAVE_SIDE_CMD: begin
                    // two write bursts of 8 side words
                    if (!f_cmd_valid) begin
                        f_cmd_valid <= 1'b1; f_cmd_write <= 1'b1; f_cmd_len <= 4'd8;
                        f_cmd_addr <= side_addr + {25'd0, cnt[3], 3'd0};
                        ms <= M_SAVE_SIDE_DATA;
                    end
                end
                M_SAVE_SIDE_DATA: begin
                    if (!f_wd_valid || f_wd_rdy) begin
                        f_wd_valid <= 1'b1; f_wd_data <= side_w; f_wd_be <= 8'hFF;
                        cnt <= cnt + 1'b1;
                        if (cnt[2:0] == 3'd7) begin
                            if (cnt[3]) ms <= M_DB_GO; else ms <= M_SAVE_SIDE_CMD;
                        end
                    end
                end
                // ---- deblocking --------------------------------------------------------------------------
                M_DB_GO: begin
                    // the engine takes this macroblock once it is idle (the previous one is
                    // deblocked and written back, so bank fb(n + 1) = fb(n - 2) is free)
                    if (!f_wd_valid && !e_busy) begin
                        db_left_en <= (mbx != 7'd0) && (disable_deblock != 2'd1) && !(disable_deblock == 2'd2 && !av_left);
                        db_top_en <= (mby != 7'd0) && (disable_deblock != 2'd1) && !(disable_deblock == 2'd2 && !av_above);
                        db_int_en <= (disable_deblock != 2'd1);
                        db_start <= 1'b1; e_go <= 1'b1;
                        ms <= M_DB_WAIT;
                    end
                end
                // the deblocker's bS pre-pass reads this macroblock's block records and the
                // left / above ones (nb_left, LM_INFO[mbx] = nb_above): once it is done the end
                // walk may rewrite them, and the next macroblock may start
                M_DB_WAIT: if (db_pre_done) begin
                    nl_run <= 1'b1; nl_k <= '0;
                    ms <= M_DONE;
                end
                // ---- done ------------------------------------------------------------------------------
                M_DONE: begin
                    if (!f_cmd_valid && !f_wd_valid && !nl_run) begin
                        // the header and {nz, mode} of the right column (its motion is walked in)
                        nb_left[48:0] <= {pcm_qpc1, pcm_qpc0, qpc1, qpc0, qp, cur_pcm, cur_i4, cur_intra, slice_id};
                        nb_left[49 +: 5] <= {mb_nz[5], modes[5]};
                        nb_left[146 +: 5] <= {mb_nz[7], modes[7]};
                        nb_left[243 +: 5] <= {mb_nz[13], modes[13]};
                        nb_left[340 +: 5] <= {mb_nz[15], modes[15]};
                        fb_prev <= fb; fb <= (fb == 2'd2) ? 2'd0 : fb + 2'd1;
                        mb_release <= 1'b1; rel_pending <= 1'b1;
                        mb_done <= 1'b1; mb_done_addr <= mb_addr; mb_count <= mb_count + 1'b1;
                        ms <= M_IDLE;
                    end
                end
                default: ms <= M_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // the back engine: the deblock and the writeback of a finished macroblock, while the
    // front builds the next one (the MB overlap, docs/h264_recon.md S6). Its registers are
    // its own; the slice and picture parameters it reads (the edge flags, the offsets,
    // cur_base, the plane geometry) hold because every NAL boundary waits for idle, which
    // includes this engine. The writeback is the former front states M_WB_*.
    // =====================================================================================
    assign idle = f_idle && !e_busy;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            es <= E_IDLE; e_mbx <= '0; e_mby <= '0; e_cur <= '0; e_left <= '0; e_cnt <= '0;
            e_cmd_valid <= 1'b0; e_cmd_addr <= '0; e_cmd_len <= 4'd1; e_wd_valid <= 1'b0; e_wd_data <= '0;
            e_bk_raddr <= '0; e_rbank <= 1'b0; e_dbk_raddr <= '0; e_dbk_we <= 1'b0; e_dbk_waddr <= '0; e_dbk_wdata <= '0;
            wb_item <= '0; wb_row <= '0; wb_w <= 1'b0; wb_x <= '0; wb_prow <= '0; wb_plane <= '0;
        end else begin
            e_dbk_we <= 1'b0;
            if (e_cmd_valid && e_cmd_rdy) e_cmd_valid <= 1'b0;
            if (e_wd_valid && e_wd_rdy) e_wd_valid <= 1'b0;
            if (clear) es <= E_IDLE;
            else case (es)
                E_IDLE: if (e_go) begin
                    e_mbx <= mbx; e_mby <= mby; e_cur <= fb; e_left <= fb_prev;
                    es <= E_DB;
                end
                E_DB: if (db_done) begin
                    wb_item <= (e_mby != 7'd0) ? 2'd0 : (e_mbx != 7'd0) ? 2'd1 : 2'd2;
                    es <= E_PLAN;
                end
                E_PLAN: begin
                    // skip items that do not apply
                    if (wb_item == 2'd0 && e_mby == 7'd0) wb_item <= 2'd1;
                    else if (wb_item == 2'd1 && e_mbx == 7'd0) wb_item <= 2'd2;
                    else if (wb_item == 2'd2 && {1'b0, e_mbx} != width_mbs - 8'd1) wb_item <= 2'd3;
                    else if (wb_item == 2'd3) es <= E_IDLE;
                    else begin
                        // item 0: luma rows 13..15 + Cb row 7 + Cr row 7 of the above MB (from LM_DBK)
                        // items 1 / 2: rows 0..12 (0..15 on the last row), chroma 0..6 (0..7)
                        wb_row <= (wb_item == 2'd0) ? 5'd13 : 5'd0;
                        wb_w <= 1'b0; e_cnt <= '0;
                        es <= E_CMD;
                    end
                end
                E_CMD: begin
                    // the row: luma rows 0..15 are wb_row 0..15, Cb rows 16..23, Cr rows 24..31
                    wb_x <= (wb_item == 2'd1) ? e_mbx - 7'd1 : e_mbx;
                    if (wb_row < 5'd16) begin
                        wb_plane <= 2'd0;
                        wb_prow <= {((wb_item == 2'd0) ? e_mby - 7'd1 : e_mby), 4'b0} + {7'd0, wb_row[3:0]};
                    end else begin
                        wb_plane <= wb_row[3] ? 2'd2 : 2'd1;
                        wb_prow <= {1'b0, ((wb_item == 2'd0) ? e_mby - 7'd1 : e_mby), 3'b0} + {8'd0, wb_row[2:0]};
                    end
                    es <= E_ADDR;
                end
                E_ADDR: es <= E_ADDR2;               // the product registered (wb_prod_q)
                E_ADDR2: es <= E_ISSUE;              // the sum registered (wb_addr_q)
                E_ISSUE: begin
                    if (!e_cmd_valid && !e_wd_valid) begin
                        e_cmd_valid <= 1'b1; e_cmd_addr <= wb_addr_q;
                        e_cmd_len <= (wb_plane == 2'd0) ? 4'd2 : 4'd1;
                        wb_w <= 1'b0; e_cnt <= '0; es <= E_DATA;
                    end
                end
                E_DATA: begin
                    // per word: the source read (e_cnt 0), its data two edges later (2) pushed,
                    // then held until the client takes it
                    case (e_cnt)
                        5'd0: begin
                            if (wb_item == 2'd0) begin
                                // LM_DBK: luma rows 12..15 at 2(r - 12) + w, Cb row 7 at 9, Cr row 7 at 11
                                if (wb_plane == 2'd0) e_dbk_raddr <= {e_mbx, 1'b0, wb_row[1:0], wb_w};
                                else e_dbk_raddr <= {e_mbx, (wb_plane == 2'd1) ? 4'd9 : 4'd11};
                            end else begin
                                e_rbank <= (wb_item == 2'd1);
                                if (wb_plane == 2'd0) e_bk_raddr <= {1'b0, wb_row[3:0], wb_w};
                                else e_bk_raddr <= ((wb_plane == 2'd1) ? 6'd32 : 6'd40) + {3'd0, wb_row[2:0]};
                            end
                            e_cnt <= 5'd1;
                        end
                        5'd1: e_cnt <= 5'd2;
                        5'd2: begin
                            e_wd_valid <= 1'b1;
                            e_wd_data <= (wb_item == 2'd0) ? dbk_q : bq_e;
                            e_cnt <= 5'd3;
                        end
                        default: begin
                            if (!e_wd_valid) begin
                                if (wb_plane == 2'd0 && !wb_w) begin wb_w <= 1'b1; e_cnt <= '0; end
                                else es <= E_NEXT;
                            end
                        end
                    endcase
                end
                E_NEXT: begin
                    // the next row of the item: item 0 = luma 13..15, Cb 7, Cr 7; items 1 / 2 =
                    // luma 0..12 (0..15 on the last row), Cb / Cr 0..6 (0..7)
                    logic [4:0] lr_end, cr_end;
                    lr_end = (wb_item == 2'd0 || e_last_row) ? 5'd15 : 5'd12;
                    cr_end = (wb_item == 2'd0 || e_last_row) ? 5'd7 : 5'd6;
                    if (wb_row < 5'd16) begin
                        if (wb_row < lr_end) wb_row <= wb_row + 1'b1;
                        else wb_row <= (wb_item == 2'd0) ? 5'd23 : 5'd16;
                        es <= E_CMD;
                    end else if (wb_row < 5'd24) begin
                        if (wb_row < 5'd16 + cr_end) wb_row <= wb_row + 1'b1;
                        else wb_row <= (wb_item == 2'd0) ? 5'd31 : 5'd24;
                        es <= E_CMD;
                    end else if (wb_row < 5'd24 + cr_end) begin
                        wb_row <= wb_row + 1'b1; es <= E_CMD;
                    end else begin
                        // the item is written; items 1 / 2 keep their pending rows in LM_DBK
                        if (wb_item == 2'd0) begin wb_item <= 2'd1; es <= E_PLAN; end
                        else begin e_cnt <= '0; es <= E_KEEP; end
                    end
                end
                E_KEEP: begin
                    // LM_DBK[x] <- rows 12..15 (8 words) and chroma rows 6..7 (4 words) of the item's bank
                    if (e_cnt < 5'd12) begin
                        e_rbank <= (wb_item == 2'd1);
                        e_bk_raddr <= (e_cnt < 5'd8) ? 6'd24 + {3'd0, e_cnt[2:0]} : (e_cnt < 5'd10) ? 6'd38 + {5'd0, e_cnt[0]} : 6'd46 + {5'd0, e_cnt[0]};
                    end
                    if (e_cnt >= 5'd2 && e_cnt < 5'd14) begin
                        logic [3:0] k;
                        k = e_cnt[3:0] - 4'd2;
                        e_dbk_we <= 1'b1; e_dbk_waddr <= {((wb_item == 2'd1) ? e_mbx - 7'd1 : e_mbx), k}; e_dbk_wdata <= bq_e;
                    end
                    if (e_cnt == 5'd14) begin wb_item <= wb_item + 1'b1; es <= E_PLAN; end
                    e_cnt <= e_cnt + 1'b1;
                end
                default: es <= E_IDLE;
            endcase
        end
    end

    // =====================================================================================
    // the residual engine (see its declarations at the top): the former M_RES_LUMA /
    // CHROMA / NEXT / FEED walk, into the residual RAM instead of res_buf
    // =====================================================================================
    // the DC values (8.5.10 dcY at 0..15 in the Intra16x16 AC order's source order, 8.5.11
    // dcC at 16 + 4c + i) in a RAM read one at a time; dc_nz marks each entry nonzero, so an
    // uncoded DC block clears the flags instead of the values, and a zero entry reads as 0.
    // The read is addressed by r_blk (whose DC is needed) and lands the edge after, so a
    // block that is transformed waits one cycle in R_DC for it
    logic [15:0] dcm [0:31];
    logic [23:0] dc_nz;
    logic [4:0]  dc_ra, dc_wa;
    logic        dc_we;
    logic signed [15:0] dc_q, dc_wd;
    always_comb begin
        logic [3:0] b;
        b = r_blk[3:0] - 4'd1;
        if (r_blk <= 5'd16) dc_ra = {1'b0, b[3], b[1], b[2], b[0]};
        else if (r_blk >= 5'd22) dc_ra = {3'b101, r_blk[1:0] - 2'd3};
        else dc_ra = {3'b100, r_blk[1:0] - 2'd2};
    end
    always_ff @(posedge clk) begin
        if (dc_we) dcm[dc_wa] <= dc_wd;
        dc_q <= dcm[dc_ra];
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dc_nz <= '0; dc_we <= 1'b0; dc_wa <= '0; dc_wd <= '0;
            rs <= R_IDLE; r_blk <= '0; r_i16 <= 1'b0; r_dcc_c <= 1'b0; r_dcnz <= 1'b0; r_id <= '0; res_rdy <= '0; res_zero <= '0;
            r_coef_addr <= '0; res_we <= 1'b0; res_wa <= '0; res_wd <= '0; r_row <= '0;
            r_kind <= '0; r_slot <= '0; r_n <= '0; r_pos <= '0; r_rq1 <= 1'b0; r_rq2 <= 1'b0; r_zpush <= 1'b0; r_coded <= 1'b0;
            cq_h <= '0; cq_t <= '0; cq_n <= '0; for (int i = 0; i < 4; i++) cq[i] <= '0;
            dq_start <= 1'b0; dq_kind <= '0; dq_qp <= '0; dq_dc <= '0; dq_coef_valid <= 1'b0; dq_coef <= '0; res_n <= '0;
        end else begin
            dq_start <= 1'b0; res_we <= 1'b0; dc_we <= 1'b0;
            // coefficient reads (address -> data two edges later) through the 4-entry queue
            r_rq2 <= r_rq1; r_rq1 <= 1'b0; r_zpush <= 1'b0;
            if (cq_push) begin cq[cq_t] <= r_rq2 ? $signed(coef_data) : 16'sd0; cq_t <= cq_t + 1'b1; end
            if (cq_pop) begin dq_coef <= cq[cq_h]; dq_coef_valid <= 1'b1; cq_h <= cq_h + 1'b1; end
            else if (cq_out_free) dq_coef_valid <= 1'b0;
            cq_n <= cq_n + {2'd0, cq_push} - {2'd0, cq_pop};
            if (clear) rs <= R_IDLE;
            else case (rs)
                R_IDLE: if (r_go) begin
                    res_rdy <= '0; res_zero <= '0;
                    r_i16 <= cur_intra && !cur_i4;
                    r_blk <= (cur_intra && !cur_i4) ? 5'd0 : 5'd1;
                    rs <= R_SETUP;
                end
                R_SETUP: begin
                    logic [2:0]  kind;
                    logic [4:0]  slot, n, id;
                    logic [5:0]  q;
                    logic        dcnz;
                    logic        coded, is_dc, c;
                    logic [3:0]  b;
                    logic [1:0]  bb;
                    kind = 3'd0; slot = 5'd0; n = 5'd16; id = 5'd0; q = qp; dcnz = 1'b0; c = 1'b0; b = '0; bb = '0;
                    if (r_blk == 5'd0) begin kind = 3'd3; slot = 5'd0; end
                    else if (r_blk <= 5'd16) begin
                        b = r_blk[3:0] - 4'd1; slot = 5'd1 + {1'b0, b}; id = {1'b0, b};
                        if (r_i16) begin kind = 3'd1; n = 5'd15; dcnz = dc_nz[dc_ra]; end
                    end else begin
                        c = (r_blk >= 5'd22);
                        q = c ? qpc1 : qpc0;
                        if (r_blk == 5'd17 || r_blk == 5'd22) begin kind = 3'd4; slot = 5'd17 + {4'd0, c}; n = 5'd4; end
                        else begin
                            bb = c ? r_blk[1:0] - 2'd3 : r_blk[1:0] - 2'd2;   // 23..26 -> 0..3, 18..21 -> 0..3
                            kind = 3'd2; slot = 5'd19 + {2'd0, c, bb}; n = 5'd15; id = 5'd16 + {2'd0, c, bb};
                            dcnz = dc_nz[dc_ra];
                        end
                    end
                    coded = mb_coded[slot];
                    is_dc = (kind == 3'd3 || kind == 3'd4);
                    if (r_blk == 5'd27) rs <= R_IDLE;
                    else if (!coded && (is_dc || !dcnz)) begin
                        // no levels and no DC: nothing to transform
                        if (kind == 3'd3) dc_nz[15:0] <= '0;
                        if (kind == 3'd4) begin if (c) dc_nz[23:20] <= '0; else dc_nz[19:16] <= '0; end
                        if (!is_dc) begin res_rdy[id] <= 1'b1; res_zero[id] <= 1'b1; end
                        r_blk <= r_blk + 5'd1;
                    end else begin
                        r_kind <= kind; r_slot <= slot; r_n <= n; r_coded <= coded; r_id <= id; r_dcc_c <= c;
                        dq_kind <= kind; dq_qp <= q; r_dcnz <= dcnz;
                        r_pos <= '0; res_n <= '0;
                        rs <= R_DC;
                    end
                end
                R_DC: begin
                    // dc_q holds this block's DC now (r_blk has been stable an edge)
                    dq_start <= 1'b1; dq_dc <= r_dcnz ? dc_q : 16'sd0;
                    rs <= R_FEED;
                end
                R_FEED: begin
                    // stream r_n coefficients (zeros when the block was not sent); collect the output
                    if (r_pos < r_n && cq_used < 3'd4) begin
                        if (r_coded) begin r_coef_addr <= {r_slot, r_pos[3:0]}; r_rq1 <= 1'b1; end
                        else r_zpush <= 1'b1;
                        r_pos <= r_pos + 1'b1;
                    end
                    if (dq_res_valid) begin
                        if (r_kind == 3'd3 || r_kind == 3'd4) begin
                            logic [4:0] wa;
                            wa = (r_kind == 3'd3) ? {1'b0, res_n[3:0]} : {2'b10, r_dcc_c, res_n[1:0]};
                            dc_we <= 1'b1; dc_wa <= wa; dc_wd <= dq_res;
                            dc_nz[wa] <= (dq_res != 16'sd0);
                        end
                        else begin
                            // raster order: four samples a row word
                            if (res_n[1:0] == 2'd3) begin
                                res_we <= 1'b1; res_wa <= {r_id, res_n[3:2]}; res_wd <= {dq_res, r_row[47:0]};
                            end else r_row[16*res_n[1:0] +: 16] <= dq_res;
                        end
                        res_n <= res_n + 1'b1;
                        if (dq_res_last) begin
                            if (r_kind != 3'd3 && r_kind != 3'd4) res_rdy[r_id] <= 1'b1;
                            r_blk <= r_blk + 5'd1;
                            rs <= R_SETUP;
                        end
                    end
                end
                default: rs <= R_IDLE;
            endcase
        end
    end
