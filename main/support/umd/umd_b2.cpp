// umd_b2.cpp -- see umd_b2.h and docs/hps_host.md §6 "B2, the procedure".
//
// The commands (each answers with "B2 ..." lines in /tmp/umd_ctl.log):
//   b2 libpng                    the libpng Main runs with: the run-time version, the version
//                                its headers were (vendored), the file the loader
//                                mapped (/proc/self/maps); and the CPU the poll thread is on
//   b2 poll <s>                  the gap between successive passes of Main's poll loop for
//                                <s> seconds, in us: count, median, p99, p99.9, max, the ten
//                                longest with their offset from the start (to match a gap
//                                to the key press that caused it)
//   b2 bw [hps_addr] [32|64|128] uncached write then read rate of a 720 x 480 plane's bytes
//                                at hps_addr (the scratch region by default): 10 writes and
//                                10 reads, ONE PASS A TICK, so the poll stall is one pass; the
//                                reads also check the last pattern (nothing else writes there).
//                                The stores are 32-bit (umd_sub's), 64-bit (strd) or 128-bit
//                                (NEON vst1): the same words either way; the reads are 32-bit
//   b2 decode <png> <ux> <uy> [heap]
//                                umd_sub_decode of a file at (ux, uy) into the scratch region
//                                (uncached, as the host will write the plane), or with "heap"
//                                into malloc'd memory (the decode alone: §6's fallbacks are
//                                about the plane write, so the two terms are measured apart);
//                                wall time, the verdict, w, h, clipped, the RSS now and its
//                                high-water mark, before and after
//   b2 bare8 <png> [heap]        a CEILING, not a decoder: bare libpng to RGBA8 (strip_16) and
//                                the premultiply, rows written at (0, 0) with 32-bit stores into
//                                the scratch region or the heap -- what an 8-bit path in umd_sub
//                                could buy on the A9 (its bit-exactness untested here)
//   b2 pal <png> [heap]          a CEILING for a palette fast path (every subtitle unit of the
//                                library is 4-bit palette): libpng hands over the indices
//                                (png_set_packing), a 256-entry premultiplied table from
//                                PLTE + tRNS, the plane written with 64-bit stores (pixel
//                                pairs; the row at (0, 0), even width assumed for the pairs)
//   b2 spi                       the EXT_BUS cost of a host-port command before the port exists
//                                (B3): 1,000 of the telemetry command (0x7A) at 4 words (a
//                                HOST_WR's size: command + 3) and at every word; us each
//   b2 dump [hps_addr len file]  memory to a file with 32-bit loads, one region a tick; with no
//                                arguments both subtitle planes to /tmp/umd_plane0.bin / 1.bin
//
// The work runs on the poll thread: a measurement, its stall accepted (one pass, one decode,
// one region at a time). A poll measurement refuses to overlap the others (and they it):
// their stall would land in its histogram.
//
// Addresses: the core's 64-bit word W is HPS physical byte W * 8 (hps_host.md §1). The
// scratch region (core word 0x0680_0000) is beyond everything the core uses (the panel's plane 3,
// P6d, ends at word 0x067A_A300; it sat at 0x0670_0000 until P6d took 0x0670_0000-0x067F_FFFF for
// planes 2 / 3, docs/panel.md §2); the planes and the ring are never written from here: the core reads them.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sched.h>
#include <unistd.h>
#include <sys/resource.h>
#include <setjmp.h>

#include "../../shmem.h"
#include "../../spi.h"
#include "libpng/png.h"
#include "umd_sub.h"
#include "umd_ctl.h"
#include "umd_telem_fields.h"
#include "umd_b2.h"

#define B2_SCRATCH      0x34000000u     // core word 0x0680_0000 (P6d: planes 2 / 3 below it)
#define B2_SCRATCH_LEN  (4u << 20)
#define B2_PLANE0       0x32800000u     // core word 0x0650_0000
#define B2_PLANE1       0x32C00000u     // core word 0x0658_0000
#define B2_PLANE_BYTES  (UMD_PLANE_W * UMD_PLANE_H * 4u)
#define B2_PASSES       10

static uint64_t now_us()
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (uint64_t)ts.tv_sec * 1000000u + ts.tv_nsec / 1000u;
}

static uint32_t page_up(uint32_t n) { return (n + 4095u) & ~4095u; }

// ------------------------------------------------------------------ libpng
static void cmd_libpng()
{
	char lib[256] = "(not mapped)";
	FILE *f = fopen("/proc/self/maps", "r");
	if (f)
	{
		char line[512];
		while (fgets(line, sizeof(line), f))
		{
			char *p = strstr(line, "libpng");
			if (!p) continue;
			while (p > line && p[-1] != ' ') p--;
			snprintf(lib, sizeof(lib), "%s", p);
			lib[strcspn(lib, "\n")] = 0;
			break;
		}
		fclose(f);
	}
	umd_ctl_log("B2 libpng run=%s headers=%s file=%s cpu=%d ncpu=%ld",
	            png_get_libpng_ver(NULL), PNG_LIBPNG_VER_STRING, lib, sched_getcpu(),
	            sysconf(_SC_NPROCESSORS_ONLN));
}

// ------------------------------------------------------------------ poll
typedef struct { uint32_t gap, at_ms; } gap_t;
static gap_t   *pg;
static size_t   pg_n, pg_cap;
static uint64_t pg_t0, pg_last, pg_end, pg_sum;
static int      pg_on;

static int by_gap_desc(const void *a, const void *b)
{
	uint32_t x = ((const gap_t *)a)->gap, y = ((const gap_t *)b)->gap;
	return x < y ? 1 : x > y ? -1 : 0;
}

static void poll_finish(uint64_t t)
{
	pg_on = 0;
	if (!pg_n)
	{
		umd_ctl_log("B2 poll: no gaps recorded");
		free(pg); pg = NULL;
		return;
	}
	qsort(pg, pg_n, sizeof(*pg), by_gap_desc);       // longest first
	size_t over50 = 0, over100 = 0, over250 = 0;
	for (size_t i = 0; i < pg_n; i++)
	{
		over50 += pg[i].gap > 50000;
		over100 += pg[i].gap > 100000;
		over250 += pg[i].gap > 250000;
	}
	// rank r of n longest-first is the (1 - r/n) quantile
	#define Q(q) pg[(size_t)((1.0 - (q)) * (pg_n - 1))].gap
	umd_ctl_log("B2 poll %.1f s: n=%zu mean=%.0f us median=%u p99=%u p99.9=%u max=%u us "
	            ">50ms=%zu >100ms=%zu >250ms=%zu",
	            (t - pg_t0) / 1e6, pg_n, (double)pg_sum / pg_n, Q(0.5), Q(0.99),
	            Q(0.999), pg[0].gap, over50, over100, over250);
	#undef Q
	char line[512];
	int k = snprintf(line, sizeof(line), "B2 poll longest (us@ms):");
	for (size_t i = 0; i < pg_n && i < 10; i++)
		k += snprintf(line + k, sizeof(line) - k, " %u@%u", pg[i].gap, pg[i].at_ms);
	umd_ctl_log("%s", line);
	free(pg); pg = NULL;
}

static void poll_sample()
{
	uint64_t t = now_us();
	if (pg_last)
	{
		if (pg_n == pg_cap)
		{
			size_t nc = pg_cap ? pg_cap * 2 : 65536;
			gap_t *np = (gap_t *)realloc(pg, nc * sizeof(*pg));
			if (!np) { umd_ctl_log("B2 poll: out of memory at n=%zu", pg_n); poll_finish(t); return; }
			pg = np; pg_cap = nc;
		}
		pg[pg_n].gap = (uint32_t)(t - pg_last);
		pg_sum += t - pg_last;
		pg[pg_n].at_ms = (uint32_t)((t - pg_t0) / 1000u);
		pg_n++;
	}
	pg_last = t;
	if (t >= pg_end) poll_finish(t);
}

// ------------------------------------------------------------------ bw
static volatile uint32_t *bw_p;
static uint32_t bw_addr, bw_len;
static int      bw_pass = -1;           // 0 .. 2*B2_PASSES-1 while running, -1 idle
static uint32_t bw_us[2][B2_PASSES];
static uint32_t bw_bad;
static int      bw_width = 32;

static inline uint32_t bw_pat(uint32_t i, uint32_t pass) { return i * 2654435761u ^ (pass * 0x9E3779B9u); }

static void bw_step()
{
	const uint32_t nw = B2_PLANE_BYTES / 4;
	int wr = bw_pass < B2_PASSES;
	uint32_t pass = wr ? bw_pass : bw_pass - B2_PASSES;
	uint64_t t0 = now_us();
	if (wr && bw_width == 64)
	{
		volatile uint64_t *q = (volatile uint64_t *)bw_p;
		for (uint32_t i = 0; i < nw; i += 2)
			q[i / 2] = bw_pat(i, pass) | (uint64_t)bw_pat(i + 1, pass) << 32;
		__sync_synchronize();
	}
	else if (wr && bw_width == 128)
	{
		uint32_t v[4] __attribute__((aligned(16)));
		for (uint32_t i = 0; i < nw; i += 4)
		{
			for (int j = 0; j < 4; j++) v[j] = bw_pat(i + j, pass);
			__asm__ volatile(".fpu neon\n\tvld1.32 {d0-d1}, [%1]\n\tvst1.32 {d0-d1}, [%0]"
			                 : : "r"(bw_p + i), "r"(v) : "d0", "d1", "memory");
		}
		__sync_synchronize();
	}
	else if (wr)
	{
		for (uint32_t i = 0; i < nw; i++) bw_p[i] = bw_pat(i, pass);
		__sync_synchronize();
	}
	else
	{
		uint32_t bad = 0;
		for (uint32_t i = 0; i < nw; i++) bad += bw_p[i] != bw_pat(i, B2_PASSES - 1);
		bw_bad += bad;
	}
	bw_us[!wr][pass] = (uint32_t)(now_us() - t0);
	if (++bw_pass < 2 * B2_PASSES) return;

	for (int d = 0; d < 2; d++)
	{
		uint32_t lo = bw_us[d][0], hi = bw_us[d][0];
		uint64_t sum = 0;
		for (int i = 0; i < B2_PASSES; i++)
		{
			if (bw_us[d][i] < lo) lo = bw_us[d][i];
			if (bw_us[d][i] > hi) hi = bw_us[d][i];
			sum += bw_us[d][i];
		}
		umd_ctl_log("B2 bw %s%d 0x%08X %u B x%d: best %.1f MB/s (%u us) worst %.1f MB/s (%u us) mean %.1f MB/s",
		            d ? "read " : "write", d ? 32 : bw_width, bw_addr, B2_PLANE_BYTES, B2_PASSES,
		            B2_PLANE_BYTES / (double)lo, lo, B2_PLANE_BYTES / (double)hi, hi,
		            B2_PLANE_BYTES * (double)B2_PASSES / sum);
	}
	umd_ctl_log("B2 bw readback mismatches: %u words of %u", bw_bad, nw * B2_PASSES);
	shmem_unmap((void *)bw_p, bw_len);
	bw_p = NULL;
	bw_pass = -1;
}

// ------------------------------------------------------------------ dump
typedef struct { uint32_t addr, len; char file[128]; } dump_t;
static dump_t dq[2];
static int    dq_n, dq_i;

static void dump_step()
{
	dump_t *d = &dq[dq_i++];
	uint32_t mlen = page_up(d->len);
	volatile uint32_t *p = (volatile uint32_t *)shmem_map(d->addr, mlen);
	uint32_t *buf = (uint32_t *)malloc(d->len);
	if (!p || !buf)
	{
		umd_ctl_log("B2 dump 0x%08X: %s", d->addr, p ? "out of memory" : "map failed");
	}
	else
	{
		uint64_t t0 = now_us();
		for (uint32_t i = 0; i < d->len / 4; i++) buf[i] = p[i];
		uint32_t us = (uint32_t)(now_us() - t0);
		FILE *f = fopen(d->file, "wb");
		size_t n = f ? fwrite(buf, 1, d->len, f) : 0;
		if (f) fclose(f);
		umd_ctl_log("B2 dump 0x%08X %u B -> %s: %s (%u us)", d->addr, d->len, d->file,
		            n == d->len ? "ok" : "write failed", us);
	}
	if (p) shmem_unmap((void *)p, mlen);
	free(buf);
	if (dq_i >= dq_n) dq_n = dq_i = 0;
}

// ------------------------------------------------------------------ decode
static void rss(long *now_kb, long *max_kb)
{
	*now_kb = -1;
	FILE *f = fopen("/proc/self/statm", "r");
	if (f)
	{
		long size, res;
		if (fscanf(f, "%ld %ld", &size, &res) == 2) *now_kb = res * (sysconf(_SC_PAGESIZE) / 1024);
		fclose(f);
	}
	struct rusage ru;
	getrusage(RUSAGE_SELF, &ru);
	*max_kb = ru.ru_maxrss;
}

static void cmd_decode(const char *path, uint32_t ux, uint32_t uy, int heap)
{
	FILE *f = fopen(path, "rb");
	if (!f) { umd_ctl_log("B2 decode %s: cannot open", path); return; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *png = (uint8_t *)malloc(len > 0 ? len : 1);
	if (!png || fread(png, 1, len, f) != (size_t)len)
	{
		fclose(f); free(png);
		umd_ctl_log("B2 decode %s: read failed", path);
		return;
	}
	fclose(f);

	volatile uint32_t *plane;
	if (heap)
	{
		// touched before the clock starts: the page faults are not the decode's
		plane = (volatile uint32_t *)calloc(UMD_PLANE_W * UMD_PLANE_H, 4);
		if (plane) memset((void *)plane, 0, B2_PLANE_BYTES);
	}
	else
	{
		plane = (volatile uint32_t *)shmem_map(B2_SCRATCH, B2_SCRATCH_LEN);
	}
	if (!plane) { free(png); umd_ctl_log("B2 decode %s: no plane", path); return; }

	long rn0, rm0, rn1, rm1;
	rss(&rn0, &rm0);
	umd_sub_result r;
	uint64_t t0 = now_us();
	umd_sub_decode(png, len, ux, uy, plane, &r, NULL, NULL);
	uint32_t us = (uint32_t)(now_us() - t0);
	rss(&rn1, &rm1);

	umd_ctl_log("B2 decode %s (%ld B) at %u,%u into %s: err=%d%s%s w=%u h=%u clipped=%u "
	            "%u us; rss %ld -> %ld kB, max %ld -> %ld kB",
	            path, len, ux, uy, heap ? "heap" : "scratch", r.err, r.err ? " " : "",
	            r.err ? r.msg : "", r.w, r.h, r.clipped, us, rn0, rn1, rm0, rm1);

	if (heap) free((void *)plane);
	else shmem_unmap((void *)plane, B2_SCRATCH_LEN);
	free(png);
}

// ------------------------------------------------------------------ bare8 (a ceiling)
typedef struct { const uint8_t *p; size_t len, pos; } b8_rd;
static void b8_read(png_structp png, png_bytep out, png_size_t n)
{
	b8_rd *s = (b8_rd *)png_get_io_ptr(png);
	if (n > s->len - s->pos) png_error(png, "Read Error");
	memcpy(out, s->p + s->pos, n);
	s->pos += n;
}
static void b8_err(png_structp png, png_const_charp) { png_longjmp(png, 1); }
static void b8_warn(png_structp, png_const_charp) {}

static void cmd_bare8(const char *path, int heap)
{
	FILE *f = fopen(path, "rb");
	if (!f) { umd_ctl_log("B2 bare8 %s: cannot open", path); return; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *png = (uint8_t *)malloc(len > 0 ? len : 1);
	size_t got = png ? fread(png, 1, len, f) : 0;
	fclose(f);
	if (!png || got != (size_t)len) { free(png); umd_ctl_log("B2 bare8 %s: read failed", path); return; }

	volatile uint32_t *plane = heap ? (volatile uint32_t *)calloc(UMD_PLANE_W * UMD_PLANE_H, 4)
	                                : (volatile uint32_t *)shmem_map(B2_SCRATCH, B2_SCRATCH_LEN);
	if (!plane) { free(png); umd_ctl_log("B2 bare8: no plane"); return; }
	if (heap) memset((void *)plane, 0, B2_PLANE_BYTES);

	b8_rd rd = {png, (size_t)len, 0};
	uint8_t *volatile row = NULL;
	volatile uint32_t w = 0, h = 0;
	volatile int ok = 0;
	uint64_t t0 = now_us();
	png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, &rd, b8_err, b8_warn);
	png_infop info = p ? png_create_info_struct(p) : NULL;
	if (p && info && !setjmp(png_jmpbuf(p)))
	{
		png_set_read_fn(p, &rd, b8_read);
		png_read_info(p, info);
		w = png_get_image_width(p, info);
		h = png_get_image_height(p, info);
		if (png_get_interlace_type(p, info) == PNG_INTERLACE_NONE && w <= UMD_PLANE_W)
		{
			png_set_expand(p);
			png_set_strip_16(p);
			png_set_gray_to_rgb(p);
			png_set_add_alpha(p, 0xFF, PNG_FILLER_AFTER);
			png_read_update_info(p, info);
			row = (uint8_t *)malloc(png_get_rowbytes(p, info));
			for (uint32_t y = 0; row && y < h; y++)
			{
				png_read_row(p, row, NULL);
				if (y >= UMD_PLANE_H) continue;
				volatile uint32_t *o = plane + y * UMD_PLANE_W;
				for (uint32_t x = 0; x < w; x++)
				{
					const uint8_t *q = row + 4 * x;
					uint32_t a = q[3], c[3];
					for (int k = 0; k < 3; k++)
					{
						uint32_t m = q[k] * a + 128;
						c[k] = (m + (m >> 8)) >> 8;
					}
					o[x] = a << 24 | c[0] << 16 | c[1] << 8 | c[2];
				}
			}
			png_read_end(p, NULL);
			ok = row != NULL;
		}
	}
	uint32_t us = (uint32_t)(now_us() - t0);
	png_destroy_read_struct(p ? &p : NULL, info ? &info : NULL, NULL);
	free(row);
	umd_ctl_log("B2 bare8 %s (%ld B) into %s: %s w=%u h=%u %u us", path, len, heap ? "heap" : "scratch",
	            ok ? "ok" : "refused or unsupported (interlaced / wider than 720)", (unsigned)w, (unsigned)h, us);
	if (heap) free((void *)plane);
	else shmem_unmap((void *)plane, B2_SCRATCH_LEN);
	free(png);
}

// ------------------------------------------------------------------ pal (a ceiling)
static void cmd_pal(const char *path, int heap)
{
	FILE *f = fopen(path, "rb");
	if (!f) { umd_ctl_log("B2 pal %s: cannot open", path); return; }
	fseek(f, 0, SEEK_END);
	long len = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *png = (uint8_t *)malloc(len > 0 ? len : 1);
	size_t got = png ? fread(png, 1, len, f) : 0;
	fclose(f);
	if (!png || got != (size_t)len) { free(png); umd_ctl_log("B2 pal %s: read failed", path); return; }

	volatile uint32_t *plane = heap ? (volatile uint32_t *)calloc(UMD_PLANE_W * UMD_PLANE_H, 4)
	                                : (volatile uint32_t *)shmem_map(B2_SCRATCH, B2_SCRATCH_LEN);
	if (!plane) { free(png); umd_ctl_log("B2 pal: no plane"); return; }
	if (heap) memset((void *)plane, 0, B2_PLANE_BYTES);

	b8_rd rd = {png, (size_t)len, 0};
	uint8_t *volatile row = NULL;
	volatile uint32_t w = 0, h = 0;
	volatile int ok = 0;
	uint32_t lut[256];
	uint64_t t0 = now_us();
	png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, &rd, b8_err, b8_warn);
	png_infop info = p ? png_create_info_struct(p) : NULL;
	if (p && info && !setjmp(png_jmpbuf(p)))
	{
		png_set_read_fn(p, &rd, b8_read);
		png_read_info(p, info);
		w = png_get_image_width(p, info);
		h = png_get_image_height(p, info);
		png_colorp pl = NULL;
		int npl = 0, ntr = 0;
		png_bytep tr = NULL;
		if (png_get_color_type(p, info) == PNG_COLOR_TYPE_PALETTE && w <= UMD_PLANE_W &&
		    png_get_interlace_type(p, info) == PNG_INTERLACE_NONE &&
		    png_get_PLTE(p, info, &pl, &npl))
		{
			png_get_tRNS(p, info, &tr, &ntr, NULL);
			for (int i = 0; i < 256; i++)
			{
				uint32_t a = i < ntr ? tr[i] : 255;
				uint32_t c[3] = {0, 0, 0};
				if (i < npl) { c[0] = pl[i].red; c[1] = pl[i].green; c[2] = pl[i].blue; }
				for (int k = 0; k < 3; k++)
				{
					uint32_t m = c[k] * a + 128;
					c[k] = (m + (m >> 8)) >> 8;
				}
				lut[i] = a << 24 | c[0] << 16 | c[1] << 8 | c[2];
			}
			png_set_packing(p);
			png_read_update_info(p, info);
			row = (uint8_t *)malloc(png_get_rowbytes(p, info));
			for (uint32_t y = 0; row && y < h; y++)
			{
				png_read_row(p, row, NULL);
				if (y >= UMD_PLANE_H) continue;
				volatile uint64_t *o = (volatile uint64_t *)(plane + y * UMD_PLANE_W);
				for (uint32_t x = 0; x + 1 < w; x += 2)
					o[x / 2] = lut[row[x]] | (uint64_t)lut[row[x + 1]] << 32;
			}
			png_read_end(p, NULL);
			ok = row != NULL;
		}
	}
	uint32_t us = (uint32_t)(now_us() - t0);
	png_destroy_read_struct(p ? &p : NULL, info ? &info : NULL, NULL);
	free(row);
	umd_ctl_log("B2 pal %s (%ld B) into %s: %s w=%u h=%u %u us", path, len, heap ? "heap" : "scratch",
	            ok ? "ok" : "refused or not a palette image", (unsigned)w, (unsigned)h, us);
	if (heap) free((void *)plane);
	else shmem_unmap((void *)plane, B2_SCRATCH_LEN);
	free(png);
}

// ------------------------------------------------------------------ spi
static void cmd_spi()
{
	const int n = 1000;
	const int len[2] = {4, UMD_TELEM_NWORDS};
	for (int k = 0; k < 2; k++)
	{
		uint32_t lo = ~0u, hi = 0;
		uint64_t sum = 0;
		int bad = 0;
		for (int i = 0; i < n; i++)
		{
			uint64_t t0 = now_us();
			uint16_t m = spi_uio_cmd_cont(UIO_UMD_TELEM);
			for (int j = 1; j < len[k]; j++) spi_w(0);
			DisableIO();
			uint32_t us = (uint32_t)(now_us() - t0);
			bad += m != UMD_TELEM_MAGIC;
			if (us < lo) lo = us;
			if (us > hi) hi = us;
			sum += us;
		}
		umd_ctl_log("B2 spi %d words x%d: min %u us mean %.1f us max %u us; magic missing %d",
		            len[k], n, lo, (double)sum / n, hi, bad);
	}
}

// ------------------------------------------------------------------ the commands
static int busy(const char *what)
{
	const char *b = pg_on ? "poll" : bw_pass >= 0 ? "bw" : dq_n ? "dump" : NULL;
	if (b) umd_ctl_log("B2 %s refused: %s is running", what, b);
	return b != NULL;
}

void umd_b2_cmd(char *args)
{
	char *argv[6];
	int argc = 0;
	for (char *t = strtok(args, " "); t && argc < 6; t = strtok(NULL, " ")) argv[argc++] = t;
	if (!argc) { umd_ctl_log("B2: no command"); return; }

	if (!strcmp(argv[0], "libpng"))
	{
		cmd_libpng();
	}
	else if (!strcmp(argv[0], "poll") && argc == 2)
	{
		if (busy("poll")) return;
		double s = atof(argv[1]);
		pg_n = pg_cap = 0;
		pg = NULL;
		pg_last = pg_sum = 0;
		pg_t0 = now_us();
		pg_end = pg_t0 + (uint64_t)(s * 1e6);
		pg_on = 1;
		umd_ctl_log("B2 poll: %.1f s started", s);
	}
	else if (!strcmp(argv[0], "bare8") && (argc == 2 || argc == 3))
	{
		if (busy("bare8")) return;
		cmd_bare8(argv[1], argc == 3 && !strcmp(argv[2], "heap"));
	}
	else if (!strcmp(argv[0], "pal") && (argc == 2 || argc == 3))
	{
		if (busy("pal")) return;
		cmd_pal(argv[1], argc == 3 && !strcmp(argv[2], "heap"));
	}
	else if (!strcmp(argv[0], "spi"))
	{
		if (busy("spi")) return;
		cmd_spi();
	}
	else if (!strcmp(argv[0], "bw"))
	{
		if (busy("bw")) return;
		bw_addr = argc > 1 ? (uint32_t)strtoul(argv[1], NULL, 0) : B2_SCRATCH;
		bw_width = argc > 2 ? atoi(argv[2]) : 32;
		if (bw_width != 32 && bw_width != 64 && bw_width != 128) { umd_ctl_log("B2 bw: width 32, 64 or 128"); return; }
		bw_len = page_up(B2_PLANE_BYTES);
		bw_p = (volatile uint32_t *)shmem_map(bw_addr, bw_len);
		if (!bw_p) { umd_ctl_log("B2 bw 0x%08X: map failed", bw_addr); return; }
		bw_bad = 0;
		bw_pass = 0;
		umd_ctl_log("B2 bw 0x%08X %d-bit stores: started", bw_addr, bw_width);
	}
	else if (!strcmp(argv[0], "decode") && (argc == 4 || argc == 5))
	{
		if (busy("decode")) return;
		cmd_decode(argv[1], (uint32_t)strtoul(argv[2], NULL, 0), (uint32_t)strtoul(argv[3], NULL, 0),
		           argc == 5 && !strcmp(argv[4], "heap"));
	}
	else if (!strcmp(argv[0], "dump") && (argc == 1 || argc == 4))
	{
		if (busy("dump")) return;
		if (argc == 1)
		{
			dq[0].addr = B2_PLANE0; dq[0].len = B2_PLANE_BYTES;
			snprintf(dq[0].file, sizeof(dq[0].file), "/tmp/umd_plane0.bin");
			dq[1].addr = B2_PLANE1; dq[1].len = B2_PLANE_BYTES;
			snprintf(dq[1].file, sizeof(dq[1].file), "/tmp/umd_plane1.bin");
			dq_n = 2;
		}
		else
		{
			dq[0].addr = (uint32_t)strtoul(argv[1], NULL, 0);
			dq[0].len = (uint32_t)strtoul(argv[2], NULL, 0) & ~3u;
			snprintf(dq[0].file, sizeof(dq[0].file), "%s", argv[3]);
			dq_n = 1;
		}
		dq_i = 0;
		umd_ctl_log("B2 dump: %d region(s) queued", dq_n);
	}
	else
	{
		umd_ctl_log("B2: unknown or malformed '%s' (%d args)", argv[0], argc);
	}
}

void umd_b2_tick()
{
	if (pg_on) { poll_sample(); return; }
	if (bw_pass >= 0) { bw_step(); return; }
	if (dq_n) dump_step();
}
