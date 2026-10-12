// bench/umd/sub_ring_tb.sv -- sub_unit -> sub_ring -> ddr_model, a host on the queue
// (docs/subtitles.md §4; fixtures: tools/sub_golden.py units, the units of the P1 tool)
//
// The ring is small (RAW 12: 32 KB) so it wraps many times on a whole disc track; the DDR3
// model waits at random. The consumer is the HPS's model (A7, docs/hps_host.md §3.2): it
// takes the head unit (the request), waits, reads the unit's bytes out of DDR3 itself
// (ddr_model's memory, wrapping at the ring's end), and then completes (`done`: the ring
// frees the unit's words). Every unit is checked against the tool's list, record and bytes,
// as the host reads them. Modes:
//   default       the input has a gap before every PES (subtitle bytes are a sliver of the
//                 stream); the consumer is prompt: no unit may be refused
//   +hold=1       the consumer is held until the input is in: the ring fills, and the units
//                 refused follow the admission rule (room for all its words and a queue slot)
//   +flush_after=N  once the input passes byte N (and everything before it is committed),
//                 flush; with +hold=1 only units starting after byte N may come out
//   +stall=1      random input gaps and host waits
//   +hostlat=N    the host holds each unit N cycles before it reads it (and frees it): the
//                 demux keeps writing meanwhile, so a ring that freed the unit's words at the
//                 request would let them be overwritten ([unit]); units may then be refused
//                 (no room), so those that come out are matched in order, refusals skipped
// Arms: [unit] a unit's record / bytes / order, [count] refusals, [hang], [ddr] (the model's
// own policing). $fatal on the first failure; PASS: sub_ring_tb.

`timescale 1ns/1ps
`default_nettype none

module sub_ring_tb;
    localparam logic [28:0] RB = 29'h0640_0000;
    parameter int RAW = 12, MAW = 4;          // -P MAW=6: the ring's room binds before the queue's depth

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
    logic        flushing, q_valid, q_take, rd_busy, done;
    logic [32:0] q_pts;
    logic [31:0] q_dur, q_len;
    logic [15:0] q_x, q_y;
    logic [RAW-1:0] q_start;
    logic [28:0] ddr_address;
    logic [7:0]  ddr_burstcount, ddr_byteenable;
    logic        ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] ddr_writedata, ddr_readdata;
    logic [MAW:0] n_q;
    int          unwritten;

    sub_unit u_unit (.clk, .rst_n, .flush, .s_byte, .s_start, .s_ptsv, .s_pts, .s_gap, .s_valid, .s_ready,
        .u_begin, .u_len, .u_words, .u_accept, .u_byte, .u_valid, .u_last, .u_ready, .u_abort,
        .rec_pts, .rec_dur, .rec_x, .rec_y, .n_units, .n_truncated, .n_overrun, .n_orphan, .n_lost,
        .n_refused, .n_badhdr, .n_oddfield);
    sub_ring #(.RING_BASE(RB), .RAW(RAW), .MAW(MAW)) u_ring (.clk, .rst_n, .flush, .flushing,
        .u_begin, .u_len, .u_words, .u_accept, .u_byte, .u_valid, .u_last, .u_ready, .u_abort,
        .rec_pts, .rec_dur, .rec_x, .rec_y, .q_valid, .q_pts, .q_dur, .q_x, .q_y, .q_len, .q_start, .q_take,
        .rd_busy, .done, .ddr_address, .ddr_burstcount,
        .ddr_write, .ddr_writedata, .ddr_byteenable, .ddr_waitrequest, .n_units (n_q));
    ddr_model #(.BASE(RB), .AW(RAW)) u_ddr (.clk, .rst_n, .address (ddr_address), .burstcount (ddr_burstcount),
        .read (1'b0), .write (ddr_write), .writedata (ddr_writedata), .byteenable (ddr_byteenable),
        .waitrequest (ddr_waitrequest), .readdata (ddr_readdata), .readdatavalid (ddr_readdatavalid),
        .unwritten_reads (unwritten));

    localparam int NIN = 4194304, NUB = 4194304, NREC = 65536;
    logic [43:0] inw [0:NIN-1];
    logic [7:0]  ub [0:NUB-1];
    logic [35:0] recs [0:5*NREC-1];
    logic [31:0] ust [0:NREC-1];
    logic [31:0] meta [0:10];
    int          uoff [0:NREC-1];           // each expected unit's offset in ub
    bit          want [0:NREC-1];           // expected to come out of the ring

    integer fd, ip, k, nx, nexp, nrefexp, nout, cyc, seed, stall, hold, flush_after, flushed, gapc, pesgap, hostlat;
    integer free_w, nin_ring, nbeg;
    reg [8*512-1:0] stem;
    string s;

    task automatic fail(input string a, input string msg);
        $display("FAIL [%s] %0s: %s", a, stem, msg);
        $fatal(1, "sub_ring_tb: failed");
    endtask

    // the host: take the head (unless held), wait, read its bytes from DDR3, complete
    logic held;
    logic busy = 1'b0;                      // a unit is taken and not yet done
    integer wait_c, t_start, t_len, idle_c;
    assign q_take = q_valid && !held && !busy;
    always @(posedge clk) if (!rst_n) begin busy <= 1'b0; done <= 1'b0; end else begin
        done <= 1'b0;
        if (q_take) begin
            while (nx < meta[1] && !want[nx]) nx = nx + 1;
            // (with a host latency units may be refused for room: skip to the one that matches)
            if (hostlat > 0)
                while (nx < meta[1] && ({3'b0, q_pts} !== recs[5 * nx] || {4'b0, q_len} !== recs[5 * nx + 4])) nx = nx + 1;
            if (nx >= meta[1]) fail("unit", "a unit the tool does not have");
            if ({3'b0, q_pts} !== recs[5 * nx] || {4'b0, q_dur} !== recs[5 * nx + 1] ||
                {20'b0, q_x} !== recs[5 * nx + 2] || {20'b0, q_y} !== recs[5 * nx + 3] || {4'b0, q_len} !== recs[5 * nx + 4])
                fail("unit", $sformatf("unit %0d: record pts %0d len %0d, the tool pts %0d len %0d (%0d refused so far)", nx, q_pts, q_len,
                     recs[5 * nx], recs[5 * nx + 4], n_refused));
            busy    <= 1'b1;
            t_start = q_start;
            t_len   = q_len;
            wait_c  = hostlat + ((stall != 0) ? ($urandom(seed) % 64) : 0);
        end else if (busy && !flushing) begin
            if (wait_c > 0) wait_c = wait_c - 1;
            else begin
                // the unit, as the host reads it: word (start + i / 8) mod the ring, byte i % 8
                for (int i = 0; i < t_len; i++) begin
                    logic [63:0] w;
                    w = u_ddr.mem[(t_start + i / 8) % (1 << RAW)];
                    if (w[8 * (i % 8) +: 8] !== ub[uoff[nx] + i])
                        fail("unit", $sformatf("unit %0d byte %0d: %02x in DDR3, the tool %02x", nx, i, w[8 * (i % 8) +: 8], ub[uoff[nx] + i]));
                end
                busy <= 1'b0;
                done <= 1'b1;
                nx = nx + 1;
                nout = nout + 1;
            end
        end
        if (flushing) busy <= 1'b0;         // the flush dropped the request
        // the admission rule, for the refusals expected while the consumer is held
        if (u_begin) nbeg = nbeg + 1;
    end

    initial begin
        if (!$value$plusargs("list=%s", s)) $fatal(1, "+list= missing");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("hold=%d", hold)) hold = 0;
        if (!$value$plusargs("flush_after=%d", flush_after)) flush_after = -1;
        if (!$value$plusargs("hostlat=%d", hostlat)) hostlat = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        // idle cycles before each PES: the other streams (a subtitle PES is a sliver of them)
        if (!$value$plusargs("pesgap=%d", pesgap)) pesgap = 2000;
        fd = $fopen(s, "r");
        s_valid = 0; s_byte = 0; s_start = 0; s_ptsv = 0; s_gap = 0; s_pts = 0; held = 1;
        while ($fscanf(fd, "%s\n", stem) == 1) begin
            $readmemh({stem, ".meta.hex"}, meta);
            if (meta[10] != 0) continue;    // a refuse-every case is sub_unit's alone
            if (meta[0] > NIN || meta[2] > NUB || meta[1] > NREC) $fatal(1, "%0s: larger than the bench", stem);
            $readmemh({stem, ".in.hex"}, inw, 0, meta[0] - 1);
            if (meta[1] != 0) begin
                $readmemh({stem, ".rec.hex"}, recs, 0, 5 * meta[1] - 1);
                $readmemh({stem, ".ustart.hex"}, ust, 0, meta[1] - 1);
            end
            if (meta[2] != 0) $readmemh({stem, ".ub.hex"}, ub, 0, meta[2] - 1);
            // which units should come out: all, or (held) those the admission rule admits,
            // and (flushed) only those starting after the flush point
            k = 0; nexp = 0; nrefexp = 0; free_w = 1 << RAW; nin_ring = 0;
            for (int u = 0; u < meta[1]; u++) begin
                uoff[u] = k;
                k = k + recs[5 * u + 4];
                want[u] = 1;
                if (flush_after >= 0 && ust[u] <= flush_after) want[u] = 0;
                else if (hold) begin
                    if ((recs[5 * u + 4] + 7) / 8 <= free_w && nin_ring < (1 << MAW)) begin
                        free_w = free_w - (recs[5 * u + 4] + 7) / 8; nin_ring = nin_ring + 1;
                    end else begin want[u] = 0; nrefexp = nrefexp + 1; end
                end
                if (want[u]) nexp = nexp + 1;
            end
            rst_n = 0; nx = 0; nout = 0; ip = 0; cyc = 0; flushed = 0; gapc = 0; nbeg = 0; held = (hold != 0);
            repeat (3) @(posedge clk);
            #1 rst_n = 1;
            while (ip < meta[0] && cyc < 400 * meta[0] + 20000) begin
                // a gap before every PES but the first: the other streams' bytes
                if (inw[ip][41] && ip != 0 && gapc < pesgap) begin
                    s_valid = 0; gapc = gapc + 1;
                end else begin
                    s_valid = (stall == 0 || ($urandom(seed) % 4) != 0);
                    if (s_valid) gapc = 0;
                end
                {s_gap, s_ptsv, s_start, s_pts, s_byte} = inw[ip];
                @(posedge clk);
                if (s_valid && s_ready) ip = ip + 1;
                cyc = cyc + 1;
                #1;
                if (flush_after >= 0 && !flushed && ip > flush_after) begin
                    // let what is in flight settle, then flush (the consumer is held)
                    s_valid = 0;
                    repeat (200) @(posedge clk);
                    #1 flush = 1; @(posedge clk); #1 flush = 0;
                    while (flushing) @(posedge clk);
                    #1 flushed = 1;
                end
            end
            s_valid = 0;
            held = 0;
            cyc = 0;
            idle_c = 0;
            while (nx < meta[1] && cyc < 200 * meta[2] + 100000 + 4 * hostlat * meta[1]) begin
                @(posedge clk); #1 cyc = cyc + 1;
                while (nx < meta[1] && !want[nx]) nx = nx + 1;
                // refusals: once nothing has moved for a while, what came out is all
                if (hostlat > 0 && !q_valid && !busy && !rd_busy && !u_valid) idle_c = idle_c + 1; else idle_c = 0;
                if (idle_c > 2000) nx = meta[1];
            end
            repeat (50) @(posedge clk);
            if (ip < meta[0]) fail("hang", $sformatf("input stuck at byte %0d of %0d", ip, meta[0]));
            while (nx < meta[1] && !want[nx]) nx = nx + 1;
            if (nx < meta[1]) fail("hang", $sformatf("unit %0d never came out", nx));
            if (q_valid || rd_busy) fail("unit", "a unit the tool does not have is still queued");
            if (flush_after < 0 && hostlat == 0 && n_refused !== nrefexp[15:0])
                fail("count", $sformatf("%0d refused, the admission rule %0d", n_refused, nrefexp));
            if (hostlat > 0 && (nout == 0 || nout + n_refused < 2))
                fail("count", $sformatf("%0d units out, %0d refused: the latency arm proved nothing", nout, n_refused));
            $display("sub_ring_tb: %0s: %0d units out identical (%0d refused)", stem, nout, n_refused);
        end
        $display("PASS: sub_ring_tb");
        $finish;
    end
endmodule

`default_nettype wire
