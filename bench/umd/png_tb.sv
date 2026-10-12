// bench/umd/png_tb.sv -- umd/png/png_top.sv against tools/png_golden.py's fixtures
// (zlib's inflated bytes, libpng's pixels; bench/umd/run_png.sh; docs/png_decode.md §5)
//
// +list=FILE   one fixture stem a line (<stem>.hex/.meta.hex/.inf.hex/.raw.hex/.rmask.hex/.pix.hex)
// +stall=1     random input gaps and random px_ready: every mismatch is then [stall]
// +seed=N
//
// Arms (each FAIL names one; the runner's mutations are each caught by their own):
//   [inflate]  the inflated bytes at tap_inf, in order, count equal       (valid cases)
//   [unfilter] the reconstructed bytes at tap_raw (under the golden's mask), count
//   [pixel]    x, y, RGBA of every pixel in emission order, count, the header (the
//              header drives the stages too, so a header fault can never show alone)
//   [err]      the verdict code at done (the CRC / Adler ones score as [csum])
//   [csum]     a CRC-32 / Adler-32 verdict expected or reported
//   [warn]     the benign flags (good images); [hang] no done in time
// Scores with !==; $fatal on the first failure; PASS: png_tb only at the end.

`timescale 1ns/1ps
`default_nettype none

module png_tb;
    import png_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;
    logic rst_n = 1'b0;

    logic        start = 1'b0;
    logic [7:0]  in_byte;
    logic        in_valid, in_last, in_ready;
    logic        hdr_valid;
    logic [15:0] hdr_w, hdr_h;
    logic [2:0]  hdr_ctype;
    logic [4:0]  hdr_depth;
    logic        hdr_il;
    logic [15:0] px_x, px_y;
    logic [31:0] px_rgba;
    logic        px_valid, px_ready;
    logic        busy, done;
    logic [4:0]  err;
    logic [5:0]  warn;
    logic        tap_inf_valid, tap_raw_valid;
    logic [7:0]  tap_inf_byte, tap_raw_byte;

    png_top dut (.*);

    // sized past a whole 720x480 frame (345,600 pixels); a larger fixture is a harness
    // failure, never a silently short $readmemh
    localparam int NIN = 1048576, NINF = 1048576, NPIX = 524288;
    logic [7:0]  inb  [0:NIN-1];
    logic [7:0]  infb [0:NINF-1];
    logic [7:0]  rawb [0:NINF-1];
    logic [7:0]  rmask [0:NINF-1];
    logic [63:0] pixw [0:NPIX-1];
    logic [31:0] meta [0:11];

    integer fd, ip, ninf, nraw, npix, cyc, limit, seed, stall, ncases;
    longint tot_cyc, tot_inf, worst_x1000;
    reg [8*512-1:0] stem;
    string arm, s;
    logic check;

    task automatic fail(input string a, input string msg);
        string arm_s;
        arm_s = a;
        if (stall != 0) arm_s = "stall";
        $display("FAIL [%s] %0s: %s", arm_s, stem, msg);
        $fatal(1, "png_tb: failed");
    endtask

    // the checks at each handshake
    always @(posedge clk) if (rst_n && busy && check) begin
        if (tap_inf_valid) begin
            if (ninf >= meta[8]) fail("inflate", $sformatf("more than %0d inflated bytes", meta[8]));
            else if (tap_inf_byte !== infb[ninf])
                fail("inflate", $sformatf("byte %0d: %02x, zlib %02x", ninf, tap_inf_byte, infb[ninf]));
            ninf = ninf + 1;
        end
        if (tap_raw_valid) begin
            if (nraw >= meta[9]) fail("unfilter", $sformatf("more than %0d row bytes", meta[9]));
            else if (((tap_raw_byte ^ rawb[nraw]) & rmask[nraw]) !== 8'd0)
                fail("unfilter", $sformatf("row byte %0d: %02x, oracle %02x (mask %02x)", nraw, tap_raw_byte,
                     rawb[nraw], rmask[nraw]));
            nraw = nraw + 1;
        end
        if (px_valid && px_ready) begin
            if (npix >= meta[10]) fail("pixel", $sformatf("more than %0d pixels", meta[10]));
            else if ({px_x, px_y, px_rgba} !== pixw[npix])
                fail("pixel", $sformatf("pixel %0d: (%0d,%0d) %08x, libpng (%0d,%0d) %08x", npix, px_x, px_y,
                     px_rgba, pixw[npix][63:48], pixw[npix][47:32], pixw[npix][31:0]));
            npix = npix + 1;
        end
    end

    initial begin
        if (!$value$plusargs("list=%s", s)) $fatal(1, "png_tb: +list= missing");
        if (!$value$plusargs("stall=%d", stall)) stall = 0;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        fd = $fopen(s, "r");
        if (fd == 0) $fatal(1, "png_tb: cannot open %s", s);
        in_valid = 1'b0; in_last = 1'b0; in_byte = 8'd0; px_ready = 1'b1; check = 1'b0;
        ncases = 0; tot_cyc = 0; tot_inf = 0; worst_x1000 = 0;
        repeat (4) @(posedge clk);
        rst_n = 1'b1;
        while ($fscanf(fd, "%s\n", stem) == 1) begin
            $readmemh({stem, ".meta.hex"}, meta);
            if (meta[7] > NIN || meta[8] > NINF || meta[9] > NINF || meta[10] > NPIX)
                $fatal(1, "png_tb: %0s is larger than the bench arrays", stem);
            $readmemh({stem, ".hex"}, inb, 0, meta[7] - 1);
            check = (meta[11] != 0);
            if (check) begin
                $readmemh({stem, ".inf.hex"}, infb, 0, meta[8] - 1);
                $readmemh({stem, ".raw.hex"}, rawb, 0, meta[9] - 1);
                $readmemh({stem, ".rmask.hex"}, rmask, 0, meta[9] - 1);
                $readmemh({stem, ".pix.hex"}, pixw, 0, meta[10] - 1);
            end
            ninf = 0; nraw = 0; npix = 0; ip = 0; cyc = 0;
            limit = 200 * meta[7] + 64 * meta[8] + 64 * meta[10] + 100000;
            @(negedge clk) start = 1'b1;
            @(negedge clk) start = 1'b0;
            while (!done && cyc < limit) begin
                in_valid = (ip < meta[7]) && (stall == 0 || ($urandom(seed) % 4) != 0);
                in_byte  = inb[ip];
                in_last  = (ip == meta[7] - 1);
                px_ready = (stall == 0) || (($urandom(seed) % 3) != 0);
                @(posedge clk);
                if (in_valid && in_ready) ip = ip + 1;
                cyc = cyc + 1;
                #1;
            end
            in_valid = 1'b0;
            if (!done) fail("hang", $sformatf("no done after %0d cycles (in %0d of %0d, inflated %0d, rows %0d, px %0d)",
                                              cyc, ip, meta[7], ninf, nraw, npix));
            @(negedge clk);
            // a good image: the data arms first (a short or long output is theirs, even
            // when it also breaks the Adler), then the verdict
            if (check) begin
                if (ninf !== meta[8]) fail("inflate", $sformatf("%0d inflated bytes, zlib %0d", ninf, meta[8]));
                if (nraw !== meta[9]) fail("unfilter", $sformatf("%0d row bytes, oracle %0d", nraw, meta[9]));
                if (npix !== meta[10]) fail("pixel", $sformatf("%0d pixels, libpng %0d", npix, meta[10]));
            end
            if (err !== meta[0][4:0]) begin
                // [csum]: a CRC / Adler verdict expected, or one reported on a good image
                if (meta[0] == E_CRC || meta[0] == E_ADLER ||
                    (meta[0] == E_OK && (err == E_CRC || err == E_ADLER))) arm = "csum";
                else arm = "err";
                fail(arm, $sformatf("verdict %0d, expected %0d", err, meta[0]));
            end
            // the benign flags are scored on good images (after a fatal verdict they are moot)
            if (meta[0] == 0 && warn !== meta[1][5:0])
                fail("warn", $sformatf("warn %02x, expected %02x", warn, meta[1]));
            if (check) begin
                if ({hdr_w, hdr_h, hdr_ctype, hdr_depth, hdr_il} !==
                    {meta[2][15:0], meta[3][15:0], meta[4][2:0], meta[5][4:0], meta[6][0]})
                    fail("pixel", $sformatf("header %0dx%0d t%0d d%0d il%0d", hdr_w, hdr_h, hdr_ctype, hdr_depth, hdr_il));
                tot_cyc = tot_cyc + cyc;
                tot_inf = tot_inf + meta[8];
                if (meta[8] > 1000 && (1000 * cyc / meta[8]) > worst_x1000) worst_x1000 = 1000 * cyc / meta[8];
            end
            ncases = ncases + 1;
        end
        $display("png_tb: %0d cases identical%0s; %0d inflated bytes in %0d cycles = %0d.%02d cycles a byte (worst %0d.%02d)",
                 ncases, (stall != 0) ? " under stalls" : "", tot_inf, tot_cyc,
                 (tot_inf != 0) ? tot_cyc / tot_inf : 0, (tot_inf != 0) ? (100 * tot_cyc / tot_inf) % 100 : 0,
                 worst_x1000 / 1000, (worst_x1000 % 1000) / 10);
        $display("PASS: png_tb");
        $finish;
    end

endmodule

`default_nettype wire
