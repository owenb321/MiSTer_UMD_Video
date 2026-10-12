#!/usr/bin/env python3
"""umd_clpi.parse()/lookup()/verify() on synthetic CLPI0088 files built from the layout
measured on real discs (docs/umd_video_format.md "CLIPINF"), not from the parser.

verify() is the instrument that CONFIRMS the EP map against the stream, so it is scored
both ways: a correct synthetic clip passes, and a clip whose EP map points one sector
off, at the wrong PTS, or at a PES that does not open with an AUD, is reported.
"""
import os
import struct
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_clpi  # noqa: E402

T = S.Score("test_umd_clpi")
u48 = S.u48
clpi = S.clpi

VID = bytes.fromhex("1410000000000000")
AUD = bytes.fromhex("f000656e02010000")
SUB = bytes.fromhex("f000656e00100000")
vmap = [(0xC000, 90000, 0), (0xC038, 225135, 2), (0xC036, 360270, 4)]
smap = [(0, 200000, 3)]
raw = clpi([(0xE0, 0, VID), (0xBD, 0, AUD), (0xBD, 0x80, SUB)],
           [(0xE0, 0, vmap), (0xBD, 0x80, smap)])

print("[parse]")
c = umd_clpi.parse(raw)
T.check("pts range", (c["start_pts"], c["end_pts"]), (90000, 900000))
T.check("stream kinds", [s["kind"] for s in c["streams"]], ["video", "audio", "subtitle"])
T.check("audio lang/channels/rate", (c["streams"][1]["lang"], c["streams"][1]["channels"],
                                     c["streams"][1]["rate_code"]), ("en", 2, 1))
T.check("video EP entries", umd_clpi.video_map(c), vmap)
T.check("subtitle EP entries", c["ep_maps"][1]["entries"], smap)
T.check("lookup mid", umd_clpi.lookup(c, 300000), (225135, 2))
T.check("lookup before first", umd_clpi.lookup(c, 10), (90000, 0))
T.check("lookup exact", umd_clpi.lookup(c, 360270), (360270, 4))

print("[rejections]")
T.raises("magic", lambda: umd_clpi.parse(b"CLPI0099" + raw[8:]), umd_clpi.ClpiError, "magic")
bad = bytearray(raw)
struct.pack_into(">I", bad, 0x30, 99)
T.raises("stream_info length", lambda: umd_clpi.parse(bytes(bad)), umd_clpi.ClpiError,
         "does not hold")
T.raises("EP entries truncated", lambda: umd_clpi.parse(raw[:-5]), umd_clpi.ClpiError,
         "runs past the end")
bad = bytearray(raw)
ep_off = struct.unpack(">I", raw[12:16])[0]
struct.pack_into(">I", bad, ep_off + 8 + 2, 2)          # video map claims 2 of 3 entries
T.raises("unaccounted EP bytes", lambda: umd_clpi.parse(bytes(bad)), umd_clpi.ClpiError,
         "unaccounted")


# --- verify(): a synthetic image with a 6-pack .MPS -------------------------------
def mps(vpts=(90000, 225135, 360270), subpts=200000):
    aud_ = b"\x00\x00\x00\x00" + bytes.fromhex("0fd0485500000000") + bytes(40)
    au = b"\x00\x00\x00\x01\x09\x10\x00\x00\x00\x01\x27\x4d" + bytes(30)
    packs = []
    for i in range(6):
        if i in (0, 2, 4):
            packs.append(S.fill_pack([S.pes(0xE0, au, pts=vpts[i // 2])]))
        elif i == 3:
            packs.append(S.fill_pack([S.pes(0xBD, b"\x80\x00\x00\x00" + bytes(20), pts=subpts)]))
        else:
            packs.append(S.fill_pack([S.pes(0xE0, bytes(100)), S.pes(0xBD, aud_, pts=90000)]))
    return b"".join(packs)


def image(clp, stream):
    b = S.ImageBuilder(60)
    b.put(16, S.pvd(20, 2048, 60))
    b.put(17, S.terminator())
    b.put(20, S.dir_sectors(20, 20, [(b"UMD_VIDEO", 21, 2048, 2)]))
    b.put(21, S.dir_sectors(21, 20, [(b"CLIPINF", 22, 2048, 2), (b"STREAM", 23, 2048, 2)]))
    b.put(22, S.dir_sectors(22, 21, [(b"00001.CLP;1", 30, len(clp), 0)]))
    b.put(23, S.dir_sectors(23, 21, [(b"00001.MPS;1", 40, len(stream), 0)]))
    b.put(30, clp)
    b.put(40, stream)
    return b.build()


def run_verify(clp, stream=None):
    fd, path = tempfile.mkstemp(suffix=".iso")
    with os.fdopen(fd, "wb") as f:
        f.write(image(clp, stream or mps()))
    try:
        return umd_clpi.verify(path, 1)
    finally:
        os.unlink(path)


print("[verify]")
streams = [(0xE0, 0, VID), (0xBD, 0, AUD), (0xBD, 0x80, SUB)]
T.check("correct clip verifies", run_verify(raw), [])
off1 = clpi(streams, [(0xE0, 0, [(0xC000, 90000, 0), (0xC038, 225135, 3), (0xC036, 360270, 4)])])
T.check("sector one off is reported", len(run_verify(off1)), 1)
wpts = clpi(streams, [(0xE0, 0, [(0xC000, 90000, 0), (0xC038, 225136, 2), (0xC036, 360270, 4)])])
T.check("PTS one tick off is reported", len(run_verify(wpts)), 1)
nomono = clpi(streams, [(0xE0, 0, [(0xC000, 90000, 0), (0xC038, 225135, 4), (0xC036, 360270, 2)])])
T.check("non-monotonic map is reported", any("not increasing" in b for b in run_verify(nomono)),
        True)
past = clpi(streams, [(0xE0, 0, [(0xC000, 90000, 0), (0xC000, 99999, 6)])])
T.check("sector past the clip is reported", any("past the clip" in b for b in run_verify(past)),
        True)
subw = clpi(streams, [(0xBD, 0x80, [(0, 200000, 2)])])
T.check("subtitle entry at a video pack is reported", len(run_verify(subw)), 1)
noaud = mps()
noaud = noaud.replace(b"\x00\x00\x00\x01\x09\x10", b"\x00\x00\x00\x01\x41\x10")
T.check("payload without an AUD is reported", len(run_verify(raw, noaud)), 3)
T.finish()
