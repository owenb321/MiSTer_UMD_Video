# timing_paths.tcl — dump the top intra-clk_dec setup paths (the Fmax-limiter cluster).
#
# The clk_dec Fmax limiter MOVES as
# features grow — framestore_request (PR fj#58) → disp_vscale (PR fj#92) → ??? . Before
# retiming anything, MEASURE which cluster is on top NOW. This script is the
# one-command version of the report_timing step PR fj#92 ran by hand.
#
# Run via the wrapper (handles Docker):   [USE_DOCKER=1] tools/timing_paths.sh [npaths]
# or directly:                            quartus_sta -t tools/timing_paths.tcl [npaths]
#
# Output: output_files/clk_dec_paths.txt — a summary table of the top N intra-clk_dec
# setup paths (slow 1100mV corner: TIMING_TEMP, default 100C) + the 3 worst paths
# in full detail. Read the From/To Node columns to spot the dominant cluster.

set rev UMD
set npaths 100
if { [info exists quartus(args)] && [llength $quartus(args)] > 0 } {
    set npaths [lindex $quartus(args) 0]
}

# Same clock string as tools/fmax_check.sh CLK_DEC (outclk_3 = clk_dec).
set clk_dec {emu|sys_pll|altera_pll_i|general[3].gpll~PLL_OUTPUT_COUNTER|divclk}
set out output_files/clk_dec_paths.txt

project_open $rev -revision $rev
create_timing_netlist
read_sdc
update_timing_netlist

# Pin the analysis to a slow corner: TIMING_TEMP (default 100). The COLD corner (-40)
# usually binds on this device: TIMING_TEMP=-40 tools/timing_paths.sh, or the report
# retimes the wrong path. (CLAUDE.md documented the knob before it existed: the tcl
# hardcoded 100 until 2026-09-27; docker_reexec.sh forwards it.)
set temp 100
if { [info exists ::env(TIMING_TEMP)] && $::env(TIMING_TEMP) ne "" } { set temp $::env(TIMING_TEMP) }
if { [catch { set_operating_conditions -model slow -temperature $temp -voltage 1100 } msg] } {
    post_message -type warning "timing_paths: could not pin slow/${temp}C corner ($msg); using default"
} else {
    post_message -type info "timing_paths: slow 1100mV ${temp}C corner"
    update_timing_netlist
}

report_timing -setup \
    -from_clock [get_clocks $clk_dec] -to_clock [get_clocks $clk_dec] \
    -npaths $npaths -detail summary -file $out

report_timing -setup \
    -from_clock [get_clocks $clk_dec] -to_clock [get_clocks $clk_dec] \
    -npaths 3 -detail full_path -append -file $out

post_message -type info "timing_paths: wrote top $npaths intra-clk_dec setup paths to $out"
project_close
