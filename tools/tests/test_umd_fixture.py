#!/usr/bin/env python3
"""umd_fixture on a synthetic disc: the --nav walk follows the LONGEST playlist (not #0)
to its clip, lists its regions in walk order with the dependency masks the P2 reader
bench enforces, predicts the reader's outputs from the P1 parsers, and the written
.hex/.lba/.reg/.sseq/.exp/.title/.meta files round-trip; a --lba cut and a --pts cut
(EP-aligned) carry the exact bytes and the documented meta words."""
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_fixture as F  # noqa: E402
import umd_iso  # noqa: E402

T = S.Score("test_umd_fixture")

SFO = (b"\0PSF" + struct.pack("<4I", 0x101, 36, 44, 1) +
       struct.pack("<HHIII", 0, 0x0204, 5, 8, 0) + b"TITLE\0\0\0" + b"Film\0\0\0\0")
PL = S.playlist_file([S.entry("Intro", [("00001", 90000, 90000 * 10)], []),
                      S.entry("Main", [("00002", 90000, 90000 * 999)], [])])
V = bytes.fromhex("1410000000000000")
CLP1 = S.clpi([(0xE0, 0, V)], [(0xE0, 0, [(0xC000, 90000, 0)])])
CLP2 = S.clpi([(0xE0, 0, V)], [(0xE0, 0, [(0xC000, 90000, 0), (0xC000, 180000, 3),
                                          (0xC000, 270000, 6)])])
MPS2 = b"".join(S.fill_pack([S.pes(0xE0, bytes([i]) * 100, pts=90000 + 30000 * i)])
                for i in range(8))
MPS1 = S.fill_pack([S.pes(0xE0, b"x" * 50, pts=90000)])


def disc():
    b = S.ImageBuilder(120)
    b.put(16, S.pvd(20, 2048, 120))
    b.put(17, S.terminator())
    b.put(20, S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, 2048, 2)]))
    b.put(21, S.dir_sectors(21, 20, [(b"CLIPINF", 22, 2048, 2), (b"PARAM.SFO;1", 30, len(SFO), 0),
                                     (b"PLAYLIST.UMD;1", 31, len(PL), 0), (b"STREAM", 23, 2048, 2)]))
    b.put(22, S.dir_sectors(22, 21, [(b"00001.CLP;1", 40, len(CLP1), 0),
                                     (b"00002.CLP;1", 41, len(CLP2), 0)]))
    b.put(23, S.dir_sectors(23, 21, [(b"00001.MPS;1", 50, len(MPS1), 0),
                                     (b"00002.MPS;1", 60, len(MPS2), 0)]))
    for lba, d in ((30, SFO), (31, PL), (40, CLP1), (41, CLP2), (50, MPS1), (60, MPS2)):
        b.put(lba, d)
    return b.build()


print("[nav walk]")
img = disc()
iso = umd_iso.UmdIso(img)
regions, sseq, info = F.nav_walk(iso, stream_packs=2)
T.check("nav walk follows the main (longest) playlist", info["main_playlist"], 1)
T.check("-> clip 2, first extent at LBA 60", (info["clip"], info["mps_first"]),
        (2, (60, len(MPS2))))
T.check("regions in walk order", regions,
        [(16, 2, "vd", 0), (20, 1, "root", 0), (21, 1, "umd_video", 0), (30, 1, "sfo", 0),
         (31, 1, "playlist", 0), (22, 1, "clipinf", 0), (23, 1, "stream", 0),
         (41, 1, "clp", 0), (60, 8, "mps", 0)])
T.check("stream = the first 2 packs", sseq, [60, 61])
bits = lambda m: [j for j in range(len(regions)) if m >> j & 1]
T.check("clp depends on playlist + clipinf", bits(F.deps_mask(regions, 7)), [4, 5])
T.check("mps depends on playlist + stream + its clp", bits(F.deps_mask(regions, 8)), [4, 6, 7])
exp, title, langs = F.reader_expect(info["sfo_raw"], info["pl_raw"], info["clps"],
                                    info["mps_first"])
got = dict(zip(F.EXP_WORDS, exp))
T.check("expect: main playlist, count, items", (got["main_pl"], got["n_playlists"],
                                                got["n_items"]), (1, 2, 1))
T.check("expect: title by key", (title, got["title_len"], got["sfo_flags"]), (b"Film\0", 5, 0))
T.check("expect: clip name 00002", (got["clip_name_hi"], got["clip_name_lo"],
                                    got["clip_name_len"]), (0x30303030, 0x32000000, 5))
T.check("expect: video attr, 1 stream", (got["vid_attr"], got["n_streams"]), (0x1014, 1))

print("[files]")
with tempfile.TemporaryDirectory() as d:
    path = os.path.join(d, "disc.iso")
    open(path, "wb").write(img)
    F.main([path, "--nav", "--stream-packs", "2", "--out", "nav", "--dir", d])
    lbas = F.read_words(os.path.join(d, "nav.lba.hex"))
    data = F.read_bytes(os.path.join(d, "nav.hex"))
    want = sorted(set(l for a, n, k, it in regions if k != "mps" for l in range(a, a + n))
                  | set(sseq))
    T.check("sectors = every nav region + the stream packs", lbas, want)
    T.check("sector bytes by index", [data[i * 2048:(i + 1) * 2048] == img[l * 2048:(l + 1) * 2048]
                                      for i, l in enumerate(lbas)], [True] * len(lbas))
    reg = F.read_words(os.path.join(d, "nav.reg.hex"))
    # region 8, REG_WORDS each: lba, n, kind<<16|item, the walk's 128-bit mask, the nav mask
    # (item 0 has no predecessor, so the two masks agree)
    deps = [(1 << 4) | (1 << 6) | (1 << 7), 0, 0, 0]
    T.check("reg file: lba, n, kind<<16|item, walk deps, nav deps",
            reg[8 * F.REG_WORDS:9 * F.REG_WORDS], [60, 8, F.MPS_KIND << 16] + deps + deps)
    T.check("sseq file", F.read_words(os.path.join(d, "nav.sseq.hex")), sseq)
    T.check("exp file", F.read_words(os.path.join(d, "nav.exp.hex")), exp)
    T.check("nav meta (incomplete: 2 of 8 packs)", F.read_words(os.path.join(d, "nav.meta.hex")),
            [len(lbas), len(regions), 2, 0, 2, 1, len(img), 0, 0, 0, 0, 0])   # no script; an image
    F.main([path, "--clip", "2", "--lba", "2", "5", "--out", "cut", "--dir", d])
    T.check("lba cut bytes", F.read_bytes(os.path.join(d, "cut.hex")), MPS2[2 * 2048:5 * 2048])
    T.check("lba cut meta (not on an EP entry)", F.read_words(os.path.join(d, "cut.meta.hex")),
            [3 * 2048, 2, 3, 2, 0xFFFFFFFF])
    F.main([path, "--clip", "2", "--pts", "200000", "250000", "--out", "p", "--dir", d])
    T.check("pts cut = EP entry at/before A .. entry after B",
            F.read_words(os.path.join(d, "p.meta.hex")), [3 * 2048, 3, 3, 2, 180000])
    T.raises("cut past the clip", lambda: F.main([path, "--clip", "2", "--lba", "5", "99",
                                                 "--out", "x", "--dir", d]),
             F.FixtureError, "outside the clip")
T.raises("meta word too wide", lambda: F.write_words(os.devnull, [1 << 32]), F.FixtureError,
         "32 bits")

print("[bare]")
# P8: what the reader must make of a bare stream file (umd_fixture.bare_expect), from the
# PSMF layout (JPCSP scePsmf.java) written here by hand:
# -> (err, mode, pmf_warn, first stream sector, sectors, IN, duration)
pk = S.fill_pack([S.pes(0xE0, b"\x00" * 100, pts=90000)])


def pmf(off, size, first, last, n):
    h = bytearray(off)
    h[0:8] = b"PSMF0015"
    h[8:16] = struct.pack(">II", off, size)
    h[0x54:0x5A] = first.to_bytes(6, "big")
    h[0x5A:0x60] = last.to_bytes(6, "big")
    return bytes(h) + pk * n


T.check("an .MPS: the whole file from sector 0, IN 90000, no duration",
        F.bare_expect(pk * 5), (0, 1, 0, 0, 5, 90000, 0))
T.check("an .MPS's last sector partial: counted",
        F.bare_expect(pk * 5 + b"\x00" * 7), (0, 1, 0, 0, 6, 90000, 0))
T.check("a .PMF: from its offset, IN 90000 whatever its header says, no duration",
        F.bare_expect(pmf(2048, 4 * 2048, 180000, 270000, 4)), (0, 2, 0, 1, 4, 90000, 0))
T.check("a .PMF whose size runs past the file: cut, flagged",
        F.bare_expect(pmf(2048, 9 * 2048, 90000, 90000, 4)), (0, 2, 1, 1, 4, 90000, 0))
T.check("a .PMF whose size ends early: the size, flagged",
        F.bare_expect(pmf(2048, 2 * 2048, 90000, 80000, 4)), (0, 2, 1, 1, 2, 90000, 0))
T.check("a .PMF offset not 2048-aligned: E_BARE",
        F.bare_expect(pmf(2048, 4 * 2048, 90000, 90000, 4)[:8] + struct.pack(">II", 2050, 0) +
                      pmf(2048, 4 * 2048, 90000, 90000, 4)[16:])[0], F.E_BARE)
T.check("a file of 4 GB: E_BARE", F.bare_expect(pk, 1 << 32)[0], F.E_BARE)
T.check("a file one byte under 4 GB: a stream", F.bare_expect(pk, (1 << 32) - 1)[:2], (0, 1))
T.raises("an image is not a bare stream", lambda: F.bare_expect(bytes(4096)), F.FixtureError,
         "not a bare stream")
T.finish()
