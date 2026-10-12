#!/usr/bin/env python3
"""ATRAC3plus reference decoder -- the golden model of the fabric decoder (umd/at3p/).

ATRAC3plus has no public specification. This model is written from reading ffmpeg's
reverse-engineered decoder (libavcodec/atrac3plus.c, atrac3plusdsp.c, atrac3plusdec.c,
atrac.c at the pinned tag n9.0.1; docs/references.md) and is checked against ffmpeg's
OUTPUT, never against its internals: `--check` decodes the same access units with the
ffmpeg binary and compares the PCM (docs/at3p_decoder.md S2).

It is split the way the RTL is split (docs/at3p_decoder.md S3):

  parse_frame()      bits -> the PARSE RECORD: every syntax element, integers only.
                     State that carries between frames (window shapes, gain data, tone
                     envelopes -- each two frames deep) is kept exactly as ffmpeg keeps
                     it, stale entries included: a decoder that clears what ffmpeg
                     leaves stale decodes a legal stream differently.
  dequant()          the parse record -> the residual spectrum (quantised spectrum x
                     scale factor x mantissa step), power compensation (noise), stereo
                     swap / negate.
  imdct()            per subband: 256-point IMDCT, sine / steep windows.
  gain_comp()        gain compensation and the overlap-add with the previous frame.
  tones()            the tonal components (GHA sine waves), added in the time domain.
  ipqf()             the 16-band inverse PQF -> 2048 samples a channel.

The FLOAT path here mirrors ffmpeg's arithmetic (its tables rounded to float32 as
ffmpeg rounds them) and must match ffmpeg's float output to a small fraction of an
s16 LSB: that proves the reading of the format. The FIXED path (at3p_fixed.py, the
widths the RTL holds) is the bit-exact golden of the fabric and is gated against
ffmpeg within a MEASURED bound.

Scope: 48 kHz stereo, one stereo channel unit per frame (the census: every UMD track).
A mono unit parses (the model is general) but the fabric refuses anything but stereo.

    at3p_ref.py --disc IMAGE.iso [--clip N] [--track T] [--aus N] [--skip N] --check
    at3p_ref.py --oma a.oma --check
"""
import argparse
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_tables as T  # noqa: E402

SUBBANDS = 16
SB_SAMPLES = 128
FRAME_SAMPLES = 2048
PQF_FIR_LEN = 12
POWER_COMP_OFF = 15
CH_UNIT_MONO, CH_UNIT_STEREO, CH_UNIT_EXTENSION, CH_UNIT_TERMINATOR = 0, 1, 2, 3


class At3pError(Exception):
    """A frame the decoder refuses. `code` names the check (the RTL's error codes use
    the same names, docs/at3p_decoder.md S3.2)."""

    def __init__(self, code, msg=""):
        Exception.__init__(self, "%s%s" % (code, (": " + msg) if msg else ""))
        self.code = code


# ---------------------------------------------------------------------------- bits

class Bits:
    """MSB-first bit reader over one frame. Past the end it reads zeros (as ffmpeg's
    reader does, from the packet's zero padding) and counts the overrun."""

    def __init__(self, data):
        self.nbytes = len(data)
        self.size = len(data) * 8
        self.val = int.from_bytes(bytes(data) + b"\x00" * 8, "big")
        self.total = self.size + 64
        self.pos = 0
        self.overrun = 0

    def peek(self, n):
        if n == 0:
            return 0
        if self.pos + n > self.total:
            return 0
        return (self.val >> (self.total - self.pos - n)) & ((1 << n) - 1)

    def skip(self, n):
        self.pos += n
        if self.pos > self.size:
            self.overrun = max(self.overrun, self.pos - self.size)

    def get(self, n):
        v = self.peek(n)
        self.skip(n)
        return v

    def get1(self):
        return self.get(1)

    def left(self):
        return self.size - self.pos


def sign_extend(v, bits):
    v &= (1 << bits) - 1
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


def av_log2(v):
    return v.bit_length() - 1 if v > 0 else 0


class Vlc:
    """A canonical Huffman code from a descriptor (counts of codes of length 1..12) and
    its symbol list, assigned as ffmpeg's ff_vlc_init_from_lengths assigns them:
    code_i = sum over j < i of 2^(max-len_j), in list order (lengths ascending).
    An incomplete code leaves holes: reading one returns -1 and consumes nothing,
    exactly as ffmpeg's table does (counted in `holes`)."""

    def __init__(self, cb, syms, name=""):
        lens = []
        for b in range(1, 13):
            lens += [b] * cb[b - 1]
        assert len(lens) == len(syms), name
        self.name = name
        self.max_len = lens[-1]
        self.lens = lens
        self.syms = list(syms)
        self.table = [(-1, 0)] * (1 << self.max_len)
        code = 0
        self.codes = []
        for ln, s in zip(lens, syms):
            step = 1 << (self.max_len - ln)
            self.codes.append(code >> (self.max_len - ln))
            for k in range(step):
                self.table[code + k] = (s, ln)
            code += step
        assert code <= (1 << self.max_len), name
        self.complete = code == (1 << self.max_len)
        self.holes = 0

    def read(self, bs):
        s, ln = self.table[bs.peek(self.max_len)]
        if ln == 0:
            self.holes += 1
            return -1
        bs.skip(ln)
        return s


def _build_vlcs():
    v = {}
    xl = list(T.WL_CT_XLATS)
    p = 0
    v["wl"], v["ct"] = [], []
    for i in range(4):
        n = sum(T.WL_CBS[i])
        v["wl"].append(Vlc(T.WL_CBS[i], xl[p:p + n], "wl%d" % i))
        p += n
        n = sum(T.CT_CBS[i])
        v["ct"].append(Vlc(T.CT_CBS[i], xl[p:p + n], "ct%d" % i))
        p += n
    v["sf"] = []
    p = 0
    for i in range(8):
        n = sum(T.SF_CBS[i])
        v["sf"].append(Vlc(T.SF_CBS[i], T.SF_XLATS[p:p + n], "sf%d" % i))
        p += n
    v["spec"] = [None] * 112
    p = 0
    for i in range(112):
        cb = T.SPECTRA_CBS[i]
        if cb[0] >= 0:
            n = sum(cb)
            v["spec"][i] = Vlc(cb, T.SPECTRA_XLATS[p:p + n], "spec%d" % i)
            p += n
        else:
            v["spec"][i] = v["spec"][-cb[0]]
    v["spec_xlat_used"] = p           # 8366 of 8987: ffmpeg's array has 621 unused tail
    v["gain"] = []
    p = 0
    for i in range(11):
        n = sum(T.GAIN_CBS[i])
        v["gain"].append(Vlc(T.GAIN_CBS[i], T.GAIN_XLATS[p:p + n], "gain%d" % i))
        p += n
    v["tone"] = []
    p = 0
    for i in range(7):
        n = sum(T.TONE_CBS[i])
        v["tone"].append(Vlc(T.TONE_CBS[i], T.TONE_XLATS[p:p + n], "tone%d" % i))
        p += n
    return v


VLC = _build_vlcs()


# --------------------------------------------------------------------------- state

class Gain:
    __slots__ = ("num_points", "lev_code", "loc_code")

    def __init__(self):
        self.num_points = 0
        self.lev_code = [0] * 7
        self.loc_code = [0] * 7

    def copy_from(self, o):
        self.num_points = o.num_points
        self.lev_code = list(o.lev_code)
        self.loc_code = list(o.loc_code)


class Env:
    __slots__ = ("has_start_point", "has_stop_point", "start_pos", "stop_pos")

    def __init__(self):
        self.has_start_point = self.has_stop_point = self.start_pos = self.stop_pos = 0

    def copy_from(self, o):
        self.has_start_point, self.has_stop_point = o.has_start_point, o.has_stop_point
        self.start_pos, self.stop_pos = o.start_pos, o.stop_pos


class WavesData:
    __slots__ = ("pend_env", "curr_env", "num_wavs", "start_index")

    def __init__(self):
        self.pend_env, self.curr_env = Env(), Env()
        self.num_wavs = self.start_index = 0

    def copy_from(self, o):
        self.pend_env.copy_from(o.pend_env)
        self.curr_env.copy_from(o.curr_env)
        self.num_wavs, self.start_index = o.num_wavs, o.start_index


class WaveParam:
    __slots__ = ("freq_index", "amp_sf", "amp_index", "phase_index")

    def __init__(self):
        self.freq_index = self.amp_sf = self.amp_index = self.phase_index = 0


class WaveSynth:
    def __init__(self):
        self.tones_present = 0
        self.amplitude_mode = 0
        self.num_tone_bands = 0
        self.tone_sharing = [0] * SUBBANDS
        self.tone_master = [0] * SUBBANDS
        self.invert_phase = [0] * SUBBANDS
        self.tones_index = 0
        self.waves = [WaveParam() for _ in range(48)]


class Chan:
    def __init__(self, ch_num):
        self.ch_num = ch_num
        self.num_coded_vals = 0
        self.fill_mode = 0
        self.split_point = 0
        self.table_type = 0
        self.qu_wordlen = [0] * 32
        self.qu_sf_idx = [0] * 32
        self.qu_tab_idx = [0] * 32
        self.spectrum = [0] * FRAME_SAMPLES
        self.power_levs = [POWER_COMP_OFF] * 5
        self.wnd_shape = [0] * SUBBANDS           # the two history buffers swap
        self.wnd_shape_prev = [0] * SUBBANDS
        self.gain_data = [Gain() for _ in range(SUBBANDS)]
        self.gain_data_prev = [Gain() for _ in range(SUBBANDS)]
        self.num_gain_subbands = 0
        self.tones_info = [WavesData() for _ in range(SUBBANDS)]
        self.tones_info_prev = [WavesData() for _ in range(SUBBANDS)]


class ChannelUnit:
    """One channel unit's whole decoder state (ffmpeg's Atrac3pChanUnitCtx)."""

    def __init__(self):
        self.unit_type = 0
        self.num_quant_units = 0
        self.num_subbands = 0
        self.used_quant_units = 0
        self.num_coded_subbands = 0
        self.mute_flag = 0
        self.use_full_table = 0
        self.noise_present = 0
        self.noise_level_index = 0
        self.noise_table_index = 0
        self.swap_channels = [0] * SUBBANDS
        self.negate_coeffs = [0] * SUBBANDS
        self.channels = [Chan(0), Chan(1)]
        self.waves_info = WaveSynth()
        self.waves_info_prev = WaveSynth()
        # synthesis state (float path)
        self.prev_buf = np.zeros((2, FRAME_SAMPLES))
        self.ipqf_buf1 = np.zeros((2, PQF_FIR_LEN * 2, 8))
        self.ipqf_buf2 = np.zeros((2, PQF_FIR_LEN * 2, 8))
        self.ipqf_pos = [0, 0]


# --------------------------------------------------------------------- the parser
# Each function mirrors the ffmpeg function of the same (or the obvious) name; the
# comments name the coding modes as ffmpeg's do. `cov` counts what each rare path
# CHANGED (CLAUDE.md: a coverage counter must count what the path changes).

def _cov(cov, key, n=1):
    if cov is not None and n:
        cov[key] = cov.get(key, 0) + n


def num_coded_units(bs, chan, ctx):
    chan.fill_mode = bs.get(2)
    if not chan.fill_mode:
        chan.num_coded_vals = ctx.num_quant_units
    else:
        chan.num_coded_vals = bs.get(5)
        if chan.num_coded_vals > ctx.num_quant_units:
            raise At3pError("WL_NUM_CODED")
        if chan.fill_mode == 3:
            chan.split_point = bs.get(2) + (chan.ch_num << 1) + 1


def unpack_vq_shape(start_val, shape_vec, dst, num_values):
    if num_values:
        dst[0] = dst[1] = dst[2] = start_val
        for i in range(3, num_values):
            dst[i] = start_val - shape_vec[T.QU_NUM_TO_SEG[i] - 1]


def decode_channel_wordlen(bs, ctx, ch_num, cov):
    chan = ctx.channels[ch_num]
    ref = ctx.channels[0]
    weight_idx = 0
    chan.fill_mode = 0
    wl = chan.qu_wordlen
    mode = bs.get(2)
    _cov(cov, "wl_mode%d_ch%d" % (mode, ch_num))
    if mode == 0:
        for i in range(ctx.num_quant_units):
            wl[i] = bs.get(3)
    elif mode == 1:
        if ch_num:
            num_coded_units(bs, chan, ctx)
            if chan.num_coded_vals:
                tab = VLC["wl"][bs.get(2)]
                for i in range(chan.num_coded_vals):
                    wl[i] = (ref.qu_wordlen[i] + tab.read(bs)) & 7
        else:
            weight_idx = bs.get(2)
            num_coded_units(bs, chan, ctx)
            if chan.num_coded_vals:
                pos = bs.get(5)
                if pos > chan.num_coded_vals:
                    raise At3pError("WL_MODE1_POS")
                delta_bits = bs.get(2)
                min_val = bs.get(3)
                for i in range(pos):
                    wl[i] = bs.get(3)
                for i in range(pos, chan.num_coded_vals):
                    wl[i] = (min_val + bs.get(delta_bits)) & 7
    elif mode == 2:
        num_coded_units(bs, chan, ctx)
        if ch_num and chan.num_coded_vals:
            tab = VLC["wl"][bs.get(2)]
            wl[0] = (ref.qu_wordlen[0] + tab.read(bs)) & 7
            for i in range(1, chan.num_coded_vals):
                diff = ref.qu_wordlen[i] - ref.qu_wordlen[i - 1]
                wl[i] = (wl[i - 1] + diff + tab.read(bs)) & 7
        elif chan.num_coded_vals:
            flag = bs.get(1)
            tab = VLC["wl"][bs.get(1)]
            start_val = bs.get(3)
            unpack_vq_shape(start_val, T.WL_SHAPES[start_val][bs.get(4)], wl,
                            chan.num_coded_vals)
            if not flag:
                for i in range(chan.num_coded_vals):
                    wl[i] = (wl[i] + tab.read(bs)) & 7
            else:
                _cov(cov, "wl_mode2_pairs")
                i = 0
                while i < (chan.num_coded_vals & ~1):
                    if not bs.get1():
                        wl[i] = (wl[i] + tab.read(bs)) & 7
                        wl[i + 1] = (wl[i + 1] + tab.read(bs)) & 7
                    i += 2
                if chan.num_coded_vals & 1:
                    wl[i] = (wl[i] + tab.read(bs)) & 7
    else:
        weight_idx = bs.get(2)
        num_coded_units(bs, chan, ctx)
        if chan.num_coded_vals:
            tab = VLC["wl"][bs.get(2)]
            wl[0] = bs.get(3)
            for i in range(1, chan.num_coded_vals):
                wl[i] = (wl[i - 1] + tab.read(bs)) & 7

    if chan.fill_mode == 2:
        _cov(cov, "wl_fill2", ctx.num_quant_units - chan.num_coded_vals)
        for i in range(chan.num_coded_vals, ctx.num_quant_units):
            wl[i] = bs.get1() if ch_num else 1
    elif chan.fill_mode == 3:
        pos = (chan.num_coded_vals + chan.split_point) if ch_num \
            else (ctx.num_quant_units - chan.split_point)
        if pos > 32:
            _cov(cov, "err_split_beyond")        # ffmpeg logs and clamps
            pos = 32
        _cov(cov, "wl_fill3", max(0, pos - chan.num_coded_vals))
        for i in range(chan.num_coded_vals, pos):
            wl[i] = 1

    if weight_idx:
        _cov(cov, "wl_weights%d_ch%d" % (weight_idx, ch_num))
        w = T.WL_WEIGHTS[chan.ch_num * 3 + weight_idx - 1]
        for i in range(ctx.num_quant_units):
            wl[i] += w[i]
            if wl[i] < 0 or wl[i] > 7:
                raise At3pError("WL_RANGE", "pos %d val %d" % (i, wl[i]))


def decode_channel_sf_idx(bs, ctx, ch_num, cov):
    chan = ctx.channels[ch_num]
    ref = ctx.channels[0]
    sf = chan.qu_sf_idx
    n = ctx.used_quant_units
    weight_idx = 0
    mode = bs.get(2)
    _cov(cov, "sf_mode%d_ch%d" % (mode, ch_num))
    if mode == 0:
        for i in range(n):
            sf[i] = bs.get(6)
    elif mode == 1:
        if ch_num:
            tab = VLC["sf"][bs.get(2)]
            for i in range(n):
                sf[i] = (ref.qu_sf_idx[i] + tab.read(bs)) & 0x3F
        else:
            weight_idx = bs.get(2)
            if weight_idx == 3:
                _cov(cov, "sf_mode1_vq")
                start_val = bs.get(6)
                unpack_vq_shape(start_val, T.SF_SHAPES[bs.get(6)], sf, n)
                num_long_vals = bs.get(5)
                delta_bits = bs.get(2)
                min_val = bs.get(4) - 7
                for i in range(num_long_vals):
                    sf[i] = (sf[i] + bs.get(4) - 7) & 0x3F
                for i in range(num_long_vals, n):
                    sf[i] = (sf[i] + min_val + bs.get(delta_bits)) & 0x3F
            else:
                num_long_vals = bs.get(5)
                delta_bits = bs.get(3)
                min_val = bs.get(6)
                if num_long_vals > n or delta_bits == 7:
                    raise At3pError("SF_MODE1_PARAMS")
                for i in range(num_long_vals):
                    sf[i] = bs.get(6)
                for i in range(num_long_vals, n):
                    sf[i] = (min_val + bs.get(delta_bits)) & 0x3F
    elif mode == 2:
        if ch_num:
            tab = VLC["sf"][bs.get(2)]
            sf[0] = (ref.qu_sf_idx[0] + tab.read(bs)) & 0x3F
            for i in range(1, n):
                diff = ref.qu_sf_idx[i] - ref.qu_sf_idx[i - 1]
                sf[i] = (sf[i - 1] + diff + tab.read(bs)) & 0x3F
        else:
            tab = VLC["sf"][bs.get(2) + 4]
            start_val = bs.get(6)
            unpack_vq_shape(start_val, T.SF_SHAPES[bs.get(6)], sf, n)
            for i in range(n):
                sf[i] = (sf[i] + sign_extend(tab.read(bs), 4)) & 0x3F
    else:
        if ch_num:
            for i in range(n):
                sf[i] = ref.qu_sf_idx[i]
        else:
            weight_idx = bs.get(2)
            vlc_sel = bs.get(2)
            tab = VLC["sf"][vlc_sel]
            if weight_idx == 3:
                _cov(cov, "sf_mode3_vq")
                tab = VLC["sf"][vlc_sel + 4]
                start_val = bs.get(6)
                unpack_vq_shape(start_val, T.SF_SHAPES[bs.get(6)], sf, n)
                diff = (bs.get(4) + 56) & 0x3F
                sf[0] = (sf[0] + diff) & 0x3F
                for i in range(1, n):
                    diff = (diff + sign_extend(tab.read(bs), 4)) & 0x3F
                    sf[i] = (diff + sf[i]) & 0x3F
            else:
                sf[0] = bs.get(6)
                for i in range(1, n):
                    sf[i] = (sf[i - 1] + tab.read(bs)) & 0x3F

    if weight_idx and weight_idx < 3:
        _cov(cov, "sf_weights%d" % weight_idx)
        w = T.SF_WEIGHTS[weight_idx - 1]
        for i in range(n):
            sf[i] -= w[i]
            if sf[i] < 0 or sf[i] > 63:
                raise At3pError("SF_RANGE", "pos %d val %d" % (i, sf[i]))


def get_num_ct_values(bs, ctx):
    if bs.get1():
        n = bs.get(5)
        if n > ctx.used_quant_units:
            raise At3pError("CT_NUM")
        return n
    return ctx.used_quant_units


def decode_channel_code_tab(bs, ctx, ch_num, cov):
    chan = ctx.channels[ch_num]
    ref = ctx.channels[0]
    mask = 7 if ctx.use_full_table else 3
    chan.table_type = bs.get1()
    mode = bs.get(2)
    _cov(cov, "ct_mode%d_ch%d" % (mode, ch_num))
    if mode == 3 and not ch_num:
        return                                  # master: nothing coded in mode 3
    num_vals = get_num_ct_values(bs, ctx)
    ct = VLC["ct"]
    if mode == 1:
        tab = ct[1] if ctx.use_full_table else ct[0]
    elif mode == 2:
        tab, dtab = (ct[1], ct[2]) if ctx.use_full_table else (ct[0], ct[0])
        pred = 0
    elif mode == 3:
        tab = ct[3] if ctx.use_full_table else ct[0]
    for i in range(num_vals):
        if chan.qu_wordlen[i]:
            if mode == 0:
                chan.qu_tab_idx[i] = bs.get(ctx.use_full_table + 2)
            elif mode == 1:
                chan.qu_tab_idx[i] = tab.read(bs)
            elif mode == 2:
                chan.qu_tab_idx[i] = tab.read(bs) if not i else (pred + dtab.read(bs)) & mask
                pred = chan.qu_tab_idx[i]
            else:
                chan.qu_tab_idx[i] = (ref.qu_tab_idx[i] + tab.read(bs)) & mask
        elif ch_num and ref.qu_wordlen[i]:
            chan.qu_tab_idx[i] = bs.get1()          # clone master flag
            _cov(cov, "ct_clone_flag")


def decode_qu_spectra(bs, tab, vlc, out, pos0, num_specs, cov):
    group_size, num_coeffs, bits, is_signed = tab
    pos = 0
    while pos < num_specs:
        if group_size == 1 or bs.get1():
            for _j in range(group_size):
                val = vlc.read(bs)
                for _i in range(num_coeffs):
                    cf = val & ((1 << bits) - 1)
                    if is_signed:
                        cf = sign_extend(cf, bits)
                    elif cf and bs.get1():
                        cf = -cf
                    out[pos0 + pos] = cf
                    pos += 1
                    val >>= bits
        else:
            _cov(cov, "spec_group_skipped")
            pos += group_size * num_coeffs


def decode_spectrum(bs, ctx, num_channels, cov):
    for ch_num in range(num_channels):
        chan = ctx.channels[ch_num]
        chan.spectrum = [0] * FRAME_SAMPLES
        chan.power_levs = [POWER_COMP_OFF] * 5
        for qu in range(ctx.used_quant_units):
            p0 = T.QU_TO_SPEC_POS[qu]
            num_specs = T.QU_TO_SPEC_POS[qu + 1] - p0
            wordlen = chan.qu_wordlen[qu]
            codetab = chan.qu_tab_idx[qu]
            if wordlen:
                if not ctx.use_full_table:
                    codetab = T.CT_RESTRICTED_TO_FULL[chan.table_type][wordlen - 1][codetab]
                tab_index = (chan.table_type * 8 + codetab) * 7 + wordlen - 1
                _cov(cov, "spec_tab%d" % tab_index)
                decode_qu_spectra(bs, T.SPECTRA_TABS[tab_index], VLC["spec"][tab_index],
                                  chan.spectrum, p0, num_specs, cov)
            elif ch_num and ctx.channels[0].qu_wordlen[qu] and not codetab:
                _cov(cov, "spec_copy_master")
                chan.spectrum[p0:p0 + num_specs] = ctx.channels[0].spectrum[p0:p0 + num_specs]
                chan.qu_wordlen[qu] = ctx.channels[0].qu_wordlen[qu]
        if ctx.used_quant_units > 2:
            n = T.SUBBAND_TO_NUM_POWGRPS[ctx.num_coded_subbands - 1]
            for i in range(n):
                chan.power_levs[i] = bs.get(4)


def get_subband_flags(bs, out, num_flags):
    for i in range(num_flags):
        out[i] = 0
    result = bs.get1()
    if result:
        if bs.get1():
            for i in range(num_flags):
                out[i] = bs.get1()
        else:
            for i in range(num_flags):
                out[i] = 1
    return result


def decode_gainc_npoints(bs, ctx, ch_num, coded_subbands, cov):
    chan = ctx.channels[ch_num]
    ref = ctx.channels[0]
    g = chan.gain_data
    gv = VLC["gain"]
    mode = bs.get(2)
    _cov(cov, "gain_np_mode%d_ch%d" % (mode, ch_num))
    if mode == 0:
        for i in range(coded_subbands):
            g[i].num_points = bs.get(3)
    elif mode == 1:
        for i in range(coded_subbands):
            g[i].num_points = gv[0].read(bs)
    elif mode == 2:
        if ch_num:
            for i in range(coded_subbands):
                g[i].num_points = (ref.gain_data[i].num_points + gv[1].read(bs)) & 7
        else:
            g[0].num_points = gv[0].read(bs)
            for i in range(1, coded_subbands):
                g[i].num_points = (g[i - 1].num_points + gv[1].read(bs)) & 7
    else:
        if ch_num:
            for i in range(coded_subbands):
                g[i].num_points = ref.gain_data[i].num_points
        else:
            delta_bits = bs.get(2)
            min_val = bs.get(3)
            for i in range(coded_subbands):
                g[i].num_points = min_val + bs.get(delta_bits)
                if g[i].num_points > 7:
                    raise At3pError("GAIN_NPOINTS")


def gainc_level_mode3s(dst, ref):
    for i in range(dst.num_points):
        dst.lev_code[i] = 7 if i >= ref.num_points else ref.lev_code[i]


def gainc_level_mode1m(bs, dst):
    gv = VLC["gain"]
    if dst.num_points > 0:
        dst.lev_code[0] = gv[2].read(bs)
    for i in range(1, dst.num_points):
        dst.lev_code[i] = (dst.lev_code[i - 1] + gv[3].read(bs)) & 0xF


def decode_gainc_levels(bs, ctx, ch_num, coded_subbands, cov):
    chan = ctx.channels[ch_num]
    ref = ctx.channels[0]
    g = chan.gain_data
    gv = VLC["gain"]
    mode = bs.get(2)
    _cov(cov, "gain_lev_mode%d_ch%d" % (mode, ch_num))
    if mode == 0:
        for sb in range(coded_subbands):
            for i in range(g[sb].num_points):
                g[sb].lev_code[i] = bs.get(4)
    elif mode == 1:
        if ch_num:
            for sb in range(coded_subbands):
                for i in range(g[sb].num_points):
                    delta = gv[5].read(bs)
                    pred = 7 if i >= ref.gain_data[sb].num_points else ref.gain_data[sb].lev_code[i]
                    g[sb].lev_code[i] = (pred + delta) & 0xF
        else:
            for sb in range(coded_subbands):
                gainc_level_mode1m(bs, g[sb])
    elif mode == 2:
        if ch_num:
            for sb in range(coded_subbands):
                if g[sb].num_points > 0:
                    if bs.get1():
                        gainc_level_mode1m(bs, g[sb])
                    else:
                        gainc_level_mode3s(g[sb], ref.gain_data[sb])
        else:
            if g[0].num_points > 0:
                gainc_level_mode1m(bs, g[0])
            for sb in range(1, coded_subbands):
                for i in range(g[sb].num_points):
                    delta = gv[4].read(bs)
                    pred = 7 if i >= g[sb - 1].num_points else g[sb - 1].lev_code[i]
                    g[sb].lev_code[i] = (pred + delta) & 0xF
    else:
        if ch_num:
            for sb in range(coded_subbands):
                gainc_level_mode3s(g[sb], ref.gain_data[sb])
        else:
            delta_bits = bs.get(2)
            min_val = bs.get(4)
            for sb in range(coded_subbands):
                for i in range(g[sb].num_points):
                    g[sb].lev_code[i] = min_val + bs.get(delta_bits)
                    if g[sb].lev_code[i] > 15:
                        raise At3pError("GAIN_LEVEL")


def gainc_loc_mode0(bs, dst, pos):
    if not pos or dst.loc_code[pos - 1] < 15:
        dst.loc_code[pos] = bs.get(5)
    elif dst.loc_code[pos - 1] >= 30:
        dst.loc_code[pos] = 31
    else:
        delta_bits = av_log2(30 - dst.loc_code[pos - 1]) + 1
        dst.loc_code[pos] = dst.loc_code[pos - 1] + bs.get(delta_bits) + 1


def gainc_loc_mode1(bs, dst):
    gv = VLC["gain"]
    if dst.num_points > 0:
        dst.loc_code[0] = bs.get(5)
        for i in range(1, dst.num_points):
            tab = gv[7] if dst.lev_code[i] <= dst.lev_code[i - 1] else gv[9]
            dst.loc_code[i] = dst.loc_code[i - 1] + tab.read(bs)


def decode_gainc_loc_codes(bs, ctx, ch_num, coded_subbands, cov):
    chan = ctx.channels[ch_num]
    ref_chan = ctx.channels[0]
    g = chan.gain_data
    gv = VLC["gain"]
    mode = bs.get(2)
    _cov(cov, "gain_loc_mode%d_ch%d" % (mode, ch_num))
    if mode == 0:
        for sb in range(coded_subbands):
            for i in range(g[sb].num_points):
                gainc_loc_mode0(bs, g[sb], i)
    elif mode == 1:
        if ch_num:
            for sb in range(coded_subbands):
                if g[sb].num_points <= 0:
                    continue
                dst, ref = g[sb], ref_chan.gain_data[sb]
                delta = gv[10].read(bs)
                pred = ref.loc_code[0] if ref.num_points > 0 else 0
                dst.loc_code[0] = (pred + delta) & 0x1F
                for i in range(1, dst.num_points):
                    more_than_ref = i >= ref.num_points
                    if dst.lev_code[i] > dst.lev_code[i - 1]:
                        if more_than_ref:
                            dst.loc_code[i] = dst.loc_code[i - 1] + gv[9].read(bs)
                        else:
                            if bs.get1():
                                gainc_loc_mode0(bs, dst, i)
                            else:
                                dst.loc_code[i] = ref.loc_code[i]
                    else:
                        tab = gv[7] if more_than_ref else gv[10]
                        delta = tab.read(bs)
                        if more_than_ref:
                            dst.loc_code[i] = dst.loc_code[i - 1] + delta
                        else:
                            dst.loc_code[i] = (ref.loc_code[i] + delta) & 0x1F
        else:
            for sb in range(coded_subbands):
                gainc_loc_mode1(bs, g[sb])
    elif mode == 2:
        if ch_num:
            for sb in range(coded_subbands):
                if g[sb].num_points <= 0:
                    continue
                dst, ref = g[sb], ref_chan.gain_data[sb]
                if dst.num_points > ref.num_points or bs.get1():
                    gainc_loc_mode1(bs, dst)
                else:
                    for i in range(dst.num_points):
                        dst.loc_code[i] = ref.loc_code[i]
        else:
            for i in range(g[0].num_points):
                gainc_loc_mode0(bs, g[0], i)
            for sb in range(1, coded_subbands):
                if g[sb].num_points <= 0:
                    continue
                dst, prv = g[sb], g[sb - 1]
                delta = gv[6].read(bs)
                pred = prv.loc_code[0] if prv.num_points > 0 else 0
                dst.loc_code[0] = (pred + delta) & 0x1F
                for i in range(1, dst.num_points):
                    more_than_ref = i >= prv.num_points
                    tab = gv[(dst.lev_code[i] > dst.lev_code[i - 1]) * 2 + more_than_ref + 6]
                    delta = tab.read(bs)
                    if more_than_ref:
                        dst.loc_code[i] = dst.loc_code[i - 1] + delta
                    else:
                        dst.loc_code[i] = (prv.loc_code[i] + delta) & 0x1F
    else:
        if ch_num:
            for sb in range(coded_subbands):
                for i in range(g[sb].num_points):
                    if i >= ref_chan.gain_data[sb].num_points:
                        gainc_loc_mode0(bs, g[sb], i)
                    else:
                        g[sb].loc_code[i] = ref_chan.gain_data[sb].loc_code[i]
        else:
            delta_bits = bs.get(2) + 1
            min_val = bs.get(5)
            for sb in range(coded_subbands):
                for i in range(g[sb].num_points):
                    g[sb].loc_code[i] = min_val + i + bs.get(delta_bits)

    for sb in range(coded_subbands):
        dst = g[sb]
        for i in range(dst.num_points):
            if dst.loc_code[i] < 0 or dst.loc_code[i] > 31 or \
                    (i and dst.loc_code[i] <= dst.loc_code[i - 1]):
                raise At3pError("GAIN_LOC", "ch %d sb %d pos %d val %d" %
                                (ch_num, sb, i, dst.loc_code[i]))


def decode_gainc_data(bs, ctx, num_channels, cov):
    for ch_num in range(num_channels):
        chan = ctx.channels[ch_num]
        for g in chan.gain_data:
            g.num_points = 0
            g.lev_code = [0] * 7
            g.loc_code = [0] * 7
        if bs.get1():
            coded_subbands = bs.get(4) + 1
            if bs.get1():
                chan.num_gain_subbands = bs.get(4) + 1
            else:
                chan.num_gain_subbands = coded_subbands
            decode_gainc_npoints(bs, ctx, ch_num, coded_subbands, cov)
            decode_gainc_levels(bs, ctx, ch_num, coded_subbands, cov)
            decode_gainc_loc_codes(bs, ctx, ch_num, coded_subbands, cov)
            for sb in range(coded_subbands, chan.num_gain_subbands):
                _cov(cov, "gain_replicated")
                chan.gain_data[sb].copy_from(chan.gain_data[sb - 1])
            _cov(cov, "gain_points", sum(g.num_points for g in chan.gain_data))
        else:
            chan.num_gain_subbands = 0


def decode_tones_envelope(bs, ctx, ch_num, band_has_tones, cov):
    dst = ctx.channels[ch_num].tones_info
    ref = ctx.channels[0].tones_info
    wi = ctx.waves_info
    if not ch_num or not bs.get1():
        _cov(cov, "tone_env_mode0_ch%d" % ch_num)
        for sb in range(wi.num_tone_bands):
            if not band_has_tones[sb]:
                continue
            e = dst[sb].pend_env
            e.has_start_point = bs.get1()
            e.start_pos = bs.get(5) if e.has_start_point else -1
            e.has_stop_point = bs.get1()
            e.stop_pos = bs.get(5) if e.has_stop_point else 32
    else:
        _cov(cov, "tone_env_mode1_ch1")
        for sb in range(wi.num_tone_bands):
            if band_has_tones[sb]:
                dst[sb].pend_env.copy_from(ref[sb].pend_env)


def decode_band_numwavs(bs, ctx, ch_num, band_has_tones, cov):
    dst = ctx.channels[ch_num].tones_info
    ref = ctx.channels[0].tones_info
    wi = ctx.waves_info
    tv = VLC["tone"]
    mode = bs.get(ch_num + 1)
    _cov(cov, "tone_num_mode%d_ch%d" % (mode, ch_num))
    for sb in range(wi.num_tone_bands):
        if not band_has_tones[sb]:
            continue
        if mode == 0:
            dst[sb].num_wavs = bs.get(4)
        elif mode == 1:
            dst[sb].num_wavs = tv[1].read(bs)
        elif mode == 2:
            delta = sign_extend(tv[2].read(bs), 3)
            dst[sb].num_wavs = (ref[sb].num_wavs + delta) & 0xF
        else:
            dst[sb].num_wavs = ref[sb].num_wavs
    for sb in range(wi.num_tone_bands):
        if band_has_tones[sb]:
            if wi.tones_index + dst[sb].num_wavs > 48:
                raise At3pError("TONES_MAX")
            dst[sb].start_index = wi.tones_index
            wi.tones_index += dst[sb].num_wavs


def decode_tones_frequency(bs, ctx, ch_num, band_has_tones, cov):
    dst = ctx.channels[ch_num].tones_info
    ref = ctx.channels[0].tones_info
    wi = ctx.waves_info
    if not ch_num or not bs.get1():
        for sb in range(wi.num_tone_bands):
            if not band_has_tones[sb] or not dst[sb].num_wavs:
                continue
            iw = wi.waves[dst[sb].start_index:dst[sb].start_index + dst[sb].num_wavs]
            nw = dst[sb].num_wavs
            direction = bs.get1() if nw > 1 else 0
            _cov(cov, "tone_freq_desc" if direction else "tone_freq_asc")
            if direction:
                iw[nw - 1].freq_index = bs.get(10)
                for i in range(nw - 2, -1, -1):
                    nbits = av_log2(iw[i + 1].freq_index) + 1
                    iw[i].freq_index = bs.get(nbits)
            else:
                for i in range(nw):
                    if not i or iw[i - 1].freq_index < 512:
                        iw[i].freq_index = bs.get(10)
                    else:
                        nbits = av_log2(1023 - iw[i - 1].freq_index) + 1
                        iw[i].freq_index = bs.get(nbits) + 1024 - (1 << nbits)
    else:
        _cov(cov, "tone_freq_mode1_ch1")
        tv = VLC["tone"]
        for sb in range(wi.num_tone_bands):
            if not band_has_tones[sb] or not dst[sb].num_wavs:
                continue
            iw = wi.waves[ref[sb].start_index:]
            ow = wi.waves[dst[sb].start_index:]
            for i in range(dst[sb].num_wavs):
                delta = sign_extend(tv[6].read(bs), 8)
                if i < ref[sb].num_wavs:
                    pred = iw[i].freq_index
                else:
                    pred = iw[ref[sb].num_wavs - 1].freq_index if ref[sb].num_wavs else 0
                ow[i].freq_index = (pred + delta) & 0x3FF


def decode_tones_amplitude(bs, ctx, ch_num, band_has_tones, cov):
    dst = ctx.channels[ch_num].tones_info
    ref = ctx.channels[0].tones_info
    wi = ctx.waves_info
    tv = VLC["tone"]
    refwaves = [0] * 48
    if ch_num:
        for sb in range(wi.num_tone_bands):
            if not band_has_tones[sb] or not dst[sb].num_wavs:
                continue
            ws = wi.waves[dst[sb].start_index:]
            wr = wi.waves[ref[sb].start_index:]
            for j in range(dst[sb].num_wavs):
                fi, maxdiff = 0, 1024
                for i in range(ref[sb].num_wavs):
                    diff = abs(ws[j].freq_index - wr[i].freq_index)
                    if diff < maxdiff:
                        maxdiff, fi = diff, i
                if maxdiff < 8:
                    refwaves[dst[sb].start_index + j] = fi + ref[sb].start_index
                elif j < ref[sb].num_wavs:
                    refwaves[dst[sb].start_index + j] = j + ref[sb].start_index
                else:
                    refwaves[dst[sb].start_index + j] = -1
    mode = bs.get(ch_num + 1)
    _cov(cov, "tone_amp_mode%d_ch%d" % (mode, ch_num))
    for sb in range(wi.num_tone_bands):
        if not band_has_tones[sb]:
            continue
        if mode != 3 and not dst[sb].num_wavs:
            continue
        s = dst[sb].start_index
        if mode == 0:
            if wi.amplitude_mode:
                for i in range(dst[sb].num_wavs):
                    wi.waves[s + i].amp_sf = bs.get(6)
            else:
                wi.waves[s].amp_sf = bs.get(6)
        elif mode == 1:
            if wi.amplitude_mode:
                for i in range(dst[sb].num_wavs):
                    wi.waves[s + i].amp_sf = tv[3].read(bs) + 20
            else:
                wi.waves[s].amp_sf = tv[4].read(bs) + 24
        elif mode == 2:
            for i in range(dst[sb].num_wavs):
                delta = sign_extend(tv[5].read(bs), 5)
                r = refwaves[s + i]
                pred = wi.waves[r].amp_sf if r >= 0 else 34
                wi.waves[s + i].amp_sf = (pred + delta) & 0x3F
        else:
            for i in range(dst[sb].num_wavs):
                r = refwaves[s + i]
                wi.waves[s + i].amp_sf = wi.waves[r].amp_sf if r >= 0 else 32


def decode_tones_phase(bs, ctx, ch_num, band_has_tones):
    dst = ctx.channels[ch_num].tones_info
    wi = ctx.waves_info
    for sb in range(wi.num_tone_bands):
        if not band_has_tones[sb]:
            continue
        for i in range(dst[sb].num_wavs):
            wi.waves[dst[sb].start_index + i].phase_index = bs.get(5)


def decode_tones_info(bs, ctx, num_channels, cov):
    for ch_num in range(num_channels):
        ctx.channels[ch_num].tones_info = [WavesData() for _ in range(SUBBANDS)]
    wi = ctx.waves_info
    wi.tones_present = bs.get1()
    if not wi.tones_present:
        return
    _cov(cov, "tones_present")
    wi.waves = [WaveParam() for _ in range(48)]
    wi.amplitude_mode = bs.get1()
    if not wi.amplitude_mode:
        raise At3pError("GHA_AMP_MODE0")          # ffmpeg: "missing feature"
    wi.num_tone_bands = VLC["tone"][0].read(bs) + 1
    if num_channels == 2:
        get_subband_flags(bs, wi.tone_sharing, wi.num_tone_bands)
        get_subband_flags(bs, wi.tone_master, wi.num_tone_bands)
        get_subband_flags(bs, wi.invert_phase, wi.num_tone_bands)
    wi.tones_index = 0
    for ch_num in range(num_channels):
        band_has_tones = [1 if not ch_num else (0 if wi.tone_sharing[i] else 1)
                          for i in range(wi.num_tone_bands)]
        decode_tones_envelope(bs, ctx, ch_num, band_has_tones, cov)
        decode_band_numwavs(bs, ctx, ch_num, band_has_tones, cov)
        decode_tones_frequency(bs, ctx, ch_num, band_has_tones, cov)
        decode_tones_amplitude(bs, ctx, ch_num, band_has_tones, cov)
        decode_tones_phase(bs, ctx, ch_num, band_has_tones)
    if num_channels == 2:
        t0, t1 = ctx.channels[0].tones_info, ctx.channels[1].tones_info
        for i in range(wi.num_tone_bands):
            if wi.tone_sharing[i]:
                _cov(cov, "tone_sharing")
                t1[i].copy_from(t0[i])
            if wi.tone_master[i]:
                _cov(cov, "tone_master_swap")
                t0[i], t1[i] = t1[i], t0[i]
    _cov(cov, "tones", wi.tones_index)


def decode_channel_unit(bs, ctx, num_channels, cov=None):
    ctx.num_quant_units = bs.get(5) + 1
    if 28 < ctx.num_quant_units < 32:
        raise At3pError("NUM_QU", str(ctx.num_quant_units))
    ctx.mute_flag = bs.get1()
    _cov(cov, "mute", ctx.mute_flag)

    for ch_num in range(num_channels):
        ctx.channels[ch_num].qu_wordlen = [0] * 32
        decode_channel_wordlen(bs, ctx, ch_num, cov)
    i = ctx.num_quant_units - 1
    while i >= 0:
        if ctx.channels[0].qu_wordlen[i] or \
                (num_channels == 2 and ctx.channels[1].qu_wordlen[i]):
            break
        i -= 1
    ctx.used_quant_units = i + 1

    ctx.num_subbands = T.QU_TO_SUBBAND[ctx.num_quant_units - 1] + 1
    ctx.num_coded_subbands = (T.QU_TO_SUBBAND[ctx.used_quant_units - 1] + 1
                              if ctx.used_quant_units else 0)

    if ctx.used_quant_units:
        for ch_num in range(num_channels):
            ctx.channels[ch_num].qu_sf_idx = [0] * 32
            decode_channel_sf_idx(bs, ctx, ch_num, cov)

    if ctx.used_quant_units:
        ctx.use_full_table = bs.get1()
        for ch_num in range(num_channels):
            ctx.channels[ch_num].qu_tab_idx = [0] * 32
            decode_channel_code_tab(bs, ctx, ch_num, cov)

    decode_spectrum(bs, ctx, num_channels, cov)

    if num_channels == 2:
        if get_subband_flags(bs, ctx.swap_channels, ctx.num_coded_subbands):
            _cov(cov, "swap_channels", sum(ctx.swap_channels[:ctx.num_coded_subbands]))
        if get_subband_flags(bs, ctx.negate_coeffs, ctx.num_coded_subbands):
            _cov(cov, "negate_coeffs", sum(ctx.negate_coeffs[:ctx.num_coded_subbands]))

    for ch_num in range(num_channels):
        get_subband_flags(bs, ctx.channels[ch_num].wnd_shape, ctx.num_subbands)
        _cov(cov, "wnd_steep", sum(ctx.channels[ch_num].wnd_shape[:ctx.num_subbands]))

    decode_gainc_data(bs, ctx, num_channels, cov)
    decode_tones_info(bs, ctx, num_channels, cov)

    ctx.noise_present = bs.get1()
    if ctx.noise_present:
        ctx.noise_level_index = bs.get(4)
        ctx.noise_table_index = bs.get(4)


def cov_universe():
    """Every coverage key a stereo stream can produce (the sweep reports the ones the
    library never reaches: decoded, but untested)."""
    k = []
    for ch in (0, 1):
        for m in range(4):
            k += ["wl_mode%d_ch%d" % (m, ch), "sf_mode%d_ch%d" % (m, ch),
                  "ct_mode%d_ch%d" % (m, ch), "gain_np_mode%d_ch%d" % (m, ch),
                  "gain_lev_mode%d_ch%d" % (m, ch), "gain_loc_mode%d_ch%d" % (m, ch)]
        for w in (1, 2, 3):
            k.append("wl_weights%d_ch%d" % (w, ch))
    for m in range(4):
        k += ["tone_num_mode%d_ch1" % m, "tone_amp_mode%d_ch1" % m]
    for m in range(2):
        k += ["tone_num_mode%d_ch0" % m, "tone_amp_mode%d_ch0" % m]
    k += ["tone_env_mode0_ch0", "tone_env_mode0_ch1", "tone_env_mode1_ch1",
          "tone_freq_asc", "tone_freq_desc", "tone_freq_mode1_ch1",
          "sf_weights1", "sf_weights2", "sf_mode1_vq", "sf_mode3_vq", "wl_mode2_pairs",
          "wl_fill2", "wl_fill3", "spec_group_skipped", "spec_copy_master", "ct_clone_flag",
          "swap_channels", "negate_coeffs", "wnd_steep", "gain_points", "gain_replicated",
          "tones_present", "tones", "tone_sharing", "tone_master_swap", "mute"]
    k += ["spec_tab%d" % i for i in range(112)]
    return k


def parse_frame(data, units, cov=None):
    """Parse one frame into `units` (a list of one ChannelUnit per channel block: one
    stereo unit here). Returns the list of (unit_index, num_channels) decoded, in order.
    Raises At3pError on a frame the decoder refuses."""
    bs = Bits(data)
    if bs.get1():
        raise At3pError("START_BIT")
    blocks = []
    while bs.left() >= 2:
        uid = bs.get(2)
        if uid == CH_UNIT_TERMINATOR:
            break
        if uid == CH_UNIT_EXTENSION:
            raise At3pError("CH_UNIT_EXTENSION")
        if len(blocks) >= len(units) or uid != CH_UNIT_STEREO:
            raise At3pError("CH_CONFIG", "unit %d type %d" % (len(blocks), uid))
        u = units[len(blocks)]
        u.unit_type = uid
        decode_channel_unit(bs, u, uid + 1, cov)
        blocks.append((len(blocks), uid + 1))
    if bs.overrun:
        _cov(cov, "bit_overrun")
    return blocks, bs


# ------------------------------------------------------------------ float tables
# ffmpeg computes these at init in float (or in double stored to float); rounding
# them to float32 the same way keeps the float path within a hair of ffmpeg.

F32 = np.float32
SINE_TABLE = np.array([F32(np.sin(2 * np.pi * i / 2048)) for i in range(2048)], dtype=np.float64)
HANN = np.array([F32((1.0 - np.cos(2 * np.pi * i / F32(256.0))) * 0.5) for i in range(256)],
                dtype=np.float64)
AMP_SF = np.array([F32(np.exp2(F32(i - 3) / F32(4.0))) for i in range(64)], dtype=np.float64)
SINE_128 = np.array([F32(np.sin((i + 0.5) * (np.pi / 256.0))) for i in range(128)], dtype=np.float64)
SINE_64 = np.array([F32(np.sin((i + 0.5) * (np.pi / 128.0))) for i in range(64)], dtype=np.float64)
GAIN_TAB1 = np.array([F32(2.0 ** (6 - i)) for i in range(16)], dtype=np.float64)
GAIN_TAB2 = np.array([F32(2.0 ** (F32(-1.0 / 4) * i)) for i in range(-15, 16)], dtype=np.float64)
SF_TAB = np.array(T.SF_TAB, dtype=np.float32).astype(np.float64)
MANT_TAB = np.array(T.MANT_TAB, dtype=np.float32).astype(np.float64)
NOISE_TAB = np.array(T.NOISE_TAB, dtype=np.float32).astype(np.float64)
PWC_LEVS = np.array(T.PWC_LEVS, dtype=np.float32).astype(np.float64)
IPQF_C1 = np.array(T.IPQF_COEFFS1, dtype=np.float32).astype(np.float64)
IPQF_C2 = np.array(T.IPQF_COEFFS2, dtype=np.float32).astype(np.float64)
MOD23 = [23, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20,
         21, 22, 23, 0]


def half_imdct_matrix(n, scale):
    """ffmpeg's (half) inverse MDCT of n coefficients -> n samples (libavutil/tx,
    the naive reference form): out[i] = scale * sum_j cos((2j+1)(2n-2i-1)pi/4n) x[j],
    out[i+n/2] = -scale * sum_j cos((2j+1)(3n+2i+1)pi/4n) x[j], i < n/2."""
    h = n // 2
    j = np.arange(n)
    m = np.zeros((n, n))
    ph = np.pi / (4.0 * n)
    for i in range(h):
        m[i] = scale * np.cos((2 * j + 1) * ph * (2 * n - 2 * i - 1))
        m[i + h] = -scale * np.cos((2 * j + 1) * ph * (3 * n + 2 * i + 1))
    return m


def full_imdct_matrix(n, scale):
    """n coefficients -> 2n samples: the half transform at [n/2, 3n/2) and its two
    mirrored quarters (ffmpeg's mdct_inv_full)."""
    hm = half_imdct_matrix(n, scale)
    m = np.zeros((2 * n, n))
    q = n // 2
    m[q:q + n] = hm
    for i in range(q):
        m[i] = -m[n - i - 1]
        m[2 * n - i - 1] = m[n + i]
    return m


IMDCT_M = full_imdct_matrix(128, -1.0)
IPQF_M = half_imdct_matrix(16, 32.0 / 32768.0)


# --------------------------------------------------------------- the float path

def dequant(u, num_channels):
    """The residual spectrum of each channel: ffmpeg's decode_residual_spectrum."""
    out = np.zeros((2, FRAME_SAMPLES))
    if u.mute_flag:
        return out
    rng = 0
    for qu in range(u.used_quant_units):
        rng += u.channels[0].qu_sf_idx[qu] + u.channels[1].qu_sf_idx[qu]
    sb_rng = [0] * SUBBANDS
    for sb in range(u.num_coded_subbands):
        sb_rng[sb] = rng & 0x3FC
        rng += 128
    for ch in range(num_channels):
        c = u.channels[ch]
        for qu in range(u.used_quant_units):
            p0, p1 = T.QU_TO_SPEC_POS[qu], T.QU_TO_SPEC_POS[qu + 1]
            if c.qu_wordlen[qu] > 0:
                q = F32(SF_TAB[c.qu_sf_idx[qu]] * MANT_TAB[c.qu_wordlen[qu]])
                out[ch, p0:p1] = np.array(c.spectrum[p0:p1], dtype=np.float64) * q
        for sb in range(u.num_coded_subbands):
            power_compensation(u, ch, out[ch], sb_rng[sb], sb)
    if u.unit_type == CH_UNIT_STEREO:
        for sb in range(u.num_coded_subbands):
            s = slice(sb * SB_SAMPLES, (sb + 1) * SB_SAMPLES)
            if u.swap_channels[sb]:
                out[0, s], out[1, s] = out[1, s].copy(), out[0, s].copy()
            if u.negate_coeffs[sb]:
                out[1, s] = -out[1, s]
    return out


def power_compensation(u, ch, sp, rng_index, sb):
    swap_ch = 1 if (u.unit_type == CH_UNIT_STEREO and u.swap_channels[sb]) else 0
    cs = u.channels[ch ^ swap_ch]
    lev = cs.power_levs[T.SUBBAND_TO_POWGRP[sb]]
    if lev == POWER_COMP_OFF:
        return
    pwcsp = NOISE_TAB[(rng_index + np.arange(SB_SAMPLES)) & 0x3FF]
    g1, g2 = cs.gain_data[sb], cs.gain_data_prev[sb]
    gain_lev = (6 - g1.lev_code[0]) if g1.num_points > 0 else 0
    gcv = 0
    for i in range(g2.num_points):
        gcv = max(gcv, gain_lev - (g2.lev_code[i] - 6))
    for i in range(g1.num_points):
        gcv = max(gcv, 6 - g1.lev_code[i])
    grp_lev = F32(PWC_LEVS[lev] / (1 << gcv))
    c = u.channels[ch]
    q0 = T.SUBBAND_TO_QU[sb] + (2 if not sb else 0)
    for qu in range(q0, T.SUBBAND_TO_QU[sb + 1]):
        if c.qu_wordlen[qu] <= 0:
            continue
        qu_lev = F32(F32(F32(SF_TAB[c.qu_sf_idx[qu]] * MANT_TAB[c.qu_wordlen[qu]]) /
                         (1 << c.qu_wordlen[qu])) * grp_lev)
        p0, p1 = T.QU_TO_SPEC_POS[qu], T.QU_TO_SPEC_POS[qu + 1]
        sp[p0:p1] += pwcsp[:p1 - p0] * qu_lev


def imdct(x, wind_id, sb):
    if sb & 1:
        x = x[::-1]
    y = IMDCT_M @ x
    if wind_id & 2:
        y[:32] = 0
        y[32:96] *= SINE_64
    else:
        y[:128] *= SINE_128
    if wind_id & 1:
        y[160:224] *= SINE_64[::-1]
        y[224:] = 0
    else:
        y[128:] *= SINE_128[::-1]
    return y


def gain_comp(inp, prev, gc_now, gc_next):
    """ffmpeg's ff_atrac_gain_compensation (loc_scale 2, id2exp_offset 6) for one
    subband: 128 output samples; returns (out, new prev)."""
    n = SB_SAMPLES
    gc_scale = GAIN_TAB1[gc_next.lev_code[0]] if gc_next.num_points else 1.0
    out = np.empty(n)
    if not gc_now.num_points:
        out[:] = inp[:n] * gc_scale + prev
    else:
        pos = 0
        for i in range(gc_now.num_points):
            lastpos = gc_now.loc_code[i] << 2
            lev = GAIN_TAB1[gc_now.lev_code[i]]
            nxt = gc_now.lev_code[i + 1] if i + 1 < gc_now.num_points else 6
            gain_inc = GAIN_TAB2[nxt - gc_now.lev_code[i] + 15]
            while pos < lastpos:
                out[pos] = (inp[pos] * gc_scale + prev[pos]) * lev
                pos += 1
            while pos < lastpos + 4:
                out[pos] = (inp[pos] * gc_scale + prev[pos]) * lev
                lev = F32(lev * gain_inc)
                pos += 1
        out[pos:] = inp[pos:n] * gc_scale + prev[pos:]
    return out, inp[n:2 * n].copy()


def waves_synth(sp, wd, env, invert_phase, reg_offset, out):
    for wn in range(wd.num_wavs):
        w = sp.waves[wd.start_index + wn]
        amp = AMP_SF[w.amp_sf] * (1.0 if sp.amplitude_mode else (w.amp_index + 1) / F32(15.13))
        inc = w.freq_index
        pos = (((w.phase_index & 0x1F) << 6) - (reg_offset ^ 128) * inc) & 2047
        idx = (pos + inc * np.arange(128)) & 2047
        out += SINE_TABLE[idx] * amp
    if invert_phase:
        out *= -1.0
    if env.has_start_point:
        pos = (env.start_pos << 2) - reg_offset
        if 0 < pos <= 128:
            out[:pos] = 0
            if not env.has_stop_point or env.start_pos != env.stop_pos:
                out[pos + 0] *= HANN[0]
                out[pos + 1] *= HANN[32]
                out[pos + 2] *= HANN[64]
                out[pos + 3] *= HANN[96]
    if env.has_stop_point:
        pos = ((env.stop_pos + 1) << 2) - reg_offset
        if 0 < pos <= 128:
            out[pos - 4] *= HANN[96]
            out[pos - 3] *= HANN[64]
            out[pos - 2] *= HANN[32]
            out[pos - 1] *= HANN[0]
            out[pos:] = 0


def generate_tones(u, ch, sb, out):
    now = u.channels[ch].tones_info_prev[sb]
    nxt = u.channels[ch].tones_info[sb]
    reg1 = np.zeros(128)
    reg2 = np.zeros(128)
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
    if now.num_wavs and reg1_nz:
        waves_synth(u.waves_info_prev, now, now.curr_env,
                    u.waves_info_prev.invert_phase[sb] & ch, 128, reg1)
    if nxt.num_wavs and reg2_nz:
        waves_synth(u.waves_info, nxt, cn, u.waves_info.invert_phase[sb] & ch, 0, reg2)
    if now.num_wavs and nxt.num_wavs and reg1_nz and reg2_nz:
        reg1 *= HANN[128:]
        reg2 *= HANN[:128]
    else:
        if now.num_wavs and not now.curr_env.has_stop_point:
            reg1 *= HANN[128:]
        if nxt.num_wavs and not cn.has_start_point:
            reg2 *= HANN[:128]
    out += reg1 + reg2


def ipqf(u, ch, inp):
    out = np.zeros(FRAME_SAMPLES)
    b1, b2 = u.ipqf_buf1[ch], u.ipqf_buf2[ch]
    grid = inp.reshape(SUBBANDS, SB_SAMPLES)
    for s in range(SB_SAMPLES):
        idct_out = IPQF_M @ grid[:, s]
        pos = u.ipqf_pos[ch]
        b1[pos] = idct_out[8:16]
        b2[pos] = idct_out[7::-1]
        pos_now = pos
        pos_next = MOD23[pos_now + 2]
        acc = np.zeros(16)
        for t in range(PQF_FIR_LEN):
            acc[:8] += b1[pos_now] * IPQF_C1[t, :8] + b2[pos_next] * IPQF_C2[t, :8]
            acc[8:] += b1[pos_now][::-1] * IPQF_C1[t, 8:] + b2[pos_next][::-1] * IPQF_C2[t, 8:]
            pos_now = MOD23[pos_next + 2]
            pos_next = MOD23[pos_now + 2]
        out[s * 16:(s + 1) * 16] = acc
        u.ipqf_pos[ch] = MOD23[pos]
    return out


def reconstruct(u, num_channels, samples):
    """imdct + gain + overlap, tones, IPQF for one unit; returns (2, 2048) floats and
    swaps the two-frame histories exactly as ffmpeg does."""
    outp = np.zeros((2, FRAME_SAMPLES))
    for ch in range(num_channels):
        c = u.channels[ch]
        time_buf = np.zeros(FRAME_SAMPLES)
        for sb in range(u.num_subbands):
            s = slice(sb * SB_SAMPLES, (sb + 1) * SB_SAMPLES)
            y = imdct(samples[ch, s], (c.wnd_shape_prev[sb] << 1) + c.wnd_shape[sb], sb)
            time_buf[s], u.prev_buf[ch, s] = gain_comp(y, u.prev_buf[ch, s],
                                                       c.gain_data_prev[sb], c.gain_data[sb])
        u.prev_buf[ch, u.num_subbands * SB_SAMPLES:] = 0
        if u.waves_info.tones_present or u.waves_info_prev.tones_present:
            for sb in range(u.num_subbands):
                if c.tones_info[sb].num_wavs or c.tones_info_prev[sb].num_wavs:
                    generate_tones(u, ch, sb, time_buf[sb * 128:(sb + 1) * 128])
        outp[ch] = ipqf(u, ch, time_buf)
    for ch in range(num_channels):
        c = u.channels[ch]
        c.wnd_shape, c.wnd_shape_prev = c.wnd_shape_prev, c.wnd_shape
        c.gain_data, c.gain_data_prev = c.gain_data_prev, c.gain_data
        c.tones_info, c.tones_info_prev = c.tones_info_prev, c.tones_info
    u.waves_info, u.waves_info_prev = u.waves_info_prev, u.waves_info
    return outp


class Decoder:
    """Float decoder, one stereo channel unit. decode(frame) -> (2, 2048) float64
    samples in ffmpeg's float scale (full scale = 1.0)."""

    def __init__(self):
        self.units = [ChannelUnit()]
        self.cov = {}
        self.frames = 0
        self.errors = {}

    def decode(self, frame):
        blocks, _bs = parse_frame(frame, self.units, self.cov)
        out = np.zeros((2, FRAME_SAMPLES))
        for ui, nch in blocks:
            u = self.units[ui]
            out[:nch] = reconstruct(u, nch, dequant(u, nch))[:nch]
        self.frames += 1
        return out


# ------------------------------------------------------------------- the oracle

def ffmpeg_f32(oma_bytes):
    """ffmpeg's float decode of an OMA file -> (n, 2) float32 (the oracle)."""
    with tempfile.TemporaryDirectory() as d:
        p = os.path.join(d, "a.oma")
        with open(p, "wb") as f:
            f.write(oma_bytes)
        r = subprocess.run(["ffmpeg", "-v", "error", "-f", "oma", "-i", p, "-f", "f32le",
                            "-acodec", "pcm_f32le", "-"], capture_output=True)
        if r.returncode:
            raise At3pError("FFMPEG", r.stderr.decode()[:300])
        return np.frombuffer(r.stdout, dtype="<f4").reshape(-1, 2)


def disc_aus(iso, clip=None, track=0, packs=None):
    import at3p_extract as X
    if clip is None:
        import cosim_golden
        clip = cosim_golden.main_title(iso)[0]
    aus, info, _marks = X.extract(iso, clip, track, packs)
    return clip, aus, info


def check(aus, skip=0, count=None, fixed=False):
    """Decode aus[skip : skip+count] (the decoder starts cold at `skip`, as does ffmpeg
    on the same cut) with the model -- the float path, and with `fixed` also the fixed
    path (tools/at3p_fixed.py) -- and with ffmpeg; returns a stats dict (errors in s16
    LSBs: ffmpeg's float x 32768)."""
    import at3p_extract as X
    sel = aus[skip:skip + count] if count else aus[skip:]
    ref = ffmpeg_f32(X.to_oma(sel))
    if len(ref) != len(sel) * FRAME_SAMPLES:
        raise At3pError("FFMPEG_SAMPLES", "%d samples for %d AUs" % (len(ref), len(sel)))
    dec = Decoder()
    fdec = None
    if fixed:
        import at3p_fixed
        fdec = at3p_fixed.FixedDecoder()
    worst = fworst = 0.0
    sq = fsq = 0.0
    cond = {}
    n = 0
    for k, (_o, _p, fr) in enumerate(sel):
        out = dec.decode(fr)
        r = ref[k * FRAME_SAMPLES:(k + 1) * FRAME_SAMPLES].T.astype(np.float64)
        d = np.abs(out - r)
        worst = max(worst, float(d.max()))
        sq += float((d * d).sum())
        n += d.size
        if fdec is not None:
            fo = fdec.decode(fr)                      # s16 (2, 2048)
            # ffmpeg's float can pass full scale; its own s16 conversion clips there
            fd = np.abs(fo.astype(np.float64) - np.clip(r * 32768.0, -32768.0, 32767.0))
            fworst = max(fworst, float(fd.max()))
            for fl in fdec.flags:
                cond[fl] = max(cond.get(fl, 0.0), float(fd.max()))
            fsq += float((fd * fd).sum())
    st = {"aus": len(sel), "max_lsb": worst * 32768, "rms_lsb": (sq / max(n, 1)) ** 0.5 * 32768,
          "cov": dec.cov, "ref_samples": len(ref),
          "ref_peak": float(np.abs(ref).max()) if len(ref) else 0.0}
    if fdec is not None:
        st["fx_max_lsb"] = fworst
        st["fx_rms_lsb"] = (fsq / max(n, 1)) ** 0.5
        st["fx_sat"] = dict(fdec.sat.n)
        st["fx_cond"] = cond
    return st


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc")
    ap.add_argument("--clip", type=int)
    ap.add_argument("--track", type=int, default=0)
    ap.add_argument("--packs", type=int, default=3000)
    ap.add_argument("--skip", type=int, default=0, help="start at this AU (cold)")
    ap.add_argument("--aus", type=int, help="decode this many AUs")
    ap.add_argument("--check", action="store_true", help="compare with ffmpeg")
    ap.add_argument("--cov", action="store_true", help="print the coverage counters")
    a = ap.parse_args(argv)
    clip, aus, info = disc_aus(a.disc, a.clip, a.track, a.packs)
    print("%s clip %d track %d: %d AUs, params %s" % (os.path.basename(a.disc), clip, a.track,
                                                     len(aus), ",".join("%04x" % p for p in info["params"])))
    if a.check:
        st = check(aus, a.skip, a.aus)
        print("float model vs ffmpeg: %d AUs, max |diff| %.4f LSB, rms %.5f LSB (s16 scale)"
              % (st["aus"], st["max_lsb"], st["rms_lsb"]))
        if a.cov:
            for k in sorted(st["cov"]):
                print("  %-28s %d" % (k, st["cov"][k]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
