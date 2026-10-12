// umd_disc_screen.c -- see umd_disc_screen.h.
#include "umd_disc_screen.h"
#include "umd_panel.h"
#include "umd_panel_art.h"

#include <stdio.h>
#include <string.h>

// ---- PARAM.SFO -------------------------------------------------------------------------------------

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t le16(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8; }

int umd_ds_sfo_title(const uint8_t *sfo, size_t n, char *out, size_t cap)
{
	if (cap) out[0] = 0;
	if (!sfo || n < 20 || memcmp(sfo, "\0PSF", 4) || !cap) return -1;
	uint32_t koff = le32(sfo + 8), doff = le32(sfo + 12), cnt = le32(sfo + 16);
	if (koff > n || doff > n || (uint64_t)20 + (uint64_t)16 * cnt > koff) return -1;
	for (uint32_t i = 0; i < cnt; i++) {
		const uint8_t *e = sfo + 20 + 16 * i;
		uint32_t ko = koff + le16(e), fmt = le16(e + 2), used = le32(e + 4), dof = doff + le32(e + 12);
		if (ko + 6 > n || memcmp(sfo + ko, "TITLE", 6)) continue;     // (the key, its NUL included)
		if ((fmt != 0x0204 && fmt != 0x0004) || dof > n || used > n - dof) return -1;
		size_t k = 0;
		while (k < used && k + 1 < cap && sfo[dof + k]) { out[k] = (char)sfo[dof + k]; k++; }
		out[k] = 0;
		return 0;
	}
	return -1;
}

// ---- the art's colours as stored --------------------------------------------------------------------

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

int umd_ds_png_plain(uint8_t *png, size_t *n)
{
	static const uint8_t sig[8] = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
	if (!png || *n < 8 || memcmp(png, sig, 8)) return -1;
	size_t r = 8, w = 8;
	int dropped = 0;
	while (r + 12 <= *n) {
		uint32_t len = be32(png + r);
		if (len > *n - r - 12) break;                  // (a broken chunk: the rest kept, the decoder judges)
		size_t whole = (size_t)len + 12;
		const uint8_t *t = png + r + 4;
		int drop = !memcmp(t, "gAMA", 4) || !memcmp(t, "cHRM", 4) || !memcmp(t, "sRGB", 4) || !memcmp(t, "iCCP", 4);
		if (drop) dropped++;
		else { if (w != r) memmove(png + w, png + r, whole); w += whole; }
		r += whole;
	}
	if (r < *n) { memmove(png + w, png + r, *n - r); w += *n - r; }
	*n = w;
	return dropped;
}

// ---- the title the font can draw -------------------------------------------------------------------

void umd_ds_display_title(const char *sfo_title, const char *image_name, char *out, size_t cap)
{
	if (!cap) return;
	out[0] = 0;
	const uint8_t *s = (const uint8_t *)(sfo_title ? sfo_title : "");
	size_t k = 0;
	int ok = 1;
	while (*s && ok) {
		uint32_t c;
		int len;
		if (s[0] < 0x80) { c = s[0]; len = 1; }
		else if ((s[0] & 0xE0) == 0xC0 && (s[1] & 0xC0) == 0x80) { c = (uint32_t)(s[0] & 0x1F) << 6 | (s[1] & 0x3F); len = 2; }
		else if ((s[0] & 0xF0) == 0xE0 && (s[1] & 0xC0) == 0x80 && (s[2] & 0xC0) == 0x80) {
			c = (uint32_t)(s[0] & 0x0F) << 12 | (uint32_t)(s[1] & 0x3F) << 6 | (s[2] & 0x3F); len = 3;
		} else { ok = 0; break; }
		s += len;
		const char *rep = NULL;
		char one[2] = { 0, 0 };
		if (c >= 0xFF01 && c <= 0xFF5E) { one[0] = (char)(c - 0xFEE0); rep = one; }   // fullwidth ASCII
		else if (c == 0x2122) rep = "TM";
		else if (c >= 32 && c <= 126) { one[0] = (char)c; rep = one; }
		else ok = 0;
		for (; ok && rep && *rep && k + 1 < cap; rep++) out[k++] = *rep;
	}
	out[k] = 0;
	// (leading / trailing blanks dropped: the golden's strip())
	size_t b = 0;
	while (out[b] == ' ') b++;
	if (b) memmove(out, out + b, strlen(out + b) + 1);
	k = strlen(out);
	while (k && out[k - 1] == ' ') out[--k] = 0;
	if (ok && out[0]) return;
	// the image's file name, its directories and extension dropped
	const char *n = image_name ? image_name : "";
	const char *sl = strrchr(n, '/');
	if (sl) n = sl + 1;
	const char *dot = strrchr(n, '.');
	size_t l = dot && dot != n ? (size_t)(dot - n) : strlen(n);
	if (l > cap - 1) l = cap - 1;
	memcpy(out, n, l);
	out[l] = 0;
}

void umd_ds_hint(char *out, size_t cap, int resume, uint32_t ms)
{
	if (!resume) { snprintf(out, cap, "> Play"); return; }
	uint32_t s = ms / 1000;
	snprintf(out, cap, "> Resume %u:%02u:%02u", s / 3600, s / 60 % 60, s % 60);
}

// ---- the drawing (umd_panel.c's arithmetic) ----------------------------------------------------------

static int rnd255(int t) { return (t + 128 + ((t + 128) >> 8)) >> 8; }

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

// one source coordinate (16.16) for destination index d of n over a source span (s0, sw) of a side
// `size`: the centre-aligned sample, clamped to the side -> the two taps and the 8-bit weight
static void tap(int64_t s0, int64_t sw, int d, int n, int size, int *i0, int *i1, int *f)
{
	int64_t u = s0 + ((int64_t)(2 * d + 1) * sw) / (2 * (int64_t)n) - 32768;
	int64_t hi = (int64_t)(size - 1) << 16;
	if (u < 0) u = 0;
	if (u > hi) u = hi;
	*i0 = (int)(u >> 16);
	*i1 = *i0 + 1 < size ? *i0 + 1 : size - 1;
	*f = (int)((u >> 8) & 255);
}

// the image's source span (16.16) scaled bilinear into the destination rectangle, premultiplied, over
static void scale_into(uint8_t *px, int stride, int layout, const umd_ds_img *im, int64_t sx0, int64_t sy0,
                       int64_t sw, int64_t sh, int dx, int dy, int dw, int dh)
{
	for (int y = 0; y < dh; y++) {
		int j0, j1, fy;
		tap(sy0, sh, y, dh, im->h, &j0, &j1, &fy);
		for (int x = 0; x < dw; x++) {
			int i0, i1, fx;
			tap(sx0, sw, x, dw, im->w, &i0, &i1, &fx);
			const uint8_t *p[4] = { im->rgba + ((size_t)j0 * im->w + i0) * 4, im->rgba + ((size_t)j0 * im->w + i1) * 4,
			                        im->rgba + ((size_t)j1 * im->w + i0) * 4, im->rgba + ((size_t)j1 * im->w + i1) * 4 };
			int v[4];
			for (int c = 0; c < 4; c++) {
				int t[4];
				for (int k = 0; k < 4; k++) t[k] = c == 3 ? p[k][3] : rnd255(p[k][c] * p[k][3]);
				int h0 = t[0] * (256 - fx) + t[1] * fx, h1 = t[2] * (256 - fx) + t[3] * fx;
				v[c] = (h0 * (256 - fy) + h1 * fy + 32768) >> 16;
			}
			over(px + (size_t)(dy + y) * stride + (size_t)(dx + x) * 4, layout, v[0], v[1], v[2], v[3]);
		}
	}
}

// a rounded box (the panel's put_box, any rectangle)
static void put_rbox(uint8_t *px, int stride, int layout, int x0, int y0, int w, int h)
{
	const int r8 = 8 * UMD_PANEL_BOX_R;
	for (int y = 0; y < h; y++)
		for (int x = 0; x < w; x++) {
			int n = 0;
			for (int sy = 0; sy < 4; sy++)
				for (int sx = 0; sx < 4; sx++) {
					int p8x = 2 * (4 * x + sx) + 1, p8y = 2 * (4 * y + sy) + 1;
					int ddx = r8 - p8x, ddy = r8 - p8y;
					if (p8x - (8 * w - r8) > ddx) ddx = p8x - (8 * w - r8);
					if (p8y - (8 * h - r8) > ddy) ddy = p8y - (8 * h - r8);
					if (ddx < 0) ddx = 0;
					if (ddy < 0) ddy = 0;
					n += ddx * ddx + ddy * ddy <= r8 * r8;
				}
			over(px + (size_t)(y0 + y) * stride + (size_t)(x0 + x) * 4, layout, (n * UMD_PANEL_BOX_R8 + 8) / 16,
			     (n * UMD_PANEL_BOX_G8 + 8) / 16, (n * UMD_PANEL_BOX_B8 + 8) / 16, (n * UMD_PANEL_BOX_A8 + 8) / 16);
		}
}

static int cls_at(const uint8_t *packed, int i) { return packed[i >> 2] >> (6 - 2 * (i & 3)) & 3; }

// a line of the HUD's font at (x0, y0), its ink `rgb` (panel_layout.text_rgba: clear / shadow / ink / edge)
static void put_text(uint8_t *px, int stride, int layout, const char *s, int x0, int y0, const int *rgb)
{
	for (int k = 0; s[k]; k++) {
		int ch = (uint8_t)s[k];
		if (ch < 32 || ch > 126) continue;              // (umd_ds_display_title leaves none)
		const uint8_t *g = umd_panel_font[ch - 32];
		for (int y = 0; y < UMD_PANEL_FONT_CH; y++)
			for (int x = 0; x < UMD_PANEL_FONT_CW; x++) {
				int c = cls_at(g, y * UMD_PANEL_FONT_CW + x);
				uint8_t *q = px + (size_t)(y0 + y) * stride + (size_t)(x0 + k * UMD_PANEL_FONT_CW + x) * 4;
				if (c == 1) over(q, layout, 0, 0, 0, UMD_PANEL_SHADOW_A);
				else if (c == 2) over(q, layout, rgb[0], rgb[1], rgb[2], 255);
				else if (c == 3) over(q, layout, rnd255(rgb[0] * UMD_PANEL_EDGE_A), rnd255(rgb[1] * UMD_PANEL_EDGE_A),
				                      rnd255(rgb[2] * UMD_PANEL_EDGE_A), UMD_PANEL_EDGE_A);
			}
	}
}

// the title word-wrapped to max_chars a line, at most 2 lines, "..." ending the last past them (the
// golden's title_lines); returns the number of lines
#define DS_LINES 2
#define DS_LINE_MAX 128
static int wrap(const char *title, int max_chars, char lines[DS_LINES][DS_LINE_MAX])
{
	static char all[64][DS_LINE_MAX];                  // (a 128-byte title wraps to at most 64 lines)
	int n = 0;
	char cur[DS_LINE_MAX] = "";
	const char *p = title;
	while (*p && n < 62) {
		while (*p == ' ') p++;
		if (!*p) break;
		char wd[DS_LINE_MAX];
		int wl = 0;
		while (p[wl] && p[wl] != ' ' && wl < DS_LINE_MAX - 1) { wd[wl] = p[wl]; wl++; }
		p += wl;
		wd[wl] = 0;
		char *w = wd;
		while ((int)strlen(w) > max_chars) {           // (a word longer than a line: broken)
			if (cur[0]) { snprintf(all[n++], DS_LINE_MAX, "%s", cur); cur[0] = 0; }
			snprintf(all[n++], DS_LINE_MAX, "%.*s", max_chars, w);
			w += max_chars;
		}
		if (!cur[0]) snprintf(cur, sizeof(cur), "%s", w);
		else if ((int)(strlen(cur) + 1 + strlen(w)) <= max_chars) { size_t l = strlen(cur); snprintf(cur + l, sizeof(cur) - l, " %s", w); }
		else { snprintf(all[n++], DS_LINE_MAX, "%s", cur); snprintf(cur, sizeof(cur), "%s", w); }
	}
	if (cur[0]) snprintf(all[n++], DS_LINE_MAX, "%s", cur);
	int out = n < DS_LINES ? n : DS_LINES;
	for (int k = 0; k < out; k++) snprintf(lines[k], DS_LINE_MAX, "%s", all[k]);
	if (n > DS_LINES)
		snprintf(lines[DS_LINES - 1], DS_LINE_MAX, "%.*s...", max_chars - 3, all[DS_LINES - 1]);
	return out;
}

static const int WHITE[3] = { UMD_PANEL_WHITE_R, UMD_PANEL_WHITE_G, UMD_PANEL_WHITE_B };
static const int GREY[3]  = { UMD_PANEL_GREY_R, UMD_PANEL_GREY_G, UMD_PANEL_GREY_B };

void umd_ds_draw(uint8_t *px, int stride, int layout, const umd_ds_img *pic1, const umd_ds_img *icon0,
                 const char *title, const char *hint, int fit)
{
	for (int y = 0; y < UMD_DS_H; y++) memset(px + (size_t)y * stride, 0, (size_t)UMD_DS_W * 4);
	if (pic1 && pic1->rgba && pic1->w > 0 && pic1->h > 0) {
		int64_t W16 = (int64_t)pic1->w << 16, H16 = (int64_t)pic1->h << 16;
		if (fit == 1) scale_into(px, stride, layout, pic1, 0, 0, W16, H16, 0, 60, UMD_DS_W, 360);
		else if (fit == 2) scale_into(px, stride, layout, pic1, W16 * 107 / 854, 0, W16 * 640 / 854, H16, 0, 0, UMD_DS_W, UMD_DS_H);
		else scale_into(px, stride, layout, pic1, 0, 0, W16, H16, 0, 0, UMD_DS_W, UMD_DS_H);
	}
	put_rbox(px, stride, layout, UMD_DS_BOX_X, UMD_DS_BOX_Y, UMD_DS_BOX_W, UMD_DS_BOX_H);
	int ix = UMD_DS_BOX_X + UMD_DS_PAD, iy = UMD_DS_BOX_Y + UMD_DS_PAD;
	int tx = ix + 6;
	if (icon0 && icon0->rgba && icon0->w > 0 && icon0->h > 0) {
		scale_into(px, stride, layout, icon0, 0, 0, (int64_t)icon0->w << 16, (int64_t)icon0->h << 16, ix, iy,
		           UMD_DS_ICON_W, UMD_DS_ICON_H);
		tx = ix + UMD_DS_ICON_W + 18;
	}
	char lines[DS_LINES][DS_LINE_MAX];
	int n = wrap(title ? title : "", (UMD_DS_BOX_X + UMD_DS_BOX_W - 14 - tx) / UMD_PANEL_FONT_CW, lines);
	for (int k = 0; k < n; k++) put_text(px, stride, layout, lines[k], tx, iy + 4 + k * UMD_PANEL_FONT_CH, WHITE);
	if (hint && hint[0]) put_text(px, stride, layout, hint, tx, iy + UMD_DS_ICON_H - UMD_PANEL_FONT_CH, GREY);
}
