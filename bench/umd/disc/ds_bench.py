#!/usr/bin/env python3
"""ds_bench.py -- R5's disc screen: main/support/umd/umd_disc_screen.c (through ds_check) against
tools/disc_screen_layout.py (the golden) and tools/umd_sfo.py. bench/umd/run_disc_screen.sh runs it.

  ds_bench.py DS_CHECK WORKDIR [--iso-dir DIR] [--arms a,b,...]

Arms (each prints PASS / FAIL / SKIP; the last line "PASS ds_bench" only when none failed):
  sfo    every library image's PARAM.SFO: the C's TITLE == umd_sfo's; malformed files -> none
  title  the title shown (umd_ds_display_title): every library title with its image's name, and the
         rule's edges (fullwidth ASCII, the (TM) sign, other non-ASCII -> the file name, blanks, empty)
  hint   the Play line: Resume H:MM:SS at its boundaries, Play
  png    every library PIC1 / ICON0 through umd_ds_png_plain + libpng's simplified API (the UMD Main's
         decode) == the stored values (PIL, no colour management): the gamma chunks dropped
  lib    every library image's page at the raster's fit, in the plane's byte order, pixel for pixel
  fit    the 4:3 CRT's Letterbox and Crop on the sample discs, in RGBA order
  syn    synthetic art: odd sizes (1 x 1, 1 x N, N x 1, large), random alpha (premultiplied scaling),
         no PIC1 / no ICON0 / neither, titles at the wrap's edges (a word longer than a line, exactly a
         line, three lines -> "..."), empty
"""
import argparse
import glob
import os
import struct
import subprocess
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import disc_screen_layout as D  # noqa: E402
import umd_sfo  # noqa: E402

ARMS = ["sfo", "title", "hint", "png", "lib", "fit", "syn"]


def run(chk, *args):
    p = subprocess.run([chk] + [str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                       universal_newlines=True)
    if p.returncode:
        raise RuntimeError("ds_check %s: rc %d %s" % (args[0], p.returncode, p.stderr.strip()))
    return p.stdout.rstrip("\n")


def c_page(chk, wd, layout, fit, title, hint, pic1, icon0):
    args = ["page", os.path.join(wd, "c.raw"), layout, fit, title, hint]
    for k, im in (("p1", pic1), ("i0", icon0)):
        if im is None:
            args.append("-")
        else:
            f = os.path.join(wd, k + ".raw")
            np.ascontiguousarray(im).tofile(f)
            args += [f, im.shape[1], im.shape[0]]
    run(chk, *args)
    c = np.fromfile(os.path.join(wd, "c.raw"), dtype=np.uint8).reshape(480, 720, 4).astype(np.int64)
    return c[..., [2, 1, 0, 3]] if layout == 1 else c


def cmp_page(chk, wd, layout, fit, title, hint, pic1, icon0):
    c = c_page(chk, wd, layout, fit, title, hint, pic1, icon0)
    g = D.page(pic1, icon0, title, hint, fit)
    d = (c != g).any(axis=2)
    if d.any():
        y, x = np.argwhere(d)[0]
        return "%d pixels differ, first (%d, %d): C %s golden %s" % (int(d.sum()), x, y, list(c[y, x]), list(g[y, x]))
    return None


def isos(iso_dir):
    return sorted(p for p in glob.glob(os.path.join(iso_dir, "*")) if p.lower().endswith(".iso"))


def sfo_raw(path):
    from umd_iso import UmdIso
    iso = UmdIso(path)
    return iso.read("/UMD_VIDEO/PARAM.SFO") if iso.exists("/UMD_VIDEO/PARAM.SFO") else None


def arm_sfo(chk, wd, lib):
    if not lib:
        return "SKIP", "no images"
    n = 0
    for p in lib:
        raw = sfo_raw(p)
        if raw is None:
            continue
        f = os.path.join(wd, "p.sfo")
        open(f, "wb").write(raw)
        want = str(umd_sfo.parse(raw).get("TITLE", "-")) or "-"
        got = run(chk, "sfo", f)
        if got != want:
            return "FAIL", "%s: C %r, umd_sfo %r" % (os.path.basename(p), got, want)
        n += 1
        if n == 1:                                       # (malformed: truncated, the magic, no TITLE)
            for bad, why in ((raw[:19], "short"), (b"\0PSX" + raw[4:], "magic"),
                             (raw.replace(b"TITLE\0", b"TITLX\0"), "no TITLE")):
                open(f, "wb").write(bad)
                if run(chk, "sfo", f) != "-":
                    return "FAIL", "a malformed SFO (%s) read a title" % why
    return "PASS", "%d SFOs equal to umd_sfo's, 3 malformed refused" % n


TITLE_CASES = [
    ("Akira", "/x/Akira (PSP Video).iso"), ("", "/x/Some Disc.iso"), ("   ", "Name.ISO"),
    ("  Padded  ", "n.iso"), ("ＡＢＣ　x", "n.iso"), ("Ｈｅｌｌｏ／Ｗｏｒｌｄ", "n.iso"), ("Spiderman 3™", "n.iso"),
    ("café", "/a/b/Cafe Film.iso"), ("トム&ジェリー Vol.1", "/a/Tom.and.Jerry.iso"),
    ("x\U0001F600", "emoji.iso"), ("tab\tin", "Tab.iso"), ("", ".hidden"), ("", "noext"), ("", ""),
    ("~!@#$%^&*()_+{}|:\"<>?`-=[]\\;',./", "p.iso"),
]


def arm_title(chk, wd, lib):
    cases = list(TITLE_CASES)
    for p in lib:
        raw = sfo_raw(p)
        if raw is not None:
            cases.append((str(umd_sfo.parse(raw).get("TITLE", "")), p))
    for t, name in cases:
        got, want = run(chk, "title", t, name), D.display_title(t, name)
        if got != want:
            return "FAIL", "title %r of %r: C %r, golden %r" % (t, name, got, want)
    return "PASS", "%d titles (%d library) shown alike" % (len(cases), len(cases) - len(TITLE_CASES))


def arm_hint(chk, wd, lib):
    cases = [(0, 0), (1, 0), (1, 999), (1, 1000), (1, 59999), (1, 60000), (1, 3599999), (1, 3600000),
             (1, 7516600), (1, 4294967295)]
    for r, ms in cases:
        got, want = run(chk, "hint", r, ms), D.hint(bool(r), ms)
        if got != want:
            return "FAIL", "hint(%d, %d): C %r, golden %r" % (r, ms, got, want)
    return "PASS", "%d Play lines" % len(cases)


def arm_png(chk, wd, lib):
    if not lib:
        return "SKIP", "no images"
    import io as _io
    from PIL import Image
    from umd_iso import UmdIso
    n = dropped = 0
    for p in lib:
        iso = UmdIso(p)
        for name in ("PIC1.PNG", "ICON0.PNG"):
            q = "/UMD_VIDEO/" + name
            if not iso.exists(q):
                continue
            raw = iso.read(q)
            f, out = os.path.join(wd, "a.png"), os.path.join(wd, "a.raw")
            open(f, "wb").write(raw)
            got = run(chk, "png", f, out).split()
            want = np.asarray(Image.open(_io.BytesIO(raw)).convert("RGBA"), dtype=np.uint8)
            if got[0] == "-" or (int(got[0]), int(got[1])) != (want.shape[1], want.shape[0]):
                return "FAIL", "%s %s: decoded %s, PIL %dx%d" % (os.path.basename(p), name, got, want.shape[1], want.shape[0])
            c = np.fromfile(out, dtype=np.uint8).reshape(want.shape)
            if (c != want).any():
                return "FAIL", "%s %s: %d values differ from the stored ones" % (os.path.basename(p), name, int((c != want).sum()))
            n += 1
            dropped += int(got[2]) > 0
    return "PASS", "%d PNGs decoded to their stored values (%d had colour chunks dropped)" % (n, dropped)


def arm_lib(chk, wd, lib):
    if not lib:
        return "SKIP", "no images"
    for k, p in enumerate(lib):
        pic1, icon0, t = D.disc_art(p)
        why = cmp_page(chk, wd, 1, 0, D.display_title(t, p), D.hint(k % 2 == 0, 1000 * (61 + 997 * k)), pic1, icon0)
        if why:
            return "FAIL", "%s: %s" % (os.path.basename(p), why)
    return "PASS", "%d library pages pixel-exact (the plane's byte order)" % len(lib)


def arm_fit(chk, wd, lib):
    n = 0
    for prefix, _ in D.SAMPLES:
        p = D.find_iso(os.path.dirname(lib[0]), prefix) if lib else None
        if not p:
            continue
        pic1, icon0, t = D.disc_art(p)
        for fit in (1, 2):
            why = cmp_page(chk, wd, 0, fit, D.display_title(t, p), D.hint(True, 124000), pic1, icon0)
            if why:
                return "FAIL", "%s fit %d: %s" % (prefix, fit, why)
            n += 1
    return ("PASS", "%d fitted pages pixel-exact" % n) if n else ("SKIP", "no sample image")


def arm_syn(chk, wd, lib):
    rng = np.random.default_rng(5)

    def img(w, h, alpha=True):
        a = rng.integers(0, 256, size=(h, w, 4), dtype=np.uint8)
        if not alpha:
            a[..., 3] = 255
        return a
    long_word = "Supercalifragilisticexpialidocious" * 2
    cases = [
        ("1x1", img(1, 1), img(1, 1), "One", "> Play", 0),
        ("1xN", img(1, 300), img(5, 1), "Tall and thin", "> Resume 0:00:01", 0),
        ("Nx1", img(900, 1), img(1, 80), "Wide", "> Play", 1),
        ("alpha", img(480, 272), img(144, 80), "Random alpha both", "> Resume 1:02:03", 0),
        ("alpha-crop", img(480, 272), img(144, 80), "Random alpha, crop", "> Play", 2),
        ("big", img(3000, 17, False), img(1000, 700), "Larger than the raster", "> Play", 0),
        ("no-pic1", None, img(144, 80), "No background", "> Play", 0),
        ("no-icon0", img(480, 272, False), None, "No thumbnail: the title takes its place at the card's edge", "> Play", 0),
        ("neither", None, None, "", "", 0),
        ("long-word", img(64, 36), img(14, 8), long_word, "> Play", 0),
        ("exact-line", img(64, 36), img(14, 8), "x" * 42, "> Play", 0),
        ("three-lines", img(64, 36), img(14, 8), " ".join(["word%02d" % k for k in range(30)]), "> Play", 0),
        ("no-icon-3l", img(64, 36), None, " ".join(["lengthy%02d" % k for k in range(25)]), "> Play", 1),
        ("blank-title", img(8, 8), img(8, 8), "   ", "> Play", 0),
    ]
    for name, p1, i0, t, h, fit in cases:
        for layout in (0, 1):
            why = cmp_page(chk, wd, layout, fit, t, h, p1, i0)
            if why:
                return "FAIL", "%s (layout %d): %s" % (name, layout, why)
    return "PASS", "%d synthetic pages x 2 byte orders pixel-exact" % len(cases)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("chk")
    ap.add_argument("wd")
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--arms", default=",".join(ARMS))
    a = ap.parse_args()
    os.makedirs(a.wd, exist_ok=True)
    lib = isos(a.iso_dir)
    bad = 0
    for arm in a.arms.split(","):
        try:
            st, why = globals()["arm_" + arm](a.chk, a.wd, lib)
        except Exception as e:                           # (a crash of the subject is a failure of its arm)
            st, why = "FAIL", "%s: %s" % (type(e).__name__, e)
        print("%s %s: %s" % (st, arm, why))
        bad += st == "FAIL"
    print("PASS ds_bench" if not bad else "FAIL ds_bench: %d arm(s)" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
