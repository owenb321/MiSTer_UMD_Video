#!/usr/bin/env bash
# run_pcm_shot.sh -- umd/pcm_shot.sv, the menus' sound one-shot (P9, docs/p9.md §3.2 item 5):
# bench/umd/pcm_shot_tb.sv against bench/umd/ddr_model.sv, three seeds of the model's
# waitrequest / latency, and a slow model (+lat_min=60 +lat_max=200: words arrive late; the
# samples must stay exact, only delayed).
# --red: mutations on a COPY (compiled inside it), each caught by its own arm:
#   S1  old-generation words played after a retrigger (the gen check gone)      -> [retrig]
#   S2  a trigger keeps the word being played                                  -> [retrig] / [stereo]
#   S3  stereo: the second frame read from the first frame's R                  -> [stereo]
#   S4  mono: R from the next sample, not L                                    -> [mono]
#   S5  one frame too many (busy falls a frame late)                           -> [len]
#   S6  the 48 kHz tick's period wrong (1,100 / 2)                             -> [tick]
#   S7  len 0 does not stop the sound                                          -> [stop]
#   S8  the beats of a burst issued before a trigger tagged with the new gen    -> [retrig]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/pcm
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
SRC="umd/fifo_dc.sv umd/pcm_shot.sv"

build() {   # DIR -> DIR/sim, compiled from inside the copy
  # shellcheck disable=SC2086
  (cd "$1" && rm -f sim && iverilog -g2012 -o sim $SRC "$OLDPWD/bench/umd/ddr_model.sv" "$OLDPWD/bench/umd/pcm_shot_tb.sv" 2> build.log)
  [ -f "$1/sim" ]
}

echo "== GREEN =="
D=.sim/pcm/green; rm -rf $D; mkdir -p $D/umd; cp $SRC $D/umd/
build $D || { echo "  FAIL build"; cat $D/build.log; exit 1; }
for run in "+seed=1" "+seed=2 +wait_pct=60" "+seed=3 +wait_pct=10" "+lat_min=60 +lat_max=200"; do
  # shellcheck disable=SC2086
  vvp -n $D/sim $run > $D/log 2>&1
  if grep -q "^PASS: pcm_shot_tb" $D/log; then echo "  PASS $run: $(grep '^pcm_shot_tb:' $D/log | sed 's/^pcm_shot_tb: //' | cut -c1-130)"
  else echo "  FAIL $run"; grep -m3 "FAIL" $D/log; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  mut() {   # name old new arm [runs...]
    local name=$1 old=$2 new=$3 arm=$4 d run hit=""; shift 4
    d=$(mktemp -d); mkdir -p "$d/umd"; cp $SRC "$d/umd/"
    if ! python3 - "$d/umd/pcm_shot.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    build "$d" || { echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; }
    for run in "$@"; do
      # shellcheck disable=SC2086
      vvp -n "$d/sim" $run > "$d/log" 2>&1
      grep -q "^PASS:" "$d/log" || { hit=$run; break; }
    done
    if [ -z "$hit" ]; then echo "  $name: SURVIVED -- the bench cannot see this defect"; fail=1
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then echo "  $name: caught ($hit) by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)"
    else echo "  $name: failed but NOT in [$arm]: $(grep -m1 "FAIL" "$d/log" | cut -c1-100)"; fail=1; fi
    rm -rf "$d"
  }
  R="+seed=1"; R2="+seed=2 +wait_pct=60"; R3="+lat_min=60 +lat_max=200"
  mut S1 "if (f_valid && f_dout[65:64] == gen) begin" "if (f_valid) begin" retrig "$R" "$R2" "$R3"
  mut S2 "                cw_v <= 1'b0; sub <= '0; started <= 1'b0;" "                sub <= '0; started <= 1'b0;" "retrig|stereo" "$R" "$R2" "$R3"
  mut S3 "            2'd1: s0 = st ? cw[47:32] : cw[31:16];" "            2'd1: s0 = st ? cw[31:16] : cw[31:16];" stereo "$R"
  mut S4 "                        pcm_r <= st ? s1 : s0;" "                        pcm_r <= s1;" mono "$R"
  mut S5 "                if (left == 24'd1) busy <= 1'b0;" "                if (left == 24'd0) busy <= 1'b0;" len "$R"
  mut S6 "else if (nco >= 11'd1123) begin nco <= nco - 11'd1123; tick <= 1'b1; end" "else if (nco >= 11'd1100) begin nco <= nco - 11'd1100; tick <= 1'b1; end" tick "$R"
  mut S7 "                busy    <= (hp_len != 24'd0);" "                busy    <= 1'b1;" "stop|harness" "$R"
  mut S8 ".din ({b_gen, ddr_readdata})" ".din ({m_gen, ddr_readdata})" retrig "$R3" "$R" "$R2"
fi

echo "== lint =="
if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-SYNCASYNCNET --top-module pcm_shot $SRC > .sim/pcm/lint.log 2>&1; then
  echo "  PASS verilator --lint-only -Wall"
else echo "  FAIL lint"; grep -m5 "%Warning\|%Error" .sim/pcm/lint.log; fail=1; fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
