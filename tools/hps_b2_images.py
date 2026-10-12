#!/usr/bin/env python3
"""B2's test images (docs/hps_host.md §6 "B2, the procedure", step 3): the PNGs the rig's
probe decodes (main/support/umd/umd_b2.cpp, "b2 decode") to time the HPS subtitle decode.

    hps_b2_images.py OUT_DIR [CORPUS]

Writes, with a list OUT_DIR/b2.txt ("path ux uy name", tools/hps_sub_check.cpp's format, so
B1's .sim/hps_sub/check_sys scores each one against its oracle before the rig sees it):

  b2_noise.png     720 x 480 RGBA16, every row Paeth-filtered, random filtered bytes: the
                   spec-sized rectangle (subtitles.md: any rectangle inside 720 x 480) at its
                   largest. zlib can only store it, so inflate is cheap and the Paeth unfilter,
                   the 16-bit expansion and the 1,382,400-byte plane write dominate.
  b2_lowent.png    the same with filtered bytes from 0..15: zlib codes every byte as a Huffman
                   literal, so the inflate is the heaviest per byte. The two bracket a real
                   spec-maximum picture.
  b2_wide.png      1,000,000 x 1 RGBA16, flat: the width bound (umd_sub.h UMD_PNG_WMAX) --
                   decodes, a row of 8 MB, all but 720 pixels clipped
  b2_wide1.png     1,000,001 x 1: refused at its IHDR

With CORPUS (tools/png_corpus.py's cache, bench/umd/fixtures/gen/png_corpus), also:
  b2_toystory.png  the largest unit measured on a disc (Toy Story, 561 x 375, 4-bit palette,
                   7,194 B), copied; decoded at its own 77,31
  b2_budget.png    THE BUDGET CASE of hps_host.md §6: that unit's picture pasted at 77,31 on a
                   transparent 720 x 480 canvas, saved 4-bit palette with its tRNS (7,346 B):
                   the spec-sized rectangle at the largest real unit's compressed size
"""
import os
import random
import struct
import sys
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from png_golden import chunk  # noqa: E402

SIG = b"\x89PNG\r\n\x1a\n"


def png(w, h, rows, ctype=6, depth=16):
    ihdr = struct.pack(">IIBBBBB", w, h, depth, ctype, 0, 0, 0)
    return SIG + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    out = sys.argv[1]
    os.makedirs(out, exist_ok=True)
    rng = random.Random(20260930)
    stride = 720 * 8
    imgs = []

    rows = bytearray()
    for _ in range(480):
        rows += b"\x04" + rng.randbytes(stride)
    imgs.append(("b2_noise", png(720, 480, bytes(rows)), 0, 0))

    rows = bytearray()
    for _ in range(480):
        rows += b"\x04" + bytes(rng.randrange(16) for _ in range(stride))
    imgs.append(("b2_lowent", png(720, 480, bytes(rows)), 0, 0))

    px = struct.pack(">HHHH", 0x8000, 0x4000, 0x2000, 0xFFFF)
    imgs.append(("b2_wide", png(1000000, 1, b"\x00" + px * 1000000), 0, 0))
    imgs.append(("b2_wide1", png(1000001, 1, b"\x00" + px * 1000001), 0, 0))

    if len(sys.argv) > 2:
        import io
        from PIL import Image
        src_path = os.path.join(sys.argv[2], "Toy_Story_PSP_Video", "c00001_s81_00256.png")
        with open(src_path, "rb") as f:
            ts = f.read()
        imgs.append(("b2_toystory", ts, 77, 31))
        src = Image.open(io.BytesIO(ts))
        tr = src.info.get("transparency")
        ti = tr.index(0) if isinstance(tr, (bytes, bytearray)) and 0 in tr else 0
        canvas = Image.new("P", (720, 480), ti)
        canvas.putpalette(src.getpalette())
        canvas.paste(src, (77, 31))
        buf = io.BytesIO()
        canvas.save(buf, format="PNG", bits=4, transparency=tr, optimize=True)
        imgs.append(("b2_budget", buf.getvalue(), 0, 0))

    with open(os.path.join(out, "b2.txt"), "w") as lst:
        for name, data, ux, uy in imgs:
            p = os.path.join(out, name + ".png")
            with open(p, "wb") as f:
                f.write(data)
            lst.write("%s %d %d %s\n" % (p, ux, uy, name))
            print("%-10s %9d B" % (name, len(data)))


if __name__ == "__main__":
    main()
