#!/usr/bin/env bash
# run_plane.sh -- the overlay plane compositor's gate (docs/compositor.md): umd/plane_reader.sv
# (a premultiplied plane from ram2, bilinear, 1:1 as its pass-through), umd/plane_blend.sv,
# umd/sub/sub_flip.sv (the subtitle plane's flips latched in the vertical blank),
# umd/rd_merge2.sv (the video and the plane on ram2's B side) and umd/ddr_mux2.sv's
# B_FIRST, composed as emu will compose them with the video from umd/disp_reader.sv
# (bench/umd/plane_tb.sv). Goldens: tools/disp_golden.py (the video), tools/plane_golden.py
# (the planes and composites; it bounds its fixed-point bilinear against float bilinear
# and PIL, and its blend against PIL's alpha_composite, and says so).
#
# GREEN:
#   plane_tb (sub)    the subtitle plane at 1:1: flip, flip (clipped at two edges), hide the
#                     cycle after the flip's ack, each raised mid-frame; 3 frames, every dot of
#                     the plane and of the composite exact; latched at the blank, acked after it
#   plane_tb +scale   480x272 up to the raster, a placed downscale, a refused geometry
#   plane_tb +il      (SCALE 0, sub) the 480i raster (docs/analog.md): both fields, both dots
#                     of every pixel; the flip at the bottom field's blank
#   lint              verilator -Wall over the four modules
# --red: mutations on a COPY (compiled inside it), each caught by its own arm, and one
# control (the DDR3 model 2,000 cycles slow: the [late] arm must fire):
#   L1  reader: the right neighbour of an odd column read at its own word      -> [scale]
#   L2  reader: the vertical weight from the other line's half                  -> [scale]
#   L3  reader: the column's parity ignored (the even bank always)              -> [pass]
#   L4  reader: an odd rectangle's first word skipped                           -> [pass]
#   L5  reader: the row below never fetched                                     -> [scale]
#   L6  reader: a negative position not clamped                                 -> [scale]
#   L7  reader: the rectangle one dot wider                                     -> [pass]
#   L8  reader: the vertical rounding (+32768) dropped                          -> [scale]
#   L9  reader: a source past the 720-pixel row not refused                     -> [geo]
#   B1  blend: red's rounding (+128) dropped                                    -> [blend]
#   B2  blend: no clip (an additive pixel wraps)                                -> [blend]
#   F1  flip: latched at once, not at the blank                                 -> [flip]
#   SI1 reader (480i): a field's next line one below, not two                   -> [pass]
#   SI2 reader (480i): the line buffer's half by v_pos[0] (every line the same)  -> [pass]
#   SI3 reader (480i): the column not halved (h_pos read as pixels)             -> [pass]
#   SI4 reader (480i): the fields' first lines swapped (523 / 524)              -> [pass]
#   F2  flip: d_req taken again in its ack cycle (the old request twice)        -> [flip]
#       (the old rectangle latched in the next request's place)
#   F3  flip: the rectangle not clipped to the frame                            -> [clip]
#   G1  merge: the choice not held under waitrequest                            -> [proto] / [avalon]
# P9, the plane's hand-over to the host (bench/umd/sub_flip_tb.sv, docs/p9.md §3.2 item 4):
#   sub_flip_tb       subtitles applied without ui; under ui acknowledged, not applied; the
#                     host's flips (clipped, one ack each, none without ui); hidden at ui's edges
#   U1  a subtitle request applied (and counted) under ui                      -> [ui]
#   U2  a subtitle request under ui never acknowledged (sub_sched waits)        -> [ui]
#   U3  a host flip applied without ui                                         -> [host]
#   U4  the host's flip acknowledged at every vbl, not once                    -> [host]
#   U5  ui's change does not hide (the subtitle under the menu, the page after)  -> [hide]
#   U6  the change's hide applied after the host flip (a blank first frame)    -> [hide]
# P6d, the panel's mode (docs/panel.md §2):
#   U7  ui_sub does not give the host the plane                                 -> [panel]
#   U8  ui_sub's fall hides instead of restoring the subtitle                   -> [panel]
#   U9  the kept state misses a hide made during ui_sub                         -> [panel]
#   U10 a menu's close (ui) restores a subtitle too                             -> [hide] / [panel]
#   U11 plane 3 addressed as plane 2                                            -> [panel]
#   U12 the host's flip not clipped (its own clip path)                         -> [host]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
ROOT=$(pwd)
RTL="umd/sync_gen.sv umd/disp_reader.sv umd/ddr_mux2.sv umd/rd_merge2.sv umd/plane_reader.sv umd/plane_blend.sv umd/sub/sub_flip.sv"

echo "== fixtures =="
python3 tools/disp_golden.py > /dev/null || { echo "  FAIL disp golden"; exit 1; }
python3 tools/plane_golden.py > .sim/plane_golden.log 2>&1 || { echo "  FAIL plane golden"; tail -3 .sim/plane_golden.log; exit 1; }
sed 's/^/  /' .sim/plane_golden.log

build() {   # DIR OUT [iverilog -P...] -- compiled from inside DIR (a mutant's copy, or the tree)
  local d=$1 out=$2; shift 2
  # shellcheck disable=SC2086
  (cd "$d" && iverilog -g2012 "$@" -o "$out" $RTL "$ROOT/bench/umd/ddr_model.sv" "$ROOT/bench/umd/plane_tb.sv" 2>&1 \
     | grep -v "sorry: constant\|pop_front") > /dev/null
  [ -f "$out" ]
}
runsim() {  # SIM ARGS... -> the log on stdout (run from the tree: the fixtures are relative)
  vvp -n "$@" 2>&1 | grep -v 'readmem\|Not enough words'
}
score() {  # LABEL LOG
  if grep -q "^PASS: plane_tb" "$2"; then
    echo "  PASS $1: $(grep "^plane_tb:" "$2" | tail -1 | sed "s/^plane_tb: //" | cut -c1-150)"
  else echo "  FAIL $1"; grep "FAIL\|FATAL" "$2" | head -3; fail=1; fi
}

echo "== GREEN =="
build "$ROOT" "$ROOT/.sim/plane_tb.vvp" || { echo "  FAIL plane_tb: build"; exit 1; }
# SCALE 0: the 1:1 reader the subtitle plane instantiates (docs/area_plan.md A3), sub mode
build "$ROOT" "$ROOT/.sim/plane_tb_s0.vvp" -Pplane_tb.P_SCALE=0 || { echo "  FAIL plane_tb (SCALE 0): build"; exit 1; }
runsim .sim/plane_tb.vvp > .sim/plane_sub.log &
runsim .sim/plane_tb.vvp +scale > .sim/plane_scale.log &
runsim .sim/plane_tb_s0.vvp > .sim/plane_sub_s0.log &
runsim .sim/plane_tb_s0.vvp +il > .sim/plane_sub_il.log &
wait
score "plane_tb sub (1:1)" .sim/plane_sub.log
score "plane_tb scale" .sim/plane_scale.log
score "plane_tb sub on the 1:1 reader (SCALE 0)" .sim/plane_sub_s0.log
score "plane_tb sub at 480i (SCALE 0)" .sim/plane_sub_il.log
# P9: the hand-over
sfbuild() { (cd "$1" && iverilog -g2012 -o "$2" umd/sub/sub_flip.sv "$ROOT/bench/umd/sub_flip_tb.sv" 2>&1) > /dev/null; [ -f "$2" ]; }
sfbuild "$ROOT" "$ROOT/.sim/sub_flip_tb.vvp" || { echo "  FAIL sub_flip_tb: build"; exit 1; }
vvp -n .sim/sub_flip_tb.vvp > .sim/sub_flip.log 2>&1
if grep -q "^PASS: sub_flip_tb" .sim/sub_flip.log; then echo "  PASS sub_flip_tb: $(grep '^sub_flip_tb:' .sim/sub_flip.log | sed 's/^sub_flip_tb: //' | cut -c1-150)"
else echo "  FAIL sub_flip_tb"; grep -m3 "FAIL" .sim/sub_flip.log; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arms args...
    local name=$1 file=$2 old=$3 new=$4 arms=$5; shift 5
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/sub"
    cp umd/*.sv umd/*.vh "$d/umd/"; cp umd/sub/sub_flip.sv "$d/umd/sub/"   # (the .vh: sync_gen includes field_polarity.vh)
    if ! python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then { echo "  $name: harness failure (anchor)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    local pv=""; case $name in S*) pv="-Pplane_tb.P_SCALE=0";; esac   # the 1:1 reader's own arms
    # shellcheck disable=SC2086
    if ! build "$d" "$d/sim" $pv; then { echo "  $name: harness failure (build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    runsim "$d/sim" "$@" > "$d/log"
    if grep -q "^PASS:" "$d/log"; then { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "^FAIL \[($arms)\]" "$d/log"; then echo "  $name: caught by $(grep -Em1 "^FAIL \[($arms)\]" "$d/log" | cut -c1-130)" > "$RES/$name"
    else { echo "  $name: failed but NOT in [$arms]: $(grep -m1 "FAIL\|FATAL\|rror" "$d/log" | cut -c1-130)"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  P=0
  go() { mut "$@" & P=$((P + 1)); if [ $P -ge 4 ]; then wait; P=0; fi; }
  R=umd/plane_reader.sv
  go L1 $R "wire  [9:0]  col_e = s2_col + 10'd1;" "wire  [9:0]  col_e = s2_col;" scale +scale
  go L2 $R "s3_fy <= fy_h[s2_half];" "s3_fy <= fy_h[!s2_half];" scale +scale
  go L3 $R "s3_odd <= s2_col[0];" "s3_odd <= 1'b0;" pass
  go L4 $R "w0 <= m_sx[9:1];" "w0 <= m_sx[9:1] + {8'd0, m_sx[0]};" pass
  go L5 $R "req_need_b <= (rq_fy != 8'd0);" "req_need_b <= 1'b0;" scale +scale
  go L6 $R "if (x1[27]) begin s2_col <= sx; s2_fx <= 8'd0; end" "if (1'b0) begin s2_col <= sx; s2_fx <= 8'd0; end" scale +scale
  go L7 $R "wire         in_x = (hp >= {2'd0, dx}) && (hp < dxe);" "wire         in_x = (hp >= {2'd0, dx}) && (hp <= dxe);" pass
  go L8 $R "vv[c] = {1'b0, top[c], 8'd0} + pv[c][24:0] + 25'd32768;" "vv[c] = {1'b0, top[c], 8'd0} + pv[c][24:0] + 25'd0;" scale +scale
  go L9 $R "(sxe > 11'd720)" "(sxe > 11'd1023)" geo +scale
  # SCALE 0 (the 1:1 reader): the column and the row come from the raster, not the accumulators
  go S1 $R "wire  [11:0] h_rel = hp - {2'd0, dx};" "wire  [11:0] h_rel = hp - {2'd0, dx} + 12'd1;" pass
  go SI1 $R "(v_pos == 12'd524) ? 9'd1 : v_pos[8:0] + 9'd2;" "(v_pos == 12'd524) ? 9'd1 : v_pos[8:0] + 9'd1;" pass +il
  go SI2 $R "wire         lsel = il ? v_pos[1] : v_pos[0];" "wire         lsel = v_pos[0];" pass +il
  go SI3 $R "wire  [11:0] hp   = il ? {1'b0, h_pos[11:1]} : h_pos;" "wire  [11:0] hp   = h_pos;" pass +il
  go SI4 $R "rq_n <= (v_pos == 12'd523) ? 9'd0 : (v_pos == 12'd524) ? 9'd1 :" "rq_n <= (v_pos == 12'd523) ? 9'd1 : (v_pos == 12'd524) ? 9'd0 :" pass +il
  go S2 $R "y1 <= {3'd0, rq_n - dy, 16'd0};" "y1 <= {3'd0, rq_n - dy + 9'd1, 16'd0};" pass
  go B1 umd/plane_blend.sv "wire [15:0] u_r = t_r + 16'd128," "wire [15:0] u_r = t_r + 16'd0," blend
  go B2 umd/plane_blend.sv "r <= m_r[8] ? 8'd255 : m_r[7:0];" "r <= m_r[7:0];" blend +scale
  go F1 umd/sub/sub_flip.sv "            if (vbl) begin
                // a change of owner" "            if (1'b1) begin
                // a change of owner" flip
  go F2 umd/sub/sub_flip.sv "if (!busy && d_req && !d_ack) begin" "if (!busy && d_req) begin" flip
  go F3 umd/sub/sub_flip.sv "wire  [15:0] m_cw = (m_xe > 17'd720) ? 16'd720 - hx : hw;" "wire  [15:0] m_cw = hw;" clip
  # (ddr_model's own [avalon] rule, main's since PR fj#11, sees this at the port first)
  go G1 umd/rd_merge2.sv "wire sel = held ? hsel : !p_read;" "wire sel = !p_read;" "proto|avalon"
  wait
  # P9: the hand-over, on sub_flip_tb
  umut() {   # name old new arms
    local name=$1 old=$2 new=$3 arms=$4 d; d=$(mktemp -d); mkdir -p "$d/umd/sub"; cp umd/sub/sub_flip.sv "$d/umd/sub/"
    if ! python3 - "$d/umd/sub/sub_flip.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then { echo "  $name: harness failure (anchor)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    if ! sfbuild "$d" "$d/sim"; then { echo "  $name: harness failure (build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    vvp -n "$d/sim" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "^FAIL \[($arms)\]" "$d/log"; then echo "  $name: caught by $(grep -Em1 "^FAIL \[($arms)\]" "$d/log" | cut -c1-130)" > "$RES/$name"
    else { echo "  $name: failed but NOT in [$arms]: $(grep -m1 "FAIL\|rror" "$d/log" | cut -c1-130)"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  F=umd/sub/sub_flip.sv
  umut U1 "if (m_new && !own) begin" "if (m_new) begin" ui
  umut U2 "ack_tog <= req_s[2];                         // always taken" "if (!own) ack_tog <= req_s[2];                         // always taken" ui
  umut U3 "wire         h_new = own && hf_req && !hf_ack;" "wire         h_new = hf_req && !hf_ack;" host
  umut U4 "                if (h_new) begin
" "                if (own) hf_ack <= 1'b1;
                if (h_new) begin
" host
  umut U5 "                    end else
                        vis <= 1'b0;" "                    end" hide
  umut U6 "                if (h_new) begin
                    vis <= h_shown;" "                if (h_new) begin
                    vis <= h_shown && !(chg_owed || chg_now);" hide
  # P6d, the panel's mode (docs/panel.md §2)
  umut U7 "wire         own = ui | ui_sub;" "wire         own = ui;" panel
  umut U8 "if (chg_now ? back_now : chg_back) begin" "if (1'b0) begin" panel
  umut U9 "k_vis <= m_shown; k_buf <= hb;" "k_buf <= hb;" panel
  umut U10 "wire         back_now = !own && sub_only_q;" "wire         back_now = !own;" "hide|panel"
  umut U11 "(hf_buf == 2'd3) ? PLANE3 :" "(hf_buf == 2'd3) ? PLANE2 :" panel
  umut U12 "wire  [15:0] h_cw = (h_xe > 17'd720) ? 16'd720 - hf_x : hf_w;" "wire  [15:0] h_cw = hf_w;" host
  # the control: a DDR3 model far too slow for a line -- [late] must fire
  runsim .sim/plane_tb.vvp +noscore +lat_min=2000 +lat_max=2000 > .sim/plane_late.log
  if grep -q "^FAIL \[late\]" .sim/plane_late.log; then echo "  control (DDR3 2,000 cycles slow): caught by $(grep -m1 "^FAIL \[late\]" .sim/plane_late.log | cut -c1-100)" > "$RES/Z"
  else { echo "  control: [late] did not fire: $(grep -m1 "FAIL\|PASS" .sim/plane_late.log)"; echo MUTFAIL; } > "$RES/Z"; fi
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

echo "== lint =="
lint_ok=1
for top in plane_reader plane_blend rd_merge2 sub_flip; do
  f=umd/$top.sv; [ $top = sub_flip ] && f=umd/sub/sub_flip.sv
  verilator --lint-only -Wall -Wno-DECLFILENAME --top-module $top $f > .sim/plane_lint_$top.log 2>&1 \
    || { echo "  FAIL lint $top"; grep -m6 "%Warning\|%Error" .sim/plane_lint_$top.log; lint_ok=0; fail=1; }
done
[ $lint_ok = 1 ] && echo "  PASS verilator --lint-only -Wall (plane_reader, plane_blend, rd_merge2, sub_flip)"

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
