// rco.c -- the RCO loader (rco.h has the format and the bounds).
#include "rco.h"
#include "rco_attrs.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
// zlib's uncompress (the packed tables): the system's zlib where there is one (the PC benches), else
// the UMD Main's own miniz (lib/miniz, zlib-compatible names; Main ships no zlib headers)
#if defined(__has_include)
#  if __has_include(<zlib.h>)
#    include <zlib.h>
#  else
#    include "miniz.h"
#  endif
#else
#  include <zlib.h>
#endif

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }

static int fail(rco *r, const char *msg, uint32_t at)
{
    snprintf(r->err, sizeof(r->err), "%s (at 0x%x)", msg, at);
    return -1;
}

uint32_t rco_word(const rco_entry *e, uint32_t i)
{
    return (4 * i + 4 <= e->nextra) ? le32(e->extra + 4 * i) : 0;
}

// the extra bytes an entry carries, by its table and type (as the census reads them)
static int extra_len(rco *r, uint32_t off, uint8_t table, uint8_t type, uint32_t esize, uint32_t nsub,
                     uint32_t nxt, uint32_t *out)
{
    const uint8_t *b = r->buf + off;
    uint32_t x = 0;
    if (table == RCO_T_VSMX && type == 1) x = 8;
    else if (table == RCO_T_TEXT && type == 1) {
        if (off + 0x30 > r->len) return fail(r, "text entry past the tree", off);
        x = 8 + 12 * le32(b + 0x2C);
    } else if ((table == RCO_T_IMAGE || table == RCO_T_MODEL) && type == 1) {
        if (off + 0x2C > r->len) return fail(r, "image entry past the tree", off);
        x = nxt ? nxt - 0x28 : 12 + (le16(b + 0x2A) ? 4u : 0u);
    } else if (table == RCO_T_SOUND && type == 1) {
        if (off + 0x2C > r->len) return fail(r, "sound entry past the tree", off);
        // {format, channels, total size, offset}, then a {size, offset} pair a channel -- at least
        // TWO pairs (a mono sound's second is zero): measured, every library RCO (menu_rco_check)
        uint32_t ch = le16(b + 0x2A);
        x = 12 + 8 * (ch < 2 ? 2u : ch);
    } else if (table == RCO_T_OBJECT && type > 0) {
        if (esize) x = esize - 0x28;
        else if (type < RCO_OBJ_NTYPES) x = 4 * (uint32_t)RCO_OBJ_TYPES[type].words;
        else return fail(r, "object of an unknown type with no size", off);
    } else if (table == RCO_T_ANIM && type > 0) {
        if (nxt && !nsub) x = nxt - 0x28;
        else if (type < RCO_ANIM_NTYPES) x = 4 * (uint32_t)RCO_ANIM_TYPES[type].words;
        else return fail(r, "animation of an unknown type with no size", off);
    }
    *out = x;
    return 0;
}

static int add_entry(rco *r)
{
    if (r->n == r->cap) {
        int nc = r->cap ? 2 * r->cap : 256;
        rco_entry *ne = (rco_entry *)realloc(r->e, (size_t)nc * sizeof(rco_entry));
        if (!ne) return -1;
        r->e = ne; r->cap = nc;
    }
    return r->n++;
}

typedef struct { uint32_t off, left, nxt; int idx; } walk_frame;

// tools/rco_census.py's walk, unrolled: an entry's children follow its extra; an entry ends at
// its next-sibling offset when it has one, else where its last child ended
static int walk(rco *r, uint32_t root)
{
    walk_frame *st = NULL;
    int sp = 0, scap = 0, rc = -1;
    uint32_t at = root, ret;
    int parent = -1, prev_sib = -1, done;
    for (;;) {
        // ---- enter the entry at `at` ----
        if ((uint64_t)at + 0x28 > r->len) { fail(r, "entry past the tree", at); goto out; }
        const uint8_t *b = r->buf + at;
        uint32_t tid = le16(b), lab = le32(b + 4), esize = le32(b + 12), nsub = le32(b + 16), nxt = le32(b + 20), x;
        if (extra_len(r, at, (uint8_t)(tid >> 8), (uint8_t)tid, esize, nsub, nxt, &x)) goto out;
        if ((uint64_t)at + 0x28 + x > r->len) { fail(r, "entry's extra past the tree", at); goto out; }
        int idx = add_entry(r);
        if (idx < 0) { fail(r, "out of memory", at); goto out; }
        rco_entry *e = &r->e[idx];
        e->table = (uint8_t)(tid >> 8); e->type = (uint8_t)tid; e->off = at;
        e->label = "";
        if (lab != 0xFFFFFFFFu && lab < r->h[RCO_H_LABELLEN] &&
            (uint64_t)r->h[RCO_H_LABELDATA] + lab < r->len)
            e->label = (const char *)r->buf + r->h[RCO_H_LABELDATA] + lab;
        e->parent = parent; e->first = -1; e->next = -1; e->nsub = nsub; e->esize = esize; e->nxt = nxt;
        e->depth = (uint32_t)sp;
        e->extra = b + 0x28; e->nextra = x;
        if (prev_sib >= 0) r->e[prev_sib].next = idx;
        else if (parent >= 0) r->e[parent].first = idx;
        if ((uint32_t)sp > r->max_depth) r->max_depth = (uint32_t)sp;
        if (nsub > r->max_children) r->max_children = nsub;
        if (e->table == RCO_T_VSMX && e->type == 1 && r->vsmx < 0) {
            uint32_t vo = le32(b + 0x28), vl = le32(b + 0x2C);
            if ((uint64_t)at + 0x30 + vo + vl <= r->len) {
                r->vsmx = idx; r->vsmx_data = b + 0x30 + vo; r->vsmx_len = vl;
            }
        }
        if (nsub) {
            if (sp == scap) {
                int nc = scap ? 2 * scap : 16;
                walk_frame *ns = (walk_frame *)realloc(st, (size_t)nc * sizeof(walk_frame));
                if (!ns) { fail(r, "out of memory", at); goto out; }
                st = ns; scap = nc;
            }
            st[sp].off = at; st[sp].left = nsub; st[sp].nxt = nxt; st[sp].idx = idx;
            sp++;
            parent = idx; prev_sib = -1; at = at + 0x28 + x;
            continue;
        }
        // ---- a leaf ends; climb while parents end ----
        ret = nxt ? at + nxt : at + 0x28 + x;
        done = idx;
        for (;;) {
            if (sp == 0) { rc = 0; goto out; }
            walk_frame *f = &st[sp - 1];
            if (--f->left) { parent = f->idx; prev_sib = done; at = ret; break; }
            ret = f->nxt ? f->off + f->nxt : ret;
            done = f->idx;
            sp--;
        }
    }
out:
    free(st);
    return rc;
}

int rco_load(rco *r, const uint8_t *file, size_t len)
{
    memset(r, 0, sizeof(*r));
    r->vsmx = -1;
    r->file = file; r->flen = len;
    if (len < 16 + 4 * RCO_H_NWORDS || memcmp(file, "\0PRF", 4)) return fail(r, "not an RCO", 0);
    r->version = le32(file + 4);
    r->compression = le32(file + 12);
    for (int i = 0; i < RCO_H_NWORDS; i++) r->h[i] = le32(file + 16 + 4 * i);
    r->buf = file; r->len = len;
    if (r->compression >> 4) {
        // the tables from 0xA4 are packed: {packed, unpacked, longest text}, then the stream
        if (len < 0xB0) return fail(r, "packed header past the file", 0xA4);
        uint32_t lp = le32(file + 0xA4), lu = le32(file + 0xA8);
        if ((r->compression >> 4) != 1) return fail(r, "packed with RLZ (unsupported)", 0xA4);
        if ((uint64_t)0xB0 + lp > len) return fail(r, "packed tables past the file", 0xB0);
        r->own = (uint8_t *)malloc((size_t)0xA4 + lu);
        if (!r->own) return fail(r, "out of memory", 0);
        memcpy(r->own, file, 0xA4);
        uLongf dl = lu;
        if (uncompress(r->own + 0xA4, &dl, file + 0xB0, lp) != Z_OK || dl != lu)
            return fail(r, "packed tables do not inflate", 0xB0);
        r->buf = r->own; r->len = 0xA4 + (size_t)lu;
    }
    if (r->h[RCO_H_MAIN] == 0xFFFFFFFFu || r->h[RCO_H_MAIN] >= r->len) return fail(r, "no main table", 16);
    return walk(r, r->h[RCO_H_MAIN]);
}

void rco_free(rco *r)
{
    free(r->e);
    free(r->own);
    memset(r, 0, sizeof(*r));
    r->vsmx = -1;
}

int rco_by_offset(const rco *r, uint32_t off)
{
    // entries are in walk order, which is offset order within a table: a linear scan is
    // enough at load-time sizes (2,653 entries at most in the library); the engine caches
    for (int i = 0; i < r->n; i++)
        if (r->e[i].off == off) return i;
    return -1;
}

int rco_by_label(const rco *r, int table, const char *label)
{
    for (int i = 0; i < r->n; i++)
        if ((table == 0 || r->e[i].table == table) && !strcmp(r->e[i].label, label)) return i;
    return -1;
}

int rco_image(const rco *r, int idx, uint32_t *format, uint32_t *compression,
              const uint8_t **data, uint32_t *len, uint32_t *unpacked)
{
    if (idx < 0 || idx >= r->n) return -1;
    const rco_entry *e = &r->e[idx];
    if (e->table != RCO_T_IMAGE || e->type != 1 || e->nextra < 12) return -1;
    uint32_t w0 = rco_word(e, 0);
    *format = w0 & 0xFFFF; *compression = w0 >> 16;
    *len = rco_word(e, 1);
    uint32_t off = rco_word(e, 2);
    *unpacked = (*compression && e->nextra >= 16) ? rco_word(e, 3) : *len;
    uint64_t at = (uint64_t)r->h[RCO_H_IMGDATA] + off;
    if (at + *len > r->flen) return -1;
    *data = r->file + at;
    return 0;
}

int rco_sound(const rco *r, int idx, uint32_t *format, uint32_t *nch, const uint8_t *data[2], uint32_t len[2])
{
    if (idx < 0 || idx >= r->n) return -1;
    const rco_entry *e = &r->e[idx];
    if (e->table != RCO_T_SOUND || e->type != 1 || e->nextra < 12 + 16) return -1;
    uint32_t w0 = rco_word(e, 0);
    *format = w0 & 0xFFFF;
    *nch = w0 >> 16;
    if (*nch < 1 || *nch > 2) return -1;                     // (the library: mono or stereo)
    for (uint32_t c = 0; c < 2; c++) {
        data[c] = NULL; len[c] = 0;
        if (c >= *nch) continue;
        uint32_t sz = rco_word(e, 3 + 2 * c), off = rco_word(e, 4 + 2 * c);
        uint64_t at = (uint64_t)r->h[RCO_H_SOUNDDATA] + off;
        if (at + sz > r->flen) return -1;
        data[c] = r->file + at; len[c] = sz;
    }
    return 0;
}

const char *rco_event(const rco *r, uint32_t off)
{
    if (off >= r->h[RCO_H_EVENTLEN]) return NULL;
    uint64_t at = (uint64_t)r->h[RCO_H_EVENTDATA] + off;
    if (at >= r->len) return NULL;
    return (const char *)r->buf + at;
}
