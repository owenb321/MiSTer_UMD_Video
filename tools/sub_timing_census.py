#!/usr/bin/env python3
"""Subtitle timing across the disc library -- what sizes the P7 unit queue and the plane
buffering (docs/subtitles.md §1).

The demultiplexer hands subtitle bytes over with no back-pressure (ps_demux `sp_*`), and
a unit arrives in the stream before its PTS. How far before, and how many units (and
bytes) are in flight at once, decide how big the compressed-unit queue must be. Per
clip, per subtitle substream:

  * lead      = unit PTS - SCR of the pack carrying its first byte (90 kHz)
  * in flight = units that have ARRIVED (SCR <= t + L) and not yet ENDED (PTS + duration
    > t), maximised over t, for a demux running L ahead of the clock
    (L = 0, 0.5, 1, 2, 5 s): unit count and compressed bytes
  * gap       = the smallest PTS step between consecutive units (the decode budget)
  * overlap   = units whose display intervals intersect (more than one on screen)

    UMD_ISO_DIR=... sub_timing_census.py [images...] [--jobs N] [--json out.json]
"""
import argparse
import json
import multiprocessing
import os
import struct
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SEC = 2048
LEADS = (0, 45000, 90000, 180000, 450000)          # 0, 0.5, 1, 2, 5 s
MAGIC = b"0088"


def scr_at(mm, off):
    """The SCR base of the pack header at `off` (MPEG-2 pack, ISO 13818-1 2.5.3.4)."""
    b = mm[off + 4:off + 9]
    return (((b[0] >> 3) & 7) << 30 | (b[0] & 3) << 28 | b[1] << 20 | (b[2] >> 3) << 15 |
            (b[2] & 3) << 13 | b[3] << 5 | b[4] >> 3)


def units_with_scr(src, packets, sub):
    """-> [(pts, duration, scr_first, nbytes)] of one substream (umd_sub_extract's rules)."""
    out = []
    cur = None
    for p in packets:
        if p.kind != "sub" or p.sub != sub:
            continue
        pl = bytes(src.mm[p.payload_off:p.payload_off + p.payload_len])
        pack = src.start + ((p.offset - src.start) // SEC) * SEC
        if p.pts is not None and len(pl) >= 20 and pl[4:8] == MAGIC:
            ln, = struct.unpack(">I", pl[0:4])
            dur, = struct.unpack(">I", pl[8:12])
            cur = {"pts": p.pts, "dur": dur, "scr": scr_at(src.mm, pack), "need": ln + 4, "got": len(pl)}
        elif cur is not None:
            cur["got"] += len(pl)
        else:
            continue
        if cur["got"] >= cur["need"]:
            out.append((cur["pts"], cur["dur"], cur["scr"], cur["need"]))
            cur = None
    return out


def in_flight(units, lead):
    """max over t of (count, bytes) of units arrived (scr <= t + lead) and not ended."""
    ev = []
    for pts, dur, scr, n in units:
        a = scr - lead                          # arrives at t = a
        e = pts + dur                           # leaves at t = e
        if e <= a:
            continue
        ev.append((a, 1, n))
        ev.append((e, -1, -n))
    ev.sort(key=lambda x: (x[0], x[1]))         # leave before arrive at the same tick
    c = b = mc = mb = 0
    for _, dc, db in ev:
        c += dc
        b += db
        mc, mb = max(mc, c), max(mb, b)
    return mc, mb


def one(img):
    import psmf_ref
    import umd_iso
    try:
        iso = umd_iso.UmdIso(img)
        clips = iso.clips()
        iso.close()
        res = []
        for n in clips:
            src = psmf_ref.Source(img, n)
            try:
                r = psmf_ref.parse(src.mm, src.start, src.end)
                for s in sorted(set(p.sub for p in r.packets if p.kind == "sub")):
                    us = units_with_scr(src, r.packets, s)
                    if not us:
                        continue
                    leads = [pts - scr for pts, _, scr, _ in us]
                    ptss = sorted(u[0] for u in us)
                    gaps = [b - a for a, b in zip(ptss, ptss[1:])]
                    srt = sorted(us)
                    overlap = sum(1 for a, b in zip(srt, srt[1:]) if a[0] + a[1] > b[0])
                    row = {"clip": n, "sub": s, "units": len(us),
                           "lead_min": min(leads), "lead_max": max(leads),
                           "gap_min": min(gaps) if gaps else None,
                           "overlap": overlap,
                           "max_unit": max(u[3] for u in us)}
                    for L in LEADS:
                        c, b = in_flight(us, L)
                        row["fl%d" % L] = (c, b)
                    res.append(row)
            finally:
                src.close()
        return img, res, None
    except Exception:
        return img, None, traceback.format_exc()[-600:]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("images", nargs="*")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--json")
    a = ap.parse_args(argv)
    imgs = a.images
    if not imgs:
        root = os.path.expanduser(os.environ.get("UMD_ISO_DIR", "~/umd-isos"))
        imgs = sorted(os.path.join(dp, f) for dp, _, fs in os.walk(root) for f in fs
                      if f.lower().endswith(".iso"))
    allrows = {}
    rc = 0
    with multiprocessing.Pool(a.jobs) as pool:
        for img, rows, tb in pool.imap_unordered(one, imgs):
            name = os.path.basename(img)
            if tb:
                print("[err] %s\n%s" % (name, tb))
                rc = 1
                continue
            allrows[name] = rows
    tot = [r for rows in allrows.values() for r in rows]
    print("tracks with units: %d over %d images" % (len(tot), sum(1 for v in allrows.values() if v)))
    if tot:
        def worst(key, f=max):
            r = f(tot, key=lambda r: r[key] if r[key] is not None else 10 ** 12)
            name = next(n for n, rows in allrows.items() if r in rows)
            return r[key], "%s clip %d sub %02x" % (name, r["clip"], r["sub"])
        print("lead (PTS - SCR at the unit's first pack): min %s (%s), max %s (%s) ticks" %
              (worst("lead_min", min) + worst("lead_max")))
        print("smallest PTS gap: %s (%s)" % worst("gap_min", min))
        print("largest unit: %s bytes (%s)" % worst("max_unit"))
        print("overlapping display intervals: %d" % sum(r["overlap"] for r in tot))
        for L in LEADS:
            k = "fl%d" % L
            r = max(tot, key=lambda r: (r[k][1], r[k][0]))
            rc_ = max(tot, key=lambda r: r[k][0])
            print("demux %4.1f s ahead: in flight at most %d units (%s), %d bytes (%s)" %
                  (L / 90000.0, rc_[k][0], next(n for n, rows in allrows.items() if rc_ in rows),
                   r[k][1], next(n for n, rows in allrows.items() if r in rows)))
    if a.json:
        with open(a.json, "w") as f:
            json.dump(allrows, f, indent=1)
    return rc


if __name__ == "__main__":
    sys.exit(main())
