#!/usr/bin/env python3
"""Census of `.PMF` files -- PSP game cutscenes and the UMD discs' ICON1.PMF -- before
the core claims to play them (docs/bare_streams.md; roadmap P8: "a census of PSP game
cutscenes before assuming the disc limits apply").

A .PMF is a PSMF header (psmf_ref.psmf_header) in front of the same program stream a
UMD .MPS carries. Every .PMF inside each image (.cso via tools/cso.py, .iso) or each
bare .pmf given is measured on its header and on the head of its stream (--packs):

  * header: version, stream offset / size vs the file, first / last PTS, stream table,
    EP-map entry counts, declared width / height
  * stream: byte accounting (psmf_ref.parse), PES per stream id / substream, extra video
    ids (0xE1..), 0xBF index packs, the first video PTS
  * video: ffmpeg trace_headers over the window (umd_census.trace): profile / level,
    entropy_coding_mode_flag (CABAC vs CAVLC), frame_mbs_only / MBAFF / field pictures,
    the coded size, decode errors (ffmpeg is the oracle)
  * audio: every ATRAC3plus params word (rate index, channels, frame bytes;
    at3p_extract.decode_params) and ffmpeg's decode of a sample (its own rate)

One image's exception never stops the run; any exception fails the exit code.

    pmf_census.py /path/to/PSP/games [more paths] [--json out.json] [--jobs N]
    pmf_census.py --sector0 $UMD_ISO_DIR      # the bare-file sniff vs every ISO's sector 0
"""
import argparse
import glob
import json
import multiprocessing
import os
import sys
import tempfile
import traceback
from collections import Counter

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_extract  # noqa: E402
import cso  # noqa: E402
import psmf_ref  # noqa: E402
import umd_census  # noqa: E402
import umd_iso  # noqa: E402

SEC = 2048
PACKS = 600                      # ~1.2 MB of stream: several GOPs, audio, the headers
EXTS = (".cso", ".iso", ".pmf")


def gather(paths):
    out = []
    for p in paths:
        if os.path.isdir(p):
            out += sorted(f for f in glob.glob(os.path.join(p, "**", "*"), recursive=True)
                          if f.lower().endswith(EXTS))
        else:
            out.append(p)
    return out


def open_image(path):
    """-> (UmdIso, closer) for an .iso / .cso."""
    if path.lower().endswith(".cso"):
        f = cso.CsoFile(path)
        return umd_iso.UmdIso(f), f.close
    iso = umd_iso.UmdIso(path)
    return iso, iso.close


def measure(name, head, read_stream, file_size, packs, tmpdir):
    """One .PMF: head = its first 2048 bytes, read_stream(off, n) -> bytes."""
    v = {"file": name, "bytes": file_size}
    h = psmf_ref.psmf_header(head, file_size)
    v["header"] = {k: h[k] for k in ("version", "stream_offset", "stream_size",
                                     "size_mismatch", "first_pts", "last_pts")}
    v["header"]["streams"] = ["%02x/%02x ep%d %dx%d ch%d r%d" % (
        e["sid"], e["sub"], e["ep_n"], e["w"], e["h"], e["ch"], e["rate"]) for e in h["streams"]]
    v["header"]["ep_entries"] = sum(e["ep_n"] for e in h["streams"])
    n = min(h["stream_end"] - h["stream_offset"], packs * SEC)
    buf = read_stream(h["stream_offset"], n)
    r = psmf_ref.parse(buf)
    v["acct_exact"] = r.total() == r.bytes
    v["junk"] = r.acct["junk"]
    v["streams"] = {"%02x%s" % (sid, "" if sub is None else "/%02x" % sub): c
                    for (sid, sub), c in sorted(r.counts.items(), key=lambda kv: (kv[0][0], kv[0][1] or 0))}
    v["extra_video"] = sorted("%02x" % sid for (sid, _s) in r.counts if 0xE1 <= sid <= 0xEF)
    v["index_packs"] = r.counts.get((0xBF, None), 0)
    vp = [p for p in r.packets if p.kind == "video" and p.pts is not None]
    v["first_video_pts"] = vp[0].pts if vp else None
    v["starts_with_pack"] = buf[:4] == b"\x00\x00\x01\xba"
    # video
    es, _ = psmf_ref.es(buf, r, "video")
    if n < h["stream_end"] - h["stream_offset"]:
        es = umd_census.trim_to_aus(es)
    hist, slices, pics, errs = umd_census.trace(es) if es else ({}, 0, 0, [])
    keep = ("profile_idc", "level_idc", "entropy_coding_mode_flag", "frame_mbs_only_flag",
            "mb_adaptive_frame_field_flag", "field_pic_flag", "pic_width_in_mbs_minus1",
            "pic_height_in_map_units_minus1", "chroma_format_idc", "transform_8x8_mode_flag",
            "num_slice_groups_minus1", "max_num_ref_frames", "pic_order_cnt_type",
            "weighted_pred_flag", "weighted_bipred_idc", "frame_cropping_flag", "slice_type")
    v["video"] = {k: dict(sorted(hist[k].items())) for k in keep if k in hist and hist[k]}
    v["video_pictures"] = pics
    errs = [e for e in errs if not any(k in e for k in umd_census.EXPECTED_ERR)
            and not e.strip().startswith("Last message repeated")]
    v["video_decode_errors"] = len(errs)
    v["video_decode_error_sample"] = errs[:2]
    # audio
    v["audio"] = {}
    for t in sorted(set(p.sub for p in r.packets if p.kind == "audio")):
        aes, marks = psmf_ref.es(buf, r, "audio", t)
        aus, info = at3p_extract.split_aus(aes, marks)
        a = {"aus": len(aus), "resyncs": info["resyncs"],
             "params": sorted("%04x" % p for p in info["params"])}
        a["decoded"] = [at3p_extract.decode_params(p) for p in sorted(info["params"])]
        if aus and len(info["params"]) == 1:
            oma = os.path.join(tmpdir, "a.oma")
            with open(oma, "wb") as f:
                f.write(at3p_extract.to_oma(aus))
            try:
                o = at3p_extract.ffprobe_decode(oma)
                a.update({"ff_codec": o["codec"], "ff_rate": o["rate"],
                          "ff_channels": o["channels"], "ff_errors": o["errors"][:200]})
            except at3p_extract.At3pError as ex:
                a["ff_fail"] = str(ex)[:200]
        v["audio"]["%02x" % t] = a
    return v


def census_image(path, packs):
    out = []
    try:
        iso, close = open_image(path)
    except (umd_iso.IsoError, cso.CsoError) as ex:
        # an image this walk cannot read (not ISO 9660): counted, not a census failure
        return [{"file": os.path.basename(path), "unreadable_image": str(ex)}]
    try:
        with tempfile.TemporaryDirectory() as tmp:
            for k in sorted(iso.files):
                e = iso.files[k]
                if e.is_dir or not k.upper().endswith(".PMF"):
                    continue
                name = "%s:%s" % (os.path.basename(path), k)
                if e.lba * SEC + e.size > iso.image_bytes:
                    # a file the image does not hold (a trimmed rip): counted, not measured
                    out.append({"file": name, "bytes": e.size, "past_end": True})
                    continue
                try:
                    head = iso.read_sectors(e.lba, 1)
                    if head[:4] != psmf_ref.PSMF_MAGIC:
                        out.append({"file": name, "bytes": e.size, "no_magic": head[:8].hex()})
                        continue
                    def rd(off, n, e=e):
                        iso.f.seek(e.lba * SEC + off)
                        return iso.f.read(n)
                    out.append(measure(name, head, rd, e.size, packs, tmp))
                except Exception:
                    out.append({"file": name, "error": traceback.format_exc()})
    finally:
        close()
    return out


def census_bare(path, packs):
    with open(path, "rb") as f, tempfile.TemporaryDirectory() as tmp:
        size = os.fstat(f.fileno()).st_size
        head = f.read(SEC)

        def rd(off, n):
            f.seek(off)
            return f.read(n)
        return [measure(os.path.basename(path), head, rd, size, packs, tmp)]


def _run(args):
    path, packs = args
    try:
        if path.lower().endswith(".pmf"):
            return census_bare(path, packs)
        return census_image(path, packs)
    except Exception:
        return [{"file": os.path.basename(path), "error": traceback.format_exc()}]


def report(vs):
    skip = ("error", "no_magic", "past_end", "unreadable_image")
    ok = [v for v in vs if not any(k in v for k in skip)]
    for v in vs:
        if "error" in v:
            print("[err] %s\n%s" % (v["file"], v["error"]))
    nm = [v for v in vs if "no_magic" in v]
    print("PMF files: %d measured, %d without the PSMF magic, %d errors" % (
        len(ok), len(nm), sum(1 for v in vs if "error" in v)))
    if nm:
        print("  no magic (first bytes): %s" % dict(Counter(v["no_magic"] for v in nm)))
    pe = [v for v in vs if "past_end" in v]
    if pe:
        print("  %d PMF files lie past their image's end (trimmed rips): %s" % (
            len(pe), sorted(set(v["file"].split(":")[0] for v in pe))))
    for v in vs:
        if "unreadable_image" in v:
            print("  unreadable image %s: %s" % (v["file"], v["unreadable_image"]))
    H = {}

    def bump(k, val):
        H.setdefault(k, Counter())[val] += 1
    for v in ok:
        hd = v["header"]
        bump("version", hd["version"])
        bump("stream_offset", hex(hd["stream_offset"]))
        bump("size_mismatch", hd["size_mismatch"])
        bump("first_pts", hd["first_pts"])
        bump("ep_entries>0", hd["ep_entries"] > 0)
        bump("acct_exact", v["acct_exact"] and not v["junk"])
        bump("starts_with_pack", v["starts_with_pack"])
        bump("first_video_pts", v["first_video_pts"])
        bump("index_packs>0", v["index_packs"] > 0)
        bump("extra_video", ",".join(v["extra_video"]) or "-")
        bump("audio_tracks", len(v["audio"]))
        bump("decode_errors>0", v["video_decode_errors"] > 0)
        vd = v["video"]
        for k in ("profile_idc", "level_idc", "entropy_coding_mode_flag", "frame_mbs_only_flag",
                  "mb_adaptive_frame_field_flag", "field_pic_flag", "chroma_format_idc",
                  "transform_8x8_mode_flag", "num_slice_groups_minus1", "pic_order_cnt_type",
                  "weighted_pred_flag", "weighted_bipred_idc", "frame_cropping_flag"):
            for val in vd.get(k, {}):
                bump(k, int(val))
        w = vd.get("pic_width_in_mbs_minus1", {})
        hh = vd.get("pic_height_in_map_units_minus1", {})
        if w and hh:
            fm = 1 if vd.get("frame_mbs_only_flag", {}).get(1) else 2
            bump("coded_size", "%dx%d" % (16 * (int(max(w)) + 1), 16 * fm * (int(max(hh)) + 1)))
        for a in v["audio"].values():
            bump("audio_params", ",".join(a["params"]) or "-")
            for d in a["decoded"]:
                bump("audio_rate", d["rate"])
                bump("audio_chan_id", d["chan_id"])
            bump("ff_rate", a.get("ff_rate", a.get("ff_fail", "n/a")))
    for k in sorted(H):
        print("  %-30s %s" % (k, dict(sorted(H[k].items(), key=lambda kv: str(kv[0])))))
    return 0


def sector0(paths):
    """The bare-file sniff's precondition: no ISO's sector 0 looks like a stream."""
    hits = 0
    isos = [p for p in gather(paths) if p.lower().endswith(".iso")]
    for p in isos:
        with open(p, "rb") as f:
            b = f.read(4)
        if b == b"\x00\x00\x01\xba" or b == psmf_ref.PSMF_MAGIC:
            print("SNIFF CLASH %s: sector 0 starts %s" % (p, b.hex()))
            hits += 1
    print("sector0: %d images, %d whose sector 0 reads as a bare stream" % (len(isos), hits))
    return 1 if hits or not isos else 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+", help="images, .pmf files or directories")
    ap.add_argument("--json")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--packs", type=int, default=PACKS)
    ap.add_argument("--sector0", action="store_true",
                    help="check every .iso's sector 0 against the bare-stream sniff")
    a = ap.parse_args(argv)
    if a.sector0:
        return sector0(a.paths)
    work = [(p, a.packs) for p in gather(a.paths)]
    if not work:
        print("pmf_census: nothing found")
        return 2
    if a.jobs > 1:
        with multiprocessing.Pool(a.jobs) as pool:
            res = pool.map(_run, work, chunksize=1)
    else:
        res = [_run(w) for w in work]
    vs = [v for r in res for v in r]
    if a.json:
        with open(a.json, "w") as f:
            json.dump(vs, f, indent=1, default=str)
    report(vs)
    return 1 if any("error" in v for v in vs) else 0


if __name__ == "__main__":
    sys.exit(main())
