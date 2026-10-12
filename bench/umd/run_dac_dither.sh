#!/usr/bin/env bash
#
# run_dac_dither.sh -- the analog DAC's ordered dither (umd/dac_dither.sv,
# bench/umd/dac_dither_tb.sv; docs/analog.md §9). Taken from MiSTer_DVD's runner (its PR #164);
# its wiring arms live in bench/umd/run_scaffold.sh here (W130 / W131, T4-T7: tools/check_emu_wiring.py).
#
#   bench/umd/run_dac_dither.sh          the bench
#   bench/umd/run_dac_dither.sh --red    every mutation must FAIL its own arm
#
#   T1  half:   the threshold 0 / 2 only (its low bit lost)      [T1]
#   T2  wide:   the threshold 0..6                               [T2]
#   T3  wrap:   no clamp at 255                                  [T3]
#   T4  blank:  dithered outside DE                              [T4]
#   T5  noen:   Off does not bypass                              [T5]
#   T6  static: the pattern never inverts                        [T6]
#   T7  bayer:  the Bayer top-bits matrix (2 x 2 {0 2; 3 1})     [T7]
#   T8a norow:  the line never steps the row                     [T8]
#   T8b pwm:    the same ramp on every line                      [T8]
#   T9  cyclic: a Latin square whose pixels are unbalanced       [T9]
#
set -e
cd "$(dirname "$0")/../.."

SRC=umd/dac_dither.sv
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SIM=$TMP/dac_dither_sim
LOG=$TMP/dac_dither.log

build() {   # $1 = module source
  iverilog -g2012 -o "$SIM" "$1" bench/umd/dac_dither_tb.sv
}

if [ "${1:-}" = "--red" ]; then
  mut=$TMP/dac_dither_red.sv
  fails=0

  verdict() {   # $1 = the arm tag that must fail
    build "$mut"
    if vvp "$SIM" > "$LOG" 2>&1; then
      echo "  FAIL: the RED arm PASSED -- the bench cannot detect this defect"
      fails=$((fails+1))
    elif ! grep -q "^FAIL \[$1\]" "$LOG"; then
      echo "  FAIL: the bench failed, but not on $1:"
      grep -E "^FAIL" "$LOG" | head -3 | sed 's/^/    /'
      fails=$((fails+1))
    else
      echo "  failed as required:"
      grep -E "^FAIL \[$1\]" "$LOG" | head -2 | sed 's/^/    /'
    fi
  }

  red_case() {   # $1 = label, $2 = the arm tag that must fail, $3 = sed program
    echo "== RED [$1] (expects $2) =="
    sed "$3" "$SRC" > "$mut"
    # a pattern that no longer matches leaves an UNMUTATED copy that passes: a hard fail
    if cmp -s "$mut" "$SRC"; then
      echo "  FAIL: the mutation did not apply -- the pattern no longer matches $SRC"
      fails=$((fails+1)); return
    fi
    verdict "$2"
  }

  red_case "half: threshold 0/2 only" T1 \
           's/{1.b0, din\[23:16\]} + {7.d0, t}/{1'"'"'b0, din[23:16]} + {7'"'"'d0, t[1], 1'"'"'b0}/'
  red_case "norow: the line never steps the row" T8 \
           's/if (hs \&\& !hs_q) row <= row + 2.d1;//'
  red_case "wide: threshold 0..6" T2 \
           's/{1.b0, din\[23:16\]} + {7.d0, t}/{1'"'"'b0, din[23:16]} + {6'"'"'d0, t, 1'"'"'b0}/'
  red_case "wrap: no clamp at 255" T3 \
           's/s2\[8\] ? 8.hFF : s2\[7:0\]/s2[7:0]/'
  red_case "blank: dithered outside DE" T4 \
           's/if (!en_s2 || !de) dout = din;/if (!en_s2) dout = din;/'
  red_case "noen: Off does not bypass" T5 \
           's/if (!en_s2 || !de) dout = din;/if (!de) dout = din;/'
  red_case "static: the pattern never inverts" T6 \
           's/wire \[1:0\] t  = fld ? (2.d3 - t0) : t0;/wire [1:0] t  = t0;/'

  # the four "// row N" lines of the case rewritten with another matrix (rows top to
  # bottom, columns left to right)
  red_matrix() {   # $1 = label, $2 = arm, $3 = "r0c0 r0c1 ... r3c3"
    echo "== RED [$1] (expects $2) =="
    python3 - "$SRC" "$mut" "$3" <<'PYEOF'
import re, sys
src, dst, vals = sys.argv[1], sys.argv[2], [int(v) for v in sys.argv[3].split()]
out = []
for line in open(src):
    m = re.match(r'(\s*)4.h[0-9A-F]: t0 = .*// row ([0-3])\s*$', line)
    if m:
        r = int(m.group(2))
        cells = []
        for c in range(4):
            sel = "4'h%X" % (4 * r + c) if (r, c) != (3, 3) else "default"
            cells.append("%s: t0 = 2'd%d;" % (sel, vals[4 * r + c]))
        line = m.group(1) + ' '.join(cells) + '  // row %d\n' % r
    out.append(line)
open(dst, 'w').writelines(out)
PYEOF
    if cmp -s "$mut" "$SRC"; then
      echo "  FAIL: the matrix mutation did not apply to $SRC"; fails=$((fails+1)); return
    fi
    verdict "$2"
  }
  # T7: the first shipped matrix (DVD's, H264's), a 4 x 4 Bayer's top two bits = 2 x 2 {0 2; 3 1}
  red_matrix "bayer: the Bayer top-bits matrix" T7 "0 2 0 2  3 1 3 1  0 2 0 2  3 1 3 1"
  # T8: the PWM cores' pattern (a phase 0..3 from hsync, identical every line)
  red_matrix "pwm: the same ramp on every line" T8 "3 2 1 0  3 2 1 0  3 2 1 0  3 2 1 0"
  # T9: a Latin square (lines and columns exact) whose high and low thresholds do not
  # alternate: a 480i pixel at {0, 1} or {2, 3} is off by a quarter step
  red_matrix "cyclic: Latin, but pixels unbalanced" T9 "0 1 2 3  1 2 3 0  2 3 0 1  3 0 1 2"

  if [ "$fails" -ne 0 ]; then echo "RED SUITE FAILED: $fails arm(s)"; exit 1; fi
  echo "RED suite OK: every mutation was caught by its own arm."
  exit 0
fi

build "$SRC"
vvp "$SIM" | tee "$LOG"
grep -q "^PASS dac_dither_tb" "$LOG" || { echo "dac_dither: no PASS marker"; exit 1; }
echo "dac_dither: green."
