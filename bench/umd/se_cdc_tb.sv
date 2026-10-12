// bench/umd/se_cdc_tb.sv -- umd/se_cdc.sv: 81 MHz writer, 27 MHz reader, random stalls on
// both sides (+wr_gap / +rd_stall percentages).
//   [order] every word arrives, in order, once (scoreboard, `!==`)
//   [rate]  with no stalls the reader sees a word at least every 2 of its cycles
//   [count] all 20,000 words delivered
// PASS marker: "PASS: se_cdc_tb".
`timescale 1ns/1ps
module se_cdc_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
localparam int N = 20000;
reg wclk = 0, rclk = 0;
always #6.173 wclk = ~wclk;
always #18.519 rclk = ~rclk;
reg wrst_n = 0, rrst_n = 0;
reg in_valid = 0; reg [47:0] in_data = 0; wire in_ready;
wire out_valid; reg out_ready = 0; wire [47:0] out_data;
se_cdc dut (.wr_clk(wclk), .wr_rst_n(wrst_n), .in_valid(in_valid), .in_ready(in_ready), .in_data(in_data),
            .rd_clk(rclk), .rd_rst_n(rrst_n), .out_valid(out_valid), .out_ready(out_ready), .out_data(out_data));
function automatic [47:0] word(input int i); word = {i[15:0], ~i[15:0], i[7:0] ^ 8'h5A, i[15:8]}; endfunction
int wr_gap = 30, rd_stall = 30, nw = 0, nr = 0, rd_cycles = 0, phase_fast = 0;
initial begin
    if (!$value$plusargs("wr_gap=%d", wr_gap)) wr_gap = 30;
    if (!$value$plusargs("rd_stall=%d", rd_stall)) rd_stall = 30;
    #100 wrst_n = 1; rrst_n = 1;
end
always @(posedge wclk) if (wrst_n) begin
    if (in_valid && in_ready) nw <= nw + 1;
    if (!(in_valid && !in_ready)) begin
        if (nw + (in_valid && in_ready) < N && $urandom_range(0, 99) >= (phase_fast ? 0 : wr_gap)) begin
            in_valid <= 1; in_data <= word(nw + (in_valid && in_ready));
        end else in_valid <= 0;
    end
end
always @(posedge rclk) if (rrst_n) begin
    if (out_valid && out_ready) begin
        if (out_data !== word(nr)) `FAIL("order", $sformatf("word %0d: %h, want %h", nr, out_data, word(nr)))
        nr <= nr + 1;
    end
    out_ready <= (phase_fast ? 1'b1 : ($urandom_range(0, 99) >= rd_stall));
end
// the rate phase: the last 2,000 words with no stalls; count reader cycles
always @(posedge rclk) if (phase_fast && nr < N) rd_cycles <= rd_cycles + 1;
initial begin
    wait (nr >= N - 2000); phase_fast = 1;
    wait (nr >= N);
    repeat (50) @(posedge rclk);
    if (nr !== N) `FAIL("count", $sformatf("%0d words delivered", nr))
    if (out_valid !== 1'b0) `FAIL("count", "a word nobody wrote")
    if (rd_cycles > 2 * 2000 + 20) `FAIL("rate", $sformatf("2000 words took %0d reader cycles", rd_cycles))
    $display("se_cdc_tb: %0d words in order; unstalled, 2000 words in %0d reader cycles", nr, rd_cycles);
    $display("PASS: se_cdc_tb");
    $finish;
end
initial begin #50_000_000; `FAIL("count", $sformatf("timeout: %0d of %0d words", nr, N)) end
endmodule
