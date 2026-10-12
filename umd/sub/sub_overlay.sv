// umd/sub/sub_overlay.sv -- everything the subtitles put on ram2 and on the raster, as one
// instance for emu (docs/compositor.md §8, docs/subtitles.md §2)
//
//   sub_top (the demux's bytes -> the DDR3 ring; A12 SD1: the fabric decodes each unit into
//            a premultiplied plane again, sub_dec.sv answering sub_top's handshake; from A7
//            to SD1 the HPS decoded each unit into a
//            premultiplied plane (A7: the h_* handshake, docs/hps_host.md §3.2);
//            flips / hides on the STC)                                   ddr_mux2 A (writes)
//   sub_flip (the requests latched at vbl) -> plane_reader (1:1)          rd_merge2 Q
//   the video's display reader (disp_reader in emu), through v_*           rd_merge2 P
//   rd_merge2 -> ddr_mux2 #(B_FIRST) B;  ddr_mux2 -> DDRAM2
//   plane_blend: the plane over the video
//
// The video comes in at LAT 4 (disp_reader's) and is delayed one dot to meet the plane
// (LAT 5); the composite leaves at LAT 7. emu's sync, HUD and wave pipelines follow it.
//
// Resets. mrst_n is power-on only: ddr_mux2 and the port must never be reset mid-burst
// (the controller waits for every beat of a write burst it accepted). A mount, a seek or
// a track change is `flush` (mclk, a pulse): sub_top drops what it holds but lets a DDR3
// burst already on the port finish, and hides the plane. ddr_mux2's abort is therefore
// tied off here -- nothing in this instance leaves a burst open.
// The menu plane (P9) is this same plane, handed to the host (`ui`, sub_flip). P9's sound
// one-shot (umd/pcm_shot.sv) is a third READER on ram2, the lowest: a second rd_merge2 behind
// the raster readers' (x_*), so the video and the plane keep their line deadlines.

`default_nettype none

module sub_overlay #(
    parameter logic [28:0] RING_BASE = 29'h0640_0000,
    parameter int          RAW       = 20,
    parameter int          MAW       = 6,
    parameter logic [28:0] PLANE0    = 29'h0650_0000,
    parameter logic [28:0] PLANE1    = 29'h0658_0000,
    parameter logic [28:0] PLANE2    = 29'h0670_0000,     // P6d: the panel's pages (docs/panel.md §2)
    parameter logic [28:0] PLANE3    = 29'h0678_0000,
    parameter bit          FABRIC_DEC = 1'b1           // A12 SD1: the decode in the fabric (sub_top)
) (
    // the demux (sclk)
    input  wire         sclk,
    input  wire         srst_n,
    input  wire  [7:0]  sp_byte,
    input  wire         sp_valid,
    input  wire         sp_frame_start,
    input  wire  [32:0] sp_pts,
    input  wire         sp_pts_valid,

    // png_top's clock (FABRIC_DEC: clk_sys in emu, as before A7)
    input  wire         pclk,

    // the DDR3 side (mclk)
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         flush,
    input  wire  [32:0] stc,
    input  wire         stc_valid,
    // the video's display reader (rd_merge2's P: first)
    input  wire  [28:0] v_address,
    input  wire  [7:0]  v_burstcount,
    input  wire         v_read,
    output logic        v_waitrequest,
    output logic [63:0] v_readdata,
    output logic        v_readdatavalid,
    // DDRAM2
    output logic [28:0] ddr_address,
    output logic [7:0]  ddr_burstcount,
    output logic        ddr_read,
    output logic        ddr_write,
    output logic [63:0] ddr_writedata,
    output logic [7:0]  ddr_byteenable,
    input  wire         ddr_waitrequest,
    input  wire  [63:0] ddr_readdata,
    input  wire         ddr_readdatavalid,

    // the raster (clk)
    input  wire         clk,
    input  wire         rst_n,
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         il,                 // the 480i raster (docs/analog.md)
    input  wire         de_in,
    input  wire         vbl,                // a strobe in the vertical blank (h_pos 0 of line 500)
    input  wire         zoom,               // fj#71 Zoom in force (zoom_ctl: changes at this vbl; docs/zoom.md)
    input  wire  [7:0]  vid_r,              // the video, LAT 4
    input  wire  [7:0]  vid_g,
    input  wire  [7:0]  vid_b,
    output logic [7:0]  out_r,              // the composite, LAT 7
    output logic [7:0]  out_g,
    output logic [7:0]  out_b,

    // the host (mclk; sub_top's handshake, umd_host carries it to EXT_BUS)
    output logic        h_req,
    output logic [7:0]  h_seq,
    output logic        h_buf,
    output logic [15:0] h_x,
    output logic [15:0] h_y,
    output logic [RAW-1:0] h_start,
    output logic [31:0] h_len,
    output logic [7:0]  h_gen,
    output logic        h_vis,
    output logic [7:0]  h_shown_seq,
    output logic        h_sbuf,             // A12 SD2: the shown unit's plane and rectangle (the panel's
    output logic [15:0] h_sx,               //   compositor reads it back: docs/nav_engine.md §10)
    output logic [15:0] h_sy,
    output logic [15:0] h_sw,
    output logic [15:0] h_sh,
    input  wire         h_done,
    input  wire  [7:0]  h_done_seq,
    input  wire  [4:0]  h_done_err,
    input  wire  [15:0] h_done_w,
    input  wire  [15:0] h_done_h,

    // counters (sclk: in_*; clk: n_flips, geo_bad; the rest mclk)
    output logic [15:0] in_lost,
    output logic [15:0] in_pts_lost,
    output logic [15:0] n_units,
    output logic [15:0] n_truncated,
    output logic [15:0] n_overrun,
    output logic [15:0] n_orphan,
    output logic [15:0] n_lost,
    output logic [15:0] n_ring_full,
    output logic [15:0] n_badhdr,
    output logic [15:0] n_oddfield,
    output logic [15:0] n_shown,
    output logic [15:0] n_late,
    output logic [15:0] n_missed,
    output logic [15:0] n_refused,
    output logic [15:0] n_stale,            // host completions ignored (mclk)
    output logic [15:0] n_line_late,        // plane lines requested during a fetch (mclk)
    output logic [15:0] n_flips,            // requests latched (clk)
    output logic        geo_bad,            // the plane's geometry refused (clk; never, at 1:1)

    // P9: the plane hand-over to the host (clk: umd_host's levels and held flip; sub_flip)
    input  wire         ui,
    input  wire         ui_sub,                         // P6d: the host's, the subtitles still running
    input  wire         hf_req,
    input  wire  [1:0]  hf_buf,
    input  wire         hf_vis,
    input  wire  [15:0] hf_x,
    input  wire  [15:0] hf_y,
    input  wire  [15:0] hf_w,
    input  wire  [15:0] hf_h,
    output logic        hf_ack,

    // P9: the sound one-shot's reader (mclk; rd_merge2's Q behind the raster readers)
    input  wire  [28:0] x_address,
    input  wire  [7:0]  x_burstcount,
    input  wire         x_read,
    output logic        x_waitrequest,
    output logic [63:0] x_readdata,
    output logic        x_readdatavalid
);

    // ---- the subtitles into DDR3 ------------------------------------------------------------------------
    logic        d_req, d_buf, d_vis, d_ack;
    logic [15:0] d_x, d_y, d_w, d_h;
    logic [28:0] a_address;
    logic [7:0]  a_burstcount, a_byteenable;
    logic        a_read, a_write, a_waitrequest;
    logic [63:0] a_writedata;
    logic        a_readdatavalid;               // the decoder's ring reads (FABRIC_DEC)
    logic [63:0] a_readdata;
    sub_top #(.RING_BASE (RING_BASE), .RAW (RAW), .MAW (MAW), .FABRIC_DEC (FABRIC_DEC),
              .PLANE0 (PLANE0), .PLANE1 (PLANE1)) u_sub (
        .sclk, .srst_n, .sp_byte, .sp_valid, .sp_frame_start, .sp_pts, .sp_pts_valid,
        .pclk, .mclk, .mrst_n, .flush, .stc, .stc_valid,
        .d_req, .d_buf, .d_vis, .d_x, .d_y, .d_w, .d_h, .d_ack,
        .h_req, .h_seq, .h_buf, .h_x, .h_y, .h_start, .h_len, .h_gen, .h_vis, .h_shown_seq,
        .h_sbuf, .h_sx, .h_sy, .h_sw, .h_sh,
        .h_done, .h_done_seq, .h_done_err, .h_done_w, .h_done_h,
        .ddr_address (a_address), .ddr_burstcount (a_burstcount), .ddr_read (a_read), .ddr_write (a_write),
        .ddr_writedata (a_writedata), .ddr_byteenable (a_byteenable), .ddr_waitrequest (a_waitrequest),
        .ddr_readdata (a_readdata), .ddr_readdatavalid (a_readdatavalid), .n_clipped (),
        .in_lost, .in_pts_lost, .n_units, .n_truncated, .n_overrun, .n_orphan, .n_lost, .n_ring_full,
        .n_badhdr, .n_oddfield, .n_shown, .n_late, .n_missed, .n_refused, .n_stale
    );

    // ---- the flips, at the vertical blank ----------------------------------------------------------------
    logic        f_vis;
    logic [28:0] f_base;
    logic [9:0]  f_x, f_w;
    logic [8:0]  f_y, f_h;
    sub_flip #(.PLANE0 (PLANE0), .PLANE1 (PLANE1), .PLANE2 (PLANE2), .PLANE3 (PLANE3)) u_flip (
        .mclk, .mrst_n, .d_req, .d_buf, .d_vis, .d_x, .d_y, .d_w, .d_h, .d_ack,
        .clk, .rst_n, .vbl, .vis (f_vis), .base (f_base), .x (f_x), .y (f_y), .w (f_w), .h (f_h), .n_flips,
        .ui, .ui_sub, .hf_req, .hf_buf, .hf_vis, .hf_x, .hf_y, .hf_w, .hf_h, .hf_ack
    );

    // ---- fj#71 Zoom (docs/zoom.md Z3): the subtitle moved inside the band the scaler shows -------------------
    // Under Zoom only raster lines 60 .. 419 reach the screen: the fabric's subtitle is placed at
    // y clamped to [60, 420 - h] (moved, never cut), one taller than the band at 60 and bounded to its
    // 360 lines (dh; the source rows from sy as before). Not the host's plane (the panel's or a menu's
    // page, which the UMD Main places itself): who owns the plane is taken at the vbl the flip and
    // `zoom` use, so the three change together. Combinational on the flip's latched geometry (a
    // register at the same vbl would take the previous rectangle).
    logic        f_host;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)   f_host <= 1'b0;
        else if (vbl) f_host <= ui | ui_sub;
    end
    wire         z_on   = zoom && !f_host;
    wire  [9:0]  z_bot  = {1'b0, f_y} + {1'b0, f_h};
    wire         z_tall = (f_h > 9'd360);
    wire  [8:0]  z_dy   = !z_on ? f_y :
                          (z_tall || f_y < 9'd60) ? 9'd60 :
                          (z_bot > 10'd420) ? 9'd420 - f_h : f_y;
    wire  [8:0]  z_dh   = (z_on && z_tall) ? 9'd360 : f_h;

    // ---- the plane on the raster (1:1: the source rectangle is the destination) -----------------------------
    logic [7:0]  p_a, p_r, p_g, p_b;
    logic [28:0] q_address;
    logic [7:0]  q_burstcount;
    logic        q_read, q_waitrequest, q_readdatavalid;
    logic [63:0] q_readdata;
    plane_reader #(.SCALE (1'b0)) u_plane (          // 1:1 (docs/area_plan.md A3)
        .clk, .rst_n, .h_pos, .v_pos, .il, .de_in,
        .vis (f_vis), .base (f_base), .sx (f_x), .sy (f_y), .sw (f_w), .sh (f_h),
        .dx (f_x), .dy (z_dy), .dw (f_w), .dh (z_dh),
        .hstep (26'h001_0000), .vstep (26'h001_0000), .hstart (28'd0), .vstart (28'd0), .geo_bad,
        .a (p_a), .r (p_r), .g (p_g), .b (p_b),
        .mclk, .mrst_n, .ddr_address (q_address), .ddr_burstcount (q_burstcount), .ddr_read (q_read),
        .ddr_waitrequest (q_waitrequest), .ddr_readdata (q_readdata), .ddr_readdatavalid (q_readdatavalid),
        .n_late (n_line_late)
    );

    // ---- ram2 ---------------------------------------------------------------------------------------------
    logic [28:0] r_address;
    logic [7:0]  r_burstcount;
    logic        r_read, r_waitrequest, r_readdatavalid;
    logic [63:0] r_readdata;
    rd_merge2 u_merge (
        .clk (mclk), .rst_n (mrst_n),
        .p_address (v_address), .p_burstcount (v_burstcount), .p_read (v_read), .p_waitrequest (v_waitrequest),
        .p_readdata (v_readdata), .p_readdatavalid (v_readdatavalid),
        .q_address, .q_burstcount, .q_read, .q_waitrequest, .q_readdata, .q_readdatavalid,
        .m_address (r_address), .m_burstcount (r_burstcount), .m_read (r_read), .m_waitrequest (r_waitrequest),
        .m_readdata (r_readdata), .m_readdatavalid (r_readdatavalid)
    );
    // P9: the sound one-shot behind the raster readers
    logic [28:0] b_address;
    logic [7:0]  b_burstcount;
    logic        b_read, b_waitrequest, b_readdatavalid;
    logic [63:0] b_readdata;
    rd_merge2 u_merge_x (
        .clk (mclk), .rst_n (mrst_n),
        .p_address (r_address), .p_burstcount (r_burstcount), .p_read (r_read), .p_waitrequest (r_waitrequest),
        .p_readdata (r_readdata), .p_readdatavalid (r_readdatavalid),
        .q_address (x_address), .q_burstcount (x_burstcount), .q_read (x_read), .q_waitrequest (x_waitrequest),
        .q_readdata (x_readdata), .q_readdatavalid (x_readdatavalid),
        .m_address (b_address), .m_burstcount (b_burstcount), .m_read (b_read), .m_waitrequest (b_waitrequest),
        .m_readdata (b_readdata), .m_readdatavalid (b_readdatavalid)
    );
    ddr_mux2 #(.B_FIRST (1'b1)) u_mux (
        .clk (mclk), .rst_n (mrst_n),
        .a_address, .a_burstcount, .a_read, .a_write, .a_writedata, .a_byteenable, .a_abort (1'b0),
        .a_waitrequest, .a_readdata, .a_readdatavalid,
        .b_address, .b_burstcount, .b_read, .b_waitrequest, .b_readdata, .b_readdatavalid,
        .b_write(1'b0), .b_writedata(64'd0),   // B reads only here (main gave B writes for the vbuf)
        .ddr_address, .ddr_burstcount, .ddr_read, .ddr_write, .ddr_writedata, .ddr_byteenable,
        .ddr_waitrequest, .ddr_readdata, .ddr_readdatavalid
    );

    // ---- the plane over the video ------------------------------------------------------------------------
    logic [7:0] v5_r, v5_g, v5_b;          // the video, LAT 4 -> 5
    always_ff @(posedge clk) begin
        v5_r <= vid_r; v5_g <= vid_g; v5_b <= vid_b;
    end
    plane_blend u_blend (
        .clk, .s_a (p_a), .s_r (p_r), .s_g (p_g), .s_b (p_b), .d_r (v5_r), .d_g (v5_g), .d_b (v5_b),
        .r (out_r), .g (out_g), .b (out_b)
    );

endmodule

`default_nettype wire
