#!/usr/bin/env bash
# run_goto_ctl.sh -- umd/goto_ctl.sv, Go To's editor (P6c, docs/p6c.md §9), in
# bench/umd/goto_ctl_tb.sv: a randomized walk of presses against the bench's reference of the
# behaviour (written from the spec: transport.md §3's walk-through, D15 / D16), a mock reader
# answering the chapter queries by umd_reader's NAV_CHAP contract.
#
# GREEN: three seeds, 3,000 presses each (titles with 0-40 chapters over three items, totals
# either side of 100 h, OUT before IN, a shown item past u16; stops, disc menus, mounts and the
# picture going away), and a directed step pressed while a query is in flight.
#
# --red [MUTS="M1 M4"]: mutations on a COPY, each caught by its own arm:
#   M1  the minutes' wrap one short (58 -> 0)                 [state]
#   M2  hours 0-99 on a title of 100 h or more                 [state]
#   M3  the chapter box focused on a title without chapters    [state]
#   M4  down asks from the candidate, not its key - 1          [state]  (stays on the chapter)
#   M5  the opening's time not divided down (t = 0)            [state]
#   M6  the marker shown for a chapter in another item         [mark]
#   M7  the marker's OUT clamp gone                            [mark]
#   M8  a chapter jump with the time's command (15)            [cmd]
#   M9  Stop does not close it                                 [state]|[cmd]
#   M10 a disc menu does not close it                          [state]|[cmd]
#   M11 a step pressed during a query is taken                 [state]|[port]
#   M12 the query dropped before its answer                    [port]|[state]
#   M13 x on the time box jumps at once (no field editing)     [cmd]|[state]
set -u
cd "$(dirname "$0")/../.."
W=.sim/goto
mkdir -p $W
fail=0; red=0
for a in "$@"; do case $a in --red) red=1;; esac; done
RTL=umd/goto_ctl.sv
TB=bench/umd/goto_ctl_tb.sv
SEEDS="1 2 3"

run_set() {   # sim -> 0 if every seed passes; the logs in $2
  local sim=$1 out=$2 s rc=0
  for s in $SEEDS; do
    timeout 1800 vvp -n "$sim" +seed=$s +n=${N:-3000} > "$out.$s" 2>&1
    grep -q "^PASS: goto_ctl_tb" "$out.$s" || { rc=1; break; }
  done
  return $rc
}

echo "== GREEN =="
rm -f $W/sim
iverilog -g2012 -o $W/sim $RTL $TB || { echo "  FAIL build"; exit 1; }
if run_set $W/sim $W/green; then
  for s in $SEEDS; do echo "  PASS $(grep '^goto_ctl_tb:' $W/green.$s | sed 's/^goto_ctl_tb: //')"; done
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
    python3 - "$d/goto_ctl.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open("umd/goto_ctl.sv").read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/goto_ctl.sv" $TB 2> "$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    N=1500 run_set "$d/sim" "$d/log"
    local hit; hit=$(grep -hEm1 "FAIL \[($arm)\]" "$d"/log.* 2>/dev/null)
    if [ -n "$hit" ]; then echo "  $name: caught by $(echo "$hit" | cut -c1-110)" > "$RES/$name"
    elif grep -qh FAIL "$d"/log.*; then { echo "  $name: failed but NOT in [$arm]: $(grep -hm1 FAIL "$d"/log.*)"; echo MUTFAIL; } > "$RES/$name"
    else { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  mut M1 "E_M: mm <= k_up ? ((mm == 6'd59) ? 6'd0" "E_M: mm <= k_up ? ((mm == 6'd58) ? 6'd0" "state" &
  mut M2 "wire [9:0] hmax     = h3 ? 10'd999 : 10'd99;" "wire [9:0] hmax     = 10'd99;" "state" &
  mut M3 "open <= 1'b1; sel <= (n_chapters == 16'd0);" "open <= 1'b1; sel <= 1'b0;" "state" &
  mut M4 "gq_key <= k_up ? cand : cand - 64'd1;" "gq_key <= cand;" "state" &
  mut M5 "ex_x <= el_ticks; ex <= X_H;" "ex_x <= el_ticks; ex <= X_IDLE;" "state" &
  wait
  mut M6 "m_in <= (rd_item_idx[31:16] == 16'd0) && (cand[63:48] == rd_item_idx[15:0]) && (g_chapter != 16'd0);" "m_in <= (g_chapter != 16'd0);" "mark" &
  mut M7 "rd_gt_out ? rd_item_out : cand[47:0];" "cand[47:0];" "mark" &
  mut M8 "cmd_v <= 1'b1; cmd_code <= C_SEEK;" "cmd_v <= 1'b1; cmd_code <= C_TIME;" "cmd" &
  mut M9 "!can_open || k_goto || k_back || k_menu) begin" "!can_open || k_goto || k_menu) begin" "state|cmd" &
  mut M10 "wire       can_open = sh_pts_v && (state == ST_PLAY || state == ST_PAUSE) && !host_ui &&" "wire       can_open = sh_pts_v && (state == ST_PLAY || state == ST_PAUSE) &&" "state|cmd" &
  wait
  mut M11 "if (!gq_req && !q_due && g_chapter != 16'd0 && (k_up || cand != 64'd0)) begin" "if (!q_due && g_chapter != 16'd0 && (k_up || cand != 64'd0)) begin" "state|port" &
  mut M12 "                gq_req <= 1'b0; q_kind <= 2'd0;
                case (q_kind)" "                q_kind <= 2'd0;
                case (q_kind)" "port|state" &
  mut M13 "if (edit == E_NONE) edit <= sel ? E_H : E_CHAP;" "if (edit == E_NONE && !sel) edit <= E_CHAP;" "cmd|state" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
