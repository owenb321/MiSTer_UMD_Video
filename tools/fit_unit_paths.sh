#!/usr/bin/env bash
# fit_unit_paths.sh -- the worst setup paths of one clock in a tools/fit_unit.sh fit
# (it does NOT refit: it opens the timing netlist .sim/fit_<top>/ left).
#
#   USE_DOCKER=1 tools/fit_unit_paths.sh TOP CLOCK [npaths] [temp]
#   USE_DOCKER=1 tools/fit_unit_paths.sh sub_top mclk 40 -40
#
# Output: .sim/fit_<top>/<clock>_paths.txt -- a summary of the npaths worst intra-clock
# setup paths at the slow corner of `temp` (default -40: the cold corner usually binds,
# CLAUDE.md), the 3 worst in full; the summary's From / To columns name the cluster.
set -u
source "$(dirname "$0")/docker_reexec.sh"
maybe_reexec_in_docker "$0" "$@"
cd "$(dirname "$0")/.."
top=${1:?usage: fit_unit_paths.sh TOP CLOCK [npaths] [temp]}; clk=${2:?clock}
n=${3:-40}; temp=${4:--40}
D=.sim/fit_$top
[ -d "$D/db" ] || { echo "fit_unit_paths: no fit in $D (run tools/fit_unit.sh first)"; exit 2; }
cat > "$D/paths.tcl" <<EOF
project_open $top -revision $top
create_timing_netlist
read_sdc
set_operating_conditions -model slow -temperature $temp -voltage 1100
update_timing_netlist
report_timing -setup -from_clock [get_clocks $clk] -to_clock [get_clocks $clk] -npaths $n -detail summary -file ${clk}_paths.txt
report_timing -setup -from_clock [get_clocks $clk] -to_clock [get_clocks $clk] -npaths 3 -detail full_path -file ${clk}_paths.txt -append
project_close
EOF
( cd "$D" && quartus_sta -t paths.tcl > paths.log 2>&1 ) || { echo "fit_unit_paths: quartus_sta failed"; tail -5 "$D/paths.log"; exit 1; }
echo "$D/${clk}_paths.txt"
