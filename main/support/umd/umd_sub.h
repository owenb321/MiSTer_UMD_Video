// umd_sub.h -- the subtitle decode on the HPS (docs/hps_host.md §3, A7): one subtitle
// unit's PNG from the core's DDR3 ring into a premultiplied ARGB plane, exactly as the
// fabric's png_top + sub_plane_wr did it.
//
// Portable: plain C that also compiles as C++ (Main builds support/*/*.cpp). The same
// file builds natively on the PC (host C) for bench/umd/run_hps_sub.sh, against the
// system libpng and against libpng 1.6.37, the version the MiSTer's Main runs with (the
// Linux image's /usr/lib/libpng16.so.16.37.0; measured by B2, docs/hps_host.md §6).
//
// No Main dependency: the caller maps the ring and the plane (shmem_map on the HPS,
// malloc on the PC) and passes plain pointers.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define UMD_PLANE_W     720             // the plane's pitch and visible width (pixels)
#define UMD_PLANE_H     480
// The size bounds, set explicitly so they are ours, not the library build's defaults.
// Height: the PNG maximum, 2^31-1 -- rows are streamed one at a time, so a tall image
// costs time (a flush cancels it), never memory. Width: libpng's default user limit,
// 1,000,000 -- a row is held whole (8 bytes a pixel after expansion, ~8 MB here, and
// libpng's own row buffers beside it); 2^31-1 would be 16 GB. A deviation from the PNG
// maximum: docs/spec_hardening.md "Known deviations" (the fabric's was row bytes <= 8192).
#define UMD_PNG_WMAX    1000000u
#define UMD_PNG_HMAX    0x7FFFFFFFu

enum umd_sub_err {
	UMD_SUB_OK = 0,
	UMD_SUB_REFUSED = 1,                // libpng refused the image (msg says why)
	UMD_SUB_NOMEM = 2,                  // a row buffer could not be allocated
	UMD_SUB_CANCELLED = 3               // the cancel hook asked to stop (a flush)
};

typedef struct {
	int      err;                       // enum umd_sub_err
	uint32_t w, h;                      // the image's size (0 when refused before IHDR)
	uint32_t clipped;                   // pixels outside 720 x 480, not written (saturating)
	char     msg[96];                   // libpng's message when refused
} umd_sub_result;

// Decode `png` (len bytes) and write it at (ux, uy) of `plane` (UMD_PLANE_W x
// UMD_PLANE_H, pixel (X, Y) at plane[Y * 720 + X]) as premultiplied {A, R', G', B'},
// A in bits 31:24, c' = (c*a + 128 + ((c*a + 128) >> 8)) >> 8 -- sub_plane_wr.sv's
// layout and formula. Only the image's own pixels are written, with aligned stores (the HPS
// mapping is uncached, strongly ordered): two neighbours as one 64-bit store, a pixel without
// its neighbour as one 32-bit store. Nothing is cleared. `plane` must be 8-byte aligned.
// Pixels past 720 x 480 are counted in `clipped`. The whole stream is decoded even past
// the plane's bottom, so the verdict is libpng's for the whole image (the fabric's rule).
//
// cancel: optional, polled once a row; nonzero stops the decode (UMD_SUB_CANCELLED).
// Returns r->err.
int umd_sub_decode(const uint8_t *png, size_t len, uint32_t ux, uint32_t uy,
                   volatile uint32_t *plane, umd_sub_result *r,
                   int (*cancel)(void *), void *cancel_arg);

// Copy one unit's bytes out of the core's subtitle ring (sub_ring.sv): `ring` is the
// ring's base, `ring_words` its size in 64-bit words, the unit starts at word `start`
// and runs `len` bytes, wrapping at the ring's end. Bytes are in address order (the
// first in bits 7:0 of a word). Reads with aligned 32-bit loads only (uncached memory).
// Returns len, or 0 when the unit is longer than the ring.
size_t umd_ring_copy(const volatile uint32_t *ring, uint32_t ring_words, uint32_t start,
                     uint32_t len, uint8_t *out);

#ifdef __cplusplus
}
#endif
