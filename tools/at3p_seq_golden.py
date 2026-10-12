#!/usr/bin/env python3
"""Goldens for the sequencer bench (bench/umd/run_at3p_seq.sh): a window of a disc's
audio as the byte stream the demux delivers (AU headers and frames), and the emulator's
trace of it -- every register write and every store, in program order
(tools/at3p_isa.py). The emulator is first scored against the model on the same AUs
(tools/at3p_emu.py, parse record): no golden is written from an emulator that
disagrees with at3p_ref.

    at3p_seq_golden.py --disc IMAGE.iso [--clip N] [--track T] [--skip N] [--aus N] --out STEM
                       [--hole K]        # break AU K's first Huffman code: a refusal arm

Files: STEM.bytes (one hex byte a line), STEM.trace ("pc kind addr value", hex; kind 0 a
register write, 1 a store), STEM.meta ("bytes events frames errors").
Exit 0 written; 3 SKIP (no image); 5 the emulator disagrees with the model.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_isa as I  # noqa: E402
import at3p_emu as E  # noqa: E402


def au_bytes(aus):
    out = bytearray()
    for _o, prm, fr in aus:
        out += bytes([0x0F, 0xD0, prm >> 8, prm & 0xFF, 0, 0, 0, 0]) + bytes(fr)
    return bytes(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", required=True)
    ap.add_argument("--clip", type=int)
    ap.add_argument("--track", type=int, default=0)
    ap.add_argument("--packs", type=int)
    ap.add_argument("--skip", type=int, default=0)
    ap.add_argument("--aus", type=int, default=8)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    if not os.path.exists(a.disc):
        print("SKIP: no image %s" % a.disc)
        return 3
    clip, aus, _info = R.disc_aus(a.disc, a.clip, a.track, a.packs)
    sel = aus[a.skip:a.skip + a.aus]
    st = E.check(sel, verbose=False, parse_only=True)
    if st["bad"]:
        print("the emulator disagrees with the model: %s" % st["reports"][:1])
        return 5
    words, labels, _ = I.load_program()
    m = I.Machine(words, labels, fast=True)
    m.trace = []
    frames = []
    m.mark_hook = lambda mach, mk: frames.append(mk) if mk == E.C["M_FRAME"] else None
    data = au_bytes(sel)
    m.feed(data)
    r = m.run()
    assert r == "need_input" and m.inpos == len(data), (r, m.inpos, len(data))
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    with open(a.out + ".bytes", "w") as f:
        f.write("".join("%02x\n" % b for b in data))
    with open(a.out + ".trace", "w") as f:
        f.write("".join("%03x %x %04x %04x\n" % t for t in m.trace))
    with open(a.out + ".meta", "w") as f:
        f.write("%d %d %d %d\n" % (len(data), len(m.trace), len(frames), sum(m.errors.values())))
    print("%s: %s clip %d AUs %d..%d, %d bytes, %d trace events, %d frames, errors %s; "
          "the emulator's parse matches the model" % (
              a.out, os.path.basename(a.disc), clip, a.skip, a.skip + len(sel), len(data),
              len(m.trace), len(frames), m.errors or "none"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
