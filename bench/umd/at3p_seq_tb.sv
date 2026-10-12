// bench/umd/at3p_seq_tb.sv -- the ATRAC3plus sequencer against its emulator
//
// Feeds STEM.bytes (AU headers + frames, tools/at3p_seq_golden.py) into at3p_seq with
// optional input stalls (+stall=N: a gap of up to N cycles before a byte) and a stub
// vector engine (done 1-4 cycles after each start: the program never reads an engine's
// result, so the trace does not depend on them). Every register write and store the
// RTL makes is compared, in order, against STEM.trace: pc, kind, register / address,
// value. Arms: [trace] (an event differs), [count] (too few / too many events or
// frames), [hang] (no progress).

`default_nettype none
`timescale 1ns/1ps

module at3p_seq_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [7:0]  in_byte;
    logic        in_valid, in_ready;
    logic        vop_start, vop_done;
    logic [3:0]  vop_op;
    logic [127:0] vop_args;
    logic [5:0]  spec_rdata;
    logic [7:0]  e_rdata;
    logic        mark_valid, err_valid, overrun;
    logic [15:0] mark_id;
    logic [7:0]  err_code;
    logic        tr_valid, tr_kind;
    logic [11:0] tr_pc;
    logic [13:0] tr_addr;
    logic [15:0] tr_val;

    at3p_seq dut (
        .clk, .rst_n, .in_byte, .in_valid, .in_ready,
        .vop_start, .vop_op, .vop_args, .vop_done,
        .spec_raddr(12'd0), .spec_rdata, .e_raddr(8'd0), .e_rdata,
        .mark_valid, .mark_id, .err_valid, .err_code, .overrun,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    string stem;
    int stall;
    logic [7:0]  bytes [];
    logic [47:0] exp [];
    int n_bytes, n_ev, n_frames, n_err;
    int bi, ei, frames, errs, gap, busy, idle, last_ei, quiet;

    initial begin
        int fd, r;
        logic [11:0] pc; logic [3:0] k; logic [15:0] a, v;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d %d %d", n_bytes, n_ev, n_frames, n_err);
        $fclose(fd);
        bytes = new[n_bytes];
        exp = new[n_ev];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin
            r = $fscanf(fd, "%h", v);
            bytes[i] = v[7:0];
        end
        $fclose(fd);
        fd = $fopen({stem, ".trace"}, "r");
        for (int i = 0; i < n_ev; i++) begin
            r = $fscanf(fd, "%h %h %h %h", pc, k, a, v);
            exp[i] = {pc, k, a, v};
        end
        $fclose(fd);
    end

    // the byte source
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bi <= 0; gap <= 0; in_valid <= 1'b0;
        end else begin
            if (in_valid && in_ready) begin
                bi <= bi + 1;
                in_valid <= 1'b0;
                gap <= (stall > 0) ? ($urandom % (stall + 1)) : 0;
            end else if (!in_valid && bi < n_bytes) begin
                if (gap > 0) gap <= gap - 1;
                else begin in_valid <= 1'b1; in_byte <= bytes[bi]; end
            end
        end
    end

    // the stub engine
    int vcnt;
    always_ff @(posedge clk) begin
        vop_done <= 1'b0;
        if (!rst_n) vcnt <= 0;
        else if (vop_start) vcnt <= 1 + ($urandom % 4);
        else if (vcnt > 0) begin
            vcnt <= vcnt - 1;
            if (vcnt == 1) vop_done <= 1'b1;
        end
    end

    // the scoreboard
    logic [47:0] e;
    always @(posedge clk) begin
        if (!rst_n) begin
            ei <= 0; frames <= 0; errs <= 0;
        end else begin
            if (tr_valid) begin
                if (ei >= n_ev)
                    $fatal(1, "FAIL [count] an event past the golden's %0d: pc %03x kind %0d addr %04x val %04x",
                           n_ev, tr_pc, tr_kind, tr_addr, tr_val);
                e = exp[ei];
                if ({tr_pc, 3'd0, tr_kind, 2'd0, tr_addr, tr_val} !== e)
                    $fatal(1, "FAIL [trace] event %0d: rtl pc %03x kind %0d addr %04x val %04x, emulator pc %03x kind %0d addr %04x val %04x",
                           ei, tr_pc, tr_kind, tr_addr, tr_val, e[47:36], e[32], e[29:16], e[15:0]);
                ei <= ei + 1;
            end
            if (mark_valid && mark_id == 16'd2) frames <= frames + 1;
            if (err_valid) errs <= errs + 1;
        end
    end

    initial begin
        busy = 0; idle = 0; last_ei = 0; quiet = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            busy++;
            if (bi == n_bytes && in_ready) idle++; else idle = 0;
            if (idle > 64) begin
                if (ei != n_ev)
                    $fatal(1, "FAIL [count] %0d of %0d trace events", ei, n_ev);
                if (frames != n_frames)
                    $fatal(1, "FAIL [count] %0d frames, the golden %0d", frames, n_frames);
                if (errs != n_err)
                    $fatal(1, "FAIL [count] %0d refusals, the golden %0d", errs, n_err);
                $display("at3p_seq_tb: %0d bytes, %0d events, %0d frames, %0d refusals, %0d cycles (%0d a frame)",
                         n_bytes, n_ev, frames, errs, busy, busy / (frames > 0 ? frames : 1));
                $display("PASS: at3p_seq_tb");
                $finish;
            end
            if (ei != last_ei) begin last_ei = ei; quiet = 0; end else quiet++;
            if (quiet > 2000000 && !(bi == n_bytes && in_ready))   // no event in 2M cycles
                $fatal(1, "FAIL [hang] at event %0d of %0d, byte %0d", ei, n_ev, bi);
        end
    end
endmodule
