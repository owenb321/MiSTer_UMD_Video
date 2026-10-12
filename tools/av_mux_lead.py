#!/usr/bin/env python3
"""The audio lead over video in each clip's multiplex: how far ahead of the video the
demux delivers the audio, as time and as audio bytes -- the input that sizes the
compressed-audio ring in front of the ATRAC3plus decoder (docs/at3p_decoder.md S7).

At every audio PES carrying a PTS, lead = that PTS - the newest video decode time seen
so far in the stream (DTS, else PTS). A positive lead is audio the demux hands over
before the video of the same moment: it waits in the ring while the video pipeline
catches up. The bytes column is the audio payload delivered between the video decode
time and the audio PTS at that point (what the ring holds for the lead alone, before
the video pipeline's own depth is added).

    UMD_ISO_DIR=... av_mux_lead.py [paths...] [--jobs 6]
"""
import argparse
import multiprocessing as mp
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def clip_list(path):
    import umd_clpi
    import umd_iso
    with umd_iso.UmdIso(path) as iso:
        clips = iso.clips()
    return [(path, c) for c in clips if umd_clpi.zero_fraction(path, c) <= 0.05]


def scan_clip(args):
    import psmf_ref
    path, clip = args
    src = psmf_ref.Source(path, clip)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
    except Exception as e:  # a damaged rip: reported, not fatal
        src.close()
        return (path, clip, None, str(e))
    src.close()
    track = min((p.sub for p in r.packets if p.kind == "audio"), default=None)
    if track is None:
        return (path, clip, None, "no audio")
    vt = None                       # newest video decode time
    hist = []                       # (audio pts, cumulative audio bytes at that PES)
    abytes = 0
    lead_max, lead_min, bytes_max, n = None, None, 0, 0
    for p in r.packets:
        if p.kind == "video" and (p.dts is not None or p.pts is not None):
            t = p.dts if p.dts is not None else p.pts
            vt = t if vt is None else max(vt, t)
        elif p.kind == "audio" and p.sub == track:
            if p.pts is not None:
                hist.append((p.pts, abytes))
                if vt is not None:
                    lead = p.pts - vt
                    n += 1
                    lead_max = lead if lead_max is None else max(lead_max, lead)
                    lead_min = lead if lead_min is None else min(lead_min, lead)
                    if lead > 0:
                        # audio bytes delivered since the PES whose PTS was <= vt
                        lo = abytes
                        for ap, ab in reversed(hist):
                            if ap <= vt:
                                lo = ab
                                break
                            lo = ab
                        bytes_max = max(bytes_max, abytes - lo)
            abytes += p.payload_len
    return (path, clip, (n, lead_min, lead_max, bytes_max, abytes), None)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--jobs", type=int, default=6)
    a = ap.parse_args(argv)
    paths = a.paths
    if not paths:
        d = os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))
        for root, _dirs, files in os.walk(d):
            paths += [os.path.join(root, f) for f in sorted(files)
                      if f.lower().endswith(".iso")]
    jobs = []
    for p in sorted(paths):
        try:
            jobs += clip_list(p)
        except Exception as e:
            print("SKIP %s: %s" % (os.path.basename(p), e))
    with mp.Pool(a.jobs) as pool:
        rows = pool.map(scan_clip, jobs)
    worst_t, worst_b = None, None
    for path, clip, res, err in rows:
        name = "%s clip %d" % (os.path.basename(path), clip)
        if res is None:
            print("%-60s %s" % (name, err))
            continue
        n, lmin, lmax, bmax, ab = res
        if n == 0:
            print("%-60s no audio PTS after a video time" % name)
            continue
        print("%-60s %6d PES  lead %+8.3f .. %+8.3f s  lead bytes max %7d" %
              (name, n, lmin / 90000.0, lmax / 90000.0, bmax))
        if worst_t is None or lmax > worst_t[0]:
            worst_t = (lmax, name)
        if worst_b is None or bmax > worst_b[0]:
            worst_b = (bmax, name)
    if worst_t:
        print("WORST lead %+.3f s (%s); WORST lead bytes %d (%s)" %
              (worst_t[0] / 90000.0, worst_t[1], worst_b[0], worst_b[1]))


if __name__ == "__main__":
    main()
