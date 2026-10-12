#!/usr/bin/env bash
#
# run_zoom.sh -- fj#71 Zoom's decision and band (umd/zoom_ctl.sv, bench/umd/zoom_ctl_tb.sv;
# docs/zoom.md). Its wiring arms live in bench/umd/run_scaffold.sh (W142-W152:
# tools/check_emu_wiring.py), the subtitle's clamp in run_overlay.sh (O5-O7), the HUD's layout
# in run_transport_hud.sh (Z1 / Z2), the host's bit in run_umd_host.sh (H32).
#
#   bench/umd/run_zoom.sh          the bench
#   bench/umd/run_zoom.sh --red    every mutation must FAIL its own arm
#
#   Z1  sel ignored                      [G-sel]
#   Z2  the 480i raster ignored          [G-il]
#   Z3  media_seen ignored               [G-media]
#   Z4  STOP ignored (the disc screen)   [G-stop]
#   Z5  a disc menu ignored              [G-menu]
#   Z6  sh_valid ignored                 [G-valid]
#   Z7  a 16:9 picture zoomed            [G-wide]
#   Z8  any width zoomed                 [G-w]
#   Z9  any height zoomed                [G-hf]
#   Z10 latched every cycle, not at vbl  [L]
#   Z11 the band from line 59            [W0]
#   Z12 the band through line 420        [W1]
#
set -e
cd "$(dirname "$0")/../.."

SRC=umd/zoom_ctl.sv
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SIM=$TMP/zoom_sim
LOG=$TMP/zoom.log

build() {   # $1 = module source
  iverilog -g2012 -o "$SIM" "$1" bench/umd/zoom_ctl_tb.sv
}

if [ "${1:-}" = "--red" ]; then
  mut=$TMP/zoom_ctl_red.sv
  fails=0
  red_case() {   # $1 = name, $2 = the arm that must fail, $3 = python old, $4 = new
    echo "== RED $1 (expects $2) =="
    if ! python3 - "$SRC" "$mut" "$3" "$4" <<'PYEOF'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(dst, "w").write(s.replace(old, new))
PYEOF
    then echo "  FAIL: the mutation did not apply"; fails=$((fails+1)); return; fi
    build "$mut"
    if vvp "$SIM" > "$LOG" 2>&1 && grep -q "^PASS" "$LOG"; then
      echo "  FAIL: the RED arm PASSED -- the bench cannot detect this defect"; fails=$((fails+1))
    elif ! grep -q "^FAIL \[$2\]" "$LOG"; then
      echo "  FAIL: the bench failed, but not on [$2]:"; grep -E "^FAIL" "$LOG" | head -2 | sed 's/^/    /'
      fails=$((fails+1))
    else
      echo "  caught: $(grep -m1 "^FAIL \[$2\]" "$LOG")"
    fi
  }
  red_case Z1  G-sel   "wire live = sel && !il" "wire live = 1'b1 && !il"
  red_case Z2  G-il    "wire live = sel && !il" "wire live = sel"
  red_case Z3  G-media "&& media_seen &&" "&&"
  red_case Z4  G-stop  "&& !stopped &&" "&&"
  red_case Z5  G-menu  "&& !host_menu &&" "&&"
  red_case Z6  G-valid "&& sh_valid &&" "&&"
  red_case Z7  G-wide  "&& !pic_wide &&" "&&"
  red_case Z8  G-w     "sh_w == 8'd45 && sh_hf" "sh_hf"
  red_case Z9  G-hf    "&& sh_hf == 8'd30;" ";"
  red_case Z10 L       "else if (vbl) zoom <= live;" "else          zoom <= live;"
  red_case Z11 W0      "parameter logic [11:0] ZOOM_Y0 = 12'd60," "parameter logic [11:0] ZOOM_Y0 = 12'd59,"
  red_case Z12 W1      "parameter logic [11:0] ZOOM_Y1 = 12'd420" "parameter logic [11:0] ZOOM_Y1 = 12'd421"
  if [ "$fails" -ne 0 ]; then echo "RED SUITE FAILED: $fails arm(s)"; exit 1; fi
  echo "RED suite OK: every mutation was caught by its own arm."
  exit 0
fi

build "$SRC"
vvp "$SIM" | tee "$LOG"
grep -q "^PASS: zoom_ctl_tb" "$LOG" || { echo "zoom: no PASS marker"; exit 1; }
echo "zoom: green."
