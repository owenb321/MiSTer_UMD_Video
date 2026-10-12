#!/usr/bin/env python3
"""Transcribe the ATRAC3plus tables from ffmpeg's source into tools/at3p_tables.py.

ATRAC3plus has no public specification: its Huffman codebooks, weight / shape tables,
quantiser steps, noise table and IPQF prototype exist only as the data of ffmpeg's
reverse-engineered decoder (Maxim Poliakovski, 2010-2013). They are FORMAT FACTS -- a
decoder cannot be built without the exact values -- so they are transcribed, with
credit (NOTICE, site/content/about/acknowledgements.md), under the LGPL-2.1-or-later
-> GPL-3.0-or-later conversion the LGPL permits (LGPL-2.1 section 3). The decoding
LOGIC of tools/at3p_ref.py and umd/at3p/ is our own, written from reading ffmpeg.

Pinned to one release, the same one as the oracle binary:

    ${UMD_REFS_DIR:-~/umd-refs}/ffmpeg-9.0.1/libavcodec/
        atrac3plus_data.h   codebooks, xlats, weights, shapes, spectra_tabs
        atrac3plusdsp.c     qu_to_spec_pos, sf_tab, mant_tab, noise_tab, pwc_levs,
                            subband_to_qu, subband_to_powgrp, ipqf_coeffs1/2

    gen_at3p_tables.py [--src DIR] [-o tools/at3p_tables.py]
    gen_at3p_tables.py --check        # regenerate and compare with the committed file

Never edit tools/at3p_tables.py by hand. Tables computed at init time by ffmpeg
(sine table, Hann window, amplitude scale factors, the sine windows, the gain tables)
are not transcribed: they are formulas, and tools/at3p_ref.py evaluates them itself.
"""
import argparse
import os
import re
import sys

FFMPEG_TAG = "n9.0.1"
DEFAULT_SRC = os.path.join(os.environ.get("UMD_REFS_DIR", os.path.expanduser("~/umd-refs")),
                           "ffmpeg-9.0.1", "libavcodec")
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "at3p_tables.py")

# (file, C name, python name, kind): kind 'int' or 'float'; the nesting of the braces is
# kept (lists of lists), so a ragged table (spectra_cbs's { -47 } rows) survives.
TABLES = [
    ("atrac3plus_data.h", "atrac3p_wl_cbs", "WL_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_ct_cbs", "CT_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_wl_ct_xlats", "WL_CT_XLATS", "int"),
    ("atrac3plus_data.h", "atrac3p_sf_cbs", "SF_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_sf_xlats", "SF_XLATS", "int"),
    ("atrac3plus_data.h", "atrac3p_wl_weights", "WL_WEIGHTS", "int"),
    ("atrac3plus_data.h", "atrac3p_sf_weights", "SF_WEIGHTS", "int"),
    ("atrac3plus_data.h", "atrac3p_qu_num_to_seg", "QU_NUM_TO_SEG", "int"),
    ("atrac3plus_data.h", "atrac3p_qu_to_subband", "QU_TO_SUBBAND", "int"),
    ("atrac3plus_data.h", "atrac3p_subband_to_num_powgrps", "SUBBAND_TO_NUM_POWGRPS", "int"),
    ("atrac3plus_data.h", "atrac3p_wl_shapes", "WL_SHAPES", "int"),
    ("atrac3plus_data.h", "atrac3p_sf_shapes", "SF_SHAPES", "int"),
    ("atrac3plus_data.h", "atrac3p_ct_restricted_to_full", "CT_RESTRICTED_TO_FULL", "int"),
    ("atrac3plus_data.h", "atrac3p_spectra_cbs", "SPECTRA_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_spectra_xlats", "SPECTRA_XLATS", "int"),
    ("atrac3plus_data.h", "atrac3p_spectra_tabs", "SPECTRA_TABS", "int"),
    ("atrac3plus_data.h", "atrac3p_gain_cbs", "GAIN_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_gain_xlats", "GAIN_XLATS", "int"),
    ("atrac3plus_data.h", "atrac3p_tone_cbs", "TONE_CBS", "int"),
    ("atrac3plus_data.h", "atrac3p_tone_xlats", "TONE_XLATS", "int"),
    ("atrac3plusdsp.c", "ff_atrac3p_qu_to_spec_pos", "QU_TO_SPEC_POS", "int"),
    ("atrac3plusdsp.c", "ff_atrac3p_sf_tab", "SF_TAB", "float"),
    ("atrac3plusdsp.c", "ff_atrac3p_mant_tab", "MANT_TAB", "float"),
    ("atrac3plusdsp.c", "subband_to_powgrp", "SUBBAND_TO_POWGRP", "int"),
    ("atrac3plusdsp.c", "noise_tab", "NOISE_TAB", "float"),
    ("atrac3plusdsp.c", "pwc_levs", "PWC_LEVS", "float"),
    ("atrac3plusdsp.c", "subband_to_qu", "SUBBAND_TO_QU", "int"),
    ("atrac3plusdsp.c", "ipqf_coeffs1", "IPQF_COEFFS1", "float"),
    ("atrac3plusdsp.c", "ipqf_coeffs2", "IPQF_COEFFS2", "float"),
]

# Expected shapes: a wrong parse fails here, not as a subtly wrong decode.
SHAPES = {
    "WL_CBS": (4, 12), "CT_CBS": (4, 12), "SF_CBS": (8, 12), "WL_WEIGHTS": (6, 32),
    "SF_WEIGHTS": (2, 32), "QU_NUM_TO_SEG": (32,), "QU_TO_SUBBAND": (32,),
    "SUBBAND_TO_NUM_POWGRPS": (16,), "WL_SHAPES": (8, 16, 9), "SF_SHAPES": (64, 9),
    "CT_RESTRICTED_TO_FULL": (2, 7, 4), "SPECTRA_TABS": (112, 4), "GAIN_CBS": (11, 12),
    "TONE_CBS": (7, 12), "QU_TO_SPEC_POS": (33,), "SF_TAB": (64,), "MANT_TAB": (8,),
    "SUBBAND_TO_POWGRP": (16,), "NOISE_TAB": (1024,), "PWC_LEVS": (16,),
    "SUBBAND_TO_QU": (17,), "IPQF_COEFFS1": (12, 16), "IPQF_COEFFS2": (12, 16),
}


def strip_comments(s):
    s = re.sub(r"/\*.*?\*/", " ", s, flags=re.S)
    return re.sub(r"//[^\n]*", " ", s)


def parse_braces(body, kind):
    """'{ {1, 2}, {3} }' -> [[1, 2], [3]] (the outer braces included in body)."""
    pos = 0
    tok = re.compile(r"\s*(\{|\}|,|0[xX][0-9a-fA-F]+|[-+]?[0-9.]+(?:[eE][-+]?[0-9]+)?[fF]?)")

    def value(t):
        if kind == "float":
            return float(t.rstrip("fF"))
        return int(t, 0)

    def group():
        nonlocal pos
        out = []
        while True:
            m = tok.match(body, pos)
            if not m:
                raise ValueError("unparsable table text at %r" % body[pos:pos + 40])
            t = m.group(1)
            pos = m.end()
            if t == "{":
                out.append(group())
            elif t == "}":
                return out
            elif t == ",":
                continue
            else:
                out.append(value(t))

    m = tok.match(body, pos)
    if not m or m.group(1) != "{":
        raise ValueError("table does not start with '{'")
    pos = m.end()
    return group()


def extract(src_text, cname, kind):
    m = re.search(r"\b" + re.escape(cname) + r"\s*(\[[^=]*\])\s*=\s*", src_text)
    if not m:
        raise ValueError("table %s not found" % cname)
    start = m.end()
    depth, i = 0, start
    while True:
        c = src_text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    return parse_braces(src_text[start:i + 1], kind)


def shape(v):
    if not isinstance(v, list):
        return ()
    inner = {shape(x) for x in v}
    if len(inner) != 1:
        return (len(v), None)
    return (len(v),) + inner.pop()


def generate(src_dir):
    texts = {}
    out = {}
    for fname, cname, pname, kind in TABLES:
        if fname not in texts:
            with open(os.path.join(src_dir, fname)) as f:
                texts[fname] = strip_comments(f.read())
        out[pname] = extract(texts[fname], cname, kind)
        want = SHAPES.get(pname)
        if want is not None and shape(out[pname]) != want:
            raise ValueError("%s: shape %s, expected %s" % (pname, shape(out[pname]), want))
    return out


def fmt(v, kind, indent=4):
    if not isinstance(v, list):
        return repr(v)
    if all(not isinstance(x, list) for x in v):
        items = [repr(x) for x in v]
        lines, cur = [], ""
        for it in items:
            if len(cur) + len(it) + 2 > 88 - indent:
                lines.append(cur.rstrip())
                cur = ""
            cur += it + ", "
        lines.append(cur.rstrip())
        pad = " " * indent
        return "[\n" + "\n".join(pad + ln for ln in lines) + "\n" + " " * (indent - 4) + "]"
    pad = " " * indent
    return "[\n" + "".join(pad + fmt(x, kind, indent + 4) + ",\n" for x in v) + \
        " " * (indent - 4) + "]"


def render(tables):
    kinds = {p: k for _, _, p, k in TABLES}
    hdr = '''"""ATRAC3plus tables, transcribed from ffmpeg %s (libavcodec/atrac3plus_data.h,
atrac3plusdsp.c; Maxim Poliakovski, LGPL-2.1-or-later, carried here under GPL-3.0-or-later
as that licence permits) by tools/gen_at3p_tables.py -- never edited by hand.
Run `tools/gen_at3p_tables.py --check` after touching the generator.

Codebooks (*_CBS) are canonical-Huffman descriptors: entry b-1 = the number of codes of
length b (1..12), assigned in order to the symbols of the matching *_XLATS slice.
SPECTRA_CBS rows whose first entry is negative reuse the codebook -row.
SPECTRA_TABS[i] = (group_size, num_coeffs, bits, is_signed).
"""
''' % FFMPEG_TAG
    body = []
    for _, _, pname, _ in TABLES:
        body.append("%s = %s\n" % (pname, fmt(tables[pname], kinds[pname])))
    return hdr + "\n" + "\n".join(body)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--src", default=DEFAULT_SRC)
    ap.add_argument("-o", "--out", default=OUT)
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if not os.path.isdir(a.src):
        print("gen_at3p_tables: SKIP (no ffmpeg source at %s)" % a.src)
        return 2
    text = render(generate(a.src))
    if a.check:
        with open(a.out) as f:
            if f.read() != text:
                print("gen_at3p_tables: FAIL %s differs from a fresh transcription" % a.out)
                return 1
        print("gen_at3p_tables: PASS (%s matches ffmpeg %s)" % (a.out, FFMPEG_TAG))
        return 0
    with open(a.out, "w") as f:
        f.write(text)
    print("gen_at3p_tables: wrote %s" % a.out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
