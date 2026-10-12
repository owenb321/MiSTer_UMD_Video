#!/usr/bin/env python3
"""UMD_VIDEO/PLAYLIST.UMD (magic UMDV0088) parser, and a cross-check against CLIPINF.

Layout, decoded by this tool on the local discs (docs/umd_video_format.md
"PLAYLIST.UMD"; big-endian). Fields marked (?) are carried raw and censused:

    0x00  "UMDV0088"
    0x08  u32 playlists_off                 (0x130 on every disc)
    0x0C  28 bytes (?)
    0x28  disc_info: u32 length (0x104), u32 (?)=1, u8 name_len, name
          ("UMDV-SAMPLE" on Akira: an authoring-tool default, not the title)

    playlists (at playlists_off): u32 length, u16 n_playlists, then n_playlists
    entries, each:
      +0x00 u32 length (bytes after this field)
      +0x04 u16 items_off, u16 marks_off     (relative to the entry's first byte)
      +0x08 28 bytes (?)
      +0x24 info: u32 length, then
                  u16 (?), 7 bytes BCD date-time (YYYY MM DD hh mm ss),
                  3 bytes (?), u16 (?), u8 name_len, name (e.g. "Trailer01" -- names
                  are authoring labels, not unique, and do not say which is the film)
      items (at items_off): u32 length, u32 n_items, then n_items x
                  { u32 item_len (22), u16 clip_name_len, char[8] clip name ("00001"),
                    u48 IN PTS, u48 OUT PTS }
      marks (at marks_off): u32 length, u16 n_marks, n_marks x 40:
                  { u8 type (?) (0x05), u8 flags (?), u16 item index, u48 PTS,
                    u48 (?), char[24] name, NUL-padded ("Mark2731" -- the number is the
                    mark's frame count at 29.97 fps, an authoring label) }

Measured on 33 discs: 3-46 playlists, EVERY one of 398 playlists exactly one item, up to
74 marks; mark flags take values 0 and 4-10 (meaning (?)); info byte 0 varies (0x00/0x10).

The P2 reader needs: the main playlist (main_playlist(): the LONGEST, not #0) -> item 0
-> clip name -> CLIPINF/<name>.CLP and STREAM/<name>.MPS. The P6 chapter list is the
marks of the playing playlist.

    umd_playlist.py disc.iso [--verify] [--json]
"""
import argparse
import json
import struct
import sys

MAGIC = b"UMDV0088"
MARK_LEN = 40


class PlaylistError(Exception):
    pass


def _u48(b, o):
    return (struct.unpack(">H", b[o:o + 2])[0] << 32) | struct.unpack(">I", b[o + 2:o + 6])[0]


def _len_at(raw, off, lo, hi, what):
    """u32 length at raw[off], its section required to end at or before `hi`."""
    if off < lo or off + 4 > hi:
        raise PlaylistError("%s at 0x%x outside its parent (0x%x..0x%x)" % (what, off, lo, hi))
    ln = struct.unpack(">I", raw[off:off + 4])[0]
    if off + 4 + ln > hi:
        raise PlaylistError("%s at 0x%x: length %d runs past its parent" % (what, off, ln))
    return ln


def _bcd(b):
    return "".join("%02x" % x for x in b)


def _parse_entry(raw, e0, e_end, idx):
    items_off, marks_off = struct.unpack(">HH", raw[e0 + 4:e0 + 8])
    ent = {"index": idx, "misc": raw[e0 + 8:e0 + 0x24].hex()}

    ioff = e0 + 0x24
    iln = _len_at(raw, ioff, e0, e_end, "playlist %d info" % idx)
    info = raw[ioff + 4:ioff + 4 + iln]
    ent["datetime"] = _bcd(info[2:9])
    nl = info[14] if len(info) > 14 else 0
    ent["name"] = info[15:15 + nl].decode("latin-1")
    ent["info_misc"] = info[:14].hex()

    a = e0 + items_off
    ln = _len_at(raw, a, e0, e_end, "playlist %d items" % idx)
    n = struct.unpack(">I", raw[a + 4:a + 8])[0]
    p = a + 8
    items = []
    for k in range(n):
        if p + 4 > a + 4 + ln:
            raise PlaylistError("playlist %d: item %d past the items section" % (idx, k))
        il = struct.unpack(">I", raw[p:p + 4])[0]
        body = raw[p + 4:p + 4 + il]
        if il < 22 or len(body) != il:
            raise PlaylistError("playlist %d item %d: length %d" % (idx, k, il))
        cl = struct.unpack(">H", body[0:2])[0]
        if cl > 8:
            raise PlaylistError("playlist %d item %d: clip name length %d > 8" % (idx, k, cl))
        items.append({"clip_name": body[2:2 + cl].decode("latin-1"),
                      "in_pts": _u48(body, 10), "out_pts": _u48(body, 16),
                      "extra": body[22:].hex()})
        p += 4 + il
    if p != a + 4 + ln:
        raise PlaylistError("playlist %d: %d unaccounted bytes in items" % (idx, a + 4 + ln - p))
    ent["items"] = items

    m = e0 + marks_off
    ln = _len_at(raw, m, e0, e_end, "playlist %d marks" % idx)
    n = struct.unpack(">H", raw[m + 4:m + 6])[0]
    if 2 + MARK_LEN * n != ln:
        raise PlaylistError("playlist %d: marks length %d does not hold %d marks" % (idx, ln, n))
    marks = []
    for k in range(n):
        b = raw[m + 6 + MARK_LEN * k:m + 6 + MARK_LEN * (k + 1)]
        marks.append({"type": b[0], "flags": b[1], "item": struct.unpack(">H", b[2:4])[0],
                      "pts": _u48(b, 4), "unk": _u48(b, 10),
                      "name": b[16:40].split(b"\x00")[0].decode("latin-1")})
    ent["marks"] = marks
    # sections must lie inside the entry and not overlap
    spans = sorted([(ioff, ioff + 4 + iln), (a, a + 4 + struct.unpack(">I", raw[a:a + 4])[0]),
                    (m, m + 4 + ln)])
    for (s0, s1), (t0, t1) in zip(spans, spans[1:]):
        if t0 < s1:
            raise PlaylistError("playlist %d: sections overlap at 0x%x" % (idx, t0))
    if spans[-1][1] != e_end:
        raise PlaylistError("playlist %d: %d bytes after its last section"
                            % (idx, e_end - spans[-1][1]))
    return ent


def parse(raw):
    if raw[:8] != MAGIC:
        raise PlaylistError("no UMDV0088 magic (got %r)" % raw[:8])
    if len(raw) < 0x30:
        raise PlaylistError("header truncated")
    pl_off = struct.unpack(">I", raw[8:12])[0]
    out = {"size": len(raw), "playlists_off": pl_off, "header_misc": raw[12:0x28].hex()}
    dln = _len_at(raw, 0x28, 0x28, pl_off, "disc_info")
    d = raw[0x2C:0x2C + dln]
    out["disc_info_unk"] = struct.unpack(">I", d[:4])[0]
    out["disc_name"] = d[5:5 + d[4]].decode("latin-1")

    ln = _len_at(raw, pl_off, pl_off, len(raw), "playlists")
    end = pl_off + 4 + ln
    if end != len(raw):
        raise PlaylistError("%d bytes after the playlists section" % (len(raw) - end))
    n = struct.unpack(">H", raw[pl_off + 4:pl_off + 6])[0]
    p = pl_off + 6
    pls = []
    for k in range(n):
        el = _len_at(raw, p, p, end, "playlist %d" % k)
        pls.append(_parse_entry(raw, p, p + 4 + el, k))
        p += 4 + el
    if p != end:
        raise PlaylistError("%d unaccounted bytes after playlist %d" % (end - p, n - 1))
    out["playlists"] = pls
    return out


def from_iso(iso):
    return parse(iso.read("/UMD_VIDEO/PLAYLIST.UMD"))


def main_playlist(pl):
    """Index of the feature: the LONGEST playlist. Not playlist 0 -- on Hero, Kill Bill
    Vol. 2 and The Incredibles playlist 0 is a <20 s intro and the film is #2. (On a PSP
    the RCO menu script chooses; this core has no menu, so it picks by duration.)"""
    best, idx = -1, 0
    for e in pl["playlists"]:
        d = sum(it["out_pts"] - it["in_pts"] for it in e["items"])
        if d > best:
            best, idx = d, e["index"]
    return idx


OUT_SLACK = 90000          # 1 s: an item OUT past its clip's CLPI end, tolerated + noted


def verify(iso, notes=None):
    """Cross-check against CLIPINF: every item names an existing clip, its IN/OUT lie
    inside that clip's CLPI PTS range (OUT may overrun the end by <= OUT_SLACK, appended
    to `notes`), and every mark names a real item and lies inside that item's IN..OUT.
    Returns problems ([] = ok)."""
    import umd_clpi
    pl = from_iso(iso)
    bad = []
    notes = [] if notes is None else notes
    cache = {}
    for e in pl["playlists"]:
        for k, it in enumerate(e["items"]):
            tag = "playlist %d item %d (%s)" % (e["index"], k, it["clip_name"])
            if not it["clip_name"].isdigit() or not iso.exists(
                    "/UMD_VIDEO/CLIPINF/%s.CLP" % it["clip_name"]):
                bad.append("%s: no such CLIPINF" % tag)
                continue
            n = int(it["clip_name"])
            if n not in cache:
                cache[n] = umd_clpi.from_iso(iso, n)
            c = cache[n]
            if not (c["start_pts"] <= it["in_pts"] < it["out_pts"]):
                bad.append("%s: IN/OUT %d..%d outside the clip's %d..%d" % (
                    tag, it["in_pts"], it["out_pts"], c["start_pts"], c["end_pts"]))
            elif it["out_pts"] > c["end_pts"]:
                # Hero playlist 1: OUT 5256 ticks (58 ms) past the CLPI end. Tolerated up
                # to OUT_SLACK and reported; a player clamps OUT to the stream's end.
                over = it["out_pts"] - c["end_pts"]
                (notes if over <= OUT_SLACK else bad).append(
                    "%s: OUT %d is %d ticks past the clip's end %d" % (
                        tag, it["out_pts"], over, c["end_pts"]))
        for j, mk in enumerate(e["marks"]):
            if mk["item"] >= len(e["items"]):
                bad.append("playlist %d mark %d: item %d of %d" % (
                    e["index"], j, mk["item"], len(e["items"])))
                continue
            it = e["items"][mk["item"]]
            if not (it["in_pts"] <= mk["pts"] <= it["out_pts"]):
                bad.append("playlist %d mark %d: PTS %d outside item %d..%d" % (
                    e["index"], j, mk["pts"], it["in_pts"], it["out_pts"]))
    return bad


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--verify", action="store_true")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    import umd_iso
    with umd_iso.UmdIso(a.iso) as iso:
        pl = from_iso(iso)
        notes = []
        bad = verify(iso, notes) if a.verify else []
    if a.json:
        json.dump(pl, sys.stdout, indent=1)
        print()
        return 0
    print("disc name %r, %d playlists, main = playlist %d (the longest)" % (
        pl["disc_name"], len(pl["playlists"]), main_playlist(pl)))
    for e in pl["playlists"]:
        print("  playlist %d %-12r %s  items %s  marks %d" % (
            e["index"], e["name"], e["datetime"],
            ", ".join("%s[%.1f..%.1f s]" % (i["clip_name"], i["in_pts"] / 90000.0,
                                           i["out_pts"] / 90000.0) for i in e["items"]),
            len(e["marks"])))
    if a.verify:
        print("verify: %s" % ("OK" if not bad else "%d PROBLEM(S)" % len(bad)))
        for b in bad[:20]:
            print("  " + b)
        for n in notes:
            print("  note: " + n)
    return 1 if bad else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except PlaylistError as e:
        sys.exit("umd_playlist: %s" % e)
