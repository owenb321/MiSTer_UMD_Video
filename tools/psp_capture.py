#!/usr/bin/env python3
"""psp_capture.py -- measuring the menu engine's pictures against phone captures of a PSP (P9 M1c /
M3; docs/p9.md S2 the captures, S3.3 M1c how the goldens in tools/menu_gate.py were measured).

    psp_capture.py warp FRAME.png OUT.png [W H] [--corners x,y,x,y,x,y,x,y]
        the PSP's screen out of a phone frame, perspective-warped to W x H (480 x 272 default).
        Corners found as the extremes of the bright screen inside the window of mostly-bright rows
        and columns (an LED or a reflection is not); --corners gives them by hand (tl tr br bl).
    psp_capture.py align CAPTURE.png RENDER.png DRAWLIST [--search N]
        per object of DRAWLIST (menu_run's "DRAW label x0 y0 x1 y1 ..." lines), the shift that best
        aligns the render's edges inside its box with the capture's (blurred, normalised correlation):
        the offset of the capture's object from the render's, and the correlation it reached
    psp_capture.py frame ISO_PREFIX PLAYLIST_INDEX FRAME_NUMBER OUT.png
        a playlist's video frame (its first item's clip, via psmf_ref.py's elementary stream and
        ffmpeg) to lay under a render (menu_run --under)

Notes from use: the phone's lens bends the warp near the frame's edges (up to ~30 px at 1920 x 1088
on X / Austin Powers 2's left edge): correct an object's offset by the video's own static art beside
it (align a box of the video frame) before taking it as the PSP's.
"""
import argparse
import glob
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))


def corners(a):
    m = a.max(axis=2) > 60
    cols = np.nonzero(m.mean(axis=0) > 0.3)[0]
    rows = np.nonzero(m.mean(axis=1) > 0.3)[0]
    w = np.zeros_like(m)
    w[max(rows.min() - 40, 0):rows.max() + 40, max(cols.min() - 40, 0):cols.max() + 40] = True
    ys, xs = np.nonzero(m & w)
    s, d = xs + ys, xs - ys
    return [(xs[s.argmin()], ys[s.argmin()]), (xs[d.argmax()], ys[d.argmax()]),
            (xs[s.argmax()], ys[s.argmax()]), (xs[d.argmin()], ys[d.argmin()])]


def warp(a):
    im = Image.open(a.frame).convert("RGB")
    src = [tuple(map(int, a.corners.split(",")[k:k + 2])) for k in range(0, 8, 2)] if a.corners else corners(np.asarray(im).astype(int))
    print("corners", [(int(x), int(y)) for x, y in src])
    W, H = a.w, a.h
    A, B = [], []
    for (X, Y), (x, y) in zip(src, [(0, 0), (W, 0), (W, H), (0, H)]):
        A.append([x, y, 1, 0, 0, 0, -X * x, -X * y]); B.append(X)
        A.append([0, 0, 0, x, y, 1, -Y * x, -Y * y]); B.append(Y)
    c = np.linalg.solve(np.array(A, float), np.array(B, float))
    im.transform((W, H), Image.PERSPECTIVE, tuple(c), Image.BICUBIC).save(a.out)


def edges(path):
    g = np.asarray(Image.open(path).convert("L").filter(ImageFilter.GaussianBlur(2))).astype(float)
    gx, gy = np.zeros_like(g), np.zeros_like(g)
    gx[:, 1:-1] = g[:, 2:] - g[:, :-2]
    gy[1:-1, :] = g[2:, :] - g[:-2, :]
    return np.hypot(gx, gy)


def align(a):
    C, R = edges(a.capture), edges(a.render)
    n = a.search
    for line in open(a.drawlist):
        f = line.split()
        if len(f) < 7 or f[1] != "DRAW":
            continue
        lab = f[2]
        x0, y0, x1, y1 = (int(float(v)) for v in f[3:7])
        x0, y0 = max(x0, 0), max(y0, 0)
        x1, y1 = min(x1, R.shape[1]), min(y1, R.shape[0])
        if x1 - x0 < 4 or y1 - y0 < 4:
            continue
        r = R[y0:y1, x0:x1]
        r = (r - r.mean()) / (r.std() + 1e-6)
        best = (-9.0, 0, 0)
        for dy in range(-n, n + 1):
            for dx in range(-n, n + 1):
                if y0 + dy < 0 or x0 + dx < 0 or y1 + dy > C.shape[0] or x1 + dx > C.shape[1]:
                    continue
                c = C[y0 + dy:y1 + dy, x0 + dx:x1 + dx]
                c = (c - c.mean()) / (c.std() + 1e-6)
                v = float((r * c).mean())
                if v > best[0]:
                    best = (v, dx, dy)
        print("%-24s ncc %.2f  offset dx %+d dy %+d  (render centre %.1f %.1f)"
              % (lab, best[0], best[1], best[2], (x0 + x1) / 2, (y0 + y1) / 2))


def frame(a):
    sys.path.insert(0, HERE)
    import umd_iso
    import umd_playlist
    iso_dir = os.environ.get("UMD_ISO_DIR", os.path.expanduser("~/umd-isos"))
    isos = sorted(glob.glob(os.path.join(iso_dir, a.iso_prefix + "*")))
    if not isos:
        sys.exit("no image %s* under %s" % (a.iso_prefix, iso_dir))
    tmp = tempfile.mkdtemp()
    with umd_iso.UmdIso(isos[0]) as u:
        pl = umd_playlist.parse(u.read("/UMD_VIDEO/PLAYLIST.UMD", record=False))
        it = pl["playlists"][a.playlist]["items"][0]
        open(os.path.join(tmp, "c.mps"), "wb").write(u.read("/UMD_VIDEO/STREAM/%s.MPS" % it["clip_name"], record=False))
    subprocess.run([sys.executable, os.path.join(HERE, "psmf_ref.py"), os.path.join(tmp, "c.mps"), "--es", "video",
                    "-o", os.path.join(tmp, "c.264")], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-r", "29.97", "-i", os.path.join(tmp, "c.264"),
                    "-vf", "select=eq(n\\,%d)" % a.n, "-frames:v", "1", a.out], check=True)
    print("clip %s frame %d -> %s" % (it["clip_name"], a.n, a.out))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("warp")
    p.add_argument("frame"); p.add_argument("out")
    p.add_argument("w", nargs="?", type=int, default=480); p.add_argument("h", nargs="?", type=int, default=272)
    p.add_argument("--corners")
    p.set_defaults(fn=warp)
    p = sub.add_parser("align")
    p.add_argument("capture"); p.add_argument("render"); p.add_argument("drawlist")
    p.add_argument("--search", type=int, default=30)
    p.set_defaults(fn=align)
    p = sub.add_parser("frame")
    p.add_argument("iso_prefix"); p.add_argument("playlist", type=int); p.add_argument("n", type=int); p.add_argument("out")
    p.set_defaults(fn=frame)
    a = ap.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
