#!/usr/bin/env python3
"""telecine_ref.py (Forgejo fj#80, docs/telecine.md): the observable against a direct sum, the
cross-store weave against fields picked by hand, the truth against the generator's own film
frames, and the cadence lock on synthetic sequences (no media). A library arm, with
$UMD_ISO_DIR: a true-video control never locks, a hard-telecined title does.

Each checkpoint's source is named beside it: the generator (synth) knows every field's film frame;
nothing here is copied from the model's own output."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
sys.path.insert(0, HERE)
import numpy as np  # noqa: E402
import telecine_ref as T  # noqa: E402
import umd_synth as S  # noqa: E402

Sc = S.Score("test_telecine_ref")


def direct_observe(W, cs, ls):
    """Sum |2b - a - d| and |a - d| by loops, the edges mirrored as disp_reader's ring does
    (bk_a of line 0 is line 1, bk_d of the last line is the line above it)."""
    H, Wd = W.shape
    C = R = 0
    for v in range(0, H, ls):
        a = W[1 if v == 0 else v - 1]
        d = W[H - 2 if v == H - 1 else v + 1]
        b = W[v]
        for x in range(0, Wd, cs):
            C += abs(2 * int(b[x]) - int(a[x]) - int(d[x]))
            R += abs(int(a[x]) - int(d[x]))
    return C, R


# --- the observable: integers, the reader's window, every variant
rng = np.random.default_rng(80)
W = rng.integers(0, 256, (12, 20), dtype=np.uint8)
obs = T.observe(W)
for v in T.VARIANTS:
    Sc.check("observe %s == the direct sum" % (v,), obs[v], direct_observe(W, *v))

# --- the cross-store weave: refresh 0's partner is the PREVIOUS store's SECOND field
# (source: the field order of a 3:2 sequence, docs/telecine.md S2; picked here by hand)
for fb in (0, 1):
    prev = rng.integers(0, 256, (8, 6), dtype=np.uint8)
    cur = rng.integers(0, 256, (8, 6), dtype=np.uint8)
    nxt = rng.integers(0, 256, (8, 6), dtype=np.uint8)
    f = T.store_features(prev, cur, nxt, fb, fb, fb)
    p1 = fb                                   # the first field's parity
    want0 = np.empty_like(cur)
    want0[p1::2] = cur[p1::2]                 # the shown (first) field
    want0[1 - p1::2] = prev[1 - p1::2]        # the previous store's second field
    want1 = np.empty_like(cur)
    want1[1 - p1::2] = cur[1 - p1::2]         # the shown (second) field
    want1[p1::2] = nxt[p1::2]                 # the next store's first field
    Sc.check("first_bot %d: refresh 0 weaves prev's second field" % fb, f["prev"], T.observe(want0))
    Sc.check("first_bot %d: refresh 1 weaves next's first field" % fb, f["next"], T.observe(want1))
    g = T.store_features(prev, cur, nxt, 1 - fb, fb, 1 - fb)
    Sc.check("first_bot %d: no partner across a field-order change" % fb,
             ("prev" in g, "next" in g), (False, False))

# --- the truth from repeats, against the generator's film frames
for fb in (0, 1):
    for ph in range(5):
        _st, fo, idet, split = T.synth("film", 40, first_bot=fb, phase=ph, h=8, w=8)
        got = T.truth(idet, fo)
        known = [k for k in range(len(got)) if got[k] is not None]
        Sc.check("truth fb %d phase %d: every known store agrees with the generator" % (fb, ph),
                 [k for k in known if got[k] != split[k]], [])
        Sc.check("truth fb %d phase %d: known past the first cycle" % (fb, ph),
                 len(known) >= 30, True)
        # the matching rule, MEASURED on the pictures: every split store combs in-store, and
        # both of the rule's cross-store weaves are the generator's clean film frames
        feats, facts, sp = T.synth_window("film", 40, first_bot=fb, phase=ph)
        Sc.check("rule fb %d phase %d: rule weaves clean, in-store combed, at every split" % (fb, ph),
                 [k for k in range(1, 39) if sp[k] and not (max(feats[k]["rprev"], feats[k]["rnext"]) < 1
                                                            and feats[k]["rin"] > 1)], [])
# the cross-check of idet (own_repeats) reads the same repeats off the pictures
for fb in (0, 1):
    feats, facts, _split = T.synth_window("film", 30, first_bot=fb, phase=1)
    Sc.check("own_repeats fb %d == the generator's repeats" % fb,
             T.own_repeats(feats, facts["fo"])[1:], facts["idet"][1:])
# an odd gap between two 3-runs (no 3:2 explains it) leaves its stores unknown: bottom first,
# 'B' at store 2 is the 3-run g[2..4], 'T' at 4 is g[7..9], 'T' at 7 is g[13..15]: 3 fields
# (10, 11, 12) between the last two
odd = T.truth("..B.T..T...", [1] * 11)
Sc.check("truth: an odd gap is unknown, not guessed", (odd[5], odd[6]), (None, None))
Sc.check("truth: an even gap is split as 2-runs", (odd[2], odd[3]), (True, True))


def arm(kind, **kw):
    feats, facts, split = T.synth_window(kind, 150, **kw)
    rows = T.run_fsm(feats, h=facts["h"], w=facts["w"])
    return feats, rows, split, T.score(feats, facts, rows, skip=0)


# --- clean 3:2, both field orders, every phase: locks, then never shows a combed weave, and
# every matched store is one the generator split
for fb in (0, 1):
    for ph in range(5):
        feats, rows, split, sc = arm("film", first_bot=fb, phase=ph)
        bad = [x["store"] for x in rows if x["shown"] in ("prev", "next") and not split[x["store"]]]
        Sc.check("film fb %d phase %d: locks within 12 cycles" % (fb, ph),
                 sc["first_lock"] is not None and sc["first_lock"] <= 60, True)
        Sc.check("film fb %d phase %d: matched only split stores" % (fb, ph), bad, [])
        Sc.check("film fb %d phase %d: no combed refresh shown" % (fb, ph), sc["model_combed"], 0)
        miss = [x["store"] for x in rows if x["locked"] and x["shown"] == "in" and split[x["store"]]]
        Sc.check("film fb %d phase %d: no split store shown woven under the lock" % (fb, ph), miss, [])

# --- true 59.94 video: never locks (a false lock is the regression)
_f, rows, _s, sc = arm("video")
Sc.check("video: never locked", sc["locked"], 0)

# --- a static picture: no evidence either way, so no lock
_f, rows, _s, sc = arm("static")
Sc.check("static: never locked", sc["locked"], 0)

# --- brief film (under ENGAGE's worth of cycles), then a still picture: the phase is kept but a
# cycle with no combed pair is no evidence, so the still never brings the lock
ff, ffacts, _ = T.synth_window("film", 12)
fs, _sfacts, _ = T.synth_window("static", 120)
rows = T.run_fsm(ff + fs, h=96, w=128)
Sc.check("film then still: phased by the film", rows[2 * 11]["slot"] is not None, True)
Sc.check("film then still: never locked", sum(1 for x in rows if x["locked"]), 0)

# --- the classifier is a RATIO (C against the same field's R), not a level: a busy clean
# picture (C below R) is clean, a flat combed one (C over 2.5 R) combed -- PARAMS' eighths
npix = 1000
Sc.check("classify: busy and clean", T.classify(8000, 16000, npix, T.PARAMS), "c")
Sc.check("classify: flat and combed", T.classify(3000, 1000, npix, T.PARAMS), "C")
Sc.check("classify: combed but no motion (under the floor)", T.classify(300, 100, npix, T.PARAMS), "?")

# --- drawings on twos: one visible split a cycle; never a wrong match, never a combed refresh
_f, rows, split, sc = arm("twos")
Sc.check("twos: no whole store matched", sc["matched_whole"], 0)
Sc.check("twos: no combed refresh", sc["model_combed"], 0)

# --- an edit mid-cadence: at most one combed refresh, one break, locked again by the end
feats, rows, split, sc = arm("film", edit=(70, 3))
after = [x for x in rows if x["store"] >= 70]
Sc.check("edit: at most one combed refresh", sc["model_combed"] <= 1, True)
Sc.check("edit: the lock breaks once", sc["breaks"], 1)
relock = next((x["store"] for x in after if x["locked"] and x["store"] > 72), None)
Sc.check("edit: locked again within 12 cycles", relock is not None and relock - 70 <= 60, True)

# --- the next store absent (the queue's head missing): that field is bobbed, never woven alone
feats, rows, split, sc = arm("film")
last = [x for x in rows if x["store"] == len(feats) - 1]
if last[0]["locked"] and last[0]["slot"] in (0, 1):
    Sc.check("no next store: refresh 1 bobbed", last[1]["shown"], "bob")
else:
    # shorten until the last store is a predicted split under the lock
    for n in range(140, 150):
        f2 = feats[:n]
        f2[-1] = {k: v for k, v in f2[-1].items() if k not in ("next", "rnext")}
        r2 = T.run_fsm(f2, h=96, w=128)
        if r2[-1]["locked"] and r2[-1]["slot"] in (0, 1):
            Sc.check("no next store: refresh 1 bobbed", r2[-1]["shown"], "bob")
            break
    else:
        Sc.check("no next store: a case found", False, True)

# --- the library: a true-video control never locks; a hard-telecined title locks
iso_dir = os.environ.get("UMD_ISO_DIR")
OFFICE = "The Office - The Complete First Series - Disc 01 (2001).ISO"
TDK = "The Dark Knight (Europe Import) (PSP Video).iso"
if not iso_dir or not all(os.path.exists(os.path.join(iso_dir, n)) for n in (OFFICE, TDK)):
    print("  SKIP: library arm (UMD_ISO_DIR with The Office Disc 01 and The Dark Knight)")
else:
    for name, want_lock in ((OFFICE, False), (TDK, True)):
        feats, facts = T.load_window(os.path.join(iso_dir, name), 0.45, 6000)
        rows = T.run_fsm(feats, h=facts["h"], w=facts["w"])
        sc = T.score(feats, facts, rows)
        Sc.check("library %s: locked" % name[:24], sc["locked"] > 0, want_lock)
        if want_lock:
            Sc.check("library %s: combed refreshes below Weave's" % name[:24],
                     sc["model_combed"] < sc["weave_combed"] // 4, True)

Sc.finish()
