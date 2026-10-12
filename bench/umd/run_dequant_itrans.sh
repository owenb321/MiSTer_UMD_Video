#!/usr/bin/env bash
# run_dequant_itrans.sh -- the inverse scan / scaling / inverse transform gate
# (umd/h264/dequant_itrans.sv, bench/umd/dequant_itrans_tb.sv; goldens
# tools/itrans_golden.py <- tools/h264_recon_ref.py's dequant4x4 + itrans4x4, luma_dc,
# chroma_dc, which are proven pixel-exact against ffmpeg). docs/h264_recon.md S2.4.
#
# GREEN, per fixture class: every output word equal to the model's, res_last on the
# right word, nothing extra, no hang:
#   * it_rand_<KIND>_<frame|field>: every qp 0..51 x random blocks inside the spec ranges
#     (the golden asserts them), each of the five kinds, both scans;
#   * it_sparse_<frame|field>: one coefficient at every scan position, both signs, at the
#     largest magnitude the range admits (the scan ROM entry by entry, the widest values);
#   * it_zero: all-zero blocks, and AC blocks whose only content is dc_in;
#   * it_real: the fixture-range check -- every block an x264 clip's decode transforms
#     (encoded at run time with ffmpeg + libx264, crf + adaptive quantisation so the QP
#     varies per macroblock; the model's own residual path is wrapped to capture the
#     levels, the QP and the scan it used) -- SKIP without libx264;
#   * with $UMD_ISO_DIR: it_real_field, the same from a Family Guy clip's field pictures;
#   * a spread of the classes again with +stall=5 (random start / coef_valid / res_ready).
#   Each PASS line reports samples/cycle and cycles/block.
#
# --red: mutations on a COPY of dequant_itrans.sv, each caught by its own fixture class
# (the class named first) while a class the defect must NOT touch still passes (the class
# in parentheses -- that is what makes the arm load-bearing):
#   M1  zig-zag entries 5 and 6 swapped                -> it_rand_L4_frame  (it_rand_L4_field passes)
#   M2  field-scan entries 1 and 2 swapped             -> it_rand_L4_field  (it_rand_L4_frame passes)
#   M3  normAdjust class (i odd, j odd) read as mixed  -> it_rand_L4_frame  (it_rand_LDC_frame: class 0 only)
#   M4  qp < 24 scaling shift wrong (>>3 for qp/6 = 0) -> it_rand_L4_frame  (it_rand_LDC_frame: no 4x4 scaling)
#   M5  butterfly (x1 >> 1) - x3 loses its >> 1        -> it_rand_L4_frame  (it_rand_LDC_frame: Hadamard path)
#   M6  the +32 of (h + 32) >> 6 dropped               -> it_rand_L4_frame  (it_rand_LDC_frame)
#   M7  luma DC qp >= 36 branch: << 1 becomes << 2     -> it_rand_LDC_frame (it_rand_L4_frame)
#   M8  luma DC qp < 12 rounding term dropped          -> it_rand_LDC_frame (it_rand_CDC)
#   M9  chroma DC >> 5 becomes >> 4                    -> it_rand_CDC       (it_rand_LDC_frame)
#   M10 dc_in ignored for kind 1 (LAC): d00 = 0        -> it_rand_LAC_frame (it_rand_CAC_frame)
#   M11 chroma DC outputs dc01 / dc10 swapped          -> it_rand_CDC       (it_rand_LDC_frame)
#   The eq. 8-338 rounding term (qp < 24) is not a mutation: with flat scaling lists it
#   is vacuous (the RTL header has the proof, itrans_golden.py checks it exhaustively),
#   so no fixture can see it; M4 covers that branch's shift instead.
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
RTL="umd/h264/dequant_itrans.sv"
TB=bench/umd/dequant_itrans_tb.sv
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
mkdir -p "$GEN"

rm -f .sim/dqit_sim   # a failed build must not run the last one (the stale-binary trap)
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/dqit_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/dqit_sim ] || { echo "  FAIL dequant_itrans_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS; log in .sim/dqit_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/dqit_last.log
  grep -q "^PASS: dequant_itrans_tb" .sim/dqit_last.log
}
report() {    # label stem stall
  if run_one .sim/dqit_sim "$2" "$3"; then
    echo "  PASS $1: $(grep '^dequant_itrans_tb:' .sim/dqit_last.log | head -1 | sed 's/^dequant_itrans_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/dqit_last.log | head -3; fail=1; fi
}

echo "== FIXTURES =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  ffmpeg -v error -f lavfi -i "testsrc2=size=720x480:rate=24" -frames:v 6 -c:v libx264 -profile:v main -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=22" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/dqit_x264.264 && X264=1 || { echo "  FAIL x264 clip"; fail=1; }
else
  echo "  SKIP it_real: ffmpeg with libx264 not found"
fi
shopt -s nullglob nocaseglob
FG=("$ISO_DIR"/family*guy*.iso)
shopt -u nullglob nocaseglob
DISC=0
GOLD_ARGS=(--out "$GEN")
[ $X264 = 1 ] && GOLD_ARGS+=(--stream .sim/dqit_x264.264)
if [ -n "${FG[0]:-}" ]; then GOLD_ARGS+=(--disc "${FG[0]}"); DISC=1; else echo "  SKIP it_real_field: no Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"; fi
if python3 tools/itrans_golden.py "${GOLD_ARGS[@]}" > .sim/dqit_fx.log 2>&1; then
  sed 's/^/  /' .sim/dqit_fx.log
else
  echo "  FAIL fixtures"; tail -3 .sim/dqit_fx.log; fail=1
fi

echo "== GREEN: random blocks, every qp, every kind, both scans =="
for k in L4 LAC CAC LDC; do
  report "it_rand_${k}_frame" "$GEN/it_rand_${k}_frame" 0
  report "it_rand_${k}_field" "$GEN/it_rand_${k}_field" 0
done
report "it_rand_CDC" "$GEN/it_rand_CDC" 0
echo "== GREEN: sparse and zero blocks =="
report "it_sparse_frame" "$GEN/it_sparse_frame" 0
report "it_sparse_field" "$GEN/it_sparse_field" 0
report "it_zero" "$GEN/it_zero" 0
echo "== GREEN: real blocks (the fixture-range check) =="
[ $X264 = 1 ] && report "it_real (x264 720x480)" "$GEN/it_real" 0
[ $DISC = 1 ] && report "it_real_field (Family Guy fields)" "$GEN/it_real_field" 0
echo "== GREEN: +stall (random start / coef_valid / res_ready) =="
report "it_rand_L4_frame +stall" "$GEN/it_rand_L4_frame" 5
report "it_rand_LAC_field +stall" "$GEN/it_rand_LAC_field" 5
report "it_rand_LDC_frame +stall" "$GEN/it_rand_LDC_frame" 5
report "it_rand_CDC +stall" "$GEN/it_rand_CDC" 5
report "it_zero +stall" "$GEN/it_zero" 5
[ $X264 = 1 ] && report "it_real +stall" "$GEN/it_real" 5

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own fixture class) =="
  RES=$(mktemp -d)
  mut() {   # name old new catch_stem pass_stem
    local name=$1 old=$2 new=$3 catch=$4 pass=$5
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/dequant_itrans.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/dequant_itrans.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    vvp -n "$d/sim" "+stem=$GEN/$catch" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: dequant_itrans_tb" "$d/log"; then
      { echo "  $name: SURVIVED $catch -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif ! grep -q "^FAIL \[res\]" "$d/log"; then
      { echo "  $name: $catch failed but NOT in [res]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    else
      vvp -n "$d/sim" "+stem=$GEN/$pass" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log2"
      if grep -q "^PASS: dequant_itrans_tb" "$d/log2"; then
        echo "  $name: caught by $catch $(grep -m1 '^FAIL \[res\]' "$d/log" | cut -c6-70)... ($pass still passes)" > "$RES/$name"
      else
        { echo "  $name: caught by $catch but $pass ALSO fails -- the arm is not specific"; echo MUTFAIL; } > "$RES/$name"
      fi
    fi
    rm -rf "$d"
  }
  L4F=it_rand_L4_frame; L4D=it_rand_L4_field; LDC=it_rand_LDC_frame; CDC=it_rand_CDC
  mut M1  "5'h05: scan_r = 4'd2;  5'h06: scan_r = 4'd3;" "5'h05: scan_r = 4'd3;  5'h06: scan_r = 4'd2;" $L4F $L4D &
  mut M2  "5'h11: scan_r = 4'd4;  5'h12: scan_r = 4'd1;" "5'h11: scan_r = 4'd1;  5'h12: scan_r = 4'd4;" $L4D $L4F &
  mut M3  "2'b11:   in_cls = 2'd1;" "2'b11:   in_cls = 2'd2;" $L4F $LDC &
  mut M4  "4'd0: dq_sh = dq_ext >>> 4;" "4'd0: dq_sh = dq_ext >>> 3;" $L4F $LDC &
  mut M5  "e2 = x1h - x3;" "e2 = x1 - x3;" $L4F $LDC &
  mut M6  "o_val = ({{12{p_val[19]}}, p_val} + 32) >>> 6;" "o_val = ({{12{p_val[19]}}, p_val}) >>> 6;" $L4F $LDC &
  wait
  mut M7  "4'd7: o_val = o_ext <<< 1;" "4'd7: o_val = o_ext <<< 2;" $LDC $L4F &
  mut M8  "4'd0: o_val = (o_ext + 32) >>> 6;" "4'd0: o_val = o_ext >>> 6;" $LDC $CDC &
  mut M9  "4'd0: o_val = o_ext >>> 5;" "4'd0: o_val = o_ext >>> 4;" $CDC $LDC &
  mut M10 "if (kind == K_LAC || kind == K_CAC) A[0] <= {{4{dc_in[15]}}, dc_in};" "if (kind == K_LAC || kind == K_CAC) A[0] <= (kind == K_CAC) ? {{4{dc_in[15]}}, dc_in} : 20'sd0;" it_rand_LAC_frame it_rand_CAC_frame &
  mut M11 "O[1] <= a12[19:0]; O[2] <= m03[19:0];" "O[1] <= m03[19:0]; O[2] <= a12[19:0];" $CDC $LDC &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
