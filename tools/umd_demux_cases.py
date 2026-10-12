#!/usr/bin/env python3
"""Synthetic program streams for the P2 ps_demux bench (bench/umd/run_ps_demux.sh),
written to bench/umd/fixtures/gen/ with their goldens (tools/psmf_golden.py).

Built from ISO 13818-1 and docs/umd_video_format.md with tools/tests/umd_synth.py's
pack builder, so every path the P2 surgery touched is exercised, including the ones no
disc window is guaranteed to hit:

    syn_ps   pack stuffing; a system header; video PES with PTS, PTS+DTS, no PTS, and
             extra header stuffing; a 0xBF packet whose payload holds 00 00 01 E0 and
             00 00 01 BA (must be skipped by length, never hunted); padding; audio
             tracks 0x00 and 0x05 interleaved with 0x05 selected, whose FIRST PES has a
             FAP past its payload (dropped: no access unit starts there) and whose
             second has FAP 5 (the first 5 payload bytes are a partial AU); track 0x0D,
             which a 3-bit compare would alias onto 0x05; an audio PES with no PTS;
             subtitles 0x80 and 0x9C with 0x9C selected; a 0xBD id outside both ranges
             (0x40); a PES whose substream id is its only payload byte
    syn_ps0  the same stream with audio 0x00 and no subtitle selected

    umd_demux_cases.py [--dir DIR]      -> prints one "stem aud sub" per line
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tests"))
import psmf_golden  # noqa: E402
import umd_fixture as F  # noqa: E402
import umd_synth as S  # noqa: E402

SEC = 2048


def pes(sid, payload, pts=None, dts=None, stuffing=0):
    """MPEG-2 PES with optional PTS/DTS and extra 0xFF header stuffing."""
    flags, opt = 0, b""
    if pts is not None and dts is not None:
        flags, opt = 0xC0, S.pts_bytes(pts, 3) + S.pts_bytes(dts, 1)
    elif pts is not None:
        flags, opt = 0x80, S.pts_bytes(pts, 2)
    opt += b"\xff" * stuffing
    body = bytes([0x81, flags, len(opt)]) + opt + payload
    return b"\x00\x00\x01" + bytes([sid]) + struct.pack(">H", len(body)) + body


def aud(sub, payload, fap, pts=None):
    return pes(0xBD, bytes([sub, 0, fap >> 8, fap & 0xFF]) + payload, pts)


def subt(sub, payload, pts=None):
    return pes(0xBD, bytes([sub, 0]) + payload, pts)


def au(tag, n):
    """n bytes that start like an AT3+ access unit header and name the tag."""
    return (b"\x0f\xd0\x48\x55\x00\x00\x00\x00" + bytes([tag]) * n)[:n]


def pack(packets, stuffing=0):
    body = S.pack_header(90000, stuffing=stuffing) + b"".join(packets)
    room = SEC - len(body)
    assert room == 0 or room >= 6, room
    if room:
        body += S.pes(0xBE, b"\xff" * (room - 6))
    return body


def syn_ps():
    sysh = S.pes(0xBB, bytes([0x80, 0x01, 0x01, 0x04, 0xE1, 0xFF]))
    trap = S.pes(0xBF, b"\x01\xe0" + b"\x00\x00\x01\xe0\x00\x10" + b"\x00\x00\x01\xba" * 4)
    packs = [
        pack([sysh, pes(0xE0, b"\x00\x00\x00\x01\x09\xf0" + bytes(range(200)), pts=90000,
                        dts=87000)], stuffing=3),
        pack([trap, pes(0xE0, bytes(range(50, 250)), pts=93003)]),
        pack([aud(0x05, au(0xA1, 300), 400, pts=90000),          # FAP past payload
              aud(0x00, au(0x10, 200), 0, pts=90000)]),
        pack([aud(0x05, b"tail!" + au(0xA2, 400), 5, pts=92000),  # partial AU first
              subt(0x80, b"U80" * 40, pts=90000)]),
        pack([pes(0xE0, b"no pts here" * 20),                    # video without a PTS
              pes(0xBD, bytes([0x40]) + b"other" * 10, pts=90000),
              pes(0xBD, bytes([0x05]))]),                        # id is the only byte
        pack([subt(0x9C, b"\x00\x00\x01\xba" + b"S9C" * 60, pts=91000),
              aud(0x05, au(0xA3, 300), 0)]),                     # audio PES, no PTS
        pack([pes(0xE0, bytes(range(256)) * 2, pts=96006, stuffing=7),
              subt(0x9C, b"continuation" * 5)]),
        pack([aud(0x05, au(0xA4, 500), 3, pts=95000), aud(0x00, au(0x11, 100), 0),
              aud(0x0D, au(0xDD, 100), 0, pts=95000)]),          # aliases 0x05 in 3 bits
    ]
    return b"".join(packs)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=F.OUT_DIR)
    a = ap.parse_args(argv)
    os.makedirs(a.dir, exist_ok=True)
    data = syn_ps()
    lines = []
    for stem, aud_t, sub_t in (("dmx_syn_ps", 0x05, 0x1C), ("dmx_syn_ps0", 0x00, None)):
        path = os.path.join(a.dir, stem)
        F.write_bytes(path + ".hex", data)
        psmf_golden.write(path, aud_t, sub_t)
        lines.append("%s %d %s" % (stem, aud_t, "-" if sub_t is None else sub_t))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
