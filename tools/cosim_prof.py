#!/usr/bin/env python3
"""Name the cosim's +prof histograms (bench/umd/cosim_main.cpp): cycles a macroblock per
state of recon_mb's front (ms), recon_inter's fetch (st) and interpolation (k) sides, the back engine (es) and the residual
engine (rs), the state names read from the RTL's enums.

    cosim_prof.py COSIM.log [--min N]     (states under N cycles a macroblock are folded)
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def enum(path, pattern):
    src = open(os.path.join(ROOT, path)).read()
    m = re.search(pattern, src, re.S)
    body = re.sub(r"//[^\n]*", "", m.group(1))
    return [n.strip() for n in body.replace("\n", " ").split(",") if n.strip()]


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    log = argv[0]
    lim = float(argv[argv.index("--min") + 1]) if "--min" in argv else 10.0
    names = {
        "ms": enum("umd/h264/recon_mb.sv", r"typedef enum logic \[6:0\] \{(.*?)\} mstate_t;"),
        "inter": enum("umd/h264/recon_inter.sv", r"typedef enum logic \[4:0\] \{(.*?)\} istate_t;"),
        "interp": enum("umd/h264/recon_inter.sv", r"typedef enum logic \[3:0\] \{(.*?)\} kstate_t;"),
        "es": enum("umd/h264/recon_mb_fsm.svh", r"typedef enum logic \[3:0\] \{(.*?)\} estate_t;"),
        "rs": enum("umd/h264/recon_mb_fsm.svh", r"typedef enum logic \[1:0\] \{(.*?)\} rstate_t;"),
    }
    txt = open(log).read()
    m = re.search(r"PROF macroblocks (\d+) span (\d+)", txt)
    if not m:
        sys.exit("cosim_prof: no PROF lines in %s (run the cosim with +prof)" % log)
    nmb, span = int(m.group(1)), int(m.group(2))
    print("%d macroblocks, %.0f cycles a macroblock" % (nmb, span / nmb))
    for unit in ("ms", "inter", "interp", "es", "rs"):
        rows = [(int(i), int(c)) for i, c in re.findall(r"PROF %s (\d+) (\d+)" % unit, txt)]
        rows.sort(key=lambda r: -r[1])
        print("  %s:" % unit)
        rest = 0.0
        for i, c in rows:
            per = c / nmb
            if per < lim:
                rest += per
                continue
            nm = names[unit][i] if i < len(names[unit]) else str(i)
            print("    %-16s %7.0f" % (nm, per))
        if rest:
            print("    %-16s %7.0f" % ("(the rest)", rest))
    return 0


if __name__ == "__main__":
    sys.exit(main())
