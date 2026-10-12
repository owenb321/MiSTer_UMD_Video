// hps_sub_check.cpp -- B1's harness (docs/hps_host.md §6): main/support/umd/umd_sub.cpp,
// the HPS subtitle decoder, against an oracle written apart from it, case by case.
//
//   hps_sub_check LIST [--digest OUT]
//
// LIST: one case a line, "path ux uy name" (bench/umd/run_hps_sub.sh writes it).
//
// The oracle is tools/png_oracle.c's decode, in-process: libpng with ITS interlace
// handling and the whole image in memory (umd_sub places Adam7 itself, a row at a time),
// umd_sub's size bounds (umd_sub.h), the 16-bit samples kept. The plane it expects is built
// here with the premultiply written another way ((2ca + 255) / 510, round-half-up of
// c*a/255: tools/sub_golden.py asserts the two agree) and its own placement and clip.
//
// Arms (each line "FAIL [arm] ..."; run_hps_sub.sh --red proves each can fail):
//   [verdict]  umd_sub refuses exactly what the oracle refuses
//   [size]     w, h as the oracle's IHDR
//   [pixel]    every pixel of the image inside 720 x 480 equal to the oracle's, premultiplied
//   [clip]     the clipped count, and NOTHING written outside the image's rectangle (the
//              rest of the plane and a guard band after it keep their sentinel)
//   [ring]     umd_ring_copy gives the unit's bytes back from a ring it wraps in
//   [cancel]   a cancel hook stops a decode with UMD_SUB_CANCELLED
//
// --digest: per case "name verdict w h clipped crc" (crc: CRC-32 of the visible pixels
// in raster order, little-endian words): the runner diffs the system libpng's run
// against the device's libpng's (1.6.37), and tools/hps_sub_cases.py checks the synthetic ones against
// tools/sub_golden.py's plane words.

#include <setjmp.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#ifdef UMD_SUB_SYSTEM_PNG
#include <png.h>
#else
#include "libpng/png.h"
#endif

#include "umd_sub.h"

#define GUARD 4096
#define SENT 0x5A3C96E1u

static unsigned long n_fail = 0;
// each arm prints its first few failures: one arm's flood must not hide another's
static const char *arms[] = {"verdict", "size", "pixel", "clip", "ring", "cancel"};
static unsigned long arm_n[6];
static void fail(const char *arm, const char *name, const char *fmt, ...)
	__attribute__((format(printf, 3, 4)));
static void fail(const char *arm, const char *name, const char *fmt, ...)
{
	n_fail++;
	for (int k = 0; k < 6; k++)
		if (!strcmp(arms[k], arm) && arm_n[k]++ >= 5) return;
	va_list ap;
	printf("FAIL [%s] %s: ", arm, name);
	va_start(ap, fmt);
	vprintf(fmt, ap);
	va_end(ap);
	printf("\n");
}

// ---------------------------------------------------------------- the oracle
typedef struct { const uint8_t *p; size_t len, pos; } orc_rd;
static void orc_read(png_structp p, png_bytep out, png_size_t n)
{
	orc_rd *s = (orc_rd *)png_get_io_ptr(p);
	if (n > s->len - s->pos) png_error(p, "Read Error");
	memcpy(out, s->p + s->pos, n);
	s->pos += n;
}
static void orc_err(png_structp p, png_const_charp m) { (void)m; png_longjmp(p, 1); }
static void orc_warn(png_structp p, png_const_charp m) { (void)p; (void)m; }

// -> 1 OK (px: w*h*4 16-bit samples R, G, B, A, malloc'd), 0 refused
static int oracle(const uint8_t *png, size_t len, uint32_t *ow, uint32_t *oh, uint16_t **px)
{
	orc_rd s = {png, len, 0};
	png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, orc_err, orc_warn);
	png_infop info = png_create_info_struct(p);
	png_bytep *volatile rows = NULL;
	volatile png_uint_32 hh = 0;
	*px = NULL;
	if (setjmp(png_jmpbuf(p))) {
		if (rows) { for (png_uint_32 y = 0; y < hh; y++) free(rows[y]); free(rows); }
		png_destroy_read_struct(&p, &info, NULL);
		return 0;
	}
	png_set_benign_errors(p, 1);
	png_set_user_limits(p, UMD_PNG_WMAX, UMD_PNG_HMAX);   // umd_sub's bounds (umd_sub.h)
	png_set_read_fn(p, &s, orc_read);
	png_read_info(p, info);
	png_uint_32 w = png_get_image_width(p, info), h = png_get_image_height(p, info);
	int ctype = png_get_color_type(p, info);
	png_set_expand(p);
	png_set_expand_16(p);
	png_set_gray_to_rgb(p);
	if (!(ctype & PNG_COLOR_MASK_ALPHA) && !png_get_valid(p, info, PNG_INFO_tRNS))
		png_set_add_alpha(p, 0xFFFF, PNG_FILLER_AFTER);
	png_set_interlace_handling(p);
	png_read_update_info(p, info);
	size_t rb = png_get_rowbytes(p, info);
	if (rb != (size_t)w * 8) png_error(p, "oracle: row bytes");
	rows = (png_bytep *)calloc(h ? h : 1, sizeof(png_bytep));
	for (png_uint_32 y = 0; y < h; y++) { rows[y] = (png_bytep)malloc(rb ? rb : 1); hh = y + 1; }
	png_read_image(p, rows);
	png_read_end(p, NULL);
	uint16_t *o = (uint16_t *)malloc((size_t)w * h * 8 + 8);
	for (png_uint_32 y = 0; y < h; y++) {
		for (size_t i = 0; i < (size_t)w * 4; i++)
			o[(size_t)y * w * 4 + i] = (uint16_t)(rows[y][2 * i] << 8 | rows[y][2 * i + 1]);
		free(rows[y]);
	}
	free(rows);
	png_destroy_read_struct(&p, &info, NULL);
	*ow = w; *oh = h; *px = o;
	return 1;
}

static uint32_t premul_ref(uint32_t c, uint32_t a) { return (2 * c * a + 255) / 510; }

// ---------------------------------------------------------------- arms
static int stop_after;
static int cancel_hook(void *arg) { (void)arg; return stop_after-- <= 0; }

static uint8_t *slurp(const char *path, size_t *len)
{
	FILE *f = fopen(path, "rb");
	if (!f) return NULL;
	fseek(f, 0, SEEK_END);
	long n = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = (uint8_t *)malloc(n > 0 ? n : 1);
	if (fread(b, 1, n, f) != (size_t)n) { fclose(f); free(b); return NULL; }
	fclose(f);
	*len = (size_t)n;
	return b;
}

int main(int argc, char **argv)
{
	if (argc < 2) { fprintf(stderr, "usage: hps_sub_check LIST [--digest OUT]\n"); return 2; }
	FILE *lf = fopen(argv[1], "r");
	if (!lf) { perror(argv[1]); return 2; }
	FILE *dg = NULL;
	if (argc >= 4 && !strcmp(argv[2], "--digest")) dg = fopen(argv[3], "w");

	const size_t NP = (size_t)UMD_PLANE_W * UMD_PLANE_H;
	uint32_t *plane = (uint32_t *)malloc((NP + GUARD) * 4);
#define REFILL() do { for (size_t i_ = 0; i_ < NP + GUARD; i_++) plane[i_] = SENT; } while (0)
	REFILL();                       // a valid case resets what it wrote; anything else refills
	unsigned long n = 0, n_ok = 0, n_ref = 0, n_clip_px = 0, n_ring = 0, n_cancel = 0, n_adam7 = 0;
	char line[4096], path[3000], name[1000];
	unsigned ux, uy;
	while (fgets(line, sizeof(line), lf)) {
		if (sscanf(line, "%2999s %u %u %999s", path, &ux, &uy, name) != 4) continue;
		size_t len;
		uint8_t *png = slurp(path, &len);
		if (!png) { fail("verdict", name, "cannot read %s", path); continue; }
		n++;

		uint32_t ow = 0, oh = 0;
		uint16_t *px;
		int ook = oracle(png, len, &ow, &oh, &px);

		umd_sub_result r;
		umd_sub_decode(png, len, ux, uy, plane, &r, NULL, NULL);

		// [verdict]
		if ((r.err == UMD_SUB_OK) != (ook == 1)) {
			fail("verdict", name, "oracle %s, umd_sub err %d (%s)", ook ? "OK" : "refuses", r.err, r.msg);
			free(px); free(png);
			REFILL();
			continue;
		}
		uint32_t crc = 0, clipped = 0;
		if (ook) {
			n_ok++;
			if (len > 28 && png[28]) n_adam7++;
			// [size]
			if (r.w != ow || r.h != oh)
				fail("size", name, "%ux%u, oracle %ux%u", r.w, r.h, ow, oh);
			// [pixel] + the expected rectangle
			uLong c = crc32(0L, Z_NULL, 0);
			unsigned long bad = 0;
			for (uint32_t y = 0; y < oh; y++)
				for (uint32_t x = 0; x < ow; x++) {
					uint64_t ax = (uint64_t)x + ux, ay = (uint64_t)y + uy;
					if (ax >= UMD_PLANE_W || ay >= UMD_PLANE_H) { clipped++; continue; }
					const uint16_t *s = px + ((size_t)y * ow + x) * 4;
					uint32_t a = s[3] >> 8;
					uint32_t e = a << 24 | premul_ref(s[0] >> 8, a) << 16 |
					             premul_ref(s[1] >> 8, a) << 8 | premul_ref(s[2] >> 8, a);
					uint32_t g = plane[ay * UMD_PLANE_W + ax];
					if (g != e && bad++ == 0)
						fail("pixel", name, "(%u,%u) got %08x want %08x", x, y, g, e);
					uint8_t le[4] = {(uint8_t)e, (uint8_t)(e >> 8), (uint8_t)(e >> 16), (uint8_t)(e >> 24)};
					c = crc32(c, le, 4);
				}
			crc = (uint32_t)c;
			// [clip]: the count, and nothing outside the rectangle
			if (r.clipped != clipped)
				fail("clip", name, "clipped %u, want %u", r.clipped, clipped);
			// row by row against a sentinel row (memcmp), then the guard band
			static uint32_t srow[UMD_PLANE_W];
			if (srow[0] != SENT) for (int i = 0; i < UMD_PLANE_W; i++) srow[i] = SENT;
			for (uint32_t Y = 0; Y < UMD_PLANE_H; Y++) {
				uint32_t *row = plane + (size_t)Y * UMD_PLANE_W;
				uint32_t a = 0, b = 0;                      // [a, b): the image's columns here
				if (Y >= uy && (uint64_t)Y < (uint64_t)uy + oh && ux < UMD_PLANE_W) {
					a = ux;
					b = (uint64_t)ux + ow < UMD_PLANE_W ? ux + ow : UMD_PLANE_W;
				}
				if ((a > 0 && memcmp(row, srow, a * 4)) ||
				    (b < UMD_PLANE_W && memcmp(row + b, srow, (UMD_PLANE_W - b) * 4))) {
					fail("clip", name, "a write outside the image on plane row %u", Y);
					break;
				}
				for (uint32_t x = a; x < b; x++) row[x] = SENT;   // reset for the next case
			}
			for (size_t i = NP; i < NP + GUARD; i++)
				if (plane[i] != SENT) { fail("clip", name, "a write past the plane (guard word %zu)", i - NP); break; }
			n_clip_px += clipped;
		} else {
			n_ref++;
			REFILL();                   // a refused decode may have written rows before failing
		}
		if (dg)
			fprintf(dg, "%s %s %u %u %u %08x\n", name, ook ? "OK" : "REF", ook ? ow : 0, ook ? oh : 0, clipped, crc);

		// [ring]: the unit put in a ring it wraps in, read back
		{
			uint32_t rw = 64;
			while ((uint64_t)rw * 8 < len + 16) rw <<= 1;
			uint32_t *ring = (uint32_t *)malloc((size_t)rw * 8);
			uint8_t *rb = (uint8_t *)ring;
			uint32_t start = rw - 1;                        // 8 bytes before the end: it wraps
			for (size_t i = 0; i < len; i++)
				rb[((uint64_t)start * 8 + i) % ((uint64_t)rw * 8)] = png[i];
			uint8_t *back = (uint8_t *)malloc(len ? len : 1);
			size_t got = umd_ring_copy(ring, rw, start, (uint32_t)len, back);
			if (got != len || memcmp(back, png, len))
				fail("ring", name, "%zu bytes back of %zu, or not the unit's", got, len);
			else
				n_ring++;
			if (umd_ring_copy(ring, rw, 0, rw * 8 + 1, back) != 0)
				fail("ring", name, "a unit longer than the ring was not refused");
			free(back); free(ring);
		}
		// [cancel]: once per valid image of two rows or more
		if (ook && oh >= 2 && n_cancel < 50) {
			stop_after = 1;
			umd_sub_decode(png, len, ux, uy, plane, &r, cancel_hook, NULL);
			if (r.err != UMD_SUB_CANCELLED)
				fail("cancel", name, "err %d after the hook asked to stop", r.err);
			else
				n_cancel++;
			REFILL();
		}
		free(px);
		free(png);
	}
	fclose(lf);
	if (dg) fclose(dg);
	printf("hps_sub_check: %lu cases (%lu OK, %lu refused, %lu Adam7), %lu pixels clipped, ring %lu, cancel %lu; libpng %s\n",
	       n, n_ok, n_ref, n_adam7, n_clip_px, n_ring, n_cancel, png_get_libpng_ver(NULL));
	if (n == 0) { printf("FAIL [verdict] no cases\n"); return 1; }
	if (n_fail) { printf("FAIL hps_sub_check: %lu failures\n", n_fail); return 1; }
	printf("PASS hps_sub_check\n");
	return 0;
}
