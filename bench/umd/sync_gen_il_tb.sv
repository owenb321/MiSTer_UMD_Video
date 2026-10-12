// bench/umd/sync_gen_il_tb.sv -- MEASURES umd/sync_gen.sv's interlaced (480i) raster.
//
// The DUT starts progressive; after two progressive frames `interlaced` rises and the
// bench checks the restart, then measures four whole fields. The expected values are the
// 480i figures written out independently of the module (docs/analog.md, MiSTer_DVD's
// N64-model raster): 1716 dots a line (pixel repetition), 240 active lines a field of
// 1440 active dots, hsync 124 dots from dot 1472, the two fields 262 and 263 lines
// (900,900 dots a frame), vsync 3 lines long, its rising edges EXACTLY 262.5 lines
// (450,450 dots) apart every field -- the short field's at dot 0 of a line, the long
// field's at the half-line (dot 858) -- and the short (SMPTE field 1) field the v_pos-ODD
// one (FIELD1_VPOS). v_pos is the frame line: every active line of a field has the
// field's parity; `field` equals v_pos[0]; ce_pix marks every even dot; the field the switch
// starts is whole (one frame_tick, not two: the restart's own cycle does not tick).
//
// !== throughout; every failure is $fatal; the PASS marker is positive.
`timescale 1ns/1ps
module sync_gen_il_tb;

reg clk = 0, rst_n = 0, il = 0;
always #18.5 clk = ~clk;

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field, ce_pix;
sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(il),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field), .ce_pix(ce_pix));

// a second raster OUT OF RESET already interlaced (emu powering up with Video Output =
// Interlaced): its restart lands with the counters at 0, where a tick in the restart's own
// cycle would make the first field tick twice
wire [11:0] h2, v2;
wire pe2, hs2, vs2, hb2, vb2, ft2, fl2, ce2;
sync_gen dut2 (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b1),
    .h_pos(h2), .v_pos(v2), .pixel_en(pe2), .h_sync(hs2), .v_sync(vs2),
    .h_blank(hb2), .v_blank(vb2), .frame_tick(ft2), .field(fl2), .ce_pix(ce2));
integer t2 = 0, ft2_n = 0, ft2_first = -1, ft2_gap = -1;
always @(posedge clk) if (rst_n) begin
    t2 = t2 + 1;
    if (ft2 === 1'b1) begin
        if (ft2_n == 0) ft2_first = t2;
        else if (ft2_n == 1) ft2_gap = t2 - ft2_first;
        ft2_n = ft2_n + 1;
    end
end

integer fails = 0;
task check(input [511:0] what, input integer got, input integer want);
    if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", what, got, want); fails = fails + 1;
    end else $display("  ok  %0s = %0d", what, got);
endtask

// per-field measurements (fields 1..4 after the switch; field 0 is checked for the restart)
integer t, nfield, dots, act, hs_dots, hs_n, hs_first, lines, vs_dots, vs_rise_dot, vs_rise_t;
integer prev_hs, prev_vs, par_fail, fld_fail, ce_fail, lastpar;
integer f_lines [0:7], f_vsdot [0:7], f_par [0:7], f_act [0:7], f_dots [0:7], f_vsw [0:7];
integer f_vsgap [0:7];
integer tick_t, i;
integer hs_dots_w = 0, hs_first_w = -1, f_cur_par = 0;

initial begin
    t = 0; nfield = -1; prev_hs = 0; prev_vs = 0; par_fail = 0; fld_fail = 0; ce_fail = 0;
    vs_rise_t = -1; tick_t = -1;
    for (i = 0; i < 8; i = i + 1) begin f_vsgap[i] = -1; f_vsdot[i] = -1; end
    repeat (4) @(posedge clk);
    rst_n = 1;
    // two progressive frames, then the switch
    repeat (2 * 858 * 525 + 100) @(posedge clk);
    il = 1;
    forever begin
        @(posedge clk); #1;
        t = t + 1;
        if (frame_tick === 1'b1) begin
            if (nfield == -1) begin
                // the restart: the first tick after the switch is the top field's first dot
                check("restart: the first field after the switch starts at h 0", h_pos, 0);
                check("restart: the first field is the top one (v_pos even)", v_pos, 0);
            end else if (nfield >= 0 && nfield < 8) begin
                f_lines[nfield] = lines; f_act[nfield] = act; f_dots[nfield] = dots;
                f_vsdot[nfield] = vs_rise_dot; f_par[nfield] = lastpar; f_vsw[nfield] = vs_dots;
            end
            nfield = nfield + 1;
            dots = 0; act = 0; hs_dots = 0; hs_n = 0; hs_first = -1; lines = 0; vs_dots = 0; vs_rise_dot = -1;
            if (nfield == 6) begin
                // fields 1..4 (the first whole ones after the restart field 0)
                // the restart's field is whole: ONE tick, then 263 lines (a restart that
                // ticked twice would be a spurious refresh at every mode switch)
                check("the first field after the switch is whole (one tick, 263 x 1716 dots)", f_dots[0], 263 * 1716);
                check("reset-interlaced first field whole (263 x 1716)", ft2_gap, 263 * 1716);
                check("hsync width (dots, 2 x 62)", hs_dots_w, 124);
                check("hsync first dot (2 x (720 + 16))", hs_first_w, 1472);
                check("active dots a field (1440 x 240)", f_act[2], 1440 * 240);
                check("the two field totals, lines (262 + 263)", f_lines[2] + f_lines[3], 525);
                check("the field totals alternate", f_lines[2] + f_lines[4] == 2 * f_lines[2] ? 1 : 0, 1);
                check("dots a frame (525 x 1716)", f_dots[2] + f_dots[3], 900900);
                check("vsync length (dots, 3 lines)", f_vsw[2], 3 * 1716);
                check("vsync length, the other field", f_vsw[3], 3 * 1716);
                check("vsync edge spacing, field 2 -> 3 (262.5 lines)", f_vsgap[3], 450450);
                check("vsync edge spacing, field 3 -> 4", f_vsgap[4], 450450);
                check("vsync edge spacing, field 4 -> 5", f_vsgap[5], 450450);
                // the short field is SMPTE field 1: line-aligned vsync, and v_pos-ODD
                for (i = 2; i <= 3; i = i + 1)
                    if (f_lines[i] == 262) begin
                        check("the short field's vsync starts at dot 0", f_vsdot[i], 0);
                        check("the short field is the v_pos-odd one (FIELD1_VPOS)", f_par[i], 1);
                    end else begin
                        check("the long field's vsync starts at the half-line", f_vsdot[i], 858);
                        check("the long field is 263 lines", f_lines[i], 263);
                        check("the long field is the v_pos-even one", f_par[i], 0);
                    end
                check("active lines keep their field's parity", par_fail, 0);
                check("field == v_pos[0] on active dots", fld_fail, 0);
                check("ce_pix on every even dot, only there", ce_fail, 0);
                if (fails != 0) begin $display("FAIL: sync_gen_il_tb %0d check(s)", fails); $fatal(1); end
                $display("PASS: sync_gen_il_tb");
                $finish;
            end
        end
        if (nfield >= 0) begin
            dots = dots + 1;
            if (pixel_en === 1'b1) begin
                act = act + 1;
                lastpar = v_pos[0];
                if (dots > 1 && v_pos[0] !== f_cur_par) par_fail = par_fail + 1;
                if (field !== v_pos[0]) fld_fail = fld_fail + 1;
            end
            if (h_pos == 0) begin
                lines = lines + 1;
                if (dots == 1) f_cur_par = v_pos[0];
            end
            if (ce_pix !== ~h_pos[0]) ce_fail = ce_fail + 1;
            if (h_sync === 1'b1) hs_dots = hs_dots + 1;
            if (h_sync === 1'b1 && prev_hs === 0) begin
                hs_n = hs_n + 1;
                if (hs_first < 0) hs_first = h_pos;
                hs_first_w = hs_first;
            end
            if (h_sync === 1'b0 && prev_hs === 1) hs_dots_w = hs_dots / hs_n;
            if (v_sync === 1'b1) vs_dots = vs_dots + 1;
            if (v_sync === 1'b1 && prev_vs === 0) begin
                vs_rise_dot = h_pos;
                if (vs_rise_t >= 0 && nfield < 8) f_vsgap[nfield] = t - vs_rise_t;
                vs_rise_t = t;
            end
        end
        prev_hs = h_sync; prev_vs = v_sync;
    end
end
initial begin #(40 * 858 * 525 * 8); $display("FAIL: sync_gen_il_tb timeout"); $fatal(1); end
endmodule
