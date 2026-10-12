#!/usr/bin/env bash
# Timing-aware fitter seed sweep. Re-runs ONLY the fitter (reuses the existing
# synthesis/map netlist) across seeds, verifies each fit's clk_dec Fmax with
# tools/fmax_check.sh (row-anchored parse — see that script for the 2026-07-09
# neighbor-row extraction bug this replaces), and keeps the BEST passing fit.
#
# A seed only COUNTS if it (a) routes and (b) closes clk_dec >= FMAX_MIN (86 MHz)
# at BOTH slow corners — "routes" alone is NOT success; a routed-but-marginal fit
# is the chroma-fringe lottery (and has produced garbled-green HW builds).
#
# The best seed's .sof AND its matching .sta.rpt are saved as a pair and restored
# before packing, so the packed rbf and the on-disk timing report always describe
# the SAME fit (the July 9 sweep shipped a seed-7 sof while seed 12's rpt was left
# on disk — never again).
#
# Usage: tools/seed_sweep.sh [name]     (release base name, default UMD_sweep)
#   SEEDS="7 9 11"  override the seed list
#   FMAX_MIN=86.0   clk_dec threshold (passed through to fmax_check.sh; keep equal to its default)
#   SWEEP_ALL=1     try every seed and keep the best (default: stop at first PASS)
set -u
# Optional: re-exec the whole sweep inside the pinned Quartus 17.0.2 Docker image when
# USE_DOCKER=1 (no-op otherwise; never returns when it re-execs). Must precede any quartus
# call and the cd below.
# SEEDS/FMAX_MIN/SWEEP_ALL are forwarded as env; NAME passes through "$@".
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"
# Repo root, derived from this script's own location — NOT hardcoded. It used to be an
# absolute path to one developer's checkout, which made the sweep fail immediately for
# anyone else. Deriving it is also correct under USE_DOCKER: docker_reexec.sh uses a
# SAME-PATH mount (-v repo:repo -w repo), so this resolves identically in-container.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAME="${1:-UMD_sweep}"
LOG=/tmp/seed_sweep.log
: > "$LOG"
SEEDS="${SEEDS:-7 9 11 13 5 8 17 23 1 29 42}"
FMAX_MIN="${FMAX_MIN:-86.0}"   # must equal tools/fmax_check.sh's default
SWEEP_ALL="${SWEEP_ALL:-0}"
# Per-fit timeout (env-overridable). The default was calibrated when a clean seed
# routed in ~14 min; on the 2026-07-30 Phase-B netlist HEALTHY fits take ~28-32 min,
# so 2100 s left no headroom and killed viable seeds mid-fit (a killed fit also
# leaves the PREVIOUS seed's fit.rpt/.summary on disk — a stale "Successful" that
# reads like the killed seed passed). Scale FIT_TIMEOUT to ~2x the observed healthy
# fit time for the current netlist (e.g. FIT_TIMEOUT=3600).
FIT_TIMEOUT="${FIT_TIMEOUT:-2100}"
BEST_DIR=/tmp/seed_sweep_best
best_seed=""; best_fmax=0
rm -f "$BEST_DIR/UMD.fit.summary"   # (never an older sweep's area)

# UMD.qsf guard. quartus_fit --seed=N persists the option, and Quartus then REWRITES the
# qsf: sys/sys.tcl's assignments inlined (P5f's sweep: 170 pin lines) and the hand-written
# SEED LEDGER's comments lost. build_release.sh guards its own compile; this sweep did not
# (found 2026-09-27, P5g). The qsf is snapshotted here and put back after every fit and on
# any exit -- so the seed that won is NOT written anywhere: pin it by hand (the DONE line).
# Never edit UMD.qsf while a sweep runs: the restore would drop the edit.
QSF_COPY=$(mktemp)
cp UMD.qsf "$QSF_COPY"
qsf_restore() {
  if ! cmp -s UMD.qsf "$QSF_COPY"; then
    echo "    qsf guard: Quartus rewrote UMD.qsf -- restored the pre-sweep copy" | tee -a "$LOG"
    cp "$QSF_COPY" UMD.qsf
  fi
}
trap 'qsf_restore; rm -f "$QSF_COPY"' EXIT

echo "=== seed sweep start $(date) (seeds: $SEEDS, clk_dec >= ${FMAX_MIN} MHz, timeout ${FIT_TIMEOUT}s/fit) ===" | tee -a "$LOG"
for s in $SEEDS; do
  echo "--- SEED $s : fitting $(date +%H:%M:%S) ---" | tee -a "$LOG"
  timeout -k 30 ${FIT_TIMEOUT} quartus_fit UMD --seed=$s >/tmp/fit_$s.log 2>&1
  rc=$?
  qsf_restore
  if [ $rc -eq 124 ] || [ $rc -eq 137 ]; then
    echo "    SEED $s -> TIMEOUT (${FIT_TIMEOUT}s) — abandoning, next seed" | tee -a "$LOG"
    continue
  fi
  status=$(grep -i "Fitter Status" output_files/UMD.fit.summary 2>/dev/null | head -1)
  if ! echo "$status" | grep -qi "Successful"; then
    echo "    SEED $s -> $status (no route, skip)" | tee -a "$LOG"
    continue
  fi
  quartus_sta UMD >/tmp/sta_$s.log 2>&1
  fmax_out=$(FMAX_MIN="$FMAX_MIN" ./tools/fmax_check.sh output_files/UMD.sta.rpt 2>&1)
  fmax_rc=$?
  summary=$(echo "$fmax_out" | grep -m1 'clk_dec Restricted Fmax' || echo "no clk_dec row")
  echo "    SEED $s -> routed; $summary" | tee -a "$LOG"
  if [ $fmax_rc -ne 0 ]; then
    echo "    SEED $s -> timing FAIL (< ${FMAX_MIN} MHz) — marginal fit, next seed" | tee -a "$LOG"
    continue
  fi
  # A negative setup slack on ANY core-PLL clock is a miss too (fmax_check's advisory line):
  # the ledger has counted it so since 2026-10-07 (clk_mem -0.065 ns on 78d2ed5, a sweep owed),
  # but this loop gated clk_dec alone and would have stopped at such a seed.
  if echo "$fmax_out" | grep -q 'negative setup slack'; then
    echo "    SEED $s -> timing FAIL ($(echo "$fmax_out" | grep -m1 'negative setup slack' | sed 's/^fmax_check: WARNING: //')) — next seed" | tee -a "$LOG"
    continue
  fi
  # Passing fit: score by the worst slow corner so "best" means most real margin.
  # (strip the "(target ...)" suffix so the threshold value can't pollute the min)
  min_corner=$(echo "$summary" | sed 's/(target.*//' | grep -oE '[0-9]+\.[0-9]+' | sort -n | head -1)
  if awk -v a="$min_corner" -v b="$best_fmax" 'BEGIN{exit !(a > b)}'; then
    echo "    SEED $s -> PASS, new best (worst-corner ${min_corner} MHz) — assembling" | tee -a "$LOG"
    quartus_asm UMD >/tmp/asm_$s.log 2>&1
    if [ ! -f output_files/UMD.sof ]; then
      echo "    SEED $s -> asm produced no .sof — check /tmp/asm_$s.log" | tee -a "$LOG"
      continue
    fi
    mkdir -p "$BEST_DIR"
    cp output_files/UMD.sof "$BEST_DIR/UMD.sof"
    cp output_files/UMD.sta.rpt "$BEST_DIR/UMD.sta.rpt"   # keep the PAIR together
    cp output_files/UMD.fit.summary "$BEST_DIR/UMD.fit.summary" 2>/dev/null || true   # (the manifest's area)
    best_seed=$s; best_fmax=$min_corner
  else
    echo "    SEED $s -> PASS but not better than seed $best_seed (${best_fmax} MHz)" | tee -a "$LOG"
  fi
  if [ "$SWEEP_ALL" != "1" ] && [ -n "$best_seed" ]; then
    break
  fi
done

if [ -z "$best_seed" ]; then
  echo "=== seed sweep EXHAUSTED — no seed routed AND closed clk_dec ${FMAX_MIN} MHz $(date) ===" | tee -a "$LOG"
  "$(dirname "$0")/notify.sh" "❌ MiSTer_UMD seed sweep EXHAUSTED — no seed closes clk_dec ${FMAX_MIN} MHz. Retime or trim logic."
  exit 1
fi

# Restore the winning pair so output_files matches what gets packed.
cp "$BEST_DIR/UMD.sof" output_files/UMD.sof
cp "$BEST_DIR/UMD.sta.rpt" output_files/UMD.sta.rpt
[ -f "$BEST_DIR/UMD.fit.summary" ] && cp "$BEST_DIR/UMD.fit.summary" output_files/UMD.fit.summary
echo "=== BEST: SEED $best_seed (clk_dec worst-corner ${best_fmax} MHz) — packing ===" | tee -a "$LOG"
BUILD_SEED=$best_seed NOTIFY_SILENT=1 ./build_release.sh --release --name "$NAME" >>"$LOG" 2>&1
rc=$?
RBF=$(ls -t releases/${NAME}_*.rbf 2>/dev/null | head -1)
if [ $rc -eq 0 ] && [ -n "$RBF" ]; then
  ls -la "$RBF" | tee -a "$LOG"
  echo "=== DONE $(date): remember to pin SEED $best_seed in UMD.qsf for this netlist ===" | tee -a "$LOG"
  "$(dirname "$0")/notify.sh" "✅ MiSTer_UMD sweep: SEED $best_seed closes clk_dec (worst-corner ${best_fmax} MHz) — packed $(basename "$RBF"). Pin SEED $best_seed in UMD.qsf."
else
  echo "=== pack FAILED after sweep (rc=$rc) — check $LOG ===" | tee -a "$LOG"
  "$(dirname "$0")/notify.sh" "⚠️ MiSTer_UMD sweep found SEED $best_seed but the pack failed — check $LOG"
  exit 1
fi
