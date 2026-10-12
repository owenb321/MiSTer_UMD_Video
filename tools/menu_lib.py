#!/usr/bin/env python3
"""menu_lib.py -- P9 M4's library sweep: every disc image's menus run through the UMD Main's whole path
on the PC (bench/umd/menu/menu_host_check.c, the core model) with the M4 probe (--walk), classified.

    menu_lib.py [--iso-dir DIR] [--out DIR] [--jobs N] [--seeds N] [--check EXPECT] [--write EXPECT] [images...]

THE PROBE (docs/p9.md M4; menu_host_check.c --walk): a user who presses Cross on whatever a page
offers once the page has sat unchanged for 6 s (Down / Right when a press changed nothing), until a
CONTENT play (the script's menuMode 0) of a playlist at least half the longest's duration starts --
the feature, as PLAYLIST.UMD defines it (the core's own choice on a stock Main), never the script's;
then Square 5 s into it (the PSP's way back to a disc's menu, onMenu). The verdict is the RULE's, not a
capture's: the captures stay the only oracle for pictures and timing (menu_gate.py).

Each disc gets a CLASS:
    menu      a page led to the feature (>= 1 press), and Square in it brought a page back
    autoplay  the startup chain played the feature with no press (Die Hard, Ghost in the Shell 2.0,
              ...), and Square brought a page
    no-square the feature reached, but Square brought no page
    stuck     no feature within the presses / the run (the walk's log says where it stood)
    stopped   the engine stopped (a bound, an unknown native, a VM error)
    refused   the host refused the disc (no startup RCO, a load error)
and its GAPS, harvested from the trace: handlers abandoned (SCRIPT ERROR), images not decoded,
events / animation references ignored, plays refused, video windows below full screen (P9-5), the
render's cost on this PC (the rig's A9 is ~19-30x slower: docs/p9.md M4).

--out DIR keeps each disc's trace and the page the feature was played from (<disc>.png: the plane
over a checkerboard, the video not drawn) for the contact sheet. --write EXPECT records the classes;
--check EXPECT fails ("FAIL: menu_lib") when any disc's class differs from the one recorded, a new
disc is not recorded, or a recorded one is missing (SKIP with no image at all). Prints "PASS: menu_lib".
"""
import argparse
import glob
import json
import multiprocessing
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
RUN = os.path.join(ROOT, ".sim/menu/menu_host_check")

LINE = re.compile(r"^\s*(\d+) (.*)$")


def images(iso_dir):
    out = []
    for p in sorted(glob.glob(os.path.join(iso_dir, "*")) + glob.glob(os.path.join(iso_dir, "*", "*"))):
        if os.path.isfile(p) and p.lower().endswith(".iso"):
            out.append(p)
    return out


def key_of(path):
    return os.path.splitext(os.path.basename(path))[0]


def run_one(job):
    iso, out, seed, ms = job
    k = key_of(iso)
    shot = os.path.join(out, k + ".png") if out else None
    cmd = [RUN, iso, "--ms", str(ms), "--walk", "--seed", str(seed)]
    if shot and seed == 1:
        cmd += ["--walk-shot", shot]
    t0 = time.time()
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True, errors="replace")
    wall = time.time() - t0
    if out and seed == 1:
        open(os.path.join(out, k + ".trace"), "w").write(p.stdout)
    r = parse(p.stdout)
    r.update({"key": k, "seed": seed, "wall_s": round(wall, 1), "rc": p.returncode})
    return r


def parse(text):
    lines = []
    for l in text.splitlines():
        m = LINE.match(l)
        if m:
            lines.append((int(m.group(1)), m.group(2)))
    r = {"start": None, "first_page": None, "presses": [], "feature": None, "feature_presses": None,
         "feature_pl": None, "square": None, "end": None, "stopped": None, "refused": None,
         "script_errors": [], "gaps": {}, "render": None, "frames": 0, "marks": 0, "back": None}

    def gap(kind, what):
        r["gaps"].setdefault(kind, [])
        if what not in r["gaps"][kind] and len(r["gaps"][kind]) < 8:
            r["gaps"][kind].append(what)

    for t, s in lines:
        if s.startswith("HOST start ") and r["start"] is None:
            r["start"] = s.split()[2].rstrip(":")
            if "REFUSED" in s:
                r["refused"] = s
        elif s.startswith("HOST the engine refused") or s.startswith("HOST no RESOURCE"):
            r["refused"] = s
        elif s.startswith("HOST engine stopped:"):
            r["stopped"] = s[len("HOST engine stopped: "):]
        elif re.match(r"CORE levels grab 0x[0-9a-f]+ ui 1 menu 1$", s) and r["first_page"] is None:
            r["first_page"] = t
        elif s.startswith("WALK FEATURE "):
            m = re.match(r"WALK FEATURE playlist (\d+) .* after (\d+) presses", s)
            r["feature"], r["feature_pl"], r["feature_presses"] = t, int(m.group(1)), int(m.group(2))
        elif s.startswith("WALK MENU AGAIN"):
            r["square"] = True
        elif s.startswith("WALK NO MENU"):
            r["square"] = False
        elif s.startswith("WALK BACK "):
            r["back"] = s[10:]
        elif s.startswith("WALK ") and not s.startswith("WALK SQUARE"):
            r["presses"].append("%d %s" % (t, s[5:]))
        elif s.startswith("SCRIPT ERROR"):
            r["script_errors"].append(s[13:120])
        elif s.startswith("IMAGE ") and ("not" in s or "no data" in s):
            gap("image", s[6:100])
        elif s.startswith("SOUND ") and "not" in s:
            gap("sound", s[6:100])
        elif s.startswith("EVENT ") and ("ignored" in s or "no such function" in s or "nothing" in s or "bad event" in s):
            gap("event", s[6:100])
        elif s.startswith("ANIM ") and "ignored" in s:
            gap("anim", s[5:100])
        elif s.startswith("HOST play refused") or "NO SUCH PLAYLIST" in s:
            gap("play", s[:100])
        elif s.startswith("HOST mark "):
            r["marks"] += 1
        elif s.startswith("movieplayer.setSize("):
            m = re.match(r"movieplayer\.setSize\(([-\d.]+), ([-\d.]+)\)", s)
            if m and (float(m.group(1)) < 854 or float(m.group(2)) < 480):
                gap("window", "%sx%s" % (m.group(1), m.group(2)))
        elif s.startswith("CORE render "):
            m = re.match(r"CORE render (\d+) frames, (\d+) ms in all, ([\d.]+) ms a frame, at most ([\d.]+) ms", s)
            if m:
                r["frames"], r["render"] = int(m.group(1)), (float(m.group(3)), float(m.group(4)))
        elif s.startswith("CORE STALE") or s.startswith("CORE PLANE WRITE") or s.startswith("CORE event lost"):
            gap("core", s[:100])
        elif s.startswith("END "):
            r["end"] = s[4:]
    if r["refused"]:
        r["class"] = "refused"
    elif r["stopped"]:
        r["class"] = "stopped"
    elif r["feature"] is None:
        r["class"] = "stuck"
    elif not r["square"]:
        r["class"] = "no-square"
    else:
        r["class"] = "menu" if r["feature_presses"] else "autoplay"
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--iso-dir", default=os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")))
    ap.add_argument("--out", default=os.path.join(ROOT, ".sim/menu/lib"))
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--seeds", type=int, default=1)
    ap.add_argument("--ms", type=int, default=900000)
    ap.add_argument("--check")
    ap.add_argument("--write")
    ap.add_argument("--json")
    ap.add_argument("images", nargs="*")
    a = ap.parse_args()
    isos = a.images or images(a.iso_dir)
    if not isos:
        print("SKIP: menu_lib: no image under the ISO dir")
        return 0
    if not os.access(RUN, os.X_OK):
        print("FAIL: menu_lib: %s not built (make -C bench/umd/menu)" % RUN)
        return 1
    os.makedirs(a.out, exist_ok=True)
    jobs = [(iso, a.out, s, a.ms) for iso in isos for s in range(1, a.seeds + 1)]
    with multiprocessing.Pool(a.jobs) as pool:
        res = pool.map(run_one, jobs)
    by = {}
    for r in res:
        by.setdefault(r["key"], []).append(r)
    rows = []
    for k in sorted(by, key=str.lower):
        rs = sorted(by[k], key=lambda r: r["seed"])
        r = rs[0]
        cls = r["class"] if all(x["class"] == r["class"] for x in rs) else "/".join(sorted({x["class"] for x in rs}))
        rows.append((k, cls, r))
    for k, cls, r in rows:
        rend = "%.1f/%.0f" % r["render"] if r["render"] else "-"
        feat = ("%5.1f s %2d pr pl %d" % (r["feature"] / 1e3, r["feature_presses"], r["feature_pl"])) if r["feature"] is not None else "-"
        gaps = " ".join("%s:%d" % (g, len(v)) for g, v in sorted(r["gaps"].items()))
        print("%-48.48s %-9s page %-7s feat %-20s back %-10.10s serr %d marks %-3d render %-10s wall %5.1f %s%s" % (
            k, cls, "%.1f" % (r["first_page"] / 1e3) if r["first_page"] is not None else "-", feat, r["back"] or "-",
            len(r["script_errors"]), r["marks"], rend, r["wall_s"], gaps,
            (" STOPPED: " + r["stopped"]) if r["stopped"] else ""))
    counts = {}
    for _, cls, _ in rows:
        counts[cls] = counts.get(cls, 0) + 1
    print("menu_lib: %d images: %s" % (len(rows), ", ".join("%s %d" % kv for kv in sorted(counts.items()))))
    if a.json:
        json.dump({k: dict(r, cls=cls) for k, cls, r in rows}, open(a.json, "w"), indent=1)
    if a.write:
        with open(a.write, "w") as f:
            f.write("# tools/menu_lib.py --write: each disc image's class under the M4 probe (docs/p9.md M4)\n")
            for k, cls, _ in rows:
                f.write("%s\t%s\n" % (cls, k))
        print("menu_lib: classes written to %s" % a.write)
    if a.check:
        exp = {}
        for l in open(a.check):
            if l.strip() and not l.startswith("#"):
                cls, k = l.rstrip("\n").split("\t", 1)
                exp[k] = cls
        bad = []
        for k, cls, _ in rows:
            if k not in exp:
                bad.append("%s: %s, not recorded" % (k, cls))
            elif exp[k] != cls:
                bad.append("%s: %s, recorded %s" % (k, cls, exp[k]))
        if not a.images:
            bad += ["%s: recorded %s, no image" % (k, c) for k, c in exp.items() if k not in by]
        for b in bad:
            print("  FAIL %s" % b)
        if bad:
            print("FAIL: menu_lib: %d of %d" % (len(bad), len(rows)))
            return 1
    print("PASS: menu_lib")
    return 0


if __name__ == "__main__":
    sys.exit(main())
