// panel_run_check.c -- bench/umd/run_panel.sh's [run] stage (P6d C4, docs/panel.md §3.3): the control panel
// inside the UMD Main's runner (main/support/umd/umd_menu_run.c), with no disc (the panel must work without
// the engine: Disc Menus Off, a disc without menus). HOST_RDs and KEY events are fed as the glue feeds them;
// the services record what the runner does to the planes; the logic's queues show what it sends the core.
// Every expectation is written here from docs/panel.md, not taken from the runner.
//   [levels]  closed: the panel button grabbed, no ui_sub; open: the D-pad, x, o and its button, ui_sub
//   [route]   a grabbed D-pad press moves the panel's cursor (it is the panel's while it grabs it)
//   [act]     x on Next: a press record of Next's bit; on Play: player_ctl's PLAY (a command, code 3)
//   [page]    the first page: plane 2, the subtitle's plane read back at its rectangle, the page written and
//             flipped as the union of the panel's box and the subtitle; nothing redrawn without a change;
//             a new subtitle redraws into plane 3; a subtitle not known draws the box alone; a re-open draws
//   [close]   o closes it: no ui_sub, nothing drawn
//   [zoom]    fj#71 (docs/zoom.md Z3): with Zoom in force (HOST_RD AUDIO[10]) the subtitle under the panel is placed
//             as the fabric places its own -- y clamped to [60, 420 - h], at most 360 rows from 60 -- its old rows
//             cleared, the page's rectangle inside the band; a change of Zoom alone redraws the page
// PASS marker "PASS: panel_run_check"; any failure prints "FAIL [arm] ..." and exits 1.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "umd_menu_run.h"

static int fails = 0;
#define FAIL(arm, ...) do { printf("FAIL [%s] ", arm); printf(__VA_ARGS__); printf("\n"); fails++; } while (0)

// ---- the services: a subtitle unit's place, the planes' traffic ----
static int known = 1;                       // sub_unit answers
static int n_get, n_put, get_buf, get_x, get_y, get_w, get_h, put_buf, put_x, put_y, put_w, put_h;
static uint8_t sub_pixel[4] = { 0x11, 0x22, 0x33, 0x44 };
static int s_sub_unit(void *ud, uint8_t seq, int *buf, int *x, int *y, int *w, int *h)
{
	(void)ud;
	if (!known) return -1;
	*buf = seq & 1; *x = 156; *y = 379; *w = 410; *h = 70;     // Akira's unit 0x80 (subtitles.md)
	return 0;
}
static void s_plane_get(void *ud, int buf, int x, int y, int w, int h, uint8_t *frame)
{
	(void)ud;
	n_get++; get_buf = buf; get_x = x; get_y = y; get_w = w; get_h = h;
	for (int yy = y; yy < y + h; yy++)
		for (int xx = x; xx < x + w; xx++) memcpy(frame + ((size_t)yy * UMD_MR_W + (size_t)xx) * 4, sub_pixel, 4);
}
static uint8_t last_page[UMD_MR_W * UMD_MR_H * 4];
static void s_plane_put_rect(void *ud, int buf, const uint8_t *frame, int x, int y, int w, int h)
{
	(void)ud;
	n_put++; put_buf = buf; put_x = x; put_y = y; put_w = w; put_h = h;
	memcpy(last_page, frame, sizeof(last_page));
}

static umd_menu_state L;
static umd_menu_run R;
static uint32_t now = 1000;

// A12 SD2: a core that decodes reports the shown unit's plane and rectangle (core_rect: on)
static int core_rect = 0, cr_buf, cr_x, cr_y, cr_w, cr_h;
static int zoom_rd = 0;                     // fj#71: HOST_RD AUDIO[10]
static void rd(int state, int sub_vis, int seq)
{
	umd_menu_rd r;
	memset(&r, 0, sizeof(r));
	r.magic = r.proto_ok = r.nwords_ok = r.host_ok = 1;
	r.state = state; r.shown = 1; r.sub_any = 1; r.sub_vis = sub_vis; r.sub_seq = (uint8_t)seq;
	r.sub_rect_v = core_rect;
	r.sub_buf = cr_buf; r.sub_x = cr_x; r.sub_y = cr_y; r.sub_w = cr_w; r.sub_h = cr_h;
	r.zoom = zoom_rd;
	now += 10;
	umd_mr_tick(&R, now);
	umd_mr_feed(&R, &r, NULL, 0);
}
static void key(uint32_t mask)
{
	umd_menu_event e = { UMD_ME_KEY, mask, 0 };   // (gen: fj#76's play_gen, unused by a KEY)
	umd_mr_feed(&R, NULL, &e, 1);
}
static void levels(umd_menu_levels *lv) { umd_mr_levels(&R, lv); }
// the core took the flip (the logic's channel drained, as its echo would)
static void core_took(void) { L.n_flip = 0; L.flip_busy = 0; }
// one render round, as the glue's worker: -1 nothing drawn
static int render(void)
{
	umd_menu_levels lv;
	levels(&lv);
	int b = umd_mr_panel_want(&R);
	if (b < 0) return -1;
	umd_mr_panel_frame(&R, b);
	umd_mr_panel_flip(&R, b);
	return b;
}

int main(void)
{
	umd_mr_services sv;
	memset(&sv, 0, sizeof(sv));
	sv.sub_unit = s_sub_unit; sv.plane_get = s_plane_get; sv.plane_put_rect = s_plane_put_rect;
	memset(&L, 0, sizeof(L));
	umd_menu_init(&L);
	umd_mr_init(&R, &sv, &L);
	umd_menu_levels lv;

	// [levels] closed
	rd(1, 0, 0);
	levels(&lv);
	if (lv.grab != (1u << UMD_PB_PANEL) || lv.ui_sub) FAIL("levels", "closed: grab %04x ui_sub %d, want 4000 0", lv.grab, lv.ui_sub);
	// open
	key(1u << UMD_PB_PANEL);
	levels(&lv);
	if (lv.grab != UMD_PANEL_GRAB_OPEN || !lv.ui_sub) FAIL("levels", "open: grab %04x ui_sub %d, want %04x 1", lv.grab, lv.ui_sub, UMD_PANEL_GRAB_OPEN);
	if (R.P.sel != UMD_PI_DISPLAY) FAIL("levels", "opened on item %d, want Display", R.P.sel);

	// [route] Right from Display wraps to UMD Menu -- dark with no engine -- so lands on Go To
	key(1u << UMD_PB_RIGHT);
	if (R.P.sel != UMD_PI_GOTO) FAIL("route", "Right moved the cursor to %d, want Go To (UMD Menu dark, no engine)", R.P.sel);

	// [act] x on Next; x on Play
	R.P.sel = UMD_PI_NEXT;
	key(1u << UMD_PB_PAUSE);
	if (L.n_press != 1 || L.q_press[0] != (1u << UMD_PB_NEXT)) FAIL("act", "x on Next: %d presses queued, first %04x, want 1 of %04x", L.n_press, L.n_press ? L.q_press[0] : 0, 1u << UMD_PB_NEXT);
	R.P.sel = UMD_PI_PLAY;
	key(1u << UMD_PB_PAUSE);
	if (L.n_cmd != 1 || L.q_cmd[0].code != UMD_PANEL_PC_PLAY) FAIL("act", "x on Play: %d commands, code %d, want 1 of PLAY", L.n_cmd, L.n_cmd ? L.q_cmd[0].code : -1);
	// (x on Pause: the command PAUSE, not Select's press -- Select toggles since 2026-10-07)
	R.P.sel = UMD_PI_PAUSE;
	key(1u << UMD_PB_PAUSE);
	if (L.n_press != 1 || L.n_cmd != 2 || L.q_cmd[1].code != UMD_PANEL_PC_PAUSE) FAIL("act", "x on Pause: %d presses, %d commands, code %d, want 1, 2 of PAUSE", L.n_press, L.n_cmd, L.n_cmd > 1 ? L.q_cmd[1].code : -1);
	R.P.sel = UMD_PI_DISPLAY;

	// [page] the first page: plane 2 over subtitle unit 5 (plane 1)
	rd(1, 1, 5);
	int b = render();
	if (b != 2) FAIL("page", "the first page into plane %d, want 2", b);
	if (n_get != 1 || get_buf != 1 || get_x != 156 || get_y != 379 || get_w != 410 || get_h != 70)
		FAIL("page", "the subtitle read back: %d reads, plane %d %d,%d %dx%d, want 1 of plane 1 156,379 410x70", n_get, get_buf, get_x, get_y, get_w, get_h);
	int bx, by, bw, bh;
	umd_panel_rect(&bx, &by, &bw, &bh);
	int ux0 = 156 < bx ? 156 : bx, uy0 = by, ux1 = 566 > bx + bw ? 566 : bx + bw, uy1 = 449;
	if (put_buf != 2 || put_x != ux0 || put_y != uy0 || put_w != ux1 - ux0 || put_h != uy1 - uy0)
		FAIL("page", "written plane %d %d,%d %dx%d, want plane 2 %d,%d %dx%d (the union)", put_buf, put_x, put_y, put_w, put_h, ux0, uy0, ux1 - ux0, uy1 - uy0);
	if (L.n_flip != 1 || L.q_flip[0].buf != 2 || L.q_flip[0].x != ux0 || L.q_flip[0].w != ux1 - ux0 || L.q_flip[0].h != uy1 - uy0)
		FAIL("page", "the flip: %d queued, plane %d, %d,%d %dx%d", L.n_flip, L.n_flip ? L.q_flip[0].buf : -1, L.n_flip ? L.q_flip[0].x : -1,
		     L.n_flip ? L.q_flip[0].y : -1, L.n_flip ? L.q_flip[0].w : -1, L.n_flip ? L.q_flip[0].h : -1);
	if (memcmp(last_page + ((size_t)440 * UMD_MR_W + 160) * 4, sub_pixel, 4))
		FAIL("page", "the subtitle's pixel (160, 440) not in the page under the panel");
	{
		const uint8_t *p = last_page + ((size_t)(uy0 + 2) * UMD_MR_W + (size_t)(ux0 + 2)) * 4;
		if (ux0 < bx && (p[0] | p[1] | p[2] | p[3])) FAIL("page", "the union outside the box and the subtitle not cleared");
	}
	core_took();
	int n0 = n_put;
	rd(1, 1, 5);
	if (render() != -1 || n_put != n0) FAIL("page", "redrawn with nothing changed");
	// a new subtitle: plane 3
	rd(1, 1, 6);
	b = render();
	if (b != 3) FAIL("page", "a new subtitle drawn into plane %d, want 3 (the other)", b);
	if (get_buf != 0) FAIL("page", "unit 6 read from plane %d, want 0", get_buf);
	core_took();
	// a subtitle not known: the box alone
	known = 0;
	rd(1, 1, 7);
	b = render();
	if (b != 2 || put_x != bx || put_y != by || put_w != bw || put_h != bh)
		FAIL("page", "an unknown unit: plane %d %d,%d %dx%d, want plane 2, the box %d,%d %dx%d", b, put_x, put_y, put_w, put_h, bx, by, bw, bh);
	{       // the page is the panel over a CLEARED box: a redraw never blends over the last page's panel
		static uint8_t ref[UMD_MR_W * UMD_MR_H * 4];
		memset(ref, 0, sizeof(ref));
		umd_panel_draw(&R.P, ref, UMD_MR_W * 4, UMD_PANEL_PX_PLANE);
		for (int y = by; y < by + bh; y++)
			if (memcmp(last_page + ((size_t)y * UMD_MR_W + (size_t)bx) * 4, ref + ((size_t)y * UMD_MR_W + (size_t)bx) * 4, (size_t)bw * 4)) {
				FAIL("page", "line %d of the box differs from the panel drawn on a cleared page (drawn over the last one?)", y);
				break;
			}
	}
	known = 1;
	core_took();

	// [close] o: no ui_sub, nothing drawn; a re-open with nothing else changed draws
	key(1u << UMD_PB_STOP);
	levels(&lv);
	if (lv.ui_sub || R.P.open) FAIL("close", "o left the panel open (ui_sub %d)", lv.ui_sub);
	if (render() != -1) FAIL("close", "a page drawn with the panel closed");
	rd(1, 1, 7);
	key(1u << UMD_PB_PANEL);
	known = 0;
	if (render() < 0) FAIL("page", "the re-opened panel not drawn (nothing else changed: ui_sub's rise must draw)");
	known = 1;

	// [core] (A12 SD2): the core decodes and reports the shown unit's plane and rectangle; the host has
	// no record of it (known 0). The page reads THAT rectangle back, from THAT plane
	core_took();
	known = 0; core_rect = 1; cr_buf = 0; cr_x = 40; cr_y = 380; cr_w = 636; cr_h = 61;
	n0 = n_get;
	rd(1, 1, 8);
	b = render();
	if (b < 0 || n_get != n0 + 1 || get_buf != 0 || get_x != 40 || get_y != 380 || get_w != 636 || get_h != 61)
		FAIL("core", "the core's rectangle: page %d, %d reads, plane %d %d,%d %dx%d, want plane 0 40,380 636x61",
		     b, n_get - n0, get_buf, get_x, get_y, get_w, get_h);
	if (memcmp(last_page + ((size_t)400 * UMD_MR_W + 50) * 4, sub_pixel, 4))
		FAIL("core", "the subtitle's pixel (50, 400) not in the page under the panel");

	// [zoom] (fj#71): the same rectangle (40, 380, 636 x 61) under Zoom: past the band's bottom (441 > 420), so at
	// 420 - 61 = 359, all 61 rows; the rows it left (420 .. 440) cleared; the page inside the band
	core_took();
	zoom_rd = 1;
	rd(1, 1, 8);
	b = render();
	if (b < 0) FAIL("zoom", "a change of Zoom alone did not redraw the page");
	if (memcmp(last_page + ((size_t)359 * UMD_MR_W + 50) * 4, sub_pixel, 4) ||
	    memcmp(last_page + ((size_t)419 * UMD_MR_W + 50) * 4, sub_pixel, 4))
		FAIL("zoom", "the subtitle not at 359 .. 419 under Zoom (want 420 - 61)");
	{
		const uint8_t *p = last_page + ((size_t)430 * UMD_MR_W + 50) * 4;
		if (p[0] | p[1] | p[2] | p[3]) FAIL("zoom", "line 430 (the subtitle's old place) not cleared");
	}
	if (put_y + put_h > 420) FAIL("zoom", "the page %d,%d %dx%d reaches past the band (420)", put_x, put_y, put_w, put_h);
	// taller than the band: at 60, its first 360 rows (70 + 400 would reach 470)
	core_took();
	cr_y = 70; cr_h = 400;
	rd(1, 1, 9);
	b = render();
	if (b < 0 || memcmp(last_page + ((size_t)60 * UMD_MR_W + 50) * 4, sub_pixel, 4) ||
	    memcmp(last_page + ((size_t)419 * UMD_MR_W + 50) * 4, sub_pixel, 4))
		FAIL("zoom", "a 400-row subtitle not at 60 .. 419 under Zoom");
	{
		const uint8_t *p = last_page + ((size_t)440 * UMD_MR_W + 50) * 4;
		if (p[0] | p[1] | p[2] | p[3]) FAIL("zoom", "a 400-row subtitle drawn past the band (line 440)");
	}
	// Zoom gone: the subtitle back at its own place (a change of Zoom alone redraws)
	core_took();
	zoom_rd = 0; cr_y = 380; cr_h = 61;
	rd(1, 1, 9);
	render();
	core_took();
	rd(1, 1, 9);
	if (render() != -1) FAIL("zoom", "redrawn with nothing changed after Zoom went");
	if (memcmp(last_page + ((size_t)440 * UMD_MR_W + 50) * 4, sub_pixel, 4))
		FAIL("zoom", "Zoom off: the subtitle not back at its own place (line 440)");
	known = 1; core_rect = 0;

	printf("panel_run_check: %u pages, %u actions\n", R.n_panel_pages, R.n_panel_acts);
	if (fails) { printf("panel_run_check: %d FAILED\n", fails); return 1; }
	printf("PASS: panel_run_check\n");
	return 0;
}
