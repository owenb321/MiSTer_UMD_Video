#!/usr/bin/env python3
"""PARAM.SFO (PSP "PSF" key/value file) -> dict.

Layout (little-endian; the common PSP homebrew description, confirmed on every local
disc by this tool -- see docs/umd_video_format.md "PARAM.SFO"):

    header, 20 bytes:  "\\0PSF", u32 version (0x00000101), u32 key_table_off,
                       u32 data_table_off, u32 entry_count
    entry_count x 16:  u16 key_off (into the key table), u16 fmt, u32 used_len,
                       u32 max_len, u32 data_off (into the data table)
    fmt: 0x0004 utf8 (not NUL-terminated), 0x0204 utf8 NUL-terminated, 0x0404 int32

Measured over the local discs: PARENTAL_LEVEL (int32) and TITLE (utf8z, max_len 128)
always, and on 11 of 33 discs a third key, PSP_SYSTEM_VER, sorted BETWEEN them -- so the
P2 reader must find TITLE by its key name, never by entry index. TITLE is UTF-8 and not
always ASCII ('Spiderman 3' ends in U+2122; Tom & Jerry's title is Japanese): the HUD
glyph ROM needs a fallback glyph for bytes >= 0x80. 128 bytes (the key's own max_len) is
what the title BRAM must hold, not the longest title seen (55 with its NUL).

    umd_sfo.py disc.iso | PARAM.SFO [--json]
"""
import argparse
import json
import struct
import sys

FMT_UTF8S = 0x0004
FMT_UTF8Z = 0x0204
FMT_INT32 = 0x0404


class SfoError(Exception):
    pass


def parse(raw):
    """-> {key: value}; values str or int (entries() keeps fmt and max_len)."""
    return {e["key"]: e["value"] for e in entries(raw)}


def entries(raw):
    if len(raw) < 20 or raw[:4] != b"\x00PSF":
        raise SfoError("no \\0PSF magic")
    ver, koff, doff, n = struct.unpack("<4I", raw[4:20])
    if 20 + 16 * n > koff or koff > doff or doff > len(raw):
        raise SfoError("table offsets out of order (entries %d, keys %d, data %d, "
                       "size %d)" % (n, koff, doff, len(raw)))
    out = []
    for i in range(n):
        ko, fmt, used, mx, do = struct.unpack("<HHIII", raw[20 + 16 * i:36 + 16 * i])
        kstart = koff + ko
        kend = raw.index(b"\x00", kstart)
        key = raw[kstart:kend].decode("ascii")
        if used > mx:
            raise SfoError("%s: used length %d > max %d" % (key, used, mx))
        d = raw[doff + do:doff + do + used]
        if len(d) != used:
            raise SfoError("%s: data runs past the end of the file" % key)
        if fmt == FMT_INT32:
            if used != 4:
                raise SfoError("%s: int32 with length %d" % (key, used))
            val = struct.unpack("<I", d)[0]
        elif fmt in (FMT_UTF8Z, FMT_UTF8S):
            val = d.split(b"\x00")[0].decode("utf-8", "replace")
        else:
            raise SfoError("%s: unknown format 0x%04x" % (key, fmt))
        out.append({"key": key, "fmt": fmt, "used": used, "max": mx, "value": val,
                    "raw": d})
    return out


def from_iso(iso):
    return entries(iso.read("/UMD_VIDEO/PARAM.SFO"))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("path", help="a disc image (.iso) or a PARAM.SFO")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    raw = open(a.path, "rb").read(4)
    if raw == b"\x00PSF":
        ents = entries(open(a.path, "rb").read())
    else:
        import umd_iso
        with umd_iso.UmdIso(a.path) as iso:
            ents = from_iso(iso)
    if a.json:
        json.dump([{k: v for k, v in e.items() if k != "raw"} for e in ents], sys.stdout,
                  indent=1)
        print()
    else:
        for e in ents:
            print("%-16s fmt %04x  %3d/%3d  %r" % (e["key"], e["fmt"], e["used"], e["max"],
                                                  e["value"]))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SfoError as e:
        sys.exit("umd_sfo: %s" % e)
