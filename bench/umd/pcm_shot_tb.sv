// bench/umd/pcm_shot_tb.sv -- umd/pcm_shot.sv, the menus' sound one-shot (P9, docs/p9.md §3.2
// item 5): a trigger as umd_host holds it (hp_req until hp_ack), the reader on mclk against
// bench/umd/ddr_model.sv (random waitrequest and latency), the player on clk_sys. The region is
// shrunk to 2^RW = 4,096 words so a sound can wrap. The bench fills the region with a sample
// pattern it can predict (sample k of the region = k xor 0x5A5A, little-endian 16-bit), and
// scores every value the player puts out at its 48 kHz ticks. Arms:
//   [mono]    four samples a word, from bit 0; L = R
//   [stereo]  two frames a word, {L, R} from bit 0
//   [len]     exactly len frames, then silence; busy falls with the last
//   [wrap]    a sound across the region's end continues at its start
//   [retrig]  a trigger mid-sound: the next value is the new sound's first, never the old one's;
//             and a trigger issued just as the port accepts a burst of the old sound (its beats
//             arrive after the trigger: they must not be taken for the new sound's)
//   [stop]    len 0 stops a sound at once
//   [tick]    one value a tick, 48 kHz from clk_sys (2 / 1125)
// Every failure is $fatal; the PASS marker is "PASS: pcm_shot_tb".
`timescale 1ns/1ps
`default_nettype none
module pcm_shot_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

localparam logic [28:0] BASE = 29'h0660_0000;
localparam int RW = 12;
reg clk = 0, mclk = 0;
always #18.5185 clk = ~clk;
always #5.5556  mclk = ~mclk;
reg rst_n = 0;

reg         hp_req = 0, hp_stereo = 0;
reg  [23:0] hp_start = 0, hp_len = 0;
wire        hp_ack, busy;
wire signed [15:0] pcm_l, pcm_r;
wire [15:0] n_under;
wire [28:0] ddr_address;
wire [7:0]  ddr_burstcount;
wire        ddr_read, ddr_waitrequest, ddr_readdatavalid;
wire [63:0] ddr_readdata;
int         unwritten;

pcm_shot #(.BASE (BASE), .RW (RW)) dut (.clk, .rst_n, .hp_req, .hp_stereo, .hp_start, .hp_len, .hp_ack, .busy,
    .pcm_l, .pcm_r, .n_under, .mclk, .mrst_n (rst_n), .ddr_address, .ddr_burstcount, .ddr_read,
    .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
ddr_model #(.BASE (BASE), .AW (RW)) u_ddr (.clk (mclk), .rst_n (rst_n), .address (ddr_address),
    .burstcount (ddr_burstcount), .read (ddr_read), .write (1'b0), .writedata (64'd0), .byteenable (8'd0),
    .waitrequest (ddr_waitrequest), .readdata (ddr_readdata), .readdatavalid (ddr_readdatavalid),
    .unwritten_reads (unwritten));

function automatic [15:0] smp(input int k);        // the region's sample k (16-bit units)
    smp = 16'(k) ^ 16'h5A5A;
endfunction
initial begin
    for (int w = 0; w < (1 << RW); w++) begin
        u_ddr.mem[w] = {smp(4 * w + 3), smp(4 * w + 2), smp(4 * w + 1), smp(4 * w)};
        u_ddr.wrt[w] = 1'b1;
    end
end

// umd_host's rule: held until acknowledged
always @(posedge clk) if (hp_ack) hp_req <= 1'b0;
task automatic trig(input bit st, input int start, input int len);
    begin
        @(negedge clk); hp_req = 1; hp_stereo = st; hp_start = 24'(start); hp_len = 24'(len);
        @(negedge clk); @(negedge clk);
        if (hp_req) `FAIL("len", "a trigger never acknowledged")
    end
endtask

// the player's ticks, seen from outside: the NCO's step, mirrored (2 / 1125 of clk_sys)
int ticks = 0, cyc = 0, last_tick = -1;
always @(posedge clk) if (rst_n) begin
    cyc <= cyc + 1;
    if (dut.tick) begin
        ticks <= ticks + 1;
        if (last_tick >= 0 && (cyc - last_tick < 562 || cyc - last_tick > 563))
            `FAIL("tick", $sformatf("ticks %0d cycles apart (48 kHz: 562.5)", cyc - last_tick))
        last_tick <= cyc;
    end
end

// the value put out after each tick (pcm_* move in the tick's cycle: sampled the next)
task automatic expect_run(input string arm, input bit st, input int start, input int n, input int skip_n);
    // n values from the sound at region word `start`, after skipping skip_n frames; then silence
    int got = 0, waited = 0;
    reg [15:0] wl, wr;
    begin
        while (got < n) begin
            @(posedge clk);
            if (dut.tick && dut.busy) begin
                @(posedge clk); #1;
                if (dut.cw_v === 1'b0 && pcm_l === 16'd0 && pcm_r === 16'd0 && !dut.started) begin
                    waited++;                          // the first word not yet arrived: silence, waited
                    if (waited > 40) `FAIL(arm, "no sample after 40 ticks")
                end else begin
                    int f;
                    f = skip_n + got;
                    if (st) begin wl = smp((4 * start + 2 * f) % (4 << RW)); wr = smp((4 * start + 2 * f + 1) % (4 << RW)); end
                    else begin wl = smp((4 * start + f) % (4 << RW)); wr = wl; end
                    if (pcm_l !== wl || pcm_r !== wr)
                        `FAIL(arm, $sformatf("frame %0d: %h %h, want %h %h", f, pcm_l, pcm_r, wl, wr))
                    got++;
                end
            end
        end
    end
endtask
task automatic expect_silence(input string arm, input int nticks);
    int t = 0;
    begin
        while (t < nticks) begin
            @(posedge clk);
            if (dut.tick) begin
                @(posedge clk); #1;
                if (pcm_l !== 16'd0 || pcm_r !== 16'd0) `FAIL(arm, $sformatf("%h %h after the sound's end", pcm_l, pcm_r))
                t++;
            end
        end
        if (busy) `FAIL(arm, "busy after the sound's end")
    end
endtask

initial begin
    repeat (5) @(posedge clk); rst_n = 1;
    repeat (20) @(posedge clk);

    // [mono] + [len]: 37 samples from word 5 (not a multiple of 4: the last word part-used)
    trig(0, 5, 37);
    if (!busy) `FAIL("len", "not busy after a trigger")
    expect_run("mono", 0, 5, 37, 0);
    expect_silence("len", 6);

    // [stereo] + [len]: 50 frames from word 100
    trig(1, 100, 50);
    expect_run("stereo", 1, 100, 50, 0);
    expect_silence("len", 6);

    // [wrap]: 40 stereo frames from 8 words before the region's end
    trig(1, (1 << RW) - 8, 40);
    expect_run("wrap", 1, (1 << RW) - 8, 40, 0);
    expect_silence("len", 4);

    // [retrig]: a long mono sound, interrupted after 30 samples by another
    trig(0, 1000, 4000);
    expect_run("retrig", 0, 1000, 30, 0);
    trig(0, 2000, 25);
    expect_run("retrig", 0, 2000, 25, 0);
    expect_silence("retrig", 6);

    // [retrig]: a trigger right after the port accepts one of the old sound's bursts
    trig(0, 1500, 4000);
    expect_run("retrig", 0, 1500, 8, 0);
    @(posedge mclk);
    while (!(ddr_read && !ddr_waitrequest)) @(posedge mclk);
    trig(0, 2500, 30);
    expect_run("retrig", 0, 2500, 30, 0);
    expect_silence("retrig", 4);

    // [stop]: a long sound, then len 0
    trig(1, 300, 4000);
    expect_run("stop", 1, 300, 10, 0);
    trig(0, 0, 0);
    expect_silence("stop", 8);

    if (ticks < 200) `FAIL("tick", "too few ticks measured")
    $display("pcm_shot_tb: mono, stereo, the region's wrap, a retrigger mid-sound, a stop; exact lengths; %0d ticks at 48 kHz; %0d underruns",
             ticks, n_under);
    $display("PASS: pcm_shot_tb");
    $finish;
end

initial begin #200_000_000; `FAIL("harness", "timeout") end

endmodule
`default_nettype wire
