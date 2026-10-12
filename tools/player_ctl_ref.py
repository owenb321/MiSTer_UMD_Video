#!/usr/bin/env python3
"""player_ctl_ref.py -- the golden of umd/player_ctl.sv (P6b3, docs/transport.md S2.1-S2.5):
the scenarios bench/umd/player_ctl_tb.sv plays, and the check of what the RTL did.

The bench surrounds player_ctl with a mock reader (NAV_CHAP answered from the title's
chapters as umd_reader's contract says, NAV_SEEK landing on the key clamped into IN..OUT)
and a mock display (a picture every REFRESH cycles while not frozen, 1501 ticks apart; a
landing shows exactly its target). It checks the SEQUENCE itself (the freeze, the flush and
its release order, the port, the audio switch, the watchdog) and logs what the transport
DECIDED. This script checks those decisions against tools/umd_nav_ref.py -- written from the
format and the PSP, never from the RTL:

  * every burst of chapter presses (presses less than MERGE apart) seeks to
    Title.presses(start, seq): start = the shown key at the burst's first press, or the
    target of the seek in flight when it came during one (each press judged from the
    pending target); a burst that finds nothing does not seek;
  * NO_CHAPTER is posted once per Next that ran past the last chapter;
  * every Go To seeks to its key;
  * P6c: every TIME (Go To by time, command 15) the DUT could take asks the reader's NAV_TIME with
    its time as given, and the mock lands it where Title.time_seek says (X lines, rechecked here);
    a burst pressed while one is in flight is judged from that landing;
  * P9: every PLAYLIST the DUT could take (a playlist below the title's count, no gesture or
    seek in flight -- the bench logs it as it reaches the DUT) asks the reader's NAV_PLAY with
    its playlist and its key as given (the reader clamps; the mock lands a missing item on
    item 0 at IN, as umd_reader does); one it could not take asks nothing; a Go To or a burst
    never asks a PLAY;
  * wherever the transport has settled (no gesture, the port quiet), the chapter it shows
    is Title.chapter_at(the shown key);
  * P6b4, trick play: every hop's request is Title.hop_request(the carried target, the edge,
    the direction, delta) with delta = the cycles at each speed x the model's rates x TICK_N,
    and every hop lands as Title.hop_land says (the carried target is the clamped one); no hop
    is issued after an exit, or past the title's ends (the model's None); and play resumes by
    a seek to the last hop's carried target (the mock display shows exactly it) -- at once
    for PLAY / PLAYPAUSE / PAUSE (the PSP's X, fj#57) / the opposite arrow / the title's ends / a
    chapter burst that finds nothing, at the next PLAY after STOP; within RESTORE_MAX of it.

    player_ctl_ref.py gen (--disc ISO | --synth NAME) --seed N --out STEM
    player_ctl_ref.py check --stem STEM
Files: STEM.title, STEM.script (the bench's input), STEM.log (the bench's output).
"""
import argparse
import os
import random
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import umd_nav_ref as N  # noqa: E402

# the bench's time (bench/umd/player_ctl_tb.sv; player_ctl's parameters scaled down with it)
REFRESH = 100          # cycles a picture
TICKS_PER_PIC = 1501   # 90 kHz ticks a picture (59.94)
MERGE = 2000           # MERGE_CYC
HOP_MIN = 1500         # HOP_MIN (P6b4)
# fj#57: a restore is due AT ONCE where it is asked (an exit, the title's end, a burst that found
# nothing, the PLAY after a STOP): the hop in flight lands, a burst's merge window, the seek --
# 2,470 cycles at most on the GREEN scripts. A PAUSE that held the picture would seek only at
# the next PLAY, >= ~19,000 cycles later in every script's forced pause exit (P65).
RESTORE_MAX = 3 * MERGE
TICK_N = 15            # 90 kHz ticks a cycle in the bench (TICK_DIV 1; 1501 ticks a REFRESH)
SEC = 90000 * REFRESH // TICKS_PER_PIC     # cycles a second of content (~6000)

# script codes (player_ctl's commands; >= 100 the bench's own directives)
PLAYPAUSE, PAUSE, PLAY, STOP, NEXT, PREV, SEEK, AUDIO, AUDIO_SET = 1, 2, 3, 4, 5, 6, 7, 8, 9
FF, REW = 10, 11
BADCMD = 0                                     # a reserved code (12 SUB P7, 13 / 14 P9, 15 P6c's TIME)
TIME = 15                                      # P6c: Go To by the playlist's time
SUB = 12
PLAYL, SUB_SET = 13, 14                        # P9 (docs/p9.md S3.2)
N_PL_SYNTH = 3                                 # the synthetic titles' playlist count
NOPIC, END, APRES, BADSYNC, PRESSSYNC, EXITSYNC, ENDSKIP = 100, 101, 102, 103, 104, 105, 106


def synth(name):
    """(Title, aud_present) of a hand-built title"""
    ep = [(i * 90000, i * 10) for i in range(400)]
    if name == "nochap":                       # no chapter at all: Next -> the message, Prev -> nothing;
        # IN at PTS 0 (P6b4: reverse trick play finds the start by its request's saturation)
        return N.Title([("A", 0, 30000000, ep)], [(16, 0, 29000000)]), 0x0001
    if name == "multi":                        # chapters on three items (the key's item from landings)
        items = [("A", 90000, 9000000, ep), ("B", 45000, 5400000, ep), ("C", 45000, 9000000, ep)]
        marks = [(5, 0, 90000), (5, 0, 2700000), (5, 1, 45000), (5, 1, 900000), (5, 2, 45000),
                 (5, 2, 4500000), (5, 0, 6300000)]
        return N.Title(items, marks), 0x0005
    if name == "dup":                          # a duplicated mark and one exactly on IN
        marks = [(5, 0, 45000), (5, 0, 900000), (5, 0, 900000), (5, 0, 1800000), (5, 0, 5000000)]
        return N.Title([("A", 45000, 30000000, ep)], marks), 0x8001
    if name == "short":                        # ten 2 s items: the reader runs 4 ahead and is held (P6b3i)
        items = [("C%d" % k, 45000, 45000 + 180000, ep) for k in range(10)]
        marks = [(5, 0, 45000), (5, 2, 90000), (5, 5, 45000), (5, 7, 135000), (5, 9, 45000)]
        return N.Title(items, marks), 0x0001
    if name == "dense":                        # P6b4: a chapter every 3 s -- any hop (>= 5 s at 20x)
        # crosses one, so a press during trick play keyed from the hop's target instead of the
        # picture shown lands a chapter off (P35)
        marks = [(5, 0, 45000 + 270000 * k) for k in range(110)]
        return N.Title([("A", 45000, 30000000, ep)], marks), 0x0001
    raise KeyError(name)


def write_title(t, aud, path, sub=0, n_pl=1):
    with open(path, "w") as f:
        f.write("T %d %d %d %d %d\n" % (len(t.items), aud, len(t.chapters), sub, n_pl))
        for it in t.items:
            f.write("I %d %d\n" % (it.in_pts, it.out_pts))
        for item, pts in t.chapters:
            f.write("C %d %d\n" % (item, pts))


def read_title(path):
    items, chaps, aud, n_pl = [], [], 0, 1
    for ln in open(path):
        w = ln.split()
        if w[0] == "T":
            aud = int(w[2])
            n_pl = int(w[5]) if len(w) > 5 else 1
        elif w[0] == "I":
            items.append(("X", int(w[1]), int(w[2]), [(0, 0)]))
        elif w[0] == "C":
            chaps.append((5, int(w[1]), int(w[2])))
    t = N.Title(items, chaps)
    t.n_pl = n_pl
    return t, aud


def script(t, aud, seed, n_pl=1):
    """[(cycle, code, item, pts, arg)]: bursts well apart (3 x MERGE and a landing), presses
    inside a burst well under MERGE apart"""
    rnd = random.Random(seed)
    out = []
    c = 3000
    tracks = [i for i in range(16) if aud >> i & 1]

    def add(code, item=0, pts=0, arg=0):
        out.append((c, code, item, pts, arg))

    def burst(seq):
        nonlocal c
        r = rnd.random()
        if r < 0.15:                           # a reserved command against the first answer
            add(BADSYNC)
            c += 1
        elif r < 0.3:                          # a Next in the cycle the first press is answered
            add(PRESSSYNC)
            c += 1
        for k, d in enumerate(seq):
            add(NEXT if d == "n" else PREV)
            c += rnd.randint(50, MERGE // 3)
        if rnd.random() < 0.3:
            # a Prev a fraction of a second after the landing (the merge, the query, the
            # seek, the first picture: <= ~4,500 cycles): back a chapter, not a restart
            c += 5200 - 50
            add(PREV)
        c += 3 * MERGE + 4000

    def playl(pl=None, item=None):
        """P9: a PLAYLIST (a menu's play): a playlist (1 in 6 one past the last: refused), an
        item (1 in 6 past the last: the reader plays item 0 at IN) and a key inside it"""
        nonlocal c
        pl = rnd.choice(list(range(n_pl)) * 5 + [n_pl]) if pl is None else pl
        if item is None:
            item = rnd.randrange(len(t.items)) if rnd.random() < 5 / 6 else len(t.items)
        if item < len(t.items):
            i = t.items[item]
            pts = rnd.randint(i.in_pts, max(i.in_pts, i.out_pts - 1))
        else:
            pts = rnd.randint(0, 1 << 40)
        add(PLAYL, item, pts, pl)

    def trick_episode(how=None, d=None, ups=None):
        nonlocal c
        d = d or rnd.choice([FF, REW])
        how = how or rnd.choice(["play", "playpause", "opposite", "pause", "stop", "next", "prev", "goto", "end", "early",
                                 "playlist"])
        if how == "end":                       # run into the title's end (FF) or start (REW)
            if d == FF:
                it = len(t.items) - 1
                add(SEEK, it, max(t.items[it].in_pts, t.items[it].out_pts - 2 * 90000))
            else:
                add(SEEK, 0, t.items[0].in_pts + 90000)
            c += 3 * MERGE + 4000
        if how == "cross":                     # across an item boundary, then play
            if d == FF:
                # (4 s before OUT: the landing then plays ~1.7 s before the press, and the first
                #  hop's 5 s reaches the edge)
                add(SEEK, 0, max(t.items[0].in_pts, t.items[0].out_pts - 4 * 90000))
            else:
                add(SEEK, 1, t.items[1].in_pts + 90000)
            c += 3 * MERGE + 4000
        add(d)
        if how == "exitsync":                  # P41: a PLAY in the cycle a hop falls due (the bench
            c += 1                             #   times it), after a few hops
            add(EXITSYNC)
            c += 3 * HOP_MIN + 3 * MERGE + 6000
            return
        if how == "early":                     # left before the first hop: nothing to restore
            c += rnd.randint(100, HOP_MIN - 200)
            add(rnd.choice([PLAY, PLAYPAUSE, PAUSE, FF + REW - d]))
            c += 3 * MERGE + 4000
            return
        length = 30000 if how == "end" else 12000 if how == "cross" else rnd.randint(4000, 40000)
        t0 = c
        for at in sorted(rnd.randint(200, length - 100) for _ in range(rnd.randint(0, 3) if ups is None else ups)):
            c = t0 + at                        # speed-ups (3 stays), in time order
            add(d)
        c = t0 + length
        if how == "end":
            c += 3 * MERGE + 4000
            return
        if how in ("play", "cross"):
            add(PLAY)
        elif how == "playpause":
            add(PLAYPAUSE)
        elif how == "pause":                  # fj#57: the PSP's X plays at normal speed, as PLAY
            add(PAUSE)
        elif how == "opposite":
            add(FF + REW - d)
        elif how == "stop":
            add(STOP)
            c += rnd.randint(3000, 8000)
            add(rnd.choice([PLAY, PLAYPAUSE]))
        elif how in ("next", "prev"):
            burst(rnd.choice(["n", "nn", "p", "pn"]) if how == "next" else rnd.choice(["p", "pp", "np"]))
            return
        elif how == "playlist":                # P9: a menu's play ends trick play
            playl(pl=rnd.randrange(n_pl))
        elif how == "time":                    # P6c: a Go To by time ends it too
            add(TIME, 0, rnd.randint(0, t.total))
        else:
            it = rnd.randrange(len(t.items))
            add(SEEK, it, rnd.randint(t.items[it].in_pts, max(t.items[it].in_pts, t.items[it].out_pts - 1)))
        c += 3 * MERGE + 6000

    for step in range(40):
        r = rnd.random()
        if r < 0.45:
            burst(rnd.choice(["n", "p", "nn", "pp", "np", "pn", "nnn", "ppn", "p"]))
            if rnd.random() < 0.2:             # a Prev 1-2 s after the landing: a restart, not a step back
                c += rnd.randint(SEC, 2 * SEC)
                burst("p")
        elif r < 0.6:                          # Go To a random key
            it = rnd.randrange(len(t.items))
            i = t.items[it]
            r2 = rnd.random()                  # 1 in 5 outside IN..OUT: the reader clamps it
            if r2 < 0.1:
                pts = max(0, i.in_pts - rnd.randint(1, 40000))
            elif r2 < 0.2:
                pts = i.out_pts + rnd.randint(1, 40000)
            else:
                pts = rnd.randint(i.in_pts, max(i.in_pts, i.out_pts - 1))
            add(SEEK, it, pts)
            c += 3 * MERGE + 4000
        elif r < 0.7:                          # a pause, or a stop, then play
            add(rnd.choice([PAUSE, PLAYPAUSE, STOP]))
            c += rnd.randint(500, 3000)
            add(rnd.choice([PLAY, PLAYPAUSE]))
            c += 1000
        elif r < 0.78 and len(tracks) > 1:     # the audio track
            if rnd.random() < 0.5:
                add(AUDIO)
            else:
                add(AUDIO_SET, arg=rnd.choice(tracks))
            c += 500
        elif r < 0.84:                         # a press while a seek is in flight
            add(NEXT)
            c += MERGE + 300
            add(rnd.choice([NEXT, PREV]))
            c += 3 * MERGE + 6000
        elif r < 0.86:                         # P6b4: trick play, and how it ends
            trick_episode()
        elif r < 0.87:                         # a landing with no picture: the watchdog
            add(NOPIC)
            c += 1                             # (the bench takes one script line a cycle)
            it = rnd.randrange(len(t.items))
            add(SEEK, it, t.items[it].in_pts)
            c += 3 * MERGE + 30000
        elif r < 0.88:
            # fix/skip-last-picture: a landing whose display ENDS with no picture (the stream's END
            # inside the skip: a target past every picture) -- the seek done, a TITLE_END, no
            # watchdog; then an absolute seek (the old picture stays shown: no press keys from it)
            add(ENDSKIP)
            c += 1
            it = rnd.randrange(len(t.items))
            add(SEEK, it, t.items[it].in_pts)
            c += 3 * MERGE + 8000
            it = rnd.randrange(len(t.items))
            add(SEEK, it, t.items[it].in_pts)
            c += 3 * MERGE + 4000
        elif r < 0.90:
            add(BADCMD)
            c += 200
        elif r < 0.95:                         # P9: a menu's play, from play or from stop
            if rnd.random() < 0.3:
                add(STOP)
                c += rnd.randint(500, 3000)
            playl()
            c += 3 * MERGE + 4000
        else:                                  # just play a while (the tracker crosses chapters)
            c += rnd.randint(5 * SEC, 40 * SEC)
    # P6b4: every script runs trick play into both ends of the title, and out through a pause
    # (fj#57: it plays) and a stop (it holds the picture; PLAY then plays)
    trick_episode("end", FF)
    trick_episode("end", REW)
    trick_episode("pause")
    trick_episode("stop")
    trick_episode("play", ups=2)               # through all three speeds
    trick_episode("opposite")                  # the opposite arrow returns to play (D9)
    trick_episode("next")                      # a chapter press during trick play: from the
    trick_episode("prev")                      #   picture shown
    if len(t.items) > 1:                       # across an item boundary, both ways
        trick_episode("cross", FF)
        trick_episode("cross", REW)
    # P9: a PLAYLIST from STOP, one refused, an item past the last, one during trick play
    add(STOP)
    c += 2000
    playl(pl=n_pl - 1, item=0)
    c += 3 * MERGE + 4000
    playl(pl=n_pl)
    c += 3 * MERGE + 4000
    playl(pl=0, item=len(t.items))
    c += 3 * MERGE + 4000
    trick_episode("playlist")
    trick_episode("exitsync", FF)              # P41: an exit in the cycle a hop falls due
    # P6c: Go To by time -- random times, 0:00:00, every item boundary and the tick before it,
    # the end and past it (D16: the last item's OUT - 4), from pause and from stop (refused), one
    # with a press during its seek (judged from the landing), one during trick play
    tm = [rnd.randint(0, max(0, t.total - 1)) for _ in range(4)] + [0]
    acc = 0
    for it in t.items[:-1][:3]:
        acc += it.duration
        tm += [acc - 1, acc]
    tm += [t.total, t.total + rnd.randint(1, 1 << 30)]
    for x in tm:
        add(TIME, 0, x)
        c += 3 * MERGE + 4000
    add(PAUSE)
    c += 1000
    add(TIME, 0, rnd.randint(0, max(0, t.total - 1)))  # from pause: the seek resumes play
    c += 3 * MERGE + 4000
    add(STOP)
    c += 1000
    add(TIME, 0, 0)                            # from stop: refused (BAD), as SEEK is
    c += 1000
    add(PLAY)
    c += 2000
    add(TIME, 0, rnd.randint(0, max(0, t.total - 1)))
    c += 300
    add(NEXT)                                  # during the TIME's seek: from its landing
    c += 3 * MERGE + 6000
    trick_episode("time")
    # fix/skip-last-picture: a seek to the last item's end whose display ENDS with no picture
    # (every script has one: the bench's [tend] wants it), then an absolute seek
    add(ENDSKIP)
    c += 1
    add(SEEK, len(t.items) - 1, N.PTS_MAX)
    c += 3 * MERGE + 8000
    add(SEEK, 0, t.items[0].in_pts)
    c += 3 * MERGE + 4000
    if t.chapters:                             # Next past the last chapter
        last = t.chapters[-1]
        add(SEEK, last[0], last[1] + 1000)
        c += 3 * MERGE + 4000
        add(BADSYNC)                           # ... against a NO_CHAPTER answer
        c += 1
        burst("n")
        add(PRESSSYNC)                         # ... and a Next queued in that answer's cycle
        c += 1
        burst("nn")
    add(END)
    c += 2000
    return out, c


# P7: the synthetic titles' subtitle tracks (0x80 + n): several, with a gap, and none on one
SYNTH_SUB = {"nochap": 0x00000023, "multi": 0x80000001, "dup": 0x00000000, "short": 0x00000004,
             "dense": 0x00000003}


def add_subs(sc, sub, seed, end):
    """P7: SUB presses merged into a script from their OWN random stream (the other commands'
    sequence is unchanged), on cycles no other line uses (the bench takes one line a cycle).
    Enough to wrap the track list (Off -> each declared -> Off) at least twice. P9: as many
    SUB_SETs (a declared track, off, or 1 in 4 an undeclared one: refused)."""
    rnd = random.Random(seed * 7919 + 12)
    used = set(x[0] for x in sc)
    n = 2 * (bin(sub).count("1") + 1) + 4
    out = list(sc)
    decl = [k for k in range(32) if sub >> k & 1]
    undecl = [k for k in range(32) if not sub >> k & 1]
    for j in range(2 * n):
        c = rnd.randint(5000, max(5001, end - 2000))
        while c in used or c + 1 in used or c - 1 in used:
            c += 3
        used.add(c)
        if j % 2 == 0:
            out.append((c, SUB, 0, 0, 0))
        else:
            r = rnd.random()
            if decl and r < 0.5:
                v = 32 | rnd.choice(decl)
            elif r < 0.75 or not undecl:
                v = 0
            else:
                v = 32 | rnd.choice(undecl)
            out.append((c, SUB_SET, v, 0, 0))
    out.sort(key=lambda x: x[0])
    return out


def gen(a):
    if a.disc:
        t = N.from_iso(a.disc)
        import umd_iso
        import umd_clpi
        with umd_iso.UmdIso(a.disc) as iso:
            clp = umd_clpi.parse(iso.read("/UMD_VIDEO/CLIPINF/%s.CLP" % t.items[0].clip, record=False))
        aud = 0
        for s in clp["streams"]:
            if s["kind"] == "audio" and s["substream_id"] < 16:
                aud |= 1 << s["substream_id"]
        aud = aud or 1
        sub = 0
        for s in clp["streams"]:
            if s["kind"] == "subtitle":
                sub |= 1 << (s["substream_id"] - 0x80)
        import umd_playlist
        with umd_iso.UmdIso(a.disc) as iso:
            n_pl = len(umd_playlist.parse(iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False))["playlists"])
    else:
        t, aud = synth(a.synth)
        sub = SYNTH_SUB.get(a.synth, 0)
        n_pl = N_PL_SYNTH
    write_title(t, aud, a.out + ".title", sub, n_pl)
    sc, end = script(t, aud, a.seed, n_pl)
    sc = add_subs(sc, sub, a.seed, end)
    with open(a.out + ".script", "w") as f:
        f.write("%d %d\n" % (len(sc), end))
        for c, code, item, pts, arg in sc:
            f.write("%d %d %d %d %d\n" % (c, code, item, pts, arg))
    print("%s: %d items, %d chapters, %d playlists, audio 0x%04x, subtitles 0x%08x, %d commands over %d cycles"
          % (os.path.basename(a.out), len(t.items), len(t.chapters), n_pl, aud, sub, len(sc), end))
    return 0


class Run(object):
    """One trick-play run (P6b4): from its entry (a K line) to its exit."""
    def __init__(self, key, rev):
        self.tgt, self.edge, self.fwd = key, False, not rev
        self.hops, self.exit, self.end_req = 0, None, None


def trick(t, log, errs):
    """Walk the log's trick play: every hop's request and landing against umd_nav_ref, and the
    exits. Returns (the log indices of the hops' S lines -- not claimable by the requests --,
    {log index: restore request}: a seek to the run's final carried target is due there, and
    {P line index: its run} for a burst pressed during trick play)."""
    hop_s, restores, burst_run = set(), {}, {}
    run, pend = None, None                      # pend: a hop issued, its S line next
    n_hops = 0
    cov = {"cross_f": 0, "cross_r": 0, "end_f": 0, "end_r": 0, "fast": 0}
    for i, x in enumerate(log):
        k = x[0]
        if k == "K":
            run = Run((int(x[2]), int(x[3])), x[4] == "1")
        elif k == "J":
            e = int(x[1])
            if run is None:
                errs.append("hop at %d outside trick play" % e)
                continue
            if run.exit is not None and e > run.exit:
                errs.append("hop at %d after trick play's exit at %d" % (e, run.exit))
            if run.end_req is not None:
                errs.append("hop at %d past the title's %s (the model resumes play)" % (e, "end" if run.fwd else "start"))
            delta = sum(int(x[2 + j]) * N.TRICK_RATES[j] * TICK_N for j in range(3))
            cov["fast"] += int(x[3]) > 0 or int(x[4]) > 0
            q = t.hop_request(run.tgt, run.edge, run.fwd, min(delta, (1 << 32) - 1))
            if q is None:
                errs.append("hop at %d: the model has none here" % e)
                continue
            pend = (e, q)
        elif k == "S" and pend is not None:
            e, (req, sat) = pend
            pend = None
            hop_s.add(i)
            got = (int(x[2]), int(x[3]))
            if got != req:
                errs.append("hop issued at %d (%s from %s, edge %s): requested %s, the model %s"
                            % (e, "fwd" if run.fwd else "rev", run.tgt, run.edge, got, req))
            if req[0] != run.tgt[0]:
                cov["cross_f" if run.fwd else "cross_r"] += 1
            _r, run.tgt, run.edge = t.hop_land(req, sat, run.fwd)
            run.hops += 1
            n_hops += 1
            if run.exit is None and t.hop_request(run.tgt, run.edge, run.fwd, 0) is None:
                run.end_req = i                 # the title's end: play resumes after this landing
                restores[i] = run
                cov["end_f" if run.fwd else "end_r"] += 1
        elif k == "M" and run is not None:
            code, spd = int(x[2]), int(x[5])
            if spd != 0 and run.exit is None:   # a command during trick play
                if code in (PLAY, PLAYPAUSE, PAUSE) or (code in (FF, REW) and (code == FF) != run.fwd):
                    run.exit = int(x[1])
                    restores.pop(run.end_req, None)
                    run.end_req = None
                    if run.hops:
                        restores[i] = run
                elif code == STOP:
                    run.exit = int(x[1])
                    restores.pop(run.end_req, None)
                    run.end_req = None
                    run.held = True
            elif spd == 0 and code in (PLAY, PLAYPAUSE) and getattr(run, "held", False):
                run.held = False                # PLAY after a STOP in trick play
                if run.hops:
                    restores[i] = run
        elif k == "P" and run is not None and len(x) > 6 and x[6] == "1":
            if run.exit is None:
                run.exit = int(x[1])
                restores.pop(run.end_req, None)
                run.end_req = None
            burst_run[i] = run
        elif ((k == "G" and len(x) > 4 and x[4] == "1") or (k == "H" and len(x) > 4 and x[3] == "1" and x[4] == "1") or
              (k == "Y" and len(x) > 6 and x[5] == "1" and x[6] == "1")) \
                and run is not None and run.exit is None:
            run.exit = int(x[1])
            restores.pop(run.end_req, None)
            run.end_req = None
            run.held = False
    # coverage: every script runs into both ends and through the speeds; a multi-item title
    # crosses an item boundary both ways (the forced episodes: a run that never did is a
    # measurement of nothing)
    need = ["end_f", "end_r", "fast"] + (["cross_f", "cross_r"] if len(t.items) > 1 else [])
    for k in need:
        if not cov[k]:
            errs.append("coverage: no hop did %s (%s)" % (k, cov))
    return hop_s, restores, burst_run, n_hops, cov


def check(a):
    t, _aud = read_title(a.stem + ".title")
    log = [ln.split() for ln in open(a.stem + ".log") if ln[:1].isalpha() and ln[1:2] == " "]
    errs = []
    hop_s, restores, burst_run, n_hops, cov = trick(t, log, errs)
    seeks = [x for i, x in enumerate(log) if x[0] == "S" and i not in hop_s]
    # the requests, in order: bursts of presses (less than MERGE apart), Go Tos and trick play's
    # restores (P6b4)
    reqs = []
    for i, x in enumerate(log):
        if i in restores:
            reqs.append(("R", ["R", x[1]], restores[i]))
        elif x[0] == "P":
            cyc = int(x[1])
            if reqs and reqs[-1][0] == "B" and cyc - int(reqs[-1][1][-1][1]) < MERGE:
                reqs[-1][1].append(x)
            else:
                reqs.append(("B", [x], burst_run.get(i)))
        elif x[0] == "G":
            reqs.append(("G", x, None))
        elif x[0] == "H":                  # P6c: a TIME (the mock's landing: X)
            reqs.append(("H", x, None))
        elif x[0] == "Y":                  # P9: a PLAYLIST (Y: L is the landings' line)
            reqs.append(("L", x, None))
    # P6c: the mock's TIME landings are the model's (a burst during the seek is judged from them)
    tland = {}
    n_h = 0
    for x in log:
        if x[0] == "X":
            r = t.time_seek(int(x[2]))
            got = (int(x[3]), int(x[4]))
            if got != (r[0], r[4]):
                errs.append("the mock landed TIME %s at %s, the model at %s" % (x[2], got, (r[0], r[4])))
            tland[int(x[2])] = got
    si = 0                 # the next seek not yet claimed: every request that seeks claims one, in order
    prev_target = None
    n_b = 0
    n_l = 0
    for k, (kind, r, run) in enumerate(reqs):
        first = int(r[0][1]) if kind == "B" else int(r[1])
        nxt = (int(reqs[k + 1][1][0][1]) if reqs[k + 1][0] == "B" else int(reqs[k + 1][1][1])) \
            if k + 1 < len(reqs) else 1 << 62
        if kind == "G":
            want = (int(r[2]), int(r[3]))
        elif kind == "H":                  # P6c: NAV_TIME asks (item -1, the time), playlist -2
            n_h += 1
            want = (-1, int(r[2])) if r[4] == "1" else None
        elif kind == "L":                  # P9: its key as given, if the DUT could take it
            n_l += 1
            want = (int(r[3]), int(r[4])) if r[6] == "1" else None
        elif kind == "R":                  # trick play's end: a seek to the last hop's target
            want = run.tgt
        else:
            n_b += 1
            if run is not None:            # pressed during trick play: from the picture shown
                start = (int(r[0][3]), int(r[0][4]))
            elif r[0][5] == "1":           # during a seek: from its target (the pending key)
                if prev_target is None:
                    errs.append("burst at %d: in flight, but no target before it" % first)
                    continue
                start = prev_target
            else:
                start = (int(r[0][3]), int(r[0][4]))
            seq = "".join("p" if x[2] == "1" else "n" for x in r)
            want, _nc = t.presses(start, seq)
            key, n_msg = start, 0
            for ch in seq:
                nx = t.next_chapter(key) if ch == "n" else t.prev_chapter(key)
                if nx is None:
                    n_msg += ch == "n"
                else:
                    key = nx
            msgs = [x for x in log if x[0] == "N" and first <= int(x[1]) < nxt]
            if len(msgs) != n_msg:
                errs.append("burst at %d (%s from %s): %d NO_CHAPTER, want %d" % (first, seq, start, len(msgs), n_msg))
            if want is None and run is not None and run.hops:
                want = run.tgt             # it found nothing: play resumes from the shown key
        what = {"G": "goto", "H": "time", "R": "trick play's exit",
                "L": "playlist %s" % (r[2] if kind == "L" else "")}.get(kind) \
            or "burst (%s from %s)" % (seq, start)
        if want is None:
            if si < len(seeks) and int(seeks[si][1]) < nxt and int(seeks[si][1]) > first:
                errs.append("%s at %d: no seek expected, got %s" % (what, first, seeks[si][2:4]))
                si += 1
            continue
        if si >= len(seeks):
            errs.append("%s at %d: no seek, want %s" % (what, first, want))
            continue
        if kind == "R" and int(seeks[si][1]) - first > RESTORE_MAX:
            errs.append("trick play's exit at %d: its seek %d cycles later (> %d): held, not resumed"
                        % (first, int(seeks[si][1]) - first, RESTORE_MAX))
        got = (int(seeks[si][2]), int(seeks[si][3]))
        if got != want:
            errs.append("%s at %d: seek %s at %s, want %s" % (what, first, got, seeks[si][1], want))
        # P9: a PLAY carries its playlist; nothing else asks a PLAY
        got_pl = int(seeks[si][4]) if len(seeks[si]) > 4 else -1
        want_pl = int(r[2]) if kind == "L" else -2 if kind == "H" else -1
        if got_pl != want_pl:
            errs.append("%s at %d: the port's playlist %d, want %d (-1: a SEEK)" % (what, first, got_pl, want_pl))
        si += 1
        prev_target = tland.get(want[1], want) if kind == "H" else want
    if si != len(seeks):
        errs.append("%d seeks no request asked for (from %s)" % (len(seeks) - si, seeks[si][1] if si < len(seeks) else "-"))
    # the settled chapter
    nz = 0
    for x in log:
        if x[0] == "Z":
            key = (int(x[2]), int(x[3]))
            want = t.chapter_at(key)[0]
            if int(x[4]) != want:
                errs.append("settled at %s (key %s): chapter %s, want %d" % (x[1], key, x[4], want))
            nz += 1
    if nz == 0:
        errs.append("no settled point was logged (the chapter check measured nothing)")
    if n_b == 0:
        errs.append("no burst was logged")
    if n_l == 0:
        errs.append("no PLAYLIST was logged (the P9 check measured nothing)")
    if n_h == 0 or not tland:
        errs.append("no TIME was logged or landed (the P6c check measured nothing)")
    for e in errs[:20]:
        print("FAIL [model] " + e)
    if errs:
        return 1
    print("player_ctl_ref: %d bursts, %d playlists, %d times, %d seeks, %d hops (%s), %d settled chapters as umd_nav_ref says"
          % (n_b, n_l, n_h, len(seeks), n_hops, " ".join("%s %d" % kv for kv in sorted(cov.items())), nz))
    print("PASS: player_ctl_ref")
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    g = sub.add_parser("gen")
    g.add_argument("--disc")
    g.add_argument("--synth")
    g.add_argument("--seed", type=int, default=1)
    g.add_argument("--out", required=True)
    c = sub.add_parser("check")
    c.add_argument("--stem", required=True)
    a = ap.parse_args(argv)
    return gen(a) if a.cmd == "gen" else check(a)


if __name__ == "__main__":
    sys.exit(main())
