// umd_panel.c -- see umd_panel.h. The decisions are tools/panel_ref.py's and the pixels
// tools/panel_layout.py's page(), rule for rule: bench/umd/run_panel.sh holds the two together.
#include <string.h>

#include "umd_panel.h"

#define N      UMD_PANEL_N
#define ROW0   UMD_PANEL_ROW0_N
#define ROW01  (UMD_PANEL_ROW0_N + UMD_PANEL_ROW1_N)
#define NROWS  3
#define B(b)   (1u << (b))

static int row_of(int i) { return i < ROW0 ? 0 : i < ROW01 ? 1 : 2; }
static int row_first(int r) { return r == 0 ? 0 : r == 1 ? ROW0 : ROW01; }
static int col_of(int i) { return i - row_first(row_of(i)); }
static int row_n(int r)  { return r == 0 ? ROW0 : r == 1 ? UMD_PANEL_ROW1_N : UMD_PANEL_ROW2_N; }
static int item_at(int r, int c) { return row_first(r) + c; }

void umd_panel_init(umd_panel *p)
{
	memset(p, 0, sizeof(*p));
	p->sel = UMD_PANEL_START;
	p->rd.sub_any = 1;                    // (panel_ref's Rd(state=0): nothing known yet)
	p->rd.engine = 1;
}

int umd_panel_available(const umd_panel *p, int i)
{
	if (p->menu_mode)
		return (i == UMD_PI_MENU && p->rd.engine) || i == UMD_PI_DISPLAY || i == UMD_PI_STOP;
	if (i == UMD_PI_SUB) return p->rd.sub_any;
	if (i == UMD_PI_MENU) return p->rd.engine;
	return 1;
}

// ---- the walk: dark items skipped ----
static void horiz(umd_panel *p, int step)
{
	int r = row_of(p->sel), c = col_of(p->sel), n = row_n(r);
	for (int k = 1; k < n; k++) {
		int cand = item_at(r, ((c + step * k) % n + n) % n);      // wraps within the row
		if (umd_panel_available(p, cand)) { p->sel = cand; return; }
	}
}

// the adjacent row, wrapping; a row with nothing available is skipped (row 3 over a disc menu)
static void vert(umd_panel *p, int step)
{
	int r0 = row_of(p->sel), c0 = col_of(p->sel);
	for (int k = 1; k < NROWS; k++) {
		int r = ((r0 + step * k) % NROWS + NROWS) % NROWS, n = row_n(r);
		int c = c0 > n - 1 ? n - 1 : c0;                        // the column kept, clamped
		int best = -1, bd = 0;
		for (int j = 0; j < n; j++) {
			if (!umd_panel_available(p, item_at(r, j))) continue;
			int d = j > c ? j - c : c - j;
			if (best < 0 || d < bd) { best = j; bd = d; }       // the nearest; a tie to the left
		}
		if (best >= 0) { p->sel = item_at(r, best); return; }
	}
}

static void close_panel(umd_panel *p) { p->open = 0; p->hidden = 0; }

static void hide(umd_panel *p)
{
	p->hidden = 1;
	p->g_seen = 0;
	p->g_since = p->now;
	p->quiet = 0;
}

void umd_panel_levels(const umd_panel *p, uint16_t *grab, int *show)
{
	if (!p->open) {
		*grab = (p->rd.state != 0 || p->rd.menu_up) ? UMD_PANEL_GRAB_CLOSED : 0;
		*show = UMD_PS_NONE;
	} else if (p->hidden) {
		*grab = B(UMD_PB_PANEL);          // the editor has the keys (gt_take); the panel button closes it
		*show = UMD_PS_NONE;
	} else {
		*grab = UMD_PANEL_GRAB_OPEN;
		*show = p->menu_mode ? UMD_PS_FRAME : UMD_PS_UI_SUB;
	}
}

void umd_panel_read(umd_panel *p, const umd_panel_rd *rd, uint32_t now)
{
	umd_panel_rd prev = p->rd;
	p->rd = *rd;
	p->now = now;
	if (!p->open) return;
	// a mount (the core idle) or the engine taking or giving back the screen closes it
	if ((rd->state == 0 && !rd->menu_up) || (!rd->menu_up != !prev.menu_up)) { close_panel(p); return; }
	if (!p->hidden && rd->goto_open) hide(p);                   // the Go To button while it is up
	if (p->hidden) {
		if (rd->goto_open) {
			p->g_seen = 1;
			p->quiet = 0;
		} else if (!p->g_seen && now - p->g_since >= UMD_PANEL_GOTO_OPEN_MS) {
			p->hidden = 0;                                      // the editor never opened
		} else if (p->g_seen) {
			p->quiet = rd->seeking ? 0 : p->quiet + 1;
			if (p->quiet >= UMD_PANEL_RETURN_READS) {
				p->hidden = 0;
				if (umd_panel_available(p, UMD_PI_GOTO)) p->sel = UMD_PI_GOTO;
			}
		}
	}
}

static int press(umd_panel *p, int b, umd_panel_act *a)
{
	if (!p->open) {
		if (b == UMD_PB_PANEL && (p->rd.state != 0 || p->rd.menu_up)) {
			p->open = 1;
			p->hidden = 0;
			p->menu_mode = p->rd.menu_up ? 1 : 0;
			p->sel = UMD_PANEL_START;     // K8, measured: on Display at every open
		}
		return 0;
	}
	if (b == UMD_PB_PANEL || (b == UMD_PB_STOP && !p->hidden)) { close_panel(p); return 0; }
	if (p->hidden) return 0;
	switch (b) {
	case UMD_PB_RIGHT: horiz(p, +1); return 0;
	case UMD_PB_LEFT:  horiz(p, -1); return 0;
	case UMD_PB_DOWN: vert(p, +1); return 0;
	case UMD_PB_UP:   vert(p, -1); return 0;
	case UMD_PB_PAUSE: break;
	default: return 0;
	}
	if (!umd_panel_available(p, p->sel)) return 0;              // (it went dark under the cursor)
	a->kind = UMD_PA_PRESS;
	a->arg = 0;
	switch (p->sel) {
	case UMD_PI_MENU:    a->kind = UMD_PA_MENU; break;
	case UMD_PI_GOTO:    a->arg = B(UMD_PB_GOTO); break;
	case UMD_PI_AUDIO:   a->arg = B(UMD_PB_AUDIO); break;
	case UMD_PI_SUB:     a->arg = B(UMD_PB_SUB); break;
	case UMD_PI_DISPLAY: a->arg = B(UMD_PB_DISPLAY); break;
	case UMD_PI_PREV:    a->arg = B(UMD_PB_PREV); break;
	case UMD_PI_NEXT:    a->arg = B(UMD_PB_NEXT); break;
	case UMD_PI_REW:     a->arg = B(UMD_PB_LEFT); break;
	case UMD_PI_FF:      a->arg = B(UMD_PB_RIGHT); break;
	case UMD_PI_PLAY:    a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_PLAY; break;
	case UMD_PI_PAUSE:   a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_PAUSE; break;
	case UMD_PI_AB:      a->arg = B(UMD_PB_AB); break;
	case UMD_PI_CLEAR:   a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_AB_CLEAR; break;
	case UMD_PI_STOP:
		if (p->menu_mode) a->kind = UMD_PA_QUIT;
		else a->arg = B(UMD_PB_STOP);
		break;
	}
	if (p->sel == UMD_PI_MENU || p->sel == UMD_PI_STOP) close_panel(p);   // K5: only these close it
	else if (p->sel == UMD_PI_GOTO) hide(p);
	return 1;
}

int umd_panel_key(umd_panel *p, uint32_t mask, umd_panel_act *out, int max)
{
	int n = 0;
	for (int b = 0; b < 16; b++) {                              // one press at a time, lowest bit first
		if (!(mask >> b & 1)) continue;
		umd_panel_act a;
		if (press(p, b, &a) && n < max) out[n++] = a;
	}
	return n;
}

uint32_t umd_panel_view(const umd_panel *p)
{
	if (!p->open || p->hidden) return 0;
	uint32_t v = 1u | (uint32_t)p->menu_mode << 1 | (uint32_t)p->sel << 2;
	for (int i = 0; i < N; i++)
		if (umd_panel_available(p, i)) v |= 1u << (8 + i);
	return v;
}

// ---- the drawing: premultiplied ARGB, plane_blend's rounding (compositor.md §3) ----------------------

static int rnd255(int t) { return (t + 128 + ((t + 128) >> 8)) >> 8; }   // round(t / 255)

// src (r, g, b, a: premultiplied) over the pixel at q, in the layout's byte order
static void over(uint8_t *q, int layout, int r, int g, int b, int a)
{
	int ir = layout == UMD_PANEL_PX_PLANE ? 2 : 0, ib = 2 - ir;
	int s[4] = { r, g, b, a };
	int ix[4] = { ir, 1, ib, 3 };
	for (int c = 0; c < 4; c++) {
		int v = s[c] + rnd255(q[ix[c]] * (255 - a));
		q[ix[c]] = (uint8_t)(v > 255 ? 255 : v);
	}
}

static int cls_at(const uint8_t *packed, int i) { return packed[i >> 2] >> (6 - 2 * (i & 3)) & 3; }

// a class bitmap (w x h) at (x0, y0), its ink `rgb`: clear / shadow / ink / edge (panel_layout.cls_rgba)
static void put_cls(uint8_t *px, int stride, int layout, const uint8_t *packed, int w, int h, int x0, int y0,
                    const int *rgb)
{
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			int c = cls_at(packed, y * w + x);
			uint8_t *q = px + (y0 + y) * stride + (x0 + x) * 4;
			if (c == 1) over(q, layout, 0, 0, 0, UMD_PANEL_SHADOW_A);
			else if (c == 2) over(q, layout, rgb[0], rgb[1], rgb[2], 255);
			else if (c == 3) over(q, layout, rnd255(rgb[0] * UMD_PANEL_EDGE_A), rnd255(rgb[1] * UMD_PANEL_EDGE_A),
			                      rnd255(rgb[2] * UMD_PANEL_EDGE_A), UMD_PANEL_EDGE_A);
		}
}

// the halo (panel_layout.halo_rgba): the ink / edge mask on a canvas HALO_PAD larger each side, summed
// over a 5 x 5 window twice (zero outside), alpha = min(HALO_A, round(HALO_A * NUM * S / DEN)), white
#define HW (UMD_PANEL_IW + 2 * UMD_PANEL_HALO_PAD)
#define HH (UMD_PANEL_IH + 2 * UMD_PANEL_HALO_PAD)
static void put_halo(uint8_t *px, int stride, int layout, const uint8_t *packed, int x0, int y0)
{
	static int m[HH][HW], s1[HH][HW];
	memset(m, 0, sizeof(m));
	for (int y = 0; y < UMD_PANEL_IH; y++)
		for (int x = 0; x < UMD_PANEL_IW; x++)
			m[y + UMD_PANEL_HALO_PAD][x + UMD_PANEL_HALO_PAD] = cls_at(packed, y * UMD_PANEL_IW + x) >= 2;
	for (int pass = 0; pass < 2; pass++) {
		int (*src)[HW] = pass ? s1 : m;
		static int t[HH][HW];
		for (int y = 0; y < HH; y++)
			for (int x = 0; x < HW; x++) {
				int v = 0;
				for (int dy = -2; dy <= 2; dy++)
					for (int dx = -2; dx <= 2; dx++) {
						int yy = y + dy, xx = x + dx;
						if (yy >= 0 && yy < HH && xx >= 0 && xx < HW) v += src[yy][xx];
					}
				t[y][x] = v;
			}
		memcpy(s1, t, sizeof(t));
	}
	for (int y = 0; y < HH; y++)
		for (int x = 0; x < HW; x++) {
			long v = ((long)s1[y][x] * UMD_PANEL_HALO_A * UMD_PANEL_HALO_NUM + UMD_PANEL_HALO_DEN / 2) / UMD_PANEL_HALO_DEN;
			int a = v > UMD_PANEL_HALO_A ? UMD_PANEL_HALO_A : (int)v;
			int c = rnd255(255 * a);
			over(px + (y0 + y) * stride + (x0 + x) * 4, layout, c, c, c, a);
		}
}

// the box (panel_layout.box_rgba): each pixel's 4 x 4 subsamples, centres in eighths of a pixel, inside
// the rounding when within the radius of its corner's centre; n of 16 -> each channel (n v + 8) / 16
static void put_box(uint8_t *px, int stride, int layout)
{
	const int w = UMD_PANEL_BOX_W, h = UMD_PANEL_BOX_H, r8 = 8 * UMD_PANEL_BOX_R;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			int n = 0;
			for (int sy = 0; sy < 4; sy++)
				for (int sx = 0; sx < 4; sx++) {
					int p8x = 2 * (4 * x + sx) + 1, p8y = 2 * (4 * y + sy) + 1;
					int dx = r8 - p8x, dy = r8 - p8y;
					if (p8x - (8 * w - r8) > dx) dx = p8x - (8 * w - r8);
					if (p8y - (8 * h - r8) > dy) dy = p8y - (8 * h - r8);
					if (dx < 0) dx = 0;
					if (dy < 0) dy = 0;
					n += dx * dx + dy * dy <= r8 * r8;
				}
			over(px + (UMD_PANEL_BOX_Y0 + y) * stride + (UMD_PANEL_BOX_X0 + x) * 4, layout,
			     (n * UMD_PANEL_BOX_R8 + 8) / 16, (n * UMD_PANEL_BOX_G8 + 8) / 16,
			     (n * UMD_PANEL_BOX_B8 + 8) / 16, (n * UMD_PANEL_BOX_A8 + 8) / 16);
		}
}

static const int WHITE[3] = { UMD_PANEL_WHITE_R, UMD_PANEL_WHITE_G, UMD_PANEL_WHITE_B };
static const int GREY[3]  = { UMD_PANEL_GREY_R, UMD_PANEL_GREY_G, UMD_PANEL_GREY_B };
static const int DARK[3]  = { UMD_PANEL_DARK_R, UMD_PANEL_DARK_G, UMD_PANEL_DARK_B };

void umd_panel_draw(const umd_panel *p, uint8_t *px, int stride, int layout)
{
	put_box(px, stride, layout);
	for (int i = 0; i < N; i++) {
		int r = row_of(i), n = row_n(r);
		int x0 = UMD_PANEL_CX - (n * UMD_PANEL_PITCH) / 2 + col_of(i) * UMD_PANEL_PITCH
		         + (UMD_PANEL_PITCH - UMD_PANEL_IW) / 2;
		int y0 = r == 0 ? UMD_PANEL_ROW_TOP0 : r == 1 ? UMD_PANEL_ROW_TOP1 : UMD_PANEL_ROW_TOP2;
		const int *rgb;
		if (i == p->sel) {
			put_halo(px, stride, layout, umd_panel_icon[i], x0 - UMD_PANEL_HALO_PAD, y0 - UMD_PANEL_HALO_PAD);
			rgb = WHITE;
		} else
			rgb = umd_panel_available(p, i) ? GREY : DARK;
		put_cls(px, stride, layout, umd_panel_icon[i], UMD_PANEL_IW, UMD_PANEL_IH, x0, y0, rgb);
	}
	const char *cap = umd_panel_caption[p->sel];
	int len = (int)strlen(cap);
	int x = UMD_PANEL_CX - len * UMD_PANEL_FONT_CW / 2;
	const int *rgb = umd_panel_available(p, p->sel) ? WHITE : DARK;
	for (int k = 0; k < len; k++, x += UMD_PANEL_FONT_CW) {
		int ch = (unsigned char)cap[k];
		if (ch < 32 || ch > 126) continue;                      // (the captions are ASCII)
		put_cls(px, stride, layout, umd_panel_font[ch - 32], UMD_PANEL_FONT_CW, UMD_PANEL_FONT_CH, x,
		        UMD_PANEL_CAP_TOP, rgb);
	}
}

void umd_panel_rect(int *x, int *y, int *w, int *h)
{
	*x = UMD_PANEL_BOX_X0;
	*y = UMD_PANEL_BOX_Y0;
	*w = UMD_PANEL_BOX_W;
	*h = UMD_PANEL_BOX_H;
}
