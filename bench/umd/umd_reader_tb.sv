// bench/umd/umd_reader_tb.sv -- umd_reader against one --nav fixture (+stem=<path>)
//
// The fixture (tools/umd_fixture.py --nav on a real disc, or tools/umd_reader_cases.py
// for the synthetic edges) is a sparse image plus goldens from the P1 parsers and the
// navigation model (tools/umd_nav_ref.py), never from the RTL. This bench serves the
// image over an hps_io-shaped sd_* model (random latency, 2 clocks per byte), applies
// random backpressure on the output, and scores the reader:
//
//   [walk]    every sector read lies in a region of the fixture (a stray read fails)
//   [order]   a region's first read follows the first read of every region it depends on
//             (after the first command, items may play out of order: the nav mask)
//   [pick]    main playlist and playlist count, checked when the playlist walk ends
//   [title]   TITLE length, flags and bytes, checked at the same moment
//   [stream]  the .MPS sectors are requested in the golden order and every output byte
//             equals the fixture's (`!==`), up to the phase's sectors. Phase 0 is the walk
//             (IN / OUT applied: the item starts at the entry at or before IN and stops
//             at the first entry at or after OUT); each SEEK starts a phase at its
//             accepting edge: every byte after it must come from the landing. Every byte's
//             item tag (stream_ep, P6b3i) is its sector's item mod 4 (the fixture's region)
//   [hold]    (P6b3i) item_hold, driven at random: the walk never leaves S_ITEM for the next
//             item while it is up
//   [done]    a complete phase ends in title_done with no extra byte
//   [tracks]  audio/subtitle presence, languages, stream counts, video attributes
//   [clip]    clip PTS range, EP-map offset, item IN/OUT, clip name, .MPS extent
//   [nav]     a good image must never raise err_code
//   [err]     a refused image raises exactly the expected err_code and streams nothing
//   [thrash]  the walk's navigation reads stay within 3x the navigation sectors (+ slack)
//   [seek]    a SEEK's results: nav_err, the landed item, the entry (index, PTS, sector),
//             the clamped target, ep_flags -- then its phase in [stream] / [done]
//   [time]    (P6c) a TIME's results (Go To by the playing playlist's time), as [seek]'s:
//             the landing umd_nav_ref.Title.time_seek gives, then its phase
//   [chap]    a CHAP's results: nav_err, rank, count, which of cur / prev / next exist,
//             and their keys; the stream runs on across it unbroken ([stream]); one scan
//             reads at most PLAYLIST.UMD's sectors + 2 (a fetch that crosses sectors for
//             bytes it does not need re-reads two at every fifth boundary of 65,535 marks)
//   [sniff]   (P8) the first read after every start is sector 0 (the bare-stream sniff: a
//             navigation read, outside the regions)
//   [bare]    (P8) the file's mode (an image, a bare .MPS, a .PMF) and pmf_warn; on a bare
//             stream every SEEK / TIME / PLAY is refused (NE_NOMAP) with NOTHING flushed --
//             the phase runs on, scored by [stream] -- and a CHAP finds no chapter
//   +restart  pulses `start` again in the middle of a stream transfer and re-scores the
//             whole walk; any failure after it reports as [restart]
//   [reset]   +hold (fj#64): after the reset, with the image's size held and NO start, 20,000
//             cycles of an idle reader -- no sector read, nothing streamed, state 0, no error (an
//             OSD Reset is a reset with the image still mounted); then the start and the walk as usual
//
// Commands (<stem>.nav.hex, NAV_W words each; tools/umd_fixture.py NAV_WORDS) are issued
// in order, each when its trigger holds: W_AFTER the phase is over (a complete phase:
// title_done), W_MID an .MPS transfer is in flight, W_HALF half the phase has arrived.
//
// PASS marker: "PASS: umd_reader_tb". Every failure path is $fatal.
`timescale 1ns/1ps
module umd_reader_tb;

localparam MAXSEC  = 2048;
localparam MAXREG  = 128;
localparam RW      = 11;              // words per region (tools/umd_fixture.py)
localparam MAXSSEQ = 8192;
localparam NAV_W   = 32;
localparam MAXCMD  = 64;
localparam S_ITEM  = 6'd27;           // umd_reader.sv: the playlist walk has chosen
localparam LIM     = 60_000_000;      // cycles per wait
localparam W_AFTER = 0, W_MID = 1, W_HALF = 2;
localparam OP_SEEK = 1, OP_CHAP = 2, OP_PLAY = 3, OP_TIME = 4;   // PLAY: P9; TIME: P6c

reg clk = 1'b0;
always #5 clk = ~clk;

reg         rst_n = 1'b0, start = 1'b0, stop = 1'b0;
reg  [63:0] file_size = 64'd0;
wire [31:0] sd_lba;
wire        sd_rd;
reg         sd_ack = 1'b0;
reg  [13:0] sd_buff_addr = 14'd0;
reg   [7:0] sd_buff_dout = 8'd0;
reg         sd_buff_wr = 1'b0;
wire  [7:0] stream_data;
wire        stream_valid;
wire  [1:0] stream_ep;
reg         item_hold = 1'b0;
reg         busy = 1'b0;
wire  [5:0] state_o;
wire  [3:0] err_code;
wire        streaming, title_done, sfo_warn, title_trunc, dur_sat, item_start;
wire  [1:0] bare;                      // P8
wire        pmf_warn;
wire [31:0] secs_streamed, n_items, item_idx, mps_lba, mps_bytes, sub_present, ep_map_off;
reg   [6:0] title_addr = 7'd0;
wire  [7:0] title_q, title_len, vid_attr0, vid_attr1;
wire [15:0] main_pl, n_playlists, n_streams, n_video, n_unknown, aud_present, lang_q;
wire [63:0] clip_name;
wire [47:0] item_in_pts, item_out_pts, clip_start_pts, clip_end_pts;
wire [47:0] item_base;                 // P6b5
wire [63:0] pl_dur;
reg   [5:0] lang_sel = 6'd0;
reg         nav_req = 1'b0;
reg   [2:0] nav_op = 3'd0;
reg  [31:0] nav_item = 32'd0;
reg  [47:0] nav_pts = 48'd0;
reg  [15:0] nav_pl = 16'd0;          // P9 NAV_PLAY
wire        nav_ready, nav_done;
wire  [2:0] nav_err, ep_flags, ch_valid;
wire [31:0] nav_land, nav_ep_idx, nav_ep_pts, nav_ep_sec;
wire [47:0] nav_skip;
wire [15:0] ch_rank, ch_count;
wire [63:0] ch_cur, ch_prev, ch_next;

umd_reader dut (
    .clk(clk), .rst_n(rst_n), .start(start), .stop(stop), .file_size(file_size),
    .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_ack(sd_ack), .sd_buff_addr(sd_buff_addr),
    .sd_buff_dout(sd_buff_dout), .sd_buff_wr(sd_buff_wr),
    .stream_data(stream_data), .stream_valid(stream_valid), .stream_ep(stream_ep), .item_hold(item_hold), .busy(busy),
    .state_o(state_o), .active(), .err_code(err_code), .streaming(streaming), .title_done(title_done),
    .secs_streamed(secs_streamed), .sfo_warn(sfo_warn), .title_trunc(title_trunc),
    .dur_sat(dur_sat), .bare(bare), .pmf_warn(pmf_warn), .title_addr(title_addr), .title_q(title_q), .title_len(title_len),
    .main_pl(main_pl), .n_playlists(n_playlists), .n_items(n_items), .item_idx(item_idx),
    .clip_name(clip_name), .item_in_pts(item_in_pts), .item_out_pts(item_out_pts),
    .item_start(item_start), .mps_lba(mps_lba), .mps_bytes(mps_bytes),
    .clip_start_pts(clip_start_pts), .clip_end_pts(clip_end_pts), .n_streams(n_streams),
    .n_video(n_video), .n_unknown(n_unknown), .vid_attr0(vid_attr0), .vid_attr1(vid_attr1),
    .aud_present(aud_present), .sub_present(sub_present), .ep_map_off(ep_map_off),
    .lang_sel(lang_sel), .lang_q(lang_q),
    .title_addr2(7'd0), .title_q2(), .item_base(item_base), .pl_dur(pl_dur),
    .nav_req(nav_req), .nav_op(nav_op), .nav_item(nav_item), .nav_pts(nav_pts), .nav_pl(nav_pl),
    .nav_ready(nav_ready), .nav_done(nav_done), .nav_err(nav_err),
    .nav_land(nav_land), .nav_ep_idx(nav_ep_idx), .nav_ep_pts(nav_ep_pts), .nav_ep_sec(nav_ep_sec),
    .nav_skip(nav_skip), .ep_flags(ep_flags),
    .ch_rank(ch_rank), .ch_count(ch_count), .ch_valid(ch_valid),
    .ch_cur(ch_cur), .ch_prev(ch_prev), .ch_next(ch_next)
);

// ---------------------------------------------------------------------------------
// Fixture
// ---------------------------------------------------------------------------------
reg  [7:0] img   [0:MAXSEC*2048-1];
reg [31:0] lbas  [0:MAXSEC-1];
reg [31:0] regw  [0:RW*MAXREG-1];    // lba, n, kind<<16|item, walk mask x4, nav mask x4
reg [31:0] sseq  [0:MAXSSEQ-1];      // phase 0 (.sseq.hex), then every command's (.nseq.hex)
reg [31:0] expw  [0:31];
reg  [7:0] tbyte [0:127];
reg [31:0] langs [0:47];
reg [31:0] meta  [0:15];
reg [31:0] cmdw  [0:NAV_W*MAXCMD-1];
integer    sseq_idx [0:MAXSSEQ-1];
reg [31:0] sitem [0:MAXSSEQ-1];      // P6b3i: each stream sector's item (.sitem.hex; the tag is mod 4)
reg        touched  [0:MAXREG-1];

string  stem;
integer n_sec, n_reg, n_sseq, n_nseq, complete, restart, nav_secs, n_cmd, pl_secs;
integer nbytes = 0, mreq = 0, nav_reads = 0, seed = 1;
integer ph_off = 0, ph_n = 0, ph_cmp = 0;   // the phase being scored: sseq[ph_off +: ph_n]
reg     in_restart = 1'b0;
reg     hold_rst = 1'b0;              // +hold: the reset with the image held, idle before the start
reg     nav_phase = 1'b0;                   // a command has been issued: the nav mask
reg     checked0 = 1'b0;                    // phase 0's walk checks done
reg     want_sniff = 1'b0;                  // P8: the next read must be sector 0
reg     bare_fx = 1'b0;                     // P8: the fixture is a bare stream file

function string armname(input string a);
    if (in_restart) armname = "restart";
    else            armname = a;
endfunction
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", armname(arm), msg); $fatal(1); end

function integer find_sec(input [31:0] lba);
    integer i;
    begin
        find_sec = -1;
        for (i = 0; i < n_sec; i = i + 1) if (lbas[i] == lba) find_sec = i;
    end
endfunction

function integer find_reg(input [31:0] lba);
    integer i;
    begin
        find_reg = -1;
        for (i = 0; i < n_reg; i = i + 1)
            if (lba >= regw[RW*i] && lba < regw[RW*i] + regw[RW*i+1]) find_reg = i;
    end
endfunction

function is_mps(input integer r);
    is_mps = (regw[RW*r+2][31:16] == 8);      // KINDS.index("mps")
endfunction

function dep(input integer r, input integer j);   // region r depends on region j
    dep = regw[RW*r + (nav_phase ? 7 : 3) + j / 32][j % 32];
endfunction

// ---------------------------------------------------------------------------------
// sd model: hps_io's shape -- sd_ack high, bytes written with sd_buff_wr, sd_ack low
// ---------------------------------------------------------------------------------
task on_request(input [31:0] lba);
    integer r, j;
    begin
        if (want_sniff) begin
            // P8: the reader's first read after a start is the sniff of sector 0
            want_sniff = 1'b0;
            if (lba !== 32'd0) `FAIL("sniff", $sformatf("the first read after a start is LBA %0d, not 0", lba))
            nav_reads = nav_reads + 1;
        end else begin
        r = find_reg(lba);
        if (r < 0) `FAIL("walk", $sformatf("read of LBA %0d outside every region", lba))
        // stream order first: for an .MPS read it is the sharper diagnosis
        if (is_mps(r) && mreq < ph_n && lba !== sseq[ph_off + mreq])
            `FAIL("stream", $sformatf("stream request %0d of the phase at %0d is LBA %0d, want %0d",
                                      mreq, ph_off, lba, sseq[ph_off + mreq]))
        if (!touched[r]) begin
            for (j = 0; j < n_reg; j = j + 1)
                if (dep(r, j) && !touched[j])
                    `FAIL("order", $sformatf("region %0d (LBA %0d, kind %0d item %0d) read before region %0d (LBA %0d, kind %0d) it depends on",
                                            r, regw[RW*r], regw[RW*r+2][31:16], regw[RW*r+2][15:0], j, regw[RW*j], regw[RW*j+2][31:16]))
            touched[r] = 1'b1;
        end
        if (is_mps(r))
            mreq = mreq + 1;
        else
            nav_reads = nav_reads + 1;
        end
    end
endtask

initial begin : server
    integer i, sidx;
    reg [31:0] lba;
    wait (rst_n);
    forever begin
        @(posedge clk);
        if (sd_rd && !sd_ack) begin
            lba = sd_lba;
            on_request(lba);
            sidx = find_sec(lba);
            repeat (2 + ($unsigned($random(seed)) % 24)) @(posedge clk);
            sd_ack <= 1'b1;
            for (i = 0; i < 2048; i = i + 1) begin
                @(posedge clk);
                sd_buff_addr <= i;
                sd_buff_dout <= (sidx >= 0) ? img[sidx*2048 + i] : 8'h00;
                sd_buff_wr   <= 1'b1;
                @(posedge clk);
                sd_buff_wr   <= 1'b0;
            end
            repeat (2) @(posedge clk);
            sd_ack <= 1'b0;
            @(posedge clk);
        end
    end
end

// backpressure: busy about a quarter of the time
always @(posedge clk) busy <= ($unsigned($random(seed)) % 4) == 0;

// ---- [hold] (P6b3i): item_hold at random; S_ITEM is left only while it is down (or by a
// command taken in that cycle) ----
reg        hold_q = 1'b0, take_q = 1'b0;
reg [5:0]  st_q = 6'd0;
reg [31:0] it_q = 32'd0;
always @(posedge clk) begin
    item_hold <= ($unsigned($random(seed)) % 3) == 0;
    hold_q <= item_hold; st_q <= state_o; it_q <= item_idx; take_q <= nav_req && nav_ready;
    if (rst_n && st_q == 6'd27 && hold_q && it_q < n_items && state_o != 6'd27 && !take_q)
        `FAIL("hold", $sformatf("the walk left S_ITEM for item %0d with item_hold up", it_q))
end

// ---- [base] (P6b5): at every item start (the walk's or a seek's landing), item_base = the
// earlier items' OUT - IN, and pl_dur the whole playlist's (tools/umd_fixture.item_bases,
// from the P1 parser); the first BASE_MAX items are checked, and at least one must be ----
reg [31:0] basew [0:2*256+2];
integer    n_base = 0, base_chk = 0;
reg        base_main = 1'b1;          // .base.hex is the main playlist's (a PLAY scores its own)
always @(posedge clk)
    if (rst_n && item_start && item_idx < n_base && base_main) begin
        if (item_base !== {basew[2+2*item_idx][15:0], basew[1+2*item_idx]})
            `FAIL("base", $sformatf("item %0d starts with base %0d, want %0d", item_idx, item_base,
                                    {basew[2+2*item_idx][15:0], basew[1+2*item_idx]}))
        base_chk = base_chk + 1;
    end

// ---------------------------------------------------------------------------------
// Stream scoring (and the per-run counters, reset on every start)
// ---------------------------------------------------------------------------------
always @(posedge clk) begin : scorer
    integer j;
    reg [7:0] want;
    if (start) begin
        nbytes = 0; mreq = 0; nav_reads = 0; want_sniff = 1'b1;
        for (j = 0; j < MAXREG; j = j + 1) touched[j] = 1'b0;
    end else if (rst_n && stream_valid) begin
        if (nbytes < ph_n * 2048) begin
            want = img[sseq_idx[ph_off + nbytes / 2048] * 2048 + nbytes % 2048];
            if (stream_data !== want)
                `FAIL("stream", $sformatf("byte %0d of the phase at %0d (sector %0d = LBA %0d, +%0d) is %02x, want %02x",
                                          nbytes, ph_off, nbytes / 2048, sseq[ph_off + nbytes / 2048],
                                          nbytes % 2048, stream_data, want))
            if (stream_ep !== sitem[ph_off + nbytes / 2048][1:0])
                `FAIL("stream", $sformatf("byte %0d of the phase at %0d (LBA %0d): item tag %0d, want %0d",
                                          nbytes, ph_off, sseq[ph_off + nbytes / 2048], stream_ep,
                                          sitem[ph_off + nbytes / 2048][1:0]))
        end
        nbytes = nbytes + 1;
    end
end

// [done] (A12): title_done rises only once every byte of a complete phase is out -- 8 cycles of
// slack for the output pipe (a title_done raised with bytes still in the cache was invisible: the
// arms below count the bytes before they wait for title_done)
reg     td_q = 1'b0;
integer td_wait = -1;
always @(posedge clk) begin
    td_q <= title_done;
    if (rst_n && title_done && !td_q && ph_cmp && !in_restart) td_wait = 8;
    else if (td_wait > 0) td_wait = td_wait - 1;
    else if (td_wait == 0) begin
        td_wait = -1;
        if (nbytes != ph_n * 2048)
            `FAIL("done", $sformatf("title_done rose with %0d of %0d bytes of the phase at %0d out",
                                    nbytes, ph_n * 2048, ph_off))
    end
end

// a good image never raises an error
always @(posedge clk)
    if (rst_n && expw[0] == 0 && err_code !== 4'd0)
        `FAIL("nav", $sformatf("walk ended in err_code %0d (state %0d)", err_code, state_o))

// ---------------------------------------------------------------------------------
task check_pick_title;
    integer i;
    begin
        if (main_pl !== expw[1][15:0] || n_playlists !== expw[2][15:0])
            `FAIL("pick", $sformatf("main playlist %0d of %0d, want %0d of %0d",
                                    main_pl, n_playlists, expw[1], expw[2]))
        if (bare !== meta[10][1:0] || pmf_warn !== meta[11][0])
            `FAIL("bare", $sformatf("mode %0d pmf_warn %0d, want %0d %0d", bare, pmf_warn, meta[10], meta[11]))
        if (title_len !== expw[4][7:0] || {title_trunc, sfo_warn} !== expw[5][1:0])
            `FAIL("title", $sformatf("title_len %0d trunc %0d sfo_warn %0d, want %0d / flags %0d",
                                     title_len, title_trunc, sfo_warn, expw[4], expw[5]))
        for (i = 0; i < expw[4]; i = i + 1) begin
            title_addr = i;
            @(posedge clk); @(posedge clk); #1;
            if (title_q !== tbyte[i])
                `FAIL("title", $sformatf("title byte %0d is %02x, want %02x", i, title_q, tbyte[i]))
        end
    end
endtask

task check_tracks_clip;
    integer i;
    begin
        // (P8: a bare file writes none of the CLP-shaped outputs -- emu leaves them unconnected --
        //  so its stream counts, attributes, PTS range, EP-map offset and clip name are not scored)
        if (aud_present !== expw[6][15:0] || sub_present !== expw[7] || (!bare_fx && (
            n_streams !== expw[8][15:0] || n_video !== expw[9][15:0] ||
            n_unknown !== expw[10][15:0] || {vid_attr1, vid_attr0} !== expw[11][15:0])))
            `FAIL("tracks", $sformatf("aud %04x sub %08x n %0d video %0d unknown %0d attr %02x%02x, want %04x %08x %0d %0d %0d %04x",
                                      aud_present, sub_present, n_streams, n_video, n_unknown,
                                      vid_attr1, vid_attr0, expw[6], expw[7], expw[8], expw[9],
                                      expw[10], expw[11]))
        for (i = 0; i < 48; i = i + 1) if (langs[i][16]) begin
            lang_sel = i;
            @(posedge clk); @(posedge clk); #1;
            if (lang_q !== langs[i][15:0])
                `FAIL("tracks", $sformatf("language %0d is %04x, want %04x", i, lang_q, langs[i][15:0]))
        end
        if ((!bare_fx && (clip_start_pts !== {expw[13][15:0], expw[12]} || clip_end_pts !== {expw[15][15:0], expw[14]} ||
            ep_map_off !== expw[16])) || item_in_pts !== {expw[18][15:0], expw[17]} ||
            item_out_pts !== {expw[20][15:0], expw[19]} || n_items !== expw[3] ||
            mps_lba !== expw[24] || mps_bytes !== expw[25] ||
            item_idx !== (streaming ? expw[26] : expw[3]))    // past the last item: n_items
            `FAIL("clip", $sformatf("pts %0d..%0d ep %0d in/out %0d..%0d items %0d mps %0d+%0d item %0d",
                                    clip_start_pts, clip_end_pts, ep_map_off, item_in_pts,
                                    item_out_pts, n_items, mps_lba, mps_bytes, item_idx))
        for (i = 0; i < expw[23]; i = i + 1)
            if (clip_name[63 - 8*i -: 8] !== (i < 4 ? expw[21][31 - 8*i -: 8] : expw[22][31 - 8*(i-4) -: 8]))
                `FAIL("clip", $sformatf("clip name byte %0d is %02x", i, clip_name[63 - 8*i -: 8]))
    end
endtask

// the walk's checks, once: when phase 0 is over or at the first command's trigger
task checks0;
    begin
        if (!checked0) begin
            checked0 = 1'b1;
            check_tracks_clip;
            if (nav_reads > 3 * nav_secs + 8 * expw[3] + 8)
                `FAIL("thrash", $sformatf("%0d navigation reads for %0d navigation sectors", nav_reads, nav_secs))
        end
    end
endtask

task wait_cycles_until_picked;
    integer t;
    begin
        t = 0;
        // (P8: a bare stream has no playlist walk: its one item starts at once)
        while (state_o !== S_ITEM && !(bare_fx && streaming) && t < LIM) begin @(posedge clk); t = t + 1; end
        if (state_o !== S_ITEM && !(bare_fx && streaming)) `FAIL("pick", "the playlist walk never finished")
    end
endtask

task pulse_start;
    begin
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
    end
endtask

// the phase is over: every scored byte arrived; a complete one also ends the title
task finish_phase(input string arm);
    integer t;
    begin
        t = 0;
        while (nbytes < ph_n * 2048 && t < LIM) begin @(posedge clk); t = t + 1; end
        if (nbytes < ph_n * 2048)
            `FAIL(arm, $sformatf("only %0d of %0d stream bytes of the phase at %0d arrived", nbytes, ph_n * 2048, ph_off))
        if (ph_cmp) begin
            t = 0;
            while (!title_done && t < LIM) begin @(posedge clk); t = t + 1; end
            if (!title_done) `FAIL("done", $sformatf("title_done never rose (phase at %0d)", ph_off))
            repeat (2000) @(posedge clk);
            if (nbytes != ph_n * 2048)
                `FAIL("done", $sformatf("%0d bytes streamed, want exactly %0d (phase at %0d)", nbytes, ph_n * 2048, ph_off))
        end
    end
endtask

// ---------------------------------------------------------------------------------
// One command: trigger, issue on nav_ready, switch the phase at a SEEK's accepting edge
// (the negedge after it: requests and bytes sampled at that posedge are the old phase's),
// then its results at nav_done.
// ---------------------------------------------------------------------------------
task run_cmd(input integer c);
    integer b, t, op, wh, nav0;
    reg [63:0] k;
    string arm;
    begin
        b  = NAV_W * c;
        op = cmdw[b][7:0];
        wh = cmdw[b][15:8];
        if (op == OP_SEEK)      arm = "seek";
        else if (op == OP_CHAP) arm = "chap";
        else if (op == OP_PLAY) arm = "play";
        else if (op == OP_TIME) arm = "time";
        else                    arm = "op";           // a reserved op: answered NE_OP
        // trigger
        t = 0;
        case (wh)
            W_AFTER: finish_phase(arm);
            W_HALF:  while (nbytes < (ph_n * 2048) / 2 && t < LIM) begin @(posedge clk); t = t + 1; end
            default: begin              // W_MID: an .MPS transfer in flight
                while (nbytes < 2048 && nbytes < ph_n * 2048 && t < LIM) begin @(posedge clk); t = t + 1; end
                while (!(sd_ack && streaming && nav_ready) && t < LIM) begin @(posedge clk); t = t + 1; end
                if (!(sd_ack && streaming)) `FAIL("harness", $sformatf("command %0d: no transfer in flight", c))
            end
        endcase
        checks0;
        // issue
        @(negedge clk);
        nav_req = 1'b1; nav_op = op; nav_item = cmdw[b+1]; nav_pts = {cmdw[b+3][15:0], cmdw[b+2]};
        nav_pl = cmdw[b+27][15:0];
        nav_phase = 1'b1;
        t = 0;
        begin : wait_ready
            forever begin
                @(posedge clk);
                if (nav_ready) disable wait_ready;          // sampled before the edge's updates
                t = t + 1;
                if (t > LIM) `FAIL(arm, $sformatf("command %0d: nav_ready never rose", c))
            end
        end
        nav0 = nav_reads;
        @(negedge clk);
        nav_req = 1'b0;
        if (((op == OP_SEEK || op == OP_TIME) && cmdw[b+4] != 1 && !bare_fx) ||   // NE_ITEM: nothing changes
            (op == OP_PLAY && cmdw[b+31][0])) begin         // (PLAY: a playlist that exists; P8: a bare stream takes none)
            if (op == OP_PLAY) base_main = (cmdw[b+27] == meta[5]);
            ph_off = n_sseq + cmdw[b+12]; ph_n = cmdw[b+11]; ph_cmp = cmdw[b+13];
            nbytes = 0; mreq = 0;
            // the accepting edge ended the old phase: a title that had ended is running again
            if (title_done)
                `FAIL("done", $sformatf("command %0d: title_done still up after a seek was taken", c))
        end
        // results
        t = 0;
        while (!nav_done && t < LIM) begin @(posedge clk); t = t + 1; end
        if (!nav_done) `FAIL(arm, $sformatf("command %0d: nav_done never rose (state %0d)", c, state_o))
        if (nav_err !== cmdw[b+4][2:0])
            `FAIL(arm, $sformatf("command %0d: nav_err %0d, want %0d", c, nav_err, cmdw[b+4]))
        if (op == OP_PLAY && cmdw[b+31][0]) begin
            if (main_pl !== cmdw[b+27][15:0] || n_items !== cmdw[b+28] ||
                pl_dur !== {cmdw[b+30], cmdw[b+29]})
                `FAIL("play", $sformatf("command %0d: playlist %0d, %0d items, duration %0d, want %0d %0d %0d",
                                        c, main_pl, n_items, pl_dur, cmdw[b+27], cmdw[b+28],
                                        {cmdw[b+30], cmdw[b+29]}))
            if (cmdw[b+31][1] && item_base !== {cmdw[b+15][15:0], cmdw[b+14]})
                `FAIL("play", $sformatf("command %0d: item_base %0d, want %0d", c, item_base,
                                        {cmdw[b+15][15:0], cmdw[b+14]}))
            if (cmdw[b+31][1] && nav_land !== cmdw[b+5])
                `FAIL("play", $sformatf("command %0d: landed in item %0d, want %0d", c, nav_land, cmdw[b+5]))
        end
        // (the arm's name in a plain variable: Icarus prints nothing for a ternary of strings)
        if (op != OP_TIME) arm = "seek";
        if (((op == OP_SEEK || op == OP_TIME) && cmdw[b+4] != 1 && !bare_fx) || (op == OP_PLAY && cmdw[b+31][1])) begin
            if (nav_land !== cmdw[b+5] || nav_ep_idx !== cmdw[b+6] || nav_ep_pts !== cmdw[b+7] ||
                nav_ep_sec !== cmdw[b+8] || nav_skip !== {cmdw[b+10][15:0], cmdw[b+9]} ||
                ep_flags !== cmdw[b+26][2:0])
                `FAIL(arm, $sformatf("command %0d (%0d, %0d): landed item %0d entry %0d pts %0d sector %0d skip %0d flags %0d, want %0d %0d %0d %0d %0d %0d",
                                        c, cmdw[b+1], {cmdw[b+3][15:0], cmdw[b+2]}, nav_land, nav_ep_idx,
                                        nav_ep_pts, nav_ep_sec, nav_skip, ep_flags, cmdw[b+5], cmdw[b+6],
                                        cmdw[b+7], cmdw[b+8], {cmdw[b+10][15:0], cmdw[b+9]}, cmdw[b+26]))
        end
        if (op == OP_CHAP && nav_reads - nav0 > pl_secs + 2)
            `FAIL("chap", $sformatf("command %0d: %0d sector reads for a PLAYLIST.UMD of %0d",
                                    c, nav_reads - nav0, pl_secs))
        if (op == OP_CHAP && cmdw[b+4] == 0) begin
            if (ch_rank !== cmdw[b+14][15:0] || ch_count !== cmdw[b+15][15:0] || ch_valid !== cmdw[b+16][2:0])
                `FAIL("chap", $sformatf("command %0d (%0d, %0d): rank %0d of %0d, valid %b, want %0d of %0d, %b",
                                        c, cmdw[b+1], {cmdw[b+3][15:0], cmdw[b+2]}, ch_rank, ch_count, ch_valid,
                                        cmdw[b+14], cmdw[b+15], cmdw[b+16][2:0]))
            k = {cmdw[b+17][15:0], cmdw[b+19][15:0], cmdw[b+18]};
            if (ch_valid[0] && ch_cur !== k)
                `FAIL("chap", $sformatf("command %0d: cur %0d/%0d, want %0d/%0d", c, ch_cur[63:48], ch_cur[47:0], k[63:48], k[47:0]))
            k = {cmdw[b+20][15:0], cmdw[b+22][15:0], cmdw[b+21]};
            if (ch_valid[1] && ch_prev !== k)
                `FAIL("chap", $sformatf("command %0d: prev %0d/%0d, want %0d/%0d", c, ch_prev[63:48], ch_prev[47:0], k[63:48], k[47:0]))
            k = {cmdw[b+23][15:0], cmdw[b+25][15:0], cmdw[b+24]};
            if (ch_valid[2] && ch_next !== k)
                `FAIL("chap", $sformatf("command %0d: next %0d/%0d, want %0d/%0d", c, ch_next[63:48], ch_next[47:0], k[63:48], k[47:0]))
        end
    end
endtask

// ---------------------------------------------------------------------------------
initial begin : main
    integer i, t;
    if (!$value$plusargs("stem=%s", stem)) begin $display("FAIL [harness] no +stem"); $fatal(1); end
    restart = $test$plusargs("restart");
    hold_rst = $test$plusargs("hold");
    for (i = 0; i < 16; i = i + 1) meta[i] = 32'd0;
    for (i = 0; i < 32; i = i + 1) expw[i] = 32'd0;
    $readmemh({stem, ".meta.hex"}, meta);
    n_sec = meta[0]; n_reg = meta[1]; n_sseq = meta[2]; complete = meta[3];
    n_cmd = meta[8]; n_nseq = meta[9];
    if (n_sec > MAXSEC || n_reg > MAXREG || n_sseq + n_nseq > MAXSSEQ || n_cmd > MAXCMD) begin
        $display("FAIL [harness] fixture too large (%0d sectors, %0d regions, %0d+%0d stream, %0d commands)",
                 n_sec, n_reg, n_sseq, n_nseq, n_cmd);
        $fatal(1);
    end
    $readmemh({stem, ".hex"}, img, 0, n_sec * 2048 - 1);
    $readmemh({stem, ".lba.hex"}, lbas, 0, n_sec - 1);
    $readmemh({stem, ".reg.hex"}, regw, 0, RW * n_reg - 1);
    if (n_sseq > 0) $readmemh({stem, ".sseq.hex"}, sseq, 0, n_sseq - 1);
    if (n_nseq > 0) $readmemh({stem, ".nseq.hex"}, sseq, n_sseq, n_sseq + n_nseq - 1);
    if (n_sseq + n_nseq > 0) $readmemh({stem, ".sitem.hex"}, sitem, 0, n_sseq + n_nseq - 1);
    if (n_cmd > 0) $readmemh({stem, ".nav.hex"}, cmdw, 0, NAV_W * n_cmd - 1);
    $readmemh({stem, ".exp.hex"}, expw);
    $readmemh({stem, ".title.hex"}, tbyte);
    $readmemh({stem, ".lang.hex"}, langs);
    $readmemh({stem, ".base.hex"}, basew);
    n_base = basew[0];
    for (i = 0; i < n_sseq + n_nseq; i = i + 1) begin
        sseq_idx[i] = find_sec(sseq[i]);
        if (sseq_idx[i] < 0) begin $display("FAIL [harness] stream LBA %0d not in the fixture", sseq[i]); $fatal(1); end
        t = find_reg(sseq[i]);
        if (t < 0 || !is_mps(t)) begin $display("FAIL [harness] stream LBA %0d in no .MPS region", sseq[i]); $fatal(1); end
        if (^sitem[i] === 1'bx) begin $display("FAIL [harness] stream sector %0d has no item tag", i); $fatal(1); end
    end
    nav_secs = 0;
    pl_secs = 0;
    for (i = 0; i < n_reg; i = i + 1) begin
        if (!is_mps(i)) nav_secs = nav_secs + regw[RW*i+1];
        if (regw[RW*i+2][31:16] == 4) pl_secs = regw[RW*i+1];   // KINDS.index("playlist")
    end
    for (i = 0; i < MAXREG; i = i + 1) touched[i] = 1'b0;
    file_size = {meta[7], meta[6]};
    bare_fx = (meta[10] != 0);
    ph_off = 0; ph_n = n_sseq; ph_cmp = complete;

    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    if (hold_rst) begin
        // fj#64: the reset leaves the engine stopped, whatever file_size says; only a start walks
        for (t = 0; t < 20000; t = t + 1) begin
            @(posedge clk);
            if (sd_rd || streaming || nbytes != 0 || err_code !== 4'd0 || state_o !== 6'd0)
                `FAIL("reset", $sformatf("%0d cycles after the reset with no start: sd_rd %b streaming %b, %0d bytes, state %0d, err_code %0d",
                                         t, sd_rd, streaming, nbytes, state_o, err_code))
        end
        $display("umd_reader_tb: 20000 cycles idle after the reset (the image held, no start)");
    end
    pulse_start;

    if (expw[0] != 0) begin
        // ---- a refusal ---------------------------------------------------------
        t = 0;
        while (err_code === 4'd0 && t < LIM) begin @(posedge clk); t = t + 1; end
        if (err_code !== expw[0][3:0])
            `FAIL("err", $sformatf("err_code %0d, want %0d (state %0d)", err_code, expw[0], state_o))
        repeat (100) @(posedge clk);
        if (nbytes != 0 || streaming) `FAIL("err", $sformatf("streamed %0d bytes after refusing", nbytes))
        if (want_sniff) `FAIL("sniff", "a refusal before the sniff read sector 0")
        if (nav_ready) `FAIL("err", "nav_ready after a refusal")
        $display("umd_reader_tb: %s refused with err_code %0d after %0d navigation reads", stem, err_code, nav_reads);
    end else begin
        if (restart) begin
            // restart in the middle of a stream transfer
            t = 0;
            while (!(nbytes >= 3000 && sd_ack && streaming) && t < LIM) begin @(posedge clk); t = t + 1; end
            if (!(sd_ack && streaming)) `FAIL("restart", "never reached a mid-stream transfer")
            in_restart = 1'b1;
            pulse_start;
        end
        wait_cycles_until_picked;
        check_pick_title;
        if (n_base > 0 && pl_dur !== {basew[2+2*n_base], basew[1+2*n_base]})
            `FAIL("base", $sformatf("pl_dur %0d, want %0d", pl_dur, {basew[2+2*n_base], basew[1+2*n_base]}))
        for (i = 0; i < n_cmd; i = i + 1) run_cmd(i);
        finish_phase("stream");
        checks0;
        if (n_base > 0 && base_chk == 0) `FAIL("base", "no item start was checked")
        $display("umd_reader_tb: %s playlist %0d/%0d, %0d item(s), phase 0 %0d sectors, %0d command(s), %0d navigation reads (%0d nav sectors), %0d item bases%s",
                 stem, main_pl, n_playlists, n_items, n_sseq, n_cmd, nav_reads, nav_secs, base_chk,
                 in_restart ? ", after a mid-transfer restart" : "");
    end
    $display("PASS: umd_reader_tb");
    $finish;
end

endmodule
