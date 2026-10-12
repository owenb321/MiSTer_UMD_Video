// menu_tree.c -- an RCO's object and animation trees with every attribute, one entry a line
// (P9 M1c: what the renderer draws; read beside the captures). Built on the engine's loader.
//
//   menu_tree FILE.RCO [--images]
// --images also lists the image table: index, label, format (0 PNG, 1 JPEG), compression, bytes and
// the size its header declares (PNG IHDR, a JPEG's SOFn; 0x0 unread).
#include "rco.h"
#include "rco_attrs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *TABLES[] = { "?", "main", "vsmx", "text", "image", "model", "sound", "font", "object", "anim" };

// an image's declared size from its header (no decode)
static void image_dims(const uint8_t *d, uint32_t n, unsigned *w, unsigned *h)
{
    *w = *h = 0;
    if (n >= 24 && !memcmp(d, "\x89PNG", 4)) {
        *w = (unsigned)d[16] << 24 | (unsigned)d[17] << 16 | (unsigned)d[18] << 8 | d[19];
        *h = (unsigned)d[20] << 24 | (unsigned)d[21] << 16 | (unsigned)d[22] << 8 | d[23];
        return;
    }
    for (uint32_t o = 2; n >= 4 && o + 9 < n && d[0] == 0xFF && d[1] == 0xD8; ) {
        if (d[o] != 0xFF) return;
        unsigned mk = d[o + 1], len = (unsigned)d[o + 2] << 8 | d[o + 3];
        if (mk >= 0xC0 && mk <= 0xCF && mk != 0xC4 && mk != 0xC8 && mk != 0xCC) {
            *h = (unsigned)d[o + 5] << 8 | d[o + 6];
            *w = (unsigned)d[o + 7] << 8 | d[o + 8];
            return;
        }
        o += 2 + len;
    }
}

static void attrs(const rco *r, const rco_entry *e)
{
    const rco_type_def *td = NULL;
    if (e->table == RCO_T_OBJECT && e->type < RCO_OBJ_NTYPES) td = &RCO_OBJ_TYPES[e->type];
    if (e->table == RCO_T_ANIM && e->type < RCO_ANIM_NTYPES) td = &RCO_ANIM_TYPES[e->type];
    if (!td) return;
    uint32_t w = 0;
    for (int i = 0; i < td->nattrs; i++) {
        int k = td->attrs[i].kind;
        uint32_t v = rco_word(e, w);
        if (k == RCO_A_FLOAT) { float f; memcpy(&f, &v, 4); printf(" %s=%g", td->attrs[i].name, f); w++; }
        else if (k == RCO_A_INT || k == RCO_A_UNK) { printf(" %s=%d", td->attrs[i].name, (int32_t)v); w++; }
        else {
            uint32_t t = v & 0xFFFF, p = rco_word(e, w + 1);
            w += 2;
            if (t == 0xFFFF) continue;
            if (t == 0x400) { const char *ev = rco_event(r, p); printf(" %s=\"%s\"", td->attrs[i].name, ev ? ev : "?"); continue; }
            int x = rco_by_offset(r, p);
            printf(" %s=@%s", td->attrs[i].name, x >= 0 && r->e[x].label[0] ? r->e[x].label : "?");
            if (t != 0x402 && t != 0x409 && t != 0x407 && t != 0x408) printf("(0x%x)", t);
        }
    }
}

int main(int argc, char **argv)
{
    if (argc < 2) { fprintf(stderr, "usage: menu_tree FILE.RCO [--images]\n"); return 2; }
    int images = argc > 2 && !strcmp(argv[2], "--images");
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc((size_t)n);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "read\n"); return 2; }
    fclose(f);
    rco r;
    if (rco_load(&r, b, (size_t)n)) { fprintf(stderr, "%s\n", r.err); return 1; }
    for (int i = 0; i < r.n; i++) {
        const rco_entry *e = &r.e[i];
        if (e->table == RCO_T_IMAGE && e->type == 1) {
            if (!images) continue;
            uint32_t fmt, cmp, len, un; const uint8_t *d;
            int ok = rco_image(&r, i, &fmt, &cmp, &d, &len, &un) == 0;
            unsigned iw = 0, ih = 0;
            if (ok && cmp == 0) image_dims(d, len, &iw, &ih);
            printf("IMG %3d %-24s fmt %u cmp %u bytes %u %ux%u%s\n", i, e->label, ok ? fmt : 0, ok ? cmp : 0, ok ? len : 0, iw, ih, ok ? "" : " (bad)");
            continue;
        }
        if (e->table != RCO_T_OBJECT && e->table != RCO_T_ANIM) continue;
        const char *tn = e->table == RCO_T_OBJECT ? (e->type < RCO_OBJ_NTYPES ? RCO_OBJ_TYPES[e->type].name : "?")
                                                  : (e->type < RCO_ANIM_NTYPES ? RCO_ANIM_TYPES[e->type].name : "?");
        printf("%*s%s %s %s", (int)e->depth * 2, "", TABLES[e->table < 10 ? e->table : 0], tn, e->label[0] ? e->label : "-");
        attrs(&r, e);
        printf("\n");
    }
    rco_free(&r);
    free(b);
    return 0;
}
