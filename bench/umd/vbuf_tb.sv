// bench/umd/vbuf_tb.sv -- umd/vbuf.sv (the compressed-video buffer) through umd/ddr_mux2.sv
// (as master B) into bench/umd/ddr_model.sv, beside a live master A (the DPB's shape:
// random read / write bursts, gapped beats, aborts), on its two real clocks (clk_sys 27,
// clk_mem 90 MHz). A small ring (RING_AW 10: 8 KB) so the streams wrap it many times.
//
// The source is a list the bench made -- random bytes, a mark (with a random PTS) at random
// positions, and one stretch with a mark every 4 bytes to fill the stamp queue -- presented
// with random gaps; the sink takes with random stalls, some long enough to fill the ring.
// Scored against the LIST, never the RTL's counters:
//   [data]  every byte out equals the list's byte at that index, in order, none extra
//   [mark]  every byte out carries the list's mark (and its PTS when marked; P6b3i: its item
//           tag too, which the bench derives from the PTS: bits [1:0] ^ [3:2])
//   [clear] a clear (the mount reset) mid-stream at a random time: after it the first byte
//           out is the NEW stream's first byte -- nothing stale from the old ring
//   [flush] the title's end: flush_in after the last byte; every byte (the padded partial
//           word's real ones) delivered, nothing more, then flush_out
//   [flow]  the ring filled (in_ready low with the sink stalled) and the stamp queue filled
//           (the dense stretch): the flow-control paths ran; no late byte
//   [avalon] the model's rule on the port (a command withdrawn or changed under waitrequest);
//           with +clear_held the clear is timed onto a READ command the port is holding off
//           (+wait_pct high keeps it held): the engine must keep presenting it
//   [live]  a byte out at least every 400k clk_sys cycles
// PASS marker: "PASS: vbuf_tb".
`timescale 1ns/1ps
`default_nettype none
module vbuf_tb;
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end
localparam [28:0] BASE  = 29'h0600_0000;
localparam [28:0] VBASE = BASE + 29'd2048;
localparam int    RAW   = 10;

reg clk = 0;  always #18.518 clk = ~clk;     // clk_sys 27 MHz
reg mclk = 0; always #5.556 mclk = ~mclk;    // clk_mem 90 MHz
reg rst_n = 0, mrst_n = 0;

// ---- the vbuf ----
reg  [7:0]  in_byte = 0; reg in_mark = 0; reg [32:0] in_pts = 0; reg in_valid = 0; wire in_ready;
reg  [1:0]  in_ep = 0; wire [1:0] out_ep;
function automatic [1:0] epf(input [32:0] p); epf = p[1:0] ^ p[3:2]; endfunction   // the bench's tag of a PTS
reg         flush_in = 0;
wire [7:0]  out_byte; wire out_mark; wire [32:0] out_pts; wire out_valid; reg out_ready = 0;
wire        flush_out, running;
wire [31:0] fill, fill_max, bp_cycles; wire [15:0] late_bytes;
wire [28:0] b_address; wire [7:0] b_burstcount; wire b_read, b_write; wire [63:0] b_writedata;
wire        b_waitrequest, b_readdatavalid; wire [63:0] b_readdata;
vbuf #(.BASE(VBASE), .RING_AW(RAW), .IDLE_T(256), .FLUSH_IDLE(4096)) dut (
    .clk(clk), .rst_n(rst_n), .in_byte(in_byte), .in_mark(in_mark), .in_pts(in_pts), .in_ep(in_ep), .in_valid(in_valid),
    .in_ready(in_ready), .flush_in(flush_in), .out_byte(out_byte), .out_mark(out_mark), .out_pts(out_pts), .out_ep(out_ep),
    .out_valid(out_valid), .out_ready(out_ready), .flush_out(flush_out), .fill(fill), .fill_max(fill_max),
    .bp_cycles(bp_cycles), .late_bytes(late_bytes), .running(running),
    .mclk(mclk), .mrst_n(mrst_n), .b_address(b_address), .b_burstcount(b_burstcount), .b_read(b_read),
    .b_write(b_write), .b_writedata(b_writedata), .b_waitrequest(b_waitrequest), .b_readdata(b_readdata),
    .b_readdatavalid(b_readdatavalid));

// ---- master A and the port ----
reg  [28:0] a_address = BASE; reg [7:0] a_burstcount = 1; reg a_read = 0, a_write = 0;
reg  [63:0] a_writedata = 0; reg a_abort = 0;
wire        a_waitrequest, a_readdatavalid; wire [63:0] a_readdata;
wire [28:0] ddr_address; wire [7:0] ddr_burstcount, ddr_byteenable; wire ddr_read, ddr_write;
wire [63:0] ddr_writedata, ddr_readdata; wire ddr_waitrequest, ddr_readdatavalid;
int unwritten;
ddr_mux2 mux (.clk(mclk), .rst_n(mrst_n),
    .a_address(a_address), .a_burstcount(a_burstcount), .a_read(a_read), .a_write(a_write), .a_writedata(a_writedata),
    .a_byteenable(8'hFF), .a_abort(a_abort), .a_waitrequest(a_waitrequest), .a_readdata(a_readdata), .a_readdatavalid(a_readdatavalid),
    .b_address(b_address), .b_burstcount(b_burstcount), .b_read(b_read), .b_write(b_write),
    .b_writedata(b_writedata), .b_waitrequest(b_waitrequest), .b_readdata(b_readdata), .b_readdatavalid(b_readdatavalid),
    .ddr_address(ddr_address), .ddr_burstcount(ddr_burstcount), .ddr_read(ddr_read), .ddr_write(ddr_write),
    .ddr_writedata(ddr_writedata), .ddr_byteenable(ddr_byteenable), .ddr_waitrequest(ddr_waitrequest),
    .ddr_readdata(ddr_readdata), .ddr_readdatavalid(ddr_readdatavalid));
ddr_model #(.BASE(BASE), .AW(12)) ddr (.clk(mclk), .rst_n(mrst_n), .address(ddr_address), .burstcount(ddr_burstcount),
    .read(ddr_read), .write(ddr_write), .writedata(ddr_writedata), .byteenable(ddr_byteenable),
    .waitrequest(ddr_waitrequest), .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

// A: random bursts in words 0..1023 (its own scoreboard), an abort now and then
logic [63:0] asb [0:1023];
logic [63:0] qa [$];
int a_beats = 0, a_aborts = 0, a_quiet = 0; bit a_hush = 0;
always @(posedge mclk) if (mrst_n && a_readdatavalid && !a_hush) begin
    if (qa.size() == 0) `FAIL("data", "A: a beat nobody asked for")
    if (a_readdata !== qa[0]) `FAIL("data", $sformatf("A beat: %h, want %h (master B corrupted A's words?)", a_readdata, qa[0]))
    void'(qa.pop_front()); a_beats = a_beats + 1;
end
bit tb_done = 0;
initial begin : a_master
    for (int i = 0; i < 1024; i++) asb[i] = 64'd0;
    wait (mrst_n);
    for (int i = 0; i < 1024; i++) ddr.poke(BASE + i, 64'd0);
    while (!tb_done) begin
        int a, n;
        a = $urandom_range(0, 1016); n = $urandom_range(1, 8);
        if ($urandom_range(0, 199) == 0) begin
            // an abort (the DPB master's mount reset): its reads' beats are swallowed
            @(negedge mclk); a_abort = 1; a_hush = 1; qa.delete();
            repeat (40) @(negedge mclk); a_abort = 0; a_aborts = a_aborts + 1;
            repeat (300) @(negedge mclk); a_hush = 0;
        end else if ($urandom_range(0, 1)) begin
            for (int j = 0; j < n; j++) begin
                logic [63:0] d; d = {$urandom, $urandom};
                @(negedge mclk);
                a_address = BASE + a; a_burstcount = n; a_write = 1; a_writedata = d;
                @(posedge mclk); while (a_waitrequest) @(posedge mclk);
                asb[a + j] = d;
            end
            @(negedge mclk); a_write = 0;
        end else begin
            @(negedge mclk);
            a_address = BASE + a; a_burstcount = n; a_read = 1;
            @(posedge mclk); while (a_waitrequest) @(posedge mclk);
            for (int j = 0; j < n; j++) qa.push_back(asb[a + j]);
            @(negedge mclk); a_read = 0;
        end
        repeat ($urandom_range(0, 12)) @(negedge mclk);
    end
end

// ---- the streams ----
logic [7:0]  sbyte [$]; logic smark [$]; logic [32:0] spts [$];
int si = 0, so = 0;                  // next to send, next expected out
int nmarks = 0, bp_seen = 0, stfull_seen = 0, clears = 0, flushes = 0, last_out = 0, cyc = 0;
task automatic make_stream(input int len, input int dense_at);
    sbyte.delete(); smark.delete(); spts.delete();
    for (int i = 0; i < len; i++) begin
        logic [31:0] r0, r1; logic [7:0] b8; logic m1; logic [32:0] p33;
        r0 = $urandom; r1 = $urandom;
        b8 = r0[7:0]; p33 = {r1[0], r0};
        if (i >= dense_at && i < dense_at + 4096) m1 = ((i % 4) == 0);
        else m1 = ($urandom_range(0, 299) == 0);
        sbyte.push_back(b8); smark.push_back(m1); spts.push_back(p33);
    end
endtask

// the sink: stalls, some of them long
int stall_left = 0;
always @(negedge clk) begin
    if (stall_left > 0) begin stall_left = stall_left - 1; out_ready = 0; end
    else if ($urandom_range(0, 9999) == 0) begin stall_left = $urandom_range(20000, 60000); out_ready = 0; end
    else out_ready = ($urandom_range(0, 3) != 0);
end
always @(posedge clk) if (rst_n) begin
    cyc <= cyc + 1;
    if (in_valid && !in_ready && running) bp_seen <= bp_seen + 1;
    if (dut.st_full) stfull_seen <= stfull_seen + 1;
    if (out_valid && out_ready) begin
        if (so >= sbyte.size()) `FAIL("data", $sformatf("a byte past the stream's end (%0d bytes): %h", sbyte.size(), out_byte))
        if (out_byte !== sbyte[so]) begin
            if (so == 0 && clears > 0) `FAIL("clear", $sformatf("the first byte after a clear is %h, want the new stream's %h", out_byte, sbyte[0]))
            `FAIL("data", $sformatf("byte %0d: %h, want %h", so, out_byte, sbyte[so]))
        end
        if (out_mark !== smark[so]) `FAIL("mark", $sformatf("byte %0d: mark %0d, want %0d", so, out_mark, smark[so]))
        if (out_mark && out_pts !== spts[so]) `FAIL("mark", $sformatf("byte %0d: pts %h, want %h", so, out_pts, spts[so]))
        if (out_mark && out_ep !== epf(spts[so]))
            `FAIL("mark", $sformatf("byte %0d: item tag %0d, want %0d", so, out_ep, epf(spts[so])))
        if (out_mark) nmarks <= nmarks + 1;
        so <= so + 1; last_out <= cyc;
    end
    if (cyc - last_out > 400000 && !flush_out && si > so) `FAIL("live", $sformatf("no byte out for 400k cycles (%0d in, %0d out, fill %0d)", si, so, fill))
end

// the source (valid / ready: a byte held until taken)
task automatic send(input int upto, input int gap_pct);
    while (si < upto) begin
        @(negedge clk);
        if ($urandom_range(0, 99) < gap_pct) begin in_valid = 0; continue; end
        in_byte = sbyte[si]; in_mark = smark[si]; in_pts = spts[si]; in_ep = epf(spts[si]); in_valid = 1;
        @(posedge clk); while (!in_ready) @(posedge clk);
        si = si + 1;
        #1 in_valid = 0;
    end
endtask

int seed; bit held_at_clear = 0;
initial begin
    if ($value$plusargs("seed=%d", seed)) void'($urandom(seed));
    #100 mrst_n = 1;
    #500 rst_n = 1;
    // stream 1: cleared at a random point while bytes are in flight everywhere
    make_stream(60000, 20000);
    fork
        send(60000, 20);
        begin
            repeat ($urandom_range(300000, 600000)) @(posedge clk);
            disable fork;
        end
    join_any
    disable fork;
    if (so == 0 || si == so) `FAIL("clear", "the clear landed with nothing in flight (the arm is vacuous)")
    if ($test$plusargs("clear_held")) begin
        // land the clear on a read the port holds off (the reload hang's shape)
        @(posedge mclk); while (!(b_read && b_waitrequest)) @(posedge mclk);
        held_at_clear = 1;
    end
    @(negedge clk); in_valid = 0; rst_n = 0; clears = 1;
    repeat (16) @(negedge clk);
    make_stream(50001, 30000);     // not a whole number of words: the flush pads
    si = 0; so = 0;
    rst_n = 1;
    // stream 2 to its end, then the title's end
    send(50001, 30);
    flush_in = 1;
    fork
        wait (flush_out);
        begin repeat (3000000) @(posedge clk); `FAIL("flush", $sformatf("no flush_out: %0d of %0d bytes out", so, sbyte.size())) end
    join_any
    disable fork;
    repeat (20000) @(posedge clk);          // nothing more may come out
    if (so != sbyte.size()) `FAIL("flush", $sformatf("%0d of %0d bytes out at flush_out", so, sbyte.size()))
    if (bp_seen == 0) `FAIL("flow", "the ring never held the source back (the flow-control arm is vacuous)")
    if (stfull_seen == 0) `FAIL("flow", "the stamp queue never filled (the dense arm is vacuous)")
    if (late_bytes != 0) `FAIL("flow", $sformatf("%0d late bytes", late_bytes))
    if ($test$plusargs("clear_held") && !held_at_clear) `FAIL("clear", "the clear never met a held read (the arm is vacuous)")
    if (a_beats < 1000) `FAIL("data", $sformatf("master A moved only %0d beats", a_beats))
    tb_done = 1;
    $display("vbuf_tb: 1 clear mid-stream, then %0d bytes (%0d marks) through an 8 KB ring (fill max %0d), source held back %0d cycles, stamp queue full %0d cycles, A %0d read beats and %0d aborts beside it",
             so, nmarks, fill_max, bp_seen, stfull_seen, a_beats, a_aborts);
    $display("PASS: vbuf_tb");
    $finish;
end
endmodule
`default_nettype wire
