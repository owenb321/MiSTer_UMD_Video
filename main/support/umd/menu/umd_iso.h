// umd_iso.h -- files out of a UMD Video image (ISO9660) for the menu engine (P9 M3, docs/p9.md):
// RESOURCE/<lang>100000.RCO and friends, UMD_VIDEO/PLAYLIST.UMD, UMD_DATA.BIN (the disc's id,
// the name of its kept-data file). Portable C: the UMD Main reads the mounted image through its
// own descriptor (the poll thread's sector reads untouched); the PC bench through stdio.
//
// The walk is tools/umd_iso.py's (the P1 tools' base; bench/umd/run_menu.sh [iso] compares the
// two on every image): the PVD found in the volume descriptor set (LBA 16 on, the set's
// terminator within 32 sectors), a 2048-byte logical block, directory records never straddling a
// sector, names upper-cased with ";1" and a trailing "." stripped, depth at most 8 (ECMA-119
// 6.8.2.1). A multi-extent file (flag bit 7) is joined when its extents are contiguous, refused
// when gapped (none in the library). Every offset and length is checked against the image's
// size: a bad image is refused with a reason (iso->err), never read out of bounds.
//
// Paths are looked up component by component (no whole-tree walk: the Main opens one or two files
// per mount), case-insensitively, "/" separated, from the root.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// read `n` bytes at byte `off` of the image into `buf`; returns the bytes read
typedef size_t (*umd_iso_read_fn)(void *ud, uint64_t off, void *buf, size_t n);

typedef struct {
    umd_iso_read_fn read;
    void    *ud;
    uint64_t image_bytes;
    uint32_t root_lba, root_len;
    char     err[160];
} umd_iso;

typedef struct {
    uint32_t lba;
    uint32_t size;             // bytes (a joined multi-extent file's total)
    int      is_dir;
} umd_iso_entry;

// 0 ok; -1 with iso->err
int  umd_iso_open(umd_iso *iso, umd_iso_read_fn read, void *ud, uint64_t image_bytes);
// 0 found; -1 not found or refused (iso->err says which)
int  umd_iso_find(umd_iso *iso, const char *path, umd_iso_entry *e);
// the whole file into a malloc'd buffer (freed by the caller); refused past `max` bytes
int  umd_iso_read_file(umd_iso *iso, const char *path, size_t max, uint8_t **out, size_t *len);
// call `fn` for each entry of a directory (its name, upper-cased, ";1" stripped); 0 ok
int  umd_iso_listdir(umd_iso *iso, const char *path, void (*fn)(void *ud, const char *name, const umd_iso_entry *e), void *ud);
// UMD_DATA.BIN's first two '|' fields (the product code, the disc id) as "<product>_<discid>",
// filename-safe (anything outside [A-Za-z0-9-] becomes '_'); 0 ok, -1 absent
int  umd_iso_disc_id(umd_iso *iso, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
