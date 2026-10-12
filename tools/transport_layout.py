#!/usr/bin/env python3
"""transport_layout.py -- the transport HUD's layout and pixel model (P6b5).

docs/transport_hud.md S6 is the design; this file writes it down exactly once. It serves as:
  * the MOCKUPS the maintainer approves before any RTL (--mockups: every HUD state over a
    real frame, at the raster and at the displayed aspect, and a contact sheet), and
  * later the bench's GOLDEN (bench/umd/run_transport_hud.sh, pixel-exact): so every
    colour below is the fabric's arithmetic -- shifts, adds and constants on 8-bit
    channels, never a float alpha. What is approved on these pictures is what ships.

THE MODEL. A HUD state (hud_state()) -> the PLANE (4 slots x 128 cells of {glyph, colour}; 69 shown)
+ up to 4 BOX spans + the rectangles (the header wash, the message band, the bar) -> the
720 x 480 picture, per pixel:
    under  = the picture; the header wash or the message band over it; the bar (opaque,
             with a translucent rim); a box span
    out    = the cell's glyph class over `under` (transport_font.py: clear / shadow / ink /
             edge)
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import transport_font as TF  # noqa: E402

W, H = 720, 480
CW, CH = TF.CW, TF.CH
X0, COLS = 12, 69                   # the grid: columns 0-68, x 12-701
PLANE_COLS = 128
# the slots (the plane's rows) and their top lines
S_HEAD, S_MSG, S_CAP, S_ICON = 0, 1, 2, 3
SLOT_Y = [6, 360, 396, 436]              # (the message: one row above the caption since 480i, below)

# colours: {0 white, 1 accent, 2 grey, 3 dark}
C_WHITE, C_ACCENT, C_GREY, C_DARK = 0, 1, 2, 3
INK = [(240, 240, 240), (64, 156, 255), (150, 150, 160), (24, 24, 32)]

# the translucent fills: out = (under >> SHIFT) + K
BOX_SHIFT, BOX_K = 2, (12, 28, 72)       # text boxes: dark, blue-tinted
# P6c, Go To (docs/p6c.md §2.1): the box the ← / → focus is on, lighter; the field ▲ / ▼ edit, a
# light grey (the PSP's grey box with the edited pair lighter, transport_hud.md §3)
SEL_SHIFT, SEL_K = 2, (52, 68, 112)
EDIT_SHIFT, EDIT_K = 3, (112, 112, 124)
BOX_KINDS = [(BOX_SHIFT, BOX_K), (SEL_SHIFT, SEL_K), (EDIT_SHIFT, EDIT_K)]
MARK_H = 7                               # the Go To marker: a ▼ of 7 lines ending 2 above the bar
HDR_SHIFT, HDR_K = 1, (40, 52, 84)       # the header wash (Display)
BAND_SHIFT, BAND_K = 2, (40, 48, 76)     # the message band (>> 1 washed out over a bright picture)
BOX_PAD = 3                              # a box's reach past its first / last cell
HDR_Y1 = 36                              # the header wash: lines 0-35
# the message STRIP (the maintainer, 2026-10-01, analog.md S8: P6b5's band from the message to the
# bottom covered half a 480i screen once the HUD moved inside title safe): one text row just above
# the caption / chapter / time row, on a 36-line strip -- on both rasters
BAND_Y0 = 354                            # the message strip: lines 354-389
BAND_Y1 = 390                            # ... its end (exclusive)

# the progress bar: inner 5 lines, a 1-pixel translucent rim (under >> 1) around it
BAR_X0, BAR_X1 = 264, 701                # inner, inclusive
BAR_Y0, BAR_Y1 = 446, 450
BAR_W = BAR_X1 - BAR_X0 + 1
BAR_REST = (200, 204, 212)

# The 480i raster (docs/analog.md S8, the maintainer 2026-10-01: a CRT's overscan cut the HUD):
# the same HUD moved as a block inside the TITLE-SAFE area of 4:3 SD (80 %: x 72..647, y 48..431).
# The grid 57 columns from x 75 (75..644; a box's 3-pixel reach makes 72..647); the header 48
# lines down (its wash to line 83); the message, caption and icon slots and the bar 48 lines up;
# the bar the same 438 pixels wide (its fill arithmetic unchanged), its right end at the grid's.
# Every value below is the 480p one or its inset twin; set_layout() switches them all at once.
LAYOUT_P = dict(X0=X0, COLS=COLS, SLOT_Y=list(SLOT_Y), HDR_Y1=HDR_Y1, BAND_Y0=BAND_Y0, BAND_Y1=BAND_Y1,
                BAR_X0=BAR_X0, BAR_X1=BAR_X1, BAR_Y0=BAR_Y0, BAR_Y1=BAR_Y1)
SAFE = (72, 48, 647, 431)                # title safe, inclusive
LAYOUT_I = dict(X0=75, COLS=57, SLOT_Y=[54, 312, 348, 388], HDR_Y1=84, BAND_Y0=306, BAND_Y1=342,
                BAR_X0=644 - (BAR_W - 1), BAR_X1=644, BAR_Y0=398, BAR_Y1=402)

TICKS = 90000                            # the PTS clock
POPUP_S = 3                              # pop-ups (icon, caption, message) last 3 s: hard cut

LANG = {b"en": "English", b"fr": "French", b"es": "Spanish", b"it": "Italian",
        b"de": "German", b"ja": "Japanese", b"zh": "Chinese", b"ca": "Catalan"}
MESSAGES = {"no_chapter": "There is no chapter available.",
            # A7 (docs/hps_host.md §5, H7: the wording left to the implementation): the Subtitle
            # button without the UMD Main (no heartbeat: stock Main), or with one whose host
            # port PROTO is not the core's
            "no_host": "Subtitles need the UMD Main.",
            "old_host": "Update the UMD Main for subtitles.",
            # 2026-10-03 (area_plan.md A11, the diagnostic HUD removed): a disc the core stops on -- the
            # front end refused its stream (an unsupported coding, CLAUDE.md "refused loudly") or the
            # reader stopped on an error -- says so here; no event, a pulse from emu (`unplay`)
            "cannot_play": "This disc cannot be played.",
            # P6d (docs/panel.md F4): the Control Panel button with no UMD Main, or with one that did not
            # take it (a mismatched PROTO, or a UMD Main older than the panel); a pulse from emu (`pmsg`)
            "panel_no_host": "The control panel needs the UMD Main.",
            "panel_old_host": "Update the UMD Main for the control panel.",
            # P8 (docs/bare_streams.md): a bare .MPS / .PMF file has no EP map -- FF / REW, Go To and a
            # disc menu's jump are refused there (player_ctl's UNAVAIL event)
            "unavailable": "Not available for this file."}
# the message's event (player_ctl): {code, data}
MSG_EVENT = {"no_chapter": (4, 0), "no_host": (10, 0), "old_host": (10, 1), "unavailable": (11, 0)}

GLYPHS = None
ICON = TF.icon_index()
ICON_W = {n: v[0] for n, v in TF.icons().items()}   # cells an icon spans
G_SPACE = 0


def glyphs():
    global GLYPHS
    if GLYPHS is None:
        GLYPHS = TF.build()
    return GLYPHS


# ---- the HUD state --------------------------------------------------------------------------

def hud_state(**kw):
    """Everything the HUD draws from (the RTL's inputs, at event rate)."""
    st = dict(
        display=False,          # the Display overlay (a toggle)
        title=b"",              # PARAM.SFO TITLE bytes (UTF-8), up to 128 (title_mem)
        title_trunc=False,      # the reader kept only the first 128 bytes
        chapter=0, n_chapters=0,
        elapsed=None, total=None,   # seconds (the mockups' shorthand: -> ticks + 0.5 s)
        el_ticks=0, tot_ticks=0,    # 90 kHz: the shown picture's title time; the playlist's
        state="play",           # play / pause / stop / ff / rew  (player_ctl)
        speed=1,                # trick play 1-3
        popup=None,             # the event shown for POPUP_S: play / pause / stop / ff / rew /
                                # next / prev / track (None: none, or expired)
        track=1, lang=b"en",    # the audio track (1-based rank) and its 2 ASCII letters
        sub_on=False, sub_track=1, sub_lang=b"en",   # P7: the subtitles (popup "sub"), the same rules
        balloon="BALLOON",      # P7: the tag's icon
        message=None,           # a MESSAGES key, for POPUP_S
        hidden=False,           # the bench: `show` low (nothing drawn)
        disc_sub=False,         # P9 M4b: a SUB event from the DISC (SUB_SET, data[6]): drawn as nothing
        via_show=False,         # P6d follow-up: the track / sub tag reached by a SHOW of the current values
                                # (emu's th_show_*: the first Audio / Subtitle press), not a change event --
                                # the same picture; the bench drives the other path
        goto=None,              # P6c: Go To's editor -- dict(sel "chapter" / "time", edit None /
                                # "chapter" / "h" / "m" / "s", chapter n, t_ticks the target time,
                                # mark_ticks where the ▼ marker sits: the target's title time, None:
                                # hidden -- a chapter in another item, D15)
        ab=None,                # A-B Repeat (docs/ab_repeat.md §4): None off, "a" (A set, B blinking),
                                # "ab" (the loop)
        ab_blink=True,          # state "a": the B's 1 Hz blink phase (True: B drawn)
        ab_hold=False,          # state "ab": inside the 2 s B-solid hold after B was set
        ab_na=False,            # the "unavailable" message reached by ab_ctl's pulse (A-B on a bare file)
    )
    st.update(kw)
    if st["elapsed"] is not None:
        st["el_ticks"] = st["elapsed"] * TICKS + TICKS // 2
    if st["total"] is not None:
        st["tot_ticks"] = st["total"] * TICKS + TICKS // 2
    assert not (st["popup"] and st["message"]), "one event on screen at a time (S6.3)"
    return st


# ---- text -> cells ----------------------------------------------------------------------------

def ascii_cells(s, colour=C_WHITE):
    out = []
    for ch in s:
        c = ord(ch)
        out.append(((c - 32) if 32 <= c <= 126 else ICON["TOFU"], colour))
    return out


def title_cells(raw, trunc, room):
    """UTF-8 -> one cell a character: printable ASCII as itself, anything else ONE placeholder.
    A continuation byte adds nothing while its lead byte's sequence is open; a stray one, a
    sequence cut short (the 128-byte cut can make one) or a byte UTF-8 never uses is a
    placeholder too, and flagged `malformed` -- never silent. Past `room` cells, or when the
    reader truncated the title, the last cell is an ellipsis.
    Returns (cells, flags) -- flags: placeholder, malformed, cut."""
    cells, ph, bad, need = [], False, False, 0
    for b in raw:
        if 0x80 <= b <= 0xBF:
            if need:
                need -= 1                       # inside a sequence: its lead made the cell
                continue
            bad = True                          # a stray continuation byte
        elif need:
            bad = True                          # the open sequence was cut short
            need = 0
        if 32 <= b <= 126:
            cells.append((b - 32, C_WHITE))
            continue
        cells.append((ICON["TOFU"], C_WHITE))
        ph = True
        if 0xC2 <= b <= 0xDF:
            need = 1
        elif 0xE0 <= b <= 0xEF:
            need = 2
        elif 0xF0 <= b <= 0xF4:
            need = 3
        elif b >= 0x80:
            bad = True                          # C0 / C1 / F5-FF: never in UTF-8
    bad = bad or need > 0                       # the title ends inside a sequence
    cut = trunc or len(cells) > room
    if cut:
        cells = cells[:room - 1] + [(ICON["ELLIPSIS"], C_WHITE)]
    return cells, {"placeholder": ph, "malformed": bad, "cut": cut}


def sat39(t):
    """The RTL holds a time in 39 bits (1,696 h of 90 kHz ticks), saturating."""
    return min(t, (1 << 39) - 1)


def hms(ticks, hdig):
    """h:mm:ss (whole seconds, floored) with `hdig` hour digits; at or past 10^hdig hours,
    the largest value and a '+'. The RTL takes the digits from the ticks by repeated
    subtraction of each digit's weight (TIME_W), so it needs no divider."""
    t = sat39(ticks) // TICKS
    if t > 10 ** hdig * 3600 - 1:
        return "%0*d:59:59+" % (hdig, 10 ** hdig - 1)
    return "%0*d:%02d:%02d" % (hdig, t // 3600, t // 60 % 60, t % 60)


def hour_digits(tot_ticks):
    return 3 if sat39(tot_ticks) >= 100 * 3600 * TICKS else 2


def bar_fill(el_ticks, tot_ticks):
    """The bar's blue pixels: a 10-bit quotient (min(el, tot) * 512 / tot, one restoring
    division on the shared subtractor), then * 438 / 512 (a constant multiply)."""
    el, tot = sat39(el_ticks), sat39(tot_ticks)
    if tot == 0:
        return 0
    q = (min(el, tot) << 9) // tot
    return (q * BAR_W) >> 9


def icon_cells(name, colour=C_WHITE):
    first = ICON[name]
    w = ICON_W[name]
    return [(first + k, colour) for k in range(w)]


# ---- the state -> plane, boxes, rectangles ----------------------------------------------------

def compose(st):
    plane = [[(G_SPACE, C_WHITE)] * PLANE_COLS for _ in range(4)]
    boxes = []                         # (slot, x0, x1) pixel extents, inclusive
    flags = {}

    def put(slot, col, cells):
        for k, c in enumerate(cells):
            if 0 <= col + k < COLS:
                plane[slot][col + k] = c

    def box(slot, col, n, kind=0):
        boxes.append((slot, X0 + col * CW - BOX_PAD, X0 + (col + n) * CW - 1 + BOX_PAD, kind))

    state, popup = st["state"], st["popup"]

    # the state icon, bottom-left: always with Display; without it, while paused, stopped or
    # in trick play (a mode the picture alone does not tell), else only as a pop-up
    icon = None
    if popup in ("next", "prev"):
        icon = icon_cells("NEXT" if popup == "next" else "PREV")
    elif st["display"] or state in ("pause", "stop", "ff", "rew") or popup is not None:
        if state in ("ff", "rew"):
            icon = icon_cells("FF" if state == "ff" else "REW") + icon_cells("BADGE%d" % st["speed"])
        else:
            icon = icon_cells({"play": "PLAY", "pause": "PAUSE", "stop": "STOP"}[state])
    # A-B Repeat (docs/ab_repeat.md §4, the PSP): with A set the icon and `A-B` stay up, the B blinking
    # at 1 Hz; at B the B is solid for 2 s, then both go while it loops -- unless the icon is up for its
    # own reason (Display, paused, ...), when the tag stays beside it. One empty cell between, no box.
    ab = st["ab"]
    ab_up = ab == "a" or (ab == "ab" and (st["ab_hold"] or icon is not None))
    if ab_up and icon is None:
        icon = icon_cells({"play": "PLAY", "pause": "PAUSE", "stop": "STOP"}.get(state, "PLAY"))
    if icon:
        put(S_ICON, 0, icon)
    if ab_up:
        put(S_ICON, len(icon) + 1, ascii_cells("A-" + ("B" if ab == "ab" or st["ab_blink"] else " ")))

    # the caption above it, boxed (pop-ups only)
    cap = None
    if popup in ("ff", "rew"):
        cap = ascii_cells("%s %d" % ("Forward" if popup == "ff" else "Reverse", st["speed"]))
    elif popup in ("next", "prev") and st["chapter"]:
        cap = ascii_cells("Chapter %d" % st["chapter"])
    elif popup == "track":
        name = LANG.get(st["lang"])
        cap = icon_cells("NOTE") + ascii_cells(" %d " % st["track"]) + (
            ascii_cells(name) if name else ascii_cells(st["lang"].decode("latin-1")))
    elif popup == "sub":                   # P7: "(balloon) 1 English", "(balloon) Off"
        if st["sub_on"]:
            name = LANG.get(st["sub_lang"])
            cap = icon_cells(st["balloon"]) + ascii_cells(" %d " % st["sub_track"]) + (
                ascii_cells(name) if name else ascii_cells(st["sub_lang"].decode("latin-1")))
        else:
            cap = icon_cells(st["balloon"]) + ascii_cells(" Off")
    if cap and not st["goto"]:              # (P6c: the caption row is Go To's while it is open)
        put(S_CAP, 0, cap)
        box(S_CAP, 0, len(cap))

    rect = {"header": False, "band": False, "bar": None, "mark": None}
    gt = st["goto"]
    if gt:
        # GO TO: the Display layout, its time row the editor -- `Chapter n` (a title with chapters),
        # then the TARGET time over the total; the box the focus is on lighter, the field being
        # edited a light grey with ▲ above it (the message row) and ▼ below (the icon row, above
        # the bar); a blue ▼ above the bar at the target
        rect["header"] = True
        put(S_HEAD, 0, icon_cells("FILM"))
        tc, flags = title_cells(st["title"], st["title_trunc"], COLS - 3)
        put(S_HEAD, 3, tc)
        hdig = hour_digits(st["tot_ticks"])
        tg, to = hms(gt["t_ticks"], hdig), hms(st["tot_ticks"], hdig)
        tcells = ascii_cells(tg) + ascii_cells("/" + to)
        tcol = COLS - len(tcells)
        put(S_CAP, tcol, tcells)
        box(S_CAP, tcol, len(tcells), 1 if gt["sel"] == "time" else 0)
        field = None                         # (first column, cells) of the field being edited
        if gt["edit"] in ("h", "m", "s"):
            k = {"h": 0, "m": 1, "s": 2}[gt["edit"]]
            field = (tcol + [0, hdig + 1, hdig + 4][k], hdig if k == 0 else 2)
        if st["n_chapters"]:
            cc = ascii_cells("Chapter %d" % gt["chapter"])
            ccol = tcol - 2 - len(cc)
            put(S_CAP, ccol, cc)
            box(S_CAP, ccol, len(cc), 1 if gt["sel"] == "chapter" else 0)
            if gt["edit"] == "chapter":
                nd = len(str(gt["chapter"]))
                field = (ccol + len(cc) - nd, nd)
        if field:
            fc, fn = field
            box(S_CAP, fc, fn, 2)
            up, dn = ("UP2", "DOWN2") if fn % 2 == 0 else ("UP", "DOWN")
            ac = fc + (fn - 2) // 2 if fn % 2 == 0 else fc + fn // 2
            put(S_MSG, ac, icon_cells(up))
            put(S_ICON, ac, icon_cells(dn))
        rect["bar"] = bar_fill(st["el_ticks"], st["tot_ticks"])
        if gt["mark_ticks"] is not None:
            rect["mark"] = BAR_X0 + bar_fill(gt["mark_ticks"], st["tot_ticks"])
    elif st["display"]:
        rect["header"] = True
        put(S_HEAD, 0, icon_cells("FILM"))
        tc, flags = title_cells(st["title"], st["title_trunc"], COLS - 3)
        put(S_HEAD, 3, tc)
        # the time, right-aligned; the chapter box to its left
        hdig = hour_digits(st["tot_ticks"])
        el, to = hms(st["el_ticks"], hdig), hms(st["tot_ticks"], hdig)
        tcells = ascii_cells(el, C_ACCENT) + ascii_cells("/" + to)
        tcol = COLS - len(tcells)
        put(S_CAP, tcol, tcells)
        box(S_CAP, tcol, len(tcells))
        if st["n_chapters"] and st["chapter"]:
            cc = ascii_cells("Chapter %d" % st["chapter"])
            ccol = tcol - 2 - len(cc)
            put(S_CAP, ccol, cc)
            box(S_CAP, ccol, len(cc))
        rect["bar"] = bar_fill(st["el_ticks"], st["tot_ticks"])
    if st["message"]:
        rect["band"] = True
        m = ascii_cells(MESSAGES[st["message"]])
        put(S_MSG, (COLS - len(m)) // 2, m)
    return plane, boxes, rect, flags


# ---- the pixels (the fabric's arithmetic) -------------------------------------------------------

def _tint(u, shift, k):
    return (u >> shift) + np.array(k, dtype=np.int32)


def render(st, bg):
    """bg: (480, 720, 3) uint8 -> (480, 720, 3) uint8."""
    plane, boxes, rect, flags = compose(st)
    u = bg.astype(np.int32).copy()
    if rect["header"]:
        u[:HDR_Y1] = _tint(u[:HDR_Y1], HDR_SHIFT, HDR_K)
    if rect["band"]:
        u[BAND_Y0:BAND_Y1] = _tint(u[BAND_Y0:BAND_Y1], BAND_SHIFT, BAND_K)
    if rect["bar"] is not None:
        rim = u[BAR_Y0 - 1:BAR_Y1 + 2, BAR_X0 - 1:BAR_X1 + 2]
        rim[:] = rim >> 1
        u[BAR_Y0:BAR_Y1 + 1, BAR_X0:BAR_X1 + 1] = BAR_REST
        if rect["bar"]:
            u[BAR_Y0:BAR_Y1 + 1, BAR_X0:BAR_X0 + rect["bar"]] = INK[C_ACCENT]
    # the boxes: per row the strongest kind wins (a field's grey over its box), tinted from the layer below
    for slot in range(4):
        kmap = np.full(W, -1)
        for bs, x0, x1, kind in boxes:
            if bs == slot:
                kmap[x0:x1 + 1] = np.maximum(kmap[x0:x1 + 1], kind)
        y0 = SLOT_Y[slot]
        for kind, (sh, k) in enumerate(BOX_KINDS):
            cols = kmap == kind
            if cols.any():
                seg = u[y0:y0 + CH]
                seg[:, cols] = _tint(seg[:, cols], sh, k)
    if rect.get("mark") is not None:          # the Go To marker: a ▼ ending 2 lines above the bar
        for r in range(MARK_H):
            y = BAR_Y0 - 2 - MARK_H + r
            hw = (MARK_H - 1 - r) // 2 + 0
            u[y, rect["mark"] - hw:rect["mark"] + hw + 1] = INK[C_ACCENT]
    g = glyphs()
    out = u.copy()
    for slot in range(4):
        y0 = SLOT_Y[slot]
        for col in range(COLS):
            gi, ci = plane[slot][col]
            if gi == G_SPACE:
                continue
            cls = g[gi]
            x0 = X0 + col * CW
            cu = u[y0:y0 + CH, x0:x0 + CW]
            co = out[y0:y0 + CH, x0:x0 + CW]
            ink = np.array(INK[ci], dtype=np.int32)
            co[cls == 1] = cu[cls == 1] >> 2
            co[cls == 2] = ink
            co[cls == 3] = (ink >> 1) + (cu[cls == 3] >> 1)
    return np.clip(out, 0, 255).astype(np.uint8), flags


# ---- the RTL's constants and string ROM (umd/transport_hud.sv includes / loads them) --------------

G_END = 127                                  # the string ROM's terminator (no glyph)
LANG_ORDER = [b"en", b"fr", b"es", b"it", b"de", b"ja", b"zh", b"ca"]
STR_FORWARD, STR_REVERSE, STR_CHAPTER, STR_MSG, STR_LANG = 0, 8, 16, 24, 64
STR_N = 512                                  # the string ROM's entries (P6d: 256 -> 512, the panel's messages)
# the messages, by the RTL's message id (0: STR_MSG; 1-3: past the languages, 40 cells each; 4-5, P6d:
# past 256, 48 cells each; 6, P8: after them)
MSG_IDS = ["no_chapter", "no_host", "old_host", "cannot_play", "panel_no_host", "panel_old_host",
           "unavailable"]
MSG_STR = [STR_MSG, 128, 168, 208, 256, 304, 352]
MSG_ROOM = [40, 40, 40, 40, 48, 48, 48]
MSG_COLS = [(COLS - len(MESSAGES[m])) // 2 for m in MSG_IDS]
MSG_COLS_I = [(LAYOUT_I["COLS"] - len(MESSAGES[m])) // 2 for m in MSG_IDS]


def set_layout(il):
    """switch the module's layout constants to the 480i (inset) set or back"""
    g = globals()
    for k, v in (LAYOUT_I if il else LAYOUT_P).items():
        g[k] = list(v) if isinstance(v, list) else v
    g["MSG_COLS"] = list(MSG_COLS_I if il else [(LAYOUT_P["COLS"] - len(MESSAGES[m])) // 2 for m in MSG_IDS])
    assert BAR_X1 - BAR_X0 + 1 == BAR_W
# a time digit's weight in ticks: 100 h, 10 h, 1 h, 10 min, 1 min, 10 s, 1 s
TIME_W = [360000 * TICKS, 36000 * TICKS, 3600 * TICKS, 600 * TICKS, 60 * TICKS, 10 * TICKS, TICKS]


def string_rom():
    rom = [G_END] * STR_N

    def put(at, text, room):
        assert len(text) <= room
        for k, ch in enumerate(text):
            rom[at + k] = ord(ch) - 32
    put(STR_FORWARD, "Forward ", 8)
    put(STR_REVERSE, "Reverse ", 8)
    put(STR_CHAPTER, "Chapter ", 8)
    for k, m in enumerate(MSG_IDS):
        put(MSG_STR[k], MESSAGES[m], MSG_ROOM[k])
    for k, code in enumerate(LANG_ORDER):
        put(STR_LANG + 8 * k, LANG[code], 8)
    return rom


def gen_rtl(outdir=None):
    outdir = outdir or os.path.join(ROOT, "umd")
    rom = string_rom()
    with open(os.path.join(outdir, "transport_str.mem"), "w") as f:
        f.write("// generated by tools/transport_layout.py --gen -- do not edit\n")
        for g in rom:
            f.write("%02x\n" % g)
    L = ["// umd/transport_hud.svh -- generated by tools/transport_layout.py --gen: do not edit.",
         "// The transport HUD's layout constants (docs/transport_hud.md S6), written down once in",
         "// the model; umd/transport_hud.sv includes this inside its module body.", ""]

    def lp(name, val, width=None, comment=""):
        v = ("%d'd%d" % (width, val)) if width else str(val)
        L.append("localparam %-12s = %s;%s" % (name, v, ("   // " + comment) if comment else ""))
    # the geometry twice: the 480p set and its 480i (title-safe) twin, suffix _I (docs/analog.md S8)
    for suf, lay in (("", LAYOUT_P), ("_I", LAYOUT_I)):
        lp("X0" + suf, lay["X0"], 11); lp("COLS" + suf, lay["COLS"], 7)
        for k, y in enumerate(lay["SLOT_Y"]):
            lp("SLOT_Y%d%s" % (k, suf), y, 10, ["header", "message", "caption", "icon"][k])
        lp("HDR_Y1" + suf, lay["HDR_Y1"], 10, "the header wash: lines 0 .. HDR_Y1-1")
        lp("BAND_Y0" + suf, lay["BAND_Y0"], 10, "the message strip: lines BAND_Y0 .. BAND_Y1-1")
        lp("BAND_Y1" + suf, lay["BAND_Y1"], 10)
        lp("BAR_X0" + suf, lay["BAR_X0"], 11); lp("BAR_X1" + suf, lay["BAR_X1"], 11)
        lp("BAR_Y0" + suf, lay["BAR_Y0"], 10); lp("BAR_Y1" + suf, lay["BAR_Y1"], 10)
    lp("CW", CW, 4); lp("CH", CH, 5)
    lp("BAR_W", BAR_W, 9); lp("BOX_PAD", BOX_PAD, 4)
    lp("BOX_SHIFT", BOX_SHIFT); lp("HDR_SHIFT", HDR_SHIFT); lp("BAND_SHIFT", BAND_SHIFT)
    lp("SEL_SHIFT", SEL_SHIFT); lp("EDIT_SHIFT", EDIT_SHIFT); lp("MARK_H", MARK_H, 10, "P6c: Go To's marker")
    for nm, rgb in (("BOX_K", BOX_K), ("SEL_K", SEL_K), ("EDIT_K", EDIT_K), ("HDR_K", HDR_K), ("BAND_K", BAND_K),
                    ("BAR_REST", BAR_REST)):
        L.append("localparam [23:0] %-7s = 24'h%02X%02X%02X;" % (nm, *rgb))
    for k, rgb in enumerate(INK):
        L.append("localparam [23:0] INK%d    = 24'h%02X%02X%02X;   // %s" % (k, *rgb, ["white", "accent", "grey", "dark"][k]))
    for n, g in sorted(ICON.items(), key=lambda t: t[1]):
        lp("G_" + n, g, 7)
    lp("G_SPACE", G_SPACE, 7); lp("G_END", G_END, 7, "the string ROM's terminator")
    lp("STR_FORWARD", STR_FORWARD, 9); lp("STR_REVERSE", STR_REVERSE, 9); lp("STR_CHAPTER", STR_CHAPTER, 9)
    lp("STR_LANG", STR_LANG, 9)
    for k, m in enumerate(MSG_IDS):
        lp("STR_MSG%d" % k, MSG_STR[k], 9, m)
        lp("MSG_COL%d" % k, (LAYOUT_P["COLS"] - len(MESSAGES[m])) // 2, 7)
        lp("MSG_COL%d_I" % k, MSG_COLS_I[k], 7); lp("MSG_LEN%d" % k, len(MESSAGES[m]), 7)
    for k, code in enumerate(LANG_ORDER):
        L.append("localparam [15:0] LANG%d   = 16'h%02X%02X;   // %s %s" % (k, code[0], code[1], code.decode(), LANG[code]))
    for k, w in enumerate(TIME_W):
        L.append("localparam [38:0] TW%d     = 39'd%d;" % (k, w))
    L.append("localparam [38:0] T100H   = 39'd%d;   // 100 h: three hour digits from here" % (100 * 3600 * TICKS))
    L.append("localparam [38:0] T1000H  = 39'd%d;  // 1000 h: a three-digit field saturates" % (1000 * 3600 * TICKS))
    with open(os.path.join(outdir, "transport_hud.svh"), "w") as f:
        f.write("\n".join(L) + "\n")


# ---- the mockups --------------------------------------------------------------------------------

AKIRA = dict(title=b"Akira", n_chapters=17, chapter=5, elapsed=631, total=7452)
MOCKUPS = [
    # (name, background key, aspect, caption, state)
    ("01_play", "akira_night", "16:9", "Play (a start or a resume): the icon for 3 s",
     hud_state(popup="play")),
    ("02_pause", "akira_dark", "16:9", "Paused, Display off: the icon stays while paused",
     hud_state(state="pause")),
    ("03_stop", "idle", "16:9", "Stopped: the idle screen, the icon stays",
     hud_state(state="stop")),
    ("04_ff3", "akira_night", "16:9", "Fast forward, speed 3: caption 3 s, icon + badge stay",
     hud_state(state="ff", speed=3, popup="ff")),
    ("05_rew1", "akira_dark", "16:9", "Fast reverse, speed 1, after the caption went",
     hud_state(state="rew", speed=1)),
    ("06_next", "akira_night", "16:9", "Next chapter: its icon and the chapter it lands on, 3 s",
     hud_state(popup="next", chapter=6, n_chapters=17)),
    ("07_track", "akira_dark", "16:9", "Audio track: its number and language, 3 s",
     hud_state(popup="track", track=2, lang=b"ja")),
    ("08_track_raw", "concert", "16:9", "Audio track, a language outside the name table",
     hud_state(popup="track", track=3, lang=b"pt")),
    ("09_message", "akira_night", "16:9", "Next at the last chapter: the message band, 3 s",
     hud_state(message="no_chapter")),
    ("10_display", "akira_dark", "16:9", "Display on, playing",
     hud_state(display=True, **AKIRA)),
    ("11_display_ff3", "akira_night", "16:9", "Display on, fast forward 3 (the clock keeps counting)",
     hud_state(display=True, state="ff", speed=3, popup="ff", **dict(AKIRA, chapter=7, elapsed=1214))),
    ("12_display_fg", "family_guy", "4:3", "Display on, a bright 4:3 title (Family Guy)",
     hud_state(display=True, title=b"FAMILY GUY: FREAKIN' SWEET COLLECTION", n_chapters=4,
               chapter=2, elapsed=1503, total=4412)),
    ("13_display_nochap", "concert", "16:9", "Display on, a title with no chapters: the time alone",
     hud_state(display=True, title=b"My Chemical Romance - Life on the Murder Scene",
               n_chapters=0, chapter=0, elapsed=3312, total=7021)),
    ("14_display_max", "akira_night", "16:9",
     "Spec maxima: chapter 65535, a 100 h+ total, a 128-byte title cut with an ellipsis",
     hud_state(display=True, title=(b"Pirates of the Caribbean: The Curse of the Black Pearl"
                                    b" - a TITLE as long as PARAM.SFO allows, 128 bytes" + b"." * 128)[:128],
               n_chapters=65535, chapter=65535, elapsed=12 * 3600 + 34 * 60 + 56,
               total=123 * 3600 + 45 * 60 + 59)),
    ("15_display_utf8", "akira_dark", "16:9",
     "Non-ASCII title bytes: one placeholder a character (Tom & Jerry's Japanese title)",
     hud_state(display=True, title=b"\xe3\x83\x88\xe3\x83\xa0&\xe3\x82\xb8\xe3\x82\xa7\xe3\x83\xaa\xe3\x83\xbc Vol.1",
               n_chapters=8, chapter=1, elapsed=12, total=2716)),
    ("16_display_pause_msg", "akira_night", "16:9", "Display on, paused, with the message band",
     hud_state(display=True, state="pause", message="no_chapter", **dict(AKIRA, chapter=17))),
    ("17_display_seek", "akira_dark", "16:9",
     "Display on, two Next presses pending: the projected chapter, the time held",
     hud_state(display=True, popup="next", **dict(AKIRA, chapter=7))),
    ("18_message_bright", "family_guy", "4:3", "The message band over a bright 4:3 picture",
     hud_state(message="no_chapter")),
    ("19_display_badutf8", "concert", "16:9",
     "A malformed title (a stray continuation byte, a sequence cut at the end): placeholders, flagged",
     hud_state(display=True, title=b"Live \x80 at Slane \xe3\x83", n_chapters=12, chapter=3,
               elapsed=400, total=5400)),
]


# ---- the bench (bench/umd/run_transport_hud.sh): a stimulus script and the expected frame per
# state, over a synthetic background the testbench computes the same way ----------------------------

# the script's words: [31:24] the op, [23:0] its argument; some ops take following words
OP_WAIT, OP_SET, OP_PULSE, OP_EVENT, OP_ITEM, OP_TITLE, OP_LANG, OP_FRAME, OP_END, OP_WAITPOP, OP_RESET = range(1, 12)
SET_IDS = ["state", "speed", "rev", "chapter", "nch", "aud_present", "pts_lo", "pts_hi", "pts_v",
           "sh_ep", "dur_lo", "dur_hi", "title_len", "title_trunc", "show", "sub_present",
           # P6c: Go To's (goto_ctl's outputs)
           "goto_open", "goto_sel", "goto_edit", "goto_chap", "goto_t_lo", "goto_t_hi", "goto_mv",
           "goto_mark_lo", "goto_mark_hi",
           # P6d follow-up: the current audio / subtitle state (player_ctl's), what a SHOW pops
           "aud_cur", "sub_on_cur", "sub_cur",
           # A-B Repeat (ab_ctl's outputs: tag_up, tag_b, loop)
           "ab_up", "ab_b", "ab_loop"]
GOTO_EDIT = {None: 0, "chapter": 1, "h": 2, "m": 3, "s": 4}
PULSE_IDS = ["mount", "disp", "next", "prev", "unplay", "pmsg1", "pmsg2",   # (P6d: pmsg 1 / 2)
             "show_aud", "show_sub",                                         # (P6d follow-up)
             "ab_na"]                                                        # (A-B Repeat on a bare file)
ST_CODE = {"play": 1, "pause": 2, "stop": 3, "ff": 1, "rew": 1}
SETTLE = 4000                       # cycles for two writer passes (~600 each) and the pipes


def bench_bg():
    """The testbench's background: a function of (x, y) in 8-bit wrapping arithmetic."""
    y, x = np.mgrid[0:H, 0:W]
    r = (x * 3 + y) & 0xFF
    g = (x ^ (y * 2)) & 0xFF
    b = ((x >> 1) + (y >> 1) * 3) & 0xFF
    return np.stack([r, g, b], axis=2).astype(np.uint8)


def stimulus(st, ep=0):
    """The inputs that bring transport_hud to the state `st` (hud_state()), as script words.
    The pop-ups are reached through the triggers the RTL watches (docs/transport_hud.md S6.3),
    so the bench also proves the trigger logic."""
    w = []

    def op(o, arg=0, *more):
        w.append((o << 24) | (arg & 0xFFFFFF))
        w.extend(m & 0xFFFFFFFF for m in more)

    def setv(name, v):
        op(OP_SET, SET_IDS.index(name), v)

    op(OP_RESET)
    setv("show", 0 if st.get("hidden") else 1)
    op(OP_PULSE, PULSE_IDS.index("mount"))
    # the title, as umd_reader keeps it: 128 bytes at most, the SFO's NUL counted
    raw = st["title"][:128]
    for k, b in enumerate(raw):
        op(OP_TITLE, (k << 8) | b)
    if len(raw) < 128:
        op(OP_TITLE, (len(raw) << 8) | 0)
    setv("title_len", min(len(raw) + 1, 128))
    setv("title_trunc", int(st["title_trunc"]))
    # the track: index trk declared with every track below it, so its rank is st["track"]
    trk = st["track"] - 1
    setv("aud_present", (2 << trk) - 1)
    op(OP_LANG, trk, (st["lang"][0] << 8) | st["lang"][1])
    setv("chapter", st["chapter"])
    setv("nch", st["n_chapters"])
    # the time: an item (tag ep) whose base is a third of the elapsed time (or more: the
    # shown PTS is 33 bits), IN = 1000
    tot, el = st["tot_ticks"], st["el_ticks"]
    base, tin = max(el // 3, el - (1 << 32)), 1000
    op(OP_ITEM, ep, tin, 0, base & 0xFFFFFFFF, base >> 32)
    setv("pts_lo", tin + el - base)
    setv("pts_hi", (tin + el - base) >> 32)
    setv("sh_ep", ep)
    setv("pts_v", 1)
    setv("dur_lo", tot)
    setv("dur_hi", tot >> 32)
    if st["display"]:
        op(OP_PULSE, PULSE_IDS.index("disp"))
    gt = st["goto"]
    if gt:                                  # P6c: goto_ctl's outputs, held
        setv("goto_sel", int(gt["sel"] == "time"))
        setv("goto_edit", GOTO_EDIT[gt["edit"]])
        setv("goto_chap", gt["chapter"])
        setv("goto_t_lo", gt["t_ticks"])
        setv("goto_t_hi", gt["t_ticks"] >> 32)
        setv("goto_mv", int(gt["mark_ticks"] is not None))
        mk = gt["mark_ticks"] or 0
        setv("goto_mark_lo", mk)
        setv("goto_mark_hi", mk >> 32)
        setv("goto_open", 1)
    if st["ab"]:                            # A-B Repeat: ab_ctl's levels, held
        setv("ab_up", int(st["ab"] == "a" or st["ab_hold"]))
        setv("ab_b", int(st["ab"] == "ab" or st["ab_blink"]))
        setv("ab_loop", int(st["ab"] == "ab"))
    state, popup = st["state"], st["popup"]
    trick = state in ("ff", "rew")
    # the mode, then the event: a play edge pops PLAY, so a state without it waits it out
    if popup == "play":
        setv("state", ST_CODE["pause"])
        op(OP_WAIT, 100)
        setv("state", ST_CODE["play"])
    else:
        setv("state", ST_CODE[state])
        if trick:
            setv("rev", int(state == "rew"))
            setv("speed", st["speed"])
        if ST_CODE[state] == 1 and popup not in ("ff", "rew"):
            op(OP_WAITPOP)                  # the PLAY (or FF) pop-up of reaching the mode
        if popup in ("next", "prev"):
            op(OP_PULSE, PULSE_IDS.index(popup))
        elif popup == "track" and st["via_show"]:   # P6d follow-up: the current track, shown
            setv("aud_cur", trk)
            op(OP_PULSE, PULSE_IDS.index("show_aud"))
        elif popup == "track":
            op(OP_EVENT, 7, trk)
        elif popup == "sub":                # P7: SUB's event, {on, track}; the language at 16 + n
            strk = st["sub_track"] - 1
            setv("sub_present", ((2 << strk) - 1) & 0xFFFFFFFF)
            if st["sub_on"]:
                op(OP_LANG, 16 + strk, (st["sub_lang"][0] << 8) | st["sub_lang"][1])
            if st["via_show"]:                # P6d follow-up: the current subtitles, shown
                setv("sub_on_cur", int(st["sub_on"]))
                setv("sub_cur", strk)
                op(OP_PULSE, PULSE_IDS.index("show_sub"))
            else:
                op(OP_EVENT, 9, (0x20 if st["sub_on"] else 0) | strk)
        if st["disc_sub"]:                  # P9 M4b: the disc set the subtitles (data[6]): no tag
            op(OP_EVENT, 9, 0x40 | 0x20)
        if st["message"] == "cannot_play":
            op(OP_PULSE, PULSE_IDS.index("unplay"))
        elif st["message"] in ("panel_no_host", "panel_old_host"):     # P6d: emu's pmsg pulse
            op(OP_PULSE, PULSE_IDS.index("pmsg1" if st["message"] == "panel_no_host" else "pmsg2"))
        elif st["message"] == "unavailable" and st["ab_na"]:
            op(OP_PULSE, PULSE_IDS.index("ab_na"))
        elif st["message"]:
            op(OP_EVENT, *MSG_EVENT[st["message"]])
    op(OP_WAIT, SETTLE)
    return w


def bench_states():
    """The mockups, and the edges no mockup shows."""
    out = [(n, st) for n, _, _, _, st in MOCKUPS]
    ak = dict(title=b"Akira", n_chapters=17, chapter=5)
    out += [
        ("b01_prev", hud_state(popup="prev", chapter=4, n_chapters=17)),
        ("b02_next_nochap", hud_state(popup="next", chapter=0, n_chapters=0)),
        ("b03_track12", hud_state(popup="track", track=12, lang=b"\x01z")),
        ("b04_sat_total", hud_state(display=True, el_ticks=5 * 90000, tot_ticks=1200 * 3600 * 90000, **ak)),
        ("b05_el_over_2digit", hud_state(display=True, el_ticks=150 * 3600 * 90000, tot_ticks=99 * 3600 * 90000, **ak)),
        ("b06_tot_zero", hud_state(display=True, el_ticks=0, tot_ticks=0, **ak)),
        ("b07_trunc_short", hud_state(display=True, title=b"Short", title_trunc=True, n_chapters=3,
                                      chapter=2, elapsed=7, total=99)),
        ("b08_display_stop", hud_state(display=True, state="stop", elapsed=3600, total=7200, **ak)),
        ("b09_hidden", hud_state(display=True, message="no_chapter", hidden=True, elapsed=1, total=2, **ak)),
        ("b10_display_rew2", hud_state(display=True, state="rew", speed=2, popup="rew", elapsed=59, total=61, **ak)),
        # the title's room (COLS - 3 cells: 66 at 480p, 54 at 480i): exactly full, and one over
        ("b11_title66", hud_state(display=True, title=b"x" * (COLS - 3), elapsed=1, total=2)),
        ("b12_title67", hud_state(display=True, title=b"y" * (COLS - 2), elapsed=1, total=2)),
        # P7: the subtitle tag's edges -- rank 32 (all 32 tracks declared) with a raw code; Off
        ("b13_sub_rank32", hud_state(popup="sub", sub_on=True, sub_track=32, sub_lang=b"\x01z")),
        ("b14_sub_off_display", hud_state(popup="sub", sub_on=False, display=True, elapsed=5, total=60, **ak)),
        # A7: the Subtitle button with no UMD Main, and with a mismatched one
        ("b15_no_host", hud_state(message="no_host")),
        ("b16_old_host", hud_state(display=True, state="pause", message="old_host", elapsed=5, total=60, **ak)),
        # A11: a disc the core stops on (a refused stream, a reader error), stopped and with Display on
        ("b17_cannot_play", hud_state(state="stop", message="cannot_play")),
        ("b18_cannot_play_display", hud_state(display=True, state="stop", message="cannot_play", elapsed=0, total=60, **ak)),
        # P9 M4b (the maintainer on the rig: The Island's every play popped the subtitle tag): a SUB event the
        # disc caused (SUB_SET, data[6]) draws nothing -- alone, and under Display
        ("b19_disc_sub", hud_state(disc_sub=True)),
        ("b20_disc_sub_display", hud_state(disc_sub=True, display=True, elapsed=5, total=60, **ak)),
        # P6d (docs/panel.md F4): the Control Panel button with no UMD Main, and with one that did not take it
        ("b21_panel_no_host", hud_state(message="panel_no_host")),
        ("b22_panel_old_host", hud_state(display=True, state="pause", message="panel_old_host", elapsed=5, total=60, **ak)),
        # P6d follow-up (the maintainer, 2026-10-05): the first Audio / Subtitle press SHOWS the current track --
        # the same tag as a change, reached by emu's show pulse with player_ctl's current values
        ("b23_show_audio", hud_state(popup="track", track=2, lang=b"ja", via_show=True)),
        ("b24_show_sub_off", hud_state(popup="sub", sub_on=False, via_show=True)),
        ("b25_show_sub_on", hud_state(popup="sub", sub_on=True, sub_track=2, sub_lang=b"fr", display=True,
                                      elapsed=5, total=60, via_show=True, **ak)),
        # P8 (docs/bare_streams.md): a seek asked of a bare stream file, alone and under Display with
        # a bare .MPS's unknown total (0: the bar empty); and a bare stream's track tag (no language:
        # emu feeds two spaces)
        ("b26_unavailable", hud_state(message="unavailable")),
        ("b27_unavailable_display", hud_state(display=True, message="unavailable", elapsed=5, total=0)),
        ("b28_track_no_lang", hud_state(popup="track", track=2, lang=b"  ")),
    ]
    out += [(n, st) for n, _, _, _, st, _ in MOCKUPS_P7]
    # A-B Repeat's mockups (docs/ab_repeat.md §4), and the edges no mockup shows
    out += [(n, st) for n, _, _, _, st, _ in MOCKUPS_AB]
    out += [
        ("ab10_a_next", hud_state(ab="a", ab_blink=True, popup="next", chapter=6, n_chapters=17)),
        ("ab11_a_rew3_display", hud_state(ab="a", ab_blink=False, display=True, state="rew", speed=3,
                                          elapsed=59, total=61, **ak)),
        ("ab12_loop_stop", hud_state(ab="ab", state="stop")),
        ("ab13_unavailable", hud_state(message="unavailable", ab_na=True)),
        ("ab14_loop_track", hud_state(ab="ab", popup="track", track=2, lang=b"ja")),
    ]
    # P6c: Go To's mockups, and the edges no mockup shows
    out += [(n, st) for n, _, _, _, st, _ in MOCKUPS_GOTO]
    g = dict(sel="time", edit=None, chapter=5, t_ticks=631 * TICKS, mark_ticks=631 * TICKS)
    out += [
        # three hour digits (a title of 100 h): the hours field odd -- one-cell arrows
        ("g01_hours3", hud_state(goto=dict(g, edit="h", t_ticks=(123 * 3600 + 4) * TICKS, mark_ticks=None),
                                 elapsed=5, total=150 * 3600, **ak)),
        # the minutes of a three-digit time; the bar full (elapsed past the total: its first quotient
        # step is 512), the marker inside it
        ("g02_min3", hud_state(goto=dict(g, edit="m", t_ticks=(999 * 3600 + 59 * 60 + 59) * TICKS,
                                         mark_ticks=30 * 3600 * TICKS), elapsed=150 * 3600 + 10, total=150 * 3600, **ak)),
        # the marker past the total: at the bar's end
        ("g09_mark_end", hud_state(goto=dict(g, mark_ticks=999 * 3600 * TICKS), elapsed=5, total=150 * 3600, **ak)),
        # a five-digit chapter (odd: one-cell arrows), the marker hidden (another item, D15)
        ("g03_chap5", hud_state(goto=dict(g, sel="chapter", edit="chapter", chapter=12345, mark_ticks=None),
                                title=b"Akira", n_chapters=65535, chapter=12000, elapsed=631, total=7452)),
        # a four-digit chapter (even: the two-cell pair) at 0:00, the marker at 0
        ("g04_chap4", hud_state(goto=dict(g, sel="chapter", edit="chapter", chapter=1000, mark_ticks=0),
                                title=b"Akira", n_chapters=2000, chapter=999, elapsed=0, total=7452)),
        # Display on too (Go To's layout wins), paused (the icon stays), a message over the up-arrow
        # (three hour digits put the chapter's digit at column 47, inside the message's 19-48)
        ("g05_display_msg", hud_state(goto=dict(g, sel="chapter", edit="chapter"), display=True, state="pause",
                                      message="no_chapter", elapsed=631, total=150 * 3600, **ak)),
        # a Next pop-up while open: its icon, but no caption (the row is the editor's)
        ("g06_next_popup", hud_state(goto=dict(g, sel="chapter"), popup="next", elapsed=631, total=7452, **ak)),
        # Chapter 0 (no chapter reachable yet), the chapter box focused, a track pop-up suppressed
        ("g07_chap0_track", hud_state(goto=dict(g, sel="chapter", chapter=0, mark_ticks=None), popup="track",
                                      elapsed=631, total=7452, **ak)),
        # trick play under it: the icon and badge stay; the total zero (the marker at the bar's start)
        ("g08_trick_tot0", hud_state(goto=dict(g, edit="h"), state="ff", speed=2, elapsed=0, total=0, **ak)),
    ]
    return out


def bench(outdir):
    """Write <outdir>/states.txt (one name a line), sNN.stim.hex and sNN.exp.hex."""
    os.makedirs(outdir, exist_ok=True)
    bg = bench_bg()
    names = []
    for k, (name, st) in enumerate(bench_states()):
        img, _ = render(st, bg) if not st.get("hidden") else (bg, None)
        w = stimulus(st, ep=(k % 4)) + [(OP_FRAME << 24) | k, OP_END << 24]
        with open(os.path.join(outdir, "s%02d.stim.hex" % k), "w") as f:
            f.write("\n".join("%08x" % x for x in w) + "\n")
        flat = (img[:, :, 0].astype(np.uint32) << 16) | (img[:, :, 1].astype(np.uint32) << 8) | img[:, :, 2]
        with open(os.path.join(outdir, "s%02d.exp.hex" % k), "w") as f:
            f.write("\n".join("%06x" % v for v in flat.ravel()) + "\n")
        names.append(name)
    with open(os.path.join(outdir, "states.txt"), "w") as f:
        f.write("\n".join(names) + "\n")
    return names


def synthetic_bg():
    y, x = np.mgrid[0:H, 0:W]
    return np.stack([(x * 255 // W), (y * 200 // H) + 30, np.full_like(x, 120)], axis=2).astype(np.uint8)


def load_bg(path):
    from PIL import Image
    im = Image.open(path).convert("RGB")
    assert im.size == (W, H), "%s: %s, want the raster %dx%d" % (path, im.size, W, H)
    return np.array(im)


def to_display(img, aspect):
    """The raster at the displayed aspect (what a TV shows: 16:9 -> 854 x 480, 4:3 -> 640)."""
    from PIL import Image
    w = 854 if aspect == "16:9" else 640
    return Image.fromarray(img).resize((w, H), Image.LANCZOS)


# P7 (docs/subtitles.md §7, S3): the subtitle tag, for the maintainer's approval before RTL. Each
# entry may carry a real subtitle unit (its PNG and its (x, y) from the disc, umd_sub_extract)
# composited under the HUD -- the tag and a bottom subtitle share the lower left.
AKIRA_SUB = (".sim/p7_subpng/80_0010642542.png", 156, 379)    # Akira 0x80, 410 x 70 at (156, 379)
MOCKUPS_P7 = [
    ("p7_01_sub_on", "akira_dark", "16:9", "Subtitle pressed: track 1, English",
     hud_state(popup="sub", sub_on=True, sub_track=1, sub_lang=b"en"), AKIRA_SUB),
    ("p7_03_sub_off", "akira_night", "16:9", "Subtitle pressed to Off",
     hud_state(popup="sub", sub_on=False), None),
    ("p7_05_sub_ja", "concert", "16:9", "Track 2, Japanese",
     hud_state(popup="sub", sub_on=True, sub_track=2, sub_lang=b"ja"), None),
    ("p7_06_sub_raw", "family_guy", "4:3", "Track 3, a language outside the name table",
     hud_state(popup="sub", sub_on=True, sub_track=3, sub_lang=b"pt"), None),
    ("p7_07_display_sub", "akira_dark", "16:9", "Display on, a subtitle showing (no tag): the bar and the subtitle",
     hud_state(display=True, **AKIRA), AKIRA_SUB),
]


# P6c (docs/p6c.md §2.1, §9): Go To's editor, for the maintainer's approval before any RTL (P6c0).
# The behaviour is the PSP's as transport_hud.md §3 and transport.md's walk-through record it: both
# boxes above the bar (`Chapter n`, then the time; the time alone without chapters), the chapter box
# focused first, ← / → between the boxes, Select (×) opens one for ▲ / ▼, the time's hours,
# minutes and seconds edited apart (← / → between them), × confirms; a blue ▼ above the bar at the
# target. The marker's place: the chapter's start, or the time typed.
MX = dict(title=b"The Matrix", n_chapters=36, chapter=5, elapsed=631, total=8170)
MOCKUPS_GOTO = [
    ("goto_01_open", "matrix", "16:9", "Go To pressed: the chapter box focused (lighter), the marker at chapter 5",
     hud_state(goto=dict(sel="chapter", edit=None, chapter=5, t_ticks=631 * TICKS, mark_ticks=540 * TICKS), **MX), None),
    ("goto_02_chapter", "matrix", "16:9", "x on the chapter box: ▲ / ▼ step it, here to 12; the marker follows",
     hud_state(goto=dict(sel="chapter", edit="chapter", chapter=12, t_ticks=631 * TICKS, mark_ticks=2604 * TICKS), **MX), None),
    ("goto_03_time", "matrix", "16:9", "→ to the time box (focused); x opens it",
     hud_state(goto=dict(sel="time", edit=None, chapter=5, t_ticks=631 * TICKS, mark_ticks=631 * TICKS), **MX), None),
    ("goto_04_minutes", "matrix", "16:9", "The time box open on its minutes (→ moved from the hours): 01:23:45",
     hud_state(goto=dict(sel="time", edit="m", chapter=5, t_ticks=5025 * TICKS, mark_ticks=5025 * TICKS), **MX), None),
    ("goto_05_no_chapters", "gits", "16:9", "A title without chapters: the time alone, its hours open",
     hud_state(goto=dict(sel="time", edit="h", chapter=0, t_ticks=1800 * TICKS, mark_ticks=1800 * TICKS),
               title=b"Ghost in the Shell 2.0", n_chapters=0, chapter=0, elapsed=40, total=5002), None),
    ("goto_06_bright", "family_guy", "4:3", "A bright 4:3 title: the seconds open",
     hud_state(goto=dict(sel="time", edit="s", chapter=2, t_ticks=754 * TICKS, mark_ticks=754 * TICKS),
               title=b"Family Guy", n_chapters=6, chapter=2, elapsed=300, total=1356), None),
]


# A-B Repeat (docs/ab_repeat.md §4): the tag as the maintainer's PSP showed it (2026-10-07), for
# approval before any RTL (AB0)
MOCKUPS_AB = [
    ("ab_01_a_on", "akira_night", "16:9", "A set (first press): the icon and A-B, the B blinking -- on phase",
     hud_state(ab="a", ab_blink=True), None),
    ("ab_02_a_off", "akira_night", "16:9", "A set: the blink's off phase (0.5 s each)",
     hud_state(ab="a", ab_blink=False), None),
    ("ab_03_b_hold", "akira_dark", "16:9", "B set (second press): the B solid for 2 s, then both go",
     hud_state(ab="ab", ab_hold=True), None),
    ("ab_04_loop", "akira_dark", "16:9", "Looping, after the 2 s: nothing drawn (the PSP)",
     hud_state(ab="ab"), None),
    ("ab_05_loop_display", "akira_night", "16:9", "Looping with Display on: the tag beside the icon (AB12)",
     hud_state(ab="ab", display=True, **AKIRA), None),
    ("ab_06_loop_pause", "akira_dark", "16:9", "Paused inside the loop: the pause icon and the tag",
     hud_state(ab="ab", state="pause"), None),
    ("ab_07_a_ff", "akira_night", "16:9", "A set, fast forward 2 to reach B (AB11): icon + badge, then the tag",
     hud_state(ab="a", state="ff", speed=2, popup="ff"), None),
    ("ab_08_a_bright", "family_guy", "4:3", "A set over a bright 4:3 picture",
     hud_state(ab="a", ab_blink=True), None),
    ("ab_09_a_sub", "akira_dark", "16:9", "A set with a subtitle showing (the tag and a bottom subtitle share the lower left)",
     hud_state(ab="a", ab_blink=True), AKIRA_SUB),
]


def with_sub(bg, spec):
    """A subtitle unit (straight RGBA, as libpng gives it) over the background at (x, y)."""
    if not spec:
        return bg
    from PIL import Image
    path, x, y = spec
    im = np.array(Image.open(os.path.join(ROOT, path)).convert("RGBA")).astype(np.float64)
    out = bg.astype(np.float64).copy()
    h, w = im.shape[:2]
    h, w = min(h, H - y), min(w, W - x)
    a = im[:h, :w, 3:4] / 255.0
    out[y:y + h, x:x + w] = im[:h, :w, :3] * a + out[y:y + h, x:x + w] * (1 - a)
    return np.round(out).astype(np.uint8)


def mockups(bgmap, outdir, only=None, which=None, il=False):
    from PIL import Image, ImageDraw
    os.makedirs(outdir, exist_ok=True)
    set_layout(il)
    tiles = []
    for ent in (MOCKUPS_P7 if which == "p7" else MOCKUPS_GOTO if which == "goto" else
                MOCKUPS_AB if which == "ab" else [m + (None,) for m in MOCKUPS]):
        name, key, aspect, caption, st, subspec = ent
        if only and name not in only:
            continue
        bg = load_bg(bgmap[key]) if key in bgmap else synthetic_bg()
        bg = with_sub(bg, subspec)
        img, flags = render(st, bg)
        Image.fromarray(img).save(os.path.join(outdir, name + "_raster.png"))
        if il:                                 # the review guide: the title-safe rectangle, dashed
            img = img.copy()
            x0, y0, x1, y1 = SAFE
            for x in range(x0, x1 + 1, 6):
                img[y0, x:x + 3] = img[y1, x:x + 3] = (255, 220, 0)
            for y in range(y0, y1 + 1, 6):
                img[y:y + 3, x0] = img[y:y + 3, x1] = (255, 220, 0)
        disp = to_display(img, aspect)
        disp.save(os.path.join(outdir, name + ".png"))
        tiles.append((name, caption + ("  [flags: %s]" % ", ".join(k for k, v in flags.items() if v)
                                       if any(flags.values()) else ""), disp))
    # the contact sheet: two across at half size, a caption under each
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
    return len(tiles)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--mockups", action="store_true", help="render every state in MOCKUPS")
    ap.add_argument("--bg", action="append", default=[], metavar="KEY=PNG",
                    help="a 720x480 background per key (a rig screenshot, mister.py shot); "
                         "keys: akira_dark akira_night family_guy concert idle")
    ap.add_argument("--out", default=os.path.join(ROOT, ".sim", "p6b5_mockups"))
    ap.add_argument("--only", nargs="*")
    ap.add_argument("--p7", action="store_true", help="the P7 subtitle-tag mockups (MOCKUPS_P7)")
    ap.add_argument("--goto", action="store_true", help="the P6c Go To editor mockups (MOCKUPS_GOTO)")
    ap.add_argument("--ab", action="store_true", help="the A-B Repeat tag mockups (MOCKUPS_AB)")
    ap.add_argument("--il", action="store_true", help="the 480i (title-safe) layout, the safe area drawn dashed")
    ap.add_argument("--gen", action="store_true", help="write umd/transport_hud.svh and transport_str.mem")
    ap.add_argument("--bench", metavar="DIR", help="write the bench's stimulus and expected frames (--il: the 480i layout)")
    a = ap.parse_args(argv)
    if a.gen:
        gen_rtl()
        print("wrote umd/transport_hud.svh and umd/transport_str.mem")
    if a.bench:
        set_layout(a.il)
        names = bench(a.bench)
        print("wrote %d bench states to %s" % (len(names), a.bench))
    if a.mockups:
        bgmap = dict(kv.split("=", 1) for kv in a.bg)
        out = os.path.join(ROOT, ".sim", "p7_mockups") if a.p7 else \
            os.path.join(ROOT, ".sim", "goto_mockups" + ("_il" if a.il else "")) if a.goto else \
            os.path.join(ROOT, ".sim", "ab_mockups" + ("_il" if a.il else "")) if a.ab else a.out
        n = mockups(bgmap, out, a.only, "p7" if a.p7 else "goto" if a.goto else "ab" if a.ab else None, a.il)
        a.out = out
        print("wrote %d mockups and sheet.png to %s" % (n, os.path.relpath(a.out, ROOT)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
