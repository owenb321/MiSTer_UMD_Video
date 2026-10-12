#!/usr/bin/env python3
"""ATRAC3plus access units out of a UMD .MPS, wrapped as OMA so ffmpeg decodes them --
the audio oracle's front end (P6 scores the fabric decoder against ffmpeg's output).

An audio PES (0xBD, substream 0x00-0x0F; tools/psmf_ref.py) carries a 4-byte
sub-header [sub, 0, FAP hi, FAP lo]; its payload is a byte stream of access units, each

    0F D0  u16 params  00 00 00 00      8-byte AU header (sync 0x0FD0)
    <frame>                             ((params & 0x3FF) * 8 + 8) bytes

and the FAP is the offset of the first AU header that starts in that PES. `params` is
the 16-bit ATRAC3plus parameter word the PSP/OMA world uses (ffmpeg omadec.c reads it
the same way): sample-rate index = bits 15..13 (0 32k, 1 44.1k, 2 48k, 3 88.2k, 4 96k),
channel id = bits 12..10 (1 mono, 2 stereo, 3-7 multichannel), frame size as above.
Measured (census, 256 tracks, all 48 kHz stereo): 0x4855 (688-byte frames, ~129 kbit/s)
on 231, 0x483F (512, ~96 kbit/s) on 18 -- including Godzilla's FEATURE -- 0x487F (1024,
~192 kbit/s) on 4 and 0x482A (344, ~64 kbit/s) on 3: the frame size
comes from each AU's header, never a constant.

The frames are re-wrapped in a 96-byte "EA3" OMA header (codec id 1 = ATRAC3plus, the
same 24-bit params) and handed to ffmpeg. Nothing is decoded here.

    at3p_extract.py disc.iso --clip 1 [--track 0] [--packs N] -o a.oma [--wav a.wav]
"""
import argparse
import json
import os
import struct
import subprocess
import sys

SYNC = b"\x0f\xd0"
AU_HDR = 8
SRATES = {0: 32000, 1: 44100, 2: 48000, 3: 88200, 4: 96000}
OMA_HDR = 96
OMA_CODEC_ATRAC3P = 1


class At3pError(Exception):
    pass


def decode_params(p):
    """16-bit params word -> dict(rate, channels_id, frame_bytes)."""
    return {"rate": SRATES.get((p >> 13) & 7), "chan_id": (p >> 10) & 7,
            "frame_bytes": (p & 0x3FF) * 8 + 8}


def split_aus(es, marks):
    """Walk the audio ES from the first PES's FAP, AU by AU (header + frame length from
    the header's own params). On a missing sync, resynchronise at the next PES's FAP
    and COUNT it -- never skip silently.

    Returns (aus, info): aus = [(es_offset, params, frame_bytes_view)], info = dict with
    resyncs, lead (bytes before the first AU), tail (bytes after the last whole AU),
    params set, header tails seen (bytes 4..7)."""
    starts = [o + f for o, _pts, _dts, f in marks if f is not None and o + f < len(es)]
    info = {"resyncs": 0, "lead": 0, "tail": 0, "params": {}, "hdr_tail": {}}
    aus = []
    if not starts:
        return aus, info
    p = starts[0]
    info["lead"] = p
    si = 0
    while p + AU_HDR <= len(es):
        if es[p:p + 2] != SYNC:
            info["resyncs"] += 1
            while si < len(starts) and starts[si] <= p:
                si += 1
            if si >= len(starts):
                info["tail"] = len(es) - p
                break
            p = starts[si]
            continue
        prm = (es[p + 2] << 8) | es[p + 3]
        fb = decode_params(prm)["frame_bytes"]
        if p + AU_HDR + fb > len(es):
            info["tail"] = len(es) - p
            break
        info["params"][prm] = info["params"].get(prm, 0) + 1
        t = es[p + 4:p + 8].hex()
        info["hdr_tail"][t] = info["hdr_tail"].get(t, 0) + 1
        aus.append((p, prm, es[p + AU_HDR:p + AU_HDR + fb]))
        p += AU_HDR + fb
    else:
        info["tail"] = len(es) - p          # fewer than a header's worth left
    return aus, info


def oma_header(params):
    """96-byte EA3 header: 'EA3', version 1, header size 0x60, encryption id 0xFFFF
    (none), codec id at 0x20, 24-bit codec params at 0x21."""
    h = bytearray(OMA_HDR)
    h[0:3] = b"EA3"
    h[3] = 1
    h[4:6] = struct.pack(">H", OMA_HDR)
    h[6:8] = b"\xff\xff"
    h[0x20] = OMA_CODEC_ATRAC3P
    h[0x21:0x24] = struct.pack(">I", params)[1:]
    return bytes(h)


def to_oma(aus):
    prms = set(p for _o, p, _f in aus)
    if len(prms) != 1:
        raise At3pError("mixed AU params %s: one OMA file cannot carry them"
                        % sorted("%04x" % p for p in prms))
    prm = prms.pop()
    return oma_header(prm) + b"".join(f for _o, _p, f in aus)


def extract(iso_path, clip, track=0, packs=None):
    """-> (aus, info, marks) for one audio substream of one clip."""
    import psmf_ref
    src = psmf_ref.Source(iso_path, clip)
    src.limit(packs)
    try:
        r = psmf_ref.parse(src.mm, src.start, src.end)
        es, marks = psmf_ref.es(src.mm, r, "audio", track)
    finally:
        src.close()
    aus, info = split_aus(es, marks)
    return aus, info, marks


def ffprobe_decode(oma_path, wav_path=None):
    """Decode with ffmpeg; returns ffprobe's view of the decoded stream plus the
    decoded sample count, peak and L/R correlation (wav_stats) -- the oracle's own report."""
    cmd = ["ffmpeg", "-v", "error", "-y", "-f", "oma", "-i", oma_path, "-f", "wav",
           wav_path or os.devnull]
    rc = subprocess.run(cmd, capture_output=True, text=True)
    if rc.returncode:
        raise At3pError("ffmpeg failed: %s" % rc.stderr.strip()[:400])
    pr = subprocess.run(["ffprobe", "-v", "error", "-f", "oma", "-show_streams", "-of",
                         "json", oma_path], capture_output=True, text=True)
    st = json.loads(pr.stdout)["streams"][0]
    out = {"codec": st.get("codec_name"), "rate": int(st.get("sample_rate", 0)),
           "channels": st.get("channels"), "errors": rc.stderr.strip()}
    if wav_path:
        out.update(wav_stats(wav_path))
    return out


def wav_stats(path, stride=7):
    """Sample count, peak, and the L/R correlation of a decoded s16 stereo WAV. A wrong
    frame alignment or a mis-set parameter word decodes to noise or silence; real film
    audio has |corr| well above 0 and a peak well below full scale (an instrument that
    can say "nothing real happened", CLAUDE.md)."""
    import array
    import math
    import wave
    w = wave.open(path)
    n, ch = w.getnframes(), w.getnchannels()
    d = array.array("h", w.readframes(n))
    w.close()
    out = {"samples": n, "peak": max((abs(x) for x in d), default=0), "lr_corr": None}
    if ch == 2 and n > 1:
        l, r = d[0::2 * stride], d[1::2 * stride]
        ml, mr = sum(l) / len(l), sum(r) / len(r)
        sl = math.sqrt(sum((x - ml) ** 2 for x in l))
        sr = math.sqrt(sum((x - mr) ** 2 for x in r))
        if sl and sr:
            out["lr_corr"] = sum((a - ml) * (b - mr) for a, b in zip(l, r)) / (sl * sr)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--clip", type=int, required=True)
    ap.add_argument("--track", type=int, default=0, help="audio substream 0x00-0x0F")
    ap.add_argument("--packs", type=int, help="only the first N packs of the clip")
    ap.add_argument("-o", "--out", required=True, help="the .oma to write")
    ap.add_argument("--wav", help="also decode with ffmpeg to this .wav")
    a = ap.parse_args(argv)
    aus, info, marks = extract(a.iso, a.clip, a.track, a.packs)
    if not aus:
        raise At3pError("no access units in substream 0x%02x" % a.track)
    with open(a.out, "wb") as f:
        f.write(to_oma(aus))
    prm = next(iter(info["params"]))
    d = decode_params(prm)
    print("substream 0x%02x: %d AUs, params %s -> %s Hz, chan id %d, %d-byte frames; "
          "lead %d, tail %d, resyncs %d, header tails %s" % (
              a.track, len(aus), ",".join("%04x" % p for p in info["params"]), d["rate"],
              d["chan_id"], d["frame_bytes"], info["lead"], info["tail"], info["resyncs"],
              info["hdr_tail"]))
    if a.wav:
        o = ffprobe_decode(a.out, a.wav)
        print("ffmpeg: %s %d Hz %s ch, %d samples (%.1f per AU, %.2f s), peak %d, "
              "L/R corr %s%s" % (
                  o["codec"], o["rate"], o["channels"], o["samples"],
                  o["samples"] / float(len(aus)), o["samples"] / float(o["rate"] or 1),
                  o["peak"], "%.2f" % o["lr_corr"] if o["lr_corr"] is not None else "-",
                  "  STDERR: " + o["errors"] if o["errors"] else ""))
    return 0 if not info["resyncs"] else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except At3pError as e:
        sys.exit("at3p_extract: %s" % e)
