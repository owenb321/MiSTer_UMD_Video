#!/usr/bin/env python3
"""Pick the bench windows: the AU index where a short window of a disc's audio exercises
the most synthesis conditions (docs/at3p_decoder.md S4.2) -- tones in both overlap
regions, a gain boost above 2^6, a steep window beside gain points, noise fill in a
swapped subband, an inverted tone phase -- from a fast parse-only scan (tools/at3p_ref.py).

    at3p_pick.py --disc IMAGE.iso [--clip N] [--scan 3000] [--window 3]
Prints "skip conditions...".
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_emu as E  # noqa: E402


def frame_conds(u, prev_tp):
    c = set()
    wi = u.waves_info
    if wi.tones_present and prev_tp:
        c.add("tones_both")
    elif wi.tones_present:
        c.add("tones")
    if wi.tones_present and any(wi.invert_phase[:wi.num_tone_bands]):
        c.add("tone_invert")
    for ch in (0, 1):
        ch_ = u.channels[ch]
        for sb in range(u.num_subbands):
            g = ch_.gain_data[sb]
            if g.num_points:
                if min(g.lev_code[:g.num_points]) <= 2:
                    c.add("gain_boost_big")
                elif min(g.lev_code[:g.num_points]) < 6:
                    c.add("gain_boost")
                if ch_.wnd_shape[sb] or ch_.wnd_shape_prev[sb]:
                    c.add("steep_with_gain")
    for sb in range(u.num_coded_subbands):
        if u.swap_channels[sb]:
            c.add("swap")
            grp = R.T.SUBBAND_TO_POWGRP[sb]
            if any(u.channels[ch].power_levs[grp] != R.POWER_COMP_OFF for ch in (0, 1)):
                c.add("swap_noise")
        if u.negate_coeffs[sb]:
            c.add("negate")
    return c


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--scan", type=int, default=3000)
    ap.add_argument("--window", type=int, default=3)
    a = ap.parse_args(argv)
    clip, aus, _info = R.disc_aus(a.disc, a.clip, 0, None)
    po = E.ParseOnly()
    per = []
    tp_prev = 0
    for k, (_o, _p, fr) in enumerate(aus[:a.scan]):
        units = po.units
        try:
            R.parse_frame(fr, units)
        except R.At3pError:
            per.append(set())
            continue
        u = units[0]
        per.append(frame_conds(u, tp_prev))
        tp_prev = u.waves_info.tones_present
        for c in u.channels:                   # the history swap (as ParseOnly.decode)
            c.wnd_shape, c.wnd_shape_prev = c.wnd_shape_prev, c.wnd_shape
            c.gain_data, c.gain_data_prev = c.gain_data_prev, c.gain_data
            c.tones_info, c.tones_info_prev = c.tones_info_prev, c.tones_info
        u.waves_info, u.waves_info_prev = u.waves_info_prev, u.waves_info
    best = (-1, 0, set())
    for k in range(1, len(per) - a.window):
        cs = set().union(*per[k:k + a.window])
        if len(cs) > best[0]:
            best = (len(cs), k, cs)
    # start one frame early: the window's first frame warms the two-frame histories
    print("%d %s" % (max(0, best[1] - 1), " ".join(sorted(best[2]))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
