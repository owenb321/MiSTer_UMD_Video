#!/usr/bin/env python3
"""The P6b navigation model (docs/transport.md S2.4-S2.7): what a seek, a chapter skip,
IN / OUT, the time display and a trick-play hop resolve to, on a UMD title. The golden
for P6b2's reader navigation (umd_reader's query port) and P6b3's player_ctl; written
from the format as the P1 parsers read it (umd_playlist, umd_clpi) and from the PSP's
measured behaviour, never from the RTL.

A position is a KEY (item, pts): a mark names its item and its PTS lies on that item's
clip's timeline, so on a multi-item title (My Chemical Romance, Now That's What I Call
Music 2006) the PTS alone does not say where a picture is (docs/transport.md S1).

The rules, each with its source:
  - EP lookup: the LAST video entry at or before the target, the first entry for a
    target before it (a seek lands on an I picture at or before where it asked).
  - Chapters: the type-5 marks (type 16 is an Endmark, never a chapter), ordered by
    their key -- NOT by table order: nothing in the format promises it.
  - Next: the first chapter after the key; None past the last ("There is no chapter
    available.", the PSP).
  - Prev: back to the previous chapter only when the key is less than 1 s after the
    current chapter's start, else a restart of it (the PSP: 1 s after the start
    restarts); the first chapter restarts.
  - Repeated presses: each evaluated from the pending target (two quick Prevs go back).
  - IN / OUT: an item starts at the entry at/before IN and shows from IN; the reader
    stops at the first entry at or after OUT; the display ends before OUT (exclusive). A
    seek's target is clamped into [IN, OUT - 4] (fix/skip-last-picture; clamp() derives the 4).
  - Elapsed: the earlier items' durations plus (pts - IN), clamped to the item.
  - Go To by time (P6c, D15 / D16, measured on the PSP 2026-10-03): the time is the PLAYING
    playlist's (a video a menu plays alone counts from 0:00:00; Play All spans them all);
    the key is the item whose span holds it, and a time past the end is the last item's
    OUT - 4 (the seek's clamp); player_ctl lands that one with no skip, so the last GOP plays
    out and the title's end takes the usual path (the PSP returned to the disc's menu). The ▼ marker of a chapter is its
    elapsed time, shown only for a chapter in the item now streaming (D15).
  - Trick play (D1): a hop's target advances rate x wall time (the PSP's ~20 / 33 / 55x),
    landing on the entry at/before it in both directions (the reader's one lookup; P6b4);
    at an item's edge the next hop crosses into the neighbour, at the title's ends play
    resumes.

    umd_nav_ref.py IMAGE.iso [--chapters] [--at SECONDS]
"""
import argparse
import bisect
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

TICKS = 90000                  # 90 kHz
PREV_BACK_TICKS = 90000        # Prev goes back only within 1 s of the chapter's start (the PSP)
MARK_CHAPTER = 5
TRICK_RATES = (20, 33, 55)     # content seconds per real second, Forward / Reverse 1-3 (the PSP, Akira)
PTS_MAX = (1 << 48) - 1        # a key's PTS is u48 (a mark's width)
END_GUARD = 4                  # a seek's target stays this many ticks below OUT (clamp(): the derivation)


class NavError(Exception):
    pass


class Item(object):
    def __init__(self, clip, in_pts, out_pts, entries):
        self.clip, self.in_pts, self.out_pts = clip, in_pts, out_pts
        self.entries = entries               # [(pts, sector)] of the clip's video EP map
        self.pts = [e[0] for e in entries]

    @property
    def duration(self):
        return max(0, self.out_pts - self.in_pts)


class Title(object):
    """items: [(clip, in_pts, out_pts, [(pts, sector)])]; marks: [(type, item, pts)] in
    TABLE order (they need not be sorted)."""

    def __init__(self, items, marks):
        self.items = [Item(*i) for i in items]
        for k, it in enumerate(self.items):
            if any(b <= a for a, b in zip(it.pts, it.pts[1:])):
                raise NavError("item %d: the EP map is not strictly increasing (a binary search assumes it)" % k)
        self.marks = list(marks)
        self.chapters = sorted((it, pts) for typ, it, pts in marks
                               if typ == MARK_CHAPTER and it < len(self.items))

    # ---- the entry point map ------------------------------------------------------------

    def ep_index(self, item, pts):
        """The last entry at or before pts (the first entry for an earlier pts)."""
        p = self.items[item].pts
        if not p:
            raise NavError("item %d has no video entry" % item)
        return max(0, bisect.bisect_right(p, pts) - 1)

    def ep_index_after(self, item, pts):
        """The first entry at or after pts, or None."""
        p = self.items[item].pts
        k = bisect.bisect_left(p, pts)
        return k if k < len(p) else None

    def clamp(self, item, pts):
        """A seek's target clamped into the item's [IN, OUT - END_GUARD]. 48-bit, as the
        reader computes it.

        OUT is exclusive, so the target must lie before it; but it must lie far enough before
        it that the display's skip (D2) still SHOWS the picture holding it. The skip drops a
        record whose estimated end is less than one tick past the target (disp_ctl's
        SKIP_TOL: the tolerance that lets a target at a stored whole-tick PTS skip the record
        before it). Two roundings sit between a picture's true end and that estimate: an
        untagged picture's time is extrapolated from the last PES PTS, itself the FLOOR of
        the exact time (< 1 tick early), and OUT is a whole tick (< 1 tick past the true end,
        when it is the last picture's end rounded up). So the target needs more than
        1 + 1 + 1 = 3 ticks below OUT to keep the last picture: OUT - 3 sits at the bound,
        OUT - 4 has a tick of margin. OUT - 1 (P6b4's clamp) lost the last picture on Akira:
        its estimated end lay 0.5 tick past OUT - 1, the whole GOP was skipped, the END never
        taken and the picture before the seek stayed up (docs/display.md S11).

        A picture lasts at least a field (1,501 ticks), so OUT - 4 lies inside the last one.
        An item shorter than END_GUARD ticks (no picture) clamps to IN."""
        it = self.items[item]
        lim = it.out_pts - END_GUARD if it.out_pts >= END_GUARD else 0
        return max(min(pts, lim), it.in_pts)

    def seek(self, key):
        """Where a seek to KEY lands: (item, entry index, entry pts, sector, skip_until).
        The display skips the stores before skip_until (exact landing, D2); the target is
        clamped into the item's [IN, OUT)."""
        item, pts = key
        it = self.items[item]
        pts = self.clamp(item, pts)
        k = self.ep_index(item, pts)
        return item, k, it.entries[k][0], it.entries[k][1], pts

    def item_start(self, item):
        """Where an item starts: at the entry at or before its IN, showing from IN (the
        reader's walk takes IN itself, unclamped)."""
        it = self.items[item]
        k = self.ep_index(item, it.in_pts)
        return item, k, it.entries[k][0], it.entries[k][1], it.in_pts

    def item_stop_sector(self, item):
        """The reader stops the item before this sector: the first entry AT or after OUT
        (OUT is exclusive: the picture at OUT is not shown, and a GOP's bytes lie before
        the next entry's sector); None: the clip's end."""
        it = self.items[item]
        k = bisect.bisect_left(it.pts, it.out_pts)
        return it.entries[k][1] if k < len(it.entries) else None

    def item_span(self, item, nsec, sector=None):
        """The clip-relative sectors [first, end) the reader streams of an item: from
        `sector` (a seek's landing; default the item's start at IN) to the item's stop
        (the first entry at or after OUT), or the clip's end (`nsec` sectors). Empty when
        the stop is at or before the start, or the start lies past the clip."""
        if sector is None:
            sector = self.item_start(item)[3]
        stop = self.item_stop_sector(item)
        end = nsec if stop is None else min(stop, nsec)
        return (sector, max(sector, end)) if sector < nsec else (sector, sector)

    def stream_plan(self, nsecs, item, sector=None):
        """What the reader streams from a landing to the title's end: [(item, first,
        end)] per item, clip-relative. nsecs[k] = item k's clip size in sectors."""
        out = [(item,) + self.item_span(item, nsecs[item], sector)]
        for k in range(item + 1, len(self.items)):
            out.append((k,) + self.item_span(k, nsecs[k]))
        return out

    # ---- chapters -------------------------------------------------------------------------

    def chapter_at(self, key):
        """(chapter number from 1, its key) of the chapter containing KEY; (0, None)
        before the first chapter, or on a title with none."""
        n = bisect.bisect_right(self.chapters, key)
        return (n, self.chapters[n - 1]) if n else (0, None)

    def next_chapter(self, key):
        """The first chapter after KEY; None past the last (the PSP's message)."""
        n = bisect.bisect_right(self.chapters, key)
        return self.chapters[n] if n < len(self.chapters) else None

    def prev_chapter(self, key):
        """Back only within 1 s of the current chapter's start, else a restart of it; the
        first chapter restarts; None before any chapter."""
        n, cur = self.chapter_at(key)
        if cur is None:
            return None
        if key[0] == cur[0] and key[1] - cur[1] < PREV_BACK_TICKS and n > 1:
            return self.chapters[n - 2]
        return cur

    def chapter_query(self, key):
        """The reader's chapter query (umd_reader's NAV_CHAP, docs/transport.md S2.4):
        (rank, n_chapters, cur, prev, next). rank counts the chapters at or before KEY;
        cur / prev are the last two of them in key order and next the first after it
        (None where there is none). Equal keys count as distinct marks, as the sorted
        list holds them, so prev may equal cur."""
        n = bisect.bisect_right(self.chapters, key)
        c = self.chapters
        return (n, len(c), c[n - 1] if n >= 1 else None, c[n - 2] if n >= 2 else None,
                c[n] if n < len(c) else None)

    def presses(self, key, seq):
        """A burst of presses ('n' / 'p', merged into one seek), each evaluated from the
        previous one's target. Returns (target, no_chapter): the last target a press found
        (None: no press moved, so nothing to seek) and whether a Next ran past the last
        chapter (the PSP's message; the presses before it still land)."""
        target, no_chapter = None, False
        for c in seq:
            t = self.next_chapter(key) if c == "n" else self.prev_chapter(key)
            if t is None:
                no_chapter = no_chapter or c == "n"
                continue
            key = target = t
        return target, no_chapter

    # ---- the time ---------------------------------------------------------------------------

    @property
    def total(self):
        return sum(it.duration for it in self.items)

    def elapsed(self, key):
        item, pts = key
        it = self.items[item]
        return sum(x.duration for x in self.items[:item]) + min(max(pts - it.in_pts, 0), it.duration)

    def key_at(self, ticks):
        """The key at `ticks` of the title's time (Go To's time box)."""
        ticks = max(0, ticks)
        for k, it in enumerate(self.items):
            if ticks < it.duration or k == len(self.items) - 1:
                return (k, it.in_pts + min(ticks, it.duration))
            ticks -= it.duration
        raise NavError("a title with no items")

    def time_seek(self, ticks):
        """Go To by time (P6c, the reader's NAV_TIME): where a seek to the playing playlist's
        time `ticks` lands -- seek(key_at(ticks)); past the end the last item's OUT - 4 (D16)."""
        return self.seek(self.key_at(ticks))

    def marker(self, key, streaming):
        """Go To's ▼ for a chapter KEY (its title time), or None when the key's item is not
        the item now streaming (D15: placing it would take an item walk per step)."""
        return self.elapsed(key) if key[0] == streaming else None

    # ---- trick play (D1; the hop rule decided in P6b4, docs/transport.md S2.6) ---------------
    #
    # A hop is a seek to a TARGET carried from hop to hop: forward target + delta, reverse
    # target - delta, delta = the speed's rate x the wall time since the last hop was issued
    # (so the rate holds whatever a hop costs). It lands, like every seek, on the entry AT OR
    # BEFORE the clamped target (the reader's one lookup) and shows that entry's I picture; the
    # carried target becomes the CLAMPED target (the reader's nav_skip). When the clamp moved
    # the target -- forward: down to OUT - 4, reverse: up to IN (or the request saturated at 0)
    # -- the last hop reached the item's edge, and the next one crosses: forward to the next
    # item's IN (a request of PTS 0, clamped up), reverse to the previous item's end (PTS_MAX,
    # clamped down to OUT - 4). The overshoot is dropped at a crossing: player_ctl knows no
    # item's duration (the reader's clamp is the only boundary it sees). Past the title's last
    # item forward, or its first reverse, the trick ends and play resumes (the maintainer,
    # 2026-09-28).

    def hop_request(self, tgt, edge, forward, delta):
        """The next hop's seek request from the carried target TGT (item, pts) and EDGE (the
        last landing was clamped at the item's edge in the travel direction): (request key,
        saturated) -- saturated: a reverse request that reached PTS 0 -- or None at the
        title's end (forward) / start (reverse): play resumes."""
        item, pts = tgt
        if edge:
            if forward:
                return ((item + 1, 0), False) if item + 1 < len(self.items) else None
            return ((item - 1, PTS_MAX), False) if item > 0 else None
        if forward:
            return (item, (pts + delta) & PTS_MAX), False
        return (item, max(0, pts - delta)), pts <= delta

    def hop_land(self, req, sat, forward):
        """Where a hop request lands: (the seek's (item, entry, entry pts, sector, skip), the
        new carried target, edge)."""
        r = self.seek(req)
        skip = r[4]
        edge = (skip < req[1]) if forward else (sat or skip > req[1])
        return r, (r[0], skip), edge

    def trick(self, key, steps):
        """A run of hops from the shown KEY: steps = [(forward, delta)] per hop. Returns the
        landings [(request, seek result)] and whether (and after which hop) play resumed."""
        tgt, edge, out = key, False, []
        for forward, delta in steps:
            q = self.hop_request(tgt, edge, forward, delta)
            if q is None:
                return out, True
            req, sat = q
            r, tgt, edge = self.hop_land(req, sat, forward)
            out.append((req, r))
        return out, False


def from_iso(path):
    """The main title (the longest playlist, as the core picks it) of an image."""
    import umd_iso
    with umd_iso.UmdIso(path) as iso:
        return from_umd(iso)


def from_umd(iso, pl_raw=None, playlist=None):
    """The main title of an open umd_iso.UmdIso (a path's, or a synthetic image's bytes);
    pl_raw: a PLAYLIST.UMD to use instead of the image's (a malformed image's good twin);
    playlist: that playlist instead of the longest (P9's NAV_PLAY)."""
    if pl_raw is None:
        pl_raw = iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False)
    return from_raw(pl_raw, lambda clip: iso.read("/UMD_VIDEO/CLIPINF/%s.CLP" % clip, record=False),
                    playlist)


def from_raw(pl_raw, clp, playlist=None):
    """The main title from PLAYLIST.UMD's bytes and clp(name) -> that clip's CLP bytes;
    playlist: that playlist instead of the longest (P9's NAV_PLAY: a disc menu chooses)."""
    import umd_clpi
    import umd_playlist
    pl = umd_playlist.parse(pl_raw)
    e = pl["playlists"][umd_playlist.main_playlist(pl) if playlist is None else playlist]
    maps = {}
    items = []
    for it in e["items"]:
        clip = it["clip_name"]
        if clip not in maps:
            maps[clip] = [(p, s) for _f, p, s in umd_clpi.video_map(umd_clpi.parse(clp(clip)))]
        items.append((clip, it["in_pts"], it["out_pts"], maps[clip]))
    return Title(items, [(m["type"], m["item"], m["pts"]) for m in e["marks"]])


def hms(ticks):
    s = int(ticks // TICKS)
    return "%d:%02d:%02d" % (s // 3600, s // 60 % 60, s % 60)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("image")
    ap.add_argument("--chapters", action="store_true", help="list the chapters and where each lands")
    ap.add_argument("--at", type=float, help="a title time in seconds: the key, its chapter, the seek")
    a = ap.parse_args(argv)
    t = from_iso(a.image)
    print("%d items, %s, %d chapters, %d marks" % (len(t.items), hms(t.total), len(t.chapters), len(t.marks)))
    if a.chapters:
        for n, ck in enumerate(t.chapters, 1):
            item, k, epts, sec, skip = t.seek(ck)
            print("  chapter %2d  item %d pts %d  %s  -> entry %d (pts %d, sector %d), %.3f s before it"
                  % (n, ck[0], ck[1], hms(t.elapsed(ck)), k, epts, sec, (skip - epts) / TICKS))
    if a.at is not None:
        key = t.key_at(int(a.at * TICKS))
        n, _c = t.chapter_at(key)
        item, k, epts, sec, skip = t.seek(key)
        print("  %s = item %d pts %d, chapter %d; a seek lands on entry %d (pts %d, sector %d); "
              "next %s, prev %s" % (hms(t.elapsed(key)), key[0], key[1], n, k, epts, sec,
                                   t.next_chapter(key), t.prev_chapter(key)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
