#!/usr/bin/env bash
# run_p3_chain.sh -- the P3 chain gate: ps_stream_fifo -> ps_demux (clk_sys) ->
# vidfeed_cdc + fifo_dc -> h264_top (clk_dec), es_probe, cdc_reset, cdc_snap and the
# end-of-title flush, composed as umd/emu.sv composes them (bench/umd/p3_chain_tb.sv;
# goldens tools/p3_chain_golden.py <- h264_top_golden.py + psmf_golden.py).
#
# GREEN, per program-stream fixture: the front end's SE stream identical to the model's
# through the real demux and the clock crossing, the counters equal, the probe's byte
# counts and CRC equal (every byte reached its sink exactly once), the flush issued
# after the quiet window, the snapshot copies consistent (docs/h264_frontend.md S6):
#   * x264 Main 720x480 I/P/B (2 slices/picture) packed into synthetic packs with audio
#     interleaved (refs-free; SKIP without libx264): at the 81 MHz clk_dec, with a
#     random-ready SE sink (+stall: the whole backpressure path, required to have
#     stalled), and at a non-integer clock ratio (73 MHz) to shake the CDC phases;
#   * with $UMD_ISO_DIR: the first 120 packs of Akira (frames) and Family Guy (fields),
#     verbatim -- cut mid-NAL, so the flush turns the cut unit into exactly one error.
#
# --red: mutations on a COPY of the RTL, each caught by its own arm on the x264 fixture:
#   F1  fifo_dc: never full (writes overrun the read side)          -> [se]    (+stall)
#   F2  fifo_dc: the gray conversion dropped (binary pointers cross) -> [se]
#   F3  vidfeed_cdc: pops from every state (the DVD's original defect: the arriving
#       byte clobbers an unconsumed head)                            -> [se]    (+stall)
#   F4  vidfeed_cdc: the flush never issued                          -> [flush]
#   F5  vidfeed_cdc: the flush issued without the quiet window       -> [flush]
#   F6  cdc_snap: the source never answers (a stale readout)         -> [snap]
#   Equivalent mutants, dropped rather than kept as false arms: rd_valid as the DVD's
#   consume pulse (valid = take) SURVIVED -- a valid that follows ready breaks the
#   protocol but loses nothing, the head still waits for ready; a cdc_reset released
#   asynchronously has no metastability to show in RTL simulation (covered by
#   construction). And the first run of the flush-never-issued mutant landed in [hang],
#   not [flush]: the flush wait must be shorter than the hang budget (it is, now).
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
RTL="umd/h264/h264_pkg.sv umd/h264/nal_parser.sv umd/h264/rbsp_reader.sv umd/h264/sps_pps.sv umd/h264/slice_hdr.sv umd/h264/cabac_ctx.sv umd/h264/cabac_engine.sv umd/h264/mb_syntax.sv umd/h264/au_pts.sv umd/h264/sei_pt.sv umd/h264/h264_top.sv umd/ps_stream_fifo.sv umd/ps_demux.sv umd/es_probe.sv umd/fifo_dc.sv umd/vidfeed_cdc.sv umd/cdc.sv"
TB=bench/umd/p3_chain_tb.sv
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
mkdir -p "$GEN"

# shellcheck disable=SC2086
rm -f .sim/p3chain_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/p3chain_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/p3chain_sim ] || { echo "  FAIL p3_chain_tb: build"; exit 1; }

run_one() {   # sim stem stall dec_ps -> 0 on PASS; log in .sim/p3chain_last.log
  timeout 3600 vvp -n "$1" "+stem=$2" "+stall=$3" "+dec_ps=$4" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/p3chain_last.log
  grep -q "^PASS: p3_chain_tb" .sim/p3chain_last.log
}
report() {    # label stem stall dec_ps
  if run_one .sim/p3chain_sim "$2" "$3" "$4"; then
    echo "  PASS $1: $(grep '^p3_chain_tb:' .sim/p3chain_last.log | head -1 | sed 's/^p3_chain_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/p3chain_last.log | head -3; fail=1; fi
}

echo "== GREEN: x264 through synthetic packs (refs-free) =="
X264=0
: > .sim/p3chain_fx.log
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  ffmpeg -v error -f lavfi -i "testsrc2=size=720x480:rate=24" -frames:v 6 -c:v libx264 -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=28" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/p3chain_main.264 \
  && python3 tools/p3_chain_golden.py --x264 .sim/p3chain_main.264 --out "$GEN/p3chain_x264" >> .sim/p3chain_fx.log 2>&1 \
  && X264=1 || { echo "  FAIL x264 fixture"; tail -3 .sim/p3chain_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    report "x264 Main I/P/B, 81 MHz clk_dec"                     "$GEN/p3chain_x264" 0 12346
    report "x264 Main +stall (random SE sink: full backpressure)" "$GEN/p3chain_x264" 1 12346
    report "x264 Main at a 73 MHz clk_dec (non-integer ratio)"    "$GEN/p3chain_x264" 1 13700
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: disc packs (\$UMD_ISO_DIR) =="
shopt -s nullglob nocaseglob
AK=("$ISO_DIR"/akira*.iso); FG=("$ISO_DIR"/family*guy*.iso)
shopt -u nullglob nocaseglob
if [ -n "${AK[0]:-}" ] && [ -n "${FG[0]:-}" ]; then
  python3 tools/p3_chain_golden.py --disc "${AK[0]}" --clip 1 --packs 120 --out "$GEN/p3chain_ak" >> .sim/p3chain_fx.log 2>&1 || { echo "  FAIL Akira fixture"; tail -2 .sim/p3chain_fx.log; fail=1; }
  python3 tools/p3_chain_golden.py --disc "${FG[0]}" --clip 1 --packs 120 --out "$GEN/p3chain_fg" >> .sim/p3chain_fx.log 2>&1 || { echo "  FAIL Family Guy fixture"; tail -2 .sim/p3chain_fx.log; fail=1; }
  report "Akira clip 1, 120 packs verbatim (frames)"           "$GEN/p3chain_ak" 0 12346
  report "Family Guy clip 1, 120 packs verbatim (fields)"      "$GEN/p3chain_fg" 0 12346
else
  echo "  SKIP: no Akira / Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixture"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name file old new stall arm
    local name=$1 file=$2 old=$3 new=$4 stall=$5 arm=$6
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local files=""; for f in $RTL; do files="$files $d/$(basename "$f")"; done
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! iverilog -g2012 -o "$d/sim" $files $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 1800 vvp -n "$d/sim" "+stem=$GEN/p3chain_x264" "+stall=$stall" +dec_ps=12346 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: p3_chain_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[$arm\]" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "FAIL \[$arm\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut F1 fifo_dc.sv "wbin <= wbin_nx; wgray <= wgray_nx; full <= full_nx;" "wbin <= wbin_nx; wgray <= wgray_nx; full <= 1'b0;" 1 se &
  mut F2 fifo_dc.sv "wire  [AW:0] wgray_nx = (wbin_nx >> 1) ^ wbin_nx;" "wire  [AW:0] wgray_nx = wbin_nx;" 0 se &
  mut F3 vidfeed_cdc.sv "wire rd_en = (st == S_IDLE) & ~empty;" "wire rd_en = ~empty;" 1 se &
  mut F4 vidfeed_cdc.sv "rd_flush <= fl_q2 && quiet && (idle_cnt == FLUSH_IDLE[12:0]) && !rd_flushed;" "rd_flush <= 1'b0;" 0 flush &
  mut F5 vidfeed_cdc.sv "rd_flush <= fl_q2 && quiet && (idle_cnt == FLUSH_IDLE[12:0]) && !rd_flushed;" "rd_flush <= fl_q2 && quiet && !rd_flushed;" 0 flush &
  mut F6 cdc.sv "if (s_q2 != ack) begin hold <= src_data; ack <= s_q2; end" "if (1'b0) begin hold <= src_data; ack <= s_q2; end" 0 snap &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
