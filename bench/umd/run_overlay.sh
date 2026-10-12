#!/usr/bin/env bash
# run_overlay.sh -- subtitles from the demux's bytes to the composite on the raster:
# umd/sub/sub_overlay.sv (sub_top + sub_flip + plane_reader + rd_merge2 + ddr_mux2 B_FIRST +
# plane_blend) as emu will instance it, with the video's disp_reader on its v_* port and
# one DDR3 model behind DDRAM2 (bench/umd/sub_overlay_tb.sv; docs/compositor.md §8). The
# decode is the HPS's since A7: the bench's host is bench/umd/mock_host.svh.
# Goldens: tools/sub_golden.py e2e (the units the tool finds, libpng's planes),
# tools/sub_overlay_golden.py (per shown unit, the plane on the raster and the composite
# over tools/disp_golden.py's video).
#
# GREEN (in parallel, ~200 MB and ~5-8 minutes each):
#   synth        RGBA8, Adam7 4-bit, RGB16, clipped at two edges, a refused PNG
#   flush1       the same, flushed while the host decodes the first unit (its completion ignored)
#   flush2       the same, flushed as the second unit's flip is requested
#   with $UMD_ISO_DIR, the corpus's extremes (docs/umd_video_format.md "Subtitles"):
#   wide         The Animatrix 0x81 #73-74: 636 wide, right edge 680 (the widest fetch)
#   tall         Stargate 0x80 #71-72: 349x441 (the tallest)
#   vert         The Animatrix 0x80 #514: 33x369 at x 612 (vertical text)
#   lint         verilator -Wall over sub_overlay and everything under it
#   fj#71 Zoom (docs/zoom.md Z3; +zoom: the subtitle moved inside the band 60 .. 419, the golden's --zoom):
#   zoom-synth   the synth units zoomed (inside the band, two past its bottom)
#   zoom-clamp   tools/sub_golden.py --zoom-synth: above the band, inside it, 400 rows tall (host and FABRIC)
#   zoom-tall    Stargate's 349x441 zoomed (FABRIC; with $UMD_ISO_DIR)
# --red: mutations on a COPY (compiled inside it), each caught by its own arm:
#   O1  overlay: the video not delayed to the plane's LAT 5          -> [comp]
#   O2  overlay: the latch's plane bases swapped (the back plane shown) -> [plane]
#   O3  sub_top: a flush does not move gen (the host's cue to abandon) -> [flush]
#   O4  scheduler: a flip requested at a flush left up (no fl_hide)  -> [flush]
#   O5  overlay: Zoom's clamp gone (the subtitle at its own y)         -> [plane] (zoom-clamp)
#   O6  overlay: a subtitle above the band left there                  -> [plane] (zoom-clamp)
#   O7  overlay: a subtitle taller than the band not bounded to 360    -> [plane] (zoom-clamp)
#   (the host's plane never clamped -- f_host -- needs the hand-over, which this bench ties off:
#    checked on the rig with the control panel over a zoomed subtitle, docs/zoom.md §5)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
ROOT=$(pwd)
G=bench/umd/fixtures/gen/ovl
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
SUB="umd/png/png_pkg.sv umd/png/inflate.sv umd/png/png_chunks.sv umd/png/png_unfilter.sv umd/png/png_pixel.sv umd/png/png_top.sv umd/sub/sub_png.sv umd/sub/sub_plane_wr.sv umd/sub/sub_dec.sv umd/fifo_dc.sv umd/cdc.sv umd/sub/sub_q.sv umd/sub/sub_in.sv umd/sub/sub_unit.sv umd/sub/sub_ring.sv umd/sub/sub_sched.sv umd/sub/sub_mem.sv umd/sub/sub_top.sv umd/sub/sub_flip.sv umd/sub/sub_overlay.sv"
CMP="umd/sync_gen.sv umd/disp_reader.sv umd/ddr_mux2.sv umd/rd_merge2.sv umd/plane_reader.sv umd/plane_blend.sv"
mkdir -p $G

echo "== fixtures =="
python3 tools/disp_golden.py > /dev/null || { echo "  FAIL disp golden"; exit 1; }
{ python3 -W ignore tools/sub_golden.py e2e --out $G --list e_synth --synth \
  && python3 tools/sub_overlay_golden.py $G/e_synth.txt \
  && python3 tools/sub_overlay_golden.py --zoom $G/e_synth.txt \
  && python3 -W ignore tools/sub_golden.py e2e --out $G --list e_zoom --zoom-synth \
  && python3 tools/sub_overlay_golden.py --zoom $G/e_zoom.txt; } > .sim/ovl_golden.log 2>&1 || { echo "  FAIL golden"; tail -3 .sim/ovl_golden.log; exit 1; }
AN=$(find "$ISO_DIR" -maxdepth 2 -iname '*animatrix*.iso' 2>/dev/null | head -1)
SG=$(find "$ISO_DIR" -maxdepth 2 -iname 'stargate*.iso' 2>/dev/null | head -1)
DISCS=0
if [ -n "$AN" ] && [ -n "$SG" ]; then
  { python3 -W ignore tools/sub_golden.py e2e --out $G --list e_wide --units 2 --skip 73 --disc "$AN:1:0x81" \
    && python3 -W ignore tools/sub_golden.py e2e --out $G --list e_tall --units 2 --skip 71 --disc "$SG:1:0x80" \
    && python3 -W ignore tools/sub_golden.py e2e --out $G --list e_vert --units 1 --skip 514 --disc "$AN:1:0x80" \
    && python3 tools/sub_overlay_golden.py $G/e_wide.txt && python3 tools/sub_overlay_golden.py $G/e_tall.txt \
    && python3 tools/sub_overlay_golden.py $G/e_vert.txt && python3 tools/sub_overlay_golden.py --zoom $G/e_tall.txt; } >> .sim/ovl_golden.log 2>&1 && DISCS=1 \
    || { echo "  FAIL disc goldens"; tail -3 .sim/ovl_golden.log; fail=1; }
else
  echo "  SKIP disc cases: no The Animatrix / Stargate image in \$UMD_ISO_DIR ($ISO_DIR)"
fi
grep "shown unit" .sim/ovl_golden.log | sed 's/^sub_overlay_golden: /  /'

build() {   # DIR OUT [iverilog flags] -- compiled from inside DIR (a mutant's copy, or the tree)
  local d=$1 out=$2; shift 2
  # shellcheck disable=SC2086
  (cd "$d" && iverilog -g2012 "$@" -o "$out" $SUB $CMP "$ROOT/bench/umd/ddr_model.sv" "$ROOT/bench/umd/sub_overlay_tb.sv" 2>&1 \
     | grep -v "sorry: constant\|pop_front") > /dev/null
  [ -f "$out" ]
}
runsim() {  # SIM ARGS... -> the log on stdout (from the tree: the fixtures are relative)
  vvp -n "$@" 2>&1 | grep -v 'readmem\|Not enough words'
}
score() {  # LABEL LOG
  if grep -q "^PASS: sub_overlay_tb" "$2"; then
    echo "  PASS $1: $(grep "^sub_overlay_tb:" "$2" | tail -1 | sed "s/^sub_overlay_tb: //; s#$G/##" | cut -c1-150)"
  else echo "  FAIL $1"; grep "FAIL\|FATAL" "$2" | head -3; fail=1; fi
}

echo "== GREEN =="
rm -f .sim/ovl.vvp
build "$ROOT" "$ROOT/.sim/ovl.vvp" || { echo "  FAIL sub_overlay_tb: build"; exit 1; }
# A12 SD1: the same bench with the fabric decoding (FABRIC_DEC; no mock host): [plane] / [comp]
# then score png_top's planes on the raster
rm -f .sim/ovl_fab.vvp
build "$ROOT" "$ROOT/.sim/ovl_fab.vvp" -DFABRIC || { echo "  FAIL sub_overlay_tb (FABRIC): build"; exit 1; }
runsim .sim/ovl_fab.vvp +list=$G/e_synth.txt > .sim/ovl_fab_synth.log &
runsim .sim/ovl_fab.vvp +list=$G/e_synth.txt +flush=1 > .sim/ovl_fab_flush1.log &
runsim .sim/ovl_fab.vvp +list=$G/e_synth.txt +flush=2 > .sim/ovl_fab_flush2.log &
runsim .sim/ovl.vvp +list=$G/e_synth.txt > .sim/ovl_synth.log &
runsim .sim/ovl.vvp +list=$G/e_synth.txt +flush=1 +mh_loose=1 > .sim/ovl_flush1.log &
runsim .sim/ovl.vvp +list=$G/e_synth.txt +flush=2 +mh_loose=1 > .sim/ovl_flush2.log &
wait
runsim .sim/ovl.vvp +list=$G/e_synth.txt +zoom > .sim/ovl_zsynth.log &
runsim .sim/ovl.vvp +list=$G/e_zoom.txt +zoom > .sim/ovl_zclamp.log &
runsim .sim/ovl_fab.vvp +list=$G/e_zoom.txt +zoom > .sim/ovl_fab_zclamp.log &
if [ $DISCS = 1 ]; then
  runsim .sim/ovl.vvp +list=$G/e_wide.txt > .sim/ovl_wide.log &
  runsim .sim/ovl.vvp +list=$G/e_tall.txt > .sim/ovl_tall.log &
  runsim .sim/ovl.vvp +list=$G/e_vert.txt > .sim/ovl_vert.log &
  runsim .sim/ovl_fab.vvp +list=$G/e_wide.txt > .sim/ovl_fab_wide.log &
  runsim .sim/ovl_fab.vvp +list=$G/e_tall.txt > .sim/ovl_fab_tall.log &
  wait
  runsim .sim/ovl_fab.vvp +list=$G/e_tall.txt +zoom > .sim/ovl_fab_ztall.log &
fi
wait
score "synth" .sim/ovl_synth.log
score "flush1 (while the host decodes)" .sim/ovl_flush1.log
score "flush2 (at a flip request)" .sim/ovl_flush2.log
score "FABRIC synth (png_top decodes)" .sim/ovl_fab_synth.log
score "FABRIC flush1 (while the fabric decodes)" .sim/ovl_fab_flush1.log
score "FABRIC flush2 (at a flip request)" .sim/ovl_fab_flush2.log
score "zoom-synth (fj#71: inside the band, past its bottom)" .sim/ovl_zsynth.log
score "zoom-clamp (fj#71: above, inside, 400 tall)" .sim/ovl_zclamp.log
score "FABRIC zoom-clamp" .sim/ovl_fab_zclamp.log
if [ $DISCS = 1 ]; then
  score "wide (The Animatrix, 636 wide, right edge 680)" .sim/ovl_wide.log
  score "tall (Stargate, 349x441)" .sim/ovl_tall.log
  score "vert (The Animatrix, 33x369)" .sim/ovl_vert.log
  score "FABRIC wide (The Animatrix)" .sim/ovl_fab_wide.log
  score "FABRIC tall (Stargate)" .sim/ovl_fab_tall.log
  score "FABRIC zoom-tall (fj#71: Stargate 441 rows at 60, 360 shown)" .sim/ovl_fab_ztall.log
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arms args...
    local name=$1 file=$2 old=$3 new=$4 arms=$5; shift 5
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/sub" "$d/umd/png" "$d/bench/umd"
    cp umd/*.sv umd/*.vh "$d/umd/"; cp umd/sub/*.sv "$d/umd/sub/"; cp umd/png/*.sv "$d/umd/png/"; cp bench/umd/mock_host.svh "$d/bench/umd/"
    if ! python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then { echo "  $name: harness failure (anchor)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    if ! build "$d" "$d/sim"; then { echo "  $name: harness failure (build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    runsim "$d/sim" "$@" > "$d/log"
    if grep -q "^PASS:" "$d/log"; then { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "^FAIL \[($arms)\]" "$d/log"; then echo "  $name: caught by $(grep -Em1 "^FAIL \[($arms)\]" "$d/log" | sed "s#$G/##" | cut -c1-130)" > "$RES/$name"
    else { echo "  $name: failed but NOT in [$arms]: $(grep -m1 "FAIL\|FATAL\|rror" "$d/log" | cut -c1-130)"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  S=+list=$G/e_synth.txt
  mut O1 umd/sub/sub_overlay.sv ".d_r (v5_r), .d_g (v5_g), .d_b (v5_b)," ".d_r (vid_r), .d_g (vid_g), .d_b (vid_b)," comp $S &
  mut O2 umd/sub/sub_overlay.sv "sub_flip #(.PLANE0 (PLANE0), .PLANE1 (PLANE1), .PLANE2" "sub_flip #(.PLANE0 (PLANE1), .PLANE1 (PLANE0), .PLANE2" plane $S &
  mut O3 umd/sub/sub_top.sv "if (flush && !flush_d) h_gen <= h_gen + 8'd1;" "if (1'b0) h_gen <= h_gen + 8'd1;" flush $S +flush=1 +mh_loose=1 &
  mut O4 umd/sub/sub_sched.sv "fend    <= fl_hide ? stc : bend;" "fend    <= bend;" flush $S +flush=2 +mh_loose=1 &
  wait
  Z=+list=$G/e_zoom.txt
  mut O5 umd/sub/sub_overlay.sv ".dx (f_x), .dy (z_dy), .dw (f_w), .dh (z_dh)," ".dx (f_x), .dy (f_y), .dw (f_w), .dh (z_dh)," plane $Z +zoom &
  mut O6 umd/sub/sub_overlay.sv "(z_tall || f_y < 9'd60) ? 9'd60 :" "z_tall ? 9'd60 :" plane $Z +zoom &
  mut O7 umd/sub/sub_overlay.sv "wire  [8:0]  z_dh   = (z_on && z_tall) ? 9'd360 : f_h;" "wire  [8:0]  z_dh   = f_h;" plane $Z +zoom &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

echo "== lint =="
# shellcheck disable=SC2086
if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET --top-module sub_overlay $SUB \
     umd/ddr_mux2.sv umd/rd_merge2.sv umd/plane_reader.sv umd/plane_blend.sv > .sim/ovl_lint.log 2>&1; then
  echo "  PASS verilator --lint-only -Wall"
else echo "  FAIL lint"; grep -m8 "%Warning\|%Error" .sim/ovl_lint.log; fail=1; fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
