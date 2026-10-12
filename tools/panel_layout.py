#!/usr/bin/env python3
"""panel_layout.py -- the control panel's layout, icons and pixel model (P6d, docs/panel.md).

The panel is drawn by the UMD Main into a premultiplied ARGB plane (docs/panel.md §2-§3). This
file writes its look down once. It serves as:
  * the MOCKUPS the maintainer approves before any C (--mockups: each state over a real frame,
    composited as the core does -- the video, the plane by plane_blend's formula, the transport HUD
    over both -- at the raster and at the displayed aspect, plus a contact sheet and an icon sheet);
  * later the renderer's GOLDEN (bench/umd/run_panel.sh, stage C2): the PAGE (page()) is what the
    C renderer must write, byte for byte.

THE LOOK. The PSP's panel is the reference for the FEEL (transport_hud.md §2: inspired by, not
recreated); the icons are this core's own, drawn with transport_font.py's round pen at the PSP's
proportion. Each icon and the caption are the HUD's four pixel classes (transport_font.py), mapped
onto premultiplied alpha so the panel reads as the HUD's sibling:
    clear   alpha 0
    shadow  black at alpha 191 (the HUD's `under >> 2`)
    ink     the item's colour at alpha 255
    edge    half the colour at alpha 128 (the HUD's `ink/2 + under/2`)
The selected item is white over a soft white halo; the others grey; an unavailable one dark.
The premultiplied blend over the video is plane_blend's integer formula (compositor.md §3).

THE LAYOUT (docs/panel.md K1): the built features only, two rows centred in the upper half, the
caption under them, on a rounded box (THE LOOK, below). The box (x 185..534, y 90..243) sits
inside title safe at both rasters (72..647 / 48..431) and clear of every HUD slot (the header wash
to line 35, at 480i 54..83; the message strip from 354, at 480i 306), so ONE layout serves 480p
and 480i.
"""
import argparse
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import transport_font as TF  # noqa: E402
import transport_layout as TL  # noqa: E402
from transport_font import line, dot, arc, rrect, keep, ellipse_poly  # noqa: E402

W, H = 720, 480
SS, XS = TF.SS, TF.XS

# ---- the items (K1: the built features only), in their rows -------------------------------------
ROWS = [["menu", "goto", "audio", "sub", "display"],
        ["prev", "next", "rew", "ff", "play", "pause", "stop"],
        ["ab", "clear"]]                 # A-B Repeat (docs/ab_repeat.md AB8): the PSP's row 3, Repeat left out
CAPTION = {"menu": "UMD Menu", "goto": "Go To", "audio": "Audio", "sub": "Subtitles",
           "display": "Display", "prev": "Previous Chapter", "next": "Next Chapter",
           "rew": "Fast Reverse", "ff": "Fast Forward", "play": "Play", "pause": "Pause",
           "stop": "Stop", "ab": "A-B Repeat", "clear": "Clear"}
START = "display"                       # K8, measured: the cursor starts on Display
IN_MENU = {"menu", "display", "stop"}   # K9 / §3.4: what is available over a disc menu

# ---- the geometry (720 x 480 raster) ----------------------------------------------------------
IW, IH = 34, 28                         # an icon's canvas: design units x * XS (40.8 wide), y 1:1
PITCH = 48                              # item to item (the PSP's ~32 px x 1.5)
ROW_TOP = [100, 154, 208]               # rows' canvas tops: centres 114 / 168 (the PSP's 59 / 90 x 1.765, 8 lower:
                                        # the box clears the 480i header wash, lines 54-83); A-B's row 3 54 lower
CAP_TOP = 264                           # the caption's cell row, 56 below the last row's top (was 210 under row 2):
                                        # the box ends at line 298, clear of 480i's message strip (306)
CX = W // 2
PEN = 1.4                               # the icons' pen radius (the HUD's 1.2 on its 24-line cells)
ICON_PEN = {"clear": 0.8}               # Clear's word needs a finer pen: five letters on a 34-pixel canvas
HALO_PAD = 6                            # the halo's reach past the icon's canvas
HALO_A = 120                            # the halo's peak alpha (the PSP's glow, ~98 at its edge)

# colours: the HUD's palette (transport_layout.INK) where it serves
WHITE = TL.INK[TL.C_WHITE]              # selected (240)
GREY = (176, 176, 184)                  # unselected: the PSP's ~178 (the HUD's 150 grey read dim here)
DARK = (84, 84, 92)                     # unavailable
# THE LOOK: "box" (proposed) -- the panel on a rounded box in the HUD's own box tint, the HUD's
# `(under >> 2) + (12, 28, 72)` as premultiplied ARGB (black at alpha 191 plus the tint), so it reads
# over a bright or busy picture as the HUD's captions do; "psp" -- the icons bare on the picture, as
# the PSP draws them (its screen is small; on a TV a busy frame swallows them: the mockups)
BOX_RGBA = (12, 28, 72, 191)
BOX_PAD_X, BOX_PAD_Y, BOX_R = 14, 10, 10


def ixy(row, k):
    """an item's canvas top-left"""
    n = len(ROWS[row])
    x0 = CX - (n * PITCH) // 2 + k * PITCH + (PITCH - IW) // 2
    return x0, ROW_TOP[row]


# ---- the icons: design units, 40.8 x 28, centre (20.4, 14); x is drawn x XS ------------------------

def _mirror(pts, w=40.8):
    out = np.array(pts, dtype=float).copy()
    out[:, 0] = w - out[:, 0]
    return out


def icons():
    """name -> (ink paths, filled polygons)"""
    ic = {}
    ic["play"] = ([], [[(13, 5), (13, 23), (29.5, 14)]])
    ic["pause"] = ([], [[(12.5, 5.5), (17.5, 5.5), (17.5, 22.5), (12.5, 22.5)],
                        [(23.3, 5.5), (28.3, 5.5), (28.3, 22.5), (23.3, 22.5)]])
    ic["stop"] = ([], [[(12, 6), (28.8, 6), (28.8, 22), (12, 22)]])
    ff = [[(5, 7), (5, 21), (20.4, 14)], [(20.4, 7), (20.4, 21), (35.8, 14)]]
    ic["ff"] = ([], ff)
    ic["rew"] = ([], [[tuple(p) for p in _mirror(pg)] for pg in ff])
    nx = [[(3.5, 7), (3.5, 21), (17, 14)], [(17, 7), (17, 21), (30.5, 14)],
          [(32, 7), (36, 7), (36, 21), (32, 21)]]
    ic["next"] = ([], nx)
    ic["prev"] = ([], [[tuple(p) for p in _mirror(pg)] for pg in nx])
    # a quaver: an oval head, a stem, a flag
    ic["audio"] = ([line(21.2, 20.5, 21.2, 4.6), line(21.2, 4.6, 27.6, 9.8), line(27.6, 9.8, 27.0, 13.2)],
                   [ellipse_poly(16.6, 20.6, 5.2, 3.7, -20)])
    # a speech balloon (the HUD's subtitle tag, drawn larger) with two lines of text in it
    ic["sub"] = ([keep(rrect(6.5, 3.5, 34.3, 19.5, 5.5), lambda x, y: not (y > 18.5 and 10.5 < x < 18.5)),
                  line(11.5, 19.5, 9.8, 25.0), line(9.8, 25.0, 18.5, 19.5),
                  line(12.5, 9.2, 28.3, 9.2), line(12.5, 13.8, 23.8, 13.8)], [])
    # Display: an "i" in a rounded frame (the information overlay)
    ic["display"] = ([rrect(9.4, 3.5, 31.4, 24.5, 4.5), line(20.4, 12.8, 20.4, 20.2)],
                     [ellipse_poly(20.4, 8.6, 1.9, 1.9, 0)])
    # Go To: a jump -- an arc over to the right, its arrowhead pointing down onto the landing
    a0, a1, cx, cy, r = 200.0, 318.0, 19.0, 21.5, 11.5
    ex, ey = cx + r * math.cos(math.radians(a1)), cy + r * math.sin(math.radians(a1))
    dx, dy = -math.sin(math.radians(a1)), math.cos(math.radians(a1))      # the tangent, increasing angle
    px, py = -dy, dx
    head = [(ex + 5.5 * dx, ey + 5.5 * dy), (ex + 4.0 * px, ey + 4.0 * py), (ex - 4.0 * px, ey - 4.0 * py)]
    ic["goto"] = ([arc(cx, cy, r, r, a0, a1 - 4), line(5.0, 25.0, 12.0, 25.0), line(26.0, 25.0, 36.0, 25.0)],
                  [head])
    # UMD Menu: the disc -- a ring and its hub
    ring = ellipse_poly(20.4, 14.0, 11.0, 11.0, 0)
    hub = ellipse_poly(20.4, 14.0, 3.0, 3.0, 0)
    ic["menu"] = ([np.array(ring + ring[:1]), np.array(hub + hub[:1])], [])
    # A-B Repeat: the letters, as the PSP's item shows them (its photo, 2026-10-07)
    ab = [line(4.0, 22.0, 9.0, 6.0), line(9.0, 6.0, 14.0, 22.0), line(5.9, 16.5, 12.1, 16.5),
          line(16.8, 14.0, 22.0, 14.0),
          np.concatenate([line(30.2, 22.0, 25.4, 22.0), line(25.4, 22.0, 25.4, 6.0), line(25.4, 6.0, 30.4, 6.0),
                          arc(30.4, 9.8, 3.8, 3.8, -90, 90), line(30.4, 13.6, 25.4, 13.6)]),
          np.concatenate([line(25.4, 13.6, 30.8, 13.6), arc(30.8, 17.8, 4.2, 4.2, -90, 90)])]
    ic["ab"] = (ab, [])
    # Clear: the word in a rounded pill, as the PSP's item (the maintainer's photo, 2026-10-07)
    y0, y1, w, g = 9.0, 19.0, 4.7, 1.8                  # the letters' top / bottom, a letter's width, the gap
    x = 20.4 - (5 * w + 4 * g) / 2
    xs = [x + k * (w + g) for k in range(5)]
    ym = (y0 + y1) / 2
    cx_, lx, ex, ax, rx = xs
    ic["clear"] = ([rrect(1.2, 5.0, 39.6, 23.0, 9.0),
                    arc(cx_ + w / 2 + 0.6, ym, w / 2 + 0.6, (y1 - y0) / 2, 50, 310),          # C
                    np.concatenate([line(lx, y0, lx, y1), line(lx, y1, lx + w, y1)]),       # L
                    np.concatenate([line(ex + w, y0, ex, y0), line(ex, y0, ex, y1), line(ex, y1, ex + w, y1)]),
                    line(ex, ym, ex + w * 0.85, ym),                                       # E
                    line(ax, y1, ax + w / 2, y0), line(ax + w / 2, y0, ax + w, y1),
                    line(ax + w * 0.22, ym + 1.4, ax + w * 0.78, ym + 1.4),                # A
                    np.concatenate([line(rx, y1, rx, y0), line(rx, y0, rx + w * 0.55, y0),
                                    arc(rx + w * 0.55, y0 + 2.25, w * 0.45, 2.25, -90, 90),
                                    line(rx + w * 0.55, y0 + 4.5, rx, y0 + 4.5)]),
                    line(rx + w * 0.45, y0 + 4.5, rx + w, y1)], [])                         # R
    return ic


def icon_classes(paths, polys, pen=PEN):
    """-> (IH, IW) classes 0-3, transport_font.classes() on the icon's canvas"""
    bits = np.zeros((IH * SS, IW * SS), dtype=bool)
    TF._stamp(bits, paths, pen)
    if polys:
        TF._fill(bits, polys)
        TF._stamp(bits, [np.concatenate([line(*a, *b) for a, b in zip(pg, list(pg[1:]) + [pg[0]])])
                         for pg in polys], 0.7)
    cov = bits.reshape(IH, SS, IW, SS).mean(axis=(1, 3))
    cls = np.zeros((IH, IW), dtype=np.uint8)
    cls[cov >= TF.EDGE_LO] = 3
    cls[cov >= TF.INK_LO] = 2
    sh = np.zeros_like(cls, dtype=bool)
    sh[1:, 1:] = (cls[:-1, :-1] == 2) | (cls[:-1, :-1] == 3)
    cls[(cls == 0) & sh] = 1
    return cls


ICON_CLS = None


def icon_cls(name):
    global ICON_CLS
    if ICON_CLS is None:
        ICON_CLS = {n: icon_classes(*v, pen=ICON_PEN.get(n, PEN)) for n, v in icons().items()}
    return ICON_CLS[name]


# ---- premultiplied ARGB, the plane's arithmetic -------------------------------------------------

def over(dst, src):
    """src over dst, both premultiplied (..., 4) int arrays: plane_blend's rounding (compositor.md §3)"""
    a = src[..., 3:4]
    t = dst * (255 - a)
    return np.minimum(255, src + ((t + 128 + ((t + 128) >> 8)) >> 8))


def blend_video(video, page):
    """the core's plane_blend: out = s + round(d (255 - a) / 255) -> (480, 720, 3) uint8"""
    d = video.astype(np.int64)
    s = page[..., :3].astype(np.int64)
    a = page[..., 3:4].astype(np.int64)
    t = d * (255 - a)
    return np.minimum(255, s + ((t + 128 + ((t + 128) >> 8)) >> 8)).astype(np.uint8)


def premul(rgb, a):
    """round(c a / 255), the plane writer's idiom"""
    t = np.asarray(rgb, dtype=np.int64) * a
    return (t + 128 + ((t + 128) >> 8)) >> 8


def cls_rgba(cls, rgb):
    out = np.zeros(cls.shape + (4,), dtype=np.int64)
    out[cls == 2] = list(rgb) + [255]
    out[cls == 3] = list(premul(rgb, 128)) + [128]
    out[cls == 1] = [0, 0, 0, 191]
    return out


def _box_sum(a, r):
    """the sum over a (2r + 1)^2 window (same size, zero outside), integers"""
    k = 2 * r + 1
    p = np.pad(a, r)
    c = np.cumsum(np.cumsum(p, axis=0), axis=1)
    c = np.pad(c, ((1, 0), (1, 0)))
    return c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]


# The halo, in integers so the C renderer reproduces it exactly (C2): the ink / edge mask summed over a
# 5 x 5 window twice (S in 0..625), alpha = min(HALO_A, round(HALO_A * 2.2 * S / 625))
HALO_NUM, HALO_DEN = 22, 6250           # 2.2 / 625


def halo_rgba(cls):
    """the selected icon's glow: white, premultiplied, on a canvas HALO_PAD larger each side"""
    m = np.pad(((cls == 2) | (cls == 3)).astype(np.int64), HALO_PAD)
    s = _box_sum(_box_sum(m, 2), 2)
    a = np.minimum(HALO_A, (s * HALO_A * HALO_NUM + HALO_DEN // 2) // HALO_DEN).astype(np.int64)
    out = np.zeros(m.shape + (4,), dtype=np.int64)
    out[..., 0] = out[..., 1] = out[..., 2] = premul(255, a)
    out[..., 3] = a
    return out


def text_rgba(s, rgb):
    g = TL.glyphs()
    cls = np.concatenate([g[(ord(ch) - 32) if 32 <= ord(ch) <= 126 else TL.ICON["TOFU"]] for ch in s], axis=1)
    return cls_rgba(cls, rgb)


def _put(page, x0, y0, el):
    h, w = el.shape[:2]
    page[y0:y0 + h, x0:x0 + w] = over(page[y0:y0 + h, x0:x0 + w], el)


# ---- the panel's state and its page -------------------------------------------------------------

def panel_state(**kw):
    st = dict(sel=START,          # the item the cursor is on
              in_menu=False,      # over a disc menu (§3.4): only IN_MENU available
              has_sub=True,       # the title has a subtitle track (Subtitles dark without)
              has_menu=True,      # the engine runs for this disc (UMD Menu dark without)
              look="box")         # "box" (proposed) or "psp" (bare): THE LOOK above
    st.update(kw)
    return st


def available(st, name):
    if st["in_menu"]:
        return name in IN_MENU and (name != "menu" or st["has_menu"])
    if name == "sub":
        return st["has_sub"]
    if name == "menu":
        return st["has_menu"]
    return True


def region():
    """the panel's bounding rectangle (x0, y0, x1, y1), exclusive: the flip's rectangle"""
    xs, ys = [], []
    for row, names in enumerate(ROWS):
        for k in range(len(names)):
            x0, y0 = ixy(row, k)
            xs += [x0 - HALO_PAD, x0 + IW + HALO_PAD]
            ys += [y0 - HALO_PAD, y0 + IH + HALO_PAD]
    longest = max(len(c) for c in CAPTION.values())
    xs += [CX - longest * TF.CW // 2 - 2, CX + (longest * TF.CW + 1) // 2 + 2]
    ys += [CAP_TOP + TF.CH]
    return min(xs), min(ys), max(xs), max(ys)


def box_geom():
    """the box's rectangle (x0, y0, w, h): region() padded"""
    x0, y0, x1, y1 = region()
    x0, y0, x1, y1 = x0 - BOX_PAD_X + HALO_PAD, y0 - BOX_PAD_Y + HALO_PAD, x1 + BOX_PAD_X - HALO_PAD, y1 + BOX_PAD_Y
    return x0, y0, x1 - x0, y1 - y0


def box_rgba():
    """-> (x0, y0, the box's premultiplied ARGB): a rounded rectangle, its corners anti-aliased by 4 x 4
    coverage. Integers (the C renderer's arithmetic): a subsample's centre in eighths of a pixel,
    p8 = 2 i + 1; inside when its distance past the corner's centre is within the radius; n of 16
    inside -> each channel (n v + 8) // 16"""
    x0, y0, w, h = box_geom()
    r8 = 8 * BOX_R
    yy, xx = np.mgrid[0:h * 4, 0:w * 4]
    px8, py8 = 2 * xx + 1, 2 * yy + 1
    dx = np.maximum(0, np.maximum(r8 - px8, px8 - (8 * w - r8)))
    dy = np.maximum(0, np.maximum(r8 - py8, py8 - (8 * h - r8)))
    n = ((dx * dx + dy * dy) <= r8 * r8).reshape(h, 4, w, 4).sum(axis=(1, 3)).astype(np.int64)
    out = np.zeros((h, w, 4), dtype=np.int64)
    for c in range(4):
        out[..., c] = (n * BOX_RGBA[c] + 8) // 16
    return x0, y0, out


def page(st, under=None):
    """-> (480, 720, 4) premultiplied ARGB: the plane the UMD Main writes. `under`: the page below the
    panel (the subtitle shown, premultiplied: docs/panel.md §2), else transparent"""
    pg = np.zeros((H, W, 4), dtype=np.int64) if under is None else under.astype(np.int64).copy()
    if st["look"] == "box":
        _put(pg, *box_rgba())
    for row, names in enumerate(ROWS):
        for k, name in enumerate(names):
            x0, y0 = ixy(row, k)
            cls = icon_cls(name)
            if name == st["sel"]:
                _put(pg, x0 - HALO_PAD, y0 - HALO_PAD, halo_rgba(cls))
                rgb = WHITE
            else:
                rgb = GREY if available(st, name) else DARK
            _put(pg, x0, y0, cls_rgba(cls, rgb))
    cap = CAPTION[st["sel"]]
    _put(pg, CX - len(cap) * TF.CW // 2, CAP_TOP, text_rgba(cap, WHITE if available(st, st["sel"]) else DARK))
    return pg


# ---- the UMD Main's art (--gen): main/support/umd/umd_panel_art.{c,h} ------------------------------
# The renderer (umd_panel.c, C2) draws from these and the constants alone: the icons' and the font's
# classes (2 bits a pixel, row-major over the whole canvas, the first pixel in a byte's top pair), the
# captions, the geometry and the colours. The halo and the box are recomputed in C by the integer
# rules above (halo_rgba, box_rgba): no float, no table.

ART_C = os.path.join(ROOT, "main", "support", "umd", "umd_panel_art.c")
ART_H = os.path.join(ROOT, "main", "support", "umd", "umd_panel_art.h")


def _pack(cls):
    flat = [int(v) for v in np.asarray(cls).reshape(-1)]
    assert len(flat) % 4 == 0
    return [(flat[i] << 6) | (flat[i + 1] << 4) | (flat[i + 2] << 2) | flat[i + 3] for i in range(0, len(flat), 4)]


def _bytes(bs, indent="\t\t"):
    out = []
    for i in range(0, len(bs), 16):
        out.append(indent + ", ".join("0x%02x" % b for b in bs[i:i + 16]) + ",")
    return "\n".join(out)


def gen_art():
    """-> (the .h text, the .c text)"""
    names = [n for r in ROWS for n in r]
    bx, by, bw, bh = box_geom()
    hd = ["// generated by tools/panel_layout.py --gen -- do not edit (docs/panel.md §3.5)",
          "#pragma once", "", "#include <stdint.h>", ""]
    defs = [("N", len(names)), ("ROW0_N", len(ROWS[0])), ("ROW1_N", len(ROWS[1])), ("ROW2_N", len(ROWS[2])),
            ("IW", IW), ("IH", IH), ("PITCH", PITCH), ("CX", CX),
            ("ROW_TOP0", ROW_TOP[0]), ("ROW_TOP1", ROW_TOP[1]), ("ROW_TOP2", ROW_TOP[2]), ("CAP_TOP", CAP_TOP),
            ("HALO_PAD", HALO_PAD), ("HALO_A", HALO_A), ("HALO_NUM", HALO_NUM), ("HALO_DEN", HALO_DEN),
            ("BOX_X0", bx), ("BOX_Y0", by), ("BOX_W", bw), ("BOX_H", bh), ("BOX_R", BOX_R),
            ("BOX_R8", BOX_RGBA[0]), ("BOX_G8", BOX_RGBA[1]), ("BOX_B8", BOX_RGBA[2]), ("BOX_A8", BOX_RGBA[3]),
            ("WHITE_R", WHITE[0]), ("WHITE_G", WHITE[1]), ("WHITE_B", WHITE[2]),
            ("GREY_R", GREY[0]), ("GREY_G", GREY[1]), ("GREY_B", GREY[2]),
            ("DARK_R", DARK[0]), ("DARK_G", DARK[1]), ("DARK_B", DARK[2]),
            ("FONT_CW", TF.CW), ("FONT_CH", TF.CH), ("FONT_N", 95),
            ("SHADOW_A", 191), ("EDGE_A", 128)]
    hd += ["#define UMD_PANEL_%-10s %d" % (k, v) for k, v in defs]
    hd += ["", "// the items, in ROWS order (row 0, row 1, row 2)", "enum {"]
    hd += ["\tUMD_PI_%s = %d," % (n.upper(), i) for i, n in enumerate(names)]
    hd += ["};", "#define UMD_PANEL_START    UMD_PI_%s" % START.upper(), "",
           "#ifdef __cplusplus", "extern \"C\" {", "#endif",
           "extern const char *const umd_panel_caption[UMD_PANEL_N];",
           "// classes, 2 bits a pixel (0 clear 1 shadow 2 ink 3 edge), row-major, a byte's top pair first",
           "extern const uint8_t umd_panel_icon[UMD_PANEL_N][UMD_PANEL_IW * UMD_PANEL_IH / 4];",
           "extern const uint8_t umd_panel_font[UMD_PANEL_FONT_N][UMD_PANEL_FONT_CW * UMD_PANEL_FONT_CH / 4];  // ASCII 32-126",
           "#ifdef __cplusplus", "}", "#endif", ""]
    g = TL.glyphs()
    cc = ["// generated by tools/panel_layout.py --gen -- do not edit (docs/panel.md §3.5)",
          '#include "umd_panel_art.h"', "",
          "const char *const umd_panel_caption[UMD_PANEL_N] = {"]
    cc += ['\t"%s",' % CAPTION[n] for n in names]
    cc += ["};", "", "const uint8_t umd_panel_icon[UMD_PANEL_N][UMD_PANEL_IW * UMD_PANEL_IH / 4] = {"]
    for n in names:
        cc += ["\t{ // %s" % n, _bytes(_pack(icon_cls(n))), "\t},"]
    cc += ["};", "", "const uint8_t umd_panel_font[UMD_PANEL_FONT_N][UMD_PANEL_FONT_CW * UMD_PANEL_FONT_CH / 4] = {"]
    for i in range(95):
        cc += ["\t{ // %r" % chr(32 + i), _bytes(_pack(g[i])), "\t},"]
    cc += ["};", ""]
    return "\n".join(hd), "\n".join(cc)


# ---- the mockups -------------------------------------------------------------------------------

BG = {  # the rig's own frames (mister.py shot; not committed, .sim/): clean ones, no HUD on them
    "akira": ".sim/rig_p9/ak_film.png",          # Akira's opening (16:9)
    "akira2": ".sim/p7c/a01_loaded.png",         # ... a few seconds on
    "fg": ".sim/rig_p9/fg_play2.png",            # Family Guy's titles (4:3)
    "ap": ".sim/rig_p9/ap_film.png",             # Austin Powers 2's logo (dark)
    "fg_menu": ".sim/rig_p9/s2_fg_main.png",     # Family Guy's disc menu (bright)
    "ak_menu": ".sim/rig_p9/ak_60.png",          # Akira's disc menu
}
AKIRA = dict(title=b"Akira", n_chapters=17, chapter=5, elapsed=631, total=7452)
SUB = TL.AKIRA_SUB                              # a real subtitle unit: Akira 0x80, 410 x 70 at (156, 379)
SUB_HIGH = (TL.AKIRA_SUB[0], 156, 150)          # the same unit placed high: the panel over a subtitle
MOCKUPS = [
    # (name, bg, aspect, caption, panel state, HUD state (None: hidden, a disc menu), subtitle)
    ("p01_open", "akira", "16:9", "Opened: the cursor on Display (K8, measured)",
     panel_state(), TL.hud_state(), None),
    ("p02_ff", "akira2", "16:9", "x on Fast Forward: FF runs, the HUD's caption, the panel stays (K5)",
     panel_state(sel="ff"), TL.hud_state(state="ff", speed=2, popup="ff"), None),
    ("p03_subtitles", "akira", "16:9", "x on Subtitles: a subtitle under the open panel (K2, K13), the HUD's tag",
     panel_state(sel="sub"), TL.hud_state(popup="sub", sub_on=True, sub_track=1, sub_lang=b"en"), SUB),
    ("p04_display", "akira2", "16:9", "Display on under the panel: the header and the bar clear of it",
     panel_state(), TL.hud_state(display=True, **AKIRA), None),
    ("p05_next_4x3", "fg", "4:3", "A 4:3 title: x on Next Chapter, the HUD's Chapter caption",
     panel_state(sel="next"), TL.hud_state(popup="next", chapter=3, n_chapters=6), None),
    ("p06_paused", "ap", "16:9", "Paused, on Play (nothing greyed by the play state: K7)",
     panel_state(sel="play"), TL.hud_state(state="pause"), None),
    ("p07_menu_fg", "fg_menu", "4:3", "Over a disc menu: UMD Menu, Display, Stop available (K9); a bright page",
     panel_state(in_menu=True), None, None),
    ("p08_menu_akira", "ak_menu", "16:9", "Over a disc menu, the cursor on UMD Menu",
     panel_state(in_menu=True, sel="menu"), None, None),
    ("p10_no_subs", "akira2", "16:9", "A title without subtitles: Subtitles dark; the cursor on Go To",
     panel_state(sel="goto", has_sub=False), TL.hud_state(), None),
    ("p11_sub_high", "akira", "16:9", "A subtitle placed high: the panel draws over it",
     panel_state(sel="audio"), TL.hud_state(), SUB_HIGH),
    # the other look, bare as the PSP draws it, on the frames that decide between them
    # A-B Repeat (docs/ab_repeat.md AB8): the PSP's row 3 -- A-B Repeat, Clear (Repeat left out)
    ("p12_ab", "akira2", "16:9", "x on A-B Repeat: A set -- the HUD's icon and A-B, the B blinking; the panel stays",
     panel_state(sel="ab"), TL.hud_state(ab="a", ab_blink=True), None),
    ("p13_clear", "fg", "4:3", "On Clear (always available, measured); a 4:3 title, looping under it",
     panel_state(sel="clear"), TL.hud_state(ab="ab", ab_hold=True), None),
    ("p14_ab_menu", "ak_menu", "16:9", "Over a disc menu: A-B Repeat and Clear dark (K9)",
     panel_state(in_menu=True, sel="display"), None, None),
    ("p15_ab_sub", "akira", "16:9", "A-B Repeat with a subtitle under the panel (the box now ends at line 298)",
     panel_state(sel="ab"), TL.hud_state(), SUB),
    ("a01_open_psp", "akira", "16:9", "ALTERNATIVE look, bare (the PSP's): p01",
     panel_state(look="psp"), TL.hud_state(), None),
    ("a02_ff_psp", "akira2", "16:9", "ALTERNATIVE look, bare: p02 (a busy frame)",
     panel_state(sel="ff", look="psp"), TL.hud_state(state="ff", speed=2, popup="ff"), None),
    ("a05_next_4x3_psp", "fg", "4:3", "ALTERNATIVE look, bare: p05",
     panel_state(sel="next", look="psp"), TL.hud_state(popup="next", chapter=3, n_chapters=6), None),
    ("a07_menu_fg_psp", "fg_menu", "4:3", "ALTERNATIVE look, bare: p07 (a bright page)",
     panel_state(in_menu=True, look="psp"), None, None),
    ("a08_menu_akira_psp", "ak_menu", "16:9", "ALTERNATIVE look, bare: p08",
     panel_state(in_menu=True, sel="menu", look="psp"), None, None),
]


def sub_page(spec):
    """a subtitle unit (straight RGBA, as libpng gives it) into a premultiplied page at its (x, y)"""
    pg = np.zeros((H, W, 4), dtype=np.int64)
    if not spec:
        return pg
    from PIL import Image
    path, x, y = spec
    im = np.array(Image.open(os.path.join(ROOT, path)).convert("RGBA")).astype(np.int64)
    h, w = min(im.shape[0], H - y), min(im.shape[1], W - x)
    a = im[:h, :w, 3]
    for c in range(3):
        pg[y:y + h, x:x + w, c] = premul(im[:h, :w, c], a)
    pg[y:y + h, x:x + w, 3] = a
    return pg


def frame(st, hud, bg, subspec, il=False):
    """the picture on the output: the video, the plane (the panel over the subtitle), the HUD over both"""
    pg = page(st, sub_page(subspec))
    img = blend_video(bg, pg)
    if hud is not None:
        TL.set_layout(il)
        img, _ = TL.render(hud, img)
    return img


def icon_sheet(path, scale=4):
    """every icon unselected, selected (with its halo) and dark, over mid grey and black, at 4x"""
    from PIL import Image
    names = [n for r in ROWS for n in r]
    cw, ch = IW + 2 * HALO_PAD + 4, IH + 2 * HALO_PAD + 4
    sheet = np.zeros((6 * ch, len(names) * cw, 3), dtype=np.uint8)
    for bgrow, bgc in enumerate([(96, 96, 104), (0, 0, 0)]):
        for v in range(3):
            y = (bgrow * 3 + v) * ch
            for i, n in enumerate(names):
                x = i * cw
                tile = np.zeros((ch, cw, 4), dtype=np.int64)
                cls = icon_cls(n)
                if v == 1:
                    _put(tile, 2, 2, halo_rgba(cls))
                _put(tile, 2 + HALO_PAD, 2 + HALO_PAD, cls_rgba(cls, [GREY, WHITE, DARK][v]))
                sheet[y:y + ch, x:x + cw] = blend_video(np.full((ch, cw, 3), bgc, dtype=np.uint8), tile)
    Image.fromarray(sheet).resize((sheet.shape[1] * scale, sheet.shape[0] * scale), Image.NEAREST).save(path)


def mockups(outdir, only=None, il=False):
    from PIL import Image, ImageDraw
    os.makedirs(outdir, exist_ok=True)
    tiles = []
    for name, key, aspect, caption, st, hud, subspec in MOCKUPS:
        if only and name not in only:
            continue
        bg = TL.load_bg(os.path.join(ROOT, BG[key])) if os.path.exists(os.path.join(ROOT, BG[key])) \
            else TL.synthetic_bg()
        img = frame(st, hud, bg, subspec, il)
        Image.fromarray(img).save(os.path.join(outdir, name + "_raster.png"))
        x0, y0, x1, y1 = region()
        Image.fromarray(img[y0 - 8:y1 + 8, x0 - 8:x1 + 8]).resize(
            ((x1 - x0 + 16) * 3, (y1 - y0 + 16) * 3), Image.NEAREST).save(os.path.join(outdir, name + "_zoom.png"))
        if il:                                 # the review guide: title safe, dashed
            img = img.copy()
            sx0, sy0, sx1, sy1 = TL.SAFE
            for x in range(sx0, sx1 + 1, 6):
                img[sy0, x:x + 3] = img[sy1, x:x + 3] = (255, 220, 0)
            for y in range(sy0, sy1 + 1, 6):
                img[y:y + 3, sx0] = img[y:y + 3, sx1] = (255, 220, 0)
        disp = TL.to_display(img, aspect)
        disp.save(os.path.join(outdir, name + ".png"))
        tiles.append((name, caption, disp))
    TL.set_layout(False)
    tw, th, cap_h = 427, 240, 30
    cols = 2
    rows = (len(tiles) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * (tw + 8) + 8, rows * (th + cap_h + 8) + 8), (28, 28, 32))
    d = ImageDraw.Draw(sheet)
    for i, (name, caption, disp) in enumerate(tiles):
        r, c = divmod(i, cols)
        x, y = 8 + c * (tw + 8), 8 + r * (th + cap_h + 8)
        t = disp.resize((tw if disp.width > 700 else 320, th), Image.LANCZOS)
        sheet.paste(t, (x + (tw - t.width) // 2, y))
        d.text((x, y + th + 3), name + ": " + caption[:70], fill=(230, 230, 230))
        if len(caption) > 70:
            d.text((x, y + th + 15), caption[70:140], fill=(230, 230, 230))
    sheet.save(os.path.join(outdir, "sheet.png"))
    icon_sheet(os.path.join(outdir, "icons.png"))
    return len(tiles)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mockups", action="store_true", help="render every state in MOCKUPS, the sheets")
    ap.add_argument("--il", action="store_true", help="the 480i raster: the HUD's title-safe layout, the safe area dashed")
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--out", help="default .sim/panel_mockups[_il]")
    ap.add_argument("--gen", action="store_true", help="write main/support/umd/umd_panel_art.{c,h}")
    a = ap.parse_args(argv)
    if a.gen:
        h, c = gen_art()
        for path, text in ((ART_H, h), (ART_C, c)):
            with open(path, "w") as f:
                f.write(text)
        print("wrote %s and %s" % (os.path.relpath(ART_H, ROOT), os.path.relpath(ART_C, ROOT)))
    if a.mockups:
        out = a.out or os.path.join(ROOT, ".sim", "panel_mockups" + ("_il" if a.il else ""))
        n = mockups(out, a.only, a.il)
        print("wrote %d mockups, sheet.png and icons.png to %s" % (n, os.path.relpath(out, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
