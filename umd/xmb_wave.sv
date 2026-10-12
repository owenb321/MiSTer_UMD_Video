// umd/xmb_wave.sv -- the idle screen: a PSP XMB-style flowing wave, tinted by month
//
// WHAT IT DRAWS. The PSP's home screen shows a slowly rolling, softly lit wave over a
// vertical gradient, in a colour that changes with the calendar month. This module
// draws that procedurally, per pixel, with NO framebuffer: three summed sines of the
// (h, v) coordinate with slowly advancing phases give the rolling light, a linear
// vertical gradient gives the depth, and a 12-entry ROM gives the month's tint. It
// replaces MiSTer_DVD's bouncing-logo screensaver (dvd/idle_logo.sv) -- there is no
// user-logo upload path here, by decision.
//
// BUDGET IS THE DESIGN (the same discipline as MiSTer_DVD's cdda_viz): no M10K, no
// per-frame state beyond three 16-bit phase accumulators, the sine as a 64-entry
// quarter-wave ROM in logic, every coefficient a shift-add. The three 8x8 tint
// multiplies are the only real arithmetic and Quartus may put them in DSP blocks;
// with 112 on the device and none otherwise used in P0, that is acceptable.
//
// MONTH FROM THE HPS CLOCK. hps_io delivers TIMESTAMP[32:0]: bits 31:0 are UTC seconds
// since 1970-01-01 and bit 32 TOGGLES on each delivery (Main sends it once at core
// load). A small sequential FSM turns that into a month in about 21,000 clk_sys cycles
// (< 1 ms): repeated subtraction of 86400 for the day count, a leap-aware year walk,
// then a cumulative-days walk. ⚠ It keys on a CHANGE of bit 32, never on the value
// being non-zero -- a fresh FPGA reads 0 there and Main's first delivery may leave it 0.
// UTC is an accepted limitation (a month boundary shifts by the user's timezone).
// Until the first delivery, or if none ever comes (a stock Main always sends one),
// DEFAULT_MONTH is used. `month_force` (1..12, 0 = off) overrides for benches and for
// a future OSD preview.
//
// PIPELINE (LAT = 4 clocks from h_pos/v_pos/de_in to r/g/b/de_out):
//   s1: register the three phase-shifted arguments, delay h/v/de
//   s2: quarter-wave sine ROM lookups (registered)
//   s3: sum, gradient, clamp to an 8-bit luminance
//   s4: tint multiply, gate on `vis`, register outputs
// Coordinates follow umd/sync_gen.sv's convention (syncgen's): h_pos = dot index,
// v_pos = line index, both 0 at the first active dot/line.

module xmb_wave #(
    parameter [3:0] DEFAULT_MONTH = 4'd7,      // July: the blue the PSP boots to for many
    parameter       PH_INC0 = 16'd137,         // phase advance per frame, wave 0 (~8 s period)
    parameter       PH_INC1 = 16'd89,          // wave 1 (~12 s)
    parameter       PH_INC2 = 16'd53           // wave 2 (~21 s)
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [11:0] h_pos,
    input  wire [11:0] v_pos,
    input  wire        de_in,
    input  wire        frame_tick,
    input  wire        vis,            // 0 = black (de_out still aligned)
    input  wire [32:0] timestamp,      // hps_io TIMESTAMP
    input  wire  [3:0] month_force,    // 0 = follow the timestamp; 1..12 = force

    output reg   [7:0] r,
    output reg   [7:0] g,
    output reg   [7:0] b,
    output reg         de_out,
    output wire  [3:0] month_o         // the month in use (telemetry / bench)
);

localparam LAT = 4;

// -------------------------------------------------------------------------
// Phase accumulators: one step per frame, so the pattern rolls at a fixed rate
// -------------------------------------------------------------------------
reg [15:0] ph0, ph1, ph2;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ph0 <= 16'd0; ph1 <= 16'd21845; ph2 <= 16'd43690;   // start spread apart
    end else if (frame_tick) begin
        ph0 <= ph0 + PH_INC0;
        ph1 <= ph1 + PH_INC1;
        ph2 <= ph2 + PH_INC2;
    end
end

// -------------------------------------------------------------------------
// s1: the three wave arguments (16-bit, wrapping = one full sine period)
//   wave 0: a long diagonal roll        arg = 40h + 16v + ph0
//   wave 1: a steeper, slower one       arg = 18h + 36v + ph1
//   wave 2: fine horizontal ripple      arg = 64h +  9v + ph2
// All coefficients are shift-adds; h and v are 12-bit so the products fit 18 bits and
// the low 16 bits are kept (wrap is the point).
// -------------------------------------------------------------------------
wire [17:0] h18 = {6'd0, h_pos};
wire [17:0] v18 = {6'd0, v_pos};
wire [17:0] a0_w = (h18 << 5) + (h18 << 3) + (v18 << 4)             + {2'd0, ph0};
wire [17:0] a1_w = (h18 << 4) + (h18 << 1) + (v18 << 5) + (v18 << 2) + {2'd0, ph1};
wire [17:0] a2_w = (h18 << 6)              + (v18 << 3) + v18        + {2'd0, ph2};

reg [15:0] a0_q, a1_q, a2_q;
reg [11:0] v_s1;
reg        de_s1, de_s2, de_s3;
always @(posedge clk) begin
    a0_q <= a0_w[15:0];
    a1_q <= a1_w[15:0];
    a2_q <= a2_w[15:0];
    v_s1 <= v_pos;
    de_s1 <= de_in;
end

// -------------------------------------------------------------------------
// s2: sine via a 64-entry quarter-wave ROM. arg[15:14] = quadrant, arg[13:8] = index.
// Quadrants 1 and 3 read the table mirrored; quadrants 2 and 3 negate. Values are
// round(127*sin(pi/2 * (i+0.5)/64)), so no entry is 0 and the mirror joins cleanly.
// Written as a case in an always block, NOT a function: MiSTer_DVD measured Quartus 17
// silently miscompiling some `function automatic` helpers (sim exact, silicon wrong).
// -------------------------------------------------------------------------
reg signed [7:0] s0_q, s1_q, s2_q;
reg [11:0] v_s2;

// one lookup, shared shape: index mirror by quadrant bit 0, sign by quadrant bit 1
wire [5:0] i0 = a0_q[14] ? ~a0_q[13:8] : a0_q[13:8];
wire [5:0] i1 = a1_q[14] ? ~a1_q[13:8] : a1_q[13:8];
wire [5:0] i2 = a2_q[14] ? ~a2_q[13:8] : a2_q[13:8];
reg  [6:0] m0, m1, m2;

// The quarter-wave magnitude table, instantiated three times as plain case
// statements in one always block -- deliberately NOT a Verilog function (see the
// hazard note above).
`define QW_ROM(IDX, OUT) \
    case (IDX) \
    6'd0:OUT=7'd2;   6'd1:OUT=7'd5;   6'd2:OUT=7'd8;   6'd3:OUT=7'd11;  6'd4:OUT=7'd14;  6'd5:OUT=7'd17;  6'd6:OUT=7'd20;  6'd7:OUT=7'd23; \
    6'd8:OUT=7'd26;  6'd9:OUT=7'd29;  6'd10:OUT=7'd32; 6'd11:OUT=7'd35; 6'd12:OUT=7'd38; 6'd13:OUT=7'd41; 6'd14:OUT=7'd44; 6'd15:OUT=7'd47; \
    6'd16:OUT=7'd50; 6'd17:OUT=7'd53; 6'd18:OUT=7'd56; 6'd19:OUT=7'd59; 6'd20:OUT=7'd61; 6'd21:OUT=7'd64; 6'd22:OUT=7'd67; 6'd23:OUT=7'd69; \
    6'd24:OUT=7'd72; 6'd25:OUT=7'd75; 6'd26:OUT=7'd77; 6'd27:OUT=7'd80; 6'd28:OUT=7'd82; 6'd29:OUT=7'd85; 6'd30:OUT=7'd87; 6'd31:OUT=7'd89; \
    6'd32:OUT=7'd92; 6'd33:OUT=7'd94; 6'd34:OUT=7'd96; 6'd35:OUT=7'd98; 6'd36:OUT=7'd100;6'd37:OUT=7'd102;6'd38:OUT=7'd104;6'd39:OUT=7'd106; \
    6'd40:OUT=7'd108;6'd41:OUT=7'd110;6'd42:OUT=7'd111;6'd43:OUT=7'd113;6'd44:OUT=7'd115;6'd45:OUT=7'd116;6'd46:OUT=7'd118;6'd47:OUT=7'd119; \
    6'd48:OUT=7'd120;6'd49:OUT=7'd121;6'd50:OUT=7'd122;6'd51:OUT=7'd123;6'd52:OUT=7'd124;6'd53:OUT=7'd125;6'd54:OUT=7'd126;6'd55:OUT=7'd126; \
    6'd56:OUT=7'd127;6'd57:OUT=7'd127;6'd58:OUT=7'd127;6'd59:OUT=7'd127;6'd60:OUT=7'd127;6'd61:OUT=7'd127;6'd62:OUT=7'd127;default:OUT=7'd127; \
    endcase

always @* begin
    `QW_ROM(i0, m0)
    `QW_ROM(i1, m1)
    `QW_ROM(i2, m2)
end
`undef QW_ROM

always @(posedge clk) begin
    s0_q <= a0_q[15] ? -$signed({1'b0, m0}) : $signed({1'b0, m0});
    s1_q <= a1_q[15] ? -$signed({1'b0, m1}) : $signed({1'b0, m1});
    s2_q <= a2_q[15] ? -$signed({1'b0, m2}) : $signed({1'b0, m2});
    v_s2 <= v_s1;
    de_s2 <= de_s1;
end

// -------------------------------------------------------------------------
// s3: luminance = base - vertical gradient + wave, clamped to 0..255
//   base 200, gradient v/4 (0..119 over 480 lines), wave = (s0+s1+s2)/4 = -95..+95
// -------------------------------------------------------------------------
wire signed [10:0] wsum = {{3{s0_q[7]}}, s0_q} + {{3{s1_q[7]}}, s1_q} + {{3{s2_q[7]}}, s2_q};
wire signed [10:0] lum_w = 11'sd200 - $signed({4'd0, v_s2[9:2]}) + (wsum >>> 2);
reg [7:0] lum_q;
always @(posedge clk) begin
    lum_q <= lum_w[10]        ? 8'd0   :        // negative
             (lum_w > 11'sd255) ? 8'd255 :
             lum_w[7:0];
    de_s3 <= de_s2;
end

// -------------------------------------------------------------------------
// Month tint ROM. An approximation of the PSP's monthly XMB colours; the bench asserts
// the months are DISTINCT and that the output follows the ROM's per-channel ratios,
// not these exact values -- change them freely.
// -------------------------------------------------------------------------
reg  [3:0] month_q;                 // from the timestamp FSM below
wire [3:0] month_sel = (month_force != 4'd0 && month_force <= 4'd12) ? month_force : month_q;
reg [7:0] tr, tg, tb;
always @* begin
    case (month_sel)
    4'd1:  {tr,tg,tb} = 24'hF0F0F0;   // January   white
    4'd2:  {tr,tg,tb} = 24'hF2C11F;   // February  gold
    4'd3:  {tr,tg,tb} = 24'h7BC96F;   // March     light green
    4'd4:  {tr,tg,tb} = 24'hF5A9C8;   // April     pink
    4'd5:  {tr,tg,tb} = 24'h3FA53C;   // May       green
    4'd6:  {tr,tg,tb} = 24'h8A6BB7;   // June      violet
    4'd7:  {tr,tg,tb} = 24'h4FB4E5;   // July      light blue
    4'd8:  {tr,tg,tb} = 24'h3865C8;   // August    blue
    4'd9:  {tr,tg,tb} = 24'h8E52A5;   // September purple
    4'd10: {tr,tg,tb} = 24'hE88F2A;   // October   orange
    4'd11: {tr,tg,tb} = 24'hA0613C;   // November  brown
    4'd12: {tr,tg,tb} = 24'hD9302E;   // December  red
    default: {tr,tg,tb} = 24'h4FB4E5; // (unreachable: month_sel is always 1..12)
    endcase
end

// -------------------------------------------------------------------------
// s4: tint * luminance, gated on vis
// -------------------------------------------------------------------------
wire [15:0] pr = tr * lum_q;
wire [15:0] pg = tg * lum_q;
wire [15:0] pb = tb * lum_q;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        r <= 8'd0; g <= 8'd0; b <= 8'd0; de_out <= 1'b0;
    end else begin
        r <= (vis && de_s3) ? pr[15:8] : 8'd0;
        g <= (vis && de_s3) ? pg[15:8] : 8'd0;
        b <= (vis && de_s3) ? pb[15:8] : 8'd0;
        de_out <= de_s3;
    end
end

// -------------------------------------------------------------------------
// Month from the HPS timestamp
// -------------------------------------------------------------------------
reg         ts_tgl_q;
reg  [31:0] secs;
reg  [15:0] days;          // days since 1970-01-01 (fits until year 2149)
reg  [11:0] year;
reg  [1:0]  y4;            // (year - 1968) mod 4 -> leap when 0 (with the century rule)
reg  [3:0]  mon;
reg  [2:0]  st;            // 0 idle, 1 days, 2 years, 3 months
localparam ST_IDLE = 3'd0, ST_DAYS = 3'd1, ST_YEARS = 3'd2, ST_MONTHS = 3'd3;

wire leap = (y4 == 2'd0) && !(year == 12'd2100 || year == 12'd2200 || year == 12'd2300);
wire [8:0] ylen = leap ? 9'd366 : 9'd365;
reg  [4:0] mlen;
always @* begin
    case (mon)
    4'd2:  mlen = leap ? 5'd29 : 5'd28;
    4'd4, 4'd6, 4'd9, 4'd11: mlen = 5'd30;
    default: mlen = 5'd31;
    endcase
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        month_q <= DEFAULT_MONTH; ts_tgl_q <= 1'b0; st <= ST_IDLE;
        secs <= 32'd0; days <= 16'd0; year <= 12'd1970; y4 <= 2'd2; mon <= 4'd1;
    end else begin
        case (st)
        ST_IDLE: begin
            ts_tgl_q <= timestamp[32];
            if (timestamp[32] != ts_tgl_q) begin
                secs <= timestamp[31:0]; days <= 16'd0;
                year <= 12'd1970; y4 <= 2'd2;      // 1970 - 1968 = 2
                mon <= 4'd1; st <= ST_DAYS;
            end
        end
        ST_DAYS: begin
            if (secs >= 32'd86400) begin secs <= secs - 32'd86400; days <= days + 16'd1; end
            else st <= ST_YEARS;
        end
        ST_YEARS: begin
            if (days >= {7'd0, ylen}) begin
                days <= days - {7'd0, ylen}; year <= year + 12'd1; y4 <= y4 + 2'd1;
            end else st <= ST_MONTHS;
        end
        ST_MONTHS: begin
            if (days >= {11'd0, mlen} && mon != 4'd12) begin
                days <= days - {11'd0, mlen}; mon <= mon + 4'd1;
            end else begin
                month_q <= mon; st <= ST_IDLE;
            end
        end
        default: st <= ST_IDLE;
        endcase
    end
end

assign month_o = month_sel;

endmodule
