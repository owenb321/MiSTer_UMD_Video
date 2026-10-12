#!/usr/bin/env python3
"""Fixtures for the subtitle benches (docs/subtitles.md §4).

`units` mode: umd/sub/sub_unit.sv's input and golden -- a subtitle substream as the
demultiplexer hands it over (per PES: the payload after the 2-byte sub-header, the first
byte flagged with the PES's PTS), and the units tools/umd_sub_extract.py.units() -- the
tool that measured every disc -- makes of it. The golden is that tool, not this RTL's
reading of it. Cases: whole disc substreams (psmf_ref.parse) and synthetic PES lists for
the edges the discs have too few of (a one-byte continuation, a PTS-bearing continuation,
truncation, overrun, orphans, a lost-bytes gap, a refused unit, a header shorter than 16).

Fixture (one hex word a line):
  <stem>.in.hex    per input byte {gap, ptsv, start, pts[32:0], byte[7:0]} (44 bits)
  <stem>.rec.hex   per unit, 5 words: pts, duration, x, y, PNG length
  <stem>.ub.hex    every unit's PNG bytes, concatenated
  <stem>.meta.hex  n_in, n_units, n_ub, truncated, overrun, orphan, lost, refused,
                   badhdr, oddfield, refuse_every (the bench refuses every Nth begin; 0 never)

    sub_golden.py units --out DIR [--disc IMAGE --clip N --sub 0x80 [--packs N]] [--synth]
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import umd_sub_extract  # noqa: E402

MAGIC = b"0088"


def unit(png, dur=3003, x=100, y=400, f12=0x10, f18=0):
    body = MAGIC + struct.pack(">IHHHH", dur, f12, x, y, f18) + png
    return struct.pack(">I", len(body)) + body


def expected(pes, refuse_every=0, gaps=()):
    """The units umd_sub_extract.units() makes of `pes`, then the RTL's own verdicts on
    top where the tool has none: a unit whose bytes cross a lost-bytes gap (PES index in
    `gaps` -- the gap flags that PES's first byte) is aborted; every Nth unit to reach
    its begin is refused. -> (records, bytes, counters)"""
    got, info = umd_sub_extract.units(pes)
    cnt = {"truncated": info["truncated"], "overrun": info["overrun"],
           "orphan": info["stray"] + info["orphan"], "lost": 0, "refused": 0,
           "badhdr": 0, "oddfield": 0}
    # which PES each unit started in / ended in (to apply the gap rule)
    spans = []
    cur = None
    for i, (pts, pl) in enumerate(pes):
        if pts is not None and len(pl) >= 20 and pl[4:8] == MAGIC:
            cur = [i, len(pl), struct.unpack(">I", pl[0:4])[0] + 4]
        elif cur is not None:
            cur[1] += len(pl)
        else:
            continue
        if cur[1] >= cur[2]:
            spans.append((cur[0], i))
            cur = None
    assert len(spans) == len(got)
    recs, ub, starts = [], bytearray(), []
    first_byte = []                         # input byte index of each PES's first byte
    o = 0
    for _, pl in pes:
        first_byte.append(o)
        o += len(pl)
    n = 0
    for (a, b), u in zip(spans, got):
        h = u["hdr"]
        if any(a < g <= b for g in gaps):
            cnt["lost"] += 1
            continue
        if h["len"] - 4 <= 16:
            cnt["badhdr"] += 1
            continue
        n += 1
        if refuse_every and n % refuse_every == 0:
            cnt["refused"] += 1
            continue
        if h["f12"] != 0x10 or h["f18"] != 0:
            cnt["oddfield"] += 1
        recs.append((u["pts"], h["duration"], h["x"], h["y"], len(u["png"])))
        starts.append(first_byte[a])
        ub += u["png"]
    expected.starts = starts
    return recs, bytes(ub), cnt


def write(stem, pes, refuse_every=0, gaps=()):
    recs, ub, cnt = expected(pes, refuse_every, gaps)
    words = []
    for i, (pts, pl) in enumerate(pes):
        for k, b in enumerate(pl):
            st = 1 if k == 0 else 0
            pv = 1 if (k == 0 and pts is not None) else 0
            gp = 1 if (k == 0 and i in gaps) else 0
            words.append(gp << 43 | pv << 42 | st << 41 | ((pts or 0) & ((1 << 33) - 1)) << 8 | b)
    with open(stem + ".in.hex", "w") as f:
        f.write("".join("%011x\n" % w for w in words))
    with open(stem + ".rec.hex", "w") as f:
        for r in recs:
            f.write("".join("%09x\n" % v for v in r))
        if not recs:
            f.write("0\n")
    with open(stem + ".ub.hex", "w") as f:
        f.write("".join("%02x\n" % b for b in ub) or "00\n")
    with open(stem + ".ustart.hex", "w") as f:           # each unit's first input byte
        f.write("".join("%08x\n" % v for v in expected.starts) or "0\n")
    meta = [len(words), len(recs), len(ub), cnt["truncated"], cnt["overrun"], cnt["orphan"],
            cnt["lost"], cnt["refused"], cnt["badhdr"], cnt["oddfield"], refuse_every]
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in meta))
    return len(recs), cnt


def synth_cases():
    """[(name, pes, refuse_every, gaps)]"""
    from PIL import Image
    import io

    def png(w, h, seed):
        im = Image.new("P", (w, h), 0)
        im.putpalette([(i * 16 + seed) % 256 for i in range(16) for _ in range(3)])
        for x in range(w):
            im.putpixel((x, (x + seed) % h), (x + seed) % 16)
        b = io.BytesIO()
        im.save(b, format="PNG", bits=4, transparency=0)
        return b.getvalue()

    p = [png(40 + 10 * i, 12 + i, i) for i in range(8)]
    u = [unit(p[i], dur=3003 * (i + 1), x=20 * i, y=300 + i) for i in range(8)]
    cases = []
    # whole units, one per PES; a unit split in three; the last PES carrying ONE byte (Akira)
    cases.append(("syn_basic", [(1000, u[0]), (2000, u[1][:30]), (None, u[1][30:-1]), (None, u[1][-1:]),
                                (3000, u[2])], 0, ()))
    # a PTS-bearing continuation (bytes 4..7 are not the magic: replayed into the unit),
    # and one shorter than the magic (ends at byte 3: replayed too)
    k = 25
    cases.append(("syn_pts_cont", [(1000, u[3][:k]), (1500, u[3][k:k + 9]), (1600, u[3][k + 9:k + 12]),
                                   (None, u[3][k + 12:]), (5000, u[4])], 0, ()))
    # truncated (a new header before the old unit is complete), overrun (a PES carrying
    # bytes past the unit), orphans (a PES with no unit: with and without a PTS)
    cases.append(("syn_trunc_overrun_orphan", [(None, b"\x01\x02\x03"), (900, b"junk-no-magic-here-xxxxxxx"),
                                               (1000, u[5][:50]), (2000, u[6] + b"\xAA\xBB\xCC"),
                                               (None, b"\x99" * 5), (3000, u[7])], 0, ()))
    # a lost-bytes gap inside a unit (on its 2nd PES), then a clean unit
    cases.append(("syn_gap", [(1000, u[0][:40]), (None, u[0][40:]), (2000, u[1])], 0, (1,)))
    # every 2nd unit refused by the ring
    cases.append(("syn_refuse", [(1000 * (i + 1), u[i]) for i in range(6)], 2, ()))
    # a header whose length leaves no PNG (len <= 16), then a good unit; odd header fields
    bad = struct.pack(">I", 16) + MAGIC + bytes(12)
    cases.append(("syn_badhdr_odd", [(1000, bad), (2000, unit(p[2], f12=0x11, f18=3))], 0, ()))
    return cases


def disc_case(image, clip, sub, packs=None):
    import psmf_ref
    src = psmf_ref.Source(image, clip)
    src.limit(packs)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        pes = [(p.pts, bytes(src.mm[p.payload_off:p.payload_off + p.payload_len]))
               for p in r.packets if p.kind == "sub" and p.sub == sub]
    finally:
        src.close()
    return pes


def premul(c, a):
    """The plane's premultiply, exactly round(c * a / 255) (docs/subtitles.md §2)."""
    t = c * a + 128
    v = (t + (t >> 8)) >> 8
    assert v == (2 * c * a + 255) // 510, (c, a)     # round-half-up of c*a/255
    return v


def plane_words(png, ux, uy):
    """libpng's pixels of `png`, premultiplied, placed at (ux, uy) of a 720-pitch plane,
    clipped to 720x480 -> (w, h, err, [(word, mask, value)] sorted by word)."""
    import png_golden as G
    v, hd, px, _ = G.libpng(png)
    if v != "OK":
        return 0, 0, 1, []
    w, h = hd["w"], hd["h"]
    words = {}
    for y in range(h):
        for x in range(w):
            ax, ay = x + ux, y + uy
            if ax >= 720 or ay >= 480:
                continue
            r, g, b, a = (c >> 8 for c in px[y * w + x])
            argb = a << 24 | premul(r, a) << 16 | premul(g, a) << 8 | premul(b, a)
            wd = ay * 360 + (ax >> 1)
            m, val = words.get(wd, (0, 0))
            if ax & 1:
                m, val = m | 0xF0, val | argb << 32
            else:
                m, val = m | 0x0F, val | argb
            words[wd] = (m, val)
    return w, h, 0, [(k, m, v_) for k, (m, v_) in sorted(words.items())]


def write_e2e(stem, pes):
    """sub_top_tb's fixture: the input stream and, per unit the tool finds (in order):
    pts, duration, x, y, w, h, err (1 = libpng refuses it), its plane words; and (A7, the
    mock host's check of what it reads from the ring) each unit's PNG bytes, .ub.hex, with
    their offset and length per record, .uo.hex."""
    recs, ub, cnt = expected(pes)
    got, _ = umd_sub_extract.units(pes)
    words = []
    for i, (pts, pl) in enumerate(pes):
        for k, b in enumerate(pl):
            st = 1 if k == 0 else 0
            pv = 1 if (k == 0 and pts is not None) else 0
            words.append(pv << 42 | st << 41 | ((pts or 0) & ((1 << 33) - 1)) << 8 | b)
    with open(stem + ".in.hex", "w") as f:
        f.write("".join("%011x\n" % w for w in words))
    pw = []
    rows = []
    ub, uo = [], []
    clipped = 0
    for u in got:
        h = u["hdr"]
        if h["len"] - 4 <= 16:
            continue
        uo.append((len(ub), len(u["png"])))
        ub += list(u["png"])
        w_, h_, err, ws = plane_words(u["png"], h["x"], h["y"])
        if not err:
            clipped += sum(1 for yy in range(h_) for xx in range(w_)
                           if xx + h["x"] >= 720 or yy + h["y"] >= 480)
        rows.append((u["pts"], h["duration"], h["x"], h["y"], w_, h_, err, len(pw), len(ws)))
        pw += ws
    with open(stem + ".urec.hex", "w") as f:
        for r in rows:
            f.write("".join("%09x\n" % v for v in r))
        if not rows:
            f.write("0\n")
    with open(stem + ".pw.hex", "w") as f:
        f.write("".join("%05x%02x%016x\n" % t for t in pw) or "0\n")
    with open(stem + ".ub.hex", "w") as f:
        f.write("".join("%02x\n" % b for b in ub) or "0\n")
    with open(stem + ".uo.hex", "w") as f:
        f.write("".join("%08x\n%08x\n" % t for t in uo) or "0\n")
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in (len(words), len(rows), len(pw), clipped,
                                                sum(1 for r in rows if r[6]))))
    return len(rows), sum(1 for r in rows if r[6])


def e2e_synth():
    """Units no disc has: RGBA8 art (the menus' type), Adam7, a rectangle clipped at the
    right and bottom edges, a PNG with a bad CRC (refused, never shown)."""
    import png_golden as G
    import random
    rng = random.Random(3)
    imgs = [
        G.Img(64, 20, 6, 8, 0, G.rnd_samples(rng, 64, 20, 6, 8)),
        G.Img(33, 17, 3, 4, 1, G.rnd_samples(rng, 33, 17, 3, 4, maxv=15), G.rnd_palette(rng, 16),
              [rng.randint(0, 255) for _ in range(16)]),
        G.Img(50, 30, 2, 16, 0, G.rnd_samples(rng, 50, 30, 2, 16)),
    ]
    pngs = [G.build_png(im, lambda p, j: rng.randint(0, 4))[0] for im in imgs]
    bad = bytearray(pngs[0])
    k = bad.index(b"IDAT") - 4
    ln = struct.unpack(">I", bytes(bad[k:k + 4]))[0]
    bad[k + 8 + ln] ^= 1                           # the IDAT CRC: fatal for libpng and the RTL
    t = 900000
    pes = []
    pos = [(100, 300), (650, 470), (700, 400), (10, 10)]
    for i, p in enumerate(pngs + [bytes(bad)]):
        x, y = pos[i]
        u = unit(p, dur=45000, x=x, y=y)
        pes.append((t, u[:40]))
        pes.append((None, u[40:]))
        t += 90000
    return pes


def e2e_zoom_synth():
    """fj#71 Zoom's clamp (docs/zoom.md Z3) on what e2e_synth lacks: a unit above the band (y < 60)
    and one taller than it (400 rows), with one inside it between them (unchanged)."""
    import png_golden as G
    import random
    rng = random.Random(71)
    imgs = [
        G.Img(48, 16, 3, 4, 0, G.rnd_samples(rng, 48, 16, 3, 4, maxv=15), G.rnd_palette(rng, 16),
              [rng.randint(0, 255) for _ in range(16)]),
        G.Img(40, 100, 6, 8, 0, G.rnd_samples(rng, 40, 100, 6, 8)),
        G.Img(24, 400, 3, 4, 0, G.rnd_samples(rng, 24, 400, 3, 4, maxv=15), G.rnd_palette(rng, 16),
              [rng.randint(0, 255) for _ in range(16)]),
    ]
    pngs = [G.build_png(im, lambda p, j: rng.randint(0, 4))[0] for im in imgs]
    t = 900000
    pes = []
    pos = [(200, 20), (300, 150), (600, 40)]
    for i, p in enumerate(pngs):
        x, y = pos[i]
        u = unit(p, dur=45000, x=x, y=y)
        pes.append((t, u[:40]))
        pes.append((None, u[40:]))
        t += 90000
    return pes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("mode", choices=("units", "e2e"))
    ap.add_argument("--units", type=int, default=0, help="e2e: keep the first N units of a disc track")
    ap.add_argument("--skip", type=int, default=0, help="e2e: start at unit number N")
    ap.add_argument("--out", required=True)
    ap.add_argument("--synth", action="store_true")
    ap.add_argument("--zoom-synth", action="store_true", help="e2e: fj#71 Zoom's clamp cases (e2e_zoom)")
    ap.add_argument("--disc", action="append", default=[], help="IMAGE:CLIP:SUB[:PACKS]")
    ap.add_argument("--list", default="units")
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    stems = []
    if a.mode == "e2e":
        cases = []
        if a.synth:
            cases.append(("e2e_synth", e2e_synth()))
        if a.zoom_synth:
            cases.append(("e2e_zoom", e2e_zoom_synth()))
        for d in a.disc:
            parts = d.rsplit(":", 2)
            image, clip, sub = parts[0], int(parts[1]), int(parts[2], 0)
            pes = disc_case(image, clip, sub)
            if a.skip:
                # start at the PES that opens unit number `skip`
                n = 0
                for i, (pts, pl) in enumerate(pes):
                    if pts is not None and len(pl) >= 20 and pl[4:8] == MAGIC:
                        if n == a.skip:
                            pes = pes[i:]
                            break
                        n += 1
            if a.units:
                # keep the PES up to the end of the N-th unit
                n = 0
                for k in range(1, len(pes) + 1):
                    got, _ = umd_sub_extract.units(pes[:k])
                    if len(got) >= a.units:
                        pes = pes[:k]
                        break
            name = "e2e_%s_c%d_s%02x" % ("".join(ch for ch in os.path.basename(image).split(" (")[0]
                                                 if ch.isalnum()), clip, sub)
            cases.append((name, pes))
        for name, pes in cases:
            stem = os.path.join(a.out, name)
            n, nbad = write_e2e(stem, pes)
            stems.append(stem)
            print("sub_golden: %s: %d units (%d refused by libpng)" % (name, n, nbad))
        with open(os.path.join(a.out, a.list + ".txt"), "w") as f:
            f.write("".join(s + "\n" for s in stems))
        return 0
    if a.synth:
        for name, pes, ref, gaps in synth_cases():
            stem = os.path.join(a.out, name)
            n, cnt = write(stem, pes, ref, gaps)
            stems.append(stem)
            print("sub_golden: %s: %d units %s" % (name, n, {k: v for k, v in cnt.items() if v}))
    for d in a.disc:
        parts = d.rsplit(":", 3) if d.count(":") >= 3 else d.rsplit(":", 2)
        image, clip, sub = parts[0], int(parts[1]), int(parts[2], 0)
        packs = int(parts[3]) if len(parts) > 3 else None
        pes = disc_case(image, clip, sub, packs)
        name = "disc_%s_c%d_s%02x" % ("".join(ch for ch in os.path.basename(image).split(" (")[0]
                                               if ch.isalnum()), clip, sub)
        stem = os.path.join(a.out, name)
        n, cnt = write(stem, pes)
        stems.append(stem)
        print("sub_golden: %s: %d units %s" % (name, n, {k: v for k, v in cnt.items() if v}))
    with open(os.path.join(a.out, a.list + ".txt"), "w") as f:
        f.write("".join(s + "\n" for s in stems))
    return 0


if __name__ == "__main__":
    sys.exit(main())
