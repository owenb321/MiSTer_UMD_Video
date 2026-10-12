#!/usr/bin/env python3
"""Cut bench fixtures from a local UMD image into bench/umd/fixtures/gen/ (gitignored:
commercial media is never committed, only cut on the machine that has it).

Two kinds (bench/umd/README.md conventions: one byte per line for $readmemh, and a
<stem>.meta.hex of 32-bit words, 8 hex digits per line, word order below):

--clip N --pts A B | --lba S E     contiguous packs of one clip's .MPS
    <stem>.hex        the packs' bytes
    <stem>.meta.hex   [0] n_bytes  [1] first sector (clip-relative)  [2] n_packs
                      [3] clip number  [4] PTS of the EP entry the cut starts on
                      (0xFFFFFFFF for an --lba cut not on an entry)

--nav                              the sparse image the P2 reader walks to "play"
    <stem>.hex        every sector of every region below (the .MPS: only the packs
                      streamed), ascending LBA order
    <stem>.lba.hex    one 32-bit word per sector: its LBA (the TB maps LBA -> index)
    <stem>.reg.hex    the regions the reader may read, in walk order, REG_WORDS (11)
                      words each: first LBA, sectors, (KIND << 16) | item, then two
                      128-bit masks as 4 words each (bit j of word j/32): the regions
                      whose first read must come before this one's in the WALK
                      (REGION_DEPS), and once a command was issued (NAV_DEPS: seeks play
                      items out of order). A read outside every region is a bench
                      failure. The .MPS regions span the whole file even when only its
                      head is in <stem>.hex.
    <stem>.sseq.hex   the .MPS sectors the walk's stream (phase 0) must carry, in order
                      (LBA per word): each item from the entry at or before IN to the
                      first entry at or after OUT (umd_nav_ref, docs/transport.md S2.4)
    <stem>.nav.hex    the navigation script (P6b2): NAV_W words per command, NAV_WORDS
    <stem>.nseq.hex   the stream each SEEK must produce, concatenated (a command's
                      seq_off / n_seq index it)
    <stem>.sitem.hex  the playlist item of every .sseq.hex then .nseq.hex sector (the
                      stream's item tag is it mod 4)
    <stem>.exp.hex    the reader's outputs after the walk (EXP_WORDS), from the P1
                      parsers -- never from the RTL
    <stem>.title.hex  PARAM.SFO TITLE's raw bytes, 128 lines (the title BRAM)
    <stem>.lang.hex   48 words: bit 16 = declared, low 16 = the 2 language bytes
                      (0-15 audio 0x00-0x0F, 16-47 subtitle 0x80-0x9F), last item's CLP
    <stem>.meta.hex   [0] n_sectors  [1] n_regions  [2] n_sseq  [3] complete (every
                      .MPS sector is included: the reader must finish)  [4] main clip
                      [5] main playlist  [6] image bytes lo32  [7] image bytes hi32
                      [8] commands  [9] .nseq.hex words  [10] the file's mode (P8: 0 an
                      image, 1 a bare .MPS, 2 a .PMF)  [11] pmf_warn
    The walk (nav_walk): volume descriptors 16.. -> root -> UMD_VIDEO/ -> PARAM.SFO,
    PLAYLIST.UMD, CLIPINF/, STREAM/ -> per item of the main playlist: <clip>.CLP,
    <clip>.MPS. "main" is umd_playlist.main_playlist(): the LONGEST playlist, not #0.
    --stream-packs N keeps the first N stream sectors (0 = all of them).

    umd_fixture.py disc.iso --clip 1 --pts 90000 400000 --out akira_head
    umd_fixture.py disc.iso --nav [--stream-packs 16] --out akira_nav

Synthetic reader images (edge cases no disc has) are written in the same --nav format
by tools/umd_reader_cases.py.

P8, bare streams (docs/bare_streams.md): --bare-mps N cuts the main clip's first N packs as a
bare .MPS file, --bare-pmf takes the disc's UMD_VIDEO/ICON1.PMF whole (a real PSMF file); both
written as a --nav fixture whose "image" is that file (bare_fixture: goldens from psmf_ref).
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import umd_clpi  # noqa: E402
import umd_iso  # noqa: E402
import umd_playlist  # noqa: E402

SEC = 2048
OUT_DIR = os.path.join(ROOT, "bench", "umd", "fixtures", "gen")
NO_PTS = 0xFFFFFFFF


class FixtureError(Exception):
    pass


def write_bytes(path, data):
    with open(path, "w") as f:
        f.write("".join("%02x\n" % b for b in data))


def write_words(path, words):
    with open(path, "w") as f:
        for w in words:
            if not 0 <= w <= 0xFFFFFFFF:
                raise FixtureError("meta word %r does not fit 32 bits" % w)
            f.write("%08x\n" % w)


def read_words(path):
    return [int(l, 16) for l in open(path) if l.strip()]


def read_bytes(path):
    return bytes(int(l, 16) for l in open(path) if l.strip())


def cut_packs(iso, clip, first, last):
    """Sectors first..last-1 of the clip's .MPS (clip-relative)."""
    e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip)
    if not 0 <= first < last <= e.nsec:
        raise FixtureError("sectors %d..%d outside the clip (%d sectors)" % (first, last, e.nsec))
    return iso.read_sectors(e.lba + first, last - first)


def pts_range(iso, clip, a, b):
    """EP-aligned cut: from the entry at/before PTS a to the entry after PTS b."""
    c = umd_clpi.from_iso(iso, clip)
    ents = umd_clpi.video_map(c)
    if not ents:
        raise FixtureError("clip %d has no video EP map" % clip)
    s_pts, s_sec = umd_clpi.lookup(c, a)
    later = [e for e in ents if e[1] > b]
    end = later[0][2] if later else iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip).nsec
    return s_sec, end, s_pts


# Region kinds (the KIND code in <stem>.reg.hex) and the partial order of first reads.
# A dependency is what the DATA forces -- a directory before the files it lists, the
# playlist before the clip it names -- plus one reader contract: an item's .CLP before
# its .MPS (the track table must describe a clip before its bytes flow), and items play
# in order. It is never the order one implementation happens to read in.
KINDS = ["vd", "root", "umd_video", "sfo", "playlist", "clipinf", "stream", "clp", "mps"]
REGION_DEPS = {"vd": [], "root": ["vd"], "umd_video": ["root"], "sfo": ["umd_video"],
               "playlist": ["umd_video"], "clipinf": ["umd_video"], "stream": ["umd_video"],
               "clp": ["playlist", "clipinf"],
               "mps": ["playlist", "stream", "clp@item", "mps@item-1"]}
NAV_DEPS = dict(REGION_DEPS, mps=["playlist", "stream", "clp@item"])
MPS_KIND = KINDS.index("mps")
MAX_REGIONS = 128
REG_WORDS = 11


def deps_mask(regions, i, deps=REGION_DEPS):
    """Bit mask of the regions region i depends on (regions: [(lba, n, kind, item)])."""
    _, _, kind, item = regions[i]
    m = 0
    for d in deps[kind]:
        want, want_item = d, None
        if d.endswith("@item"):
            want, want_item = d[:-5], item
        elif d.endswith("@item-1"):
            want, want_item = d[:-7], item - 1
        for j, (_, _, k2, it2) in enumerate(regions):
            if k2 == want and (want_item is None or it2 == want_item):
                m |= 1 << j
    return m

# <stem>.exp.hex word order (umd_reader.sv output ports; 48-bit values as lo32, hi16)
EXP_WORDS = ["err_code", "main_pl", "n_playlists", "n_items", "title_len", "sfo_flags",
             "aud_present", "sub_present", "n_streams", "n_video", "n_unknown", "vid_attr",
             "clip_start_lo", "clip_start_hi", "clip_end_lo", "clip_end_hi", "ep_map_off",
             "item_in_lo", "item_in_hi", "item_out_lo", "item_out_hi", "clip_name_hi",
             "clip_name_lo", "clip_name_len", "mps_lba", "mps_bytes", "item_idx"]
TITLE_MAX = 128


BASE_MAX = 256                      # items whose base the bench checks (the rest counted)


def item_bases(pl_raw):
    """P6b5: the title's time at each item's IN of the main playlist -- the sum of the earlier
    items' OUT - IN (0 where OUT <= IN), saturating at 48 bits: umd_reader's item_base -- and,
    last, the playlist's duration (pl_dur, 64 bits). From the P1 parser, never the RTL.
    -> [base_0, ..., base_n-1, duration]"""
    pl = umd_playlist.parse(pl_raw)
    items = pl["playlists"][umd_playlist.main_playlist(pl)]["items"]
    out, acc = [], 0
    for it in items:
        out.append(min(acc, (1 << 48) - 1))
        acc += max(it["out_pts"] - it["in_pts"], 0)
    return out + [min(acc, (1 << 64) - 1)]


def reader_expect(sfo_raw, pl_raw, clps, mps_first, item=None):
    """The P2 reader's outputs after walking a disc, from the P1 parsers alone.
    sfo_raw: PARAM.SFO bytes or None; clps: {clip name: CLP bytes}; mps_first: (LBA,
    size) of the described item's first .MPS extent. -> (exp words, title bytes, lang
    words). The track outputs describe the playing item: `item`, by default the LAST
    (a complete walk ends there; a partial one is described at the item it stopped in)."""
    import umd_sfo
    pl = umd_playlist.parse(pl_raw)
    mp = umd_playlist.main_playlist(pl)
    items = pl["playlists"][mp]["items"]
    title, sfo_warn = b"", 0
    try:
        t = [e for e in umd_sfo.entries(sfo_raw) if e["key"] == "TITLE"] if sfo_raw else []
        if t:
            title = t[0]["raw"]
        else:
            sfo_warn = 1
    except umd_sfo.SfoError:
        sfo_warn = 1
    trunc = len(title) > TITLE_MAX
    item = len(items) - 1 if item is None else item
    last = items[item]
    c = umd_clpi.parse(clps[last["clip_name"]])
    aud = sub = nv = nu = 0
    va = 0
    langs = [0] * 48
    for st in c["streams"]:
        attr = bytes.fromhex(st["attr"])
        lang = 0x10000 | (attr[2] << 8) | attr[3]
        if st["kind"] == "video":
            if nv == 0:
                va = attr[0] | (attr[1] << 8)
            nv += 1
        elif st["kind"] == "audio":
            aud |= 1 << st["substream_id"]
            langs[st["substream_id"]] = lang
        elif st["kind"] == "subtitle":
            sub |= 1 << (st["substream_id"] - 0x80)
            langs[16 + st["substream_id"] - 0x80] = lang
        else:
            nu += 1
    name = last["clip_name"].encode("latin-1").ljust(8, b"\0")
    lo32 = lambda v: v & 0xFFFFFFFF
    hi16 = lambda v: v >> 32
    exp = [0, mp, len(pl["playlists"]), len(items), min(len(title), TITLE_MAX),
           sfo_warn | (trunc << 1), aud, sub, len(c["streams"]), nv, nu, va,
           lo32(c["start_pts"]), hi16(c["start_pts"]), lo32(c["end_pts"]), hi16(c["end_pts"]),
           c["ep_map_off"], lo32(last["in_pts"]), hi16(last["in_pts"]),
           lo32(last["out_pts"]), hi16(last["out_pts"]),
           int.from_bytes(name[:4], "big"), int.from_bytes(name[4:], "big"),
           len(last["clip_name"]), mps_first[0], mps_first[1], item]
    assert len(exp) == len(EXP_WORDS)
    return exp, title[:TITLE_MAX], langs


def write_nav(stem, sectors, regions, sseq, exp, title, langs, main_clip, main_pl,
              image_bytes, script=None, bases=(), bare=0, pmf_warn=0):
    """Write a --nav fixture. sectors: {LBA: 2048 bytes}; regions: [(LBA, n, kind, item)];
    script: a NavScript (its stream sectors must be in `sectors`)."""
    lbas = sorted(sectors)
    if len(regions) > MAX_REGIONS:
        raise FixtureError("%d regions: the bench's dependency masks hold %d"
                           % (len(regions), MAX_REGIONS))
    cmds = script.cmds if script else []
    nseq = script.nseq if script else []
    # the walk's checks run when phase 0 ends or at the first command's trigger: a
    # complete multi-item walk must have ended by then (it is described at its last item)
    if cmds and exp[0] == 0 and exp[3] > 1 and (script.p0_complete is not False) \
            and cmds[0][0] >> 8 != W_AFTER:
        raise FixtureError("a complete multi-item phase 0 needs a W_AFTER first command")
    missing = [l for l in list(sseq) + nseq if l not in sectors]
    if missing:
        raise FixtureError("stream sectors not in the fixture: %r" % missing[:4])
    owner = {}
    for i, (a, n, k, it) in enumerate(regions):
        for l in range(a, a + n):
            if l in owner:      # e.g. one clip played twice: ranks would be ambiguous
                raise FixtureError("LBA %d is in regions %d and %d" % (l, owner[l], i))
            owner[l] = i
    complete = (script.p0_complete if script is not None and script.p0_complete is not None
                else all(l in sectors for l in _mps_lbas(regions)))
    write_bytes(stem + ".hex", b"".join(sectors[l] for l in lbas))
    write_words(stem + ".lba.hex", lbas)
    def words128(m):
        return [(m >> (32 * j)) & 0xFFFFFFFF for j in range(4)]
    write_words(stem + ".reg.hex", [w for i, (a, n, k, it) in enumerate(regions)
                                    for w in [a, n, (KINDS.index(k) << 16) | it]
                                    + words128(deps_mask(regions, i))
                                    + words128(deps_mask(regions, i, NAV_DEPS))])
    write_words(stem + ".sseq.hex", sseq)
    write_words(stem + ".nav.hex", [w for c in cmds for w in c])
    write_words(stem + ".nseq.hex", nseq)
    # each stream sector's item (the reader's tag is it mod 4): the script's, else the
    # region's (a clip in two playlists is two items: P9's PLAY)
    if script is not None and script.p0tag is not None:
        tags = list(script.p0tag) + list(script.ntag)
    else:
        tags = [next(it for a, n, k, it in regions if k == "mps" and a <= l < a + n)
                for l in list(sseq) + nseq]
    if len(tags) != len(sseq) + len(nseq):
        raise FixtureError("%d item tags for %d stream sectors" % (len(tags), len(sseq) + len(nseq)))
    write_words(stem + ".sitem.hex", [t & 0xFFFF for t in tags])
    write_words(stem + ".exp.hex", exp)
    write_bytes(stem + ".title.hex", title.ljust(TITLE_MAX, b"\0"))
    write_words(stem + ".lang.hex", langs)
    # P6b5: <stem>.base.hex: 1 + the items checked, then {lo32, hi32} per item base, then
    # the playlist's duration
    nb = min(max(len(bases) - 1, 0), BASE_MAX)
    bw = [nb]
    for b in list(bases[:nb]) + list(bases[-1:]):
        bw += [b & 0xFFFFFFFF, b >> 32]
    write_words(stem + ".base.hex", bw)
    write_words(stem + ".meta.hex", [len(lbas), len(regions), len(sseq), int(complete),
                                     main_clip, main_pl, image_bytes & 0xFFFFFFFF,
                                     image_bytes >> 32, len(cmds), len(nseq), bare,
                                     int(pmf_warn)])
    return lbas


# ---------------------------------------------------------------------------------
# P8: a bare stream file as a --nav fixture (docs/bare_streams.md). The reader sniffs sector
# 0: a pack header is a bare .MPS, "PSMF" a .PMF (psmf_ref.psmf_header: the stream offset
# checked as JPCSP checks it). It then streams the file (an .MPS) or the PSMF's stream cut at
# the nearer of its size and the file's end, as ONE item: no title, no CLP, no map. Goldens
# from psmf_ref, never the RTL.
E_BARE = 12                               # umd_reader.sv
BARE_IN_MPS = 90000                       # a CLP's start PTS (always): an .MPS's time origin
BARE_OUT = (1 << 48) - 1                  # no OUT: the END record ends it


class RawScript(object):
    """A navigation script of hand-built command words (a bare stream: nothing lands)."""
    def __init__(self, cmds):
        self.cmds, self.nseq, self.ntag = cmds, [], []
        self.p0_complete, self.p0tag = None, None


def bare_cmd(op, when, err, item=0, pts=0, pl=0):
    """A command a bare stream refuses (SEEK / TIME / PLAY: NE_NOMAP, nothing flushed) or
    answers empty (CHAP: no chapter, NE_NONE)."""
    w = [0] * NAV_W
    w[0] = op | (when << 8)
    w[1], w[2], w[3], w[4] = item, pts & 0xFFFFFFFF, pts >> 32, err
    w[27] = pl
    return w


def bare_script():
    return RawScript([bare_cmd(OP_CHAP, W_HALF, NE_NONE),
                      bare_cmd(OP_SEEK, W_MID, NE_NOMAP, 0, 90000 * 5),
                      bare_cmd(OP_TIME, W_MID, NE_NOMAP, 0, 90000),
                      bare_cmd(OP_PLAY, W_MID, NE_NOMAP, 0, 0, pl=0),
                      bare_cmd(OP_SEEK, W_AFTER, NE_NOMAP, 1, 0),
                      bare_cmd(OP_CHAP, W_AFTER, NE_NONE, 0, 90000)])


def bare_expect(raw, image_bytes=None):
    """-> (err, mode, pmf_warn, first stream sector, stream sectors, IN, duration)."""
    import psmf_ref
    size = len(raw) if image_bytes is None else image_bytes
    total = (size + SEC - 1) // SEC
    magic = raw[:4]
    if magic not in (b"\x00\x00\x01\xba", psmf_ref.PSMF_MAGIC):
        raise FixtureError("not a bare stream (sector 0 starts %s)" % magic.hex())
    if size >= 1 << 32:                   # the reader's extent is u32 bytes (S_MPS)
        return E_BARE, 0, 0, 0, 0, 0, 0
    if magic != psmf_ref.PSMF_MAGIC:
        return 0, 1, 0, 0, total, BARE_IN_MPS, 0
    try:
        h = psmf_ref.psmf_header(raw[:SEC], size)
    except psmf_ref.PsError:
        return E_BARE, 0, 0, 0, 0, 0, 0
    off = h["stream_offset"]
    n = (h["stream_end"] - off + SEC - 1) // SEC
    # IN 90000 (JPCSP's PSMF validity rule; every census file's first PTS); the duration is not
    # read (the PMF stage: bare_streams.md S5)
    return 0, 2, int(h["size_mismatch"]), off // SEC, n, BARE_IN_MPS, 0


def bare_fixture(stem, raw, image_bytes=None, script=True):
    """Write a bare stream file (raw: its bytes; image_bytes: the size the reader is told, when
    it differs) as a --nav fixture. Returns (err, mode, sectors streamed)."""
    err, mode, warn, s0, n, t_in, dur = bare_expect(raw, image_bytes)
    size = len(raw) if image_bytes is None else image_bytes
    secs = {l: raw[l * SEC:(l + 1) * SEC].ljust(SEC, b"\0")
            for l in range((len(raw) + SEC - 1) // SEC)}
    if err:
        write_nav(stem, secs, [(0, max(len(secs), 1), "mps", 0)], [],
                  [err] + [0] * (len(EXP_WORDS) - 1), b"", [0] * 48, 0, 0, size)
        return err, 0, 0
    sseq = list(range(s0, s0 + n))
    exp = [0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
           t_in & 0xFFFFFFFF, t_in >> 32, BARE_OUT & 0xFFFFFFFF, BARE_OUT >> 32, 0, 0, 0,
           0, size & 0xFFFFFFFF, 0]      # the extent: the whole file (a .PMF skips its header in it)
    assert len(exp) == len(EXP_WORDS)
    write_nav(stem, secs, [(s0, n, "mps", 0)], sseq, exp, b"", [0] * 48, 0, 0, size,
              bare_script() if script else None, [0, dur], bare=mode, pmf_warn=warn)
    return 0, mode, n


# ---------------------------------------------------------------------------------
# The navigation script (P6b2): commands for umd_reader's query port, with goldens from
# tools/umd_nav_ref.py (never the RTL). <stem>.nav.hex holds NAV_W words per command:
NAV_W = 32
NAV_WORDS = ["op | when << 8", "item", "pts_lo", "pts_hi", "err",
             # SEEK: where it lands, and the stream it must produce (.nseq.hex)
             "land_item", "ep_idx", "ep_pts", "ep_sec", "skip_lo", "skip_hi",
             "n_seq", "seq_off", "seq_complete",
             # CHAP (keys as item, pts lo32, pts hi16)
             "rank", "count", "valid (cur 1, prev 2, next 4)", "cur_item", "cur_lo", "cur_hi",
             "prev_item", "prev_lo", "prev_hi", "next_item", "next_lo", "next_hi",
             "ep_flags (SEEK: no map 1, past 2, wide 4)",
             # PLAY (P9): the playlist, its items and duration, and (in rank / count) the
             # landing item's item_base; taken 1 (the playlist exists: flushed), landed 2
             # (it has an item: the SEEK words score the landing)
             "playlist", "n_items", "pl_dur_lo", "pl_dur_hi", "taken | landed << 1"]
OP_SEEK, OP_CHAP, OP_PLAY, OP_TIME = 1, 2, 3, 4      # TIME: P6c's Go To (the playlist's time in "pts")
W_AFTER, W_MID, W_HALF = 0, 1, 2       # the phase is over / an .MPS transfer in flight / half of it
# umd_reader.sv's nav_err codes (docs/transport.md S2.4)
NE_NONE, NE_ITEM, NE_MARKS, NE_OOB, NE_NOMAP, NE_PAST, NE_WIDE, NE_OP = range(8)
SEEK_CAP = 8                            # stream sectors scored after a seek's landing


class NavScript(object):
    """Commands and their goldens. title: umd_nav_ref.Title; ext[k]: item k's .MPS
    extents [(first LBA, sectors)] in record order (clip-relative sectors run through
    them, as the reader walks them). playlists(p) -> (Title, ext) of playlist p, and
    n_pl the playlist count, for P9's PLAY (the script then runs on playlist p)."""

    def __init__(self, title, ext, playlists=None, n_pl=1):
        self._title(title, ext)
        self.playlists, self.n_pl = playlists, n_pl
        self.cmds, self.nseq, self.ntag = [], [], []
        self.p0_complete, self.p0tag = None, None
        self.last = (None, 0)           # the running phase: (complete, sectors)

    def _title(self, title, ext):
        self.t, self.ext = title, ext
        self.nsecs = [sum(n for _, n in e) for e in ext]

    def lba(self, k, s):
        for a, n in self.ext[k]:
            if s < n:
                return a + s
            s -= n
        raise FixtureError("item %d sector past its clip" % k)

    def landing(self, key):
        """(item, entry, entry pts, sector, skip, ep_flags) of a seek or an item start: the
        model's seek, plus the reader's flags; an item with no video entry streams whole
        from sector 0."""
        item, pts = key
        it = self.t.items[item]
        skip = self.t.clamp(item, pts)
        if not it.entries:
            return item, 0, 0, 0, skip, 1
        _, k, epts, sec, skip = self.t.seek(key)
        wide = skip >= 2 ** 32 or it.out_pts >= 2 ** 32
        return item, k, epts, sec, skip, (2 if sec >= self.nsecs[item] else 0) | (4 if wide else 0)

    def span(self, k, sector=None):
        if sector is None:
            sector = self.landing((k, self.t.items[k].in_pts))[3]
        if not self.t.items[k].entries:
            return sector, self.nsecs[k]
        return self.t.item_span(k, self.nsecs[k], sector)

    def plan(self, item, sector=None, tags=None):
        """The LBAs the reader streams from a landing to the title's end; tags (a list):
        each one's item, appended."""
        out = []
        for k in range(item, len(self.t.items)):
            a, b = self.span(k, sector if k == item else None)
            out += [self.lba(k, s) for s in range(a, b)]
            if tags is not None:
                tags += [k] * (b - a)
        return out

    def phase0(self, cap=0):
        """The walk's stream: (LBAs, complete). cap: keep the first `cap` sectors."""
        tags = []
        seq = self.plan(0, tags=tags)
        self.p0_complete = not cap or len(seq) <= cap
        self.last = (self.p0_complete, min(len(seq), cap) if cap else len(seq))
        self.p0tag = tags[:cap] if cap else tags
        return (seq[:cap] if cap else seq), self.p0_complete

    def _cmd(self, op, when, key, err):
        # a mid-transfer trigger needs a transfer: a complete phase of a few sectors may
        # be read whole before its first sector is out (a seek landing near the end)
        if when == W_MID and self.last[0] and self.last[1] < 4:
            when = W_AFTER
        w = [0] * NAV_W
        w[0], w[1], w[2], w[3], w[4] = op | (when << 8), key[0], key[1] & 0xFFFFFFFF, key[1] >> 32, err
        self.cmds.append(w)
        return w

    def raw(self, op, when, key, err):
        self._cmd(op, when, key, err)

    def seek(self, key, when, cap=SEEK_CAP):
        if key[0] >= len(self.t.items):
            self._cmd(OP_SEEK, when, key, NE_ITEM)
            return
        item, k, epts, sec, skip, flags = self.landing(key)
        err = NE_NOMAP if flags & 1 else NE_PAST if flags & 2 else NE_WIDE if flags & 4 else NE_NONE
        w = self._cmd(OP_SEEK, when, key, err)
        self._land(w, key, cap)

    def _land(self, w, key, cap):
        """A landing's goldens and the stream it must produce."""
        item, k, epts, sec, skip, flags = self.landing(key)
        tags = []
        seq = self.plan(item, sec, tags)
        w[5:14] = [item, k, epts, sec, skip & 0xFFFFFFFF, skip >> 32, min(len(seq), cap),
                   len(self.nseq), int(len(seq) <= cap)]
        w[26] = flags
        self.nseq += seq[:cap]
        self.ntag += tags[:cap]
        self.last = (len(seq) <= cap, min(len(seq), cap))

    def time(self, ticks, when, cap=SEEK_CAP):
        """P6c NAV_TIME: Go To the playing playlist's time `ticks` -- a seek to
        umd_nav_ref.Title.key_at (past the end the last item's OUT - 4, D16); refused (NE_ITEM)
        only on a playlist with no item."""
        if not self.t.items:
            self._cmd(OP_TIME, when, (0, ticks), NE_ITEM)
            return
        key = self.t.key_at(ticks)
        flags = self.landing(key)[5]
        err = NE_NOMAP if flags & 1 else NE_PAST if flags & 2 else NE_WIDE if flags & 4 else NE_NONE
        w = self._cmd(OP_TIME, when, (0, ticks), err)
        self._land(w, key, cap)

    def play(self, pl, key, when, cap=SEEK_CAP):
        """P9 NAV_PLAY: playlist pl from key = (item, pts). A playlist that does not exist is
        refused (NE_ITEM, nothing changes); an item past its last plays it from its first at
        IN (NE_ITEM); the script runs on playlist pl after it (seeks, chapters)."""
        w = None
        if pl >= self.n_pl:
            w = self._cmd(OP_PLAY, when, key, NE_ITEM)
            w[27] = pl
            return
        title, ext = self.playlists(pl)
        clamped = key[0] >= len(title.items)
        k2 = (0, 0) if clamped else key
        self._title(title, ext)
        dur = sum(max(it.out_pts - it.in_pts, 0) for it in title.items)
        if not title.items:                       # no item: lands on its end, nothing streamed
            w = self._cmd(OP_PLAY, when, key, NE_ITEM)
            w[11:14] = [0, len(self.nseq), 1]
            self.last = (True, 0)
        else:
            flags = self.landing(k2)[5]
            err = (NE_ITEM if clamped else NE_NOMAP if flags & 1 else NE_PAST if flags & 2
                   else NE_WIDE if flags & 4 else NE_NONE)
            w = self._cmd(OP_PLAY, when, key, err)
            self._land(w, k2, cap)
            base = sum(max(it.out_pts - it.in_pts, 0) for it in title.items[:w[5]])
            w[14], w[15] = base & 0xFFFFFFFF, base >> 32
        w[27], w[28] = pl, len(title.items)
        w[29], w[30] = dur & 0xFFFFFFFF, (dur >> 32) & 0xFFFFFFFF
        w[31] = 1 | (2 if title.items else 0)

    def chap(self, key, when, err=None):
        w = self._cmd(OP_CHAP, when, key, NE_NONE if err is None else err)
        if err is not None:
            return
        rank, count, cur, prev, nxt = self.t.chapter_query(key)
        w[14], w[15] = rank, count
        w[16] = (cur is not None) | ((prev is not None) << 1) | ((nxt is not None) << 2)
        for j, c in ((17, cur), (20, prev), (23, nxt)):
            if c is not None:
                w[j:j + 3] = [c[0], c[1] & 0xFFFFFFFF, c[1] >> 32]


def disc_script(title, ext, seed, tail_cap=640, playlists=None, n_pl=1, main=0, other=None):
    """The script run on every disc image: queries and seeks at random keys (mid-transfer
    and between phases), a chapter's landing, the tail of item 0 into the next item (or
    the title's end) and of the last item to the end ([inout]: the stop at OUT), a seek
    after title_done, a query past the last chapter; P9's PLAY: a playlist that does not
    exist, then (a disc with another playlist, `other`) that one mid-transfer, a chapter
    query and a seek on it, an item past its last (from its first), and back to the main
    playlist; a bad item. P6c's Go To by time: random times, 0:00:00, each item boundary
    and the tick before it, the title's end and past it -- and one on the other playlist
    (its own time, D15)."""
    import bisect
    import random
    rng = random.Random(seed)
    ns = NavScript(title, ext, playlists, n_pl)
    n = len(title.items)

    def rkey(item=None, t=None):
        t = ns.t if t is None else t
        item = rng.randrange(len(t.items)) if item is None else item
        it = t.items[item]
        return item, rng.randint(it.in_pts, max(it.in_pts, it.out_pts))

    def tail(k):
        it = title.items[k]
        j = max(0, bisect.bisect_left(it.pts, it.out_pts) - 1)
        return k, it.pts[j] if it.pts else it.in_pts

    ns.chap(rkey(0), W_HALF)                        # during the walk's stream: it runs on
    for i in range(8):
        ns.seek(rkey(), W_MID if i % 2 == 0 else W_AFTER)
        if i == 2:
            ns.chap(rng.choice(title.chapters) if title.chapters else rkey(), W_HALF)
        if i == 4 and title.chapters:
            ns.seek(rng.choice(title.chapters), W_AFTER)
    ns.seek(tail(0), W_AFTER, cap=tail_cap)
    if n > 1:
        ns.seek(tail(n - 1), W_AFTER, cap=tail_cap)
    ns.seek(rkey(), W_AFTER)
    # P6c, Go To by time: random times, 0:00:00, every item boundary and a tick before it (a
    # multi-item title), the end itself and past it (D16: the last item's OUT - 4)
    tot = title.total
    ns.time(rng.randint(0, max(0, tot - 1)), W_MID)
    ns.time(0, W_AFTER)
    acc = 0
    for it in title.items[:-1][:4]:
        acc += it.duration
        ns.time(acc - 1, W_AFTER)
        ns.time(acc, W_MID)
    ns.time(rng.randint(0, max(0, tot - 1)), W_HALF)
    ns.time(tot, W_AFTER, cap=tail_cap)
    ns.time(tot + rng.randint(1, 1 << 36), W_AFTER)
    ns.chap((n - 1, title.items[-1].out_pts), W_HALF)
    ns.play(n_pl, (0, 0), W_HALF)                   # no such playlist: nothing changes
    if other is not None:
        ns.play(other, (0, 0), W_MID)
        ns.play(other, rkey(), W_AFTER)
        ns.chap(rkey(), W_HALF)                     # its own marks
        ns.time(rng.randint(0, ns.t.total), W_AFTER)  # P6c: its own time (D15)
        ns.seek(rkey(), W_AFTER)
        ns.play(other, (len(ns.t.items), rng.randrange(1 << 40)), W_AFTER)  # from its first
        ns.play(main, rkey(t=title), W_MID)         # back to the feature
        ns.seek(rkey(), W_AFTER)
    ns.seek((len(ns.t.items), 0), W_HALF)
    return ns


def _mps_lbas(regions):
    return [l for a, n, k, it in regions if k == "mps" for l in range(a, a + n)]


def nav_walk(iso, stream_packs=0, seed=None):
    """The reader's walk over a real image (module docstring). Returns (regions, sseq,
    info): regions [(first LBA, sectors, kind, item)] in walk order, sseq the .MPS sectors the
    stream carries (the first `stream_packs`, 0 = all; IN / OUT applied), info the main
    clip, the reader_expect() inputs and the navigation script (disc_script(seed); none
    without a seed)."""
    regions = []
    lba = umd_iso.VD_START
    while iso.sec(lba, record=False)[0] != 255:
        lba += 1
    regions.append((umd_iso.VD_START, lba + 1 - umd_iso.VD_START, "vd", 0))

    def add(path, kind, item=0):
        e = iso.files[""] if path == "" else iso.extent(path)
        regions.append((e.lba, e.nsec, kind, item))
        return e
    add("", "root")
    add("/UMD_VIDEO", "umd_video")
    sfo_raw = None
    if iso.exists("/UMD_VIDEO/PARAM.SFO"):
        add("/UMD_VIDEO/PARAM.SFO", "sfo")
        sfo_raw = iso.read("/UMD_VIDEO/PARAM.SFO", record=False)
    add("/UMD_VIDEO/PLAYLIST.UMD", "playlist")
    pl_raw = iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False)
    pl = umd_playlist.parse(pl_raw)
    mp = umd_playlist.main_playlist(pl)
    add("/UMD_VIDEO/CLIPINF", "clipinf")
    add("/UMD_VIDEO/STREAM", "stream")
    clps, ext, mpss = {}, [], []
    for k, it in enumerate(pl["playlists"][mp]["items"]):
        name = it["clip_name"]
        add("/UMD_VIDEO/CLIPINF/%s.CLP" % name, "clp", k)
        clps[name] = iso.read("/UMD_VIDEO/CLIPINF/%s.CLP" % name, record=False)
        mps = add("/UMD_VIDEO/STREAM/%s.MPS" % name, "mps", k)
        mpss.append(mps)
        ext.append([(mps.lba, mps.nsec)])
    import umd_nav_ref
    title = umd_nav_ref.from_umd(iso)
    # P9's PLAY: another playlist with an item (chosen by the seed), its clips' regions
    # added (a clip already walked keeps its region: the reader reads the same sectors)
    ext_of = {it["clip_name"]: e for it, e in zip(pl["playlists"][mp]["items"], ext)}
    other = None
    if seed is not None:
        cands = [e["index"] for e in pl["playlists"] if e["index"] != mp and e["items"]]
        for p in cands[seed % len(cands):] + cands[:seed % len(cands)] if cands else []:
            names = [it["clip_name"] for it in pl["playlists"][p]["items"]]
            new = sorted(set(nm for nm in names if nm not in ext_of))
            if len(regions) + 2 * len(new) > MAX_REGIONS or not all(
                    iso.exists("/UMD_VIDEO/CLIPINF/%s.CLP" % nm) and
                    iso.exists("/UMD_VIDEO/STREAM/%s.MPS" % nm) for nm in new):
                continue
            try:
                umd_nav_ref.from_umd(iso, pl_raw, p)
            except Exception:                       # a playlist the model refuses
                continue
            for j, nm in enumerate(new):
                add("/UMD_VIDEO/CLIPINF/%s.CLP" % nm, "clp", 0x8000 | j)
                m = add("/UMD_VIDEO/STREAM/%s.MPS" % nm, "mps", 0x8000 | j)
                ext_of[nm] = [(m.lba, m.nsec)]
            other = p
            break

    def playlists(p):
        return (umd_nav_ref.from_umd(iso, pl_raw, p),
                [ext_of[it["clip_name"]] for it in pl["playlists"][p]["items"]])
    script = (disc_script(title, ext, seed, playlists=playlists, n_pl=len(pl["playlists"]),
                          main=mp, other=other)
              if seed is not None else NavScript(title, ext))
    sseq, complete = script.phase0(stream_packs)
    # the item the walk is in when phase 0 ends (a partial one must end well inside it:
    # the reader runs up to 8 sectors ahead of the bytes it has delivered)
    item = len(ext) - 1
    if not complete:
        at = [k for k in range(len(ext)) for s in range(*script.span(k))]
        item = at[len(sseq) - 1]
        if at[len(sseq) - 1:len(sseq) + 10].count(item) != len(at[len(sseq) - 1:len(sseq) + 10]):
            raise FixtureError("phase 0 ends within 10 sectors of item %d's end" % item)
    name0 = pl["playlists"][mp]["items"][0]["clip_name"]
    return regions, sseq, {"clip": int(name0), "main_playlist": mp, "sfo_raw": sfo_raw,
                           "pl_raw": pl_raw, "clps": clps, "item": item, "script": script,
                           "mps_first": (mpss[item].lba, mpss[item].size)}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("iso")
    ap.add_argument("--out", required=True, help="fixture stem")
    ap.add_argument("--dir", default=OUT_DIR)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--pts", type=int, nargs=2, metavar=("A", "B"))
    ap.add_argument("--lba", type=int, nargs=2, metavar=("FIRST", "END"),
                    help="clip-relative sectors [FIRST, END)")
    ap.add_argument("--nav", action="store_true")
    ap.add_argument("--stream-packs", type=int, default=0)
    ap.add_argument("--nav-seed", type=int, help="--nav: add the navigation script (P6b2)")
    ap.add_argument("--bare-mps", type=int, metavar="N",
                    help="P8: the main clip's first N packs as a bare .MPS file")
    ap.add_argument("--bare-pmf", action="store_true",
                    help="P8: the disc's UMD_VIDEO/ICON1.PMF as a bare .PMF file (exit 3: none)")
    a = ap.parse_args(argv)
    os.makedirs(a.dir, exist_ok=True)
    stem = os.path.join(a.dir, a.out)
    with umd_iso.UmdIso(a.iso) as iso:
        if a.bare_mps or a.bare_pmf:
            if a.bare_pmf:
                if not iso.exists("/UMD_VIDEO/ICON1.PMF"):
                    print("%s: no UMD_VIDEO/ICON1.PMF" % a.iso)
                    return 3
                raw = iso.read("/UMD_VIDEO/ICON1.PMF", record=False)
            else:
                pl = umd_playlist.parse(iso.read("/UMD_VIDEO/PLAYLIST.UMD", record=False))
                clip = int(pl["playlists"][umd_playlist.main_playlist(pl)]["items"][0]["clip_name"])
                e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip)
                raw = cut_packs(iso, clip, 0, min(a.bare_mps, e.nsec))
            err, mode, n = bare_fixture(stem, raw)
            print("%s: bare %s, %d bytes, %d stream sectors%s" % (
                stem, "PMF" if a.bare_pmf else "MPS", len(raw), n, ", refused %d" % err if err else ""))
            return 0
        if a.nav:
            regions, sseq, info = nav_walk(iso, a.stream_packs, a.nav_seed)
            sectors = {l: iso.sec(l, record=False)
                       for f, n, k, it in regions if k != "mps"
                       for l in range(f, f + n)}
            ns = info["script"]
            sectors.update((l, iso.sec(l, record=False)) for l in list(sseq) + ns.nseq)
            exp, title, langs = reader_expect(info["sfo_raw"], info["pl_raw"], info["clps"],
                                              info["mps_first"], info["item"])
            lbas = write_nav(stem, sectors, regions, sseq, exp, title, langs, info["clip"],
                             info["main_playlist"], os.path.getsize(a.iso), ns,
                             item_bases(info["pl_raw"]))
            print("%s: %d sectors, %d regions, %d stream sectors, %d commands, main playlist "
                  "%d -> clip %05d" % (stem, len(lbas), len(regions), len(sseq), len(ns.cmds),
                                       info["main_playlist"], info["clip"]))
            return 0
        if a.clip is None or (a.pts is None) == (a.lba is None):
            raise FixtureError("give --clip N and exactly one of --pts / --lba (or --nav)")
        if a.pts:
            first, end, pts = pts_range(iso, a.clip, *a.pts)
        else:
            first, end = a.lba
            c = umd_clpi.from_iso(iso, a.clip)
            on = [e for e in umd_clpi.video_map(c) if e[2] == first]
            pts = on[0][1] if on else NO_PTS
        data = cut_packs(iso, a.clip, first, end)
        write_bytes(stem + ".hex", data)
        write_words(stem + ".meta.hex", [len(data), first, end - first, a.clip, pts])
        print("%s: clip %05d sectors %d..%d (%d bytes), start PTS %s" % (
            stem, a.clip, first, end, len(data), pts if pts != NO_PTS else "-"))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (FixtureError, umd_iso.IsoError) as e:
        sys.exit("umd_fixture: %s" % e)
