// bench/umd/zoom_ctl_tb.sv -- fj#71 Zoom's decision and band (umd/zoom_ctl.sv, docs/zoom.md).
// Run through bench/umd/run_zoom.sh (--red).
//
// The reference is the rule as decided (docs/zoom.md §3, the gating table), written here from that
// table, not from the RTL: Zoom is live iff Aspect Ratio is Zoom, the raster is 480p, media is seen,
// the player is not stopped, no disc menu is up, a picture is shown, it is 4:3 (declared), and it is
// 720 x 480 (45 x 30 MBs). The band is raster lines 60 .. 419.
//
// Arms (each gating input its own, so a mutation that drops one is caught by its own):
//   [G-sel] [G-il] [G-media] [G-stop] [G-menu] [G-valid] [G-wide] [G-w] [G-hf]
//           from the all-live inputs, that one input alone made not-live: zoom 0 after a vbl, and
//           back to 1 after the next (so the arm also proves the input is not stuck)
//   [R]     1,000 random input sets, each latched by a vbl: zoom == the reference
//   [L]     inputs changed between vbls never move zoom; the next vbl takes them
//   [W0]    the band's top edge: cut at line 59, not at 60
//   [W1]    its bottom edge: not cut at 419, cut at 420
//   [C]     zoom 0: no line cut (0 .. 524)
//   [X]     no X on zoom / cut after reset
// All comparisons !==. PASS: zoom_ctl_tb.

`timescale 1ns/1ps
`default_nettype none

module zoom_ctl_tb;
    reg         clk = 1'b0;
    always #5 clk = ~clk;
    reg         rst_n = 1'b0;
    reg         sel, il, media_seen, stopped, host_menu, sh_valid, pic_wide, vbl;
    reg  [7:0]  sh_w, sh_hf;
    reg  [11:0] v_pos;
    wire        zoom, cut;

    zoom_ctl dut (.clk, .rst_n, .sel, .il, .media_seen, .stopped, .host_menu, .sh_valid, .pic_wide,
                  .sh_w, .sh_hf, .vbl, .v_pos, .zoom, .cut);

    function automatic bit ref_live();
        ref_live = sel && !il && media_seen && !stopped && !host_menu && sh_valid && !pic_wide &&
                   sh_w == 8'd45 && sh_hf == 8'd30;
    endfunction

    task automatic fail(input string arm, input string msg);
        $display("FAIL [%s] %s", arm, msg);
        $fatal(1, "zoom_ctl_tb: failed");
    endtask

    task automatic live_inputs();
        sel = 1; il = 0; media_seen = 1; stopped = 0; host_menu = 0; sh_valid = 1; pic_wide = 0;
        sh_w = 8'd45; sh_hf = 8'd30;
    endtask

    task automatic pulse_vbl();
        @(negedge clk) vbl = 1'b1;
        @(negedge clk) vbl = 1'b0;
        @(negedge clk);
    endtask

    // one input off from the all-live set: zoom must fall at the vbl, and rise again when restored
    task automatic gate(input string arm, input int which);
        live_inputs(); pulse_vbl();
        if (zoom !== 1'b1) fail(arm, "not live with every input live");
        case (which)
            0: sel = 0;          1: il = 1;          2: media_seen = 0;  3: stopped = 1;
            4: host_menu = 1;    5: sh_valid = 0;    6: pic_wide = 1;    7: sh_w = 8'd44;
            default: sh_hf = 8'd15;
        endcase
        pulse_vbl();
        if (zoom !== 1'b0) fail(arm, "still zoomed with this input not live");
        live_inputs(); pulse_vbl();
        if (zoom !== 1'b1) fail(arm, "not back after the input was restored");
    endtask

    integer i, v;
    initial begin
        live_inputs(); vbl = 0; v_pos = 12'd0;
        repeat (3) @(negedge clk);
        if (zoom !== 1'b0 || cut !== 1'b0) fail("X", $sformatf("in reset: zoom %b cut %b", zoom, cut));
        rst_n = 1'b1;
        @(negedge clk);
        if (zoom !== 1'b0) fail("L", "zoomed before any vbl");

        gate("G-sel", 0);  gate("G-il", 1);     gate("G-media", 2);
        gate("G-stop", 3); gate("G-menu", 4);   gate("G-valid", 5);
        gate("G-wide", 6); gate("G-w", 7);      gate("G-hf", 8);

        // [L] no change without a vbl, in both directions
        live_inputs(); pulse_vbl();
        stopped = 1; repeat (50) @(negedge clk);
        if (zoom !== 1'b1) fail("L", "fell without a vbl");
        pulse_vbl();
        if (zoom !== 1'b0) fail("L", "the vbl not taken (fall)");
        stopped = 0; repeat (50) @(negedge clk);
        if (zoom !== 1'b0) fail("L", "rose without a vbl");
        pulse_vbl();
        if (zoom !== 1'b1) fail("L", "the vbl not taken (rise)");

        // [W0] / [W1] the band, zoomed
        for (v = 0; v < 525; v = v + 1) begin
            v_pos = v[11:0]; #1;
            if (v < 60 || v >= 420) begin
                if (cut !== 1'b1) fail(v < 60 ? "W0" : "W1", $sformatf("line %0d not cut", v));
            end else if (cut !== 1'b0) fail(v < 240 ? "W0" : "W1", $sformatf("line %0d cut", v));
        end

        // [C] not zoomed: nothing cut
        sel = 0; pulse_vbl();
        for (v = 0; v < 525; v = v + 1) begin
            v_pos = v[11:0]; #1;
            if (cut !== 1'b0) fail("C", $sformatf("line %0d cut with Zoom not in force", v));
        end

        // [R] random sets, biased towards live (each input live 7 times in 8)
        for (i = 0; i < 1000; i = i + 1) begin
            sel = ($urandom % 8) != 0;  il = ($urandom % 8) == 0;  media_seen = ($urandom % 8) != 0;
            stopped = ($urandom % 8) == 0;  host_menu = ($urandom % 8) == 0;  sh_valid = ($urandom % 8) != 0;
            pic_wide = ($urandom % 8) == 0;
            sh_w  = (($urandom % 8) != 0) ? 8'd45 : 8'($urandom);
            sh_hf = (($urandom % 8) != 0) ? 8'd30 : 8'($urandom);
            pulse_vbl();
            if (zoom !== ref_live()) fail("R", $sformatf("set %0d: zoom %b, the rule says %b", i, zoom, ref_live()));
        end

        $display("zoom_ctl_tb: 9 gates, the latch, the band 60 .. 419, 1000 random sets");
        $display("PASS: zoom_ctl_tb");
        $finish;
    end
endmodule

`default_nettype wire
