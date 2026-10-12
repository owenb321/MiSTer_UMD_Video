// umd_panel.h -- the control panel (P6d, docs/panel.md): its decisions and its drawing, as pure C (no
// Main dependency, no I/O). The runner (umd_menu_run.c) feeds it every HOST_RD and every grabbed press,
// sends what it returns to the core, publishes its levels and draws it. bench/umd/run_panel.sh drives it
// on the PC against tools/panel_ref.py (the decisions) and tools/panel_layout.py (the pixels).
//
// THE RULES (docs/panel.md §1.1 measured on the PSP, §3.3, §3.4, §8 K1-K16):
//   * The panel button opens it, in playback (any play state) or over a disc menu, never with no title;
//     the cursor starts on Display.
//   * <- / -> walk a row, wrapping; ^ / v go to the adjacent row's nearest available item, wrapping over
//     the three rows (the column kept, clamped; a tie to the left; a row with nothing available skipped).
//     Dark items are skipped.
//   * x does the item: each is its own button's press (HOST_WR's press record), Play is player_ctl's PLAY
//     (no button maps to it), UMD Menu the engine's onMenu, Stop over a disc menu P9-6's quit. The panel
//     stays up, except Stop and UMD Menu, which close it, and Go To, which hides it until the editor has
//     closed and no seek is in flight (two quiet reads; 250 ms if the editor never opens).
//   * o, the panel button, a mount, and a disc menu coming or going close it.
//   * Over a disc menu only UMD Menu, Display and Stop are available; in playback Subtitles is dark
//     without a track and UMD Menu without the engine.
// THE LOOK: tools/panel_layout.py (docs/panel.md §3.5): the HUD-tinted box, the icons and caption in the
// HUD's four pixel classes on premultiplied alpha, the selected icon white over a halo. umd_panel_art.c
// is generated from it; the halo and the box's corners are integer rules recomputed here.
#pragma once

#include <stdint.h>

#include "umd_panel_art.h"

#ifdef __cplusplus
extern "C" {
#endif

// joystick bits: the framework's D-pad, then emu's J1 list (CONF_STR order, B1 = bit 4)
enum { UMD_PB_RIGHT = 0, UMD_PB_LEFT, UMD_PB_DOWN, UMD_PB_UP, UMD_PB_PLAYPAUSE, UMD_PB_PAUSE, UMD_PB_STOP,
       UMD_PB_PREV, UMD_PB_NEXT, UMD_PB_AUDIO, UMD_PB_DISPLAY, UMD_PB_MENU, UMD_PB_SUB, UMD_PB_GOTO,
       UMD_PB_PANEL,
       UMD_PB_AB };                       // A-B Repeat: no J1 button (the keyboard's B), emu's bit 15
#define UMD_PANEL_GRAB_CLOSED  (1u << UMD_PB_PANEL)
#define UMD_PANEL_GRAB_OPEN    (0xFu | (1u << UMD_PB_PAUSE) | (1u << UMD_PB_STOP) | (1u << UMD_PB_PANEL))
#define UMD_PANEL_PC_PLAY      3          // player_ctl's PLAY
#define UMD_PANEL_PC_PAUSE     2          // player_ctl's PAUSE (Select toggles since 2026-10-07: the item stays a pause)
#define UMD_PANEL_PC_AB_CLEAR  0          // the host's code 0: A-B Repeat's CLEAR (ab_ctl's, docs/ab_repeat.md)
#define UMD_PANEL_RETURN_READS 2          // Go To: quiet reads before the panel shows again
#define UMD_PANEL_GOTO_OPEN_MS 250        // ... or this long, if the editor never opened

// what x sends
enum { UMD_PA_PRESS = 1,                  // arg: the press mask (HOST_WR's press record, docs/panel.md F1)
       UMD_PA_CMD,                        // arg: player_ctl's code (HOST_WR's player command)
       UMD_PA_MENU,                       // the engine's onMenu
       UMD_PA_QUIT };                     // P9-6's quit (Stop over a disc menu)
typedef struct { int kind; uint32_t arg; } umd_panel_act;

// how the panel shows (the runner's levels)
enum { UMD_PS_NONE, UMD_PS_UI_SUB,       // in playback: the panel's own planes, the subtitles running (§2)
       UMD_PS_FRAME };                    // over a disc menu: drawn into the engine's frame (§3.4)

// what it reads (a HOST_RD, decoded, and the runner's own state)
typedef struct {
	int state;                            // player_ctl: 0 idle 1 play 2 pause 3 stop
	int seeking;
	int goto_open;                        // F2: Go To's editor is up
	int sub_any;                          // F2: the title has a subtitle track
	int menu_up;                          // a disc menu's page is up (the engine holds ui)
	int engine;                           // the engine runs for this disc (it has an onMenu)
} umd_panel_rd;

typedef struct {
	int          open, hidden, menu_mode, sel;
	umd_panel_rd rd;
	int          g_seen, quiet;           // Go To: the editor seen open since the hide; quiet reads
	uint32_t     g_since, now;            // ms
} umd_panel;

void umd_panel_init(umd_panel *p);
// a HOST_RD at `now` ms (it never sends anything)
void umd_panel_read(umd_panel *p, const umd_panel_rd *rd, uint32_t now);
// a grabbed press (a KEY event's mask; bits taken lowest first): up to `max` actions into `out`, the count
int  umd_panel_key(umd_panel *p, uint32_t mask, umd_panel_act *out, int max);
void umd_panel_levels(const umd_panel *p, uint16_t *grab, int *show);
int  umd_panel_available(const umd_panel *p, int item);
// what the page shows, as one word: the runner redraws when it changes (0: nothing shown)
uint32_t umd_panel_view(const umd_panel *p);

// DRAW the panel OVER px: 720 x 480 premultiplied, `stride` bytes a row, holding what lies under it (the
// subtitle shown, or the engine's frame), in menu.h's MENU_PX_RGBA (bytes R, G, B, A) or MENU_PX_PLANE
// (bytes B, G, R, A) layout. Only the panel's rectangle is touched (umd_panel_rect: the flip's).
enum { UMD_PANEL_PX_RGBA, UMD_PANEL_PX_PLANE };
void umd_panel_draw(const umd_panel *p, uint8_t *px, int stride, int layout);
void umd_panel_rect(int *x, int *y, int *w, int *h);

#ifdef __cplusplus
}
#endif
