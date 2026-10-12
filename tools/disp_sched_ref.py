#!/usr/bin/env python3
"""disp_sched_ref.py -- the display scheduler's reference (roadmap P5e, docs/display.md
S7): which store the 480p raster shows at every refresh, and with which field parity,
given the output queue's records (umd/recon_out.sv) -- exact to the 90 kHz tick -- and
the stimulus scenarios bench/umd/disp_sched_tb.sv plays (tools-side generator).

FIELD MATCHING (Forgejo fj#80, docs/telecine.md S5; 480p): at every pickup tools/telecine_ref.py's
FilmLock steps on the evidence of the refresh just shown -- the comb sums of the luma the reader
fetched (a record's `pic`, or black: the bench's unwritten stores read 0) -- and picks how the coming
refresh shows: in-store, or the shown field woven with the previous store's other field (the
previous store HELD: a field pair taken after a field pair of the same field order, size and item
keeps the outgoing store instead of releasing it, and releases the one it held; a resync drops the
hold) or with the queue's head. Each refresh's line carries (match, partner store, film kernel).

THE RULES (written from the spec and MiSTer_DVD's scheduler notes, not from the RTL):

  duration   a store lasts n_ticks clock ticks (Table E-6 DeltaTfiDivisor): a frame 2,
             or its pic_struct's 0/3/4 -> 2, 5/6 -> 3, 7 -> 4, 8 -> 6; a field 1 (a pair
             1 + 1). A tick is num_units_in_tick / time_scale s (C-1): field_q3 =
             720000 * nuit // ts eighth-ticks of 90 kHz (Q3; 4004 / 240000 -> 12012,
             5005 / 240000 -> 15015). No VUI timing (or ts 0): 12012 (59.94) and a flag.
             A quotient >= 2^24 is clamped (a tick over 23 s) and flagged. A pic_struct
             that does not fit the store (1/2 on a frame, 0/3-8 on a field, 9-15) takes
             the default and is flagged.
  time       STC counts 90 kHz ticks, one per 300 clk_sys cycles, phased to the raster:
             P = 0 at the first (h 0, v 0) after reset, ticks at P = 300 m (m >= 1).
             A refresh is 858 x 525 = 450,450 cycles (1501.5 ticks). Refresh k's
             decision is evaluated with the STC of cycle P_eval(k) = 450450 k + 499 x 858
             and taken at P_pick(k) = 450450 k + 500 x 858 (vertical blanking: after the
             last line's fetch, before line 0's). An anchor at P_pick sets STC there; it
             then counts the ticks at P_pick+1 .. Q-1 as seen in cycle Q.
  due        the head record (if present at P_eval) is due when STC >= want - 750
             (half a refresh), want = its PTS when tagged (a pair's second-field PTS
             minus one tick when only that one is), else the timeline's next PTS.
  anchor     the first head ever, or a TAGGED head that has jumped: more than one frame
             (2 ticks) BEHIND the timeline, more than 0.5 s (45000) AHEAD of it, or
             more than 2.7 s (243000) late -- re-anchors STC to it (an untagged first
             head anchors at 0). Lateness below that is NOT a jump: a late picture is
             simply shown at once (MiSTer_DVD's HW round B).
  lone PTS   (fix/film-timing, docs/display.md S10) a TAGGED head more than half a refresh
             and at most 0.5 s AHEAD of the timeline or BEHIND it (750 < |PTS - next| <=
             45000; behind: fix/lone-early, the maintainer's rule B), not late past LATE_MAX,
             is DISBELIEVED -- taken as untagged, on the timeline -- unless
             the previous tag taken was disbelieved too: the next tag is always believed
             (a real gap is waited out one tag later). The discs carry lone PES PTS 5-8
             ticks late on one GOP-opening PES (1-8 in the census, 206 of 208 ahead), the
             next tag back on the old timeline (both the pic_struct timeline and the SEI's
             HRD delays disagree with it): believing it held a picture ~3x and then
             re-anchored the STC back. The edge is half a refresh, not a frame: +1 tick
             held a picture one refresh too long, and +1 frame came back as a re-anchor.
             Behind (The Simpsons Movie -3 ticks, The Transporter -1 frame): believing one
             re-anchored the STC back at once, then waited on the return. A real backward
             edit under 0.5 s is corrected one tag late (the video ahead of the audio by it
             meanwhile); a larger one re-anchors at once, as before. Behind the
             timeline is unchanged (re-anchors). The flag is set by a pickup of a
             disbelieved head, cleared by a pickup of a believed tagged one, and by a
             resync; `lone` counts the disbelieved pickups.
  pickup     at P_pick, a due head is taken: the store shown until then is released,
             the timeline's next PTS = want (or the anchor) + the duration. The END
             record is taken at the first pickup it heads; the last store stays.
  parity     a field store shows parity first_bot ^ (refreshes since its pickup) & 1;
             a single field its own parity; a frame 0.
  counters   dc: the decided (store, parity) changes (a pickup, a field store's parity
             step); reanchors; late: pickups of a head that was ALREADY due at the
             previous refresh's eval (STC then >= want - 750, the same timeline: no
             anchor between) -- a missed opportunity, starved or backlogged. (A first
             draft counted STC - want > 750 at the pickup: 23.976 frames last 2.5
             refreshes, so every other one is taken ~750 ticks after its PTS -- the best
             a 59.94 raster can do -- and phase noise pushed some over; X-Men 2 read
             LT 21 a minute on the rig with the decoder ahead, 2026-09-26);
             cadence: a store held for a refresh count outside {floor, ceil} of its
             duration / 12012, judged at the next pickup when that one is contiguous
             (not an anchor, |its PTS - the timeline| < 750, no starved refresh between).

THE TRANSPORT (P6b3, docs/transport.md S2.1-S2.3; written from the plan, not the RTL):
  freeze     (pause, a seek's hold) sampled at each refresh's eval: a frozen refresh has
             no eval and no pickup, the shown field store's parity does not step, nothing
             is judged starved, and the STC does not count the ticks from that eval to the
             next (the audio gate stops on the same cycles).
  resync     a seek's discontinuity (line 2 of its refresh): every queued record is
             released unseen (the drain), the timeline is cleared (the next shown record
             anchors), the shown store stays up, and the ITEM TABLE is cleared.
  items      (P6b3i) a record's item tag is its own when it carries a PTS, else the current
             one. The table (4 entries, W events at line 5: {IN or a seek's target, OUT,
             last, skip}) starts all valid with no skip and no OUT. A head whose tag differs
             from the current one (or any after a resync) ENTERS its item: it waits until
             the item's entry is valid, then that entry's target and OUT apply:
  target     with skip, a record whose interval [t, t + duration) ends before the target +
             one tick is released unseen (the tick: a stream stores its PTS in whole ticks,
             a time extrapolated from them keeps the fraction -- a mark at a picture's
             stored PTS must not leave the picture before it on screen), t = its PTS, else
             the end of the last skipped record (none: the skip ends, the record is shown).
             The first record shown gets its t as its PTS. Without skip: shown from the first.
             The END reached inside a skip (the target past every picture) ends the display,
             the shown store kept (fix/skip-last-picture, docs/display.md S11).
  left       (P6b3i) the tags of the items the display has LEFT (set as it enters the next,
             cleared when the tag's entry is rewritten, and by a resync): the audio drops a
             left item's leftovers. stalled: 64 starved refreshes in a row (the audio's
             breaker), counted from the last pickup.
  OUT        a record whose time (its PTS, else the timeline's next) is at or after its
             item's OUT is released unseen; on the title's last item the display ends there,
             the last store held. A rewrite of the current item without a skip ends a skip.
  sh_pts     the shown store's time: `want` at its pickup.
  These judgements run as a record reaches the head (before its refresh's eval), never
  on a head the eval chose.
  480i (--il, docs/analog.md V6): a refresh is a FIELD, refresh k the raster's field of
             parity k & 1 (0 = top; refreshes counted from a top field). The cycle grid is
             unchanged (the eval / pickup sit 450,450 cycles apart on both fields). FIELD
             ORDER: a due head that is a field PAIR whose first field's parity is not the next
             field's, (k + 1) & 1, is not taken (deferred: the shown store held one more
             refresh, `pdefer`); it is evaluated again at refresh k + 1, where an anchoring
             head anchors -- a field later, in phase. A LATE head (already due at the previous
             refresh: a starve's backlog) is not deferred -- it is taken at once, so an overdue
             queue still drains a store a refresh. Frames and single fields are never deferred.
             The FREEZE is sampled only at a top field's eval (even k), so a pause spans whole
             frames and leaves the timeline's phase to the raster unchanged.

    disp_sched_ref.py --scenario NAME --out STEM     the stimulus + the expected refreshes
    disp_sched_ref.py --list
"""
import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import telecine_ref  # noqa: E402

FRAME = 450450
P_EVAL = 499 * 858
P_PICK = 500 * 858
HALF = 750
REF_Q3 = 12012
FWD_MAX = 45000
LATE_MAX = 243000
DIV = {0: 2, 3: 2, 4: 2, 5: 3, 6: 3, 7: 4, 8: 6}
Q3_MAX = (1 << 24) - 1
SKIP_TOL_Q3 = 8                # the skip's tolerance: one tick (stored PTS are whole ticks)


def ticks_between(a, b):
    """ticks at P = 300 m, m >= 1, with a <= P <= b"""
    if b < a:
        return 0
    lo = max(1, -(-a // 300))
    hi = b // 300
    return max(0, hi - lo + 1)


class Rec(object):
    FIELDS = ("avail", "store", "frame", "unpaired", "first_bot", "dec_t", "dec_b", "ps_a", "ps_a_v",
              "ps_b", "ps_b_v", "pts", "pts_v", "pts_b", "pts_b_v", "timing_v", "nuit", "ts", "w", "hf", "ep")

    def __init__(self, **kw):
        self.end = kw.pop("end", False)
        self.pic = kw.pop("pic", None)            # fj#80: the store's luma (H x W, woven), else black
        for f in self.FIELDS:
            setattr(self, f, kw.get(f, 0))

    def line(self):
        if self.end:
            return "E %d" % self.avail
        return "R " + " ".join(str(getattr(self, f)) for f in self.FIELDS)


def field_q3(r):
    """(Q3 ticks of one clock tick, flag bits: 1 no timing, 2 clamped / ts 0)"""
    if not r.timing_v or r.ts == 0:
        return REF_Q3, (1 if not r.timing_v else 2)
    q = (720000 * r.nuit) // r.ts
    if q > Q3_MAX:
        return Q3_MAX, 2
    if q == 0:
        return REF_Q3, 2
    return q, 0


def n_ticks(r):
    """(DeltaTfiDivisor total, pic_struct error)"""
    if r.frame:
        if r.ps_a_v:
            if r.ps_a in DIV:
                return DIV[r.ps_a], 0
            return 2, 1
        return 2, 0
    err = 0
    a = 1
    if r.ps_a_v and r.ps_a not in (1, 2):
        err = 1
    if r.unpaired:
        return 1, err
    if r.ps_b_v and r.ps_b not in (1, 2):
        err = 1
    return 2, err


def _s36(v):
    v %= 1 << 36
    return v - (1 << 36) if v >= 1 << 35 else v


MAXPTS = (1 << 33) - 1


class Ctl(object):
    """a transport event at refresh k: kind F (frozen refresh), S (resync), W (an item
    table entry: a = index, b = IN / the target, c = OUT, d = last | skip << 1)"""

    def __init__(self, kind, k, a=0, b=0, c=0, d=0):
        self.kind, self.k, self.a, self.b, self.c, self.d = kind, k, a, b, c, d

    def line(self):
        return "C %s %d %d %d %d %d" % (self.kind, self.k, self.a, self.b, self.c, self.d)


def W(k, idx, tin, tout=MAXPTS, last=0, skip=1):
    return Ctl("W", k, idx, tin, tout, last | (skip << 1))


def simulate(recs, n_refresh, n_store=20, ctls=(), il=False):
    """recs: Rec list (store fields ignored: assigned here, lowest free at emission).
    Returns (per refresh [(valid, store, parity, field, single)], counters, recs with stores).
    single: the shown store is one field (the reader bobs it in every deinterlace mode)."""
    held = set()                       # emitted, not released
    q = []                             # the queue (emitted, not taken)
    todo = list(recs)
    anchored = False
    stc = 0
    stc_anchor = None                  # (value, P_pick) of the last anchor
    next_q3 = 0
    next_valid = False
    cur = None                         # the shown record
    idx = 0
    ended = False
    starved = False
    cnt = {"dc": 0, "reanchors": 0, "late": 0, "cadence": 0, "flags": 0, "pickups": 0, "starve": 0,
           "skip": 0, "drain": 0, "outhit": 0, "lone": 0, "pdefer": 0}
    frozen = set(c.k for c in ctls if c.kind == "F")
    if il:                                 # sampled at the top fields' evals, held for the bottom
        frozen = set(k for k in range(n_refresh + 1) if (k & ~1) in frozen)
    spans = sorted((FRAME * k + P_EVAL + 1, FRAME * (k + 1) + P_EVAL) for k in frozen)
    skipping = waiting = False
    x_v, x_q3 = False, 0
    out_hit = False
    t_v, t_in, t_out, t_last, t_skip = [True] * 4, [0] * 4, [MAXPTS] * 4, [False] * 4, [False] * 4
    cur_ep, cur_v = 0, False
    sh_ep = 0
    cur_kind = None                        # fj#80: the size of the store the evidence came from
    left, srun = set(), 0
    sh_pts = None
    # fj#80: field matching
    prev = None                            # the held previous store's record
    fl = telecine_ref.FilmLock()
    ev = (False, 0, 0)                     # the reader's sums of the refresh just shown
    film = (0, 0, 0)                       # (match, partner store, film kernel) of the shown refresh
    partner = None
    late = []                              # fj#80: stores a resync releases at its refresh's pickup
    susp = False                           # the previous tag taken was disbelieved (a lone PTS)
    anchored_prev_eval = False             # the STC ran at the previous refresh's eval
    anchored_at_prev_pick = False          # the previous pickup re-anchored it
    s_prev = 0                             # the previous refresh's eval STC
    out = []

    def stc_at(Q):
        if not anchored:
            return 0
        v, pp = stc_anchor
        n = ticks_between(pp + 1, Q - 1)
        for a, b in spans:                 # the frozen spans' ticks do not count
            n -= ticks_between(max(a, pp + 1), min(b, Q - 1))
        return (v + n) & ((1 << 33) - 1)

    def prep(h):
        """(tag, pts_eff, dur, flags, pic_struct error, tick_t, frame_t) of a head"""
        fq, ff = field_q3(h)
        nt, pe_err = n_ticks(h)
        tick_t = fq >> 3
        if getattr(h, "ovr", None) is not None:
            tag, pts_eff = True, h.ovr
        elif h.pts_v:
            tag, pts_eff = True, h.pts
        elif h.pts_b_v and not h.frame and not h.unpaired:
            tag, pts_eff = True, (h.pts_b - tick_t) & ((1 << 33) - 1)
        else:
            tag, pts_eff = False, 0
        return tag, pts_eff, nt * fq, ff, pe_err, tick_t, fq >> 2

    def unseen(r):
        if not r.end:
            held.discard(r.store)

    def judge():
        """the transport's judgements on the head as it reaches it: before a refresh's eval
        and again right after its pickup (the RTL judges a head the cycle it arrives)"""
        nonlocal waiting, ended, out_hit, skipping, x_q3, x_v, cur_ep, cur_v, left
        waiting = False
        while q:
            h = q[0]
            if ended:
                if h.end:
                    q.pop(0)
                    continue
                q.pop(0)
                unseen(h)
                continue
            if h.end:
                if skipping:
                    # the stream ended inside a skip (its target past every picture): the
                    # display ends -- END taken, the shown picture kept (fix/skip-last-picture)
                    q.pop(0)
                    ended, skipping = True, False
                    continue
                break
            tag, pts_eff, dur, _, _, _, _ = prep(h)
            # its item: its own tag when it carries a PTS, else the current one
            ep_v = bool(h.pts_v or h.pts_b_v)
            h_ep = h.ep if ep_v else cur_ep
            if (ep_v or cur_v) and (not cur_v or h_ep != cur_ep):
                if not t_v[h_ep]:
                    waiting = True
                    break
                if cur_v:
                    left.add(cur_ep)
                left.discard(h_ep)
                cur_ep, cur_v, skipping, x_v = h_ep, True, t_skip[h_ep], False
                continue
            tgt = t_in[cur_ep]
            if skipping:
                # t in eighth-ticks: a skipped run keeps the fraction (1501.5 ticks a refresh)
                if tag:
                    est_q3 = pts_eff << 3
                elif x_v:
                    est_q3 = x_q3
                else:
                    est_q3 = None
                if est_q3 is not None and _s36(est_q3 + dur - (tgt << 3)) < SKIP_TOL_Q3:
                    q.pop(0)
                    unseen(h)
                    cnt["skip"] += 1
                    x_q3, x_v = (est_q3 + dur) % (1 << 36), True
                    continue
                skipping = False
                if not tag and est_q3 is not None:
                    h.ovr = est_q3 >> 3
                continue
            if cur_v and t_v[cur_ep]:
                if tag:
                    est = pts_eff
                elif next_valid:
                    est = (next_q3 >> 3) & ((1 << 33) - 1)
                else:
                    est = None
                if est is not None and est - t_out[cur_ep] >= 0:
                    q.pop(0)
                    unseen(h)
                    cnt["skip"] += 1
                    if t_last[cur_ep]:
                        ended = out_hit = True
                    continue
            break

    for k in range(n_refresh):
        # the transport's events at this refresh: resync (line 2), target (line 5), stop (line 6)
        for c in ctls:
            if c.k != k:
                continue
            if c.kind == "S":
                while q:
                    r = q.pop(0)
                    cnt["drain"] += 1
                    if film[0] and partner is r:   # fj#80: the NEXT partner, released at the pickup
                        late.append(r)
                    else:
                        unseen(r)
                if prev is not None:               # fj#80: the hold dropped, released at the pickup
                    late.append(prev)
                    prev = None
                fl.reset()
                film, partner = (0, 0, 0), None
                anchored = next_valid = False
                susp = False
                stc_anchor = None
                anchored_prev_eval = anchored_at_prev_pick = False
                s_prev = 0
                starved = ended = out_hit = False
                skipping, x_v = False, False
                t_v = [False] * 4
                cur_v = False
                left, srun = set(), 0
            elif c.kind == "W":
                t_v[c.a], t_in[c.a], t_out[c.a] = True, c.b, c.c
                t_last[c.a], t_skip[c.a] = bool(c.d & 1), bool(c.d & 2)
                if not t_skip[c.a] and cur_v and c.a == cur_ep:
                    skipping = False
                left.discard(c.a)
        # emissions for this refresh (frame k, line 10): the lowest free store
        while todo and todo[0].avail <= k:
            r = todo.pop(0)
            if not r.end:
                free = [s for s in range(n_store) if s not in held]
                if not free:
                    raise RuntimeError("scenario needs more than %d stores at refresh %d" % (n_store, k))
                r.store = free[0]
                held.add(r.store)
            q.append(r)
        pe = FRAME * k + P_EVAL
        pp = FRAME * k + P_PICK
        judge()
        took = False
        if k in frozen:                    # no eval, no pickup, the parity held, the STC held
            out.append(_shown(cur, idx, sh_pts, sh_ep) + (sum(1 << e for e in left), int(srun >= 64)) + film)
            ev = _evidence(cur, idx, film, partner, il)
            for r in late:                 # fj#80: (the pickup's line 500 comes, frozen or not)
                held.discard(r.store)
            late = []
            continue
        s_e = stc_at(pe)
        prev_ok = anchored_prev_eval and not anchored_at_prev_pick
        anchored_prev_eval = anchored
        anchored_at_prev_pick = False
        h = q[0] if q and not waiting and not skipping else None
        if h is not None and h.end:
            q.pop(0)
            ended = True
            h = None
        if h is not None and not ended:
            tag, pts_eff, dur, ff, pe_err, tick_t, frame_t = prep(h)
            next_pts = (next_q3 >> 3) & ((1 << 33) - 1)
            # a lone PTS ahead of or behind the timeline: disbelieved (taken as untagged)
            lone = (tag and anchored and next_valid and not susp and
                    HALF < abs(pts_eff - next_pts) <= FWD_MAX and s_e - pts_eff <= LATE_MAX)
            if lone:
                tag = False
            want = pts_eff if tag else (next_pts if next_valid else s_e)
            d_pic_next = pts_eff - next_pts
            d_stc_pic = s_e - pts_eff
            disc = tag and anchored and next_valid and (d_pic_next < -frame_t or d_pic_next > FWD_MAX
                                                         or d_stc_pic > LATE_MAX)
            anchor_now = (not anchored) or (tag and (not next_valid or disc))
            due = anchor_now or (s_e - want >= -HALF)
            # V6 (480i): a pair waits for the raster field of its first field's parity
            late_h = not anchor_now and prev_ok and (s_prev - want >= -HALF)
            if due and il and not late_h and not h.frame and not h.unpaired and h.first_bot != ((k + 1) & 1):
                cnt["pdefer"] += 1
                due = False
            if due:
                took = True
                q.pop(0)
                cnt["pickups"] += 1
                cnt["flags"] |= ff | (4 if pe_err else 0)
                # the previous store's cadence, judged when this one is contiguous
                if cur is not None and not anchor_now and not starved and \
                        (not tag or abs(d_pic_next) < HALF):
                    lo, hi = cur_dur // REF_Q3, -(-cur_dur // REF_Q3)
                    if not (lo <= idx + 1 <= hi):
                        cnt["cadence"] += 1
                if not anchor_now and prev_ok and (s_prev - want >= -HALF):
                    cnt["late"] += 1
                if anchor_now:
                    anchored_at_prev_pick = True
                    av = pts_eff if tag else 0
                    cnt["reanchors"] += 1
                    anchored = True
                    stc_anchor = (av, pp)
                    next_q3 = (av << 3) + dur
                else:
                    next_q3 = (want << 3) + dur
                next_valid = True
                if lone:
                    susp = True
                    cnt["lone"] += 1
                elif tag:
                    susp = False
                sh_pts = want & ((1 << 33) - 1)
                # fj#80: the outgoing store held as the next one's partner, else released
                np_ = (cur is not None and _pair(cur) and _same_kind(h, cur) and cur_ep == sh_ep and not il)
                if cur is not None:
                    if np_:
                        if prev is not None:
                            held.discard(prev.store)
                        prev = cur
                    else:
                        held.discard(cur.store)
                        if prev is not None:
                            held.discard(prev.store)
                        prev = None
                sh_ep = cur_ep
                cur = h
                cur_dur = dur
                idx = 0
                starved = False
                srun = 0
                cnt["dc"] += 1
        if not took:
            np_ = False
            if cur is not None:
                idx += 1
                if not cur.frame and not cur.unpaired:
                    cnt["dc"] += 1               # the pair's other field
            if (not q or q[0].end or waiting or skipping) and anchored and next_valid and not ended:
                if s_e - ((next_q3 >> 3) & ((1 << 33) - 1)) >= -HALF:
                    starved = True
                    cnt["starve"] += 1
                    srun = min(srun + 1, 64)
        s_prev = s_e
        # fj#80: the lock's step at this pickup (480p; the 480i raster holds it cleared)
        if il:
            fl.reset()
            film, partner = (0, 0, 0), None
        else:
            hd = q[0] if q and not waiting and not skipping and not ended else None
            nx_ok = (not took and hd is not None and not hd.end and cur is not None and _same_kind(hd, cur))
            first = took or (idx % 2 == 0)
            fl.npix = telecine_ref.npix_of(16 * (cur_kind[1] if cur_kind else 0), 16 * (cur_kind[0] if cur_kind else 0),
                                           (8, 1))
            show = fl.step(pick=took, np_=np_, first=first, prev_ok=(np_ if took else prev is not None),
                           next_ok=nx_ok, mv=ev[0], C=ev[1], R=ev[2])
            if show == telecine_ref.PREV:
                film, partner = (1, prev.store, 1), prev
            elif show == telecine_ref.NEXT:
                film, partner = (1, hd.store, 1), hd
            else:
                film, partner = (0, 0, 1 if show == telecine_ref.IN else 2 if show == telecine_ref.BOB else 0), None
        cur_kind = (cur.w, cur.hf) if cur is not None else None
        judge()                            # the head after the pickup (before line 510's sample)
        out.append(_shown(cur, idx, sh_pts, sh_ep) + (sum(1 << e for e in left), int(srun >= 64)) + film)
        ev = _evidence(cur, idx, film, partner, il)
        for r in late:                     # fj#80: released at this refresh's pickup
            held.discard(r.store)
        late = []
    cnt["outhit"] = int(out_hit)
    cnt["ended"] = int(ended)          # the display ended (an END taken, or the stop at the last OUT)
    return out, cnt, recs


def _pair(r):
    return not r.frame and not r.unpaired


def _same_kind(h, cur):
    """fj#80: h continues cur's field pairs (the same field order and size)"""
    return _pair(h) and h.first_bot == cur.first_bot and h.w == cur.w and h.hf == cur.hf


def _evidence(cur, idx, film, partner, il):
    """fj#80: disp_reader's sums (cm_v, C, R) over the refresh shown: a 480p field pair's luma as
    fetched (the shown field's lines from cur, the other parity's from the partner when matched)"""
    if il or cur is None or not _pair(cur):
        return (False, 0, 0)
    if cur.pic is None and (partner is None or partner.pic is None):
        return (True, 0, 0)
    H, W = 16 * cur.hf, 16 * cur.w
    Y = cur.pic if cur.pic is not None else np.zeros((H, W), np.uint8)
    if film[0]:
        par = (cur.first_bot ^ (idx & 1)) & 1
        P = partner.pic if partner.pic is not None else np.zeros((H, W), np.uint8)
        Y = Y.copy()
        Y[1 - par::2] = P[1 - par::2]
    c, r = telecine_ref.observe(Y)[(8, 1)]
    return (True, c, r)


def _shown(cur, idx, sh_pts, sh_ep):
    pv, pt = (0, 0) if sh_pts is None else (1, sh_pts)
    if cur is None:
        return (0, 0, 0, 0, 0, pv, pt, sh_ep)
    field = 0 if cur.frame else 1
    if cur.frame:
        par = 0
    elif cur.unpaired:
        par = 1 if (cur.dec_b and not cur.dec_t) else 0
    else:
        par = (cur.first_bot ^ (idx & 1)) & 1
    return (1, cur.store, par, field, 1 if (not cur.frame and cur.unpaired) else 0, pv, pt, sh_ep)


# ---- scenarios ---------------------------------------------------------------------------

def frames(n, ps_cycle, pts0, tag_every, nuit=4004, ts=240000, avail0=0, lead=3, ps_v=1, start=0, t0=0.0,
           ceil_pts=False):
    """n frame records; PTS on every tag_every-th (exact 90 kHz of the running Q3 sum);
    record i available `lead` refreshes before its nominal display refresh (t0 + the
    durations before it)"""
    recs = []
    q3 = pts0 << 3
    fq = (720000 * nuit) // ts
    t_ref = float(t0)
    for i in range(start, start + n):
        ps = ps_cycle[i % len(ps_cycle)] if ps_cycle else 0
        nt = DIV.get(ps, 2) if ps_v else 2
        disp_ref = int(t_ref)
        recs.append(Rec(avail=max(avail0, disp_ref - lead), frame=1, dec_t=1, dec_b=1, ps_a=ps, ps_a_v=ps_v,
                        pts=(-(-q3 // 8) if ceil_pts else q3 >> 3), pts_v=int(i % tag_every == 0), timing_v=1,
                        nuit=nuit, ts=ts, w=45, hf=30))
        q3 += nt * fq
        t_ref += nt * fq / REF_Q3
    return recs


def pairs(n, first_bot, pts0, tag_every, avail0=0, lead=3):
    recs = []
    q3 = pts0 << 3
    for i in range(n):
        ps_a, ps_b = (2, 1) if first_bot else (1, 2)
        recs.append(Rec(avail=max(avail0, 2 * i - lead), frame=0, first_bot=first_bot, dec_t=1, dec_b=1,
                        ps_a=ps_a, ps_a_v=1, ps_b=ps_b, ps_b_v=1, pts=q3 >> 3, pts_v=int(i % tag_every == 0),
                        timing_v=1, nuit=4004, ts=240000, w=45, hf=30))
        q3 += 2 * 12012
    return recs


def fields(n, pts0, tag_every, lead=3, t0=0):
    """n single top fields (1 tick each: one refresh -- the display's maximum rate)"""
    recs = []
    for i in range(n):
        recs.append(Rec(avail=max(0, t0 + i - lead), frame=0, unpaired=1, dec_t=1, dec_b=0, ps_a=1, ps_a_v=1,
                        pts=((pts0 << 3) + i * 12012) >> 3, pts_v=int(i % tag_every == 0), timing_v=1, nuit=4004,
                        ts=240000, w=45, hf=30))
    return recs


def end_at(recs, extra=4):
    last = max(r.avail for r in recs)
    return recs + [Rec(end=True, avail=last + extra)]


def scenario(name):
    """(records, refreshes to simulate)"""
    P0 = 1000000
    if name == "film32":                          # C1 3:2 film on frames
        r = frames(120, [5, 4, 6, 3], P0, 12)
        return end_at(r), 320
    if name == "prog24":                          # C2 23.976 progressive: 2.5 refreshes a frame
        r = frames(120, None, P0, 12, nuit=5005, ps_v=0)
        return end_at(r), 320
    if name == "prog24r":                         # C2' the disc's phase: time stamps rounded UP --
        # every other frame lands 750.75 ticks past a refresh and is taken at the next one:
        # the best a 59.94 raster can do, NOT late (X-Men 2 on the rig, 2026-09-26)
        r = frames(120, None, P0, 1, nuit=5005, ps_v=0, ceil_pts=True)
        return end_at(r), 320
    if name == "tff":                             # C3 field pairs, top first / bottom first
        return end_at(pairs(120, 0, P0, 15)), 260
    if name == "bff":
        return end_at(pairs(120, 1, P0, 15)), 260
    if name == "ps78":                            # C4 frame doubling / tripling
        r = frames(60, [7, 8, 0], P0, 6)
        return end_at(r), 260
    if name == "unpaired":                        # C5 single fields (1 tick) among pairs
        r = pairs(40, 0, P0, 10)
        for i in (7, 19, 30):
            r[i].unpaired, r[i].dec_b, r[i].ps_b_v = 1, 0, 0
        # the timeline after a single field is one tick shorter: re-stamp the tags
        q3 = P0 << 3
        for x in r:
            if x.pts_v:
                x.pts = q3 >> 3
            q3 += (1 if x.unpaired else 2) * 12012
        return end_at(r), 120
    if name == "geom":                            # C6 sizes and no VUI timing (the default, flagged)
        r = frames(40, None, P0, 8)
        for i, x in enumerate(r):
            x.w, x.hf = (30, 17) if i % 3 == 0 else (45, 30)
            if i >= 20:
                x.timing_v = 0
        return end_at(r), 120
    if name == "latefld":                         # [5b] the same on field pairs (480i: a late pair is
        r = pairs(90, 0, P0, 10, lead=3)          #   taken at once, not deferred for field order: V6)
        for i in range(30, 60):
            r[i].avail += (i - 29) // 2
        for i in range(60, 90):
            r[i].avail = max(r[i].avail, r[59].avail)
        return end_at(r), 220
    if name == "late":                            # [5] a late decoder: pictures 30-59 grow late
        r = frames(90, [5, 4, 6, 3], P0, 12, lead=3)
        for i in range(30, 60):
            r[i].avail += (i - 29) // 2
        for i in range(60, 90):
            r[i].avail = max(r[i].avail, r[59].avail)
        return end_at(r), 300
    # the second segment is displayed right after the first (60 film frames = 150
    # refreshes); only its PTS jumps. First picture of each segment tagged.
    if name == "back":                            # [7a] PTS restarts 5 s back
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], P0 - 450000, 12, start=60, t0=150)
        return end_at(r), 320
    if name == "back200":                         # [7d] 200 ms back: under LATE_MAX, only the backward leg
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts - 18000)
        return end_at(r), 320
    if name == "backfld":                         # [7e] 200 ms back on single fields: the picture after
        # the anchor is taken at the very next refresh, so "already due at the previous one"
        # must not be judged with the OLD timeline's STC (D13)
        r = fields(60, P0, 10) + fields(60, P0 + 60 * 1501 - 18000, 10, t0=60)
        return end_at(r), 140
    if name == "gap03":                           # [7b] a 0.3 s forward gap is waited out
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts + 60060 // 8 + 27000)
        return end_at(r), 340
    if name == "gap2s":                           # [7c] a 2 s forward gap re-anchors
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts + 180000)
        return end_at(r), 320
    if name == "held":                            # [8] a 4 s held still: past LATE_MAX
        r = frames(80, [5, 4, 6, 3], P0, 12)
        for i in range(40, 80):
            r[i].avail = r[i].avail + 240
        return end_at(r), 520
    if name == "starve400":                       # [8b] a 400 ms starvation is NOT a re-anchor
        r = frames(100, [5, 4, 6, 3], P0, 12)
        for i in range(40, 100):
            r[i].avail = r[i].avail + 24
        return end_at(r), 340
    # ---- lone PTS (fix/film-timing, docs/display.md S10): the discs' shape ----
    if name == "lone7":                           # [L1] 3:2 film; lone tags +7 ticks (Akira 3352 s: record
        # 48, the next tag on the old timeline) and +8 (record 84: the flag was cleared by the
        # believed tag between: record 72, +600 ticks -- under the edge, believed, carried on);
        # record 108 +1 tick (The Simpsons Movie's: over the edge, disbelieved)
        r = frames(120, [5, 4, 6, 3], P0, 12)
        r[48].pts += 10511
        r[72].pts += 600
        r[84].pts += 12012
        r[108].pts += 1501
        return end_at(r), 320
    if name == "lonefld":                         # [L2] field pairs, a lone tag +5 ticks (Astro Boy 476 s)
        r = pairs(120, 0, P0, 15)
        r[45].pts += 7508
        return end_at(r), 260
    if name == "lone2":                           # [L3] a real +7-tick gap from record 48: its tag is
        # disbelieved, the next (60) believed -- the gap waited out one tag later
        r = frames(120, [5, 4, 6, 3], P0, 12)
        for x in r[48:]:
            x.pts += 10511
        return end_at(r), 330
    if name == "loneearly":                       # [L4] rule B: 23.976 progressive, a lone tag one
        # frame and half a tick EARLY (The Transporter, 100.47 s: -3,754.5 ticks). The timeline
        # carries whole ticks for untagged pictures (-0.75 a 23.976 frame), so it reads -3,746:
        # under rule A believed (inside a frame: shown a frame early, no re-anchor), its return
        # then disbelieved and waited for at the next tag
        r = frames(120, None, P0, 12, nuit=5005, ps_v=0)
        r[48].pts -= 3755
        return end_at(r), 320
    if name == "loneearlyfld":                    # [L5] rule B: field pairs, a lone tag 3 ticks early
        # (The Simpsons Movie, 2,324.90 s)
        r = pairs(120, 0, P0, 15)
        r[45].pts -= 4504
        return end_at(r), 260
    if name == "back1s":                          # [7f] 1 s back: past FWD_MAX, under LATE_MAX -- not a
        # lone PTS, re-anchors at once (the band's lower bound)
        r = frames(60, [5, 4, 6, 3], P0, 12) + frames(60, [5, 4, 6, 3], 0, 12, start=60, t0=150)
        _shift_pts(r, 60, r[59].pts - 90000)
        return end_at(r), 320
    # ---- the transport (P6b3) ----
    if name == "pause":                           # [P1] 1 s paused mid-film: the STC and the cadence resume
        r = frames(120, [5, 4, 6, 3], P0, 12)
        for x in r:
            if x.avail >= 97:
                x.avail += 60                     # the decoder waits on the full DPB while paused
        return end_at(r), 380, [Ctl("F", k) for k in range(100, 160)]
    if name == "pausefld":                        # [P2] paused on field pairs: the parity holds
        r = pairs(100, 0, P0, 15)
        for x in r:
            if x.avail >= 57:
                x.avail += 31
        return end_at(r), 280, [Ctl("F", k) for k in range(60, 91)]
    if name in ("telecine", "telecinebff"):
        # [F1] fj#80: hard-telecined film on field pairs (176x96, telecine_ref.synth's 3:2 pan):
        # the lock forms after ten cycles and matches every split pair -- the reader reads the
        # held previous store and the queue's head ([hold] checks every burst)
        fb = 1 if name == "telecinebff" else 0
        r = pairs(110, fb, P0, 15)
        st, _fo, _idet, _split = telecine_ref.synth("film", 110, first_bot=fb, phase=1, h=96, w=176)
        for x, Y in zip(r, st):
            x.w, x.hf, x.pic = 11, 6, Y
        return end_at(r), 250
    if name == "telecineseek":
        # [F2] fj#80: a seek while locked: the hold dropped, the queue drained, the lock cleared;
        # B (another item, another cadence phase) locks afresh
        a = pairs(90, 0, P0, 15)
        st, _fo, _idet, _split = telecine_ref.synth("film", 90, phase=1, h=96, w=176)
        for x, Y in zip(a, st):
            x.w, x.hf, x.pic = 11, 6, Y
        a = [x for x in a if x.avail < 130]
        P1 = 5000000
        b = pairs(90, 0, P1, 15)
        st, _fo, _idet, _split = telecine_ref.synth("film", 90, phase=3, h=96, w=176, edit=(0, 3))
        for x, Y in zip(b, st):
            x.w, x.hf, x.pic, x.ep = 11, 6, Y, 1
            x.avail += 134
        ctl = [Ctl("S", 130), W(132, 1, P1, last=1, skip=0)]
        return end_at(a + b), 330, ctl
    if name in ("seek", "seekfrz", "seeknoskip"):
        # [S1] segment A playing; at refresh 100 the resync drains A's queued records; B
        # (another timeline) arrives from refresh 104 while the display waits; the target
        # at 106 lands inside B's record 17 (untagged: its time extrapolated from record
        # 12), so 0-16 are skipped (4 of them as they arrive, after the target) and 17,
        # arriving at 109, anchors. seekfrz: frozen from the command through the target
        # and on; seeknoskip: the target without a skip (B from its first record).
        a = frames(60, [5, 4, 6, 3], P0, 12)
        P1 = 5000000
        if name == "seeknoskip":
            b = frames(80, [5, 4, 6, 3], P1, 12, t0=107)
        else:
            b = frames(80, [5, 4, 6, 3], P1, 12, t0=66)
            for i, x in enumerate(b):
                x.avail = 104 + i // 4 if i < 17 else max(109, x.avail)
        r17 = ((P1 << 3) + 43 * 12012) >> 3
        for x in b:
            x.ep = 1                               # the landing is another item (its tag 1)
        ctl = [Ctl("S", 100), W(106, 1, r17 + 100, last=1, skip=0 if name == "seeknoskip" else 1)]
        if name == "seek":
            ctl += [Ctl("F", k) for k in range(96, 101)]
        if name == "seekfrz":
            ctl += [Ctl("F", k) for k in range(96, 112)]
        a = [x for x in a if x.avail < 100]         # nothing of A arrives after the resync (player_ctl: the queue idle)
        return end_at(a + b), 330, ctl
    if name in ("seekend", "seekend1"):
        # [S5] fix/skip-last-picture (docs/display.md S11): a seek clamped to the title's end.
        # B is the shape of Akira's last GOP, read off the disc: 28 frames, pic_struct 6 3 5 4,
        # PES PTS on pictures 0 and 14 only (each the floor of its exact time), the item's OUT
        # one tick past the last picture's extrapolated end (676497731.5). The target is the
        # reader's clamp: OUT - 4 (seekend; umd_nav_ref.clamp) shows the last picture and takes
        # the END; OUT - 1 (seekend1, the old clamp) lies 0.5 tick before that end,
        # inside the skip's one tick of tolerance: every record is skipped (the rig's defect),
        # and the END reached inside the skip ends the display with A's picture kept (the
        # backstop: an OUT far past a title's content puts any target past every picture).
        a = frames(60, [5, 4, 6, 3], P0, 12)
        P1, OUT = 676392627, 676497732
        b = frames(28, [6, 3, 5, 4], P1, 14, t0=66)
        for i, x in enumerate(b):
            x.avail = 104 + i // 4
            x.ep = 1
        tgt = OUT - (1 if name == "seekend1" else 4)
        ctl = [Ctl("F", k) for k in range(96, 101)] + [Ctl("S", 100), W(106, 1, tgt, OUT, last=1)]
        a = [x for x in a if x.avail < 100]
        return end_at(a + b), 160, ctl
    if name == "mountin":                         # [S2] IN at the first item start: 0-8 skipped
        r = frames(60, [5, 4, 6, 3], P0, 12, t0=-23)
        r9 = ((P0 << 3) + 23 * 12012) >> 3
        return end_at(r), 200, [W(0, 0, r9)]
    if name == "stopout":                         # [S3] OUT 10 ticks before record 50: 49 is the last shown
        r = frames(80, [5, 4, 6, 3], P0, 12)
        r50 = ((P0 << 3) + 125 * 12012) >> 3
        return end_at(r), 260, [W(0, 0, 0, r50 - 10, last=1, skip=0)]
    if name == "items":
        # [S4] two playlist items back to back (P6b3i): A (tag 0) is cut at its OUT, 10 ticks
        # before its record 30 (30-39 dropped, the display goes on); B (tag 1, another
        # timeline 300 s on) opens at its IN, inside its record 5 (0-4 skipped; 5 untagged:
        # its time from record 0), re-anchors -- A's last picture then gets one refresh, not
        # its duration: P5's rule for a timeline jump; the item change itself is P8's -- and
        # ends at its OUT before record 35 (the title's last item). (A head never waits at a
        # natural item change: its entry is written at its item start, before its bytes.)
        a = frames(40, [5, 4, 6, 3], P0, 12)
        P1 = P0 + 27000000
        # A's record 30 would show at refresh 75; B's record 5 takes its place
        b = frames(40, [5, 4, 6, 3], P1, 12, t0=75 - 12)
        for x in b:
            x.ep = 1
        for x in a[30:]:
            x.avail = a[29].avail                  # the tail past OUT is decoded right behind 29
        a30 = ((P0 << 3) + 75 * 12012) >> 3
        b5 = ((P1 << 3) + 13 * 12012) >> 3        # the 3:2 cycle: record i starts at 10 (i // 4) + (0, 3, 5, 8)
        b35 = ((P1 << 3) + 88 * 12012) >> 3
        ctl = [W(0, 0, P0, a30 - 10, last=0, skip=1), W(0, 1, b5 + 1, b35 - 10, last=1, skip=1)]
        return end_at(a + b), 300, ctl
    if name == "trick":
        # [T1] P6b4 trick play: A plays; four HOPS, each a seek (frozen, the resync) whose
        # landing writes its entry WITHOUT a skip and brings ONE picture (the entry's I; the
        # third a field pair) and the END word (the front end ends a hop's stream after its
        # first frame) -- each must be shown at the first pickup after it arrives (it anchors:
        # no untimed mode is needed) and held until the next resync, the END taken; then play
        # resumes by a seek to the last hop's picture (a skip to its PTS), B playing on from it
        a = [x for x in frames(40, [5, 4, 6, 3], P0, 12) if x.avail < 38]
        recs, ctl = list(a), []
        pk = [P0 + 900000 * (i + 1) for i in range(4)]       # 10 s apart (forward)
        for i, p in enumerate(pk):
            k = 40 + 20 * i
            # (the entry's target is the hop's clamped target, 0.5 s past the entry's I: with no
            #  skip the I is shown; a skip would drop it and show nothing)
            ctl += [Ctl("F", j) for j in range(k - 2, k + 1)] + [Ctl("S", k), W(k + 1, 0, p + 45000, skip=0)]
            h = pairs(1, 0, p, 1)[0] if i == 2 else frames(1, None, p, 1)[0]
            h.avail = k + 3
            recs += [h, Rec(end=True, avail=k + 4)]
        k = 120
        ctl += [Ctl("F", j) for j in range(k - 2, k + 1)] + [Ctl("S", k), W(k + 1, 0, pk[3])]
        b = frames(40, [5, 4, 6, 3], pk[3], 12, t0=k + 4)
        for x in b:
            x.avail = max(x.avail, k + 3)
        return end_at(recs + b), 260, ctl
    raise KeyError(name)


def _shift_pts(r, i0, new0):
    base = r[i0].pts
    for x in r[i0:]:
        x.pts = x.pts - base + new0


SCENARIOS = ("film32", "prog24", "prog24r", "tff", "bff", "ps78", "unpaired", "geom", "late", "latefld", "back", "back200", "backfld", "gap03", "gap2s",
             "held", "starve400", "lone7", "lonefld", "lone2", "loneearly", "loneearlyfld", "back1s", "pause", "pausefld", "seek", "seekfrz", "seeknoskip", "seekend", "seekend1", "mountin", "stopout", "items",
             "trick", "telecine", "telecinebff", "telecineseek")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--scenario")
    ap.add_argument("--out")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--il", action="store_true", help="the 480i raster (a refresh is a field; V6)")
    a = ap.parse_args(argv)
    if a.list:
        print(" ".join(SCENARIOS))
        return 0
    sc = scenario(a.scenario)
    recs, n = sc[0], sc[1]
    ctls = sc[2] if len(sc) > 2 else []
    for i in range(1, len(recs)):
        recs[i].avail = max(recs[i].avail, recs[i - 1].avail)     # FIFO: availability is monotonic
    out, cnt, recs = simulate(recs, n, ctls=ctls, il=a.il)
    with open(a.out + ".stim", "w") as f:
        f.write("%d %d %d\n" % (len(recs), n, len(ctls)))
        for r in recs:
            f.write(r.line() + "\n")
        for c in ctls:
            f.write(c.line() + "\n")
    with open(a.out + ".exp", "w") as f:
        for v, s, p, fl, sg, pv, pt, ep, lm, st, fm, fs, fk in out:
            f.write("%d %d %d %d %d %d %d %d %d %d %d %d %d\n" % (v, s, p, fl, sg, pv, pt, ep, lm, st, fm, fs, fk))
    # fj#80: the records' pictures (luma words as the store holds them), for the bench to write
    pics = [r for r in recs if not r.end and r.pic is not None]
    with open(a.out + ".pic", "w") as f:
        npw = (16 * pics[0].hf) * (2 * pics[0].w) if pics else 0
        f.write("%d %d\n" % (npw, len(recs)))
        for r in recs:
            if r.end or r.pic is None:
                continue
            Y = r.pic.astype(np.uint64)
            w8 = Y.reshape(Y.shape[0], -1, 8)
            words = sum(w8[:, :, i] << np.uint64(8 * i) for i in range(8)).reshape(-1)
            f.write("".join("%016x\n" % int(v) for v in words))
    with open(a.out + ".cnt", "w") as f:
        f.write(" ".join("%s=%d" % kv for kv in sorted(cnt.items())) + "\n")
    nm = sum(1 for o in out if o[10])
    print("%s: %d records, %d refreshes (%d matched); %s" % (a.scenario, len(recs), n, nm,
                                                " ".join("%s %d" % kv for kv in sorted(cnt.items()))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
