#!/usr/bin/env python3
"""telecine_ref.py -- field matching for hard-telecined film (Forgejo fj#80, docs/telecine.md):
the comb observable the display reader can compute, the cadence lock, and the scores, as the
golden of the bench the RTL stage will have.

The case: ~15 of the library's main titles are 23.976 film coded as 59.94 field pairs
(pic_struct 1 / 2, ct_type 1, no repeat flag): the 3:2 pulldown baked into the fields. Woven
as coded, 2 pairs of every 5 hold two film frames and comb. Field matching weaves the shown
field with the neighbouring field of the other parity that belongs to the same film frame.

What the model may use is what disp_reader sees (docs/telecine.md S2):
  * at 480p the reader fetches every line of the ONE store on screen; its window holds lines
    a = v-1, b = v, d = v+1 (mirrored at the edges, disp_reader.sv bk_a / bk_d), so the
    observable is, per refresh, over the DISPLAYED weave,
        C = sum |2b - a - d|        R = sum |a - d|        (luma, integers)
    -- the in-store weave while unlocked, the cross-store weave under a lock; known at line
    478, before the pickup at line 500, so refresh k's evidence steers refresh k+1;
  * no lookahead: a pair's in-store comb is known only once it has been shown;
  * the partner of a matched field (the matching rule; measured by `score`, not assumed):
        refresh 0 of a pair (its first field)  -> the previous store's SECOND field
        refresh 1 of a pair (its second field) -> the next store's FIRST field.

Independent truth (never C): ffmpeg idet's per-frame repeated-field flag, and the model's own
same-parity field difference, give each field's film frame; from that, which pairs span two film
frames. Whether the rule's partners belong to the same frame is MEASURED, not derived from that
truth (which assumes 2- and 3-field runs, so it could never say otherwise): at every split pair
with both partners present, the rule's two cross-store weaves against the in-store weave on the
rig gate (score's rule_* figures).

    telecine_ref.py ISO [--frac F ...] [--packs N] [--cache DIR] [--rows]   one title's windows
    telecine_ref.py --selftest                                              the synthetic arms
"""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

SEC = 2048

# The subsample variants of the observable: (column step, line step). The RTL accumulates on
# the dots / lines it keeps; (1, 1) is every dot of every line.
VARIANTS = [(1, 1), (2, 1), (4, 1), (8, 1), (4, 2), (8, 2), (8, 4)]


# ---------------------------------------------------------------- the observable

def window3(W):
    """The reader's a / b / d lines for every raster line v of a store (disp_reader.sv's ring:
    bk_a = v-1, the top line mirrored to +1; bk_d = v+1, the last line mirrored to -1)."""
    H = W.shape[0]
    ia = np.arange(H) - 1
    ia[0] = 1
    idd = np.arange(H) + 1
    idd[-1] = H - 2
    return W[ia], W, W[idd]


RASTER_LINES = 480     # the raster shows lines 0..479 of a taller picture (720x576: line 479's d is 480)


def observe(W):
    """{variant: (C, R)} over one displayed weave W (uint8 luma, H x W), integers -- the raster's
    lines only (disp_reader accumulates what it shows)."""
    a, b, d = (x.astype(np.int32)[:RASTER_LINES] for x in window3(W))
    cm = np.abs(2 * b - a - d)
    rm = np.abs(a - d)
    out = {}
    for cs, ls in VARIANTS:
        out[(cs, ls)] = (int(cm[::ls, ::cs].sum()), int(rm[::ls, ::cs].sum()))
    return out


def rig_ratio(W):
    """comb_metric.py's ratio (the rig gate's definition of "combed": > 1) on luma."""
    import comb_metric
    m = comb_metric.metric(W.astype(np.float64))
    return None if m is None else float(m[1])


def weave(top, bot):
    H = top.shape[0] + bot.shape[0]
    W = np.empty((H, top.shape[1]), np.uint8)
    W[0::2] = top
    W[1::2] = bot
    return W


def fields(Y, first_bot):
    """(first field, second field, first field's parity) of a woven store."""
    t, b = Y[0::2], Y[1::2]
    return (b, t, 1) if first_bot else (t, b, 0)


# ---------------------------------------------------------------- per-store features

def store_features(prev, cur, nxt, fo_prev, fo, fo_next):
    """Everything the FSM and the scores need about store n, computed once:
    in-store weave, the two cross-store weaves (prev / next), the same-parity differences."""
    f1, f2, p1 = fields(cur, fo)
    feat = {"in": observe(cur), "rin": rig_ratio(cur)}
    # refresh 0: the first field with the previous store's second field
    if prev is not None and fo_prev == fo:
        q1, q2, _ = fields(prev, fo_prev)
        Wp = weave(f1, q2) if p1 == 0 else weave(q2, f1)
        feat["prev"] = observe(Wp)
        feat["rprev"] = rig_ratio(Wp)
        feat["d1"] = float(np.abs(f1.astype(np.int16) - q1).mean())     # first vs first
        feat["d2"] = float(np.abs(f2.astype(np.int16) - q2).mean())     # second vs second
    # refresh 1: the second field with the next store's first field
    if nxt is not None and fo_next == fo:
        n1, _n2, _ = fields(nxt, fo_next)
        Wn = weave(n1, f2) if p1 == 0 else weave(f2, n1)
        feat["next"] = observe(Wn)
        feat["rnext"] = rig_ratio(Wn)
    return feat


# ---------------------------------------------------------------- the window cut + decode

def main_clip(iso_path):
    import umd_clpi
    import umd_iso
    import umd_playlist
    with umd_iso.UmdIso(iso_path) as iso:
        pl = umd_playlist.from_iso(iso)
        it = pl["playlists"][umd_playlist.main_playlist(pl)]["items"][0]
        clip = int(it["clip_name"])
        ep = umd_clpi.video_map(umd_clpi.from_iso(iso, clip))
    return clip, ep


def cut_window(iso_path, frac, packs):
    """The main title's video ES from the EP entry at `frac` of its clip, `packs` packs, whole
    access units (umd_census.py's mid-clip window, at a chosen fraction)."""
    import psmf_ref
    import umd_census
    clip, ep = main_clip(iso_path)
    src = psmf_ref.Source(iso_path, clip)
    try:
        w0 = ep[min(len(ep) - 1, int(frac * len(ep)))][2] if ep else 0
        a0 = src.start + w0 * SEC
        end = min(src.end, a0 + packs * SEC)
        r = psmf_ref.parse(src.mm, a0, end)
        es, _ = psmf_ref.es(src.mm, r, "video")
        if end < src.end:
            es = umd_census.trim_to_aus(es)
    finally:
        src.close()
    return es


TRACE_RE = re.compile(r"\]\s+\d+\s+(\w+)\s+[01]+\s+=\s+(-?\d+)")


def trace_pictures(path):
    """Per coded picture in decode order: (field_pic_flag, bottom_field_flag, pic_struct)."""
    r = subprocess.run(["ffmpeg", "-v", "trace", "-nostdin", "-f", "h264", "-i", path, "-c", "copy",
                        "-bsf:v", "trace_headers", "-f", "null", "-"],
                       capture_output=True, text=True, errors="replace")
    pics, ps = [], None
    cur = None
    for line in r.stderr.splitlines():
        if "trace_headers" not in line:
            continue
        m = TRACE_RE.search(line)
        if not m:
            continue
        k, v = m.group(1), int(m.group(2))
        if k == "pic_struct":
            ps = v
        elif k == "first_mb_in_slice":
            cur = {"field": 0, "bottom": 0, "ps": ps, "first": v == 0}
            if v == 0:
                pics.append(cur)
        elif k == "field_pic_flag" and cur is not None and cur["first"]:
            cur["field"] = v
        elif k == "bottom_field_flag" and cur is not None and cur["first"]:
            cur["bottom"] = v
    return pics


def probe(path):
    """(width, height, [top_field_first per output frame]) in output (display) order."""
    r = subprocess.run(["ffprobe", "-v", "error", "-f", "h264", "-i", path, "-select_streams", "v",
                        "-show_entries", "stream=width,height:frame=top_field_first", "-of", "json"],
                       capture_output=True, text=True, check=True)
    j = json.loads(r.stdout)
    st = j["streams"][0]
    return st["width"], st["height"], [int(f.get("top_field_first", 0)) for f in j["frames"]]


def idet_repeats(path):
    """ffmpeg idet's repeated-field verdict per output frame: '.', 'T' or 'B' -- the truth."""
    with tempfile.NamedTemporaryFile(suffix=".txt") as t:
        subprocess.run(["ffmpeg", "-v", "error", "-nostdin", "-f", "h264", "-i", path, "-fps_mode",
                        "passthrough", "-vf", "idet,metadata=mode=print:file=" + t.name, "-f", "null", "-"],
                       capture_output=True, check=True)
        txt = open(t.name).read()
    return "".join({"neither": ".", "top": "T", "bottom": "B"}[v]
                   for v in re.findall(r"repeated\.current_frame=(\w+)", txt))


def decode_luma(path, w, h):
    """Every output frame's luma (display order), streamed off a pipe."""
    p = subprocess.Popen(["ffmpeg", "-v", "quiet", "-nostdin", "-f", "h264", "-i", path, "-fps_mode",
                          "passthrough", "-f", "rawvideo", "-pix_fmt", "gray", "-"],
                         stdout=subprocess.PIPE)
    fs = w * h
    while True:
        b = p.stdout.read(fs)
        if len(b) < fs:
            break
        yield np.frombuffer(b, np.uint8).reshape(h, w)
    p.wait()


def window_features(es):
    """The per-store feature list of one window (display order) + its stream facts."""
    with tempfile.NamedTemporaryFile(suffix=".264") as t:
        t.write(es)
        t.flush()
        pics = trace_pictures(t.name)
        w, h, tff = probe(t.name)
        rep = idet_repeats(t.name)
        fo = [1 - x for x in tff]                       # first field bottom
        feats = []
        prev = cur = None
        n = 0
        for Y in decode_luma(t.name, w, h):
            Y = Y.copy()
            if cur is not None:
                feats.append(store_features(prev, cur, Y, fo[n - 2] if n >= 2 else None,
                                            fo[n - 1], fo[n] if n < len(fo) else None))
            prev, cur = cur, Y
            n += 1
        if cur is not None:
            feats.append(store_features(prev, cur, None, fo[n - 2] if n >= 2 else None, fo[n - 1], None))
    nf = sum(1 for p in pics if p["field"])
    facts = {"pictures": len(pics), "field_pictures": nf,
             "frame_pictures": len(pics) - nf,
             "ps": sorted(set(p["ps"] for p in pics if p["ps"] is not None)),
             "stores": len(feats), "w": w, "h": h, "fo": fo[:len(feats)], "idet": rep[:len(feats)]}
    return feats, facts


def _pack(feats):
    """Features -> JSON-able (variant keys as "cs,ls")."""
    out = []
    for f in feats:
        g = {}
        for k, v in f.items():
            g[k] = {"%d,%d" % kk: list(vv) for kk, vv in v.items()} if isinstance(v, dict) else v
        out.append(g)
    return out


def _unpack(feats):
    out = []
    for f in feats:
        g = {}
        for k, v in f.items():
            g[k] = ({tuple(int(x) for x in kk.split(",")): tuple(vv) for kk, vv in v.items()}
                    if isinstance(v, dict) else v)
        out.append(g)
    return out


def load_window(iso_path, frac, packs, cache=None):
    """One window's features, from the cache when present (keyed by the image's name, size,
    the fraction and the pack count)."""
    key = None
    if cache:
        st = os.stat(iso_path)
        key = hashlib.sha1(("%s|%d|%.4f|%d|%s" % (os.path.basename(iso_path), st.st_size, frac, packs,
                                                  VARIANTS)).encode()).hexdigest()[:16]
        fn = os.path.join(cache, key + ".json")
        if os.path.exists(fn):
            j = json.load(open(fn))
            return _unpack(j["feats"]), j["facts"]
    es = cut_window(iso_path, frac, packs)
    feats, facts = window_features(es)
    if cache:
        os.makedirs(cache, exist_ok=True)
        json.dump({"feats": _pack(feats), "facts": facts}, open(os.path.join(cache, key + ".json"), "w"))
    return feats, facts


# ---------------------------------------------------------------- truth (never C)

def truth(idet, fo):
    """Film-frame boundaries from idet's repeated-field flags, under the telecine's own
    structure (every film frame a run of 2 or 3 contiguous fields).

    Fields in display order: store n's first field is g[2n], its second g[2n+1]. A repeat at
    store n of parity P says g[j] == g[j-2] for the field j of that parity, so g[j-2..j] is one
    3-field run. Between two 3-runs the fields are 2-runs only if their count is 0, 2 or 4
    (3:2 has one 2-run between, 2:3:3:2 none or two); any other gap -- a static stretch where
    idet sees nothing, an edit, an irregular cadence -- leaves its boundaries unknown.

    Returns split[n] True / False / None: store n's two fields are two film frames. (Built on
    2- and 3-field runs, it cannot test the matching rule itself: score() measures that.)"""
    N = len(idet)
    nb = 2 * N + 1
    b = [None] * nb                     # b[j]: a boundary between g[j-1] and g[j]
    runs = []
    for n, c in enumerate(idet):
        if c == ".":
            continue
        P = 0 if c == "T" else 1
        j = 2 * n if P == fo[n] else 2 * n + 1
        if j >= 2:
            runs.append(j)
    for j in runs:                      # inside a 3-run: no boundary
        b[j - 1] = b[j] = False
    for j1, j2 in zip(runs, runs[1:]):
        s2 = j2 - 2                     # the next run's first field
        m = s2 - (j1 + 1)               # fields strictly between the two runs
        if j2 - 2 <= j1:                # overlapping runs (a 4-field repeat): not 3:2
            for j in range(max(1, j1 - 2), min(nb, j2 + 1)):
                b[j] = None
            continue
        if m in (0, 2, 4):
            for j in range(j1 + 1, s2 + 1, 2):
                b[j] = True
            for j in range(j1 + 2, s2, 2):
                b[j] = False
    return [b[2 * n + 1] for n in range(N)]


def own_repeats(feats, fo):
    """The cross-check of idet: a store's first (second) field repeats when its mean difference
    from the previous store's first (second) field is under a quarter of the other parity's (and
    that one moved). Strict on purpose: it may miss a repeat, it should never invent one."""
    out = []
    for k, f in enumerate(feats):
        c = "."
        if "d1" in f:
            d1, d2 = f["d1"], f["d2"]
            if d1 < 0.25 * d2 and d2 > 0.5:
                c = "B" if fo[k] else "T"
            elif d2 < 0.25 * d1 and d1 > 0.5:
                c = "T" if fo[k] else "B"
        out.append(c)
    return "".join(out)


# ---------------------------------------------------------------- the cadence FSM

# Every constant's source is the census (docs/telecine.md S4); ratios are in eighths so the RTL
# compares C * 8 against R * T8 -- a shift and a comparator.
PARAMS = dict(
    variant=(8, 1),     # the observable's subsample: every 8th dot of every line
    comb8=20,           # in-store C / R >= 2.5: a COMBED pair (acquisition evidence)
    clean8=10,          # in-store C / R <= 1.25: a CLEAN pair
    brk8=12,            # under a lock, any shown weave C / R >= 1.5 is a contradiction
    floor16=16,         # and a COMBED pair needs C >= 1.0 a sampled dot (real motion)
    up=1,               # + per agreeing informative cycle
    dn_soft=2,          # - an unsure pair where the cadence says clean
    engage=8,           # locked at conf >= 8 cycles
    conf_max=15,
    fallback="bob",     # unlocked: what is shown ("bob" or "weave"); the measure is the same
)


def classify(C, R, npix, P):
    if C * 8 >= R * P["comb8"] and C * 16 >= npix * P["floor16"]:
        return "C"
    if C * 8 <= R * P["clean8"]:
        return "c"
    return "?"


def npix_of(h, w, variant):
    """The dots the observable sums: the raster's lines of the picture, every ls-th, by every
    cs-th column (disp_ctl: min(16 hf, 480) x 2 w_mbs for the chosen (8, 1))."""
    cs, ls = variant
    h = min(h, RASTER_LINES)
    return ((h + ls - 1) // ls) * ((w + cs - 1) // cs)


# What a refresh shows (umd/film_lock.sv's `show`):
FALLBACK, IN, PREV, NEXT, BOB = 0, 1, 2, 3, 4
SHOW_NAMES = {IN: "in", PREV: "prev", NEXT: "next", BOB: "bob"}


class FilmLock(object):
    """The cadence lock, one step per pickup (umd/film_lock.sv, bit for bit; its bench's golden).

    At every pickup the display makes (disp_ctl, line 500 of a 480p refresh; never on a frozen
    one), in this order:
      1. the evidence of the refresh just shown: (mv, C, R), the reader's sums over what it
         fetched (disp_reader, complete at line 480). Under the lock, any shown weave (IN, PREV,
         NEXT -- not a bobbed field) at C >= brk R breaks it at once. Unlocked (after that), an
         in-store refresh (FALLBACK, IN) records the store's class.
      2. a new store (pick): acquisition on the store just left, with its last in-store class;
         then the slot steps -- if the new store continues the pairs (np: a field pair after a
         field pair, the same field order and size, the same item), else everything resets.
      3. the coming refresh: locked at slot 0 / 1, the first field with the previous store's
         second (PREV, if prev_ok), the second with the next store's first (NEXT, if next_ok),
         else that field bobbed (BOB); locked at slot 2-4, the store woven (IN); unlocked,
         FALLBACK -- the Deinterlace setting (T2)."""

    def __init__(self, P=None, npix=43200):
        self.P = dict(PARAMS, **(P or {}))
        self.npix = npix
        self.reset()

    def reset(self):
        self.locked, self.conf, self.slot = False, 0, None
        self.hit = self.bad = False
        self.prev_cls = self.last_cls = None
        self.show = FALLBACK

    def step(self, pick, np_, first, prev_ok, next_ok, mv, C, R):
        P = self.P
        cls = None
        # 1. the evidence of the refresh just shown
        if mv:
            cls = classify(C, R, self.npix, P)
            if self.locked and self.show in (IN, PREV, NEXT) and C * 8 >= R * P["brk8"]:
                self.locked, self.conf, self.slot = False, 0, None
            if not self.locked and self.show in (FALLBACK, IN):
                self.last_cls = cls
        # 2. a new store
        if pick:
            if not self.locked and self.last_cls is not None:
                c = self.last_cls
                if self.slot is None:
                    if c == "C" and self.prev_cls == "C":
                        self.slot, self.conf, self.hit, self.bad = 1, 0, True, False   # the two: slots 0, 1
                elif self.slot in (0, 1):
                    self.hit = self.hit or c == "C"
                elif c == "C":
                    self.conf, self.slot = 0, None    # a combed pair where the cadence says clean
                elif c == "?":
                    self.bad = True
                    self.conf = max(0, self.conf - P["dn_soft"])
                if self.slot == 4:
                    if self.hit and not self.bad:
                        self.conf = min(P["conf_max"], self.conf + P["up"])
                    if self.conf >= P["engage"]:
                        self.locked = True
                self.prev_cls = c
            else:
                self.prev_cls = None
            self.last_cls = None
            if np_:
                if self.slot is not None:
                    self.slot = (self.slot + 1) % 5
                    if self.slot == 0:
                        self.hit = self.bad = False
            else:
                self.locked, self.conf, self.slot = False, 0, None
                self.prev_cls = None
        # 3. the coming refresh
        if self.locked and self.slot in (0, 1):
            self.show = (PREV if prev_ok else BOB) if first else (NEXT if next_ok else BOB)
        elif self.locked:
            self.show = IN
        else:
            self.show = FALLBACK
        return self.show


def run_fsm(feats, P=None, h=480, w=720, vectors=None):
    """The cadence lock over a window's stores, two refreshes a store (the first field, then the
    second), as the display runs it (FilmLock: the evidence of each refresh steers the next).
    A store continues the pairs (np) when it has a previous one of the same field order.

    Returns one row per refresh: dict(store, r, show, shown, partner, locked, slot, conf, C, R,
    cls) -- what it showed and under which state, and the sums of what the reader fetched.
    `vectors`, a list, collects each step's inputs and outputs (umd/film_lock.sv's bench)."""
    P = dict(PARAMS, **(P or {}))
    v = tuple(P["variant"])
    npix = npix_of(h, w, v)
    fl = FilmLock(P, npix)
    rows = []
    mv, C, R = False, 0, 0
    for k, f in enumerate(feats):
        for r in (0, 1):
            ins = dict(pick=r == 0, np_="prev" in f, first=r == 0, prev_ok="prev" in f,
                       next_ok="next" in f, mv=mv, C=C, R=R)
            show = fl.step(**ins)
            if vectors is not None:
                vectors.append((ins, npix, dict(show=show, locked=fl.locked,
                                                slot=7 if fl.slot is None else fl.slot, conf=fl.conf)))
            key = {PREV: "prev", NEXT: "next"}.get(show, "in")
            C, R = f[key][v]
            mv = True
            shown = SHOW_NAMES.get(show) or (P["fallback"] if P["fallback"] != "weave" else "in")
            partner = k - 1 if show == PREV else k + 1 if show == NEXT else None
            rows.append(dict(store=k, r=r, show=show, shown=shown, partner=partner, locked=fl.locked,
                             slot=fl.slot, conf=fl.conf, C=C, R=R, cls=classify(C, R, npix, P)))
    return rows


def walk_vectors(feats, rng, P=None, h=480, w=720, perturb=True):
    """umd/film_lock.sv's bench stimulus: FilmLock driven over a window's stores as the display
    may run it -- with perturb, a store held 1-4 refreshes (a starve, a late pickup: the parity
    alternates), the next store absent (the queue's head missing), a store that breaks the pairs
    (a frame, an item change), a refresh without evidence (the window, il), and a clr (a seek).
    Returns [(op, ins, npix, outs)]: op "S" a step, "C" a clr (ins / outs then the reset)."""
    P = dict(PARAMS, **(P or {}))
    v = tuple(P["variant"])
    npix = npix_of(h, w, v)
    fl = FilmLock(P, npix)
    out = []
    mv, C, R = False, 0, 0
    for k, f in enumerate(feats):
        if perturb and (k == (2 * len(feats)) // 3 or rng.random() < 0.004):
            fl.reset()
            out.append(("C", None, npix, dict(show=fl.show, locked=fl.locked, slot=7, conf=fl.conf)))
            mv = False
        nref = 2
        if perturb:
            u = rng.random()
            nref = 1 if u < 0.03 else 3 if u < 0.06 else 4 if u < 0.07 else 2
        np_ = "prev" in f and not (perturb and rng.random() < 0.01)
        for r in range(nref):
            first = (r % 2) == 0
            next_ok = "next" in f and not (perturb and rng.random() < 0.05)
            prev_ok = np_ and "prev" in f
            ins = dict(pick=r == 0, np_=np_, first=first, prev_ok=prev_ok, next_ok=next_ok,
                       mv=mv, C=C, R=R)
            show = fl.step(**ins)
            out.append(("S", ins, npix, dict(show=show, locked=fl.locked,
                                             slot=7 if fl.slot is None else fl.slot, conf=fl.conf)))
            key = {PREV: "prev", NEXT: "next"}.get(show, "in")
            if key not in f:
                key = "in"
            C, R = f[key][v]
            mv = not (perturb and rng.random() < 0.01)
    return out


def write_vectors(path, vec):
    """One line a step: op pick np first prev_ok next_ok mv C R npix show locked slot conf."""
    with open(path, "w") as fo:
        for op, ins, npix, o in vec:
            if op == "C":
                fo.write("C 0 0 0 0 0 0 0 0 %d %d %d %d %d\n" % (npix, o["show"], o["locked"], o["slot"], o["conf"]))
            else:
                fo.write("S %d %d %d %d %d %d %d %d %d %d %d %d %d\n" % (
                    ins["pick"], ins["np_"], ins["first"], ins["prev_ok"], ins["next_ok"], ins["mv"],
                    ins["C"], ins["R"], npix, o["show"], o["locked"], o["slot"], o["conf"]))
    return len(vec)


# ---------------------------------------------------------------- scores

SKIP = 30           # the window's first stores: the open GOP before the cut decodes with gaps


def shown_ratio(f, shown):
    """The rig gate's comb ratio (comb_metric.py, > 1 = combed) of what a refresh showed."""
    if shown == "bob":
        return 0.0
    return f.get({"in": "rin", "prev": "rprev", "next": "rnext"}[shown]) or 0.0


def score(feats, facts, rows, skip=SKIP):
    """One window's figures: combed refreshes (Weave / the model / the oracle), the lock's
    coverage, its breaks, and the truth's verdicts on what the model matched."""
    split = truth(facts["idet"], facts["fo"])
    rr = [x for x in rows if x["store"] >= skip]
    n = len(rr)
    out = dict(refreshes=n)
    if not n:
        return out
    weave = sum(1 for x in rr if (feats[x["store"]]["rin"] or 0) > 1)
    model = sum(1 for x in rr if shown_ratio(feats[x["store"]], x["shown"]) > 1)
    orac = 0
    for x in rr:
        f = feats[x["store"]]
        alt = f.get("rprev" if x["r"] == 0 else "rnext")
        best = min(f["rin"] or 0, alt if alt is not None else 1e9)
        orac += best > 1
    locked = sum(1 for x in rr if x["locked"])
    breaks = sum(1 for a, b in zip(rr, rr[1:]) if a["locked"] and not b["locked"])
    first = next((x["store"] for x in rows if x["locked"]), None)
    m_whole = m_split = m_unknown = 0
    for x in rr:
        if x["shown"] in ("prev", "next"):
            s = split[x["store"]]
            if s is None:
                m_unknown += 1
            elif s:
                m_split += 1
            else:
                m_whole += 1
    ks = [k for k in range(skip, len(split)) if split[k] is not None]
    rsplit = [k for k in ks if split[k] and (feats[k]["rin"] or 0) > 1
              and feats[k].get("rprev") is not None and feats[k].get("rnext") is not None]
    own = own_repeats(feats, facts["fo"])
    xc = [(own[k], facts["idet"][k]) for k in range(skip, len(feats))]
    out.update(
        weave_combed=weave, model_combed=model, oracle_combed=orac,
        locked=locked, breaks=breaks, first_lock=first,
        matched_split=m_split, matched_whole=m_whole, matched_unknown=m_unknown,
        truth_known=len(ks), truth_split=sum(1 for k in ks if split[k]),
        # the matching rule, measured: split pairs combed in-store whose two rule weaves read clean
        rule_split=len(rsplit), rule_clean=sum(1 for k in rsplit if max(feats[k]["rprev"],
                                                                       feats[k]["rnext"]) <= 1),
        rule_bad=[k for k in rsplit if max(feats[k]["rprev"], feats[k]["rnext"]) > 1],
        locked_combed=sum(1 for x in rr if x["locked"]
                          and shown_ratio(feats[x["store"]], x["shown"]) > 1),
        repeats=sum(1 for c in facts["idet"][skip:] if c != "."),
        xcheck_agree=sum(1 for a, b in xc if a == b),
        xcheck_conflict=sum(1 for a, b in xc if a != b and a != "." and b != "."),
        stores=len(feats) - skip)
    return out


def classify_title(facts, sc):
    """The census family (docs/umd_video_format.md): frame pictures are soft 3:2 / progressive
    (the deinterlacer never touches them); field pairs are hard 3:2 when idet repeats a field on
    >= 25 % of stores (3:2 itself: 40 %), true video under 5 %."""
    if facts["field_pictures"] == 0:
        return "frames (ps %s)" % ",".join(str(p) for p in facts["ps"])
    if facts["frame_pictures"]:
        return "mixed"
    rep = sc["repeats"] / max(1, sc["stores"])
    known = sc["truth_known"] / max(1, sc["stores"])
    if rep >= 0.25:
        return "hard 3:2 clean" if known >= 0.9 else "hard 3:2 noisy"
    if rep < 0.05:
        return "video"
    return "irregular"


def fmt(sc):
    n = max(1, sc["refreshes"])
    return ("combed: weave %5.1f%% model %5.1f%% oracle %5.1f%% | locked %5.1f%% breaks %3d first %s | "
            "matched split/whole/? %d/%d/%d | rule: %d of %d clean | combed when locked %.2f%%" % (
                100.0 * sc["weave_combed"] / n, 100.0 * sc["model_combed"] / n,
                100.0 * sc["oracle_combed"] / n, 100.0 * sc["locked"] / n, sc["breaks"],
                sc["first_lock"], sc["matched_split"], sc["matched_whole"], sc["matched_unknown"],
                sc["rule_clean"], sc["rule_split"], 100.0 * sc["locked_combed"] / max(1, sc["locked"])))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("iso", nargs="?")
    ap.add_argument("--frac", type=float, action="append")
    ap.add_argument("--packs", type=int, default=6000)
    ap.add_argument("--cache")
    ap.add_argument("--rows", action="store_true", help="print every refresh's row")
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--vectors", metavar="DIR", help="umd/film_lock.sv's bench vectors (run_film_lock.sh)")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if a.vectors:
        return bench_vectors(a.vectors, a.cache)
    if not a.iso:
        ap.error("an image, or --selftest")
    for fr in a.frac or [0.45]:
        feats, facts = load_window(a.iso, fr, a.packs, a.cache)
        rows = run_fsm(feats, h=facts["h"], w=facts["w"])
        sc = score(feats, facts, rows)
        if a.rows:
            for x in rows:
                print("%5d r%d %-4s slot %s %s C %9d R %9d %s" % (
                    x["store"], x["r"], x["shown"], x["slot"], "L" if x["locked"] else "-",
                    x["C"], x["R"], x["cls"]))
        print("%s @%.2f [%s] %s" % (os.path.basename(a.iso), fr, classify_title(facts, sc), fmt(sc)))
    return 0


# ---------------------------------------------------------------- synthetic sequences

def _picture(t, h, w, seed=0):
    """A textured picture panned t dots: smooth in both directions with hard vertical bars,
    where a horizontal pan combs (comb_metric.py's self-test picture, smaller)."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float64)
    xx = xx + t
    v = (110 + 40 * np.sin(xx / 7 + seed) * np.cos(yy / 11) + 50 * (((xx + 3 * seed) // 12) % 2))
    return np.clip(v, 0, 255).astype(np.uint8)


def synth(kind, n, first_bot=0, phase=0, h=96, w=128, edit=None):
    """Stores of a synthetic field sequence (display order) and their truth:
      "film"   23.976 film, 3:2 into fields (runs 2, 3, 2, 3, ... from `phase`), 4 dots a frame
      "twos"   film drawn on twos (each drawing held for two film frames), 3:2 as "film"
      "video"  59.94 fields, each its own instant (2 dots a field)
      "static" one picture
      "black"  a flat picture (a fade's end: C = R = 0, where only the motion floor is not COMBED)
    edit = (store, new phase): from that store the film is another scene with another cadence.
    Returns (stores, fo, idet, split): idet as ffmpeg's would read the content (a repeat where a
    field's picture equals the same-parity field of the previous store), split per store."""
    if kind == "video":
        fid = list(range(2 * n))
        pic = {j: _picture(2 * j, h, w) for j in fid}
    elif kind == "black":
        fid = [0] * (2 * n)
        pic = {0: np.full((h, w), 16, np.uint8)}
    else:
        runs = [2, 3] * (n + 5)
        f = 0
        # phase 0..4: where in the 2-3 pattern the sequence starts (a 5-field cycle)
        seq = []
        for r in runs:
            seq += [f] * r
            f += 1
        seq = seq[phase % 5:]
        fid = seq[:2 * n]
        if edit:
            e, ph2 = edit
            seq2 = []
            g = 1000
            for r in runs:
                seq2 += [g] * r
                g += 1
            seq2 = seq2[ph2 % 5:]
            fid = fid[:2 * e] + seq2[:2 * n - 2 * e]
        pic = {}
        for i in set(fid):
            if kind == "static":
                pic[i] = _picture(0, h, w)
            else:
                base, sd = (i - 1000, 1) if i >= 1000 else (i, 0)
                d = (base // 2) if kind == "twos" else base
                pic[i] = _picture(4 * d, h, w, sd)
    stores, fo, idet, split = [], [], [], []
    for s in range(n):
        j1, j2 = 2 * s, 2 * s + 1
        p1 = (first_bot + j1) & 1
        Y = np.empty((h, w), np.uint8)
        Y[p1::2] = pic[fid[j1]][p1::2]
        Y[1 - p1::2] = pic[fid[j2]][1 - p1::2]
        stores.append(Y)
        fo.append(first_bot)
        split.append(fid[j1] != fid[j2] if kind != "video" else None)
        rep = "."
        if s and kind not in ("static", "black"):
            if np.array_equal(pic[fid[j1]][p1::2], pic[fid[j1 - 2]][p1::2]):
                rep = "B" if p1 else "T"
            elif np.array_equal(pic[fid[j2]][1 - p1::2], pic[fid[j2 - 2]][1 - p1::2]):
                rep = "T" if p1 else "B"
        idet.append(rep)
    return stores, fo, "".join(idet), split


def synth_window(kind, n, **kw):
    """synth() as a window: (feats, facts) exactly as load_window() returns for a disc."""
    stores, fo, idet, split = synth(kind, n, **kw)
    feats = []
    for k in range(n):
        feats.append(store_features(stores[k - 1] if k else None, stores[k],
                                    stores[k + 1] if k + 1 < n else None,
                                    fo[k - 1] if k else None, fo[k], fo[k + 1] if k + 1 < n else None))
    h, w = stores[0].shape
    facts = dict(pictures=2 * n, field_pictures=2 * n, frame_pictures=0, ps=[1, 2], stores=n,
                 w=w, h=h, fo=fo, idet=idet)
    return feats, facts, split


# the library windows of the film_lock bench (with $UMD_ISO_DIR): a clean 3:2 title, an animated
# one, and a true-video control
LIB_VECTORS = (("tdk", "The Dark Knight (Europe Import) (PSP Video).iso", 0.45),
               ("simpsons", "The Simpsons Movie (Europe Import) (PSP Video).iso", 0.45),
               ("office", "The Office - The Complete First Series - Disc 01 (2001).ISO", 0.45))


def bench_vectors(d, cache=None):
    """run_film_lock.sh's stimulus: one file per arm, each the model's walk (perturbed) over a
    synthetic sequence, and with $UMD_ISO_DIR over three library windows -- one unperturbed walk
    (the display's own two refreshes a store) and one perturbed."""
    os.makedirs(d, exist_ok=True)
    rng = np.random.default_rng(80)
    arms = []
    syn = [("syn_film_f0", "film", dict(first_bot=0)), ("syn_film_f1_p3", "film", dict(first_bot=1, phase=3))]
    # an edit at every phase of the new cadence: its first contradiction lands on a matched weave
    # or an in-store one, at either refresh
    syn += [("syn_film_e90_%d" % ph, "film", dict(edit=(90, ph))) for ph in range(5)]
    syn += [("syn_twos", "twos", {}), ("syn_video", "video", {}), ("syn_static", "static", {}),
            ("syn_black", "black", {})]
    for nm, kind, kw in syn:
        feats, facts, _ = synth_window(kind, 240, **kw)
        for pert in (False, True):
            vec = walk_vectors(feats, rng, h=facts["h"], w=facts["w"], perturb=pert)
            arms.append((nm + ("_p" if pert else ""), vec))
    iso_dir = os.environ.get("UMD_ISO_DIR")
    lib = 0
    for tag, name, fr in LIB_VECTORS:
        path = os.path.join(iso_dir or "", name)
        if not iso_dir or not os.path.exists(path):
            continue
        feats, facts = load_window(path, fr, 6000, cache)
        for pert in (False, True):
            vec = walk_vectors(feats, rng, h=facts["h"], w=facts["w"], perturb=pert)
            arms.append(("lib_%s%s" % (tag, "_p" if pert else ""), vec))
        lib += 1
    for nm, vec in arms:
        write_vectors(os.path.join(d, nm + ".vec"), vec)
        locks = sum(1 for op, _i, _n, o in vec if op == "S" and o["locked"])
        shows = sorted(set(o["show"] for op, _i, _n, o in vec if op == "S"))
        print("  %-24s %6d steps, %5d locked, shows %s" % (nm, len(vec), locks, shows))
    print("telecine_ref: %d vector files (%d library windows%s)" % (
        len(arms), lib, "" if lib else "; SKIP: library arms (UMD_ISO_DIR)"))
    return 0


def selftest():
    """The synthetic arms in one line each (tools/tests/test_telecine_ref.py scores them)."""
    ok = True
    for kind, kw in (("film", dict(first_bot=0)), ("film", dict(first_bot=1, phase=2)),
                     ("twos", {}), ("video", {}), ("static", {}),
                     ("film", dict(edit=(60, 3)))):
        feats, facts, _split = synth_window(kind, 120, **kw)
        rows = run_fsm(feats, h=facts["h"], w=facts["w"])
        sc = score(feats, facts, rows, skip=0)
        print("  %-6s %-28s %s" % (kind, kw, fmt(sc)))
        if kind in ("video", "static"):
            ok = ok and sc["locked"] == 0               # never a lock without film evidence
        elif kind == "twos":
            ok = ok and sc["model_combed"] == 0 and sc["matched_whole"] == 0
        elif "edit" in kw:
            ok = ok and sc["model_combed"] <= 1 and sc["breaks"] == 1 and rows[-1]["locked"]
        else:
            ok = ok and sc["locked"] > 0 and sc["matched_whole"] == 0 and sc["model_combed"] == 0
    print("PASS: telecine_ref selftest" if ok else "FAIL: telecine_ref selftest")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
