// umd_sub.cpp -- see umd_sub.h and docs/hps_host.md §3.3.
//
// The decode is libpng's (H4): the transforms are tools/png_oracle.c's -- the oracle that
// scored the fabric decoder -- so every pixel is libpng's by construction: expand
// (palette, low-depth grey, tRNS -> alpha, the key compared at the raw depth), expand to
// 16 bits, grey -> RGB, an opaque alpha added when there is none. The 8-bit value is the
// 16-bit sample's high byte (png_oracle.c's own convention, and the fabric's png_pixel).
//
// A PALETTE image (every subtitle unit of the library: 4-bit, docs/hps_host.md §6 "B2, the
// results") skips libpng's expansion: libpng hands over the indices (png_set_packing) and a
// 256-entry table maps each to its premultiplied word. The table is the general path's pixel
// by construction -- libpng expands an index to its PLTE entry (zero past the PLTE: libpng
// allocates the palette whole) and its tRNS alpha (255 past the tRNS), and an 8-bit sample
// expanded to 16 bits is v * 257, whose high byte is v -- and run_hps_sub.sh holds it to the
// oracle's libpng expansion on every case. On the A9 it is ~2.4x faster (B2: 26.8 vs 64.6 ms
// on a 720 x 480 unit), which is what puts the decode inside B2's 50 ms budget.
//
// The plane is written a row at a time from a line buffer: contiguous pixels (every pass of
// a non-interlaced image) as aligned 64-bit pairs, one 32-bit store at an odd start or a
// lone end; Adam7's spaced pixels one 32-bit store each. A 64-bit store halves the uncached
// write (B2: 137 vs 68 MB/s).
//
// Adam7 is placed HERE, not by png_set_interlace_handling: libpng's handling needs the
// whole image in memory, ours needs one row, so memory is bounded by the width alone
// for any height (a spec-maximum PNG on a 1 GB HPS). Without the handling, libpng hands
// over each pass's reduced rows in order and skips a pass with no rows or no columns
// (png_read_finish_row) -- the same passes the loop below walks.
//
// setjmp / longjmp is libpng's error path; this file holds no C++ objects across it,
// and the locals the error path reads are volatile.
//
// No `function`-style cleverness: plain loops, so the PC build (bench/umd/run_hps_sub.sh)
// and the ARM build are the same code.

#include <setjmp.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef UMD_SUB_SYSTEM_PNG
#include <png.h>                       // the PC's libpng (run_hps_sub.sh's first arm)
#else
#include "libpng/png.h"                // 1.6.37's headers: the version Main runs with (NOTICE)
#endif

#include "umd_sub.h"

// Adam7 (PNG 8.2): x0, y0, dx, dy per pass
static const uint8_t A7[7][4] = {
	{0, 0, 8, 8}, {4, 0, 8, 8}, {0, 4, 4, 8}, {2, 0, 4, 4},
	{0, 2, 2, 4}, {1, 0, 2, 2}, {0, 1, 1, 2}
};

typedef struct {
	const uint8_t *p;
	size_t len, pos;
	umd_sub_result *r;
} rd_t;

static void on_read(png_structp png, png_bytep out, png_size_t n)
{
	rd_t *s = (rd_t *)png_get_io_ptr(png);
	if (n > s->len - s->pos)
		png_error(png, "Read Error");  // libpng's own wording for a short stream
	memcpy(out, s->p + s->pos, n);
	s->pos += n;
}

static void on_error(png_structp png, png_const_charp msg)
{
	rd_t *s = (rd_t *)png_get_error_ptr(png);
	snprintf(s->r->msg, sizeof(s->r->msg), "%s", msg);
	png_longjmp(png, 1);
}

static void on_warn(png_structp png, png_const_charp msg)
{
	(void)png; (void)msg;              // benign errors are warnings (png_set_benign_errors)
}

static inline uint32_t premul(uint32_t c, uint32_t a)
{
	uint32_t t = c * a + 128;
	return (t + (t >> 8)) >> 8;
}

// n contiguous pixels v[] at x = ax of one plane row (the row's base is 8-byte aligned:
// the plane is, and its pitch is 720 words): pixel x is the low half of a 64-bit word
// when x is even (little-endian, sub_plane_wr.sv's pair order)
static void put_run(volatile uint32_t *dst, uint32_t ax, const uint32_t *v, uint32_t n)
{
	uint32_t i = 0;
	if (n && (ax & 1)) {
		dst[ax] = v[0];
		i = 1;
	}
	volatile uint64_t *d64 = (volatile uint64_t *)(dst + ax + i);
	for (; i + 1 < n; i += 2)
		*d64++ = v[i] | (uint64_t)v[i + 1] << 32;
	if (i < n)
		dst[ax + i] = v[i];
}

int umd_sub_decode(const uint8_t *png, size_t len, uint32_t ux, uint32_t uy,
                   volatile uint32_t *plane, umd_sub_result *r,
                   int (*cancel)(void *), void *cancel_arg)
{
	memset(r, 0, sizeof(*r));
	rd_t src;
	src.p = png; src.len = len; src.pos = 0; src.r = r;

	png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, &src, on_error, on_warn);
	if (!p) { r->err = UMD_SUB_NOMEM; return r->err; }
	png_infop info = png_create_info_struct(p);
	png_bytep volatile row = NULL;      // freed on every exit, longjmp included
	volatile int status = UMD_SUB_REFUSED;
	if (!info) { png_destroy_read_struct(&p, NULL, NULL); r->err = UMD_SUB_NOMEM; return r->err; }

	if (setjmp(png_jmpbuf(p))) {
		r->err = status;
		if (status == UMD_SUB_REFUSED) r->clipped = 0;
		free(row);
		png_destroy_read_struct(&p, &info, NULL);
		return r->err;
	}
	png_set_benign_errors(p, 1);
	png_set_user_limits(p, UMD_PNG_WMAX, UMD_PNG_HMAX);
	png_set_read_fn(p, &src, on_read);
	png_read_info(p, info);
	png_uint_32 w = png_get_image_width(p, info), h = png_get_image_height(p, info);
	int ctype = png_get_color_type(p, info);
	int il = png_get_interlace_type(p, info);
	r->w = w; r->h = h;
	int pal = ctype == PNG_COLOR_TYPE_PALETTE;
	uint32_t lut[256];
	if (pal) {
		png_colorp plte = NULL;
		int nplte = 0, ntrns = 0;
		png_bytep trns = NULL;
		png_get_PLTE(p, info, &plte, &nplte);
		if (png_get_valid(p, info, PNG_INFO_tRNS))
			png_get_tRNS(p, info, &trns, &ntrns, NULL);
		for (int i = 0; i < 256; i++) {
			uint32_t a = i < ntrns ? trns[i] : 255;
			uint32_t cr = 0, cg = 0, cb = 0;
			if (i < nplte) { cr = plte[i].red; cg = plte[i].green; cb = plte[i].blue; }
			lut[i] = a << 24 | premul(cr, a) << 16 | premul(cg, a) << 8 | premul(cb, a);
		}
		png_set_packing(p);             // one index a byte at depths 1, 2, 4
	} else {
		png_set_expand(p);
		png_set_expand_16(p);
		png_set_gray_to_rgb(p);
		if (!(ctype & PNG_COLOR_MASK_ALPHA) && !png_get_valid(p, info, PNG_INFO_tRNS))
			png_set_add_alpha(p, 0xFFFF, PNG_FILLER_AFTER);
	}
	png_read_update_info(p, info);
	size_t rb = png_get_rowbytes(p, info);
	size_t want = pal ? (size_t)w : (size_t)w * 8;   // indices, or RGBA x 16 bits
	if (rb != want) {
		snprintf(r->msg, sizeof(r->msg), "row bytes %zu, expected %zu", rb, want);
		png_longjmp(p, 1);
	}
	row = (png_bytep)malloc(rb ? rb : 1);
	if (!row) { status = UMD_SUB_NOMEM; png_longjmp(p, 1); }

	int npass = il == PNG_INTERLACE_ADAM7 ? 7 : 1;
	uint32_t written = 0;
	uint32_t line[UMD_PLANE_W];         // one row's visible pixels, premultiplied
	for (int pass = 0; pass < npass; pass++) {
		uint32_t x0 = 0, y0 = 0, dx = 1, dy = 1;
		if (npass == 7) { x0 = A7[pass][0]; y0 = A7[pass][1]; dx = A7[pass][2]; dy = A7[pass][3]; }
		if (w <= x0 || h <= y0)
			continue;                   // an empty pass: libpng skips it too
		uint32_t pw = (w - x0 + dx - 1) / dx;
		for (uint32_t y = y0; y < h; y += dy) {
			if (cancel && cancel(cancel_arg)) { status = UMD_SUB_CANCELLED; png_longjmp(p, 1); }
			png_read_row(p, row, NULL);
			uint32_t ay = y + uy;
			if (ay >= UMD_PLANE_H)
				continue;               // decoded for the verdict, not shown
			// the pixels of this row on the plane: i < n (the rest is off its right edge)
			uint64_t sx = (uint64_t)ux + x0;
			uint32_t n = 0;
			if (sx < UMD_PLANE_W) {
				uint64_t fit = (UMD_PLANE_W - sx + dx - 1) / dx;
				n = fit < pw ? (uint32_t)fit : pw;
			}
			if (n > UMD_PLANE_W)
				n = UMD_PLANE_W;            // never true (fit <= 720 - sx); line[]'s bound, kept explicit
			if (pal) {
				for (uint32_t i = 0; i < n; i++)
					line[i] = lut[row[i]];
			} else {
				for (uint32_t i = 0; i < n; i++) {
					const png_byte *s = row + (size_t)i * 8;   // R, G, B, A, 16 bits big-endian
					uint32_t a = s[6];
					line[i] = a << 24 | premul(s[0], a) << 16 | premul(s[2], a) << 8 | premul(s[4], a);
				}
			}
			volatile uint32_t *dst = plane + (size_t)ay * UMD_PLANE_W;
			if (dx == 1)
				put_run(dst, (uint32_t)sx, line, n);
			else
				for (uint32_t i = 0; i < n; i++)
					dst[(uint32_t)sx + i * dx] = line[i];
			written += n;
		}
	}
	png_read_end(p, NULL);
	free(row);
	png_destroy_read_struct(&p, &info, NULL);
	r->err = UMD_SUB_OK;
	uint64_t off = (uint64_t)w * h - written;      // up to ~2^51 at the size bounds:
	r->clipped = off > 0xFFFFFFFFu ? 0xFFFFFFFFu : (uint32_t)off;   // saturates, never wraps
	return r->err;
}

size_t umd_ring_copy(const volatile uint32_t *ring, uint32_t ring_words, uint32_t start,
                     uint32_t len, uint8_t *out)
{
	uint64_t ring_bytes = (uint64_t)ring_words * 8;
	if (len > ring_bytes || start >= ring_words)
		return 0;
	uint64_t pos = (uint64_t)start * 8;
	uint32_t i = 0;
	while (i < len) {
		uint32_t v = ring[pos >> 2];                // pos is 4-aligned: an aligned load
		for (int k = 0; k < 4 && i < len; k++, i++)
			out[i] = (uint8_t)(v >> (8 * k));       // little-endian: the first byte low
		pos += 4;
		if (pos == ring_bytes)
			pos = 0;
	}
	return len;
}
