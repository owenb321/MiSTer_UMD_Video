#!/usr/bin/env python3
"""panel_bench.py -- bench/umd/run_panel.sh's driver (P6d C2, docs/panel.md §4): the UMD Main's control
panel (main/support/umd/umd_panel.c, through bench/umd/panel/panel_check.c) against
  * tools/panel_ref.py, the behaviour model written from the PSP measurements -- every step's state,
    levels, view and actions, in order;
  * tools/panel_layout.py's page() -- the pixels, byte for byte.

Arms (each a FAIL line tagged with it; one PASS line at the end):
  [open] [walk] [act] [close] [menu] [goto] [dark]  directed scripts, one per rule group
  [random]  seeded random walks: reads (the play state, seeks, Go To's editor, a disc menu, the
            subtitle track, the engine changing under it) and presses, 40 x 400 steps
  [pixels]  every item selected, in playback and over a disc menu, items dark and not, over an empty page
  [under]   ... over a real subtitle unit and over a random premultiplied page
  [plane]   ... in the plane's byte order (B, G, R, A)
  [rect]    the rectangle umd_panel_rect reports is the model's box, and nothing is drawn outside it
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(HERE)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import numpy as np  # noqa: E402
import panel_ref as R  # noqa: E402
import panel_layout as PL  # noqa: E402

NAMES = [n for r in PL.ROWS for n in r]
FAILS = []
KIND = {"press": 1, "cmd": 2, "menu": 3, "quit": 4}
SHOW = {None: 0, "ui_sub": 1, "frame": 2}


def fail(arm, what):
    FAILS.append("[%s] %s" % (arm, what))


# ---- the model's answer line ----

def view(p):
    if not p.open or p.hidden:
        return 0
    v = 1 | (p.mode == "menu") << 1 | NAMES.index(p.sel) << 2
    for i, n in enumerate(NAMES):
        if p.available(n):
            v |= 1 << (8 + i)
    return v


def answer(p, acts):
    lv = p.levels()
    parts = ["S", int(p.open), int(p.hidden), int(p.mode == "menu"), NAMES.index(p.sel), lv["grab"],
             SHOW[lv["show"]], view(p), len(acts)]
    for a in acts:
        parts += [KIND[a[0]], a[1] if len(a) > 1 else 0]
    return " ".join(str(x) for x in parts)


# ---- a script: steps applied to the model, written for the harness ----

class Script:
    def __init__(self):
        self.p = R.Panel()
        self.lines, self.want = [], []

    def r(self, now, state=1, seeking=0, goto_open=0, sub_any=1, menu_up=0, engine=1):
        rd = R.Rd(state=state, seeking=bool(seeking), goto_open=bool(goto_open), sub_any=bool(sub_any),
                  menu_up=bool(menu_up), engine=bool(engine))
        self.p.read(rd, now)
        self.lines.append("R %d %d %d %d %d %d %d" % (state, seeking, goto_open, sub_any, menu_up, engine, now))
        self.want.append(answer(self.p, []))

    def k(self, *bits, mask=None):
        m = mask if mask is not None else sum(1 << b for b in bits)
        acts = self.p.key(m)
        self.lines.append("K %d" % m)
        self.want.append(answer(self.p, acts))

    def set(self, open_=1, hidden=0, menu=0, sel="display", sub_any=1, engine=1):
        p = self.p
        p.open, p.hidden, p.mode, p.sel = bool(open_), bool(hidden), "menu" if menu else "play", sel
        p.rd.sub_any, p.rd.engine = bool(sub_any), bool(engine)
        self.lines.append("P %d %d %d %d %d %d" % (open_, hidden, menu, NAMES.index(sel), sub_any, engine))
        self.want.append(answer(p, []))


def run_bin(binp, lines):
    r = subprocess.run([binp], input="\n".join(lines) + "\n", capture_output=True, text=True)
    out = r.stdout.splitlines()
    if r.returncode != 0 or not out or out[-1] != "END":
        return None, r.stderr.strip()[:200]
    return out[:-1], ""


def score(binp, arm, name, sc):
    got, err = run_bin(binp, sc.lines)
    if got is None:
        fail(arm, "%s: the harness failed: %s" % (name, err))
        return
    got = [g for g in got if g.startswith("S ")]
    for i, (w, g) in enumerate(zip(sc.want, got)):
        if w != g:
            fail(arm, "%s step %d (%s): want '%s' got '%s'" % (name, i, sc.lines[i], w, g))
            return
    if len(got) != len(sc.want):
        fail(arm, "%s: %d answers for %d steps" % (name, len(got), len(sc.want)))


# ---- the directed scripts ----
B = R

def directed():
    out = []
    s = Script()                                                    # [open]
    s.r(0, state=0); s.k(B.B_PANEL)
    for st in (1, 2, 3):
        s.r(10 * st, state=st); s.k(B.B_PANEL); s.k(B.B_PANEL)
    s.r(50, state=0, menu_up=1); s.k(B.B_PANEL)
    s.r(60, state=3, menu_up=1); s.k(B.B_PANEL)
    s.r(70, state=3, menu_up=0); s.k(B.B_PANEL, B.B_RIGHT)          # opened and walked in one mask
    out.append(("open", "the panel button", s))

    for sub_any, engine in ((1, 1), (0, 1), (1, 0), (0, 0)):        # [walk]
        s = Script()
        s.r(0, sub_any=sub_any, engine=engine); s.k(B.B_PANEL)
        for b in [B.B_RIGHT] * 6 + [B.B_LEFT] * 6 + [B.B_DOWN] + [B.B_RIGHT] * 8 + [B.B_UP, B.B_DOWN] + \
                [B.B_LEFT] * 8 + [B.B_UP, B.B_LEFT, B.B_DOWN, B.B_LEFT, B.B_UP, B.B_DOWN, B.B_DOWN]:
            s.k(b)
        out.append(("walk", "sub %d engine %d" % (sub_any, engine), s))
    s = Script()
    s.r(0, sub_any=0); s.k(B.B_PANEL)
    s.set(sel="ff", sub_any=0); s.k(B.B_UP)                          # the tie to the left
    s.set(sel="rew", sub_any=0); s.k(B.B_UP)
    out.append(("walk", "ties", s))

    s = Script()                                                    # [act]
    s.r(0)
    for name in NAMES:
        s.set(sel=name); s.k(B.B_PAUSE); s.k(B.B_PANEL) if s.p.open else None
    out.append(("act", "every item", s))

    s = Script()                                                    # [close]
    s.r(0); s.k(B.B_PANEL); s.k(B.B_STOP)
    s.k(B.B_PANEL); s.k(B.B_PANEL)
    s.k(B.B_PANEL); s.r(10, state=0)
    s.r(20); s.k(B.B_PANEL); s.r(30, menu_up=1)
    s.r(40, menu_up=1); s.k(B.B_PANEL); s.r(50, menu_up=0)
    s.r(60); s.k(B.B_PANEL); s.r(70, state=2); s.r(80, state=3); s.r(90, state=1)
    s.set(sel="stop"); s.k(B.B_PAUSE)
    s.r(100); s.k(B.B_PANEL); s.set(sel="menu"); s.k(B.B_PAUSE)
    out.append(("close", "what closes it", s))

    s = Script()                                                    # [menu]
    s.r(0, menu_up=1); s.k(B.B_PANEL)
    for b in (B.B_RIGHT, B.B_RIGHT, B.B_LEFT, B.B_DOWN, B.B_LEFT, B.B_RIGHT, B.B_UP, B.B_PAUSE):
        s.k(b)
    s.set(menu=1, sel="stop"); s.k(B.B_PAUSE)
    s.r(10, menu_up=1, engine=0); s.k(B.B_PANEL); s.k(B.B_RIGHT); s.k(B.B_PAUSE)
    s.set(menu=1, sel="menu", engine=1); s.k(B.B_PAUSE)
    out.append(("menu", "over a disc menu", s))

    s = Script()                                                    # [goto]
    s.r(0); s.k(B.B_PANEL); s.set(sel="goto"); s.k(B.B_PAUSE)
    s.k(B.B_RIGHT); s.k(B.B_STOP)                                   # (keys while hidden)
    s.r(10, goto_open=1); s.r(500, goto_open=1)
    s.r(510, seeking=1); s.r(520, seeking=1); s.r(530); s.r(540); s.r(550)
    s.set(sel="goto"); s.k(B.B_PAUSE); s.r(560, goto_open=1); s.r(570); s.r(580)        # a cancel
    s.r(600); s.set(sel="goto"); s.k(B.B_PAUSE)                                       # hidden at 600 exactly:
    s.r(600 + B.GOTO_OPEN_MS - 1); s.r(600 + B.GOTO_OPEN_MS)                          # the timeout's boundary
    s.set(sel="audio"); s.r(1000, goto_open=1); s.r(1010); s.r(1020)                    # the Go To button
    s.set(sel="goto"); s.k(B.B_PAUSE); s.r(1030, goto_open=1); s.k(B.B_PANEL)
    s.r(1100, sub_any=0); s.k(B.B_PANEL); s.set(sel="goto", sub_any=0); s.k(B.B_PAUSE)
    s.r(1110, goto_open=1, sub_any=0); s.r(1120, sub_any=0); s.r(1130, sub_any=0)
    out.append(("goto", "Go To's hide and return", s))

    s = Script()                                                    # [dark]
    s.r(0); s.k(B.B_PANEL); s.set(sel="sub"); s.r(10, sub_any=0); s.k(B.B_PAUSE)
    s.set(sel="menu"); s.r(20, engine=0); s.k(B.B_PAUSE)
    out.append(("dark", "an item gone dark under the cursor", s))
    return out


def random_script(seed, steps=400):
    rng = random.Random(seed)
    s = Script()
    now, st = 0, dict(state=1, seeking=0, goto_open=0, sub_any=1, menu_up=0, engine=1)
    common = [B.B_RIGHT, B.B_LEFT, B.B_UP, B.B_DOWN, B.B_PAUSE, B.B_STOP, B.B_PANEL, B.B_PANEL]
    for _ in range(steps):
        if rng.random() < 0.45:
            now += rng.choice([0, 1, 5, 10, 10, 10, 40, 300])
            if rng.random() < 0.10: st["state"] = rng.choice([0, 1, 1, 2, 3])
            if rng.random() < 0.15: st["seeking"] ^= 1
            if rng.random() < 0.15: st["goto_open"] ^= 1
            if rng.random() < 0.04: st["menu_up"] ^= 1
            if rng.random() < 0.05: st["sub_any"] ^= 1
            if rng.random() < 0.04: st["engine"] ^= 1
            s.r(now, **st)
        elif rng.random() < 0.9:
            s.k(rng.choice(common))
        else:
            s.k(mask=rng.getrandbits(16))
    return s


# ---- the pixels ----

def noise_page(seed):
    rng = np.random.default_rng(seed)
    a = rng.integers(0, 256, (PL.H, PL.W), dtype=np.int64)
    pg = np.zeros((PL.H, PL.W, 4), dtype=np.int64)
    for c in range(3):
        pg[..., c] = (rng.integers(0, 256, (PL.H, PL.W)) * a) // 255
    pg[..., 3] = a
    return pg


def pixel_states():
    sts = []
    for menu in (0, 1):
        for sub_any, engine in ((1, 1), (0, 0)):
            for name in NAMES:
                sts.append((menu, name, sub_any, engine))
    return sts


def draw(binp, tmp, set_line, under, layout):
    """under: (H, W, 4) RGBA int -> the harness's page, as RGBA"""
    up, op = os.path.join(tmp, "under.raw"), os.path.join(tmp, "out.raw")
    raw = under.astype(np.uint8)
    if layout == 1:
        raw = raw[..., [2, 1, 0, 3]]
    raw.tofile(up)
    got, err = run_bin(binp, [set_line, "D %d %s %s" % (layout, up, op)])
    if got is None:
        return None, err
    out = np.fromfile(op, dtype=np.uint8).reshape(PL.H, PL.W, 4)
    if layout == 1:
        out = out[..., [2, 1, 0, 3]]
    return out.astype(np.int64), ""


def pixel_arm(binp, tmp, arm, cases):
    for menu, name, sub_any, engine, under, layout, tag in cases:
        st = PL.panel_state(sel=name, in_menu=bool(menu), has_sub=bool(sub_any), has_menu=bool(engine))
        want = PL.page(st, under)
        got, err = draw(binp, tmp, "P 1 0 %d %d %d %d" % (menu, NAMES.index(name), sub_any, engine), under, layout)
        if got is None:
            fail(arm, "%s: the harness failed: %s" % (tag, err))
            return
        d = np.argwhere((got != want).any(axis=2))
        if len(d):
            y, x = d[0]
            fail(arm, "%s: %d pixels differ, first (%d, %d): want %s got %s" % (
                tag, len(d), x, y, list(want[y, x]), list(got[y, x])))
            return


def main():
    binp, tmp = sys.argv[1], sys.argv[2]
    os.makedirs(tmp, exist_ok=True)
    for arm, name, sc in directed():
        score(binp, arm, name, sc)
    cov = {}
    for seed in range(40):
        sc = random_script(seed)
        score(binp, "random", "seed %d" % seed, sc)
        for w in sc.want:                                           # what the walks reached (the model's view)
            f = w.split()
            if f[1] == "1":
                cov["open"] = cov.get("open", 0) + 1
                cov["hidden" if f[2] == "1" else "shown"] = cov.get("hidden" if f[2] == "1" else "shown", 0) + 1
                cov["menu_mode" if f[3] == "1" else "play_mode"] = 1
                cov["sel_" + NAMES[int(f[4])]] = 1
            for k in range(int(f[8])):
                cov["act_%s" % f[9 + 2 * k]] = cov.get("act_%s" % f[9 + 2 * k], 0) + 1
    need = ["open", "hidden", "shown", "menu_mode", "play_mode"] + ["sel_" + n for n in NAMES] + \
        ["act_%d" % k for k in (1, 2, 3, 4)]
    miss = [n for n in need if not cov.get(n)]
    if miss:
        fail("random", "the walks never reached %s: the arm is vacuous there" % miss)

    empty = np.zeros((PL.H, PL.W, 4), dtype=np.int64)
    pixel_arm(binp, tmp, "pixels", [(m, n, s, e, empty, 0, "menu %d %s sub %d engine %d" % (m, n, s, e))
                                    for m, n, s, e in pixel_states()])
    sub = PL.sub_page(PL.SUB_HIGH)
    noise = noise_page(7)
    pixel_arm(binp, tmp, "under", [(0, "audio", 1, 1, sub, 0, "a subtitle under it"),
                                   (0, "ff", 0, 1, noise, 0, "a random page under it"),
                                   (1, "display", 1, 1, noise, 0, "a random page, over a disc menu")])
    pixel_arm(binp, tmp, "plane", [(0, "display", 1, 1, noise, 1, "the plane's byte order"),
                                   (1, "stop", 1, 0, sub, 1, "the plane's byte order, over a disc menu")])

    got, err = run_bin(binp, ["Q"])                                 # [rect]
    bx, by, bw, bh = PL.box_geom()
    if got is None or got != ["Q %d %d %d %d" % (bx, by, bw, bh)]:
        fail("rect", "umd_panel_rect: want Q %d %d %d %d, got %s" % (bx, by, bw, bh, got or err))
    for menu, name, sub_any, engine in pixel_states()[::5]:
        st = PL.panel_state(sel=name, in_menu=bool(menu), has_sub=bool(sub_any), has_menu=bool(engine))
        pg = PL.page(st)
        inside = np.zeros((PL.H, PL.W), dtype=bool)
        inside[by:by + bh, bx:bx + bw] = True
        if (pg[~inside] != 0).any():
            fail("rect", "%s: the model draws outside the box" % name)
            break
    got, err = draw(binp, tmp, "P 1 0 0 %d 1 1" % NAMES.index("display"), noise, 0)
    if got is not None:
        outside = np.ones((PL.H, PL.W), dtype=bool)
        outside[by:by + bh, bx:bx + bw] = False
        if (got[outside] != noise[outside]).any():
            fail("rect", "the C draws outside its rectangle")

    if FAILS:
        for f in FAILS:
            print("FAIL", f)
        print("panel_bench: %d FAILED" % len(FAILS))
        sys.exit(1)
    print("PASS panel_bench: %d directed scripts, 40 random walks, %d pixel states, rect" % (
        len(directed()), len(pixel_states()) + 5))


if __name__ == "__main__":
    main()
