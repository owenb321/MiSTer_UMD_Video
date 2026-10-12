#!/usr/bin/env python3
"""The transport HUD's model (tools/transport_layout.py, P6b5): the rules docs/transport_hud.md
S6 states, checked against hand-written expectations -- not against the model's own output --
because the model is the RTL's golden (bench/umd/run_transport_hud.sh). tools/tests/red_umd.py
proves each arm can fail.

    [title]  one cell a character, one placeholder a non-ASCII character, malformed UTF-8 a
             placeholder too and flagged, the ellipsis rule (66 cells fit, 67 do not, the
             reader's cut ends in one)
    [time]   h:mm:ss floored from 90 kHz ticks, three hour digits from 100 h, the '+' past
             what the digits hold
    [bar]    the fill's arithmetic (empty, full, over-full, half, a zero total)
    [layout] where the boxes, the message and the icons land
    [pixel]  the washes' arithmetic on a known pixel
    [gen]    the RTL's constants and string ROM are the model's (a stale .svh / .mem fails)
"""
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import numpy as np  # noqa: E402
import transport_layout as TL  # noqa: E402

FAILS = []


def check(arm, cond, what):
    if not cond:
        FAILS.append("[%s] %s" % (arm, what))


TOFU, ELL = TL.ICON["TOFU"], TL.ICON["ELLIPSIS"]


def glyphs(cells):
    return [g for g, _ in cells]


# ---- [title] --------------------------------------------------------------------------------
c, f = TL.title_cells("Spiderman 3™".encode(), False, 66)
check("title", glyphs(c) == [ord(ch) - 32 for ch in "Spiderman 3"] + [TOFU], "a 3-byte character is one placeholder")
check("title", f == {"placeholder": True, "malformed": False, "cut": False}, "Spiderman flags %r" % f)
c, f = TL.title_cells("トム&ジ".encode(), False, 66)
check("title", glyphs(c) == [TOFU, TOFU, ord("&") - 32, TOFU], "Japanese: one cell a code point")
c, f = TL.title_cells(b"ab\x80c", False, 66)
check("title", glyphs(c) == [65, 66, TOFU, 67] and f["malformed"], "a stray continuation byte: a flagged placeholder")
c, f = TL.title_cells(b"x\xe3\x83", False, 66)
check("title", glyphs(c) == [88, TOFU] and f["malformed"], "a sequence cut at the end: flagged")
c, f = TL.title_cells(b"\xe3A", False, 66)
check("title", glyphs(c) == [TOFU, 33] and f["malformed"], "a lead byte followed by ASCII: flagged, the ASCII kept")
c, f = TL.title_cells(b"\xc0\xaf", False, 66)
check("title", f["malformed"], "C0 is never UTF-8")
c, f = TL.title_cells(b"\x01", False, 66)
check("title", glyphs(c) == [TOFU] and f["placeholder"] and not f["malformed"], "a control byte: a placeholder, not malformed")
c, f = TL.title_cells(b"x" * 66, False, 66)
check("title", len(c) == 66 and ELL not in glyphs(c) and not f["cut"], "66 cells fit")
c, f = TL.title_cells(b"y" * 67, False, 66)
check("title", len(c) == 66 and glyphs(c)[65] == ELL and f["cut"], "67 cells: the 66th is the ellipsis")
c, f = TL.title_cells(b"Short", True, 66)
check("title", glyphs(c) == [ord(ch) - 32 for ch in "Short"] + [ELL] and f["cut"], "the reader's cut: an ellipsis after")

# ---- [time] ---------------------------------------------------------------------------------
T = TL.TICKS
check("time", TL.hms(0, 2) == "00:00:00", "zero")
check("time", TL.hms(3723 * T + T - 1, 2) == "01:02:03", "floored to the second")
check("time", TL.hms((99 * 3600 + 3599) * T, 2) == "99:59:59", "the last two-digit time")
check("time", TL.hms(100 * 3600 * T, 2) == "99:59:59+", "past two digits: saturated, marked")
check("time", TL.hms(100 * 3600 * T, 3) == "100:00:00", "three digits")
check("time", TL.hms(1000 * 3600 * T, 3) == "999:59:59+", "past three digits: saturated, marked")
check("time", TL.hms(1 << 45, 3) == "999:59:59+", "past 39 bits: saturated")
check("time", TL.hour_digits(100 * 3600 * T - 1) == 2 and TL.hour_digits(100 * 3600 * T) == 3, "100 h widens the hours")

# ---- [bar] ----------------------------------------------------------------------------------
check("bar", TL.bar_fill(0, 1000) == 0, "empty")
check("bar", TL.bar_fill(1000, 1000) == 438, "full")
check("bar", TL.bar_fill(5000, 1000) == 438, "elapsed past the total: full")
check("bar", TL.bar_fill(500, 1000) == 219, "half")
check("bar", TL.bar_fill(7, 0) == 0, "a zero total: empty")
check("bar", TL.bar_fill(1, 1000) == 0 and TL.bar_fill(3, 1000) == 0 and TL.bar_fill(1000 - 1, 1000) == 437,
      "floored: q = el * 512 // tot, then q * 438 >> 9")

# ---- [layout] -------------------------------------------------------------------------------
plane, boxes, rect, _ = TL.compose(TL.hud_state(state="ff", speed=3, popup="ff"))
# (a box is (slot, x0, x1, kind) since P6c0: kind 0 a plain box, 1 Go To's focused box, 2 its edited field)
check("layout", boxes == [(TL.S_CAP, 12 - 3, 12 + 9 * 10 - 1 + 3, 0)], "the 'Forward 3' box %r" % boxes)
check("layout", [g for g, _ in plane[TL.S_ICON][:3]] == [TL.ICON["FF"], TL.ICON["FF"] + 1, TL.ICON["BADGE3"]],
      "trick play: the icon and the badge")
plane, boxes, rect, _ = TL.compose(TL.hud_state(display=True, title=b"A", n_chapters=3, chapter=2,
                                                elapsed=61, total=3600))
tb = [b for b in boxes if b[2] == 12 + 69 * 10 - 1 + 3]
check("layout", len(tb) == 1 and tb[0][1] == 12 + (69 - 17) * 10 - 3, "the time box ends at x 704, 17 cells")
cb = [b for b in boxes if b not in tb]
check("layout", len(cb) == 1 and cb[0][1] == 12 + (69 - 17 - 2 - 9) * 10 - 3, "'Chapter 2' two cells left of the time")
check("layout", rect["bar"] == TL.bar_fill(61 * T + T // 2, 3600 * T) and rect["header"], "the bar and the header")
plane, boxes, rect, _ = TL.compose(TL.hud_state(message="no_chapter"))
m = "".join(chr(g + 32) for g, _ in plane[TL.S_MSG][19:49])
check("layout", m == "There is no chapter available." and rect["band"], "the message at column 19")
plane, _, _, _ = TL.compose(TL.hud_state(state="pause"))
check("layout", plane[TL.S_ICON][0][0] == TL.ICON["PAUSE"], "paused: the icon stays (Display off)")
plane, _, _, _ = TL.compose(TL.hud_state(state="play"))
check("layout", plane[TL.S_ICON][0][0] == 0, "playing, no pop-up: nothing")
plane, _, _, _ = TL.compose(TL.hud_state(popup="next", chapter=0))
check("layout", plane[TL.S_ICON][0][0] == TL.ICON["NEXT"] and plane[TL.S_CAP][0][0] == 0,
      "Next with no chapter: the icon, no caption")

# ---- [pixel] --------------------------------------------------------------------------------
bg = np.zeros((TL.H, TL.W, 3), dtype=np.uint8)
bg[:] = (200, 100, 40)
img, _ = TL.render(TL.hud_state(display=True, message="no_chapter", elapsed=1, total=2), bg)
check("pixel", tuple(img[0, 700]) == (100 + 40, 50 + 52, 20 + 84), "the header: under >> 1 + (40, 52, 84)")
# the message STRIP (analog.md S8: lines BAND_Y0 .. BAND_Y1 - 1, no longer a band to the bottom)
check("pixel", tuple(img[TL.BAND_Y0, 5]) == (50 + 40, 25 + 48, 10 + 76), "the strip: under >> 2 + (40, 48, 76)")
check("pixel", tuple(img[TL.BAND_Y1 - 1, 5]) == (50 + 40, 25 + 48, 10 + 76), "the strip's last line")
check("pixel", tuple(img[TL.BAND_Y0 - 1, 5]) == (200, 100, 40) and tuple(img[479, 5]) == (200, 100, 40),
      "the picture untouched above and below the strip")
check("pixel", tuple(img[446, 700]) == TL.BAR_REST, "the bar's rest")
check("pixel", tuple(img[445, 700]) == (100, 50, 20), "the rim over the picture: under >> 1")

# ---- [gen] ----------------------------------------------------------------------------------
root = os.path.dirname(os.path.dirname(HERE))
if os.path.isdir(os.path.join(root, "umd")):          # (red_umd.py runs a copy of tools/ alone)
    with tempfile.TemporaryDirectory() as d:
        TL.gen_rtl(d)
        for f in ("transport_hud.svh", "transport_str.mem"):
            check("gen", open(os.path.join(d, f)).read() == open(os.path.join(root, "umd", f)).read(),
                  "umd/%s is not what the model generates (run transport_layout.py --gen)" % f)

for f in FAILS:
    print("FAIL", f)
print("test_transport_layout: %s" % ("ALL GREEN" if not FAILS else "%d FAILED" % len(FAILS)))
sys.exit(1 if FAILS else 0)
