#!/usr/bin/env python3
"""What a seek lands on: the video entry points (CLPI EP map) and the chapter marks
(PLAYLIST.UMD) of every disc's main title, measured for the P6b plan
(docs/transport.md; the findings are in docs/umd_video_format.md "Entry points and
marks").

Per main title (the longest playlist, as the core picks it; every item, each on its own
clip -- a mark names its item and lies on that clip's timeline):
  - every video EP entry: the first picture's NAL type (IDR or not), whether the access
    unit repeats the SPS / PPS, and its recovery point SEI (D.2.8: recovery_frame_cnt,
    exact_match_flag, broken_link_flag);
  - the largest gap between IDR entries (a seek that must land on an IDR waits that long);
  - for up to --samples entries, evenly spaced: the LEADING pictures -- those after the
    entry's I picture in decode order with a smaller POC (they precede it in output
    order, so a decode that starts at the entry may lack their references and a
    recovery point with recovery_frame_cnt 0 does not promise them); POC type 0 only;
  - the marks: types, how many are chapters (type 5), whether they are in PTS order,
    and how far each lies after the EP entry at or before it.

    umd_seek_census.py [ISO or directory ...] [--samples N]

With no argument it reads ${UMD_ISO_DIR:-~/umd-isos} (one directory level deep).
"""
import argparse
import bisect
import collections
import glob
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref  # noqa: E402
import psmf_ref  # noqa: E402
import umd_clpi  # noqa: E402
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402
from cabac_ref import BitReader, CabacError  # noqa: E402

SEC = 2048
LEAD_SECTORS = 96          # how far past an entry the leading-picture scan reads


def isos(args):
    roots = args or [os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))]
    out = []
    for r in roots:
        if os.path.isfile(r):
            out.append(r)
            continue
        for p in sorted(glob.glob(os.path.join(r, "*")) + glob.glob(os.path.join(r, "*", "*"))):
            if os.path.isfile(p) and p.lower().endswith(".iso"):
                out.append(p)
    return out


def sei_recovery_point(rbsp):
    """The recovery point SEI (payloadType 6) of one SEI NAL -> (cnt, exact, broken)."""
    p = 0
    while p < len(rbsp) - 1:
        pt = 0
        while rbsp[p] == 0xFF:
            pt += 255
            p += 1
        pt += rbsp[p]
        p += 1
        sz = 0
        while rbsp[p] == 0xFF:
            sz += 255
            p += 1
        sz += rbsp[p]
        p += 1
        if pt == 6:
            br = BitReader(bytes(rbsp[p:p + sz]) + b"\x00")
            cnt = br.ue()
            return cnt, br.read_bit(), br.read_bit()
        p += sz
        if p < len(rbsp) and rbsp[p] == 0x80:
            break
    return None


def entry_head(pl):
    """The access unit at an entry point, up to its first slice -> dict."""
    d = {"sps": False, "pps": False, "rp": None, "idr": None}
    for _ref, t, rbsp in h264_fe_ref.nal_units(pl):
        if t == 7:
            d["sps"] = True
        elif t == 8:
            d["pps"] = True
        elif t == 6 and d["rp"] is None:
            d["rp"] = sei_recovery_point(rbsp)
        elif t in (1, 5):
            d["idr"] = t == 5
            break
    return d


def leading_pictures(es, sps_map, pps_map):
    """Pictures after the first I in decode order whose POC is below it. POC type 0 by
    8.2.1.1 (PicOrderCntMsb from the previous reference picture's; the I's own msb taken
    as 0, which is what a decoder starting there must assume; no MMCO 5 on any disc).
    Fields count one each. Scans until the next I picture. None when not type 0."""
    rec = []
    first = None
    lead = 0
    seen_first = False
    prev = None                           # (msb, lsb) of the previous reference picture
    for ref, t, rbsp in h264_fe_ref.nal_units(es):
        try:
            if t == 7:
                s = h264_fe_ref.parse_sps(rbsp, rec)
                sps_map[s.id] = s
            elif t == 8:
                p = h264_fe_ref.parse_pps(rbsp, sps_map, rec)
                pps_map[p.id] = p
            elif t in (1, 5):
                del rec[:]
                br = BitReader(rbsp)
                h = h264_fe_ref.parse_slice_header(br, t, ref, sps_map, pps_map, rec)
                if h.first_mb != 0:
                    continue
                if h.sps.poc_type != 0:
                    return None
                lsb = [int(r.split()[2]) for r in rec if r.startswith("S pic_order_cnt_lsb ")][0]
                mx = 1 << h.sps.log2_max_poc_lsb
                if not seen_first:
                    if h.slice_type != h264_fe_ref.I:
                        return None
                    first = (lsb, h.field_pic, h.bottom_field)
                    prev = (0, lsb)
                    seen_first = True
                    continue
                if h.slice_type == h264_fe_ref.I and (h.field_pic == 0 or h.bottom_field == first[2]):
                    return lead
                pmsb, plsb = prev
                if lsb < plsb and plsb - lsb >= mx // 2:
                    msb = pmsb + mx
                elif lsb > plsb and lsb - plsb > mx // 2:
                    msb = pmsb - mx
                else:
                    msb = pmsb
                if msb + lsb < first[0]:
                    lead += 1
                if ref:
                    prev = (msb, lsb)
        except (h264_fe_ref.FeError, h264_fe_ref.Refused, CabacError, IndexError, KeyError):
            return None          # a NAL cut by the scan window's end, or not type 0
    return lead


def clip_census(path, clip, samples, r):
    """The EP entries of one clip, accumulated into r. Returns the video EP PTS list."""
    with umd_iso.UmdIso(path) as iso:
        c = umd_clpi.from_iso(iso, clip)
    ents = umd_clpi.video_map(c)
    src = psmf_ref.Source(path, clip)
    sps_map, pps_map = {}, {}
    try:
        # the clip start's parameter sets, for a scan that meets none before its slices
        res = psmf_ref.parse(src.mm, src.start, min(src.end, src.start + 64 * SEC))
        es0, _ = psmf_ref.es(src.mm, res, "video")
        for _ref, t, rbsp in h264_fe_ref.nal_units(es0[:65536]):
            try:
                if t == 7:
                    s = h264_fe_ref.parse_sps(rbsp, [])
                    sps_map[s.id] = s
                elif t == 8:
                    q = h264_fe_ref.parse_pps(rbsp, sps_map, [])
                    pps_map[q.id] = q
            except (h264_fe_ref.FeError, h264_fe_ref.Refused, CabacError):
                pass
        step = max(1, len(ents) // samples) if samples else 0
        idr_pts = []
        for j, (_fl, pts, sec) in enumerate(ents):
            a = src.start + sec * SEC
            if a + SEC > src.end:
                r["kind"]["past the clip"] += 1
                continue
            res = psmf_ref.parse(src.mm, a, min(src.end, a + 2 * SEC))
            hit = [q for q in res.packets if q.sid == 0xE0]
            if not hit:
                r["kind"]["no video PES"] += 1
                continue
            d = entry_head(bytes(src.mm[hit[0].payload_off:hit[0].payload_off + hit[0].payload_len]))
            r["kind"]["IDR" if d["idr"] else "non-IDR I" if d["idr"] is False else "no slice"] += 1
            r["rp"][d["rp"]] += 1
            if not d["sps"]:
                r["no_sps"] += 1
            if d["idr"]:
                idr_pts.append(pts)
            if step and j % step == 0:
                res = psmf_ref.parse(src.mm, a, min(src.end, a + LEAD_SECTORS * SEC))
                es, _ = psmf_ref.es(src.mm, res, "video")
                r["lead"][leading_pictures(es, sps_map, pps_map)] += 1
        gaps = [b - a for a, b in zip(idr_pts, idr_pts[1:])]
        r["idr_gap"] = max([r["idr_gap"]] + [g / 90000.0 for g in gaps])
        eg = [b[1] - a[1] for a, b in zip(ents, ents[1:])]
        r["ep_gap"] = max([r["ep_gap"]] + [g / 90000.0 for g in eg])
        r["entries"] += len(ents)
    finally:
        src.close()
    return [q for _f, q, _s in ents]


def census(path, samples):
    """Every item of the main title. A mark names its item (u16); its PTS is on that
    item's clip's timeline."""
    with umd_iso.UmdIso(path) as iso:
        pl = umd_playlist.from_iso(iso)
    e = pl["playlists"][umd_playlist.main_playlist(pl)]
    items = e["items"]
    r = {"name": os.path.basename(path), "items": len(items), "entries": 0,
         "kind": collections.Counter(), "rp": collections.Counter(), "no_sps": 0,
         "lead": collections.Counter(), "idr_gap": 0.0, "ep_gap": 0.0,
         "multi_item_playlists": sum(1 for q in pl["playlists"] if len(q["items"]) > 1)}
    eps = {}
    for it in items:
        clip = int(it["clip_name"])
        if clip not in eps:
            eps[clip] = clip_census(path, clip, samples, r)
    marks = e["marks"]
    after = []
    for m in marks:
        if m["item"] >= len(items):
            r["kind"]["mark naming no item"] += 1
            continue
        ep = eps[int(items[m["item"]]["clip_name"])]
        k = bisect.bisect_right(ep, m["pts"]) - 1
        if k >= 0:
            after.append((m["pts"] - ep[k]) / 90000.0)
    ch = [m for m in marks if m["type"] == 5]
    r["marks"] = len(marks)
    r["chapters"] = len(ch)
    r["other_marks"] = [(m["type"], m["name"]) for m in marks if m["type"] != 5]
    key = [(m["item"], m["pts"]) for m in marks]
    r["sorted"] = all(a < b for a, b in zip(key, key[1:]))
    r["first_chapter"] = min(((m["item"], (m["pts"] - items[m["item"]]["in_pts"]) / 90000.0)
                              for m in ch if m["item"] < len(items)), default=None)
    r["mark_after_ep"] = max(after) if after else 0.0
    return r


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*")
    ap.add_argument("--samples", type=int, default=64,
                    help="entries per title scanned for leading pictures (0 = none)")
    a = ap.parse_args(argv)
    tot = collections.Counter()
    rps = collections.Counter()
    leads = collections.Counter()
    worst = {"idr_gap": (0, ""), "ep_gap": (0, ""), "mark_after_ep": (0, "")}
    for path in isos(a.paths):
        try:
            r = census(path, a.samples)
        except Exception as ex:          # a damaged rip: report and go on
            print("%-44s ERROR %s" % (os.path.basename(path)[:44], ex), flush=True)
            continue
        tot.update(r["kind"])
        tot["no SPS at the entry"] += r["no_sps"]
        rps.update(r["rp"])
        leads.update(r["lead"])
        for k in worst:
            if r[k] > worst[k][0]:
                worst[k] = (r[k], r["name"])
        tot["main titles"] += 1
        tot["multi-item main titles"] += r["items"] > 1
        tot["multi-item playlists"] += r["multi_item_playlists"]
        print("%-44s items %d EP %5d %-34s IDR gap %6.2f s, EP gap %.2f s | lead %s | marks %d "
              "(chapters %d, first %s, %s, <= %.2f s after an EP) %s%s" % (
                  r["name"][:44], r["items"], r["entries"], dict(r["kind"]), r["idr_gap"],
                  r["ep_gap"], dict(r["lead"]), r["marks"], r["chapters"],
                  "item %d at %.1f s" % r["first_chapter"] if r["first_chapter"] else "none",
                  "sorted" if r["sorted"] else "NOT SORTED", r["mark_after_ep"],
                  "no SPS at %d entries " % r["no_sps"] if r["no_sps"] else "",
                  r["other_marks"] if r["other_marks"] else ""), flush=True)
    print("\nentries: %s" % dict(tot))
    print("recovery point SEI (cnt, exact, broken): %s" % dict(rps))
    print("leading pictures per sampled entry: %s" % dict(sorted(leads.items(), key=str)))
    for k, (v, n) in worst.items():
        print("worst %s: %.2f s (%s)" % (k, v, n))


if __name__ == "__main__":
    main()
