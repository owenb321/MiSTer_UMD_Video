// bench/umd/player_ctl_bare_tb.sv -- umd/player_ctl.sv on a BARE stream file (P8,
// docs/bare_streams.md): one item, no EP map, no marks, the audio tracks learned from the stream.
// Directed (no script, no model): the rule is short and is the spec here.
//
// The mocks: the reader announces its one item (OUT at the end of time) and answers a NAV_CHAP
// with no chapter 50 cycles later; anything else it is asked fails the bench. The display shows a
// picture every REFRESH cycles. The audio mask starts EMPTY at the item start and grows, as emu
// builds it from the demux's substream taps.
//
// Arms (every failure is $fatal; PASS marker "PASS: player_ctl_bare_tb"):
//   [unavail] FF, REW, SEEK, TIME and PLAYLIST each post exactly one UNAVAIL (11) event, and
//             nothing else moves: no request to the reader, no flush, no trick play, no hop, the
//             state unchanged
//   [chap]    Next still asks the reader (NAV_CHAP) and, finding no chapter, posts NO_CHAPTER
//   [land]    the item start writes the display's item entry with NO skip (the reader leaves its
//             nav_skip unwritten on a bare file: a stale target would drop pictures)
//   [audio]   with the mask empty at the item start the track stays 0; a track the stream shows
//             later becomes the default without another item start; a lower one seen after that
//             does not move it; the audio chain is never reset by the default
`timescale 1ns/1ps
`default_nettype none
module player_ctl_bare_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam int REFRESH = 100;
localparam [3:0] C_NEXT = 4'd5, C_SEEK = 4'd7, C_FF = 4'd10, C_REW = 4'd11, C_PLAYL = 4'd13, C_TIME = 4'd15;
localparam [3:0] EV_NO_CHAPTER = 4'd4, EV_UNAVAIL = 4'd11;
localparam [2:0] NAV_CHAP = 3'd2;

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;

reg         mount = 0, cmd_valid = 0;
reg  [3:0]  cmd_code = 0;
reg  [31:0] cmd_item = 0;
reg  [47:0] cmd_pts = 0;
reg         rd_item_start = 0;
reg  [15:0] aud_m = 16'd0;
wire [15:0] nav_pl;
wire        nav_req;
wire [2:0]  nav_op;
wire [31:0] nav_item;
wire [47:0] nav_pts;
reg         nav_done = 0;
wire        gq_done;
wire        rd_hold, seek_flush, aud_rst, aud_realign, freeze, idle_screen, ep_we, ep_last, ep_skip, item_hold;
wire [3:0]  aud_track;
wire        sub_on, sub_flush;
wire [4:0]  sub_track;
wire [1:0]  ep_wi;
wire [32:0] ep_in, ep_out;
reg  [32:0] sh_pts = 33'd90000;
reg         sh_pts_v = 0, pick = 0;
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

player_ctl #(.MERGE_CYC(2000), .WD_CYC(20000), .FLUSH_MIN(16), .IDLE_MIN(8), .AUD_RST_CYC(16),
             .HOP_MIN(1500), .TICK_DIV(1), .TICK_N(15)) dut (
    .clk(clk), .rst_n(rst_n), .mount(mount), .eject(1'b0),
    .cmd_valid(cmd_valid), .cmd_code(cmd_code), .cmd_item(cmd_item), .cmd_pts(cmd_pts), .cmd_arg(4'd0),
    .cmd_pl(16'd0), .rd_n_playlists(16'd1), .bare(1'b1), .nav_pl(nav_pl),
    .rd_item_start(rd_item_start), .rd_item_idx(32'd0), .rd_n_items(32'd1), .rd_item_out({48{1'b1}}),
    .rd_aud_present(aud_m), .rd_sub_present(32'd0), .host_ok(1'b1), .host_bad(1'b0),
    .sub_on(sub_on), .sub_track(sub_track), .sub_flush(sub_flush),
    .nav_req(nav_req), .nav_op(nav_op), .nav_item(nav_item), .nav_pts(nav_pts), .nav_ready(1'b1),
    .nav_done(nav_done), .nav_err(3'd0), .nav_land(32'd0), .nav_skip(48'd0), .ch_rank(16'd0),
    .ch_count(16'd0), .ch_valid(3'd0), .ch_cur(64'd0), .ch_prev(64'd0), .ch_next(64'd0),
    .gq_req(1'b0), .gq_key(64'd0), .gq_done(gq_done),
    .rd_hold(rd_hold), .seek_flush(seek_flush), .aud_rst(aud_rst), .aud_track(aud_track), .aud_realign(aud_realign),
    .one_frame(one_frame), .land_pts(land_pts), .seek_lat(seek_lat), .tk_speed(tk_speed), .tk_rev(tk_rev),
    .freeze(freeze), .idle_screen(idle_screen), .ep_we(ep_we), .ep_wi(ep_wi), .ep_in(ep_in), .ep_out(ep_out),
    .ep_last(ep_last), .ep_skip(ep_skip), .item_hold(item_hold), .sh_ep(2'd0),
    .sh_pts(sh_pts), .sh_pts_v(sh_pts_v), .pick(pick), .ended(1'b0),
    .rec_idle(1'b1), .state(state), .seeking(seeking), .chapter(chapter), .n_chapters(n_chapters),
    .key_item(key_item), .n_hold(n_hold), .n_seeks(n_seeks), .n_wd(n_wd), .n_bad(n_bad),
    .n_press_lost(n_press_lost), .last_nav_err(last_nav_err),
    .ev_valid(ev_valid), .ev_code(ev_code), .ev_data(ev_data), .ev_pop(ev_valid), .ev_lost(ev_lost));

// ---- the display: a picture every REFRESH cycles ----
integer rc = 0;
always @(posedge clk) begin
    pick <= 1'b0;
    if (sh_pts_v) begin
        rc <= rc + 1;
        if (rc == REFRESH - 1) begin rc <= 0; pick <= 1'b1; sh_pts <= sh_pts + 33'd1501; end
    end
end

// ---- the reader: one chapter query at a time, answered with none; nothing else is legal ----
integer n_req = 0, n_unavail = 0, n_nochap = 0, n_flush = 0, n_arst = 0, n_ep = 0;
always @(posedge clk) if (rst_n && ep_we) begin
    n_ep <= n_ep + 1;
    if (ep_skip !== 1'b0) `FAIL("land", "a bare file's item entry written with a skip")
end
always @(posedge clk) begin
    if (rst_n && nav_req) begin
        if (nav_op !== NAV_CHAP) `FAIL("unavail", $sformatf("the reader was asked op %0d on a bare stream", nav_op))
        n_req <= n_req + 1;
        fork begin repeat (50) @(posedge clk); nav_done <= 1'b1; @(posedge clk); nav_done <= 1'b0; end join_none
    end
    if (rst_n && seek_flush) n_flush <= n_flush + 1;
    if (rst_n && aud_rst) n_arst <= n_arst + 1;
    if (ev_valid && ev_code == EV_UNAVAIL) n_unavail <= n_unavail + 1;
    if (ev_valid && ev_code == EV_NO_CHAPTER) n_nochap <= n_nochap + 1;
    if (rst_n && (tk_speed != 2'd0 || one_frame)) `FAIL("unavail", "trick play / a hop on a bare stream")
end

task press(input [3:0] code, input [31:0] item, input [47:0] pts);
    begin
        @(negedge clk); cmd_valid = 1'b1; cmd_code = code; cmd_item = item; cmd_pts = pts;
        @(negedge clk); cmd_valid = 1'b0;
    end
endtask

initial begin : main
    integer k, u0, r0;
    reg [2:0] st0;
    reg [3:0] codes [0:4];
    codes[0] = C_FF; codes[1] = C_REW; codes[2] = C_SEEK; codes[3] = C_TIME; codes[4] = C_PLAYL;
    repeat (5) @(posedge clk);
    rst_n = 1'b1;
    repeat (5) @(posedge clk);
    @(negedge clk); mount = 1'b1; @(negedge clk); mount = 1'b0;
    repeat (20) @(posedge clk);
    @(negedge clk); rd_item_start = 1'b1; @(negedge clk); rd_item_start = 1'b0;   // the mask still empty
    sh_pts_v = 1'b1;
    repeat (300) @(posedge clk);
    if (n_ep != 1) `FAIL("land", $sformatf("%0d item entries written at the item start", n_ep))
    if (aud_track !== 4'd0) `FAIL("audio", $sformatf("track %0d with nothing seen", aud_track))
    // the stream shows track 2: it becomes the default with no item start
    aud_m = 16'b0000_0000_0000_0100;
    repeat (50) @(posedge clk);
    if (aud_track !== 4'd2) `FAIL("audio", $sformatf("track %0d after the stream showed track 2 only", aud_track))
    // a lower track seen later does not move a made choice
    aud_m = 16'b0000_0000_0000_0101;
    repeat (300) @(posedge clk);
    if (aud_track !== 4'd2) `FAIL("audio", $sformatf("track %0d: the default moved once made", aud_track))
    if (n_arst != 0) `FAIL("audio", "the default reset the audio chain")
    // the seeks: one UNAVAIL each, nothing else
    for (k = 0; k < 5; k++) begin
        st0 = state; u0 = n_unavail; r0 = n_req;
        press(codes[k], 32'd0, 48'd90000 * 7);
        repeat (3000) @(posedge clk);
        if (n_unavail != u0 + 1) `FAIL("unavail", $sformatf("command %0d: %0d UNAVAIL events", codes[k], n_unavail - u0))
        if (n_req != r0) `FAIL("unavail", $sformatf("command %0d asked the reader", codes[k]))
        if (state !== st0) `FAIL("unavail", $sformatf("command %0d: state %0d -> %0d", codes[k], st0, state))
    end
    if (n_flush != 0) `FAIL("unavail", "a flush on a bare stream")
    // Next: asked, none, NO_CHAPTER
    r0 = n_req;
    press(C_NEXT, 32'd0, 48'd0);
    repeat (5000) @(posedge clk);
    if (n_req != r0 + 1 || n_nochap != 1) `FAIL("chap", $sformatf("Next: %0d queries, %0d NO_CHAPTER", n_req - r0, n_nochap))
    if (n_flush != 0) `FAIL("chap", "a flush after Next on a bare stream")
    $display("player_ctl_bare_tb: 5 seeks refused (UNAVAIL), Next -> NO_CHAPTER, the track from the stream");
    $display("PASS: player_ctl_bare_tb");
    $finish;
end

initial begin #50_000_000; `FAIL("harness", "timeout") end

endmodule
