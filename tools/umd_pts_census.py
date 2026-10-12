#!/usr/bin/env python3
"""umd_pts_census.py -- every PES PTS of a disc's main title against the pic_struct timeline
(fix/film-timing, docs/display.md S10): the evidence for the display's lone-PTS rule.

The display (umd/disp_sched.sv, tools/disp_sched_ref.py) times the pictures between two
time stamps by their durations (Table E-6: pic_struct x the VUI tick). This tool does the
same over a whole clip, header-only (no macroblock decode): each picture's PTS by the
position rule of ISO/IEC 13818-1 2.4.3.7 (tools/h264_fe_ref.decode_stream's), its pic_struct
from its picture timing SEI, the output order as (IDR period, POC) (POC type 0; field pairs
one store, as recon_out emits them), and at every tagged store the difference between its
PTS and the time extrapolated from the previous tag. A difference over 2 ticks of 90 kHz
is a DISAGREEMENT; one followed within 60 stores by the opposite one (the next tag back on
the old timeline) is a LONE PTS -- the discs' authoring defect the film gate found (Akira:
three, +7 / +8 / +8 field ticks, the three rig points). Anything else is a SHIFT (a real
change of timeline).

    umd_pts_census.py IMAGE [IMAGE...] [-j 4]    (default: every image under $UMD_ISO_DIR)

Prints one line per disc and the census: lone PTS by sign and size in ticks, the closest
two on one disc (the rule believes the tag after a disbelieved one: two lone PTS within a
tag of each other would defeat it), and every shift. ~1 min per film.
"""
import argparse
import collections
import glob
import os
import sys
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

DEF_TICK = 1501.5                         # 1/59.94 s in 90 kHz: no VUI timing
DIV = {0: 2, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 6}


def stores(disc, clip):
    """[(key, duration in 90 kHz, tick, PTS or None)] in output order."""
    import h264_fe_ref as FE
    import psmf_ref
    src = psmf_ref.Source(disc, clip)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end, keep=True)
        data, marks = psmf_ref.es(src.mm, r, "video")
    finally:
        src.close()
    marks = [(o, p) for (o, p, _d, _f) in marks if p is not None]
    sps_map, pps_map = {}, {}
    au_pos, vcl_last, pt, mi = None, True, None, 0
    pics = []
    prev_ref, period = (0, 0), 0
    for pos, ref_idc, ntype, rbsp in FE.nal_units_pos(data):
        if ntype in FE.AU_OPENERS and vcl_last:
            au_pos, vcl_last, pt = pos - 3, False, None
        if ntype == 6:
            touched, got, _bad = FE.sei_pic_timing(rbsp)
            if touched:
                pt = got
        if ntype == 7:
            s = FE.parse_sps(rbsp, [])
            sps_map[s.id] = s
        elif ntype == 8:
            p = FE.parse_pps(rbsp, sps_map, [])
            pps_map[p.id] = p
        elif ntype in (1, 5):
            rec = []
            try:
                h = FE.parse_slice_header(FE.BitReader(rbsp), ntype, ref_idc, sps_map, pps_map, rec)
            except Exception as e:           # a damaged rip's tail: the census stops there
                print("  %s: stopped at ES byte %d: %s" % (os.path.basename(disc), pos, e), file=sys.stderr)
                break
            vcl_last = True
            if h.first_mb != 0:
                continue
            if au_pos is None:
                au_pos = pos - 3
            prec = []
            if pt is not None:
                FE.interpret_pic_timing(pt, h.sps, h.field_pic, h.bottom_field, prec,
                                        {"pt_seen": 0, "pt_missing": 0, "pt_short": 0, "pt_struct": 0})
            pt = None
            tag = None
            while mi < len(marks) and marks[mi][0] <= au_pos:
                tag = marks[mi][1]
                mi += 1
            au_pos = None
            d = dict(x.split()[1:] for x in prec)
            f = dict(x.split()[1:] for x in rec)
            if h.sps.poc_type != 0:
                raise SystemExit("%s: POC type %d (only type 0 is modelled here)" % (disc, h.sps.poc_type))
            lsb, mx = int(f["pic_order_cnt_lsb"]), 1 << h.sps.log2_max_poc_lsb
            if h.idr:
                period, prev_ref = period + 1, (0, 0)
            pm, pl = prev_ref
            msb = pm + mx if (lsb < pl and pl - lsb >= mx // 2) else pm - mx if (lsb > pl and lsb - pl > mx // 2) else pm
            if ref_idc:
                prev_ref = (msb, lsb)
            tk = 90000.0 * h.sps.num_units_in_tick / h.sps.time_scale if h.sps.timing_info_present else DEF_TICK
            pics.append((h.field_pic, h.bottom_field, h.frame_num, int(d["pic_struct"]) if "pic_struct" in d else None,
                         tag, (period, msb + lsb), tk))
    st, i = [], 0
    while i < len(pics):
        fld, bot, fn, ps, tag, key, tk = pics[i]
        if fld and i + 1 < len(pics) and pics[i + 1][0] and pics[i + 1][2] == fn and pics[i + 1][1] != bot:
            tag2, key2 = pics[i + 1][4], pics[i + 1][5]
            # a pair tagged only on its second field: that PTS minus one tick (display.md S7)
            t = tag if tag is not None else (tag2 - int(tk) if tag2 is not None else None)
            st.append((min(key, key2), 2 * tk, tk, t))
            i += 2
            continue
        st.append((key, (1 if fld else DIV.get(ps, 2)) * tk, tk, tag))
        i += 1
    st.sort(key=lambda s: s[0])
    return st


def census(disc):
    import cosim_golden
    clip = cosim_golden.main_title(disc)[0]
    st = stores(disc, clip)
    t, ev, tagged = None, [], 0
    for k, (_key, dur, tk, tag) in enumerate(st):
        if tag is not None:
            tagged += 1
            if t is not None and abs(tag - t) > 2:
                ev.append((k, tag, tag - t, tk))
            t = tag
        if t is not None:
            t += dur
    lone, shift, i = [], [], 0
    while i < len(ev):
        k, tag, d, tk = ev[i]
        if i + 1 < len(ev) and abs(ev[i + 1][2] + d) < 3 and ev[i + 1][0] - k < 60:
            lone.append((k, tag, d, tk))
            i += 2
        else:
            shift.append((k, tag, d, tk))
            i += 1
    return os.path.basename(disc), clip, len(st), tagged, lone, shift


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("-j", type=int, default=4)
    a = ap.parse_args(argv)
    imgs = a.images or sorted(p for p in glob.glob(os.path.join(
        os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos")), "**", "*"), recursive=True)
        if p.lower().endswith(".iso"))
    if not imgs:
        print("SKIP: no disc images (set UMD_ISO_DIR)")
        return 2
    tot = collections.Counter()
    sizes = collections.Counter()
    closest, shifts = [], []
    with ProcessPoolExecutor(a.j) as ex:
        for name, clip, n, tagged, lone, shift in ex.map(census, imgs):
            tot["discs"] += 1
            tot["stores"] += n
            tot["tagged"] += tagged
            tot["with lone PTS"] += bool(lone)
            print("%-60s clip %d: %6d stores, %5d tagged, %d lone PTS, %d shifts" %
                  (name[:60], clip, n, tagged, len(lone), len(shift)))
            for k, tag, d, tk in lone:
                sizes[("+" if d > 0 else "-", int(round(abs(d) / tk)), round(tk, 1))] += 1
                print("    lone  store %6d  PTS %10.4f s  %+.2f ticks of %.1f" % (k, tag / 90000.0, d / tk, tk))
            for x, y in zip(lone, lone[1:]):
                closest.append((y[0] - x[0], name))
            for k, tag, d, tk in shift:
                shifts.append((name, k, tag / 90000.0, d / tk))
    print("\n%(discs)d discs, %(stores)d stores, %(tagged)d tagged; %(with lone PTS)d with a lone PTS" % tot)
    print("lone PTS by sign, size (ticks), tick:", ", ".join("%s%d@%.1f: %d" % (s, m, t, c)
                                                            for (s, m, t), c in sorted(sizes.items())))
    print("closest two on one disc (stores):", sorted(closest)[:3])
    print("shifts: %d" % len(shifts))
    for s in shifts:
        print("    %s store %d PTS %.4f s %+.2f ticks" % s)
    return 0


if __name__ == "__main__":
    sys.exit(main())
