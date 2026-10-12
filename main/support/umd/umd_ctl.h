// umd_ctl.h -- the hook into Main's poll loop: the host module (umd_host.h, always on under the
// UMD core) and the HIL channel for the UMD core (main/README.md): telemetry from the
// core (umd/umd_telem.sv, command 0x7A) into /tmp/umd_telem.json at 4 Hz, and a command
// FIFO (/tmp/umd_ctl: "osd <option> <value>", "mount <path>", "ping", "b2 ..." --
// umd_b2.h). ARMED only while
// /media/fat/umd_hil exists; otherwise it does nothing at all.
#pragma once

char is_umd();
void umd_ctl_log(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void umd_ctl_tick();
