// bench/umd/disp_sched_tb.sv -- the display path from the output queue to the reader
// (roadmap P5e, docs/display.md S7): umd/recon_out.sv (clk_dec -> clk_sys), umd/disp_ctl.sv
// + umd/disp_sched.sv (clk_sys, the raster's) and umd/disp_reader.sv (clk_mem, reading
// bench/umd/ddr_model.sv), on three real clocks and the real raster (umd/sync_gen.sv),
// scored refresh by refresh against tools/disp_sched_ref.py.
//
// The bench is the DPB: at line 10 of the refresh a record becomes available it writes
// the store's display facts (pinfo) and emits it (the stores are the model's: the lowest
// free one, which the bench checks is really free), and pulses eos_done for the END
// record. Arms:
//   [refresh] at line 510 of every refresh: {shown, store, parity, field, single} equal to the
//             model's (the pickup is at line 500)
//   [count]   pickups, decided changes, re-anchors, late pickups, starved refreshes,
//             cadence errors and flags equal to the model's
//   [judder]  the reader's own count of the (store, parity) changes it fetched equals the
//             decided changes (the independent half of the judder gate)
//   [hold]    every reader burst is from a store the display holds (emitted, not
//             released); the seam recon_out -> disp_ctl -> disp_reader in one simulation
//   [queue]   the harness: a store the model assigns is free when emitted
//   [film]    fj#80 field matching: at every refresh's line 510 {sh_match, sh_film} and, when
//             matched, the partner store sh_pstore equal to the model's (FilmLock fed by the
//             comb sums of what this reader fetched: the records' pictures, written into their
//             stores at emission from STEM.pic; a scenario without pictures is black and never
//             locks). [hold] sees every partner burst.
//   [xport]   the transport (P6b3, P6b3i): the shown store's time (sh_pts) and item tag
//             (sh_ep) at every refresh, and the records dropped unseen (a target, an OUT),
//             drained, and the stop at the title's OUT, equal to the model's. The control
//             events are the scenario's: freeze (set at line 300 of its refresh, so that
//             refresh's eval at line 499 samples it), resync (lines 2-4), an item table
//             entry (line 5). Every record carries its item tag (pinfo_ep, both halves).
// +il (docs/analog.md): the same on the 480i raster -- a refresh is a FIELD (counted from a top
// field: the fork's bench counted from a bottom one and every 480i scenario went RED), the
// stimulus's lines are field lines (the check at 255, the freeze at 150, the resync at 1-2, the
// table writes at 3-4, the emissions at 5), the expected refreshes from
// `disp_sched_ref.py --il` (V6: field order; the freeze at top fields), the reader at 480i.
// PASS marker: "PASS: disp_sched_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module disp_sched_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam [28:0] BASE = 29'h0600_0000;
reg clk = 0, sclk = 0, mclk = 0, rst_n = 0, srst_n = 0, mrst_n = 0;
always #6.173  clk = ~clk;           // clk_dec 81 MHz
always #18.5185 sclk = ~sclk;        // clk_sys 27 MHz
always #5.5555 mclk = ~mclk;         // the DDR3 bridge 90 MHz

// ---- the raster --------------------------------------------------------------------------
wire [11:0] h_pos, v_pos;
reg         raster_rst_n = 0;
reg         il = 0;                  // +il: the 480i raster
sync_gen u_sync (.clk(sclk), .clk_en(1'b1), .rst_n(raster_rst_n), .interlaced(il), .h_pos(h_pos), .v_pos(v_pos),
                 .pixel_en(), .h_sync(), .v_sync(), .h_blank(), .v_blank(), .frame_tick(), .field(), .ce_pix());
// the refresh's line: 480p the line, 480i the field line; the stimulus's lines on it
wire [11:0] rl = il ? {1'b0, v_pos[11:1]} : v_pos;
wire [11:0] L_CHK = il ? 12'd255 : 12'd510, L_FRZ = il ? 12'd150 : 12'd300, L_RS1 = il ? 12'd1 : 12'd2,
            L_RS0 = il ? 12'd2 : 12'd4, L_W0 = il ? 12'd3 : 12'd5, L_W1 = il ? 12'd4 : 12'd6,
            L_EMIT = il ? 12'd5 : 12'd10;

// ---- the queue --------------------------------------------------------------------------
reg         pinfo_we = 0, pinfo_second = 0, pinfo_ps_v = 0, pinfo_pts_v = 0, pinfo_timing_v = 0;
reg  [4:0]  pinfo_store = 0;
reg  [7:0]  pinfo_w = 0, pinfo_hf = 0;
reg  [3:0]  pinfo_ps = 0;
reg  [32:0] pinfo_pts = 0;
reg  [31:0] pinfo_nuit = 0, pinfo_ts = 0;
reg         emit_valid = 0, emit_unpaired = 0, emit_first_bot = 0, emit_frame = 0, emit_dec_t = 0, emit_dec_b = 0;
reg  [4:0]  emit_store = 0;
reg         eos_done = 0;
wire [19:0] oq_hold;
wire        rec_valid, rec_end, rec_frame, rec_unpaired, rec_first_bot, rec_dec_t, rec_dec_b, rec_timing_v;
wire        rec_ps_a_v, rec_ps_b_v, rec_pts_v, rec_pts_b_v, rec_take, rel_valid, rec_ovf, rel_bad;
wire [4:0]  rec_store, rel_store;
wire [7:0]  rec_w, rec_hf;
wire [39:0] rec_aspect;
wire [31:0] rec_nuit, rec_ts;
wire [3:0]  rec_ps_a, rec_ps_b;
wire [32:0] rec_pts, rec_pts_b;
recon_out #(.NST(20)) u_out (
    .clk(clk), .rst_n(rst_n),
    .pinfo_we(pinfo_we), .pinfo_store(pinfo_store), .pinfo_second(pinfo_second), .pinfo_w_mbs(pinfo_w),
    .pinfo_hf_mbs(pinfo_hf), .pinfo_crop(40'd0), .pinfo_aspect(40'd0), .pinfo_timing_v(pinfo_timing_v),
    .pinfo_nuit(pinfo_nuit), .pinfo_ts(pinfo_ts), .pinfo_ps(pinfo_ps), .pinfo_ps_v(pinfo_ps_v), .pinfo_pts(pinfo_pts),
    .pinfo_pts_v(pinfo_pts_v), .pinfo_idr(1'b0), .pinfo_ep(pinfo_ep),
    .emit_valid(emit_valid), .emit_store(emit_store), .emit_unpaired(emit_unpaired), .emit_first_bot(emit_first_bot),
    .emit_frame(emit_frame), .emit_dec_t(emit_dec_t), .emit_dec_b(emit_dec_b), .eos_done(eos_done),
    .oq_hold(oq_hold), .n_emit(), .n_rel(), .rec_ovf(rec_ovf), .rel_bad(rel_bad),
    .sclk(sclk), .srst_n(srst_n),
    .rec_valid(rec_valid), .rec_take(rec_take), .rec_end(rec_end), .rec_store(rec_store), .rec_frame(rec_frame),
    .rec_unpaired(rec_unpaired), .rec_first_bot(rec_first_bot), .rec_dec_t(rec_dec_t), .rec_dec_b(rec_dec_b),
    .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf), .rec_crop(), .rec_aspect(rec_aspect), .rec_timing_v(rec_timing_v),
    .rec_nuit(rec_nuit), .rec_ts(rec_ts), .rec_ps_a(rec_ps_a), .rec_ps_a_v(rec_ps_a_v), .rec_ps_b(rec_ps_b),
    .rec_ps_b_v(rec_ps_b_v), .rec_pts(rec_pts), .rec_pts_v(rec_pts_v), .rec_pts_b(rec_pts_b), .rec_pts_b_v(rec_pts_b_v),
    .rec_idr(), .rec_ep_v(rec_ep_v), .rec_ep(rec_ep), .rel_valid(rel_valid), .rel_store(rel_store), .rec_idle());

// ---- the display control ------------------------------------------------------------------
wire        sh_valid, sh_field, sh_parity, sh_single, ended;
wire [4:0]  sh_store;
wire [7:0]  sh_w, sh_hf;
wire [31:0] n_dc, n_pick;
wire [7:0]  n_reanchor;
wire [3:0]  n_lone;
wire [15:0] n_late, n_starve, n_cadence;
wire [2:0]  flags;
reg         freeze = 0, resync = 0, ep_we = 0, ep_last = 0, ep_skip = 0;
reg  [1:0]  ep_wi = 0, pinfo_ep = 0;
reg  [32:0] ep_in = 0, ep_out = 0;
wire        rec_ep_v;
wire [1:0]  rec_ep, sh_ep;
wire [3:0]  left_mask;
wire        vid_stalled;
wire [32:0] sh_pts;
wire        sh_pts_v, out_hit;
wire [15:0] n_skip, n_drain, n_pdefer;
wire        frz;
wire        sh_match; wire [4:0] sh_pstore; wire [1:0] sh_film;   // fj#80
wire [24:0] cm_c; wire [23:0] cm_r; wire cm_v;
disp_ctl u_ctl (
    .clk(sclk), .rst_n(srst_n), .h_pos(h_pos), .v_pos(v_pos), .il(il),
    .rec_valid(rec_valid), .rec_take(rec_take), .rec_end(rec_end), .rec_store(rec_store), .rec_frame(rec_frame),
    .rec_unpaired(rec_unpaired), .rec_first_bot(rec_first_bot), .rec_dec_t(rec_dec_t), .rec_dec_b(rec_dec_b),
    .rec_w_mbs(rec_w), .rec_hf_mbs(rec_hf), .rec_aspect(rec_aspect), .rec_timing_v(rec_timing_v), .rec_nuit(rec_nuit),
    .rec_ts(rec_ts), .rec_ps_a(rec_ps_a), .rec_ps_a_v(rec_ps_a_v), .rec_ps_b(rec_ps_b), .rec_ps_b_v(rec_ps_b_v),
    .rec_pts(rec_pts), .rec_pts_v(rec_pts_v), .rec_pts_b(rec_pts_b), .rec_pts_b_v(rec_pts_b_v),
    .rel_valid(rel_valid), .rel_store(rel_store),
    .sh_valid(sh_valid), .sh_field(sh_field), .sh_store(sh_store), .sh_w(sh_w), .sh_hf(sh_hf), .sh_parity(sh_parity),
    .sh_single(sh_single), .sh_aspect(), .n_dc(n_dc), .n_pick(n_pick), .n_reanchor(n_reanchor), .n_lone(n_lone), .n_late(n_late), .n_starve(n_starve),
    .n_cadence(n_cadence), .flags(flags), .lag_ms(), .stc(), .stc_run(), .ended(ended),
    .freeze(freeze), .frz(frz), .resync(resync), .rec_ep_v(rec_ep_v), .rec_ep(rec_ep),
    .ep_we(ep_we), .ep_wi(ep_wi), .ep_in(ep_in), .ep_out(ep_out), .ep_last(ep_last), .ep_skip(ep_skip),
    .sh_pts(sh_pts), .sh_pts_v(sh_pts_v), .sh_ep(sh_ep), .left_mask(left_mask), .vid_stalled(vid_stalled), .waiting(), .skipping(),
    .out_hit(out_hit), .n_pdefer(n_pdefer), .n_skip(n_skip), .n_drain(n_drain),
    .cm_c(cm_c), .cm_r(cm_r), .cm_v(cm_v), .sh_match(sh_match), .sh_pstore(sh_pstore), .sh_film(sh_film),
    .fl_locked(), .fl_slot(), .fl_conf(), .n_flost());

// ---- the reader over the DDR model ------------------------------------------------------
wire [28:0] d_addr;
wire [7:0]  d_burst;
wire        d_read, d_wait, d_rdv;
wire [63:0] d_rdata;
wire [31:0] fetch_changes;
disp_reader #(.DPB_BASE(BASE)) u_rd (
    .clk(sclk), .rst_n(srst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(1'b1),
    .pic_valid(sh_valid), .pic_store(sh_store), .pic_field(sh_field), .pic_w_mbs(sh_w), .pic_hf_mbs(sh_hf),
    .pic_parity(sh_parity), .pic_single(sh_single), .deint_mode(2'd2), .il(il), .pic_still(frz), .aa_mode(2'd0), .r(), .g(), .b(), .de_out(),
    .pic_match(sh_match), .pic_pstore(sh_pstore), .pic_film(sh_film), .cm_c(cm_c), .cm_r(cm_r), .cm_v(cm_v),
    .win(1'b0), .win_hold(1'b0), .win_x(10'd0), .win_y(10'd0), .win_w(10'd0), .win_h(10'd0), .win_hs(26'd0), .win_vs(26'd0), .win_x0(26'd0), .win_y0(26'd0), .win_bad(),   // P9's video window: run_disp_reader.sh's W arms
    .mclk(mclk), .mrst_n(mrst_n), .ddr_address(d_addr), .ddr_burstcount(d_burst), .ddr_read(d_read),
    .ddr_waitrequest(d_wait), .ddr_readdata(d_rdata), .ddr_readdatavalid(d_rdv), .fetch_changes(fetch_changes));
ddr_model #(.BASE(BASE), .AW(22)) u_mem (
    .clk(mclk), .rst_n(mrst_n), .address(d_addr), .burstcount(d_burst), .read(d_read), .write(1'b0),
    .writedata(64'd0), .byteenable(8'd0), .waitrequest(d_wait), .readdata(d_rdata), .readdatavalid(d_rdv),
    .unwritten_reads());

// ---- the stimulus and the expected refreshes --------------------------------------------
localparam int MAXR = 1024, MAXK = 4096, MAXC = 1024;
string stem;
integer n_rec, n_ref, n_ctl;
integer ck [0:MAXC-1], ca [0:MAXC-1], cd [0:MAXC-1];
longint cb [0:MAXC-1], cc [0:MAXC-1];
string  ckind [0:MAXC-1];
reg     frozen_k [0:MAXK];
integer e_pv [0:MAXK-1], e_ep [0:MAXK-1], e_lm [0:MAXK-1], e_st [0:MAXK-1];
integer e_fm [0:MAXK-1], e_fs [0:MAXK-1], e_fk [0:MAXK-1];         // fj#80: match, partner, film kernel
localparam int MAXPW = 3000;                                        // fj#80: luma words a picture (176x96: 2112)
reg [63:0] picw [0:MAXR*MAXPW-1];
integer    npw = 0, pic_of [0:MAXR-1];
longint e_pt [0:MAXK-1];
integer c_skip, c_drain, c_outhit, c_ended;
integer r_end [0:MAXR-1], r_av [0:MAXR-1], r_st [0:MAXR-1], r_fr [0:MAXR-1], r_up [0:MAXR-1], r_fb [0:MAXR-1];
integer r_dt [0:MAXR-1], r_db [0:MAXR-1], r_psa [0:MAXR-1], r_psav [0:MAXR-1], r_psb [0:MAXR-1], r_psbv [0:MAXR-1];
longint r_pts [0:MAXR-1], r_ptsb [0:MAXR-1], r_nuit [0:MAXR-1], r_ts [0:MAXR-1];
integer r_ptsv [0:MAXR-1], r_ptsbv [0:MAXR-1], r_tv [0:MAXR-1], r_w [0:MAXR-1], r_hf [0:MAXR-1], r_ep [0:MAXR-1];
integer e_v [0:MAXK-1], e_s [0:MAXK-1], e_p [0:MAXK-1], e_f [0:MAXK-1], e_g [0:MAXK-1];
integer c_dc, c_pick, c_re, c_late, c_starve, c_cad, c_flags, c_lone, c_pdefer;

task automatic load;
    integer fd, i, rc;
    string tagc;
    begin
        fd = $fopen({stem, ".stim"}, "r");
        if (fd == 0) `FAIL("harness", {"no ", stem, ".stim"})
        rc = $fscanf(fd, "%d %d %d\n", n_rec, n_ref, n_ctl);
        if (rc != 3) `FAIL("harness", "bad .stim header")
        for (i = 0; i < n_rec; i++) begin
            rc = $fscanf(fd, "%s", tagc);
            if (tagc == "E") begin
                r_end[i] = 1; rc = $fscanf(fd, "%d\n", r_av[i]);
            end else begin
                r_end[i] = 0;
                rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d\n",
                             r_av[i], r_st[i], r_fr[i], r_up[i], r_fb[i], r_dt[i], r_db[i], r_psa[i], r_psav[i],
                             r_psb[i], r_psbv[i], r_pts[i], r_ptsv[i], r_ptsb[i], r_ptsbv[i], r_tv[i], r_nuit[i],
                             r_ts[i], r_w[i], r_hf[i], r_ep[i]);
                if (rc != 21) `FAIL("harness", $sformatf("bad record %0d", i))
            end
        end
        for (i = 0; i <= MAXK; i++) frozen_k[i] = 1'b0;
        for (i = 0; i < n_ctl; i++) begin
            rc = $fscanf(fd, "%s %s %d %d %d %d %d\n", tagc, ckind[i], ck[i], ca[i], cb[i], cc[i], cd[i]);
            if (rc != 7 || tagc != "C") `FAIL("harness", $sformatf("bad control %0d", i))
            if (ckind[i] == "F") frozen_k[ck[i]] = 1'b1;
        end
        $fclose(fd);
        fd = $fopen({stem, ".exp"}, "r");
        for (i = 0; i < n_ref; i++)
            rc = $fscanf(fd, "%d %d %d %d %d %d %d %d %d %d %d %d %d\n", e_v[i], e_s[i], e_p[i], e_f[i], e_g[i], e_pv[i], e_pt[i], e_ep[i],
                         e_lm[i], e_st[i], e_fm[i], e_fs[i], e_fk[i]);
        $fclose(fd);
        // fj#80: the records' pictures (luma words, in record order; none: black)
        fd = $fopen({stem, ".pic"}, "r");
        if (fd == 0) `FAIL("harness", {"no ", stem, ".pic"})
        rc = $fscanf(fd, "%d %d\n", npw, i);
        if (rc != 2 || npw > MAXPW) `FAIL("harness", "bad .pic header")
        begin : pics
            integer j, np;
            np = 0;
            for (j = 0; j < n_rec; j++) pic_of[j] = -1;
            if (npw > 0) for (j = 0; j < n_rec; j++) if (!r_end[j]) begin
                pic_of[j] = np;
                for (int w = 0; w < npw; w++) rc = $fscanf(fd, "%h\n", picw[np * npw + w]);
                np = np + 1;
            end
        end
        $fclose(fd);
        fd = $fopen({stem, ".cnt"}, "r");
        rc = $fscanf(fd, "cadence=%d dc=%d drain=%d ended=%d flags=%d late=%d lone=%d outhit=%d pdefer=%d pickups=%d reanchors=%d skip=%d starve=%d",
                     c_cad, c_dc, c_drain, c_ended, c_flags, c_late, c_lone, c_outhit, c_pdefer, c_pick, c_re, c_skip, c_starve);
        if (rc != 13) `FAIL("harness", "bad .cnt")
        $fclose(fd);
    end
endtask

// ---- the refresh count, the display's holds (the bench's view) ----------------------------
integer k = -1;                         // the refresh (frame since the alignment)
reg     aligned_seen = 0;
reg [19:0] held = 20'd0;                // emitted, not released
always @(posedge sclk) if (srst_n) begin
    // a refresh starts at a frame's (480i: a field's) first line; the count from a TOP field
    if (h_pos == 12'd0 && v_pos == 12'd0) aligned_seen <= 1'b1;
    if (h_pos == 12'd0 && rl == 12'd0 && (aligned_seen || v_pos == 12'd0)) k <= k + 1;
    if (rel_valid) held[rel_store] = 1'b0;
end

// ---- [refresh] ------------------------------------------------------------------------------
integer n_checked = 0, n_matched = 0;
always @(posedge sclk) if (srst_n && aligned_seen && h_pos == 12'd0 && rl == L_CHK && k < n_ref) begin
    if ({sh_valid, sh_store, sh_parity, sh_field, sh_single} !== {e_v[k][0], e_s[k][4:0], e_p[k][0], e_f[k][0], e_g[k][0]})
        `FAIL("refresh", $sformatf("refresh %0d: shown %b store %0d parity %b field %b single %b, want %0d %0d %0d %0d %0d", k,
                                    sh_valid, sh_store, sh_parity, sh_field, sh_single, e_v[k], e_s[k], e_p[k], e_f[k], e_g[k]))
    if ({sh_pts_v, sh_pts} !== {e_pv[k][0], e_pt[k][32:0]})
        `FAIL("xport", $sformatf("refresh %0d: the shown time %b %0d, want %0d %0d", k, sh_pts_v, sh_pts, e_pv[k], e_pt[k]))
    if (sh_ep !== e_ep[k][1:0])
        `FAIL("xport", $sformatf("refresh %0d: the shown item tag %0d, want %0d", k, sh_ep, e_ep[k]))
    if (left_mask !== e_lm[k][3:0] || vid_stalled !== e_st[k][0])
        `FAIL("xport", $sformatf("refresh %0d: left items %b stalled %b, want %b %0d", k, left_mask, vid_stalled, e_lm[k][3:0], e_st[k]))
    if ({sh_match, sh_film} !== {e_fm[k][0], e_fk[k][1:0]} || (sh_match === 1'b1 && sh_pstore !== e_fs[k][4:0]))
        `FAIL("film", $sformatf("refresh %0d: match %b partner %0d film %0d, want %0d %0d %0d", k, sh_match, sh_pstore, sh_film,
                                 e_fm[k], e_fs[k], e_fk[k]))
    n_matched = n_matched + sh_match;
    n_checked = n_checked + 1;
end

// ---- the transport's control events (P6b3) --------------------------------------------------
integer ci;
always @(posedge sclk) if (srst_n && aligned_seen) begin
    if (h_pos == 12'd0 && rl == L_FRZ) freeze <= frozen_k[k];
    if (h_pos == 12'd0 && rl == L_RS0) resync <= 1'b0;
    ep_we <= 1'b0;
    // (one event a line: two table writes in a refresh take lines 5 and 6; 480i 3 and 4)
    if (h_pos == 12'd0 && (rl == L_RS1 || rl == L_W0 || rl == L_W1)) begin : ev
        integer nw;
        nw = 0;
        for (ci = 0; ci < n_ctl; ci++) if (ck[ci] == k) begin
            if (ckind[ci] == "S" && rl == L_RS1) resync <= 1'b1;
            if (ckind[ci] == "W") begin
                if (nw == rl - L_W0) begin
                    ep_we <= 1'b1; ep_wi <= ca[ci][1:0]; ep_in <= cb[ci][32:0]; ep_out <= cc[ci][32:0];
                    ep_last <= cd[ci][0]; ep_skip <= cd[ci][1];
                end
                nw = nw + 1;
            end
        end
    end
end

// ---- [hold]: every reader burst from a held store -------------------------------------------
always @(posedge mclk) if (mrst_n && d_read && !d_wait) begin : hold_check
    reg [28:0] rel;
    rel = d_addr - BASE;
    if (!held[rel[21:17]])
        `FAIL("hold", $sformatf("refresh %0d: the reader reads store %0d, which the display does not hold", k, rel[21:17]))
end

// ---- the DPB: emissions at line 10 of each refresh ------------------------------------------
integer ri = 0;
initial begin : dpb
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    if ($test$plusargs("il")) il = 1'b1;
    load();
    // the raster first: disp_ctl aligns its tick at the first (0, 0) it sees
    #100 raster_rst_n = 1;
    #500 rst_n = 1; srst_n = 1; mrst_n = 1;
    forever begin
        @(posedge sclk);
        if (aligned_seen && h_pos == 12'd0 && rl == L_EMIT) begin
            while (ri < n_rec && r_av[ri] <= k) begin
                @(negedge clk);
                if (r_end[ri]) begin
                    eos_done = 1; @(negedge clk); eos_done = 0;
                end else begin
                    if (held[r_st[ri]] || oq_hold[r_st[ri]])
                        `FAIL("queue", $sformatf("record %0d: store %0d is not free at refresh %0d", ri, r_st[ri], k))
                    pinfo_we = 1; pinfo_second = 0; pinfo_store = r_st[ri]; pinfo_w = r_w[ri]; pinfo_hf = r_hf[ri];
                    pinfo_timing_v = r_tv[ri]; pinfo_nuit = r_nuit[ri]; pinfo_ts = r_ts[ri];
                    pinfo_ps = r_psa[ri]; pinfo_ps_v = r_psav[ri]; pinfo_pts = r_pts[ri]; pinfo_pts_v = r_ptsv[ri];
                    pinfo_ep = r_ep[ri][1:0];
                    @(negedge clk);
                    if (!r_fr[ri] && !r_up[ri]) begin
                        pinfo_second = 1; pinfo_ps = r_psb[ri]; pinfo_ps_v = r_psbv[ri]; pinfo_pts = r_ptsb[ri];
                        pinfo_pts_v = r_ptsbv[ri];
                        @(negedge clk);
                    end
                    pinfo_we = 0;
                    // fj#80: the record's picture into its store (else the store keeps what it held:
                    // unwritten, black -- the old scenarios never write)
                    if (pic_of[ri] >= 0)
                        for (int w = 0; w < npw; w++) u_mem.poke(BASE + {r_st[ri][4:0], 17'd0} + w, picw[pic_of[ri] * npw + w]);
                    emit_valid = 1; emit_store = r_st[ri]; emit_frame = r_fr[ri]; emit_unpaired = r_up[ri];
                    emit_first_bot = r_fb[ri]; emit_dec_t = r_dt[ri]; emit_dec_b = r_db[ri];
                    held[r_st[ri]] = 1'b1;
                    @(negedge clk);
                    emit_valid = 0;
                end
                ri = ri + 1;
            end
        end
    end
end

initial begin
    #1;
    wait (k == n_ref && h_pos == 12'd10);
    if (n_checked !== n_ref) `FAIL("refresh", $sformatf("%0d refreshes checked of %0d", n_checked, n_ref))
    if (n_pick !== c_pick || n_dc !== c_dc || n_reanchor !== c_re[7:0] || n_late !== c_late[15:0] ||
        n_starve !== c_starve[15:0] || n_cadence !== c_cad[15:0] || flags !== c_flags[2:0] ||
        n_lone !== (c_lone > 15 ? 4'hF : c_lone[3:0]) || n_pdefer !== c_pdefer[15:0])
        `FAIL("count", $sformatf("pickups %0d dc %0d reanchors %0d late %0d starve %0d cadence %0d flags %0d lone %0d pdefer %0d; want %0d %0d %0d %0d %0d %0d %0d %0d %0d",
                                  n_pick, n_dc, n_reanchor, n_late, n_starve, n_cadence, flags, n_lone, n_pdefer,
                                  c_pick, c_dc, c_re, c_late, c_starve, c_cad, c_flags, c_lone, c_pdefer))
    // the decided changes up to refresh n_ref - 1 were fetched at refresh n_ref - 1's line 0
    if (n_skip !== c_skip[15:0] || n_drain !== c_drain[15:0] || out_hit !== c_outhit[0] || ended !== c_ended[0])
        `FAIL("xport", $sformatf("skipped %0d drained %0d out_hit %b ended %b; want %0d %0d %0d %0d", n_skip, n_drain, out_hit,
                                  ended, c_skip, c_drain, c_outhit, c_ended))
    if (fetch_changes !== n_dc)
        `FAIL("judder", $sformatf("the reader fetched %0d (store, parity) changes, the display decided %0d", fetch_changes, n_dc))
    if (rec_ovf !== 1'b0 || rel_bad !== 1'b0) `FAIL("hold", $sformatf("queue faults: rec_ovf %b rel_bad %b", rec_ovf, rel_bad))
    $display("disp_sched_tb: %0d refreshes%0s identical to the model (%0d matched, fj#80); %0d pickups, %0d re-anchors, %0d lone PTS, %0d late, %0d starved, %0d cadence errors, flags %0d, %0d field-order deferrals; the reader fetched every one of %0d decided changes",
             n_ref, il ? " (480i fields)" : "", n_matched, n_pick, n_reanchor, n_lone, n_late, n_starve, n_cadence, flags, n_pdefer, n_dc);
    $display("PASS: disp_sched_tb");
    $finish;
end

endmodule
`default_nettype wire
