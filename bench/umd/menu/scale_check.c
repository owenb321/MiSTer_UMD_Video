// scale_check.c -- M4h, THE CANVAS SCALE (menu.c menu_scale; docs/p9.md M4h): the stretch of the menu's
// 480 x 272 canvas onto the plane, against
//   [def]   a reference written from the definition alone, one pixel and one channel at a time (no lanes,
//           no vectors, no line cache, no column tables): EQUAL, every pixel;
//   [clip]  random clips (widths not a multiple of 4: the vector step's tail) against the whole call:
//           EQUAL inside the clip, the target untouched outside it;
//   [one]   1:1 (the source onto itself): the source, EXACTLY;
//   [float] a float bilinear at the same centres, clamped at the edges: within 7 LSB -- the bound derived,
//           not fitted: per axis the weight's 8 bits (<= 1/256) and the 16.16 position over 720 steps
//           (<= 0.0055 px) move a sample by <= 0.0094 x 255 = 2.4, the truncating lerp by < 1; the vertical
//           lerp carries the horizontal error and adds its own: < 6.8. Measured 3-4 on random sources; a
//           misplaced centre or a swapped weight is tens of LSB (the definition's own check);
//   [edge]  the clamp: a source whose border column / row is unique reaches the target's border.
// The cases: the runner's three fits (Fit 480 x 272 -> 720 x 480, Letterbox -> 720 x 360, Crop's view
// (60.14, 0, 359.72, 272) -> 720 x 480), and odd geometries (a downscale, a sub-rectangle, 1:1).
// PASS line "scale_check: ... PASS", $-exit nonzero on any failure.
#include "menu.h"

#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rs = 12345;
static uint32_t rnd(void) { rs = rs * 1664525u + 1013904223u; return rs >> 8; }

// the definition: the target pixel X's source position u = rx + (X + 0.5) rw / dw - 0.5 in 16.16 as
// first + X x step (both rounded once), the two columns floor(u) and floor(u) + 1 clamped to the source,
// the weight u's fraction's top 8 bits; the same for rows; per channel lerp(lerp(row v0), lerp(row v1)),
// each lerp (a (256 - w) + b w) >> 8
static void ref_scale(const uint8_t *s, int sw, int sh, uint8_t *d, int dw, int dh, float rx, float ry, float rw, float rh)
{
	long du = lroundf(rw / (float)dw * 65536.0f), dv = lroundf(rh / (float)dh * 65536.0f);
	long uf = lroundf((rx + 0.5f * rw / (float)dw - 0.5f) * 65536.0f), vf = lroundf((ry + 0.5f * rh / (float)dh - 0.5f) * 65536.0f);
	for (int Y = 0; Y < dh; Y++) {
		long V = vf + (long)Y * dv;
		long v0 = (long)floor((double)V / 65536.0);
		int fv = (int)((V - v0 * 65536) >> 8);
		long v1 = v0 + 1;
		v0 = v0 < 0 ? 0 : v0 > sh - 1 ? sh - 1 : v0;
		v1 = v1 < 0 ? 0 : v1 > sh - 1 ? sh - 1 : v1;
		for (int X = 0; X < dw; X++) {
			long U = uf + (long)X * du;
			long u0 = (long)floor((double)U / 65536.0);
			int fu = (int)((U - u0 * 65536) >> 8);
			long u1 = u0 + 1;
			u0 = u0 < 0 ? 0 : u0 > sw - 1 ? sw - 1 : u0;
			u1 = u1 < 0 ? 0 : u1 > sw - 1 ? sw - 1 : u1;
			for (int c = 0; c < 4; c++) {
				int p00 = s[4 * (v0 * sw + u0) + c], p01 = s[4 * (v0 * sw + u1) + c];
				int p10 = s[4 * (v1 * sw + u0) + c], p11 = s[4 * (v1 * sw + u1) + c];
				int a = (p00 * (256 - fu) + p01 * fu) >> 8, b = (p10 * (256 - fu) + p11 * fu) >> 8;
				d[4 * ((size_t)Y * dw + X) + c] = (uint8_t)((a * (256 - fv) + b * fv) >> 8);
			}
		}
	}
}

static double flt_px(const uint8_t *s, int sw, int sh, int dw, int dh, float rx, float ry, float rw, float rh, int X, int Y, int c)
{
	double u = rx + (X + 0.5) * rw / dw - 0.5, v = ry + (Y + 0.5) * rh / dh - 0.5;
	double fu0 = floor(u), fv0 = floor(v), fu = u - fu0, fv = v - fv0;
	long u0 = (long)fu0, v0 = (long)fv0, u1 = u0 + 1, v1 = v0 + 1;
	u0 = u0 < 0 ? 0 : u0 > sw - 1 ? sw - 1 : u0; u1 = u1 < 0 ? 0 : u1 > sw - 1 ? sw - 1 : u1;
	v0 = v0 < 0 ? 0 : v0 > sh - 1 ? sh - 1 : v0; v1 = v1 < 0 ? 0 : v1 > sh - 1 ? sh - 1 : v1;
	double a = s[4 * (v0 * sw + u0) + c] * (1 - fu) + s[4 * (v0 * sw + u1) + c] * fu;
	double b = s[4 * (v1 * sw + u0) + c] * (1 - fu) + s[4 * (v1 * sw + u1) + c] * fu;
	return a * (1 - fv) + b * fv;
}

static int fails;
static long checked;
static void fail(const char *what) { if (fails++ < 12) printf("FAIL %s\n", what); }

static void one_case(const char *name, int sw, int sh, int dw, int dh, float rx, float ry, float rw, float rh, int smooth)
{
	uint8_t *s = malloc((size_t)sw * sh * 4), *d = malloc((size_t)dw * dh * 4), *ref = malloc((size_t)dw * dh * 4),
	        *c = malloc((size_t)dw * dh * 4);
	// a source: random, or (smooth) gradients with sharp edges -- every byte in use, premultiplied or not
	// (the stretch treats every channel alike)
	for (int y = 0; y < sh; y++)
		for (int x = 0; x < sw; x++)
			for (int k = 0; k < 4; k++)
				s[4 * (y * sw + x) + k] = smooth ? (uint8_t)((x * (k + 3) + y * (5 - k) + ((x / 17 + y / 11) & 1) * 120) & 0xFF) : (uint8_t)rnd();
	char what[200];
	// [def]
	memset(d, 0xA5, (size_t)dw * dh * 4);
	menu_scale(s, sw, sh, sw * 4, d, dw, dh, dw * 4, rx, ry, rw, rh, NULL);
	ref_scale(s, sw, sh, ref, dw, dh, rx, ry, rw, rh);
	for (size_t i = 0; i < (size_t)dw * dh * 4; i++)
		if (d[i] != ref[i]) { snprintf(what, sizeof(what), "[def] %s: pixel %zu channel %zu: %u, the definition %u", name, i / 4 % dw, i % 4, d[i], ref[i]); fail(what); break; }
	checked += (long)dw * dh;
	// [float]
	int worst = 0;
	for (int Y = 0; Y < dh; Y++)
		for (int X = 0; X < dw; X++)
			for (int k = 0; k < 4; k++) {
				int e = (int)lround(fabs(flt_px(s, sw, sh, dw, dh, rx, ry, rw, rh, X, Y, k) - d[4 * ((size_t)Y * dw + X) + k]) + 0.4999);
				if (e > worst) worst = e;
			}
	if (worst > 7) { snprintf(what, sizeof(what), "[float] %s: %d LSB from the float bilinear (bound 7)", name, worst); fail(what); }
	// [clip]
	for (int t = 0; t < 40; t++) {
		int x0 = (int)(rnd() % (unsigned)dw), y0 = (int)(rnd() % (unsigned)dh);
		int x1 = x0 + 1 + (int)(rnd() % (unsigned)(dw - x0)), y1 = y0 + 1 + (int)(rnd() % (unsigned)(dh - y0));
		if (t == 0) { x0 = 0; y0 = 0; x1 = dw; y1 = dh; }
		int clip[4] = { x0, y0, x1, y1 };
		memset(c, 0x5A, (size_t)dw * dh * 4);
		menu_scale(s, sw, sh, sw * 4, c, dw, dh, dw * 4, rx, ry, rw, rh, clip);
		for (int Y = 0; Y < dh; Y++)
			for (int X = 0; X < dw; X++) {
				int in = X >= x0 && X < x1 && Y >= y0 && Y < y1;
				for (int k = 0; k < 4; k++) {
					uint8_t g = c[4 * ((size_t)Y * dw + X) + k], w = in ? d[4 * ((size_t)Y * dw + X) + k] : 0x5A;
					if (g != w) {
						snprintf(what, sizeof(what), "[clip] %s: clip (%d,%d)-(%d,%d) pixel (%d,%d): %u, %s %u", name, x0, y0, x1, y1, X, Y, g, in ? "the whole call" : "untouched", w);
						fail(what);
						Y = dh; X = dw; t = 40;
						break;
					}
				}
			}
	}
	printf("  %-34s %4dx%-4d -> %4dx%-4d view (%.2f, %.2f, %.2f, %.2f): float within %d\n", name, sw, sh, dw, dh, (double)rx, (double)ry, (double)rw, (double)rh, worst);
	free(s); free(d); free(ref); free(c);
}

int main(void)
{
	// the runner's fits (umd_menu_run.c mr_fit): the canvas 480 x 272
	one_case("Fit", 480, 272, 720, 480, 0, 0, 480, 272, 1);
	one_case("Fit (random)", 480, 272, 720, 480, 0, 0, 480, 272, 0);
	one_case("Letterbox", 480, 272, 720, 360, 0, 0, 480, 272, 1);
	one_case("Crop", 480, 272, 720, 480, (107.0f) * 480.0f / 854.0f, 0, 640.0f * 480.0f / 854.0f, 272, 1);
	one_case("Crop (random)", 480, 272, 720, 480, (107.0f) * 480.0f / 854.0f, 0, 640.0f * 480.0f / 854.0f, 272, 0);
	// odd geometries: a downscale, a sub-rectangle, widths not a multiple of 4
	one_case("downscale 300x200 -> 97x51", 300, 200, 97, 51, 0, 0, 300, 200, 0);
	one_case("sub-rectangle", 64, 48, 133, 71, 10.3f, 5.7f, 40.2f, 30.9f, 0);
	// [one]: 1:1 is a copy
	{
		int sw = 37, sh = 23;
		uint8_t *s = malloc((size_t)sw * sh * 4), *d = malloc((size_t)sw * sh * 4);
		for (int i = 0; i < sw * sh * 4; i++) s[i] = (uint8_t)rnd();
		menu_scale(s, sw, sh, sw * 4, d, sw, sh, sw * 4, 0, 0, (float)sw, (float)sh, NULL);
		if (memcmp(s, d, (size_t)sw * sh * 4)) fail("[one] 1:1 is not the source");
		else printf("  1:1 (37 x 23): the source exactly\n");
		free(s); free(d);
	}
	// [edge]: a 2 x 2 source with four distinct pixels stretched: the target's corners are those pixels
	{
		uint8_t s[16] = { 10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 150, 160 }, d[9 * 7 * 4];
		menu_scale(s, 2, 2, 8, d, 9, 7, 36, 0, 0, 2, 2, NULL);
		int ok = !memcmp(d, s, 4) && !memcmp(d + 4 * 8, s + 4, 4) && !memcmp(d + 4 * 6 * 9, s + 8, 4) && !memcmp(d + 4 * (6 * 9 + 8), s + 12, 4);
		if (!ok) fail("[edge] the corners of a stretched 2 x 2 are not its pixels (the clamp)");
		else printf("  edge: a 2 x 2 stretched to 9 x 7 keeps its corners (the clamp)\n");
	}
	if (fails) { printf("scale_check: %d FAIL\n", fails); return 1; }
	printf("scale_check: %ld target pixels equal to the definition, clips exact, 1:1 a copy -- PASS\n", checked);
	return 0;
}
