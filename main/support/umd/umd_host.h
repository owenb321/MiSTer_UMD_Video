// umd_host.h -- the UMD Main's host module (docs/hps_host.md §1-§3, B4): the subtitle decode
// for the core's host port (umd/umd_host.sv). Always on under the UMD core -- unlike the HIL
// module (umd_ctl), which only an arm file wakes. umd_ctl_tick calls these: it is the one hook
// the integration patches into Main's poll loop.
#pragma once

#include <stdint.h>
#include <stdio.h>

void umd_host_tick();          // a pass of Main's poll loop, the UMD core loaded
void umd_host_away();          // a pass with another core (or none): stop, forget
void umd_host_stats(FILE *f);  // the counters as one JSON object (the HIL writes /tmp/umd_host.json)
// P6d (docs/panel.md §2): the subtitle plane (0 / 1) and rectangle unit `seq` was decoded into, whole;
// 0 found, -1 not (the control panel then draws without it). Any thread.
int umd_host_unit(uint8_t seq, int *buf, int *x, int *y, int *w, int *h);
