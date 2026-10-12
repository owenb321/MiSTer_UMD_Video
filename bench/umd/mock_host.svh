// bench/umd/mock_host.svh -- the HPS's model for the subtitle benches (A7, docs/hps_host.md
// §3.2, §6 "The mock host"): `include'd at the END of a bench module (sub_top_tb,
// sub_overlay_tb), which declares what it uses:
//   mclk, mrst_n                       the DDR3 side's clock and reset
//   h_req, h_seq, h_buf, h_start, h_len, h_gen     the request (the DUT's outputs)
//   h_done, h_done_seq, h_done_err, h_done_w, h_done_h   the completion (logic, driven here)
//   u_ddr, MH_MBASE                    the ddr_model instance (its `mem`) and its BASE
//   RB, P0, P1, MH_RAW                 the ring's base, the planes, the ring's log2 words
//   urec, pw, ub, uo, meta             tools/sub_golden.py e2e's fixture (9 words a record)
//   front_v, front_b                   the plane the display holds ([tear])
//   stem, fail(arm, msg)               the bench's failure task
//
// What it does, as the HPS will (one request at a time, in order):
//   * takes a request it has not served (h_req, a seq it has not completed), waits
//     +host_lat mclk cycles (the poll and the decode);
//   * reads the unit's h_len bytes out of DDR3 itself, from word h_start of the ring,
//     wrapping at its end, and finds them in the tool's units, in order ([unit]: the bytes
//     the fabric wrote, as the host will read them);
//   * writes that unit's GOLDEN plane words (libpng's pixels premultiplied, sub_golden.py)
//     into plane h_buf -- a backdoor write into the model's memory, as the HPS writes through
//     its own port, never ram2's Avalon -- and fails [tear] if that plane is on screen;
//   * completes: {seq, err (libpng refused it), w, h}.
// A request whose gen moved while it waited (a flush) is completed without reading or
// writing anything: the real host's completion of an abandoned decode, which the fabric must
// ignore (n_stale). +stale=1: before each stem's first real completion, one completion
// with the previous seq is sent (err 1): the fabric must ignore it ([stale]: the request is
// still up the cycle after, and the bench's n_stale counts it).
// +mh_loose=1: units may be skipped (flushes drop some); else they must come in order.

    integer      mh_lat, mh_stale, mh_loose, mh_wait, mh_k, mh_start, mh_len, mh_sent_stale;
    logic        mh_busy, mh_served, mh_buf;
    logic [7:0]  mh_seq, mh_last, mh_gen;

    initial begin
        if (!$value$plusargs("host_lat=%d", mh_lat)) mh_lat = 20000;
        if (!$value$plusargs("stale=%d", mh_stale)) mh_stale = 0;
        if (!$value$plusargs("mh_loose=%d", mh_loose)) mh_loose = 0;
    end

    // the unit's byte i, as the host reads it from the ring
    function automatic logic [7:0] mh_ring_byte(input integer start, input integer i);
        logic [63:0] w;
        w = u_ddr.peek(RB + ((start + i / 8) % (1 << MH_RAW)));
        return w[8 * (i % 8) +: 8];
    endfunction

    // does record k's PNG equal the ring's bytes?
    function automatic bit mh_is(input integer k, input integer start, input integer len);
        if (uo[2 * k + 1] != len) return 0;
        for (int i = 0; i < len; i++) if (mh_ring_byte(start, i) !== ub[uo[2 * k] + i]) return 0;
        return 1;
    endfunction

    always @(posedge mclk) begin
        if (!mrst_n) begin
            h_done <= 1'b0; mh_busy <= 1'b0; mh_served <= 1'b0; mh_k = 0; mh_sent_stale = 0;
        end else begin
            h_done <= 1'b0;
            if (!mh_busy && h_req && !(mh_served && h_seq == mh_last)) begin
                mh_busy  <= 1'b1;
                mh_seq   <= h_seq;
                mh_buf   <= h_buf;
                mh_gen   <= h_gen;
                mh_start = h_start;
                mh_len   = h_len;
                mh_wait  = mh_lat;
            end else if (mh_busy && h_done) begin
                // (one cycle between completions: the fabric samples this one now)
            end else if (mh_busy) begin
                // the cycle after the fabric saw the stale completion: the request is still up
                if (mh_sent_stale == 1) begin
                    if (!h_req || h_seq != mh_seq)
                        fail("stale", $sformatf("the fabric took a completion of seq %0d for request %0d", mh_seq - 8'd1, mh_seq));
                    mh_sent_stale = 2;
                end
                if (mh_wait > 0) mh_wait = mh_wait - 1;
                else if (mh_stale != 0 && mh_sent_stale == 0 && mh_gen == h_gen) begin
                    // a completion of a request that is not outstanding: ignored by the fabric
                    h_done <= 1'b1; h_done_seq <= mh_seq - 8'd1; h_done_err <= 5'd1;
                    h_done_w <= 16'd0; h_done_h <= 16'd0;
                    mh_sent_stale = 1;
                end else begin
                    if (mh_gen == h_gen) begin : serve
                        integer k;
                        k = mh_k;
                        if (mh_loose != 0) while (k < meta[1] && !mh_is(k, mh_start, mh_len)) k = k + 1;
                        if (k >= meta[1] || !mh_is(k, mh_start, mh_len))
                            fail("unit", $sformatf("request seq %0d: the %0d bytes at ring word %0d are not unit %0d's",
                                 mh_seq, mh_len, mh_start, mh_k));
                        if (urec[9 * k + 6] == 0) begin
                            logic [28:0] base;
                            integer off, n;
                            if (front_v && front_b == mh_buf)
                                fail("tear", $sformatf("unit %0d written into plane %0d while the display holds it", k, mh_buf));
                            base = mh_buf ? (P1 - MH_MBASE) : (P0 - MH_MBASE);
                            off  = urec[9 * k + 7];
                            n    = urec[9 * k + 8];
                            // (the model's poke: its written flags too -- a word read back
                            //  through the port must read what the host wrote)
                            for (int i = 0; i < n; i++) begin
                                logic [63:0] m;
                                logic [28:0] a;
                                for (int b = 0; b < 8; b++) m[8 * b +: 8] = pw[off + i][64 + b] ? 8'hFF : 8'h00;
                                a = MH_MBASE + base + pw[off + i][90:72];
                                u_ddr.poke(a, (u_ddr.peek(a) & ~m) | (pw[off + i][63:0] & m));
                            end
                        end
                        h_done_err <= (urec[9 * k + 6] != 0) ? 5'd1 : 5'd0;
                        h_done_w   <= urec[9 * k + 4][15:0];
                        h_done_h   <= urec[9 * k + 5][15:0];
                        mh_k = k + 1;
                    end else begin
                        h_done_err <= 5'd0; h_done_w <= 16'd0; h_done_h <= 16'd0;   // abandoned: nothing read or written
                    end
                    h_done     <= 1'b1;
                    h_done_seq <= mh_seq;
                    mh_busy    <= 1'b0;
                    mh_served  <= 1'b1;
                    mh_last    <= mh_seq;
                end
            end
        end
    end
