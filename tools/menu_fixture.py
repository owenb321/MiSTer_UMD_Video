#!/usr/bin/env python3
"""menu_fixture.py -- a disc's inputs for the menu engine on the PC (P9 M1, bench/umd/menu/
menu_run.c): its RESOURCE/*.RCO files and its playlists' timing, written into one directory.

    menu_fixture.py DISC.iso OUTDIR
writes OUTDIR/<NAME>.RCO and OUTDIR/playlists.txt, one line a playlist:
    <index> <duration ms> <chapters> <chapter 1 start ms> <chapter 2 start ms> ...
the duration the items' OUT - IN summed, the chapters the playlist's type-5 marks as offsets
from its start (umd_playlist.py: the P1 parser; never the engine's code); and OUTDIR/marks.txt, one
line a NAMED mark (any other type, its name not empty: movieplayer.onMark's), by time:
    <index> <offset ms> <name>
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402


def main(argv):
    if len(argv) != 2:
        sys.exit(__doc__)
    iso_path, out = argv
    os.makedirs(out, exist_ok=True)
    with umd_iso.UmdIso(iso_path) as iso:
        for n in iso.listdir("/UMD_VIDEO/RESOURCE"):
            if n.upper().endswith(".RCO"):
                open(os.path.join(out, n.upper()), "wb").write(iso.read("/UMD_VIDEO/RESOURCE/" + n, record=False))
        pl = umd_playlist.parse(iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False))
    lines, mlines = [], []
    for e in pl["playlists"]:
        items = e["items"]
        base, acc = [], 0
        for it in items:
            base.append(acc)
            acc += max(it["out_pts"] - it["in_pts"], 0)
        chaps = sorted(base[m["item"]] + m["pts"] - items[m["item"]]["in_pts"]
                       for m in e["marks"] if m["type"] == 5 and m["item"] < len(items))
        lines.append("%d %d %d %s" % (e["index"], acc // 90, len(chaps), " ".join(str(max(c, 0) // 90) for c in chaps)))
        named = sorted((base[m["item"]] + m["pts"] - items[m["item"]]["in_pts"], k, m["name"])
                       for k, m in enumerate(e["marks"]) if m["type"] != 5 and m["name"] and m["item"] < len(items))
        mlines += ["%d %d %s" % (e["index"], max(t, 0) // 90, n) for t, _, n in named]   # (the name: the rest of the line)
    open(os.path.join(out, "playlists.txt"), "w").write("\n".join(lines) + "\n")
    open(os.path.join(out, "marks.txt"), "w").write("".join(l + "\n" for l in mlines))
    print("menu_fixture: %s -> %s (%d playlists)" % (os.path.basename(iso_path), out, len(lines)))


if __name__ == "__main__":
    main(sys.argv[1:])
