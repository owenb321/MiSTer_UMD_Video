// bench/umd/sub_unit_tb.sv -- umd/sub/sub_unit.sv against tools/sub_golden.py units
// (tools/umd_sub_extract.py's units of the same PES stream; docs/subtitles.md §4)
//
// +list=FILE (stems) +stall=1 (random input gaps and u_ready) +seed=N
// Arms: [unit]  every delivered unit's record and PNG bytes, in order, the count
//       [count] truncated / overrun / orphan / lost / refused / badhdr / oddfield
//       [hang]  the stream consumed and the last unit out in time
// $fatal on the first failure; PASS: sub_unit_tb.

`timescale 1ns/1ps
`default_nettype none

module sub_unit_tb;
    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;
    logic flush = 1'b0;

    logic [7:0]  s_byte;
    logic        s_start, s_ptsv, s_gap, s_valid, s_ready;
    logic [32:0] s_pts;
    logic        u_begin, u_accept, u_valid, u_last, u_ready, u_abort;
    logic [31:0] u_len, u_words;
    logic [7:0]  u_byte;
    logic [32:0] rec_pts;
    logic [31:0] rec_dur;
    logic [15:0] rec_x, rec_y;
    logic [15:0] n_units, n_truncated, n_overrun, n_orphan, n_lost, n_refused, n_badhdr, n_oddfield;

    sub_unit dut (.*);

    localparam int NIN = 4194304, NUB = 4194304, NREC = 65536;
    logic [43:0] inw [0:NIN-1];
    logic [7:0]  ub [0:NUB-1];
    logic [35:0] recs [0:5*NREC-1];
    logic [31:0] meta [0:10];

    integer fd, ip, k, nu, ubase, nbeg, cyc, seed, stall, nb, ncases;
    logic [7:0] cur [0:1048575];
    reg [8*512-1:0] stem;
    string s;

    task automatic fail(input string a, input string msg);
        $display("FAIL [%s] %0s: %s", a, stem, msg);
        $fatal(1, "sub_unit_tb: failed");
    endtask

    // the ring's answer: refuse every Nth begin
    always_comb u_accept = !(meta[10] != 0 && ((nbeg + 1) % meta[10]) == 0);

    always @(posedge clk) if (rst_n) begin
        if (u_begin) nbeg = nbeg + 1;
        if (u_abort) nb = 0;
        if (u_valid && u_ready) begin
            cur[nb] = u_byte;
            nb = nb + 1;
            if (u_last) begin
                if (nu >= meta[1]) fail("unit", $sformatf("more than %0d units", meta[1]));
                if ({3'b0, rec_pts} !== recs[5 * nu] || {4'b0, rec_dur} !== recs[5 * nu + 1] ||
                    {20'b0, rec_x} !== recs[5 * nu + 2] || {20'b0, rec_y} !== recs[5 * nu + 3] ||
                    nb !== recs[5 * nu + 4])
                    fail("unit", $sformatf("unit %0d: pts %0d dur %0d (%0d,%0d) %0d bytes; tool pts %0d dur %0d (%0d,%0d) %0d",
                         nu, rec_pts, rec_dur, rec_x, rec_y, nb, recs[5 * nu], recs[5 * nu + 1], recs[5 * nu + 2],
                         recs[5 * nu + 3], recs[5 * nu + 4]));
                for (k = 0; k < nb; k = k + 1)
                    if (cur[k] !== ub[ubase + k])
                        fail("unit", $sformatf("unit %0d byte %0d: %02x, tool %02x", nu, k, cur[k], ub[ubase + k]));
                ubase = ubase + nb;
                nu = nu + 1;
                nb = 0;
            end
        end
    end

    initial begin
        if (!$value$plusargs("list=%s", s)) $fatal(1, "+list= missing");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        fd = $fopen(s, "r");
        s_valid = 0; s_byte = 0; s_start = 0; s_ptsv = 0; s_gap = 0; s_pts = 0; u_ready = 1;
        ncases = 0;
        while ($fscanf(fd, "%s\n", stem) == 1) begin
            $readmemh({stem, ".meta.hex"}, meta);
            if (meta[0] > NIN || meta[2] > NUB || meta[1] > NREC) $fatal(1, "%0s: larger than the bench", stem);
            $readmemh({stem, ".in.hex"}, inw, 0, meta[0] - 1);
            if (meta[1] != 0) $readmemh({stem, ".rec.hex"}, recs, 0, 5 * meta[1] - 1);
            if (meta[2] != 0) $readmemh({stem, ".ub.hex"}, ub, 0, meta[2] - 1);
            rst_n = 0; nu = 0; ubase = 0; nbeg = 0; nb = 0; ip = 0; cyc = 0;
            repeat (3) @(posedge clk);
            #1 rst_n = 1;
            while ((ip < meta[0] || nu < meta[1]) && cyc < 40 * meta[0] + 10000) begin
                s_valid = (ip < meta[0]) && (stall == 0 || ($urandom(seed) % 4) != 0);
                {s_gap, s_ptsv, s_start, s_pts, s_byte} = inw[ip];
                u_ready = (stall == 0) || ($urandom(seed) % 3) != 0;
                @(posedge clk);
                if (s_valid && s_ready) ip = ip + 1;
                cyc = cyc + 1;
                #1;
            end
            s_valid = 0;
            repeat (4) @(posedge clk);
            if (ip < meta[0]) fail("hang", $sformatf("input stuck at byte %0d of %0d", ip, meta[0]));
            if (nu != meta[1]) fail("unit", $sformatf("%0d units, the tool %0d", nu, meta[1]));
            if ({n_truncated, n_overrun, n_orphan, n_lost, n_refused, n_badhdr, n_oddfield} !==
                {meta[3][15:0], meta[4][15:0], meta[5][15:0], meta[6][15:0], meta[7][15:0], meta[8][15:0], meta[9][15:0]})
                fail("count", $sformatf("trunc %0d ovr %0d orph %0d lost %0d refused %0d bad %0d odd %0d; want %0d %0d %0d %0d %0d %0d %0d",
                     n_truncated, n_overrun, n_orphan, n_lost, n_refused, n_badhdr, n_oddfield,
                     meta[3], meta[4], meta[5], meta[6], meta[7], meta[8], meta[9]));
            if (n_units !== meta[1][15:0] + meta[7][15:0] - meta[7][15:0])
                fail("count", $sformatf("n_units %0d, want %0d", n_units, meta[1]));
            $display("sub_unit_tb: %0s: %0d units identical", stem, nu);
            ncases = ncases + 1;
        end
        $display("sub_unit_tb: %0d streams identical%0s", ncases, stall ? " under stalls" : "");
        $display("PASS: sub_unit_tb");
        $finish;
    end
endmodule

`default_nettype wire
