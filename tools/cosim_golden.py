#!/usr/bin/env python3
"""The Verilator cosim's golden (bench/umd/run_cosim.sh): a window of a disc's main title
as the elementary stream the decoder is fed, and the model's decode-order pictures
(tools/h264_recon_ref.py) before and after deblocking -- the cosim scores the RTL against
them per macroblock and per picture. The model's display-order output of the same window
is compared with ffmpeg's decode first (the independent oracle: a window where the model
and ffmpeg disagree is reported and not scored).

    cosim_golden.py --disc IMAGE.iso --out STEM [--frames 300] [--at 0.4] [--ep-start [--non-idr]]

The window: the main title (the LONGEST playlist, umd_playlist.main_playlist), from the
video EP entry at or before `at` of its IN..OUT span, whole access units, cut after
`frames` frames (a field pair is one frame) -- the header parsers count them, no CABAC.
By default it starts at the first IDR from there. With --ep-start it starts AT the entry,
as a seek lands (P6b, docs/transport.md S2.2): the model makes a recovery-point start
(the entry's I picture, IDR or not; the leading pictures after it skipped); --non-idr
first walks forward to the next entry that is NOT an IDR, the case the start exists for.

Files:
  STEM.es     the Annex-B bytes
  STEM.pics   a header line "pictures macroblocks frames field_pictures play_us" (the
              window's display time from its pic_struct SEI, 0 if unknown), then per
              picture (decode order) "struct width_mbs height_mbs word_offset" (struct 0 F,
              1 T, 2 B; a field's own height)
  STEM.pre / STEM.post   the samples, per picture luma rows then Cb then Cr, raw bytes
              (8 samples = one little-endian DPB word, docs/h264_recon.md S2.2)
  STEM.out    P5d, the output process: per store emitted, in order, "picture step frame
              unpaired" -- the decode index of the store's first picture, the pictures
              opened when it is emitted, coded as a frame, a single field (the window's
              end included: the end-of-stream flush)
  STEM.seek   (--seek only) P6b1's mid-stream seek: "a_pics abandon_mbs b_offset" -- the
              ES is window A (from an IDR, --frames / 2) then window B (a non-IDR EP entry
              at --seek-at, its SPS / PPS STRIPPED when they equal A's: the decoder must have
              kept them); the harness resets the decoder (ps_rst_n held: the parameter sets
              survive) once it has reconstructed abandon_mbs macroblocks of A's LAST picture
              (picture a_pics, abandoned: absent from the golden), then feeds B from
              b_offset. The model: A, discontinuity(abandon=True), B; its oracle is ffmpeg's
              A (the frames emitted before the seek) followed by ffmpeg's B. STEM.rp holds
              B's start counts (the RTL's counters reset with the seek)
  STEM.es alone with --es-only (no model): P6b4's trick-play cosim feeds a longer window
              from the same entry and scores the golden of its first frame
  STEM.feat   the window's stream features, "name count" a line (tools/cosim_features.py:
              the census run_cosim.sh --sample chooses from)
  STEM.rp     (--ep-start only) the recovery-point start's counts, "starts non_idr
              pre_i lead mmco_missing" -- the cosim's [count] arm scores recon_dpb's (P6b1)
Exit: 0 written; 3 SKIP (a damaged rip, or no video); 4 REFUSED (the model refuses the
stream: a scoping decision, e.g. CAVLC or MBAFF); 5 the model disagrees with ffmpeg.
"""
import argparse
import os
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import h264_fe_ref as FE  # noqa: E402
import h264_recon_ref as RR  # noqa: E402
import h264_top_golden as TG  # noqa: E402
import recon_top_golden as RG  # noqa: E402
import cosim_features as CF  # noqa: E402


def main_title(path):
    """(clip, in_pts, out_pts) of the main title's longest item."""
    import umd_iso
    import umd_playlist
    with umd_iso.UmdIso(path) as iso:
        pl = umd_playlist.from_iso(iso)
    idx = umd_playlist.main_playlist(pl)
    ent = [e for e in pl["playlists"] if e["index"] == idx][0]
    it = max(ent["items"], key=lambda i: i["out_pts"] - i["in_pts"])
    return int(it["clip_name"]), it["in_pts"], it["out_pts"]


def nal_spans(data):
    """(start, end, nal_unit_type) per NAL unit, start at its start code (a 4-byte one's
    leading zero included), end at the next unit's start."""
    out = []
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(data):
        s = i - 1 if i > 0 and data[i - 1] == 0 else i
        j = data.find(b"\x00\x00\x01", i + 3)
        e = len(data) if j < 0 else (j - 1 if data[j - 1] == 0 else j)
        out.append((s, e, data[i + 3] & 0x1F))
        i = j
    return out


def param_sets(data):
    """The SPS and PPS NAL units of `data`, in order, with their start codes."""
    return b"".join(data[s:e] for s, e, t in nal_spans(data) if t in (7, 8))


def from_idr(data, prefix=b""):
    """The data from the access unit of the first IDR picture, or None. A video EP entry
    is an I picture but not always an IDR (Family Guy's are recovery points): decoding
    from one starts with no reference state (the model refuses the frame_num gap), so the
    window starts at the next IDR. Its access unit need not repeat the parameter sets
    (Astro Boy's IDRs do not: they are sent once, at the start), so the SPS / PPS a player
    would already hold go right after its delimiter: `prefix` (the title start's) and then
    every one the data sent before the IDR -- later ones override, as in a decoder."""
    aud = None
    for s, e, t in nal_spans(data):
        if t == 9:
            aud = (s, e)
        elif t == 5:
            if aud is None:
                return prefix + param_sets(data[:s]) + data[s:]
            return data[aud[0]:aud[1]] + prefix + param_sets(data[:aud[0]]) + data[aud[1]:]
    return None


def at_entry(data, prefix=b""):
    """The data as cut at an EP entry (it opens on the entry's access unit delimiter), with
    the parameter sets a player would already hold -- `prefix`, the title start's -- right
    after the delimiter. Every disc's entries repeat their own after it (docs/transport.md
    S1), which follow and override, as in a decoder."""
    sp = nal_spans(data)
    if not sp or sp[0][2] != 9:
        return None
    s, e, _t = sp[0]
    return data[s:e] + prefix + data[e:]


def non_idr_entry(disc, clip, pts):
    """The PTS of the first video EP entry at or after the one at/before `pts` whose
    picture is not an IDR (None if none in the clip)."""
    import umd_clpi
    import umd_iso
    import umd_seek_census
    import psmf_ref
    with umd_iso.UmdIso(disc) as iso:
        c = umd_clpi.from_iso(iso, clip)
    ents = umd_clpi.video_map(c)
    k = max([0] + [j for j, e in enumerate(ents) if e[1] <= pts])
    src = psmf_ref.Source(disc, clip)
    try:
        for _fl, p, sec in ents[k:]:
            a = src.start + sec * psmf_ref.SEC
            r = psmf_ref.parse(src.mm, a, min(src.end, a + psmf_ref.SEC))
            hit = [q for q in r.packets if q.sid == 0xE0]
            if hit and umd_seek_census.entry_head(
                    bytes(src.mm[hit[0].payload_off:hit[0].payload_off + hit[0].payload_len]))["idr"] is False:
                return p
    finally:
        src.close()
    return None


def raw_es(disc, clip, packs, from_pts=None):
    """(the clip's video ES from its first byte -- or from the EP entry at/before from_pts, to
    the clip's end --, [(es_offset, pts)] of each PES with a PTS): an item's start or end as
    the reader and the demux feed it (P8). Whole access units."""
    import psmf_ref
    import umd_clpi
    import umd_iso
    from h264_trace_ref import trim_to_last_au
    src = psmf_ref.Source(disc, clip)
    if from_pts is not None:
        with umd_iso.UmdIso(disc) as iso:
            c = umd_clpi.from_iso(iso, clip)
        _p, sec = umd_clpi.lookup(c, from_pts)
        src.start += sec * psmf_ref.SEC
    else:
        src.limit(packs)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end, keep=True)
        data, mk = psmf_ref.es(src.mm, r, "video")
    finally:
        src.close()
    return trim_to_last_au(data), [(off, pts) for off, pts, _dts, _fap in mk if pts is not None]


def trim_tail(data):
    """Drop the non-VCL NAL units after the last slice (the next access unit's delimiter
    and SEI, which the cut leaves behind: an access unit with no picture)."""
    last_slice = -1
    i = data.find(b"\x00\x00\x01")
    while i >= 0 and i + 3 < len(data):
        if data[i + 3] & 0x1F in (1, 5):
            last_slice = i
        i = data.find(b"\x00\x00\x01", i + 3)
    if last_slice < 0:
        return data
    j = data.find(b"\x00\x00\x01", last_slice + 3)
    if j < 0:
        return data
    while j > last_slice + 3 and data[j - 1] == 0:
        j -= 1
    return data[:j]


def count_pictures(data, frames):
    """How many pictures (decode order) make up the first `frames` frames, and how many
    of them are fields. Header parsing only."""
    sps_map, pps_map = {}, {}
    n_pic, n_fields, n_frames2 = 0, 0, 0       # n_frames2 in half frames
    for ref_idc, ntype, rbsp in FE.nal_units(data):
        rec = []
        if ntype == 7:
            s = FE.parse_sps(rbsp, rec)
            sps_map[s.id] = s
        elif ntype == 8:
            p = FE.parse_pps(rbsp, sps_map, rec)
            pps_map[p.id] = p
        elif ntype in (1, 5):
            h = FE.parse_slice_header(FE.BitReader(rbsp), ntype, ref_idc, sps_map, pps_map, rec)
            if h.first_mb != 0:
                continue
            if n_frames2 >= 2 * frames:
                break
            n_pic += 1
            if h.field_pic:
                n_fields += 1
                n_frames2 += 1
            else:
                n_frames2 += 2
    return n_pic, n_fields


# Table E-6: clock ticks a picture is displayed for, by pic_struct (a tick is
# num_units_in_tick / time_scale: 1/59.94 s on the 4004 / 240000 streams, one field)
TICKS = {0: 2, 1: 1, 2: 1, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 6}


def display_seconds(data):
    """How long the window plays: the pic_timing SEI's pic_struct of every access unit
    (ffmpeg's trace_headers, via umd_census.trace), in the VUI's ticks. The decoder is in
    real time on the window when it decodes it in less. (seconds, SEI count, pictures)."""
    import umd_census
    h, _slices, pics, _errs = umd_census.trace(data)
    ps = h["pic_struct"]
    if not h["num_units_in_tick"] or not h["time_scale"]:
        return None, 0, pics
    nuit = h["num_units_in_tick"].most_common(1)[0][0]
    ts = h["time_scale"].most_common(1)[0][0]
    ticks = sum(TICKS.get(k, 2) * c for k, c in ps.items())
    return ticks * nuit / float(ts), sum(ps.values()), pics


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--frames", type=int, default=300)
    ap.add_argument("--at", type=float, default=0.4, help="the window's start, a fraction of the title")
    ap.add_argument("--packs", type=int, default=12000, help="packs read from the start (24 MB)")
    ap.add_argument("--ep-start", action="store_true",
                    help="start AT the EP entry with a recovery-point start, as a seek does (P6b)")
    ap.add_argument("--non-idr", action="store_true",
                    help="with --ep-start: the first entry from there that is not an IDR")
    ap.add_argument("--seek", action="store_true",
                    help="P6b1: window A, a mid-picture seek, window B from a non-IDR entry (STEM.seek)")
    ap.add_argument("--seek-at", type=float, default=0.7, help="with --seek: B's entry, a fraction of the title")
    ap.add_argument("--clip", type=int, help="this clip instead of the main title's longest item")
    ap.add_argument("--raw", action="store_true",
                    help="the clip from its first byte, exactly as the reader feeds an item's start "
                         "(no IDR search, no parameter sets moved): P8's item-start cosim")
    ap.add_argument("--raw-from", type=int, metavar="PTS", default=None,
                    help="with --raw: start at the clip's EP entry at or before this PTS (90 kHz) and "
                         "read to the clip's end (the entry should be an IDR)")
    ap.add_argument("--then-clip", type=int, metavar="M", default=None,
                    help="with --raw: then clip M from its first byte, no reset between -- an item "
                         "crossing as the reader plays through it (P8); --marks tags it EP + 1")
    ap.add_argument("--no-oracle", action="store_true",
                    help="skip the ffmpeg comparison (an item crossing: ffmpeg joins two clips its own way)")
    ap.add_argument("--marks", type=int, metavar="EP", default=None,
                    help="also write STEM.marks: each PES with a PTS as 'es_offset pts ep' (ep: the "
                         "item tag to feed, 0-3) -- the harness drives h264_top's PES sideband from it")
    ap.add_argument("--es-only", action="store_true",
                    help="write STEM.es alone, no model (P6b4: the longer window a trick-play cosim is fed)")
    ap.add_argument("--timing-only", action="store_true",
                    help="cut the window and print its display time; no model, no files")
    a = ap.parse_args(argv)

    import umd_clpi
    clip, t_in, t_out = main_title(a.disc)
    if a.clip is not None:
        clip = a.clip
    if umd_clpi.zero_fraction(a.disc, clip) > 0.05:
        print("SKIP: clip %d of %s is a damaged rip (zero-filled sectors)" % (clip, a.disc))
        return 3
    pts = t_in + int(a.at * (t_out - t_in))
    try:
        head = param_sets(RR.disc_es(a.disc, clip, 64, None))   # the clip's start
        marks = None
        if a.raw:
            data, marks = raw_es(a.disc, clip, a.packs, a.raw_from)
            marks = [(o, p, 0) for o, p in marks]
            if a.then_clip is not None:
                b_data, b_marks = raw_es(a.disc, a.then_clip, a.packs)
                marks += [(len(data) + o, p, 1) for o, p in b_marks]
                data = data + b_data
        elif a.ep_start:
            if a.non_idr:
                pts = non_idr_entry(a.disc, clip, pts)
                if pts is None:
                    print("SKIP: no non-IDR entry from there to the clip's end")
                    return 3
            data = at_entry(RR.disc_es(a.disc, clip, a.packs, pts), head)
            if data is None:
                print("SKIP: the entry does not open on an access unit delimiter")
                return 3
        else:
            data = from_idr(RR.disc_es(a.disc, clip, a.packs, pts), head)
            if data is None:          # no IDR in the packs read: the title's start is one
                pts = t_in
                data = from_idr(RR.disc_es(a.disc, clip, a.packs, pts), head)
            if data is None:
                print("SKIP: no IDR picture in the window or at the title's start")
                return 3
        frames_a = a.frames // 2 if a.seek else a.frames
        n_pic, n_fields = count_pictures(data, frames_a)
        if n_pic == 0:
            print("SKIP: no pictures in the window")
            return 3
        data = trim_tail(RG.truncate_es(data, n_pic - 1))   # exactly n_pic pictures
        if a.marks is not None:
            if marks is None:
                print("SKIP: --marks needs --raw (the window's PES offsets)")
                return 3
            with open(a.out + ".marks", "w") as f:
                for off, pts, dep in marks:
                    if off < len(data):
                        f.write("%d %d %d\n" % (off, pts, (a.marks + dep) & 3))
        seek = None
        if a.seek:
            # P6b1: B, from a non-IDR entry further on, its parameter sets stripped when A's
            # are the same bytes (then only a decoder that KEPT them can decode it)
            pts_b = non_idr_entry(a.disc, clip, t_in + int(a.seek_at * (t_out - t_in)))
            if pts_b is None:
                print("SKIP: no non-IDR entry for B")
                return 3
            b_full = at_entry(RR.disc_es(a.disc, clip, a.packs, pts_b), b"")
            nb, _nbf = count_pictures(b_full, a.frames - frames_a)
            b_full = trim_tail(RG.truncate_es(b_full, nb - 1))
            # a parameter set NAL of B is stripped when it is the same bytes as the LAST one of
            # its type A sent -- what a decoder holds at the seek (a disc re-sends PPS 0 with
            # other contents per GOP: an older equal copy in A does not count)
            a_last = {}
            for s0, e0, t in nal_spans(data):
                if t in (7, 8):
                    a_last[t] = bytes(data[s0:e0]).lstrip(b"\x00")
            keep, stripped = [], []
            for s0, e0, t in nal_spans(b_full):
                if t in (7, 8) and bytes(b_full[s0:e0]).lstrip(b"\x00") == a_last.get(t):
                    stripped.append("SPS" if t == 7 else "PPS")
                else:
                    keep.append(b_full[s0:e0])
            b_data = b"".join(keep)
            seek = {"a": data, "b_full": b_full, "b_off": len(data), "stripped": stripped, "pts_b": pts_b}
            data = data + b_data
        if a.es_only:
            os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
            with open(a.out + ".es", "wb") as f:
                f.write(data)
            print("ES: %d pictures (%d fields), %d bytes" % (n_pic, n_fields, len(data)))
            return 0
        secs, n_sei, _p = display_seconds(data)
        if a.timing_only:
            if secs is None:
                print("TIMING: no VUI timing in the window")
                return 3
            print("TIMING: %d pictures (%d fields), %d frames, %d pic_timing SEI, plays %.3f s: "
                  "%.3f frames/s needed" % (n_pic, n_fields, a.frames, n_sei, secs, a.frames / secs))
            return 0
        rec = FE.decode_stream(data)
    except (FE.Refused, RR.ReconError) as e:
        print("REFUSED: %s" % e)
        return 4
    except Exception as e:  # a front-end refusal raised under another name
        if type(e).__name__ in ("Refused", "Unsupported"):
            print("REFUSED: %s" % e)
            return 4
        raise

    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".es", "wb") as f:
        f.write(data)
    pics = []
    fpre = open(a.out + ".pre", "wb")
    fpost = open(a.out + ".post", "wb")
    off = [0]

    frame_of = []

    def hook(pic, pre):
        frame_of.append(pic.frame.id)
        pics.append(({"F": 0, "T": 1, "B": 2}[pic.struct], pic.w, pic.hgt, off[0]))
        for planes, f in ((pre, fpre), ([pic.Y, pic.Cb, pic.Cr], fpost)):
            for pl in planes:
                f.write(np.ascontiguousarray(pl.astype(np.uint8)).tobytes())
        off[0] += (16 * pic.hgt * 2 * pic.w) + 2 * (8 * pic.hgt * pic.w)
    dec = RR.Decoder(on_picture=hook, rp_start=a.ep_start or a.seek)
    try:
        if seek is None:
            dec.feed(rec)
        else:
            rec_a = FE.decode_stream(seek["a"])
            if rec[:len(rec_a)] != rec_a:
                print("SKIP: A's records are not a prefix of the spliced stream's")
                return 3
            dec.feed(rec[:len(rec_a)], finish=False)       # A's last picture: in progress
            seek["a_pics"] = len(pics)
            seek["abandon_mbs"] = dec.pic.n_mbs // 2 if dec.pic is not None else 0
            dec.discontinuity(abandon=True)
            seek["n_before"] = len(dec.emitted)
            seek["rp_before"] = dict(dec.rp_cnt)
            dec.feed(rec[len(rec_a):])
    except RR.ReconError as e:
        print("REFUSED: %s" % e)
        return 4
    dec.flush_output()                    # the end of stream: the last picture, then every one waiting
    fpre.close()
    fpost.close()
    # the macroblocks of the pictures DECODED (a recovery-point start skips the leading
    # pictures: their macroblock words are in the stream, never reconstructed)
    n_mbs = sum(w * h for _st, w, h, _off in pics)
    if not a.ep_start and not a.seek:
        assert n_mbs == sum(1 for w in TG.words(rec) if w[0] == 1)
    frames = dec.output_frames()
    n_fields = sum(1 for p in pics if p[0] != 0)

    # the independent oracle: the model's display-order window against ffmpeg's decode
    with tempfile.TemporaryDirectory() as td:
        es = os.path.join(td, "w.264")
        open(es, "wb").write(data)
        ours, ref = os.path.join(td, "m.yuv"), os.path.join(td, "f.yuv")
        RR.write_yuv(frames, ours)
        if seek is None:
            RR.ffmpeg_yuv(es, ref)
        else:
            # ffmpeg's A, the frames the model emitted before the seek, then ffmpeg's B (with
            # its own parameter sets)
            s0 = frames[0].sps
            fsz = (s0.width - 2 * (s0.crop[0] + s0.crop[1])) * (s0.height - 2 * (2 - s0.frame_mbs_only) * (s0.crop[2] + s0.crop[3])) * 3 // 2
            parts = []
            for key in ("a", "b_full"):
                pe, py = os.path.join(td, key + ".264"), os.path.join(td, key + ".yuv")
                open(pe, "wb").write(seek[key])
                RR.ffmpeg_yuv(pe, py)
                parts.append(open(py, "rb").read())
            open(ref, "wb").write(parts[0][:seek["n_before"] * fsz] + parts[1])
        s = frames[0].sps
        l, r, t, b = s.crop
        cu_y = 2 * (2 - s.frame_mbs_only)
        w, h = s.width - 2 * (l + r), s.height - cu_y * (t + b)
        mism, na, nb = RR.compare_yuv(ours, ref, w, h)
    if (mism is not None or na != nb) and a.no_oracle:
        print("NOTE (--no-oracle): the model differs from ffmpeg: %s (model %d frames, ffmpeg %d)" % (mism, na, nb))
    elif mism is not None or na != nb:
        print("MODEL-MISMATCH vs ffmpeg: %s (model %d frames, ffmpeg %d)" % (mism, na, nb))
        return 5

    with open(a.out + ".pics", "w") as f:
        f.write("%d %d %d %d %d\n" % (len(pics), n_mbs, len(frames), n_fields,
                                     int(round((secs or 0) * 1e6))))
        for p in pics:
            f.write("%d %d %d %d\n" % p)
    CF.write(a.out + ".feat", CF.features(rec))
    if seek is not None:
        with open(a.out + ".seek", "w") as f:
            f.write("%d %d %d\n" % (seek["a_pics"], seek["abandon_mbs"], seek["b_off"]))
    else:
        try:
            os.remove(a.out + ".seek")
        except OSError:
            pass
    if a.ep_start or a.seek:
        # P6b1: the recovery-point start's counts, scored by the cosim's [count] arm (after a
        # seek: B's alone -- the RTL's counters reset with the decoder)
        c = dict(dec.rp_cnt)
        if seek is not None:
            c = {k: c[k] - seek["rp_before"].get(k, 0) for k in c}
        with open(a.out + ".rp", "w") as f:
            f.write("%d %d %d %d %d\n" % (c["starts"], c["non_idr"], c["pre_i"], c["lead"], c["mmco_missing"]))
    else:
        try:
            os.remove(a.out + ".rp")          # a stale one from an --ep-start run of the same stem
        except OSError:
            pass
    with open(a.out + ".out", "w") as f:
        f.write("%d\n" % len(dec.emitted))
        for fr, n, _how in dec.emitted:
            unpaired = int(not fr.coded_as_frame and fr.decoded != [1, 1])
            f.write("%d %d %d %d\n" % (frame_of.index(fr.id), n, fr.coded_as_frame, unpaired))
    where = ("the EP entry at PTS %d (a recovery-point start: %s)" % (pts, dec.rp_cnt) if a.ep_start
             else "the first IDR after PTS %d" % pts)
    if seek is not None:
        where += (", then a seek abandoning picture %d after %d macroblocks, to the non-IDR entry at PTS %d "
                  "(stripped from B, kept by the decoder: %s)" % (seek["a_pics"], seek["abandon_mbs"], seek["pts_b"],
                                                                        " ".join(seek["stripped"]) or "none"))
    print("%s: clip %d from %s, %d bytes, %d pictures (%d fields), %d frames, %d macroblocks, "
          "plays %.3f s; the model BIT-EXACT vs ffmpeg" % (a.out, clip, where, len(data), len(pics), n_fields,
                                                        len(frames), n_mbs, secs or 0))
    return 0


if __name__ == "__main__":
    sys.exit(main())
