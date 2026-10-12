// umd_playlist.c -- see umd_playlist.h.
#include "umd_playlist.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MARK_LEN      40
#define MARK_CHAPTER  5

static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3]; }
static uint16_t be16(const uint8_t *p) { return (uint16_t)(p[0] << 8 | p[1]); }
static uint64_t be48(const uint8_t *p) { return (uint64_t)be16(p) << 32 | be32(p + 2); }

static int fail(umd_playlists *pl, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(pl->err, sizeof(pl->err), fmt, ap);
    va_end(ap);
    return -1;
}

// the u32 length at off, its section inside [lo, hi): *ln; 0 ok
static int len_at(umd_playlists *pl, const uint8_t *raw, uint64_t off, uint64_t lo, uint64_t hi, const char *what, uint32_t idx, uint32_t *ln)
{
    if (off < lo || off + 4 > hi) return fail(pl, "%s %u at 0x%llx outside its parent", what, idx, (unsigned long long)off);
    *ln = be32(raw + off);
    if (off + 4 + *ln > hi) return fail(pl, "%s %u at 0x%llx: length %u runs past its parent", what, idx, (unsigned long long)off, *ln);
    return 0;
}

static const umd_pl_mark *sort_marks;
static int chap_cmp(const void *a, const void *b)
{
    const umd_pl_mark *x = &sort_marks[*(const uint32_t *)a], *y = &sort_marks[*(const uint32_t *)b];
    if (x->item != y->item) return x->item < y->item ? -1 : 1;
    if (x->pts != y->pts) return x->pts < y->pts ? -1 : 1;
    // equal keys: table order (a stable sort, as Python's sorted() over (item, pts) tuples
    // leaves equal tuples indistinguishable anyway)
    uint32_t i = *(const uint32_t *)a, j = *(const uint32_t *)b;
    return i < j ? -1 : i > j;
}

static int parse_entry(umd_playlists *pl, const uint8_t *raw, uint64_t e0, uint64_t e_end, uint32_t idx, umd_pl_entry *ent)
{
    uint32_t items_off = be16(raw + e0 + 4), marks_off = be16(raw + e0 + 6), iln = 0, ln = 0;   // (= 0: gcc -O3 cannot see len_at set them)
    if (e0 + 8 > e_end) return fail(pl, "playlist %u: shorter than its header", idx);
    uint64_t ioff = e0 + 0x24;
    if (len_at(pl, raw, ioff, e0, e_end, "the info of playlist", idx, &iln)) return -1;
    const uint8_t *info = raw + ioff + 4;
    uint32_t nl = iln > 14 ? info[14] : 0;
    if (15 + nl > iln) nl = iln > 15 ? iln - 15 : 0;             // (Python's slice stops at the info's end)
    memcpy(ent->name, info + 15, nl < sizeof(ent->name) ? nl : sizeof(ent->name) - 1);
    ent->name[nl < sizeof(ent->name) ? nl : sizeof(ent->name) - 1] = 0;

    uint64_t a = e0 + items_off;
    if (len_at(pl, raw, a, e0, e_end, "the items of playlist", idx, &ln)) return -1;
    uint32_t items_ln = ln;
    if (a + 8 > a + 4 + ln) return fail(pl, "playlist %u: the items section is shorter than its count", idx);
    uint32_t n = be32(raw + a + 4);
    if (n > (ln - 4) / 26) return fail(pl, "playlist %u: %u items cannot fit in %u bytes", idx, n, ln);
    ent->items = (umd_pl_item *)calloc(n ? n : 1, sizeof(umd_pl_item));
    if (!ent->items) return fail(pl, "out of memory");
    ent->nitems = n;
    uint64_t p = a + 8;
    for (uint32_t k = 0; k < n; k++) {
        if (p + 4 > a + 4 + ln) return fail(pl, "playlist %u: item %u past the items section", idx, k);
        uint32_t il = be32(raw + p);
        if (il < 22 || p + 4 + il > a + 4 + ln) return fail(pl, "playlist %u item %u: length %u", idx, k, il);
        const uint8_t *body = raw + p + 4;
        uint32_t cl = be16(body);
        if (cl > 8) return fail(pl, "playlist %u item %u: clip name length %u > 8", idx, k, cl);
        memcpy(ent->items[k].clip, body + 2, cl);
        ent->items[k].clip[cl] = 0;
        ent->items[k].in = be48(body + 10);
        ent->items[k].out = be48(body + 16);
        p += 4 + il;
    }
    if (p != a + 4 + ln) return fail(pl, "playlist %u: %llu unaccounted bytes in items", idx, (unsigned long long)(a + 4 + ln - p));

    uint64_t m = e0 + marks_off;
    if (len_at(pl, raw, m, e0, e_end, "the marks of playlist", idx, &ln)) return -1;
    if (ln < 2) return fail(pl, "playlist %u: marks length %u", idx, ln);
    uint32_t nm = be16(raw + m + 4);
    if (2u + MARK_LEN * nm != ln) return fail(pl, "playlist %u: marks length %u does not hold %u marks", idx, ln, nm);
    ent->marks = (umd_pl_mark *)calloc(nm ? nm : 1, sizeof(umd_pl_mark));
    ent->chapters = (uint32_t *)calloc(nm ? nm : 1, sizeof(uint32_t));
    if (!ent->marks || !ent->chapters) return fail(pl, "out of memory");
    ent->nmarks = nm;
    for (uint32_t k = 0; k < nm; k++) {
        const uint8_t *b = raw + m + 6 + (uint64_t)MARK_LEN * k;
        ent->marks[k].type = b[0]; ent->marks[k].flags = b[1];
        ent->marks[k].item = be16(b + 2); ent->marks[k].pts = be48(b + 4);
        memcpy(ent->marks[k].name, b + 16, 24);             // (calloc'd: the 25th byte ends it)
        if (b[0] == MARK_CHAPTER && ent->marks[k].item < ent->nitems) ent->chapters[ent->nchapters++] = k;
    }
    sort_marks = ent->marks;
    qsort(ent->chapters, ent->nchapters, sizeof(uint32_t), chap_cmp);

    // the sections inside the entry, not overlapping, the entry ending at its last
    uint64_t s[3][2] = { { ioff, ioff + 4 + iln }, { a, a + 4 + items_ln }, { m, m + 4 + ln } };
    for (int i = 0; i < 3; i++) for (int j = i + 1; j < 3; j++)
        if (s[j][0] < s[i][0]) { uint64_t t0 = s[i][0], t1 = s[i][1]; s[i][0] = s[j][0]; s[i][1] = s[j][1]; s[j][0] = t0; s[j][1] = t1; }
    for (int i = 0; i < 2; i++) if (s[i + 1][0] < s[i][1]) return fail(pl, "playlist %u: sections overlap at 0x%llx", idx, (unsigned long long)s[i + 1][0]);
    if (s[2][1] != e_end) return fail(pl, "playlist %u: %lld bytes after its last section", idx, (long long)(e_end - s[2][1]));
    return 0;
}

int umd_pl_parse(umd_playlists *pl, const uint8_t *raw, size_t len)
{
    memset(pl, 0, sizeof(*pl));
    if (len < 8 || memcmp(raw, "UMDV0088", 8)) return fail(pl, "no UMDV0088 magic");
    if (len < 0x30) return fail(pl, "header truncated");
    uint32_t pl_off = be32(raw + 8), dln = 0, ln = 0;
    if (len_at(pl, raw, 0x28, 0x28, pl_off, "the disc info", 0, &dln)) return -1;
    if (dln < 5) return fail(pl, "the disc info is %u bytes (its name's length at +4)", dln);
    if (len_at(pl, raw, pl_off, pl_off, len, "the playlists section", 0, &ln)) return -1;
    uint64_t end = (uint64_t)pl_off + 4 + ln;
    if (end != len) return fail(pl, "%llu bytes after the playlists section", (unsigned long long)(len - end));
    if (pl_off + 6 > end) return fail(pl, "the playlists section holds no count");
    uint32_t n = be16(raw + pl_off + 4);
    pl->e = (umd_pl_entry *)calloc(n ? n : 1, sizeof(umd_pl_entry));
    if (!pl->e) return fail(pl, "out of memory");
    pl->n = n;
    uint64_t p = (uint64_t)pl_off + 6;
    for (uint32_t k = 0; k < n; k++) {
        uint32_t el = 0;
        if (len_at(pl, raw, p, p, end, "playlist", k, &el) || parse_entry(pl, raw, p, p + 4 + el, k, &pl->e[k])) {
            char keep[sizeof(pl->err)];
            memcpy(keep, pl->err, sizeof(keep));
            umd_pl_free(pl);
            memcpy(pl->err, keep, sizeof(keep));
            return -1;
        }
        p += 4 + el;
    }
    if (p != end) { umd_pl_free(pl); return fail(pl, "%llu unaccounted bytes after playlist %u", (unsigned long long)(end - p), n ? n - 1 : 0); }
    return 0;
}

void umd_pl_free(umd_playlists *pl)
{
    for (uint32_t k = 0; pl->e && k < pl->n; k++) { free(pl->e[k].items); free(pl->e[k].marks); free(pl->e[k].chapters); }
    free(pl->e);
    pl->e = NULL; pl->n = 0;
}

int umd_pl_chapter(const umd_playlists *pl, uint32_t i, uint32_t c, uint32_t *item, uint64_t *pts)
{
    if (i >= pl->n || c < 1 || c > pl->e[i].nchapters) return -1;
    const umd_pl_mark *mk = &pl->e[i].marks[pl->e[i].chapters[c - 1]];
    *item = mk->item; *pts = mk->pts;
    return 0;
}
