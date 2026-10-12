#!/usr/bin/env bash
# run_ab_ctl.sh -- umd/ab_ctl.sv, A-B Repeat (docs/ab_repeat.md), in bench/umd/ab_ctl_tb.sv: a
# randomized walk of a mock player (multi-item titles with each item's PTS restarting, u32 / 33-bit
# tops, pauses, stops, trick play, foreign seeks, the host's seeks and menus, the end, mounts, bare
# files; a command port that refuses now and then) against the bench's reference written from
# docs/ab_repeat.md §2 (the maintainer's PSP).
#
# GREEN: three seeds, 3,000 steps each, plus the directed blink / hold and bare-file arms.
#
# --red [MUTS="M1 M4"]: mutations on a COPY, each caught by its own arm:
#   M1  B reached by the PTS alone (item first dropped)        [cmd]
#   M2  B allowed at A (not after it)                          [state]|[cnt]
#   M3  re-armed at the take, not at the landing               [cmd]
#   M4  a chapter press in the loop not taken                  [cmd]
#   M5  a refused SEEK never asked again                       [retry]
#   M6  Stop does not clear                                    [state]
#   M7  a host seek does not clear                             [state]
#   M8  the blink's half-period one short                      [tag]
#   M9  no 2 s hold after B                                    [tag]
#   M10 a press in trick play taken                            [state]|[cnt]
#   M11 a bare file not gated (no UNAVAIL)                     [na]|[state]
#   M12 the SEEK's target B, not A                             [cmd]
#   M13 a press in a pickup's own cycle taken (the key half new) [cnt]|[state]|[cmd]
#   M14 the title's end does not clear                         [state]
set -u
cd "$(dirname "$0")/../.."
W=.sim/ab
mkdir -p $W
fail=0; red=0
for a in "$@"; do case $a in --red) red=1;; esac; done
RTL=umd/ab_ctl.sv
TB=bench/umd/ab_ctl_tb.sv
SEEDS="1 2 3"

run_set() {   # sim -> 0 if every seed passes; the logs in $2
  local sim=$1 out=$2 s rc=0
  for s in $SEEDS; do
    timeout 900 vvp -n "$sim" +seed=$s +n=${N:-3000} > "$out.$s" 2>&1
    grep -q "^PASS: ab_ctl_tb" "$out.$s" || { rc=1; break; }
  done
  return $rc
}

echo "== GREEN =="
rm -f $W/sim
iverilog -g2012 -o $W/sim $RTL $TB || { echo "  FAIL build"; exit 1; }
if run_set $W/sim $W/green; then
  for s in $SEEDS; do echo "  PASS $(grep '^ab_ctl_tb:' $W/green.$s | sed 's/^ab_ctl_tb: //')"; done
else
  echo "  FAIL"; grep -h FAIL $W/green.* | head -3; fail=1
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name old new arm-regex
    local name=$1 old=$2 new=$3 arm=$4 d
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    d=$(mktemp -d)
    python3 - "$d/ab_ctl.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open("umd/ab_ctl.sv").read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/ab_ctl.sv" $TB 2> "$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    run_set "$d/sim" "$d/log"
    local hit; hit=$(grep -hEm1 "FAIL \[($arm)\]" "$d"/log.* 2>/dev/null)
    if [ -n "$hit" ]; then echo "  $name: caught by $(echo "$hit" | cut -c1-110)" > "$RES/$name"
    elif grep -qh FAIL "$d"/log.*; then { echo "  $name: failed but NOT in [$arm]: $(grep -hm1 FAIL "$d"/log.*)"; echo MUTFAIL; } > "$RES/$name"
    else { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  mut M1 "((key_item > b_item) || (key_item == b_item && sh_pts >= b_pts))" "(sh_pts >= b_pts)" "cmd" &
  mut M2 "(key_item == a_item && sh_pts > a_pts)" "(key_item == a_item && sh_pts >= a_pts)" "state|cnt" &
  mut M3 "req <= 1'b0; inflight <= 1'b1; seen <= 1'b0; twait <= '0;" "req <= 1'b0; inflight <= 1'b1; seen <= 1'b0; twait <= '0; armed <= 1'b1;" "cmd" &
  mut M4 "if ((k_next || k_prev) && !req && !inflight)" "if (1'b0)" "cmd" &
  mut M5 "if (twait == TAKE_WAIT[6:0]) begin" "if (1'b0) begin" "retry" &
  wait
  mut M6 "((state == ST_STOP || ended) && ab_st != AB_OFF)" "(ended && ab_st != AB_OFF)" "state" &
  mut M7 "(host_ui && !host_ui_q) || host_nav ||" "(host_ui && !host_ui_q) ||" "state" &
  mut M8 "if (tmr == BLINK_CYC[25:0] - 26'd1)" "if (tmr == BLINK_CYC[25:0] - 26'd2)" "tag" &
  mut M9 "tmr <= HOLD_CYC[25:0];" "tmr <= '0;" "tag" &
  mut M10 "wire can_set  = playing && tk_speed == 2'd0 &&" "wire can_set  = playing &&" "state|cnt" &
  wait
  mut M11 "if (bare) unavail <= 1'b1;" "if (1'b0) unavail <= 1'b1;" "na|state" &
  mut M12 "assign cmd_item = a_item;" "assign cmd_item = b_item;" "cmd" &
  mut M13 "sh_pts_v && !pick && !ended;" "sh_pts_v && !ended;" "cnt|state|cmd" &
  mut M14 "((state == ST_STOP || ended) && ab_st != AB_OFF)" "(state == ST_STOP && ab_st != AB_OFF)" "state" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
