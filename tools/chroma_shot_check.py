#!/usr/bin/env python3
"""chroma_shot_check.py -- score a rig screenshot of a PAUSED picture against ffmpeg's decode of the
same picture, rendered with each chroma rule the reader has had (docs/display.md S12 / S13), so a
run says which one the silicon does.

    tools/chroma_shot_check.py IMAGE.iso SHOT.png SH_PTS [field]

SHOT.png: `mister.py seq "...; key play/pause; wait 3; shot NAME"` -- the RAW 720x480 raster: on a rig
whose HDMI output is 720x480 (video_mode=2) ascal shrinks a 16:9 picture to 720x405 on its INPUT side
and the shot is not the raster (docs/hil_harness.md "Facts that bite"). SH_PTS: telemetry's shown
picture (sh_pts_hi << 16 | sh_pts_lo) at the shot; it locates the clip and the window, and the picture
itself is picked by the luma of each field (model-independent). `field`: a field store in Weave --
its rules S13's field step (Figure E-1's siting), S12's along the line only, and nearest -- else a
frame: S12's both ways, and nearest. The pause glyph is excluded (a box at the bottom left)."""
import sys, os, subprocess, tempfile, re
import numpy as np
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import psmf_ref, umd_iso
SEC = 2048

def rgb(Y, U, V):
    C, D, E = Y - 16, U - 128, V - 128
    R = np.clip((298 * C + 409 * E + 128) >> 8, 0, 255)
    G = np.clip((298 * C - 100 * D - 208 * E + 128) >> 8, 0, 255)
    B = np.clip((298 * C + 516 * D + 128) >> 8, 0, 255)
    return np.stack([R, G, B], -1)

def up(c): return np.repeat(np.repeat(c, 2, 0), 2, 1)
def hup(c):
    cols = np.arange(2 * c.shape[1]); n, nx = cols >> 1, np.minimum((cols + 1) >> 1, c.shape[1] - 1)
    return np.where(cols & 1, (c[:, n] + c[:, nx] + 1) >> 1, c[:, n])
def up_h(c): return np.repeat(hup(c), 2, 0)
def up_ident(c):
    h = hup(c); H = 2 * c.shape[0]; rows = []
    for k in range(H):
        ra = k + 1 if k == 0 else k - 1; rd = k - 1 if k == H - 1 else k + 1
        o = ra if (k & 1) == 0 else rd
        rows.append((3 * h[k >> 1] + h[o >> 1] + 2) >> 2)
    return np.stack(rows)

def up_fv(c, p):
    """(S13) one field's chroma (p: 0 top, 1 bottom) at Figure E-1's field siting: the line nearer its
    row (k & 1 == p) (7 h[m] + h[n] + 4) >> 3, the other (5 h[m] + 3 h[n] + 4) >> 3, n the far-side row"""
    h = hup(c); R = c.shape[0]; rows = []
    for k in range(2 * R):
        m = k >> 1
        n = max(m - 1, 0) if (k & 1) == 0 else min(m + 1, R - 1)
        rows.append((7 * h[m] + h[n] + 4) >> 3 if (k & 1) == p else (5 * h[m] + 3 * h[n] + 4) >> 3)
    return np.stack(rows)

def first_vpts(mm, a, b):
    r = psmf_ref.parse(mm, a, b)
    for p in r.packets:
        if p.kind == "video" and p.pts is not None:
            return p.pts
    return None

def locate(iso, pts):
    u = umd_iso.UmdIso(iso); clips = u.clips(); u.close()
    for c in clips:
        s = psmf_ref.Source(iso, c)
        n = (s.end - s.start) // SEC
        p0 = first_vpts(s.mm, s.start, min(s.end, s.start + 64 * SEC))
        p1 = first_vpts(s.mm, s.start + max(0, n - 200) * SEC, s.end)
        if p0 is not None and p1 is not None and p0 <= pts <= p1 + 90000 * 2:
            lo, hi = 0, n - 64
            tgt = pts - 4 * 90000
            while lo < hi:
                m = (lo + hi + 1) // 2
                v = first_vpts(s.mm, s.start + m * SEC, s.start + (m + 64) * SEC)
                if v is not None and v <= tgt: lo = m
                else: hi = m - 1
            return s, c, lo
    raise SystemExit("pts %d in no clip" % pts)

def decode(s, k, n_bytes=6 << 20):
    data = s.mm[s.start + k * SEC: min(s.end, s.start + k * SEC + n_bytes)]
    d = tempfile.mkdtemp()
    src = os.path.join(d, "w.mpg"); open(src, "wb").write(data)
    r = subprocess.run(["ffmpeg", "-v", "info", "-nostdin", "-f", "mpeg", "-i", src, "-map", "0:v:0", "-copyts",
                        "-vf", "showinfo", "-f", "rawvideo", "-pix_fmt", "yuv420p", os.path.join(d, "o.yuv")],
                       capture_output=True, text=True)
    pts = [int(m.group(1)) for m in re.finditer(r"n:\s*\d+\s+pts:\s*(-?\d+)", r.stderr)]
    raw = np.fromfile(os.path.join(d, "o.yuv"), np.uint8)
    os.remove(src); os.remove(os.path.join(d, "o.yuv")); os.rmdir(d)
    return pts, raw

def frame(raw, i, W=720, H=480):
    fs = W * H * 3 // 2; a = raw[i * fs:(i + 1) * fs].astype(np.int64)
    Y = a[:W * H].reshape(H, W); U = a[W * H:W * H + W * H // 4].reshape(H // 2, W // 2); V = a[W * H + W * H // 4:].reshape(H // 2, W // 2)
    return Y, U, V

def lum(img):  # a BT.601 limited luma estimate of the shot (picks the picture: independent of the chroma model)
    i = img.astype(np.float64); return 16 + (65.738 * i[..., 0] + 129.057 * i[..., 1] + 25.064 * i[..., 2]) / 256

def score(shot, want, mask):
    d = np.abs(shot.astype(np.int64) - want).max(-1)[mask]
    return 100.0 * (d == 0).mean(), 100.0 * (d <= 2).mean(), int(d.max()), float(d.mean())

def main():
    iso, png, pts = sys.argv[1], sys.argv[2], int(sys.argv[3])
    field = len(sys.argv) > 4 and sys.argv[4] == "field"
    shot = np.asarray(Image.open(png).convert("RGB"))
    s, c, k = locate(iso, pts)
    fp, raw = decode(s, k)
    n = raw.size // (720 * 480 * 3 // 2)
    ys = lum(shot)
    best = []
    for p in (0, 1):
        e = [np.abs(frame(raw, i)[0][p::2] - ys[p::2]).mean() for i in range(n)]
        best.append((int(np.argmin(e)), min(e)))
    (i0, e0), (i1, e1) = best
    print("pts %d -> clip %05d, %d pictures decoded; top field from #%d (luma err %.2f), bottom from #%d (%.2f)" % (pts, c, n, i0, e0, i1, e1))
    if not field:
        Yf, Uf, Vf = frame(raw, i0)
        models = [("S12 both ways", rgb(Yf, up_ident(Uf), up_ident(Vf))), ("nearest", rgb(Yf, up(Uf), up(Vf)))]
    else:
        rules = [("S13 field step", lambda c, p: up_fv(c, p)), ("S12 along the line", lambda c, p: up_h(c)),
                 ("nearest", lambda c, p: up(c))]
        models = []
        for nm, f in rules:
            pl = [np.zeros((480, 720), np.int64) for _ in range(3)]
            for p, i in ((0, i0), (1, i1)):
                Yf, Uf, Vf = frame(raw, i)
                pl[0][p::2], pl[1][p::2], pl[2][p::2] = Yf[p::2], f(Uf[p::2], p), f(Vf[p::2], p)
            models.append((nm, rgb(*pl)))
    shot = shot.astype(np.int64)
    box = np.zeros((480, 720), bool); box[436:461, 12:33] = True     # the pause glyph's box (rows 440..456, cols 16..28 + 4)
    for nm, w in models:
        d = np.abs(shot - w).max(-1)
        bad = (d > 0) & ~box
        print("  %-20s %6d pixels differ outside the glyph box (of %d)%s; exact %6.2f %%" % (
            nm, bad.sum(), (~box).sum(), "" if not bad.any() else ", max %d" % d[bad].max(),
            100.0 * (d[~box] == 0).mean()))

main()
