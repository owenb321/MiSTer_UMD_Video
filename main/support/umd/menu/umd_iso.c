// umd_iso.c -- see umd_iso.h.
#include "umd_iso.h"

#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SEC          2048u
#define VD_START     16u
#define VD_SCAN_MAX  32u
#define FLAG_DIR     0x02
#define FLAG_MULTI   0x80
#define DEPTH_MAX    8

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

static int fail(umd_iso *iso, const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(iso->err, sizeof(iso->err), fmt, ap);
    va_end(ap);
    return -1;
}

static int sector(umd_iso *iso, uint32_t lba, uint8_t *buf)
{
    if ((uint64_t)(lba + 1) * SEC > iso->image_bytes) return fail(iso, "sector %u is past the end of the image", lba);
    if (iso->read(iso->ud, (uint64_t)lba * SEC, buf, SEC) != SEC) return fail(iso, "sector %u could not be read", lba);
    return 0;
}

int umd_iso_open(umd_iso *iso, umd_iso_read_fn read, void *ud, uint64_t image_bytes)
{
    memset(iso, 0, sizeof(*iso));
    iso->read = read; iso->ud = ud; iso->image_bytes = image_bytes;
    uint8_t d[SEC];
    int have_pvd = 0;
    for (uint32_t lba = VD_START;; lba++) {
        if (lba >= VD_START + VD_SCAN_MAX) return fail(iso, "no volume descriptor set terminator within %u sectors", VD_SCAN_MAX);
        if (sector(iso, lba, d)) return -1;
        if (memcmp(d + 1, "CD001", 5)) return fail(iso, "not ISO9660: no CD001 at sector %u", lba);
        if (d[0] == 1 && !have_pvd) {
            have_pvd = 1;
            uint32_t bs = (uint32_t)d[128] | (uint32_t)d[129] << 8;
            if (bs != SEC) return fail(iso, "logical block size %u, not 2048", bs);
            iso->root_lba = le32(d + 158); iso->root_len = le32(d + 166);
        }
        if (d[0] == 255) break;
    }
    if (!have_pvd) return fail(iso, "no Primary Volume Descriptor");
    return 0;
}

// the records of one directory, each passed to `cb` (name upper-cased, ";1" and a trailing "."
// stripped; '.' and '..' skipped; multi-extent files joined); cb returns nonzero to stop
typedef int (*rec_cb)(void *ud, const char *name, const umd_iso_entry *e);

static int walk_dir(umd_iso *iso, uint32_t dlba, uint32_t dlen, rec_cb cb, void *ud)
{
    uint8_t buf[SEC];
    char pend[256] = "";            // a multi-extent file being joined
    uint32_t p_lba = 0, p_next = 0, p_size = 0;
    if ((uint64_t)dlba * SEC + dlen > iso->image_bytes) return fail(iso, "a directory at LBA %u runs past the image (%u bytes)", dlba, dlen);
    for (uint32_t s = 0; s < (dlen + SEC - 1) / SEC; s++) {
        if (sector(iso, dlba + s, buf)) return -1;
        for (uint32_t p = 0; p < SEC;) {
            uint32_t rl = buf[p];
            if (rl == 0) break;                         // records never straddle a sector
            if (rl < 34 || p + rl > SEC) return fail(iso, "bad directory record at LBA %u+%u", dlba + s, p);
            uint32_t lba = le32(buf + p + 2), size = le32(buf + p + 10);
            uint8_t fl = buf[p + 25], nl = buf[p + 32];
            if (33u + nl > rl) return fail(iso, "bad directory record name at LBA %u+%u", dlba + s, p);
            const uint8_t *nm = buf + p + 33;
            p += rl;
            if (nl == 1 && (nm[0] == 0 || nm[0] == 1)) continue;      // '.' and '..'
            char name[256];
            size_t k = 0;
            for (uint32_t i = 0; i < nl && k < sizeof(name) - 1; i++) {
                char c = (char)nm[i];
                if (c == ';') break;
                name[k++] = (c >= 'a' && c <= 'z') ? (char)(c - 32) : c;
            }
            name[k] = 0;
            if (k && name[k - 1] == '.') name[--k] = 0;
            umd_iso_entry e = { lba, size, (fl & FLAG_DIR) != 0 };
            if (e.is_dir) { if (cb(ud, name, &e)) return 0; continue; }
            if (pend[0] && strcmp(pend, name)) return fail(iso, "a multi-extent file has no final record (LBA %u)", dlba + s);
            if ((fl & FLAG_MULTI) || pend[0]) {
                if (!pend[0]) { snprintf(pend, sizeof(pend), "%s", name); p_lba = lba; p_next = lba; p_size = 0; }
                if (lba != p_next) return fail(iso, "a multi-extent file is not contiguous (LBA %u, %u)", lba, p_next);
                if ((fl & FLAG_MULTI) && size % SEC) return fail(iso, "a multi-extent file's non-final extent is %u bytes", size);
                p_next = lba + size / SEC;
                p_size += size;
                if (fl & FLAG_MULTI) continue;
                pend[0] = 0;
                e.lba = p_lba; e.size = p_size;
            }
            if ((uint64_t)e.lba * SEC + e.size > iso->image_bytes) return fail(iso, "a file at LBA %u runs past the image (%u bytes)", e.lba, e.size);
            if (cb(ud, name, &e)) return 0;
        }
    }
    if (pend[0]) return fail(iso, "a multi-extent file has no final record");
    return 0;
}

typedef struct { const char *want; size_t wl; umd_iso_entry e; int found; } find_ctx;

static int find_cb(void *ud, const char *name, const umd_iso_entry *e)
{
    find_ctx *f = (find_ctx *)ud;
    if (strlen(name) != f->wl) return 0;
    for (size_t i = 0; i < f->wl; i++) {
        char c = f->want[i];
        if (c >= 'a' && c <= 'z') c = (char)(c - 32);
        if (c != name[i]) return 0;
    }
    f->e = *e; f->found = 1;
    return 1;
}

int umd_iso_find(umd_iso *iso, const char *path, umd_iso_entry *out)
{
    umd_iso_entry cur = { iso->root_lba, iso->root_len, 1 };
    const char *p = path;
    int depth = 0;
    iso->err[0] = 0;
    while (*p == '/') p++;
    while (*p) {
        const char *q = strchr(p, '/');
        size_t l = q ? (size_t)(q - p) : strlen(p);
        if (!cur.is_dir) return fail(iso, "a path goes through a file");
        if (++depth > DEPTH_MAX + 1) return fail(iso, "a path deeper than %u", DEPTH_MAX);    // (its parent at most 8 deep)
        find_ctx f = { p, l, { 0, 0, 0 }, 0 };
        if (walk_dir(iso, cur.lba, cur.size, find_cb, &f)) return -1;
        if (!f.found) return -1;
        cur = f.e;
        p += l;
        while (*p == '/') p++;
    }
    *out = cur;
    return 0;
}

int umd_iso_read_file(umd_iso *iso, const char *path, size_t max, uint8_t **out, size_t *len)
{
    umd_iso_entry e;
    *out = NULL; *len = 0;
    if (umd_iso_find(iso, path, &e)) { if (!iso->err[0]) snprintf(iso->err, sizeof(iso->err), "%s not in the image", path); return -1; }
    if (e.is_dir) return fail(iso, "a directory, not a file (LBA %u)", e.lba);
    if (e.size > max) return fail(iso, "a file of %u bytes, over the %u allowed", e.size, (uint32_t)max);
    uint8_t *b = (uint8_t *)malloc(e.size ? e.size : 1);
    if (!b) return fail(iso, "out of memory (%u bytes)", e.size);
    if (e.size && iso->read(iso->ud, (uint64_t)e.lba * SEC, b, e.size) != e.size) { free(b); return fail(iso, "a file at LBA %u could not be read", e.lba); }
    *out = b; *len = e.size;
    return 0;
}

typedef struct { void (*fn)(void *, const char *, const umd_iso_entry *); void *ud; } list_ctx;
static int list_cb(void *ud, const char *name, const umd_iso_entry *e)
{
    list_ctx *l = (list_ctx *)ud;
    l->fn(l->ud, name, e);
    return 0;
}

int umd_iso_listdir(umd_iso *iso, const char *path, void (*fn)(void *ud, const char *name, const umd_iso_entry *e), void *ud)
{
    umd_iso_entry d;
    if (umd_iso_find(iso, path, &d)) return -1;
    if (!d.is_dir) return fail(iso, "not a directory (LBA %u)", d.lba);
    // its depth (the root 0): ECMA-119 6.8.2.1 allows 8 levels, as tools/umd_iso.py does
    int depth = 0;
    for (const char *q = path; *q; q++) if (*q != '/' && (q == path || q[-1] == '/')) depth++;
    if (depth > DEPTH_MAX) return fail(iso, "directory depth %d > %d", depth, DEPTH_MAX);
    list_ctx l = { fn, ud };
    return walk_dir(iso, d.lba, d.size, list_cb, &l);
}

int umd_iso_disc_id(umd_iso *iso, char *out, size_t cap)
{
    uint8_t *b;
    size_t n;
    if (cap == 0 || umd_iso_read_file(iso, "/UMD_DATA.BIN", 4096, &b, &n)) return -1;
    // the first two '|' fields, each trimmed of spaces (tools/umd_iso.py's parse_umd_data)
    size_t end = 0;
    while (end < n && b[end]) end++;
    size_t f0 = 0, f1 = end, f1e = end;
    for (size_t i = 0; i < end; i++) if (b[i] == '|') { f1 = i + 1; break; }
    size_t f0e = f1 < end ? f1 - 1 : end;
    for (size_t i = f1; i < end; i++) if (b[i] == '|') { f1e = i; break; }
    size_t k = 0;
    const size_t st[2] = { f0, f1 }, en[2] = { f0e, f1e };
    for (int f = 0; f < 2; f++) {
        size_t a = st[f], z = en[f];
        while (a < z && b[a] == ' ') a++;
        while (z > a && b[z - 1] == ' ') z--;
        if (f && k + 1 < cap) out[k++] = '_';
        for (size_t i = a; i < z && k + 1 < cap; i++) {
            char c = (char)b[i];
            int ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-';
            out[k++] = ok ? c : '_';
        }
    }
    out[k] = 0;
    free(b);
    return k > 1 ? 0 : -1;
}
