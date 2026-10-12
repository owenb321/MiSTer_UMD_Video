#!/usr/bin/env python3
"""umd_sub_extract.units()/png_info() on synthetic subtitle PES built from the measured
layout (docs/umd_video_format.md "Subtitles"), with a real 4-bit indexed PNG made by
PIL: a unit in one PES, a unit split so its last PES carries ONE byte (Akira's case),
a stray PES, a truncated unit, and a unit whose payload is not a PNG."""
import io
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_sub_extract as U  # noqa: E402
from PIL import Image  # noqa: E402

T = S.Score("test_umd_sub_extract")


def png(w, h):
    im = Image.new("P", (w, h), 0)
    im.putpalette([i * 16 for i in range(16) for _ in range(3)])
    for x in range(w):
        im.putpixel((x, h // 2), x % 16)
    b = io.BytesIO()
    im.save(b, format="PNG", bits=4, transparency=0)
    return b.getvalue()


def unit(p, dur, x, y):
    body = b"0088" + struct.pack(">IHHHH", dur, 0x10, x, y, 0) + p
    return struct.pack(">I", len(body)) + body


p1, p2 = png(300, 40), png(500, 70)
u1, u2 = unit(p1, 378378, 210, 400), unit(p2, 594594, 110, 379)
pes = [(90000, u1),
       (500000, u2[:len(u2) - 1]), (None, u2[-1:]),        # last PES = 1 byte (0x82)
       (None, b"\x55")]                                      # stray: no unit open
got, info = U.units(pes)
T.check("last byte of the split unit is IEND's", u2[-1:], b"\x82")
T.check("unit count", len(got), 2)
T.check("header", [(u["pts"], u["hdr"]["duration"], u["hdr"]["x"], u["hdr"]["y"],
                    u["hdr"]["f12"]) for u in got],
        [(90000, 378378, 210, 400, 16), (500000, 594594, 110, 379, 16)])
T.check("PNG bytes exact", [u["png"] for u in got], [p1, p2])
T.check("counters", info, {"stray": 1, "orphan": 0, "overrun": 0, "truncated": 0})
i2 = U.png_info(got[1]["png"])
T.check("PIL: 500x70 P 4-bit 16-colour tRNS", (i2["w"], i2["h"], i2["mode"], i2["bits"],
                                               i2["palette"], i2["trns"]),
        (500, 70, "P", 4, 16, True))

print("[faults]")
got, info = U.units([(1, u1[:100]), (2, u2)])
T.check("a unit cut short is counted truncated", (len(got), info["truncated"]), (1, 1))
got, info = U.units([(1, u1 + b"\x00\x00")])
T.check("bytes past the declared length counted overrun", info["overrun"], 1)
got, info = U.units([(None, u1)])
T.check("a full unit without a PTS is an orphan", (len(got), info["orphan"]), (0, 1))
T.raises("not a PNG", lambda: U.png_info(b"GIF89a" + bytes(40)), U.SubError, "not a PNG")
T.raises("PNG not ending at the unit end", lambda: U.png_info(p1 + b"\x00"), U.SubError,
         "IEND")
T.raises("bad magic", lambda: U.parse_header(bytes(4) + b"0099" + bytes(12)), U.SubError,
         "0088")
T.finish()
