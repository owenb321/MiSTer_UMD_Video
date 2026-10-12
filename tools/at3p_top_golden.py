#!/usr/bin/env python3
"""Goldens for the whole decoder's bench (bench/umd/run_at3p.sh): a window of a disc's
audio as the demux delivers it, the emulator's PCM of it, and the engine buffers'
checksums after every vector op (tools/at3p_isa.py Machine.checksums). The emulator's
PCM is first scored against tools/at3p_fixed.py (the independent path) and its parse
against tools/at3p_ref.py: no golden is written from an emulator that disagrees.

    at3p_top_golden.py --disc IMAGE.iso [--clip N] [--track T] [--skip N] [--aus N] --out STEM
                       [--mute K]      # set AU K's mute flag (the path no disc takes)
                       [--refuse K]    # make AU K a mono unit (refused: 2,048 silent pairs)

Files: STEM.bytes (hex a line), STEM.pcm ("llll rrrr" a pair), STEM.vops ("op x t p r" hex,
a line a vector op), STEM.meta ("bytes pairs vops frames refusals").
Exit 0 written; 3 SKIP (no image); 5 the emulator disagrees with a model.
"""
import argparse
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_isa as I  # noqa: E402
import at3p_emu as E  # noqa: E402
import at3p_fixed as F  # noqa: E402
import at3p_seq_golden as SG  # noqa: E402


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--track", type=int, default=0)
    ap.add_argument("--packs", type=int)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--aus", type=int, default=4)
    ap.add_argument("--mute", type=int, action="append", default=[])
    ap.add_argument("--refuse", type=int, action="append", default=[])
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if not os.path.exists(a.disc):
        print("SKIP: no image %s" % a.disc)
        return 3
    clip, aus, _info = R.disc_aus(a.disc, a.clip, a.track, a.packs)
    sel = list(aus[a.skip:a.skip + a.aus])
    for k in a.mute:
        o, p, fr = sel[k]
        fr = bytearray(fr)
        fr[1] |= 0x80
        sel[k] = (o, p, bytes(fr))
    for k in a.refuse:
        o, p, fr = sel[k]
        fr = bytearray(fr)
        fr[0] &= 0x9F
        sel[k] = (o, p, bytes(fr))
    # the emulator against the fixed model: PCM, frame by frame (refused frames: silence)
    words, labels, _ = I.load_program()
    m = I.Machine(words, labels)
    vops = []
    m.vop_hook = lambda mach, k: vops.append((k,) + mach.checksums())
    frames = []
    m.mark_hook = lambda mach, mk: frames.append(mk) if mk == E.C["M_FRAME"] else None
    fd = F.FixedDecoder()
    data = SG.au_bytes(sel)
    pcm = []
    for k, (_o, prm, fr) in enumerate(sel):
        n0 = len(m.pcm)
        m.feed(bytes([0x0F, 0xD0, prm >> 8, prm & 0xFF, 0, 0, 0, 0]) + bytes(fr))
        m.run()
        if len(m.pcm) != n0 + 1:
            print("the emulator produced %d frames for AU %d" % (len(m.pcm) - n0, k))
            return 5
        got = np.array(m.pcm[-1])
        if k in a.refuse:
            ref = np.zeros((2, 2048), dtype=np.int64)
            if not np.array_equal(got, ref):
                print("AU %d: a refused frame is not silence" % k)
                return 5
            try:                                   # the model refuses it too (its state as ffmpeg's)
                fd.decode(fr)
                print("AU %d: the model decodes a frame the emulator refused" % k)
                return 5
            except R.At3pError:
                pass
        else:
            try:
                ref = fd.decode(fr)
            except R.At3pError as e:
                print("AU %d: the model refuses (%s)" % (k, e))
                return 5
            if not np.array_equal(got, ref):
                print("AU %d: the emulator's PCM differs from the fixed model" % k)
                return 5
        pcm.append(got)
    with open(a.out + ".bytes", "w") as f:
        f.write("".join("%02x\n" % b for b in data))
    with open(a.out + ".pcm", "w") as f:
        for fr in pcm:
            for i in range(2048):
                f.write("%04x %04x\n" % (int(fr[0][i]) & 0xFFFF, int(fr[1][i]) & 0xFFFF))
    with open(a.out + ".vops", "w") as f:
        f.write("".join("%x %08x %08x %08x %08x\n" % v for v in vops))
    with open(a.out + ".meta", "w") as f:
        f.write("%d %d %d %d %d\n" % (len(data), 2048 * len(pcm), len(vops), len(frames),
                                      sum(m.errors.values())))
    print("%s: %s clip %d AUs %d..%d, %d bytes, %d vector ops, %d frames, refusals %s; "
          "the emulator's PCM matches the fixed model" % (
              a.out, os.path.basename(a.disc), clip, a.skip, a.skip + len(sel), len(data),
              len(vops), len(frames), m.errors or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
