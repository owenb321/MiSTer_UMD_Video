// umd/sync_gen.sv -- the core's raster: 720x480 progressive at 27 MHz (CEA-861 480p timing)
//
// Inherited verbatim from MiSTer_UMD_Video (umd/sync_gen.sv). It keeps MiSTer_DVD's
// syncgen coordinate convention, which every overlay and display module harvested from
// those projects consumes:
//
//   h_pos  = dot index within the line, 0..H_TOTAL-1, 0 at the first active dot
//   v_pos  = line index within the frame, 0..V_TOTAL-1, 0 at the first active line
//   in interlaced mode v_pos = {v_cntr[10:0], ~odd_field}: even numbers on the odd
//   field, odd numbers on the even field (syncgen.v:415-426) -- v_pos is the FRAME line.
//
// Interlaced (P6, docs/analog.md: 480i on the 27 MHz clock with pixel repetition, the
// CEA 720(1440)x480i shape, one raster for HDMI and the analog pins) -- MiSTer_DVD's
// "N64 model", proven on real CRTs there (rtl/mpeg2/syncgen.v, its DVD-FORK notes):
//   H: every progressive horizontal value doubled -- 1440 active, 32 front porch, 124
//      sync, 120 back porch = 1716 dots (15.734 kHz); h_pos counts DOTS (0..1715), a
//      pixel is two dots, ce_pix marks the first of each pair (CE_PIXEL).
//   V: per field 240 active lines, vsync window lines [244, 247); the fields' totals
//      ALTERNATE, 262 and 263 lines, and the longer field samples its vsync window at
//      the half-line (dot 858), the shorter at dot 0 -- vsync edges exactly 262.5 lines
//      apart every field, the 2:1 interlace a CRT locks to, and 525 x 1716 = 900,900
//      dots a frame = exactly 29.97 frames / 59.94 fields a second (equal 262-line
//      fields would run 0.19 % fast). WHICH field is the short, line-aligned one is
//      umd/field_polarity.vh's FIELD1_VPOS (SMPTE field 1 = the v_pos-ODD field, set on
//      a hardware measurement in DVD -- one constant shared with csync_smpte.sv).
//   frame_tick marks the first active dot of every FIELD (a field is a refresh);
//   `field` = v_pos[0] (1 = the v_pos-odd field): VGA_F1, 0 on the top field, what
//   ascal's Weave needs (DVD issue #41).
//   A change of `interlaced` restarts the counters at the top field's first dot.
//   A 576-line PAL raster is a later step (docs/analog.md).
//
// Timing (CEA-861-D 720x480p, 27.000 MHz):
//   H: 720 active, 16 front porch, 62 sync, 60 back porch  = 858 dots   (15.734 kHz)
//   V: 480 active,  9 front porch,  6 sync, 30 back porch  = 525 lines  (59.94 Hz)
// Sync pulses are emitted ACTIVE-HIGH; sys_top's sync_fix block normalises polarity
// before the pins, and hps_io measures the raster from DE and the sync edges.
//
// Latency: every output is registered once from the counters. h_pos/v_pos are aligned
// with pixel_en (the dot they describe is the dot pixel_en is high for).

`include "umd/field_polarity.vh"

module sync_gen #(
    parameter H_ACTIVE = 720,
    parameter H_FP     = 16,
    parameter H_SYNC   = 62,
    parameter H_BP     = 60,
    parameter V_ACTIVE = 480,
    parameter V_FP     = 9,
    parameter V_SYNC   = 6,
    parameter V_BP     = 30
)(
    input  wire        clk,
    input  wire        clk_en,       // 1 = every clock is a dot
    input  wire        rst_n,
    input  wire        interlaced,   // 1 = the 480i raster (pixel repetition, fields)

    output reg  [11:0] h_pos,        // the dot (interlaced: 0..1715, a pixel is two dots)
    output reg  [11:0] v_pos,        // the frame line (interlaced: {field line, ~odd_field})
    output reg         pixel_en,     // active picture area (DE)
    output reg         h_sync,
    output reg         v_sync,
    output reg         h_blank,
    output reg         v_blank,
    output reg         frame_tick,   // one clk_en at the first active dot of a frame (interlaced: of a field)
    output reg         field,        // interlaced: v_pos[0] (VGA_F1); 0 in progressive
    output reg         ce_pix        // the dot starts a pixel (CE_PIXEL): always 1 in progressive
);

localparam H_TOTAL = H_ACTIVE + H_FP + H_SYNC + H_BP;   // 858
localparam V_TOTAL = V_ACTIVE + V_FP + V_SYNC + V_BP;   // 525
// the interlaced (480i) raster: horizontal values doubled (pixel repetition), per field
localparam IH_ACTIVE = 2 * H_ACTIVE;                     // 1440
localparam IH_SS     = 2 * (H_ACTIVE + H_FP);            // 1472: hsync start
localparam IH_SE     = 2 * (H_ACTIVE + H_FP + H_SYNC);   // 1596: hsync end
localparam IH_TOTAL  = 2 * H_TOTAL;                      // 1716
localparam IH_HALF   = H_TOTAL;                          // 858: the half-line dot
localparam IV_ACTIVE = 240;
localparam IV_VS     = 244;                              // the vsync window [244, 247)
localparam IV_VE     = 247;
localparam IV_SHORT  = 262;                              // field 1's total; the other field 263

reg [11:0] h_cnt;   // 0..total-1, 0 = first active dot
reg [11:0] v_cnt;   // progressive: 0..V_TOTAL-1; interlaced: the field line, 0 = first active
reg        il_q;    // the mode the counters run in
reg        odd_field;                                    // 1: the field scanning v_pos-EVEN lines (top)
reg        vs_il;   // the interlaced vsync, sampled once a line at the field's reference dot

wire field1 = ((~odd_field) == `FIELD1_VPOS);           // this field is SMPTE field 1 (short, line-aligned)
wire h_last = il_q ? (h_cnt == IH_TOTAL - 1) : (h_cnt == H_TOTAL - 1);
wire v_last = il_q ? (v_cnt == (field1 ? IV_SHORT - 1 : IV_SHORT)) : (v_cnt == V_TOTAL - 1);
wire mode_chg = (interlaced != il_q);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_cnt <= 12'd0;
        v_cnt <= 12'd0;
        il_q <= 1'b0;
        odd_field <= 1'b1;
    end else if (clk_en) begin
        if (mode_chg) begin
            // a clean restart in the new mode, at the top field's first dot
            il_q <= interlaced;
            h_cnt <= 12'd0;
            v_cnt <= 12'd0;
            odd_field <= 1'b1;
        end else begin
            h_cnt <= h_last ? 12'd0 : h_cnt + 12'd1;
            if (h_last) begin
                v_cnt <= v_last ? 12'd0 : v_cnt + 12'd1;
                if (v_last && il_q) odd_field <= ~odd_field;
            end
        end
    end
end

// Decoded from the counters, registered once so the outputs share one edge.
wire h_act  = il_q ? (h_cnt < IH_ACTIVE) : (h_cnt < H_ACTIVE);
wire v_act  = il_q ? (v_cnt < IV_ACTIVE) : (v_cnt < V_ACTIVE);
wire hs_now = il_q ? ((h_cnt >= IH_SS) && (h_cnt < IH_SE))
                   : ((h_cnt >= H_ACTIVE + H_FP) && (h_cnt < H_ACTIVE + H_FP + H_SYNC));
wire vs_now = (v_cnt >= V_ACTIVE + V_FP) && (v_cnt < V_ACTIVE + V_FP + V_SYNC);
// interlaced vsync: the window sampled at the field's reference dot (dot 0 on field 1,
// the half-line on the other) -- DVD's "CRT vsync sampler"
wire [11:0] vs_ref  = field1 ? 12'd0 : IH_HALF;
wire        vs_il_n = (h_cnt == vs_ref) ? ((v_cnt >= IV_VS) && (v_cnt < IV_VE)) : vs_il;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        h_pos <= 12'd0; v_pos <= 12'd0;
        pixel_en <= 1'b0; h_sync <= 1'b0; v_sync <= 1'b0;
        h_blank <= 1'b1; v_blank <= 1'b1; frame_tick <= 1'b0; field <= 1'b0; ce_pix <= 1'b1;
        vs_il <= 1'b0;
    end else if (clk_en) begin
        vs_il      <= il_q ? vs_il_n : 1'b0;
        h_pos      <= h_cnt;
        v_pos      <= il_q ? {v_cnt[10:0], ~odd_field} : v_cnt;
        pixel_en   <= h_act & v_act;
        h_sync     <= hs_now;
        v_sync     <= il_q ? vs_il_n : vs_now;
        h_blank    <= ~h_act;
        v_blank    <= ~v_act;
        // (not in a restart's own cycle: the counters are already at 0 there and stay at 0
        // into the next, which would tick twice -- a spurious refresh at every mode switch)
        frame_tick <= (h_cnt == 12'd0) && (v_cnt == 12'd0) && !mode_chg;
        field      <= il_q & ~odd_field;
        ce_pix     <= il_q ? ~h_cnt[0] : 1'b1;
    end else begin
        frame_tick <= 1'b0;
    end
end

endmodule
