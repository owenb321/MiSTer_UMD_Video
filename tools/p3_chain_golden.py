#!/usr/bin/env python3
"""Fixtures for bench/umd/p3_chain_tb.sv: a program stream (2048-byte packs) and what
the chain emu composes -- ps_stream_fifo -> ps_demux -> vidfeed_cdc (clk_sys -> clk_dec)
-> h264_top, with es_probe beside the demux and cdc_snap carrying the counters back --
must make of it (docs/h264_frontend.md S6).

Files (one word per line, $readmemh):
  <stem>.ps.hex     the pack bytes, as umd_reader would stream them
  <stem>.se.hex     the front end's expected SE words (tools/h264_top_golden.py's format)
  <stem>.meta.hex   h264_top_golden's meta over the video ES the packs carry
  <stem>.dmeta.hex  tools/psmf_golden.py's demux golden: byte counts per class and the
                    zlib CRC-32 of the first 64 KiB of video ES (es_probe's checks)
  <stem>.cmeta.hex  [0] pack bytes [1] audio track [2] subtitle track (0xFF none)

Sources:
  --x264 stream.264   the refs-free arm: the whole Annex-B stream packed one video PES
                      per pack (a PTS on every fourth), an audio pack (substream 0x00)
                      after every third video pack, a private_stream_2 index-style pack
                      up front and a padding pack at the end. The ES is complete, so the
                      end-of-title flush releases a whole last NAL unit: no error.
  --disc x.iso --clip N --packs K   the clip's first K packs verbatim. The ES they carry
                      ends wherever pack K ends -- normally inside a NAL unit -- so the
                      golden is built the way h264_top_golden --truncate builds one: the
                      whole NAL units before the cut are the expected words, and the
                      flush turns the cut unit into exactly one error (meta[9] = 1,
                      meta[11] = 1) unless the cut happens to fall on a boundary.

    p3_chain_golden.py --x264 .sim/x.264 --out bench/umd/fixtures/gen/p3chain_x264
    p3_chain_golden.py --disc x.iso --clip 1 --packs 200 --out .../p3chain_ak
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tests"))
import h264_top_golden as HG  # noqa: E402
import psmf_golden  # noqa: E402
import psmf_ref  # noqa: E402
import umd_demux_cases as DC  # noqa: E402
import umd_synth as S  # noqa: E402
from umd_fixture import write_bytes, write_words  # noqa: E402

SEC = 2048
NONE = 0xFF
PACK_HDR = 14
VID_PES_HDR = 6 + 3            # start code + id + length, then flags + header length
PTS_LEN = 5
PAD_MIN = 6                    # a padding PES needs its 6-byte head


def pack_es(es):
    """Synthetic packs carrying an Annex-B ES (docstring: the --x264 arm)."""
    packs = [DC.pack([S.pes(0xBF, b"\x01\xe0" + bytes(range(40)))])]   # skipped by length
    pos, i, pts = 0, 0, 90000
    while pos < len(es):
        if i % 3 == 2:
            packs.append(DC.pack([DC.aud(0x00, DC.au(0xA0, 1200), 0, pts)]))
        with_pts = (i % 4 == 0)
        room = SEC - PACK_HDR - VID_PES_HDR - (PTS_LEN if with_pts else 0)
        chunk = es[pos:pos + room]
        left = room - len(chunk)
        if 0 < left < PAD_MIN:            # the last chunk: leave room for the padding PES
            chunk = chunk[:len(chunk) - PAD_MIN]
        packs.append(DC.pack([DC.pes(0xE0, chunk, pts if with_pts else None)]))
        pos += len(chunk)
        i += 1
        pts += 3754
    packs.append(DC.pack([]))                                             # padding only
    return b"".join(packs)


def disc_packs(iso, clip, packs):
    src = psmf_ref.Source(iso, clip)
    src.limit(packs)
    try:
        return bytes(src.mm[src.start:src.end])
    finally:
        src.close()


def tracks(buf):
    """The lowest audio and subtitle substream ids the packs carry (emu picks the
    lowest DECLARED; for a clip's first packs the two agree on every surveyed disc)."""
    r = psmf_ref.parse(buf)
    auds = sorted(p.sub for p in r.packets if p.kind == "audio")
    subs = sorted(p.sub for p in r.packets if p.kind == "sub")
    return (auds[0] if auds else 0), (subs[0] - 0x80 if subs else None)


def build(buf, out, complete):
    aud, sub = tracks(buf)
    write_bytes(out + ".ps.hex", buf)
    write_bytes(out + ".hex", buf)                    # psmf_golden reads <stem>.hex
    g = psmf_golden.write(out, aud, sub)
    es = g["vid"]
    marks = [(off, pts) for (off, pts, _v) in g["vmk"]]       # what ps_demux marks (P5c)
    if complete:
        data, w, meta, _m = HG.build(es, marks=marks)
    else:
        data, w, meta, _m = HG.build(es, truncate=len(es), marks=marks)
    if data != es:
        raise SystemExit("p3_chain_golden: the model cut the ES (%d -> %d bytes): a refused stream is "
                         "not a chain fixture" % (len(es), len(data)))
    with open(out + ".se.hex", "w") as f:
        for kind, aux, val in w:
            f.write("%02x%02x%08x\n" % (kind, aux, val & 0xFFFFFFFF))
    write_words(out + ".meta.hex", meta)
    write_words(out + ".cmeta.hex", [len(buf), aud, NONE if sub is None else sub])
    for k in ("vid", "aud", "sub", "vmk", "amk", "smk"):       # the demux bench's copies: not needed here
        os.remove(out + "." + k + ".hex")
    os.remove(out + ".hex")
    print("%s: %d packs, video ES %d bytes (audio 0x%02x %d B, sub %s %d B), %d SE words, %d NAL units, "
          "%d slices, %d pictures, errors %d%s"
          % (out, len(buf) // SEC, len(es), aud, len(g["aud"]), "-" if sub is None else "0x%02x" % (0x80 + sub),
             len(g["sub"]), meta[1], meta[2], meta[3], meta[4], meta[9], " (partial)" if meta[11] else ""))
    return meta


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--x264", help="an Annex-B stream to pack")
    ap.add_argument("--disc")
    ap.add_argument("--clip", type=int, default=1)
    ap.add_argument("--packs", type=int, default=200)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if a.x264:
        buf = pack_es(open(a.x264, "rb").read())
        complete = True
    elif a.disc:
        buf = disc_packs(a.disc, a.clip, a.packs)
        if not any(buf):
            raise SystemExit("p3_chain_golden: the clip's packs are all zero (a damaged image)")
        complete = False
    else:
        ap.error("--x264 or --disc")
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    build(buf, a.out, complete)
    return 0


if __name__ == "__main__":
    sys.exit(main())
