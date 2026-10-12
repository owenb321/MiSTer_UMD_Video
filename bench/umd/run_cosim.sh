#!/usr/bin/env bash
# run_cosim.sh -- the P4 disc cosim: the decoder as emu composes it (umd/h264/h264_top.sv ->
# umd/h264/recon_top.sv, bench/umd/cosim_top.sv) Verilated with the C++ harness
# bench/umd/cosim_main.cpp (its DDR model is ddr_model.sv's), fed a window of a disc's main
# title as ES bytes and scored against tools/cosim_golden.py: the model's decode-order
# pictures, the model itself checked against ffmpeg on the same window first.
# docs/h264_recon.md S5.
#
# Arms (cosim_main.cpp): [pre] every macroblock pre-deblock, [post] every picture in the
# DDR model, [count] pictures / macroblocks / no error or refusal on either half, [hang]
# a macroblock within 200,000 cycles, [ddr] the Avalon rules, [out] every store emitted in
# the model's output order and at its time (P5d), [hold] no write into a store the
# display holds (the harness is the display: random holds, then releases).
#
#   run_cosim.sh [--frames N]           GREEN: Akira (frames) and Family Guy (fields)
#   run_cosim.sh --sweep [--jobs J (5)] [--frames N] [--match GLOB]...
#                                        every image in $UMD_ISO_DIR and its folders one
#                                        level down (.iso, and .zip
#                                        holding one: unpacked to scratch, one at a time
#                                        per job); a table in .sim/cosim/sweep.tsv
#                                        A FULL sweep (no --match, the RTL, the default
#                                        window) also writes .sim/cosim/census.tsv: each
#                                        disc's verdict, real-time factor, cycles a
#                                        macroblock and stream features (STEM.feat,
#                                        tools/cosim_features.py) -- what --sample chooses from
#   run_cosim.sh --sample [--tail N (3)] [--frames N] [--jobs J]
#                                        a sample of the library chosen from the census
#                                        (tools/cosim_sample.py): every disc the census has as
#                                        FAIL, the N slowest windows (throughput is content,
#                                        not features), then a greedy cover of every stream
#                                        feature, plus any disc newer than the census (its
#                                        features unknown). The gate for a change that keeps
#                                        the cycle counts; a change that alters cycles or what
#                                        is decoded, and a release, take the full --sweep
#                                        (docs/h264_recon.md S5 "The sample")
#   run_cosim.sh ... --ep-start          the window starts AT a video EP entry, the first
#                                        non-IDR one from 40 % of the title, as a seek lands:
#                                        the recovery-point start (P6b, docs/transport.md
#                                        S2.2; cosim_golden.py --ep-start --non-idr). The RTL
#                                        passes it from P6b1 on.
#   run_cosim.sh ... --seek              P6b1, a mid-stream SEEK: window A from an IDR, the
#                                        decoder reset half-way through A's last picture (the
#                                        mount's reset and ddr_mux2's abort, the parameter sets
#                                        kept), then window B from a non-IDR entry at 70 % with
#                                        its SPS / PPS stripped where A's equal them
#                                        (cosim_golden.py --seek; the harness: cosim_main.cpp)
#   run_cosim.sh ... --trick             P6b4, TRICK PLAY: from the same non-IDR entry as
#                                        --ep-start, h264_top's one_frame set: the RTL is fed
#                                        a longer window (STEM_long.es, --frames 8) and scored
#                                        against the golden of the entry's FIRST FRAME alone
#                                        (--frames 1, a field pair one frame): the stream must
#                                        end at the next access unit, the entry's I emitted
#                                        bit-exact by the end-of-stream flush, nothing after
#                                        it decoded (cosim_main.cpp +one_frame +es=)
#   run_cosim.sh ... --model-only         no Verilator: the golden alone, i.e. the model
#                                        against ffmpeg (PASS = bit-exact; the P6b0 gate
#                                        with --sweep --ep-start)
#   run_cosim.sh --red                   mutations on a COPY of the RTL (compiled from
#                                        inside the copy: iverilog / Verilator resolve
#                                        `include "umd/..." against the working directory),
#                                        each caught by its own arm on a short window:
#     C1 mc_interp: the half-sample 6-tap's 20 as 16             (Akira)  -> [pre]
#     C2 deblock_bs: coded coefficients give bS 1, not 2          (Akira)  -> [post]
#     C3 recon_inter: no opposite-parity chroma offset (T 8-10)   (Family Guy) -> [pre]
#     C4 nal_parser: emulation prevention bytes kept              (Akira)  -> [pre] / [count] / [hang]
#     C5 recon_mb: the DDR arbiter grants a write inside a burst  (Akira)  -> [hang] / [pre] / [post] / [ddr]
#     C6 dpb_mem: a write issued with read beats outstanding     (Akira)  -> [ddr]
#     C7 recon_dpb: the bump takes the LARGEST POC                (Family Guy) -> [out]
#     C8 recon_dpb: the VUI's DPB size one larger (output late)   (Akira)  -> [out]
#   P6b1, the recovery-point start, on the same titles from a non-IDR EP entry (--ep-start
#   windows; the model's counts in STEM.rp):
#     C9  recon_dpb: the leading pictures decoded, not skipped     (Family Guy) -> [count] / [pre]
#     C10 recon_dpb: a non-IDR start keeps PrevRefFrameNum (a gap) (Akira)  -> [count]
#     C11 recon_top: a skipped slice's words not discarded         (Akira)  -> [hang] / [count] / [pre]
#   P6b1, the seek (--seek windows: the decoder reset mid-picture, B from a non-IDR entry
#   with its SPS stripped):
#     C12 sps_pps: the parameter sets reset with the decoder       (Akira)  -> [count] / [out]
#     C13 recon_hdr: the parameter sets reset with the decoder     (Family Guy) -> [count]
#     C14 ddr_mux2: no abort (the reset on an open write burst)    (Akira)  -> [ddr] / [avalon] / [hang] / ...
#     C15 recon_dpb: the reset does not arm the start              (Family Guy) -> [count] / [pre]
#   P6b4, trick play (--trick windows: the first frame of a longer window):
#     C16 h264_top: the cut after the FIRST FIELD of a pair         (Family Guy) -> [count] / [out]
#     C17 h264_top: no cut (the stream decodes on)                  (Akira)  -> [count] / [pre] / [out]
#     C18 h264_top: the cut with no end-of-stream word (the I held) (Akira)  -> [hang] / [out]
#   P8 (2026-10-07), the scoring the item-start chase added (docs/transport.md "D8, the handoff measured"):
#     C19 recon_top: a size refusal counted on every I slice (the decode unchanged)  (Akira) -> [count]
#     C20 h264_top: the PTS word sent as a NAL word -- only a window fed the PES sideband
#         (akm: Akira's main title from its first byte, cosim_golden.py --raw --marks, +marks=) can see it
#                                                                                 (Akira, marked) -> [count] / [pre] / [hang] / [out]
#   NOT COVERABLE here: the MMCO tolerance after a start (no disc uses MMCOs): x264's open
#   GOP in run_recon_ctl.sh
#
# Verdicts per disc: PASS (with cycles a macroblock and frames/s at 81 MHz under the DDR
# model), FAIL [arm], SKIP (a damaged rip, no video), REFUSED (the model refuses the stream:
# a scoping decision such as CAVLC or MBAFF -- the core must refuse it loudly too; not a
# decode failure), ORACLE (the model and ffmpeg disagree: the window is not scored).
# Exit 0 only when nothing FAILs and no ORACLE mismatch occurs. Needs verilator,
# ffmpeg, unzip for .zip images.
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/cosim
mkdir -p $W
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
frames=300; sweep=0; sample=0; tail=3; red=0; jobs=5; matches=(); epstart=(); model_only=0; trick=0
while [ $# -gt 0 ]; do
  case $1 in
    --frames) frames=$2; shift;;
    --sweep) sweep=1;;
    --sample) sample=1;;
    --tail) tail=$2; shift;;
    --red) red=1;;
    --jobs) jobs=$2; shift;;
    --match) matches+=("$2"); shift;;
    --ep-start) epstart=(--ep-start --non-idr);;
    --seek) epstart=(--seek);;
    --trick) epstart=(--ep-start --non-idr); trick=1;;
    --model-only) model_only=1;;
  esac
  shift
done
[ $model_only = 1 ] && [ $red = 1 ] && { echo "run_cosim: --red needs the RTL (not --model-only)"; exit 2; }
[ $sample = 1 ] && [ $sweep = 1 ] && { echo "run_cosim: --sample or --sweep, not both"; exit 2; }
[ $sample = 1 ] && [ ${#matches[@]} -gt 0 ] && { echo "run_cosim: --sample chooses the discs (no --match)"; exit 2; }
[ $model_only = 1 ] || command -v verilator >/dev/null || { echo "run_cosim: SKIP -- no verilator"; exit 2; }

FE="umd/h264/nal_parser.sv umd/h264/rbsp_reader.sv umd/h264/sps_pps.sv umd/h264/slice_hdr.sv
    umd/h264/cabac_ctx.sv umd/h264/cabac_engine.sv umd/h264/mb_syntax.sv umd/h264/au_pts.sv umd/h264/sei_pt.sv umd/h264/h264_top.sv"
RC="umd/fifo_dc.sv umd/sfifo.sv umd/h264/dpb_mem.sv umd/h264/recon_hdr.sv umd/h264/recon_dpb.sv
    umd/h264/recon_lists.sv umd/h264/dsf_calc.sv umd/h264/recon_slice_tab.sv umd/h264/mb_intake.sv
    umd/h264/mv_pred.sv umd/h264/mc_interp.sv umd/h264/wpred.sv umd/h264/recon_inter.sv
    umd/h264/intra_pred.sv umd/h264/dequant_itrans.sv umd/h264/deblock_bs.sv umd/h264/deblock_filter.sv
    umd/h264/recon_deblock.sv umd/h264/recon_mb.sv umd/h264/recon_top.sv"
RTL="umd/h264/h264_pkg.sv $FE $RC umd/cdc.sv umd/ddr_mux2.sv"    # (the last two: the seek path as emu builds it, P6b1)

build() {       # SRC_DIR OBJ_DIR -> OBJ_DIR/cosim, compiled from inside SRC_DIR
  local src=$1 obj=$2
  # shellcheck disable=SC2086
  (cd "$src" && verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast \
     -Wno-fatal -Wno-lint -Wno-style -Wno-LATCH -Wno-MULTIDRIVEN -I. --top-module cosim_top \
     -Mdir "$obj" -o cosim -MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2' \
     $RTL "$ROOT/bench/umd/cosim_top.sv" "$ROOT/bench/umd/cosim_main.cpp") > "$obj.build.log" 2>&1 \
     && [ -x "$obj/cosim" ]
}

golden() {      # IMAGE STEM [frames] -> exit status of cosim_golden.py, its line in STEM.golden.log
  if [ $trick = 1 ]; then   # P6b4: the entry's first frame, and a longer window to feed (STEM_long.es)
    python3 tools/cosim_golden.py --disc "$1" --out "$2" --frames 1 "${epstart[@]}" > "$2.golden.log" 2>&1 || return $?
    python3 tools/cosim_golden.py --disc "$1" --out "$2_long" --frames 8 "${epstart[@]}" --es-only >> "$2.golden.log" 2>&1
    return $?
  fi
  python3 tools/cosim_golden.py --disc "$1" --out "$2" --frames "${3:-$frames}" "${epstart[@]}" > "$2.golden.log" 2>&1
}

if [ $model_only = 0 ]; then
  echo "== build =="
  if ! build "$ROOT" "$ROOT/$W/obj"; then echo "FAIL: build ($W/obj.build.log)"; tail -5 "$W/obj.build.log"; exit 1; fi
  echo "  built $W/obj/cosim"
fi

shopt -s nullglob nocaseglob
AK=("$ISO_DIR"/akira*.iso); FG=("$ISO_DIR"/family*guy*.iso)
shopt -u nullglob nocaseglob
fail=0

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  if [ -z "${AK[0]:-}" ] || [ -z "${FG[0]:-}" ]; then echo "  SKIP: no Akira / Family Guy image in $ISO_DIR"; exit 2; fi
  golden "${AK[0]}" $W/red_ak 12 || { echo "FAIL: golden (Akira)"; cat $W/red_ak.golden.log; exit 1; }
  golden "${FG[0]}" $W/red_fg 12 || { echo "FAIL: golden (Family Guy)"; cat $W/red_fg.golden.log; exit 1; }
  # P6b1: the same titles from a NON-IDR entry (the recovery-point start)
  for g in ak:AK fg:FG; do
    img=${g#*:}; img=${img}[0]
    python3 tools/cosim_golden.py --disc "${!img}" --out $W/red_${g%:*}e --frames 12 --ep-start --non-idr \
      > $W/red_${g%:*}e.golden.log 2>&1 || { echo "FAIL: golden (red_${g%:*}e)"; cat $W/red_${g%:*}e.golden.log; exit 1; }
  done
  # P6b1: a mid-stream seek on each (the reset on an open write burst: +seek_on=burst below)
  for g in ak:AK fg:FG; do
    img=${g#*:}; img=${img}[0]
    python3 tools/cosim_golden.py --disc "${!img}" --out $W/red_${g%:*}s --frames 16 --seek \
      > $W/red_${g%:*}s.golden.log 2>&1 || { echo "FAIL: golden (red_${g%:*}s)"; cat $W/red_${g%:*}s.golden.log; exit 1; }
  done
  # P8: Akira's main title from its first byte, with the PES sideband (STEM.marks)
  python3 tools/cosim_golden.py --disc "${AK[0]}" --out $W/red_akm --frames 12 --raw --marks 0 \
    > $W/red_akm.golden.log 2>&1 || { echo "FAIL: golden (red_akm)"; cat $W/red_akm.golden.log; exit 1; }
  $W/obj/cosim $W/red_akm +label=red_akm +marks=$W/red_akm.marks > $W/red_akm.log 2>&1
  grep -q "^PASS: cosim" $W/red_akm.log || { echo "FAIL: the unmutated control on red_akm"; grep -m2 FAIL $W/red_akm.log; exit 1; }
  [ -s $W/red_akm.marks ] || { echo "FAIL: red_akm has no marks (the sideband would not be exercised)"; exit 1; }
  # P6b4: trick play on each (the first frame of a longer window)
  for g in ak:AK fg:FG; do
    img=${g#*:}; img=${img}[0]
    { python3 tools/cosim_golden.py --disc "${!img}" --out $W/red_${g%:*}t --frames 1 --ep-start --non-idr &&
      python3 tools/cosim_golden.py --disc "${!img}" --out $W/red_${g%:*}t_long --frames 8 --ep-start --non-idr --es-only; } \
      > $W/red_${g%:*}t.golden.log 2>&1 || { echo "FAIL: golden (red_${g%:*}t)"; cat $W/red_${g%:*}t.golden.log; exit 1; }
  done
  for g in akt fgt; do
    $W/obj/cosim $W/red_$g +label=red_$g +one_frame +es=$W/red_${g}_long.es > $W/red_$g.log 2>&1
    grep -q "^PASS: cosim" $W/red_$g.log || { echo "FAIL: the unmutated control on red_$g"; grep -m2 FAIL $W/red_$g.log; exit 1; }
  done
  for g in ak fg ake fge aks fgs; do
    $W/obj/cosim $W/red_$g +label=red_$g > $W/red_$g.log 2>&1
    grep -q "^PASS: cosim" $W/red_$g.log || { echo "FAIL: the unmutated control on red_$g"; grep -m2 FAIL $W/red_$g.log; exit 1; }
  done
  for g in aks fgs; do                        # and the seek windows with the reset on an open burst
    $W/obj/cosim $W/red_$g +label=red_${g}b +seek_mbs=1 +seek_on=burst > $W/red_${g}b.log 2>&1
    grep -q "^PASS: cosim" $W/red_${g}b.log || { echo "FAIL: the unmutated control on red_${g} (burst)"; grep -m2 FAIL $W/red_${g}b.log; exit 1; }
    grep -q "open write burst [1-9]" $W/red_${g}b.log || { echo "FAIL: red_${g} (burst): the abort met no open burst"; exit 1; }
  done
  echo "  control: all nine windows PASS unmutated (the seek windows also with the reset on an open burst; akm with its marks)"
  RES=$(mktemp -d)
  mut() {   # name file old new window arm [plusargs]
    local name=$1 file=$2 old=$3 new=$4 win=$5 arm=$6 plus=${7:-}
    local d; d=$(mktemp -d)
    for f in $RTL; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
    cp umd/h264/*.svh "$d/umd/h264/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # the builds one at a time (eight compilers each); the simulations in parallel
    if [ $? != 0 ] || ! flock "$ROOT/$W/build.lock" bash -c "$(declare -f build); ROOT='$ROOT' RTL='$RTL' build '$d' '$d/obj'"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 3600 "$d/obj/cosim" $W/red_$win +label=$name $plus > "$d/log" 2>&1
    if grep -q "^PASS: cosim" "$d/log"; then
      { echo "  $name: SURVIVED -- the cosim cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut C1 umd/h264/mc_interp.sv "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4) + (vp2s <<< 2);" \
         "h1  <= vp0s - (vp1s <<< 2) - vp1s + (vp2s <<< 4);" ak pre &
  mut C2 umd/h264/deblock_bs.sv "else if (p_nz || q_nz)    bs_c = 3'd2;" "else if (p_nz || q_nz)    bs_c = 3'd1;" ak post &
  mut C3 umd/h264/recon_inter.sv "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy + 16'sd2;" \
         "if (field_pic && gcode[1:0] == 2'd1 && bottom)  cmvy = gmvy;" fg pre &
  mut C4 umd/h264/nal_parser.sv "wire is_epb   = (zeros >= 2'd2) && (in_byte == 8'h03);" "wire is_epb   = 1'b0;" ak "pre|count|hang" &
  mut C5 umd/h264/recon_mb_fsm.svh "wire         grant_e = !fq_valid && e_cmd_valid && (w_left == 4'd0);" \
         "wire         grant_e = !fq_valid && e_cmd_valid;" ak "hang|pre|post|ddr" &
  mut C6 umd/h264/dpb_mem.sv "(!c_write ? credit_ok : (outstanding == '0 && !ddr_readdatavalid));" \
         "(!c_write ? credit_ok : 1'b1);" ak ddr &
  mut C7 umd/h264/recon_dpb.sv "(!best_found || sq_poc < best_poc)" "(!best_found || sq_poc > best_poc)" fg out &
  mut C8 umd/h264/recon_dpb.sv "5'd1 : s.max_dec_frame_buffering;" "5'd1 : s.max_dec_frame_buffering + 5'd1;" ak out &
  wait
  # P6b1, the recovery-point start, on the non-IDR windows (built after C1-C8: memory)
  mut C9 umd/h264/recon_dpb.sv "rp_cap <= 1'b0; rp_leadm <= 1'b1;" "rp_cap <= 1'b0; rp_leadm <= 1'b0;" fge "count|pre" &
  mut C10 umd/h264/recon_dpb.sv "prev_ref_fn <= sh_frame_num; prev_fn <= sh_frame_num; prev_fno <= '0;" \
          "prev_fn <= sh_frame_num; prev_fno <= '0;" ake count &
  mut C11 umd/h264/recon_top.sv "R_SLICE_WAIT: if (dpb_skip) rs <= R_DISCARD;" "R_SLICE_WAIT: if (1'b0) rs <= R_DISCARD;" \
          ake "hang|count|pre" &
  wait
  # P6b1, the seek (the parameter sets kept, the abort, the start armed by the reset)
  mut C12 umd/h264/sps_pps.sv "    always_ff @(posedge clk or negedge ps_rst_n) begin
        if (!ps_rst_n) begin" "    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin" aks "count|out" &
  mut C13 umd/h264/recon_hdr.sv "    always_ff @(posedge clk or negedge ps_rst_n) begin
        if (!ps_rst_n) begin" "    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin" fgs count &
  mut C14 umd/ddr_mux2.sv "if (a_abort) a_flush <= 1'b1;" "if (1'b0) a_flush <= 1'b1;" aks "ddr|avalon|hang|pre|post|count|out" \
          "+seek_mbs=1 +seek_on=burst" &
  mut C15 umd/h264/recon_dpb.sv "            rp_arm <= 1'b1; rp_leadm <= 1'b0; rp_cap <= 1'b0; rp_probe <= 1'b0; rp_probed <= 1'b0;
            recovering <= 1'b0; skipping <= 1'b0; rp_poc <= '0; slice_skip <= 1'b0;" "            rp_arm <= 1'b0; rp_leadm <= 1'b0; rp_cap <= 1'b0; rp_probe <= 1'b0; rp_probed <= 1'b0;
            recovering <= 1'b0; skipping <= 1'b0; rp_poc <= '0; slice_skip <= 1'b0;" fgs "count|pre" &
  wait
  # P6b4, trick play (one_frame: the first frame of a longer window)
  mut C16 umd/h264/h264_top.sv "((cut_n == 2'd1 && !cut_fld) || cut_n == 2'd2)" "((cut_n == 2'd1) || cut_n == 2'd2)" \
          fgt "count|out" "+one_frame +es=$W/red_fgt_long.es" &
  mut C17 umd/h264/h264_top.sv "wire cut_now    = one_frame && hdr_opener" "wire cut_now    = 1'b0 && hdr_opener" \
          akt "count|pre|out" "+one_frame +es=$W/red_akt_long.es" &
  mut C18 umd/h264/h264_top.sv "cut_q <= 1'b1; state <= T_EOS;" "cut_q <= 1'b1; state <= T_SINK;" \
          akt "hang|out" "+one_frame +es=$W/red_akt_long.es" &
  wait
  # P8: the size refusal scored ([count]), the PES sideband exercised (only the marked window sees C20)
  mut C19 umd/h264/recon_top.sv "                        mb_slice_go <= 1'b1; rs <= R_RUN;
                    end else begin" "                        mb_slice_go <= 1'b1; rs <= R_RUN; ref_size <= ref_size + 1'b1;
                    end else begin" ak count &
  mut C20 umd/h264/h264_top.sv "T_PT_LO:  begin se_valid = 1'b1; se_kind = K_HDR_WORD;" \
          "T_PT_LO:  begin se_valid = 1'b1; se_kind = K_NAL_WORD;" akm "count|pre|hang|out|post" "+marks=$W/red_akm.marks" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
  if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; fi
  exit $fail
fi

# one disc: IMAGE LABEL [INNER] -> a verdict line on stdout (the golden and logs under
# $W/sweep). INNER: the ISO inside a .zip (a zip may hold several: King Kong's two discs)
one() {
  local img=$1 label=$2 inner=${3:-} tmp="" stem=$W/sweep/$2
  mkdir -p $W/sweep
  if [[ ${img,,} == *.zip ]]; then
    tmp=$(mktemp -d "$ROOT/$W/unz.XXXXXX")
    if [ -z "$inner" ] || ! unzip -p "$img" "$inner" > "$tmp/d.iso"; then
      echo -e "$label\tSKIP\tno ISO inside the zip (not a readable zip archive?)"; rm -rf "$tmp"; return
    fi
    img=$tmp/d.iso
  fi
  golden "$img" "$stem"
  local rc=$?
  [ -n "$tmp" ] && rm -rf "$tmp"
  case $rc in
    0) ;;
    3) echo -e "$label\tSKIP\t$(tail -1 $stem.golden.log)"; rm -f $stem.es $stem.pre $stem.post $stem"_long.es"; return;;
    4) echo -e "$label\tREFUSED\t$(grep -m1 REFUSED $stem.golden.log)"; rm -f $stem.es $stem.pre $stem.post; return;;
    5) echo -e "$label\tORACLE\t$(grep -m1 MISMATCH $stem.golden.log)"; return;;
    *) echo -e "$label\tFAIL\t[golden] $(tail -1 $stem.golden.log)"; return;;
  esac
  if [ $model_only = 1 ]; then
    echo -e "$label\tPASS\t$(tail -1 $stem.golden.log | sed 's/^[^:]*: //' | cut -c1-220)"
    rm -f $stem.es $stem.pre $stem.post
    return
  fi
  if [ "${epstart[0]:-}" = "--seek" ]; then
    # P6b1: the seek at six reset points (+seek_mbs / +seek_delay: into the picture, and
    # clk_dec cycles on from there; +seek_on: then the first cycle the mux holds an open
    # write burst / outstanding A reads -- blind delays met no burst in 12 seeks), each must
    # PASS; the abort must have met an open write burst in at least one (else unexercised)
    local v k=0 wb=0 rd=0 bad=""
    for v in "" "+seek_mbs=1 +seek_on=burst" "+seek_on=burst" "+seek_delay=113 +seek_on=reads" "+seek_mbs=0 +seek_delay=5" "+seek_delay=611 +seek_on=burst"; do
      k=$((k + 1))
      # shellcheck disable=SC2086
      $W/obj/cosim $stem +label="$label" +seed=$k $v > $stem.log.$k 2>&1
      if ! grep -q "^PASS: cosim" $stem.log.$k; then bad="$bad [$v] $(grep -m1 FAIL $stem.log.$k | cut -c1-120)"; continue; fi
      wb=$((wb + $(grep -o "open write burst [0-9]*" $stem.log.$k | grep -o "[0-9]*$")))
      rd=$((rd + $(grep -o "A reads [0-9]*" $stem.log.$k | grep -o "[0-9]*$")))
    done
    cp $stem.log.1 $stem.log
    if [ -n "$bad" ]; then echo -e "$label\tFAIL\tseek:$bad"; return; fi
    if [ $wb = 0 ]; then echo -e "$label\tFAIL\t[coverage] the abort never met an open write burst in 6 seeks"; return; fi
    echo -e "$label\tPASS\t6 seeks; the abort completed open write bursts ($wb mclk cycles) and swallowed A reads ($rd); $(grep -o '[0-9]* pictures ([0-9]* fields)' $stem.log)"
    rm -f $stem.es $stem.pre $stem.post
    return
  fi
  if [ $trick = 1 ]; then
    # P6b4: the longer window fed, the first frame scored
    $W/obj/cosim $stem +label="$label" +one_frame +es=$stem"_long.es" > $stem.log 2>&1
    if grep -q "^PASS: cosim" $stem.log; then
      echo -e "$label\tPASS\ttrick: $(grep -o '[0-9]* pictures ([0-9]* fields)' $stem.log) of the $(grep -o 'ES: [0-9]* pictures' $stem.golden.log | grep -o '[0-9]*') fed, bit-exact; the rest cut"
      rm -f $stem.es $stem.pre $stem.post $stem"_long.es"
    else
      echo -e "$label\tFAIL\ttrick: $(grep -m1 "FAIL" $stem.log | cut -c1-160)"
    fi
    return
  fi
  $W/obj/cosim $stem +label="$label" > $stem.log 2>&1
  if grep -q "^PASS: cosim" $stem.log; then
    local l; l=$(grep -m1 "identical" $stem.log)
    echo -e "$label\tPASS\t$(grep -o '[0-9]* pictures ([0-9]* fields), [0-9]* frames' <<< "$l"); $(grep -o '[0-9]* clk_dec cycles a macroblock, [0-9.]* frames/s at 81 MHz, [0-9.]*x real time' <<< "$l")"
    rm -f $stem.es $stem.pre $stem.post          # 300 MB a disc; kept on failure
  else
    echo -e "$label\tFAIL\t$(grep -m1 "FAIL" $stem.log | cut -c1-160)"
  fi
}

TSV=$W/sweep${epstart:+_ep}$([ $trick = 1 ] && echo _trick)$([ $model_only = 1 ] && echo _model).tsv   # never clobbers the RTL sweep's table
CENSUS=$W/census.tsv

# the library: every image in $UMD_ISO_DIR and one folder deep (a multi-disc title kept as a
# folder of disc ISOs: King Kong, My Chemical Romance; the P5g sweep missed them), each ISO
# inside a .zip its own disc -> LIB_IMG / LIB_LABEL / LIB_INNER, filtered by --match (compared
# against each file's name: a pattern with spaces, e.g. 'King Kong*', is not word-split)
library() {
  LIB_IMG=(); LIB_LABEL=(); LIB_INNER=()
  shopt -s nullglob nocaseglob nocasematch
  local f b m base inner k inners
  for f in "$ISO_DIR"/*.iso "$ISO_DIR"/*.zip "$ISO_DIR"/*/*.iso "$ISO_DIR"/*/*.zip; do
    b=$(basename "$f")
    for m in "${matches[@]:-*}"; do
      [[ ${b%.*} == $m ]] || continue
      base=${b%.*}; base=${base//[^A-Za-z0-9._-]/_}
      inners=("")
      if [[ ${f,,} == *.zip ]]; then
        mapfile -t inners < <(unzip -Z1 "$f" 2>/dev/null | grep -i '\.iso$')
        [ ${#inners[@]} = 0 ] && inners=("")
      fi
      k=0
      for inner in "${inners[@]}"; do
        k=$((k + 1))
        LIB_IMG+=("$f"); LIB_INNER+=("$inner")
        if [ ${#inners[@]} -gt 1 ]; then LIB_LABEL+=("${base}_disc$k"); else LIB_LABEL+=("$base"); fi
      done
      break
    done
  done
  shopt -u nullglob nocaseglob nocasematch
}

run_set() {     # INDEX... -> each disc's verdict line into $OUT, $jobs at a time
  local i
  : > "$OUT"
  for i in "$@"; do
    one "${LIB_IMG[$i]}" "${LIB_LABEL[$i]}" "${LIB_INNER[$i]}" >> "$OUT" &
    while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
  done
  wait
  sort -o "$OUT" "$OUT"
}

report() {      # $OUT -> the table, the counts, the windows at risk; fail=1 on FAIL / ORACLE
  column -t -s $'\t' "$OUT" | sed 's/^/  /'
  for v in PASS FAIL SKIP REFUSED ORACLE; do printf "  %s %d" $v "$(cut -f2 "$OUT" | grep -cx $v)"; done; echo
  # real time is reported, not gated: the DDR model is not the rig's DDR3 (the rig ran
  # 4-7 % slower on Akira / Family Guy), so a window under ~1.07x here is at risk there
  local slow
  slow=$(grep -P "\tPASS\t" "$OUT" | awk -F'\t' '{ if (match($3, /([0-9.]+)x real time/, m) && m[1] + 0 < 1.07) print "    " $1 " " m[1] "x" }')
  [ -n "$slow" ] && { echo "  under 1.07x real time (at risk on the rig):"; echo "$slow"; }
  grep -qP "\t(FAIL|ORACLE)\t" "$OUT" && fail=1
}

if [ $sweep = 1 ]; then
  echo "== SWEEP: every image in \$UMD_ISO_DIR, $frames frames of the main title, $jobs at a time =="
  library
  [ ${#LIB_IMG[@]} = 0 ] && { echo "  SKIP: no image in $ISO_DIR (set UMD_ISO_DIR)"; exit 2; }
  OUT=$TSV
  run_set "${!LIB_IMG[@]}"
  report
  # the census --sample chooses from: written by a FULL sweep of the RTL on the default
  # window only (a --match, --model-only or --ep-start sweep sees another set or window)
  if [ ${#matches[@]} = 0 ] && [ $model_only = 0 ] && [ ${#epstart[@]} = 0 ]; then
    {
      echo "# census $(date -u +%F) $(git rev-parse --short HEAD 2>/dev/null)$(git diff --quiet 2>/dev/null || echo +dirty) frames=$frames"
      while IFS=$'\t' read -r label verdict detail; do
        xrt=$(grep -oP '[0-9.]+(?=x real time)' <<< "$detail")
        cyc=$(grep -oP '[0-9]+(?= clk_dec cycles a macroblock)' <<< "$detail")
        feats=""
        [ -f "$W/sweep/$label.feat" ] && [ "$verdict" = PASS ] && feats=$(cut -d' ' -f1 "$W/sweep/$label.feat" | tr '\n' ' ')
        echo -e "$label\t$verdict\t$xrt\t$cyc\t${feats% }"
      done < "$TSV"
    } > "$CENSUS"
    echo "  census: $CENSUS ($(grep -vc '^#' "$CENSUS") windows) for --sample"
  fi
elif [ $sample = 1 ]; then
  [ -f "$CENSUS" ] || { echo "run_cosim: --sample needs the census a full --sweep writes ($CENSUS): run one first"; exit 2; }
  head -1 "$CENSUS" | grep -q "frames=$frames\b" || echo "  note: the census was taken over $(head -1 "$CENSUS" | grep -oP 'frames=\K[0-9]+') frames, this run $frames"
  library
  [ ${#LIB_IMG[@]} = 0 ] && { echo "  SKIP: no image in $ISO_DIR (set UMD_ISO_DIR)"; exit 2; }
  printf '%s\n' "${LIB_LABEL[@]}" > "$W/present.txt"
  declare -A WHY=(); declare -A IDX=()
  for i in "${!LIB_LABEL[@]}"; do IDX[${LIB_LABEL[$i]}]=$i; done
  pick=$(python3 tools/cosim_sample.py "$CENSUS" --tail "$tail" --present "$W/present.txt") \
    || { echo "FAIL: tools/cosim_sample.py"; echo "$pick"; exit 1; }
  sel=()
  while IFS=$'\t' read -r label why; do
    [[ $label == \#* ]] && continue
    sel+=("${IDX[$label]}"); WHY[$label]=$why
  done <<< "$pick"
  # a disc the census has not seen (added to the library since): its features are
  # unknown, so it is always run until the next full sweep
  for i in "${!LIB_LABEL[@]}"; do
    grep -qP "^\Q${LIB_LABEL[$i]}\E\t" "$CENSUS" || { sel+=("$i"); WHY[${LIB_LABEL[$i]}]="new: not in the census"; }
  done
  echo "== SAMPLE: ${#sel[@]} of ${#LIB_IMG[@]} discs, $frames frames of the main title, $jobs at a time =="
  echo "  from $(head -1 "$CENSUS" | sed 's/^# //'); $(grep '^#' <<< "$pick" | sed 's/^# //')"
  for i in "${sel[@]}"; do l=${LIB_LABEL[$i]}; printf '    %-58s %s\n' "$l" "$(cut -c1-110 <<< "${WHY[$l]}")"; done
  OUT=$W/sample${epstart:+_ep}$([ $trick = 1 ] && echo _trick)$([ $model_only = 1 ] && echo _model).tsv
  run_set "${sel[@]}"
  report
else
  echo "== GREEN: Akira (frames) and Family Guy (fields), $frames frames of each main title =="
  if [ -z "${AK[0]:-}" ] || [ -z "${FG[0]:-}" ]; then echo "  SKIP: no Akira / Family Guy image in $ISO_DIR (set UMD_ISO_DIR)"; exit 2; fi
  : > $W/green.tsv
  one "${AK[0]}" akira >> $W/green.tsv &
  one "${FG[0]}" family_guy >> $W/green.tsv &
  wait
  column -t -s $'\t' $W/green.tsv | sed 's/^/  /'
  grep -qvP "\tPASS\t" $W/green.tsv && fail=1
fi
if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; fi
exit $fail
