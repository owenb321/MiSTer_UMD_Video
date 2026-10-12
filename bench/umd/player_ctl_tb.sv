// bench/umd/player_ctl_tb.sv -- umd/player_ctl.sv (P6b3, docs/transport.md S2.1-S2.5) in a
// mock of what surrounds it in emu, playing a script from tools/player_ctl_ref.py.
//
// The mocks: the READER answers NAV_CHAP from the title's chapters as umd_reader's
// contract says (rank = chapters at or before the key, cur / prev = the last two of them,
// next = the first after), 50-300 cycles later, and lands a NAV_SEEK on its key clamped
// into the item's IN..OUT (nav_skip) 500-2,000 cycles after taking it, with an item start;
// nav_ready drops at random. The DISPLAY shows a picture every REFRESH (100) cycles while
// not frozen, 1,501 ticks apart; after a flush it waits for the landing's target and shows
// exactly it 200 unfrozen cycles later (a NOPIC directive: never, until the watchdog's
// target without a skip). The output queue drains 0-40 cycles into a flush.
//
// Arms (every failure is $fatal; PASS marker "PASS: player_ctl_tb"):
//   [port]   one command at a time: no request while one is in flight; a SEEK's key names
//            an item that exists
//   [flush]  seek_flush rises exactly at a SEEK's accepting edge (with the reader's flush),
//            lasts >= FLUSH_MIN cycles, falls only after the queue has been idle IDLE_MIN
//            cycles in a row; rd_hold covers it and outlasts it; nothing else raises it
//   [freeze] the display is frozen at every SEEK's accepting edge (the picture held from
//            the command to the flush); PAUSE / STOP freeze and PLAY releases; STOP shows
//            the idle screen and PLAY takes it away
//   [land]   (P6b3i) every item start (the mount's, the walk's, a seek's landing) writes its
//            entry in the display's item table the cycle after: {its tag, IN or the seek's
//            target (nav_skip), its OUT, last, skip}; the watchdog's rewrite has no skip
//   [key]    (P6b3i) after every pickup the transport's key_item is the item on screen
//   [hold]   (P6b3i) item_hold is up exactly when the item the reader is about to start is
//            4 or more past the one on screen (not checked while a gesture or seek runs);
//            the mock reader waits while it is up. The mock walks the items after every
//            landing and the mock display moves into the next item at the current one's OUT
//   [audio]  a track switch: the audio chain's reset for AUD_RST_CYC cycles, its LAST cycle the
//            new track and the demux's realign (P6b7: not the release's own cycle), then the new
//            track and the demux's realign in the cycle it ends; the new track declared,
//            the next after the old (AUDIO) or the one asked (AUDIO_SET); the default at the
//            mount the lowest declared
//   [wd]     a landing with no picture ends in a SEEK_WD event and a target without a skip
//   [tend]   (fix/skip-last-picture) a landing whose display ENDS with no picture (the stream's END
//            inside the skip) ends the seek without the watchdog and posts one TITLE_END
//   [sub]    P7: off after a mount (P9 M4b: a SUB_SET's event carries data[6], the button's not); each SUB steps Off -> the lowest declared subtitle track ->
//            each higher -> Off (recomputed here from the title's mask); the new state appears
//            only inside the change's flush, which lasts SUB_FL_CYC - 1 cycles; a SUB event
//            carries it
//   [event]  nothing lost from the event FIFO; a reserved command posts BAD
//   [trick]  (P6b4) one_frame changes only at a SEEK's accepting edge; the audio chain is in
//            reset while it is up; no TITLE_END on a hop's stream (the mock display ends it
//            after the hop's picture, as the real end-of-stream word does); the reader held
//            while a hop's picture is held; hops issued HOP_MIN apart at least, each only
//            after the last one's picture was shown; a hop's item start writes no skip
//   [landpts] (P6b7) land_pts is the first picture every landing shows (a seek's, a hop's, the
//            watchdog's late one, the mount's): the display's target, which [land] and the
//            model tie to umd_nav_ref -- and it holds between landings
//   [lat]    (P6b7) every seek that lands with a picture and is not a hop: seek_lat = the cycles
//            (one strobe a cycle here) from the seek machine leaving idle to that picture;
//            it holds between them (a hop's or a watchdog's landing leaves it); coverage required
//   [proj]   (P6b7, found on the rig) after a chapter press's landing the chapter never drops
//            below the projected one: the mock's first picture after a skip landing starts up to one
//            picture BEFORE the target half the time (the real display shows the picture
//            containing the mark, D2), which ranks as the previous chapter by its PTS
//   [goto]   (P6c) Go To's query port: gq_req raised at random with a key (one no other query asks),
//            held until gq_done; gq_done pulses exactly with the answer of the NAV_CHAP that
//            carried that key, never for a press's or the tracker's query nor unasked; every
//            request answered within GQ_LIM cycles with no gesture in flight (the tracker and the
//            gestures go first, never for ever); coverage required. The mock reader lands a NAV_TIME (command 15) as
//            umd_nav_ref.Title.time_seek does (the model rechecks it: X lines); [land] wants a TIME
//            past the end (the last item's OUT - 4) to land with NO skip (it plays out to END)
//   [model]  tools/player_ctl_ref.py check on the log (the runner): the decisions vs
//            umd_nav_ref -- P6b4: every hop's request from the carried target and the wall
//            time at each speed (umd_nav_ref.hop_request / hop_land), the title's ends, and
//            every exit's seek to the shown key
`timescale 1ns/1ps
`default_nettype none
module player_ctl_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam int REFRESH = 100, MERGE = 2000, WD = 20000, FLUSH_MIN = 16, IDLE_MIN = 8, AUD_RST = 16, HOLD_TAIL = 4;
localparam int HOP_MIN = 1500, TICK_N = 15;   // P6b4: a strobe every cycle, 15 ticks (1501 a REFRESH)
reg clk = 0, rst_n = 0;
always #5 clk = ~clk;
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

// ---- the title and the script ------------------------------------------------------------
string stem;
integer n_items, n_chap, n_cmd, t_end, fdl, want_hold = 0, want_trick = 0, n_pl = 1;
reg [15:0] aud_pres;
reg [31:0] sub_pres;
longint it_in [0:255], it_out [0:255];
reg [63:0] chap [0:255];
integer s_cyc [0:1023], s_code [0:1023], s_arg [0:1023];
longint s_item [0:1023], s_pts [0:1023];
initial begin : load
    integer fd, rc, i;
    string tg;
    longint a, b, c;
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    fd = $fopen({stem, ".title"}, "r");
    if (fd == 0) `FAIL("harness", "no .title")
    rc = $fscanf(fd, "%s %d %d %d %d %d\n", tg, n_items, a, n_chap, c, n_pl);   // P9: the playlists
    aud_pres = a[15:0];
    sub_pres = c[31:0];
    for (i = 0; i < n_items; i++) rc = $fscanf(fd, "%s %d %d\n", tg, it_in[i], it_out[i]);
    for (i = 0; i < n_chap; i++) begin rc = $fscanf(fd, "%s %d %d\n", tg, a, b); chap[i] = {a[15:0], b[47:0]}; end
    $fclose(fd);
    fd = $fopen({stem, ".script"}, "r");
    rc = $fscanf(fd, "%d %d\n", n_cmd, t_end);
    for (i = 0; i < n_cmd; i++) rc = $fscanf(fd, "%d %d %d %d %d\n", s_cyc[i], s_code[i], s_item[i], s_pts[i], s_arg[i]);
    $fclose(fd);
    fdl = $fopen({stem, ".log"}, "w");
    want_hold = $test$plusargs("want_hold");
    want_trick = $test$plusargs("want_trick");
end

// ---- A7: the UMD Main as player_ctl sees it (docs/hps_host.md §5) ---------------------------------
//   default        host_ok throughout (every scenario's SUB presses as before)
//   +no_host       never a heartbeat (stock Main): every SUB press refused with a HOST event,
//                  the subtitles never on; +host_bad: the heartbeat's PROTO mismatched
//   +host_drop=C   the heartbeat stops at cycle C: subtitles on then go off (flushed, SUB off,
//                  then HOST), and later presses are refused; +host_drop_on: 2,000 cycles after
//                  the subtitles first come on
reg host_ok = 1'b1, host_bad = 1'b0;
integer host_drop = -1;
initial begin
    if ($test$plusargs("no_host")) host_ok = 1'b0;
    if ($test$plusargs("host_bad")) host_bad = 1'b1;
    if (!$value$plusargs("host_drop=%d", host_drop)) host_drop = -1;
end

// ---- the DUT --------------------------------------------------------------------------------
reg         mount = 0, eject = 0, cmd_valid = 0;
reg  [3:0]  cmd_code = 0, cmd_arg = 0;
reg  [31:0] cmd_item = 0;
reg  [47:0] cmd_pts = 0;
reg  [15:0] cmd_pl = 0;                   // P9: PLAYLIST's playlist (the script's arg field)
wire [15:0] nav_pl;
reg         rd_item_start = 0;
reg  [31:0] rd_item_idx = 0;
reg  [47:0] rd_item_out = 0;
wire        nav_req;
wire [2:0]  nav_op;
wire [31:0] nav_item;
wire [47:0] nav_pts;
reg         nav_ready = 0, nav_done = 0;
reg  [2:0]  nav_err = 0;
reg  [31:0] nav_land = 0;
reg  [47:0] nav_skip = 0;
reg  [15:0] ch_rank = 0, ch_count = 0;
reg  [2:0]  ch_valid = 0;
reg  [63:0] ch_cur = 0, ch_prev = 0, ch_next = 0;
reg         gq_req = 0;                   // P6c: Go To's query port ([goto])
reg  [63:0] gq_key = 0;
wire        gq_done;
wire        rd_hold, seek_flush, aud_rst, aud_realign, freeze, idle_screen, ep_we, ep_last, ep_skip, item_hold;
wire [3:0]  aud_track;
wire        sub_on, sub_flush;           // P7
wire [4:0]  sub_track;
wire [1:0]  ep_wi;
wire [32:0] ep_in, ep_out;
reg  [1:0]  sh_ep = 0;
reg  [32:0] sh_pts = 0;
reg         sh_pts_v = 0, pick = 0, ended_s = 0, hop_end = 0, rec_idle = 1, ended_k = 0, endskip = 0;
// the script's END, a hop's stream ended (P6b4), or a landing's display ended with no picture
// (fix/skip-last-picture: the END inside the skip)
wire        ended = ended_s | hop_end | ended_k;
wire        one_frame, tk_rev;
wire [1:0]  tk_speed;
wire [2:0]  state, last_nav_err;
wire        seeking;
wire [15:0] chapter, n_chapters, n_seeks;
wire [31:0] key_item;
wire [32:0] land_pts;
wire [19:0] seek_lat;
wire [7:0]  n_wd, n_bad, n_press_lost, ev_lost, n_hold;
wire        ev_valid;
wire [3:0]  ev_code;
wire [15:0] ev_data;
// The CLP transient (P7, found on the rig 2026-09-30): umd_reader clears aud_present /
// sub_present at every clip's CLP header and sets one bit per stream as it parses, BEFORE the
// item start (S_MPS). The mock does the same in the CLP_N cycles before each item start: the
// masks read 0, then fill from bit 0 up.
localparam int CLP_N = 40;
integer  clp_n = 0;
wire [5:0]  clp_k    = (clp_n > 0) ? CLP_N[5:0] - clp_n[5:0] : 6'd63;
wire [31:0] clp_mask = (clp_k >= 6'd32) ? 32'hFFFF_FFFF : ((32'd1 << clp_k) - 32'd1);
wire [15:0] aud_seen = aud_pres & clp_mask[15:0];
wire [31:0] sub_seen = sub_pres & clp_mask;
player_ctl #(.MERGE_CYC(MERGE), .WD_CYC(WD), .FLUSH_MIN(FLUSH_MIN), .IDLE_MIN(IDLE_MIN), .AUD_RST_CYC(AUD_RST),
             .HOP_MIN(HOP_MIN), .TICK_DIV(1), .TICK_N(TICK_N)) dut (
    .clk(clk), .rst_n(rst_n), .mount(mount), .eject(eject),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_item(cmd_item), .cmd_pts(cmd_pts), .cmd_arg(cmd_arg),
    .cmd_pl(cmd_pl), .rd_n_playlists(n_pl[15:0]), .bare(1'b0), .nav_pl(nav_pl),
    .rd_item_start(rd_item_start), .rd_item_idx(rd_item_idx), .rd_n_items(n_items), .rd_item_out(rd_item_out),
    .rd_aud_present(aud_seen), .rd_sub_present(sub_seen), .host_ok(host_ok), .host_bad(host_bad),
    .sub_on(sub_on), .sub_track(sub_track), .sub_flush(sub_flush),
    .nav_req(nav_req), .nav_op(nav_op), .nav_item(nav_item), .nav_pts(nav_pts), .nav_ready(nav_ready),
    .nav_done(nav_done), .nav_err(nav_err), .nav_land(nav_land), .nav_skip(nav_skip), .ch_rank(ch_rank),
    .ch_count(ch_count), .ch_valid(ch_valid), .ch_cur(ch_cur), .ch_prev(ch_prev), .ch_next(ch_next),
    .gq_req(gq_req), .gq_key(gq_key), .gq_done(gq_done),
    .rd_hold(rd_hold), .seek_flush(seek_flush), .aud_rst(aud_rst), .aud_track(aud_track), .aud_realign(aud_realign),
    .one_frame(one_frame), .land_pts(land_pts), .seek_lat(seek_lat), .tk_speed(tk_speed), .tk_rev(tk_rev),
    .freeze(freeze), .idle_screen(idle_screen), .ep_we(ep_we), .ep_wi(ep_wi), .ep_in(ep_in), .ep_out(ep_out),
    .ep_last(ep_last), .ep_skip(ep_skip), .item_hold(item_hold), .sh_ep(sh_ep),
    .sh_pts(sh_pts), .sh_pts_v(sh_pts_v), .pick(pick), .ended(ended),
    .rec_idle(rec_idle), .state(state), .seeking(seeking), .chapter(chapter), .n_chapters(n_chapters),
    .key_item(key_item), .n_hold(n_hold), .n_seeks(n_seeks), .n_wd(n_wd), .n_bad(n_bad),
    .n_press_lost(n_press_lost), .last_nav_err(last_nav_err),
    .ev_valid(ev_valid), .ev_code(ev_code), .ev_data(ev_data), .ev_pop(ev_valid), .ev_lost(ev_lost));

// P6b4: a press during trick play is keyed from the picture shown (the DUT's latch condition;
// its state peeked for the model's bookkeeping, as q_track / pq_n are below)
wire    in_trick = (tk_speed != 2'd0) || (dut.sk == 3'd7);

// ---- the script -------------------------------------------------------------------------------
integer m_item = 0;                      // the item the display is in (the mock's own view)
reg        st_q = 0, st_of = 0;          // [land]: the item start one cycle ago (and one_frame then)
integer    st_idx = 0, n_wd_seen = 0;
reg [47:0] st_in = 0;
integer    n_nopic = 0;
integer    n_ek = 0, n_tend_k = 0;   // [tend] landings whose display ended with no picture; TITLE_ENDs during one
integer si = 0;
reg     nopic = 0;
// BADSYNC (directive 103): a reserved command lands in the cycle before the next chapter
// answer, so its event and the answer's contend for one push (the arbiter's case)
reg     bs_arm = 0, bs_fire = 0;
// PRESSSYNC (directive 104): a Next lands in the very cycle a burst's head is answered
// (the press queue's push and pop in one cycle)
reg     ps_arm = 0, ps_fire = 0;
// EXITSYNC (directive 105): during trick play, a PLAY lands in the very cycle the next hop
// becomes due (tk_wall reaches HOP_MIN with the port free): the hop must not be issued with the
// exit (P41's case; the bench peeks at the seek machine for the TIMING only)
reg     es_arm = 0;
integer n_es = 0;
// (an injected command yields to a scripted one due in the same cycle: one command a cycle,
//  and only what reached the DUT is logged or counted -- P6b4's longer scripts met this)
wire scr_now = (si < n_cmd) && (cyc == s_cyc[si]) && (s_code[si] < 100);
always @(posedge clk) begin
    cmd_valid <= 1'b0; mount <= 1'b0;
    if (bs_fire && !scr_now) begin cmd_valid <= 1'b1; cmd_code <= 4'd0; end    // reserved (15 is P6c's TIME)
    if (es_arm && !scr_now && !bs_fire && !ps_fire && dut.sk == 3'd7 && dut.tk_wall == HOP_MIN - 1 &&
        dut.tk_exit == 3'd0 && !dut.nav_req && !dut.q_busy) begin
        cmd_valid <= 1'b1; cmd_code <= 4'd3; es_arm <= 1'b0; n_es <= n_es + 1;
        $fdisplay(fdl, "M %0d %0d %0d %0d %0d %0d", cyc, 3, m_item, sh_pts, tk_speed, tk_rev);
    end
    if (ps_fire && !scr_now) begin
        cmd_valid <= 1'b1; cmd_code <= 4'd5;
        $fdisplay(fdl, "P %0d %0d %0d %0d %0d %0d", cyc, 0, m_item, sh_pts, seeking, in_trick);
    end
    if (cyc == 50) rst_n <= 1'b1;
    if (cyc == 100) mount <= 1'b1;
    if (si < n_cmd && cyc == s_cyc[si]) begin
        if (s_code[si] < 100) begin
            cmd_valid <= 1'b1; cmd_code <= s_code[si][3:0]; cmd_item <= s_item[si][31:0];
            cmd_pts <= s_pts[si][47:0]; cmd_arg <= s_arg[si][3:0]; cmd_pl <= s_arg[si][15:0];
            if (s_code[si] == 5 || s_code[si] == 6)
                $fdisplay(fdl, "P %0d %0d %0d %0d %0d %0d", cyc, s_code[si] == 6, m_item, sh_pts, seeking, in_trick);
            if (s_code[si] == 7) $fdisplay(fdl, "G %0d %0d %0d %0d", cyc, s_item[si], s_pts[si], in_trick);
            // P6b4: the transport commands, with the picture shown and trick play's state
            if (s_code[si] <= 4 || s_code[si] == 10 || s_code[si] == 11)
                $fdisplay(fdl, "M %0d %0d %0d %0d %0d %0d", cyc, s_code[si], m_item, sh_pts, tk_speed, tk_rev);
        end
        if (s_code[si] == 100) nopic <= 1'b1;
        if (s_code[si] == 106) endskip <= 1'b1;
        if (s_code[si] == 103) bs_arm <= 1'b1;
        if (s_code[si] == 104) ps_arm <= 1'b1;
        if (s_code[si] == 105) es_arm <= 1'b1;
        if (s_code[si] == 101) ended_s <= 1'b1;
        si <= si + 1;
    end
end

// ---- the mock reader -------------------------------------------------------------------------
integer  r_lat = 0, r_rank, k;
reg      r_busy = 0, r_seek = 0, r_walk = 0, te_pend = 0;
// the walk (P6b3i): after a landing the mock starts the following items, WDELAY cycles
// apart, each waiting while item_hold is up; a SEEK stops it until its landing
localparam int WDELAY = 700;
integer  w_next = 1 << 30, w_tmr = 0;
reg [63:0] r_key;
longint  r_pts, r_t;
localparam longint END_GUARD = 4;      // the reader's clamp below OUT (umd_reader.sv)
integer  r_it;
always @(posedge clk) begin
    nav_done <= 1'b0; rd_item_start <= 1'b0;
    if (rd_item_start) te_pend <= 1'b0;      // (st_te sampled it with the item start)
    if (clp_n > 0) clp_n = clp_n - 1;
    if (r_walk && !r_busy && w_next < n_items && w_tmr == CLP_N + 1) clp_n = CLP_N;   // the walk's next CLP
    if (r_busy && r_seek && r_lat == CLP_N + 1) clp_n = CLP_N;                        // a seek's landing's CLP
    if (cyc == 300) begin                // the mount's walk: item 0 starts at its IN
        rd_item_start <= 1'b1; rd_item_idx <= 0; rd_item_out <= it_out[0][47:0]; nav_skip <= it_in[0][47:0];
        r_walk <= 1'b1; w_next = 1; w_tmr = WDELAY;
    end else if (r_walk && !r_busy && w_next < n_items && !(nav_req && nav_ready)) begin
        if (w_tmr > 0) w_tmr = w_tmr - 1;
        else begin
            rd_item_idx <= w_next;                          // the item about to start (S_ITEM)
            if (!item_hold && rd_item_idx == w_next) begin
                rd_item_start <= 1'b1; rd_item_out <= it_out[w_next][47:0]; nav_skip <= it_in[w_next][47:0];
                w_next = w_next + 1; w_tmr = WDELAY;
            end
        end
    end
    nav_ready <= r_walk && !r_busy && ($urandom % 8 != 0);
    if (nav_req && nav_ready) begin
        if (r_busy) `FAIL("port", "a command taken while one is in flight")
        r_busy <= 1'b1;
        if (nav_op == 3'd2) begin                             // NAV_CHAP
            r_seek <= 1'b0; r_lat <= 50 + $urandom % 250;
            nav_err <= 3'd0;                                  // (umd_reader's S_MK: a query answers its own)
            r_key = (nav_item[31:16] != 0) ? 64'hFFFF_FFFF_FFFF_FFFF : {nav_item[15:0], nav_pts};
            r_rank = 0;
            for (k = 0; k < n_chap; k++) if (chap[k] <= r_key) r_rank = k + 1;
            ch_rank <= r_rank; ch_count <= n_chap;
            ch_valid <= {r_rank < n_chap, r_rank >= 2, r_rank >= 1};
            ch_cur <= (r_rank >= 1) ? chap[r_rank - 1] : 64'd0;
            ch_prev <= (r_rank >= 2) ? chap[r_rank - 2] : 64'd0;
            ch_next <= (r_rank < n_chap) ? chap[r_rank] : 64'd0;
        end else if (nav_op == 3'd1) begin                    // NAV_SEEK
            te_pend <= 1'b0;
            if (nav_item >= n_items) `FAIL("port", $sformatf("a SEEK to item %0d of %0d", nav_item, n_items))
            r_seek <= 1'b1; r_lat <= 500 + $urandom % 1500;
            r_pts = nav_pts;
            if (r_pts > ((it_out[nav_item] < END_GUARD) ? 0 : it_out[nav_item] - END_GUARD))   // [IN, OUT - 4] (umd_nav_ref.clamp)
                r_pts = (it_out[nav_item] < END_GUARD) ? 0 : it_out[nav_item] - END_GUARD;
            if (r_pts < it_in[nav_item]) r_pts = it_in[nav_item];
            nav_land <= nav_item; nav_skip <= r_pts[47:0]; nav_err <= 3'd0;
            w_next = 1 << 30;                                 // the walk stops until the landing
            $fdisplay(fdl, "S %0d %0d %0d -1", cyc, nav_item, nav_pts);
        end else if (nav_op == 3'd4) begin                    // P6c NAV_TIME: the playlist's time
            // the items' spans [start, start + OUT - IN): the one holding it, else the last at OUT
            r_seek <= 1'b1; r_lat <= 500 + $urandom % 1500;
            r_t = nav_pts; r_it = 0;
            while (r_it + 1 < n_items && r_t >= ((it_out[r_it] > it_in[r_it]) ? it_out[r_it] - it_in[r_it] : 0)) begin
                r_t = r_t - ((it_out[r_it] > it_in[r_it]) ? it_out[r_it] - it_in[r_it] : 0); r_it = r_it + 1;
            end
            r_pts = (r_t < ((it_out[r_it] > it_in[r_it]) ? it_out[r_it] - it_in[r_it] : 0)) ? it_in[r_it] + r_t : it_out[r_it];
            if (r_pts > ((it_out[r_it] < END_GUARD) ? 0 : it_out[r_it] - END_GUARD))   // [IN, OUT - 4] (umd_nav_ref.clamp)
                r_pts = (it_out[r_it] < END_GUARD) ? 0 : it_out[r_it] - END_GUARD;
            if (r_pts < it_in[r_it]) r_pts = it_in[r_it];
            nav_land <= r_it; nav_skip <= r_pts[47:0]; nav_err <= 3'd0;
            te_pend <= (r_it == n_items - 1) && (r_pts == it_out[r_it] - END_GUARD);   // past the end (D16)
            w_next = 1 << 30;
            $fdisplay(fdl, "S %0d -1 %0d -2", cyc, nav_pts);
            $fdisplay(fdl, "X %0d %0d %0d %0d", cyc, nav_pts, r_it, r_pts);
        end else if (nav_op == 3'd3) begin                    // P9 NAV_PLAY: a seek on the same title (the
            te_pend <= 1'b0;
            // reader bench proves the playlist switch); an item past the last plays item 0 at IN
            if (nav_pl >= n_pl) `FAIL("port", $sformatf("a PLAY of playlist %0d of %0d (player_ctl must refuse it)", nav_pl, n_pl))
            r_seek <= 1'b1; r_lat <= 500 + $urandom % 1500;
            if (nav_item >= n_items) begin
                nav_land <= 0; nav_skip <= it_in[0][47:0]; nav_err <= 3'd1;
            end else begin
                r_pts = nav_pts;
                if (r_pts > ((it_out[nav_item] < END_GUARD) ? 0 : it_out[nav_item] - END_GUARD))   // [IN, OUT - 4] (umd_nav_ref.clamp)
                    r_pts = (it_out[nav_item] < END_GUARD) ? 0 : it_out[nav_item] - END_GUARD;
                if (r_pts < it_in[nav_item]) r_pts = it_in[nav_item];
                nav_land <= nav_item; nav_skip <= r_pts[47:0]; nav_err <= 3'd0;
            end
            w_next = 1 << 30;
            $fdisplay(fdl, "S %0d %0d %0d %0d", cyc, nav_item, nav_pts, nav_pl);
        end else `FAIL("port", $sformatf("op %0d", nav_op))
    end else if (r_busy) begin
        bs_fire <= 1'b0; ps_fire <= 1'b0;
        if (r_lat == 2 && !r_seek && bs_arm) begin bs_fire <= 1'b1; bs_arm <= 1'b0; end
        // (the bench peeks at q_track for TIMING only: the answer must be a press's)
        if (r_lat == 1 && !r_seek && ps_arm && !dut.q_track) begin ps_fire <= 1'b1; ps_arm <= 1'b0; end
        if (r_lat > 0) r_lat <= r_lat - 1;
        else begin
            r_busy <= 1'b0; nav_done <= 1'b1;
            if (r_seek) begin
                rd_item_start <= 1'b1; rd_item_idx <= nav_land; rd_item_out <= it_out[nav_land][47:0];
                w_next = nav_land + 1; w_tmr = WDELAY;
            end
        end
    end
end

// ---- the mock display and the output queue ----------------------------------------------------
integer d_cnt = 0, q_drain = 0, l_cnt = 0, he_cnt = 0;
reg     d_wait = 0, d_land = 0, d_hop = 0;   // d_hop: a hop's picture shown and held (P6b4)
reg [32:0] d_tgt;
integer d_tgt_item;
reg     d_just = 0;                   // [landpts]: the pick below is a landing's
integer d_off = 0;                    // [proj]: the landing picture starts this many ticks before its target
always @(posedge clk) begin
    pick <= 1'b0; d_just <= 1'b0;
    if (seek_flush && !d_wait) begin
        d_wait <= 1'b1; d_land <= 1'b0; q_drain <= $urandom % 41;
        d_hop <= 1'b0; hop_end <= 1'b0; he_cnt <= 0; ended_k <= 1'b0;   // the resync clears the display's END
    end
    // a hop's stream ends after its one picture: the display takes the END a little later
    if (d_hop && !hop_end) begin
        if (he_cnt == 30) hop_end <= 1'b1; else if (!freeze) he_cnt <= he_cnt + 1;
    end
    if (q_drain > 0) q_drain <= q_drain - 1;
    rec_idle <= (q_drain <= 1) && !(seek_flush && !d_wait);
    // the landing: its item's entry, written after the flush began (or the mount's first)
    if (ep_we && (d_wait || cyc < 400) && ep_wi == ((cyc < 400) ? 2'd0 : nav_land[1:0])) begin
        d_land <= 1'b1; d_tgt <= ep_in; d_tgt_item <= (cyc < 400) ? 0 : nav_land; l_cnt <= 200;
        d_off <= (ep_skip && ($urandom % 2)) ? ($urandom % 1501) : 0;
        if (!ep_skip) begin nopic <= 1'b0; endskip <= 1'b0; end
    end
    if ((d_wait || cyc < 300) && d_land) begin
        if (!freeze && l_cnt > 0) l_cnt <= l_cnt - 1;
        if (!freeze && l_cnt == 0 && endskip && !nopic) begin
            // the stream's END inside the skip: no picture, the display ends (disp_ctl's skip_eos).
            // The display is now IN the landing's item, showing nothing new -- player_ctl's key is
            // that item (it completes the landing on `ended`), so [hold] measures from it. (Kept at
            // the pre-seek item until 2026-10-05, the mock's walk then held at a stale screen: ntwicm_2,
            // a landing at item 11 of 30 with the old picture still item 14.)
            d_wait <= 1'b0; d_land <= 1'b0; ended_k <= 1'b1; endskip <= 1'b0; n_ek <= n_ek + 1;
            m_item = d_tgt_item;
        end else if (!freeze && l_cnt == 0 && !nopic) begin
            d_wait <= 1'b0; d_land <= 1'b0; sh_pts_v <= 1'b1; pick <= 1'b1; d_cnt <= 0; d_just <= 1'b1;
            sh_pts <= (d_tgt >= d_off) ? d_tgt - d_off : 33'd0;
            m_item = d_tgt_item; sh_ep <= d_tgt_item[1:0];
            d_hop <= one_frame;                        // a hop's: nothing follows it
        end
    end else if (!d_wait && sh_pts_v && !freeze && !d_hop && !ended_k) begin   // (an ended display picks nothing)
        if (d_cnt == REFRESH - 1) begin
            d_cnt <= 0;
            if (sh_pts + 33'd1501 >= it_out[m_item][32:0]) begin
                // the item's OUT: into the next item once the reader has started it
                if (m_item + 1 < n_items && w_next > m_item + 1 && w_next != (1 << 30)) begin
                    m_item = m_item + 1; sh_pts <= it_in[m_item][32:0]; sh_ep <= m_item[1:0]; pick <= 1'b1;
                end
            end else begin
                sh_pts <= sh_pts + 33'd1501; pick <= 1'b1;
            end
        end else d_cnt <= d_cnt + 1;
    end
    if (cyc < 300) d_wait <= 1'b1;       // the mount: waiting for the walk's target
end

// ---- [flush] [freeze] [land] ------------------------------------------------------------------
integer f_len = 0, idle_run = 0, tail = -1;
reg     f_q = 0, nd_since = 0, fl_done = 0, take_q = 0, st_te = 0;
integer n_te = 0;                     // P6c: TIME landings past the end (no skip) checked
always @(posedge clk) if (rst_n) begin
    f_q <= seek_flush;
    take_q <= nav_req && nav_ready && (nav_op == 3'd1 || nav_op == 3'd3 || nav_op == 3'd4);
    idle_run <= rec_idle ? idle_run + 1 : 0;
    if (nav_req && nav_ready && (nav_op == 3'd1 || nav_op == 3'd3 || nav_op == 3'd4)) begin
        if (!freeze) `FAIL("freeze", "a SEEK taken with the display not frozen")
        nd_since <= 1'b0; fl_done <= 1'b0;
    end
    if (seek_flush && !f_q) begin
        if (!take_q)
            `FAIL("flush", "seek_flush rose without a SEEK's accepting edge")
        f_len <= 1;
    end else if (seek_flush) f_len <= f_len + 1;
    if (seek_flush && !rd_hold) `FAIL("flush", "the reader's stream not held during the flush")
    if (!seek_flush && f_q) begin
        if (f_len < FLUSH_MIN) `FAIL("flush", $sformatf("the flush lasted %0d cycles", f_len))
        if (idle_run < IDLE_MIN) `FAIL("flush", $sformatf("released with the queue idle only %0d cycles", idle_run))
        fl_done <= 1'b1; tail <= 0;
    end
    // the stream stays held HOLD_TAIL cycles past the flush (no byte into a FIFO in reset)
    if (tail >= 0) begin
        if (!rd_hold && tail < HOLD_TAIL) `FAIL("flush", $sformatf("the stream released %0d cycles after the flush", tail))
        tail <= (tail >= HOLD_TAIL) ? -1 : tail + 1;
    end
    if (nav_done && r_seek) nd_since <= 1'b1;
    // every item start writes its entry the cycle after
    // (P6c: a TIME the reader clamped to the last item's OUT - 4 lands with no skip: st_te)
    st_q <= rd_item_start; st_idx <= rd_item_idx; st_in <= nav_skip; st_of <= one_frame; st_te <= te_pend;
    if (st_q && !(ep_we && ep_skip == (!st_of && !st_te) && ep_wi == st_idx[1:0] && ep_in == st_in[32:0] &&
                  ep_out == it_out[st_idx][32:0] && ep_last == (st_idx == n_items - 1)))
        `FAIL("land", $sformatf("item %0d's start wrote no entry, or a wrong one (we %b tag %0d in %0d out %0d last %b skip %b)",
                                st_idx, ep_we, ep_wi, ep_in, ep_out, ep_last, ep_skip))
    // (an item start's entry follows the one_frame it was computed with, st_of: a walk's item start in
    //  the cycle of a seek's accepting edge -- trick play's exit -- carries the hop's no-skip)
    if (ep_we && !ep_skip && !(st_q ? st_of : one_frame) && !(st_q && st_te) && !(n_nopic > n_wd_seen))
        `FAIL("land", $sformatf("cycle %0d: an entry without a skip (tag %0d in %0d), and no watchdog was due", cyc, ep_wi, ep_in))
    if (ep_we && !ep_skip && !(st_q ? st_of : one_frame) && !(st_q && st_te)) n_wd_seen <= n_wd_seen + 1;
    if (st_q && st_te) n_te <= n_te + 1;
    if (ep_we && cyc > 400) begin
        $fdisplay(fdl, "L %0d %0d %0d %0d", cyc, ep_wi, ep_in, ep_skip);
    end
end
// ---- [hold] (P6b3i): up exactly when the next item would be the fifth in flight ----
integer h_st = 0;
reg     hx_q = 0, hold_exp;
always @(posedge clk) if (rst_n) begin
    if (r_walk && w_next < n_items && w_tmr == 0 && rd_item_idx == w_next && !seeking && !d_wait) begin
        hold_exp = (w_next - m_item >= 4);
        h_st <= (hold_exp == hx_q) ? h_st + 1 : 0;
        hx_q <= hold_exp;
        if (h_st > 3 && hold_exp == hx_q && item_hold !== hold_exp)    // stable, including this cycle
            `FAIL("hold", $sformatf("item_hold %b with the reader at item %0d and item %0d on screen", item_hold, w_next, m_item))
    end else h_st <= 0;
end

// ---- [landpts] [lat] (P6b7): the landing's first picture, and the seek's latency ----------------
// (the mock display's landing branch is the only one that shows a target: every landing's
//  first picture, the mount's included; the gesture's start is the DUT's sk leaving idle,
//  peeked for timing only)
reg [32:0] lp_exp = 0;
reg        lp_chk = 0, lp_on = 0, lat_chk = 0, lat_hop = 0, lat_on = 0;
reg [19:0] lat_last = 0;
integer    lat_t0 = -1, lat_exp = 0, n_lat = 0, lp_n = 0;
reg  [2:0] lsk_q = 0;
always @(posedge clk) if (rst_n) begin
    lsk_q <= dut.sk;
    if ((lsk_q == 3'd0 || lsk_q == 3'd7) && dut.sk != 3'd0 && dut.sk != 3'd7) lat_t0 <= cyc;
    lp_chk <= 1'b0; lat_chk <= 1'b0;
    // the landing's picture: pick (registered) rises the cycle after the branch sets it
    if (pick && d_just) begin
        lp_exp <= sh_pts; lp_chk <= 1'b1; lp_n <= lp_n + 1;
        lat_hop <= one_frame; lat_exp <= cyc - lat_t0;
        lat_chk <= !one_frame && (dut.sk == 3'd6);        // (a watchdog's late picture has no latency)
    end
    if (lp_chk) begin
        lp_on <= 1'b1;
        if (land_pts !== lp_exp) `FAIL("landpts", $sformatf("cycle %0d: land_pts %0d, the landing showed %0d", cyc, land_pts, lp_exp))
    end else if (lp_on && land_pts !== lp_exp)
        `FAIL("landpts", $sformatf("cycle %0d: land_pts moved to %0d between landings (the last %0d)", cyc, land_pts, lp_exp))
    if (lat_chk) begin
        n_lat <= n_lat + 1; lat_on <= 1'b1; lat_last <= lat_exp[19:0];
        if (seek_lat !== lat_exp[19:0])
            `FAIL("lat", $sformatf("cycle %0d: seek_lat %0d, the seek took %0d cycles", cyc, seek_lat, lat_exp))
    end else if (lat_on && seek_lat !== lat_last)
        `FAIL("lat", $sformatf("cycle %0d: seek_lat moved to %0d with no play landing (the last %0d)", cyc, seek_lat, lat_last))
end

// ---- [proj] (P6b7): a chapter press's landing keeps its projected chapter ----
reg        g_pr = 0, pj_on = 0, pj_sq = 0;
reg [15:0] pj_v = 0;
integer    pj_cnt = 0, n_pj = 0, n_pj_early = 0;
always @(posedge clk) if (rst_n) begin
    pj_sq <= seeking;
    if ((lsk_q == 3'd0 || lsk_q == 3'd7) && dut.sk != 3'd0 && dut.sk != 3'd7) g_pr <= (dut.sk == 3'd1);
    if (pick && d_just && !one_frame && dut.sk == 3'd6 && g_pr) begin
        pj_on <= 1'b1; pj_v <= chapter; pj_cnt <= 3 * REFRESH; n_pj <= n_pj + 1;
        if (sh_pts < d_tgt) n_pj_early <= n_pj_early + 1;
    end else if (pj_on) begin
        // (ends at a NEW gesture: seeking is registered, still up the cycle after the landing)
        if ((seeking && !pj_sq) || pj_cnt == 0) pj_on <= 1'b0;
        else begin
            pj_cnt <= pj_cnt - 1;
            // (only a DROP is the flicker: a rise is legitimate -- two marks on one key, dup)
            if (chapter < pj_v)
                `FAIL("proj", $sformatf("cycle %0d: chapter %0d right after a landing on chapter %0d (the picture %0d ticks before its mark)",
                                        cyc, chapter, pj_v, d_off))
        end
    end
end

// ---- [key] (P6b3i): after every pickup the transport's item is the one on screen ----
reg pk_q = 0;
always @(posedge clk) if (rst_n) begin
    pk_q <= pick;
    if (pk_q && key_item !== m_item)
        `FAIL("key", $sformatf("cycle %0d: key_item %0d, item %0d on screen (a tag aliased?)", cyc, key_item, m_item))
end

// PAUSE / STOP / PLAY (3 cycles to settle)
integer pc_code = 0, pc_at = -10;
reg     pc_seek = 0;
always @(posedge clk) begin
    // (P6b4: PLAY on a hop's held picture seeks -- the restore freezes, as every seek does)
    if (cmd_valid) begin pc_code <= cmd_code; pc_at <= cyc; pc_seek <= seeking || one_frame; end
    if (cyc == pc_at + 3 && !pc_seek) begin
        if ((pc_code == 2 || pc_code == 4) && !freeze) `FAIL("freeze", $sformatf("command %0d did not freeze", pc_code))
        if (pc_code == 4 && !idle_screen) `FAIL("freeze", "STOP without the idle screen")
        if (pc_code == 3 && (freeze || idle_screen)) `FAIL("freeze", "PLAY did not release")
    end
end

// ---- [trick] (P6b4) and the hop log for the model ------------------------------------------------
// J e c1 c2 c3: a hop ISSUED at edge e (the seek machine left SK_HOP for SK_SEEK with a hop),
// with the cycles spent at speed 1 / 2 / 3 strictly between the last reset point (trick play's
// entry, or the last hop's issue) and e -- the model multiplies them by its rates. The hop's
// request is the next S line. K e item pts rev: trick play entered at edge e from that key.
// (The seek machine's state is peeked for TIMING only, as q_track is above.)
reg     of_q = 0, j_pend = 0;
reg [1:0] spd_q = 0;
reg [2:0] sk_q = 0;
integer c1 = 0, c2 = 0, c3 = 0, last_rst = -1, n_hops = 0, n_runs = 0, dh_run = 0;
integer cmd_item_q = 0;
reg [32:0] cmd_pts_q = 0;
always @(posedge clk) if (rst_n) begin
    of_q <= one_frame; spd_q <= tk_speed; sk_q <= dut.sk;
    if (cmd_valid) begin cmd_item_q <= m_item; cmd_pts_q <= sh_pts; end
    if (one_frame !== of_q && !take_q) `FAIL("trick", "one_frame changed outside a SEEK's accepting edge")
    if (one_frame && !aud_rst) `FAIL("trick", "a hop's stream with the audio chain not in reset")
    // (the hold follows the pickup by two cycles: SK_PIC -> SK_HOP -> rd_hold)
    dh_run <= (d_hop && one_frame) ? dh_run + 1 : 0;
    if (dh_run > 2 && !rd_hold) `FAIL("trick", "the reader not held while a hop's picture is held")
    // (edge e = cyc - 1 is judged now: was it an issue, or trick play's entry?)
    if (sk_q == 3'd7 && dut.sk == 3'd3 && dut.hop_next) begin
        if (last_rst >= 0 && (cyc - 1) - last_rst <= HOP_MIN)
            `FAIL("trick", $sformatf("a hop issued %0d cycles after the last (HOP_MIN %0d)", (cyc - 1) - last_rst, HOP_MIN))
        if (j_pend) `FAIL("trick", "a hop issued before the last hop's picture was shown")
        $fdisplay(fdl, "J %0d %0d %0d %0d", cyc - 1, c1, c2, c3);
        c1 = 0; c2 = 0; c3 = 0; last_rst = cyc - 1; n_hops = n_hops + 1; j_pend <= 1'b1;
    end else if (spd_q == 2'd0 && tk_speed != 2'd0) begin
        $fdisplay(fdl, "K %0d %0d %0d %0d", cyc - 1, cmd_item_q, cmd_pts_q, tk_rev);
        c1 = 0; c2 = 0; c3 = 0; last_rst = cyc - 1; n_runs = n_runs + 1;
    end else begin
        if (spd_q == 2'd1) c1 = c1 + 1;
        if (spd_q == 2'd2) c2 = c2 + 1;
        if (spd_q == 2'd3) c3 = c3 + 1;
    end
    if (pick && one_frame) j_pend <= 1'b0;
    if (ev_valid && ev_code == 4'd3 && (one_frame || hop_end)) `FAIL("trick", "a TITLE_END posted on a hop's stream")
end

// ---- [audio] ------------------------------------------------------------------------------------
integer a_len = 0;
reg [3:0] a_old, a_want;
reg       a_q = 0, a_set_seen = 0, a_rl = 0;
// (the switch's own reset: aud_rst also holds the chain through trick play, P6b4 -- [trick])
wire aud_sw = aud_rst && !one_frame;
always @(posedge clk) if (rst_n) begin
    a_q <= aud_sw;
    if (cmd_valid && (cmd_code == 8 || cmd_code == 9) && !aud_rst) begin
        a_old <= aud_track;
        a_want <= cmd_arg;
    end
    if (aud_sw && !a_q) a_len <= 1; else if (aud_sw) a_len <= a_len + 1;
    // the realign: only in the switch's last reset cycle (a_len counts the cycles before it)
    if (aud_realign && cyc > 1000) begin
        if (!aud_sw || a_len != AUD_RST - 1)
            `FAIL("audio", $sformatf("a realign outside a switch's last reset cycle (reset %b, cycle %0d of it)", aud_sw, a_len + 1))
        a_rl <= 1'b1;
    end
    if (!aud_sw && a_q) begin
        a_rl <= 1'b0;
        if (a_len != AUD_RST) `FAIL("audio", $sformatf("the chain reset lasted %0d cycles", a_len))
        if (!a_rl) `FAIL("audio", "no realign in the reset's last cycle")
        if (!aud_pres[aud_track]) `FAIL("audio", $sformatf("switched to undeclared track %0d", aud_track))
        if (pc_code == 9 && aud_track !== a_want) `FAIL("audio", $sformatf("AUDIO_SET %0d gave %0d", a_want, aud_track))
        if (pc_code == 8) begin : nxt
            reg [3:0] t; integer j;
            t = a_old;
            for (j = 1; j < 16; j++) if (aud_pres[(a_old + j) % 16] && t == a_old) t = (a_old + j) % 16;
            if (aud_track !== t) `FAIL("audio", $sformatf("AUDIO from %0d gave %0d, want %0d", a_old, aud_track, t))
        end
        $fdisplay(fdl, "A %0d %0d", cyc, aud_track);
    end
    if (cyc == 400) begin : dflt
        integer j; reg [3:0] lo; lo = 0;
        for (j = 15; j >= 0; j--) if (aud_pres[j]) lo = j;
        if (aud_track !== lo) `FAIL("audio", $sformatf("the mount's default track %0d, want %0d", aud_track, lo))
    end
end

// ---- [sub] (P7) ------------------------------------------------------------------------------------
localparam int SUB_FL = 16;
reg        u_pend = 0, u_want_on = 0, u_on_q = 0, u_fl_q = 0;
reg        u_want_host = 0;              // P9 M4b: the change was the disc's (SUB_SET): its event's data[6]
reg  [4:0] u_want_t = 0, u_t_q = 0, u_prev_t = 0;
reg        u_prev_on = 0;
integer    u_fl_len = 0, n_sub_ev = 0, n_sub_chg = 0, n_host_ev = 0, n_host_want = 0, n_host_off = 0;
reg        h_owed = 0, h_owed_b = 0;    // a HOST event owed (the DUT keeps one pending flag: presses merge)
integer    h_gone = -1;                 // the cycle the host went with the subtitles on
integer    n_subset = 0;                 // P9: SUB_SETs taken
always @(posedge clk) if (rst_n) begin
    u_on_q <= sub_on; u_t_q <= sub_track; u_fl_q <= sub_flush;
    if (cyc == host_drop) host_ok <= 1'b0;
    if ($test$plusargs("host_drop_on") && host_drop < 0 && sub_on) host_drop = cyc + 2000;
    // A7: a SUB without the UMD Main: refused, a HOST event owed
    if (cmd_valid && (cmd_code == 4'd12 || cmd_code == 4'd14) && !host_ok) begin
        h_owed <= 1'b1; h_owed_b <= host_bad; n_host_want <= n_host_want + 1;
    end
    // A7: subtitles on with the host gone: off (the flush's way) and a HOST event owed
    if (!host_ok && sub_on && !u_pend && dut.sfl == 5'd0) begin
        u_pend <= 1'b1; u_prev_on <= sub_on; u_prev_t <= sub_track; u_want_on <= 1'b0; u_want_t <= sub_track;
        u_want_host <= 1'b0;
        h_owed <= 1'b1; h_owed_b <= host_bad; n_host_want <= n_host_want + 1; n_host_off <= n_host_off + 1;
        if (h_gone < 0) h_gone = cyc;
    end
    // ...and they are off by then (the flush's length and some): nothing would decode the units
    if (h_gone >= 0 && cyc == h_gone + SUB_FL + 200 && sub_on)
        `FAIL("host", "subtitles still on after the UMD Main went")
    if (ev_valid && ev_code == 4'd10) begin
        n_host_ev <= n_host_ev + 1;
        if (!h_owed) `FAIL("host", "a HOST event with no refused press and no host loss")
        if (ev_data !== {15'd0, h_owed_b}) `FAIL("host", $sformatf("HOST event data %h, want %0d (host_bad)", ev_data, h_owed_b))
        h_owed <= 1'b0;
    end
    if (sub_on && !host_ok && !sub_flush && dut.sfl == 5'd0 && u_pend == 1'b0 && cyc > 0 && host_drop < 0)
        `FAIL("host", "subtitles on without the UMD Main")
    // a SUB accepted (no change in flight): the rule, from the mask -- the READER's (sub_seen: during a
    // clip's CLP read, the CLP_N cycles before an item start, its mask is partial, as the DUT sees it)
    if (cmd_valid && cmd_code == 4'd12 && host_ok && !u_pend && !sub_flush && dut.sfl == 5'd0 && dut.titled && !dut.start_wait) begin : want
        integer j; reg any, more; reg [4:0] lo, nx;
        any = 0; more = 0; lo = 0; nx = 0;
        for (j = 31; j >= 0; j--) if (sub_seen[j]) begin lo = j; any = 1; end
        for (j = 31; j >= 0; j--) if (sub_seen[j] && j > sub_track) begin nx = j; more = 1; end
        u_pend <= 1'b1; u_prev_on <= sub_on; u_prev_t <= sub_track;
        u_want_on <= sub_on ? more : any;
        u_want_t  <= sub_on ? (more ? nx : sub_track) : lo;
        u_want_host <= 1'b0;
    end
    // P9: SUB_SET, accepted (a declared track, or off): exactly the state asked
    if (cmd_valid && cmd_code == 4'd14 && host_ok && !u_pend && !sub_flush && dut.sfl == 5'd0 && dut.titled && !dut.start_wait &&
        (!cmd_item[5] || sub_seen[cmd_item[4:0]])) begin
        u_pend <= 1'b1; u_prev_on <= sub_on; u_prev_t <= sub_track;
        u_want_on <= cmd_item[5]; u_want_t <= cmd_item[5] ? cmd_item[4:0] : sub_track; n_subset <= n_subset + 1;
        u_want_host <= 1'b1;
    end
    if (sub_flush && !u_fl_q) u_fl_len <= 1; else if (sub_flush) u_fl_len <= u_fl_len + 1;
    if (!sub_flush && u_fl_q && u_fl_len != SUB_FL - 1)
        `FAIL("sub", $sformatf("the change's flush lasted %0d cycles, want %0d", u_fl_len, SUB_FL - 1))
    // the state changes only inside the flush (the demux's subtitle output is off then)
    if ((sub_on !== u_on_q || (sub_on && sub_track !== u_t_q)) && !sub_flush && !mount)
        `FAIL("sub", $sformatf("the subtitles changed outside a flush (on %0d track %0d)", sub_on, sub_track))
    if (ev_valid && ev_code == 4'd9) begin
        n_sub_ev <= n_sub_ev + 1;
        if (!u_pend) `FAIL("sub", "a SUB event with no press")
        if (ev_data[5] !== u_want_on || (u_want_on && ev_data[4:0] !== u_want_t))
            `FAIL("sub", $sformatf("cycle %0d: SUB gave on %0d track %0d, want on %0d track %0d", cyc, ev_data[5], ev_data[4:0], u_want_on, u_want_t))
        if (ev_data[6] !== u_want_host)
            `FAIL("sub", $sformatf("SUB event's disc flag %b, want %b (a SUB_SET's event marked, the button's not: P9 M4b)", ev_data[6], u_want_host))
        if (sub_on !== u_want_on || (u_want_on && sub_track !== u_want_t))
            `FAIL("sub", $sformatf("the outputs on %0d track %0d, the event's %0d / %0d", sub_on, sub_track, u_want_on, u_want_t))
        if (u_want_on && !sub_pres[u_want_t]) `FAIL("sub", $sformatf("switched to undeclared track %0d", u_want_t))
        u_pend <= 1'b0;
        if (u_want_on != u_prev_on || (u_want_on && u_want_t != u_prev_t)) n_sub_chg <= n_sub_chg + 1;
    end
    if (mount) u_pend <= 1'b0;
    if (cyc == 400 && sub_on !== 1'b0) `FAIL("sub", "on after the mount (S1: off)")
end

// ---- [goto] P6c: Go To's query port --------------------------------------------------------------
// (the mock reader's NAV_CHAP answers it like any query; goto_ctl's reading of the answer is its own
//  bench's. Here: the port carries the key, and gq_done marks exactly that query's answer)
localparam int GQ_LIM = 200000;
integer gq_n = 0, gq_tmr = 3000, gq_wait = 0;
reg     gq_mine = 0, gq_fl = 0;              // the query in flight is Go To's; one is in flight
always @(posedge clk) if (rst_n) begin
    if (!gq_req) begin
        if (gq_tmr > 0) gq_tmr <= gq_tmr - 1;
        else if (cyc > 400) begin
            gq_req <= 1'b1; gq_wait <= 0;
            // (an item past the title's: a key no press and no tracker ever asks, so the bench
            //  knows the query by its key alone)
            gq_key <= {16'(n_items + $urandom % 8), 16'($urandom), 32'($urandom)};
        end
    end else begin
        // (counted while no gesture or seek holds the port: a seek machine stuck in a landing is
        //  the [wd] arm's, not Go To's starvation)
        if (!seeking || tk_speed != 2'd0) gq_wait <= gq_wait + 1;
        if (gq_wait > GQ_LIM) `FAIL("goto", $sformatf("a Go To query waited %0d free cycles", gq_wait))
    end
    if (nav_req && nav_ready && nav_op == 3'd2) begin
        gq_fl <= 1'b1;
        gq_mine <= gq_req && nav_item[31:16] == 16'd0 && {nav_item[15:0], nav_pts} == gq_key && !gq_done;
    end
    if (gq_done && !gq_req) `FAIL("goto", "gq_done with no Go To query asked")
    if (gq_done !== (nav_done && gq_fl && gq_mine))
        `FAIL("goto", $sformatf("gq_done %b at a query's answer (Go To's: %b)", gq_done, nav_done && gq_fl && gq_mine))
    if (nav_done && !r_seek) gq_fl <= 1'b0;
    if (gq_done) begin gq_req <= 1'b0; gq_n <= gq_n + 1; gq_tmr <= 2000 + $urandom % 8000; end
    if (mount) begin gq_req <= 1'b0; gq_tmr <= 3000; end
end

// ---- events, and the log for the model -----------------------------------------------------------
integer n_wd_ev = 0, n_bad_ev = 0, n_bad_cmd = 0, quiet = 0, z_cyc = 0, z_item = 0;
reg        z_ok = 0;
reg [32:0] z_pts = 0;
reg [15:0] z_ch = 0;
always @(posedge clk) if (rst_n) begin
    if (ev_valid) begin
        case (ev_code)
            4'd1: $fdisplay(fdl, "C %0d %0d", cyc, ev_data);
            4'd2: $fdisplay(fdl, "D %0d", cyc);
            4'd3: begin $fdisplay(fdl, "E %0d", cyc); if (ended_k) n_tend_k <= n_tend_k + 1; end
            4'd4: $fdisplay(fdl, "N %0d %0d", cyc, ev_data);
            4'd5: begin $fdisplay(fdl, "W %0d", cyc); n_wd_ev <= n_wd_ev + 1; end
            4'd6: $fdisplay(fdl, "R %0d %0d", cyc, ev_data);
            4'd7: $fdisplay(fdl, "T %0d %0d", cyc, ev_data);
            4'd8: begin $fdisplay(fdl, "B %0d %0d", cyc, ev_data); n_bad_ev <= n_bad_ev + 1; end
            4'd9: $fdisplay(fdl, "U %0d %0d", cyc, ev_data);     // P7: SUB (the [sub] arm scores it)
            4'd10: ;                                                // A7: HOST (the [host] arm scores it)
            default: `FAIL("event", $sformatf("code %0d", ev_code))
        endcase
    end
    if (si < n_cmd && cyc == s_cyc[si] && s_code[si] == 100) n_nopic <= n_nopic + 1;
    // BAD: the reserved code; P9's refusals -- a PLAYLIST of a playlist >= n_pl or with a gesture or a
    // seek in flight, a SUB_SET of an undeclared track or with a change in flight (the host's own
    // refusal is HOST, the [host] arm's)
    if ((si < n_cmd && cyc == s_cyc[si] && s_code[si] == 0) || (bs_fire && !scr_now)) n_bad_cmd <= n_bad_cmd + 1;
    if (cmd_valid && dut.titled && cmd_code == 4'd13 &&
        !((cmd_pl < n_pl) && ((dut.sk == 3'd0 && tk_speed == 2'd0) || tk_speed != 2'd0))) n_bad_cmd <= n_bad_cmd + 1;
    // P9: a PLAYLIST as it reaches the DUT, with whether it can take it (the bench peeks at the
    // seek machine for that only: refused while a gesture or a seek is in flight)
    if (cmd_valid && dut.titled && cmd_code == 4'd13)
        $fdisplay(fdl, "Y %0d %0d %0d %0d %0d %0d", cyc, cmd_pl, cmd_item, cmd_pts, in_trick,
                  (cmd_pl < n_pl) && ((dut.sk == 3'd0 && tk_speed == 2'd0) || tk_speed != 2'd0));
    // P6c: a TIME as it reaches the DUT, with whether it can take it (the bench peeks at the seek
    // machine for that only, as for PLAYLIST): from play or pause with no gesture in flight, or
    // during trick play (its exit); else BAD
    if (cmd_valid && dut.titled && cmd_code == 4'd15) begin
        $fdisplay(fdl, "H %0d %0d %0d %0d", cyc, cmd_pts, in_trick,
                  (dut.sk == 3'd0 && state != 3'd3) || tk_speed != 2'd0);
        if (!((dut.sk == 3'd0 && state != 3'd3) || tk_speed != 2'd0)) n_bad_cmd <= n_bad_cmd + 1;
    end
    if (cmd_valid && dut.titled && cmd_code == 4'd14 && host_ok &&
        !(dut.sfl == 5'd0 && !dut.start_wait && (!cmd_item[5] || sub_seen[cmd_item[4:0]]))) n_bad_cmd <= n_bad_cmd + 1;
    quiet <= (nav_req || r_busy || seeking || dut.pq_n != 0) ? 0 : quiet + 1;
    // settled: the PREVIOUS picture's key and chapter, when the port has been quiet since
    // well before it (a picture crossing a chapter makes the tracker ask the cycle after)
    if (pick) begin
        // (quiet since 700 cycles before THAT picture: a pause between the two pickups kept the
        //  port quiet after a tracker query the previous picture caused -- P6b7)
        if (quiet - (cyc - z_cyc) > 700 && z_ok && state == 3'd1)
            $fdisplay(fdl, "Z %0d %0d %0d %0d", z_cyc, z_item, z_pts, z_ch);
        z_ok <= 1'b1; z_cyc <= cyc; z_item <= m_item; z_pts <= sh_pts; z_ch <= chapter;
    end
    if (cyc == t_end) begin
        if (ev_lost !== 8'd0) `FAIL("event", $sformatf("%0d events lost", ev_lost))
        if (want_hold && n_hold == 0) `FAIL("hold", "the reader was never held (the arm measured nothing)")
        if (n_wd_ev != n_nopic) `FAIL("wd", $sformatf("%0d watchdog events for %0d landings with no picture", n_wd_ev, n_nopic))
        // [tend] (fix/skip-last-picture) a landing whose display ENDED with no picture: the seek done
        // without the watchdog ([wd] above) and one TITLE_END posted while that END stands
        if (n_tend_k != n_ek) `FAIL("tend", $sformatf("%0d TITLE_ENDs for %0d landings that ended with no picture", n_tend_k, n_ek))
        if (want_trick && n_ek == 0) `FAIL("tend", "no landing ended with no picture (the arm measured nothing)")
        if (n_bad_ev != n_bad_cmd || n_bad !== n_bad_cmd[7:0])
            `FAIL("event", $sformatf("%0d BAD events, n_bad %0d, for %0d reserved commands", n_bad_ev, n_bad, n_bad_cmd))
        $fclose(fdl);
        if (want_trick && n_hops == 0) `FAIL("trick", "no hop was made (the arms measured nothing)")
        if (n_seeks > n_wd && n_lat == 0) `FAIL("lat", "no seek's latency was checked (the arm measured nothing)")
        if (lp_n == 0) `FAIL("landpts", "no landing was checked")
        if (want_trick && (n_es == 0 || es_arm)) `FAIL("trick", "EXITSYNC never fired (the P41 arm measured nothing)")
        if (n_chap > 0 && n_pj_early == 0) `FAIL("proj", "no chapter landing began before its mark (the arm measured nothing)")
        // P7: the SUB presses were answered, and on a title with subtitles they changed something
        if ($test$plusargs("no_host")) begin
            // A7: stock Main -- never on, every press answered by HOST
            if (n_sub_ev != 0 || n_sub_chg != 0) `FAIL("host", $sformatf("%0d SUB events, %0d changes without the UMD Main", n_sub_ev, n_sub_chg))
            if (n_host_want == 0 || n_host_ev == 0) `FAIL("host", "no SUB press was refused (the arm measured nothing)")
        end else begin
            if (n_sub_ev == 0) `FAIL("sub", "no SUB event (the arm measured nothing)")
            if (sub_pres != 0 && n_sub_chg < 2) `FAIL("sub", $sformatf("only %0d subtitle changes on a title with tracks 0x%08h", n_sub_chg, sub_pres))
            if (n_subset == 0 && host_drop < 0) `FAIL("sub", "no SUB_SET was taken (P9: the arm measured nothing)")
        end
        if (host_drop >= 0 && n_host_off == 0) `FAIL("host", "the subtitles were not on when the host went (the arm measured nothing)")
        if (h_owed) `FAIL("host", "a HOST event owed and never posted")
        if (n_te == 0) `FAIL("land", "no TIME past the end landed (the P6c no-skip rule measured nothing)")
        if (gq_n < 5) `FAIL("goto", $sformatf("only %0d Go To queries answered (the arm measured nothing)", gq_n))
        $display("player_ctl_tb: %0d commands, %0d seeks, %0d hops in %0d trick runs, %0d watchdogs, %0d holds, chapter %0d of %0d at the end, %0d SUB (%0d changes, %0d SUB_SET), %0d HOST",
                 n_cmd, n_seeks, n_hops, n_runs, n_wd, n_hold, chapter, n_chapters, n_sub_ev, n_sub_chg, n_subset, n_host_ev);
        $display("PASS: player_ctl_tb");
        $finish;
    end
end

endmodule
`default_nettype wire
