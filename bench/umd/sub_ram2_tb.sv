// bench/umd/sub_ram2_tb.sv -- the raster readers' line fetches on ram2 with the subtitles'
// master saturating the port (docs/subtitles.md §2 "sub_mem"; umd/ddr_mux2.sv, A =
// subtitles, B = umd/rd_merge2.sv: P the video display reader, Q the overlay plane reader)
//
// A never stops: 8-beat write bursts and 8-beat read bursts at random, back to back --
// more than sub_mem can ever ask for (the ring writes a unit at the demux's pace, reads it
// once, the plane writer writes one image), so this is the ceiling. Every line period
// both readers ask for their NEXT line at once, as they do at the first dot of a line:
//   P (disp_reader): 180 words (Y 90, Cb 45, Cr 45 for 720 samples);
//   Q (plane_reader): +qwords (default 720: two whole 720-pixel source rows of
//     premultiplied ARGB8888, 360 words each -- the bilinear worst case; a 1:1 plane
//     fetches one row, 360 at most), in bursts of up to 8.
// ddr_model: random waitrequest and read latency.
//
// [latency] each reader's line must be complete within one line: 858 dots at 27 MHz =
// 31.78 us = 2,860 cycles at 90 MHz. The worst line and the headroom are reported.
// [share]   A (the subtitle writer, behind which the ring's writer serves a demux that
//   cannot be stalled) must be granted at least +a_floor words a line (default 32; the
//   demux can deliver at most ~10 subtitle words a line: 2.4 MB/s of packs).
// [data]    every beat to its owner: each reader's words are the addresses it asked for.
// [proto]   a command the merge presented under waitrequest is held until accepted.
// -Psub_ram2_tb.DIRECT=1: the merge alone on the model (no A, run with +a_floor=0 and a
//   long latency): nothing downstream limits its outstanding bursts, so its own guard
//   (16) is what keeps the owner FIFO from wrapping.
// PASS: sub_ram2_tb.

`timescale 1ns/1ps
`default_nettype none

module sub_ram2_tb;
    localparam logic [28:0] BASE = 29'h0600_0000;
    localparam int LINE = 2860, WORDS = 180, LINES = 600;
    parameter bit DIRECT = 1'b0;           // -P: the merge alone on the model (its own FIFO guard binds)

    logic clk = 0;
    always #5.5 clk = ~clk;
    logic rst_n = 0;

    logic [28:0] a_address, b_address, ddr_address;
    logic [7:0]  a_burstcount, b_burstcount, a_byteenable, ddr_burstcount, ddr_byteenable;
    logic        a_read, a_write, a_waitrequest, a_readdatavalid, b_read, b_waitrequest, b_readdatavalid;
    logic [28:0] p_address, q_address;
    logic [7:0]  p_burstcount, q_burstcount;
    logic        p_read, q_read, p_waitrequest, q_waitrequest, p_readdatavalid, q_readdatavalid;
    logic [63:0] p_readdata, q_readdata;
    logic        ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] a_writedata, a_readdata, b_readdata, ddr_writedata, ddr_readdata;
    int          unwritten;

    generate if (DIRECT) begin : g_direct
        // the merge alone on the model: nothing downstream caps its outstanding bursts
        assign ddr_address = b_address; assign ddr_burstcount = b_burstcount; assign ddr_read = b_read;
        assign ddr_write = 1'b0; assign ddr_writedata = '0; assign ddr_byteenable = 8'hFF;
        assign b_waitrequest = ddr_waitrequest; assign b_readdata = ddr_readdata; assign b_readdatavalid = ddr_readdatavalid;
        assign a_waitrequest = 1'b1; assign a_readdata = '0; assign a_readdatavalid = 1'b0;
    end else begin : g_mux
        ddr_mux2 #(.B_FIRST (1'b1)) u_mux (.clk, .rst_n,
            .a_address, .a_burstcount, .a_read, .a_write, .a_writedata, .a_byteenable, .a_abort (1'b0),
            .a_waitrequest, .a_readdata, .a_readdatavalid,
            .b_address, .b_burstcount, .b_read, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .b_write(1'b0), .b_writedata(64'd0),   // B reads only here (main gave B writes for the vbuf)
            .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
            .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
    end endgenerate

    // [proto]: a command the merge presented under waitrequest is held until accepted
    logic pend_q; logic [28:0] pend_a; logic [7:0] pend_n;
    always @(posedge clk) begin
        if (!rst_n) pend_q <= 1'b0;
        else begin
            if (pend_q && !(b_read && b_address === pend_a && b_burstcount === pend_n)) begin
                $display("FAIL [proto] the merge withdrew or changed a command under waitrequest (%h x%0d)", pend_a, pend_n);
                $fatal(1, "sub_ram2_tb: failed");
            end
            pend_q <= b_read && b_waitrequest; pend_a <= b_address; pend_n <= b_burstcount;
        end
    end
    rd_merge2 u_merge (.clk, .rst_n,
        .p_address, .p_burstcount, .p_read, .p_waitrequest, .p_readdata, .p_readdatavalid,
        .q_address, .q_burstcount, .q_read, .q_waitrequest, .q_readdata, .q_readdatavalid,
        .m_address (b_address), .m_burstcount (b_burstcount), .m_read (b_read), .m_waitrequest (b_waitrequest),
        .m_readdata (b_readdata), .m_readdatavalid (b_readdatavalid));
    ddr_model #(.BASE (BASE), .AW (14)) u_ddr (.clk, .rst_n, .address (ddr_address), .burstcount (ddr_burstcount),
        .read (ddr_read), .write (ddr_write), .writedata (ddr_writedata), .byteenable (ddr_byteenable),
        .waitrequest (ddr_waitrequest), .readdata (ddr_readdata), .readdatavalid (ddr_readdatavalid),
        .unwritten_reads (unwritten));

    // ---- A: always a burst in hand ---------------------------------------------------------------------
    int seed = 1;
    int a_words = 0;
    logic [3:0] abeat;
    always @(posedge clk) begin
        if (!rst_n) begin
            a_read <= 0; a_write <= 0; abeat <= 0;
        end else begin
            if (a_read && !a_waitrequest) begin a_read <= 0; a_words = a_words + a_burstcount; end
            if (a_write && !a_waitrequest) begin
                abeat <= abeat + 1; a_words = a_words + 1;
                a_writedata <= {$urandom(seed), $urandom(seed)};
                if (abeat == 7) begin a_write <= 0; abeat <= 0; end
            end
            if (!a_read && !a_write || (a_read && !a_waitrequest) || (a_write && !a_waitrequest && abeat == 7)) begin
                if ($urandom(seed) % 2) begin a_write <= 1; a_read <= 0; end
                else begin a_read <= 1; a_write <= 0; end
                a_address    <= BASE + ($urandom(seed) % 1024) * 8;
                a_burstcount <= 8;
                a_byteenable <= 8'hFF;
                a_writedata  <= {$urandom(seed), $urandom(seed)};
            end
        end
    end

    // ---- the readers: each asks for its line at the line's start ---------------------------------------
    // Reader 0 is P, 1 is Q; the words fetched are the model's contents at the addresses
    // asked for (preloaded: address -> {~address, address}), in order.
    localparam logic [28:0] PBASE = BASE + 8192, QBASE = BASE + 12288;   // above A's addresses (BASE .. + 8191)
    int pwords = 180, qwords = 720, a_floor = 32;
    int t = 0, lines, worst [0:1], took [0:1], a_min, a0;

    function automatic logic [63:0] word_at(input logic [28:0] a);
        return {3'd0, ~a, 3'd0, a};
    endfunction

    task automatic reader(input int who, input int words);
        int req, got, t0;
        logic [28:0] base;
        logic [63:0] w;
        base = who ? QBASE : PBASE;
        req = 0; got = 0; t0 = t;
        while (got < words) begin
            if (who == 0 && !p_read && req < words) begin
                p_read = 1; p_burstcount = (words - req >= 8) ? 8 : words - req; p_address = base + req;
            end
            if (who == 1 && !q_read && req < words) begin
                q_read = 1; q_burstcount = (words - req >= 8) ? 8 : words - req; q_address = base + req;
            end
            @(posedge clk);
            if (who == 0 ? p_readdatavalid : q_readdatavalid) begin
                w = who ? q_readdata : p_readdata;
                if (w !== word_at(base + got)) begin
                    $display("FAIL [data] reader %0d word %0d: %h, want %h", who, got, w, word_at(base + got));
                    $fatal(1, "sub_ram2_tb: failed");
                end
                got = got + 1;
            end
            if (who == 0 && p_read && !p_waitrequest) begin req = req + p_burstcount; #1 p_read = 0; end
            else if (who == 1 && q_read && !q_waitrequest) begin req = req + q_burstcount; #1 q_read = 0; end
            else #1;
            if (t - t0 > 4 * LINE) begin
                $display("FAIL [latency] reader %0d line %0d: %0d of %0d words after %0d cycles (starved)", who, lines, got, words, t - t0);
                $fatal(1, "sub_ram2_tb: failed");
            end
        end
        took[who] = t - t0;
    endtask

    initial begin
        void'($value$plusargs("seed=%d", seed));
        void'($value$plusargs("qwords=%d", qwords));
        void'($value$plusargs("a_floor=%d", a_floor));
        p_read = 0; q_read = 0; p_address = BASE; q_address = BASE; p_burstcount = 8; q_burstcount = 8;
        for (int i = 0; i < 1024; i++) begin
            u_ddr.poke(PBASE + i, word_at(PBASE + i));
            u_ddr.poke(QBASE + i, word_at(QBASE + i));
        end
        repeat (4) @(posedge clk);
        #1 rst_n = 1;
        worst[0] = 0; worst[1] = 0; took[1] = 0; a_min = 1 << 30;
        for (lines = 0; lines < LINES; lines++) begin
            int t0;
            t0 = t; a0 = a_words;
            fork
                reader(0, pwords);
                if (qwords > 0) reader(1, qwords);
            join
            for (int k = 0; k < 2; k++) begin
                if (took[k] > worst[k]) worst[k] = took[k];
                if (took[k] > LINE) begin
                    $display("FAIL [latency] reader %0d line %0d took %0d cycles, the line is %0d", k, lines, took[k], LINE);
                    $fatal(1, "sub_ram2_tb: failed");
                end
            end
            while (t < t0 + LINE) @(posedge clk);
            if (a_words - a0 < a_min) a_min = a_words - a0;
            if (a_words - a0 < a_floor) begin
                $display("FAIL [share] line %0d: the subtitle master got %0d words, the floor is %0d", lines, a_words - a0, a_floor);
                $fatal(1, "sub_ram2_tb: failed");
            end
        end
        $display("sub_ram2_tb: %0d lines, video %0d + plane %0d words a line against a saturating subtitle master: worst video %0d, plane %0d cycles of %0d; the subtitle master >= %0d words a line",
                 LINES, pwords, qwords, worst[0], worst[1], LINE, a_min);
        $display("PASS: sub_ram2_tb");
        $finish;
    end
    always @(posedge clk) t <= t + 1;
endmodule

`default_nettype wire
