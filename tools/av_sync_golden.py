#!/usr/bin/env python3
"""Goldens for the audio path's gate (bench/umd/run_av_sync.sh): a program stream, what
every access unit's tag must be, and the PCM of every AU.

The bench runs ps_demux -> aud_ring -> at3p_top -> aud_out on the stream; it checks the
tags aud_ring hands to aud_out, every PCM pair played, and when each pair plays against
the bench's STC. The goldens here are independent of the RTL they score:
  * the tags come from the FORMAT's own pointer: a PES's PTS belongs to the AU at its
    FAP (the first AU header that starts in it, docs/umd_video_format.md); an AU no PTS
    names takes the previous tag + 3,840 (derived). The RTL instead frames the bytes as
    the decoder does and attaches the PTS of the last PES that began at or before an
    AU header's first byte -- two readings of one rule, from two directions;
  * the PCM is tools/at3p_fixed.py's (the decoder's bench proves the RTL bit-exact with
    it, run_at3p.sh), starting cold at the first AU, as the RTL does after a reset.

Streams (--stream):
  disc      the clip's first packs, as recorded (every PES starts an AU, FAP 0)
  split     the AUs re-packetised: the first PES opens with 5 bytes of a previous AU's
            tail (FAP 5: the demux's realign skips them); PES boundaries in mid-frame,
            one on an AU's 0xD0 byte (the PTS there names the NEXT AU), one PES in which
            no AU starts (no PTS, legal), and every third PTS left out (derived tags);
            a 256-byte video PES after each audio PES
  garbage   split, with 7 bytes (no 0x0F) after AU 3: the ring's framer and the
            decoder must slide over them identically (slides = 7) and the tags stay
            aligned with the PCM frames
  deadlock  split's audio first, all of it, then 8 KB of video: with a small ring the
            demux blocks on audio before any video passes, so the STC (anchored by the
            bench after video bytes) can only start if the gate yields audio from its
            stale end
  switch    (P6b7) the clip's own packs, 128 of them, carrying BOTH its audio tracks
            (substreams 0 and 1): the bench plays track 0, then switches to track 1 as
            player_ctl does (the chain reset, then the track and the demux's realign
            together). Where the new chain starts depends on how far the demux had read,
            so the golden gives track 1's tag of every AU (STEM.tags1) and its PCM decoded
            COLD from each AU k as the first, SWITCH_M AUs each (STEM.pcm1, k-major);
            STEM.meta1 "aus1 SWITCH_M"

    av_sync_golden.py --disc ISO [--clip N] --aus N --stream S --out STEM
Files: STEM.ps (hex a line), STEM.tags ("has derived pts" hex, an AU a line), STEM.pcm
("llll rrrr" a pair), STEM.meta ("ps_bytes aus slides first_pts").
Exit 0 written; 3 SKIP (no image); 5 an internal check failed.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "tests"))
import at3p_extract as X  # noqa: E402
import at3p_fixed as FX  # noqa: E402
import psmf_ref  # noqa: E402
import umd_demux_cases as DC  # noqa: E402
import umd_fixture as UF  # noqa: E402

AU_TICKS = 3840
SEC = 2048
GARBAGE = bytes([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77])
SWITCH_PACKS = 128             # ~34 AUs a track on Akira clip 1
SWITCH_M = 3                   # the new track's AUs scored after the switch


def fap_tags(aus, marks):
    """[(has, derived, pts)] per AU: the PTS of a PES whose FAP lands on the AU, else
    the previous + 3840. aus: es offsets; marks: (es_offset, pts, dts, fap) per PES."""
    named = {}
    for o, pts, _dts, fap in marks:
        if fap is not None and pts is not None:
            named.setdefault(o + fap, pts)
    out, last = [], None
    for o in aus:
        if o in named:
            last = named[o]
            out.append((1, 0, last))
        elif last is not None:
            last = (last + AU_TICKS) % (1 << 33)
            out.append((1, 1, last))
        else:
            out.append((0, 0, 0))
    return out


def au_bytes(prm, fr):
    return bytes([0x0F, 0xD0, prm >> 8, prm & 0xFF, 0, 0, 0, 0]) + bytes(fr)


def synth(sel, pts0, garbage_after=None, video="interleave"):
    """Re-packetise AUs sel = [(params, frame)] -> (ps bytes, au es offsets, marks,
    slides). The ES starts with 5 bytes of a fake AU tail (skipped by the realign)."""
    es = bytearray(b"\x99" * 5)
    starts = []
    for k, (prm, fr) in enumerate(sel):
        starts.append(len(es))
        es += au_bytes(prm, fr)
        if garbage_after is not None and k == garbage_after:
            es += GARBAGE
    # PES boundaries: the realign PES, then mid-frame cuts, one on AU 2's 0xD0 byte
    # (that PES's PTS names AU 3, the first AU starting in it: always kept), and a short
    # PES inside AU 4's frame (no AU starts in it)
    edge = starts[2] + 1
    cuts = {0, edge}
    if len(starts) > 4:
        cuts |= {starts[4] + 100, starts[4] + 160}
    p = 0
    while p < len(es):
        cuts.add(p)
        p += 777
    # nothing may cut between the edge and AU 3's header: that PES must hold AU 3's start
    cuts = sorted(c for c in cuts if c < len(es) and not edge < c <= starts[3])
    true_pts = {s: (pts0 + AU_TICKS * k) % (1 << 33) for k, s in enumerate(starts)}
    packets, marks = [], []
    for i, c in enumerate(cuts):
        e = cuts[i + 1] if i + 1 < len(cuts) else len(es)
        first = [s for s in starts if c <= s < e]
        fap = (first[0] - c) if first else 0xFFFF
        pts = true_pts[first[0]] if first else None
        if first and i % 3 == 2 and c != edge:
            pts = None                     # every third: no PTS (derived tags)
        marks.append((c, pts, None, fap if first else None))
        packets.append(DC.aud(0x00, bytes(es[c:e]), fap, pts=pts))
    vid = [DC.pes(0xE0, bytes([0x5A]) * 256, pts=pts0) for _ in packets]
    if video == "interleave":
        seq = [x for pair in zip(packets, vid) for x in pair]
    else:                                  # all audio, then 8 KB of video
        seq = packets + [DC.pes(0xE0, bytes([0x5A]) * 1024, pts=pts0) for _ in range(8)]
    # packs: as many whole packets as fit (every packet here is < 2 KB minus a header)
    ps, cur = bytearray(), []
    room0 = SEC - len(DC.S.pack_header(90000))
    for pk in seq:
        used = sum(len(x) for x in cur)
        if cur and used + len(pk) > room0 - 6 and used + len(pk) != room0:
            ps += DC.pack(cur)
            cur = []
        cur.append(pk)
    if cur:
        ps += DC.pack(cur)
    em = [m for m in marks if m[0] == edge]
    assert em and em[0][1] == true_pts[starts[3]] and em[0][3] == starts[3] - edge, \
        "the 0xD0-edge PES must carry AU 3's PTS"
    slides = len(GARBAGE) if garbage_after is not None else 0
    return bytes(ps), starts, marks, slides


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int, default=1)
    ap.add_argument("--aus", type=int, default=8)
    ap.add_argument("--stream", choices=("disc", "split", "garbage", "deadlock", "switch"),
                    required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if not os.path.exists(a.disc):
        print("SKIP: no image %s" % a.disc)
        return 3
    if a.stream == "switch":
        import umd_iso
        aus, _info, marks = X.extract(a.disc, a.clip, 0, SWITCH_PACKS)
        aus1, _i1, marks1 = X.extract(a.disc, a.clip, 1, SWITCH_PACKS)
        if len(aus) <= a.aus or len(aus1) < a.aus + SWITCH_M:
            print("the clip's first %d packs do not carry two tracks of enough AUs" % SWITCH_PACKS)
            return 5
        with umd_iso.UmdIso(a.disc) as iso:
            ps = UF.cut_packs(iso, a.clip, 0, SWITCH_PACKS)
        sel = [(prm, fr) for _o, prm, fr in aus[:a.aus]]
        tags = fap_tags([o for o, _p, _f in aus[:a.aus]], marks)
        slides = 0
        tags1 = fap_tags([o for o, _p, _f in aus1], marks1)
        if not all(t[0] for t in tags1):
            print("a track 1 AU has no tag")
            return 5
        n1 = len(aus1) - SWITCH_M + 1
        with open(a.out + ".tags1", "w") as f:
            f.write("".join("%x %x %09x\n" % t for t in tags1))
        with open(a.out + ".pcm1", "w") as f:
            for k in range(n1):
                fd = FX.FixedDecoder()
                for _o, _prm, fr in aus1[k:k + SWITCH_M]:
                    o = fd.decode(bytes(fr))
                    for i in range(2048):
                        f.write("%04x %04x\n" % (int(o[0][i]) & 0xFFFF, int(o[1][i]) & 0xFFFF))
        with open(a.out + ".meta1", "w") as f:
            f.write("%d %d\n" % (n1, SWITCH_M))
    elif a.stream == "disc":
        # enough packs for the AUs (the audio is ~1/10 of the stream)
        packs = 64
        while True:
            aus, _info, marks = X.extract(a.disc, a.clip, 0, packs)
            if len(aus) > a.aus:
                break
            packs *= 2
        import umd_iso
        with umd_iso.UmdIso(a.disc) as iso:
            ps = UF.cut_packs(iso, a.clip, 0, packs)
        sel = [(prm, fr) for _o, prm, fr in aus[:a.aus]]
        tags = fap_tags([o for o, _p, _f in aus[:a.aus]], marks)
        slides = 0
    else:
        aus, _info, marks = X.extract(a.disc, a.clip, 0, 256)
        if len(aus) < a.aus or not marks or marks[0][1] is None:
            print("the clip's first packs hold too few AUs")
            return 5
        sel = [(prm, fr) for _o, prm, fr in aus[:a.aus]]
        pts0 = marks[0][1]
        ps, starts, smarks, slides = synth(
            sel, pts0, garbage_after=3 if a.stream == "garbage" else None,
            video="after" if a.stream == "deadlock" else "interleave")
        tags = fap_tags(starts, smarks)
        # the synthetic stream must say what the disc says: re-walk it as the P1 tools do
        r = psmf_ref.parse(ps)
        es, m2 = psmf_ref.es(ps, r, "audio", 0)
        au2, _i2 = X.split_aus(es, m2)
        if a.stream != "garbage" and [bytes(f) for _o, _p, f in au2] != [bytes(f) for _p, f in sel]:
            print("the synthetic stream does not carry the AUs")
            return 5
    if not tags or not tags[0][0]:
        print("the first AU has no PTS")
        return 5
    # the PCM: the fixed model, cold from the first AU
    fd = FX.FixedDecoder()
    with open(a.out + ".pcm", "w") as f:
        for _prm, fr in sel:
            o = fd.decode(bytes(fr))
            for i in range(2048):
                f.write("%04x %04x\n" % (int(o[0][i]) & 0xFFFF, int(o[1][i]) & 0xFFFF))
    with open(a.out + ".ps", "w") as f:
        f.write("".join("%02x\n" % b for b in ps))
    with open(a.out + ".tags", "w") as f:
        f.write("".join("%x %x %09x\n" % t for t in tags))
    with open(a.out + ".meta", "w") as f:
        f.write("%d %d %d %d\n" % (len(ps), len(sel), slides, tags[0][2]))
    nder = sum(t[1] for t in tags)
    print("%s: %s clip %d, stream %s, %d bytes, %d AUs (%d derived tags), slides %d, "
          "first PTS %d" % (a.out, os.path.basename(a.disc), a.clip, a.stream, len(ps),
                            len(sel), nder, slides, tags[0][2]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
