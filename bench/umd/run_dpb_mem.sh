#!/usr/bin/env bash
# run_dpb_mem.sh -- the memory plumbing gate: umd/sfifo.sv (bench/umd/sfifo_tb.sv) and
# umd/h264/dpb_mem.sv on two real clocks against bench/umd/ddr_model.sv
# (bench/umd/dpb_mem_tb.sv). docs/h264_recon.md S2.2.
#
# GREEN: sfifo_tb (every word in order, count/full honest, a pop every cycle when fed);
# dpb_mem_tb (every read beat equals the scoreboard, byte enables honoured, command
# order kept, the DDR model's rules held -- no write during outstanding reads, no read
# without credit -- and 192 pipelined beats within 4 clk cycles per beat).
#
# --red: mutations on a COPY of the RTL, each caught by its own arm:
#   F1  sfifo: the skid-room check off by one (a landing word overwrites the head) -> [order]
#       (re-anchored at the clk_dec 103.85 retime: rd_ok's no-pop case, room_nop)
#   F3  sfifo: full rises a cycle late (the last free slot's write not seen)        -> [order]/[count]
#   F4  sfifo: full ignores a same-cycle read (clears a cycle late: one refused push -> [rate]
#       each time the RAM tops out; caught by one push, deterministically)
#   F2  sfifo: count not decremented on a pop                                       -> [count]
#   M1  dpb_mem: a write no longer waits for outstanding reads                      -> [ddr] (the model's rule)
#   M2  dpb_mem: the read credit ignored                                             -> [data] (the stalled-consumer phase overflows the read FIFO)
#   M3  dpb_mem: byte enables forced to all ones                                     -> [data]
#   M4  dpb_mem: reads serialised (wait for the burst to return before the next)     -> [rate]
#   M5  dpb_mem: burstcount sent as 1 for every read                                 -> [count]/[data]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
RTL="umd/fifo_dc.sv umd/sfifo.sv umd/h264/dpb_mem.sv"
MODEL=bench/umd/ddr_model.sv

echo "== GREEN: sfifo =="
rm -f .sim/sfifo_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/sfifo_sim umd/sfifo.sv bench/umd/sfifo_tb.sv 2>&1 | grep -v sorry
if [ -f .sim/sfifo_sim ] && vvp -n .sim/sfifo_sim > .sim/sfifo.log 2>&1 && grep -q "^PASS: sfifo_tb" .sim/sfifo.log; then
  echo "  PASS sfifo_tb: $(grep '^sfifo_tb:' .sim/sfifo.log | sed 's/^sfifo_tb: //')"
else echo "  FAIL sfifo_tb"; grep FAIL .sim/sfifo.log | head -3; fail=1; fi

echo "== GREEN: dpb_mem =="
# shellcheck disable=SC2086
rm -f .sim/dpbmem_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/dpbmem_sim $RTL $MODEL bench/umd/dpb_mem_tb.sv 2>&1 | grep -v sorry
if [ -f .sim/dpbmem_sim ] && vvp -n .sim/dpbmem_sim > .sim/dpbmem.log 2>&1 && grep -q "^PASS: dpb_mem_tb" .sim/dpbmem.log; then
  echo "  PASS dpb_mem_tb: $(grep '^dpb_mem_tb: .*writes' .sim/dpbmem.log | sed 's/^dpb_mem_tb: //')"
else echo "  FAIL dpb_mem_tb"; grep FAIL .sim/dpbmem.log | head -3; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new tb arm(s regex)
    local name=$1 file=$2 old=$3 new=$4 tb=$5 arm=$6
    local d; d=$(mktemp -d)
    cp $RTL $MODEL "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local files=""; for f in $RTL $MODEL; do files="$files $d/$(basename "$f")"; done
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! iverilog -g2012 -o "$d/sim" $files "$tb" 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 600 vvp -n "$d/sim" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  ST=bench/umd/sfifo_tb.sv; MT=bench/umd/dpb_mem_tb.sv
  mut F1 umd/sfifo.sv "wire room_nop = (sk_land <= 3'd1);" "wire room_nop = (sk_land <= 3'd2);" $ST "order|count" &
  mut F3 umd/sfifo.sv "full  <= !rd_ok && (at_top || (at_top1 && wr_ok));" "full  <= !rd_ok && at_top;" $ST "order|count" &
  mut F4 umd/sfifo.sv "full  <= !rd_ok && (at_top || (at_top1 && wr_ok));" "full  <= at_top || (at_top1 && wr_ok);" $ST "count|rate" &
  mut F2 umd/sfifo.sv "count <= count + {{(AW+1){1'b0}}, wr_ok} - {{(AW+1){1'b0}}, pop};" "count <= count + {{(AW+1){1'b0}}, wr_ok};" $ST "count" &
  mut M1 umd/h264/dpb_mem.sv "(!c_write ? credit_ok : (outstanding == '0 && !ddr_readdatavalid));" "(!c_write ? credit_ok : 1'b1);" $MT "ddr" &
  mut M2 umd/h264/dpb_mem.sv "(!c_write ? credit_ok : (outstanding == '0 && !ddr_readdatavalid));" "(!c_write ? 1'b1 : (outstanding == '0 && !ddr_readdatavalid));" $MT "ddr|data|order" &
  mut M3 umd/h264/dpb_mem.sv "ddr_writedata <= wf_dout[63:0]; ddr_byteenable <= wf_dout[71:64];" "ddr_writedata <= wf_dout[63:0]; ddr_byteenable <= 8'hFF;" $MT "data" &
  mut M4 umd/h264/dpb_mem.sv "(!c_write ? credit_ok : (outstanding == '0 && !ddr_readdatavalid));" "(!c_write ? (credit_ok && outstanding == '0) : (outstanding == '0 && !ddr_readdatavalid));" $MT "rate" &
  mut M5 umd/h264/dpb_mem.sv "ddr_read <= 1'b1; ddr_address <= c_addr; ddr_burstcount <= {4'd0, c_len};" "ddr_read <= 1'b1; ddr_address <= c_addr; ddr_burstcount <= 8'd1;" $MT "count|data|hang" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
