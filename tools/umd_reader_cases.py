#!/usr/bin/env python3
"""Synthetic disc images for the P2 reader bench (bench/umd/run_umd_reader.sh), written
as umd_fixture.py --nav fixtures into bench/umd/fixtures/gen/.

Each case is an edge the 33-disc library does not exercise (or exercises only once), or
a refusal the reader must make LOUDLY. The images are built from the format documents
with tools/tests/umd_synth.py; the expected outputs of the good cases come from the P1
parsers via umd_fixture.reader_expect() -- never from the RTL.

    syn_basic   boot record before the PVD; ';1' version suffixes; near-miss names
                (UMD_VIDEO.BAK, a FILE called CLIPINF, PARAM.SFOX, STREAMS/);
                UMD_VIDEO/ spanning two sectors with PLAYLIST.UMD in the second;
                PSP_SYSTEM_VER sorted between PARENTAL_LEVEL and TITLE; the longest
                playlist is #1; audio 0x00/0x03, subtitles 0x80/0x9C, an unknown entry
    syn_multi   no suffixes (as on every real disc); the main playlist has 3 items and
                is the longest only as a SUM (playlist 0's single item is longer than
                any one of them), with a tie after it (first wins); an item record and
                the 200-byte TITLE (> 128: truncated, flagged) each straddle a sector;
                clip 00003.MPS is multi-extent with three GAPPED, out-of-order extents
                whose records straddle the STREAM/ directory's two sectors
    syn_no_sfo  no PARAM.SFO: plays, sfo_warn; chapter queries on a title with no marks
    syn_wide    (A12) PTS and durations whose 48 / 64-bit sums carry across 32 bits
    syn_nav     the navigation port (P6b2, docs/transport.md S2.4): three items, IN / OUT
                cutting item 0 (it starts at the entry before IN and stops at the entry
                at OUT), a 4,000-entry video map of 20 sectors behind a subtitle map
                (the video map is found by stream_id, never assumed to be map 0), an
                entry straddling a sector, a one-entry map, an OUT past 2^32 ticks, an
                entry past its clip; marks unsorted, duplicated, an Endmark, one on an
                item that does not exist. Seeks: an exact hit, one tick before it, the
                straddling entry, before IN, past OUT, before the first entry, past the
                last, into every item, a bad item, a reserved op; P6c's Go To by time (0,
                each item boundary and the tick before it, past the end, the largest time,
                on the trailer and on the empty playlist; ops 5-7 reserved); chapter queries around
                every mark, and with the key's item beyond u16
    syn_marks_max  65,535 marks (the u16 maximum; 2.6 MB of PLAYLIST.UMD), unsorted,
                with Endmarks and marks on a missing item: chapter queries scan them all
    syn_badmarks / syn_oobmarks  a marks section whose length does not hold its count, and
                one whose count runs past the file: NE_MARKS / NE_OOB, playback unharmed
    err_*       one image per refusal, expected err_code in exp[0]
    P8, bare stream files (docs/bare_streams.md; goldens umd_fixture.bare_fixture, from
    psmf_ref): the reader sniffs sector 0 and streams the file as ONE item; navigation is
    refused with nothing flushed (NE_NOMAP), chapters answer none:
    syn_bare_mps    a bare .MPS of 12 packs
    syn_bare_small  a bare .MPS of 8 packs: under an image's 17-sector minimum, still a stream
    syn_pmf         a .PMF: a one-sector PSMF header (first PTS 180000: IN stays 90000, no
                    duration -- the header's PTS are the PMF stage's), 10 packs
    syn_pmf_2sec    a two-sector header (stream offset 0x1000, as 5 game PMFs have)
    syn_pmf_cut     the header's stream size runs past the file: cut at the file, pmf_warn
    syn_pmf_short   the header's stream size ends before the file: the rest is never read
    err_pmf_off0 / err_pmf_unaligned / err_pmf_past  a stream offset of 0, not 2048-aligned,
                    at or past the file's end: E_BARE
    err_bare_huge   a bare .MPS of 4 GB (the reader's extent is u32 bytes): E_BARE

The good cases carry a navigation script (umd_fixture.NavScript): commands with goldens
from tools/umd_nav_ref.py, and the stream each SEEK must produce.

    umd_reader_cases.py [--dir DIR]      -> prints one stem per line
"""
import argparse
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tests"))
import umd_fixture as F  # noqa: E402
import umd_synth as S  # noqa: E402

SEC = 2048
E_SMALL, E_NOT_ISO, E_BADDIR, E_NO_UMDV, E_NO_PL, E_PL, E_NO_CLP, E_CLP, E_NO_MPS, \
    E_INTERLEAVE, E_EXTENT, E_BARE = range(1, 13)


def nsec(n):
    return max(1, (n + SEC - 1) // SEC)


def sfo(keys):
    """keys: [(name, fmt, raw data, max_len)] in table order."""
    kt = b"".join(k.encode() + b"\0" for k, _, _, _ in keys)
    kt += bytes(-len(kt) % 4)
    koff = 20 + 16 * len(keys)
    doff = koff + len(kt)
    ents, data, ko = b"", b"", 0
    for name, fmt, raw, mx in keys:
        ents += struct.pack("<HHIII", ko, fmt, len(raw), mx, len(data))
        ko += len(name) + 1
        data += raw.ljust(mx, b"\0")
    return b"\0PSF" + struct.pack("<4I", 0x101, koff, doff, len(keys)) + ents + kt + data


def pack(clip, k, part=0):
    """One 2048-byte pack whose payload names (clip, sector, extent): a misplaced
    sector is a byte mismatch, not a coincidence."""
    tag = bytes([clip & 0xFF, k & 0xFF, (k >> 8) & 0xFF, part]) * 60
    return S.fill_pack([S.pes(0xE0, tag, pts=90000 + 3003 * k)])


V_ATTR = bytes.fromhex("1410000000000000")


def aud(lang):
    return bytes([0, 0]) + lang.encode() + bytes([2, 1, 0, 0])


def subt(lang):
    return bytes([0, 0]) + lang.encode() + bytes(4)


class Disc(object):
    def __init__(self, total):
        self.img = S.ImageBuilder(total)
        self.total = total
        self.regions = []
        self.sectors = {}

    def put(self, lba, data, kind=None, item=0):
        self.img.put(lba, data)
        for i in range(nsec(len(data))):
            self.sectors[lba + i] = None
        if kind:
            self.regions.append((lba, nsec(len(data)), kind, item))

    def region(self, lba, n, kind, item=0):
        self.regions.append((lba, n, kind, item))

    def finish(self):
        raw = self.img.build()
        return raw, {l: raw[l * SEC:(l + 1) * SEC] for l in sorted(self.sectors)}


def vds(d, root_lba, boot=False):
    first = 16
    if boot:                                   # a boot record (type 0) first
        b = bytearray(SEC)
        b[0], b[1:6], b[6] = 0, b"CD001", 1
        d.put(16, bytes(b))
        first = 17
    d.put(first, S.pvd(root_lba, SEC, d.total))
    d.put(first + 1, S.terminator())
    d.region(16, first + 2 - 16, "vd")


def write_good(stem, d, sfo_raw, pl_raw, clps, sseq, mps_first, main_clip, script=None,
               describe=None):
    """pl_raw is the playlist the goldens are computed from (a malformed image carries
    a twin of it); describe: the item the walk's checks describe (default the last)."""
    raw, sectors = d.finish()
    exp, title, langs = F.reader_expect(sfo_raw, pl_raw, clps, mps_first, describe)
    main_pl = exp[1]
    sectors.update((l, raw[l * SEC:(l + 1) * SEC]) for l in sseq)
    if script is not None:
        sectors.update((l, raw[l * SEC:(l + 1) * SEC]) for l in script.nseq)
    F.write_nav(stem, sectors, d.regions, sseq, exp, title, langs, main_clip, main_pl,
                len(raw), script, F.item_bases(pl_raw))


def title_of(pl_raw, clps, playlist=None):
    """The navigation model of a synthetic title: its playlist and {clip name: CLP};
    playlist: that one instead of the longest (P9's PLAY)."""
    import umd_nav_ref
    return umd_nav_ref.from_raw(pl_raw, lambda c: clps[c], playlist)


def write_err(stem, d, err):
    raw, sectors = d.finish()
    F.write_nav(stem, sectors, d.regions, [], [err] + [0] * (len(F.EXP_WORDS) - 1), b"",
                [0] * 48, 0, 0, len(raw))


# ---------------------------------------------------------------------------------
def syn_basic(stem):
    d = Disc(200)
    vds(d, 20, boot=True)
    SFO = sfo([("PARENTAL_LEVEL", 0x0404, struct.pack("<I", 1), 4),
               ("PSP_SYSTEM_VER", 0x0204, b"1.50\0", 8),
               ("TITLE", 0x0204, "Synthetic Film ™\0".encode(), 128)])
    PL = S.playlist_file([S.entry("Intro", [("00001", 90000, 90000 * 10)], []),
                          S.entry("Main", [("00002", 90000, 90000 * 999)],
                                  [(0, 0, 90000 * 5, "Mark1")]),
                          S.entry("Extra", [("00001", 90000, 90000 * 500)], [])])
    CLP1 = S.clpi([(0xE0, 0, V_ATTR)], [(0xE0, 0, [(0xC000, 90000, 0)])])
    CLP2 = S.clpi([(0xE0, 0, bytes.fromhex("1120000000000000")), (0xBD, 0x00, aud("en")),
                   (0xBD, 0x03, aud("fr")), (0xBD, 0x80, subt("en")),
                   (0xBD, 0x9C, subt("de")), (0xBD, 0x40, bytes(8)),
                   (0xE1, 0x00, bytes(8))],
                  [(0xE0, 0, [(0xC000, 90000, 0), (0xC000, 180000, 3)])],
                  start=90000, end=90000 * 1000)
    MPS2 = b"".join(pack(2, k) for k in range(6))
    MPS1 = pack(1, 0)
    root = S.dir_sectors(20, 20, [(b"UMD_DATA.BIN;1", 30, 48, 0),
                                  (b"UMD_VIDEO.BAK;1", 30, 48, 0),
                                  (b"UMD_VIDEO", 21, 2 * SEC, 2)])
    dummies = [(b"RESOURCE_%02d.RCO;1" % i, 30, 100, 0) for i in range(44)]
    uv = S.dir_sectors(21, 20, [(b"PARAM.SFOX;1", 30, 10, 0), (b"PARAM.SFO;1", 40, len(SFO), 0),
                                (b"CLIPINF;1", 30, 10, 0), (b"STREAMS", 25, SEC, 2)]
                       + dummies + [(b"PLAYLIST.UMD;1", 41, len(PL), 0),
                                    (b"CLIPINF", 23, SEC, 2), (b"STREAM", 24, SEC, 2)], nsec=2)
    ci = S.dir_sectors(23, 21, [(b"00001.CLP;1", 50, len(CLP1), 0),
                                (b"00002.CLP;1", 51, len(CLP2), 0)])
    st = S.dir_sectors(24, 21, [(b"00001.MPS;1", 60, len(MPS1), 0),
                                (b"00002.MPS;1", 70, len(MPS2), 0)])
    d.put(20, root, "root")
    d.put(21, uv, "umd_video")
    d.put(40, SFO, "sfo")
    d.put(41, PL, "playlist")
    d.put(23, ci, "clipinf")
    d.put(24, st, "stream")
    d.put(51, CLP2, "clp")
    d.put(70, MPS2, "mps")
    d.put(30, b"UMD_DATA")
    sseq = list(range(70, 76))
    ns = F.NavScript(title_of(PL, {"00002": CLP2}), [[(70, 6)]])
    assert ns.phase0() == (sseq, True), "the model disagrees with the hand-written walk"
    ns.seek((0, 180000), F.W_MID)                  # mid-transfer: entry 1 (sector 3)
    ns.chap((0, 0), F.W_HALF)                      # before the only chapter
    ns.seek((0, 0), F.W_AFTER)                     # after title_done; clamped to IN
    ns.chap((0, 90000 * 5), F.W_HALF)              # exactly on the chapter
    ns.seek((1, 0), F.W_HALF)                      # no item 1: NE_ITEM, nothing changes
    write_good(stem, d, SFO, PL, {"00002": CLP2}, sseq, (70, len(MPS2)), 2, ns)


def straddle_marks():
    """Marks on playlist 0 that make an item of the main playlist straddle offset 2048
    of PLAYLIST.UMD with its IN/OUT fields on the far side."""
    for n in range(80):
        ents = multi_entries(n)
        off = 0x130 + 4 + 2 + len(ents[0])            # main playlist's entry
        items_off = struct.unpack(">H", ents[1][4:6])[0]
        for k in range(3):
            q = off + items_off + 8 + 26 * k
            if 4 <= SEC - q <= 16:
                return n
    raise AssertionError("no straddling layout")


def multi_entries(nmarks):
    marks = [(0, 0, 90000 + 900 * i, "M%d" % i) for i in range(nmarks)]
    return [S.entry("Long", [("00009", 90000, 90000 * 901)], marks),
            S.entry("Main", [("00003", 90000, 90000 * 401), ("00001", 90000, 90000 * 301),
                             ("00007", 90000, 90000 * 251)], []),
            S.entry("Tie", [("00001", 90000, 90000 * 951)], [])]


def syn_multi(stem):
    d = Disc(400)
    vds(d, 20)
    title = ("A " + "very " * 38 + "long title").encode()[:199] + b"\0"
    assert len(title) == 200
    head = 20 + 16 * 3
    kt_len = len(b"PARENTAL_LEVEL\0DUMMY\0TITLE\0") + (-len(b"PARENTAL_LEVEL\0DUMMY\0TITLE\0") % 4)
    fill = 2030 - (head + kt_len) - 4                 # TITLE data at file offset 2030
    SFO = sfo([("PARENTAL_LEVEL", 0x0404, struct.pack("<I", 1), 4),
               ("DUMMY", 0x0004, b"d" * fill, fill),
               ("TITLE", 0x0204, title, 256)])
    assert SFO.index(title) == 2030
    PL = S.playlist_file(multi_entries(straddle_marks()))
    clps = {}
    # clip 3's entries start each of its three extents and one inside the second
    # (clip-relative sectors 0, 2, 3, 5 -> LBAs 300, 200, 201, 150): a seek into the
    # second or third extent; clip 7 has a subtitle map only: no video entry (NE_NOMAP)
    emaps = {3: [(0xE0, 0, [(0xC000, 90000 + 3003 * k, k) for k in (0, 2, 3, 5)])],
             7: [(0xBD, 0x9F, [(0, 90000, 0)])]}
    for n in (1, 3, 7, 9):
        streams = [(0xE0, 0, V_ATTR), (0xBD, n & 0xF, aud("j%d" % (n % 10)))]
        if n == 7:
            streams.append((0xBD, 0x9F, subt("zz")))
        clps["%05d" % n] = S.clpi(streams, emaps.get(n, [(0xE0, 0, [(0xC000, 90000, 0)])]),
                                  start=90000, end=90000 * 1000)
    # clip 3: three gapped, out-of-order extents (2 sectors @300, 3 @200, 1 partial @150)
    parts = [(300, 2), (200, 3), (150, 1)]
    ext = []
    for i, (lba, n) in enumerate(parts):
        data = b"".join(pack(3, k, i) for k in range(n))
        if i == len(parts) - 1:
            data = data[:1000]                           # a partial final sector
        d.put(lba, data)
        d.region(lba, n, "mps")
        ext.append((lba, len(data)))
    mps = {1: (100, 2), 7: (110, 4), 9: (120, 1)}
    for n, (lba, k) in mps.items():
        d.put(lba, b"".join(pack(n, j) for j in range(k)))
    root = S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, SEC, 2)])
    uv = S.dir_sectors(21, 20, [(b"CLIPINF", 22, SEC, 2), (b"STREAM", 23, 2 * SEC, 2),
                                (b"PARAM.SFO", 40, len(SFO), 0),
                                (b"PLAYLIST.UMD", 45, len(PL), 0)])
    ci = S.dir_sectors(22, 21, [(b"%05d.CLP" % n, 50 + i * 2, len(clps["%05d" % n]), 0)
                                for i, n in enumerate((1, 3, 7, 9))])
    # push clip 3's extent records across the directory's sector boundary
    for npad in range(30, 50):
        pad = [(b"PAD%04d.XXX" % i, 30, 10, 0) for i in range(npad)]
        recs = pad + [(b"00003.MPS", ext[0][0], ext[0][1], 0x80),
                      (b"00003.MPS", ext[1][0], ext[1][1], 0x80),
                      (b"00003.MPS", ext[2][0], ext[2][1], 0x00)]
        recs += [(b"%05d.MPS" % n, lba, k * SEC, 0) for n, (lba, k) in mps.items()]
        st = S.dir_sectors(23, 21, recs, nsec=2)
        if st.index(b"00003.MPS") < SEC < st.rindex(b"00003.MPS"):
            break
    else:
        raise AssertionError("extent records must straddle the directory's sectors")
    d.put(20, root, "root")
    d.put(21, uv, "umd_video")
    d.put(22, ci, "clipinf")
    d.put(23, st, "stream")
    d.put(40, SFO, "sfo")
    d.put(45, PL, "playlist")
    item_of = {3: 0, 1: 1, 7: 2}                          # the main playlist's order
    for i, n in enumerate((1, 3, 7)):
        d.put(50 + i * 2, clps["%05d" % n], "clp", item_of[n])
    d.put(56, clps["00009"])
    d.region(100, 2, "mps", 1)
    d.region(110, 4, "mps", 2)
    sseq = [l for lba, n in parts for l in range(lba, lba + n)]
    sseq += list(range(100, 102)) + list(range(110, 114))
    ns = F.NavScript(title_of(PL, clps), [[(lba, n) for lba, n in parts], [(100, 2)], [(110, 4)]])
    assert ns.phase0() == (sseq, True), "the model disagrees with the hand-written walk"
    ns.seek((0, 90000 + 3003 * 2), F.W_AFTER)       # the second extent's first sector
    ns.seek((0, 90000 + 3003 * 5), F.W_MID)         # the third extent, mid-transfer
    ns.seek((0, 90000 + 3003 * 4), F.W_AFTER)       # inside the second (entry at sector 3)
    ns.seek((2, 90000 * 7), F.W_AFTER)              # no video map: from sector 0, flagged
    ns.chap((1, 0), F.W_AFTER)                      # the main playlist has no marks (#0 does)
    write_good(stem, d, SFO, PL, {k: clps[k] for k in ("00001", "00003", "00007")}, sseq,
               (110, 4 * SEC), 3, ns)


def minimal(total=120, sfo_on=True, pl_magic=b"UMDV0088", clp_bad=False, mps_on=True,
            clp_on=True, interleave=False, umdv=True, vd="pvd"):
    """A one-clip disc with one knob turned; returns the Disc and its files."""
    d = Disc(total)
    if vd == "pvd":
        vds(d, 20)
    elif vd == "none":
        d.put(16, bytes(SEC))
        d.region(16, 1, "vd")
    elif vd == "term":
        d.put(16, S.terminator())
        d.region(16, 1, "vd")
    SFO = sfo([("TITLE", 0x0204, b"Min\0", 128)])
    PL = pl_magic + S.playlist_file([S.entry("Main", [("00001", 90000, 90000 * 60)], [])])[8:]
    CLP = S.clpi([(0xE0, 0, V_ATTR)], [(0xE0, 0, [(0xC000, 90000, 0)])])
    if clp_bad:
        CLP = CLP[:0x30] + struct.pack(">I", 99) + CLP[0x34:]
    MPS = pack(1, 0) + pack(1, 1)
    uv_ents = [(b"CLIPINF", 22, SEC, 2), (b"STREAM", 23, SEC, 2),
               (b"PLAYLIST.UMD", 41, len(PL), 0)]
    if sfo_on:
        uv_ents.append((b"PARAM.SFO", 40, len(SFO), 0))
    root = S.dir_sectors(20, 20, [(b"UMD_VIDEO" if umdv else b"PSP_GAME", 21, SEC, 2)])
    d.put(20, root, "root")
    if umdv:
        d.put(21, S.dir_sectors(21, 20, uv_ents), "umd_video")
        d.put(22, S.dir_sectors(22, 21, [(b"00001.CLP", 50, len(CLP), 0)] if clp_on else []),
              "clipinf")
        st = bytearray(S.dir_sectors(23, 21, [(b"00001.MPS", 60, len(MPS), 0)] if mps_on
                                     else []))
        if interleave:
            st[st.index(b"00001.MPS") - 33 + 26] = 1     # file unit size
        d.put(23, bytes(st), "stream")
        if sfo_on:
            d.put(40, SFO, "sfo")
        d.put(41, PL, "playlist")
        if clp_on:
            d.put(50, CLP, "clp")
        if mps_on:
            d.put(60, MPS, "mps")
    return d, SFO if sfo_on else None, PL, CLP, MPS


def syn_no_sfo(stem):
    d, sfo_raw, pl, clp, mps = minimal(sfo_on=False)
    ns = F.NavScript(title_of(pl, {"00001": clp}), [[(60, 2)]])
    ns.chap((0, 0), F.W_HALF)
    ns.chap((70000, 0), F.W_AFTER)                  # the key's item saturates past u16
    write_good(stem, d, None, pl, {"00001": clp}, [60, 61], (60, len(mps)), 1, ns)


# ---------------------------------------------------------------------------------
# The navigation port (P6b2)
NAV_A = 4000                        # item 0's video map: 40,000 bytes, 20 sectors of CLP


def pts_a(k):
    return 90000 + 9000 * k


def syn_nav(stem):
    d = Disc(9100)
    vds(d, 20)
    # item 0 starts at entry 3 (IN between entries) and stops at entry 3990: OUT is
    # exactly that entry's PTS (exclusive: the stop is the entry AT OUT, not the next)
    in0, out0 = pts_a(3) + 100, pts_a(NAV_A - 10)
    out2 = 2 ** 32 + 90000                                   # past the u32 an entry can hold
    marks = [(0, 2, 90000 * 3, "c2a"), (0, 0, pts_a(2000), "c0b"),
             (0, 2, 90000 * 6, "end", 16), (0, 1, 95000, "c1a"), (0, 0, pts_a(2000), "dup"),
             (0, 3, 1000, "gone"), (0, 0, in0, "c0a"), (0, 0, pts_a(3000), "c0c")]
    PL = S.playlist_file([S.entry("Trailer", [("00012", 90000, 90000 * 20)], []),
                          S.entry("Main", [("00011", in0, out0), ("00012", 90000, 90000 * 50),
                                           ("00013", 90000, out2)], marks),
                          S.entry("Empty", [], [])])      # P9: a PLAY of no item
    ents_a = [(0xC000, pts_a(k), 2 * k) for k in range(NAV_A)]
    CLP_A = S.clpi([(0xE0, 0, V_ATTR), (0xBD, 0x00, aud("en"))],
                   [(0xBD, 0x80, [(0, 90000, 0), (0, 99000, 7)]), (0xE0, 0, ents_a)],
                   start=90000, end=pts_a(NAV_A))
    CLP_B = S.clpi([(0xE0, 0, V_ATTR)], [(0xE0, 0, [(0xC000, 100000, 0)])],
                   start=90000, end=90000 * 60)
    CLP_C = S.clpi([(0xE0, 0, V_ATTR), (0xBD, 0x02, aud("ja"))],
                   [(0xE0, 0, [(0xC000, 90000 + 90000 * k, 3 * k) for k in range(5)]
                     + [(0xC000, 90000 * 7, 99)])],          # an entry past the clip (15 sectors)
                   start=90000, end=out2 + 90000)
    mps = {"00011": (1000, 2 * NAV_A), "00012": (9000, 4), "00013": (9010, 15)}
    for name, (lba, n) in mps.items():
        d.img.put(lba, b"".join(pack(int(name), k) for k in range(n)))
    root = S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, SEC, 2)])
    uv = S.dir_sectors(21, 20, [(b"CLIPINF", 22, SEC, 2), (b"STREAM", 23, SEC, 2),
                                (b"PLAYLIST.UMD", 40, len(PL), 0)])
    ci = S.dir_sectors(22, 21, [(b"00011.CLP", 50, len(CLP_A), 0),
                                (b"00012.CLP", 80, len(CLP_B), 0),
                                (b"00013.CLP", 82, len(CLP_C), 0)])
    st = S.dir_sectors(23, 21, [(b"%s.MPS" % n.encode(), lba, k * SEC, 0)
                                for n, (lba, k) in mps.items()])
    d.put(20, root, "root")
    d.put(21, uv, "umd_video")
    d.put(40, PL, "playlist")
    d.put(22, ci, "clipinf")
    d.put(23, st, "stream")
    for k, (name, clp, lba) in enumerate((("00011", CLP_A, 50), ("00012", CLP_B, 80),
                                          ("00013", CLP_C, 82))):
        d.put(lba, clp, "clp", k)
        d.region(mps[name][0], mps[name][1], "mps", k)
    # the entry of item 0 that straddles a CLP sector boundary
    import umd_clpi
    c = umd_clpi.parse(CLP_A)
    base = c["ep_map_off"] + 6 + struct.unpack(">I", CLP_A[c["ep_map_off"] + 8 + 10 + 6:
                                                       c["ep_map_off"] + 8 + 10 + 10])[0]
    strad = [j for j in range(100, NAV_A - 20) if (base + 10 * j) // SEC != (base + 10 * j + 9) // SEC]
    assert strad, "no straddling entry"
    clps = {"00011": CLP_A, "00012": CLP_B, "00013": CLP_C}
    import umd_playlist
    pls = umd_playlist.parse(PL)["playlists"]
    ns = F.NavScript(title_of(PL, clps), [[mps["00011"]], [mps["00012"]], [mps["00013"]]],
                     lambda p: (title_of(PL, clps, p),
                                [[mps[it["clip_name"]]] for it in pls[p]["items"]]), len(pls))
    sseq, _ = ns.phase0(cap=6)
    t = ns.t
    ns.chap((0, pts_a(2000)), F.W_HALF)               # on a duplicated chapter: prev == cur
    ns.seek((0, pts_a(2000)), F.W_MID)                # [ep] an exact hit
    ns.seek((0, pts_a(2000) - 1), F.W_AFTER)          #   one tick before it
    ns.seek((0, pts_a(strad[0])), F.W_MID)            #   the entry straddling a sector
    ns.seek((0, 0), F.W_AFTER)                        # [inout] before IN: clamped, entry 3
    ns.seek((1, 95000), F.W_AFTER, cap=24)            # before the first (only) entry; to the end
    ns.seek((1, 90000 * 40), F.W_AFTER, cap=3)        # past the last entry of a one-entry map
    ns.seek((0, pts_a(NAV_A - 11)), F.W_AFTER, cap=30)  # [inout] the stop, then items 1, 2
    ns.seek((0, 2 ** 40), F.W_AFTER, cap=30)          # past OUT: clamped to OUT - 4 (fix/skip-last-picture), entry 3989 to the stop
    ns.seek((2, 90000 * 3 + 5), F.W_AFTER)            # OUT past 2^32: NE_WIDE
    ns.seek((2, 2 ** 32 + 100), F.W_AFTER)            # the entry past the clip: NE_PAST, the end
    ns.seek((3, 0), F.W_AFTER)                        # no item 3: NE_ITEM
    ns.raw(0, F.W_AFTER, (0, 0), F.NE_OP)             # a reserved op
    # [time] P6c's NAV_TIME: Go To by the playlist's time across the three items (D15 / D16)
    d0, d1 = t.items[0].duration, t.items[1].duration
    ns.time(0, F.W_MID)                               # 0:00:00: item 0 at IN (entry 3)
    ns.time(d0 - 1, F.W_AFTER, cap=30)                #   a tick before the boundary: item 0's last
    ns.time(d0, F.W_AFTER)                            #   ON it: item 1 at IN (before its only entry)
    ns.time(d0 + d1 - 1, F.W_MID)                     # item 1's last tick
    ns.time(d0 + d1, F.W_AFTER)                       # item 2 at IN
    ns.time(d0 + d1 + 90000 * 3 + 5, F.W_AFTER)       # inside item 2: OUT past 2^32, NE_WIDE
    ns.time(2 ** 47, F.W_AFTER)                       # past the end: item 2's OUT - 4 (NE_PAST)
    ns.time(2 ** 48 - 1, F.W_HALF)                    # the largest time: no wrap
    for op in (5, 6, 7):
        ns.raw(op, F.W_AFTER, (0, 0), F.NE_OP)        # the reserved ops of the 3-bit nav_op
    # [play] P9's NAV_PLAY
    ns.play(3, (0, 0), F.W_AFTER)                     # no playlist 3: NE_ITEM, nothing changes
    ns.play(0, (0, 95000), F.W_MID)                   # the trailer (main item 1's clip), mid-transfer
    ns.chap((0, 0), F.W_HALF)                         # its marks: none
    ns.time(90000 * 5, F.W_AFTER)                     # P6c: ITS time (D15), not the feature's
    ns.time(2 ** 48 - 1, F.W_AFTER)                   #   the largest time on one item: IN + it wraps
    ns.seek((1, 0), F.W_AFTER)                        # its items: no item 1
    ns.play(0, (4, 2 ** 40), F.W_AFTER)               # no item 4: from item 0 at IN, NE_ITEM
    ns.play(2, (0, 0), F.W_AFTER)                     # no item at all: lands on its end
    ns.time(0, F.W_AFTER)                             # P6c: a TIME on it: NE_ITEM, nothing changes
    ns.play(1, (2, 90000 * 3 + 5), F.W_AFTER)         # back to the feature, NE_WIDE passed on
    ns.chap((0, pts_a(2000)), F.W_AFTER)              # its marks again
    for key in ((70000, 0), (0, 0), (1, 0), (2, 90000 * 6), (0, in0 - 1), (0, pts_a(3000))):
        ns.chap(key, F.W_AFTER)
    assert t.chapter_query((0, pts_a(2000)))[2:4] == ((0, pts_a(2000)),) * 2
    write_good(stem, d, None, PL, {"00011": CLP_A}, sseq, (1000, 2 * NAV_A * SEC), 11, ns, 0)


def syn_wide(stem):
    """A12 (docs/nav_engine.md S9): 48- and 64-bit sums that CARRY across 32 bits -- two items of
    0xC0000000 ticks (9.9 h each: the playlist's duration and the third item's title time carry),
    then an item at IN 0xFFFF0000 (a Go To by time landing in it adds IN and the remainder with a
    carry). No disc of the library reaches 2^32 ticks; the format allows it."""
    d = Disc(9100)
    vds(d, 20)
    big = 0xC0000000
    in_c, out_c = 0xFFFF0000, 0xFFFF0000 + 0x40000          # OUT past 2^32 (NE_WIDE)
    PL = S.playlist_file([S.entry("Main", [("00021", 90000, 90000 + big),
                                           ("00022", 90000, 90000 + big),
                                           ("00023", in_c, out_c)], [])])
    step = big // 8
    CLP_A = S.clpi([(0xE0, 0, V_ATTR)], [(0xE0, 0, [(0xC000, 90000 + step * k, 2 * k)
                                                    for k in range(9)])],
                   start=90000, end=90000 + big + 1)
    CLP_B = S.clpi([(0xE0, 0, V_ATTR), (0xBD, 0x01, aud("fr"))],
                   [(0xE0, 0, [(0xC000, 90000 + step * k, 2 * k) for k in range(9)])],
                   start=90000, end=90000 + big + 1)
    CLP_C = S.clpi([(0xE0, 0, V_ATTR), (0xBD, 0x02, aud("ja"))],
                   [(0xE0, 0, [(0xC000, in_c + 0x2000 * k, 2 * k) for k in range(8)])],
                   start=in_c, end=out_c)
    mps = {"00021": (1000, 18), "00022": (2000, 18), "00023": (3000, 16)}
    for name, (lba, n) in mps.items():
        d.img.put(lba, b"".join(pack(int(name), k) for k in range(n)))
    root = S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, SEC, 2)])
    uv = S.dir_sectors(21, 20, [(b"CLIPINF", 22, SEC, 2), (b"STREAM", 23, SEC, 2),
                                (b"PLAYLIST.UMD", 40, len(PL), 0)])
    ci = S.dir_sectors(22, 21, [(b"00021.CLP", 50, len(CLP_A), 0),
                                (b"00022.CLP", 60, len(CLP_B), 0),
                                (b"00023.CLP", 70, len(CLP_C), 0)])
    st = S.dir_sectors(23, 21, [(b"%s.MPS" % n.encode(), lba, k * SEC, 0)
                                for n, (lba, k) in mps.items()])
    d.put(20, root, "root")
    d.put(21, uv, "umd_video")
    d.put(40, PL, "playlist")
    d.put(22, ci, "clipinf")
    d.put(23, st, "stream")
    for k, (name, clp, lba) in enumerate((("00021", CLP_A, 50), ("00022", CLP_B, 60),
                                          ("00023", CLP_C, 70))):
        d.put(lba, clp, "clp", k)
        d.region(mps[name][0], mps[name][1], "mps", k)
    clps = {"00021": CLP_A, "00022": CLP_B, "00023": CLP_C}
    ns = F.NavScript(title_of(PL, clps), [[mps["00021"]], [mps["00022"]], [mps["00023"]]])
    sseq, _ = ns.phase0(cap=6)
    t = ns.t
    d0, d1 = t.items[0].duration, t.items[1].duration
    ns.time(d0 + d1 + 0x10005, F.W_MID)           # in item 2: IN + 0x10005 carries past 2^32
    ns.time(d0 + 5, F.W_AFTER)                    # item 1, its title time 0xC0000000 + 5
    ns.time(d0 + d1 - 1, F.W_AFTER)               # item 1's last tick: the sum d0 + d1 carries
    ns.seek((2, in_c + 0x4000), F.W_AFTER)        # a seek into item 2 (its base carries)
    ns.time(2 ** 40, F.W_AFTER)                   # past the end: item 2's OUT - 4
    write_good(stem, d, None, PL, {"00021": CLP_A}, sseq, (1000, 18 * SEC), 21, ns, 0)


N_MAX = 65535


def syn_marks_max(stem):
    """65,535 marks: the scan's spec maximum (u16). Keys pseudo-random, every eighth an
    Endmark, every thirteenth on item 1 (which does not exist), runs of equal keys."""
    import random
    rng = random.Random(65535)
    marks, key = [], None
    for i in range(N_MAX):
        if key is None or i % 997 != 0:
            key = (1 if i % 13 == 5 else 0, rng.randrange(0, 2 ** 48))
        marks.append((0, key[0], key[1], "", 16 if i % 8 == 7 else 5))
    PL = S.playlist_file([S.entry("Main", [("00001", 90000, 90000 * 60)], marks)])
    npl = nsec(len(PL))
    d = Disc(100 + npl + 10)
    vds(d, 20)
    CLP = S.clpi([(0xE0, 0, V_ATTR)], [(0xE0, 0, [(0xC000, 90000, 0)])])
    MPS = pack(1, 0) + pack(1, 1)
    d.put(20, S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, SEC, 2)]), "root")
    d.put(21, S.dir_sectors(21, 20, [(b"CLIPINF", 22, SEC, 2), (b"STREAM", 23, SEC, 2),
                                     (b"PLAYLIST.UMD", 100, len(PL), 0)]), "umd_video")
    d.put(22, S.dir_sectors(22, 21, [(b"00001.CLP", 30, len(CLP), 0)]), "clipinf")
    d.put(23, S.dir_sectors(23, 21, [(b"00001.MPS", 31, len(MPS), 0)]), "stream")
    d.put(100, PL, "playlist")
    d.put(30, CLP, "clp")
    d.put(31, MPS, "mps")
    ns = F.NavScript(title_of(PL, {"00001": CLP}), [[(31, 2)]])
    mid = ns.t.chapters[len(ns.t.chapters) // 2]
    ns.chap(mid, F.W_HALF)
    ns.chap((0, 2 ** 48 - 1), F.W_AFTER)
    write_good(stem, d, None, PL, {"00001": CLP}, [31, 32], (31, len(MPS)), 1, ns)


def syn_badmarks(stem, oob=False):
    """The main playlist's marks header broken in the image (the goldens from its good
    twin): a length that does not hold the count (NE_MARKS), or a count, with a length to
    match, that runs past the file (NE_OOB). Neither may stop playback."""
    d, sfo_raw, pl, clp, mps = minimal()
    e0 = 0x130 + 6
    m = e0 + struct.unpack(">H", pl[e0 + 6:e0 + 8])[0]
    assert pl[m:m + 6] == struct.pack(">IH", 2, 0)
    bad = pl[:m] + (struct.pack(">IH", 2 + 40 * N_MAX, N_MAX) if oob
                    else struct.pack(">IH", 7, 0)) + pl[m + 6:]
    d.put(41, bad)
    ns = F.NavScript(title_of(pl, {"00001": clp}), [[(60, 2)]])
    ns.chap((0, 0), F.W_HALF, err=F.NE_OOB if oob else F.NE_MARKS)
    ns.seek((0, 0), F.W_AFTER)                       # the reader goes on
    write_good(stem, d, sfo_raw, pl, {"00001": clp}, [60, 61], (60, len(mps)), 1, ns)


ERRS = {
    "err_small":      (E_SMALL,      dict(total=10)),
    "err_not_iso":    (E_NOT_ISO,    dict(vd="none")),
    "err_no_pvd":     (E_NOT_ISO,    dict(vd="term")),
    "err_no_umdv":    (E_NO_UMDV,    dict(umdv=False)),
    "err_bad_pl":     (E_NO_PL,      dict(pl_magic=b"UMDV0089")),
    "err_no_clp":     (E_NO_CLP,     dict(clp_on=False)),
    "err_bad_clp":    (E_CLP,        dict(clp_bad=True)),
    "err_no_mps":     (E_NO_MPS,     dict(mps_on=False)),
    "err_interleave": (E_INTERLEAVE, dict(interleave=True)),
}


# ---------------------------------------------------------------------------------
# P8: bare stream files
def psmf_head(off, size, first, last, nsec_hdr=1):
    """A PSMF header (JPCSP scePsmf.java's layout, docs/bare_streams.md), nsec_hdr sectors."""
    h = bytearray(SEC * nsec_hdr)
    h[0:8] = b"PSMF0014"
    h[8:16] = struct.pack(">II", off, size)
    h[0x54:0x5A] = first.to_bytes(6, "big")
    h[0x5A:0x60] = last.to_bytes(6, "big")
    h[0x80:0x82] = struct.pack(">H", 1)
    h[0x82:0x86] = bytes([0xE0, 0x00, 0x20, 0x44])
    h[0x82 + 12], h[0x82 + 13] = 30, 17                 # 480x272
    return bytes(h)


def packs(n, clip=9):
    return b"".join(pack(clip, k) for k in range(n))


BARE = {
    "syn_bare_mps": lambda: (packs(12), None),
    "syn_bare_small": lambda: (packs(8), None),
    # (a first PTS other than 90000: IN stays 90000, the header's PTS are not read)
    "syn_pmf": lambda: (psmf_head(SEC, 10 * SEC, 180000, 180000 + 450450) + packs(10), None),
    "syn_pmf_2sec": lambda: (psmf_head(2 * SEC, 10 * SEC, 90000, 90000 + 3003, 2) + packs(10), None),
    "syn_pmf_cut": lambda: (psmf_head(SEC, 20 * SEC, 90000, 90000 + 900900) + packs(10), None),
    "syn_pmf_short": lambda: (psmf_head(SEC, 6 * SEC, 90000, 90000) + packs(10), None),
    "err_pmf_off0": lambda: (psmf_head(0, 10 * SEC, 90000, 180000) + packs(10), None),
    "err_pmf_unaligned": lambda: (psmf_head(SEC + 16, 10 * SEC, 90000, 180000) + packs(10), None),
    "err_pmf_past": lambda: (psmf_head(11 * SEC, 0, 90000, 180000) + packs(10), None),
    "err_bare_huge": lambda: (packs(4), 1 << 32),
}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--dir", default=F.OUT_DIR)
    a = ap.parse_args(argv)
    os.makedirs(a.dir, exist_ok=True)
    stems = []
    for name, fn in (("syn_basic", syn_basic), ("syn_multi", syn_multi),
                     ("syn_no_sfo", syn_no_sfo), ("syn_nav", syn_nav), ("syn_wide", syn_wide),
                     ("syn_marks_max", syn_marks_max), ("syn_badmarks", syn_badmarks),
                     ("syn_oobmarks", lambda st: syn_badmarks(st, oob=True))):
        fn(os.path.join(a.dir, name))
        stems.append(name)
    for name, (err, kw) in ERRS.items():
        if kw.get("total") == 10:
            d = Disc(10)
            d.put(0, bytes(SEC))
            d.region(0, 1, "vd")
        else:
            d = minimal(**kw)[0]
        write_err(os.path.join(a.dir, name), d, err)
        stems.append(name)
    for name, fn in BARE.items():
        raw, size = fn()
        err, _mode, _n = F.bare_fixture(os.path.join(a.dir, name), raw, size)
        if (err != 0) != name.startswith("err_") or (err and err != E_BARE):
            raise SystemExit("%s: the golden says err_code %d" % (name, err))
        stems.append(name)
    print("\n".join(stems))
    return 0


if __name__ == "__main__":
    sys.exit(main())
