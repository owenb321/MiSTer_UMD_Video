// umd_playlist.h -- UMD_VIDEO/PLAYLIST.UMD for the menu engine's player (P9 M3, docs/p9.md): a
// script's play(playlist n, chapter c) becomes the core's NAV_PLAY (index n - 1, the chapter's item,
// its PTS). Portable C (the UMD Main; the PC bench).
//
// The layout and every check are tools/umd_playlist.py's (the P1 parser; docs/umd_video_format.md
// "PLAYLIST.UMD"; bench/umd/run_menu.sh [playlist] compares the two on every image and on the
// P2 reader's synthetic playlists): big-endian; "UMDV0088"; the playlists section's u32 length and
// u16 count; each entry's u32 length, u16 items / marks offsets, an info block; items {u32 len >= 22,
// u16 clip name length <= 8, name, ..., u48 IN at +10, u48 OUT at +16}; marks {u32 len, u16 count,
// 40 bytes each: u8 type, u8 flags, u16 item, u48 PTS, ...}; the sections inside their entry, not
// overlapping, the entry ending at its last. A file that breaks any of them is refused whole with a
// reason (pl->err), never read out of bounds.
//
// CHAPTERS are tools/umd_nav_ref.py's (the transport's, P6b): the type-5 marks (16 is an Endmark)
// whose item exists, ordered by (item, PTS) -- not by table order, which nothing in the format
// orders.
//
// Bounds: the format's own (u16 playlists, u32 items, u16 marks), each held by the file's length.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char     clip[9];
    uint64_t in, out;           // 90 kHz, u48
} umd_pl_item;

typedef struct {
    uint8_t  type, flags;
    uint16_t item;
    uint64_t pts;
    char     name[25];          // char[24] at +16, NUL-padded (a type-16 mark's: movieplayer.onMark's mark_name)
} umd_pl_mark;

typedef struct {
    uint32_t nitems, nmarks, nchapters;
    umd_pl_item *items;
    umd_pl_mark *marks;
    uint32_t *chapters;         // indices into marks, in chapter order
    char     name[256];
} umd_pl_entry;

typedef struct {
    uint32_t n;
    umd_pl_entry *e;
    char     err[160];
} umd_playlists;

// 0 ok; -1 with pl->err (nothing kept)
int  umd_pl_parse(umd_playlists *pl, const uint8_t *raw, size_t len);
void umd_pl_free(umd_playlists *pl);
// chapter c (from 1) of playlist index i: its item and PTS; 0 ok, -1 none (the caller plays the
// playlist from its first item's IN)
int  umd_pl_chapter(const umd_playlists *pl, uint32_t i, uint32_t c, uint32_t *item, uint64_t *pts);

#ifdef __cplusplus
}
#endif
