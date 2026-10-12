#!/usr/bin/env python3
"""panel_ref.py -- the control panel's behaviour (P6d, docs/panel.md §1.1, §3.3, §3.4): the golden that
umd_panel.c is benched against (bench/umd/run_panel.sh, stage C2).

Written from the PSP measurements and the maintainer's decisions (docs/panel.md §8, K1-K16), not from
the C. The look and the item order are panel_layout.py's (ROWS); everything here is what the panel
DOES: when it opens, where the cursor goes, what a confirm sends to the core, when it closes, when it
hides for Go To and comes back.

THE INPUTS, one call each (the UMD Main's poll thread sees them in this order):
    read(rd, now)   a HOST_RD, decoded (`Rd`) at `now` ms
    key(mask)       a grabbed button's press (umd_host's KEY event): joystick bit order
THE OUTPUTS, the list each call returns (to the runner, in order):
    ("press", mask)  a HOST_WR press record (F1): the core acts as if those buttons were pressed
    ("cmd", code)    a HOST_WR player command (Play: no button maps to player_ctl's PLAY)
    ("menu",)        the engine's onMenu (UMD Menu: the host's own action)
    ("quit",)        P9-6's quit (Stop over a disc menu: stop, the file browser)
and the state the runner publishes (`levels()`): the grab mask, and how the panel shows -- "ui_sub" (in
playback: the panel's own planes, the subtitles kept running, docs/panel.md §2), "frame" (over a disc
menu: drawn into the engine's frame, §3.4) or None.
"""
import os
import sys
from dataclasses import dataclass

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from panel_layout import ROWS, START, IN_MENU  # noqa: E402

# joystick bits: the framework's D-pad, then emu's J1 list (CONF_STR order, B1 = bit 4)
B_RIGHT, B_LEFT, B_DOWN, B_UP = 0, 1, 2, 3
B_PLAYPAUSE, B_PAUSE, B_STOP, B_PREV, B_NEXT, B_AUDIO, B_DISPLAY, B_MENU, B_SUB, B_GOTO, B_PANEL = range(4, 15)
B_AB = 15                                                  # A-B Repeat: no J1 button (the keyboard's B), emu's bit 15
DPAD = (1 << B_RIGHT) | (1 << B_LEFT) | (1 << B_DOWN) | (1 << B_UP)
GRAB_CLOSED = 1 << B_PANEL                                 # the panel button, so it opens the panel
GRAB_OPEN = DPAD | (1 << B_PAUSE) | (1 << B_STOP) | (1 << B_PANEL)   # K6: x, o, the panel, the walk
PC_PLAY = 3                                                # player_ctl's PLAY
PC_PAUSE = 2                                               # player_ctl's PAUSE: the item (x, Select, toggles since 2026-10-07)
PC_AB_CLEAR = 0                                            # the host's code 0: A-B Repeat's CLEAR (ab_ctl's, docs/ab_repeat.md)

# what x on an item sends (docs/panel.md §3.2 F1: each item IS its button)
ACTION = {
    "menu": ("menu",), "goto": ("press", 1 << B_GOTO), "audio": ("press", 1 << B_AUDIO),
    "sub": ("press", 1 << B_SUB), "display": ("press", 1 << B_DISPLAY),
    "prev": ("press", 1 << B_PREV), "next": ("press", 1 << B_NEXT),
    "rew": ("press", 1 << B_LEFT), "ff": ("press", 1 << B_RIGHT),
    "play": ("cmd", PC_PLAY), "pause": ("cmd", PC_PAUSE), "stop": ("press", 1 << B_STOP),
    # A-B Repeat (docs/ab_repeat.md AB8): its press (bit 15); Clear the host's code 0 (in state A a press would set B)
    "ab": ("press", 1 << B_AB), "clear": ("cmd", PC_AB_CLEAR),
}
ACTION_IN_MENU = {"menu": ("menu",), "display": ("press", 1 << B_DISPLAY), "stop": ("quit",)}
CLOSES = {"menu", "stop"}                                  # K5, measured: only these close it

# Go To (K5 / K14): the panel hides while the editor is up and comes back once it has closed and no
# seek is in flight, on RETURN_READS reads in a row (a jump's seek starts within cycles of the editor
# closing; two reads cannot both fall in that gap). If the editor never opens (refused), it comes back
# after GOTO_OPEN_MS.
RETURN_READS = 2
GOTO_OPEN_MS = 250


@dataclass
class Rd:
    state: int = 1          # player_ctl: 0 idle 1 play 2 pause 3 stop (HOST_RD `play` [15:13])
    seeking: bool = False
    goto_open: bool = False  # F2: Go To's editor is up
    sub_any: bool = True     # F2: the title has a subtitle track
    menu_up: bool = False    # the runner: a disc menu's page is up (the engine holds ui)
    engine: bool = True      # the runner: the engine runs for this disc (it has an onMenu)


class Panel:
    def __init__(self):
        self.open = False
        self.hidden = False       # hidden for Go To
        self.mode = "play"        # "play" or "menu" (opened over a disc menu)
        self.sel = START
        self.rd = Rd(state=0)
        self.g_seen = False       # the editor seen open since the hide
        self.g_since = 0          # when the hide began (ms)
        self.quiet = 0            # reads in a row with the editor closed and no seek
        self.now = 0

    # ---- what is available ----
    def available(self, name):
        if self.mode == "menu":
            return name in IN_MENU and (name != "menu" or self.rd.engine)
        if name == "sub":
            return self.rd.sub_any
        if name == "menu":
            return self.rd.engine
        return True

    def _pos(self, name):
        for r, row in enumerate(ROWS):
            if name in row:
                return r, row.index(name)
        raise KeyError(name)

    # ---- the walk: the cursor skips what is dark (the maintainer, 2026-10-04) ----
    def _horiz(self, step):
        r, c = self._pos(self.sel)
        row = ROWS[r]
        for k in range(1, len(row)):
            cand = row[(c + step * k) % len(row)]       # wraps within the row
            if self.available(cand):
                self.sel = cand
                return

    def _vert(self, step):
        r, c0 = self._pos(self.sel)
        # the adjacent row, wrapping (A-B's row 3: the maintainer, 2026-10-07); a row with nothing available
        # (row 3 over a disc menu) is skipped, as <- / -> skip a dark item
        for k in range(1, len(ROWS)):
            row = ROWS[(r + step * k) % len(ROWS)]
            c = min(c0, len(row) - 1)                   # the column kept, clamped to a shorter row
            best = None
            for j, cand in enumerate(row):
                if self.available(cand):
                    d = abs(j - c)
                    if best is None or d < best[0]:     # the nearest available; a tie to the left
                        best = (d, cand)
            if best:
                self.sel = best[1]
                return

    # ---- the levels the runner publishes ----
    def levels(self):
        if not self.open:
            ok = self.rd.state != 0 or self.rd.menu_up
            return dict(grab=GRAB_CLOSED if ok else 0, show=None)
        if self.hidden:
            return dict(grab=1 << B_PANEL, show=None)  # the editor has the keys (gt_take); the panel button closes
        return dict(grab=GRAB_OPEN, show="frame" if self.mode == "menu" else "ui_sub")

    def _close(self):
        self.open = False
        self.hidden = False

    # ---- the inputs ----
    def read(self, rd, now):
        prev, self.rd, self.now = self.rd, rd, now
        if not self.open:
            return []
        # a mount (the core idle) or the engine taking or giving back the screen closes it
        if rd.state == 0 and not rd.menu_up or rd.menu_up != prev.menu_up:
            self._close()
            return []
        if not self.hidden and rd.goto_open:            # the Go To button while the panel is up
            self._hide()
        if self.hidden:
            if rd.goto_open:
                self.g_seen = True
                self.quiet = 0
            elif not self.g_seen and now - self.g_since >= GOTO_OPEN_MS:
                self.hidden = False                      # the editor never opened
            elif self.g_seen:
                self.quiet = self.quiet + 1 if not rd.seeking else 0
                if self.quiet >= RETURN_READS:
                    self.hidden = False
                    self.sel = "goto" if self.available("goto") else self.sel
        return []

    def _hide(self):
        self.hidden = True
        self.g_seen = False
        self.g_since = self.now
        self.quiet = 0

    def key(self, mask):
        out = []
        for b in range(16):                             # one press at a time, lowest bit first
            if mask >> b & 1:
                out += self._press(b)
        return out

    def _press(self, b):
        if not self.open:
            if b == B_PANEL and (self.rd.state != 0 or self.rd.menu_up):
                self.open = True
                self.hidden = False
                self.mode = "menu" if self.rd.menu_up else "play"
                self.sel = START                         # K8, measured: on Display at every open
            return []
        if b == B_PANEL or (b == B_STOP and not self.hidden):
            self._close()                                # K6: o and the panel button close it
            return []
        if self.hidden:
            return []
        if b == B_RIGHT:
            self._horiz(+1)
        elif b == B_LEFT:
            self._horiz(-1)
        elif b == B_DOWN:
            self._vert(+1)
        elif b == B_UP:
            self._vert(-1)
        elif b == B_PAUSE:                               # x: do the item
            if not self.available(self.sel):
                return []                                # (it went dark while the cursor was on it)
            act = (ACTION_IN_MENU if self.mode == "menu" else ACTION)[self.sel]
            if self.sel in CLOSES:
                self._close()
            elif self.sel == "goto":
                self._hide()
            return [act]
        return []
