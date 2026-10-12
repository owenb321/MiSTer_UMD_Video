#!/usr/bin/env bash
# run_recon_top.sh -- the P4 reconstruction gate: umd/h264/recon_top.sv (the whole
# reconstruction, SE words in, pictures in the DPB out) through umd/h264/dpb_mem.sv on two
# real clocks against bench/umd/ddr_model.sv (bench/umd/recon_top_tb.sv), scored against
# tools/h264_recon_ref.py (pixel-exact vs ffmpeg and the H.264.1 YUVs) by
# tools/recon_top_golden.py. docs/h264_recon.md S5.
#
# Arms (bench/umd/recon_top_tb.sv): [pre] every macroblock's samples before deblocking,
# [post] every picture in the DDR model after deblocking, [count] pictures and
# macroblocks, [hang] a macroblock within 200,000 cycles of the previous one.
#
# GREEN:
#   x264 clips (ffmpeg + libx264; refs-free): intra; P with 2 refs; B spatial and temporal
#     direct (partitions=all); explicit weighted P over a fade; implicit weighted B; 3
#     slices a picture with deblocking offsets; P over a sub-pixel scroll with noise (mvq:
#     testsrc2 moves by whole pixels, so p4 never reaches the vertical half-sample filter);
#     16 reference frames at 64x48 (r16: Level 3.0's MaxDpbFrames for 12 macroblocks --
#     16 references + the current picture + the bench's held store need 18 of the 20).
#   H.264.1 conformance ($UMD_REFS_DIR, SKIP without): field pictures, PAFF, weights with
#     list modification, long-term references and MMCOs -- the first pictures of each.
#   JM lencod streams ($UMD_REFS_DIR, SKIP without the JM source): the control paths no x264
#     setting and no disc reaches -- field MMCOs (jfmmco), a long-term reference used in a
#     frame stream (jlt), low-delay B and the list-1 swap (jswap), list modification with
#     its duplicate removal (jmod). tools/jm_fixtures.py writes a fixture only when the
#     model is bit-exact vs ffmpeg on the stream AND the model's counters show the stream
#     reaches the case's own path; lencod is built on first use (tools/jm_build.sh --lencod).
#   --discs: Akira (frames) and Family Guy (fields) windows from $UMD_ISO_DIR (slow:
#     ~20-40 minutes each under Icarus; SKIP without the images).
#
# --red: mutations on a COPY of the RTL, each caught by its own arm on its own clip:
#   R1  mc_interp: the half-sample 6-tap's 20 as 16            (mvq)       -> [pre]
#   R2  deblock_bs: coded coefficients give bS 1, not 2         (sl)        -> [post]
#   (Measured 2026-09-24: on p4 both survive -- whole-pixel motion; and no bS-2 edge of
#   p4 / bsp / mvq filters differently from bS 1 or even bS 0: testsrc2's edges exceed
#   alpha. sl's deblocking offsets bring them in; even bS 2 -> 0 passes elsewhere.)
#   R3  recon_inter: explicit weights skipped (default pred)    (wp)        -> [pre]
#   R4  recon_inter: no opposite-parity chroma offset (T 8-10)  (fields)    -> [pre]
#   R5  recon_mb: the zig-zag scan in a field picture           (fields)    -> [pre]
#   R6  recon_inter: implicit weights' logWD 5 as 4             (wb)        -> [pre]
#   R7  recon_deblock: a vertical edge's p2 not written back     (i2)        -> [post]
#       (only the bS-4 strong filter changes p2: the intra clip)
#   R8  recon_deblock: a horizontal edge's rows written one sample rotated (p4) -> [post]
#   R9  h264_pkg: 16 DPB stores instead of 20                     (r16)       -> [pre] / [count]
#       (picture 17 is the first with 16 references + itself live)
#   R10 recon_inter: the bi prefetch FIFO never advances         (bsp)       -> [pre]
#   R11 recon_inter: row buffers 8..15 aliased onto 0..7 (the lanes) (p4)       -> [pre]
#   R12 recon_mb: an all-zero residual block not marked zero        (p4)        -> [pre]
#   R13 recon_mb: the DDR arbiter grants a write inside a burst     (p4)        -> [pre] / [post] / [hang]
#   R14 recon_mb: the deblocker's writes lost while fb is still e_cur (i2)      -> [post]
#   R15 recon_mb: a DC value never marked nonzero (read as 0)       (i2)        -> [pre]
#   R16 recon_inter: the fetch fills a window bank still being interpolated (bsp) -> [pre]
#   R17 recon_lists: the list-1 swap never taken                    (jswap)     -> [pre]
#   R18 recon_lists: a modification keeps the later duplicate      (jmod)      -> [pre]
#   R19 recon_dpb: a field MMCO 1 leaves the bottom field marked    (jfmmco)    -> [pre] / [post] / [count]
#   R20 recon_dpb: long_term_reference_flag ignored (the IDR short) (jlt)       -> [pre] / [count]
#   O1-O12 the output process (P5d; the arms' lines below)
#   F1  recon_dpb: the wait's alarm counts while the display is frozen (r16f) -> [frz]
#   F2  recon_dpb: the alarm never counts                           (r16a)      -> [alarm]
#   F3  recon_top: disp_frz not passed to recon_dpb                 (r16f)      -> [frz]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/rtop_gate
fail=0
red=0; discs=0
for a in "$@"; do case $a in --red) red=1;; --discs) discs=1;; esac; done
REFS=${UMD_REFS_DIR:-$HOME/umd-refs}
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
GEN=bench/umd/fixtures/gen
W=.sim/rtop_gate
RTL="umd/h264/h264_pkg.sv umd/fifo_dc.sv umd/sfifo.sv umd/h264/dpb_mem.sv umd/h264/recon_hdr.sv umd/h264/recon_dpb.sv
     umd/h264/recon_lists.sv umd/h264/dsf_calc.sv umd/h264/recon_slice_tab.sv umd/h264/mb_intake.sv umd/h264/mv_pred.sv
     umd/h264/mc_interp.sv umd/h264/wpred.sv umd/h264/recon_inter.sv umd/h264/intra_pred.sv umd/h264/dequant_itrans.sv
     umd/h264/deblock_bs.sv umd/h264/deblock_filter.sv umd/h264/recon_deblock.sv umd/h264/recon_mb.sv umd/h264/recon_top.sv"
TB="bench/umd/ddr_model.sv bench/umd/recon_top_tb.sv"
rm -f $W/sim $W/sim_st   # a failed build must not run the last one (the stale-binary trap)
# shellcheck disable=SC2086
iverilog -g2012 -I . -o $W/sim $RTL $TB 2>&1 | grep -v "sorry\|warning" && { echo "FAIL: build"; exit 1; }
[ -f $W/sim ] || { echo "FAIL: build"; exit 1; }
# P6b3i: a second build with recon_dpb's wait bound at 20,000 cycles (11M in the core), so
# r16's holds outlast it: the frozen arm (no alarm) and the unfrozen one (the alarm)
STALL_FLAGS="-Precon_top_tb.STALL=20000"
# shellcheck disable=SC2086
iverilog -g2012 $STALL_FLAGS -I . -o $W/sim_st $RTL $TB 2>&1 | grep -v "sorry\|warning" && { echo "FAIL: build"; exit 1; }
[ -f $W/sim_st ] || { echo "FAIL: build (STALL)"; exit 1; }

STEMS=()
fx() {          # name fixture-command... -> the fixture, log in $W/<name>_fx.log
  local name=$1; shift
  "$@" --out "$GEN/rtop_$name" > "$W/${name}_fx.log" 2>&1
}
run() {         # sim name [stem [plusarg...]] -> the bench's verdict in $W/<name>.log
  local sim=$1 name=$2 stem=${3:-$2}
  shift $(( $# < 3 ? $# : 3 ))
  timeout 7200 vvp -n "$sim" "+stem=$GEN/rtop_$stem" "$@" > "$W/$name.log" 2>&1
}
verdict() {     # label name
  if grep -q "^PASS: recon_top_tb" "$W/$2.log"; then
    echo "  PASS $1: $(grep -m1 '^recon_top_tb:' "$W/$2.log" | sed 's/^recon_top_tb: //')"; STEMS+=("$2")
    grep '^recon_top_tb: the longest wait' "$W/$2.log" | sed 's/^recon_top_tb: /      /'
  else echo "  FAIL $1"; grep -m3 "FAIL" "$W/$2.log" | sed 's/^/    /'; fail=1; fi
}
x264() {        # name size frames params [filter] -> .264 + fixture
  local f="testsrc2=size=$2:rate=24"; [ -n "${5:-}" ] && f="$f,$5"
  ffmpeg -v error -f lavfi -i "$f" -frames:v "$3" -c:v libx264 -pix_fmt yuv420p -x264-params "$4" \
    -bsf:v h264_mp4toannexb -f h264 -y "$W/$1.264" && fx "$1" python3 tools/recon_top_golden.py "$W/$1.264"
}

echo "== GREEN: x264 clips (refs-free) =="
X264=(i2 p4 bsp btm wp wb sl mvq r16)
declare -A XL=([i2]="intra, 2 IDR" [p4]="P, 2 refs" [bsp]="B spatial direct, partitions=all"
               [btm]="B temporal direct" [wp]="explicit weighted P (fade)" [wb]="implicit weighted B (fade)"
               [sl]="3 slices/picture, deblock offsets" [mvq]="P, sub-pixel scroll + noise, qp 36" [r16]="16 reference frames (the DPB at its maximum)")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  x264 i2 64x48 2 "cabac=1:8x8dct=0:keyint=1:crf=24" &
  x264 p4 64x48 4 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=4:crf=26:weightp=0" &
  x264 bsp 64x48 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=spatial:weightp=0:partitions=all" &
  x264 btm 64x48 6 "cabac=1:8x8dct=0:bframes=2:b-pyramid=0:ref=2:keyint=6:crf=26:direct=temporal:weightp=0:partitions=all" &
  x264 wp 64x48 6 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=6:crf=26:weightp=2" "fade=t=out:st=0:d=0.25" &
  x264 wb 64x48 6 "cabac=1:8x8dct=0:bframes=2:ref=2:keyint=6:crf=26:weightb=1:weightp=2" "fade=t=out:st=0:d=0.25" &
  x264 sl 96x64 4 "cabac=1:8x8dct=0:bframes=1:ref=2:keyint=4:crf=24:slices=3:deblock=1,-2" &
  x264 mvq 64x48 5 "cabac=1:8x8dct=0:bframes=0:ref=2:keyint=5:qp=36:weightp=0:subme=7" "scroll=h=0.013:v=0.021,noise=alls=10:allf=t:all_seed=7" &
  x264 r16 64x48 30 "cabac=1:8x8dct=0:bframes=0:ref=16:keyint=60:min-keyint=60:scenecut=0:crf=26:weightp=0" "scroll=h=0.013:v=0.021" &
  wait
  for n in "${X264[@]}"; do run $W/sim $n & done; wait
  for n in "${X264[@]}"; do verdict "${XL[$n]} ($n)" $n; done
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: the output process (P5d: C.4.4 / C.4.5, the display's holds) =="
# c44b: B pictures, two IDRs, x264's VUI DPB size (non-reference pictures output directly,
# C.4.5.2); c44n: its second IDR's no_output_of_prior_pics_flag set (the waiting stores
# dropped, not output -- JM agrees, ffmpeg ignores the flag); c44m: MMCO 5 on the last
# reference before the second IDR (the others bumped BEFORE the POC rewrite). Both
# rewrites drop the VUI: the DPB size from Table A-1. r16s: r16 with holds long enough
# that the decoder must wait for a release (+expect_stall): the stall path, no error.
# P6b3i, on the short-bound build: r16f the same holds with the display frozen (a wait
# outlasts the bound, no error counted: a pause is no alarm); r16a unfrozen (the
# no-free-store alarm counts, every picture still exact).
C44=(c44b c44n c44m)
declare -A OL=([c44b]="B pictures, direct output (C.4.5.2)" [c44n]="no_output_of_prior_pics_flag (C.4.4)"
               [c44m]="MMCO 5 bumps everything (C.4.4)")
if ffmpeg -hide_banner -encoders 2>/dev/null | grep -q libx264; then
  c44() {       # name x264-params [synth kind]
    ffmpeg -v error -f lavfi -i testsrc2=size=64x64:rate=24 -frames:v 14 -c:v libx264 -pix_fmt yuv420p \
      -x264-params "cabac=1:8x8dct=0:keyint=7:min-keyint=7:scenecut=0:weightp=0:$2" -f h264 -y "$W/$1.264" || return
    if [ -n "${3:-}" ]; then python3 tools/h264_synth.py "$W/$1.264" "$3" "$W/$1s.264" > "$W/${1}_synth.log" 2>&1 \
                             && mv "$W/$1s.264" "$W/$1.264" || return; fi
    fx "$1" python3 tools/recon_top_golden.py "$W/$1.264"
  }
  c44 c44b "bframes=2:b-pyramid=0:ref=2" &
  c44 c44n "bframes=2:b-pyramid=0:ref=2" no_output &
  c44 c44m "bframes=0:ref=1" mmco5 &
  wait
  for n in "${C44[@]}"; do run $W/sim $n & done
  if [[ " ${STEMS[*]} " =~ " r16 " ]]; then
    run $W/sim r16s r16 +hold=600000 +expect_stall &
    run $W/sim_st r16f r16 +hold=600000 +expect_stall +frozen &
    run $W/sim_st r16a r16 +hold=600000 +expect_stall +expect_alarm &
  fi
  wait
  for n in "${C44[@]}"; do verdict "${OL[$n]} ($n)" $n; done
  if [[ " ${STEMS[*]} " =~ " r16 " ]]; then
    verdict "the display holds, the decoder waits (r16s)" r16s
    verdict "the display frozen: its holds are no alarm (r16f)" r16f
    verdict "unfrozen holds past the bound: the alarm (r16a)" r16a
  else echo "  FAIL the display holds: r16 not GREEN in this run"; fail=1; fi
else
  echo "  SKIP: ffmpeg with libx264 not found"
fi

echo "== GREEN: H.264.1 conformance (\$UMD_REFS_DIR), the first pictures =="
AVC="$REFS/H.264.1_bitstreams/AVCv1"
CONF=(CAFI1_SVA_C cabac_mot_fld0_full CAPA1_TOSHIBA_B CAWP5_TOSHIBA_E CABREF3_Sand_D)
declare -A CL=([CAFI1_SVA_C]="fields, spatial direct" [cabac_mot_fld0_full]="fields, P and B"
               [CAPA1_TOSHIBA_B]="PAFF" [CAWP5_TOSHIBA_E]="explicit weights, list modification"
               [CABREF3_Sand_D]="fields (its long-term / MMCO pictures come later: jlt / jfmmco)")
CONF_OK=()
if [ -d "$AVC" ]; then
  for c in "${CONF[@]}"; do
    if [ -f "$AVC/$c.zip" ]; then
      (d=$(mktemp -d); unzip -o -q "$AVC/$c.zip" -d "$d"
       f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" | head -1)
       fx "$c" python3 tools/recon_top_golden.py "$f" --max-pics 4; rm -rf "$d") &
      CONF_OK+=("$c")
    else echo "  SKIP ${CL[$c]}: no $AVC/$c.zip"; fi
  done
  wait
  # fodd: the field stream cut after an odd picture -- its last first field has no
  # partner, and the end of stream emits it UNPAIRED (P5d)
  if [ -f "$AVC/cabac_mot_fld0_full.zip" ]; then
    d=$(mktemp -d); unzip -o -q "$AVC/cabac_mot_fld0_full.zip" -d "$d"
    f=$(find "$d" -iname "*.jsv" -o -iname "*.264" -o -iname "*.26l" -o -iname "*.jvt" -o -iname "*.avc" | head -1)
    fx fodd python3 tools/recon_top_golden.py "$f" --max-pics 5; rm -rf "$d"
    CONF_OK+=(fodd); CL[fodd]="fields, cut after a first field: unpaired at the end"
  fi
  for c in "${CONF_OK[@]}"; do run $W/sim "$c" & done; wait
  for c in "${CONF_OK[@]}"; do verdict "${CL[$c]} ($c)" "$c"; done
else
  echo "  SKIP: no $AVC (set UMD_REFS_DIR)"
fi

echo "== GREEN: JM lencod control-path streams (\$UMD_REFS_DIR) =="
JMCASES=(jfmmco jlt jswap jmod jdefer)
declare -A JL=([jfmmco]="field pictures with MMCOs" [jlt]="a long-term reference in a frame stream"
               [jswap]="low-delay B, the list-1 swap" [jmod]="list modification, duplicates removed"
               [jdefer]="B field pairs output directly, emitted with the second field")
LENCOD="$REFS/JM/build_enc/bin/lencod.exe"
if [ ! -x "$LENCOD" ] && [ -d "$REFS/JM/lencod/src" ]; then
  UMD_REFS_DIR="$REFS" bash tools/jm_build.sh --lencod > $W/lencod_build.log 2>&1
fi
if [ -x "$LENCOD" ]; then
  # a stale fixture must not stand in for one this run could not write
  for c in "${JMCASES[@]}"; do (rm -f "$GEN/rtop_$c".*; fx "$c" python3 tools/jm_fixtures.py "$c" --lencod "$LENCOD") & done
  wait
  for c in "${JMCASES[@]}"; do
    if [ -f "$GEN/rtop_$c.meta.hex" ]; then run $W/sim "$c" &
    else echo "  FAIL ${JL[$c]} ($c): $(grep -m1 'FAIL\|Error\|rror' $W/${c}_fx.log | cut -c1-200)"; fail=1; fi
  done
  wait
  for c in "${JMCASES[@]}"; do [ -f "$GEN/rtop_$c.meta.hex" ] && verdict "${JL[$c]} ($c)" "$c"; done
else
  echo "  SKIP: no JM source / lencod under $REFS (set UMD_REFS_DIR)"
fi

echo "== GREEN: disc windows (\$UMD_ISO_DIR) =="
if [ $discs = 1 ]; then
  shopt -s nullglob nocaseglob
  AK=("$ISO_DIR"/akira*.iso); FG=("$ISO_DIR"/family*guy*.iso)
  shopt -u nullglob nocaseglob
  if [ -n "${AK[0]:-}" ] && [ -n "${FG[0]:-}" ]; then
    (fx ak python3 tools/recon_top_golden.py --disc "${AK[0]}" --clip 1 --pts 180000000 --packs 80 --max-pics 4 && run $W/sim ak) &
    (fx fg python3 tools/recon_top_golden.py --disc "${FG[0]}" --clip 1 --pts 27000000 --packs 80 --max-pics 6 && run $W/sim fg) &
    wait
    verdict "Akira window (frames)" ak; verdict "Family Guy window (fields)" fg
  else
    echo "  SKIP: no Akira / Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"
  fi
else
  echo "  SKIP: pass --discs (slow)"
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  FIELDS=cabac_mot_fld0_full
  RES=$(mktemp -d)
  mut() {   # name file old new clip arm [plusargs [iverilog flags]]
    local name=$1 file=$2 old=$3 new=$4 clip=$5 arm=$6 extra=${7:-} iflags=${8:-}
    if [ ! -f "$GEN/rtop_$clip.se.hex" ] || [[ ! " ${STEMS[*]} " =~ " $clip " ]]; then
      { echo "  $name: clip $clip not GREEN in this run -- cannot score"; echo MUTFAIL; } > "$RES/$name"; return
    fi
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/h264"
    for f in $RTL; do cp "$f" "$d/$f"; done
    cp umd/h264/*.svh "$d/umd/h264/" 2>/dev/null
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    local pyrc=$?          # the anchor edit's status (a later loop would mask it)
    local tbs=""; for f in $TB; do tbs="$tbs $PWD/$f"; done
    # compiled FROM the copy: iverilog resolves `include "umd/h264/..." against the working
    # directory BEFORE any -I, so compiled from the repo root a mutated .svh (recon_mb_fsm)
    # was silently replaced by the repo's own -- R12-R14 once "survived" for that reason
    # shellcheck disable=SC2086
    if [ $pyrc != 0 ] || ! (cd "$d" && iverilog -g2012 $iflags -I . -o sim $RTL $tbs) 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 7200 vvp -n "$d/sim" "+stem=$GEN/rtop_$clip" $extra > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut R1 umd/h264/mc_interp.sv "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4) + (vp2s <<< 2);" \
         "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4);" mvq pre &
  mut R2 umd/h264/deblock_bs.sv "else if (p_nz || q_nz)    bs_c = 3'd2;" "else if (p_nz || q_nz)    bs_c = 3'd1;" sl post &
  mut R3 umd/h264/recon_inter.sv "wp_mode <= explicit ? 2'd1 : 2'd0;" "wp_mode <= 2'd0;" wp pre &
  mut R4 umd/h264/recon_inter.sv "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;" \
         "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy;" $FIELDS pre &
  mut R5 umd/h264/recon_mb.sv ".field_scan(field_pic)" ".field_scan(1'b0)" $FIELDS pre &
  mut R6 umd/h264/recon_inter.sv "wp_mode <= 2'd1; wp_logwd <= 3'd5;" "wp_mode <= 2'd1; wp_logwd <= 3'd4;" wb pre &
  mut R7 umd/h264/recon_deblock.sv "(is_c ? 8'h08 : 8'h0E) << poff" "(is_c ? 8'h08 : 8'h0C) << poff" i2 post &
  mut R9 umd/h264/h264_pkg.sv "localparam int NSTORE = 20;" "localparam int NSTORE = 16;" r16 "pre|count|hang" &
  mut R8 umd/h264/recon_deblock.sv "wr_data <= hr[1]; wr_be <= 8'hFF;" \
         "wr_data <= {hr[1][7:0], hr[1][63:8]}; wr_be <= 8'hFF;" p4 post &
  mut R10 umd/h264/recon_inter.sv "if (kd_bi && wp_a_ready) pf_h <= pf_h + 1'b1;" "if (1'b0) pf_h <= pf_h + 1'b1;" bsp pre &
  mut R11 umd/h264/recon_inter.sv "if (rx_we) m[{rx_row[3:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];" "if (rx_we) m[{1'b0, rx_row[2:0], rx_word[1:0]}] <= rd_data[8*gl +: 8];" p4 pre &
  mut R12 umd/h264/recon_mb_fsm.svh "if (!is_dc) begin res_rdy[id] <= 1'b1; res_zero[id] <= 1'b1; end" \
         "if (!is_dc) begin res_rdy[id] <= 1'b1; res_zero[id] <= 1'b0; end" p4 pre &
  mut R13 umd/h264/recon_mb_fsm.svh "wire         grant_e = !fq_valid && e_cmd_valid && (w_left == 4'd0);" \
         "wire         grant_e = !fq_valid && e_cmd_valid;" p4 "pre|post|ddr|hang" &
  mut R14 umd/h264/recon_mb_fsm.svh "bk_we[e_cur] = 1'b1; bk_waddr[e_cur] = db_wr_addr;" "bk_we[e_cur] = (e_cur != fb); bk_waddr[e_cur] = db_wr_addr;" i2 post &
  mut R15 umd/h264/recon_mb_fsm.svh "dc_nz[wa] <= (dq_res != 16'sd0);" "dc_nz[wa] <= 1'b0;" i2 pre &
  mut R16 umd/h264/recon_inter.sv "I_LIST: if (!bank_full[fb]) begin" "I_LIST: if (1'b1) begin" bsp pre &
  mut R17 umd/h264/recon_lists.sv "if (sw_same && lq0 == lq1 && n_init[1] > 6'd1) ls <= L_SWAP_W0;" "if (1'b0) ls <= L_SWAP_W0;" jswap pre &
  mut R18 umd/h264/recon_lists.sv "if (!ent_match) begin" "if (1'b1) begin" jmod pre &
  mut R19 umd/h264/recon_dpb.sv "if (y_ms_b) ref_b[dx] <= UNUSED;" "if (1'b0) ref_b[dx] <= UNUSED;" jfmmco "pre|post|count" &
  mut R20 umd/h264/recon_dpb.sv "cur_ltref <= sh_long_term_reference;" "cur_ltref <= 1'b0;" jlt "pre|count" &
  wait
  # P5d, the output process (sequenced: memory)
  mut O1 umd/h264/recon_dpb.sv "(!best_found || sq_poc < best_poc)" "(!best_found || sq_poc > best_poc)" c44b out &
  mut O2 umd/h264/recon_dpb.sv "5'd1 : s.max_dec_frame_buffering;" "5'd1 : s.max_dec_frame_buffering + 5'd1;" c44b out &
  mut O3 umd/h264/recon_dpb.sv "sz_acc <= sz_acc - {2'd0, sz_pic}; sz_cnt <= sz_cnt + 5'd1;" \
         "sz_acc <= '0; sz_cnt <= sz_cnt + 5'd1;" c44m out &
  mut O4 umd/h264/recon_dpb.sv "if (cur_idr && cur_no_output) begin" "if (1'b0) begin" c44n out &
  mut O5 umd/h264/recon_dpb.sv "end else if (cur_idr || cur_mmco5) begin" "end else if (cur_idr) begin" c44m out &
  mut O6 umd/h264/recon_dpb.sv "bump_it = best_found && ((om != OM_NONREF) || (best_poc <= cur_poc));" \
         "bump_it = best_found;" c44b out &
  mut O7 umd/h264/recon_dpb.sv "end else pend_emit[cur_store] <= 1'b1;" "end else pend_emit[cur_store] <= 1'b0;" jdefer out &
  mut O8 umd/h264/recon_dpb.sv "om <= OM_EOS; di <= '0; best_found <= 1'b0; ds <= D_OUT_SCAN;" \
         "eos_done <= 1'b1; eos_mode <= 1'b0; busy <= 1'b0; ds <= D_IDLE;" c44b out &
  wait
  mut O9 umd/h264/recon_dpb.sv "if (!pairing && !op_free && (|disp_hold)) begin" "if (1'b0) begin" r16 "count|hold|pre|post" \
         "+hold=600000 +expect_stall" &
  mut O10 umd/h264/recon_dpb.sv "|| disp_hold[i] || waiting[i] ||" "|| disp_hold[i] ||" c44m "out|post|pre" &
  mut O11 umd/h264/recon_dpb.sv "emit_unpaired <= !frame_coded[best_store] && !(dec_t[best_store] && dec_b[best_store]);" \
         "emit_unpaired <= 1'b0;" fodd out &
  mut O12 umd/h264/recon_top.sv $'.sh_no_output_of_prior_pics(sh_no_output),\n' \
          $'.sh_no_output_of_prior_pics(1\'b0),\n' c44n out &
  wait
  # P6b3i, the wait's alarm (short-bound build)
  mut F1 umd/h264/recon_dpb.sv $'stall_ctr <= disp_frz ? 24\'d0 : stall_ctr + 24\'d2;\n                        if (!disp_frz && ' \
         $'stall_ctr <= stall_ctr + 24\'d2;\n                        if (' r16 frz "+hold=600000 +expect_stall +frozen" "$STALL_FLAGS" &
  mut F2 umd/h264/recon_dpb.sv "if (!disp_frz && stall_ctr >= STALL_LIMIT[23:0])" "if (1'b0 && stall_ctr >= STALL_LIMIT[23:0])" \
         r16 alarm "+hold=600000 +expect_stall +expect_alarm" "$STALL_FLAGS" &
  mut F3 umd/h264/recon_top.sv ".disp_frz(disp_frz)," ".disp_frz(1'b0)," r16 frz "+hold=600000 +expect_stall +frozen" "$STALL_FLAGS" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
