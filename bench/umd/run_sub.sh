#!/usr/bin/env bash
# run_sub.sh -- the subtitle chain's gate (umd/sub/: sub_in, sub_unit, sub_ring, sub_sched,
# sub_mem, sub_top; docs/subtitles.md §4). Since A7 (docs/hps_host.md §3.2) the decode is the
# HPS's: the benches' host is bench/umd/mock_host.svh (the units read back from DDR3 and
# checked, the golden planes written, completions after a latency); the C decoder itself is
# bench/umd/run_hps_sub.sh's. Goldens: tools/sub_golden.py -- the units
# tools/umd_sub_extract.py finds (the tool that measured every disc), their PNG bytes, and
# libpng's pixels premultiplied into the plane.
#
# GREEN:
#   sub_unit_tb   PES payloads -> units vs the tool: six synthetic streams (continuations,
#                 truncation, overrun, orphans, a gap, refusals, a bad header), straight and
#                 under stalls; with $UMD_ISO_DIR Akira's and The Mummy's whole tracks
#   sub_ring_tb   sub_unit -> the DDR3 ring (32 KB: it wraps) -> a host that reads each unit
#                 out of DDR3: straight, stalled, the host held (the refusals follow the
#                 admission rule), a flush mid-stream, and a host that holds each unit 3 ms
#                 (the demux writes on: the unit's words must stay until it completes)
#   sub_top_tb    end to end on two clocks, the STC at the real rate, the mock host: synthetic
#                 (RGBA8, Adam7, RGB16, clipped at two edges, a refused PNG; and a stale
#                 completion) and with $UMD_ISO_DIR Akira's first 12 units and The Mummy's
#                 tightest window (a 0.1 s unit, then a 583x275 one) with the host at 30 ms
#                 (B2's measured worst, rounded up); every plane word vs the golden, never
#                 early, [tear] never a write into the plane on screen
#   sub_ram2_tb   the raster readers' line fetches (the video's 180 words, the plane's 720:
#                 two whole rows) through umd/rd_merge2.sv and ddr_mux2 (B_FIRST) against a
#                 subtitle master that never stops: every line inside its 2,860 cycles, the
#                 master >= 32 words a line, every beat to its owner; twice (the model's
#                 default and a slow one); and the merge alone on a slow model (DIRECT)
#   lint          verilator -Wall over umd/sub/
# --red: mutations on a COPY (compiled inside it), each caught by its own arm.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
ROOT=$(pwd)
GEN=bench/umd/fixtures/gen/sub
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
SUB="umd/png/png_pkg.sv umd/png/inflate.sv umd/png/png_chunks.sv umd/png/png_unfilter.sv umd/png/png_pixel.sv umd/png/png_top.sv umd/sub/sub_png.sv umd/sub/sub_plane_wr.sv umd/sub/sub_dec.sv umd/fifo_dc.sv umd/cdc.sv umd/sub/sub_q.sv umd/sub/sub_in.sv umd/sub/sub_unit.sv umd/sub/sub_ring.sv umd/sub/sub_sched.sv umd/sub/sub_mem.sv umd/sub/sub_top.sv"
mkdir -p "$GEN"

echo "== fixtures =="
AK=$(find "$ISO_DIR" -maxdepth 1 -iname 'akira*.iso' 2>/dev/null | head -1)
MU=$(find "$ISO_DIR" -maxdepth 1 -iname 'the mummy (1999).iso' 2>/dev/null | head -1)
python3 -W ignore tools/sub_golden.py units --out $GEN --list u_synth --synth > .sim/sub_golden.log 2>&1 || { echo "  FAIL golden"; tail -3 .sim/sub_golden.log; exit 1; }
python3 -W ignore tools/sub_golden.py e2e --out $GEN --list e_synth --synth >> .sim/sub_golden.log 2>&1 || { echo "  FAIL golden"; tail -3 .sim/sub_golden.log; exit 1; }
DISCS=0
if [ -n "$AK" ] && [ -n "$MU" ]; then
  python3 -W ignore tools/sub_golden.py units --out $GEN --list u_discs --disc "$AK:1:0x80" --disc "$MU:1:0x8b" >> .sim/sub_golden.log 2>&1 \
  && python3 -W ignore tools/sub_golden.py units --out $GEN --list u_akira --disc "$AK:1:0x80" >> .sim/sub_golden.log 2>&1 \
  && python3 -W ignore tools/sub_golden.py e2e --out $GEN --list e_akira --units 12 --disc "$AK:1:0x80" >> .sim/sub_golden.log 2>&1 \
  && python3 -W ignore tools/sub_golden.py e2e --out $GEN --list e_mummy --units 8 --skip 22 --disc "$MU:1:0x8b" >> .sim/sub_golden.log 2>&1 \
  && DISCS=1 || { echo "  FAIL disc goldens"; tail -3 .sim/sub_golden.log; fail=1; }
else
  echo "  SKIP disc cases: no Akira / The Mummy (1999) image in \$UMD_ISO_DIR ($ISO_DIR)"
fi
grep "^sub_golden" .sim/sub_golden.log | sed 's/^/  /'

build() {   # DIR OUT TB [iverilog -P...] -- compiled from inside DIR (a mutant's copy, or the tree)
  local d=$1 out=$2 tb=$3; shift 3
  # shellcheck disable=SC2086
  (cd "$d" && iverilog -g2012 "$@" -o "$out" $SUB umd/ddr_mux2.sv umd/rd_merge2.sv "$ROOT/bench/umd/ddr_model.sv" "$ROOT/bench/umd/$tb" 2>&1 \
     | grep -v "sorry: constant\|pop_front") > /dev/null
  [ -f "$out" ]
}
runsim() {  # SIM ARGS... -> the log on stdout
  vvp -n "$@" 2>&1 | grep -v 'readmem\|Not enough words'
}
report() {  # LABEL BENCH SIM ARGS...
  local label=$1 bench=$2; shift 2
  runsim "$@" > .sim/sub_last.log
  if grep -q "^PASS: $bench" .sim/sub_last.log; then
    echo "  PASS $label: $(grep "^$bench:" .sim/sub_last.log | tail -1 | sed "s/^$bench: //" | cut -c1-150)"
  else echo "  FAIL $label"; grep "FAIL\|FATAL" .sim/sub_last.log | head -3; fail=1; fi
}

echo "== GREEN =="
for tb in sub_unit_tb sub_ring_tb sub_top_tb sub_ram2_tb sub_dec_tb; do
  build "$ROOT" "$ROOT/.sim/$tb.vvp" "$tb.sv" || { echo "  FAIL $tb: build"; exit 1; }
done
# the ring with a 64-unit queue: held, its ROOM binds before the queue's depth
build "$ROOT" "$ROOT/.sim/sub_ring_tb_q64.vvp" sub_ring_tb.sv -Psub_ring_tb.MAW=6 || { echo "  FAIL sub_ring_tb (MAW 6): build"; exit 1; }
# the read merge alone on the model: its own owner-FIFO guard is what binds
build "$ROOT" "$ROOT/.sim/sub_ram2_tb_direct.vvp" sub_ram2_tb.sv -Psub_ram2_tb.DIRECT=1 || { echo "  FAIL sub_ram2_tb (DIRECT): build"; exit 1; }
report "sub_unit synthetic" sub_unit_tb .sim/sub_unit_tb.vvp +list=$GEN/u_synth.txt
report "sub_unit synthetic +stall" sub_unit_tb .sim/sub_unit_tb.vvp +list=$GEN/u_synth.txt +stall=1
report "sub_ring synthetic" sub_ring_tb .sim/sub_ring_tb.vvp +list=$GEN/u_synth.txt
report "sub_top synthetic" sub_top_tb .sim/sub_top_tb.vvp +list=$GEN/e_synth.txt
report "sub_top synthetic, a stale completion" sub_top_tb .sim/sub_top_tb.vvp +list=$GEN/e_synth.txt +stale=1
report "sub_ram2" sub_ram2_tb .sim/sub_ram2_tb.vvp
report "sub_dec synthetic (A12 SD1: the fabric decode vs libpng)" sub_dec_tb .sim/sub_dec_tb.vvp +stem=$(cat $GEN/e_synth.txt)
report "sub_dec synthetic, flushed mid-decode" sub_dec_tb .sim/sub_dec_tb.vvp +stem=$(cat $GEN/e_synth.txt) +flush=1
report "sub_ram2 (70 % waits, latency 20-120)" sub_ram2_tb .sim/sub_ram2_tb.vvp +wait_pct=70 +lat_min=20 +lat_max=120
report "sub_ram2 the merge alone (latency 150-200)" sub_ram2_tb .sim/sub_ram2_tb_direct.vvp +a_floor=0 +lat_min=150 +lat_max=200
if [ $DISCS = 1 ]; then
  report "sub_unit Akira + The Mummy tracks" sub_unit_tb .sim/sub_unit_tb.vvp +list=$GEN/u_discs.txt
  report "sub_ring Akira" sub_ring_tb .sim/sub_ring_tb.vvp +list=$GEN/u_akira.txt
  report "sub_ring Akira +stall" sub_ring_tb .sim/sub_ring_tb.vvp +list=$GEN/u_akira.txt +stall=1
  report "sub_ring Akira held (the queue's depth binds)" sub_ring_tb .sim/sub_ring_tb.vvp +list=$GEN/u_akira.txt +hold=1
  report "sub_ring Akira held, 64-unit queue (the ring's room binds)" sub_ring_tb .sim/sub_ring_tb_q64.vvp +list=$GEN/u_akira.txt +hold=1
  report "sub_ring Akira held + flush" sub_ring_tb .sim/sub_ring_tb.vvp +list=$GEN/u_akira.txt +hold=1 +flush_after=300000
  report "sub_ring Akira, the host holding each unit 3 ms, 64-unit queue" sub_ring_tb .sim/sub_ring_tb_q64.vvp +list=$GEN/u_akira.txt +hostlat=300000
  report "sub_top Akira 12 units" sub_top_tb .sim/sub_top_tb.vvp +list=$GEN/e_akira.txt
  report "sub_dec Akira 12 units" sub_dec_tb .sim/sub_dec_tb.vvp +stem=$(cat $GEN/e_akira.txt)
  report "sub_dec Akira, flushed mid-decode" sub_dec_tb .sim/sub_dec_tb.vvp +stem=$(cat $GEN/e_akira.txt) +flush=1
  report "sub_dec The Mummy's tightest window" sub_dec_tb .sim/sub_dec_tb.vvp +stem=$(cat $GEN/e_mummy.txt)
  report "sub_top The Mummy 0.1 s window, the host at 30 ms" sub_top_tb .sim/sub_top_tb.vvp +list=$GEN/e_mummy.txt +host_lat=2700000
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arms bench args...
    local name=$1 file=$2 old=$3 new=$4 arms=$5 bench=$6; shift 6
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/sub" "$d/umd/png" "$d/bench/umd"
    cp umd/png/*.sv "$d/umd/png/"
    cp umd/sub/*.sv "$d/umd/sub/"; cp umd/fifo_dc.sv umd/cdc.sv umd/ddr_mux2.sv umd/rd_merge2.sv "$d/umd/"
    cp bench/umd/mock_host.svh "$d/bench/umd/"
    if ! python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then { echo "  $name: harness failure (anchor)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    local pv=""; [ "$name" = R2 ] || [ "$name" = R4 ] && pv="-Psub_ring_tb.MAW=6"      # where the ring's room binds
    [ "$name" = G2 ] && pv="-Psub_ram2_tb.DIRECT=1"                    # where the merge's own guard binds
    # shellcheck disable=SC2086
    if ! build "$d" "$d/sim" "$bench.sv" $pv; then { echo "  $name: harness failure (build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    runsim "$d/sim" "$@" > "$d/log"
    if grep -q "^PASS:" "$d/log"; then { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "^FAIL \[($arms)\]" "$d/log"; then echo "  $name: caught by $(grep -Em1 "^FAIL \[($arms)\]" "$d/log" | cut -c1-130)" > "$RES/$name"
    else { echo "  $name: failed but NOT in [$arms]: $(grep -m1 "FAIL\|FATAL\|rror" "$d/log" | cut -c1-130)"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  P=0
  go() { mut "$@" & P=$((P + 1)); if [ $P -ge 6 ]; then wait; P=0; fi; }
  U=+list=$GEN/u_synth.txt; E=+list=$GEN/e_synth.txt
  # sub_unit
  go S1 umd/sub/sub_unit.sv "if (cur) begin state <= U_REPLAY; rk <= 5'd0; end" "if (1'b0) begin state <= U_REPLAY; rk <= 5'd0; end" "unit|count" sub_unit_tb $U
  go S2 umd/sub/sub_unit.sv "!cur && ovr_arm) n_overrun <= n_overrun + 16'd1;" "!cur && ovr_arm) n_overrun <= n_overrun;" count sub_unit_tb $U
  go S3 umd/sub/sub_unit.sv "if (s_gap && cur) begin cur <= 1'b0; u_abort <= 1'b1; n_lost <= n_lost + 16'd1; end" \
                            "if (1'b0) begin cur <= 1'b0; u_abort <= 1'b1; n_lost <= n_lost + 16'd1; end" "unit|count" sub_unit_tb $U
  # sub_ring
  go R1 umd/sub/sub_ring.sv "wire  [63:0]   wword    = wacc | ({56'd0, u_byte} << {wbi, 3'b000});" \
                            "wire  [63:0]   wword    = wacc | ({56'd0, u_byte} << {~wbi, 3'b000});" unit sub_ring_tb $U
  if [ $DISCS = 1 ]; then
    go R2 umd/sub/sub_ring.sv "({{(32 - PW){1'b0}}, free_w} >= need_w);" "1'b1;" "count|unit" sub_ring_tb +list=$GEN/u_akira.txt +hold=1
    go R3 umd/sub/sub_ring.sv "(fcnt == 4'd7 || u_last || wr_ptr_n[RAW-1:0] == '0);" "(fcnt == 4'd7 || u_last);" "unit|ddr" sub_ring_tb +list=$GEN/u_akira.txt
    # A7: the unit's words freed at the request, not at the completion: the demux overwrites
    # them while the host still reads (docs/hps_host.md §3.2)
    go R4 umd/sub/sub_ring.sv "                r_end   <= q_start_p + q_words[PW-1:0];" \
                              "                r_end   <= q_start_p + q_words[PW-1:0]; tail <= q_start_p + q_words[PW-1:0];" unit sub_ring_tb +list=$GEN/u_akira.txt +hostlat=300000
  fi
  # A7: the host's completion taken whatever its seq (a stale one: a dropped request's)
  go K1 umd/sub/sub_top.sv "(c_seq == h_seq)" "1'b1" stale sub_top_tb $E +stale=1
  # the scheduler
  go T1 umd/sub/sub_sched.sv "wire         at_pts = stc_valid && !d_pts[32];" "wire         at_pts = stc_valid;" time sub_top_tb $E
  go T2 umd/sub/sub_sched.sv "wire         at_fe  = stc_valid && !d_fe[32];" "wire         at_fe  = stc_valid;" time sub_top_tb $E
  # the host told to decode into the plane on screen: [tear] (the mock host writes where it is told)
  go T3 umd/sub/sub_sched.sv "assign wr_buf  = !front;" "assign wr_buf  = front;" "tear|plane" sub_top_tb $E
  # the output register held while the port holds its command off (ddr_model's [avalon] rule)
  go M2 umd/sub/sub_mem.sv "wire        take      = !o_v || !ddr_waitrequest;" "wire        take      = 1'b1;" avalon sub_top_tb $E
  go X1 umd/ddr_mux2.sv "if (b_req && !orphan && ((a_rd_acc) || (a_wr_acc && a_wburst == 8'd1) || (a_wr_acc && ddr_burstcount == 8'd1 && a_wburst == 8'd0) || a_idle || (a_wr_blocked && (!b_cut || B_FIRST))))" \
                        "if (b_req && !orphan && a_idle)" latency sub_ram2_tb
  # B_FIRST: B cuts in ahead of a blocked A write only once (the alternation), under the slow model
  go X2 umd/ddr_mux2.sv "(a_wr_blocked && (!b_cut || B_FIRST))))" "(a_wr_blocked && !b_cut)))" \
                        latency sub_ram2_tb +wait_pct=70 +lat_min=20 +lat_max=120
  # the read merge: its own FIFO guard (alone on the model: the model's credit rule or a misrouted beat)
  go G2 umd/rd_merge2.sv "wire         own_full  = o_cnt[4];" "wire         own_full  = 1'b0;" "data|ddr" sub_ram2_tb +a_floor=0 +lat_min=150 +lat_max=200
  go G3 umd/rd_merge2.sv "own[o_wr] <= sel;" "own[o_wr] <= !sel;" data sub_ram2_tb
  # A12 SD1: the fabric decoder (sub_dec) and its share of the master (sub_mem), against libpng
  DS=+stem=$(cat $GEN/e_synth.txt)
  go D1 umd/sub/sub_dec.sv "wire  [7:0]  b_byte  = fq[fq_rp][{bi, 3'b000} +: 8];" "wire  [7:0]  b_byte  = fq[fq_rp][{~bi, 3'b000} +: 8];" "done|plane" sub_dec_tb $DS
  go D3 umd/sub/sub_dec.sv "drain <= 1'b1;" "drain <= 1'b0;" "done|plane|flush|hang" sub_dec_tb $DS +flush=1
  go D4 umd/sub/sub_dec.sv "<= 7'd8;" "<= 7'd16;" "done|plane|hang" sub_dec_tb $DS
  go D5 umd/sub/sub_dec.sv "h_done <= 1'b1; h_done_seq <= cur_seq; h_done_err <= e_err;" "h_done <= 1'b1; h_done_seq <= cur_seq; h_done_err <= 5'd0;" done sub_dec_tb $DS
  go D6 umd/sub/sub_dec.sv "!(done_v && h_seq == done_seq);" "1'b1;" "done|hang" sub_dec_tb $DS
  go D7 umd/sub/sub_mem.sv "wire w_ok = w_write && no_reads;" "wire w_ok = w_write;" "avalon|ddr|done|plane" sub_dec_tb $DS
  if [ $DISCS = 1 ]; then
    # a burst past the ring's end (a unit that wraps: The Mummy's units fill the 32 KB ring)
    go D2 umd/sub/sub_dec.sv "wire [31:0]   b_lim  = (to_end < 'd8) ? {{(31-RAW){1'b0}}, to_end} : 32'd8;" "wire [31:0]   b_lim  = 32'd8;" "done|plane|ddr" sub_dec_tb $DS
  fi
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

echo "== lint =="
# shellcheck disable=SC2086
if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET --top-module sub_top $SUB > .sim/sub_lint.log 2>&1; then
  echo "  PASS verilator --lint-only -Wall"
else echo "  FAIL lint"; grep -m8 "%Warning\|%Error" .sim/sub_lint.log; fail=1; fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
