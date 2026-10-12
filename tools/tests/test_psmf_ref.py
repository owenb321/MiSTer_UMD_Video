#!/usr/bin/env python3
"""psmf_ref.parse()/es() on hand-built packs (tests/umd_synth.py, written from
ISO/IEC 13818-1 and the measured UMD substream layout).

Every stream class is present, so each accounting bucket is scored against a total the
builder computed independently; PTS/DTS round-trip through 33 bits; ES bytes and
(offset, pts, fap) marks per substream; a short 0xBD PES; junk between packs is counted,
not dropped; a truncated PES raises.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import psmf_ref  # noqa: E402

T = S.Score("test_psmf_ref")

AU = bytes.fromhex("0fd0485500000000")
vid1 = b"\x00\x00\x00\x01\x09\x10" + bytes(range(1, 200))
vid2 = bytes(range(50, 250)) * 3
aud0 = AU + bytes([0xA5]) * 100              # FAP 0: the AU header starts the payload
aud0b = bytes([0x5A]) * 20 + AU + b"\x11" * 30   # FAP 20
aud1 = AU + b"\x22" * 64
sub80 = b"\x00\x00\x03\xfe0088" + b"PNGDATA" * 5
p2 = b"\x01\xe0" + bytes(60)
BIG = (1 << 33) - 3                           # a PTS using bit 32

packs = [
    S.fill_pack([S.pes(0xBB, bytes(12)), S.pes(0xBF, p2),
                 S.pes(0xE0, vid1, pts=BIG, dts=BIG - 3003)], scr=1000),
    S.fill_pack([S.pes(0xBD, b"\x00\x00\x00\x00" + aud0, pts=90000),
                 S.pes(0xBD, b"\x01\x00\x00\x00" + aud1, pts=90001)]),
    S.fill_pack([S.pes(0xE0, vid2),
                 S.pes(0xBD, b"\x00\x00\x00\x14" + aud0b, pts=93003),
                 S.pes(0xBD, b"\x80\x00" + sub80, pts=180000),
                 S.pes(0xBD, b"\x80\x00\x82"),       # the 1-byte subtitle PES Akira has
                 S.pes(0xBD, b"\x81")]),               # a PES too short for any sub-header
]
data = b"".join(packs)

print("[accounting]")
r = psmf_ref.parse(data)
T.check("packs", (r.packs, r.unaligned_packs), (3, 0))
T.check("total == size", r.total(), len(data))
T.check("no junk", r.acct["junk"], 0)
T.check("video bytes", r.acct["video"], len(vid1) + len(vid2))
T.check("audio bytes (sub-header excluded)", r.acct["audio"],
        len(aud0) + len(aud1) + len(aud0b))
T.check("sub bytes (2-byte sub-header excluded)", r.acct["sub"], len(sub80) + 1)
T.check("private2 bytes", r.acct["private2"], 6 + len(p2))
T.check("system bytes", r.acct["system"], 6 + 12)
T.check("pack header bytes", r.acct["pack"], 3 * 14)
T.check("short 0xBD counted", r.short_bd, 1)
T.check("sub-header lengths by class", sorted(set((p.kind, len(p.subhdr)) for p in r.packets
                                                   if p.sid == 0xBD)),
        [("audio", 4), ("sub", 1), ("sub", 2)])

print("[timestamps]")
v = [p for p in r.packets if p.kind == "video"]
T.check("33-bit PTS", v[0].pts, BIG)
T.check("DTS", v[0].dts, BIG - 3003)
T.check("no PTS on continuation", (v[1].pts, v[1].dts), (None, None))

print("[elementary streams]")
e, m = psmf_ref.es(data, r, "audio", 0)
T.check("audio:0 bytes", e, aud0 + aud0b)
T.check("audio:0 marks", m, [(0, 90000, None, 0), (len(aud0), 93003, None, 20)])
T.check("FAP lands on an AU header", e[m[1][0] + m[1][3]:m[1][0] + m[1][3] + 8], AU)
e, m = psmf_ref.es(data, r, "audio", 1)
T.check("audio:1 bytes", e, aud1)
e, m = psmf_ref.es(data, r, "video")
T.check("video ES", e, vid1 + vid2)
T.check("video marks", [(o, p) for o, p, _, _ in m], [(0, BIG), (len(vid1), None)])
e, m = psmf_ref.es(data, r, "sub", 0x80)
T.check("sub ES", e, sub80 + b"\x82")
T.check("subtitle PES carry no FAP", [x[3] for x in m], [None, None])

print("[substream classes]")
edge = S.fill_pack([S.pes(0xBD, b"\x9c\x00" + b"S" * 10, pts=1),     # subtitle (Desperado)
                    S.pes(0xBD, b"\xa0\x00" + b"?" * 10, pts=2),     # beyond: bd_other
                    S.pes(0xBD, b"\x0f\x00\x00\x00" + b"A" * 10, pts=3)])
re_ = psmf_ref.parse(edge)
T.check("0x9C is a subtitle, 0xA0 is bd_other, 0x0F audio",
        [(p.sub, p.kind) for p in re_.packets if p.sid == 0xBD],
        [(0x9C, "sub"), (0xA0, "bd_other"), (0x0F, "audio")])
T.check("bd_other PES counted whole (6 + 3 + PTS 5 + 12)", re_.acct["bd_other"], 26)

print("[robustness]")
junky = packs[0] + b"\xde\xad\xbe\xef" * 3 + packs[1]
r2 = psmf_ref.parse(junky)
T.check("junk counted, total still exact", (r2.acct["junk"], r2.total()), (12, len(junky)))
T.check("unaligned pack seen", r2.unaligned_packs, 1)
T.raises("truncated PES", lambda: psmf_ref.parse(data[:2048 + 100]), psmf_ref.PsError,
         "runs past the end")

print("[psmf header]")
# a .PMF as the census measured them (docs/bare_streams.md): one header sector, then the
# stream; layout from JPCSP scePsmf.java -- offsets written here by hand, not by psmf_ref
import struct  # noqa: E402
import tempfile  # noqa: E402


def psmf(off, size, first, last, streams):
    h = bytearray(off)
    h[0:8] = b"PSMF0014"
    h[8:16] = struct.pack(">II", off, size)
    h[0x54:0x5A] = first.to_bytes(6, "big")
    h[0x5A:0x60] = last.to_bytes(6, "big")
    h[0x80:0x82] = struct.pack(">H", len(streams))
    for i, (sid, sub, w16, h16) in enumerate(streams):
        q = 0x82 + 16 * i
        h[q:q + 4] = bytes([sid, sub, 0x20, 0x04])
        h[q + 12], h[q + 13] = w16, h16
    return bytes(h)


LAST = (1 << 32) + 3003               # past 32 bits: the field is a u48 (JPCSP readTimestamp)
hdr = psmf(0x800, len(data), 90000, LAST, [(0xE0, 0, 30, 17), (0xBD, 0, 0, 0)])
h = psmf_ref.psmf_header(hdr, len(hdr) + len(data))
T.check("offset / size / end", (h["stream_offset"], h["stream_size"], h["stream_end"],
                                 h["size_mismatch"]), (0x800, len(data), 0x800 + len(data), False))
T.check("first / last PTS (u48 BE)", (h["first_pts"], h["last_pts"]), (90000, LAST))
T.check("stream table", [(e["sid"], e["sub"], e["w"], e["h"]) for e in h["streams"]],
        [(0xE0, 0, 480, 272), (0xBD, 0, 0, 0)])
h2 = psmf_ref.psmf_header(hdr, len(hdr) + len(data) - 2048)
T.check("a size past the file: cut at the file, flagged", (h2["stream_end"], h2["size_mismatch"]),
        (len(hdr) + len(data) - 2048, True))
T.raises("offset 0", lambda: psmf_ref.psmf_header(psmf(0x800, 0, 0, 0, [])[:8] + bytes(8) +
                                                    bytes(0x800 - 16), 0x4000),
         psmf_ref.PsError, "offset")
T.raises("offset not 2048-aligned", lambda: psmf_ref.psmf_header(
    psmf(0x800, 0, 0, 0, [])[:8] + struct.pack(">II", 0x900, 0) + bytes(0x800 - 16), 0x4000),
    psmf_ref.PsError, "offset")
T.raises("offset past the file", lambda: psmf_ref.psmf_header(psmf(0x800, 0, 0, 0, []), 0x800),
         psmf_ref.PsError, "offset")
with tempfile.NamedTemporaryFile(suffix=".pmf") as f:
    f.write(hdr + data)
    f.flush()
    src = psmf_ref.Source(f.name)
    try:
        r3 = psmf_ref.parse(src.mm, src.start, src.end)
        T.check("Source skips the header: the stream parses whole",
                (src.start, r3.total() == r3.bytes, r3.acct["junk"], r3.packs), (0x800, True, 0, 3))
    finally:
        src.close()
T.finish()
