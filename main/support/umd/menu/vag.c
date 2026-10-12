// vag.c -- see vag.h.
#include "vag.h"

#include <stdlib.h>
#include <string.h>

static const int vag_f[5][2] = { { 0, 0 }, { 60, 0 }, { 115, -52 }, { 98, -55 }, { 122, -60 } };

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }

int vag_decode(const uint8_t *vag, size_t len, int16_t **pcm, uint32_t *n, uint32_t *rate)
{
    *pcm = NULL; *n = 0; *rate = 0;
    if (len < 48 || memcmp(vag, "VAGp", 4)) return -1;
    uint64_t data = be32(vag + 12);
    *rate = be32(vag + 16);
    if (data > len - 48) data = len - 48;
    uint32_t blocks = (uint32_t)(data / 16);
    int16_t *o = (int16_t *)malloc((size_t)(blocks ? blocks : 1) * 28 * sizeof(int16_t));
    if (!o) return -1;
    int s1 = 0, s2 = 0;                         // the history: UNCLIPPED (ffmpeg's)
    const uint8_t *b = vag + 48;
    for (uint32_t k = 0; k < blocks; k++, b += 16) {
        int shift = b[0] & 15, filter = b[0] >> 4, flag = b[1] & 7;
        if (filter >= 5) { free(o); return -1; }
        for (int i = 0; i < 28; i++) {
            int byte = b[2 + i / 2];
            int nib = (i & 1) ? (byte >> 4) : (byte & 15);
            int scale = nib >= 8 ? nib - 16 : nib;          // a signed nibble
            int sample = 0;
            if (flag < 7)
                sample = ((scale * (1 << 12)) >> shift) + (s1 * vag_f[filter][0] + s2 * vag_f[filter][1]) / 64;
            o[k * 28 + (uint32_t)i] = (int16_t)(sample > 32767 ? 32767 : sample < -32768 ? -32768 : sample);
            s2 = s1;
            s1 = sample;
        }
    }
    *pcm = o;
    *n = blocks * 28;
    return 0;
}

int vag_to_48k(const int16_t *const ch[2], const uint32_t n[2], int nch, uint32_t rate,
               int16_t **out, uint32_t *frames)
{
    *out = NULL; *frames = 0;
    if (nch < 1 || nch > 2 || rate == 0 || rate > 192000) return -1;
    uint32_t len = n[0];
    if (nch == 2 && n[1] > len) len = n[1];
    if (!len) return 0;
    uint64_t f = ((uint64_t)len * 48000 + rate - 1) / rate;
    int16_t *o = (int16_t *)malloc((size_t)f * (size_t)nch * sizeof(int16_t));
    if (!o) return -1;
    for (uint64_t k = 0; k < f; k++) {
        uint64_t pos = k * rate;                // in 1 / 48000 of a source sample
        uint64_t i = pos / 48000, fr = pos % 48000;
        for (int c = 0; c < nch; c++) {
            uint32_t m = n[c];
            int a = m ? ch[c][i < m ? i : m - 1] : 0;
            int b2 = m ? ch[c][i + 1 < m ? i + 1 : m - 1] : 0;
            o[k * (uint64_t)nch + (uint64_t)c] = (int16_t)(a + (int)(((int64_t)(b2 - a) * (int64_t)fr) / 48000));
        }
    }
    *out = o;
    *frames = (uint32_t)f;
    return 0;
}
