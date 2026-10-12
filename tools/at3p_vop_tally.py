#!/usr/bin/env python3
"""Which vector-op modes a set of windows exercises (the bench arms' coverage of the
synthesis, docs/at3p_decoder.md S5): the microcode's vector ops and their arguments,
from the emulator in its fast mode (the arguments come from the program, not from the
engines' results), reduced to the modes that matter:

  IMDCT window pairs 0..3, TZERO / RZERO with a non-zero count, RWIN steps (+1 the
  overlap windows, +32 a start ramp, -32 a stop ramp), WAVE offsets 0 / 128, RSAT with
  invert, NZ (noise), DQ with a negative shift (large scale factors), PCMZ.

    at3p_vop_tally.py --disc IMAGE.iso [--clip N] --skip N --aus N  [--disc ... ]...
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import at3p_ref as R  # noqa: E402
import at3p_isa as I  # noqa: E402
import at3p_fixed as F  # noqa: E402
import at3p_seq_golden as SG  # noqa: E402

MODES = ["imdct_w0", "imdct_w1", "imdct_w2", "imdct_w3", "tzero", "rzero", "rwin_+1",
         "rwin_+32", "rwin_-32", "wave_off0", "wave_off128", "rsat_invert", "nz",
         "dq_neg_shift", "pcmz"]


def modes_of(aus):
    words, labels, _ = I.load_program()
    m = I.Machine(words, labels, fast=True)
    seen = {}

    def hook(mach, k):
        r = mach.reg
        name = I.VOPS[k]
        tags = []
        if name == "imdct":
            tags.append("imdct_w%d" % (r[9] & 3))
        elif name == "tzero" and r[10]:
            tags.append("tzero")
        elif name == "rzero" and r[10]:
            tags.append("rzero")
        elif name == "rwin":
            tags.append("rwin_%+d" % I.s16(r[12]))
        elif name == "wave":
            tags.append("wave_off%d" % r[12])
        elif name == "rsat" and r[9]:
            tags.append("rsat_invert")
        elif name == "nz":
            tags.append("nz")
        elif name == "dq" and F.SF_E[r[12]] < 10:
            tags.append("dq_neg_shift")
        elif name == "pcmz":
            tags.append("pcmz")
        for t in tags:
            seen[t] = seen.get(t, 0) + 1
    m.vop_hook = hook
    m.feed(SG.au_bytes(aus))
    m.run()
    return seen


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--disc", action="append", required=True)
    ap.add_argument("--clip", action="append", type=int)
    ap.add_argument("--skip", action="append", type=int, required=True)
    ap.add_argument("--aus", action="append", type=int, required=True)
    a = ap.parse_args(argv)
    total = {}
    for i, disc in enumerate(a.disc):
        clip = a.clip[i] if a.clip and i < len(a.clip) and a.clip[i] >= 0 else None
        _c, aus, _info = R.disc_aus(disc, clip, 0, None)
        seen = modes_of(aus[a.skip[i]:a.skip[i] + a.aus[i]])
        print("%-45s %s" % (os.path.basename(disc)[:45], " ".join("%s=%d" % kv for kv in sorted(seen.items()))))
        for k, v in seen.items():
            total[k] = total.get(k, 0) + v
    print("never: %s" % (" ".join(m for m in MODES if not total.get(m)) or "-"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
