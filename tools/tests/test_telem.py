#!/usr/bin/env python3
"""The HIL telemetry's host side, no hardware:

  layout  tools/telem_layout.py: the generated files are current; word 0 MAGIC, word 1
          {FORMAT, NWORDS}; every word 16 bits, a fast counter's scale its slice's low
          bit; the expression evaluator on
          hand values (a concatenation, a part-select, a sized constant).
  host    tools/mister.py: a 32-bit and a 16-bit counter unwrapped across their wraps; the
          least-squares rate of a counter sampled with jitter recovers the true rate to
          within 50 ppm (2 min of a 24/s counter) and beats endpoint differencing.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.dirname(HERE))
import umd_synth as S  # noqa: E402
import telem_layout as T  # noqa: E402
import mister as M  # noqa: E402

Sc = S.Score("test_telem")

print("[layout]")
gen = {"svh": T.svh(), "h": T.header(), "tb": T.tb_ports()}
Sc.check("generated files current", [k for k, v in gen.items() if open(T.PATHS[k]).read() != v], [])
w = T.words()
Sc.check("word 0 magic, word 1 {format, nwords}", (w[0][3], w[1][3]),
         ("16'h%04X" % T.MAGIC, "16'h%02X%02X" % (T.FORMAT, len(w))))
import re  # noqa: E402
bad = []
for nm, kind, e, _a, sc, _w in T.FIELDS:
    m = re.fullmatch(r"(\w+)\[(\d+):(\d+)\]", e)
    upstream = {"wait4k": 4096}          # its port is already cycles / 4096 (emu's sn_ow)
    if m and (int(m.group(2)) - int(m.group(3)) != 15 or
              (1 << int(m.group(3))) * upstream.get(nm, 1) != sc):
        bad.append(nm)
Sc.check("every slice 16 bits wide, its scale 2^(its low bit)", bad, [])
# the responder's word index holds the table (2026-10-07: a 6-bit counter saturated at word 63 under
# a 67-word table, and refused / warn / subs read word 63 on hardware)
_src = open(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "..", "umd", "umd_telem.sv")).read()
_m = re.search(r"logic \[(\d+):0\]\s+wcnt", _src)
Sc.check("umd_telem's word counter is WIDX bits and holds every word",
         (int(_m.group(1)) + 1 if _m else None, len(w) <= (1 << T.WIDX) - 1), (T.WIDX, True))
val = {"t_reanchor": 0x12, "t_ended": 1, "t_sflags": 5, "t_wait4k": 0xABCDE, "t_rerr": 0x123456, "t_rcode": 9}
Sc.check("concatenation {8, 1, 3, 4'd0}", T.evaluate("{t_reanchor, t_ended, t_sflags, 4'd0}", val),
         (0x12 << 8) | (1 << 7) | (5 << 4))
Sc.check("part-select [15:0]", T.evaluate("t_wait4k[15:0]", val), 0xBCDE)
Sc.check("concatenation with a part-select", T.evaluate("{t_rerr[11:0], t_rcode}", val), (0x456 << 4) | 9)

print("[host]")
rows = [{"t": i * 0.25, "a": (0xFFFFFF00 + 100 * i) & 0xFFFFFFFF, "b": (65000 + 300 * i) & 0xFFFF} for i in range(20)]
Sc.check("32-bit counter unwrapped across its wrap", M._unwrapped(rows, "a", 32)[-1], 1900)
Sc.check("16-bit counter unwrapped across its wrap", M._unwrapped(rows, "b", 16)[-1], 5700)
import random  # noqa: E402
rnd = random.Random(7)
true = 23.976023976
ts, ys = [], []
for i in range(480):                                  # 2 min at 4 Hz, sample times jittered
    t = i * 0.25 + rnd.uniform(0, 0.02)
    ts.append(t)
    ys.append(int(true * t))                          # an integer counter
fit = M._rate(ts, ys)
end = (ys[-1] - ys[0]) / (ts[-1] - ts[0])
Sc.check("least-squares rate within 50 ppm (2 min of a 24/s counter: ~15 ppm of quantisation)", abs(fit / true - 1) * 1e6 < 50, True)
Sc.check("(and endpoint differencing is worse)", abs(end / true - 1) > abs(fit / true - 1), True)

Sc.finish()
