// menu_dump.c -- P9 M1a's gate tool: load an RCO with main/support/umd/menu/rco.c and print what
// tools/rco_census.py measures of it, as one JSON object (tools/menu_rco_check.py compares them).
#include "rco.h"
#include "rco_attrs.h"
#include <stdio.h>
#include <stdlib.h>

static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }

int main(int argc, char **argv)
{
    if (argc != 2) { fprintf(stderr, "usage: menu_dump FILE.RCO\n"); return 2; }
    FILE *f = fopen(argv[1], "rb");
    if (!f) { perror(argv[1]); return 2; }
    fseek(f, 0, SEEK_END); long n = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *b = (uint8_t *)malloc((size_t)n);
    if (!b || fread(b, 1, (size_t)n, f) != (size_t)n) { fprintf(stderr, "read\n"); return 2; }
    fclose(f);
    rco r;
    if (rco_load(&r, b, (size_t)n)) { printf("{\"error\": \"%s\"}\n", r.err); return 1; }
    unsigned obj[256] = {0}, anim[256] = {0}, img[4][4] = {{0}}, snd[4][4] = {{0}};
    // the extras against the file's own sizes (no census field sees them; the engine reads every
    // attribute from them): a leaf's extra is its span; the VSMX blob fits its entry; an object's /
    // animation's size is its type's attribute words (rco_attrs.h, RCOMage's tables)
    unsigned x_bad = 0, a_bad = 0, a_seen = 0;
    int x_first = -1, a_first = -1;
    for (int i = 0; i < r.n; i++) {
        const rco_entry *e = &r.e[i];
        if (e->nsub == 0 && e->nxt && e->table != RCO_T_VSMX && e->nextra != e->nxt - 0x28) { if (!x_bad++) x_first = i; }
        if (e->table == RCO_T_VSMX && e->type == 1 && e->nxt &&
            (uint64_t)8 + rco_word(e, 0) + rco_word(e, 1) > (uint64_t)e->nxt - 0x28) { if (!x_bad++) x_first = i; }
        if (e->table == RCO_T_OBJECT && e->type > 0 && e->type < RCO_OBJ_NTYPES && e->esize) {
            a_seen++;
            if (e->esize - 0x28 != 4u * (uint32_t)RCO_OBJ_TYPES[e->type].words) { if (!a_bad++) a_first = i; }
        }
        if (e->table == RCO_T_ANIM && e->type > 0 && e->type < RCO_ANIM_NTYPES && e->nsub == 0 && e->nxt) {
            a_seen++;
            if (e->nxt - 0x28 != 4u * (uint32_t)RCO_ANIM_TYPES[e->type].words) { if (!a_bad++) a_first = i; }
        }
        if (e->table == RCO_T_OBJECT && e->type > 0) obj[e->type]++;
        if (e->table == RCO_T_ANIM && e->type > 0) anim[e->type]++;
        if (e->table == RCO_T_IMAGE && e->type == 1) {
            uint32_t w = rco_word(e, 0);
            if ((w & 0xFFFF) < 4 && (w >> 16) < 4) img[w & 0xFFFF][w >> 16]++;
        }
        if (e->table == RCO_T_SOUND && e->type == 1) {
            uint32_t w = rco_word(e, 0);
            if ((w & 0xFFFF) < 4 && (w >> 16) < 4) snd[w & 0xFFFF][w >> 16]++;
        }
    }
    printf("{\"version\": %u, \"compression\": %u, \"entries\": %d, \"max_depth\": %u, \"max_children\": %u",
           r.version, r.compression >> 4, r.n, r.max_depth, r.max_children);
    printf(", \"obj\": {");
    for (int t = 0, c = 0; t < 256; t++) if (obj[t]) printf("%s\"%d\": %u", c++ ? ", " : "", t, obj[t]);
    printf("}, \"anim\": {");
    for (int t = 0, c = 0; t < 256; t++) if (anim[t]) printf("%s\"%d\": %u", c++ ? ", " : "", t, anim[t]);
    printf("}, \"img_fmt\": {");
    for (int a = 0, c = 0; a < 4; a++) for (int k = 0; k < 4; k++) if (img[a][k]) printf("%s\"%d,%d\": %u", c++ ? ", " : "", a, k, img[a][k]);
    printf("}, \"sound_fmt\": {");
    for (int a = 0, c = 0; a < 4; a++) for (int k = 0; k < 4; k++) if (snd[a][k]) printf("%s\"%d,%d\": %u", c++ ? ", " : "", a, k, snd[a][k]);
    printf("}, \"extra_bad\": %u, \"attr_bad\": %u, \"attr_seen\": %u", x_bad, a_bad, a_seen);
    if (x_bad) printf(", \"extra_first\": \"table %u type %u at 0x%x\"", r.e[x_first].table, r.e[x_first].type, r.e[x_first].off);
    if (a_bad) printf(", \"attr_first\": \"table %u type %u at 0x%x\"", r.e[a_first].table, r.e[a_first].type, r.e[a_first].off);
    if (r.vsmx >= 0 && r.vsmx_len >= 52) {
        const uint8_t *v = r.vsmx_data;
        printf(", \"vsmx\": {\"instructions\": %u, \"text_entries\": %u, \"prop_entries\": %u, \"name_entries\": %u}",
               le32(v + 12) / 8, le32(v + 24), le32(v + 36), le32(v + 48));
    }
    printf("}\n");
    rco_free(&r);
    free(b);
    return 0;
}
