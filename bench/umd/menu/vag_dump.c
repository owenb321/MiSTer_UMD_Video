// vag_dump.c -- P9 M3 (C)'s gate tool for vag.c: every sound of an RCO, each channel's VAG bytes
// (OUT/<entry>_<c>.vag), its decode (OUT/<entry>_<c>.s16, s16le) and the sound at 48 kHz
// (OUT/<entry>.r48, interleaved s16le), one line a sound: "S <entry> <channels> <rate> <n0> <n1>
// <frames>" -- or "ERR <entry> <reason>". tools/menu_vag_check.py compares them with ffmpeg and with
// its own resample.
//
//   vag_dump FILE.RCO OUTDIR
//   vag_dump --vag FILE.vag OUT.s16      one bare VAG (the synthetic cases), its decode
#include "rco.h"
#include "vag.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int put(const char *path, const void *d, size_t n)
{
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = fwrite(d, 1, n, f);
    fclose(f);
    return w == n ? 0 : -1;
}

int main(int argc, char **argv)
{
    if (argc == 4 && !strcmp(argv[1], "--vag")) {
        FILE *g = fopen(argv[2], "rb");
        if (!g) { perror(argv[2]); return 2; }
        fseek(g, 0, SEEK_END);
        long gn = ftell(g);
        fseek(g, 0, SEEK_SET);
        uint8_t *gb = (uint8_t *)malloc((size_t)gn);
        if (!gb || fread(gb, 1, (size_t)gn, g) != (size_t)gn) return 2;
        fclose(g);
        int16_t *pcm; uint32_t ns, rate;
        if (vag_decode(gb, (size_t)gn, &pcm, &ns, &rate)) { printf("ERR not decoded\n"); return 1; }
        put(argv[3], pcm, (size_t)ns * 2);
        printf("V %u %u\n", ns, rate);
        free(pcm); free(gb);
        return 0;
    }
    if (argc != 3) { fprintf(stderr, "usage: vag_dump FILE.RCO OUTDIR | --vag FILE.vag OUT.s16\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc((size_t)n);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "read\n"); return 2; }
    fclose(f);
    rco r;
    if (rco_load(&r, b, (size_t)n)) { printf("ERR - %s\n", r.err); return 1; }
    char path[1024];
    for (int i = 0; i < r.n; i++) {
        if (r.e[i].table != RCO_T_SOUND || r.e[i].type != 1) continue;
        uint32_t fmt, nch, len[2];
        const uint8_t *data[2];
        if (rco_sound(&r, i, &fmt, &nch, data, len)) { printf("ERR %d not a sound I read\n", i); continue; }
        int16_t *pcm[2] = { NULL, NULL };
        uint32_t ns[2] = { 0, 0 }, rate = 0, rate1 = 0;
        int bad = 0;
        for (uint32_t c = 0; c < nch; c++) {
            snprintf(path, sizeof(path), "%s/%d_%u.vag", argv[2], i, c);
            put(path, data[c], len[c]);
            if (vag_decode(data[c], len[c], &pcm[c], &ns[c], c ? &rate1 : &rate)) { printf("ERR %d channel %u not decoded\n", i, c); bad = 1; break; }
            snprintf(path, sizeof(path), "%s/%d_%u.s16", argv[2], i, c);
            put(path, pcm[c], (size_t)ns[c] * 2);
        }
        if (!bad && nch == 2 && rate1 != rate) { printf("ERR %d the channels' rates differ (%u, %u)\n", i, rate, rate1); bad = 1; }
        if (!bad) {
            int16_t *o;
            uint32_t frames;
            const int16_t *const ch[2] = { pcm[0], pcm[1] };
            if (vag_to_48k(ch, ns, (int)nch, rate, &o, &frames)) printf("ERR %d not resampled (rate %u)\n", i, rate);
            else {
                snprintf(path, sizeof(path), "%s/%d.r48", argv[2], i);
                put(path, o, (size_t)frames * nch * 2);
                printf("S %d %u %u %u %u %u\n", i, nch, rate, ns[0], ns[1], frames);
                free(o);
            }
        }
        free(pcm[0]); free(pcm[1]);
    }
    rco_free(&r);
    free(b);
    return 0;
}
