#!/usr/bin/env python3
"""Per-disc feature vector over a directory of UMD Video images -- what the discs
actually use, measured by the Phase 1 tools (docs/umd_video_format.md "Census").

Skeleton after MiSTer_DVD's tools/dvd_census.py (gather -> per-disc vector -> report,
[ok]/[err] per disc; one disc's exception never stops the run, and any exception fails
the exit code -- "no parser exception on any disc" is a Phase 1 gate).

Per disc: filesystem shape, SFO title, playlists/items/marks and the main playlist,
CLPI streams + EP maps (verified against the stream), and per clip:
  * one full pack walk (psmf_ref): byte accounting == size, stream PES counts
  * audio (every 0xBD 0x00-0x0F track): AUs, params words, resyncs; ffmpeg decode of a
    sample (or the whole track with --full-audio) with rate/channels/samples per AU
  * subtitles (0x80-0x8F): units, PNG validity (PIL), max size / right / bottom edge
  * video: ffmpeg trace_headers + an ffmpeg decode over two windows (the clip head and
    an EP entry at mid-clip): SPS/PPS/slice/SEI field histograms, field coding,
    slices per picture, decode errors
  * 0xBF index packs verified against the video (first --index-packs packs)
  * zero-filled sectors (a damaged image says so instead of failing a parser)

    UMD_ISO_DIR=... umd_census.py [paths...] [--json out.json] [--jobs N] [--full-audio]
"""
import argparse
import glob
import json
import multiprocessing
import os
import re
import subprocess
import sys
import tempfile
import traceback
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_extract  # noqa: E402
import psmf_ref  # noqa: E402
import umd_clpi  # noqa: E402
import umd_index_packs  # noqa: E402
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402
import umd_sfo  # noqa: E402
import umd_sub_extract  # noqa: E402

SEC = 2048
WINDOW_PACKS = 2500                 # ~5 MB of stream per video window
AUDIO_SAMPLE_PACKS = 6000           # audio decoded from the clip head unless --full-audio

# trace_headers fields kept as value histograms (SPS / PPS / slice / SEI)
HIST = """profile_idc level_idc constraint_set1_flag constraint_set3_flag seq_parameter_set_id
pic_width_in_mbs_minus1 pic_height_in_map_units_minus1 frame_mbs_only_flag
mb_adaptive_frame_field_flag direct_8x8_inference_flag max_num_ref_frames
frame_cropping_flag aspect_ratio_idc sar_width sar_height num_units_in_tick time_scale
fixed_frame_rate_flag pic_struct_present_flag nal_hrd_parameters_present_flag
pic_order_cnt_type log2_max_frame_num_minus4 max_num_reorder_frames
max_dec_frame_buffering chroma_format_idc
pic_parameter_set_id entropy_coding_mode_flag weighted_pred_flag weighted_bipred_idc
num_ref_idx_l0_default_active_minus1 num_ref_idx_l1_default_active_minus1
deblocking_filter_control_present_flag constrained_intra_pred_flag transform_8x8_mode_flag
num_slice_groups_minus1 redundant_pic_cnt_present_flag
bottom_field_pic_order_in_frame_present_flag
slice_type field_pic_flag bottom_field_flag direct_spatial_mv_pred_flag
num_ref_idx_active_override_flag num_ref_idx_l0_active_minus1 num_ref_idx_l1_active_minus1
cabac_init_idc disable_deblocking_filter_idc long_term_reference_flag
adaptive_ref_pic_marking_mode_flag memory_management_control_operation
ref_pic_list_modification_flag_l0 ref_pic_list_modification_flag_l1
luma_log2_weight_denom pic_struct nal_unit_type""".split()
TRACE_RE = re.compile(r"\]\s+\d+\s+([A-Za-z0-9_]+)(?:\[[^\]]*\])*\s+[01]+ = (-?\d+)\s*$")


def gather(paths):
    if not paths:
        d = os.path.expanduser(os.environ.get("UMD_ISO_DIR", "~/umd-isos"))
        paths = [d]
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(f for f in glob.glob(os.path.join(p, "*"))
                          if f.lower().endswith(".iso"))
        else:
            out.append(p)
    return out


def trace(es):
    """ffmpeg trace_headers over an Annex-B ES -> (Counter per field, slices, pictures)."""
    with tempfile.NamedTemporaryFile(suffix=".h264") as t:
        t.write(es)
        t.flush()
        r = subprocess.run(["ffmpeg", "-v", "trace", "-nostdin", "-f", "h264", "-i", t.name,
                            "-c", "copy", "-bsf:v", "trace_headers", "-f", "null", "-"],
                           capture_output=True, text=True, errors="replace")
        d = subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-f", "h264", "-i", t.name,
                            "-f", "null", "-"], capture_output=True, text=True,
                           errors="replace")
    h = {k: Counter() for k in HIST}
    slices = pics = 0
    for line in r.stderr.splitlines():
        if "trace_headers" not in line:
            continue
        m = TRACE_RE.search(line)
        if not m:
            continue
        k, v = m.group(1), int(m.group(2))
        if k in h:
            h[k][v] += 1
        if k == "first_mb_in_slice":
            slices += 1
            pics += v == 0
    errs = [l for l in d.stderr.splitlines() if l.strip()]
    return h, slices, pics, errs


def trim_to_aus(es):
    """Cut a window's ES at its last AUD so no truncated access unit reaches ffmpeg (a
    cut mid-picture decodes as 'error while decoding MB ... bytestream -N' -- an error
    of the census's own making, not the disc's)."""
    k = es.rfind(b"\x00\x00\x01\x09")
    return es[:k - 1 if k > 0 and es[k - 1] == 0 else k] if k > 0 else es


# "Missing reference picture": a B picture whose reference is not in what ffmpeg was
# given. At a mid-clip window start that is the open GOP before the cut; but xXx clip 2
# (a spliced trailer) says it 147 times decoded WHOLE, with exact byte accounting and no
# bitstream error -- a property of the stream (open GOPs across edit points), not of
# the extraction. Counted and reported apart in every window; bitstream-class errors
# ("error while decoding MB ...") stay fatal in the gate.
EXPECTED_ERR = ("Missing reference picture", "reference picture missing")


def full_decode(aus, tmpdir, n, t):
    """Decode a whole track through ffmpeg, counting s16 samples off a pipe (a 2 h
    feature is 1.4 GB of PCM: never written, never held)."""
    oma = os.path.join(tmpdir, "full_c%d_t%d.oma" % (n, t))
    with open(oma, "wb") as f:
        f.write(at3p_extract.to_oma(aus))
    p = subprocess.Popen(["ffmpeg", "-v", "error", "-nostdin", "-f", "oma", "-i", oma,
                          "-f", "s16le", "-ac", "2", "pipe:1"],
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    total = 0
    while True:
        b = p.stdout.read(1 << 20)
        if not b:
            break
        total += len(b)
    err = p.stderr.read().decode(errors="replace").strip()
    rc = p.wait()
    os.unlink(oma)
    return {"full_rc": rc, "full_samples": total // 4, "full_aus": len(aus),
            "full_samples_per_au": total / 4.0 / len(aus), "full_errors": err[:300]}


def merge_hist(a, b):
    for k, c in b.items():
        a.setdefault(k, Counter()).update(c)


def census_clip(iso, path, n, full_audio, index_packs, tmpdir):
    c = {"clip": n}
    e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % n)
    c["bytes"] = e.size
    c["zero_fraction"] = round(umd_clpi.zero_fraction(path, n), 3)
    c["has_clpi"] = n in iso.clip_infos()
    src = psmf_ref.Source(path, n)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        c["acct_exact"] = r.total() == r.bytes
        c["junk"] = r.acct["junk"]
        c["unaligned_packs"] = r.unaligned_packs
        c["short_bd"] = r.short_bd
        c["streams"] = {"%02x%s" % (sid, "" if sub is None else "/%02x" % sub): cnt
                        for (sid, sub), cnt in sorted(r.counts.items(),
                                                      key=lambda kv: (kv[0][0], kv[0][1] or 0))}
        # audio tracks
        c["audio"] = {}
        tracks = sorted(set(p.sub for p in r.packets if p.kind == "audio"))
        for t in tracks:
            es, marks = psmf_ref.es(src.mm, r, "audio", t)
            aus, info = at3p_extract.split_aus(es, marks)
            a = {"aus": len(aus), "resyncs": info["resyncs"], "lead": info["lead"],
                 "tail": info["tail"], "params": sorted("%04x" % p for p in info["params"]),
                 "hdr_tail": sorted(info["hdr_tail"])}
            pts = [m[1] for m in marks if m[1] is not None]
            a["pts_span_s"] = round((pts[-1] - pts[0]) / 90000.0, 2) if len(pts) > 1 else 0
            if aus and len(info["params"]) == 1:
                if full_audio:
                    a.update(full_decode(aus, tmpdir, n, t))
                cut = aus[:int(AUDIO_SAMPLE_PACKS * 2048 / 696 / 8)]
                oma = os.path.join(tmpdir, "c%d_t%d.oma" % (n, t))
                wav = os.path.join(tmpdir, "c%d_t%d.wav" % (n, t))
                with open(oma, "wb") as f:
                    f.write(at3p_extract.to_oma(cut))
                try:
                    o = at3p_extract.ffprobe_decode(oma, wav)
                    a.update({"ff_codec": o["codec"], "ff_rate": o["rate"],
                              "ff_channels": o["channels"], "ff_samples": o["samples"],
                              "ff_samples_per_au": o["samples"] / float(len(cut)),
                              "ff_decoded_aus": len(cut), "ff_peak": o["peak"],
                              "ff_lr_corr": None if o["lr_corr"] is None else round(o["lr_corr"], 3),
                              "ff_errors": o["errors"][:200]})
                except at3p_extract.At3pError as ex:
                    a["ff_fail"] = str(ex)[:300]
                for f in (oma, wav):
                    if os.path.exists(f):
                        os.unlink(f)
            c["audio"]["%02x" % t] = a
        # subtitles
        c["subs"] = {}
        for s in sorted(set(p.sub for p in r.packets if p.kind == "sub")):
            pes = [(p.pts, bytes(src.mm[p.payload_off:p.payload_off + p.payload_len]))
                   for p in r.packets if p.kind == "sub" and p.sub == s]
            us, info = umd_sub_extract.units(pes)
            bad = 0
            w = h = right = bottom = dur = 0
            pal = Counter()
            for u in us:
                try:
                    im = umd_sub_extract.png_info(u["png"])
                except Exception:
                    bad += 1
                    continue
                w, h = max(w, im["w"]), max(h, im["h"])
                right = max(right, u["hdr"]["x"] + im["w"])
                bottom = max(bottom, u["hdr"]["y"] + im["h"])
                dur = max(dur, u["hdr"]["duration"])
                pal["%s%d/%d%s" % (im["mode"], im["bits"], im["palette"],
                                   "t" if im["trns"] else "")] += 1
            c["subs"]["%02x" % s] = dict(units=len(us), bad_png=bad, max_w=w, max_h=h,
                                         max_right=right, max_bottom=bottom,
                                         max_duration=dur, png=dict(pal), **info)
        # video windows: head, and the EP entry nearest mid-clip
        wins = [0]
        if c["has_clpi"]:
            ep = umd_clpi.video_map(umd_clpi.from_iso(iso, n))
            if len(ep) > 4:
                wins.append(ep[len(ep) // 2][2])
        hist = {}
        slices = pics = 0
        errs = []
        for w0 in sorted(set(wins)):
            a0 = src.start + w0 * SEC
            rr = psmf_ref.parse(src.mm, a0, min(src.end, a0 + WINDOW_PACKS * SEC))
            es, _ = psmf_ref.es(src.mm, rr, "video")
            if a0 + WINDOW_PACKS * SEC < src.end:
                es = trim_to_aus(es)
            hh, s1, p1, e1 = trace(es)
            c.setdefault("video_missing_ref", 0)
            c["video_missing_ref"] += sum(1 for x in e1 if any(k in x for k in EXPECTED_ERR))
            e1 = [x for x in e1 if not any(k in x for k in EXPECTED_ERR)
                  and not x.strip().startswith("Last message repeated")]
            merge_hist(hist, hh)
            slices += s1
            pics += p1
            errs += e1
        c["video"] = {k: dict(sorted(v.items())) for k, v in hist.items() if v}
        c["video_slices"] = slices
        c["video_pictures"] = pics
        c["video_decode_errors"] = len(errs)
        c["video_decode_error_sample"] = errs[:3]
    finally:
        src.close()
    if c["has_clpi"] and c["zero_fraction"] < 0.5:
        chk, bad, wrapped, conv = umd_index_packs.verify(path, n, index_packs)
        c["index"] = {"gops_checked": chk, "problems": len(bad), "wrapped_sizes": wrapped,
                      "ref_end_fields": conv["field"], "ref_end_frames": conv["frame"],
                      "ref_end_either": conv["either"],
                      "sample": bad[:3]}
    return c


def census_iso(path, full_audio=False, index_packs=20000):
    v = {"file": os.path.basename(path)}
    with umd_iso.UmdIso(path) as iso, tempfile.TemporaryDirectory() as tmp:
        v["system_id"] = iso.system_id
        v["top_dirs"] = sorted(set(k.split("/")[1] for k in iso.files if k))
        v["multi_extent"] = iso.multi_extent
        v["umd_data"] = iso.umd_data()["raw"] if iso.umd_data() else None
        v["sfo"] = umd_sfo.parse(iso.read("/UMD_VIDEO/PARAM.SFO"))
        v["clips"] = iso.clips()
        v["clip_infos"] = iso.clip_infos()
        pl = umd_playlist.from_iso(iso)
        notes = []
        v["playlist_problems"] = umd_playlist.verify(iso, notes)
        v["playlist_notes"] = notes
        v["main_playlist"] = umd_playlist.main_playlist(pl)
        v["playlists"] = [{"name": e["name"], "items": [(i["clip_name"], i["in_pts"], i["out_pts"])
                                                        for i in e["items"]],
                           "marks": len(e["marks"])} for e in pl["playlists"]]
        v["clpi"] = {}
        for n in iso.clip_infos():
            c = umd_clpi.from_iso(iso, n)
            v["clpi"][n] = {"streams": ["%02x/%02x %s %s" % (s["stream_id"], s["substream_id"],
                                                             s["attr"], s.get("lang", ""))
                                        for s in c["streams"]],
                            "ep": {"%02x/%02x" % (m["stream_id"], m["substream_id"]): len(m["entries"])
                                   for m in c["ep_maps"]},
                            "start_pts": c["start_pts"], "end_pts": c["end_pts"],
                            "header_misc": c["header_misc"], "extra": c["extra"],
                            "ep_unk": c["ep_unk"],
                            "ep_flags_hi": sorted(set(e[0] >> 14 for m in c["ep_maps"]
                                                      for e in m["entries"])),
                            "verify": umd_clpi.verify(path, n)[:3]}
        v["clip_detail"] = [census_clip(iso, path, n, full_audio, index_packs, tmp)
                            for n in iso.clips()]
    return v


def _run(args):
    path, full_audio, index_packs = args
    try:
        return census_iso(path, full_audio, index_packs)
    except Exception:
        return {"file": os.path.basename(path), "error": traceback.format_exc()}


def report(vecs):
    """Human summary: per disc one line, then the corpus maxima and histograms."""
    ok = [v for v in vecs if "error" not in v]
    for v in vecs:
        if "error" in v:
            print("[err] %s\n%s" % (v["file"], v["error"]))
            continue
        cd = v["clip_detail"]
        feats = []
        field = [c["clip"] for c in cd if c["video"].get("field_pic_flag", {}).get(1)]
        if field:
            feats.append("FIELD-CODED clips %s" % field)
        bad = [c["clip"] for c in cd if not c["acct_exact"] or c["junk"]]
        if bad:
            feats.append("accounting/junk clips %s" % bad)
        dmg = [c["clip"] for c in cd if c["zero_fraction"] > 0.5]
        if dmg:
            feats.append("DAMAGED (zero-filled) clips %s" % dmg)
        main_clip = int(v["playlists"][v["main_playlist"]]["items"][0][0])
        mc = [c for c in cd if c["clip"] == main_clip][0]
        fp = mc["video"].get("field_pic_flag", {})
        kind = ("DAMAGED" if mc["zero_fraction"] > 0.5 else
                "field" if fp.get(1) and not fp.get(0) else
                "MIXED" if fp.get(1) else
                "progressive" if mc["video"].get("frame_mbs_only_flag", {}).get(1) else "frame")
        print("[ok]  %-36s %-26s clips %-2d playlists %-2d main #%d (clip %d: %s) %s" % (
            v["file"][:36], v["sfo"].get("TITLE", "")[:26], len(v["clips"]),
            len(v["playlists"]), v["main_playlist"], main_clip, kind, "; ".join(feats)))
    # corpus-wide
    H = {}
    mx = Counter()
    for v in ok:
        mx["playlists"] = max(mx["playlists"], len(v["playlists"]))
        mx["marks"] = max([mx["marks"]] + [p["marks"] for p in v["playlists"]])
        mx["clips"] = max(mx["clips"], len(v["clips"]))
        for n, c in v["clpi"].items():
            mx["clpi_streams"] = max(mx["clpi_streams"], len(c["streams"]))
            mx["ep_entries"] = max([mx["ep_entries"]] + list(c["ep"].values()))
        for c in v["clip_detail"]:
            if c["zero_fraction"] > 0.5:
                continue
            for k, hist in c["video"].items():
                for val, cnt in hist.items():
                    H.setdefault(k, Counter())[int(val)] += cnt
            mx["audio_tracks"] = max(mx["audio_tracks"], len(c["audio"]))
            mx["sub_tracks"] = max(mx["sub_tracks"], len(c["subs"]))
            for s in c["subs"].values():
                for k in ("max_w", "max_h", "max_right", "max_bottom", "max_duration"):
                    mx["sub_" + k] = max(mx["sub_" + k], s[k])
            if c["video_pictures"]:
                mx["slices_per_picture_x100"] = max(mx["slices_per_picture_x100"],
                                                    100 * c["video_slices"] // c["video_pictures"])
    print("\nMEASURED MAXIMA:", dict(mx))
    print("\nVIDEO HISTOGRAMS (value: slices/headers):")
    for k in HIST:
        if k in H:
            print("  %-44s %s" % (k, dict(sorted(H[k].items()))))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="*", help="images or directories (default $UMD_ISO_DIR)")
    ap.add_argument("--json", help="write the raw per-disc vectors here")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--full-audio", action="store_true",
                    help="decode every audio track end to end (slow)")
    ap.add_argument("--index-packs", type=int, default=20000,
                    help="packs per clip the 0xBF index verify covers")
    a = ap.parse_args(argv)
    isos = gather(a.paths)
    if not isos:
        print("umd_census: no images found (set UMD_ISO_DIR)")
        return 2
    work = [(p, a.full_audio, a.index_packs) for p in isos]
    if a.jobs > 1:
        with multiprocessing.Pool(a.jobs) as pool:
            vecs = pool.map(_run, work)
    else:
        vecs = [_run(w) for w in work]
    if a.json:
        with open(a.json, "w") as f:
            json.dump(vecs, f, indent=1, default=str)
    report(vecs)
    return 1 if any("error" in v for v in vecs) else 0


if __name__ == "__main__":
    sys.exit(main())
