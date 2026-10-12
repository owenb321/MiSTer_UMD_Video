#!/usr/bin/env python3
"""menu_pl_check.py -- P9 M3: the UMD Main's PLAYLIST.UMD parser (main/support/umd/menu/
umd_playlist.c, run by bench/umd/menu/pl_dump.c) against tools/umd_playlist.py, and its chapters
against tools/umd_nav_ref.py's rule (the type-5 marks on an existing item, by (item, PTS)).

    menu_pl_check.py [--iso-dir DIR] [--dump .sim/menu/pl_dump] [--synthetic-only]

EQUAL per file: every playlist (items, marks, the chapter list) -- or both refuse it. On every
image's PLAYLIST.UMD, and on synthetic files built with tools/tests/umd_synth.py for what no disc
has: 65,535 marks (the u16 maximum) unsorted, with Endmarks, duplicates and marks on a missing
item; several items; a marks section whose length does not hold its count; a count past the file;
a playlists section short of its file; an item's clip name over 8. "PASS: menu_pl_check".
"""
import argparse
import glob
import os
import random
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tests"))
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402
import umd_synth as S  # noqa: E402


def expect(raw):
    try:
        pl = umd_playlist.parse(raw)
    except Exception:                      # PlaylistError, or a short field the P1 parser trips on
        return None
    out = []
    for e in pl["playlists"]:
        i = e["index"]
        n = len(e["items"])
        chaps = sorted((m["item"], m["pts"]) for m in e["marks"] if m["type"] == 5 and m["item"] < n)
        out.append("P %d %d %d %d %s" % (i, n, len(e["marks"]), len(chaps), e["name"]))
        for k, it in enumerate(e["items"]):
            out.append("I %d %d %s %d %d" % (i, k, it["clip_name"], it["in_pts"], it["out_pts"]))
        for k, m in enumerate(e["marks"]):
            nm = "".join(c if 0x20 < ord(c) < 0x7F and c != "\\" else "\\x%02x" % ord(c) for c in m["name"])
            out.append("M %d %d %d %d %d %d %s" % (i, k, m["type"], m["flags"], m["item"], m["pts"], nm))
        for c, (it, pts) in enumerate(chaps):
            out.append("C %d %d %d %d" % (i, c + 1, it, pts))
    return out


def synthetic():
    r = random.Random(9)
    marks = []
    for k in range(65535):
        typ = 16 if k % 997 == 0 else 5
        item = 3 if k % 1009 == 0 else r.randrange(3)       # item 3 does not exist
        marks.append((0, item, r.randrange(1 << 40), "M%d" % k, typ))
    marks[100] = marks[99]                                   # a duplicate
    # the names (onMark's mark_name): all 24 bytes used (no NUL), and a space, a backslash, a byte past ASCII
    marks[997] = marks[997][:3] + ("ABCDEFGHIJKLMNOPQRSTUVWX",) + marks[997][4:]
    marks[1994] = marks[1994][:3] + ("End mark\\\u00e9",) + marks[1994][4:]
    items = [("00001", 90000, 9000000), ("00002", 1000, 5000000), ("00003", 0, 1 << 47)]
    good = S.playlist_file([S.entry("Feature", items, marks), S.entry("Empty", [], []),
                            S.entry("One", items[:1], [(0, 0, 90000, "x"), (0, 0, 90000, "y", 16)])])
    yield "syn_pl_max", good
    e = bytearray(S.entry("Bad", items[:1], [(0, 0, 1, "a")]))
    # the marks length one short of holding its count
    mo = struct.unpack(">H", e[6:8])[0]                     # the marks offset, from the entry's length word
    struct.pack_into(">H", e, mo + 4, 2)                     # two marks claimed in a one-mark length
    yield "syn_pl_badmarks", S.playlist_file([bytes(e)])
    f = bytearray(S.playlist_file([S.entry("A", items[:1], [])]))
    struct.pack_into(">H", f, 0x130 + 4, 5)                  # five playlists claimed, one there
    yield "syn_pl_oobcount", bytes(f)
    yield "syn_pl_short", S.playlist_file([S.entry("A", items[:1], [])])[:-3]
    e = bytearray(S.entry("Long", [("00001", 0, 1)], []))
    io = struct.unpack(">H", e[4:6])[0]                      # the items offset
    struct.pack_into(">H", e, io + 12, 9)                    # the first item's clip name length: 9
    yield "syn_pl_clipname", S.playlist_file([bytes(e)])


def run(dump, args):
    return subprocess.run([dump] + args, stdout=subprocess.PIPE, universal_newlines=True).stdout.splitlines()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--dump", default=os.path.join(os.path.dirname(HERE), ".sim/menu/pl_dump"))
    ap.add_argument("--synthetic-only", action="store_true")
    a = ap.parse_args()
    n = bad = refused = lines = 0
    tmp = tempfile.mkdtemp()
    cases = list(synthetic())
    for p in ([] if a.synthetic_only else sorted(glob.glob(os.path.join(a.iso_dir, "*")))):
        if p.lower().endswith(".iso"):
            with umd_iso.UmdIso(p) as iso:
                cases.append((os.path.basename(p), iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False)))
    for name, raw in cases:
        f = os.path.join(tmp, "pl.bin")
        open(f, "wb").write(raw)
        got = run(a.dump, ["--raw", f])
        want = expect(raw)
        n += 1
        if want is None:
            if got and got[0].startswith("ERR"):
                refused += 1
            else:
                bad += 1
                print("  FAIL %s: umd_playlist.py refuses it, umd_playlist.c does not" % name)
            continue
        lines += len(want)
        if got != want:
            bad += 1
            miss = [l for l in want if l not in got][:2]
            extra = [l for l in got if l not in want][:2]
            print("  FAIL %s: missing %s, extra %s" % (name, miss, extra))
    print("menu_pl_check: %d files (%d lines), %d differ, %d refused by both" % (n, lines, bad, refused))
    if bad:
        print("FAIL: menu_pl_check")
        return 1
    print("PASS: menu_pl_check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
