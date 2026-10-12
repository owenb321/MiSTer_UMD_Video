#!/usr/bin/env python3
"""at3p_extract on synthetic audio ES (no media, no ffmpeg): the params word read the
way ffmpeg's omadec.c reads it, AU splitting from the FAP, a resync counted (not
skipped), the OMA header bytes, and mixed params refused."""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import at3p_extract as A  # noqa: E402

T = S.Score("test_at3p_extract")

print("[params]")
T.check("0x4855 = 48k stereo 688", A.decode_params(0x4855),
        {"rate": 48000, "chan_id": 2, "frame_bytes": 688})
T.check("0x2455 = 44.1k mono 688", A.decode_params(0x2455),
        {"rate": 44100, "chan_id": 1, "frame_bytes": 688})

print("[split]")
HDR = bytes.fromhex("0fd0485500000000")
frames = [bytes([i]) * 688 for i in range(1, 6)]
aus = b"".join(HDR + f for f in frames)
lead = b"\x77" * 40                         # the tail of an AU that began before the cut
es = lead + aus + b"\x0f\xd0\x48"           # a partial header at the end
# two PES: the first's FAP skips the lead; the second starts inside AU 2
marks = [(0, 90000, None, 40), (1000, 93000, None, 40 + 2 * 696 - 1000)]
got, info = A.split_aus(es, marks)
T.check("AU count", len(got), 5)
T.check("frames exact", [f for _o, _p, f in got], frames)
T.check("lead / tail / resyncs", (info["lead"], info["tail"], info["resyncs"]), (40, 3, 0))
T.check("params seen", info["params"], {0x4855: 5})

bad = bytearray(es)
bad[40 + 696] = 0x00                        # break AU 2's sync
got, info = A.split_aus(bytes(bad), marks)
T.check("resync counted", info["resyncs"], 1)
T.check("resync lands on the next PES's FAP (AU 3)", [f[0] for _o, _p, f in got],
        [1, 3, 4, 5])

print("[oma]")
h = A.oma_header(0x4855)
T.check("EA3 tag/version/size/enc", (h[:3], h[3], struct.unpack(">H", h[4:6])[0], h[6:8]),
        (b"EA3", 1, 96, b"\xff\xff"))
T.check("codec id + params", h[0x20:0x24].hex(), "01004855")
got, _ = A.split_aus(es, marks)
T.check("oma body = frames only", A.to_oma(got)[96:], b"".join(frames))
mixed = got[:2] + [(0, 0x2455, b"")]
T.raises("mixed params refused", lambda: A.to_oma(mixed), A.At3pError, "mixed")
T.finish()
