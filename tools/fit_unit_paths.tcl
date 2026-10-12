# fit_unit_paths.tcl -- the worst setup paths of a tools/fit_unit.sh fit, at the -40 C
# slow corner (the one that usually binds, CLAUDE.md). Run by fit_unit.sh inside its
# project directory:  quartus_sta -t fit_unit_paths.tcl TOP [npaths]
set top [lindex $argv 0]
set n 20
if {[llength $argv] > 1} { set n [lindex $argv 1] }
project_open $top
create_timing_netlist -model slow -temperature -40 -voltage 1100
read_sdc
update_timing_netlist
report_timing -setup -npaths $n -detail summary -file paths.txt
report_timing -setup -npaths 1 -detail full_path -file worst_path.txt
project_close
