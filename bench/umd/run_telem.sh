#!/usr/bin/env bash
# run_telem.sh -- the HIL telemetry path (docs/hil_harness.md "Telemetry"):
# umd/umd_telem.sv (the EXT_BUS responder, bench/umd/telem_tb.sv, scored against
# tools/telem_layout.py's golden) and umd/ddr_probe.sv (the DDR3 port watcher,
# bench/umd/ddr_probe_tb.sv). First the table's own consistency: the generated files
# are current (--check) and its port list is the module's.
#
# --red: mutations on a COPY, each caught by its own arm:
#   T1  the responder answers every command                 -> [offbus]
#   T2  the atomic group latched at every word              -> [snapshot]
#   T4  the format word off by one                          -> [magic]
#   T5  two words' sources swapped                          -> [words]
#   T6  the word counter saturating at 63 (6 bits: the A11 bug) -> [words]
#   P1  the BUSY run wraps instead of saturating            -> [busy]
#   P2  returned beats never paid off                       -> [owed]
#   P3  write beats counted under waitrequest               -> [count]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/telem
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
echo "== the table =="
python3 tools/telem_layout.py --check | sed 's/^/  /' || fail=1
python3 - <<'PYEOF' || fail=1
import re, sys
sys.path.insert(0, "tools")
import telem_layout as T
src = open("umd/umd_telem.sv").read()
ports = re.findall(r"input\s+wire\s+(?:\[(\d+):0\]\s+)?(t_\w+)", src)
got = [(n, int(h) + 1 if h else 1) for h, n in ports]
if got != T.PORTS:
    print("  FAIL: umd_telem's source ports differ from tools/telem_layout.py PORTS"); sys.exit(1)
print("  OK: umd_telem's %d source ports are the table's" % len(got))
PYEOF
for seed in 1 2 3; do python3 tools/telem_layout.py --golden .sim/telem/g$seed --seed $seed; done
echo "== GREEN =="
if iverilog -g2012 -I . -o .sim/telem/t_sim umd/umd_telem.sv bench/umd/telem_tb.sv 2>.sim/telem/build.log; then
  for seed in 1 2 3; do
    if vvp -n .sim/telem/t_sim +stem=.sim/telem/g$seed > .sim/telem/t$seed.log 2>&1 && grep -q "^PASS: telem_tb" .sim/telem/t$seed.log; then
      echo "  PASS seed $seed: $(grep '^telem_tb:' .sim/telem/t$seed.log | sed 's/^telem_tb: //')"
    else echo "  FAIL telem seed $seed"; grep -m3 FAIL .sim/telem/t$seed.log; fail=1; fi
  done
else echo "  FAIL: build"; head -5 .sim/telem/build.log; fail=1; fi
if iverilog -g2012 -o .sim/telem/p_sim umd/ddr_probe.sv bench/umd/ddr_probe_tb.sv 2>.sim/telem/pbuild.log &&
   vvp -n .sim/telem/p_sim > .sim/telem/p.log 2>&1 && grep -q "^PASS: ddr_probe_tb" .sim/telem/p.log; then
  echo "  PASS $(grep '^ddr_probe_tb:' .sim/telem/p.log)"
else echo "  FAIL ddr_probe"; grep -m3 FAIL .sim/telem/p.log; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  mut() {   # name file old new arm
    local name=$1 file=$2 old=$3 new=$4 arm=$5 d
    d=$(mktemp -d); mkdir -p "$d/umd" "$d/bench/umd"
    cp umd/umd_telem.sv umd/umd_telem_words.svh umd/ddr_probe.sv "$d/umd/"
    cp bench/umd/telem_tb.sv bench/umd/telem_tb_ports.svh bench/umd/ddr_probe_tb.sv "$d/bench/umd/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    [ $? != 0 ] && { echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; }
    # compiled FROM the copy (iverilog resolves `include against the working directory first)
    if [[ $file == *probe* ]]; then
      (cd "$d" && iverilog -g2012 -o sim umd/ddr_probe.sv bench/umd/ddr_probe_tb.sv 2>build.log && timeout 600 vvp -n sim > log 2>&1)
    else
      (cd "$d" && iverilog -g2012 -I . -o sim umd/umd_telem.sv bench/umd/telem_tb.sv 2>build.log &&
       timeout 600 vvp -n sim +stem="$OLDPWD/.sim/telem/g1" > log 2>&1)
    fi
    if grep -q "^PASS:" "$d/log" 2>/dev/null; then echo "  $name: SURVIVED -- the bench cannot see this defect"; fail=1
    elif grep -Eq "FAIL \[($arm)\]" "$d/log" 2>/dev/null; then echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)"
    else echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log" "$d/build.log" 2>/dev/null; fail=1; fi
    rm -rf "$d"
  }
  mut T1 umd/umd_telem.sv "active <= (io_din == T_CMD);" "active <= 1'b1;" offbus
  mut T2 umd/umd_telem.sv $'            if (wcnt == 7\'d0) begin\n                active <= (io_din == T_CMD);\n                `UMD_TELEM_LATCH\n            end' \
         $'            if (wcnt == 7\'d0) active <= (io_din == T_CMD);\n            `UMD_TELEM_LATCH' snapshot
  # the format word as generated ({FORMAT, NWORDS}: it moves whenever a word is added)
  FMTW=$(grep -o "7'd1: w_val = 16'h[0-9A-Fa-f]*;" umd/umd_telem_words.svh)
  mut T4 umd/umd_telem_words.svh "$FMTW" "7'd1: w_val = 16'h0001;" magic
  mut T5 umd/umd_telem_words.svh "w_val = t_late;   // late" "w_val = t_starve;   // late" words
  mut T6 umd/umd_telem.sv "if (wcnt != 7'h7F) wcnt <= wcnt + 7'd1;" "if (wcnt != 7'h3F) wcnt <= wcnt + 7'd1;" words
  mut P1 umd/ddr_probe.sv "if (busy != 16'hFFFF) busy <= busy + 16'd1;" "busy <= busy + 16'd1;" busy
  mut P2 umd/ddr_probe.sv "if (rv_q && o != 17'd0) o = o - 17'd1;" "if (1'b0) o = o - 17'd1;" owed
  mut P3 umd/ddr_probe.sv "if (wr_q && !wt_q) wr_beats <= wr_beats + 24'd1;" "if (wr_q) wr_beats <= wr_beats + 24'd1;" count
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
