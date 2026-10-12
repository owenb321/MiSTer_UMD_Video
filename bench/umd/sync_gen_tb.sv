// bench/umd/sync_gen_tb.sv -- MEASURES umd/sync_gen.sv's raster rather than restating it.
//
// Every number below is counted from the DUT's outputs over whole frames: dots between
// frame_ticks, active dots per frame, hsync width and period, vsync width and start
// line, coordinate monotonicity. The expected values are the CEA-861 480p figures
// written out independently of the module's parameters (858x525, 720x480, 62/6, sync
// at dot 736 and line 489), so a wrong parameter in the DUT cannot also be wrong here.
//
// Scoring uses !== throughout (an X passes != vacuously) and every failure is $fatal
// (a $finish on failure exits 0 and a runner reads it as PASS).
`timescale 1ns/1ps
module sync_gen_tb;

reg clk = 0, rst_n = 0;
always #18.5 clk = ~clk;           // ~27 MHz

wire [11:0] h_pos, v_pos;
wire pixel_en, h_sync, v_sync, h_blank, v_blank, frame_tick, field;
sync_gen dut (
    .clk(clk), .clk_en(1'b1), .rst_n(rst_n), .interlaced(1'b0),
    .h_pos(h_pos), .v_pos(v_pos), .pixel_en(pixel_en), .h_sync(h_sync), .v_sync(v_sync),
    .h_blank(h_blank), .v_blank(v_blank), .frame_tick(frame_tick), .field(field));

integer fails = 0;
task check(input [255:0] what, input integer got, input integer want);
    if (got !== want) begin
        $display("FAIL %0s: got %0d want %0d", what, got, want); fails = fails + 1;
    end else $display("  ok  %0s = %0d", what, got);
endtask

// counters over one measured frame (from the 2nd frame_tick to the 3rd)
integer dots, active, hs_dots, vs_lines, hs_periods, hs_first_dot, vs_first_line;
integer hs_rise_dot, prev_hs, prev_vs, lines_in_frame, prev_h, prev_v;
integer mono_fail, field_fail, ticks;
integer frame_no;

initial begin
    dots = 0; active = 0; hs_dots = 0; vs_lines = 0; hs_periods = 0;
    hs_first_dot = -1; vs_first_line = -1; hs_rise_dot = -1; prev_hs = 0; prev_vs = 0;
    lines_in_frame = 0; prev_h = -1; prev_v = -1; mono_fail = 0; field_fail = 0; ticks = 0;
    frame_no = 0;
    repeat (4) @(posedge clk);
    rst_n = 1;
    // count frame_ticks; measure the whole frame between the 2nd and the 3rd (the
    // first frame after reset is partial). The tick dot itself belongs to the frame
    // it starts, so it is counted below in the same cycle it is seen.
    forever begin
        @(posedge clk);
        if (frame_tick) begin
            ticks = ticks + 1;
            if (ticks == 3) begin
                check("dots per frame (858x525)", dots, 858*525);
                check("active dots per frame (720x480)", active, 720*480);
                check("hsync width (dots)", hs_dots / hs_periods, 62);
                check("hsync periods per frame", hs_periods, 525);
                check("hsync first dot (720+16)", hs_first_dot, 736);
                check("vsync width (lines)", vs_lines, 6);
                check("vsync first line (480+9)", vs_first_line, 489);
                check("h_pos/v_pos monotone", mono_fail, 0);
                check("field stays 0", field_fail, 0);
                if (fails != 0) begin $display("FAIL: sync_gen_tb %0d check(s)", fails); $fatal(1); end
                $display("PASS: sync_gen_tb");
                $finish;
            end
        end
        if (ticks >= 2) begin
            dots = dots + 1;
            if (pixel_en === 1'b1) active = active + 1;
            if (h_sync === 1'b1) hs_dots = hs_dots + 1;
            if (h_sync === 1'b1 && prev_hs === 0) begin
                hs_periods = hs_periods + 1;
                if (hs_first_dot < 0) hs_first_dot = h_pos;
            end
            if (v_sync === 1'b1 && prev_vs === 0) vs_first_line = v_pos;
            if (v_sync === 1'b1 && h_pos == 0) vs_lines = vs_lines + 1;
            // coordinates: h steps by 1 and wraps at 857; v steps by 1 at the wrap
            if (prev_h >= 0) begin
                if (h_pos !== ((prev_h == 857) ? 0 : prev_h + 1)) mono_fail = mono_fail + 1;
                if (prev_h == 857 && v_pos !== ((prev_v == 524) ? 0 : prev_v + 1)) mono_fail = mono_fail + 1;
                if (prev_h != 857 && v_pos !== prev_v) mono_fail = mono_fail + 1;
            end
            if (field !== 1'b0) field_fail = field_fail + 1;
            prev_h = h_pos; prev_v = v_pos;
        end
        prev_hs = h_sync; prev_vs = v_sync;
    end
end

initial begin #(40*858*525*4); $display("FAIL: sync_gen_tb timeout"); $fatal(1); end
endmodule
