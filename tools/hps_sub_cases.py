#!/usr/bin/env python3
"""B1's cases and its second golden (docs/hps_host.md §6; bench/umd/run_hps_sub.sh).

`lists`: the case lists tools/hps_sub_check.cpp reads ("path ux uy name" a line):
  synth.txt   every synthetic PNG of tools/png_golden.py (every colour type x depth, plain
              and Adam7, every filter, the DEFLATE edges, the refused cases) at four
              placements: (0, 0); half off the right and bottom edges; at (719, 479), one
              pixel on the plane; at (65535, 65535), wholly off it -- plus
              tools/sub_golden.py's end-to-end units (RGBA8, Adam7, an edge-clipped
              rectangle, a bad IDAT CRC) at their own placements
  corpus.txt  every subtitle unit of every disc (tools/png_corpus.py's cache), at its x, y
  rco.txt     every menu PNG (tools/rco_png.py's cache) at (0, 0) and centred as a 480x272
              page on the plane (120, 104)

`golden LIST DIGEST`: the synthetic cases' digests (hps_sub_check --digest) against
tools/sub_golden.py's plane_words() -- libpng's pixels through tools/png_oracle.c (a
separate program), premultiplied and placed in Python. One more oracle path, independent
of the C harness's.

    hps_sub_cases.py lists --out DIR [--corpus CACHE] [--rco CACHE]
    hps_sub_cases.py golden LIST DIGEST
"""
import argparse
import json
import os
import struct
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)


def ihdr_wh(png):
    if len(png) >= 24 and png[12:16] == b"IHDR":
        return struct.unpack(">II", png[16:24])
    return 0, 0


def placements(png):
    w, h = ihdr_wh(png)
    out = [(0, 0), (65535, 65535), (719, 479)]
    if 0 < w < 1 << 20 and 0 < h < 1 << 20:
        out.append((max(0, 720 - (w + 1) // 2), max(0, 480 - (h + 1) // 2)))
    return out


def write_lists(a):
    import png_golden as G
    import sub_golden as SG
    import umd_sub_extract
    sd = os.path.join(a.out, "synth")
    os.makedirs(sd, exist_ok=True)
    rows = []
    sc, _ = G.synth_cases()
    for c in sc + G.invalid_cases():
        p = os.path.join(sd, c.name + ".png")
        with open(p, "wb") as f:
            f.write(c.png)
        for ux, uy in placements(c.png):
            rows.append("%s %d %d %s@%d,%d" % (p, ux, uy, c.name, ux, uy))
    got, _ = umd_sub_extract.units(SG.e2e_synth())
    for i, u in enumerate(got):
        p = os.path.join(sd, "e2e_%d.png" % i)
        with open(p, "wb") as f:
            f.write(u["png"])
        x, y = u["hdr"]["x"], u["hdr"]["y"]
        rows.append("%s %d %d e2e_%d@%d,%d" % (p, x, y, i, x, y))
    with open(os.path.join(a.out, "synth.txt"), "w") as f:
        f.write("\n".join(rows) + "\n")
    print("hps_sub_cases: synth %d cases" % len(rows))

    if a.corpus and os.path.isdir(a.corpus):
        import png_corpus
        rows = []
        for disc, u in png_corpus.iter_cache(a.corpus):
            rows.append("%s %d %d %s/%s" % (u["path"], u["x"], u["y"], disc, u["file"]))
        with open(os.path.join(a.out, "corpus.txt"), "w") as f:
            f.write("\n".join(rows) + "\n")
        print("hps_sub_cases: corpus %d units" % len(rows))
    if a.rco and os.path.isdir(a.rco):
        rows = []
        for d in sorted(os.listdir(a.rco)):
            idx = os.path.join(a.rco, d, "index.json")
            if not os.path.exists(idx):
                continue
            with open(idx) as f:
                units = json.load(f)["units"]
            for u in units:
                if not u["file"].endswith(".png"):
                    continue
                p = os.path.join(a.rco, d, u["file"])
                rows.append("%s 0 0 %s/%s@0,0" % (p, d, u["file"]))
                rows.append("%s 120 104 %s/%s@120,104" % (p, d, u["file"]))
        with open(os.path.join(a.out, "rco.txt"), "w") as f:
            f.write("\n".join(rows) + "\n")
        print("hps_sub_cases: rco %d cases" % len(rows))
    return 0


def golden(a):
    import png_golden as G
    import sub_golden as SG
    G.build_oracle()
    dg = {}
    with open(a.digest) as f:
        for ln in f:
            name, v, w, h, clipped, crc = ln.split()
            dg[name] = (v, int(w), int(h), int(clipped), int(crc, 16))
    n = bad = 0
    with open(a.list) as f:
        for ln in f:
            path, ux, uy, name = ln.split()
            ux, uy = int(ux), int(uy)
            with open(path, "rb") as g:
                png = g.read()
            w, h, err, words = SG.plane_words(png, ux, uy)
            if err:
                want = ("REF", 0, 0, 0, 0)
            else:
                pix = {}
                for wd, m, val in words:
                    y, x2 = divmod(wd, 360)
                    if m & 0x0F:
                        pix[(2 * x2, y)] = val & 0xFFFFFFFF
                    if m & 0xF0:
                        pix[(2 * x2 + 1, y)] = val >> 32
                crc = 0
                clipped = 0
                for yy in range(h):
                    for xx in range(w):
                        ax, ay = xx + ux, yy + uy
                        if ax >= 720 or ay >= 480:
                            clipped += 1
                            continue
                        crc = zlib.crc32(struct.pack("<I", pix[(ax, ay)]), crc)
                want = ("OK", w, h, clipped, crc)
            n += 1
            if dg.get(name) != want:
                bad += 1
                if bad <= 10:
                    print("FAIL [golden] %s: C %s, sub_golden %s" % (name, dg.get(name), want))
    if not n:
        print("FAIL [golden] no cases")
        return 1
    if bad:
        print("FAIL [golden] %d of %d cases differ from sub_golden.py" % (bad, n))
        return 1
    print("PASS [golden] %d cases equal to sub_golden.py's plane words" % n)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = ap.add_subparsers(dest="cmd", required=True)
    l = sp.add_parser("lists")
    l.add_argument("--out", required=True)
    l.add_argument("--corpus")
    l.add_argument("--rco")
    g = sp.add_parser("golden")
    g.add_argument("list")
    g.add_argument("digest")
    a = ap.parse_args(argv)
    return write_lists(a) if a.cmd == "lists" else golden(a)


if __name__ == "__main__":
    sys.exit(main())
