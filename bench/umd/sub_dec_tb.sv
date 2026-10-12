// bench/umd/sub_dec_tb.sv -- the subtitle decode in the fabric (umd/sub/sub_dec.sv, A12 SD1,
// docs/nav_engine.md §10): sub_top's host handshake answered by png_top, against libpng.
//
// The fixture is tools/sub_golden.py e2e's (sub_top_tb's): every unit's PNG bytes (.ub / .uo),
// and per unit (.urec) x, y, w, h, err (libpng refuses it) and its golden plane words (.pw:
// libpng's pixels premultiplied, clipped to 720x480). The bench lays the units one after the
// other into a 32 KB ring in the DDR3 model (2**12 words, so units wrap at its end, as
// sub_ring lays them: a unit's byte 8k+i is bits [8i+7:8i] of its word k), zeroes the target
// plane, and requests each unit as sub_top does (h_req held, seq counting, buf alternating).
// sub_dec's two masters reach the model through umd/sub/sub_mem.sv (the ring writer's client
// idle), and the model enforces Avalon's port rules ([avalon]) with random waits / latencies.
//
// Arms:
//   [done]   one completion per request, its seq, err != 0 exactly when libpng refuses, and
//            for an accepted image libpng's w x h
//   [plane]  every word of the plane: the golden words (masked by their bytes), every other
//            word 0 (a refused image's plane is not scored: it is never shown)
//   [flush]  +flush=1: a flush in the middle of each third unit's decode -- that request never
//            completes, and the same unit requested again (a new seq) comes out exact; the
//            beats in flight are drained (the next decode reads only its own unit)
//   [hang]   a request that never completes within 20 M cycles
// PASS: sub_dec_tb.
`timescale 1ns/1ps
`default_nettype none

module sub_dec_tb;
    localparam logic [28:0] RB = 29'h0640_0000;
    localparam logic [28:0] P0 = RB + 29'h1000;
    localparam logic [28:0] P1 = RB + 29'h1000 + 29'h2A300;
    localparam int RAW = 12, RWORDS = 1 << RAW, PWORDS = 172800;

    logic mclk = 0, pclk = 0;
    always #5.5  mclk = ~mclk;           // 90 MHz, the DDR3 port's
    always #18.5 pclk = ~pclk;           // 27 MHz, clk_sys (png_top's)
    logic mrst_n = 0, flush = 0;

    logic        h_req = 0, h_buf = 0, h_done;
    logic [7:0]  h_seq = 0, h_done_seq;
    logic [15:0] h_x = 0, h_y = 0, h_done_w, h_done_h, n_clipped;
    logic [RAW-1:0] h_start = 0;
    logic [31:0] h_len = 0;
    logic [4:0]  h_done_err;
    logic [28:0] r_address, w_address, ddr_address;
    logic [7:0]  r_burstcount, w_burstcount, w_byteenable, ddr_burstcount, ddr_byteenable;
    logic        r_read, r_waitrequest, r_readdatavalid, w_write, w_waitrequest;
    logic        ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid, a_waitrequest;
    logic [63:0] r_readdata, w_writedata, ddr_writedata, ddr_readdata;
    int          unwritten;

    sub_dec #(.RING_BASE (RB), .RAW (RAW), .PLANE0 (P0), .PLANE1 (P1)) dut (
        .mclk, .mrst_n, .flush, .pclk,
        .h_req, .h_seq, .h_buf, .h_x, .h_y, .h_start, .h_len,
        .h_done, .h_done_seq, .h_done_err, .h_done_w, .h_done_h,
        .r_address, .r_burstcount, .r_read, .r_waitrequest, .r_readdata, .r_readdatavalid,
        .w_address, .w_burstcount, .w_write, .w_writedata, .w_byteenable, .w_waitrequest,
        .n_clipped
    );
    sub_mem u_mem (
        .clk (mclk), .rst_n (mrst_n),
        .a_address ('0), .a_burstcount (8'd1), .a_write (1'b0), .a_writedata ('0), .a_byteenable ('0),
        .a_waitrequest,
        .r_address, .r_burstcount, .r_read, .r_waitrequest, .r_readdata, .r_readdatavalid,
        .w_address, .w_burstcount, .w_write, .w_writedata, .w_byteenable, .w_waitrequest,
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid
    );
    ddr_model #(.BASE (RB), .AW (19)) u_ddr (.clk (mclk), .rst_n (mrst_n), .address (ddr_address),
        .burstcount (ddr_burstcount), .read (ddr_read), .write (ddr_write), .writedata (ddr_writedata),
        .byteenable (ddr_byteenable), .waitrequest (ddr_waitrequest), .readdata (ddr_readdata),
        .readdatavalid (ddr_readdatavalid), .unwritten_reads (unwritten));

    localparam int NPW = 4194304, NU = 4096, NUB = 4194304;
    logic [35:0] urec [0:9*NU-1];
    logic [90:0] pw [0:NPW-1];
    logic [7:0]  ub [0:NUB-1];
    logic [31:0] uo [0:2*NU-1];
    logic [31:0] meta [0:4];
    reg [8*512-1:0] stem;
    string s;
    integer do_flush;
    int     nflushed_ok = 0;                 // flushes with read beats in flight

    task automatic fail(input string a, input string msg);
        $display("FAIL [%s] %0s: %s", a, stem, msg);
        $fatal(1, "sub_dec_tb: failed");
    endtask

    function automatic logic [63:0] bmask(input logic [7:0] m);
        for (int i = 0; i < 8; i++) bmask[8*i +: 8] = m[i] ? 8'hFF : 8'h00;
    endfunction

    // completions seen (any, so a flushed request's late one is caught)
    int          n_done = 0;
    logic [7:0]  last_done_seq;
    always @(posedge mclk) if (h_done) begin n_done++; last_done_seq = h_done_seq; end

    // ---- one request: wait for its completion, or flush it half-way -------------------------------------
    task automatic request(input int k, input logic [RAW-1:0] w0, input logic [7:0] seq,
                           input logic buf_, input bit flush_it);
        int t, n0;
        n0 = n_done;
        @(negedge mclk);
        h_seq = seq; h_buf = buf_; h_x = urec[9*k+2][15:0]; h_y = urec[9*k+3][15:0];
        h_start = w0; h_len = uo[2*k+1]; h_req = 1;
        if (flush_it) begin
            repeat ($urandom % 60) @(posedge mclk);
            // ... at a moment read beats are in flight (they must be drained, not decoded next)
            t = 0;
            while (dut.inflight == 0 && n_done == n0 && t < 2000000) begin @(posedge mclk); t++; end
            if (n_done != n0) begin $display("  (unit %0d finished before the flush: no flush scored)", k); end
            else begin
                if (dut.inflight != 0) nflushed_ok++;
                @(negedge mclk); flush = 1; h_req = 0;
                repeat (2) @(negedge mclk); flush = 0;
                repeat (3000) @(posedge mclk);
                if (n_done != n0) fail("flush", $sformatf("unit %0d: the flushed request seq %0d completed", k, seq));
                return;
            end
        end
        t = 0;
        while (n_done == n0) begin @(posedge mclk); t++; if (t > 20000000) fail("hang", $sformatf("unit %0d never completed", k)); end
        @(negedge mclk); h_req = 0;
        if (last_done_seq !== seq) fail("done", $sformatf("unit %0d: completion seq %0d, want %0d", k, last_done_seq, seq));
        if ((h_done_err != 5'd0) !== (urec[9*k+6] != 0))
            fail("done", $sformatf("unit %0d: err %0d, libpng %0s", k, h_done_err, urec[9*k+6] ? "refuses it" : "accepts it"));
        if (urec[9*k+6] == 0 && (h_done_w !== urec[9*k+4][15:0] || h_done_h !== urec[9*k+5][15:0]))
            fail("done", $sformatf("unit %0d: %0dx%0d, want %0dx%0d", k, h_done_w, h_done_h, urec[9*k+4], urec[9*k+5]));
    endtask

    // ---- the plane: the golden words, and 0 everywhere else ----------------------------------------------
    task automatic check_plane(input int k, input logic buf_);
        logic [28:0] base;
        int off, n, j;
        logic [63:0] got;
        base = buf_ ? P1 : P0;
        off = urec[9*k+7]; n = urec[9*k+8];
        j = 0;
        for (int wd = 0; wd < PWORDS; wd++) begin
            got = u_ddr.peek(base + wd);
            if (j < n && pw[off + j][90:72] == wd) begin
                logic [63:0] m;
                m = bmask(pw[off + j][71:64]);
                if ((got & m) !== (pw[off + j][63:0] & m))
                    fail("plane", $sformatf("unit %0d word %0d (x %0d, y %0d): %h, want %h (mask %h)", k, wd,
                         (wd % 360) * 2, wd / 360, got, pw[off + j][63:0], m));
                if ((got & ~m) !== 64'd0)
                    fail("plane", $sformatf("unit %0d word %0d: %h outside the image's pixels", k, wd, got & ~m));
                j++;
            end else if (got !== 64'd0)
                fail("plane", $sformatf("unit %0d word %0d (x %0d, y %0d): %h, want 0", k, wd, (wd % 360) * 2, wd / 360, got));
        end
    endtask

    initial begin
        logic [RAW-1:0] wp;
        logic [7:0] seq;
        int nb, ok_units, nflushed;
        if (!$value$plusargs("stem=%s", stem)) begin $display("FAIL [harness] no +stem"); $fatal(1); end
        s = $sformatf("%0s", stem);
        if (!$value$plusargs("flush=%d", do_flush)) do_flush = 0;
        $readmemh({s, ".urec.hex"}, urec);
        $readmemh({s, ".pw.hex"}, pw);
        $readmemh({s, ".ub.hex"}, ub);
        $readmemh({s, ".uo.hex"}, uo);
        $readmemh({s, ".meta.hex"}, meta);
        repeat (10) @(posedge mclk);
        mrst_n = 1;
        repeat (40) @(posedge mclk);
        // the first unit 37 words before the ring's end: it wraps, and the bursts are misaligned
        // (no fixture's units fill the 32 KB ring: started at 0, none would ever cross its end)
        wp = RAW'(RWORDS - 37); seq = 8'd0; ok_units = 0; nflushed = 0;
        for (int k = 0; k < meta[1]; k++) begin
            logic b;
            nb = uo[2*k+1];
            if ((nb + 7) / 8 > RWORDS) fail("harness", $sformatf("unit %0d of %0d bytes does not fit the ring", k, nb));
            // the unit into the ring (it may wrap), the plane zeroed
            for (int w = 0; w < (nb + 7) / 8; w++) begin
                logic [63:0] d;
                d = '0;
                for (int i = 0; i < 8; i++) if (8 * w + i < nb) d[8*i +: 8] = ub[uo[2*k] + 8 * w + i];
                u_ddr.poke(RB + ((wp + w) % RWORDS), d);
            end
            b = k[0];
            for (int wd = 0; wd < PWORDS; wd++) u_ddr.poke((b ? P1 : P0) + wd, 64'd0);
            if (do_flush != 0 && (k % 3) == 1) begin
                request(k, wp, seq, b, 1);
                seq = seq + 8'd1;
                nflushed++;
                for (int wd = 0; wd < PWORDS; wd++) u_ddr.poke((b ? P1 : P0) + wd, 64'd0);
            end
            request(k, wp, seq, b, 0);
            seq = seq + 8'd1;
            if (urec[9*k+6] == 0) begin check_plane(k, b); ok_units++; end
            wp = wp + ((nb + 7) / 8);
        end
        if (do_flush != 0 && nflushed_ok == 0) fail("flush", "no flush landed with read beats in flight");
        $display("sub_dec_tb: %0s: %0d units (%0d decoded and scored, %0d refused), %0d flushed mid-decode (%0d with beats in flight), %0d words clipped",
                 s, meta[1], ok_units, meta[1] - ok_units, nflushed, nflushed_ok, n_clipped);
        $display("PASS: sub_dec_tb");
        $finish;
    end
endmodule

`default_nettype wire
