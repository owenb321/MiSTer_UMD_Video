#!/usr/bin/env python3
"""P6b0 (docs/transport.md S5): the navigation model and the recovery-point start.

  nav     tools/umd_nav_ref.py on hand-built titles, the expectations written from the
          format and the PSP's measured behaviour (docs/transport.md S2.4-S2.7), not from
          the model: the EP lookup's edges, chapters ordered by (item, PTS) whatever the
          table order, Endmarks ignored, Next past the last (None: the PSP's message),
          Prev's 1 s rule and its edge, a burst of presses, IN / OUT, the time across
          items, the trick-play hops.
  x264    (SKIP without ffmpeg's libx264) an open-GOP clip whose second I picture is not
          an IDR and has leading B pictures:
          - cut AT that I, the model's recovery-point start (h264_recon_ref, rp_start)
            skips the leading pictures (as many as umd_seek_census's own POC scan counts),
            ignores x264's MMCO naming a picture from before the entry, and is
            bit-exact with ffmpeg on the same bytes;
          - without the start armed, the model refuses the cut (the frame_num gap) -- the
            arm is what makes it decodable;
          - a DISCONTINUITY: the clip's first frames, then the cut with its parameter sets
            STRIPPED (kept from before, as a seek must), the waiting stores dropped: the
            output == ffmpeg's first frames of the head (those emitted before the seek)
            followed by ffmpeg's decode of the cut.
"""
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_nav_ref as N  # noqa: E402
import disp_sched_ref as DS  # noqa: E402

Sc = S.Score("test_umd_nav_ref")
T = N.TICKS

print("[nav]")
# one item, entries every 2 s from 1 s (PTS 90000 = 1 s is the clip start on every disc)
ents = [(90000 + 2 * T * k, 100 * k) for k in range(50)]          # pts 1 s .. 99 s, sectors 0 .. 4900
marks = [(5, 0, 90000 + 30 * T), (16, 0, 90000 + 95 * T), (5, 0, 90000),     # TABLE order unsorted;
         (5, 0, 90000 + 61 * T + 45000), (5, 0, 90000 + 10 * T)]              # an Endmark
t = N.Title([(1, 90000, 90000 + 96 * T, ents)], marks)
Sc.check("chapters: the type-5 marks in (item, PTS) order, the Endmark ignored",
         [p for _i, p in t.chapters], [90000, 90000 + 10 * T, 90000 + 30 * T, 90000 + 61 * T + 45000])
Sc.check("EP lookup: an exact hit", t.ep_index(0, 90000 + 4 * T), 2)
Sc.check("EP lookup: between entries -> the one before", t.ep_index(0, 90000 + 5 * T), 2)
Sc.check("EP lookup: before the first -> the first", t.ep_index(0, 0), 0)
Sc.check("EP lookup: past the last -> the last", t.ep_index(0, 10 ** 9), 49)
Sc.check("seek: lands on the entry before, shows from the target",
         t.seek((0, 90000 + 61 * T + 45000)), (0, 30, 90000 + 60 * T, 3000, 90000 + 61 * T + 45000))
Sc.check("chapter at a key", t.chapter_at((0, 90000 + 45 * T))[0], 3)
Sc.check("chapter at: exactly on a mark is that chapter", t.chapter_at((0, 90000 + 10 * T))[0], 2)
Sc.check("next chapter", t.next_chapter((0, 90000 + 12 * T)), (0, 90000 + 30 * T))
Sc.check("next past the last: None (the PSP's 'There is no chapter available.')",
         t.next_chapter((0, 90000 + 70 * T)), None)
Sc.check("prev 5 s into a chapter: restarts it", t.prev_chapter((0, 90000 + 35 * T)), (0, 90000 + 30 * T))
Sc.check("prev 1 s after the start: restarts it (the PSP at 0:13 on a 0:12 chapter)",
         t.prev_chapter((0, 90000 + 31 * T)), (0, 90000 + 30 * T))
Sc.check("prev 0.99 s after the start: the chapter before",
         t.prev_chapter((0, 90000 + 30 * T + 89999)), (0, 90000 + 10 * T))
Sc.check("prev in the first chapter's first second: restarts it", t.prev_chapter((0, 90000 + 500)), (0, 90000))
Sc.check("two quick Prevs from mid-chapter: back one", t.presses((0, 90000 + 35 * T), "pp"), ((0, 90000 + 10 * T), False))
Sc.check("Next Next Prev: the net", t.presses((0, 90000 + 12 * T), "nnp"), ((0, 90000 + 30 * T), False))
Sc.check("a Next past the last: nothing to seek, the message", t.presses((0, 90000 + 70 * T), "n"), (None, True))
Sc.check("Next Next from the second-last: lands on the last, the message too",
         t.presses((0, 90000 + 40 * T), "nn"), ((0, 90000 + 61 * T + 45000), True))
Sc.check("elapsed", t.elapsed((0, 90000 + 61 * T)), 61 * T)
Sc.check("IN / OUT: the reader stops at the first entry at/after OUT (OUT exclusive)", t.item_stop_sector(0), 4800)
t3 = N.Title([(1, 90000, 90000 + 95 * T, ents)], [])
Sc.check("IN / OUT: OUT between entries -> the entry after it", t3.item_stop_sector(0), 4800)
Sc.check("IN / OUT: OUT past the last entry -> the clip's end", N.Title([(1, 90000, 10 ** 9, ents)], []).item_stop_sector(0), None)

# two items (the multi-item titles): a short one with IN / OUT inside its clip, then the feature
short = [(90000 + T * k, 10 * k) for k in range(70)]                  # a 70 s clip, entries every 1 s
t2 = N.Title([(9, 90000 + 54 * T, 90000 + 56 * T, short), (1, 90000, 90000 + 96 * T, ents)],
             [(5, 1, 90000 + 30 * T), (5, 0, 90000 + 54 * T), (5, 1, 90000)])
Sc.check("multi-item: chapters by (item, PTS)", t2.chapters,
         [(0, 90000 + 54 * T), (1, 90000), (1, 90000 + 30 * T)])
Sc.check("multi-item: an item starts at the entry at IN, shows from IN",
         t2.item_start(0), (0, 54, 90000 + 54 * T, 540, 90000 + 54 * T))
Sc.check("multi-item: the reader stops at the entry at OUT", t2.item_stop_sector(0), 560)
Sc.check("multi-item: a seek clamps into IN..OUT", t2.seek((0, 90000))[4], 90000 + 54 * T)
Sc.check("multi-item: total", t2.total, 98 * T)
Sc.check("multi-item: elapsed counts the earlier items", t2.elapsed((1, 90000 + 10 * T)), 12 * T)
Sc.check("multi-item: the chapter number across items", t2.chapter_at((1, 90000 + 40 * T))[0], 3)
Sc.check("multi-item: next crosses into the next item", t2.next_chapter((0, 90000 + 55 * T)), (1, 90000))
Sc.check("multi-item: Go To's time -> the key", t2.key_at(12 * T), (1, 90000 + 10 * T))

# Go To by time (P6c, D15 / D16 measured on the PSP): the PLAYING playlist's time; an item's
# span is [its start, its start + OUT - IN), so a time ON a boundary is the next item's IN; past
# the end (or at it) the last item's OUT - 4 -- the title then ends within a picture
Sc.check("Go To: 0:00:00 is the first item's IN", t2.time_seek(0), (0, 54, 90000 + 54 * T, 540, 90000 + 54 * T))
Sc.check("Go To: a tick before the boundary stays in the first item", t2.key_at(2 * T - 1), (0, 90000 + 56 * T - 1))
Sc.check("Go To: ON the boundary is the next item's IN", t2.key_at(2 * T), (1, 90000))
Sc.check("Go To: at the title's end -> the last item's OUT - 4",
         t2.time_seek(98 * T), (1, 47, 90000 + 94 * T, 4700, 90000 + 96 * T - 4))
Sc.check("Go To: past the end (999:59:59) -> the last item's OUT - 4",
         t2.time_seek((999 * 3600 + 3599) * T)[4], 90000 + 96 * T - 4)
Sc.check("Go To: the key itself stops at the last item's OUT (IN + time would pass 2^48)",
         t2.key_at(((1 << 48) - 1)), (1, 90000 + 96 * T))
t4 = N.Title([("A", 90000, 90000 + 10 * T, ents), ("B", 90000, 90000, ents), ("C", 90000, 90000 + 20 * T, ents)], [])
Sc.check("Go To: an item of no duration holds no time (skipped)", t4.key_at(10 * T), (2, 90000))
Sc.check("Go To: an empty LAST item -> its IN (the clamp: shorter than END_GUARD)",
         N.Title([("A", 90000, 90000 + 10 * T, ents), ("B", 90000, 90000, ents)], []).time_seek(50 * T)[4], 90000)
# the marker of a chapter (D15): its title time, only in the item now streaming
Sc.check("marker: a chapter in the streaming item -> its title time", t2.marker((1, 90000 + 30 * T), 1), 32 * T)
Sc.check("marker: a chapter in another item -> hidden", t2.marker((1, 90000 + 30 * T), 0), None)
Sc.check("marker: a mark before IN -> the item's start", t2.marker((0, 90000), 0), 0)
Sc.check("marker: a mark past OUT -> the item's end", t2.marker((0, 90000 + 60 * T), 0), 2 * T)

# a seek's target is clamped into [IN, OUT - 4] (fix/skip-last-picture; P6b4 clamped to OUT - 1):
# inside the item's last picture, far enough from OUT that the display's skip keeps it --
# never an entry AT OUT, which the display's OUT would drop (nothing shown)
Sc.check("seek: a target at OUT is OUT - 4", t.seek((0, 90000 + 96 * T)), (0, 47, 90000 + 94 * T, 4700, 90000 + 96 * T - 4))
Sc.check("seek: a target past OUT is OUT - 4", t.seek((0, 10 ** 9))[4], 90000 + 96 * T - 4)
Sc.check("seek: a target at OUT - 3 is OUT - 4", t.seek((0, 90000 + 96 * T - 3))[4], 90000 + 96 * T - 4)
Sc.check("seek: a target at OUT - 4 is kept", t.seek((0, 90000 + 96 * T - 4))[4], 90000 + 96 * T - 4)
Sc.check("seek: an item shorter than END_GUARD -> IN",
         N.Title([(1, 90000, 90002, ents)], []).seek((0, 10 ** 9))[4], 90000)

# ... and the clamp, fed to the display (tools/disp_sched_ref.py, an independent model of
# disp_ctl), keeps the title's last picture on the shape that lost it on the rig: Akira's last
# GOP (28 frames, PES PTS on pictures 0 and 14 only, OUT one tick past the last picture's
# extrapolated end). With P6b4's OUT - 1 every picture is skipped (and, before the display's
# END-inside-a-skip rule, the END was never taken: the old picture stayed up).


def _seekend(tgt):
    recs, n, ctls = DS.scenario("seekend")
    out_pts = [c for c in ctls if c.kind == "W"][0].c
    ctls = [DS.W(c.k, c.a, tgt(out_pts), c.c, last=1) if c.kind == "W" else c for c in ctls]
    for i in range(1, len(recs)):
        recs[i].avail = max(recs[i].avail, recs[i - 1].avail)
    out, cnt, recs = DS.simulate(recs, n, ctls=ctls)
    return out[-1][6], cnt["skip"], cnt["ended"]


ta = N.Title([(1, 676392627 - 9 * T, 676497732, [(676392627 - 9 * T, 0), (676392627, 100)])], [])
Sc.check("seek to the end, displayed: the clamp shows the last picture and ends",
         _seekend(lambda o: ta.seek((0, o))[4]), (676494728, 27, 1))
Sc.check("seek to the end, displayed: OUT - 1 skips every picture (the defect); the END inside the skip ends it",
         _seekend(lambda o: o - 1)[1:], (28, 1))
t5 = N.Title([(1, 90000, 90000 + 10 * T, ents)], [])                  # OUT exactly ON entry 5
Sc.check("seek: OUT on an entry -> the entry before it, not the one at OUT", t5.seek((0, 90000 + 10 * T))[1:3], (4, 90000 + 8 * T))
Sc.check("an item's start: IN itself (the reader's walk does not clamp)", t5.item_start(0)[4], 90000)

# trick play (P6b4): the target advances rate x wall time, and lands at/before it BOTH ways
# (the reader's one lookup); the carried target is the CLAMPED one; a clamp that moved the
# target marks the item's edge, and the next hop crosses (or, at the title's ends, play
# resumes)
d20 = N.TRICK_RATES[0] * T // 4                                         # Forward 1 (20x), 0.25 s: 5 s
Sc.check("trick: Forward 1's delta over 0.25 s", d20, 5 * T)
(req, sat) = t.hop_request((0, 90000 + 10 * T), False, True, d20)
Sc.check("trick: a forward request is the target + delta", (req, sat), ((0, 90000 + 15 * T), False))
Sc.check("trick: it lands on the entry at/before, the target carried, no edge",
         t.hop_land(req, sat, True), ((0, 7, 90000 + 14 * T, 700, 90000 + 15 * T), (0, 90000 + 15 * T), False))
d55 = N.TRICK_RATES[2] * T // 10                                        # Reverse 3 (55x), 0.1 s: 5.5 s
(req, sat) = t.hop_request((0, 90000 + 50 * T), False, False, d55)
Sc.check("trick: Reverse 3 lands on the entry at/before target - delta",
         t.hop_land(req, sat, False)[0][1:3], (22, 90000 + 44 * T))
(req, sat) = t.hop_request((0, 90000 + 95 * T), False, True, 20 * T)
Sc.check("trick: forward past OUT: clamped to OUT - 4, the edge",
         t.hop_land(req, sat, True), ((0, 47, 90000 + 94 * T, 4700, 90000 + 96 * T - 4), (0, 90000 + 96 * T - 4), True))
Sc.check("trick: forward from the last item's edge: play resumes", t.hop_request((0, 90000 + 96 * T - 4), True, True, T), None)
(req, sat) = t.hop_request((0, 90000 + 2 * T), False, False, 20 * T)
Sc.check("trick: a reverse request below PTS 0 saturates", (req, sat), ((0, 0), True))
Sc.check("trick: ... lands on the first entry at IN, the edge", t.hop_land(req, sat, False)[1:], ((0, 90000), True))
t6 = N.Title([(1, 0, 96 * T, [(2 * T * k, 100 * k) for k in range(50)])], [])   # IN at PTS 0
(req, sat) = t6.hop_request((0, T), False, False, 2 * T)
Sc.check("trick: IN at PTS 0 -- only the saturation marks the start's edge", t6.hop_land(req, sat, False)[1:], ((0, 0), True))
(req, sat) = t.hop_request((0, 90000 + 10 * T), False, False, 10 * T + 1)
Sc.check("trick: a reverse request below IN (not 0): clamped up, the edge", t.hop_land(req, sat, False)[1:], ((0, 90000), True))
Sc.check("trick: reverse from the first item's edge: play resumes", t.hop_request((0, 90000), True, False, T), None)
(req, sat) = t2.hop_request((0, 90000 + 55 * T), False, True, T)
Sc.check("trick: forward to item 0's OUT: its last entry, the edge", t2.hop_land(req, sat, True)[1:], ((0, 90000 + 56 * T - 4), True))
(req, sat) = t2.hop_request((0, 90000 + 56 * T - 4), True, True, 7 * T)
Sc.check("trick: the next hop crosses to item 1's IN (the overshoot dropped)", (req, sat), ((1, 0), False))
Sc.check("trick: ... landing on item 1's first entry, no edge", t2.hop_land(req, sat, True), ((1, 0, 90000, 0, 90000), (1, 90000), False))
(req, sat) = t2.hop_request((1, 90000 + T), False, False, 2 * T)
Sc.check("trick: reverse to item 1's IN: the edge", t2.hop_land(req, sat, False)[1:], ((1, 90000), True))
(req, sat) = t2.hop_request((1, 90000), True, False, T)
Sc.check("trick: the next reverse hop crosses to item 0's end", (req, sat), ((0, N.PTS_MAX), False))
Sc.check("trick: ... clamped to its OUT - 4, no edge",
         t2.hop_land(req, sat, False), ((0, 55, 90000 + 55 * T, 550, 90000 + 56 * T - 4), (0, 90000 + 56 * T - 4), False))
Sc.check("trick: a run to the end -- two landings (the second at the edge), then play",
         [r[1][1] for r in t.trick((0, 90000 + 90 * T), [(True, 5 * T)] * 4)[0]], [47, 47])
Sc.check("trick: ... and play resumed", t.trick((0, 90000 + 90 * T), [(True, 5 * T)] * 4)[1], True)
# the reader's chapter query (NAV_CHAP) and the stream it plays (P6b2's goldens)
Sc.check("chapter query: rank, count, cur, prev, next",
         t.chapter_query((0, 90000 + 45 * T)),
         (3, 4, (0, 90000 + 30 * T), (0, 90000 + 10 * T), (0, 90000 + 61 * T + 45000)))
Sc.check("chapter query: before the first chapter", t.chapter_query((0, 0)), (0, 4, None, None, (0, 90000)))
Sc.check("chapter query: in the first chapter (no prev)", t.chapter_query((0, 90000 + T))[2:4], ((0, 90000), None))
Sc.check("chapter query: past the last (no next)", t.chapter_query((0, 10 ** 9))[4], None)
t4 = N.Title([(1, 90000, 90000 + 96 * T, ents)],
             [(5, 0, 90000 + 20 * T), (5, 0, 90000 + 20 * T), (5, 3, 90000), (5, 0, 90000)])
Sc.check("chapter query: equal keys are two chapters (prev == cur); a mark on a missing item is none",
         t4.chapter_query((0, 90000 + 20 * T)), (3, 3, (0, 90000 + 20 * T), (0, 90000 + 20 * T), None))
Sc.check("chapter query: a key past every item (the reader saturates it to u16)",
         t2.chapter_query((70000, 0))[:3], (3, 3, (1, 90000 + 30 * T)))
Sc.check("item span: from IN's entry to OUT's (a 5,000-sector clip)", t.item_span(0, 5000), (0, 4800))
Sc.check("item span: a landing mid-item", t.item_span(0, 5000, 3000), (3000, 4800))
Sc.check("item span: a landing at the stop is empty", t.item_span(0, 5000, 4800), (4800, 4800))
Sc.check("item span: a landing past the clip is empty", t.item_span(0, 4000, 4500), (4500, 4500))
Sc.check("item span: no stop -> the clip's end", N.Title([(1, 90000, 10 ** 9, ents)], []).item_span(0, 5000), (0, 5000))
Sc.check("stream plan: item 0 from its landing, then item 1 whole",
         t2.stream_plan([700, 5000], 0, 550), [(0, 550, 560), (1, 0, 4800)])
Sc.check("stream plan: a multi-item title's walk starts item 0 at IN's entry",
         t2.stream_plan([700, 5000], 0)[0], (0, 540, 560))
Sc.raises("an EP map not increasing is refused (the binary search assumes it)",
          lambda: N.Title([(1, 0, 10, [(5, 0), (5, 1)])], []), N.NavError, "not strictly increasing")

print("[x264]")
if not (shutil.which("ffmpeg") and b"libx264" in subprocess.run(
        ["ffmpeg", "-hide_banner", "-encoders"], capture_output=True).stdout):
    print("SKIP: [x264] needs ffmpeg with libx264")
else:
    import numpy as np
    import h264_fe_ref as FE
    import h264_recon_ref as R
    from cabac_ref import BitReader

    def spans(data):
        """(start, end, type, slice_type or None) per NAL unit, start at its start code."""
        out = []
        for pos, ref, typ, rbsp in FE.nal_units_pos(data):
            st = None
            if typ in (1, 5):
                br = BitReader(rbsp)
                br.ue()
                st = br.ue() % 5
            out.append([pos - 3 - (1 if pos >= 4 and data[pos - 4] == 0 else 0), None, typ, st])
        for a, b in zip(out, out[1:]):
            a[1] = b[0]
        out[-1][1] = len(data)
        return out

    def ff(path):
        y = path + ".ff.yuv"
        R.ffmpeg_yuv(path, y)
        return open(y, "rb").read()

    def model_yuv(frames, d, name):
        y = os.path.join(d, name + ".yuv")
        R.write_yuv(frames, y)
        return open(y, "rb").read()

    with tempfile.TemporaryDirectory(prefix="rpstart_") as d:
        src = os.path.join(d, "og.264")
        subprocess.run(["ffmpeg", "-v", "error", "-f", "lavfi", "-i", "testsrc2=size=64x64:rate=24",
                        "-frames:v", "30", "-c:v", "libx264", "-profile:v", "main", "-pix_fmt", "yuv420p",
                        "-x264-params", "cabac=1:8x8dct=0:keyint=12:min-keyint=12:scenecut=0:open-gop=1:"
                        "bframes=2:b-pyramid=0:ref=2:weightp=0:aud=1:repeat-headers=1",
                        "-f", "h264", "-y", src], check=True)
        data = open(src, "rb").read()
        sp = spans(data)
        # the second I picture: a non-IDR I slice; the cut starts at its access unit delimiter
        islices = [k for k, s in enumerate(sp) if s[2] == 1 and s[3] == 2]
        Sc.check("x264 open GOP: a non-IDR I picture exists", bool(islices), True)
        k = islices[0]
        aud = max(j for j in range(k) if sp[j][2] == 9)
        cut = data[sp[aud][0]:]
        cpath = os.path.join(d, "cut.264")
        open(cpath, "wb").write(cut)
        FS = 64 * 64 * 3 // 2

        dec = R.Decoder(rp_start=True)
        dec.feed(FE.decode_stream(cut))
        dec.flush_output()
        mine, ref = model_yuv(dec.output_frames(), d, "rp"), ff(cpath)
        import umd_seek_census
        want_lead = umd_seek_census.leading_pictures(cut, {}, {})   # an independent POC scan (8.2.1.1)
        Sc.check("rp start: the census finds leading pictures in the fixture", bool(want_lead), True)
        Sc.check("rp start: the leading pictures skipped == the census's count", dec.rp_cnt["lead"], want_lead)
        Sc.check("rp start: a non-IDR start", (dec.rp_cnt["starts"], dec.rp_cnt["non_idr"]), (1, 1))
        Sc.check("rp start: x264's MMCO naming a picture from before the entry ignored, counted",
                 dec.rp_cnt["mmco_missing"] > 0, True)
        Sc.check("rp start: frames == ffmpeg's on the same bytes", len(mine) // FS, len(ref) // FS)
        Sc.check("rp start: bit-exact with ffmpeg", mine == ref, True)
        Sc.raises("without the start armed the cut is refused (the frame_num gap)",
                  lambda: R.Decoder().feed(FE.decode_stream(cut)), R.ReconError, "gap in frame_num")

        # the discontinuity: 8 frames of the head, then the cut with its SPS / PPS stripped
        auds = [j for j, s in enumerate(sp) if s[2] == 9]
        head = data[:sp[auds[8]][0]]
        stripped = b"".join(data[s[0]:s[1]] for s in sp[aud:] if s[2] not in (7, 8))
        rec_head = FE.decode_stream(head)
        rec_all = FE.decode_stream(head + stripped)
        Sc.check("discontinuity fixture: the head's records are a prefix", rec_all[:len(rec_head)] == rec_head, True)
        dec = R.Decoder()
        dec.feed(rec_all[:len(rec_head)])
        n_before = len(dec.emitted)
        dec.discontinuity()
        dec.feed(rec_all[len(rec_head):])
        dec.flush_output()
        hpath = os.path.join(d, "head.264")
        open(hpath, "wb").write(head)
        want = ff(hpath)[:n_before * FS] + ref
        got = model_yuv(dec.output_frames(), d, "disc")
        Sc.check("discontinuity: stores waiting at the seek dropped", dec.rp_cnt["dropped"] > 0, True)
        Sc.check("discontinuity: the parameter sets kept (the cut carries none)", dec.rp_cnt["non_idr"], 1)
        Sc.check("discontinuity: frames == the head's emitted + the cut's", len(got) // FS, len(want) // FS)
        Sc.check("discontinuity: bit-exact with ffmpeg (head's emitted, then the cut)", got == want, True)

        # the same, the seek landing MID-PICTURE (the RTL's reset): the head's records cut
        # after the 10th macroblock of the picture that opens after 8 frames' worth; that
        # picture is abandoned -- never deblocked, marked or output
        heads = [i for i, r in enumerate(rec_all[:len(rec_head)]) if r.startswith("M 0")]
        k0 = heads[-1]                                   # the head's last picture opens here
        ms = [i for i in range(k0, len(rec_head)) if rec_all[i][0] == "M"]
        cutrec = rec_all[:ms[10]]                        # 10 macroblocks of it
        dec2 = R.Decoder()
        dec2.feed(cutrec, finish=False)
        dec2.discontinuity(abandon=True)
        n_before2 = len(dec2.emitted)
        dec2.feed(rec_all[len(rec_head):])
        dec2.flush_output()
        want = ff(hpath)[:n_before2 * FS] + ref
        got = model_yuv(dec2.output_frames(), d, "abandon")
        Sc.check("mid-picture: the picture in progress abandoned", dec2.rp_cnt["abandoned"], 1)
        Sc.check("mid-picture: bit-exact with ffmpeg (head's emitted, then the cut)", got == want, True)

Sc.finish()
