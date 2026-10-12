// bench/umd/sub_top_tb.sv -- subtitles end to end: the demultiplexer's bytes in, the units
// in DDR3, the host's decode of each into a plane, and the display's requests out
// (umd/sub/sub_top.sv; docs/subtitles.md §4; A7, docs/hps_host.md §3.2)
//
// Two clocks: sclk 27 MHz (the demux), mclk 90 MHz (the DDR3 port; ddr_model's random
// waits). The host is bench/umd/mock_host.svh: it reads each requested unit out of the ring
// and checks its bytes against the tool's ([unit]), writes the GOLDEN plane into the plane
// it was told ([tear] if that plane is on screen), and completes after +host_lat cycles.
// Fixtures: tools/sub_golden.py e2e -- the units umd_sub_extract.py finds, their PNG bytes,
// libpng's pixels premultiplied (round(c * a / 255)) and laid into the 720-pitch plane,
// clipped. (The decode itself is B1's: bench/umd/run_hps_sub.sh.)
//
// Time: the STC ticks once every 1,000 mclk cycles -- the real ratio (90 MHz, 90 kHz), so
// `late` and `missed` mean what they would on the board; the input releases each PES 0.8 s
// before its PTS (the discs: 0.57 - 1.0 s); the display latches requests at vblank, every
// 1,500 ticks (60 Hz). When nothing moves (no DDR3 command for 3,000 cycles, no decode in
// flight -- png_top can run long without a DDR3 command), the STC jumps to the next event,
// so a film's minutes take no simulated time.
//
// Checks: at every acknowledged flip -- the unit is the next one the tool has (refused
// ones skipped), never before its PTS, before its end, the rectangle {x, y, w, h}, and
// every plane word of it in DDR3 equal to the golden under its byte mask (the host wrote
// the plane it was told: a wrong plane fails here); at every acknowledged hide -- the shown
// unit's end has come. At the end: every unit shown, and the refused / missed / late counts;
// [stale] the completions ignored are the ones the host sent stale (+stale=1). [tear]: no
// write ever lands in the plane the display holds -- the host's, and none at all from the
// fabric's port. [ddr]: ddr_model's port rules. $fatal on the first failure; PASS: sub_top_tb.

`timescale 1ns/1ps
`default_nettype none

module sub_top_tb;
    localparam logic [28:0] RB = 29'h0640_0000;
    localparam logic [28:0] P0 = RB + 29'h1000;
    localparam logic [28:0] P1 = RB + 29'h1000 + 29'h2A300;
    localparam int TICK = 1000, VBL = 1500, LEAD = 72000;   // 90 MHz mclk, the 90 kHz STC
    localparam int MH_RAW = 12;
    localparam logic [28:0] MH_MBASE = RB;      // ddr_model's BASE

    logic sclk = 0, mclk = 0;
    always #18.5 sclk = ~sclk;
    always #5.5  mclk = ~mclk;
    logic srst_n = 0, mrst_n = 0, flush = 0;

    logic [7:0]  sp_byte;
    logic        sp_valid, sp_frame_start, sp_pts_valid;
    logic [32:0] sp_pts;
    logic [32:0] stc;
    logic        stc_valid;
    logic        d_req, d_buf, d_vis, d_ack;
    logic [15:0] d_x, d_y, d_w, d_h;
    logic        h_req, h_buf, h_vis, h_done;
    logic [7:0]  h_seq, h_gen, h_shown_seq, h_done_seq;
    logic [15:0] h_x, h_y, h_done_w, h_done_h;
    logic [MH_RAW-1:0] h_start;
    logic [31:0] h_len;
    logic [4:0]  h_done_err;
    logic [28:0] ddr_address;
    logic [7:0]  ddr_burstcount, ddr_byteenable;
    logic        ddr_write, ddr_waitrequest, ddr_readdatavalid;
    logic [63:0] ddr_writedata, ddr_readdata;
    logic [15:0] in_lost, in_pts_lost, n_units, n_truncated, n_overrun, n_orphan, n_lost, n_ring_full,
                 n_badhdr, n_oddfield, n_shown, n_late, n_missed, n_refused, n_stale;
    int          unwritten;

    logic        pclk = 0, ddr_read;            // (FABRIC_DEC 0: the mock host decodes; A12 SD1's
    logic [15:0] n_clipped;                      //  fabric decoder is sub_dec_tb's and sub_overlay_tb's)
    logic        h_sbuf;                         // A12 SD2: the shown unit's plane and rectangle
    logic [15:0] h_sx, h_sy, h_sw, h_sh;
    sub_top #(.RING_BASE (RB), .RAW (MH_RAW), .MAW (4), .FABRIC_DEC (1'b0)) dut (.*);
    ddr_model #(.BASE (RB), .AW (19)) u_ddr (.clk (mclk), .rst_n (mrst_n), .address (ddr_address),
        .burstcount (ddr_burstcount), .read (1'b0), .write (ddr_write), .writedata (ddr_writedata),
        .byteenable (ddr_byteenable), .waitrequest (ddr_waitrequest), .readdata (ddr_readdata),
        .readdatavalid (ddr_readdatavalid), .unwritten_reads (unwritten));

    localparam int NIN = 4194304, NPW = 4194304, NU = 4096, NUB = 4194304;
    logic [43:0] inw [0:NIN-1];
    logic [35:0] urec [0:9*NU-1];
    logic [90:0] pw [0:NPW-1];
    logic [7:0]  ub [0:NUB-1];
    logic [31:0] uo [0:2*NU-1];
    logic [31:0] meta [0:4];

    integer fd, seed, k, nx, quiet, ip;
    longint cyc;
    reg [8*512-1:0] stem;
    string s;
    logic [32:0] rel;                        // the input's next release time
    logic        waiting;                    // the input waits for the STC

    task automatic fail(input string a, input string msg);
        $display("FAIL [%s] %0s: %s", a, stem, msg);
        $fatal(1, "sub_top_tb: failed");
    endtask

    function automatic logic [63:0] bmask(input logic [7:0] m);
        for (int i = 0; i < 8; i++) bmask[8*i +: 8] = m[i] ? 8'hFF : 8'h00;
    endfunction

    logic front_v, front_b;                 // the plane the display holds ([tear])

    `include "bench/umd/mock_host.svh"

    // ---- the STC, vblank and the display's acknowledgements (mclk) ---------------------------------
    logic [32:0] shown_end;
    logic        showing;
    integer      div;
    always @(posedge mclk) if (!mrst_n) d_ack <= 1'b0; else begin
        d_ack <= 1'b0;
        if (ddr_write) quiet <= 0; else quiet <= quiet + 1;
        div <= (div == TICK - 1) ? 0 : div + 1;
        if (div == TICK - 1) begin
            stc <= stc + 1;
            // vblank: take the outstanding request
            if (d_req && ((stc + 1) % VBL) == 0) d_ack <= 1'b1;
        end
        // nothing moves: jump to the next event (a vblank if a request waits)
        // (never over a decode in flight: png_top can run long without a DDR3 command)
        if (quiet > 3000 && stc_valid && dut.u_sched.bst != 2'd1 && !dut.u_ring.rd_busy && !mh_busy) begin : jump
            logic [32:0] t;
            t = 33'h1_FFFF_FFFF;
            if (d_req) t = stc + VBL - (stc % VBL) - 1;
            else begin
                if (waiting && rel > stc + 1) t = rel - 1;
                if (dut.u_sched.bst == 2'd2 && dut.u_sched.bpts > stc + 1 && dut.u_sched.bpts - 1 < t) t = dut.u_sched.bpts - 1;
                if (showing && shown_end > stc + 1 && shown_end - 1 < t) t = shown_end - 1;
            end
            if (t != 33'h1_FFFF_FFFF && t > stc) begin stc <= t; quiet <= 0; end
        end
    end

    // ---- the checks at each acknowledgement -----------------------------------------------------------
    always @(posedge mclk) if (mrst_n && d_ack) begin
        if ($test$plusargs("trace"))
            $display("ACK stc %0d vis %0d buf %0d (%0d,%0d) %0dx%0d  nx %0d showing %0d", stc, d_vis, d_buf, d_x, d_y, d_w, d_h, nx, showing);
        if (d_vis) begin : flip
            logic [28:0] base;
            integer off, n;
            while (nx < meta[1] && urec[9 * nx + 6] != 0) nx = nx + 1;       // refused: never shown
            if (nx >= meta[1]) fail("show", "a unit the tool does not have");
            if ($signed(stc - urec[9 * nx][32:0]) < 0) fail("time", $sformatf("unit %0d shown at %0d, before its PTS %0d", nx, stc, urec[9 * nx]));
            if ($signed(stc - (urec[9 * nx][32:0] + urec[9 * nx + 1][32:0])) >= VBL)
                fail("time", $sformatf("unit %0d shown at %0d, after its end", nx, stc));
            if ({d_x, d_y, d_w, d_h} !== {urec[9 * nx + 2][15:0], urec[9 * nx + 3][15:0], urec[9 * nx + 4][15:0], urec[9 * nx + 5][15:0]})
                fail("show", $sformatf("unit %0d: rect (%0d,%0d) %0dx%0d, the tool (%0d,%0d) %0dx%0d", nx, d_x, d_y, d_w, d_h,
                     urec[9 * nx + 2], urec[9 * nx + 3], urec[9 * nx + 4], urec[9 * nx + 5]));
            base = d_buf ? (P1 - RB) : (P0 - RB);
            off = urec[9 * nx + 7];
            n = urec[9 * nx + 8];
            for (int i = 0; i < n; i++) begin
                logic [63:0] got, want, m;
                got  = u_ddr.mem[base + pw[off + i][90:72]];
                want = pw[off + i][63:0];
                m    = bmask(pw[off + i][71:64]);
                if ((got & m) !== (want & m))
                    fail("plane", $sformatf("unit %0d word %0d (plane %0d, word %0d): %016x, the golden %016x (mask %02x)",
                         nx, i, d_buf, pw[off + i][90:72], got & m, want & m, pw[off + i][71:64]));
            end
            showing   = 1;
            shown_end = urec[9 * nx][32:0] + urec[9 * nx + 1][32:0];
            nx = nx + 1;
        end else begin
            if (!showing) fail("show", "a hide with nothing shown");
            if ($signed(stc - shown_end) < 0) fail("time", $sformatf("hidden at %0d, before the end %0d", stc, shown_end));
            showing = 0;
        end
    end

    // ---- [shown] (A12 SD2): after a flip that shows a unit, its plane and rectangle are reported --------
    logic        sh_chk = 1'b0, sh_b;
    logic [15:0] sh_x, sh_y, sh_w, sh_h;
    always @(posedge mclk) if (mrst_n) begin
        if (sh_chk && (h_sbuf !== sh_b || h_sx !== sh_x || h_sy !== sh_y || h_sw !== sh_w || h_sh !== sh_h))
            fail("shown", $sformatf("reported plane %0d %0d,%0d %0dx%0d, the flip's %0d %0d,%0d %0dx%0d",
                 h_sbuf, h_sx, h_sy, h_sw, h_sh, sh_b, sh_x, sh_y, sh_w, sh_h));
        sh_chk <= d_req && d_ack && d_vis;
        sh_b <= d_buf; sh_x <= d_x; sh_y <= d_y; sh_w <= d_w; sh_h <= d_h;
    end

    // ---- [tear]: nothing may be written into the plane the display holds (the host's writes:
    //      mock_host.svh; and the fabric's port must not write a plane at all) ---------------
    always @(posedge mclk) if (!mrst_n) front_v <= 1'b0; else begin
        if (d_ack && d_vis) begin front_v <= 1'b1; front_b <= d_buf; end
        if (ddr_write && !ddr_waitrequest && front_v) begin
            if (( front_b && ddr_address >= P1 && ddr_address < P1 + 29'h2A300) ||
                (!front_b && ddr_address >= P0 && ddr_address < P0 + 29'h2A300))
                fail("tear", $sformatf("a write into plane %0d (word %0h) while the display holds it", front_b, ddr_address));
        end
    end

    // ---- the input (sclk): each PES released 0.8 s before its PTS ------------------------------------
    initial begin
        if (!$value$plusargs("list=%s", s)) $fatal(1, "+list= missing");
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        fd = $fopen(s, "r");
        sp_valid = 0; sp_frame_start = 0; sp_pts_valid = 0; sp_pts = 0; sp_byte = 0;
        while ($fscanf(fd, "%s\n", stem) == 1) begin
            $readmemh({stem, ".meta.hex"}, meta);
            if (meta[0] > NIN || meta[2] > NPW || meta[1] > NU) $fatal(1, "%0s: larger than the bench", stem);
            $readmemh({stem, ".in.hex"}, inw, 0, meta[0] - 1);
            $readmemh({stem, ".urec.hex"}, urec, 0, 9 * meta[1] - 1);
            if (meta[2] != 0) $readmemh({stem, ".pw.hex"}, pw, 0, meta[2] - 1);
            $readmemh({stem, ".ub.hex"}, ub);
            $readmemh({stem, ".uo.hex"}, uo, 0, 2 * meta[1] - 1);
            srst_n = 0; mrst_n = 0; nx = 0; showing = 0; waiting = 0; quiet = 0; div = 0;
            stc = inw[0][40:8] - LEAD - 9000;      // start a little before the first release
            stc_valid = 1;
            repeat (5) @(posedge mclk);
            #1 srst_n = 1; mrst_n = 1;
            ip = 0;
            cyc = 0;
            while (ip < meta[0]) begin
                @(negedge sclk);
                if (inw[ip][41] && inw[ip][42]) begin
                    // a PES with a PTS: wait for its release
                    rel = inw[ip][40:8] - LEAD;
                    waiting = 1;
                    while ($signed(stc - rel) < 0) @(negedge sclk);
                    waiting = 0;
                    repeat (200) @(negedge sclk);  // the other streams' bytes between PES
                end
                sp_valid       = 1;
                sp_byte        = inw[ip][7:0];
                sp_frame_start = inw[ip][41];
                sp_pts_valid   = inw[ip][42];
                sp_pts         = inw[ip][40:8];
                ip = ip + 1;
                @(negedge sclk);
                sp_valid = 0; sp_frame_start = 0;
            end
            // let the last one be shown and hidden
            waiting = 0;
            rel = 0;
            cyc = 0;
            while ((nx < meta[1] || showing) && cyc < 50000000) begin
                @(posedge mclk); cyc = cyc + 1;
                while (nx < meta[1] && urec[9 * nx + 6] != 0) nx = nx + 1;
            end
            if (nx < meta[1] || showing) fail("hang", $sformatf("unit %0d never shown (or never hidden)", nx));
            if (n_refused !== meta[4][15:0]) fail("count", $sformatf("%0d refused, libpng %0d", n_refused, meta[4]));
            if (n_missed !== 16'd0 || n_late !== 16'd0) fail("count", $sformatf("%0d missed, %0d late", n_missed, n_late));
            if (n_shown !== meta[1][15:0] - meta[4][15:0]) fail("count", $sformatf("%0d shown", n_shown));
            if (n_stale !== ((mh_stale != 0) ? 16'd1 : 16'd0)) fail("stale", $sformatf("%0d completions ignored, the host sent %0d stale", n_stale, mh_stale != 0));
            $display("sub_top_tb: %0s: %0d units shown on time, every plane word identical (%0d refused, %0d stale ignored)",
                     stem, n_shown, n_refused, n_stale);
        end
        $display("PASS: sub_top_tb");
        $finish;
    end
endmodule

`default_nettype wire
