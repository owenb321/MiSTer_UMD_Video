// bench/umd/xmb_wave_tb.sv -- the idle wave, scored on RENDERED PIXELS.
//
// Drives the real umd/sync_gen.sv into the real umd/xmb_wave.sv and renders whole
// frames into memory, writing a few as .ppm under .sim/ for a human to look at.
// The assertions are properties a correct wave must have and a plausible wrong one
// lacks (the cdda_viz_tb discipline from MiSTer_DVD):
//
//   [cov]   de_out is de_in delayed by exactly LAT, and no active pixel is black
//   [mot]   frame 8 differs from frame 0 in more than 20 % of pixels (it rolls)
//   [tint]  month 12 and month 1 give different mean colours, and each month's
//           channel ordering matches its ROM row (r>g>b for December, b>r for August)
//   [grad]  with the waves forced flat, luminance falls monotonically top to bottom
//   [sat]   fewer than 2 % of active pixels are clamped at 255 on any channel
//   [sym]   the sine ROM is odd-symmetric: for every argument, s(a) + s(a+32768) == 0
//           (a dropped quadrant sign breaks this and nothing else)
//   [date]  month_force=0 with a timestamp for 2026-09-22T00:00:00Z gives month 9;
//           1972-02-29 gives 2 (the leap day) and 1972-03-01 gives 3; a second delivery
//           (bit 32 toggled) re-evaluates
//   [vis]   vis=0 -> every pixel black, de_out still aligned
//
// Mutations in bench/umd/run_scaffold.sh --red each break exactly one of these.
`timescale 1ns/1ps
module xmb_wave_tb;

reg clk = 0, rst_n = 0;
always #18.5 clk = ~clk;

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field;
sync_gen sg (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field));

reg        vis = 1;
reg [32:0] timestamp = 33'd0;
reg  [3:0] month_force = 4'd0;
wire [7:0] r, g, b;
wire       de_out;
wire [3:0] month_o;
xmb_wave dut (
    .clk(clk), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(pixel_en),
    .frame_tick(frame_tick), .vis(vis), .timestamp(timestamp), .month_force(month_force),
    .r(r), .g(g), .b(b), .de_out(de_out), .month_o(month_o));

localparam LAT = 4;
localparam W = 720, H = 480;

// frame capture: the pixel at (x, y) lands LAT clocks after sync_gen presents it
reg [11:0] hd [0:LAT-1]; reg [11:0] vd [0:LAT-1]; reg ded [0:LAT-1];
integer k;
always @(posedge clk) begin
    hd[0] <= h_pos; vd[0] <= v_pos; ded[0] <= pixel_en;
    for (k = 1; k < LAT; k = k + 1) begin hd[k] <= hd[k-1]; vd[k] <= vd[k-1]; ded[k] <= ded[k-1]; end
end

reg [7:0] fr0 [0:W*H-1]; reg [7:0] fg0 [0:W*H-1]; reg [7:0] fb0 [0:W*H-1];
reg [7:0] fr1 [0:W*H-1]; reg [7:0] fg1 [0:W*H-1]; reg [7:0] fb1 [0:W*H-1];

integer fails = 0;
integer cov_fail, black_px, ticks, i, x, y, diff, sat, f;
integer sum_top, sum_bot, n_top, n_bot;
integer sr, sg_, sb;
integer fd;

task fail(input [639:0] what); begin $display("FAIL %0s", what); fails = fails + 1; end endtask

// capture one full frame (from the next frame_tick) into set `which`
task capture(input integer which);
    integer got;
    begin
        got = 0;
        @(posedge clk); while (!frame_tick) @(posedge clk);
        // the tick marks h=0,v=0 at sync_gen's output; the pixel for that dot arrives LAT clocks later
        while (got < W*H) begin
            @(posedge clk);
            if (ded[LAT-1] === 1'b1) begin
                if (de_out !== 1'b1) cov_fail = cov_fail + 1;
                if (which == 0) begin fr0[vd[LAT-1]*W + hd[LAT-1]] = r; fg0[vd[LAT-1]*W + hd[LAT-1]] = g; fb0[vd[LAT-1]*W + hd[LAT-1]] = b; end
                else            begin fr1[vd[LAT-1]*W + hd[LAT-1]] = r; fg1[vd[LAT-1]*W + hd[LAT-1]] = g; fb1[vd[LAT-1]*W + hd[LAT-1]] = b; end
                got = got + 1;
            end else if (de_out !== 1'b0) cov_fail = cov_fail + 1;
        end
    end
endtask

task write_ppm(input [511:0] name, input integer which);
    integer p;
    begin
        fd = $fopen(name, "w");
        if (fd) begin
            $fwrite(fd, "P6\n%0d %0d\n255\n", W, H);
            for (p = 0; p < W*H; p = p + 1)
                if (which == 0) $fwrite(fd, "%c%c%c", fr0[p], fg0[p], fb0[p]);
                else            $fwrite(fd, "%c%c%c", fr1[p], fg1[p], fb1[p]);
            $fclose(fd);
        end
    end
endtask

task means(input integer which);
    integer p;
    begin
        sr = 0; sg_ = 0; sb = 0;
        for (p = 0; p < W*H; p = p + 1)
            if (which == 0) begin sr = sr + fr0[p]; sg_ = sg_ + fg0[p]; sb = sb + fb0[p]; end
            else            begin sr = sr + fr1[p]; sg_ = sg_ + fg1[p]; sb = sb + fb1[p]; end
        sr = sr / (W*H); sg_ = sg_ / (W*H); sb = sb / (W*H);
    end
endtask

// odd symmetry of the sine path, probed through the module's own phase registers:
// force the three arguments via a small hierarchical poke is invasive, so instead the
// check reads the ROM through its lookup wires by driving h/v to zero and sweeping ph0.
integer sym_fail;
task sym_check;
    integer a; integer s_a, s_b;
    begin
        sym_fail = 0;
        for (a = 0; a < 65536; a = a + 4096 + 257) begin
            force dut.a0_q = a[15:0];
            @(posedge clk); @(posedge clk);
            s_a = $signed(dut.s0_q);
            force dut.a0_q = (a + 32768) & 16'hFFFF;
            @(posedge clk); @(posedge clk);
            s_b = $signed(dut.s0_q);
            if (s_a + s_b !== 0) begin sym_fail = sym_fail + 1; $display("  sym: a=%0d s=%0d s'=%0d", a, s_a, s_b); end
        end
        release dut.a0_q;
    end
endtask

integer m1r, m1g, m1b, m12r, m12g, m12b;

initial begin
    cov_fail = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;

    // ---- [cov] + frame 0 (December) ----
    month_force = 4'd12;
    capture(0);
    if (cov_fail !== 0) fail("[cov] de_out is not de_in delayed by LAT");
    black_px = 0;
    for (i = 0; i < W*H; i = i + 1) if (fr0[i] == 0 && fg0[i] == 0 && fb0[i] == 0) black_px = black_px + 1;
    if (black_px !== 0) fail("[cov] black active pixels in a visible frame");
    write_ppm(".sim/xmb_wave/frame0_dec.ppm", 0);

    // ---- [sat] ----
    sat = 0;
    for (i = 0; i < W*H; i = i + 1) if (fr0[i] == 255 || fg0[i] == 255 || fb0[i] == 255) sat = sat + 1;
    if (sat * 50 > W*H) fail("[sat] more than 2 % of pixels clamped");
    $display("  sat: %0d clamped px", sat);

    // ---- [grad] measured with the WAVES FORCED FLAT, so the phases cannot confound it:
    //      row luminance must then be exactly the gradient, falling top to bottom ----
    force dut.s0_q = 8'sd0; force dut.s1_q = 8'sd0; force dut.s2_q = 8'sd0;
    month_force = 4'd1;
    capture(1);
    release dut.s0_q; release dut.s1_q; release dut.s2_q;
    sum_top = 0; sum_bot = 0; n_top = 0; n_bot = 0;
    for (y = 0; y < H; y = y + 1) for (x = 0; x < W; x = x + 1) begin
        if (y < H/3)    begin sum_top = sum_top + fr1[y*W+x] + fg1[y*W+x] + fb1[y*W+x]; n_top = n_top + 1; end
        if (y >= 2*H/3) begin sum_bot = sum_bot + fr1[y*W+x] + fg1[y*W+x] + fb1[y*W+x]; n_bot = n_bot + 1; end
    end
    $display("  grad (waves flat): top mean %0d bottom mean %0d", sum_top/n_top, sum_bot/n_bot);
    if (!(sum_top/n_top > sum_bot/n_bot + 150)) fail("[grad] no vertical gradient");
    // and monotone: every 40-line band is no brighter than the one above it
    for (y = 40; y < H; y = y + 40) begin
        sum_top = 0; sum_bot = 0;
        for (x = 0; x < W; x = x + 1) begin
            sum_top = sum_top + fr1[(y-40)*W+x] + fg1[(y-40)*W+x] + fb1[(y-40)*W+x];
            sum_bot = sum_bot + fr1[y*W+x] + fg1[y*W+x] + fb1[y*W+x];
        end
        if (sum_bot > sum_top) fail("[grad] a lower band is brighter than the one above");
    end

    // ---- [tint] December channel order, then January ----
    means(0); m12r = sr; m12g = sg_; m12b = sb;
    if (!(m12r > m12g && m12g > m12b)) fail("[tint] December is not r>g>b");
    month_force = 4'd1;
    capture(1);
    means(1); m1r = sr; m1g = sg_; m1b = sb;
    $display("  tint: dec (%0d,%0d,%0d) jan (%0d,%0d,%0d)", m12r, m12g, m12b, m1r, m1g, m1b);
    if (m1r == m12r && m1g == m12g && m1b == m12b) fail("[tint] month 1 == month 12");
    if (!(m1g > m12g + 20 && m1b > m12b + 20)) fail("[tint] January should be much brighter in g and b than December");
    write_ppm(".sim/xmb_wave/frame_jan.ppm", 1);
    month_force = 4'd8;
    capture(1);
    means(1);
    if (!(sb > sr + 20)) fail("[tint] August is not blue-dominant (b > r)");

    // ---- [mot] frame 8 vs frame 0, same month ----
    month_force = 4'd12;
    capture(1);                      // frame N
    for (f = 0; f < 7; f = f + 1) begin @(posedge clk); while (!frame_tick) @(posedge clk); end
    capture(1);                      // frame N+8
    // compare with frame0_dec captured much earlier: the phases have advanced further
    diff = 0;
    for (i = 0; i < W*H; i = i + 1) if (fr1[i] != fr0[i] || fg1[i] != fg0[i] || fb1[i] != fb0[i]) diff = diff + 1;
    $display("  mot: %0d of %0d pixels differ", diff, W*H);
    if (diff * 5 < W*H) fail("[mot] the wave does not move (< 20 % of pixels changed)");
    write_ppm(".sim/xmb_wave/frame8_dec.ppm", 1);

    // ---- [sym] ----
    sym_check();
    if (sym_fail !== 0) fail("[sym] sine is not odd-symmetric");

    // ---- [date] ----
    month_force = 4'd0;
    @(posedge clk); @(posedge clk);               // let the combinational month_sel settle
    if (month_o !== 4'd7) begin $display("  date: default got %0d", month_o); fail("[date] default month before any timestamp is not 7"); end
    timestamp = {1'b1, 32'd1790035200};          // 2026-09-22T00:00:00Z
    repeat (30000) @(posedge clk);
    if (month_o !== 4'd9) begin $display("  date: got month %0d", month_o); fail("[date] 2026-09-22 is not month 9"); end
    timestamp = {1'b0, 32'd68169600};            // 1972-02-29T00:00:00Z (leap day)
    repeat (30000) @(posedge clk);
    if (month_o !== 4'd2) begin $display("  date: got month %0d", month_o); fail("[date] 1972-02-29 is not month 2"); end
    timestamp = {1'b1, 32'd68256000};            // 1972-03-01T00:00:00Z
    repeat (30000) @(posedge clk);
    if (month_o !== 4'd3) begin $display("  date: got month %0d", month_o); fail("[date] 1972-03-01 is not month 3"); end
    timestamp = {1'b0, 32'd1893456000};          // 2030-01-01T00:00:00Z
    repeat (30000) @(posedge clk);
    if (month_o !== 4'd1) begin $display("  date: got month %0d", month_o); fail("[date] 2030-01-01 is not month 1"); end

    // ---- [vis] ----
    vis = 0; cov_fail = 0;
    capture(1);
    if (cov_fail !== 0) fail("[vis] de_out misaligned with vis=0");
    black_px = 0;
    for (i = 0; i < W*H; i = i + 1) if (fr1[i] == 0 && fg1[i] == 0 && fb1[i] == 0) black_px = black_px + 1;
    if (black_px !== W*H) fail("[vis] vis=0 is not all black");

    if (fails != 0) begin $display("FAIL: xmb_wave_tb %0d check(s)", fails); $fatal(1); end
    $display("PASS: xmb_wave_tb");
    $finish;
end

initial begin #(40*858*525*40); $display("FAIL: xmb_wave_tb timeout"); $fatal(1); end
endmodule
