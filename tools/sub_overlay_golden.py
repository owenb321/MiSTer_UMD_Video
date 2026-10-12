#!/usr/bin/env python3
"""Fixtures for bench/umd/sub_overlay_tb.sv: what the raster must show for each subtitle
unit (umd/sub/sub_overlay.sv; docs/compositor.md §8).

Input: tools/sub_golden.py's e2e fixtures (per unit the tool finds: pts, duration, x, y, w,
h, refused, and its plane words -- libpng's pixels premultiplied and clipped to 720x480)
and tools/disp_golden.py's video frame (disp_rgb.hex).

Per unit that is not refused:
  <stem>.ovl<k>_argb.hex  the plane on the raster: the unit's pixels inside its rectangle
                          clipped to 720x480, 0 elsewhere (345,600 words, {A, R, G, B})
  <stem>.ovl<k>_rgb.hex   the composite: out = min(255, s + round(d (255 - a) / 255)) over
                          the video (docs/compositor.md §3; plane_golden.py checks that
                          formula against PIL's alpha_composite)
k counts the shown units from 0. The plane is rebuilt from the plane words alone -- what
libpng decoded, placed where the tool says -- so nothing here comes from the RTL. Every
pixel of the clipped rectangle must have been written (the display draws the whole
rectangle: a pixel left unwritten would show an earlier image's).

    sub_overlay_golden.py [--zoom] LIST   (a list of stems, as sub_golden.py --list writes)

--zoom (fj#71, docs/zoom.md Z3): the same units under Zoom, written as <stem>.zovl<k>_*.hex --
only raster lines 60 .. 419 reach the screen, so the clipped rectangle (x, y, cw, ch) is
placed at y' = 60 if ch > 360 or y < 60, else 420 - ch if y + ch > 420, else y; and at most
its first 360 rows are shown (the rows from y as before: the image moves, it is not re-cut).
"""
import os
import sys
import numpy as np

W, H = 720, 480
GEN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "umd", "fixtures", "gen")


def hexfile(path):
    with open(path) as f:
        return [int(x, 16) for x in f.read().split()]


def video():
    v = np.array(hexfile(os.path.join(GEN, "disp_rgb.hex")), dtype=np.int64)
    assert v.size == W * H, "disp_rgb.hex: run tools/disp_golden.py first"
    return np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=-1).reshape(H, W, 3)


def blend(plane, vid):
    a = plane[..., 0:1]
    t = vid * (255 - a) + 128
    return np.minimum(255, plane[..., 1:4] + ((t + (t >> 8)) >> 8))


def write_hex(path, vals, digits):
    with open(path, "w") as f:
        f.write("\n".join(format(int(v), "0%dx" % digits) for v in vals) + "\n")


ZY0, ZY1 = 60, 420


def zoom_place(y, ch):
    """The subtitle's raster y and shown rows under Zoom (docs/zoom.md Z3), from the definition."""
    zh = min(ch, ZY1 - ZY0)
    if ch > ZY1 - ZY0 or y < ZY0:
        return ZY0, zh
    if y + ch > ZY1:
        return ZY1 - ch, zh
    return y, zh


def stem_units(stem, vid, zoom=False):
    meta = hexfile(stem + ".meta.hex")
    nu = meta[1]
    urec = hexfile(stem + ".urec.hex")
    pw = []
    with open(stem + ".pw.hex") as f:
        for line in f.read().split():
            v = int(line, 16)
            pw.append((v >> 72, (v >> 64) & 0xFF, v & ((1 << 64) - 1)))
    k = 0
    for u in range(nu):
        pts, dur, x, y, w, h, err, off, n = urec[9 * u:9 * u + 9]
        if err:
            continue
        plane = np.zeros((H, W, 4), dtype=np.int64)
        written = np.zeros((H, W), dtype=bool)
        for wd, m, val in pw[off:off + n]:
            yy, xx = divmod(wd, 360)
            for half in (0, 1):
                if (m >> (4 * half)) & 0xF:
                    p = (val >> (32 * half)) & 0xFFFFFFFF
                    plane[yy, 2 * xx + half] = [(p >> 24) & 255, (p >> 16) & 255, (p >> 8) & 255, p & 255]
                    written[yy, 2 * xx + half] = True
        cw, ch = min(w, W - x), min(h, H - y)
        if cw > 0 and ch > 0:
            assert written[y:y + ch, x:x + cw].all(), "%s unit %d: a pixel of the rectangle unwritten" % (stem, u)
            outside = written.copy(); outside[y:y + ch, x:x + cw] = False
            assert not outside.any(), "%s unit %d: a pixel written outside its rectangle" % (stem, u)
        a = plane[..., 0]
        assert (plane[..., 1:4] <= a[..., None]).all(), "%s unit %d: not premultiplied" % (stem, u)
        if zoom and cw > 0 and ch > 0:
            zy, zh = zoom_place(y, ch)
            moved = np.zeros_like(plane)
            moved[zy:zy + zh, x:x + cw] = plane[y:y + zh, x:x + cw]
            plane = moved
        argb = (plane[..., 0] << 24) | (plane[..., 1] << 16) | (plane[..., 2] << 8) | plane[..., 3]
        comp = blend(plane, vid)
        pre = "zovl" if zoom else "ovl"
        write_hex("%s.%s%d_argb.hex" % (stem, pre, k), argb.reshape(-1), 8)
        write_hex("%s.%s%d_rgb.hex" % (stem, pre, k), ((comp[..., 0] << 16) | (comp[..., 1] << 8) | comp[..., 2]).reshape(-1), 6)
        zs = ""
        if zoom and cw > 0 and ch > 0:
            zy, zh = zoom_place(y, ch)
            zs = ", zoomed to y %d, %d rows" % (zy, zh)
        print("sub_overlay_golden: %s shown unit %d: (%d, %d) %dx%d, clipped %dx%d%s" % (os.path.basename(stem), k, x, y, w, h, cw, ch, zs))
        k += 1
    return k


def main(argv):
    zoom = "--zoom" in argv
    argv = [a for a in argv if a != "--zoom"]
    vid = video()
    with open(argv[0]) as f:
        stems = f.read().split()
    total = sum(stem_units(s, vid, zoom) for s in stems)
    print("sub_overlay_golden: %d shown units over %d cases" % (total, len(stems)))


if __name__ == "__main__":
    main(sys.argv[1:])
