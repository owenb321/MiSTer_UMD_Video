#!/usr/bin/env python3
"""menu_render_ab.py -- the menu renderer against a reference build, every library image (fj#74).

Runs two builds of bench/umd/menu/menu_host_check (A: the reference, e.g. main's menu.c; B: the change)
with the same arguments on every image -- the M4 library probe (--walk), so each disc's own menus are
opened, navigated and played through -- and compares, per image:
  * "CORE frames hash": FNV-1a over every frame the runner flipped. Equal = the same pixels, frame by
    frame, over the whole run (a renderer change meant to be exact must leave every hash unchanged).
  * "CORE inc ... N differ": the incremental frame against the full render, every frame (B's own check).
  * "END ok" in both.
A disc whose runs diverge in timing (frame counts differ) is reported as such: a hash comparison needs
the same frames. A run that drew NO frame (a walk still in the disc's trailers) compared nothing: it FAILs
-- run it longer (--ms; the probe's own default is 900000).

  tools/menu_render_ab.py (--ref-commit SHA | --ref BIN) [--new .sim/menu/menu_host_check]
                          [--iso-dir DIR] [--ms 240000] [--jobs 8] [images...]
--ref-commit builds the reference itself: SHA's main/support/umd (git archive) with TODAY's bench
(bench/umd/menu: the frame hash), into .sim/menu-ab-ref/SHA. The bench must still compile against that
tree's API -- fine across a renderer change (fj#74's reference: the commit before it, 1175ac3).
Exit 0 when every image matches.
"""
import argparse, concurrent.futures as cf, os, re, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
HASH = re.compile(r"CORE frames hash ([0-9a-f]+)")
REND = re.compile(r"CORE render (\d+) frames, (\d+) ms in all")
INC = re.compile(r"CORE inc (\d+) frames checked, (\d+) differ")


def build_ref(sha):
    d = os.path.join(ROOT, ".sim", "menu-ab-ref", sha)
    out = os.path.join(d, "out", "menu_host_check")
    if os.path.exists(out):
        return out
    tree = os.path.join(d, "tree")
    os.makedirs(tree, exist_ok=True)
    arc = subprocess.run(["git", "-C", ROOT, "archive", sha, "main/support/umd"], stdout=subprocess.PIPE, check=True).stdout
    subprocess.run(["tar", "-x", "-C", tree], input=arc, check=True)
    sup = os.path.join(tree, "main", "support", "umd")
    subprocess.run(["make", "-s", "-C", os.path.join(ROOT, "bench", "umd", "menu"), "SRC=" + os.path.join(sup, "menu"),
                    "HSRC=" + sup, "OUT=" + os.path.join(d, "out"), out], check=True)
    return out


def run(binary, iso, ms):
    p = subprocess.run([binary, iso, "--ms", str(ms), "--walk", "--seed", "1"], stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, universal_newlines=True, errors="replace")
    o = p.stdout
    h, r, i = HASH.search(o), REND.search(o), INC.search(o)
    return {"hash": h.group(1) if h else None, "frames": int(r.group(1)) if r else -1,
            "ms": int(r.group(2)) if r else -1, "differ": int(i.group(2)) if i else -1,
            "end": "END ok" in o}


def one(job):
    ref, new, iso, ms = job
    a, b = run(ref, iso, ms), run(new, iso, ms)
    # (a run that drew no frame compared nothing: a FAIL, never a vacuous ok -- run it longer)
    ok = a["hash"] and a["hash"] == b["hash"] and a["frames"] == b["frames"] and b["frames"] > 0 and b["differ"] == 0 and a["end"] and b["end"]
    return iso, a, b, ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref")
    ap.add_argument("--ref-commit")
    ap.add_argument("--new", default=os.path.join(ROOT, ".sim/menu/menu_host_check"))
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--ms", type=int, default=240000)
    ap.add_argument("--jobs", type=int, default=8)
    ap.add_argument("images", nargs="*")
    a = ap.parse_args()
    if bool(a.ref) == bool(a.ref_commit):
        ap.error("give one of --ref / --ref-commit")
    if a.ref_commit:
        a.ref = build_ref(a.ref_commit)
    isos = a.images or sorted(os.path.join(dp, f) for dp, _, fs in os.walk(a.iso_dir) for f in fs if f.lower().endswith(".iso"))
    if not isos:
        print("SKIP: no image"); return 0
    bad = 0
    ta = tb = 0
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        for iso, ra, rb, ok in ex.map(one, [(a.ref, a.new, i, a.ms) for i in isos]):
            ta += max(ra["ms"], 0); tb += max(rb["ms"], 0)
            name = os.path.splitext(os.path.basename(iso))[0]
            if ok:
                print("  ok   %-60s %5d frames %s  render %d -> %d ms" % (name[:60], rb["frames"], rb["hash"], ra["ms"], rb["ms"]))
            else:
                bad += 1
                print("  FAIL %-60s ref %s new %s" % (name[:60], ra, rb))
    print("%s: %d of %d images the same pixels; render %d -> %d ms in all (this PC)" %
          ("PASS" if not bad else "FAIL", len(isos) - bad, len(isos), ta, tb))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
