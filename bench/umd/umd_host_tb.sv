// bench/umd/umd_host_tb.sv -- umd/umd_host.sv, the host port (A7, docs/hps_host.md §2),
// driven the way hps_io's EXT_BUS drives it (io_enable frames a transaction, io_strobe
// clocks a word, the first strobe carries the command), with the subtitle side's mclk
// handshake played by the bench. The word layout is tools/host_layout.py's (the bench
// reads the generated localparams through the DUT's names where it can, and hard-codes
// MAGIC / the command numbers: a table that drifted from Main's header would show here).
// Arms:
//   [magic]     HOST_RD word 0 is MAGIC, word 1 {PROTO, NWORDS}
//   [words]     every request field set on mclk comes back in its HOST_RD word
//   [snapshot]  with the mclk fields changed right after the command strobe, every word of
//               that read is still the old record (one snapshot a read)
//   [offbus]    the responder drives the bus for HOST_RD only: never for Main's own
//               commands, the telemetry's 0x7A or HOST_WR
//   [heartbeat] host_ok low until a HOST_WR with a matching PROTO, then high, then low again
//               2^HB_W cycles after the last one; the status word says so
//   [bad]       a mismatched PROTO sets host_bad (not host_ok), and its completion is ignored
//   [done]      a HOST_WR with the done bit: exactly one h_done on mclk, its fields as sent;
//               one without the done bit: none; two in a row: two
// P9 (docs/p9.md §3.2, the appended rows):
//   [rows]      every player input comes back in its HOST_RD word, latched with the record
//   [cmd]       a player command is taken ONCE by its seq: re-sent unchanged it is not taken
//               again, a mismatched PROTO never takes it, a new seq while one is held waits;
//               its fields as sent; the echo (acks[15:8]) moves only when the consumer takes it
//   [levels]    grab / ui / menu / mute follow the last HOST_WR that carried them, read back in the
//               status word, and fall to 0 when the heartbeat times out (not restored after)
//   [events]    player_ctl's events and the grabbed buttons' presses (KEY, code 15) in order,
//               one meeting the other in a cycle kept; read by count (ev_w / ev_r, the first
//               4 unread); ev_rp pops; a full FIFO counts its losses; nothing without host_ok
//               and no KEY for an ungrabbed button
//   [flip]      a flip taken once by its seq, held until hf_ack, echoed (acks[7:0]) then
//   [pcm]       the same for the PCM trigger (pcm_ack[15:8]); pcm_busy in the audio word
//   [win]       the video window's words land as sent, its seq echoes (pcm_ack[7:0]), win_hold
//               covers every HOST_WR, the status word shows win / win_bad, and the window goes
//               off with the heartbeat
// P6d (docs/panel.md F1 / F2 / F5):
//   [press]     a press record is taken ONCE by its seq as a ONE-cycle pulse with its mask, echoed at
//               once (press_ack); re-sent unchanged it is not taken again, a mismatched PROTO never
//               takes it
//   [panel]     ui_sub follows ctl[12] (the status word shows it) and falls with the heartbeat; the
//               status word carries Go To's editor and the title's subtitle track; a flip addresses
//               planes 2 / 3
// PASS marker: "PASS: umd_host_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module umd_host_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam int HB_W = 10;
reg clk = 0, mclk = 0;
always #18.5185 clk = ~clk;          // clk_sys 27 MHz
always #5.5556  mclk = ~mclk;        // the DDR3 port's 90 MHz
reg rst_n = 0, mrst_n = 0;

reg        io_enable = 0, io_strobe = 0;
reg [15:0] io_din = 0;
wire       drive, host_ok, host_bad;
wire [15:0] dout;
reg        h_req = 0, h_buf = 0, h_vis = 0;
reg [7:0]  h_seq = 0, h_gen = 0, h_shown_seq = 0;
reg        h_sbuf = 0;                      // A12 SD2: the shown unit's plane and rectangle
reg [15:0] h_sx = 0, h_sy = 0, h_sw = 0, h_sh = 0;
reg [15:0] h_x = 0, h_y = 0, n_stale = 0;
reg [19:0] h_start = 0;
reg [31:0] h_len = 0;
wire       h_done;
wire [7:0] h_done_seq;
wire [4:0] h_done_err;
wire [15:0] h_done_w, h_done_h;
// P9
reg  [2:0]  p_state = 0;
reg         p_seeking = 0, p_tk_rev = 0, p_sub_on = 0, p_pts_v = 0;
reg  [1:0]  p_tk_speed = 0;
reg  [4:0]  p_sub_track = 0;
reg  [3:0]  p_aud_track = 0;
reg  [15:0] p_chapter = 0, p_n_chapters = 0, p_playlist = 0;
reg  [31:0] p_n_items = 0, p_key_item = 0;
reg  [32:0] p_pts = 0;
reg         p_goto_open = 0, p_sub_any = 0;   // P6d
reg         ev_in_v = 0;
reg  [3:0]  ev_in_code = 0;
reg  [15:0] ev_in_data = 0, key_press = 0;
wire [15:0] grab;
wire        ui, menu, mute, ui_sub;
wire        hx_v;                             // P6d: the press record's pulse
wire [15:0] hx_mask;
integer     n_hx = 0;
reg  [15:0] last_hx = 0;
reg         hx_q = 0;
always @(posedge clk) begin
    hx_q <= hx_v;
    if (hx_v) begin n_hx <= n_hx + 1; last_hx <= hx_mask; end
    if (hx_v && hx_q) `FAIL("press", "the press pulse lasted more than one cycle")
end
wire        hc_v;
wire [3:0]  hc_code, hc_arg;
wire [15:0] hc_pl;
wire [31:0] hc_item;
wire [47:0] hc_pts;
reg         hc_take = 0;
wire        hf_req, hf_vis;
wire [1:0]  hf_buf;
wire [15:0] hf_x, hf_y, hf_w, hf_h;
reg         hf_ack = 0, hp_ack = 0, pcm_busy = 0, pic_wide = 0, pic_known = 0;
reg  [1:0]  menu_aa = 0;
reg         zoom = 0;                    // fj#71: Zoom in force (AUDIO[10])
reg  [15:0] pcm_under = 0;
wire        win, win_hold;
wire [9:0]  win_x, win_y, win_w, win_h;
wire [25:0] win_hs, win_vs, win_x0, win_y0;
reg         win_bad = 0;
integer     n_hold_seen = 0;
always @(posedge clk) if (win_hold) n_hold_seen <= n_hold_seen + 1;
wire        hp_req, hp_stereo;
wire [23:0] hp_start, hp_len;
wire [7:0]  ev_lost;

umd_host #(.RAW (20), .HB_W (HB_W)) dut (.*);

integer ndone = 0;
reg [7:0] last_seq; reg [4:0] last_err; reg [15:0] last_w, last_h;
always @(posedge mclk) if (h_done) begin
    ndone = ndone + 1; last_seq = h_done_seq; last_err = h_done_err; last_w = h_done_w; last_h = h_done_h;
end

localparam int NRD = 44, NWR = 40;
reg [15:0] rd [0:63];
reg [15:0] wv [0:63];             // the words a transaction sends (wv[0] unused: the command)
// one transaction: the command, then the words; drive is checked at every strobe
task automatic xact(input [15:0] cmd, input integer n, input [15:0] w1, input [15:0] w2, input [15:0] w3,
                    input [15:0] w4, input bit expect_drive, input bit change);
    reg [15:0] keep [0:63];
    begin
        // (the P9 arms' words are kept: a HOST_RD between two HOST_WRs must not clear them)
        for (int j = 0; j < 64; j++) keep[j] = wv[j];
        wv[1] = w1; wv[2] = w2; wv[3] = w3; wv[4] = w4;
        for (int j = 5; j < 64; j++) wv[j] = 16'd0;
        xactv(cmd, n, expect_drive, change);
        for (int j = 0; j < 64; j++) wv[j] = keep[j];
    end
endtask
task automatic xactv(input [15:0] cmd, input integer n, input bit expect_drive, input bit change);
    integer k;
    begin
        @(negedge clk); io_enable = 1;
        repeat (2) @(negedge clk);
        for (k = 0; k < n; k++) begin
            io_din = (k == 0) ? cmd : wv[k];
            io_strobe = 1;
            @(negedge clk); io_strobe = 0;
            rd[k] = dout;
            if (k == 0 && change) begin
                // the record moves right after the command strobe (on mclk), and settles
                @(posedge mclk); h_seq = ~h_seq; h_x = ~h_x; h_y = ~h_y; h_len = ~h_len; h_start = ~h_start;
                h_gen = ~h_gen; h_req = ~h_req; h_buf = ~h_buf; h_vis = ~h_vis; h_shown_seq = ~h_shown_seq; n_stale = ~n_stale;
                // (P9: the player's record moves too, on clk_sys)
                p_state = ~p_state; p_chapter = ~p_chapter; p_n_chapters = ~p_n_chapters; p_playlist = ~p_playlist;
                p_n_items = ~p_n_items; p_key_item = ~p_key_item; p_pts = ~p_pts; p_aud_track = ~p_aud_track;
                repeat (40) @(negedge clk);
            end
            if (drive !== expect_drive)
                `FAIL("offbus", $sformatf("command %h word %0d: drive %b, want %b", cmd, k, drive, expect_drive))
            repeat (3) @(negedge clk);
        end
        io_enable = 0;
        repeat (3) @(negedge clk);
        if (drive !== 1'b0) `FAIL("offbus", "drive held after io_enable fell")
    end
endtask

task automatic hrd(input bit change); xact(16'h007B, NRD, 0, 0, 0, 0, 1'b1, change); endtask
// a full HOST_WR (P9): wv[1..24] as set by the caller
task automatic hwrv(); xactv(16'h007C, NWR, 1'b0, 1'b0); repeat (40) @(posedge mclk); endtask
task automatic wv_clear(input [15:0] proto);
    for (int j = 0; j < 64; j++) wv[j] = 16'd0;
    wv[1] = proto;
endtask
task automatic hwr(input [15:0] proto, input [15:0] done, input [15:0] w, input [15:0] h);
    xact(16'h007C, 5, proto, done, w, h, 1'b0, 1'b0);
    repeat (40) @(posedge mclk);          // the completion's crossing
endtask

task automatic check_rd(input string arm);
    reg [15:0] want [0:12];
    begin
        want[0] = 16'hB057; want[1] = {8'd1, 8'd44}; want[2] = {8'd0, h_gen};
        want[3] = {h_req, h_buf, 6'd0, h_seq}; want[4] = h_x; want[5] = h_y;
        want[6] = h_start[15:0]; want[7] = {12'd0, h_start[19:16]}; want[8] = h_len[15:0]; want[9] = h_len[31:16];
        want[10] = {h_vis, 7'd0, h_shown_seq}; want[11] = n_stale; want[12] = {host_ok, host_bad, ui, menu, win, win_bad, p_goto_open, p_sub_any, ui_sub, 7'd0};
        for (int i = 0; i < 13; i++)
            if (rd[i] !== want[i]) begin
                string a;
                if (i < 2) a = "magic"; else if (i == 12) a = (arm == "panel") ? "panel" : "heartbeat"; else a = arm;
                `FAIL(a, $sformatf("HOST_RD word %0d %h, want %h", i, rd[i], want[i]))
            end
        // A12 SD2: the shown unit's plane and rectangle (words 39-43)
        if (rd[39] !== {h_sbuf, 15'd0} || rd[40] !== h_sx || rd[41] !== h_sy || rd[42] !== h_sw || rd[43] !== h_sh)
            `FAIL(arm, $sformatf("HOST_RD words 39-43 %h %h %h %h %h, want %h %h %h %h %h", rd[39], rd[40], rd[41], rd[42], rd[43],
                                 {h_sbuf, 15'd0}, h_sx, h_sy, h_sw, h_sh))
    end
endtask

task automatic check_rows();
    reg [15:0] want [13:37];
    begin
        want[13] = {p_state, p_seeking, p_tk_speed, p_tk_rev, p_sub_on, p_pts_v, 2'd0, p_sub_track};
        want[14] = {pcm_busy, pic_known, pic_wide, menu_aa, zoom, 6'd0, p_aud_track};
        want[17] = p_chapter; want[18] = p_n_chapters; want[19] = p_playlist;
        want[20] = p_n_items[15:0]; want[21] = p_n_items[31:16]; want[22] = p_key_item[15:0]; want[23] = p_key_item[31:16];
        want[24] = p_pts[15:0]; want[25] = p_pts[31:16]; want[26] = {15'd0, p_pts[32]};
        want[37] = pcm_under;
        for (int i = 13; i <= 37; i++)
            if ((i <= 26 || i == 37) && i != 15 && i != 16 && rd[i] !== want[i])
                `FAIL("rows", $sformatf("HOST_RD word %0d %h, want %h", i, rd[i], want[i]))
    end
endtask

reg [15:0] int_cmds [0:8];
initial begin
    int_cmds[0] = 16'h0000; int_cmds[1] = 16'h0005; int_cmds[2] = 16'h0044; int_cmds[3] = 16'h0061;
    int_cmds[4] = 16'h00F0; int_cmds[5] = 16'h00F9; int_cmds[6] = 16'h007A; int_cmds[7] = 16'h0012;
    int_cmds[8] = 16'h0063;
end

initial begin
    integer i, n0;
    repeat (5) @(negedge clk); rst_n = 1; mrst_n = 1;
    repeat (5) @(negedge clk);

    // [offbus]: Main's own commands and the telemetry's
    for (i = 0; i < 9; i++) xact(int_cmds[i], 4, 16'h0100, 16'h8000, 1, 1, 1'b0, 1'b0);
    if (host_ok !== 1'b0) `FAIL("heartbeat", "host_ok high with no HOST_WR yet")
    if (ndone != 0) `FAIL("done", "a completion from other commands")

    // [magic] + [words]: two records
    h_req = 1; h_seq = 8'h5A; h_buf = 1; h_x = 16'd123; h_y = 16'd456; h_start = 20'hABCDE; h_len = 32'h0001_2345;
    h_gen = 8'h07; h_vis = 1; h_shown_seq = 8'h59; n_stale = 16'd3;
    h_sbuf = 1; h_sx = 16'd42; h_sy = 16'd380; h_sw = 16'd636; h_sh = 16'd61;
    repeat (40) @(negedge clk);
    hrd(0); check_rd("words");
    h_req = 0; h_seq = 8'hA5; h_buf = 0; h_x = 16'hFFFF; h_y = 16'd0; h_start = 20'h00001; h_len = 32'hFFFF_FFFF;
    h_gen = 8'hFF; h_vis = 0; h_shown_seq = 8'h00; n_stale = 16'hFFFF;
    h_sbuf = 0; h_sx = 16'hFFFF; h_sy = 16'h0001; h_sw = 16'h8000; h_sh = 16'h7FFF;
    repeat (40) @(negedge clk);
    hrd(0); check_rd("words");

    // [snapshot]: the record changes after the command strobe; the read is the old one
    begin
        reg [15:0] old [0:12];
        reg [15:0] oldp [13:26];
        hrd(0); for (i = 0; i < 13; i++) old[i] = rd[i];
        for (i = 13; i <= 26; i++) oldp[i] = rd[i];
        hrd(1);
        for (i = 2; i < 12; i++)
            if (rd[i] !== old[i]) `FAIL("snapshot", $sformatf("word %0d %h, want %h (the record changed mid-read)", i, rd[i], old[i]))
        for (i = 13; i <= 26; i++)
            if (rd[i] !== oldp[i]) `FAIL("snapshot", $sformatf("P9 word %0d %h, want %h (the player's record changed mid-read)", i, rd[i], oldp[i]))
        repeat (40) @(negedge clk);
        hrd(0); check_rd("words");       // and the next read has the new one
    end

    // [heartbeat]: a matching PROTO sets host_ok
    hwr({8'd1, 8'd3}, 16'h0000, 0, 0);
    if (host_ok !== 1'b1 || host_bad !== 1'b0) `FAIL("heartbeat", $sformatf("after a heartbeat: ok %b bad %b", host_ok, host_bad))
    hrd(0); check_rd("words");
    if (ndone != 0) `FAIL("done", "a completion from a HOST_WR without the done bit")

    // [done]: one completion, then two in a row
    hwr({8'd1, 8'd3}, {1'b1, 2'b0, 5'd0, 8'h33}, 16'd640, 16'd80);
    if (ndone != 1) `FAIL("done", $sformatf("%0d h_done for one completion", ndone))
    if ({last_seq, last_err, last_w, last_h} !== {8'h33, 5'd0, 16'd640, 16'd80})
        `FAIL("done", $sformatf("completion %h %h %0d %0d, want 33 00 640 80", last_seq, last_err, last_w, last_h))
    hwr({8'd1, 8'd3}, {1'b1, 2'b0, 5'd17, 8'h34}, 16'hFFFF, 16'd1);
    hwr({8'd1, 8'd3}, {1'b1, 2'b0, 5'd0, 8'h35}, 16'd2, 16'd3);
    if (ndone != 3) `FAIL("done", $sformatf("%0d h_done for three completions", ndone))
    if ({last_seq, last_err, last_w, last_h} !== {8'h35, 5'd0, 16'd2, 16'd3}) `FAIL("done", "the third completion's fields")

    // [bad]: a mismatched PROTO: host_bad, and its completion is ignored
    n0 = ndone;
    hwr({8'd2, 8'd3}, {1'b1, 2'b0, 5'd0, 8'h36}, 16'd1, 16'd1);
    if (host_bad !== 1'b1) `FAIL("bad", "a mismatched PROTO did not set host_bad")
    if (ndone != n0) `FAIL("bad", "a completion taken with a mismatched PROTO")
    hrd(0); check_rd("words");

    // ================= P9 =================
    // [rows]: the player's record, two sets of values
    p_state = 3'd2; p_seeking = 1; p_tk_speed = 2'd3; p_tk_rev = 1; p_sub_on = 1; p_sub_track = 5'd28; p_pts_v = 1;
    p_aud_track = 4'd9; p_chapter = 16'd17; p_n_chapters = 16'd74; p_playlist = 16'd11; p_n_items = 32'h0001_0003;
    p_key_item = 32'h8000_0002; p_pts = 33'h1_2345_6789; pcm_busy = 1; pcm_under = 16'hA55A; pic_known = 1; pic_wide = 0; menu_aa = 2'd2; zoom = 1;
    repeat (4) @(negedge clk);
    hrd(0); check_rows();
    p_state = 3'd3; p_seeking = 0; p_tk_speed = 2'd0; p_tk_rev = 0; p_sub_on = 0; p_sub_track = 5'd0; p_pts_v = 0;
    p_aud_track = 4'd0; p_chapter = 16'hFFFF; p_n_chapters = 16'd0; p_playlist = 16'hFFFF; p_n_items = 32'hFFFF_FFFF;
    p_key_item = 32'd0; p_pts = 33'h0_FFFF_0000; pcm_busy = 0; pcm_under = 16'h0001;
    repeat (4) @(negedge clk);
    hrd(0); check_rows();

    // [cmd]: once by its seq
    wv_clear({8'd1, 8'd3});
    wv[5] = {8'h01, 4'd13, 4'd5}; wv[6] = 16'd11; wv[7] = 16'h0003; wv[8] = 16'h0002;
    wv[9] = 16'h1111; wv[10] = 16'h2222; wv[11] = 16'h0033;
    hwrv();
    if (hc_v !== 1'b1) `FAIL("cmd", "a new seq not taken")
    if ({hc_code, hc_arg, hc_pl, hc_item, hc_pts} !== {4'd13, 4'd5, 16'd11, 32'h0002_0003, 48'h0033_2222_1111})
        `FAIL("cmd", $sformatf("the command %h %h %h %h %h", hc_code, hc_arg, hc_pl, hc_item, hc_pts))
    hrd(0); if (rd[15][15:8] !== 8'h00) `FAIL("cmd", "the echo moved before the command was taken")
    wv[5] = {8'h02, 4'd7, 4'd0};             // a new seq while one is held: waits (not seen)
    hwrv();
    if (hc_code !== 4'd13) `FAIL("cmd", "a held command overwritten")
    @(negedge clk); hc_take = 1; @(negedge clk); hc_take = 0;
    if (hc_v !== 1'b0) `FAIL("cmd", "hc_v held after its take")
    hrd(0); if (rd[15][15:8] !== 8'h01) `FAIL("cmd", $sformatf("echo %h after the take, want 01", rd[15][15:8]))
    wv[5] = {8'h01, 4'd13, 4'd5};            // the same seq again: never taken twice
    hwrv(); hwrv();
    if (hc_v !== 1'b0) `FAIL("cmd", "a command taken twice (its seq unchanged)")
    wv[1] = {8'd2, 8'd3}; wv[5] = {8'h05, 4'd4, 4'd0};      // a mismatched PROTO: not taken
    hwrv();
    if (hc_v !== 1'b0) `FAIL("cmd", "a command taken with a mismatched PROTO")
    wv[1] = {8'd1, 8'd3};
    hwrv();
    if (hc_v !== 1'b1 || hc_code !== 4'd4) `FAIL("cmd", "the next seq not taken")
    @(negedge clk); hc_take = 1; @(negedge clk); hc_take = 0;

    // [levels]
    wv[12] = 16'hA5F0; wv[13] = 16'hE000;
    hwrv();
    if (grab !== 16'hA5F0 || ui !== 1'b1 || menu !== 1'b1 || mute !== 1'b1) `FAIL("levels", $sformatf("grab %h ui %b menu %b mute %b", grab, ui, menu, mute))
    hrd(0); check_rd("levels");
    wv[13] = 16'h4000; hwrv();
    if (ui !== 1'b0 || menu !== 1'b1 || mute !== 1'b0) `FAIL("levels", $sformatf("ctl 4000 not followed: ui %b menu %b mute %b", ui, menu, mute))
    wv[13] = 16'h2000; hwrv();
    if (ui !== 1'b0 || menu !== 1'b0 || mute !== 1'b1) `FAIL("levels", $sformatf("ctl 2000 not followed: ui %b menu %b mute %b", ui, menu, mute))
    wv[13] = 16'hA000; wv[12] = 16'h0FFF; hwrv();                    // (mute held up: the timeout must drop it)
    if (ui !== 1'b1 || menu !== 1'b0 || mute !== 1'b1) `FAIL("levels", $sformatf("ctl a000 not followed: ui %b menu %b mute %b", ui, menu, mute))

    // [events]: two player events, a grabbed key, a key in the same cycle as an event
    @(negedge clk); ev_in_v = 1; ev_in_code = 4'd1; ev_in_data = 16'd5;
    @(negedge clk); ev_in_v = 0; key_press = 16'h0020;               // grabbed (bit 5)
    @(negedge clk); key_press = 16'h1000;                            // NOT grabbed (bit 12): no KEY
    @(negedge clk); key_press = 16'h0001; ev_in_v = 1; ev_in_code = 4'd3; ev_in_data = 16'hBEEF;
    @(negedge clk); key_press = 0; ev_in_v = 0;
    repeat (4) @(negedge clk);
    hrd(0);
    if (rd[27][7:0] - rd[28][7:0] !== 8'd4) `FAIL("events", $sformatf("%0d unread, want 4 (w %h r %h)", rd[27][7:0] - rd[28][7:0], rd[27], rd[28]))
    if ({rd[29][3:0], rd[30], rd[31][3:0], rd[32], rd[33][3:0], rd[34], rd[35][3:0], rd[36]} !==
        {4'd1, 16'd5, 4'd15, 16'h0020, 4'd3, 16'hBEEF, 4'd15, 16'h0001})
        `FAIL("events", $sformatf("events %h:%h %h:%h %h:%h %h:%h", rd[29], rd[30], rd[31], rd[32], rd[33], rd[34], rd[35], rd[36]))
    wv[14] = {8'd0, rd[28][7:0] + 8'd2}; hwrv();                     // consume two
    hrd(0);
    if (rd[27][7:0] - rd[28][7:0] !== 8'd2 || rd[29][3:0] !== 4'd3) `FAIL("events", "ev_rp did not pop two")
    hwrv();                                                          // the same count again: no more pops
    hrd(0); if (rd[27][7:0] - rd[28][7:0] !== 8'd2) `FAIL("events", "a repeated ev_rp popped again")
    for (i = 0; i < 9; i++) begin                                    // fill: 2 + 9 -> 8 kept, 3 lost
        @(negedge clk); ev_in_v = 1; ev_in_code = 4'd2; ev_in_data = i[15:0];
    end
    @(negedge clk); ev_in_v = 0;
    hrd(0);
    if (rd[27][7:0] - rd[28][7:0] !== 8'd8 || rd[27][15:8] !== 8'd3) `FAIL("events", $sformatf("full FIFO: %0d unread, %0d lost", rd[27][7:0] - rd[28][7:0], rd[27][15:8]))
    wv[14] = {8'd0, rd[27][7:0]}; hwrv();                            // consume all

    // [flip]
    wv[15] = {8'h07, 6'd0, 1'b1, 1'b1}; wv[16] = 16'd10; wv[17] = 16'd20; wv[18] = 16'd720; wv[19] = 16'd480;
    hwrv();
    if (hf_req !== 1'b1 || {hf_buf, hf_vis, hf_x, hf_y, hf_w, hf_h} !== {2'd1, 1'b1, 16'd10, 16'd20, 16'd720, 16'd480})
        `FAIL("flip", "the flip not taken as sent")
    hwrv(); hrd(0);
    if (rd[15][7:0] !== 8'h00) `FAIL("flip", "echoed before its ack")
    @(negedge clk); hf_ack = 1; @(negedge clk); hf_ack = 0;
    if (hf_req !== 1'b0) `FAIL("flip", "held after its ack")
    hwrv();
    if (hf_req !== 1'b0) `FAIL("flip", "a flip taken twice (its seq unchanged)")
    hrd(0); if (rd[15][7:0] !== 8'h07) `FAIL("flip", $sformatf("echo %h, want 07", rd[15][7:0]))

    // [pcm]
    wv[20] = {8'h09, 7'd0, 1'b1}; wv[21] = 16'h4321; wv[22] = 16'h0065; wv[23] = 16'h8765; wv[24] = 16'h0043;
    hwrv();
    if (hp_req !== 1'b1 || {hp_stereo, hp_start, hp_len} !== {1'b1, 24'h654321, 24'h438765}) `FAIL("pcm", "the trigger not taken as sent")
    @(negedge clk); hp_ack = 1; @(negedge clk); hp_ack = 0;
    hwrv();
    if (hp_req !== 1'b0) `FAIL("pcm", "a trigger taken twice")
    hrd(0); if (rd[16][15:8] !== 8'h09) `FAIL("pcm", "not echoed")

    // [win]: the geometry, in place; the seq echoed; win_hold through the transaction
    n_hold_seen = 0;
    wv[25] = {8'h0B, 7'd0, 1'b1}; wv[26] = 16'd200; wv[27] = 16'd100; wv[28] = 16'd360; wv[29] = 16'd240;
    wv[30] = 16'h0000; wv[31] = 16'h0002; wv[32] = 16'h5678; wv[33] = 16'h03FF;
    wv[34] = 16'h8000; wv[35] = 16'h0001; wv[36] = 16'h1234; wv[37] = 16'h0155;
    hwrv();
    if (win !== 1'b1 || {win_x, win_y, win_w, win_h} !== {10'd200, 10'd100, 10'd360, 10'd240} ||
        win_hs !== 26'h002_0000 || win_vs !== 26'h3FF_5678 || win_x0 !== 26'h001_8000 || win_y0 !== 26'h155_1234)
        `FAIL("win", $sformatf("window %b %0d %0d %0d %0d %h %h %h %h", win, win_x, win_y, win_w, win_h, win_hs, win_vs, win_x0, win_y0))
    if (n_hold_seen < NWR) `FAIL("win", $sformatf("win_hold up %0d cycles over a %0d-word HOST_WR", n_hold_seen, NWR))
    if (win_hold !== 1'b0) `FAIL("win", "win_hold up between transactions")
    win_bad = 1;
    hrd(0); check_rd("win");
    if (rd[16][7:0] !== 8'h0B) `FAIL("win", $sformatf("window seq echo %h, want 0b", rd[16][7:0]))
    win_bad = 0;
    wv[1] = {8'd2, 8'd3}; wv[26] = 16'd7; hwrv();                    // a mismatched PROTO: not written
    if (win_x !== 10'd200) `FAIL("win", "the window written by a HOST_WR with a mismatched PROTO")
    wv[1] = {8'd1, 8'd3}; wv[26] = 16'd200;

    // ================= P6d =================
    // [panel]: ui_sub from ctl[12], the status bits, the flip into planes 2 / 3
    wv[13] = 16'h3000; hwrv();                                       // (mute kept up: the timeout must drop it)
    if (ui_sub !== 1'b1 || ui !== 1'b0 || mute !== 1'b1) `FAIL("panel", $sformatf("ctl 3000: ui_sub %b ui %b mute %b", ui_sub, ui, mute))
    p_goto_open = 1; p_sub_any = 1; repeat (4) @(negedge clk);
    hrd(0); check_rd("panel");
    if (rd[12][9:7] !== 3'b111) `FAIL("panel", $sformatf("status %h: goto / sub_any / ui_sub not all shown", rd[12]))
    p_goto_open = 0; repeat (4) @(negedge clk);
    hrd(0); check_rd("panel");
    if (rd[12][9:7] !== 3'b011) `FAIL("panel", $sformatf("status %h: goto_open not followed", rd[12]))
    wv[15] = {8'h0C, 5'd0, 2'd3, 1'b1}; hwrv();
    if (hf_req !== 1'b1 || hf_buf !== 2'd3) `FAIL("panel", $sformatf("a flip into plane 3: req %b buf %0d", hf_req, hf_buf))
    @(negedge clk); hf_ack = 1; @(negedge clk); hf_ack = 0;
    wv[15] = {8'h0D, 5'd0, 2'd2, 1'b0}; hwrv();
    if (hf_req !== 1'b1 || hf_buf !== 2'd2) `FAIL("panel", $sformatf("a flip into plane 2: req %b buf %0d", hf_req, hf_buf))
    @(negedge clk); hf_ack = 1; @(negedge clk); hf_ack = 0;

    // [press]: once by its seq, one cycle, its mask, echoed at once
    n0 = n_hx;
    wv[38] = {8'h21, 8'd0}; wv[39] = 16'h4021; hwrv();
    if (n_hx != n0 + 1 || last_hx !== 16'h4021) `FAIL("press", $sformatf("%0d pulses (want 1), mask %h (want 4021)", n_hx - n0, last_hx))
    hrd(0); if (rd[38] !== 16'h0021) `FAIL("press", $sformatf("echo %h, want 0021", rd[38]))
    hwrv(); hwrv();
    if (n_hx != n0 + 1) `FAIL("press", "a press taken twice (its seq unchanged)")
    wv[1] = {8'd2, 8'd3}; wv[38] = {8'h22, 8'd0}; hwrv();
    if (n_hx != n0 + 1) `FAIL("press", "a press taken with a mismatched PROTO")
    wv[1] = {8'd1, 8'd3}; wv[39] = 16'h0003; hwrv();
    if (n_hx != n0 + 2 || last_hx !== 16'h0003) `FAIL("press", "the next seq not taken, or its mask")
    hrd(0); if (rd[38] !== 16'h0022) `FAIL("press", $sformatf("echo %h, want 0022", rd[38]))
    wv[13] = 16'hB000; wv[12] = 16'h0FFF; hwrv();                    // every level up into the timeout below
    if (ui !== 1'b1 || mute !== 1'b1 || ui_sub !== 1'b1) `FAIL("levels", "ctl b000 not followed")

    // [levels] + [events]: the heartbeat times out: the levels fall, nothing is pushed
    repeat ((1 << HB_W) + 10) @(negedge clk);
    if (host_ok !== 1'b0) `FAIL("heartbeat", "host_ok still high 2^HB_W cycles after the last heartbeat")
    if (grab !== 16'd0 || ui !== 1'b0 || menu !== 1'b0 || mute !== 1'b0) `FAIL("levels", "the levels held with the host gone")
    if (ui_sub !== 1'b0) `FAIL("panel", "ui_sub held with the host gone")
    if (win !== 1'b0) `FAIL("win", "the video window held with the host gone")
    @(negedge clk); ev_in_v = 1; ev_in_code = 4'd1; key_press = 16'hFFFF;
    @(negedge clk); ev_in_v = 0; key_press = 0;
    hrd(0); if (rd[27][7:0] !== rd[28][7:0]) `FAIL("events", "an event pushed with the host gone")
    hwr({8'd1, 8'd3}, 16'h0000, 0, 0);                                // back (B4's 4-word HOST_WR: no levels sent)
    if (grab !== 16'd0 || ui !== 1'b0) `FAIL("levels", "old levels restored when the host came back")

    // [heartbeat]: no heartbeat for 2^HB_W cycles: host_ok falls (and host_bad with it)
    repeat ((1 << HB_W) + 10) @(negedge clk);
    if (host_ok !== 1'b0) `FAIL("heartbeat", "host_ok still high 2^HB_W cycles after the last heartbeat")
    if (host_bad !== 1'b0) `FAIL("bad", "host_bad still high 2^HB_W cycles after the mismatch")
    hrd(0); check_rd("words");

    $display("umd_host_tb: the magic, every request word, one snapshot a read, off the bus for 9 other commands, the heartbeat up and timed out, a PROTO mismatch refused, %0d completions exact; P9: the player rows, commands / flips / PCM once by seq, the levels, the event FIFO (keys, pops, 3 lost); P6d: ui_sub, the status bits, planes 2 / 3, %0d press records",
             ndone, n_hx);
    $display("PASS: umd_host_tb");
    $finish;
end

endmodule
`default_nettype wire
