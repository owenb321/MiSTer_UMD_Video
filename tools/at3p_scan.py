#!/usr/bin/env python3
"""Every AU of every audio track in the library, parsed (tools/at3p_ref.py, no
synthesis): the Huffman holes (a code in no codebook: the fabric refuses such a frame,
docs/at3p_decoder.md S3.2), the model's refusals, and the first frame of each track that
uses a rare synthesis mode the bench windows may miss -- a tone envelope's start point or
stop point, an inverted tone phase (stereo, a band flagged and waves in it).

    UMD_ISO_DIR=... at3p_scan.py [paths...] [--jobs 6] [--tsv out.tsv]
Prints per-track rows and the totals; the rare modes' first frames (disc, clip, track,
AU) are what bench/umd/run_at3p.sh's arms are cut from.
"""
import argparse
import multiprocessing as mp
import os
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402

MODES = ("env_start", "env_stop", "tone_invert")


def track_list(path):
    import umd_clpi
    import umd_iso
    import psmf_ref
    out = []
    with umd_iso.UmdIso(path) as iso:
        clips = iso.clips()
    for clip in clips:
        if umd_clpi.zero_fraction(path, clip) > 0.05:
            continue
        src = psmf_ref.Source(path, clip)
        try:
            r = psmf_ref.parse(src.mm, src.start, src.end)
            tracks = sorted(set(p.sub for p in r.packets if p.kind == "audio"))
        finally:
            src.close()
        out += [(path, clip, t) for t in tracks]
    return out


def holes_total():
    return sum(v.holes for v in R.VLC["wl"] + R.VLC["ct"] + R.VLC["sf"] + R.VLC["gain"]
               + R.VLC["tone"] + R.VLC["spec"])


def scan_track(args):
    path, clip, track = args
    try:
        _c, aus, _info = R.disc_aus(path, clip, track, None)
        units = [R.ChannelUnit()]
        h0 = holes_total()
        first = {}
        errs = 0
        for k, (_o, _p, fr) in enumerate(aus):
            try:
                R.parse_frame(fr, units)
            except R.At3pError:
                errs += 1
                continue
            u = units[0]
            wi = u.waves_info
            if wi.tones_present:
                for ch in (0, 1):
                    for sb in range(wi.num_tone_bands):
                        t = u.channels[ch].tones_info[sb]
                        if not t.num_wavs:
                            continue
                        if t.pend_env.has_start_point and "env_start" not in first:
                            first["env_start"] = k
                        if t.pend_env.has_stop_point and "env_stop" not in first:
                            first["env_stop"] = k
                        if ch == 1 and wi.invert_phase[sb] and "tone_invert" not in first:
                            first["tone_invert"] = k
            for c in u.channels:
                c.wnd_shape, c.wnd_shape_prev = c.wnd_shape_prev, c.wnd_shape
                c.gain_data, c.gain_data_prev = c.gain_data_prev, c.gain_data
                c.tones_info, c.tones_info_prev = c.tones_info_prev, c.tones_info
            u.waves_info, u.waves_info_prev = u.waves_info_prev, u.waves_info
        return (path, clip, track, len(aus), errs, holes_total() - h0, first, None)
    except Exception:
        return (path, clip, track, 0, 0, 0, {}, traceback.format_exc().strip().splitlines()[-1])


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--tsv")
    a = ap.parse_args(argv)
    import umd_census
    isos = umd_census.gather(a.paths)
    if not isos:
        print("at3p_scan: SKIP (no images)")
        return 2
    with mp.Pool(a.jobs) as pool:
        tracks = [t for tl in pool.map(track_list, isos) for t in tl]
        rows = []
        for r in pool.imap_unordered(scan_track, tracks):
            rows.append(r)
            print("%-44s clip %3d tr %2d %7d AUs  refused %d  holes %d  %s%s" % (
                os.path.basename(r[0])[:44], r[1], r[2], r[3], r[4], r[5],
                " ".join("%s@%d" % kv for kv in sorted(r[6].items())),
                ("  ERROR " + r[7]) if r[7] else ""), flush=True)
    rows.sort(key=lambda r: (r[0], r[1], r[2]))
    if a.tsv:
        with open(a.tsv, "w") as f:
            f.write("disc\tclip\ttrack\taus\trefused\tholes\t%s\n" % "\t".join(MODES))
            for r in rows:
                f.write("\t".join([os.path.basename(r[0]), str(r[1]), str(r[2]), str(r[3]),
                                   str(r[4]), str(r[5])] + [str(r[6].get(m, "")) for m in MODES]) + "\n")
    n = sum(r[3] for r in rows)
    print("\n%d tracks, %d AUs: refused %d, Huffman holes %d, errors %d" % (
        len(rows), n, sum(r[4] for r in rows), sum(r[5] for r in rows),
        sum(1 for r in rows if r[7])))
    for m in MODES:
        hits = [r for r in rows if m in r[6]]
        print("%-12s %d tracks; first: %s" % (m, len(hits), (
            "%s clip %d tr %d AU %d" % (os.path.basename(hits[0][0]), hits[0][1], hits[0][2], hits[0][6][m]))
            if hits else "NONE in the library"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
