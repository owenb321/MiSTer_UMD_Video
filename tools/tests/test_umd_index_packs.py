#!/usr/bin/env python3
"""umd_index_packs.parse() on synthetic 0xBF payloads built from the measured layout
(docs/umd_video_format.md "Index packs"), and the rejections. verify() is exercised on
real discs by tools/tests/corpus_umd.sh, where it has caught real mismatches (the u16
size wrap) -- i.e. it is proven able to fail."""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_index_packs as X  # noqa: E402

T = S.Score("test_umd_index_packs")


def payload(refs, ents):
    body = struct.pack(">H", len(ents)) + b"".join(struct.pack(">BBH", *e) for e in ents)
    return (b"\x01\xe0" + struct.pack(">4H", *refs) + bytes(4) + struct.pack(">H", len(body))
            + body + bytes(4))


ents = [(3, 0x80, 26492), (4, 0x80, 7285), (5, 0x80, 94047 & 0xFFFF), (6, 0, 4756)]
d = X.parse(payload((13, 16, 18, 20), ents))
T.check("ref_end", d["refs"], [13, 16, 18, 20])
T.check("entries", d["entries"], ents)
T.check("wrapped size is stored mod 65536", d["entries"][2][2], 28511)
T.raises("not an index payload", lambda: X.parse(b"\x01\xc0" + bytes(30)), X.IndexError_,
         "not an index")
bad = bytearray(payload((1, 2, 3, 4), ents))
struct.pack_into(">H", bad, 16, 5)
T.raises("count vs length", lambda: X.parse(bytes(bad)), X.IndexError_, "mismatch")
T.raises("truncated", lambda: X.parse(payload((1, 2, 3, 4), ents)[:-2]), X.IndexError_,
         "mismatch")
T.finish()
