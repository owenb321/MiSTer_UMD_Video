#!/usr/bin/env python3
"""Fixtures for bench/umd/disp_reader_tb.sv: random 4:2:0 pictures as DPB store words
(docs/h264_recon.md S2.2: luma rows of 2W words, then Cb, Cr rows of W) and the expected
720x480 raster of every variant the reader shows, one line per active dot, {de, R, G, B}
as 7 hex digits (de 0 and black beyond the picture). The RGB is the BT.601 limited-range
integer conversion umd/disp_reader.sv states, of each dot's Y / Cb / Cr:

  frame   the store as a FRAME: luma line y takes chroma row y >> 1
  field   the store as a FIELD PAIR (line-interleaved), woven: luma line y takes its own
          field's chroma. That siting is NOT computed here from the RTL's formula
          (2 (y >> 2) + (y & 1)): ffmpeg's `separatefields` splits the woven picture into
          its two fields (every plane, chroma included, line-interleaved -- the layout the
          reconstruction writes and ffmpeg decodes to), each field's chroma is expanded with
          the plain 4:2:0 rule of its own planes, and the two are woven back.
  blend   the field pair's 4:4:4 lines through ffmpeg's `interlace` lowpass (vf_tinterlace:
          (1 + a + 2b + d) >> 2 on every line, per plane), the Blend kernel's definition. The
          filter clamps each FIELD's first and last lines to themselves; the reader mirrors
          the PICTURE's edges (line -1 := line 1, line H := line H - 2), so the planes go in
          padded by two mirrored lines each side and come out cropped: ffmpeg's edge rule never
          touches a scored line, and the golden checks the reader's edge rule too.
  bob0/1  the Bob kernel, keeping the top (0) / bottom (1) field: its lines as woven, the
          other field's (a + d + 1) >> 1, edges mirrored. No ffmpeg filter computes this (its
          bobs are temporal or edge-directed): the formula is the definition, and the kept
          lines are the ffmpeg-split weave's.

480i Analog Aspect (docs/analog.md S3, S2's Letterbox and Crop; written from the walker's
definition, not from the RTL): raster frame line Y = 2j + q (field line j, raster parity q)
is built from source field lines of parity ps (q, or the kept field of a single / paused
pair) of the 4:4:4 picture (the frame's, or the field pair's woven one above):
  vertical    N in sixths of a source field line -- Fit: N = 3 (Y - ps); Letterbox: field
              lines 30..209 only (the rest black, de 0), o = j - 30, N = 8o + 4q - 3ps
              (source frame position (Y - 60) * 4/3); N < 0 -> line 0 alone; s = N // 6,
              k = N % 6, s at the last field line -> k 0; the row is F[s], or with k != 0
              a + (((b - a) * W[k] + 128) >> 8), a = F[s], b = F[s + 1], W = 0 43 85 128
              171 213 (k 3: (a + b + 1) >> 1, the Bob's line)
  horizontal  Crop: column x samples source position 90 + 3x/4: Xq = 360 + 3x quarters,
              (r[Xq >> 2] (4 - f) + r[(Xq >> 2) + 1] f + 2) >> 2, f = Xq & 3 -- on each of
              the two source rows BEFORE the vertical blend
  only a 720x480 picture is scaled (any other size is Fit)

The video window (P9, docs/p9.md S3.2 item 6; written from its definition, not from the RTL):
the source is ROWS -- a frame store's frame lines (4:4:4 by the frame chroma rule), a field
store's KEPT field's lines (pic_parity; its own chroma) -- scaled into the rectangle
{wx, wy, ww, wh} on the raster with Q16 steps hs / vs and start positions x0 / y0 (all from the
host, in the picture's FRAME rows: the host cannot know a store's kind). Raster frame line Y in
the window: A = y0 + (Y - wy) vs; a frame store's s = A >> 16, f = (A >> 12) & 15 (sixteenths), a
field store's (half the rows) s = A >> 17, f = (A >> 13) & 15; s at or past the last row -> the
last, f 0; column X: B = x0 + (X - wx) hs,
t = B >> 16, g = (B >> 12) & 15, likewise clamped. Each row first horizontally,
r[t] + (((r[t + 1] - r[t]) g + 8) >> 4), then vertically a + (((b - a) 16 f + 128) >> 8); outside
the rectangle black, de 0. At 480i the raster's frame line Y is the same line (a field shows the
window's lines of its parity). Bounded here against float bilinear sampling at the same
positions (it is a bilinear scale, rounded twice).

Field matching (Forgejo fj#80, docs/telecine.md S5): the shown field's lines from store L, the
other parity's from a partner store M (a second random 720x480 picture), as ONE field store:
luma line y and chroma row c from L when their parity is the shown field's, else from M (a field
store's chroma rows are line-interleaved by field like its luma), then the field rule above --
disp_want_match0/1 (the shown field top / bottom). The comb sums the reader latches for the lock
(C = sum |2b - a - d|, R = sum |a - d| on every 8th dot's luma, edges mirrored) are
tools/telecine_ref.py's observe() -- the lock's own definition -- of the shown luma: in-store
(the pair L) and matched (disp_cm_*.args).

Three pictures: L, 720x480 (the raster's size); S, 480x272 (the PSP's own; its last line
is inside the raster, so the bottom mirror is seen, and the dots beyond it are black); T,
720x576 (the Level 3.0 maximum, 1,620 macroblocks, clipped to the raster's 480 lines: the
last shown line's d is the picture's real line 480, not a mirror).
Without ffmpeg the field split falls back to numpy and blend to the formula (no oracle) and
the script says so.

    disp_golden.py   -> bench/umd/fixtures/gen/disp_store{,_s,_t}.hex, disp_want_*.hex
"""
import os
import shutil
import subprocess
import tempfile
import numpy as np

RW, RH = 720, 480                                 # the raster
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "umd", "fixtures", "gen")
os.makedirs(out, exist_ok=True)
HAVE_FFMPEG = shutil.which("ffmpeg") is not None


def picture(seed, W, H):
    rng = np.random.default_rng(seed)
    Y = rng.integers(0, 256, (H, W))
    # a ramp band: every level of the clip. Rows 40-79, not the top: the top field lines must
    # differ (a field's first two lines share a chroma row, so identical luma there hid the
    # 480i top-edge rule's mutation, run_disp_reader.sh I4)
    Y[40:80] = np.arange(W) % 256
    Cb = rng.integers(0, 256, (H // 2, W // 2))
    Cr = rng.integers(0, 256, (H // 2, W // 2))
    return Y, Cb, Cr


def words(p):
    h, w = p.shape
    b = p.astype(np.uint64).reshape(h, w // 8, 8)
    return (sum(b[:, :, i] << np.uint64(8 * i) for i in range(8))).reshape(-1)


def up(c):
    """4:2:0 chroma -> one sample per luma dot (rows sited on luma row pairs)."""
    return np.repeat(np.repeat(c, 2, 0), 2, 1)


def rgb(Y, U, V):
    C, D, E = Y - 16, U - 128, V - 128
    R = np.clip((298 * C + 409 * E + 128) >> 8, 0, 255)
    G = np.clip((298 * C - 100 * D - 208 * E + 128) >> 8, 0, 255)
    B = np.clip((298 * C + 516 * D + 128) >> 8, 0, 255)
    return np.stack([R, G, B], -1)


def ffmpeg(args, planes, W, H, fmt):
    with tempfile.TemporaryDirectory() as d:
        src, dst = os.path.join(d, "in.yuv"), os.path.join(d, "out.yuv")
        with open(src, "wb") as f:
            f.write(b"".join(p.astype(np.uint8).tobytes() for p in planes))
        subprocess.run(["ffmpeg", "-v", "error", "-f", "rawvideo", "-pix_fmt", fmt, "-s", "%dx%d" % (W, H),
                        "-i", src] + args + ["-f", "rawvideo", "-pix_fmt", fmt, dst], check=True)
        return np.frombuffer(open(dst, "rb").read(), np.uint8).astype(np.int64)


def fields(Y, Cb, Cr):
    """The two fields' 4:2:0 planes, split by ffmpeg `separatefields` (numpy without it)."""
    H, W = Y.shape
    if not HAVE_FFMPEG:
        return [(Y[p::2], Cb[p::2], Cr[p::2]) for p in (0, 1)]
    raw = ffmpeg(["-vf", "setfield=tff,separatefields"], (Y, Cb, Cr), W, H, "yuv420p")
    fh = H // 2
    fsz = W * fh + 2 * (W // 2) * (fh // 2)
    assert raw.size == 2 * fsz, "separatefields: %d bytes" % raw.size
    res = []
    for k in range(2):                            # output order = top field, then bottom (tff)
        a = raw[k * fsz:(k + 1) * fsz]
        yp = a[:W * fh].reshape(fh, W)
        cb = a[W * fh:W * fh + (W // 2) * (fh // 2)].reshape(fh // 2, W // 2)
        cr = a[W * fh + (W // 2) * (fh // 2):].reshape(fh // 2, W // 2)
        res.append((yp, cb, cr))
    # the split must be the luma lines as stored (a sanity check on the oracle's field order)
    assert all((res[p][0] == Y[p::2]).all() for p in (0, 1)), "field order"
    return res


def woven444(Y, Cb, Cr):
    """Every luma line with its own field's chroma, woven (H x W, three planes)."""
    H, W = Y.shape
    planes = [np.zeros((H, W), np.int64) for _ in range(3)]
    for p, (yp, cb, cr) in enumerate(fields(Y, Cb, Cr)):
        planes[0][p::2], planes[1][p::2], planes[2][p::2] = yp, up(cb), up(cr)
    return planes


def mirror_pad(p, n=2):
    """Rows -n..-1 and H..H+n-1 mirrored about the picture's first / last line."""
    top = p[1:n + 1][::-1]
    bot = p[-n - 1:-1][::-1]
    return np.concatenate([top, p, bot])


def blend(planes):
    H, W = planes[0].shape
    padded = [mirror_pad(p) for p in planes]
    if HAVE_FFMPEG:
        # two identical frames in, one out: each output line is the lowpass of its own frame
        raw = ffmpeg(["-vf", "interlace=scan=tff:lowpass=linear"], padded * 2, W, H + 4, "yuv444p")
        n = W * (H + 4)
        assert raw.size == 3 * n, "interlace: %d bytes" % raw.size
        return [raw[k * n:(k + 1) * n].reshape(H + 4, W)[2:-2] for k in range(3)]
    return [(pp[1:-3] + 2 * pp[2:-2] + pp[3:-1] + 1) >> 2 for pp in padded]


def bob(planes, keep):
    res = []
    for p in planes:
        pp = mirror_pad(p, 1)                     # pp[y + 1] = line y
        o = p.copy()
        for y in range(p.shape[0]):
            if (y & 1) != keep:
                o[y] = (pp[y] + pp[y + 2] + 1) >> 1
        res.append(o)
    return res


def write_want(name, img):
    """img: the picture's RGB (h x w x 3), placed at the raster's top left."""
    h, w, _ = img.shape
    with open(os.path.join(out, name), "w") as f:
        for y in range(RH):
            for x in range(RW):
                if y < h and x < w:
                    f.write("1%02x%02x%02x\n" % tuple(img[y, x]))
                else:
                    f.write("0000000\n")


W6 = (0, 43, 85, 128, 171, 213)


def il_aspect(planes, mode, keep=None):
    """the 480i raster (both fields woven back): (480 x 720 RGB, 480 x 720 de)"""
    H, W = planes[0].shape
    if (W, H) != (720, 480):
        mode = "fit"
    nf = H // 2
    rgb_o = np.zeros((RH, RW, 3), np.int64)
    de_o = np.zeros((RH, RW), bool)
    for Y in range(RH):
        j, q = Y >> 1, Y & 1
        ps = q if keep is None else keep
        if mode == "lb":
            if j < 30 or j >= 210:
                continue
            N = 8 * (j - 30) + 4 * q - 3 * ps
        else:
            if Y >= H:
                continue
            N = 3 * (Y - ps)
        s, k = (0, 0) if N < 0 else (N // 6, N % 6)
        if s >= nf - 1:
            s, k = nf - 1, 0

        def row(sl, p):
            r = p[ps::2][sl]
            if mode != "crop":
                return r[:W]
            xq = 360 + 3 * np.arange(RW)
            sx, f = xq >> 2, xq & 3
            return (r[sx] * (4 - f) + r[sx + 1] * f + 2) >> 2

        ch = []
        for p in planes:
            a = row(s, p)
            if k:
                b = row(s + 1, p)
                a = a + (((b - a) * W6[k] + 128) >> 8)
            ch.append(a)
        w = len(ch[0])
        rgb_o[Y, :w] = rgb(*ch)
        de_o[Y, :w] = True
    return rgb_o, de_o


def write_want_de(name, img, de):
    with open(os.path.join(out, name), "w") as f:
        for y in range(RH):
            for x in range(RW):
                f.write(("1%02x%02x%02x\n" % tuple(img[y, x])) if de[y, x] else "0000000\n")


def write_store(name, Y, Cb, Cr):
    with open(os.path.join(out, name), "w") as f:
        for p in (Y, Cb, Cr):
            f.write("".join("%016x\n" % int(v) for v in words(p)))


# L: 720x480 (seed 7: the picture the frame / field fixtures have always used)
L = picture(7, 720, 480)
write_store("disp_store.hex", *L)
write_want("disp_want_frame.hex", rgb(L[0], up(L[1]), up(L[2])))
# the frame's bare RGB, one dot a line: the video layer of tools/plane_golden.py,
# tools/sub_overlay_golden.py and bench/umd/sub_overlay_tb.sv (dropped by P5f when the
# disp_want_* files replaced it, while those three still read it: restored 2026-10-01)
with open(os.path.join(out, "disp_rgb.hex"), "w") as f:
    f.write("".join("%02x%02x%02x\n" % tuple(p) for p in rgb(L[0], up(L[1]), up(L[2])).reshape(-1, 3)))
Lf = woven444(*L)
write_want("disp_want_field.hex", rgb(*Lf))
write_want("disp_want_blend.hex", rgb(*blend(Lf)))
write_want("disp_want_bob0.hex", rgb(*bob(Lf, 0)))
write_want("disp_want_bob1.hex", rgb(*bob(Lf, 1)))
# S: 480x272
S = picture(11, 480, 272)
write_store("disp_store_s.hex", *S)
Sf = woven444(*S)
write_want("disp_want_s_blend.hex", rgb(*blend(Sf)))
write_want("disp_want_s_bob0.hex", rgb(*bob(Sf, 0)))
write_want("disp_want_s_bob1.hex", rgb(*bob(Sf, 1)))
# T: 720x576, blend (the clip)
T = picture(13, 720, 576)
write_store("disp_store_t.hex", *T)
write_want("disp_want_t_blend.hex", rgb(*blend(woven444(*T)))[:RH])

# 480i Analog Aspect (S2): Letterbox / Crop of the frame and of the pair, and with one kept
# field (V7); the 480x272 picture under Letterbox stays Fit (a control)
Lfr = [L[0], up(L[1]), up(L[2])]
for nm, pl, mode, keep in (("lb", Lfr, "lb", None), ("lb_field", Lf, "lb", None), ("lb_keep1", Lf, "lb", 1),
                           ("lb_keep0", Lf, "lb", 0), ("crop", Lfr, "crop", None), ("crop_keep0", Lf, "crop", 0),
                           ("crop_field", Lf, "crop", None)):
    write_want_de("disp_want_il_%s.hex" % nm, *il_aspect(pl, mode, keep))
# the fit path's identity with the 480p rasters (the S1 arms' premise), checked here
for pl, keep, want in ((Lfr, None, rgb(*Lfr)), (Lf, None, rgb(*Lf)), (Lf, 0, rgb(*bob(Lf, 0))), (Lf, 1, rgb(*bob(Lf, 1)))):
    im, de = il_aspect(pl, "fit", keep)
    assert de.all() and (im == want).all(), "the 480i Fit walker is not the woven / Bob raster"

# ---- the video window (P9) -------------------------------------------------------------
def window(rows, W, H, g, fld=False):
    """rows: three planes (H x W) of source rows (a field store's kept field: fld); g: the
    geometry in the picture's frame rows -> (480 x 720 RGB, de)"""
    wx, wy, ww, wh, hs, vs, x0, y0 = g
    img = np.zeros((RH, RW, 3), np.int64)
    de = np.zeros((RH, RW), bool)
    fmax = 0.0
    X = np.arange(ww)
    B = x0 + X * hs
    t, gx = B >> 16, (B >> 12) & 15
    gx = np.where(t >= W - 1, 0, gx)
    t = np.minimum(t, W - 1)
    t1 = np.minimum(t + 1, W - 1)
    for yy in range(wh):
        Y = wy + yy
        A = y0 + yy * vs
        sl, f = (A >> 17, (A >> 13) & 15) if fld else (A >> 16, (A >> 12) & 15)
        if sl >= H - 1:
            sl, f = H - 1, 0
        out = []
        for p in rows:
            def hrow(r):
                return r[t] + (((r[t1] - r[t]) * gx + 8) >> 4)
            a = hrow(p[sl])
            if f:
                b = hrow(p[sl + 1])
                a = a + (((b - a) * (16 * f) + 128) >> 8)
            out.append(a)
            # the float bilinear at the same (truncated-to-sixteenths) positions
            fr = p[sl] * (1 - f / 16) + (p[min(sl + 1, H - 1)] * (f / 16) if f else 0)
            fl = fr[t] * (1 - gx / 16) + fr[t1] * (gx / 16)
            fmax = max(fmax, float(np.abs(fl - a).max()))
        img[Y, wx:wx + ww] = rgb(*out)
        de[Y, wx:wx + ww] = True
    assert fmax <= 1.0, "the window's fixed point is %.3f from float bilinear" % fmax
    return img, de, fmax


def q16(n, d):
    return (n << 16) // d


def geo(wx, wy, ww, wh, W, H):
    """the host's geometry for a picture W x H into {wx, wy, ww, wh}: steps and centred starts"""
    hs, vs = q16(W, ww), q16(H, wh)
    return (wx, wy, ww, wh, hs, vs, max(0, (hs - 65536) // 2), max(0, (vs - 65536) // 2))


WIN = {
    # name: (store, field-kept parity or None, geometry)
    "half":    ("L", None, geo(200, 100, 360, 240, 720, 480)),
    "low":     ("L", None, geo(301, 77, 209, 139, 720, 480)),       # 29 %, odd origin
    "edge":    ("L", None, geo(14, 9, 706, 471, 720, 480)),         # 98 %, flush right / bottom
    "one":     ("L", None, geo(359, 239, 1, 1, 720, 480)),          # one pixel
    "keep1":   ("L", 1, geo(120, 60, 480, 270, 720, 480)),          # a field store's kept field (frame rows)
    "up":      ("S", None, geo(0, 0, 720, 480, 480, 272)),          # an upscale, the whole raster
    "tall":    ("T", None, geo(0, 0, 720, 480, 720, 576)),          # 576 lines: rows past 511 fetched
}
fmaxes = []
for nm, (st, kp, g) in WIN.items():
    if st == "L":
        rows = [L[0], up(L[1]), up(L[2])] if kp is None else [pl[kp::2] for pl in Lf]
    elif st == "S":
        rows = [S[0], up(S[1]), up(S[2])]
    else:
        rows = [T[0], up(T[1]), up(T[2])]
    H, W = rows[0].shape
    img, de, fm = window(rows, W, H, g, fld=kp is not None)
    fmaxes.append(fm)
    write_want_de("disp_want_win_%s.hex" % nm, img, de)
    with open(os.path.join(out, "disp_win_%s.args" % nm), "w") as f:
        f.write("+win +wx=%d +wy=%d +ww=%d +wh=%d +hs=%d +vs=%d +x0=%d +y0=%d\n" % g)

# a refused rectangle (700 + 40 > 720): the reader shows nothing and raises win_bad
write_want_de("disp_want_win_bad.hex", np.zeros((RH, RW, 3), np.int64), np.zeros((RH, RW), bool))
with open(os.path.join(out, "disp_win_bad.args"), "w") as f:
    f.write("+win +bad +wx=700 +wy=10 +ww=40 +wh=20 +hs=65536 +vs=65536 +x0=0 +y0=0\n")

# ---- field matching (fj#80) ---------------------------------------------------------------
import sys                                                          # noqa: E402
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import telecine_ref                                                 # noqa: E402
M = picture(19, 720, 480)
write_store("disp_store_m.hex", *M)


def matched(keep):
    """L's field `keep` with M's other field, as one field store's three planes"""
    out = []
    for a, b in zip(L, M):
        p = b.copy()
        p[keep::2] = a[keep::2]
        out.append(p)
    return out


def cm_args(name, Y):
    c, r = telecine_ref.observe(Y.astype(np.uint8))[(8, 1)]
    with open(os.path.join(out, name), "w") as f:
        f.write("+cmc=%d +cmr=%d\n" % (c, r))


cm_args("disp_cm_field.args", L[0])
for keep in (0, 1):
    mp = matched(keep)
    write_want("disp_want_match%d.hex" % keep, rgb(*woven444(*mp)))
    cm_args("disp_cm_match%d.args" % keep, mp[0])

oracle = "ffmpeg separatefields + interlace lowpass" if HAVE_FFMPEG else \
    "numpy (NO ffmpeg: not an independent oracle)"
print("disp_golden: 720x480, 480x272, 720x576 stores; frame, field, blend, bob0/1 rasters (%s)" % oracle)
print("disp_golden: %d video windows (P9), max |fixed - float bilinear| %.3f (bound 1)" % (len(WIN), max(fmaxes)))
