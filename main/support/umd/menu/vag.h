// vag.h -- the menus' sound effects (P9 M3 C, docs/p9.md): a VAG file (Sony's PSX / PSP ADPCM, as
// an RCO sound channel carries it: the "VAGp" header and its blocks) into 16-bit PCM, and a sound's
// channels resampled to the core's 48 kHz for its PCM one-shot (umd/pcm_shot.sv).
//
// THE DECODE is ffmpeg's adpcm_psx (the oracle: tools/menu_vag_check.py compares every library
// sound sample for sample): a 16-byte block {filter << 4 | shift, flag, 14 bytes of 28 nibbles, low
// nibble first}; a sample is (nibble << 12 >> shift) + (s1 f0 + s2 f1) / 64 (C's truncation), its
// history UNCLIPPED, the output clipped to 16 bits; a block flagged 7 gives silence; a filter past
// the table refuses the file. The data is the header's size (big-endian at 12) after the 48-byte
// header, cut to whole blocks and to the file; the rate is the header's (big-endian at 16).
// THE RESAMPLE is linear: output frame k at source position k * rate / 48000, exactly (a rational,
// no float), a + (b - a) * frac rounded toward zero -- a sound's length ceil(n * 48000 / rate).
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// one channel: *pcm malloc'd, *n samples, *rate Hz. 0 ok, -1 not a VAG / a bad block / no memory
int vag_decode(const uint8_t *vag, size_t len, int16_t **pcm, uint32_t *n, uint32_t *rate);
// nch (1, 2) channels of n samples at rate -> 48 kHz, interleaved; *out malloc'd, *frames. A
// channel shorter than the other is padded with its last sample. 0 ok, -1 no memory / a bad rate
int vag_to_48k(const int16_t *const ch[2], const uint32_t n[2], int nch, uint32_t rate,
               int16_t **out, uint32_t *frames);

#ifdef __cplusplus
}
#endif
