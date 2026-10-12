// pl_dump.c -- P9 M3's gate tool for umd_playlist.c: a PLAYLIST.UMD's playlists, items, marks and
// chapters, one line each (tools/menu_pl_check.py compares them with umd_playlist.py and
// umd_nav_ref.py's chapter rule); or "ERR <reason>" for a file it refuses.
//
//   pl_dump IMAGE.iso | pl_dump --raw PLAYLIST.UMD
#include "umd_iso.h"
#include "umd_playlist.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static size_t rd(void *ud, uint64_t off, void *buf, size_t n)
{
    FILE *f = (FILE *)ud;
    if (fseeko(f, (off_t)off, SEEK_SET)) return 0;
    return fread(buf, 1, n, f);
}

int main(int argc, char **argv)
{
    uint8_t *raw = NULL;
    size_t len = 0;
    FILE *f = fopen(argv[argc - 1], "rb");
    if (argc < 2 || !f) { fprintf(stderr, "usage: pl_dump IMAGE.iso | --raw FILE\n"); return 2; }
    fseeko(f, 0, SEEK_END);
    uint64_t sz = (uint64_t)ftello(f);
    if (argc == 3 && !strcmp(argv[1], "--raw")) {
        raw = (uint8_t *)malloc(sz ? sz : 1);
        fseeko(f, 0, SEEK_SET);
        if (!raw || fread(raw, 1, sz, f) != sz) { printf("ERR read\n"); return 1; }
        len = sz;
    } else {
        umd_iso iso;
        if (umd_iso_open(&iso, rd, f, sz) || umd_iso_read_file(&iso, "/UMD_VIDEO/PLAYLIST.UMD", 64u << 20, &raw, &len)) { printf("ERR iso: %s\n", iso.err); return 1; }
    }
    fclose(f);
    umd_playlists pl;
    if (umd_pl_parse(&pl, raw, len)) { printf("ERR %s\n", pl.err); free(raw); return 0; }
    for (uint32_t i = 0; i < pl.n; i++) {
        const umd_pl_entry *e = &pl.e[i];
        printf("P %u %u %u %u %s\n", i, e->nitems, e->nmarks, e->nchapters, e->name);
        for (uint32_t k = 0; k < e->nitems; k++)
            printf("I %u %u %s %llu %llu\n", i, k, e->items[k].clip, (unsigned long long)e->items[k].in, (unsigned long long)e->items[k].out);
        for (uint32_t k = 0; k < e->nmarks; k++) {
            // the name's bytes, printable ASCII as is, any other as \xHH (menu_pl_check.py's spelling)
            char nm[24 * 4 + 1], *q = nm;
            for (const unsigned char *c = (const unsigned char *)e->marks[k].name; *c; c++)
                q += (*c > 0x20 && *c < 0x7F && *c != '\\') ? sprintf(q, "%c", *c) : sprintf(q, "\\x%02x", *c);
            *q = 0;
            printf("M %u %u %u %u %u %llu %s\n", i, k, e->marks[k].type, e->marks[k].flags, e->marks[k].item, (unsigned long long)e->marks[k].pts, nm);
        }
        for (uint32_t c = 1; c <= e->nchapters; c++) {
            uint32_t it; uint64_t pts;
            umd_pl_chapter(&pl, i, c, &it, &pts);
            printf("C %u %u %u %llu\n", i, c, it, (unsigned long long)pts);
        }
    }
    umd_pl_free(&pl);
    free(raw);
    return 0;
}
