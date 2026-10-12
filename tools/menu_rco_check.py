#!/usr/bin/env python3
"""menu_rco_check.py -- P9 M1a's gate (docs/p9.md S3.4): the menu engine's RCO loader
(main/support/umd/menu/rco.c, through .sim/menu/menu_dump) against tools/rco_census.py on every
RCO of every disc image: the entry count, the tree's depth and widest fan-out, the object /
animation / image / sound histograms and the VSMX script's header counts must be EQUAL.

rco_census.py was written from RCOMage's and JPCSP's descriptions, the C loader from RCOMage's
rcofile.h; both read the same documented layout, and agreement on 246 files across 84 discs is
the check that the C reads it the same way (the census found no unknown opcode or type, so a
disagreement is the C's bug or a layout neither knew).

    menu_rco_check.py [--iso-dir DIR] [--dump .sim/menu/menu_dump] [--jobs N]
The RCOs are extracted once into bench/umd/fixtures/gen/rco/ (gitignored: commercial media).
"""
import argparse
import glob
import hashlib
import json
import multiprocessing
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import rco_census as C  # noqa: E402

CACHE = os.path.join(ROOT, "bench", "umd", "fixtures", "gen", "rco")


def extract(img):
    import umd_iso
    tag = hashlib.sha1(os.path.basename(img).encode()).hexdigest()[:10]
    d = os.path.join(CACHE, tag)
    done = os.path.join(d, ".done")
    if not os.path.exists(done):
        os.makedirs(d, exist_ok=True)
        try:
            with umd_iso.UmdIso(img) as iso:
                for n in iso.listdir("/UMD_VIDEO/RESOURCE"):
                    if n.upper().endswith(".RCO"):
                        open(os.path.join(d, n), "wb").write(iso.read("/UMD_VIDEO/RESOURCE/" + n, record=False))
        except Exception as e:  # an unreadable image: said, not hidden
            return img, [], "extract: %r" % e
        open(done, "w").write(os.path.basename(img))
    return img, sorted(glob.glob(os.path.join(d, "*.RCO")) + glob.glob(os.path.join(d, "*.rco"))), None


def census_view(rec):
    t = rec["tree"]
    out = {"version": int(rec["version"], 16), "compression": rec["compression"], "entries": t["entries"],
           "max_depth": t["max_depth"], "max_children": t["max_children"]}
    out["obj"] = {str(C.OBJ_TYPES.index(k)): v for k, v in t["obj"].items()}
    out["anim"] = {str(C.ANIM_TYPES.index(k)): v for k, v in t["anim"].items()}
    out["img_fmt"] = {k.strip("()").replace(" ", ""): v for k, v in t["img_fmt"].items()}
    out["sound_fmt"] = {k.strip("()").replace(" ", ""): v for k, v in t["sound_fmt"].items()}
    if rec.get("vsmx"):
        v = rec["vsmx"][0]
        out["vsmx"] = {k: v[k] for k in ("instructions", "text_entries", "prop_entries", "name_entries")}
    return out


def check(args):
    path, dump = args
    b = open(path, "rb").read()
    rec = C.parse_rco(b)
    if "error" in rec:
        return path, "census refused it: %s" % rec["error"], 0
    want = census_view(rec)
    r = subprocess.run([dump, path], capture_output=True, text=True)
    try:
        got = json.loads(r.stdout)
    except ValueError:
        return path, "menu_dump: %r" % (r.stdout + r.stderr)[:200], 0
    if "error" in got:
        return path, "the loader refused it: %s" % got["error"], 0
    diffs = ["%s: %r vs census %r" % (k, got.get(k), want[k]) for k in want if got.get(k) != want[k]]
    # the extras against the file's own sizes (menu_dump.c): every one consistent
    for k in ("extra_bad", "attr_bad"):
        if got.get(k, 1):
            diffs.append("%s %s (first: %s)" % (k, got.get(k), got.get(k.replace("bad", "first"))))
    return path, ("; ".join(diffs) if diffs else None), got.get("attr_seen", 0)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--dump", default=os.path.join(ROOT, ".sim", "menu", "menu_dump"))
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args(argv)
    imgs = sorted(f for f in glob.glob(os.path.join(a.iso_dir, "**", "*"), recursive=True)
                  if f.lower().endswith(".iso"))
    if not imgs:
        print("menu_rco_check: SKIP -- no disc image in %s" % a.iso_dir)
        return 0
    with multiprocessing.Pool(a.jobs) as p:
        ex = p.map(extract, imgs)
        jobs = [(f, a.dump) for _, fs, _ in ex for f in fs]
        res = p.map(check, jobs)
    bad = [(f, d) for f, d, _ in res if d]
    seen = sum(s for _, _, s in res)
    for img, _, err in ex:
        if err:
            print("  NOTE %s: %s" % (os.path.basename(img), err))
    for f, d in bad[:20]:
        print("  FAIL %s: %s" % (os.path.relpath(f, CACHE), d))
    discs = sum(1 for _, fs, _ in ex if fs)
    print("menu_rco_check: %d RCOs from %d discs, %d agree with rco_census.py, %d differ; %d object / animation "
          "sizes checked against rco_attrs.h" % (len(res), discs, len(res) - len(bad), len(bad), seen))
    if bad or not res or not seen:
        return 1
    print("PASS: menu_rco_check")
    return 0


if __name__ == "__main__":
    sys.exit(main())
