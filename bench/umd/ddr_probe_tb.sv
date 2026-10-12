// bench/umd/ddr_probe_tb.sv -- umd/ddr_probe.sv, the passive DDR3 port watcher, on a
// scripted Avalon-MM port (the tb is both master and slave; the probe only observes):
//   [count]  write beats counted only when accepted (not under waitrequest), read beats
//            as they return
//   [owed]   read beats owed = accepted burst lengths - returned beats, back to 0
//   [busy]   the current BUSY run counts a request held under waitrequest, resets when it
//            is accepted, SATURATES at 0xFFFF (a hang must read as one, not wrap); the
//            longest run is kept and saturates too
// PASS marker: "PASS: ddr_probe_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module ddr_probe_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 0, rst_n = 0;
always #5.5555 clk = ~clk;
reg        read = 0, write = 0, waitrequest = 0, readdatavalid = 0;
reg  [7:0] burstcount = 8'd1;
wire [23:0] wr_beats, rd_beats;
wire [15:0] owed, busy, busy_max;
ddr_probe dut (.clk(clk), .rst_n(rst_n), .read(read), .write(write), .burstcount(burstcount),
               .waitrequest(waitrequest), .readdatavalid(readdatavalid), .wr_beats(wr_beats),
               .rd_beats(rd_beats), .owed(owed), .busy(busy), .busy_max(busy_max));

integer acc_w = 0, acc_r = 0, ret = 0, beats_owed = 0, i;
initial begin
    #50 rst_n = 1;
    // 200 write beats against a random waitrequest: only the accepted ones count
    for (i = 0; i < 200; i++) begin
        @(negedge clk); write = 1; waitrequest = ($urandom_range(0, 2) == 0);
        if (!waitrequest) acc_w = acc_w + 1;
    end
    @(negedge clk); write = 0; waitrequest = 0;
    // 40 read bursts of 1..8 beats, returned later
    for (i = 0; i < 40; i++) begin
        @(negedge clk); read = 1; burstcount = $urandom_range(1, 8); waitrequest = ($urandom_range(0, 3) == 0);
        if (!waitrequest) begin acc_r = acc_r + 1; beats_owed = beats_owed + burstcount; end
    end
    @(negedge clk); read = 0; waitrequest = 0;
    @(negedge clk); @(negedge clk);
    if (owed !== beats_owed[15:0]) `FAIL("owed", $sformatf("owed %0d after the commands, want %0d", owed, beats_owed))
    while (beats_owed > 0) begin
        @(negedge clk); readdatavalid = ($urandom_range(0, 1) == 1);
        if (readdatavalid) begin beats_owed = beats_owed - 1; ret = ret + 1; end
    end
    @(negedge clk); readdatavalid = 0;
    @(negedge clk);
    if (wr_beats !== acc_w[23:0] || rd_beats !== ret[23:0])
        `FAIL("count", $sformatf("writes %0d returned %0d, want %0d %0d", wr_beats, rd_beats, acc_w, ret))
    if (owed !== 16'd0) `FAIL("owed", $sformatf("owed %0d after every beat returned", owed))
    // a short BUSY run: 37 cycles held, then accepted
    @(negedge clk); write = 1; waitrequest = 1;
    // (the probe registers its inputs once, P7: it counts a cycle behind the port -- the run is
    // read one cycle after the release, when every held cycle has been counted and the
    // acceptance not yet seen)
    repeat (37) @(negedge clk);
    waitrequest = 0; @(negedge clk);
    if (busy !== 16'd37) `FAIL("busy", $sformatf("the run reads %0d after 37 held cycles", busy))
    write = 0;
    @(negedge clk); @(negedge clk);
    if (busy !== 16'd0) `FAIL("busy", "the run did not reset when the request was accepted")
    if (busy_max !== 16'd37) `FAIL("busy", $sformatf("the longest run %0d, want 37", busy_max))
    // a hang: 70,000 cycles held -- must SATURATE, not wrap
    @(negedge clk); read = 1; burstcount = 8; waitrequest = 1;
    repeat (70000) @(negedge clk);
    if (busy !== 16'hFFFF || busy_max !== 16'hFFFF)
        `FAIL("busy", $sformatf("after 70,000 held cycles: run %h longest %h, want FFFF FFFF", busy, busy_max))
    $display("ddr_probe_tb: %0d write beats, %0d read commands, %0d beats returned, owed back to 0, BUSY runs counted, reset and saturating",
             acc_w, acc_r, ret);
    $display("PASS: ddr_probe_tb");
    $finish;
end
endmodule
`default_nettype wire
