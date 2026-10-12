#!/usr/bin/env python3
"""Fixtures for bench/umd/plane_tb.sv: the overlay plane compositor (umd/plane_reader.sv,
umd/plane_blend.sv, umd/sub/sub_flip.sv; docs/compositor.md).

Two kinds of expectation, and which arm is which:

  EXACT, independent of the design:
    * the 1:1 pass-through ([pass]): the plane on the raster is the buffer's pixels inside
      the clipped rectangle and 0 outside -- plain numpy slicing, no filter at all;
    * the blend ([blend]) at 1:1: PIL's Image.alpha_composite of the STRAIGHT image over the
      opaque video must be within +-1 of the core's integer blend of the premultiplied
      plane (two roundings: the writer's premultiply and the blend); the integer formula
      is checked exactly.
  EXACT against the fixed-point algorithm as docs/compositor.md §2 states it ([scale]),
  which is itself BOUNDED against independent bilinear filters, so that the model cannot
  share a misunderstanding with the RTL unnoticed:
    * float bilinear at the exact positions (i + 0.5) sw / dw - 0.5, clamped to the
      source rectangle -- the definition the fixed point approximates;
    * PIL's resize(BILINEAR) per channel for the upscale (PIL widens its filter when it
      downscales, so it is not a bilinear reference there).
    The bounds, and the measured maxima, are printed; exceeding a bound fails the golden.

The video layer is disp_golden.py's frame (disp_rgb.hex, run that first): the bench
composes over umd/disp_reader.sv's real output.

    plane_golden.py  -> bench/umd/fixtures/gen/plane_*.hex, plane_sub.txt, plane_scale.txt
"""
import os
import sys
import numpy as np
from PIL import Image

W, H = 720, 480
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "umd", "fixtures", "gen")
rng = np.random.default_rng(11)
FLOAT_BOUND = 2        # |model - float bilinear| (8-bit weights, a 16-bit fraction step): 1.83 measured
PIL_BOUND = 2          # |model - PIL BILINEAR|  (PIL's own 22-bit coefficients and rounding): 2.0 measured


def premul(c, a):
    """round(c * a / 255) exactly, the plane writer's formula (main/support/umd/umd_sub.cpp since A7)."""
    t = c.astype(np.int64) * a + 128
    return (t + (t >> 8)) >> 8


def pack(argb):
    """(H, W, 4) channels A, R, G, B -> (H, W) uint32 {A, R, G, B}."""
    a = argb.astype(np.uint64)
    return (a[..., 0] << 24) | (a[..., 1] << 16) | (a[..., 2] << 8) | a[..., 3]


def words(u32):
    """a (480, 720) plane -> 172,800 words, the even x in [31:0]."""
    u = u32.astype(np.uint64).reshape(H, W // 2, 2)
    return (u[..., 0] | (u[..., 1] << np.uint64(32))).reshape(-1)


def write_hex(name, vals, digits):
    with open(os.path.join(OUT, name), "w") as f:
        f.write("\n".join(format(int(v), "0%dx" % digits) for v in vals) + "\n")


# ---- the video (disp_golden.py's frame) --------------------------------------------------------
with open(os.path.join(OUT, "disp_rgb.hex")) as f:
    v = np.array([int(x, 16) for x in f.read().split()], dtype=np.int64)
assert v.size == W * H, "disp_rgb.hex: run tools/disp_golden.py first"
video = np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=-1).reshape(H, W, 3)
# the same frame at 480i (disp_rgb_il.hex: its chroma rows nearest, docs/display.md S12): the
# composite under plane_tb +il
with open(os.path.join(OUT, "disp_rgb_il.hex")) as f:
    v = np.array([int(x, 16) for x in f.read().split()], dtype=np.int64)
assert v.size == W * H, "disp_rgb_il.hex: run tools/disp_golden.py first"
video_il = np.stack([(v >> 16) & 255, (v >> 8) & 255, v & 255], axis=-1).reshape(H, W, 3)


# ---- the fixed-point plane (docs/compositor.md §2) ---------------------------------------------
def clamp(p, size):
    """position(s) S.16 -> (index, 8-bit weight); negative -> (0, 0); >= size - 1 -> (size - 1, 0)."""
    p = np.asarray(p, dtype=np.int64)
    i = p >> 16
    f = (p >> 8) & 255
    lo = p < 0
    hi = (~lo) & (i >= size - 1)
    i = np.where(lo, 0, np.where(hi, size - 1, i))
    f = np.where(lo | hi, 0, f)
    return i, f


def plane_model(buf, g):
    """buf (480, 720, 4) premultiplied A, R, G, B -> the plane on the raster, (480, 720, 4)."""
    out = np.zeros((H, W, 4), dtype=np.int64)
    if not g["vis"] or bad(g):
        return out
    sx, sy, sw, sh, dx, dy, dw, dh = (g[k] for k in ("sx", "sy", "sw", "sh", "dx", "dy", "dw", "dh"))
    hs = np.arange(dx, min(dx + dw, W))
    c, fx = clamp(g["hstart"] + (hs - dx) * g["hstep"], sw)
    for n in range(dy, min(dy + dh, H)):
        r, fy = clamp(g["vstart"] + (n - dy) * g["vstep"], sh)
        r = int(r); fy = int(fy)
        top = buf[sy + r]
        botrow = buf[sy + r + 1] if fy else top
        p00 = top[sx + c]
        p01 = np.where((fx != 0)[:, None], top[np.minimum(sx + c + 1, W - 1)], p00)
        p10 = botrow[sx + c]
        p11 = np.where((fx != 0)[:, None], botrow[np.minimum(sx + c + 1, W - 1)], p10)
        f1 = fx[:, None]
        t = 256 * p00 + (p01 - p00) * f1
        b = 256 * p10 + (p11 - p10) * f1
        out[n, hs] = (256 * t + (b - t) * fy + 32768) >> 16
    return out


def bad(g):
    return g["sw"] == 0 or g["sh"] == 0 or g["sx"] + g["sw"] > W or g["sy"] + g["sh"] > H


def blend(plane, vid):
    """out = min(255, s + round(d (255 - a) / 255)) per channel (docs/compositor.md §3)."""
    a = plane[..., 0:1]
    t = vid * (255 - a) + 128
    return np.minimum(255, plane[..., 1:4] + ((t + (t >> 8)) >> 8))


def steps(sw, sh, dw, dh):
    """the owner's computation (docs/compositor.md §2): centre-aligned, S.16."""
    hstep = (sw * 65536 * 2 + dw) // (2 * dw)
    vstep = (sh * 65536 * 2 + dh) // (2 * dh)
    return dict(hstep=hstep, vstep=vstep, hstart=(hstep - 65536) >> 1, vstart=(vstep - 65536) >> 1)


def float_bilinear(buf, g):
    """the independent reference: exact positions, float weights, clamped at the edges."""
    sx, sy, sw, sh, dx, dy, dw, dh = (g[k] for k in ("sx", "sy", "sw", "sh", "dx", "dy", "dw", "dh"))
    src = buf[sy:sy + sh, sx:sx + sw].astype(np.float64)
    u = np.clip((np.arange(dw) + 0.5) * sw / dw - 0.5, 0, sw - 1)
    w = np.clip((np.arange(dh) + 0.5) * sh / dh - 0.5, 0, sh - 1)
    i0 = np.floor(u).astype(int); i1 = np.minimum(i0 + 1, sw - 1); fu = (u - i0)[None, :, None]
    j0 = np.floor(w).astype(int); j1 = np.minimum(j0 + 1, sh - 1); fw = (w - j0)[:, None, None]
    top = src[j0][:, i0] * (1 - fu) + src[j0][:, i1] * fu
    bot = src[j1][:, i0] * (1 - fu) + src[j1][:, i1] * fu
    out = np.zeros((H, W, 4))
    out[dy:dy + dh, dx:dx + dw] = (top * (1 - fw) + bot * fw)[:H - dy, :W - dx]
    return out


def pil_bilinear(buf, g):
    sx, sy, sw, sh, dx, dy, dw, dh = (g[k] for k in ("sx", "sy", "sw", "sh", "dx", "dy", "dw", "dh"))
    out = np.zeros((H, W, 4))
    for ch in range(4):
        im = Image.fromarray(buf[sy:sy + sh, sx:sx + sw, ch].astype(np.uint8), "L")
        out[dy:dy + dh, dx:dx + dw, ch] = np.asarray(im.resize((dw, dh), Image.BILINEAR))
    return out


def check(name, got, ref, bound, region):
    d = np.abs(got.astype(np.float64) - ref)[region]
    m = float(d.max())
    print("plane_golden: %s: max |model - reference| %.3f (bound %d), mean %.4f" % (name, m, bound, float(d.mean())))
    if m > bound:
        sys.exit("plane_golden: FAIL %s exceeds its bound" % name)


# ---- the subtitle planes (1:1, sub mode) ----------------------------------------------------------
def junk():
    """what a plane holds outside the rectangle: earlier images, never cleared (valid, opaque-ish)."""
    a = rng.integers(1, 256, (H, W))
    rgb = premul(rng.integers(0, 256, (H, W, 3)), a[..., None])
    return np.concatenate([a[..., None], rgb], axis=-1)


def straight_image(w, h):
    a = np.where(rng.random((h, w)) < 0.4, 0, np.where(rng.random((h, w)) < 0.5, 255, rng.integers(0, 256, (h, w))))
    return rng.integers(0, 256, (h, w, 3)), a


def sub_clip(x, y, w, h, vis):
    if not vis or x >= W or y >= H or w == 0 or h == 0:
        return None
    return x, y, min(w, W - x), min(h, H - y)


SUB_REQS = [   # (buf, vis, x, y, w, h) as sub_sched raises them
    (0, 1, 115, 0, 603, 480),      # odd x and w, flush with the top and bottom edges (480i: a field's
                                   # first line is inside it -- run_plane.sh SI4), 2 dots short of the right
    (1, 1, 701, 460, 40, 40),      # past both edges: clipped to 19 x 20
    (1, 0, 701, 460, 40, 40),      # the hide, raised the cycle after the flip's ack
]
sbuf = [junk(), junk()]
simg = {}
for bsel, vis, x, y, w, h in SUB_REQS[:2]:
    rgb, a = straight_image(w, h)
    cw, ch = min(w, W - x), min(h, H - y)
    rgb, a = rgb[:ch, :cw], a[:ch, :cw]
    sbuf[bsel][y:y + ch, x:x + cw] = np.concatenate([a[..., None], premul(rgb, a[..., None])], axis=-1)
    simg[bsel] = (rgb, a)
for i in range(2):
    write_hex("plane_sbuf%d.hex" % i, words(pack(sbuf[i])), 16)

sub_lines = []
for k, (bsel, vis, x, y, w, h) in enumerate(SUB_REQS):
    cl = sub_clip(x, y, w, h, vis)
    plane = np.zeros((H, W, 4), dtype=np.int64)
    if cl:
        cx, cy, cw, ch = cl
        plane[cy:cy + ch, cx:cx + cw] = sbuf[bsel][cy:cy + ch, cx:cx + cw]     # [pass]: slicing, no filter
        g = dict(vis=1, sx=cx, sy=cy, sw=cw, sh=ch, dx=cx, dy=cy, dw=cw, dh=ch, hstep=65536, vstep=65536, hstart=0, vstart=0)
        assert (plane_model(sbuf[bsel], g) == plane).all(), "the model's 1:1 is not the pass-through"
    comp = blend(plane, video)
    if cl:
        rgb, a = simg[bsel]
        base = Image.fromarray(video.astype(np.uint8), "RGB").convert("RGBA")
        layer = np.zeros((H, W, 4), dtype=np.uint8)
        layer[cy:cy + ch, cx:cx + cw] = np.concatenate([rgb, a[..., None]], axis=-1)
        pil = np.asarray(Image.alpha_composite(base, Image.fromarray(layer, "RGBA")))[..., :3]
        check("sub %d blend vs PIL alpha_composite" % k, comp, pil.astype(np.float64), 1, np.s_[:])
    write_hex("plane_s%d_argb.hex" % k, pack(plane[..., [0, 1, 2, 3]]).reshape(-1), 8)
    write_hex("plane_s%d_rgb.hex" % k, ((comp[..., 0] << 16) | (comp[..., 1] << 8) | comp[..., 2]).reshape(-1), 6)
    ci = blend(plane, video_il)
    write_hex("plane_s%d_rgb_il.hex" % k, ((ci[..., 0] << 16) | (ci[..., 1] << 8) | ci[..., 2]).reshape(-1), 6)
    c = cl if cl else (0, 0, 0, 0)
    sub_lines.append("%d %d %d %d %d %d  %d %d %d %d %d" % (bsel, vis, x, y, w, h, 1 if cl else 0, *c))
with open(os.path.join(OUT, "plane_sub.txt"), "w") as f:
    f.write("\n".join(sub_lines) + "\n")


# ---- the menu-style planes (bilinear, scale mode) -------------------------------------------------
def smooth_image():
    yy, xx = np.mgrid[0:H, 0:W]
    rgb = np.stack([(xx * 255) // (W - 1), (yy * 255) // (H - 1), ((xx + yy) * 3) % 256], axis=-1)
    a = np.full((H, W), 255)
    a[:, 200:400] = (np.arange(200) * 255) // 199                    # an alpha ramp
    rgb[100:300, 400:700] = rng.integers(0, 256, (200, 300, 3))       # noise: the worst gradient
    a[100:300, 400:700] = rng.integers(0, 256, (200, 300))
    a[300:340] = 0                                                    # transparent band
    for k in range(0, W, 24):                                         # thin opaque strokes
        rgb[350:450, k:k + 2] = 255; a[350:450, k:k + 2] = 255
    buf = np.concatenate([a[..., None], premul(rgb, a[..., None])], axis=-1)
    buf[20:60, 20:120, 1:] = 200; buf[20:60, 20:120, 0] = 0           # additive (colour > alpha): the clip
    return buf


mbuf = [smooth_image(), smooth_image()]
for i in range(2):
    write_hex("plane_mbuf%d.hex" % i, words(pack(mbuf[i])), 16)
SCALE = [   # (buf, geometry)
    (0, dict(vis=1, sx=33, sy=17, sw=480, sh=272, dx=0, dy=0, dw=720, dh=480)),     # 480x272 -> the raster
    (1, dict(vis=1, sx=0, sy=0, sw=720, sh=480, dx=411, dy=250, dw=301, dh=203)),   # a downscale, placed
    (1, dict(vis=1, sx=33, sy=0, sw=700, sh=480, dx=0, dy=0, dw=720, dh=480)),      # bad: past the row
]
scale_lines = []
for k, (bsel, g) in enumerate(SCALE):
    g.update(steps(g["sw"], g["sh"], g["dw"], g["dh"]))
    plane = plane_model(mbuf[bsel], g)
    if not bad(g):
        reg = np.s_[g["dy"]:g["dy"] + g["dh"], g["dx"]:g["dx"] + g["dw"]]
        check("scale %d model vs float bilinear" % k, plane, float_bilinear(mbuf[bsel], g), FLOAT_BOUND, reg)
        if g["dw"] >= g["sw"] and g["dh"] >= g["sh"]:
            check("scale %d model vs PIL BILINEAR" % k, plane, pil_bilinear(mbuf[bsel], g), PIL_BOUND, reg)
    comp = blend(plane, video)
    fl = np.minimum(255, plane[..., 1:4] + video * (255 - plane[..., 0:1]) / 255.0)
    check("scale %d blend vs float" % k, comp, fl, 1, np.s_[:])
    write_hex("plane_m%d_argb.hex" % k, pack(plane).reshape(-1), 8)
    write_hex("plane_m%d_rgb.hex" % k, ((comp[..., 0] << 16) | (comp[..., 1] << 8) | comp[..., 2]).reshape(-1), 6)
    scale_lines.append(" ".join(str(x) for x in (bsel, g["vis"], g["sx"], g["sy"], g["sw"], g["sh"], g["dx"], g["dy"],
                                                 g["dw"], g["dh"], g["hstep"], g["vstep"], g["hstart"], g["vstart"],
                                                 1 if bad(g) else 0)))
with open(os.path.join(OUT, "plane_scale.txt"), "w") as f:
    f.write("\n".join(scale_lines) + "\n")
print("plane_golden: 2 subtitle buffers, 3 requests; 2 menu buffers, 3 geometries (one refused)")
