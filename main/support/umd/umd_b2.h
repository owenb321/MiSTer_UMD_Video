// umd_b2.h -- B2's probe (docs/hps_host.md §6 "B2, the procedure"): measurements on the
// rig for the subtitle decode on the HPS, before any RTL. Reached only through the HIL
// command FIFO (umd_ctl.cpp: "b2 ..."), so it is as inert as the rest of the HIL module in
// a Main that is not armed. Not part of A7's shipped host (B4's umd_host.cpp).
#pragma once

#include <stdint.h>

// a "b2 ..." line from the FIFO (the "b2 " stripped)
void umd_b2_cmd(char *args);
// called first thing in umd_ctl_tick, before the arm check: the poll-gap timestamp, then
// at most one pass of a pending bw / dump
void umd_b2_tick();
