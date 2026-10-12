// umd_disc_screen.h -- R5, the disc screen (docs/resume.md §6): the page the UMD Main shows while a disc
// is stopped and no menu engine runs -- the disc's XMB art (UMD_VIDEO/PIC1.PNG over the whole page,
// ICON0.PNG on a card), its title and the Play line -- as the PSP's XMB shows an inserted UMD.
// Pure C, pixel-exact against tools/disc_screen_layout.py's page() (the approved mockups' card, R5e),
// benched by bench/umd/run_disc_screen.sh.
//
// THE PAGE (720 x 480, premultiplied, plane_blend's rounding: umd_panel.c's arithmetic):
//   * PIC1 scaled bilinear (umd_ds_scale: 16.16 source steps, 8-bit weights) into the fit's target --
//     the whole raster, or the 4:3 CRT's Letterbox (720 x 360 at line 60) or Crop (the centre 640 of the
//     854-wide scene) -- the menus' fit (analog.md S7, umd_mh_fit). Nothing behind it (R5a revised: black).
//   * the card: a rounded box in the HUD's tint (the panel's), 612 x 118 at (54, 260), above the
//     transport HUD's line; ICON0 at 144 x 94 inside it (2/3 of the PSP's proportions on a 16:9 raster),
//     the title (two lines, word-wrapped, "..." past them) and the Play line in the HUD's font.
//   * A missing PIC1 or ICON0 is left out (Now That's What I Call Music 2006 has no ICON0: the title takes
//     its place). An image past UMD_DS_MAX_SIDE a side is refused by the caller (umd_menu_run.c).
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_DS_W 720
#define UMD_DS_H 480
#define UMD_DS_MAX_SIDE 4096                     // a decoded PIC1 / ICON0 side, at most (resume.md §6)
#define UMD_DS_TITLE_MAX 129                     // PARAM.SFO's TITLE: 128 bytes + NUL

// a decoded image: straight (not premultiplied) RGBA8, row-major, w x h
typedef struct { const uint8_t *rgba; int w, h; } umd_ds_img;

// the card's geometry (the golden's)
#define UMD_DS_BOX_X 54
#define UMD_DS_BOX_W 612
#define UMD_DS_PAD 12
#define UMD_DS_ICON_W 144
#define UMD_DS_ICON_H 94
#define UMD_DS_BOX_H (UMD_DS_ICON_H + 2 * UMD_DS_PAD)
#define UMD_DS_BOX_Y (378 - UMD_DS_BOX_H)

// THE ART'S COLOURS AS STORED (the rig, 2026-10-07): 58 of the library's 84 PIC1s and most ICON0s carry
// gAMA / cHRM / iCCP (Akira's gAMA 55531, a Mac's 1/1.8), and libpng's simplified API converts such a file
// to sRGB -- Akira's mid-tones up to 12 levels brighter than the PSP shows them. The PSP's XMB shows the
// stored values; so the page is drawn from them: the colour chunks (gAMA, cHRM, sRGB, iCCP -- ancillary,
// no other chunk depends on them) are dropped in place before the decode. Returns the chunks dropped,
// -1 not a PNG (left as it is)
int  umd_ds_png_plain(uint8_t *png, size_t *n);
// PARAM.SFO's TITLE (UTF-8) -> out (NUL-terminated); 0 found, -1 none / a malformed file
int  umd_ds_sfo_title(const uint8_t *sfo, size_t n, char *out, size_t cap);
// the title the HUD's font can draw: the SFO title with fullwidth ASCII (U+FF01-FF5E) folded and U+2122
// as "TM", if every character is then printable ASCII; else the image's file name without its extension
// (and its directories); "" when both are empty
void umd_ds_display_title(const char *sfo_title, const char *image_name, char *out, size_t cap);
// the Play line: "> Resume H:MM:SS" (have a point, ms from the title's start) or "> Play"
void umd_ds_hint(char *out, size_t cap, int resume, uint32_t ms);
// the page into px (UMD_DS_W x UMD_DS_H x 4, stride bytes a row), cleared first; layout as the panel's
// (UMD_PANEL_PX_RGBA / UMD_PANEL_PX_PLANE); fit as umd_mh_fit's (0 the whole raster, 1 Letterbox,
// 2 Crop); pic1 / icon0 NULL when missing
void umd_ds_draw(uint8_t *px, int stride, int layout, const umd_ds_img *pic1, const umd_ds_img *icon0,
                 const char *title, const char *hint, int fit);

#ifdef __cplusplus
}
#endif
