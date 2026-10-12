// umd/zoom_ctl.sv -- Zoom (Forgejo fj#71, docs/zoom.md): a letterboxed 4:3 title filling a 16:9
// screen, on clk_sys beside the raster.
//
// THE CROP: Aspect Ratio's fourth value. While it is live the 480p raster's active lines are only
// ZOOM_Y0 .. ZOOM_Y1 - 1 (60 .. 419: the middle 3/4) and emu presents 16:9 -- 4 * 480 : 3 * 360 is
// 16 : 9 exactly, so the band keeps the picture's geometry. ascal captures by DE (sys_top's
// hde_emu), so emu drops DE outside the band (`cut`) and the HDMI scaler fills the screen from it;
// emu blanks the cut lines' RGB too (Z5: the analog pins are not DE-gated in sys_top). The raster is
// always 720 x 480 here, so the window is a constant: sys/video_freak.sv, which measures the frame's
// lines and rescales the aspect with a multiplier, would re-derive what is known (docs/zoom.md §2).
//
// LIVE (Z1-Z2, the maintainer 2026-10-09) when Aspect Ratio is Zoom (`sel`) and a 720 x 480 4:3
// picture is playing: not on the 480i raster (`il`: a CRT has Analog Aspect), not under a disc menu
// (`host_menu`: a menu is 16:9), not with no media, not stopped (`stopped`: the wave or the disc
// screen shows over the held picture -- NOT host_ui, which the control panel raises too), not on a
// 16:9 or undeclared picture (`pic_wide`, aspect_vui's, unknown = 16:9 as Auto), not on a picture of
// another size (aa_live's 45 x 30 MBs). Otherwise Zoom behaves as Auto.
//
// `zoom` changes only at `vbl` (a strobe in the vertical blank, the one sub_overlay's flips use),
// so DE, VIDEO_ARX / ARY and the subtitle plane's clamp change together between frames. `cut` is
// combinational on v_pos (LAT 0; emu delays it with DE).
//
// A seek, a chapter or trick play does not toggle it: disp_ctl's shown-picture record (sh_valid,
// sh_w / sh_hf, the aspect) is reset by the mount alone.

`default_nettype none

module zoom_ctl #(
    parameter logic [11:0] ZOOM_Y0 = 12'd60,    // the first raster line kept
    parameter logic [11:0] ZOOM_Y1 = 12'd420    // the first line past the band
) (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         sel,                    // Aspect Ratio = Zoom (status[2:1] == 3)
    input  wire         il,                     // the 480i raster
    input  wire         media_seen,
    input  wire         stopped,                // player_ctl's idle screen (STOP)
    input  wire         host_menu,              // a disc menu is up (P9)
    input  wire         sh_valid,               // the shown picture's record (disp_ctl)
    input  wire         pic_wide,               // ... 16:9 or undeclared
    input  wire  [7:0]  sh_w,                   // ... its width in MBs
    input  wire  [7:0]  sh_hf,                  // ... its frame height in MBs
    input  wire         vbl,
    input  wire  [11:0] v_pos,
    output logic        zoom,                   // in force (latched at vbl)
    output logic        cut                     // this line is outside the band
);

    wire live = sel && !il && media_seen && !stopped && !host_menu && sh_valid && !pic_wide &&
                sh_w == 8'd45 && sh_hf == 8'd30;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)   zoom <= 1'b0;
        else if (vbl) zoom <= live;
    end

    assign cut = zoom && (v_pos < ZOOM_Y0 || v_pos >= ZOOM_Y1);

endmodule

`default_nettype wire
