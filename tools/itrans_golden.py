#!/usr/bin/env python3
"""Fixtures for bench/umd/dequant_itrans_tb.sv: blocks of coefficient levels in scan
order and the residual samples / scaled DC values umd/h264/dequant_itrans.sv must
produce, from the model functions of tools/h264_recon_ref.py (dequant4x4, itrans4x4,
luma_dc, chroma_dc -- proven pixel-exact against ffmpeg and the H.264.1 YUVs).
docs/h264_recon.md S2.4.

Files per case class (one hex word per line, $readmemh):
  <stem>.meta.hex   [0] n_blocks [1] n_coef words [2] n_out words [3] max |d| seen
  <stem>.blk.hex    one 32-bit word per block: {kind[31:29], field[28], qp[27:22], 0[21:16],
                    dc_in[15:0] (two's complement)}
  <stem>.coef.hex   the levels in scan order, 16-bit two's complement, block after block
                    (16 per L4/LDC block, 15 per LAC/CAC block, 4 per CDC block)
  <stem>.exp.hex    the expected outputs, 16-bit two's complement (16 per block, 4 per CDC)

Case classes (the RED arms of run_dequant_itrans.sh are named by these stems):
  it_rand_<KIND>_<frame|field>  every qp 0..51 x random blocks, levels kept inside the
                    spec's ranges (8.5.12: d, f, h in 16 bits; 8.5.10 / 8.5.11.2: dcY, dcC
                    in 16 bits) by a sufficient condition that is ASSERTED on the golden
                    (sum |d| <= 32767 bounds every f and h; sum |c| times the DC gain
                    bounds every dcY / dcC); a block outside the range is regenerated with
                    smaller levels, never written, and the retries are counted
  it_sparse_<frame|field>  one coefficient at every scan position of every kind, at the
                    largest magnitude the range admits, both signs, 7 qps
  it_zero           all-zero blocks of every kind, and AC blocks whose only content is dc_in
  it_real[_field]   the blocks a real stream's decode transforms (the fixture-range check):
                    the x264 clip the runner encodes (--stream), captured by wrapping the
                    model's own transform functions while h264_recon_ref decodes it, with
                    the QP the decoder used for that macroblock; with --disc, field-coded
                    blocks from a disc image (the model decodes the field pictures)

    itrans_golden.py --out bench/umd/fixtures/gen [--stream clip.264] [--disc image.iso]
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import h264_recon_ref as R  # noqa: E402

K_L4, K_LAC, K_CAC, K_LDC, K_CDC = range(5)
KIND_NAME = ["L4", "LAC", "CAC", "LDC", "CDC"]
NCOEF = [16, 15, 15, 16, 4]
NOUT = [16, 16, 16, 16, 4]
LIM = 32767                                 # 2^(7 + bitDepth) - 1 at 8 bits


class RangeError(Exception):
    pass


def check_rounding_identity():
    """The RTL omits the rounding term of eq. 8-338 (qp < 24): with flat scaling lists
    LevelScale4x4 is a multiple of 16, so (c * LS + 2^(3 - qp/6)) >> (4 - qp/6) equals
    (c * LS) >> (4 - qp/6) for every level c. This checks that identity exhaustively --
    every 16-bit level, every qp % 6, every position class, every qp/6 below 4 -- against
    the model's own tables before any fixture is written, so a change to the model's
    scaling (a scaling matrix, say) fails here rather than silently in the RTL."""
    import numpy as np
    c = np.arange(-32768, 32768, dtype=np.int64)
    for m in range(6):
        for cls, (i, j) in enumerate(((0, 0), (1, 1), (0, 1))):
            ls = R.LEVEL_SCALE[m][i][j]
            assert ls == 16 * R.NORM_ADJUST[m][cls], (m, cls, ls)
            for q6 in range(4):
                s = 4 - q6
                with_term = (c * ls + (1 << (3 - q6))) >> s
                without = (c * ls) >> s
                if not np.array_equal(with_term, without):
                    raise SystemExit("itrans_golden: the eq. 8-338 rounding term is NOT vacuous "
                                     "(m %d class %d qp/6 %d): the RTL must build it" % (m, cls, q6))


def golden(kind, qp, field, dc, levels, strict=True):
    """The model's outputs for one block, and the range facts the spec states about it.
    Returns (outputs, max_abs_d, tight). Raises RangeError when the block is outside what
    a conforming stream may carry (the bench must never see one of those). `strict` also
    demands the sufficient condition below, which the random generator keeps to; a real
    stream's block may legally exceed it (`tight` says so) while its f and h stay in range."""
    scan = R.FIELD_SCAN if field else R.ZIGZAG
    if kind in (K_L4, K_LAC, K_CAC):
        d = R.dequant4x4(levels, scan, qp, dc=(dc if kind != K_L4 else None))
        # 8.5.12.1: every d_ij within 16 bits; 8.5.12.2: every f_ij and h_ij too. Sufficient
        # for the latter: each row's f is a signed combination of that row's d with
        # |weights| <= 1, so |f_ij| <= sum_j |d_ij|, and |h_ij| <= sum_i |f_ij| <= the sum
        # over the block of |d|.
        if min(d) < -LIM - 1 or max(d) > LIM:
            raise RangeError("d out of range")
        tight = sum(abs(v) for v in d) > LIM
        if strict and tight:
            raise RangeError("d sum out of range")
        return R.itrans4x4(d), max(abs(v) for v in d), tight
    if kind == K_LDC:
        out = R.luma_dc(levels, scan, qp)
    else:
        out = R.chroma_dc(levels, qp)
    if min(out) < -LIM - 1 or max(out) > LIM:      # 8.5.10 / 8.5.11.2: dcY, dcC within 16 bits
        raise RangeError("dc out of range")
    return out, max(abs(v) for v in out), False


def unit_scale(kind, qp, field, pos):
    """|d| (or the DC output gain) of a level of 1 at scan position `pos`, from the model."""
    scan = R.FIELD_SCAN if field else R.ZIGZAG
    n = NCOEF[kind]
    lv = [0] * n
    lv[pos] = 1
    if kind in (K_L4, K_LAC, K_CAC):
        d = R.dequant4x4(lv, scan, qp, dc=(0 if kind != K_L4 else None))
        return max(abs(v) for v in d)
    if kind == K_LDC:
        # the Hadamard spreads a single level to every f_ij with |f| = 1: the gain is
        # LevelScale * 2^(qp/6) / 64 (the rounding hides it at low qp, so use the formula)
        return R.LEVEL_SCALE[qp % 6][0][0] * (2 ** (qp // 6)) / 64.0
    return R.LEVEL_SCALE[qp % 6][0][0] * (2 ** (qp // 6)) / 32.0


def max_level(kind, qp, field, pos, budget):
    """The largest level magnitude at `pos` whose scaled value stays within `budget`
    (the estimate from the unit gain, then backed off until the model agrees -- the DC
    rounding can add one)."""
    g = unit_scale(kind, qp, field, pos)
    if g == 0:
        return 0
    m = max(0, min(int(budget // g), LIM))
    n = NCOEF[kind]
    while m > 0:
        lv = [0] * n
        lv[pos] = m
        try:
            out, maxv, _ = golden(kind, qp, field, 0, lv)
            if maxv <= budget:
                break
        except RangeError:
            pass
        m -= 1
    return m


class Case(object):
    __slots__ = ("kind", "qp", "field", "dc", "levels", "out", "maxd", "tight")

    def __init__(self, kind, qp, field, dc, levels, strict=True):
        self.kind, self.qp, self.field, self.dc, self.levels = kind, qp, field, dc, levels
        self.out, self.maxd, self.tight = golden(kind, qp, field, dc, levels, strict)


def rand_block(rng, kind, qp, field, retries):
    """A random block inside the spec ranges: n_nz positions, the range budget shared."""
    n = NCOEF[kind]
    for attempt in range(40):
        n_nz = rng.randint(1, n)
        positions = rng.sample(range(n), n_nz)
        # the budget shared by the non-zero coefficients (and dc_in for the AC kinds); a
        # deliberately uneven split so a few coefficients can be large
        shares = [rng.random() ** 2 + 0.02 for _ in range(n_nz + (1 if kind in (K_LAC, K_CAC) else 0))]
        tot = sum(shares)
        scale = LIM / float(2 ** attempt)
        levels = [0] * n
        for p, s in zip(positions, shares):
            m = max_level(kind, qp, field, p, s / tot * scale)
            if m == 0:
                continue
            v = rng.randint(1, m)
            levels[p] = -v if rng.random() < 0.5 else v
        dc = 0
        if kind in (K_LAC, K_CAC):
            m = int(shares[-1] / tot * scale)
            m = max(0, min(m, LIM))
            if m:
                dc = rng.randint(-m, m)
        try:
            return Case(kind, qp, field, dc, levels)
        except RangeError:
            retries[0] += 1
    raise SystemExit("itrans_golden: could not place a block in range (kind %d qp %d)" % (kind, qp))


def sparse_cases(field, rng):
    cases = []
    qps = [0, 7, 13, 26, 35, 36, 51]
    for kind in (K_L4, K_LAC, K_CAC, K_LDC):
        n = NCOEF[kind]
        for qp in qps:
            for pos in range(n):
                m = max_level(kind, qp, field, pos, LIM)
                for sign in (1, -1):
                    lv = [0] * n
                    lv[pos] = sign * m
                    cases.append(Case(kind, qp, field, 0, lv))
                # an AC block's DC and one AC coefficient share the range
                if kind in (K_LAC, K_CAC):
                    lv = [0] * n
                    lv[pos] = -(m // 2) if pos % 2 else (m // 2)
                    dc = rng.randint(-(LIM // 2), LIM // 2)
                    cases.append(Case(kind, qp, field, dc, lv))
    if not field:
        for qp in qps:
            for pos in range(4):
                m = max_level(K_CDC, qp, field, pos, LIM)
                for sign in (1, -1):
                    lv = [0] * 4
                    lv[pos] = sign * m
                    cases.append(Case(K_CDC, qp, field, 0, lv))
    return cases


def zero_cases(rng):
    cases = []
    for qp in (0, 5, 11, 23, 24, 40, 51):
        for kind in range(5):
            for field in ((0, 1) if kind != K_CDC else (0,)):
                cases.append(Case(kind, qp, field, 0, [0] * NCOEF[kind]))
        for field in (0, 1):
            # a DC-only block: every h_ij is d00 itself, so the whole 16-bit range is legal
            # (the random classes' sum|d| condition is only sufficient -- not demanded here)
            for dc in (1, -1, 63, -64, LIM, -LIM - 1, rng.randint(-LIM, LIM)):
                cases.append(Case(K_LAC, qp, field, dc, [0] * 15, strict=False))
                cases.append(Case(K_CAC, qp, field, dc, [0] * 15, strict=False))
    return cases


# ---- real blocks: what the model transforms while decoding a stream --------------------

class Harvest(Exception):
    pass


def real_cases(stream_path, want_field, limit, seed, disc=None, packs=400):
    """Wrap the model's transform functions, decode the stream, keep what they were called
    with. Every call is one case; nothing is reconstructed here."""
    import h264_fe_ref as FE
    got = []
    state = {"chroma": False, "field": 0}
    o_dq, o_ldc, o_cdc, o_rc = R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma

    def dq(levels, scan, qp, dc=None, m6=None):
        field = 1 if scan is R.FIELD_SCAN else 0
        if len(levels) == 16:
            got.append((K_L4, qp, field, 0, list(levels)))
        else:
            got.append((K_CAC if state["chroma"] else K_LAC, qp, field, dc, list(levels)))
        return o_dq(levels, scan, qp, dc=dc, m6=m6)

    def ldc(levels, scan, qp):
        got.append((K_LDC, qp, 1 if scan is R.FIELD_SCAN else 0, 0, list(levels)))
        return o_ldc(levels, scan, qp)

    def cdc(levels, qp):
        got.append((K_CDC, qp, state["field"], 0, list(levels)))
        return o_cdc(levels, qp)

    def rc(self, m, info):
        state["chroma"] = True
        state["field"] = 1 if self.field else 0
        try:
            return o_rc(self, m, info)
        finally:
            state["chroma"] = False
            if self.field and want_field and len(got) >= limit:
                raise Harvest()

    R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma = dq, ldc, cdc, rc
    try:
        if disc:
            data = R.disc_es(disc, 1, packs)
        else:
            data = open(stream_path, "rb").read()
        try:
            R.decode_file(None, records=FE.decode_stream(data))
        except Harvest:
            pass
    finally:
        R.dequant4x4, R.luma_dc, R.chroma_dc, R.SliceDecoder.residual_chroma = o_dq, o_ldc, o_cdc, o_rc
    if want_field:
        got = [g for g in got if g[2] == 1]
    n_all = len(got)
    rng = random.Random(seed)
    if len(got) > limit:
        got = rng.sample(got, limit)
    cases = []
    for kind, qp, field, dc, levels in got:
        cases.append(Case(kind, qp, field, dc if dc is not None else 0, levels, strict=False))
    print("  real: %d blocks transformed by the model, %d kept, %d beyond the random classes'"
          " sum|d| condition (legal: f/h still in range)" % (n_all, len(cases), sum(1 for c in cases if c.tight)))
    return cases


# ---- writing ----------------------------------------------------------------------

def h16(v):
    assert -32768 <= v <= 32767, v
    return "%04x" % (v & 0xFFFF)


def write(stem, cases):
    n_coef = sum(len(c.levels) for c in cases)
    n_out = sum(len(c.out) for c in cases)
    maxd = max([c.maxd for c in cases] + [0])
    with open(stem + ".blk.hex", "w") as f:
        for c in cases:
            f.write("%08x\n" % ((c.kind << 29) | (c.field << 28) | (c.qp << 22) | (c.dc & 0xFFFF)))
    with open(stem + ".coef.hex", "w") as f:
        for c in cases:
            assert len(c.levels) == NCOEF[c.kind]
            f.write("".join(h16(v) + "\n" for v in c.levels))
    with open(stem + ".exp.hex", "w") as f:
        for c in cases:
            assert len(c.out) == NOUT[c.kind]
            f.write("".join(h16(v) + "\n" for v in c.out))
    with open(stem + ".meta.hex", "w") as f:
        f.write("".join("%08x\n" % v for v in (len(cases), n_coef, n_out, maxd)))
    kinds = [sum(1 for c in cases if c.kind == k) for k in range(5)]
    qps = sorted(set(c.qp for c in cases))
    print("  %-22s %6d blocks (%s) qp %d..%d (%d distinct) max|d| %d" % (
        os.path.basename(stem), len(cases), " ".join("%s %d" % (KIND_NAME[k], n) for k, n in enumerate(kinds) if n),
        qps[0], qps[-1], len(qps), maxd))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--out", required=True, help="the fixture directory")
    ap.add_argument("--stream", help="an Annex-B clip for it_real (the x264 clip the runner makes)")
    ap.add_argument("--disc", help="a UMD image with field pictures for it_real_field")
    ap.add_argument("--per-qp", type=int, default=6, help="random blocks per qp per class")
    ap.add_argument("--real-limit", type=int, default=6000)
    ap.add_argument("--disc-packs", type=int, default=400)
    ap.add_argument("--seed", type=int, default=20260923)
    a = ap.parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    rng = random.Random(a.seed)
    retries = [0]
    check_rounding_identity()
    # a sanity check of the sufficient condition against the model on a few hot blocks
    for kind in range(5):
        for field in (0, 1):
            for qp in (0, 51):
                for pos in range(NCOEF[kind]):
                    lv = [0] * NCOEF[kind]
                    lv[pos] = max_level(kind, qp, field, pos, LIM)
                    Case(kind, qp, field, 0, lv)     # raises RangeError if the bound lies
    for kind in range(5):
        for field in ((0, 1) if kind != K_CDC else (0,)):
            cases = []
            for qp in range(52):
                for _ in range(a.per_qp):
                    cases.append(rand_block(rng, kind, qp, field, retries))
            stem = "it_rand_%s" % KIND_NAME[kind] + ("" if kind == K_CDC else ("_field" if field else "_frame"))
            write(os.path.join(a.out, stem), cases)
    write(os.path.join(a.out, "it_sparse_frame"), sparse_cases(0, rng))
    write(os.path.join(a.out, "it_sparse_field"), sparse_cases(1, rng))
    write(os.path.join(a.out, "it_zero"), zero_cases(rng))
    print("  random blocks regenerated for range: %d" % retries[0])
    if a.stream:
        cases = real_cases(a.stream, False, a.real_limit, a.seed)
        if not cases:
            raise SystemExit("itrans_golden: the stream produced no blocks")
        write(os.path.join(a.out, "it_real"), cases)
    if a.disc:
        cases = real_cases(None, True, a.real_limit, a.seed, disc=a.disc, packs=a.disc_packs)
        if not cases:
            raise SystemExit("itrans_golden: the disc produced no field blocks")
        write(os.path.join(a.out, "it_real_field"), cases)
    return 0


if __name__ == "__main__":
    sys.exit(main())
