#!/usr/bin/env python3
"""Choose run_cosim.sh --sample's discs from the last full sweep's census.

    cosim_sample.py CENSUS.tsv [--tail N] [--present LABELS.txt]

CENSUS.tsv (written by a full `run_cosim.sh --sweep`): one disc window a line,
"label <TAB> verdict <TAB> xrt <TAB> cycles_per_mb <TAB> feature feature ...".

The sample, in this order (each disc once):
  1. every disc whose census verdict is FAIL (a known failure stays in view);
  2. the TAIL: the N slowest PASS windows by real-time factor (default 3). Throughput
     depends on content, not on features: a change that costs cycles hits the slowest
     windows first, and only a full sweep finds which those are;
  3. a greedy set cover of every feature any PASS window holds: the disc covering the
     most features not yet covered, ties to the slower window, then by label.
SKIP (a damaged rip) and REFUSED (the model refuses: no RTL runs) are never chosen.
With --present, discs not in that list (no longer in the library) are dropped first.

Prints one line a chosen disc, "label <TAB> reason", then "# ..." summary lines.
The reason is FAIL, "tail 1.35x", or "cover N: feature feature ..." (what it added).
"""

import argparse
import sys


def load(path):
    rows = []
    for line in open(path):
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        label, verdict = parts[0], parts[1]
        xrt = float(parts[2]) if len(parts) > 2 and parts[2] else None
        cyc = int(parts[3]) if len(parts) > 3 and parts[3] else None
        feats = set(parts[4].split()) if len(parts) > 4 else set()
        rows.append({"label": label, "verdict": verdict, "xrt": xrt, "cyc": cyc, "feats": feats})
    return rows


def choose(rows, tail=3):
    """[(label, reason)] in the order above"""
    chosen, seen = [], set()

    def take(r, why):
        chosen.append((r["label"], why))
        seen.add(r["label"])

    for r in sorted(rows, key=lambda r: r["label"]):
        if r["verdict"] == "FAIL":
            take(r, "FAIL")
    passing = [r for r in rows if r["verdict"] == "PASS"]
    slow = sorted((r for r in passing if r["xrt"] is not None), key=lambda r: (r["xrt"], r["label"]))
    for r in slow:
        if len([c for c in chosen if c[1].startswith("tail")]) >= tail:
            break
        if r["label"] not in seen:
            take(r, "tail %.2fx" % r["xrt"])
    universe = set().union(*(r["feats"] for r in passing)) if passing else set()
    covered = set()
    for r in rows:
        if r["label"] in seen:
            covered |= r["feats"]
    # sorted by label: max() returns the first of equals, so the last tie goes to the label
    left = sorted((r for r in passing if r["label"] not in seen), key=lambda r: r["label"])
    while universe - covered:
        best = max(left, key=lambda r: (len(r["feats"] - covered),
                                        -(r["xrt"] if r["xrt"] is not None else 99.0)))
        new = best["feats"] - covered
        if not new:
            break                       # cannot happen: universe is the union of `left` and `covered`
        take(best, "cover %d: %s" % (len(new), " ".join(sorted(new))))
        covered |= new
        left.remove(best)
    return chosen, universe, covered


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("census")
    ap.add_argument("--tail", type=int, default=3)
    ap.add_argument("--present", help="a file of the labels in the library now, one a line")
    a = ap.parse_args(argv)
    rows = load(a.census)
    if a.present:
        now = set(l.strip() for l in open(a.present) if l.strip())
        rows = [r for r in rows if r["label"] in now]
    chosen, universe, covered = choose(rows, a.tail)
    for label, why in chosen:
        print("%s\t%s" % (label, why))
    n_pass = sum(1 for r in rows if r["verdict"] == "PASS")
    print("# %d of %d PASS windows cover all %d features%s" %
          (len(chosen), n_pass, len(universe), "" if covered >= universe else " -- NOT ALL COVERED"))
    return 0 if covered >= universe else 1


if __name__ == "__main__":
    sys.exit(main())
