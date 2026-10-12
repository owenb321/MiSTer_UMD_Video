#!/usr/bin/env python3
"""transport_font.py -- the transport HUD's own font and icons (P6b5, docs/transport_hud.md S6).

Drawn for this core, not traced and not rasterised from a typeface: every glyph is a few
strokes (lines, quarter-rounded rectangles, arcs) on the cell's grid, stamped with a round
pen and supersampled 8x8, so the rounded look comes from the pen. The PSP player is the
reference for the FEEL only (transport_hud.md: inspiration, not recreation).

The cell is 10 x 24 raster pixels (the 720 x 480 raster). The glyphs are designed on a
12 x 24 grid and drawn with x scaled by 10 / 12 (the pen stays round): on a 16:9 title a
raster pixel shows ~1.19 wide, so the type reads at about its designed proportions there,
and ~26 % narrower on a 4:3 title. Metrics (the design grid), as stroke centre lines: cap / ascender 4, x-height 8.5, baseline 18.5, descender 22.5; the
pen's radius is PEN, so ink spans ~3-20 for a capital.

Every pixel is one of four classes (2 bits, MSB pair = the leftmost pixel of a row):
    0  clear       the layer below (a box, a wash or the picture)
    1  shadow      the layer below at a quarter: the drop shadow, (+1, +1) from the ink,
                   and the digit cut out of a speed badge
    2  ink         the cell's colour
    3  edge        half the cell's colour plus half the layer below: one level of
                   anti-aliasing (coverage EDGE_LO .. INK_LO)
The arithmetic of each class is transport_layout.py's (the golden), shifts and adds only.

Glyph index map (7 bits, 128 glyphs):
    0-94     ASCII 32-126: index = byte - 32 (the title's bytes map by one subtraction)
    95-127   icons, below (ICONS); two-cell icons take two consecutive indices, left first

Emits:
    umd/transport_font.mem   $readmemh: 128 x 24 words of 20 bits, address = glyph * 24 + row
                             (3,072 words: 6 M10K as 1024 x 10 blocks, two wide, docs/transport_hud.md S6)
    .sim/transport_font_preview.png   the glyph sheet at 4x, classes coloured (not committed)
"""
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)

CW, CH = 10, 24                 # the cell
DW = 12                         # the design grid's cell width: x is scaled by CW / DW
XS = CW / DW
NGLYPH = 128
SS = 8                          # supersampling per axis
PEN = 1.2                       # pen radius, raster pixels
THIN = 0.95                     # ... for M W m w, three stems in ten pixels
INK_LO, EDGE_LO = 0.55, 0.18    # coverage thresholds: ink, edge

# metrics (stroke centre lines)
T, X, B, D = 4.0, 8.5, 18.5, 22.5
L, R = 2.5, 9.5                 # capitals and digits
LL, LR = 3.0, 9.0               # lower case
RC, RL = 3.2, 2.6               # corner radii: capitals / lower case
MID = 11.25                     # the capitals' middle


# ---- the stroke primitives: each returns an (N, 2) array of pen-centre points ------------

def _n(length):
    return max(2, int(math.ceil(length * SS * 2)))


def line(x0, y0, x1, y1):
    n = _n(math.hypot(x1 - x0, y1 - y0))
    t = np.linspace(0.0, 1.0, n)
    return np.stack([x0 + (x1 - x0) * t, y0 + (y1 - y0) * t], axis=1)


def dot(x, y):
    return np.array([[x, y]])


def arc(cx, cy, rx, ry, a0, a1):
    """Degrees, 0 = +x, 90 = +y (down); from a0 to a1."""
    n = _n(abs(a1 - a0) / 360.0 * 2 * math.pi * max(rx, ry))
    a = np.radians(np.linspace(a0, a1, n))
    return np.stack([cx + rx * np.cos(a), cy + ry * np.sin(a)], axis=1)


def rrect(x0, y0, x1, y1, r):
    """The outline of a rectangle with quarter-round corners of radius r (clipped to fit)."""
    r = min(r, (x1 - x0) / 2.0, (y1 - y0) / 2.0)
    return np.concatenate([
        line(x0 + r, y0, x1 - r, y0), arc(x1 - r, y0 + r, r, r, -90, 0),
        line(x1, y0 + r, x1, y1 - r), arc(x1 - r, y1 - r, r, r, 0, 90),
        line(x1 - r, y1, x0 + r, y1), arc(x0 + r, y1 - r, r, r, 90, 180),
        line(x0, y1 - r, x0, y0 + r), arc(x0 + r, y0 + r, r, r, 180, 270)])


def keep(pts, pred):
    """The points of a path for which pred(x, y) holds (cuts an opening in a shape)."""
    m = np.array([bool(pred(x, y)) for x, y in pts], dtype=bool)
    return pts[m]


def mirror(pts, w=12):
    out = pts.copy()
    out[:, 0] = w - out[:, 0]
    return out


# ---- the glyphs ---------------------------------------------------------------------------
# Each entry: a list of paths (point arrays). Letters are centred on the 12-pixel advance.

def upper():
    g = {}
    g['A'] = [line(L - 0.3, B, 6, T), line(6, T, R + 0.3, B), line(3.9, 13.5, 8.1, 13.5)]
    g['B'] = [line(L, T, L, B), line(L, T, 5, T), line(L, MID, 5, MID), line(L, B, 5, B),
              keep(rrect(L, T, R - 0.6, MID, 2.8), lambda x, y: x >= 4.5),
              keep(rrect(L, MID, R, B, RC), lambda x, y: x >= 4.5)]
    g['C'] = [keep(rrect(L, T, R, B, RC), lambda x, y: not (x > 7 and 7.5 < y < 15))]
    g['D'] = [line(L, T, L, B), line(L, T, 5, T), line(L, B, 5, B),
              keep(rrect(L, T, R, B, 4.2), lambda x, y: x >= 4.5)]
    g['E'] = [line(L, T, L, B), line(L, T, R, T), line(L, MID, 8.5, MID), line(L, B, R, B)]
    g['F'] = [line(L, T, L, B), line(L, T, R, T), line(L, MID, 8.5, MID)]
    g['G'] = [keep(rrect(L, T, R, B, RC), lambda x, y: not (x > 7 and 7.5 < y < 11.8)),
              line(6.5, 11.8, R, 11.8)]
    g['H'] = [line(L, T, L, B), line(R, T, R, B), line(L, MID, R, MID)]
    g['I'] = [line(6, T, 6, B), line(4, T, 8, T), line(4, B, 8, B)]
    g['J'] = [line(8.8, T, 8.8, 14.5), line(5.5, T, 8.8, T),
              keep(rrect(L, 6, 8.8, B, RC), lambda x, y: y >= 14.5)]
    g['K'] = [line(L, T, L, B), line(R, T, L + 0.4, 12.2), line(5.2, 10.3, R, B)]
    g['L'] = [line(L, T, L, B), line(L, B, R, B)]
    g['M'] = [line(1.0, B, 1.0, T), line(1.0, T, 6, 13), line(6, 13, 11.0, T),
              line(11.0, T, 11.0, B)]
    g['N'] = [line(L, B, L, T), line(L, T, R, B), line(R, B, R, T)]
    g['O'] = [rrect(L, T, R, B, RC)]
    g['P'] = [line(L, T, L, B), line(L, T, 5, T), line(L, 12, 5, 12),
              keep(rrect(L, T, R, 12, 3.0), lambda x, y: x >= 4.5)]
    g['Q'] = [rrect(L, T, R, B, RC), line(7, 15, R + 0.6, B + 1.2)]
    g['R'] = g['P'] + [line(6, 12, R, B)]
    g['S'] = [keep(rrect(L, T, R, MID, 3.0), lambda x, y: not (x > 7 and y > 6.8)),
              keep(rrect(L, MID, R, B, RC), lambda x, y: not (x < 5 and y < 15.3))]
    g['T'] = [line(L - 0.5, T, R + 0.5, T), line(6, T, 6, B)]
    g['U'] = [keep(rrect(L, -6, R, B, RC), lambda x, y: y >= T)]
    g['V'] = [line(L - 0.3, T, 6, B), line(6, B, R + 0.3, T)]
    g['W'] = [line(0.9, T, 3.4, B), line(3.4, B, 6, 9), line(6, 9, 8.6, B), line(8.6, B, 11.1, T)]
    g['X'] = [line(L, T, R, B), line(R, T, L, B)]
    g['Y'] = [line(L - 0.2, T, 6, 11.5), line(R + 0.2, T, 6, 11.5), line(6, 11.5, 6, B)]
    g['Z'] = [line(L, T, R, T), line(R, T, L, B), line(L, B, R, B)]
    return g


def lower():
    g = {}
    bowl = rrect(LL, X, LR, B, RL)
    g['a'] = [bowl, line(LR, X, LR, B)]
    g['b'] = [line(LL, T, LL, B), bowl]
    g['c'] = [keep(bowl, lambda x, y: not (x > 6.5 and X + 2.4 < y < B - 2.4))]
    g['d'] = [line(LR, T, LR, B), bowl]
    g['e'] = [keep(bowl, lambda x, y: not (x > 6.5 and 13.6 < y < B - 2.0)),
              line(LL, 13.5, LR, 13.5)]
    g['f'] = [keep(rrect(5, T, 9.8, 40, 2.8), lambda x, y: y <= B and not (x > 7.6 and y > T + 1.6)),
              line(3, X, 8.5, X)]
    g['g'] = [rrect(LL, X, LR, 17.5, RL), line(LR, X, LR, 20),
              keep(rrect(LL, 12, LR, D, RL), lambda x, y: y >= 19.8 and not (x < 4 and y < 21))]
    g['h'] = [line(LL, T, LL, B), keep(rrect(LL, X, LR, 30, RL), lambda x, y: y <= B)]
    g['i'] = [line(6, X, 6, B), dot(6, 4.9)]
    g['j'] = [line(7, X, 7, 20), dot(7, 4.9),
              keep(rrect(3, 10, 7, D, RL), lambda x, y: y >= 19.8 and x >= 3.8)]
    g['k'] = [line(3.5, T, 3.5, B), line(9, X, 3.8, 14), line(5.8, 12.6, 9, B)]
    g['l'] = [line(5.2, T, 5.2, B - RL), keep(rrect(5.2, 0, 9.4, B, RL), lambda x, y: y >= B - RL and x <= 7.4)]
    g['m'] = [line(1.0, X, 1.0, B), keep(rrect(1.0, X, 6, 30, 2.0), lambda x, y: y <= B),
              keep(rrect(6, X, 11.0, 30, 2.0), lambda x, y: y <= B)]
    g['n'] = [line(LL, X, LL, B), keep(rrect(LL, X, LR, 30, RL), lambda x, y: y <= B)]
    g['o'] = [bowl]
    g['p'] = [line(LL, X, LL, D), bowl]
    g['q'] = [line(LR, X, LR, D), bowl]
    g['r'] = [line(4, X, 4, B), keep(rrect(4, X, 9.5, 30, RL), lambda x, y: y <= X + 2.2 and x <= 9.2)]
    g['s'] = [keep(rrect(LL, X, LR, 13.5, 2.2), lambda x, y: not (x > 6.6 and y > X + 1.8)),
              keep(rrect(LL, 13.5, LR, B, 2.4), lambda x, y: not (x < 5.4 and y < B - 1.8))]
    g['t'] = [line(5, 5.2, 5, B - RL), keep(rrect(5, 0, 9, B, RL), lambda x, y: y >= B - RL and x <= 8.4),
              line(3, X, 8.5, X)]
    g['u'] = [keep(rrect(LL, -10, LR, B, RL), lambda x, y: y >= X), line(LR, X, LR, B)]
    g['v'] = [line(LL, X, 6, B), line(6, B, LR, X)]
    g['w'] = [line(0.9, X, 3.4, B), line(3.4, B, 6, 11.6), line(6, 11.6, 8.6, B), line(8.6, B, 11.1, X)]
    g['x'] = [line(LL, X, LR, B), line(LR, X, LL, B)]
    g['y'] = [line(LL, X, 6.2, B - 0.2), line(LR, X, 4.6, D)]
    g['z'] = [line(LL, X, LR, X), line(LR, X, LL, B), line(LL, B, LR, B)]
    return g


def digits():
    g = {}
    g['0'] = [rrect(L, T, R, B, RC)]
    g['1'] = [line(6.3, T, 6.3, B), line(6.3, T, 3.8, 6.6)]
    g['2'] = [keep(rrect(L, T, R, 13, RC), lambda x, y: y <= 7.2 or (x >= 6 and y <= 9.5)),
              line(R, 9.3, L, B), line(L, B, R, B)]
    g['3'] = [keep(rrect(L, T, R - 0.4, MID, 3.0), lambda x, y: x >= 4.2),
              keep(rrect(L, MID, R, B, RC), lambda x, y: x >= 4.2),
              line(L, T, 4.4, T), line(L, B, 4.4, B)]
    g['4'] = [line(7.6, B, 7.6, T), line(7.6, T, L, 14), line(L, 14, R + 0.3, 14)]
    g['5'] = [line(R, T, L, T), line(L, T, L, 10.6), line(L, 10.6, 6, 10.6), line(L, B, 6, B),
              keep(rrect(L, 10.6, R, B, RC), lambda x, y: x >= 5.6)]
    g['6'] = [keep(rrect(L, T, R, B, RC), lambda x, y: not (x > 7 and 6.8 < y < 12)),
              rrect(L, 10.6, R, B, RC)]
    g['7'] = [line(L, T, R, T), line(R, T, 4.6, B)]
    g['8'] = [rrect(L + 0.4, T, R - 0.4, MID, 2.9), rrect(L, MID, R, B, RC)]
    g['9'] = [rrect(L, T, R, 12.1, RC),
              keep(rrect(L, T, R, B, RC), lambda x, y: not (x < 5 and 10.5 < y < 15.7))]
    return g


def punct():
    g = {}
    g[' '] = []
    g['!'] = [line(6, T, 6, 14), dot(6, B - 0.2)]
    g['"'] = [line(4.5, T, 4.5, 7.5), line(7.5, T, 7.5, 7.5)]
    g['#'] = [line(5, 6, 4, 17), line(8.5, 6, 7.5, 17), line(2.5, 9.5, 10, 9.5), line(2, 14, 9.5, 14)]
    g['$'] = digits_s() + [line(6, 2.3, 6, 20.3)]
    g['%'] = [rrect(2, T, 5.4, 9.2, 1.7), rrect(6.6, 13.3, 10, B, 1.7), line(R + 0.3, T, L - 0.3, B)]
    g['&'] = [rrect(3.4, T, 8, 10.6, 2.3), line(4.6, 10.2, R + 0.3, B),
              keep(rrect(L, 10.2, 8, B, RC), lambda x, y: not (x > 6.6 and y < 13.6)),
              line(7.2, 15.2, R, 11.8)]
    g["'"] = [line(6, T, 6, 7.5)]
    g['('] = [keep(rrect(5.2, T - 0.5, 14, B + 2.5, 3.6), lambda x, y: x <= 7.6)]
    g[')'] = [mirror(p) for p in g['(']]
    g['*'] = [line(6, T, 6, 11), line(3.2, 5.7, 8.8, 9.3), line(8.8, 5.7, 3.2, 9.3)]
    g['+'] = [line(6, 8.2, 6, 16.2), line(2.2, 12.2, 9.8, 12.2)]
    g[','] = [line(5.9, B - 0.4, 4.8, 21.6)]
    g['-'] = [line(3.5, 12.5, 8.5, 12.5)]
    g['.'] = [dot(6, B - 0.2)]
    g['/'] = [line(R, T, L, B + 1)]
    g[':'] = [dot(6, X + 1.4), dot(6, B - 0.2)]
    g[';'] = [dot(6, X + 1.4), line(5.9, B - 0.4, 4.8, 21.6)]
    g['<'] = [line(R, 6.5, L, 12.2), line(L, 12.2, R, 17.9)]
    g['='] = [line(3, 10, 9, 10), line(3, 14.8, 9, 14.8)]
    g['>'] = [mirror(p) for p in g['<']]
    g['?'] = [keep(rrect(L, T, R, 11.6, 3.0), lambda x, y: not (x < 5.2 and y > 7.2)),
              line(6, 11.6, 6, 14), dot(6, B - 0.2)]
    g['@'] = [keep(rrect(1.4, 4.8, 10.6, B, 3.2), lambda x, y: not (x > 8.2 and y > 14.6)),
              rrect(4.4, 8.8, 7.9, 14.6, 1.6), line(7.9, 8.8, 7.9, 14.6), line(7.9, 14.6, 10.6, 14.6)]
    g['['] = [line(8, T - 0.5, 5, T - 0.5), line(5, T - 0.5, 5, B + 2), line(5, B + 2, 8, B + 2)]
    g['\\'] = [line(L, T, R, B + 1)]
    g[']'] = [mirror(p) for p in g['[']]
    g['^'] = [line(3, 9, 6, T), line(6, T, 9, 9)]
    g['_'] = [line(1.5, D, 10.5, D)]
    g['`'] = [line(5, T, 7, 6.5)]
    g['{'] = [keep(rrect(5.6, T - 0.5, 10, 11.6, 1.6), lambda x, y: x <= 7.6),
              keep(rrect(5.6, 11.6, 10, B + 2, 1.6), lambda x, y: x <= 7.6), line(3.4, 11.6, 5.6, 11.6)]
    g['|'] = [line(6, T - 1, 6, D)]
    g['}'] = [mirror(p) for p in g['{']]
    g['~'] = [arc(4.5, 13.6, 2.2, 2.0, 180, 360), arc(8.9, 11.6, 2.2, 2.0, 180, 0)]
    return g


def digits_s():
    return [keep(rrect(L, T + 1, R, MID, 3.0), lambda x, y: not (x > 7 and y > 7.4)),
            keep(rrect(L, MID, R, B - 1, RC), lambda x, y: not (x < 5 and y < 14.6))]


# ---- icons: two-cell (24 x 24) or one-cell (12 x 24) canvases ------------------------------
# Each: (width in cells, [ink paths], [filled polygons], [cut paths] (drawn as class 1))

def poly_pts(pts):
    return [tuple(p) for p in pts]


def icons():
    ic = {}
    ic['PLAY'] = (2, [], [[(6, 4.5), (6, 19.5), (19.5, 12)]], [])
    ic['PAUSE'] = (2, [], [[(6.5, 5), (10.5, 5), (10.5, 19), (6.5, 19)],
                           [(13.5, 5), (17.5, 5), (17.5, 19), (13.5, 19)]], [])
    ic['STOP'] = (2, [], [[(5.5, 5), (18.5, 5), (18.5, 19), (5.5, 19)]], [])
    ic['FF'] = (2, [], [[(2.5, 6), (2.5, 18), (12, 12)], [(12, 6), (12, 18), (21.5, 12)]], [])
    ic['REW'] = (2, [], [[(21.5, 6), (21.5, 18), (12, 12)], [(12, 6), (12, 18), (2.5, 12)]], [])
    ic['NEXT'] = (2, [], [[(1.5, 6), (1.5, 18), (10, 12)], [(10, 6), (10, 18), (18.5, 12)],
                          [(19.5, 6), (22, 6), (22, 18), (19.5, 18)]], [])
    ic['PREV'] = (2, [], [[(22.5, 6), (22.5, 18), (14, 12)], [(14, 6), (14, 18), (5.5, 12)],
                          [(2, 6), (4.5, 6), (4.5, 18), (2, 18)]], [])
    # a quaver: an oval head, a stem, a flag
    ic['NOTE'] = (1, [line(7.6, 16.5, 7.6, 4.6), line(7.6, 4.6, 10.6, 8.6)],
                  [ellipse_poly(5.0, 16.8, 3.0, 2.3, -20)], [])
    # the film mark: a frame of film, sprocket holes top and bottom
    holes = []
    for hx in (4.0, 8.4, 12.8, 17.2):
        holes += [line(hx + 0.6, 7.6, hx + 2.0, 7.6), line(hx + 0.6, 16.4, hx + 2.0, 16.4)]
    ic['FILM'] = (2, [], [[(1.5, 5.5), (22.5, 5.5), (22.5, 18.5), (1.5, 18.5)]],
                  holes + [line(5.5, 10.6, 18.5, 10.6), line(5.5, 13.4, 18.5, 13.4),
                           line(5.5, 10.6, 5.5, 13.4), line(18.5, 10.6, 18.5, 13.4)])
    # the speed badge: a disc with its digit cut out
    for n in (1, 2, 3):
        cut = {1: [line(6.4, 7.6, 6.4, 16.6), line(6.4, 7.6, 4.6, 9.2)],
               2: [keep(rrect(3.8, 7.4, 8.4, 12.4, 2.1), lambda x, y: y <= 9.6 or (x >= 6.1 and y <= 10.8)),
                   line(8.4, 10.6, 3.8, 16.6), line(3.8, 16.6, 8.4, 16.6)],
               3: [keep(rrect(3.8, 7.4, 8.1, 12.0, 2.0), lambda x, y: x >= 4.9),
                   keep(rrect(3.8, 12.0, 8.4, 16.6, 2.1), lambda x, y: x >= 4.9),
                   line(3.8, 7.4, 5.1, 7.4), line(3.8, 16.6, 5.1, 16.6)]}[n]
        ic['BADGE%d' % n] = (1, [], [ellipse_poly(6.1, 12.1, 5.9, 7.3, 0)], cut)
    ic['TOFU'] = (1, [rrect(2.8, T + 0.5, 9.2, B, 1.2)], [], [])
    # P7 (docs/subtitles.md §7, S3): the subtitle tag's speech balloon -- an outline, the tail
    # below-left (the maintainer chose it over a filled one with dots cut out, 2026-09-30;
    # .sim/p7_mockups)
    ic['BALLOON'] = (2, [keep(rrect(2.5, 4.5, 21.5, 15.5, 4.2), lambda x, y: not (y > 14.0 and 5.5 < x < 11.5)),
                           line(6.0, 15.5, 5.0, 20.5), line(5.0, 20.5, 11.0, 15.5)], [], [])
    ic['ELLIPSIS'] = (1, [dot(2.4, B - 0.2), dot(6, B - 0.2), dot(9.6, B - 0.2)], [], [])
    # P6c (Go To, docs/p6c.md §2.1): the editor's arrows, small filled triangles. UP sits low in
    # its cell (the message row, just above the box it steps); DOWN sits high in its cell (the
    # icon row, just below the box), clear of the progress bar 10 lines into that row
    ic['UP'] = (1, [], [[(2.0, 23.0), (10.0, 23.0), (6.0, 17.0)]], [])
    ic['DOWN'] = (1, [], [[(2.0, 0.5), (10.0, 0.5), (6.0, 6.5)]], [])
    # ... and over a two-digit field (minutes, seconds, a two-digit chapter): centred on the pair
    ic['UP2'] = (2, [], [[(8.0, 23.0), (16.0, 23.0), (12.0, 17.0)]], [])
    ic['DOWN2'] = (2, [], [[(8.0, 0.5), (16.0, 0.5), (12.0, 6.5)]], [])
    return ic


def ellipse_poly(cx, cy, rx, ry, rot):
    a = np.radians(np.linspace(0, 360, 96, endpoint=False))
    c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    x, y = rx * np.cos(a), ry * np.sin(a)
    return [(cx + c * xi - s * yi, cy + s * xi + c * yi) for xi, yi in zip(x, y)]


ICON_ORDER = ['PLAY', 'PAUSE', 'STOP', 'FF', 'REW', 'NEXT', 'PREV', 'NOTE', 'FILM',
              'BADGE1', 'BADGE2', 'BADGE3', 'TOFU', 'ELLIPSIS',
              'BALLOON',                     # P7: the subtitle tag
              'UP', 'DOWN', 'UP2', 'DOWN2']  # P6c: Go To's arrows


def icon_index():
    """name -> first glyph index (the RTL's G_* localparams and the layout's)."""
    idx, g = {}, 95
    ic = icons()
    for n in ICON_ORDER:
        idx[n] = g
        g += ic[n][0]
    assert g <= NGLYPH
    return idx


# ---- rasterising ----------------------------------------------------------------------------

def _stamp(cov, paths, r):
    """Mark every supersample within r (raster px) of any path point."""
    h, w = cov.shape
    rs = r * SS
    for p in paths:
        for x, y in p:
            cx, cy = x * XS * SS, y * SS
            x0, x1 = max(0, int(cx - rs - 1)), min(w, int(cx + rs + 2))
            y0, y1 = max(0, int(cy - rs - 1)), min(h, int(cy + rs + 2))
            if x0 >= x1 or y0 >= y1:
                continue
            yy, xx = np.mgrid[y0:y1, x0:x1]
            m = (xx + 0.5 - cx) ** 2 + (yy + 0.5 - cy) ** 2 <= rs * rs
            cov[y0:y1, x0:x1] |= m


def _fill(cov, polys):
    from PIL import Image, ImageDraw
    h, w = cov.shape
    im = Image.new("1", (w, h), 0)
    d = ImageDraw.Draw(im)
    for pg in polys:
        d.polygon([(x * XS * SS, y * SS) for x, y in pg], fill=1)
    cov |= np.array(im, dtype=bool)


def _coverage(bits, wpx):
    return bits.reshape(CH, SS, wpx, SS).mean(axis=(1, 3))


def classes(ink_paths, polys=(), cut_paths=(), wcells=1, pen=PEN):
    """-> (CH, wcells*CW) array of classes 0-3 (module docstring)."""
    wpx = wcells * CW
    bits = np.zeros((CH * SS, wpx * SS), dtype=bool)
    _stamp(bits, ink_paths, pen)
    if polys:
        _fill(bits, polys)
        # round the polygons' corners a little: the same pen along their edges
        _stamp(bits, [np.concatenate([line(*a, *b) for a, b in zip(pg, pg[1:] + pg[:1])])
                      for pg in polys], 0.7)
    cov = _coverage(bits, wpx)
    cls = np.zeros((CH, wpx), dtype=np.uint8)
    cls[cov >= EDGE_LO] = 3
    cls[cov >= INK_LO] = 2
    if cut_paths:
        cb = np.zeros_like(bits)
        _stamp(cb, cut_paths, 0.85)
        cc = _coverage(cb, wpx)
        cls[(cc >= 0.45) & (cls != 0)] = 1
    # the drop shadow: (+1, +1) from ink or edge, where nothing is drawn
    sh = np.zeros_like(cls, dtype=bool)
    sh[1:, 1:] = (cls[:-1, :-1] == 2) | (cls[:-1, :-1] == 3)
    cls[(cls == 0) & sh] = 1
    return cls


def build():
    """-> list of NGLYPH (CH, CW) class arrays."""
    g = {}
    for d in (upper(), lower(), digits(), punct()):
        g.update(d)
    glyphs = [np.zeros((CH, CW), dtype=np.uint8) for _ in range(NGLYPH)]
    for code in range(32, 127):
        ch = chr(code)
        assert ch in g, "no glyph for %r" % ch
        glyphs[code - 32] = classes(g[ch], pen=THIN if ch in "MWmw" else PEN)
    ic = icons()
    for name, first in icon_index().items():
        w, paths, polys, cut = ic[name]
        c = classes(paths, polys, cut, w)
        for k in range(w):
            glyphs[first + k] = c[:, k * CW:(k + 1) * CW]
    return glyphs


def mem_words(glyphs):
    words = []
    for gl in glyphs:
        for row in gl:
            v = 0
            for px in row:                  # leftmost pixel -> the MSB pair
                v = (v << 2) | int(px)
            words.append(v)
    return words


def preview(glyphs, path, scale=4):
    from PIL import Image
    pal = np.array([[40, 40, 48], [0, 0, 0], [255, 255, 255], [150, 150, 170]], dtype=np.uint8)
    cols = 16
    rows = (NGLYPH + cols - 1) // cols
    sheet = np.full((rows * (CH + 2), cols * (CW + 2), 3), 90, dtype=np.uint8)
    for i, gl in enumerate(glyphs):
        r, c = divmod(i, cols)
        sheet[r * (CH + 2):r * (CH + 2) + CH, c * (CW + 2):c * (CW + 2) + CW] = pal[gl]
    im = Image.fromarray(sheet).resize((sheet.shape[1] * scale, sheet.shape[0] * scale), Image.NEAREST)
    im.save(path)


def main(argv=None):
    glyphs = build()
    words = mem_words(glyphs)
    out = os.path.join(ROOT, "umd", "transport_font.mem")
    with open(out, "w") as f:
        f.write("// generated by tools/transport_font.py -- do not edit\n")
        for w in words:
            f.write("%05x\n" % w)
    os.makedirs(os.path.join(ROOT, ".sim"), exist_ok=True)
    pv = os.path.join(ROOT, ".sim", "transport_font_preview.png")
    preview(glyphs, pv)
    print("wrote %s (%d words) and %s" % (os.path.relpath(out, ROOT), len(words), os.path.relpath(pv, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
