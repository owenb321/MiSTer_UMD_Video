#!/usr/bin/env python3
"""Fixtures for bench/umd/intra_pred_tb.sv: neighbour samples in, prediction samples out,
from tools/h264_recon_ref.py's intra4x4_pred / intra16x16_pred / intra_chroma_pred (the
model proven pixel-exact vs ffmpeg; docs/h264_recon.md S2.4). The gate of
bench/umd/run_intra_pred.sh.

Cases, in (kind, mode) order so a mutation's first failure names its class:
  * random neighbours (--seeds per class) for every kind, every mode and every LEGAL
    availability combination: V needs the row above, H the column left, DC any of the
    four; Intra_4x4 modes 3 and 7 need p[0..7,-1] (both "present" and "p[4..7,-1]
    substituted from p[3,-1]" variants, 8.3.1.2), modes 4/5/6 need the row, the column
    and the corner, mode 8 the column; the Plane modes need everything (8.3.3.4, 8.3.4.4);
  * extreme fills for every class (all 0, all 255, alternating, ramps, split runs -- the
    Plane's clipping at both ends, the DC's largest sums);
  * with --clip, the recorded calls of a real stream decoded through h264_recon_ref
    (the three functions monkeypatched to log their inputs and output), capped per class
    (--clip-cap): real neighbour / mode / availability combinations, the fixture-range
    check of CLAUDE.md. The coverage table is printed.
Unavailable runs (and the unused store entries) are filled with random bytes the golden
never sees: the unit must not read them either.

Files (bench/umd/README.md conventions, one word per line, $readmemh):
  <stem>.case.hex  32-bit per case: {kind[7:0], mode[7:0], avail_top[7:0], avail_left[7:0]}
  <stem>.nb.hex    33 bytes per case, the store in index order:
                   0..15 p[x,-1], 16..31 p[-1,y], 32 p[-1,-1]
  <stem>.exp.hex   the samples in raster order, one byte per line, 16 / 256 / 64 per case
  <stem>.meta.hex  [0] n_cases [1] n_exp [2] n_nb [3] seed [4] n_clip_cases

    intra_golden.py --out bench/umd/fixtures/gen/intra --seeds 24 --clip .sim/ip_x264.264
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_recon_ref as R  # noqa: E402

N_OF = {0: 16, 1: 256, 2: 64}          # samples per block
TOP_OF = {0: 8, 1: 16, 2: 8}           # p[x,-1] entries a kind reads
LEFT_OF = {0: 4, 1: 16, 2: 8}          # p[-1,y] entries a kind reads
KIND_NAME = {0: "4x4", 1: "16x16", 2: "chroma"}

ANY = ((0, 0), (0, 1), (1, 0), (1, 1))
TOP = ((1, 0), (1, 1))
LEFT = ((0, 1), (1, 1))
BOTH = ((1, 1),)
# (kind, mode) -> the legal (avail_top, avail_left) pairs
LEGAL = {
    (0, 0): TOP, (0, 1): LEFT, (0, 2): ANY, (0, 3): TOP, (0, 4): BOTH, (0, 5): BOTH,
    (0, 6): BOTH, (0, 7): TOP, (0, 8): LEFT,
    (1, 0): TOP, (1, 1): LEFT, (1, 2): ANY, (1, 3): BOTH,
    (2, 0): ANY, (2, 1): LEFT, (2, 2): TOP, (2, 3): BOTH,
}
CLASSES = sorted(LEGAL)


def golden(kind, mode, top, left, tl):
    if kind == 0:
        return [int(v) for v in R.intra4x4_pred((top, left, tl), mode, 0)]
    if kind == 1:
        return [int(v) for v in R.intra16x16_pred(mode, top, left, tl).reshape(-1)]
    return [int(v) for v in R.intra_chroma_pred(mode, top, left, tl).reshape(-1)]


def make_case(kind, mode, at, al, nb):
    """A case from a full 33-byte store: the golden sees only the available runs."""
    top = [int(v) for v in nb[0:TOP_OF[kind]]] if at else None
    left = [int(v) for v in nb[16:16 + LEFT_OF[kind]]] if al else None
    tl = int(nb[32])
    return (kind, mode, at, al, list(nb), golden(kind, mode, top, left, tl))


def random_store(rnd, kind, mode, substituted=False):
    nb = [rnd.randrange(256) for _ in range(33)]
    if substituted and kind == 0:
        nb[4:8] = [nb[3]] * 4
    return nb


FILLS = {
    "zero":   lambda i: 0,
    "full":   lambda i: 255,
    "alt":    lambda i: 255 * (i & 1),
    "up":     lambda i: (i * 8) & 255,
    "down":   lambda i: 255 - ((i * 8) & 255),
    "split":  lambda i: 0 if i < 16 else 255,      # row above 0, column left 255
    "split2": lambda i: 255 if i < 16 else 0,
    "steep":  lambda i: (0 if (i & 15) < 8 else 255) if i < 16 else (255 if (i & 15) < 8 else 0),
}


def random_cases(rnd, seeds):
    cases = []
    for kind, mode in CLASSES:
        for at, al in LEGAL[(kind, mode)]:
            variants = (False, True) if (kind == 0 and mode in (3, 7)) else (False,)
            for sub in variants:
                for _ in range(seeds):
                    cases.append(make_case(kind, mode, at, al, random_store(rnd, kind, mode, sub)))
            for name in FILLS:
                nb = [FILLS[name](i) for i in range(33)]
                cases.append(make_case(kind, mode, at, al, nb))
    return cases


def clip_cases(rnd, path, cap):
    """Decode a stream through the model with the three predictors recording their calls."""
    recorded = []
    orig4, orig16, origc = R.intra4x4_pred, R.intra16x16_pred, R.intra_chroma_pred

    def w4(p, mode, blk_idx):
        out = orig4(p, mode, blk_idx)
        top, left, tl = p
        recorded.append((0, mode, top, left, tl, [int(v) for v in out]))
        return out

    def w16(mode, top, left, tl):
        out = orig16(mode, top, left, tl)
        recorded.append((1, mode, top, left, tl, [int(v) for v in out.reshape(-1)]))
        return out

    def wc(mode, top, left, tl):
        out = origc(mode, top, left, tl)
        recorded.append((2, mode, top, left, tl, [int(v) for v in out.reshape(-1)]))
        return out

    R.intra4x4_pred, R.intra16x16_pred, R.intra_chroma_pred = w4, w16, wc
    try:
        R.decode_file(path)
    finally:
        R.intra4x4_pred, R.intra16x16_pred, R.intra_chroma_pred = orig4, orig16, origc

    by_class = {}
    for kind, mode, top, left, tl, out in recorded:
        at, al = int(top is not None), int(left is not None)
        if (at, al) not in LEGAL[(kind, mode)]:
            raise SystemExit("clip: %s mode %d with availability (%d, %d) is not legal" % (KIND_NAME[kind], mode, at, al))
        nb = [rnd.randrange(256) for _ in range(33)]
        if top is not None:
            nb[0:len(top)] = [int(v) for v in top]
        if left is not None:
            nb[16:16 + len(left)] = [int(v) for v in left]
        if tl is not None:
            nb[32] = int(tl)
        else:
            tl = nb[32]
        # the record's output is the golden; recomputing from the store must agree (a
        # check that the store carries everything the model looked at)
        chk = golden(kind, mode, [int(v) for v in top] if top is not None else None,
                     [int(v) for v in left] if left is not None else None, int(tl))
        if chk != out:
            raise SystemExit("clip: a recorded %s mode %d call does not reproduce from its store" % (KIND_NAME[kind], mode))
        by_class.setdefault((kind, mode, at, al), []).append((kind, mode, at, al, nb, out))
    cases = []
    print("clip %s: %d intra predictions recorded" % (os.path.basename(path), len(recorded)))
    print("  %-7s %-4s %-5s %-5s %8s %6s" % ("kind", "mode", "top", "left", "recorded", "kept"))
    for key in sorted(by_class):
        lst = by_class[key]
        keep = lst if len(lst) <= cap else rnd.sample(lst, cap)
        keep.sort(key=lambda c: c[:4])
        cases.extend(keep)
        print("  %-7s %-4d %-5d %-5d %8d %6d" % (KIND_NAME[key[0]], key[1], key[2], key[3], len(lst), len(keep)))
    return cases


def write(stem, cases, seed, n_clip):
    n_exp = 0
    with open(stem + ".case.hex", "w") as fc, open(stem + ".nb.hex", "w") as fn, open(stem + ".exp.hex", "w") as fe:
        for kind, mode, at, al, nb, out in cases:
            assert len(nb) == 33 and len(out) == N_OF[kind]
            fc.write("%02x%02x%02x%02x\n" % (kind, mode, at, al))
            fn.write("".join("%02x\n" % v for v in nb))
            fe.write("".join("%02x\n" % v for v in out))
            n_exp += len(out)
    with open(stem + ".meta.hex", "w") as f:
        for v in (len(cases), n_exp, 33 * len(cases), seed, n_clip):
            f.write("%08x\n" % v)
    return n_exp


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="fixture stem")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--seeds", type=int, default=24, help="random stores per (kind, mode, availability) class")
    ap.add_argument("--clip", help="an Annex-B stream to decode through the model, recording every call")
    ap.add_argument("--clip-cap", type=int, default=150, help="recorded cases kept per class")
    a = ap.parse_args(argv)
    rnd = random.Random(a.seed)
    cases = random_cases(rnd, a.seeds)
    n_clip = 0
    if a.clip:
        cc = clip_cases(rnd, a.clip, a.clip_cap)
        n_clip = len(cc)
        cases.extend(cc)
    cases.sort(key=lambda c: (c[0], c[1]))          # stable: (kind, mode) order, random before clip
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    n_exp = write(a.out, cases, a.seed, n_clip)
    per = {}
    for c in cases:
        per[(c[0], c[1])] = per.get((c[0], c[1]), 0) + 1
    print("%s: %d cases (%d from the clip), %d samples; per class: %s" % (
        a.out, len(cases), n_clip, n_exp,
        " ".join("%s/m%d=%d" % (KIND_NAME[k], m, n) for (k, m), n in sorted(per.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
