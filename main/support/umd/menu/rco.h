// rco.h -- a disc menu's resource file (UMD_VIDEO/RESOURCE/*.RCO): the loader (P9 M1a,
// docs/p9.md S3.3). Portable C, built for the PC (bench/umd/menu/) and the HPS (the UMD Main).
//
// The layout is RCOMage's description (github.com/kakaroto/RCOMage, LGPL 2.1: src/rcofile.h,
// src/rcoreader.c), cross-checked against tools/rco_census.py on every RCO of the library:
//   header  "\0PRF", version, 0, compression (upper nibble: 0 none, 1 zlib), then 37 words --
//           the table pointers (main, VSMX, text, sound, model, image, -, font, object, anim),
//           the text / label / event data, the pointer tables, the attached image / sound /
//           model data (offset, length).
//   entry   0x28 bytes {u16 typeId (low byte the type, high byte the table), u16 0, label
//           offset, header size, entry size, subentries, next sibling offset, previous, parent
//           table offset, 2 x 0}, its extra words, then its subentries.
// Little-endian throughout (every UMD RCO; the PS3's big-endian ones are refused).
// A sound entry {format (1 VAG), channels, total size, offset} carries at least TWO {size, offset}
// channel pairs (a mono sound's second is zero), and a channel's offset is from the start of the
// sound data (header word RCO_H_SOUNDDATA), not from the entry's offset (measured 2026-10-02 on
// every library RCO: the entries' spans and the VAG headers they point at).
//
// The whole tree is kept as loaded (the bytes stay the caller's); entries are an array in
// walk order with parent / first child / next sibling indices. References between entries
// are file offsets (an attribute {type, offset}); rco_by_offset() resolves one.
//
// Bounds (docs/p9.md S6, "spec maximum"): counts and offsets are the format's u32s; the walk is
// iterative with a stack grown as needed (the census's deepest tree is 5, its widest 161
// children; the format allows any). Every structure is checked against the file: an entry or a
// table past the end refuses the file with a reason (rco.err), never a read out of bounds.
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { RCO_T_MAIN = 1, RCO_T_VSMX, RCO_T_TEXT, RCO_T_IMAGE, RCO_T_MODEL, RCO_T_SOUND, RCO_T_FONT,
       RCO_T_OBJECT, RCO_T_ANIM };

// the header's word indices (after the 16-byte signature / version / 0 / compression)
enum { RCO_H_MAIN = 0, RCO_H_VSMX, RCO_H_TEXT, RCO_H_SOUND, RCO_H_MODEL, RCO_H_IMAGE, RCO_H_UNK,
       RCO_H_FONT, RCO_H_OBJECT, RCO_H_ANIM, RCO_H_TEXTDATA, RCO_H_TEXTLEN, RCO_H_LABELDATA,
       RCO_H_LABELLEN, RCO_H_EVENTDATA, RCO_H_EVENTLEN, RCO_H_TEXTPTRS, RCO_H_TEXTPTRSLEN,
       RCO_H_IMGPTRS, RCO_H_IMGPTRSLEN, RCO_H_MODELPTRS, RCO_H_MODELPTRSLEN, RCO_H_SOUNDPTRS,
       RCO_H_SOUNDPTRSLEN, RCO_H_OBJPTRS, RCO_H_OBJPTRSLEN, RCO_H_ANIMPTRS, RCO_H_ANIMPTRSLEN,
       RCO_H_IMGDATA, RCO_H_IMGDATALEN, RCO_H_SOUNDDATA, RCO_H_SOUNDDATALEN, RCO_H_MODELDATA,
       RCO_H_MODELDATALEN, RCO_H_NWORDS = 37 };

typedef struct {
    uint8_t  table, type;      // typeId >> 8, typeId & 0xFF
    uint32_t off;              // its offset in the tree (what references point at)
    const char *label;         // "" when it has none
    int      parent, first, next;   // indices; -1 none
    uint32_t nsub;
    uint32_t esize, nxt;       // the entry's own size and next-sibling offset fields
    uint32_t depth;
    const uint8_t *extra;      // its extra words (little-endian)
    uint32_t nextra;           // ... in bytes
} rco_entry;

typedef struct {
    const uint8_t *buf;        // the tree (the file, or its unpacked tables)
    size_t   len;
    uint8_t *own;              // a buffer this loader allocated (unpacked tables), freed by rco_free
    const uint8_t *file;       // the file as given (the attached data lives here)
    size_t   flen;
    uint32_t version, compression;
    uint32_t h[RCO_H_NWORDS];
    rco_entry *e;
    int      n, cap;
    uint32_t max_depth, max_children;
    int      vsmx;             // the entry index of the (first) VSMX script, -1 none
    const uint8_t *vsmx_data;
    uint32_t vsmx_len;
    char     err[160];
} rco;

// 0 on success; else -1 with r->err. The file's bytes must outlive the rco.
int  rco_load(rco *r, const uint8_t *file, size_t len);
void rco_free(rco *r);
// the entry at a tree offset (a reference), -1 none
int  rco_by_offset(const rco *r, uint32_t off);
// the first entry of a table / type with this label, -1 none
int  rco_by_label(const rco *r, int table, const char *label);
// a little-endian word of an entry's extra, 0 past its end
uint32_t rco_word(const rco_entry *e, uint32_t i);
// an image entry's data in the file: format (0 PNG, 1 JPEG, ...), compression, the bytes
// a sound entry's channels (format 1: VAG, each channel its own VAG file, header included):
// 0 ok, -1 not a sound, more than two channels (the library: mono or stereo), or past the file
int  rco_sound(const rco *r, int idx, uint32_t *format, uint32_t *nch, const uint8_t *data[2], uint32_t len[2]);
int  rco_image(const rco *r, int idx, uint32_t *format, uint32_t *compression,
               const uint8_t **data, uint32_t *len, uint32_t *unpacked);
// an event string (an event reference's offset into the event data), NULL if out of range
const char *rco_event(const rco *r, uint32_t off);

#ifdef __cplusplus
}
#endif
