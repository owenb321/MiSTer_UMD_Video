#!/usr/bin/env bash
# run_mb_syntax.sh -- the macroblock-layer gate (umd/h264/mb_syntax.sv driving
# cabac_engine.sv + cabac_ctx.sv, bench/umd/mb_syntax_tb.sv; goldens
# tools/mb_syntax_golden.py <- tools/h264_fe_ref.py)
#
# GREEN, per slice fixture: the SE stream identical to the model's, every macroblock,
# no engine error, bins/cycle >= 0.16 (the Level-3.0 ceiling of 13 Mbins/s at 81 MHz;
# docs/h264_frontend.md S4 has the measured 0.18-0.20 and what is left on the table):
#   * an x264 clip encoded at run time (no media, no reference set: needs ffmpeg with
#     libx264): I slices incl. a second slice of a picture, P with 1 and 4 references,
#     B with two, crf + adaptive quantisation so mb_qp_delta varies -- SKIP without libx264;
#   * with $UMD_REFS_DIR: CABACI3_Sony_B's I / P (cabac_init_idc 2) / B slices and
#     CAPM3_Sony_D's I_PCM slices (an I one and a B one with 43 PCM macroblocks);
#   * with $UMD_ISO_DIR: an Akira P slice with content (frame, weighted P) and a
#     Family Guy I and P field slice (288k / 97k bins).
#   One fixture also runs with a random-ready SE consumer (+stall).
#
# --red: mutations on a COPY of mb_syntax.sv, each caught by its own arm (the x264 I
# and P slices, so the arm needs no reference set):
#   M1  mb_skip_flag ctxIdxInc ignores the left neighbour      -> [se]
#   M2  B mb_type: the intra-suffix offset 32 becomes 17       -> [se]  (the x264 B slice)
#   M3  Intra16x16's implied luma cbp dropped                  -> [se]
#   M4  cbp luma: the 4th 8x8's left neighbour is the wrong prior bin -> [se]
#   M5  mb_qp_delta: the previous macroblock never counts      -> [se]
#   M6  coded_block_flag: an unavailable neighbour of an intra MB gives 0  -> [se]
#   M7  significance map: the last position never inferred     -> [se]
#   M8  coeff_abs_level_minus1: numDecodAbsLevelGt1 saturates at 3 -> [se]
#   M9  mvd ctxIdxInc threshold 2 -> 3                          -> [se]
#   M10 ref_idx: the neighbour's ref_idx > 0 read from the wrong list -> [se]
#   M11 the row above: chroma AC cbf slots swapped              -> [se]
#   M12 field pictures: the frame significance contexts used   -> [se]  (the field fixture, refs)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
RTL="umd/h264/cabac_ctx.sv umd/h264/cabac_engine.sv umd/h264/mb_syntax.sv"
TB=bench/umd/mb_syntax_tb.sv
REFS=${UMD_REFS_DIR:-$HOME/umd-refs}
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
mkdir -p "$GEN"

# shellcheck disable=SC2086
rm -f .sim/mbs_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/mbs_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/mbs_sim ] || { echo "  FAIL mb_syntax_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS; log in .sim/mbs_last.log
  vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/mbs_last.log
  grep -q "^PASS: mb_syntax_tb" .sim/mbs_last.log
}
report() {    # label stem stall
  if run_one .sim/mbs_sim "$2" "$3"; then
    echo "  PASS $1: $(grep '^mb_syntax_tb:' .sim/mbs_last.log | head -1 | sed 's/^mb_syntax_tb: [^:]*: //')"
  else echo "  FAIL $1"; grep FAIL .sim/mbs_last.log | head -3; fail=1; fi
}

echo "== GREEN: x264 slices (refs-free) =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  ffmpeg -v error -f lavfi -i "testsrc2=size=720x480:rate=24" -frames:v 6 -c:v libx264 -profile:v main -pix_fmt yuv420p \
    -x264-params "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=3:weightp=2:slices=2:keyint=6:min-keyint=6:scenecut=0:direct=spatial:aq-mode=1:aq-strength=1.5:crf=28" \
    -bsf:v h264_mp4toannexb -f h264 -y .sim/mbs_x264.264 \
  && python3 tools/mb_syntax_golden.py .sim/mbs_x264.264 --slice 0 1 3 5 8 --out "$GEN/mbs_x264" > .sim/mbs_fx.log 2>&1 \
  && X264=1 || { echo "  FAIL x264 fixtures"; tail -2 .sim/mbs_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    report "x264 I slice 0"            "$GEN/mbs_x264_0" 0
    report "x264 I slice 1 (2nd of picture)" "$GEN/mbs_x264_1" 0
    report "x264 P slice 3"            "$GEN/mbs_x264_3" 0
    report "x264 B slice 5"            "$GEN/mbs_x264_5" 0
    report "x264 P slice 8 (4 refs)"   "$GEN/mbs_x264_8" 0
    report "x264 P slice 3 +stall"     "$GEN/mbs_x264_3" 5
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance slices (\$UMD_REFS_DIR) =="
CI3="$REFS/H.264.1_bitstreams/AVCv1/CABACI3_Sony_B.zip"
PCM="$REFS/H.264.1_bitstreams/AVCv1/CAPM3_Sony_D.zip"
if [ -f "$CI3" ] && [ -f "$PCM" ]; then
  d=$(mktemp -d)
  unzip -o -q "$CI3" -d "$d" && unzip -o -q "$PCM" -d "$d"
  python3 tools/mb_syntax_golden.py "$d/CABACI3_Sony_B.jsv" --slice 0 4 12 --out "$GEN/mbs_ci3" > .sim/mbs_fx.log 2>&1 || { echo "  FAIL CABACI3 fixtures"; fail=1; }
  python3 tools/mb_syntax_golden.py "$d/CAPM3_Sony_D.jsv" --slice 0 4 --out "$GEN/mbs_pcm" >> .sim/mbs_fx.log 2>&1 || { echo "  FAIL CAPM3 fixtures"; fail=1; }
  rm -rf "$d"
  report "CABACI3 I slice 0"          "$GEN/mbs_ci3_0" 0
  report "CABACI3 P slice 4 (idc 2)"  "$GEN/mbs_ci3_4" 0
  report "CABACI3 B slice 12"         "$GEN/mbs_ci3_12" 0
  report "CAPM3 I slice 0 (I_PCM)"    "$GEN/mbs_pcm_0" 0
  report "CAPM3 B slice 4 (43 I_PCM)" "$GEN/mbs_pcm_4" 0
else
  echo "  SKIP: no $CI3 / $PCM (set UMD_REFS_DIR)"
fi

echo "== GREEN: disc slices (\$UMD_ISO_DIR) =="
shopt -s nullglob nocaseglob
AK=("$ISO_DIR"/akira*.iso); FG=("$ISO_DIR"/family*guy*.iso)
shopt -u nullglob nocaseglob
if [ -n "${AK[0]:-}" ] && [ -n "${FG[0]:-}" ]; then
  python3 tools/mb_syntax_golden.py --disc "${AK[0]}" --clip 1 --packs 1500 --slice 15 --out "$GEN/mbs_ak" > .sim/mbs_fx.log 2>&1 || { echo "  FAIL Akira fixture"; fail=1; }
  python3 tools/mb_syntax_golden.py --disc "${FG[0]}" --clip 1 --packs 1500 --slice 120 121 --out "$GEN/mbs_fg" >> .sim/mbs_fx.log 2>&1 || { echo "  FAIL Family Guy fixtures"; fail=1; }
  report "Akira P slice 15 (frame, content)"     "$GEN/mbs_ak" 0
  report "Family Guy P field slice 121"          "$GEN/mbs_fg_121" 0
  report "Family Guy I field slice 120 (288k bins)" "$GEN/mbs_fg_120" 0
else
  echo "  SKIP: no Akira / Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name old new stem
    local name=$1 old=$2 new=$3 stem=$4
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/mb_syntax.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/cabac_ctx.sv" "$d/cabac_engine.sv" "$d/mb_syntax.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    vvp -n "$d/sim" "+stem=$stem" +stall=0 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: mb_syntax_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[se\]" "$d/log"; then
      echo "  $name: caught by $(grep -m1 'FAIL \[se\]' "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [se]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  XI="$GEN/mbs_x264_0"; XP="$GEN/mbs_x264_3"; XB="$GEN/mbs_x264_5"
  mut M1 "+ (left_avail && !p_skip ? 9'd1 : 9'd0) + (a_avail && !a_skip ? 9'd1 : 9'd0));" "+ (a_avail && !a_skip ? 9'd1 : 9'd0));" "$XP" &
  mut M2 "4'd13: begin mbt_off <= 9'd32; mbt_add <= 6'd23; state <= S_MBT_I0; end" "4'd13: begin mbt_off <= 9'd17; mbt_add <= 6'd23; state <= S_MBT_I0; end" "$XB" &
  mut M3 "c_cbp <= {mbt_chroma, (mbt_ac ? 4'hF : 4'h0)};" "c_cbp <= {mbt_chroma, 4'h0};" "$XI" &
  mut M4 "default: cbpA_zero = !cbp_acc[2];" "default: cbpA_zero = !cbp_acc[1];" "$XP" &
  mut M5 "(prev_valid && !p_skip && !p_pcm && (p_i16 || p_cbp != 6'd0) && p_qpd_nz) ? 4'd1 : 4'd0," "4'd0," "$XI" &
  mut M6 "        else if (!left_avail)\n            cbfA = c_intra;" "        else if (!left_avail)\n            cbfA = 1'b0;" "$XI" &
  wait
  mut M7 "rb_sig[rb_n - 5'd1] <= 1'b1; rb_num <= rb_n;" "rb_num <= rb_n;" "$XI" &
  mut M8 "4'd5 + (((4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) < rb_gt1) ? (4'd4 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) : rb_gt1)," "4'd5 + (((4'd3 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) < rb_gt1) ? (4'd3 - (rb_cat == 3'd3 ? 4'd1 : 4'd0)) : rb_gt1)," "$XI" &
  mut M9 "(mvd_sum > 7'd2) ? 4'd1 : 4'd0;" "(mvd_sum > 7'd3) ? 4'd1 : 4'd0;" "$XP" &
  mut M10 "nA_refgt = lx ? p_ref1gt[nbA_idx] : p_ref0gt[nbA_idx];" "nA_refgt = lx ? p_ref0gt[nbA_idx] : p_ref1gt[nbA_idx];" "$GEN/mbs_x264_8" &
  mut M11 "c_cbf_cac[7], c_cbf_cac[6], c_cbf_cac[3], c_cbf_cac[2]," "c_cbf_cac[2], c_cbf_cac[3], c_cbf_cac[6], c_cbf_cac[7]," "$XI" &
  if [ -f "$GEN/mbs_fg_121.meta.hex" ]; then
    mut M12 "wire [8:0] sig_ctx  = (field ? 9'd277 : 9'd105)" "wire [8:0] sig_ctx  = (1'b0 ? 9'd277 : 9'd105)" "$GEN/mbs_fg_121" &
  else
    echo "  M12: SKIP (the field fixture needs \$UMD_ISO_DIR)" > "$RES/M12"
  fi
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
