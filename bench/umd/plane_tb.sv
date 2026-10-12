// bench/umd/plane_tb.sv -- the overlay plane compositor as emu will compose it
// (docs/compositor.md): umd/sync_gen.sv's raster; umd/disp_reader.sv (the video, a random
// 720x480 store) and umd/plane_reader.sv on ram2's B side through umd/rd_merge2.sv and
// umd/ddr_mux2.sv (B_FIRST), whose A is a subtitle master that never stops; the plane
// over the video by umd/plane_blend.sv; bench/umd/ddr_model.sv. Goldens: tools/
// disp_golden.py (the video) and tools/plane_golden.py (the planes, the composites).
//
// (default)   the subtitle plane at 1:1: sub_sched's requests (flip, flip, hide the cycle
//             after the second flip's ack) through umd/sub/sub_flip.sv, raised mid-frame
// +scale      menu-style geometries set in the vertical blank: 480x272 up to the raster,
//             a placed downscale, a refused one (the source past the 720-pixel row)
// +il         (sub mode) the 480i raster (docs/analog.md): raw raster coordinates (V11), so
//             the expected rasters are the 480p ones, every pixel scored on both of its dots
//             and both fields; the strobe at line 501 (the bottom field's blank: a flip at a
//             frame's end)
// Frame 0 warms up; frames 1-3 are scored, every active dot:
//   [pass]  (sub) the plane's premultiplied ARGB (LAT 5) equals the buffer inside the
//           clipped rectangle and 0 outside (!==)
//   [scale] (scale) the plane's ARGB equals the fixed-point bilinear (!==)
//   [blend] the composite (LAT 7) equals the golden's (!==)
//   [flip]  (sub) a request is latched at the first vertical blank after it was raised
//           and acknowledged within 40 mclk cycles of it, never before; the latch count
//           equals the requests raised; the plane's geometry changes only at the strobe
//   [clip]  (sub) the latched rectangle is the golden's clip of the raw one
//   [geo]   geo_bad is raised exactly for the refused geometry
//   [late]  no line request ever arrives while the last is still being fetched
//   [proto] a command the merge presented under waitrequest is held until accepted
//   [count] 3 x 345,600 dots scored; (sub) 3 latches
// PASS marker: "PASS: plane_tb".
`timescale 1ns/1ps
`default_nettype none
module plane_tb #(
    parameter bit P_SCALE = 1'b1   // plane_reader's SCALE: 0 = the 1:1 reader (sub mode only; area_plan.md A3)
);
`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1, "plane_tb: failed"); end
localparam logic [28:0] BASE = 29'h0600_0000;
localparam logic [28:0] PL0 = BASE + 29'h30_0000, PL1 = BASE + 29'h38_0000;
localparam int NDOT = 720 * 480;
logic clk = 0, mclk = 0;
always #18.519 clk = ~clk;       // 27 MHz
always #5.556 mclk = ~mclk;      // 90 MHz
logic rst_n = 0;
bit scale, noscore, il;
initial il = $test$plusargs("il");

// ---- the raster ---------------------------------------------------------------------------------
wire [11:0] h_pos, v_pos; wire pixel_en, hs, vs, hbl, vbk, ft, fld;
sync_gen sg (.clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(il), .ce_pix(), .h_pos(h_pos), .v_pos(v_pos),
             .pixel_en(pixel_en), .h_sync(hs), .v_sync(vs), .h_blank(hbl), .v_blank(vbk), .frame_tick(ft), .field(fld));
wire vbl = (h_pos == 12'd0) && (v_pos == (il ? 12'd501 : 12'd500));

// ---- ram2 ---------------------------------------------------------------------------------------
wire [28:0] p_address, q_address, b_address, ddr_address;
wire [7:0]  p_burstcount, q_burstcount, b_burstcount, ddr_burstcount, ddr_byteenable;
wire        p_read, q_read, b_read, p_waitrequest, q_waitrequest, b_waitrequest;
wire        p_readdatavalid, q_readdatavalid, b_readdatavalid;
wire [63:0] p_readdata, q_readdata, b_readdata, ddr_readdata, ddr_writedata;
wire        ddr_read, ddr_write, ddr_waitrequest, ddr_readdatavalid;
logic [28:0] a_address; logic [7:0] a_burstcount; logic a_read, a_write; logic [63:0] a_writedata;
wire        a_waitrequest, a_readdatavalid; wire [63:0] a_readdata;
int unwritten;
rd_merge2 u_merge (.clk(mclk), .rst_n(rst_n),
    .p_address, .p_burstcount, .p_read, .p_waitrequest, .p_readdata, .p_readdatavalid,
    .q_address, .q_burstcount, .q_read, .q_waitrequest, .q_readdata, .q_readdatavalid,
    .m_address(b_address), .m_burstcount(b_burstcount), .m_read(b_read), .m_waitrequest(b_waitrequest),
    .m_readdata(b_readdata), .m_readdatavalid(b_readdatavalid));
ddr_mux2 #(.B_FIRST(1'b1)) u_mux (.clk(mclk), .rst_n(rst_n),
    .a_address, .a_burstcount, .a_read, .a_write, .a_writedata, .a_byteenable(8'hFF), .a_abort(1'b0),
    .a_waitrequest, .a_readdata, .a_readdatavalid,
    .b_address, .b_burstcount, .b_read, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .b_write(1'b0), .b_writedata(64'd0),   // B reads only here (main gave B writes for the vbuf)
    .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
    .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid);
ddr_model #(.BASE(BASE), .AW(22)) ddr (.clk(mclk), .rst_n(rst_n), .address(ddr_address), .burstcount(ddr_burstcount),
    .read(ddr_read), .write(ddr_write), .writedata(ddr_writedata), .byteenable(ddr_byteenable), .waitrequest(ddr_waitrequest),
    .readdata(ddr_readdata), .readdatavalid(ddr_readdatavalid), .unwritten_reads(unwritten));

// A: the subtitle master, never idle (8-beat writes and reads at random, its own region)
int aseed = 3;
logic [3:0] abeat;
bit aload = 1;
always @(posedge mclk) begin
    if (!rst_n) begin a_read <= 0; a_write <= 0; abeat <= 0; a_burstcount <= 8; a_address <= BASE + 29'h10_0000; a_writedata <= 0; end
    else if (aload) begin
        if (a_read && !a_waitrequest) a_read <= 0;
        if (a_write && !a_waitrequest) begin
            abeat <= abeat + 1; a_writedata <= {$urandom(aseed), $urandom(aseed)};
            if (abeat == 7) begin a_write <= 0; abeat <= 0; end
        end
        if (!a_read && !a_write || (a_read && !a_waitrequest) || (a_write && !a_waitrequest && abeat == 7)) begin
            if ($urandom(aseed) % 2) begin a_write <= 1; a_read <= 0; end
            else begin a_read <= 1; a_write <= 0; end
            a_address <= BASE + 29'h10_0000 + ($urandom(aseed) % 4096) * 8;
        end
    end
end

// [proto]: the merge's command is held under waitrequest
logic pend_q; logic [28:0] pend_a; logic [7:0] pend_n;
always @(posedge mclk) begin
    if (!rst_n) pend_q <= 0;
    else begin
        if (pend_q && !(b_read && b_address === pend_a && b_burstcount === pend_n))
            `FAIL("proto", $sformatf("the merge withdrew or changed a command under waitrequest (%h x%0d)", pend_a, pend_n))
        pend_q <= b_read && b_waitrequest; pend_a <= b_address; pend_n <= b_burstcount;
    end
end

// ---- the video --------------------------------------------------------------------------------
wire [7:0] vr, vg, vb; wire vde;
disp_reader #(.DPB_BASE(BASE)) u_disp (.clk(clk), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .de_in(pixel_en), .il(il), .pic_still(1'b0), .aa_mode(2'd0),
    .win(1'b0), .win_hold(1'b0), .win_x(10'd0), .win_y(10'd0), .win_w(10'd0), .win_h(10'd0), .win_hs(26'd0), .win_vs(26'd0), .win_x0(26'd0), .win_y0(26'd0), .win_bad(),   // P9's video window: run_disp_reader.sh's W arms
    .pic_valid(1'b1), .pic_store(5'd17), .pic_field(1'b0), .pic_w_mbs(8'd45), .pic_hf_mbs(8'd30),
    .pic_parity(1'b0), .pic_single(1'b0), .deint_mode(2'd0),   // (tied: they floated until 480i read them)
    .pic_match(1'b0), .pic_pstore(5'd0), .pic_film(2'd0), .cm_c(), .cm_r(), .cm_v(),   // fj#80 (run_disp_reader.sh's match / film / comb arms)
    .r(vr), .g(vg), .b(vb), .de_out(vde),
    .mclk(mclk), .mrst_n(rst_n), .ddr_address(p_address), .ddr_burstcount(p_burstcount), .ddr_read(p_read),
    .ddr_waitrequest(p_waitrequest), .ddr_readdata(p_readdata), .ddr_readdatavalid(p_readdatavalid));
logic [7:0] vr5, vg5, vb5;          // LAT 4 -> 5, the plane's
always @(posedge clk) begin vr5 <= vr; vg5 <= vg; vb5 <= vb; end

// ---- the subtitle latch (sub mode) --------------------------------------------------------------
logic d_req, d_buf, d_vis; logic [15:0] d_x, d_y, d_w, d_h; wire d_ack;
wire f_vis; wire [28:0] f_base; wire [9:0] f_x, f_w; wire [8:0] f_y, f_h; wire [15:0] n_flips;
sub_flip #(.PLANE0(PL0), .PLANE1(PL1)) u_flip (.mclk(mclk), .mrst_n(rst_n), .d_req, .d_buf, .d_vis, .d_x, .d_y, .d_w, .d_h, .d_ack,
    .clk(clk), .rst_n(rst_n), .vbl(vbl), .vis(f_vis), .base(f_base), .x(f_x), .y(f_y), .w(f_w), .h(f_h), .n_flips(n_flips),
    .ui(1'b0), .ui_sub(1'b0), .hf_req(1'b0), .hf_buf(2'd0), .hf_vis(1'b0), .hf_x(16'd0), .hf_y(16'd0), .hf_w(16'd0), .hf_h(16'd0),
    .hf_ack());                                  // P9's hand-over: sub_flip_tb

// ---- the plane --------------------------------------------------------------------------------
logic g_vis; logic [28:0] g_base; logic [9:0] g_sx, g_sw, g_dx, g_dw; logic [8:0] g_sy, g_sh, g_dy, g_dh;
logic [25:0] g_hstep, g_vstep; logic [27:0] g_hstart, g_vstart;
wire        pvis   = scale ? g_vis : f_vis;
wire [28:0] pbase  = scale ? g_base : f_base;
wire [9:0]  psx = scale ? g_sx : f_x, psw = scale ? g_sw : f_w, pdx = scale ? g_dx : f_x, pdw = scale ? g_dw : f_w;
wire [8:0]  psy = scale ? g_sy : f_y, psh = scale ? g_sh : f_h, pdy = scale ? g_dy : f_y, pdh = scale ? g_dh : f_h;
wire [25:0] phs = scale ? g_hstep : 26'h10000, pvs = scale ? g_vstep : 26'h10000;
wire [27:0] phst = scale ? g_hstart : 28'd0, pvst = scale ? g_vstart : 28'd0;
wire [7:0] pa, pr, pg, pb; wire geo_bad; wire [15:0] n_late;
plane_reader #(.SCALE(P_SCALE)) u_plane (.clk(clk), .rst_n(rst_n), .h_pos(h_pos), .v_pos(v_pos), .il(il), .de_in(pixel_en),
    .vis(pvis), .base(pbase), .sx(psx), .sy(psy), .sw(psw), .sh(psh), .dx(pdx), .dy(pdy), .dw(pdw), .dh(pdh),
    .hstep(phs), .vstep(pvs), .hstart(phst), .vstart(pvst), .geo_bad(geo_bad),
    .a(pa), .r(pr), .g(pg), .b(pb),
    .mclk(mclk), .mrst_n(rst_n), .ddr_address(q_address), .ddr_burstcount(q_burstcount), .ddr_read(q_read),
    .ddr_waitrequest(q_waitrequest), .ddr_readdata(q_readdata), .ddr_readdatavalid(q_readdatavalid), .n_late(n_late));
wire [7:0] cr, cg, cb;
plane_blend u_blend (.clk(clk), .s_a(pa), .s_r(pr), .s_g(pg), .s_b(pb), .d_r(vr5), .d_g(vg5), .d_b(vb5), .r(cr), .g(cg), .b(cb));

// ---- fixtures -----------------------------------------------------------------------------------
logic [63:0] store [0:65535];
logic [63:0] pbuf [0:172799];
logic [31:0] e_argb [0:3*NDOT-1];
logic [23:0] e_rgb [0:3*NDOT-1];
int sreq [0:2][0:10];                // sub: buf vis x y w h  shown cx cy cw ch
int sgeo [0:2][0:14];                // scale: buf vis sx sy sw sh dx dy dw dh hstep vstep hstart vstart bad
initial begin
    int fd;
    string pre, fn;
    scale = $test$plusargs("scale");
    noscore = $test$plusargs("noscore");
    if ($test$plusargs("noaload")) aload = 0;
    pre = scale ? "bench/umd/fixtures/gen/plane_m" : "bench/umd/fixtures/gen/plane_s";
    $readmemh("bench/umd/fixtures/gen/disp_store.hex", store);
    for (int i = 0; i < 43200 + 21600; i++) ddr.poke(BASE + {5'd17, 17'd0} + i, store[i]);
    for (int i = 0; i < 4096 * 8 + 8; i++) ddr.poke(BASE + 29'h10_0000 + i, 64'd0);     // A's region: no unwritten reads
    for (int k = 0; k < 2; k++) begin
        fn = $sformatf("%sbuf%0d.hex", pre, k);
        $readmemh(fn, pbuf);
        for (int i = 0; i < 172800; i++) ddr.poke((k ? PL1 : PL0) + i, pbuf[i]);
    end
    for (int k = 0; k < 3; k++) begin
        fn = $sformatf("%s%0d_argb.hex", pre, k);
        $readmemh(fn, e_argb, k * NDOT, (k + 1) * NDOT - 1);
        fn = $sformatf("%s%0d_rgb.hex", pre, k);
        $readmemh(fn, e_rgb, k * NDOT, (k + 1) * NDOT - 1);
    end
    fn = scale ? "bench/umd/fixtures/gen/plane_scale.txt" : "bench/umd/fixtures/gen/plane_sub.txt";
    fd = $fopen(fn, "r");
    for (int k = 0; k < 3; k++)
        for (int i = 0; i < (scale ? 15 : 11); i++) begin
            int v;
            void'($fscanf(fd, "%d", v));
            if (scale) sgeo[k][i] = v; else sreq[k][i] = v;
        end
    $fclose(fd);
    #100 rst_n = 1;
end

// ---- frames, vertical blanks ----------------------------------------------------------------
int frame = 0, nvbl = 0;              // frame: counted after each frame's last dot (the first from reset is 0)
always @(posedge clk) if (rst_n) begin
    if (il ? (h_pos == 1715 && v_pos == 523) : (h_pos == 857 && v_pos == 524)) frame <= frame + 1;
    if (vbl) nvbl <= nvbl + 1;
end

// scale mode: the geometry of frame f + 1 set at frame f's vertical blank
always @(posedge clk) begin
    if (!rst_n) begin
        g_vis <= 0; g_base <= PL0; g_sx <= 0; g_sy <= 0; g_sw <= 0; g_sh <= 0; g_dx <= 0; g_dy <= 0; g_dw <= 0; g_dh <= 0;
        g_hstep <= 0; g_vstep <= 0; g_hstart <= 0; g_vstart <= 0;
    end else if (scale && vbl && frame >= 0 && frame < 3) begin
        g_base <= sgeo[frame][0] ? PL1 : PL0; g_vis <= sgeo[frame][1];
        g_sx <= sgeo[frame][2]; g_sy <= sgeo[frame][3]; g_sw <= sgeo[frame][4]; g_sh <= sgeo[frame][5];
        g_dx <= sgeo[frame][6]; g_dy <= sgeo[frame][7]; g_dw <= sgeo[frame][8]; g_dh <= sgeo[frame][9];
        g_hstep <= sgeo[frame][10]; g_vstep <= sgeo[frame][11]; g_hstart <= sgeo[frame][12]; g_vstart <= sgeo[frame][13];
    end
end

// sub mode: sub_sched's side of the handshake. Request 0 at frame 0 line 100, request 1 at
// frame 1 line 200, request 2 (the hide) the cycle after request 1's ack lowered d_req.
int nk = 0, raised_vbl [0:2], raised_n_at_vbl = 0, last_vbl_m = 0, tm = 0;
logic vbl_m1, vbl_m2, vbl_m3;
always @(posedge mclk) begin
    tm <= tm + 1;
    vbl_m1 <= vbl; vbl_m2 <= vbl_m1; vbl_m3 <= vbl_m2;
    if (vbl_m2 && !vbl_m3) last_vbl_m <= tm;
    if (!rst_n) begin d_req <= 0; d_buf <= 0; d_vis <= 0; d_x <= 0; d_y <= 0; d_w <= 0; d_h <= 0; end
    else if (!scale) begin
        if (d_req && d_ack) begin
            if (nvbl != raised_vbl[nk - 1] + 1)
                `FAIL("flip", $sformatf("request %0d acknowledged after %0d vertical blanks, not the first", nk - 1, nvbl - raised_vbl[nk - 1]))
            if (tm - last_vbl_m > 40)
                `FAIL("flip", $sformatf("request %0d acknowledged %0d mclk cycles after the blank", nk - 1, tm - last_vbl_m))
            d_req <= 0;
        end else if (d_ack) `FAIL("flip", "an acknowledgement with no request")
        else if (!d_req && nk < 3 && ((nk == 0 && frame == 0 && v_pos >= 100) || (nk == 1 && frame == 1 && v_pos >= 200) || nk == 2 && frame >= 1)) begin
            d_req <= 1; d_buf <= sreq[nk][0]; d_vis <= sreq[nk][1]; d_x <= sreq[nk][2]; d_y <= sreq[nk][3]; d_w <= sreq[nk][4]; d_h <= sreq[nk][5];
            raised_vbl[nk] <= nvbl; nk <= nk + 1;
        end
    end
end

// [flip] / [clip]: the latch's outputs change only at the strobe; the count after each blank
logic [66:0] fprev; logic vbl_d;
wire  [66:0] fnow = {f_vis, f_base, f_x, f_y, f_w, f_h};
int nlatched = 0;
always @(posedge clk) if (rst_n && !scale) begin
    vbl_d <= vbl; fprev <= fnow;
    if (fnow !== fprev && !vbl_d && frame >= 0)
        `FAIL("flip", $sformatf("the plane's geometry changed at (%0d, %0d), not at the blank", h_pos, v_pos))
    if (h_pos == 20 && v_pos == (il ? 12'd501 : 12'd500)) begin
        int want;
        want = 0;
        for (int k = 0; k < nk; k++) if (raised_vbl[k] < nvbl) want++;
        if (n_flips != want) `FAIL("flip", $sformatf("%0d latches after blank %0d, %0d requests raised before it", n_flips, nvbl, want))
        if (n_flips > nlatched) begin
            int k;
            k = n_flips - 1;
            // another request's rectangle in this one's place is the handshake's defect
            for (int j = 0; j < 3; j++)
                if (j != k && sreq[j][6] != 0 && f_vis === 1'b1 && f_x == sreq[j][7] && f_y == sreq[j][8] && f_w == sreq[j][9]
                    && f_h == sreq[j][10] && f_base === (sreq[j][0] ? PL1 : PL0))
                    `FAIL("flip", $sformatf("latch %0d holds request %0d's rectangle", k, j))
            if (sreq[k][6] == 0) begin
                if (f_vis !== 1'b0) `FAIL("clip", $sformatf("request %0d: shown, the golden hides it", k))
            end else if (f_vis !== 1'b1 || f_x !== sreq[k][7] || f_y !== sreq[k][8] || f_w !== sreq[k][9] || f_h !== sreq[k][10]
                         || f_base !== (sreq[k][0] ? PL1 : PL0))
                `FAIL("clip", $sformatf("request %0d: %0d %0d %0d %0d %0d, the golden %0d %0d %0d %0d", k, f_vis, f_x, f_y, f_w, f_h,
                                        sreq[k][7], sreq[k][8], sreq[k][9], sreq[k][10]))
            nlatched = n_flips;
        end
    end
end

// ---- scoring --------------------------------------------------------------------------------
logic [11:0] hq [0:7]; logic [11:0] vq [0:7]; logic dq [0:7]; int fq [0:7];
always @(posedge clk) begin
    hq[0] <= h_pos; vq[0] <= v_pos; dq[0] <= pixel_en; fq[0] <= frame;
    for (int i = 1; i < 8; i++) begin hq[i] <= hq[i-1]; vq[i] <= vq[i-1]; dq[i] <= dq[i-1]; fq[i] <= fq[i-1]; end
end
int n_argb = 0, n_rgb = 0;
always @(posedge clk) if (rst_n) begin
    if (n_late !== 16'd0) `FAIL("late", $sformatf("%0d line requests arrived during a fetch", n_late))
    if (h_pos == 5 && v_pos == 0 && frame >= 1 && frame <= 3) begin
        if (geo_bad !== (scale && sgeo[frame - 1][14] != 0)) `FAIL("geo", $sformatf("frame %0d: geo_bad %0d", frame, geo_bad))
    end
    // the plane, LAT 5 (+noscore: the [late] control, whose slow model breaks every picture)
    if (dq[4] && fq[4] >= 1 && fq[4] <= 3 && !noscore) begin
        int i;
        i = (fq[4] - 1) * NDOT + vq[4] * 720 + (il ? hq[4][11:1] : hq[4]);
        if ({pa, pr, pg, pb} !== e_argb[i])
            `FAIL(scale ? "scale" : "pass", $sformatf("frame %0d (%0d, %0d): %h, want %h", fq[4], hq[4], vq[4], {pa, pr, pg, pb}, e_argb[i]))
        n_argb++;
    end
    // the composite, LAT 7
    if (dq[6] && fq[6] >= 1 && fq[6] <= 3 && !noscore) begin
        int i;
        i = (fq[6] - 1) * NDOT + vq[6] * 720 + (il ? hq[6][11:1] : hq[6]);
        if ({cr, cg, cb} !== e_rgb[i])
            `FAIL("blend", $sformatf("frame %0d (%0d, %0d): %h, want %h", fq[6], hq[6], vq[6], {cr, cg, cb}, e_rgb[i]))
        n_rgb++;
    end
    if (frame == 4 && h_pos == 100) begin
        if (n_argb !== (il ? 6 : 3) * NDOT || n_rgb !== (il ? 6 : 3) * NDOT) `FAIL("count", $sformatf("%0d plane / %0d composite dots scored", n_argb, n_rgb))
        if (!scale && n_flips !== 16'd3) `FAIL("count", $sformatf("%0d latches", n_flips))
        if (unwritten != 0) `FAIL("count", $sformatf("%0d reads of unwritten DDR3", unwritten))
        $display("plane_tb: %0s%0s: 3 frames, %0d plane + %0d composite dots exact%0s", scale ? "scale" : "sub", il ? " (480i)" : "", n_argb, n_rgb,
                 scale ? " (480x272 up, a placed downscale, a refused geometry)" : ", 3 latches at the blank (flip, flip, hide)");
        $display("PASS: plane_tb");
        $finish;
    end
end
endmodule
`default_nettype wire
