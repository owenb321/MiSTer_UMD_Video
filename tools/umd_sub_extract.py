#!/usr/bin/env python3
"""Subtitle units out of a UMD .MPS (0xBD substreams 0x80-0x9F) -- the P7 golden input.

A unit starts in a PES that carries a PTS and continues through the following PES of
the same substream until its declared length is reached. Subtitle PES carry a 2-BYTE
sub-header [sub, 0x00] (psmf_ref strips it) -- not the audio's 4: only with 2 do the
unit lengths add up, whether a unit fills one PES or spans two. The unit (decoded by
this tool on the local discs, docs/umd_video_format.md "Subtitles"; big-endian):

    +0   u32 unit_len        bytes in the unit AFTER this field
    +4   "0088"              magic
    +8   u32 duration        90 kHz ticks the image stays up (a multiple of 3003 seen)
    +12  u16 (?)             0x0010 on every unit seen
    +14  u16 x, u16 y        top-left position on the 720x480 frame
    +18  u16 (?)             0
    +20  a PNG               4-bit indexed (PLTE, often tRNS), zlib/DEFLATE

A continuation PES can be tiny: Akira has one carrying the single byte 0x82 -- the
last byte of a PNG's IEND CRC. A PES with no PTS and no unit in progress is counted
as `stray`/`orphan`, never glued onto anything.

    umd_sub_extract.py disc.iso --clip 1 [--sub 0x80] [--png-dir DIR] [--json]
"""
import argparse
import io
import json
import os
import struct
import sys

MAGIC = b"0088"
HDR = 20


class SubError(Exception):
    pass


def parse_header(b):
    if len(b) < HDR or b[4:8] != MAGIC:
        raise SubError("no '0088' unit header (%s)" % b[:HDR].hex())
    ln, = struct.unpack(">I", b[0:4])
    dur, = struct.unpack(">I", b[8:12])
    f12, x, y, f18 = struct.unpack(">HHHH", b[12:20])
    return {"len": ln + 4, "duration": dur, "f12": f12, "x": x, "y": y, "f18": f18}


def units(pes):
    """pes: [(pts, payload)] of ONE substream, in stream order -> (units, info).
    units: [{"pts", "hdr", "png"}]; info: counts of stray / orphan / overrun PES."""
    out = []
    info = {"stray": 0, "orphan": 0, "overrun": 0, "truncated": 0}
    cur = None
    for pts, pl in pes:
        if pts is not None and len(pl) >= HDR and pl[4:8] == MAGIC:
            if cur is not None:
                info["truncated"] += 1          # the previous unit never completed
            cur = {"pts": pts, "buf": bytearray(pl)}
        elif cur is not None:
            cur["buf"] += pl
        else:
            info["stray" if len(pl) < HDR else "orphan"] += 1
            continue
        h = parse_header(cur["buf"])
        if len(cur["buf"]) >= h["len"]:
            if len(cur["buf"]) > h["len"]:
                info["overrun"] += 1
            b = bytes(cur["buf"][:h["len"]])
            out.append({"pts": cur["pts"], "hdr": h, "png": b[HDR:]})
            cur = None
    if cur is not None:
        info["truncated"] += 1
    return out, info


def png_info(png):
    """Validate with PIL (an independent PNG decoder) -> dict, or raise SubError."""
    from PIL import Image
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        raise SubError("unit payload is not a PNG (%s)" % png[:8].hex())
    if not png.endswith(b"IEND\xaeB`\x82"):
        raise SubError("PNG does not end at the unit's end (no IEND there)")
    im = Image.open(io.BytesIO(png))
    im.load()
    pal = im.getpalette() or []
    return {"w": im.width, "h": im.height, "mode": im.mode,
            "bits": png[24], "colour_type": png[25],
            "palette": len(pal) // 3, "trns": "transparency" in im.info}


def extract(iso_path, clip, sub=None, packs=None):
    """-> {substream: (units, info)} for one clip (every 0x80-0x9F if sub is None)."""
    import psmf_ref
    src = psmf_ref.Source(iso_path, clip)
    src.limit(packs)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        subs = sorted(set(p.sub for p in r.packets if p.kind == "sub"))
        if sub is not None:
            subs = [s for s in subs if s == sub]
        res = {}
        for s in subs:
            pes = [(p.pts, bytes(src.mm[p.payload_off:p.payload_off + p.payload_len]))
                   for p in r.packets if p.kind == "sub" and p.sub == s]
            res[s] = units(pes)
    finally:
        src.close()
    return res


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--clip", type=int, required=True)
    ap.add_argument("--sub", type=lambda s: int(s, 0), help="0x80-0x9F (default: all)")
    ap.add_argument("--packs", type=int)
    ap.add_argument("--png-dir", help="write each unit as <sub>_<pts>.png")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    res = extract(a.iso, a.clip, a.sub, a.packs)
    rep = {}
    rc = 0
    for s, (us, info) in sorted(res.items()):
        bad = 0
        sizes = []
        for u in us:
            try:
                u["img"] = png_info(u["png"])
                sizes.append((u["img"]["w"], u["img"]["h"]))
            except Exception as e:           # PIL raises its own types
                u["err"] = str(e)
                bad += 1
            if a.png_dir:
                os.makedirs(a.png_dir, exist_ok=True)
                with open(os.path.join(a.png_dir, "%02x_%010d.png" % (s, u["pts"])), "wb") as f:
                    f.write(u["png"])
        rep["%02x" % s] = {
            "units": len(us), "bad_png": bad, **info,
            "max_w": max((w for w, _ in sizes), default=0),
            "max_h": max((h for _, h in sizes), default=0),
            "max_right": max((u["hdr"]["x"] + u["img"]["w"] for u in us if "img" in u), default=0),
            "max_bottom": max((u["hdr"]["y"] + u["img"]["h"] for u in us if "img" in u), default=0),
            "max_duration": max((u["hdr"]["duration"] for u in us), default=0),
            "f12": sorted(set(u["hdr"]["f12"] for u in us)),
            "f18": sorted(set(u["hdr"]["f18"] for u in us)),
            "modes": sorted(set("%s/%d-bit/pal%d%s" % (u["img"]["mode"], u["img"]["bits"],
                                                      u["img"]["palette"],
                                                      "/tRNS" if u["img"]["trns"] else "")
                                for u in us if "img" in u)),
        }
        rc |= bool(bad or info["truncated"] or info["overrun"] or info["orphan"])
    if a.json:
        json.dump(rep, sys.stdout, indent=1)
        print()
    else:
        if not rep:
            print("no subtitle substreams")
        for s, v in rep.items():
            print("sub 0x%s: %s" % (s, ", ".join("%s=%s" % kv for kv in v.items())))
    return rc


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SubError as e:
        sys.exit("umd_sub_extract: %s" % e)
