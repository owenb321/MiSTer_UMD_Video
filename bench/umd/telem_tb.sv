// bench/umd/telem_tb.sv -- umd/umd_telem.sv, the HIL telemetry responder, driven the way
// hps_io's EXT_BUS drives it (io_enable frames a transaction, io_strobe clocks a word,
// the first strobe carries the command), against tools/telem_layout.py's golden:
//   [magic]    word 0 is MAGIC, word 1 {FORMAT, NWORDS}
//   [words]    every word equals the table's value for the sources (static)
//   [snapshot] with every source changed right after the command strobe, the ATOMIC words
//              still answer the strobe's values and the rest the new ones
//   [offbus]   for any other command (Main's own: 0x00, 0x05, 0x44, 0x61, 0xF0, 0xF9, and
//              0x7B) the responder never drives the bus
// PASS marker: "PASS: telem_tb". Every failure path is $fatal.
`timescale 1ns/1ps
`default_nettype none
module telem_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 0;
always #18.5185 clk = ~clk;
reg        io_enable = 0, io_strobe = 0, refresh = 0;
reg [15:0] io_din = 0;
wire       drive;
wire [15:0] dout;
reg [63:0] src_v [0:127];            // (NPORTS + the refresh count: 76 since P6b3i)
`include "bench/umd/telem_tb_ports.svh"

reg [63:0] set1 [0:127], set2 [0:127];
// sized from the table (2026-10-07): at [0:63] the words past 63 were compared out of range,
// X !== X, and the responder's saturation at word 63 passed (docs/transport.md "D8, ...")
reg [15:0] exp1 [0:NWORDS-1], exp2 [0:NWORDS-1];
reg [15:0] rd [0:NWORDS-1];
string stem;
reg [15:0] int_cmds [0:6];
initial begin
    int_cmds[0] = 16'h0000; int_cmds[1] = 16'h0005; int_cmds[2] = 16'h0044; int_cmds[3] = 16'h0061;
    int_cmds[4] = 16'h00F0; int_cmds[5] = 16'h00F9; int_cmds[6] = 16'h007B;
end

// one transaction: the command then n - 1 more strobes; sources switch to set2 after the
// command strobe when `change` (tear_w: unused, kept for the call shape)
task automatic xact(input [15:0] cmd, input integer n, input bit change, input integer tear_w, input bit expect_drive);
    integer k;
    begin
        @(negedge clk); io_enable = 1;
        repeat (2) @(negedge clk);
        for (k = 0; k < n; k++) begin
            io_din = (k == 0) ? cmd : 16'd0; io_strobe = 1;
            @(negedge clk); io_strobe = 0;
            rd[k] = dout;
            if (k == 0 && change) for (int i = 0; i < NPORTS; i++) src_v[i] = set2[i];
            if (drive !== expect_drive)
                `FAIL("offbus", $sformatf("command %h word %0d: drive %b, want %b", cmd, k, drive, expect_drive))
            repeat (3) @(negedge clk);
            if (drive !== expect_drive)
                `FAIL("offbus", $sformatf("command %h between words: drive %b, want %b", cmd, drive, expect_drive))
        end
        io_enable = 0;
        repeat (3) @(negedge clk);
        if (drive !== 1'b0) `FAIL("offbus", "drive held after io_enable fell")
    end
endtask

initial begin
    integer n, fd, i, rc;
    if (!$value$plusargs("stem=%s", stem)) `FAIL("harness", "+stem= missing")
    $readmemh({stem, ".src"}, set1);
    $readmemh({stem, ".src2"}, set2);
    $readmemh({stem, ".exp"}, exp1);
    $readmemh({stem, ".exp2"}, exp2);
    n = NWORDS;
    if (NPORTS + 1 > 128) `FAIL("harness", $sformatf("%0d ports: widen src_v / set1 / set2", NPORTS))
    for (i = 0; i < NPORTS; i++) src_v[i] = set1[i];
    // the refresh count: set1's last entry
    repeat (4) @(negedge clk);
    for (i = 0; i < set1[NPORTS]; i++) begin refresh = 1; @(negedge clk); refresh = 0; @(negedge clk); end

    // [offbus] first: Main's own commands must never see the core on the bus
    for (i = 0; i < 7; i++) xact(int_cmds[i], 4, 0, -1, 1'b0);

    // [magic] + [words]
    xact(16'h007A, n, 0, -1, 1'b1);
    if (rd[0] !== 16'hB0D5) `FAIL("magic", $sformatf("word 0 %h, want B0D5", rd[0]))
    if (rd[1] !== exp1[1]) `FAIL("magic", $sformatf("word 1 %h, want %h", rd[1], exp1[1]))
    for (i = 2; i < n; i++)
        if (rd[i] !== exp1[i]) `FAIL("words", $sformatf("word %0d %h, want %h", i, rd[i], exp1[i]))

    // [snapshot]
    xact(16'h007A, n, 1, -1, 1'b1);
    for (i = 2; i < n; i++)
        if (rd[i] !== exp2[i]) `FAIL("snapshot", $sformatf("word %0d %h, want %h (sources changed after the command)", i, rd[i], exp2[i]))

    $display("telem_tb: %0d words, the magic and format, every word from its table source, the atomic group latched, off the bus for %0d other commands",
             n, 7);
    $display("PASS: telem_tb");
    $finish;
end


endmodule
`default_nettype wire
