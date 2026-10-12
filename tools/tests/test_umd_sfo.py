#!/usr/bin/env python3
"""umd_sfo on synthetic PSF files built from the layout in its docstring's source
(the PSP homebrew PSF description), not from the parser: key lookup by NAME with a
third key in between, UTF-8 multi-byte titles, int32, and the rejections."""
import os
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import umd_sfo  # noqa: E402

T = S.Score("test_umd_sfo")


def psf(items):
    """items: [(key, fmt, value_bytes, max_len)] in file order."""
    keys = b""
    data = b""
    ents = b""
    for k, fmt, v, mx in items:
        ents += struct.pack("<HHIII", len(keys), fmt, len(v), mx, len(data))
        keys += k.encode() + b"\0"
        data += v.ljust(mx, b"\0")
    keys = keys.ljust((len(keys) + 3) & ~3, b"\0")
    koff = 20 + len(ents)
    doff = koff + len(keys)
    return b"\0PSF" + struct.pack("<4I", 0x101, koff, doff, len(items)) + ents + keys + data


title = "Spiderman 3™".encode("utf-8")
raw = psf([("PARENTAL_LEVEL", 0x0404, struct.pack("<I", 5), 4),
           ("PSP_SYSTEM_VER", 0x0204, b"2.50\0", 8),
           ("TITLE", 0x0204, title + b"\0", 128)])
d = umd_sfo.parse(raw)
T.check("title by key, 3rd entry", d["TITLE"], "Spiderman 3™")
T.check("int32", d["PARENTAL_LEVEL"], 5)
T.check("sysver", d["PSP_SYSTEM_VER"], "2.50")
e = {x["key"]: x for x in umd_sfo.entries(raw)}
T.check("title max_len", e["TITLE"]["max"], 128)
T.check("title used (utf-8 bytes + NUL)", e["TITLE"]["used"], len(title) + 1)

print("[rejections]")
T.raises("magic", lambda: umd_sfo.parse(b"XPSF" + raw[4:]), umd_sfo.SfoError, "magic")
bad = bytearray(raw)
struct.pack_into("<I", bad, 20 + 16 * 2 + 4, 200)          # TITLE used > max
T.raises("used > max", lambda: umd_sfo.parse(bytes(bad)), umd_sfo.SfoError, "> max")
bad = bytearray(raw)
struct.pack_into("<H", bad, 20 + 2, 0x9999)
T.raises("unknown fmt", lambda: umd_sfo.parse(bytes(bad)), umd_sfo.SfoError, "unknown format")
T.raises("truncated", lambda: umd_sfo.parse(raw[:len(raw) - 125]), umd_sfo.SfoError,
         "past the end")
T.finish()
