#!/usr/bin/env bash
# run_vbuf.sh -- the compressed-video buffer (umd/vbuf.sv) through ddr_mux2's master B into
# bench/umd/ddr_model.sv beside a live master A (bench/umd/vbuf_tb.sv), scored against the
# stimulus list: every byte, mark and PTS; a mid-stream clear; the title's end; flow control.
# docs/h264_frontend.md "The compressed-video buffer".
#
# GREEN: three seeds, and a fourth with the port busy (+wait_pct=80) and the clear timed
# onto a read the port is holding off (+clear_held: the reload hang's shape).
# --red: mutations on a COPY, each caught by its own arm (seed 1):
#   V1 a stamp's position one byte late                     -> [mark]
#   V2 the stamp queue full no longer holds the source      -> [mark] (stamps lost)
#   V3 the clear leaves the engine's FIFO sides running     -> [clear] / [data] (stale words)
#   V4 the padding leaves (the limit ignores the title's end) -> [data] / [flush]
#   V5 the engine drops a held read command on a clear (arm 4) -> [avalon]
#   V6 no burst cut at the ring's end (a burst crosses it)  -> [data]
#   V7 no partial burst after IDLE_T (words stranded)       -> [live] / [flush]
#   V8 the ring-full check removed (the ring overruns)      -> [data]
#   V9  the item tag read from the wrong stamp bits (P6b3i)           -> [mark]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="umd/sfifo.sv umd/fifo_dc.sv umd/vbuf.sv umd/ddr_mux2.sv bench/umd/ddr_model.sv"
TB=bench/umd/vbuf_tb.sv

echo "== GREEN =="
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/vbuf_sim $RTL $TB 2>&1 | grep -v "sorry\|pop_front\|warning" | grep . && { echo "  FAIL build"; exit 1; }
ARGS=([1]="+seed=1" [2]="+seed=2" [3]="+seed=3" [4]="+seed=4 +wait_pct=80 +clear_held")
for s in 1 2 3 4; do
  # shellcheck disable=SC2086
  timeout 1800 vvp -n .sim/vbuf_sim ${ARGS[$s]} > .sim/vbuf_$s.log 2>&1 &
done
wait
for s in 1 2 3 4; do
  if grep -q "^PASS: vbuf_tb" .sim/vbuf_$s.log; then echo "  PASS seed $s: $(grep '^vbuf_tb:' .sim/vbuf_$s.log | sed 's/^vbuf_tb: //')"
  else echo "  FAIL seed $s: $(grep -m1 FAIL .sim/vbuf_$s.log)"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name old new arm-regex [arm number]
    local name=$1 old=$2 new=$3 pat=$4 arm=${5:-1}
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd" "$d/bench/umd"
    cp umd/sfifo.sv umd/fifo_dc.sv umd/vbuf.sv umd/ddr_mux2.sv "$d/umd/"
    cp bench/umd/ddr_model.sv $TB "$d/bench/umd/"
    python3 - "$d/umd/vbuf.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # shellcheck disable=SC2086
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    (cd "$d" && timeout 1800 vvp -n sim ${ARGS[$arm]} > log 2>&1)
    if grep -q "^PASS: vbuf_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL \[($pat)\]" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL \[($pat)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$pat]:"; grep -m2 "FAIL" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut V1 "din({in_ep, wpos[23:0], in_pts})" "din({in_ep, wpos[23:0] + 24'd1, in_pts})" "mark" &
  mut V2 "(held < CAP_BYTES) && !st_full &&" "(held < CAP_BYTES) &&" "mark" &
  mut V3 "ww <= '0; rw <= '0; m_frst_n <= 1'b0;" "ww <= '0; rw <= '0;" "clear|data" &
  mut V4 "wire  [31:0] lim = padded ? endpos : wpos;" "wire  [31:0] lim = wpos;" "data|flush" &
  wait
  mut V5 "E_RCMD: if (!b_waitrequest) begin" "E_RCMD: if (!b_waitrequest || req_m2) begin" "avalon" 4 &
  mut V6 "((pend_nx == 6'd8) || at_end ||" "((pend_nx == 6'd8) ||" "data" &
  mut V7 "|| (!wf_wr && idle_w >= IDLE_W));" ");" "live|flush" &
  mut V8 "assign in_ready = run && (held < CAP_BYTES) &&" "assign in_ready = run &&" "data" &
  mut V9 "assign out_ep    = st_head[58:57];" "assign out_ep    = st_head[57:56];" "mark" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
