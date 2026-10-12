#!/usr/bin/env python3
"""Demux goldens for the P2 ps_demux bench (bench/umd/run_ps_demux.sh), from
tools/psmf_ref.py -- never from the RTL.

Reads <stem>.hex (program-stream bytes, one per line: an umd_fixture.py pack cut or a
tools/umd_demux_cases.py stream) and writes, beside it:

    <stem>.vid.hex   the video elementary stream (every 0xE0 payload byte, in order)
    <stem>.vmk.hex   3 words per video PES that carried a PTS and a payload:
                     ES offset of its first payload byte, PTS[31:0], PTS[32]
    <stem>.aud.hex   audio substream --aud, FROM ITS FIRST ACCESS UNIT: the first PES
                     whose FAP lies inside its payload contributes payload[FAP:], every
                     later PES all of its payload (ps_demux arms its realign out of
                     reset; FAP counts from the byte after the 4-byte sub-header, 0 = the
                     first payload byte -- docs/umd_video_format.md)
    <stem>.amk.hex   3 words per audio frame start (the first forwarded byte of each PES):
                     ES offset, PTS[31:0], (has_pts << 1) | PTS[32]
    <stem>.sub.hex   subtitle substream 0x80 + --sub (after the 2-byte sub-header)
    <stem>.smk.hex   as .amk, per subtitle PES with a payload
    <stem>.dmeta.hex [0] input bytes [1] video bytes [2] video marks [3] audio bytes
                     [4] audio marks [5] subtitle bytes [6] subtitle marks [7] audio track
                     [8] subtitle track (0xFF = none selected) [9] packs holding a 0xE0 or
                     0xBD PES (pes_hdr_ok pulses) [10] audio PES of any track with a byte
                     after the id (aud_ss_seen) [11] of those, the selected track's
                     (aud_pes_hit) [12] zlib CRC-32 of the first BENCH_CRC_BYTES video ES
                     bytes (es_probe) [13] how many bytes that CRC covers [14] subtitle PES
                     of any track with a byte after the id (sub_ss_seen, P8) [15] the audio
                     ids those taps name, a mask [16] the subtitle ids (id - 0x80), a mask --
                     what a bare stream's tracks are learned from (docs/bare_streams.md)

    psmf_golden.py <stem> --aud 0 [--sub 0x1c]
    psmf_golden.py --crc disc.iso      the value the P2 HUD's CRC must show: zlib CRC-32
                                       of the first 1 MiB of the main clip's video ES
    psmf_golden.py --chain STEM        for bench/umd/p2_chain_tb.sv: the stream bytes of an
                                       umd_fixture.py --nav fixture (its .sseq sectors, in
                                       order) -> STEM_chain.hex + goldens, with the tracks
                                       the P1 parsers say the reader will declare (the
                                       lowest audio / subtitle id in STEM.exp.hex)
    psmf_golden.py --disc disc.iso --prefix dmx_d1 [--dir DIR]
        cuts the main clip's windows from an image and writes each with its goldens:
        <prefix>_head (the first HEAD_PACKS packs, the lowest declared audio track) and,
        when the clip has a subtitle EP map, <prefix>_sub (from SUB_LEAD packs before
        its first subtitle unit, that subtitle track selected). Prints one stem per line.
"""
import argparse
import os
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import psmf_ref  # noqa: E402
from umd_fixture import read_bytes, write_bytes, write_words  # noqa: E402

SEC = 2048
NONE = 0xFF
BENCH_CRC_BYTES = 65536        # es_probe's CRC_BYTES in bench/umd/ps_demux_tb.sv
HW_CRC_BYTES = 1 << 20         # es_probe's CRC_BYTES in umd/emu.sv


class DamagedWindow(Exception):
    """The window is all zero bytes: a damaged image (Desperado's clips are zero-filled
    while its tables are intact -- docs/umd_video_format.md). Reported as a SKIP by the
    runner, by what the data IS, never by a disc's name."""


def marks_words(marks):
    out = []
    for off, pts, has in marks:
        p = pts or 0
        out += [off, p & 0xFFFFFFFF, (int(has) << 1) | (p >> 32)]
    return out


def golden(buf, aud, sub):
    r = psmf_ref.parse(buf)
    if r.unaligned_packs or r.acct["junk"]:
        raise psmf_ref.PsError("stream is not pack-aligned (%d unaligned, %d junk bytes)"
                               % (r.unaligned_packs, r.acct["junk"]))
    vid, vm = psmf_ref.es(buf, r, "video")
    vmk = [(off, pts, True) for (off, pts, dts, fap), p in
           zip(vm, [q for q in r.packets if q.kind == "video"])
           if pts is not None and p.payload_len > 0]

    aes, amk, started = bytearray(), [], False
    sub_bytes, smk = bytearray(), []
    packs_with_pes, n_seen, n_hit = set(), 0, 0
    n_sseen, amask, smask = 0, 0, 0
    for p in r.packets:
        if p.sid in (0xE0, 0xBD):
            packs_with_pes.add(p.offset // SEC)
        if p.kind == "audio" and len(p.subhdr) + p.payload_len >= 2:
            n_seen += 1
            n_hit += p.sub == aud
            amask |= 1 << p.sub
        if p.kind == "sub" and len(p.subhdr) + p.payload_len >= 2:
            n_sseen += 1
            smask |= 1 << (p.sub - 0x80)
        if p.kind == "audio" and p.sub == aud and len(p.subhdr) == 4 and p.payload_len:
            data = buf[p.payload_off:p.payload_off + p.payload_len]
            if not started:
                if p.fap >= p.payload_len:
                    continue                         # no access unit starts here
                data = data[p.fap:]
                started = True
            amk.append((len(aes), p.pts, p.pts is not None))
            aes += data
        if (sub is not None and p.kind == "sub" and p.sub == 0x80 + sub
                and len(p.subhdr) == 2 and p.payload_len):
            smk.append((len(sub_bytes), p.pts, p.pts is not None))
            sub_bytes += buf[p.payload_off:p.payload_off + p.payload_len]
    return {"vid": vid, "vmk": vmk, "aud": bytes(aes), "amk": amk, "sub": bytes(sub_bytes),
            "smk": smk, "packs": len(packs_with_pes), "seen": n_seen, "hit": n_hit,
            "sseen": n_sseen, "amask": amask, "smask": smask}


def write(stem, aud, sub=None):
    buf = read_bytes(stem + ".hex")
    g = golden(buf, aud, sub)
    for k in ("vid", "aud", "sub"):
        write_bytes(stem + "." + k + ".hex", g[k])
    for k in ("vmk", "amk", "smk"):
        write_words(stem + "." + k + ".hex", marks_words(g[k]))
    write_words(stem + ".dmeta.hex", [len(buf), len(g["vid"]), len(g["vmk"]), len(g["aud"]),
                                      len(g["amk"]), len(g["sub"]), len(g["smk"]), aud,
                                      NONE if sub is None else sub, g["packs"], g["seen"],
                                      g["hit"], zlib.crc32(g["vid"][:BENCH_CRC_BYTES]),
                                      min(len(g["vid"]), BENCH_CRC_BYTES), g["sseen"],
                                      g["amask"], g["smask"]])
    return g


HEAD_PACKS, SUB_LEAD, SUB_PACKS = 120, 16, 120


def hw_crc(iso_path):
    """(CRC-32 of the first HW_CRC_BYTES of the main clip's video ES, clip number)."""
    import umd_iso
    import umd_playlist
    with umd_iso.UmdIso(iso_path) as iso:
        pl = umd_playlist.from_iso(iso)
        clip = int(pl["playlists"][umd_playlist.main_playlist(pl)]["items"][0]["clip_name"])
        e = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip)
        vid, n = bytearray(), 0
        while len(vid) < HW_CRC_BYTES and n < e.nsec:
            k = min(512, e.nsec - n)
            buf = iso.read_sectors(e.lba + n, k)
            r = psmf_ref.parse(buf)
            vid += psmf_ref.es(buf, r, "video")[0]
            n += k
        return zlib.crc32(bytes(vid[:HW_CRC_BYTES])), clip


def disc_windows(iso_path, prefix, out_dir):
    """Cut + golden the main clip's windows (docstring); returns the stems written."""
    import umd_clpi
    import umd_fixture
    import umd_iso
    import umd_playlist
    stems = []
    with umd_iso.UmdIso(iso_path) as iso:
        pl = umd_playlist.from_iso(iso)
        clip = int(pl["playlists"][umd_playlist.main_playlist(pl)]["items"][0]["clip_name"])
        c = umd_clpi.from_iso(iso, clip)
        nsec = iso.extent("/UMD_VIDEO/STREAM/%05d.MPS" % clip).nsec
        auds = sorted(s["substream_id"] for s in c["streams"] if s["kind"] == "audio")
        aud = auds[0] if auds else 0
        wins = [("head", 0, min(HEAD_PACKS, nsec), None)]
        smaps = [m for m in c["ep_maps"] if m["kind"] == "subtitle" and m["entries"]]
        if smaps:
            m = smaps[0]
            first = max(0, m["entries"][0][2] - SUB_LEAD)
            wins.append(("sub", first, min(first + SUB_PACKS, nsec), m["substream_id"] - 0x80))
        for tag, a0, a1, sub in wins:
            stem = os.path.join(out_dir, "%s_%s" % (prefix, tag))
            data = umd_fixture.cut_packs(iso, clip, a0, a1)
            if not any(data):
                raise DamagedWindow("clip %05d packs %d..%d are all zero" % (clip, a0, a1))
            write_bytes(stem + ".hex", data)
            write(stem, aud, sub)
            stems.append("%s_%s" % (prefix, tag))
    return stems


def chain(stem):
    from umd_fixture import read_words, EXP_WORDS
    lbas = read_words(stem + ".lba.hex")
    data = read_bytes(stem + ".hex")
    at = {l: i for i, l in enumerate(lbas)}
    stream = b"".join(data[at[l] * SEC:(at[l] + 1) * SEC] for l in read_words(stem + ".sseq.hex"))
    if not any(stream):
        raise DamagedWindow("the fixture's stream packs are all zero")
    exp = dict(zip(EXP_WORDS, read_words(stem + ".exp.hex")))
    low = lambda m: (m & -m).bit_length() - 1 if m else None
    aud = low(exp["aud_present"]) or 0
    sub = low(exp["sub_present"])
    write_bytes(stem + "_chain.hex", stream)
    return write(stem + "_chain", aud, sub)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("stem", nargs="?")
    ap.add_argument("--aud", type=lambda s: int(s, 0), default=0)
    ap.add_argument("--sub", type=lambda s: int(s, 0))
    ap.add_argument("--disc")
    ap.add_argument("--crc")
    ap.add_argument("--chain")
    ap.add_argument("--prefix", default="dmx_disc")
    ap.add_argument("--dir", default=os.path.join(os.path.dirname(HERE), "bench", "umd",
                                                  "fixtures", "gen"))
    a = ap.parse_args(argv)
    if a.chain:
        try:
            chain(a.chain)
        except DamagedWindow as e:
            print("DAMAGED %s" % e)
            return 3
        return 0
    if a.crc:
        c, clip = hw_crc(a.crc)
        print("%08X  (clip %05d, first %d video ES bytes)" % (c, clip, HW_CRC_BYTES))
        return 0
    if a.disc:
        try:
            print("\n".join(disc_windows(a.disc, a.prefix, a.dir)))
        except DamagedWindow as e:
            print("DAMAGED %s" % e)
            return 3
        return 0
    g = write(a.stem, a.aud, a.sub)
    print("%s: video %d B / %d marks, audio 0x%02x %d B / %d marks, subtitle %s %d B / %d "
          "marks" % (a.stem, len(g["vid"]), len(g["vmk"]), a.aud, len(g["aud"]),
                     len(g["amk"]), "-" if a.sub is None else "0x%02x" % (0x80 + a.sub),
                     len(g["sub"]), len(g["smk"])))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except psmf_ref.PsError as e:
        sys.exit("psmf_golden: %s" % e)
