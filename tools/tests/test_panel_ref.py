#!/usr/bin/env python3
"""The control panel's behaviour model (tools/panel_ref.py, P6d) and its art (tools/panel_layout.py),
checked against hand-written expectations from docs/panel.md §1.1 (the PSP, measured) and §8 (the
decisions) -- not against the model's own output: the model is umd_panel.c's golden (C2).
tools/tests/red_umd.py proves each arm can fail.

    [open]   the panel button opens it on Display, in playback (any play state) and over a disc menu;
             not with no title; the grab and the level it publishes
    [walk]   <- / -> wrap within a row; ^ / v keep the column, clamped; dark items skipped
    [act]    x on each item sends its button's press (Play: player_ctl's PLAY); the panel stays
    [close]  Stop and UMD Menu close it; o and the panel button close it; a mount, a disc menu
             coming or going closes it
    [menu]   over a disc menu: UMD Menu, Display, Stop only; Stop is P9-6's quit
    [goto]   Go To hides it; it comes back after the jump's seek, at once after a cancel, after a
             timeout if the editor never opens; the Go To button while it is up
    [dark]   an item that goes dark under the cursor sends nothing
    [art]    the icons and the box: the integer halo and corners as specified; the generated
             main/support/umd/umd_panel_art.{c,h} current
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import panel_ref as R  # noqa: E402
import panel_layout as PL  # noqa: E402

FAILS = []


def check(arm, cond, what):
    if not cond:
        FAILS.append("[%s] %s" % (arm, what))


def bit(b):
    return 1 << b


def opened(**rd):
    p = R.Panel()
    p.read(R.Rd(**rd), 0)
    p.key(bit(R.B_PANEL))
    return p


def walk(p, *bits):
    for b in bits:
        p.key(bit(b))
    return p.sel


# ---- [open] ----
p = R.Panel()
p.read(R.Rd(state=0), 0)
check("open", p.levels()["grab"] == 0, "no title: the panel button not grabbed")
p.key(bit(R.B_PANEL))
check("open", not p.open, "no title: the panel does not open")
for st in (1, 2, 3):
    p = opened(state=st)
    check("open", p.open and p.sel == "display", "state %d: opens on Display" % st)
    check("open", p.levels() == dict(grab=0b0100_0000_0110_1111, show="ui_sub"),
          "state %d: grabs the D-pad, x, o and the panel button; shows by ui_sub" % st)
p = R.Panel()
p.read(R.Rd(state=1), 0)
check("open", p.levels() == dict(grab=bit(14), show=None), "closed: only the panel button grabbed")
p = opened(state=3, menu_up=True)
check("open", p.open and p.mode == "menu" and p.levels()["show"] == "frame",
      "over a disc menu: opens drawn into the engine's frame")
p = opened(state=0, menu_up=True)
check("open", p.open, "a disc menu over a stopped player (state idle): opens")

# ---- [walk] ----
p = opened()
check("walk", walk(p, R.B_RIGHT) == "menu", "-> from Display wraps to UMD Menu")
check("walk", walk(p, R.B_LEFT) == "display", "<- from UMD Menu wraps to Display")
check("walk", walk(p, R.B_DOWN) == "play", "v from Display (column 4) lands on Play (column 4)")
check("walk", walk(p, R.B_RIGHT, R.B_RIGHT) == "stop", "-> -> to Stop")
check("walk", walk(p, R.B_UP) == "display", "^ from Stop (column 6) clamps to Display (column 4)")
check("walk", walk(p, R.B_RIGHT, R.B_DOWN) == "prev", "v from UMD Menu (column 0) lands on Previous")
check("walk", walk(p, R.B_UP) == "menu", "^ back to UMD Menu")
p = opened(sub_any=False)
check("walk", walk(p, R.B_LEFT) == "audio", "<- from Display skips the dark Subtitles to Audio")
check("walk", walk(p, R.B_RIGHT) == "display", "-> from Audio skips the dark Subtitles")
p = opened(sub_any=False)
p.sel = "ff"
check("walk", walk(p, R.B_UP) == "audio",
      "^ from Fast Forward (column 3) onto the dark Subtitles: a tie between Audio and Display goes left")
p = opened(engine=False)
check("walk", walk(p, R.B_RIGHT) == "goto", "-> from Display wraps past a dark UMD Menu to Go To")
p = opened(engine=False)
walk(p, R.B_DOWN, R.B_LEFT, R.B_LEFT, R.B_LEFT, R.B_LEFT)         # Play -> ... -> Previous
check("walk", p.sel == "prev" and walk(p, R.B_UP) == "goto",
      "^ from Previous (column 0) with UMD Menu dark: the nearest available, Go To")

# A-B Repeat's row 3 (docs/ab_repeat.md AB8; the maintainer 2026-10-07: v / ^ to the adjacent row, wrapping)
p = opened()
check("walk", walk(p, R.B_DOWN, R.B_DOWN) == "clear", "v v from Display (column 4): row 3, clamped to Clear (column 1)")
p = opened()
walk(p, R.B_DOWN, R.B_DOWN)
check("walk", walk(p, R.B_DOWN) == "goto", "v from Clear (column 1) wraps to row 1's column 1: Go To")
p = opened()
check("walk", walk(p, R.B_UP) == "clear", "^ from Display wraps to row 3 (column 4 clamped: Clear)")
p = opened()
walk(p, R.B_UP)
check("walk", walk(p, R.B_UP) == "next", "^ from Clear (column 1) to row 2's column 1: Next Chapter")
check("walk", walk(p, R.B_LEFT) == "prev" and walk(p, R.B_DOWN) == "ab", "v from Previous (column 0): A-B Repeat")
check("walk", walk(p, R.B_LEFT) == "clear", "<- in row 3 wraps to Clear")

# ---- [act] ----
want = {"goto": ("press", bit(13)), "audio": ("press", bit(9)), "sub": ("press", bit(12)),
        "display": ("press", bit(10)), "prev": ("press", bit(7)), "next": ("press", bit(8)),
        "rew": ("press", bit(1)), "ff": ("press", bit(0)), "play": ("cmd", 3), "pause": ("cmd", 2),
        "ab": ("press", bit(15)), "clear": ("cmd", 0)}
for name, act in want.items():
    p = opened()
    p.sel = name
    out = p.key(bit(R.B_PAUSE))
    check("act", out == [act], "x on %s sends %r (got %r)" % (name, act, out))
    if name != "goto":
        check("act", p.open and not p.hidden, "x on %s: the panel stays (K5)" % name)

# ---- [close] ----
for name, act in (("stop", ("press", bit(6))), ("menu", ("menu",))):
    p = opened()
    p.sel = name
    out = p.key(bit(R.B_PAUSE))
    check("close", out == [act] and not p.open, "x on %s sends %r and closes it" % (name, act))
for b, what in ((R.B_STOP, "o"), (R.B_PANEL, "the panel button")):
    p = opened()
    out = p.key(bit(b))
    check("close", out == [] and not p.open, "%s closes it, sending nothing" % what)
p = opened()
p.read(R.Rd(state=0), 10)
check("close", not p.open, "a mount (the core idle) closes it")
p = opened()
p.read(R.Rd(state=1, menu_up=True), 10)
check("close", not p.open, "a disc menu coming up (UMD Menu, a title's end) closes it")
p = opened(state=1, menu_up=True)
p.read(R.Rd(state=1, menu_up=False), 10)
check("close", not p.open, "the disc menu leaving closes it")
p = opened()
p.read(R.Rd(state=2), 10)
p.read(R.Rd(state=3), 20)
check("close", p.open, "a play-state change does not close it")

# ---- [menu] ----
p = opened(menu_up=True)
check("menu", [n for r in PL.ROWS for n in r if p.available(n)] == ["menu", "display", "stop"],
      "over a disc menu only UMD Menu, Display, Stop are available")
check("menu", walk(p, R.B_DOWN) == "stop", "v from Display: Stop, the only one in row 2")
check("menu", walk(p, R.B_LEFT) == "stop", "<- in row 2: nothing else to land on")
check("menu", walk(p, R.B_DOWN) == "display" and walk(p, R.B_UP) == "stop",
      "v from Stop: row 3 all dark (A-B Repeat, Clear), on to row 1; ^ back")
check("menu", p.key(bit(R.B_PAUSE)) == [("quit",)] and not p.open, "x on Stop: P9-6's quit, closed")
p = opened(menu_up=True)
check("menu", p.key(bit(R.B_PAUSE)) == [("press", bit(10))] and p.open, "x on Display: its press; it stays")
p = opened(menu_up=True)
walk(p, R.B_RIGHT)
check("menu", p.sel == "menu" and p.key(bit(R.B_PAUSE)) == [("menu",)] and not p.open, "x on UMD Menu: onMenu, closed")
p = opened(menu_up=True, engine=False)
check("menu", walk(p, R.B_RIGHT) == "display", "no engine: UMD Menu dark too")

# ---- [goto] ----
def goto_open(t0=0):
    p = opened()
    p.sel = "goto"
    out = p.key(bit(R.B_PAUSE))
    return p, out


p, out = goto_open()
check("goto", out == [("press", bit(13))] and p.open and p.hidden, "x on Go To: its press; hidden")
check("goto", p.levels() == dict(grab=bit(14), show=None), "hidden: shows nothing, grabs only the panel button")
p.read(R.Rd(goto_open=True), 10)
p.read(R.Rd(goto_open=True), 500)
check("goto", p.hidden, "hidden while the editor is up (any time)")
p.read(R.Rd(goto_open=False, seeking=True), 510)
p.read(R.Rd(goto_open=False, seeking=True), 520)
p.read(R.Rd(goto_open=False, seeking=False), 530)
check("goto", p.hidden, "still hidden on the first quiet read after the seek")
p.read(R.Rd(goto_open=False, seeking=False), 540)
check("goto", not p.hidden and p.open and p.sel == "goto", "back after the seek, on Go To")
p, _ = goto_open()
p.read(R.Rd(goto_open=True), 10)
p.read(R.Rd(goto_open=False), 20)
p.read(R.Rd(goto_open=False), 30)
check("goto", not p.hidden, "a cancel: back at once (two reads)")
p, _ = goto_open()
p.read(R.Rd(), R.GOTO_OPEN_MS - 1)
check("goto", p.hidden, "the editor not yet open: still hidden")
p.read(R.Rd(), R.GOTO_OPEN_MS)
check("goto", not p.hidden, "the editor never opened: back after GOTO_OPEN_MS")
p = opened()
p.read(R.Rd(goto_open=True), 10)
check("goto", p.hidden, "the Go To button with the panel up: hidden")
p.read(R.Rd(), 20)
p.read(R.Rd(), 30)
check("goto", not p.hidden and p.sel == "goto", "... and back after it")
p, _ = goto_open()
p.read(R.Rd(goto_open=True), 10)
p.key(bit(R.B_PANEL))
check("goto", not p.open, "the panel button while hidden closes it")

# ---- [dark] ----
p = opened()
p.sel = "sub"
p.read(R.Rd(sub_any=False), 10)
check("dark", p.key(bit(R.B_PAUSE)) == [], "x on Subtitles gone dark: nothing")

# ---- [art] ----
import numpy as np  # noqa: E402
x0, y0, box = PL.box_rgba()
h, w = box.shape[:2]
check("art", tuple(box[h // 2, w // 2]) == PL.BOX_RGBA, "the box's inside is the HUD's box tint, whole")
check("art", tuple(box[0, 0]) == (0, 0, 0, 0), "the box's corner pixel is outside the rounding")
check("art", tuple(box[0, w // 2]) == PL.BOX_RGBA, "the box's top edge is whole")
check("art", tuple(box[h - 1, w - 1]) == (0, 0, 0, 0), "the opposite corner too")
check("art", 0 < box[3, 2, 3] < PL.BOX_RGBA[3] and 0 < box[0, 7, 3] < PL.BOX_RGBA[3],
      "the rounding's edge is partly covered: anti-aliased")
check("art", box[3, 2, 3] == box[2, 3, 3] and (box == box[::-1]).all() and (box == box[:, ::-1]).all(),
      "the four corners are one rounding: the box symmetric both ways")
check("art", tuple(box[h // 2, w // 2]) == tuple(box[h // 2 + 1, w // 2 + 1]), "the box is flat inside")
hal = PL.halo_rgba(PL.icon_cls("stop"))
check("art", hal[..., 3].max() == PL.HALO_A, "the halo peaks at HALO_A")
check("art", hal[0, 0, 3] == 0, "the halo fades to nothing at its canvas' edge")
check("art", (hal[..., :3] == hal[..., 3:4]).all(), "the halo is white, premultiplied")
c = PL.icon_cls("stop")
check("art", c[14, 17] == 2 and c[0, 0] == 0, "Stop: ink in the middle, clear at the corner")
check("art", PL.CAPTION["prev"] == "Previous Chapter", "full names (the maintainer, 2026-10-04)")
x0, y0, x1, y1 = PL.region()
# (A-B Repeat's row 3, 2026-10-07: 154 -> 208 tall, the box ends at line 298 -- clear of 480i's message strip, 306)
check("art", PL.box_geom() == (185, 90, 350, 208), "the box's place: inside title safe, clear of the HUD")
h_txt, c_txt = PL.gen_art()
for path, text in ((PL.ART_H, h_txt), (PL.ART_C, c_txt)):
    cur = open(path).read() if os.path.exists(path) else ""
    check("art", cur == text, "%s is current (run tools/panel_layout.py --gen)" % os.path.relpath(path, PL.ROOT))

if FAILS:
    for f in FAILS:
        print("FAIL", f)
    print("test_panel_ref: %d FAILED" % len(FAILS))
    sys.exit(1)
print("test_panel_ref: ALL GREEN")
