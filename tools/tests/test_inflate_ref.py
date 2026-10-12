#!/usr/bin/env python3
"""tools/inflate_ref.py (the puff port that counts P7's DEFLATE coverage) against zlib:
random data at every level and strategy, window sizes down to 512 bytes, a preset-free
raw stream, the coverage counters on streams built to reach them, and zlib's verdict on
defects. zlib is the oracle; the model is only trusted where it agrees
(docs/png_decode.md §5)."""
import os
import random
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import inflate_ref as R  # noqa: E402

T = S.Score("test_inflate_ref")
rng = random.Random(7)


def data(kind, n):
    if kind == 0:
        return bytes(rng.getrandbits(8) for _ in range(n))
    if kind == 1:
        return bytes(rng.choice(b"abcab ") for _ in range(n))
    if kind == 2:
        blk = bytes(rng.getrandbits(8) for _ in range(20000))
        return (blk + b"xy" * 1500) * 3                   # repeats 23 KB apart
    return bytes(i % 251 for i in range(n))


print("[agrees with zlib]")
bad = 0
cases = 0
for kind in range(4):
    for n in (0, 1, 300, 40000):
        d = data(kind, n)
        for lvl, strat, wb in ((0, 0, 15), (1, 0, 15), (6, 0, 15), (9, zlib.Z_FIXED, 15),
                               (9, zlib.Z_RLE, 15), (9, zlib.Z_HUFFMAN_ONLY, 15), (9, 0, 9)):
            co = zlib.compressobj(lvl, zlib.DEFLATED, wb, 9, strat)
            z = co.compress(d) + co.flush()
            out, inf = R.inflate_zlib(z)
            cases += 1
            if out != d or inf.pos != len(z):
                bad += 1
T.check("%d streams: bytes and stream end identical" % cases, bad, 0)
d = data(1, 5000)
co = zlib.compressobj(6, zlib.DEFLATED, -15)
raw = co.compress(d) + co.flush()
T.check("raw DEFLATE (no zlib wrapper)", R.Inflater(raw).run(), d)

print("[coverage counts what changes the output]")
d = data(2, 0)
_, inf = R.inflate_zlib(zlib.compress(d, 9))
T.check("a 16 KB window would alias: counted", inf.cov["dist_gt16k_differs"] > 0, True)
T.check("max distance past 16 KB", inf.cov["max_dist"] > 16384, True)
d = bytes(5000)
_, inf = R.inflate_zlib(zlib.compress(d, 9))
T.check("zeros: dist-1 overlap, never a far-aliasing byte",
        (inf.cov["overlap_dist1"] > 0, inf.cov["dist_gt16k_differs"]), (True, 0))

print("[zlib's verdicts]")
good = zlib.compress(b"hello hello hello")
T.raises("header check", lambda: R.inflate_zlib(bytes([good[0], good[1] ^ 1]) + good[2:]),
         R.InflateError, "incorrect header check")
T.raises("Adler", lambda: R.inflate_zlib(good[:-1] + bytes([good[-1] ^ 1])),
         R.InflateError, "incorrect data check")
T.raises("block type 3", lambda: R.Inflater(bytes([0x07, 0, 0])).run(), R.InflateError,
         "invalid block type")
T.raises("stored NLEN", lambda: R.Inflater(bytes([0x01, 3, 0, 0, 0, 1, 2, 3])).run(), R.InflateError,
         "invalid stored block lengths")
# fixed block: literal 'A' (8 bits 01110001), then length 3 (7 bits 0000001), distance
# code 1 (5 bits 00001) = distance 2 with one byte out: too far back
bits = [1, 1, 0] + [0, 1, 1, 1, 0, 0, 0, 1] + [0, 0, 0, 0, 0, 0, 1] + [0, 0, 0, 0, 1]
b = bytearray()
for i in range(0, len(bits), 8):
    v = 0
    for k, x in enumerate(bits[i:i + 8]):
        v |= x << k
    b.append(v)
T.raises("distance too far back", lambda: R.Inflater(bytes(b) + bytes(2)).run(), R.InflateError,
         "invalid distance too far back")
T.raises("the data runs out", lambda: R.inflate_zlib(good[:-6]), R.InflateError, "unexpected end")
T.finish()
