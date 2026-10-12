#!/usr/bin/env python3
"""The fixed-point ATRAC3plus synthesis: the BIT-EXACT golden of the fabric decoder
(umd/at3p/). The parse is tools/at3p_ref.py's (integers already); everything after it
is integer arithmetic on the widths the RTL holds, one 27x27 signed multiplier and a
wide accumulator (docs/at3p_decoder.md S4 has the formats and why).

Every rounding is round-half-up at the accumulator ((v + 2^(s-1)) >> s, arithmetic);
every stage boundary saturates to its word width and COUNTS it (`sat`): a legal stream
never saturates (measured, S4.3), and one that does is visible, never silent.

Formats (Qn = n fractional bits; widths are two's complement):
  X    residual spectrum      Q20, 40 bits, block-normalised per subband to 27 bits
  T    time domain            Q6,  24 bits   (imdct out, overlap, gain out, tones, into IPQF)
  D    IPQF DCT output        Q16, 27 bits   (the history the FIR reads)
  out  PCM                    s16            (ffmpeg's float x 32768, saturated)
ROMs (all from one quarter-wave cosine, COSQ[i] = round(cos(pi i / 1024) 2^25), i 0..512):
  the IMDCT matrix, the IPQF DCT matrix, the sine windows, the tone oscillator and the
  Hann window are all read from it; AMPQ (tone amplitudes, Q10), F4 (2^(r/4), Q25),
  SF_M/SF_E (the scale factors, EXACT), MANT_Q19 (exact), PWC_Q5 (exact), NOISE_Q15,
  IPQF_Q30 (the prototype filter).

    at3p_fixed.py --disc IMAGE.iso [--clip N] [--track T] [--skip N] [--aus N]
"""
import argparse
import math
import os
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_tables as T  # noqa: E402

FXW, WXW = 20, 40         # residual, wide (the X buffer); block-normalised to 27 bits for the MAC
WX = 27
FT, WT = 6, 24            # time domain
FD, WD = 16, 27           # IPQF DCT out / history
CB = 25                   # COSQ
GB = 25                   # F4
AB = 10                   # AMPQ
PB = 30                   # IPQF_Q30
GATE_LSB = 1.0            # fixed vs ffmpeg, s16 LSBs: measured worst 0.615 over 787 tracks (docs S4.3)


def rsr(v, s):
    """Round-half-up arithmetic shift right by s (s <= 0 shifts left)."""
    if s <= 0:
        return v << -s
    return (v + (1 << (s - 1))) >> s


# ------------------------------------------------------------------------- ROMs

COSQ = [int(math.floor(math.cos(math.pi * i / 1024.0) * (1 << CB) + 0.5)) for i in range(513)]
COSQ[512] = 0


def cosq(m):
    """cos(pi m / 1024) x 2^25 from the quarter-wave table (m any integer)."""
    m &= 2047
    if m <= 512:
        return COSQ[m]
    if m <= 1024:
        return -COSQ[1024 - m]
    if m <= 1536:
        return -COSQ[m - 1024]
    return COSQ[2048 - m]


def sinq(m):
    """sin(pi m / 1024) x 2^25."""
    return cosq(512 - m)


def _f32(v):
    """The value ffmpeg holds: the C literal rounded to float32."""
    import numpy as np
    return float(np.float32(v))


def _exact(v, frac):
    f = Fraction(_f32(v)) * (1 << frac)
    assert f.denominator == 1, (v, frac)
    return int(f)


def _sf_split(v):
    """float32 scale factor -> (mantissa <= 16 bits, e): v = m 2^-e exactly."""
    f = Fraction(_f32(v))
    e = 0
    while f.denominator != 1:
        f *= 2
        e += 1
    m = int(f)
    while m >= (1 << 16):          # the largest entries are integers of 16 bits
        assert m % 2 == 0
        m //= 2
        e -= 1
    assert e >= 0
    return m, e


SF_M, SF_E = zip(*[_sf_split(v) for v in T.SF_TAB])
MANT_Q19 = [_exact(v, 19) for v in T.MANT_TAB]
PWC_Q5 = [_exact(v, 5) for v in T.PWC_LEVS]
NOISE_Q15 = [int(round(v * 32768)) for v in T.NOISE_TAB]
assert max(abs(n - v * 32768) for n, v in zip(NOISE_Q15, T.NOISE_TAB)) < 1e-3   # a Q15 table
IPQF1_Q = [[int(round(c * (1 << PB))) for c in row] for row in T.IPQF_COEFFS1]
IPQF2_Q = [[int(round(c * (1 << PB))) for c in row] for row in T.IPQF_COEFFS2]
AMPQ = [int(round(2.0 ** ((a - 3) / 4.0) * (1 << AB))) for a in range(64)]
F4 = [int(round(2.0 ** (r / 4.0) * (1 << GB))) for r in range(4)]
MOD23 = R.MOD23

# window ROM views (the RTL computes these indices; they read COSQ)
SINE128 = [sinq(4 * i + 2) for i in range(128)]      # sin((i + .5) pi / 256)
SINE64 = [sinq(8 * i + 4) for i in range(64)]        # sin((i + .5) pi / 128)
HANNQ = [((1 << CB) - cosq(8 * i)) >> 1 for i in range(256)]   # (1 - cos(2 pi i / 256)) / 2


def imdct_m(n, k):
    """The full IMDCT's angle index: y[n] = sum_k X[k] cos(pi (2n+129)(2k+1) / 512)
    (ffmpeg's scale -1 and its sign convention cancel; checked against the float model)."""
    return 2 * (2 * n + 129) * (2 * k + 1)


def ipqf_dct(i, j):
    """(sign, m) of the IPQF's 16-point DCT, x 2^-10 (ffmpeg's half IMDCT of 16)."""
    if i < 8:
        return 1, 16 * (2 * j + 1) * (31 - 2 * i)
    return -1, 16 * (2 * j + 1) * (49 + 2 * (i - 8))


class Sat:
    def __init__(self):
        self.n = {}

    def __call__(self, v, bits, name):
        hi = (1 << (bits - 1)) - 1
        lo = -(1 << (bits - 1))
        if v > hi or v < lo:
            self.n[name] = self.n.get(name, 0) + 1
            return hi if v > hi else lo
        return v


# -------------------------------------------------------------------- synthesis

def residual(u, ch, sb, sb_rng, sat, flags=None):
    """128 residual coefficients (Q9) of subband sb for OUTPUT channel ch: the
    dequantised spectrum and the power-compensation noise of the SOURCE channel
    (ch ^ swap), negated on channel 1 when the unit says so (ffmpeg applies the swap
    and the negation after the whole spectrum; per subband it is the same)."""
    X = [0] * 128
    if u.mute_flag or sb >= u.num_coded_subbands:
        return X
    swap = 1 if (u.unit_type == R.CH_UNIT_STEREO and u.swap_channels[sb]) else 0
    src = ch ^ swap
    c = u.channels[src]
    b0 = sb * 128
    q_lo, q_hi = T.SUBBAND_TO_QU[sb], T.SUBBAND_TO_QU[sb + 1]
    # the dequantised spectrum (qu < used_quant_units, wordlen > 0)
    for qu in range(q_lo, min(q_hi, u.used_quant_units)):
        wl = c.qu_wordlen[qu]
        if wl <= 0:
            continue
        qm = rsr(MANT_Q19[wl] * SF_M[c.qu_sf_idx[qu]], 9)
        sh = SF_E[c.qu_sf_idx[qu]] + 10 - FXW
        for p in range(T.QU_TO_SPEC_POS[qu], T.QU_TO_SPEC_POS[qu + 1]):
            X[p - b0] = sat(rsr(c.spectrum[p] * qm, sh), WXW, "X")
    # power compensation: channel src's spectrum, channel (src ^ swap) = ch's levels
    lc = u.channels[src ^ swap]
    lev = lc.power_levs[T.SUBBAND_TO_POWGRP[sb]]
    if lev != R.POWER_COMP_OFF:
        if flags is not None:
            flags.add("noise_swapped" if swap else "noise")
        g1, g2 = lc.gain_data[sb], lc.gain_data_prev[sb]
        gain_lev = (6 - g1.lev_code[0]) if g1.num_points > 0 else 0
        gcv = 0
        for i in range(g2.num_points):
            gcv = max(gcv, gain_lev - (g2.lev_code[i] - 6))
        for i in range(g1.num_points):
            gcv = max(gcv, 6 - g1.lev_code[i])
        rng = sb_rng[sb]
        for qu in range(q_lo + (2 if not sb else 0), q_hi):
            wl = c.qu_wordlen[qu]
            if wl <= 0:
                continue
            qm = rsr(MANT_Q19[wl] * SF_M[c.qu_sf_idx[qu]], 9)
            qn = rsr(qm * PWC_Q5[lev], 7)
            sh = 15 + 8 + SF_E[c.qu_sf_idx[qu]] + wl + gcv - FXW
            p0 = T.QU_TO_SPEC_POS[qu]
            for i in range(T.QU_TO_SPEC_POS[qu + 1] - p0):
                X[p0 - b0 + i] = sat(X[p0 - b0 + i] + rsr(NOISE_Q15[(rng + i) & 0x3FF] * qn, sh),
                                     WXW, "X")
    neg = u.unit_type == R.CH_UNIT_STEREO and ch == 1 and u.negate_coeffs[sb]
    return [sat(-x if neg else x, WXW, "X") for x in X]


def normalize(X):
    """Block normalisation of one subband's residual (Q20, 40 bits) for the 27-bit
    multiplier port: shift right by s = max(0, bitlen(max |X|) - 25), rounding. A quiet
    subband keeps its full Q20 precision, a loud one 25 significant bits; gain
    compensation (up to 2^12) can no longer amplify the residual's rounding
    (docs/at3p_decoder.md S4.2). Returns (X27, s)."""
    m = max(abs(x) for x in X)
    s = max(0, m.bit_length() - 25)
    return [rsr(x, s) for x in X], s


def window(wind_id):
    """The 256 window weights (Q25) for a window-shape pair: bit 1 = the previous
    frame's shape (first half), bit 0 = this frame's (second half); 0 sine, 1 steep.
    A steep half is 32 zeros, a 64-sample sine ramp, then 32 samples at weight 1.0
    (ffmpeg multiplies only the ramp)."""
    w = [0] * 256
    if wind_id & 2:
        for i in range(64):
            w[32 + i] = SINE64[i]
        for i in range(96, 128):
            w[i] = 1 << CB
    else:
        w[:128] = SINE128
    if wind_id & 1:
        for i in range(64):
            w[160 + i] = SINE64[63 - i]
        for i in range(128, 160):
            w[i] = 1 << CB
    else:
        for i in range(128):
            w[128 + i] = SINE128[127 - i]
    return w


def gain_exps(g):
    """Quarter-octave exponents of one subband's gain curve (ffmpeg's lev per sample):
    level 2^(E/4), E = 4 (6 - lev_code) up to each point, then a 4-sample ramp that
    moves E by (cur - next) a sample towards the next point's level; 0 (unity) after
    the last point and for a subband without points."""
    E = [0] * 128
    pos = 0
    for i in range(g.num_points):
        last = g.loc_code[i] << 2
        cur = g.lev_code[i]
        nxt = g.lev_code[i + 1] if i + 1 < g.num_points else 6
        while pos < last:
            E[pos] = 4 * (6 - cur)
            pos += 1
        for k in range(4):
            if pos >= 128:
                break
            E[pos] = 4 * (6 - cur) - (nxt - cur) * k
            pos += 1
    return E


def imdct_gain_fx(X, wind_id, sb, P, E1, E2, sat):
    X, s = normalize(X)
    """IMDCT, window and gain compensation of one subband, with no rounding the gain
    can amplify (docs/at3p_decoder.md S4.2).

    The residual is block-normalised (normalize); the half transform h (128 values,
    Q20, 40 bits) is kept wide. Every output sample
    y[n] (h mirrored) is multiplied once by its whole factor: the window weight times
    2^(E/4), E1 for the first half (this frame's scale 2^(6-gcs) and the previous
    frame's gain curve, folded in by the caller), E2 for the second half (THIS frame's
    curve, which ffmpeg applies to the overlap in the next frame: every gain on this
    frame's samples is known now). The factor is M = round(w F4[E mod 4] / 2^25) times
    2^floor(E/4); the product is rounded once to Q6.
    Returns (128 outputs = first half + the stored overlap P, the new overlap)."""
    if sb & 1:
        X = X[::-1]
    h = [0] * 128
    for i in range(128):
        n = 64 + i
        acc = 0
        for k in range(128):
            if X[k]:
                acc += X[k] * cosq(imdct_m(n, k))
        h[i] = sat(rsr(acc, CB + FXW - s - 20), 40, "imdct")        # Q20
    y = [0] * 256
    for i in range(64):
        y[i] = -h[63 - i]
        y[255 - i] = h[64 + i]
    y[64:192] = h
    w = window(wind_id)
    v = [0] * 256
    for n in range(256):
        if not w[n]:
            continue
        e = E1[n] if n < 128 else E2[n - 128]
        M = rsr(w[n] * F4[e & 3], CB)
        v[n] = rsr(y[n] * M, 20 + CB - FT - (e >> 2))
    out = [sat(v[i] + P[i], WT, "gain") for i in range(128)]
    return out, [sat(v[128 + i], WT, "overlap") for i in range(128)]


def waves_fx(sp, wd, env, invert_phase, reg_offset, sat):
    """One overlap region (128 samples, Q6) of a group of sine waves."""
    # wave by wave, each rounded into the region (the engine runs one oscillator at a
    # time over the 128 samples, docs/at3p_decoder.md S3.4); saturated once at the end
    out = [0] * 128
    for wn in range(wd.num_wavs):
        w = sp.waves[wd.start_index + wn]
        pos = (((w.phase_index & 0x1F) << 6) - (reg_offset ^ 128) * w.freq_index) & 2047
        amp = AMPQ[w.amp_sf]
        for i in range(128):
            out[i] = sat(out[i] + rsr(sinq(pos) * amp, CB + AB - FT), 27, "tone")
            pos = (pos + w.freq_index) & 2047
    out = [sat(v, WT, "tone") for v in out]
    if invert_phase:
        out = [sat(-v, WT, "tone") for v in out]
    if env.has_start_point:
        pos = (env.start_pos << 2) - reg_offset
        if 0 < pos <= 128:
            for i in range(pos):
                out[i] = 0
            if not env.has_stop_point or env.start_pos != env.stop_pos:
                for k in range(4):
                    if pos + k < 128:
                        out[pos + k] = rsr(out[pos + k] * HANNQ[32 * k], CB)
    if env.has_stop_point:
        pos = ((env.stop_pos + 1) << 2) - reg_offset
        if 0 < pos <= 128:
            for k in range(4):
                out[pos - 4 + k] = rsr(out[pos - 4 + k] * HANNQ[96 - 32 * k], CB)
            for i in range(pos, 128):
                out[i] = 0
    return out


def tones_fx(u, ch, sb, tb, sat, flags=None):
    """ffmpeg's generate_tones in fixed point; adds into tb (128 samples, in place).
    The envelope bookkeeping is the float model's (integers), shared state included."""
    now = u.channels[ch].tones_info_prev[sb]
    nxt = u.channels[ch].tones_info[sb]
    pn, cn = nxt.pend_env, nxt.curr_env
    if pn.has_start_point and pn.start_pos < pn.stop_pos:
        cn.has_start_point, cn.start_pos = 1, pn.start_pos + 32
    elif now.pend_env.has_start_point:
        cn.has_start_point, cn.start_pos = 1, now.pend_env.start_pos
    else:
        cn.has_start_point, cn.start_pos = 0, 0
    if now.pend_env.has_stop_point and now.pend_env.stop_pos >= cn.start_pos:
        cn.has_stop_point, cn.stop_pos = 1, now.pend_env.stop_pos
    elif pn.has_stop_point:
        cn.has_stop_point, cn.stop_pos = 1, pn.stop_pos + 32
    else:
        cn.has_stop_point, cn.stop_pos = 0, 64
    reg1_nz = 0 if now.curr_env.stop_pos < 32 else 1
    reg2_nz = 0 if cn.start_pos >= 32 else 1
    reg1 = [0] * 128
    reg2 = [0] * 128
    if now.num_wavs and reg1_nz:
        reg1 = waves_fx(u.waves_info_prev, now, now.curr_env,
                        u.waves_info_prev.invert_phase[sb] & ch, 128, sat)
    if nxt.num_wavs and reg2_nz:
        reg2 = waves_fx(u.waves_info, nxt, cn, u.waves_info.invert_phase[sb] & ch, 0, sat)
    if flags is not None and (now.num_wavs and reg1_nz) and (nxt.num_wavs and reg2_nz):
        flags.add("tones_both_regions")
    elif flags is not None:
        flags.add("tones_one_region")
    w1 = w2 = False
    if now.num_wavs and nxt.num_wavs and reg1_nz and reg2_nz:
        w1 = w2 = True
    else:
        w1 = bool(now.num_wavs and not now.curr_env.has_stop_point)
        w2 = bool(nxt.num_wavs and not cn.has_start_point)
    for i in range(128):
        a = rsr(reg1[i] * HANNQ[128 + i], CB) if w1 else reg1[i]
        b = rsr(reg2[i] * HANNQ[i], CB) if w2 else reg2[i]
        tb[i] = sat(tb[i] + a + b, WT, "tone_add")


class FixedUnit:
    def __init__(self):
        self.prev = [[0] * R.FRAME_SAMPLES for _ in range(2)]
        self.h1 = [[[0] * 8 for _ in range(24)] for _ in range(2)]
        self.h2 = [[[0] * 8 for _ in range(24)] for _ in range(2)]
        self.pos = [0, 0]


def ipqf_fx(fu, ch, tb, sat):
    out = [0] * R.FRAME_SAMPLES
    b1, b2 = fu.h1[ch], fu.h2[ch]
    for s in range(128):
        col = [tb[sb * 128 + s] for sb in range(16)]
        d = [0] * 16
        for i in range(16):
            acc = 0
            for j in range(16):
                sg, m = ipqf_dct(i, j)
                acc += col[j] * sg * cosq(m)
            d[i] = sat(rsr(acc, CB + FT + 10 - FD), WD, "ipqf_dct")
        p = fu.pos[ch]
        b1[p] = d[8:16]
        b2[p] = d[7::-1]
        pn = p
        px = MOD23[pn + 2]
        acc_lo = [0] * 8
        acc_hi = [0] * 8
        for t in range(12):
            c1, c2 = IPQF1_Q[t], IPQF2_Q[t]
            for i in range(8):
                acc_lo[i] += b1[pn][i] * c1[i] + b2[px][i] * c2[i]
                acc_hi[i] += b1[pn][7 - i] * c1[i + 8] + b2[px][7 - i] * c2[i + 8]
            pn = MOD23[px + 2]
            px = MOD23[pn + 2]
        for i in range(8):
            out[s * 16 + i] = sat(rsr(acc_lo[i], FD + PB - 15), 16, "pcm")
            out[s * 16 + 8 + i] = sat(rsr(acc_hi[i], FD + PB - 15), 16, "pcm")
        fu.pos[ch] = MOD23[p]
    return out


class FixedDecoder:
    """decode(frame) -> numpy int (2, 2048) s16."""

    def __init__(self):
        self.units = [R.ChannelUnit()]
        self.fx = [FixedUnit()]
        self.cov = {}
        self.sat = Sat()
        self.frames = 0
        self.flags = set()      # synthesis conditions this frame hit (at3p_sweep scores each)

    def decode(self, frame):
        import numpy as np
        self.flags = set()
        blocks, _bs = R.parse_frame(frame, self.units, self.cov)
        out = np.zeros((2, R.FRAME_SAMPLES), dtype=np.int64)
        for ui, nch in blocks:
            u, fu = self.units[ui], self.fx[ui]
            rng = 0
            if not u.mute_flag:
                for qu in range(u.used_quant_units):
                    rng += u.channels[0].qu_sf_idx[qu] + u.channels[1].qu_sf_idx[qu]
            sb_rng = [0] * 16
            for sb in range(u.num_coded_subbands):
                sb_rng[sb] = rng & 0x3FC
                rng += 128
            for ch in range(nch):
                c = u.channels[ch]
                tb = [0] * R.FRAME_SAMPLES
                for sb in range(u.num_subbands):
                    X = residual(u, ch, sb, sb_rng, self.sat, self.flags)
                    g_now, g_next = c.gain_data_prev[sb], c.gain_data[sb]
                    gcs = g_next.lev_code[0] if g_next.num_points else 6
                    E1 = [e + 4 * (6 - gcs) for e in gain_exps(g_now)]
                    E2 = gain_exps(g_next)
                    top = max(max(E1), max(E2))
                    if top > 24:
                        self.flags.add("gain_boost_over_x64")
                    elif top > 0:
                        self.flags.add("gain_boost")
                    if min(min(E1), min(E2)) < 0:
                        self.flags.add("gain_cut")
                    if (c.wnd_shape_prev[sb] or c.wnd_shape[sb]) and (g_now.num_points or g_next.num_points):
                        self.flags.add("steep_with_gain")
                    s = slice(sb * 128, (sb + 1) * 128)
                    tb[s], fu.prev[ch][s] = imdct_gain_fx(
                        X, (c.wnd_shape_prev[sb] << 1) + c.wnd_shape[sb], sb,
                        fu.prev[ch][s], E1, E2, self.sat)
                for i in range(u.num_subbands * 128, R.FRAME_SAMPLES):
                    fu.prev[ch][i] = 0
                if u.waves_info.tones_present or u.waves_info_prev.tones_present:
                    for sb in range(u.num_subbands):
                        if c.tones_info[sb].num_wavs or c.tones_info_prev[sb].num_wavs:
                            seg = tb[sb * 128:(sb + 1) * 128]
                            tones_fx(u, ch, sb, seg, self.sat, self.flags)
                            tb[sb * 128:(sb + 1) * 128] = seg
                out[ch] = ipqf_fx(fu, ch, tb, self.sat)
            for ch in range(nch):
                c = u.channels[ch]
                c.wnd_shape, c.wnd_shape_prev = c.wnd_shape_prev, c.wnd_shape
                c.gain_data, c.gain_data_prev = c.gain_data_prev, c.gain_data
                c.tones_info, c.tones_info_prev = c.tones_info_prev, c.tones_info
            u.waves_info, u.waves_info_prev = u.waves_info_prev, u.waves_info
        self.frames += 1
        return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--track", type=int, default=0)
    ap.add_argument("--packs", type=int)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--aus", type=int, default=24)
    a = ap.parse_args(argv)
    clip, aus, _info = R.disc_aus(a.disc, a.clip, a.track, a.packs)
    st = R.check(aus, a.skip, a.aus, fixed=True)
    print("%s clip %d track %d AUs %d..%d: float max %.4f LSB; FIXED max %.3f rms %.4f LSB"
          % (os.path.basename(a.disc), clip, a.track, a.skip, a.skip + st["aus"],
             st["max_lsb"], st["fx_max_lsb"], st["fx_rms_lsb"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
