// iso_dump.c -- P9 M3's gate tool for umd_iso.c: an image's whole tree (every entry: path, LBA,
// size, dir), its disc id, and the CRC-32 of the files the menus read (PLAYLIST.UMD, UMD_DATA.BIN,
// every RESOURCE/*.RCO), one line each; tools/menu_iso_check.py compares it with tools/umd_iso.py.
//
//   iso_dump IMAGE.iso
#include "umd_iso.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

static size_t rd(void *ud, uint64_t off, void *buf, size_t n)
{
    FILE *f = (FILE *)ud;
    if (fseeko(f, (off_t)off, SEEK_SET)) return 0;
    return fread(buf, 1, n, f);
}

static umd_iso iso;

typedef struct { char path[512]; } walk_ctx;
static void walk(const char *path, int depth);

static void entry_cb(void *ud, const char *name, const umd_iso_entry *e)
{
    walk_ctx *w = (walk_ctx *)ud;
    char p[800];
    snprintf(p, sizeof(p), "%s/%s", w->path, name);
    printf("E %s %u %u %d\n", p, e->lba, e->size, e->is_dir);
    if (e->is_dir) walk(p, 0);
}

static void walk(const char *path, int depth)
{
    (void)depth;
    walk_ctx w;
    snprintf(w.path, sizeof(w.path), "%s", path);
    if (umd_iso_listdir(&iso, path[0] ? path : "/", entry_cb, &w)) printf("ERR listdir %s: %s\n", path, iso.err);
}

static void crc_file(const char *path)
{
    uint8_t *b;
    size_t n;
    if (umd_iso_read_file(&iso, path, 64u << 20, &b, &n)) { printf("C %s absent\n", path); return; }
    printf("C %s %zu %08lx\n", path, n, crc32(0L, b, (uInt)n));
    free(b);
}

static void rco_cb(void *ud, const char *name, const umd_iso_entry *e)
{
    (void)ud; (void)e;
    size_t l = strlen(name);
    if (l > 4 && !strcmp(name + l - 4, ".RCO")) {
        char p[300];
        snprintf(p, sizeof(p), "/UMD_VIDEO/RESOURCE/%s", name);
        crc_file(p);
    }
}

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: iso_dump IMAGE.iso\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseeko(f, 0, SEEK_END);
    uint64_t sz = (uint64_t)ftello(f);
    if (umd_iso_open(&iso, rd, f, sz)) { printf("ERR open: %s\n", iso.err); return 1; }
    walk("", 0);
    char id[128];
    if (umd_iso_disc_id(&iso, id, sizeof(id)) == 0) printf("ID %s\n", id); else printf("ID -\n");
    crc_file("/UMD_VIDEO/PLAYLIST.UMD");
    crc_file("/UMD_DATA.BIN");
    if (umd_iso_listdir(&iso, "/UMD_VIDEO/RESOURCE", rco_cb, NULL)) printf("ERR resource: %s\n", iso.err);
    fclose(f);
    return 0;
}
