// bench/umd/sub_flip_tb.sv -- umd/sub/sub_flip.sv's hand-over of the plane to the host (P9,
// docs/hps_host.md §3.4, docs/p9.md §3.2 item 4). sub_sched's mclk requests are played by the
// bench (raise, hold until d_ack, drop), the host's flip as umd_host holds it (hf_req until
// hf_ack). vbl is a strobe every VB clk_sys cycles. Arms:
//   [sub]    without ui a subtitle request is applied at the first vbl after it and acknowledged
//   [ui]     under ui a subtitle request (a flush's hide, a flip) is acknowledged -- sub_sched
//            never waits -- but the plane keeps the host's page (and n_flips does not count it)
//   [host]   under ui a host flip is applied at the next vbl, clipped to 720 x 480 as a
//            subtitle's, and acknowledged with ONE hf_ack pulse in that vbl's cycle; a host flip
//            without ui is never applied nor acknowledged
//   [hide]   ui rising hides a shown subtitle at the next vbl; ui falling hides the page; a host
//            flip pending when ui rises shows in that same vbl (no blank frame)
// P6d (docs/panel.md §2, the panel's mode):
//   [panel]  ui_sub raised with a page pending shows it in that vbl; under ui_sub subtitle requests
//            are acknowledged, not applied; host flips into planes 2 / 3 land there; when ui_sub
//            falls the subtitle sub_sched flipped DURING it is restored whole (not hidden), and a
//            hide made during it restores as hidden; ui and ui_sub falling together hide (a menu's
//            rule wins)
// PASS marker: "PASS: sub_flip_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module sub_flip_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam logic [28:0] PL0 = 29'h0650_0000, PL1 = 29'h0658_0000, PL2 = 29'h0670_0000, PL3 = 29'h0678_0000;
localparam int VB = 300;
reg clk = 0, mclk = 0;
always #18.5185 clk = ~clk;
always #5.5556  mclk = ~mclk;
reg rst_n = 0;

integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;
wire vbl = rst_n && (cyc % VB == 0);
integer nvbl = 0;
always @(posedge clk) if (vbl) nvbl <= nvbl + 1;

reg         d_req = 0, d_buf = 0, d_vis = 0;
reg  [15:0] d_x = 0, d_y = 0, d_w = 0, d_h = 0;
wire        d_ack;
wire        vis;
wire [28:0] base;
wire  [9:0] x, w;
wire  [8:0] y, h;
wire [15:0] n_flips;
reg         ui = 0, ui_sub = 0, hf_req = 0, hf_vis = 0;
reg  [1:0]  hf_buf = 0;
reg  [15:0] hf_x = 0, hf_y = 0, hf_w = 0, hf_h = 0;
wire        hf_ack;

sub_flip #(.PLANE0(PL0), .PLANE1(PL1), .PLANE2(PL2), .PLANE3(PL3)) dut (.mclk, .mrst_n (rst_n), .d_req, .d_buf, .d_vis, .d_x, .d_y, .d_w, .d_h, .d_ack,
    .clk, .rst_n, .vbl, .vis, .base, .x, .y, .w, .h, .n_flips,
    .ui, .ui_sub, .hf_req, .hf_buf, .hf_vis, .hf_x, .hf_y, .hf_w, .hf_h, .hf_ack);

// the host's flip, held until acknowledged (umd_host's rule); every ack counted, and only at vbl
integer n_hack = 0;
always @(posedge clk) begin
    if (hf_ack) begin
        n_hack <= n_hack + 1;
        if (!hf_req) `FAIL("host", "hf_ack with no host flip held")
        hf_req <= 1'b0;
    end
end
reg vbl_q = 0;
always @(posedge clk) begin
    vbl_q <= vbl;
    if (hf_ack && !vbl_q) `FAIL("host", "hf_ack not in the cycle after a vbl")
end

// sub_sched: a request, held until its acknowledgement (mclk)
task automatic sub_req(input bit b, input bit v, input [15:0] rx, input [15:0] ry, input [15:0] rw, input [15:0] rh,
                       input string arm);
    integer t;
    begin
        @(posedge mclk); d_req <= 1; d_buf <= b; d_vis <= v; d_x <= rx; d_y <= ry; d_w <= rw; d_h <= rh;
        t = 0;
        while (!d_ack && t < 20 * VB * 4) begin @(posedge mclk); t++; end
        if (!d_ack) `FAIL(arm, "a subtitle request never acknowledged (sub_sched would wait for ever)")
        d_req <= 0;
        @(posedge mclk);
    end
endtask
task automatic host_flip(input [1:0] b, input bit v, input [15:0] rx, input [15:0] ry, input [15:0] rw, input [15:0] rh);
    begin
        @(negedge clk); hf_req = 1; hf_buf = b; hf_vis = v; hf_x = rx; hf_y = ry; hf_w = rw; hf_h = rh;
    end
endtask
task automatic to_vbl(input integer n);       // n vertical blanks later, a few cycles past the latch
    integer v0;
    begin
        v0 = nvbl;
        while (nvbl < v0 + n) @(posedge clk);
        repeat (4) @(posedge clk);
    end
endtask
task automatic expect_plane(input string arm, input bit ev, input [28:0] eb, input [9:0] ex, input [8:0] ey,
                            input [9:0] ew, input [8:0] eh);
    if (vis !== ev || (ev && {base, x, y, w, h} !== {eb, ex, ey, ew, eh}))
        `FAIL(arm, $sformatf("plane vis %b base %h %0d,%0d %0dx%0d, want vis %b base %h %0d,%0d %0dx%0d",
                             vis, base, x, y, w, h, ev, eb, ex, ey, ew, eh))
endtask

initial begin
    integer a0;
    repeat (5) @(posedge clk); rst_n = 1;
    to_vbl(1);

    // [sub]: a subtitle shown without ui
    fork sub_req(1, 1, 100, 400, 300, 40, "sub"); join_none
    to_vbl(2);
    expect_plane("sub", 1, PL1, 100, 400, 300, 40);

    // [host]: a flip without ui -- never applied, never acknowledged
    host_flip(0, 1, 0, 0, 720, 480);
    to_vbl(3);
    if (n_hack != 0) `FAIL("host", "a host flip acknowledged without ui")
    expect_plane("host", 1, PL1, 100, 400, 300, 40);
    @(negedge clk); hf_req = 0;

    // [hide]: ui rises with no host flip: the subtitle is hidden at the next vbl
    @(negedge clk); ui = 1;
    to_vbl(1);
    if (vis !== 1'b0) `FAIL("hide", "the subtitle left up when ui rose")

    // [host]: a flip under ui, clipped at the right and bottom edges, one ack
    a0 = n_hack;
    host_flip(1, 1, 600, 400, 200, 200);
    to_vbl(1);
    if (n_hack != a0 + 1) `FAIL("host", $sformatf("%0d acknowledgements for one host flip", n_hack - a0))
    expect_plane("host", 1, PL1, 600, 400, 120, 80);
    to_vbl(2);
    if (n_hack != a0 + 1) `FAIL("host", "a host flip acknowledged twice")

    // [ui]: a subtitle hide and flip under ui (a menu starting a clip): acknowledged, not applied
    // (nor counted: n_flips counts what the plane latched)
    a0 = n_flips;
    sub_req(0, 0, 0, 0, 0, 0, "ui");
    expect_plane("ui", 1, PL1, 600, 400, 120, 80);
    sub_req(0, 1, 10, 10, 50, 50, "ui");
    to_vbl(1);
    expect_plane("ui", 1, PL1, 600, 400, 120, 80);
    if (n_flips != a0) `FAIL("ui", $sformatf("%0d subtitle requests latched under ui", n_flips - a0))

    // [host]: the host flips back to plane 0, full screen
    host_flip(0, 1, 0, 0, 720, 480);
    to_vbl(1);
    expect_plane("host", 1, PL0, 0, 0, 720, 480);

    // [hide]: ui falls: the page is hidden at the next vbl
    @(negedge clk); ui = 0;
    to_vbl(1);
    if (vis !== 1'b0) `FAIL("hide", "the page left up when ui fell")
    // ... and subtitles apply again
    fork sub_req(1, 1, 20, 300, 100, 30, "sub"); join_none
    to_vbl(2);
    expect_plane("sub", 1, PL1, 20, 300, 100, 30);

    // [hide]: ui rises WITH a host flip pending: shown in that same vbl, no blank frame
    host_flip(0, 1, 40, 50, 60, 70);
    @(negedge clk); ui = 1;
    begin : same
        integer v0;
        v0 = nvbl;
        while (nvbl == v0) begin
            @(posedge clk);
            if (nvbl == v0 && vis !== 1'b1) `FAIL("hide", "the plane blank before the vbl")
        end
        repeat (3) @(posedge clk);
    end
    expect_plane("hide", 1, PL0, 40, 50, 60, 70);
    @(negedge clk); ui = 0;
    to_vbl(2);

    // ================= P6d: the panel's mode =================
    // a subtitle up, then ui_sub with the panel's first page pending: the page in that same vbl
    fork sub_req(1, 1, 100, 400, 300, 40, "panel"); join_none
    to_vbl(2);
    expect_plane("panel", 1, PL1, 100, 400, 300, 40);
    host_flip(2, 1, 185, 90, 350, 154);
    @(negedge clk); ui_sub = 1;
    begin : same_sub
        integer v0;
        v0 = nvbl;
        while (nvbl == v0) begin
            @(posedge clk);
            if (nvbl == v0 && vis !== 1'b1) `FAIL("panel", "the plane blank before ui_sub's first vbl")
        end
        repeat (3) @(posedge clk);
    end
    expect_plane("panel", 1, PL2, 185, 90, 350, 154);
    // under ui_sub: sub_sched flips to plane 0 (a new subtitle): acknowledged, not applied
    a0 = n_flips;
    sub_req(0, 1, 30, 380, 200, 40, "panel");
    to_vbl(1);
    expect_plane("panel", 1, PL2, 185, 90, 350, 154);
    // the panel's next page, into plane 3
    host_flip(3, 1, 185, 90, 350, 154);
    to_vbl(1);
    expect_plane("panel", 1, PL3, 185, 90, 350, 154);
    // ui_sub falls: the subtitle flipped during it, restored whole at the next vbl (not hidden)
    @(negedge clk); ui_sub = 0;
    to_vbl(1);
    expect_plane("panel", 1, PL0, 30, 380, 200, 40);
    // ... and subtitles apply again
    fork sub_req(1, 1, 50, 350, 100, 30, "panel"); join_none
    to_vbl(2);
    expect_plane("panel", 1, PL1, 50, 350, 100, 30);
    // a hide made during ui_sub restores as hidden
    host_flip(2, 1, 185, 90, 350, 154);
    @(negedge clk); ui_sub = 1;
    to_vbl(1);
    expect_plane("panel", 1, PL2, 185, 90, 350, 154);
    sub_req(1, 0, 0, 0, 0, 0, "panel");
    to_vbl(1);
    @(negedge clk); ui_sub = 0;
    to_vbl(1);
    if (vis !== 1'b0) `FAIL("panel", "a subtitle hidden during ui_sub came back at its fall")
    // ui and ui_sub up together, then both down: hidden (the menu's rule), not restored
    fork sub_req(0, 1, 60, 360, 120, 30, "panel"); join_none
    to_vbl(2);
    host_flip(2, 1, 0, 0, 720, 480);
    @(negedge clk); ui = 1; ui_sub = 1;
    to_vbl(1);
    @(negedge clk); ui = 0; ui_sub = 0;
    to_vbl(1);
    if (vis !== 1'b0) `FAIL("panel", "ui and ui_sub fell together: a subtitle restored over the menu's close")
    to_vbl(1);

    $display("sub_flip_tb: subtitles applied without ui; under ui acknowledged but not applied; %0d host flips (clipped, one ack each, none without ui); hidden at ui's edges, the first page in ui's own vbl; P6d: ui_sub's pages in planes 2 / 3, the subtitle restored at its fall; %0d latches",
             n_hack, n_flips);
    $display("PASS: sub_flip_tb");
    $finish;
end

initial begin #20_000_000; `FAIL("harness", "timeout") end

endmodule
`default_nettype wire
