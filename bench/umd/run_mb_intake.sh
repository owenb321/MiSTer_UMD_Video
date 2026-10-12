#!/usr/bin/env bash
# run_mb_intake.sh -- the macroblock intake gate (umd/h264/mb_intake.sv,
# bench/umd/mb_intake_tb.sv; goldens tools/intake_golden.py <- tools/h264_recon_ref.py's
# intake and expand_mb). docs/h264_recon.md S2.3.
#
# GREEN, per stream: every macroblock's descriptor (type, sub-types, cbp incl.
# Intra16x16's implied one, the Intra4x4 syntax, refs per slot, mvd and pred flags per
# 4x4 block, the direct sub-macroblocks, coded slots, nz) and every level read back
# identical, with and without input gaps:
#   * x264 at run time (SKIP without libx264): P with every partition size incl. 4x4
#     sub-partitions and 4 references; B with B_8x8 and direct sub-macroblocks, 3
#     references; a lossless noise clip (I_PCM); an intra clip (Intra4x4 / 16x16);
#   * with $UMD_REFS_DIR: CAPM3_Sony_D (I_PCM in P / B), CAWP5_TOSHIBA_E (many refs);
#   * with $UMD_ISO_DIR: an Akira and a Family Guy window.
#
# --red: mutations on a COPY of the RTL, each caught by its own stream:
#   I1  Intra16x16's implied chroma cbp halved (class 1 -> 0, 2 -> 1) -> intra (the clip has
#       no Plane-mode Intra16x16, so an off-by-one on the type would only move Plane types)
#   I2  the ref cursor never advances (every ref to slot 0)        -> x264 P
#   I3  8x4 sub-partitions' mvd masks swapped                       -> x264 P
#   I4  B mb_type 12 (L0 / Bi) lists swapped                        -> x264 B
#   I5  B_8x8 direct sub-macroblocks not flagged                    -> x264 B
#   I6  I_PCM samples written at block-slot addresses               -> pcm
#   I7  nz set for zero levels too                                  -> x264 P
#   I8  prev_intra4x4_pred_mode_flag 1 does not advance the block   -> intra
#   I9  the coefficient read from the working bank, not the output  -> intra (the next MB's levels)
#   I10 the working descriptor moved out over one still being read  -> x264 P
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
RTL="umd/h264/mb_intake.sv"
TB=bench/umd/mb_intake_tb.sv
REFS=${UMD_REFS_DIR:-$HOME/umd-refs}
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
mkdir -p "$GEN"
: > .sim/intake_fx.log

rm -f .sim/intake_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/intake_sim $RTL $TB 2>&1 | grep -v sorry
[ -f .sim/intake_sim ] || { echo "  FAIL mb_intake_tb: build"; exit 1; }

run_one() {   # sim stem stall -> 0 on PASS
  timeout 1800 vvp -n "$1" "+stem=$2" "+stall=$3" 2>&1 | grep -v 'readmem' > .sim/intake_last.log
  grep -q "^PASS: mb_intake_tb" .sim/intake_last.log
}
report() {    # label name
  local stem="$GEN/intake_$2"
  for st in 0 3; do
    if run_one .sim/intake_sim "$stem" $st; then
      echo "  PASS $1 (stall $st): $(grep '^mb_intake_tb:' .sim/intake_last.log | sed 's/^mb_intake_tb: //')"
    else echo "  FAIL $1 (stall $st)"; grep -m2 FAIL .sim/intake_last.log; fail=1; fi
  done
}
fixture() {   # name stream [max_mbs]
  python3 tools/intake_golden.py "$2" --out "$GEN/intake_$1" ${3:+--max-mbs $3} >> .sim/intake_fx.log 2>&1
}
x264() {      # out size frames extra-params
  ffmpeg -v error -f lavfi -i "testsrc2=size=$2:rate=24" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p \
    -x264-params "$4" -bsf:v h264_mp4toannexb -f h264 -y "$1"
}

echo "== GREEN: x264 streams (refs-free) =="
X264=0
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 .sim/intake_p.264 320x240 6 "cabac=1:8x8dct=0:bframes=0:ref=4:partitions=all:me=umh:subme=7:keyint=6:crf=24" \
  && x264 .sim/intake_b.264 320x240 8 "cabac=1:8x8dct=0:bframes=3:b-pyramid=0:ref=3:partitions=all:direct=spatial:subme=7:keyint=8:crf=24" \
  && x264 .sim/intake_i.264 320x240 2 "cabac=1:8x8dct=0:keyint=1:crf=18" \
  && ffmpeg -v error -f lavfi -i "nullsrc=size=64x64:rate=24,geq=lum='random(1)*255':cb='random(1)*255':cr='random(1)*255'" \
       -frames:v 1 -c:v libx264 -profile:v main -pix_fmt yuv420p -x264-params "cabac=1:8x8dct=0:qp=0" -bsf:v h264_mp4toannexb -f h264 -y .sim/intake_pcm.264 \
  && fixture p .sim/intake_p.264 && fixture b .sim/intake_b.264 && fixture i .sim/intake_i.264 && fixture pcm .sim/intake_pcm.264 \
  && X264=1 || { echo "  FAIL x264 fixtures"; tail -3 .sim/intake_fx.log; fail=1; }
  if [ $X264 = 1 ]; then
    report "x264 P, every partition, 4 refs" p
    report "x264 B, B_8x8 + direct, 3 refs" b
    report "x264 intra (4x4 / 16x16)" i
    report "x264 lossless noise (I_PCM)" pcm
  fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: conformance streams (\$UMD_REFS_DIR) =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
conf() {      # label zip max_mbs
  if [ -f "$AVC/$2.zip" ]; then
    local d; d=$(mktemp -d)
    unzip -o -q "$AVC/$2.zip" -d "$d"
    local f; f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" | head -1)
    if [ -n "$f" ] && fixture "$2" "$f" "$3"; then report "$1" "$2"; else echo "  FAIL $1: fixture"; fail=1; fi
    rm -rf "$d"
  else echo "  SKIP $1: no $AVC/$2.zip"; fi
}
if [ -d "$AVC" ]; then
  conf "CAPM3_Sony_D (I_PCM in P / B), 4000 MBs" CAPM3_Sony_D 4000
  conf "CAWP5_TOSHIBA_E (many refs), 4000 MBs" CAWP5_TOSHIBA_E 4000
else
  echo "  SKIP: no $AVC (set UMD_REFS_DIR)"
fi

echo "== GREEN: disc windows (\$UMD_ISO_DIR) =="
shopt -s nullglob nocaseglob
AK=("$ISO_DIR"/akira*.iso); FG=("$ISO_DIR"/family*guy*.iso)
shopt -u nullglob nocaseglob
if [ -n "${AK[0]:-}" ] && [ -n "${FG[0]:-}" ]; then
  python3 tools/h264_recon_ref.py .sim/intake_ak.264 --disc "${AK[0]}" --clip 1 --pts 180000000 --packs 150 >> .sim/intake_fx.log 2>&1 \
    && fixture ak .sim/intake_ak.264 6000 && report "Akira window, 6000 MBs" ak || { echo "  FAIL Akira fixture"; fail=1; }
  python3 tools/h264_recon_ref.py .sim/intake_fg.264 --disc "${FG[0]}" --clip 1 --pts 27000000 --packs 150 >> .sim/intake_fx.log 2>&1 \
    && fixture fg .sim/intake_fg.264 6000 && report "Family Guy window (fields), 6000 MBs" fg || { echo "  FAIL Family Guy fixture"; fail=1; }
else
  echo "  SKIP: no Akira / Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own stream) =="
  if [ $X264 != 1 ]; then echo "  FAIL: the RED arm needs the x264 fixtures"; fail=1; fi
  RES=$(mktemp -d)
  mut() {   # name old new stream
    local name=$1 old=$2 new=$3 target=$4
    local d; d=$(mktemp -d)
    cp $RTL "$d/"
    python3 - "$d/mb_intake.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/mb_intake.sv" $TB 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 1800 vvp -n "$d/sim" "+stem=$GEN/intake_$target" +stall=0 2>&1 | grep -v readmem > "$d/log"
    if grep -q "^PASS: mb_intake_tb" "$d/log"; then
      { echo "  $name: SURVIVED on $target -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[\(dsc\|coef\)\]" "$d/log"; then
      echo "  $name: caught on $target by $(grep -m1 FAIL "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed on $target but not in [dsc]/[coef]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut I1 "w_cbp <= {(i16_t >= 5'd12) ? ((i16_t - 5'd12) >> 2) : (i16_t >> 2)," "w_cbp <= {(i16_t >= 5'd12) ? ((i16_t - 5'd12) >> 3) : (i16_t >> 3)," i &
  mut I2 "ref_next[lx] <= ref_sel[lx] + 3'd1;" "ref_next[lx] <= ref_sel[lx];" p &
  mut I3 "SS_8X4: m4 = (w_sub == 2'd0) ? 4'b0011 : 4'b1100;" "SS_8X4: m4 = (w_sub == 2'd0) ? 4'b1100 : 4'b0011;" p &
  mut I4 "6'd12: begin b_shape = SH_16X8;  b_p0 = 2'b01; b_p1 = 2'b11; end" "6'd12: begin b_shape = SH_16X8;  b_p0 = 2'b11; b_p1 = 2'b01; end" b &
  wait
  mut I5 "w_direct8 <= {(slice_type == ST_B && in_val[3:0] == 4'd0), w_direct8[3:1]};" "w_direct8 <= {1'b0, w_direct8[3:1]};" b &
  mut I6 "cram_waddr <= blk_pcm ? blk_pos : {blk_slot, blk_pos[3:0]};" "cram_waddr <= {blk_slot, blk_pos[3:0]};" pcm &
  mut I7 "if (!blk_pcm && blk_slot >= 5'd1 && blk_slot <= 5'd16 && in_val != 16'd0)" "if (!blk_pcm && blk_slot >= 5'd1 && blk_slot <= 5'd16)" p &
  mut I8 "if (in_val[0]) i4_blk <= i4_blk + 1'b1;          // no rem follows" "if (1'b0) i4_blk <= i4_blk + 1'b1;" i &
  mut I9 "coef_data <= cram[{rb, coef_addr}];" "coef_data <= cram[{wb, coef_addr}];" i &
  mut I10 "if (w_done && !mb_valid) begin" "if (w_done) begin" p &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
