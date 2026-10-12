// bench/umd/sub_overlay_tb.sv -- subtitles from the demux's bytes to the composite on the
// raster: umd/sub/sub_overlay.sv as emu will instance it (docs/compositor.md §8), with the
// video's umd/disp_reader.sv on its v_* port, umd/sync_gen.sv's raster and one DDR3 model
// (bench/umd/ddr_model.sv: random waits and latencies) behind DDRAM2.
//
// Clocks as in emu: one 27 MHz clock for the demux and the raster (clk_sys), and mclk
// 90 MHz. The host is bench/umd/mock_host.svh (A7, docs/hps_host.md §3.2): it reads each
// requested unit out of the ring and checks it ([unit]), writes the golden plane into the
// plane it was told ([tear] if on screen), and completes after +host_lat cycles. The STC ticks every 1,000 mclk cycles (the real 90 kHz), so the raster's
// 59.94 Hz and the STC agree; when nothing moves it jumps to the next event, but never while
// a request waits for its blank or a frame after an acknowledgement is being scored.
// Input: each PES released 0.8 s before its PTS (sub_top_tb's rule).
// Fixtures: tools/sub_golden.py e2e (the units, libpng's planes) and
// tools/sub_overlay_golden.py (per shown unit the plane on the raster and the composite
// over tools/disp_golden.py's video).
//
// Arms:
//   [plane] the first whole frame after each acknowledgement: the plane (LAT 5) equals the
//           shown unit's (or 0 after a hide), every active dot (!==)
//   [comp]  the same frame's composite (LAT 7) equals the golden's, every active dot
//   [show]  flips come in the tool's order (refused units skipped), none before its PTS;
//           every unit shown and hidden; hides not before the end
//   [flush] +flush=1: a flush while the host decodes the first unit -- that unit is never
//           shown, the later ones are, exactly, and the host's late completion of it is
//           ignored ([stale]: n_stale 1; the host saw the gen move);
//           +flush=2: a flush the cycle the second unit's flip is requested -- it is shown
//           for one frame and hidden at the very next blank. (Left up, it would hide at its
//           own end -- which the STC jump reaches within a couple of blanks, so the arm counts
//           blanks exactly: a change to the jump policy must keep "next" distinguishable.)
//   [hang]  after a flush, the port holds no open write burst 2,000 mclk cycles later
//   [unit] / [tear]  the mock host's (a unit's bytes in the ring; a write into the shown plane)
//   [late]  the plane reader never finds a line request during a fetch
//   [count] every scored frame complete (345,600 dots twice); refused / missed / late counts
//           as the golden says
//   +zoom (fj#71, docs/zoom.md Z3): `zoom` held high, [plane] / [comp] scored on the golden's
//           zovl<k> files -- each subtitle moved inside the band 60 .. 419, never cut
// PASS: sub_overlay_tb.

`timescale 1ns/1ps
`default_nettype none

module sub_overlay_tb;
    localparam logic [28:0] BASE = 29'h0600_0000;
    localparam logic [28:0] RB = BASE + 29'h30_0000;
    localparam logic [28:0] P0 = BASE + 29'h31_0000, P1 = P0 + 29'h2A300;
    localparam int TICK = 1000, LEAD = 72000, NDOT = 720 * 480;
    localparam int MH_RAW = 12;
    localparam logic [28:0] MH_MBASE = BASE;    // ddr_model's BASE

`ifdef FABRIC
    localparam bit FAB = 1'b1;              // A12 SD1: the fabric decodes (no mock host)
`else
    localparam bit FAB = 1'b0;
`endif
    logic clk = 0, mclk = 0;
    always #18.519 clk = ~clk;              // clk_sys, 27 MHz: the demux, the raster
    always #5.556  mclk = ~mclk;            // the DDR3 port, 90 MHz
    logic rst_n = 0, flush = 0;

    // ---- the raster and the video ---------------------------------------------------------------------
    wire [11:0] h_pos, v_pos; wire pixel_en, hs, vs, hbl, vbk, ft, fld;
    sync_gen sg (.clk (clk), .clk_en (1'b1), .rst_n (rst_n), .interlaced (1'b0), .h_pos (h_pos), .v_pos (v_pos),
                 .pixel_en (pixel_en), .h_sync (hs), .v_sync (vs), .h_blank (hbl), .v_blank (vbk), .frame_tick (ft), .field (fld));
    wire vbl = (h_pos == 12'd0) && (v_pos == 12'd500);
    wire [28:0] v_address; wire [7:0] v_burstcount; wire v_read, v_waitrequest, v_readdatavalid; wire [63:0] v_readdata;
    wire [7:0] vr, vg, vb; wire vde;
    disp_reader #(.DPB_BASE (BASE)) u_disp (.clk (clk), .rst_n (rst_n), .h_pos (h_pos), .v_pos (v_pos), .de_in (pixel_en), .il (1'b0), .pic_still (1'b0), .aa_mode (2'd0),
    .win(1'b0), .win_hold(1'b0), .win_x(10'd0), .win_y(10'd0), .win_w(10'd0), .win_h(10'd0), .win_hs(26'd0), .win_vs(26'd0), .win_x0(26'd0), .win_y0(26'd0), .win_bad(),   // P9's video window: run_disp_reader.sh's W arms
        .pic_valid (1'b1), .pic_store (5'd17), .pic_field (1'b0), .pic_w_mbs (8'd45), .pic_hf_mbs (8'd30),
        .pic_parity (1'b0), .pic_single (1'b0), .deint_mode (2'd0),   // (tied: they floated until 480i read them)
        .pic_match (1'b0), .pic_pstore (5'd0), .pic_film (2'd0), .cm_c (), .cm_r (), .cm_v (),   // fj#80 (run_disp_reader.sh's arms)
        .r (vr), .g (vg), .b (vb), .de_out (vde),
        .mclk (mclk), .mrst_n (rst_n), .ddr_address (v_address), .ddr_burstcount (v_burstcount), .ddr_read (v_read),
        .ddr_waitrequest (v_waitrequest), .ddr_readdata (v_readdata), .ddr_readdatavalid (v_readdatavalid));

    // ---- the overlay and DDR3 --------------------------------------------------------------------------
    logic [7:0]  sp_byte = 0;
    logic        sp_valid = 0, sp_frame_start = 0, sp_pts_valid = 0;
    logic [32:0] sp_pts = 0, stc = 0;
    logic        stc_valid = 0;
    wire  [28:0] ddr_address; wire [7:0] ddr_burstcount, ddr_byteenable;
    wire         ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
    wire  [63:0] ddr_writedata, ddr_readdata;
    wire  [7:0]  out_r, out_g, out_b;
    wire  [15:0] in_lost, in_pts_lost, n_units, n_truncated, n_overrun, n_orphan, n_lost, n_ring_full,
                 n_badhdr, n_oddfield, n_shown, n_late, n_missed, n_refused, n_stale, n_line_late, n_flips;
    wire         geo_bad;
    wire         h_req, h_buf, h_vis;
    wire  [7:0]  h_seq, h_gen, h_shown_seq;
    wire  [15:0] h_x, h_y;
    wire  [MH_RAW-1:0] h_start;
    wire  [31:0] h_len;
    logic        h_done;
    logic [7:0]  h_done_seq;
    logic [4:0]  h_done_err;
    logic [15:0] h_done_w, h_done_h;
    int          unwritten;
    logic        zoom_tb = 1'b0;               // +zoom (fj#71)
    sub_overlay #(.RING_BASE (RB), .RAW (MH_RAW), .MAW (4), .PLANE0 (P0), .PLANE1 (P1), .FABRIC_DEC (FAB)) dut (
        .sclk (clk), .srst_n (rst_n), .sp_byte, .sp_valid, .sp_frame_start, .sp_pts, .sp_pts_valid,
        .pclk (clk), .mclk, .mrst_n (rst_n), .flush, .stc, .stc_valid,
        .v_address, .v_burstcount, .v_read, .v_waitrequest, .v_readdata, .v_readdatavalid,
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid,
        .clk, .rst_n, .h_pos, .v_pos, .il (1'b0), .de_in (pixel_en), .vbl, .zoom (zoom_tb), .vid_r (vr), .vid_g (vg), .vid_b (vb),
        .out_r, .out_g, .out_b,
        .h_req, .h_seq, .h_buf, .h_x, .h_y, .h_start, .h_len, .h_gen, .h_vis, .h_shown_seq,
        .h_done, .h_done_seq, .h_done_err, .h_done_w, .h_done_h,
        .in_lost, .in_pts_lost, .n_units, .n_truncated, .n_overrun, .n_orphan, .n_lost, .n_ring_full,
        .n_badhdr, .n_oddfield, .n_shown, .n_late, .n_missed, .n_refused, .n_stale, .n_line_late, .n_flips, .geo_bad,
        .ui (1'b0), .ui_sub (1'b0), .hf_req (1'b0), .hf_buf (2'd0), .hf_vis (1'b0), .hf_x (16'd0), .hf_y (16'd0), .hf_w (16'd0),
        .hf_h (16'd0), .hf_ack (),                                   // P9's hand-over: run_plane.sh's sub_flip_tb
        .x_address (29'd0), .x_burstcount (8'd0), .x_read (1'b0), .x_waitrequest (), .x_readdata (),
        .x_readdatavalid ());                                        // P9's sound one-shot: run_pcm_shot.sh
    ddr_model #(.BASE (BASE), .AW (22)) u_ddr (.clk (mclk), .rst_n (rst_n), .address (ddr_address),
        .burstcount (ddr_burstcount), .read (ddr_read), .write (ddr_write), .writedata (ddr_writedata),
        .byteenable (ddr_byteenable), .waitrequest (ddr_waitrequest), .readdata (ddr_readdata),
        .readdatavalid (ddr_readdatavalid), .unwritten_reads (unwritten));

    // ---- fixtures ----------------------------------------------------------------------------------------
    localparam int NIN = 1048576, NU = 256, NPW = 1048576, NUB = 1048576;
    logic [43:0] inw [0:NIN-1];
    logic [35:0] urec [0:9*NU-1];
    logic [90:0] pw [0:NPW-1];
    logic [7:0]  ub [0:NUB-1];
    logic [31:0] uo [0:2*NU-1];
    logic [31:0] meta [0:4];
    logic [63:0] store [0:65535];
    logic [23:0] video [0:NDOT-1];
    logic [31:0] e_argb [0:NDOT-1];
    logic [23:0] e_rgb [0:NDOT-1];
    string       stem, s;
    integer      fd, flush_mode;
    int          nframes, flush_t;
    bit          waiting, flush_seen;
    logic        dreq_d;

    task automatic fail(input string a, input string msg);
        $display("FAIL [%s] %0s: %s", a, stem, msg);
        $fatal(1, "sub_overlay_tb: failed");
    endtask

    // the plane the display holds ([tear], the mock host's check)
    logic front_v, front_b;
    always @(posedge mclk) if (!rst_n) front_v <= 1'b0;
                           else if (dut.d_req && dut.d_ack && dut.d_vis) begin front_v <= 1'b1; front_b <= dut.d_buf; end

    wire mrst_n = rst_n;                    // (one reset here; the mock host's name for it)
`ifdef FABRIC
    // the fabric decodes: no host completion; the decode's busy stands for the mock's
    logic mh_busy;
    int   mh_wait = 0, mh_lat = 2;
    assign mh_busy = dut.u_sub.g_dec.u_dec.busy;
    assign h_done = 1'b0; assign h_done_seq = '0; assign h_done_err = '0;
    assign h_done_w = '0; assign h_done_h = '0;
`else
    `include "bench/umd/mock_host.svh"
`endif

    // ---- the frame counter and the blanks ----------------------------------------------------------------
    int frame = 0, nvbl = 0;
    always @(posedge clk) if (rst_n) begin
        if (h_pos == 857 && v_pos == 524) frame <= frame + 1;
        if (vbl) nvbl <= nvbl + 1;
    end

    // ---- the acknowledgements (mclk): order, time, what the next frame must show ---------------------------
    integer nx, nshow, ack_vbl, flip_vbl, score_req, score_busy, scored;
    bit     showing, want_quick_hide, dropped_first;
    logic [32:0] shown_end;
    always @(posedge mclk) if (rst_n && dut.d_req && dut.d_ack) begin
        if (dut.d_vis) begin
            string fn;
            while (nx < meta[1] && urec[9 * nx + 6] != 0) nx = nx + 1;       // refused: never shown
            if (nx >= meta[1]) fail("show", "a flip the tool has no unit for");
            if ($signed(stc - urec[9 * nx][32:0]) < 0) fail("show", $sformatf("unit %0d shown at %0d, before its PTS %0d", nx, stc, urec[9 * nx]));
            begin : golden_k                   // the golden numbers the tool's units that are not refused
                int gk;
                gk = 0;
                for (int j = 0; j < nx; j++) if (urec[9 * j + 6] == 0) gk++;
                fn = $sformatf("%0s.%0s%0d_argb.hex", stem, zoom_tb ? "zovl" : "ovl", gk); $readmemh(fn, e_argb);
                fn = $sformatf("%0s.%0s%0d_rgb.hex", stem, zoom_tb ? "zovl" : "ovl", gk);  $readmemh(fn, e_rgb);
            end
            showing = 1; shown_end = urec[9 * nx][32:0] + urec[9 * nx + 1][32:0];
            flip_vbl = nvbl;
            nx = nx + 1; nshow = nshow + 1;
        end else begin
            if (!showing) fail("show", "a hide with nothing shown");
            if (want_quick_hide) begin
                if (nvbl != flip_vbl + 1) fail("flush", $sformatf("the flip requested at the flush hidden %0d blanks later, not at the next", nvbl - flip_vbl));
                want_quick_hide = 0;
            end else if ($signed(stc - shown_end) < 0) fail("show", $sformatf("hidden at %0d, before the end %0d", stc, shown_end));
            for (int i = 0; i < NDOT; i++) begin e_argb[i] = 32'd0; e_rgb[i] = video[i]; end
            showing = 0;
        end
        score_req = score_req + 1;
    end

    // ---- scoring (clk): the first whole frame after each acknowledgement -----------------------------------
    logic [11:0] hq [0:7]; logic [11:0] vq [0:7]; logic dq [0:7]; int fq [0:7];
    always @(posedge clk) begin
        hq[0] <= h_pos; vq[0] <= v_pos; dq[0] <= pixel_en; fq[0] <= frame;
        for (int i = 1; i < 8; i++) begin hq[i] <= hq[i-1]; vq[i] <= vq[i-1]; dq[i] <= dq[i-1]; fq[i] <= fq[i-1]; end
    end
    int sframe = -1, np, nc;
    always @(posedge clk) if (rst_n) begin
        if (n_line_late !== 16'd0) fail("late", $sformatf("%0d plane line requests during a fetch", n_line_late));
        // a frame starts: score it if an acknowledgement came since the last scored one
        if (h_pos == 0 && v_pos == 0 && score_req > scored && sframe < 0) begin
            sframe = frame; np = 0; nc = 0; score_busy = 1;
        end
        if (sframe >= 0 && dq[4] && fq[4] == sframe) begin
            int i;
            i = vq[4] * 720 + hq[4];
            if ({dut.p_a, dut.p_r, dut.p_g, dut.p_b} !== e_argb[i])
                fail("plane", $sformatf("frame %0d (%0d, %0d): %h, want %h", sframe, hq[4], vq[4], {dut.p_a, dut.p_r, dut.p_g, dut.p_b}, e_argb[i]));
            np++;
        end
        if (sframe >= 0 && dq[6] && fq[6] == sframe) begin
            int i;
            i = vq[6] * 720 + hq[6];
            if ({out_r, out_g, out_b} !== e_rgb[i])
                fail("comp", $sformatf("frame %0d (%0d, %0d): %h, want %h", sframe, hq[6], vq[6], {out_r, out_g, out_b}, e_rgb[i]));
            nc++;
        end
        if (sframe >= 0 && fq[7] == sframe + 1) begin
            if (np != NDOT || nc != NDOT) fail("count", $sformatf("frame %0d: %0d plane / %0d composite dots scored", sframe, np, nc));
            scored = score_req; sframe = -1; score_busy = 0; nframes++;
        end
    end

    // ---- the STC (mclk): real rate, jumping over the quiet stretches ---------------------------------------
    integer div, quiet;
    logic [32:0] rel;
    always @(posedge mclk) if (rst_n) begin
        // quiet: the subtitle master idle (the video's reader never is)
        if (dut.a_write || dut.a_read) quiet <= 0; else quiet <= quiet + 1;
        div <= (div == TICK - 1) ? 0 : div + 1;
        if (div == TICK - 1) stc <= stc + 1;
        if (quiet > 3000 && stc_valid && !dut.d_req && score_req == scored && sframe < 0
            && dut.u_sub.u_sched.bst != 2'd1 && !dut.u_sub.u_ring.rd_busy && !mh_busy) begin : jump
            logic [32:0] t;
            t = 33'h1_FFFF_FFFF;
            if (waiting && rel > stc + 1) t = rel - 1;
            if (dut.u_sub.u_sched.bst == 2'd2 && dut.u_sub.u_sched.bpts > stc + 1 && dut.u_sub.u_sched.bpts - 1 < t) t = dut.u_sub.u_sched.bpts - 1;
            if (showing && shown_end > stc + 1 && shown_end - 1 < t) t = shown_end - 1;
            if (t != 33'h1_FFFF_FFFF && t > stc) begin stc <= t; quiet <= 0; end
        end
    end

    // ---- the flushes (mclk) ---------------------------------------------------------------------------------
    logic [7:0] gen_pre;                    // gen just before the flush
    always @(posedge mclk) begin
        flush <= 1'b0;
        dreq_d <= dut.d_req;
        if (!flush_seen) gen_pre <= h_gen;
        if (rst_n && !flush_seen) begin
            // 1: while the host decodes the first unit: that unit is dropped
            // (a threshold, not an equality: mh_wait is the mock's blocking variable, read here
            //  in the same edge in either order -- an equality was missed every other cycle)
            if (flush_mode == 1 && nshow == 0 && mh_busy && mh_wait <= mh_lat / 2) begin
                flush <= 1'b1; flush_seen = 1; flush_t = 0; dropped_first = 1;
                while (nx < meta[1] && urec[9 * nx + 6] != 0) nx = nx + 1;
                nx = nx + 1;
            end
            // 2: as the second unit's flip is requested (the request still outstanding)
            if (flush_mode == 2 && nshow == 1 && dut.d_req && dut.d_vis && !dreq_d) begin
                flush <= 1'b1; flush_seen = 1; flush_t = 0; want_quick_hide = 1;
            end
        end
        if (flush_seen && flush_t >= 0) begin
            flush_t = flush_t + 1;
            // the flush moved gen (the host's cue to abandon a decode: the seq rule alone keeps
            // the plane right, so only this sees a gen that stands still)
            if (flush_t == 20 && h_gen == gen_pre)
                fail("flush", $sformatf("gen %0d did not move at the flush", h_gen));
            if (flush_t == 2000) begin
                if (u_ddr.wr_beats_left != 0) fail("hang", $sformatf("a write burst left open by the flush (%0d beats to come)", u_ddr.wr_beats_left));
                flush_t = -1;
            end
        end
    end

    // ---- the cases -----------------------------------------------------------------------------------------
    int ip, cyc, nshown_want;
    initial begin
        if (!$value$plusargs("list=%s", s)) $fatal(1, "+list= missing");
        if (!$value$plusargs("flush=%d", flush_mode)) flush_mode = 0;
        zoom_tb = $test$plusargs("zoom");
        $readmemh("bench/umd/fixtures/gen/disp_store.hex", store);
        $readmemh("bench/umd/fixtures/gen/disp_rgb.hex", video);
        for (int i = 0; i < 43200 + 21600; i++) u_ddr.poke(BASE + {5'd17, 17'd0} + i, store[i]);
        fd = $fopen(s, "r");
        nframes = 0;
        while ($fscanf(fd, "%s\n", stem) == 1) begin
            $readmemh({stem, ".meta.hex"}, meta);
            if (meta[0] > NIN || meta[1] > NU) $fatal(1, "%0s: larger than the bench", stem);
            $readmemh({stem, ".in.hex"}, inw, 0, meta[0] - 1);
            $readmemh({stem, ".urec.hex"}, urec, 0, 9 * meta[1] - 1);
            if (meta[2] != 0) $readmemh({stem, ".pw.hex"}, pw, 0, meta[2] - 1);
            $readmemh({stem, ".ub.hex"}, ub);
            $readmemh({stem, ".uo.hex"}, uo, 0, 2 * meta[1] - 1);
            rst_n = 0; nx = 0; nshow = 0; showing = 0; waiting = 0; quiet = 0; div = 0; score_req = 0; scored = 0;
            sframe = -1; want_quick_hide = 0; dropped_first = 0; flush_seen = 0; flush_t = -1;
            stc = inw[0][40:8] - LEAD - 9000; stc_valid = 1;
            repeat (8) @(posedge mclk);
            #1 rst_n = 1;
            ip = 0;
            while (ip < meta[0]) begin
                @(negedge clk);
                if (inw[ip][41] && inw[ip][42]) begin
                    rel = inw[ip][40:8] - LEAD;
                    waiting = 1;
                    while ($signed(stc - rel) < 0) @(negedge clk);
                    waiting = 0;
                    repeat (200) @(negedge clk);
                end
                sp_valid = 1; sp_byte = inw[ip][7:0]; sp_frame_start = inw[ip][41];
                sp_pts_valid = inw[ip][42]; sp_pts = inw[ip][40:8];
                ip = ip + 1;
                @(negedge clk);
                sp_valid = 0; sp_frame_start = 0;
            end
            waiting = 0; rel = 0;
            nshown_want = meta[1] - meta[4] - (dropped_first ? 1 : 0);
            cyc = 0;
            while ((nshow < nshown_want || showing || score_req != scored) && cyc < 100000000) begin
                @(posedge mclk); cyc = cyc + 1;
                nshown_want = meta[1] - meta[4] - (dropped_first ? 1 : 0);
            end
            if (nshow < nshown_want || showing || score_req != scored) fail("show", $sformatf("%0d of %0d units shown (showing %0d)", nshow, nshown_want, showing));
            if (flush_mode != 0 && !flush_seen) fail("flush", "the flush point never came");
            if (n_refused !== meta[4][15:0]) fail("count", $sformatf("%0d refused, libpng %0d", n_refused, meta[4]));
            // (the mock completes the abandoned decode late, and the fabric ignores it; the
            //  fabric's own decoder never completes a dropped decode)
            if (n_stale !== ((flush_mode == 1 && !FAB) ? 16'd1 : 16'd0))
                fail("stale", $sformatf("%0d host completions ignored, want %0d", n_stale, flush_mode == 1 && !FAB));
            if (n_missed !== 16'd0 || n_late !== 16'd0) fail("count", $sformatf("%0d missed, %0d late", n_missed, n_late));
            if (geo_bad !== 1'b0) fail("count", "geo_bad at 1:1");
            $display("sub_overlay_tb: %0s: %0d units shown, %0d frames scored exact (plane and composite)%0s", stem, nshow,
                     score_req, flush_mode == 1 ? ", flushed while the host decoded" : flush_mode == 2 ? ", flushed at a flip request" : "");
        end
        $display("PASS: sub_overlay_tb");
        $finish;
    end
endmodule

`default_nettype wire
