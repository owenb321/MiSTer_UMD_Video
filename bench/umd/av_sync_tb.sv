// bench/umd/av_sync_tb.sv -- the audio path as emu composes it: ps_demux -> aud_ring ->
// at3p_top -> aud_out, against a program stream and its goldens
// (tools/av_sync_golden.py). The STC is the bench's: it starts (at first_pts +
// +anchor_ofs ticks) only once +anchor_vb video bytes have left the demux -- the first
// picture needs its bytes -- then counts at clk / 300, as disp_sched's does.
//
// Scored (docs/at3p_decoder.md S7):
//   [tag]   every tag aud_out takes, in order, == the golden's (FAP-derived) tag;
//           a PCM frame that begins with no tag waiting fails here too
//   [pcm]   every pair played == the golden pair at its index (pops count played and
//           discarded pairs alike, so a dropped or repeated pair shifts everything)
//   [start] every release (not a fallback): the STC inside the head pair, 0 <= d < 15
//           eighth-ticks, d = STC * 8 - (tag PTS * 8 + 15 * index), from the GOLDEN tags
//   [drop]  every discard with the STC running is wholly past (d >= 15); every discard
//           before it runs happens with the ring blocking the demux
//   [sync]  every tagged frame start played: -8 <= d <= 40 (a pair plus a tick)
//   [count] slides, refusals, fallbacks, re-arms, pre-anchor drops as the arm expects
//   [live]  some progress (a pair popped, a byte into the ring or the decoder) every 8M
//           cycles (a pause does not count against it)
//   [pause] (P6b3) while frozen -- the STC's ticks and aud_out held together, as disp_ctl's
//           frz does -- no pair is played or discarded; the chain resumes in step
//           ([sync], no re-arm). +pause_frame=N +pause_len=C: frozen C cycles once N frames
//           have played; +pause_at0=C: frozen C cycles from the reset (before the STC
//           starts: the pre-anchor discard must hold too)
//   [left]  (P6b3i) +left_frame=N: once N frames have played the display leaves the audio's
//           item (left_mask); no pair plays after it, every later one is discarded as a
//           left item's (n_left)
//   [tag]   also (P6b3i) +ep_in=N: every input byte carries item tag N; the tag rides the demux
//           and the ring as in emu, and every frame reaches the gate with tag N
//   [yield] (P6b3i) +vstall: the display reports a stall once the STC runs; with the audio
//           early (+anchor_ofs far negative) and the ring blocking, the gate must yield the
//           audio from its stale end (n_yield) -- [live] is what a missing breaker fails. The
//           arm ends once the source is spent and something was yielded: the tail then waits,
//           rightly, for an STC that runs (10 s behind here: past the [live] window)
//   [switch] (P6b7) +switch_frame=N on the switch stream (both of the clip's tracks): once N
//           frames of track 0 have played, the track switch as player_ctl makes it -- the
//           ring, the decoder and the gate in reset AUD_RST cycles, aud_track = 1 and the
//           demux's realign in its last cycle, the release after it. The first tag after it must be a
//           track-1 AU's (k, found by its PTS); from there [tag] / [pcm] (the golden decoded
//           COLD from AU k) / [start] / [drop] / [sync] score track 1 for SWITCH_M frames
// PASS when every golden pair has been popped (the switch: SWITCH_M frames of track 1).

`default_nettype none
`timescale 1ns/1ps

module av_sync_tb;
    parameter int RING_AW = 15;

    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    // ---- stimulus / goldens ----
    string stem;
    logic [7:0]  ps [];
    logic [31:0] pcm_exp [];
    logic        t_has [], t_der [];
    logic [32:0] t_pts [];
    int n_ps, n_aus, n_pairs, exp_slides, first_pts;
    int anchor_vb, anchor_ofs, dstall_at, dstall_len, jump_frame, jump;
    int exp_under, exp_resync, exp_pre, min_played;
    int pause_frame, pause_len, pause_at0, left_frame, vstall, exp_yield, ep_in;
    // P6b7: the track switch
    int switch_frame, n1, sw_m;
    logic [32:0] t1_pts [];
    logic        t1_has [], t1_der [];
    logic [31:0] pcm1 [];
    localparam int AUD_RST = 16;          // player_ctl's AUD_RST_CYC in emu
    wire [1:0] dmx_aep;
    logic [3:0] left_mask;
    logic       left_on;
    logic frz;                            // the pause (below)

    initial begin
        int fd, r;
        logic [31:0] v0, v1, v2;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("anchor_vb=%d", anchor_vb))   anchor_vb = 0;
        if (!$value$plusargs("anchor_ofs=%d", anchor_ofs)) anchor_ofs = 0;
        if (!$value$plusargs("dstall_at=%d", dstall_at))   dstall_at = -1;
        if (!$value$plusargs("dstall_len=%d", dstall_len)) dstall_len = 0;
        if (!$value$plusargs("jump_frame=%d", jump_frame)) jump_frame = -1;
        if (!$value$plusargs("jump=%d", jump))             jump = 0;
        if (!$value$plusargs("exp_under=%d", exp_under))   exp_under = 0;
        if (!$value$plusargs("exp_resync=%d", exp_resync)) exp_resync = 0;
        if (!$value$plusargs("exp_pre=%d", exp_pre))       exp_pre = 0;
        if (!$value$plusargs("min_played=%d", min_played)) min_played = 4096;
        if (!$value$plusargs("pause_frame=%d", pause_frame)) pause_frame = -1;
        if (!$value$plusargs("pause_len=%d", pause_len))     pause_len = 0;
        if (!$value$plusargs("pause_at0=%d", pause_at0))     pause_at0 = 0;
        if (!$value$plusargs("left_frame=%d", left_frame))   left_frame = -1;
        vstall = $test$plusargs("vstall"); exp_yield = $test$plusargs("exp_yield");
        if (!$value$plusargs("ep_in=%d", ep_in)) ep_in = 0;
        if (!$value$plusargs("switch_frame=%d", switch_frame)) switch_frame = -1;
        if (switch_frame >= 0) begin
            fd = $fopen({stem, ".meta1"}, "r");
            if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta1", stem);
            r = $fscanf(fd, "%d %d", n1, sw_m);
            $fclose(fd);
            t1_pts = new[n1 + sw_m - 1]; t1_has = new[n1 + sw_m - 1]; t1_der = new[n1 + sw_m - 1];
            pcm1 = new[n1 * sw_m * 2048];
            fd = $fopen({stem, ".tags1"}, "r");
            for (int i = 0; i < n1 + sw_m - 1; i++) begin
                logic [35:0] p;
                r = $fscanf(fd, "%h %h %h", v0, v1, p);
                t1_has[i] = v0[0]; t1_der[i] = v1[0]; t1_pts[i] = p[32:0];
            end
            $fclose(fd);
            fd = $fopen({stem, ".pcm1"}, "r");
            for (int i = 0; i < n1 * sw_m * 2048; i++) begin
                r = $fscanf(fd, "%h %h", v0, v1); pcm1[i] = {v0[15:0], v1[15:0]};
            end
            $fclose(fd);
        end
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d %d %d", n_ps, n_aus, exp_slides, first_pts);
        $fclose(fd);
        n_pairs = n_aus * 2048;
        ps = new[n_ps]; pcm_exp = new[n_pairs];
        t_has = new[n_aus]; t_der = new[n_aus]; t_pts = new[n_aus];
        fd = $fopen({stem, ".ps"}, "r");
        for (int i = 0; i < n_ps; i++) begin r = $fscanf(fd, "%h", v0); ps[i] = v0[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".pcm"}, "r");
        for (int i = 0; i < n_pairs; i++) begin
            r = $fscanf(fd, "%h %h", v0, v1); pcm_exp[i] = {v0[15:0], v1[15:0]};
        end
        $fclose(fd);
        fd = $fopen({stem, ".tags"}, "r");
        for (int i = 0; i < n_aus; i++) begin
            logic [35:0] p;
            r = $fscanf(fd, "%h %h %h", v0, v1, p);
            t_has[i] = v0[0]; t_der[i] = v1[0]; t_pts[i] = p[32:0];
        end
        $fclose(fd);
        repeat (20) @(posedge clk);
        rst_n = 1'b1;
    end

    // ---- the chain ----
    logic [7:0]  in_byte, vid_byte, aud_byte, sp_byte;
    logic        in_valid, in_ready, vid_valid, vid_mark, aud_valid, aud_fs, aud_ready;
    logic [32:0] vid_pts, aud_pts, aud_fpts, sp_pts;
    logic        vid_pts_valid, aud_pts_valid, aud_fpts_valid, sp_valid, sp_fs, sp_pts_valid;
    logic        pes_hdr_ok, aud_ss_seen, aud_pes_hit, saw_pack;
    logic [3:0]  aud_ss_id;

    // the track switch (P6b7): the audio chain's reset, then the track and the realign
    logic       sw_on, sw_rst, sw_rlgn;
    logic [3:0] sw_track;
    int         sw_cnt;
    wire        a_rst_n = rst_n && !sw_rst;
    ps_demux u_dmx (
        .clk, .rst_n, .in_byte, .in_ep(ep_in[1:0]), .in_valid, .in_ready, .aud_frame_ep(dmx_aep),
        .aud_track(sw_track), .aud_realign(sw_rlgn), .sp_track(5'd0), .sp_enable(1'b0),
        .vid_byte, .vid_valid, .vid_ready(1'b1), .vid_mark,
        .aud_byte, .aud_valid, .aud_frame_start(aud_fs), .aud_ready,
        .vid_pts, .vid_pts_valid, .aud_pts, .aud_pts_valid,
        .aud_frame_pts(aud_fpts), .aud_frame_pts_valid(aud_fpts_valid),
        .sp_byte, .sp_valid, .sp_frame_start(sp_fs), .sp_pts, .sp_pts_valid,
        .pes_hdr_ok, .aud_ss_seen, .aud_ss_id, .aud_pes_hit, .saw_pack);

    logic [7:0]  r_byte;
    logic        r_valid, r_ready, tag_valid, tag_der, tag_has, tag_pop;
    logic [1:0]  tag_ep_w;
    logic [32:0] tag_pts_w;
    logic [RING_AW+1:0] r_fill, r_fill_max;
    logic [15:0] r_aus, r_slides, r_derived, r_jumps;
    logic [31:0] r_bp;
    aud_ring #(.AW(RING_AW)) u_ring (
        .clk, .rst_n(a_rst_n), .in_byte(aud_byte), .in_valid(aud_valid), .in_frame_start(aud_fs),
        .in_pts(aud_fpts), .in_pts_valid(aud_fpts_valid), .in_ep(dmx_aep), .in_ready(aud_ready),
        .out_byte(r_byte), .out_valid(r_valid), .out_ready(r_ready),
        .tag_valid, .tag_derived(tag_der), .tag_has, .tag_pts(tag_pts_w), .tag_ep(tag_ep_w), .tag_pop,
        .fill(r_fill), .fill_max(r_fill_max), .aus(r_aus), .slides(r_slides),
        .derived(r_derived), .jumps(r_jumps), .bp_cycles(r_bp));

    // the decoder's input, with the bench's stall (+dstall_at bytes in, +dstall_len)
    logic        dstall;
    logic        d_ready;
    logic [15:0] pcm_l, pcm_r;
    logic        pcm_valid, pcm_ready;
    logic [15:0] a_frames, a_refused, a_overruns, a_sat, a_clip, mark_id, tr_val;
    logic [7:0]  a_last_err;
    logic        mark_valid, vop_start, vop_done, tr_valid, tr_kind;
    logic [3:0]  vop_op;
    logic [11:0] tr_pc;
    logic [13:0] tr_addr;
    assign r_ready = d_ready && !dstall;
    at3p_top u_dec (
        .clk, .rst_n(a_rst_n), .in_byte(r_byte), .in_valid(r_valid && !dstall), .in_ready(d_ready),
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready,
        .frames(a_frames), .refused(a_refused), .last_err(a_last_err), .overruns(a_overruns),
        .sat_count(a_sat), .clip_count(a_clip),
        .mark_valid, .mark_id, .vop_start, .vop_op, .vop_done,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    logic [32:0] stc;
    logic        stc_run;
    logic [15:0] audio_l, audio_r, o_frames, o_stale, o_pre;
    logic [7:0]  o_under, o_resync, o_fb, o_miss;
    logic signed [15:0] o_err;
    logic        o_running, o_err_seen, o_tick, o_play;
    logic [13:0] o_fill;
    logic [15:0] o_left, o_yield;
    aud_out u_out (
        .clk, .rst_n(a_rst_n), .pcm_l, .pcm_r, .pcm_valid, .pcm_ready,
        .tag_valid, .tag_has, .tag_pts(tag_pts_w), .tag_ep(tag_ep_w), .tag_pop,
        .stc, .stc_run, .ring_blocked(aud_valid && !aud_ready), .freeze(frz),
        .left_mask(left_mask), .vid_stalled(vstall != 0 && stc_run), .n_left(o_left), .n_yield(o_yield),
        .audio_l, .audio_r, .running(o_running), .frames_played(o_frames),
        .under(o_under), .resync(o_resync), .fallback(o_fb), .tag_miss(o_miss),
        .stale(o_stale), .pre_drop(o_pre), .err_ticks(o_err), .err_seen(o_err_seen),
        .sample_tick(o_tick), .play(o_play), .fill(o_fill));

    // ---- the source ----
    int bi;
    always @(posedge clk) begin
        if (!rst_n) bi <= 0;
        else if (in_valid && in_ready) bi <= bi + 1;
    end
    assign in_valid = rst_n && (bi < n_ps);
    always @* begin
        if (bi < n_ps) in_byte = ps[bi];
        else           in_byte = 8'd0;
    end

    // ---- the decoder stall ----
    int dbytes, dst_left;
    logic dst_done;
    always @(posedge clk) begin
        if (!rst_n) begin dbytes <= 0; dst_left <= 0; dst_done <= 1'b0; end
        else begin
            if (r_valid && r_ready) dbytes <= dbytes + 1;
            if (!dst_done && dstall_at >= 0 && dbytes >= dstall_at) begin
                dst_done <= 1'b1; dst_left <= dstall_len;
            end else if (dst_left > 0) dst_left <= dst_left - 1;
        end
    end
    assign dstall = (dst_left > 0);

    // ---- the track switch (P6b7, +switch_frame): as player_ctl sequences it ----
    always @(posedge clk) begin
        if (!rst_n) begin sw_on <= 1'b0; sw_rst <= 1'b0; sw_rlgn <= 1'b0; sw_track <= 4'd0; sw_cnt <= 0; end
        else begin
            sw_rlgn <= 1'b0;
            if (!sw_on && switch_frame >= 0 && o_frames == switch_frame) begin
                sw_on <= 1'b1; sw_rst <= 1'b1; sw_cnt <= AUD_RST;
            end else if (sw_cnt > 0) begin
                sw_cnt <= sw_cnt - 1;
                // (the track and the realign in the reset's last cycle, the release after: P6b7)
                if (sw_cnt == 2) begin sw_track <= 4'd1; sw_rlgn <= 1'b1; end
                if (sw_cnt == 1) sw_rst <= 1'b0;
            end
        end
    end

    // ---- the display leaves the audio's item (P6b3i, +left_frame) ----
    always @(posedge clk) begin
        if (!rst_n) begin left_mask <= 4'd0; left_on <= 1'b0; end
        else if (!left_on && left_frame >= 0 && o_frames == left_frame) begin left_mask <= 4'b0001; left_on <= 1'b1; end
    end

    // ---- the pause (P6b3): frz holds the STC's ticks and aud_out together ----
    int   frz_left, frz_n;
    logic frz_done;
    always @(posedge clk) begin
        if (!rst_n) begin
            frz <= 1'b0; frz_left <= pause_at0; frz_done <= 1'b0; frz_n <= 0;
        end else begin
            if (!frz_done && pause_frame >= 0 && o_frames == pause_frame) begin
                frz_done <= 1'b1; frz_left <= pause_len;
            end else if (frz_left > 0) frz_left <= frz_left - 1;
            frz <= (frz_left > 1);
            if (frz) frz_n <= frz_n + 1;
        end
    end

    // ---- the STC ----
    int vbytes, tdiv;
    logic jumped;
    always @(posedge clk) begin
        if (!rst_n) begin
            vbytes <= 0; tdiv <= 0; stc <= '0; stc_run <= 1'b0; jumped <= 1'b0;
        end else begin
            if (vid_valid) vbytes <= vbytes + 1;
            if (!stc_run) begin
                if (vbytes >= anchor_vb && !frz) begin
                    stc_run <= 1'b1; tdiv <= 0;
                    stc <= 33'(first_pts + anchor_ofs);
                end
            end else begin
                tdiv <= (tdiv == 299) ? 0 : tdiv + 1;
                if (tdiv == 299 && !frz) stc <= stc + 33'd1;
                if (!jumped && jump_frame >= 0 && o_frames == jump_frame) begin
                    jumped <= 1'b1;
                    stc <= stc + 33'(jump) + ((tdiv == 299) ? 33'd1 : 33'd0);
                end
            end
        end
    end

    // ---- scoring ----
    int ti, g, played, discards, releases, last_prog, cyc, sync_n;
    int sync_min, sync_max;
    // STC * 8 - (tag PTS * 8 + 15 * index), modulo 2**36, signed
    function automatic logic signed [63:0] d_of(input int gi);
        logic [35:0] v;
        v = {stc, 3'b000} - ({t_pts[gi / 2048], 3'b000} + 36'(15 * (gi % 2048)));
        d_of = {{28{v[35]}}, v};
    endfunction
    logic signed [63:0] dd;

    always @(posedge clk) begin
        if (!rst_n) begin
            ti <= 0; g <= 0; played <= 0; discards <= 0; releases <= 0; last_prog <= 0;
            cyc <= 0; sync_n <= 0; sync_min <= 1000; sync_max <= -1000;
        end else begin
            cyc <= cyc + 1;
            // [pause]
            if (frz && (o_play || u_out.discard || u_out.release_now))
                $fatal(1, "FAIL [pause] pair %0d %s while frozen", g,
                       o_play ? "played" : u_out.discard ? "discarded" : "released");
            // [tag]
            if (u_out.fstart_wr && !sw_on) begin
                if (!tag_valid) $fatal(1, "FAIL [tag] PCM frame %0d began with no tag waiting", ti);
                if (ti >= n_aus) begin
                    // past the golden's AUs (a disc cut carries more): not scored
                end else if (tag_has !== t_has[ti] || tag_der !== t_der[ti] ||
                             (t_has[ti] && tag_pts_w !== t_pts[ti]))
                    $fatal(1, "FAIL [tag] AU %0d: got has %0d derived %0d pts %0d, want %0d %0d %0d",
                           ti, tag_has, tag_der, tag_pts_w, t_has[ti], t_der[ti], t_pts[ti]);
                if (tag_valid && tag_ep_w !== ep_in[1:0])
                    $fatal(1, "FAIL [tag] AU %0d reached the gate with item tag %0d, want %0d", ti, tag_ep_w, ep_in);
                ti <= ti + 1;
            end
            // [start]
            if (u_out.release_now && !sw_on) begin
                if (!t_has[g / 2048]) $fatal(1, "FAIL [start] a release on untagged pair %0d", g);
                dd = d_of(g);
                if (dd < 0 || dd >= 15)
                    $fatal(1, "FAIL [start] release at pair %0d: STC*8 - pos = %0d (want 0..14)", g, dd);
                releases <= releases + 1;
            end
            // [drop] / [pcm] / [sync]
            // [left]
            if (left_on && o_play) $fatal(1, "FAIL [left] pair %0d played after the display left its item", g);
            if (u_out.discard && (u_out.d_left || u_out.d_yield)) begin
                // a left item's leftover, or the stall breaker: counted apart, judged by [left] / [yield]
            end else if (u_out.discard && !sw_on) begin
                if (stc_run) begin
                    if (d_of(g) < 15)
                        $fatal(1, "FAIL [drop] pair %0d discarded at d = %0d (not wholly past)", g, d_of(g));
                end else if (!(aud_valid && !aud_ready))
                    $fatal(1, "FAIL [drop] pair %0d discarded before the STC with the ring not blocking", g);
                discards <= discards + 1;
            end
            if (o_play && !sw_on) begin
                if (g >= n_pairs) $fatal(1, "FAIL [pcm] played past the golden (%0d pairs)", n_pairs);
                if (u_out.h_pair !== pcm_exp[g])
                    $fatal(1, "FAIL [pcm] pair %0d: got %08h want %08h", g, u_out.h_pair, pcm_exp[g]);
                if ((g % 2048) == 0 && stc_run && t_has[g / 2048]) begin
                    dd = d_of(g);
                    if (dd < -8 || dd > 40)
                        $fatal(1, "FAIL [sync] frame %0d plays at d = %0d eighth-ticks (want -8..40)", g / 2048, dd);
                    if (dd < sync_min) sync_min <= dd;
                    if (dd > sync_max) sync_max <= dd;
                    sync_n <= sync_n + 1;
                end
                played <= played + 1;
            end
            if (u_out.pop && !sw_on) g <= g + 1;
            // [live]
            if (u_out.pop || (aud_valid && aud_ready) || (r_valid && r_ready) || frz) last_prog <= cyc;
            else if (cyc - last_prog > 8_000_000)
                $fatal(1, "FAIL [live] no progress for 8M cycles (pairs %0d/%0d, ring %0d bytes, STC %s)",
                       g, n_pairs, r_fill, stc_run ? "running" : "not started");
            // the end (S10: the breaker's arm ends when the source is spent and it yielded)
            if (exp_yield && bi >= n_ps && !(aud_valid && !aud_ready) && o_yield != 16'd0) begin
                $display("av_sync_tb: the stall breaker yielded %0d pairs while the ring blocked the demux; %0d played, %0d popped",
                         o_yield, played, g);
                $display("PASS: av_sync_tb");
                $finish;
            end
            if (g == n_pairs && !sw_on) begin
                if (r_slides !== 16'(exp_slides))
                    $fatal(1, "FAIL [count] slides %0d, want %0d", r_slides, exp_slides);
                if (a_refused !== 16'd0 || a_sat !== 16'd0)
                    $fatal(1, "FAIL [count] %0d refused, %0d saturations", a_refused, a_sat);
                if (o_fb !== 8'd0) $fatal(1, "FAIL [count] %0d fallback releases", o_fb);
                if (o_miss !== 8'd0) $fatal(1, "FAIL [count] %0d tags missed", o_miss);
                if ((o_under != 0) != (exp_under != 0))
                    $fatal(1, "FAIL [count] %0d underrun re-arms (want %s)", o_under, exp_under ? "some" : "none");
                if (o_resync !== 8'(exp_resync))
                    $fatal(1, "FAIL [count] %0d resync re-arms, want %0d", o_resync, exp_resync);
                if ((o_pre != 0) != (exp_pre != 0))
                    $fatal(1, "FAIL [count] %0d pre-anchor drops (want %s)", o_pre, exp_pre ? "some" : "none");
                if (played < min_played)
                    $fatal(1, "FAIL [count] only %0d pairs played", played);
                if (left_frame >= 0 && o_left == 16'd0) $fatal(1, "FAIL [left] nothing discarded as a left item's");
                if (exp_yield && o_yield == 16'd0) $fatal(1, "FAIL [yield] the stall breaker never yielded");
                if (!exp_yield && o_yield != 16'd0) $fatal(1, "FAIL [yield] %0d pairs yielded with no stall", o_yield);
                if ((pause_len > 0 || pause_at0 > 0) && frz_n == 0)
                    $fatal(1, "FAIL [pause] the pause never happened (the arm measured nothing)");
                $display("av_sync_tb: %0d pairs (%0d played, %0d discarded: %0d stale, %0d pre-anchor), %0d releases, %0d tags (%0d derived), slides %0d, re-arms %0d underrun / %0d resync, frame-start d %0d..%0d eighth-ticks over %0d, ring max %0d bytes, %0d cycles (%0d frozen)",
                         n_pairs, played, discards, o_stale, o_pre, releases, ti, r_derived, r_slides,
                         o_under, o_resync, sync_min, sync_max, sync_n, r_fill_max, cyc, frz_n);
                $display("av_sync_tb: left-item discards %0d, stall yields %0d", o_left, o_yield);
                $display("PASS: av_sync_tb");
                $finish;
            end
        end
    end

    // ---- [switch] (P6b7): track 1 after the switch, from its first AU k ----
    int  k1, ti1, g1, played1, disc1, rel1, f0_diff;
    int  dl, dr;
    logic [31:0] gw;
    int  fmax [0:7];
    localparam int SW_TOL = 4;          // LSB, frames 1.. after the switch (the stale-history residue)
    logic k1_ok;
    function automatic logic signed [63:0] d1_of(input int kk, input int gi);
        logic [35:0] v;
        v = {stc, 3'b000} - ({t1_pts[kk + gi / 2048], 3'b000} + 36'(15 * (gi % 2048)));
        d1_of = {{28{v[35]}}, v};
    endfunction
    always @(posedge clk) begin
        int kk;
        if (!rst_n || !sw_on) begin
            k1 <= 0; k1_ok <= 1'b0; ti1 <= 0; g1 <= 0; played1 <= 0; disc1 <= 0; rel1 <= 0; f0_diff <= 0;
            for (int i = 0; i < 8; i++) fmax[i] = 0;
        end else if (a_rst_n) begin
            kk = k1;
            if (u_out.fstart_wr) begin
                if (!tag_valid) $fatal(1, "FAIL [tag] track-1 frame %0d began with no tag waiting", ti1);
                if (!k1_ok) begin
                    kk = -1;
                    for (int i = 0; i < n1 + sw_m - 1; i++) if (kk < 0 && tag_has && tag_pts_w === t1_pts[i]) kk = i;
                    if (kk < 0)
                        $fatal(1, "FAIL [switch] the first tag after the switch (has %0d pts %0d) is no track-1 AU's", tag_has, tag_pts_w);
                    if (kk >= n1)
                        $fatal(1, "FAIL [switch] track 1 starts at AU %0d: too late for the golden (%0d)", kk, n1);
                    k1 <= kk; k1_ok <= 1'b1;
                end else if (kk + ti1 < n1 + sw_m - 1 &&
                             (tag_has !== t1_has[kk + ti1] || tag_der !== t1_der[kk + ti1] || tag_pts_w !== t1_pts[kk + ti1]))
                    $fatal(1, "FAIL [tag] track-1 AU %0d: got has %0d derived %0d pts %0d, want %0d %0d %0d", kk + ti1,
                           tag_has, tag_der, tag_pts_w, t1_has[kk + ti1], t1_der[kk + ti1], t1_pts[kk + ti1]);
                ti1 <= ti1 + 1;
            end
            if (g1 < sw_m * 2048) begin
                if (u_out.release_now) begin
                    dd = d1_of(kk, g1);
                    if (dd < 0 || dd >= 15)
                        $fatal(1, "FAIL [start] track-1 release at pair %0d of AU %0d: STC*8 - pos = %0d (want 0..14)", g1, kk, dd);
                    rel1 <= rel1 + 1;
                end
                if (u_out.discard) begin
                    if (!stc_run || d1_of(kk, g1) < 15)
                        $fatal(1, "FAIL [drop] track-1 pair %0d discarded at d = %0d (not wholly past)", g1, d1_of(kk, g1));
                    disc1 <= disc1 + 1;
                end
                if (o_play) begin
                    // Frame 0 after the switch is scored for timing only, and the frames after it
                    // within SW_TOL LSB of the golden decoded COLD from AU k: the decoder's history
                    // RAMs (the overlap, the IPQF history, the previous frame's window and gain data)
                    // are not cleared by a reset, so frame 0 blends the old track's overlap tail
                    // and a residue of a few LSB lingers (ffmpeg keeps its history across a seek
                    // too: no .flush). docs/at3p_decoder.md S8, transport.md S9.
                    gw = pcm1[kk * sw_m * 2048 + g1];
                    dl = $signed(u_out.h_pair[31:16]) - $signed(gw[31:16]);
                    dr = $signed(u_out.h_pair[15:0]) - $signed(gw[15:0]);
                    if (dl < 0) dl = -dl;
                    if (dr < 0) dr = -dr;
                    if (g1 < 2048) begin
                        if (dl != 0 || dr != 0) f0_diff <= f0_diff + 1;
                    end else begin
                        if (dl > fmax[g1 / 2048]) fmax[g1 / 2048] = dl;
                        if (dr > fmax[g1 / 2048]) fmax[g1 / 2048] = dr;
                        if (dl > SW_TOL || dr > SW_TOL)
                            $fatal(1, "FAIL [pcm] track-1 pair %0d (from AU %0d, cold): got %08h want %08h (> %0d LSB)",
                                   g1, kk, u_out.h_pair, pcm1[kk * sw_m * 2048 + g1], SW_TOL);
                    end
                    if ((g1 % 2048) == 0) begin
                        dd = d1_of(kk, g1);
                        if (dd < -8 || dd > 40)
                            $fatal(1, "FAIL [sync] track-1 frame %0d plays at d = %0d eighth-ticks (want -8..40)", g1 / 2048, dd);
                    end
                    played1 <= played1 + 1;
                end
                if (u_out.pop) g1 <= g1 + 1;
            end else begin
                if (r_slides !== 16'd0 || a_refused !== 16'd0 || a_sat !== 16'd0 || o_fb !== 8'd0 || o_miss !== 8'd0)
                    $fatal(1, "FAIL [count] after the switch: slides %0d, refused %0d, saturations %0d, fallbacks %0d, tags missed %0d",
                           r_slides, a_refused, a_sat, o_fb, o_miss);
                if (played1 < 2 * 2048) $fatal(1, "FAIL [switch] only %0d track-1 pairs played (frame 1 on is the exact part)", played1);
                $display("av_sync_tb: the switch after %0d frames of track 0 (%0d pairs popped); track 1 from its AU %0d (PTS %0d): %0d pairs, %0d played, %0d discarded, %0d releases, %0d tags; frame 0's pairs differing from cold (stale history) %0d; the largest difference in frames 1, 2: %0d, %0d LSB",
                         switch_frame, g, k1, t1_pts[k1], g1, played1, disc1, rel1, ti1, f0_diff, fmax[1], fmax[2]);
                $display("PASS: av_sync_tb");
                $finish;
            end
        end
    end

endmodule

`default_nettype wire
