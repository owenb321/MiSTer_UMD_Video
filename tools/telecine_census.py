#!/usr/bin/env python3
"""telecine_census.py -- the library sweep of telecine_ref.py (Forgejo fj#80, docs/telecine.md S4):
per image, windows of the main title at fixed fractions, each classed by its truth (idet's
repeated fields) and run through the cadence lock; one line per window and a summary per family.

The headline is the true-video controls: a lock on one is a regression (the model must never
match fields across stores there); a missed lock on film is today's picture.

    UMD_ISO_DIR=... telecine_census.py [images...] [--frac F ...] [--cache DIR] [--json OUT]
                                       [--jobs N] [--param key=value ...]

Features are cached per window (--cache), so a re-run with other --param values (the FSM's
constants, the observable's variant) costs seconds, not the decode.
"""
import argparse
import glob
import json
import multiprocessing
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import telecine_ref as T  # noqa: E402

FRACS = [0.45, 0.70]        # 0.45: the issue's measurement; 0.70: a second scene


def images(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(os.path.join(p, f) for f in os.listdir(p)
                          if os.path.isfile(os.path.join(p, f)))
        else:
            out += sorted(glob.glob(p)) or [p]
    return out


def one(job):
    path, fr, packs, cache, params = job
    try:
        feats, facts = T.load_window(path, fr, packs, cache)
        rows = T.run_fsm(feats, params, h=facts["h"], w=facts["w"])
        sc = T.score(feats, facts, rows)
        return dict(image=os.path.basename(path), frac=fr, family=T.classify_title(facts, sc),
                    w=facts["w"], h=facts["h"], ps=facts["ps"], **sc)
    except Exception as e:      # one image's failure never stops the sweep
        return dict(image=os.path.basename(path), frac=fr, error="%s: %s" % (type(e).__name__, e),
                    trace=traceback.format_exc())


def parse_param(s):
    k, _, v = s.partition("=")
    if k not in T.PARAMS:
        raise SystemExit("telecine_census: no parameter %r (have %s)" % (k, ", ".join(T.PARAMS)))
    d = T.PARAMS[k]
    if isinstance(d, tuple):
        return k, tuple(int(x) for x in v.split(","))
    return k, type(d)(v)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--frac", type=float, action="append")
    ap.add_argument("--packs", type=int, default=6000)
    ap.add_argument("--cache")
    ap.add_argument("--json")
    ap.add_argument("--jobs", type=int, default=1)
    ap.add_argument("--param", action="append", default=[])
    a = ap.parse_args()
    paths = a.paths or [os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))]
    imgs = images(paths)
    if not imgs:
        print("SKIP: no images (set UMD_ISO_DIR)")
        return 0
    params = dict(parse_param(s) for s in a.param)
    jobs = [(p, fr, a.packs, a.cache, params) for p in imgs for fr in (a.frac or FRACS)]
    if a.jobs > 1:
        with multiprocessing.Pool(a.jobs) as pool:
            res = pool.map(one, jobs, chunksize=1)
    else:
        res = [one(j) for j in jobs]
    errs = 0
    fam = {}
    for r in res:
        if "error" in r:
            errs += 1
            print("[err] %s @%.2f %s" % (r["image"], r["frac"], r["error"]))
            continue
        if not r.get("refreshes"):
            print("[--]  %s @%.2f no stores" % (r["image"], r["frac"]))
            continue
        print("[ok]  %-58.58s @%.2f %-15s %s" % (r["image"], r["frac"], r["family"], T.fmt(r)))
        f = fam.setdefault(r["family"].split(" (")[0], dict(windows=0, refreshes=0, weave=0, model=0,
                                                            oracle=0, locked=0, breaks=0, rule_split=0, rule_clean=0, lcombed=0,
                                                            xagree=0, xconflict=0, stores=0))
        f["windows"] += 1
        f["refreshes"] += r["refreshes"]
        f["weave"] += r["weave_combed"]
        f["model"] += r["model_combed"]
        f["oracle"] += r["oracle_combed"]
        f["locked"] += r["locked"]
        f["breaks"] += r["breaks"]
        f["rule_split"] += r["rule_split"]
        f["rule_clean"] += r["rule_clean"]
        f["lcombed"] += r["locked_combed"]
        f["xagree"] += r["xcheck_agree"]
        f["xconflict"] += r["xcheck_conflict"]
        f["stores"] += r["stores"]
    print()
    print("%-16s %7s %9s %8s %8s %8s %8s %8s %6s %11s %7s %9s" % (
        "family", "windows", "refreshes", "weave%", "model%", "oracle%", "locked%", "Lcombed%", "breaks",
        "rule_clean", "xagree%", "xconflict"))
    for k in sorted(fam):
        f = fam[k]
        n = max(1, f["refreshes"])
        print("%-16s %7d %9d %8.2f %8.2f %8.2f %8.2f %8.2f %6d %11s %7.1f %9d" % (
            k, f["windows"], f["refreshes"], 100.0 * f["weave"] / n, 100.0 * f["model"] / n,
            100.0 * f["oracle"] / n, 100.0 * f["locked"] / n, 100.0 * f["lcombed"] / max(1, f["locked"]),
            f["breaks"], "%d/%d" % (f["rule_clean"], f["rule_split"]),
            100.0 * f["xagree"] / max(1, f["stores"]), f["xconflict"]))
    if a.json:
        json.dump(dict(params=dict(T.PARAMS, **params), windows=res), open(a.json, "w"), indent=1,
                  default=list)
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
