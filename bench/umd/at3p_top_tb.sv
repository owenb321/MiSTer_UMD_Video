// bench/umd/at3p_top_tb.sv -- the whole ATRAC3plus decoder against its emulator
//
// Feeds STEM.bytes (tools/at3p_top_golden.py) into at3p_top with optional input stalls
// (+stall=N) and output back-pressure (+ostall=N), and scores:
//   [vop]   after every vector op, the engine buffers' checksums (the residual, the time
//           signal, the overlap, the tone regions) against the emulator's: the first
//           engine that differs is named, not just the PCM;
//   [pcm]   every stereo pair, in order, bit-exact;
//   [count] vector ops, pairs, frames, refusals; internal saturations must be 0;
//   [hang]  no progress.

`default_nettype none
`timescale 1ns/1ps

module at3p_top_tb;
    logic clk = 1'b0, rst_n = 1'b0;
    always #5 clk = ~clk;

    logic [7:0]  in_byte;
    logic        in_valid, in_ready;
    logic [15:0] pcm_l, pcm_r;
    logic        pcm_valid, pcm_ready;
    logic [15:0] frames, refused, overruns, sat_count, clip_count, mark_id, tr_val;
    logic [7:0]  last_err;
    logic        mark_valid, vop_start, vop_done, tr_valid, tr_kind;
    logic [3:0]  vop_op;
    logic [11:0] tr_pc;
    logic [13:0] tr_addr;

    at3p_top dut (
        .clk, .rst_n, .in_byte, .in_valid, .in_ready,
        .pcm_l, .pcm_r, .pcm_valid, .pcm_ready,
        .frames, .refused, .last_err, .overruns, .sat_count, .clip_count,
        .mark_valid, .mark_id, .vop_start, .vop_op, .vop_done,
        .tr_valid, .tr_pc, .tr_kind, .tr_addr, .tr_val);

    string stem;
    int stall, ostall;
    logic [7:0]   bytes [];
    logic [31:0]  pcm_exp [];
    logic [131:0] vop_exp [];
    int n_bytes, n_pairs, n_vops, n_frames, n_err;
    int bi, pi, vi, gap, ogap, busy, idle, last_prog, quiet;
    logic [3:0] cur_op;

    initial begin
        int fd, r;
        logic [31:0] v0, v1, v2, v3, v4;
        if (!$value$plusargs("stem=%s", stem)) $fatal(1, "FAIL [setup] no +stem");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("ostall=%d", ostall)) ostall = 0;
        fd = $fopen({stem, ".meta"}, "r");
        if (fd == 0) $fatal(1, "FAIL [setup] no %s.meta", stem);
        r = $fscanf(fd, "%d %d %d %d %d", n_bytes, n_pairs, n_vops, n_frames, n_err);
        $fclose(fd);
        bytes = new[n_bytes];
        pcm_exp = new[n_pairs];
        vop_exp = new[n_vops];
        fd = $fopen({stem, ".bytes"}, "r");
        for (int i = 0; i < n_bytes; i++) begin r = $fscanf(fd, "%h", v0); bytes[i] = v0[7:0]; end
        $fclose(fd);
        fd = $fopen({stem, ".pcm"}, "r");
        for (int i = 0; i < n_pairs; i++) begin
            r = $fscanf(fd, "%h %h", v0, v1); pcm_exp[i] = {v0[15:0], v1[15:0]};
        end
        $fclose(fd);
        fd = $fopen({stem, ".vops"}, "r");
        for (int i = 0; i < n_vops; i++) begin
            r = $fscanf(fd, "%h %h %h %h %h", v0, v1, v2, v3, v4);
            vop_exp[i] = {v0[3:0], v1, v2, v3, v4};
        end
        $fclose(fd);
    end

    // the byte source
    always @(posedge clk) begin
        if (!rst_n) begin
            bi <= 0; gap <= 0; in_valid <= 1'b0;
        end else begin
            if (in_valid && in_ready) begin
                bi <= bi + 1; in_valid <= 1'b0;
                gap <= (stall > 0) ? ($urandom % (stall + 1)) : 0;
            end else if (!in_valid && bi < n_bytes) begin
                if (gap > 0) gap <= gap - 1;
                else begin in_valid <= 1'b1; in_byte <= bytes[bi]; end
            end
        end
    end

    // the PCM sink
    always @(posedge clk) begin
        if (!rst_n) begin pcm_ready <= 1'b0; ogap <= 0; pi <= 0; end
        else begin
            if (pcm_valid && pcm_ready) begin
                if (pi >= n_pairs) $fatal(1, "FAIL [count] a pair past the golden's %0d", n_pairs);
                if ({pcm_l, pcm_r} !== pcm_exp[pi]) begin
                    logic [31:0] e;
                    e = pcm_exp[pi];
                    $fatal(1, "FAIL [pcm] pair %0d (frame %0d sample %0d, during vector op %0d): rtl %04x %04x, emulator %04x %04x",
                           pi, pi / 2048, pi % 2048, vi, pcm_l, pcm_r, e[31:16], e[15:0]);
                end
                pi <= pi + 1;
                ogap <= (ostall > 0) ? ($urandom % (ostall + 1)) : 0;
                pcm_ready <= (ostall == 0);
            end else if (ogap > 0) begin ogap <= ogap - 1; pcm_ready <= 1'b0; end
            else pcm_ready <= 1'b1;
        end
    end

    // the engine buffers' checksums: sum (i + 1) (v mod 2^w), mod 2^32
    function automatic logic [31:0] ck40x(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 128; i++) acc = acc + (i + 1) * dut.u_vec.xb[i];
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_tb(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 2048; i++) acc = acc + (i + 1) * dut.u_vec.tb[i];
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_pb(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 4096; i++) acc = acc + (i + 1) * dut.u_vec.pb[i];
        return acc[31:0];
    endfunction
    function automatic logic [31:0] ck_rb(input int dummy);
        logic [63:0] acc; acc = 0;
        for (int i = 0; i < 256; i++) acc = acc + (i + 1) * dut.u_vec.rb[i];
        return acc[31:0];
    endfunction

    always @(posedge clk) begin
        if (!rst_n) vi <= 0;
        else begin
            if (vop_start) cur_op <= vop_op;
            if (vop_done) begin
                logic [131:0] e;
                logic [31:0] cx, ct, cp, cr;
                if (vi >= n_vops) $fatal(1, "FAIL [count] a vector op past the golden's %0d", n_vops);
                e = vop_exp[vi];
                #1;
                cx = ck40x(0); ct = ck_tb(0); cp = ck_pb(0); cr = ck_rb(0);
                if (cur_op !== e[131:128])
                    $fatal(1, "FAIL [vop] op %0d: rtl op %0d, emulator op %0d", vi, cur_op, e[131:128]);
                if (cx !== e[127:96]) $fatal(1, "FAIL [vop] op %0d (%0d): the residual buffer differs (%08x, emulator %08x)", vi, cur_op, cx, e[127:96]);
                if (ct !== e[95:64])  $fatal(1, "FAIL [vop] op %0d (%0d): the time buffer differs (%08x, emulator %08x)", vi, cur_op, ct, e[95:64]);
                if (cp !== e[63:32])  $fatal(1, "FAIL [vop] op %0d (%0d): the overlap buffer differs (%08x, emulator %08x)", vi, cur_op, cp, e[63:32]);
                if (cr !== e[31:0])   $fatal(1, "FAIL [vop] op %0d (%0d): the tone regions differ (%08x, emulator %08x)", vi, cur_op, cr, e[31:0]);
                vi <= vi + 1;
            end
        end
    end

    initial begin
        busy = 0; idle = 0; last_prog = 0; quiet = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        forever begin
            @(posedge clk);
            busy++;
            if (bi == n_bytes && in_ready && !pcm_valid) idle++; else idle = 0;
            if (idle > 64) begin
                if (vi != n_vops) $fatal(1, "FAIL [count] %0d of %0d vector ops", vi, n_vops);
                if (pi != n_pairs) $fatal(1, "FAIL [count] %0d of %0d pairs", pi, n_pairs);
                if (frames != n_frames) $fatal(1, "FAIL [count] %0d frames, the golden %0d", frames, n_frames);
                if (refused != n_err) $fatal(1, "FAIL [count] %0d refusals, the golden %0d", refused, n_err);
                if (sat_count != 0) $fatal(1, "FAIL [count] %0d internal saturations", sat_count);
                $display("at3p_top_tb: %0d bytes, %0d vector ops, %0d pairs, %0d frames, %0d refused, %0d clipped, %0d cycles (%0d a frame, %0.1f %% of 27 MHz real time)",
                         n_bytes, vi, pi, frames, refused, clip_count, busy, busy / (frames > 0 ? frames : 1),
                         100.0 * busy / (frames > 0 ? frames : 1) / 1152000.0);
                $display("PASS: at3p_top_tb");
                $finish;
            end
            if (vi + pi != last_prog) begin last_prog = vi + pi; quiet = 0; end else quiet++;
            if (quiet > 2000000 && !(bi == n_bytes && in_ready))   // no vector op or pair in 2M cycles
                $fatal(1, "FAIL [hang] at vector op %0d, pair %0d, byte %0d", vi, pi, bi);
        end
    end
endmodule
