#!/usr/bin/env bash
# fit_unit.sh -- a full fit of ONE module on the core's device, for its Fmax before it is
# wired into emu (tools/synth_unit.sh stops at synthesis and says nothing about timing).
#
#   USE_DOCKER=1 tools/fit_unit.sh TOP "CLK=MHz ..." file.sv ...
#   USE_DOCKER=1 tools/fit_unit.sh sub_top "sclk=27 mclk=90 pclk=90" umd/png/*.sv umd/sub/*.sv ...
#
# Every top-level port but the named clocks is a VIRTUAL PIN (a register or LUT stands in
# for the pad: the module's own paths are timed, the device's I/O is not). Each clock gets
# create_clock at its MHz and the clocks are one asynchronous group each (the modules this
# is for cross between them only through fifo_dc / cdc_*). The settings the core's fit uses
# where they touch timing: the device, -40 / 100 C junction (both slow corners analysed),
# FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS, SEED 1. The numbers are an ESTIMATE:
# alone on an empty device the placer has room it will not have beside the decoder, so
# treat a clock that closes with little margin here as one that may not close in the core.
#
# Output: Fmax at both slow corners per clock (row-anchored, as tools/fmax_check.sh reads
# the core's report), the logic / memory / DSP use. Project in .sim/fit_<top>/ (scratch).
# Memory: a fit takes a few GB -- never beside another fit or a big simulation batch.
#
# Also accepted (main's one-clock form, P6a; merged with this one on feature/p7-png):
#   USE_DOCKER=1 tools/fit_unit.sh TOP CLK_PORT MHZ file...     # = TOP "CLK_PORT=MHZ" file...
#   PATHS_ONLY=1 USE_DOCKER=1 tools/fit_unit.sh TOP ...         # re-report an existing fit
# After the fit, tools/fit_unit_paths.tcl writes the worst setup paths at -40 C into the
# project (paths.txt, worst_path.txt); tools/fit_unit_paths.sh names one clock's.
set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"
cd "$(dirname "$0")/.."
ROOT=$(pwd)
top=${1:?usage: fit_unit.sh TOP \"clk=MHz ...\" files...}; clocks=${2:?clocks}; shift 2
# main's one-clock form: TOP CLK_PORT MHZ files...
if [[ "$clocks" != *=* && "${1:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then clocks="$clocks=$1"; shift; fi
[ $# -gt 0 ] || { echo "fit_unit: no files"; exit 2; }
D=.sim/fit_$top
[ "${PATHS_ONLY:-0}" = "1" ] || { rm -rf "$D"; mkdir -p "$D"; }
{
  echo "set_global_assignment -name FAMILY \"Cyclone V\""
  echo "set_global_assignment -name DEVICE 5CSEBA6U23I7"
  echo "set_global_assignment -name TOP_LEVEL_ENTITY $top"
  echo "set_global_assignment -name SEARCH_PATH $ROOT"
  echo "set_global_assignment -name VERILOG_MACRO \"QUARTUS=1\""
  echo "set_global_assignment -name MIN_CORE_JUNCTION_TEMP \"-40\""
  echo "set_global_assignment -name MAX_CORE_JUNCTION_TEMP 100"
  echo "set_global_assignment -name TIMEQUEST_MULTICORNER_ANALYSIS ON"
  echo "set_global_assignment -name FITTER_AGGRESSIVE_ROUTABILITY_OPTIMIZATION ALWAYS"
  echo "set_global_assignment -name SEED 1"
  echo "set_global_assignment -name SDC_FILE $top.sdc"
  for f in "$@"; do echo "set_global_assignment -name SYSTEMVERILOG_FILE $ROOT/$f"; done
  echo "set_instance_assignment -name VIRTUAL_PIN ON -to *"
  for c in $clocks; do echo "set_instance_assignment -name VIRTUAL_PIN OFF -to ${c%%=*}"; done
} > "$D/$top.qsf"
echo "PROJECT_REVISION = \"$top\"" > "$D/$top.qpf"
{
  groups=""
  for c in $clocks; do
    n=${c%%=*}; mhz=${c#*=}
    echo "create_clock -name $n -period [expr {1000.0 / $mhz}] [get_ports {$n}]"
    groups="$groups -group {$n}"
  done
  echo "set_clock_groups -asynchronous$groups"
  echo "derive_clock_uncertainty"
} > "$D/$top.sdc"

rc=0
if [ "${PATHS_ONLY:-0}" != "1" ]; then
  ( cd "$D" && quartus_map "$top" > map.log 2>&1 && quartus_fit "$top" > fit.log 2>&1 && quartus_sta "$top" > sta.log 2>&1 )
  rc=$?
fi
R="$D/output_files/$top.sta.rpt"; [ -f "$R" ] || R="$D/$top.sta.rpt"
F="$D/output_files/$top.fit.rpt"; [ -f "$F" ] || F="$D/$top.fit.rpt"
if [ $rc != 0 ] || [ ! -f "$R" ]; then
  echo "fit_unit: the flow failed (exit $rc)"; grep -h -m5 "Error" "$D"/*.log; exit 1
fi
echo "-- Fmax (Restricted, slow corners):"
for c in $clocks; do
  n=${c%%=*}; mhz=${c#*=}
  awk -v pat="$n" -v want="$mhz" '
    /^; Slow 1100mV 100C Model Fmax Summary/ { corner = "100C"; next }
    /^; Slow 1100mV -40C Model Fmax Summary/ { corner = "-40C"; next }
    /^; (Fast|Multicorner|Setup|Hold)/       { corner = "" }
    corner != "" && / MHz / {
      n = split($0, f, ";"); name = f[4]; gsub(/^ +| +$/, "", name)
      if (name == pat) { v = f[3]; gsub(/^ +| +$/, "", v); sub(/ MHz$/, "", v); r[corner] = v }
    }
    END { printf "  %-6s target %6.2f MHz: 100C %s, -40C %s\n", pat, want, (r["100C"] ? r["100C"] : "none"), (r["-40C"] ? r["-40C"] : "none") }' "$R"
done
echo "-- use:"
grep -E "^; (Logic utilization \(in ALMs\)|Total block memory bits|Total DSP Blocks|Total RAM Blocks)" "$F" | sed 's/  \+/ /g'
( cd "$D" && quartus_sta -t "$ROOT/tools/fit_unit_paths.tcl" "$top" 20 > paths.log 2>&1 ) \
  && echo "-- the worst setup paths at -40 C: $D/paths.txt, $D/worst_path.txt"
