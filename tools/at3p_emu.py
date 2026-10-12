#!/usr/bin/env python3
"""Score the microcode (umd/at3p/at3p.uasm, run by tools/at3p_isa.py's emulator) against
the models, AU by AU in lockstep (docs/at3p_decoder.md S3.4):

  * the PARSE RECORD at the `mark M_PARSED` of every frame, field by field, against
    at3p_ref's parse state (stale entries included: both keep what a frame leaves);
  * the PCM of every frame, word for word, against at3p_fixed.FixedDecoder;
  * the cycles a frame (the emulator's count: one per instruction, plus each vector
    op's and Huffman read's own), against the 1,152,000 budget at 27 MHz.

    at3p_emu.py --disc IMAGE.iso [--clip N] [--track T] [--skip N] [--aus N]
Exit 0 when every frame matches.
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_fixed as F  # noqa: E402
import at3p_isa as I  # noqa: E402

BUDGET = 27000000 * 2048 // 48000


def _asm_consts():
    """The .equ values of the program (the record layout)."""
    text = I.read_source(I.UASM)
    out = {}
    for line in text.splitlines():
        line = line.split(";")[0].strip()
        if line.startswith(".equ"):
            _, n, v = line.split(None, 2)
            out[n] = int(eval(v, {"__builtins__": {}}, dict(out)))
    return out


C = _asm_consts()


def snapshot_ref(u):
    """at3p_ref's parse state after parse_frame (before synthesis and the swap)."""
    s = {"unit": (u.num_quant_units, u.mute_flag, u.used_quant_units, u.num_subbands,
                  u.num_coded_subbands),
         "swap": list(u.swap_channels), "neg": list(u.negate_coeffs)}
    if u.used_quant_units:
        s["full"] = u.use_full_table
    for ch in (0, 1):
        c = u.channels[ch]
        s["wl%d" % ch] = list(c.qu_wordlen)
        s["sf%d" % ch] = list(c.qu_sf_idx)
        s["tab%d" % ch] = list(c.qu_tab_idx)
        s["pwr%d" % ch] = list(c.power_levs)
        s["wnd%d" % ch] = list(c.wnd_shape)
        s["ngs%d" % ch] = c.num_gain_subbands
        s["gain%d" % ch] = [(g.num_points, g.lev_code[:g.num_points], g.loc_code[:g.num_points])
                            for g in c.gain_data]
        s["tone%d" % ch] = [((t.pend_env.has_start_point, t.pend_env.start_pos,
                              t.pend_env.has_stop_point, t.pend_env.stop_pos),
                             t.num_wavs, t.start_index) for t in c.tones_info]
        spec = []
        for qu in range(u.used_quant_units):
            if c.qu_wordlen[qu]:
                p0, p1 = R.T.QU_TO_SPEC_POS[qu], R.T.QU_TO_SPEC_POS[qu + 1]
                spec.append((qu, c.spectrum[p0:p1]))
        s["spec%d" % ch] = spec
    wi = u.waves_info
    s["tp"] = wi.tones_present
    if wi.tones_present:
        s["tones"] = (wi.amplitude_mode, wi.num_tone_bands, wi.tones_index)
        n = wi.num_tone_bands
        s["share"] = list(wi.tone_sharing[:n])
        s["master"] = list(wi.tone_master[:n])
        s["inv"] = list(wi.invert_phase[:n])
        s["waves"] = [(w.freq_index, w.amp_sf, w.phase_index) for w in wi.waves]
    return s


def snapshot_emu(m):
    """The same fields read out of the machine's record RAM."""
    rec = [I.s16(v) for v in m.rec]
    cb = rec[C["CURB"]]
    s = {"unit": tuple(rec[C[k]] for k in ("U_NQU", "U_MUTE", "U_USED", "U_NSB", "U_NCSB")),
         "swap": rec[C["SWAP"]:C["SWAP"] + 16], "neg": rec[C["NEG"]:C["NEG"] + 16]}
    used = rec[C["U_USED"]]
    if used:
        s["full"] = rec[C["U_FULL"]]
    for ch in (0, 1):
        b = ch * 0x80
        s["wl%d" % ch] = rec[b + C["WL"]:b + C["WL"] + 32]
        s["sf%d" % ch] = rec[b + C["SF"]:b + C["SF"] + 32]
        s["tab%d" % ch] = rec[b + C["TAB"]:b + C["TAB"] + 32]
        s["pwr%d" % ch] = rec[b + C["PWR"]:b + C["PWR"] + 5]
        s["wnd%d" % ch] = rec[cb + C["B_WND"] + ch * 16:cb + C["B_WND"] + ch * 16 + 16]
        s["ngs%d" % ch] = rec[b + C["NGS"]]
        g = []
        for sb in range(16):
            a = cb + C["B_GAIN"] + ch * 0x80 + sb * 8
            n = rec[a]
            pts = [rec[a + 1 + i] & 0xFFFF for i in range(n)]
            g.append((n, [p & 15 for p in pts], [I.s16(p) >> 4 for p in pts]))
        s["gain%d" % ch] = g
        t = []
        for sb in range(16):
            a = cb + C["B_TONE"] + ch * 160 + sb * 10
            t.append(((rec[a], rec[a + 1], rec[a + 2], rec[a + 3]), rec[a + 8], rec[a + 9]))
        s["tone%d" % ch] = t
        spec = []
        wl = s["wl%d" % ch]
        for qu in range(used):
            if wl[qu]:
                p0, p1 = R.T.QU_TO_SPEC_POS[qu], R.T.QU_TO_SPEC_POS[qu + 1]
                src = 0 if (ch == 1 and rec[C["COPY"] + qu]) else ch
                spec.append((qu, m.spec[src * 2048 + p0:src * 2048 + p1]))
        s["spec%d" % ch] = spec
    s["tp"] = rec[cb + C["B_TP"]]
    if s["tp"]:
        n = rec[cb + C["B_NTB"]]
        s["tones"] = (rec[cb + C["B_AM"]], n, rec[cb + C["B_TIDX"]])
        s["share"] = rec[cb + C["B_SHARE"]:cb + C["B_SHARE"] + n]
        s["master"] = rec[cb + C["B_MAST"]:cb + C["B_MAST"] + n]
        s["inv"] = rec[cb + C["B_INV"]:cb + C["B_INV"] + n]
        w = []
        for i in range(48):
            a = cb + C["B_WAVES"] + 2 * i
            w.append((rec[a] & 0x3FF, rec[a + 1], (rec[a] >> 10) & 31))
        s["waves"] = w
    return s


def diff(a, b):
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append(k)
    return out


class ParseOnly:
    """The model's parse and its history swaps, no synthesis (for check(parse_only))."""

    def __init__(self):
        self.units = [R.ChannelUnit()]
        self.cov = {}

    def decode(self, frame):
        blocks, _bs = R.parse_frame(frame, self.units, self.cov)
        if blocks:
            u = self.units[0]
            for c in u.channels:
                c.wnd_shape, c.wnd_shape_prev = c.wnd_shape_prev, c.wnd_shape
                c.gain_data, c.gain_data_prev = c.gain_data_prev, c.gain_data
                c.tones_info, c.tones_info_prev = c.tones_info_prev, c.tones_info
            u.waves_info, u.waves_info_prev = u.waves_info_prev, u.waves_info
        return None


def check(aus, verbose=True, max_report=3, parse_only=False):
    """Run the machine and the models over a list of (offset, params, frame). Returns a
    stats dict; st['bad'] lists the mismatching frames. parse_only scores the parse
    record alone (the vector ops cost cycles and compute nothing: fast)."""
    words, labels, _ = I.load_program()
    m = I.Machine(words, labels, fast=parse_only)
    fd = ParseOnly() if parse_only else F.FixedDecoder()
    snaps = {}
    _pf = R.parse_frame

    def pf(frame, units, cov=None):
        r = _pf(frame, units, cov)
        snaps["ref"] = snapshot_ref(units[0])
        return r
    st = {"frames": 0, "bad": [], "cycles": [], "reports": []}
    cur = {}

    def hook(mach, mk):
        if mk == C["M_PARSED"]:
            cur["emu"] = snapshot_emu(mach)
            cur["cyc_parse"] = mach.cycles - cur["c0"]
    m.mark_hook = hook
    R.parse_frame = pf
    F.R.parse_frame = pf
    try:
        for k, (_o, prm, fr) in enumerate(aus):
            ref_pcm = fd.decode(fr)
            cur.clear()
            cur["c0"] = m.cycles
            n0 = len(m.pcm)
            hdr = bytes([0x0F, 0xD0, prm >> 8, prm & 0xFF, 0, 0, 0, 0])
            m.feed(hdr + bytes(fr))
            r = m.run()
            assert r == "need_input"
            problems = []
            if "emu" not in cur:
                problems.append("no M_PARSED (errors %s)" % m.errors)
            else:
                d = diff(snaps["ref"], cur["emu"])
                if d:
                    problems.append("record: %s" % " ".join(d))
            if len(m.pcm) != n0 + 1:
                problems.append("%d PCM frames" % (len(m.pcm) - n0))
            elif not parse_only:
                got = np.array(m.pcm[-1])
                if not np.array_equal(got, ref_pcm):
                    e = np.abs(got - ref_pcm)
                    problems.append("PCM: %d samples differ, max %d" % (int((e > 0).sum()), int(e.max())))
            st["cycles"].append((cur.get("cyc_parse", 0), m.cycles - cur["c0"]))
            st["frames"] += 1
            if problems:
                st["bad"].append(k)
                if len(st["reports"]) < max_report:
                    rep = "AU %d: %s" % (k, "; ".join(problems))
                    if "emu" in cur and verbose:
                        for key in diff(snaps["ref"], cur["emu"])[:4]:
                            rep += "\n    %s ref %s\n    %s emu %s" % (
                                key, str(snaps["ref"].get(key))[:200], key,
                                str(cur["emu"].get(key))[:200])
                    st["reports"].append(rep)
    finally:
        R.parse_frame = _pf
        F.R.parse_frame = _pf
    st["errors"] = dict(m.errors)
    st["sat"] = dict(m.sat.n)
    return st


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--track", type=int, default=0)
    ap.add_argument("--packs", type=int)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--aus", type=int, default=16)
    ap.add_argument("--parse-only", action="store_true")
    a = ap.parse_args(argv)
    clip, aus, _info = R.disc_aus(a.disc, a.clip, a.track, a.packs)
    sel = aus[a.skip:a.skip + a.aus]
    st = check(sel, parse_only=a.parse_only)
    for r in st["reports"]:
        print(r)
    cyc = st["cycles"]
    worst = max(c[1] for c in cyc) if cyc else 0
    print("%s clip %d AUs %d..%d: %d frames, %d mismatching; cycles a frame: parse avg %d, "
          "total avg %d, worst %d (%.0f %% of the 27 MHz budget); errors %s" % (
              os.path.basename(a.disc), clip, a.skip, a.skip + len(sel), st["frames"],
              len(st["bad"]), sum(c[0] for c in cyc) // max(1, len(cyc)),
              sum(c[1] for c in cyc) // max(1, len(cyc)), worst, 100.0 * worst / BUDGET,
              st["errors"] or "none"))
    return 0 if not st["bad"] else 1


if __name__ == "__main__":
    sys.exit(main())
