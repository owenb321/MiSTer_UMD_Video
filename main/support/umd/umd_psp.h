// umd_psp.h -- a PSP's UMD over USB (ARK-5's "USB Device: UMD", the file UMD9660.ISO): found on
// /media/usb0..7 and mounted into slot 0 by itself, dropped when the PSP leaves USB mode, a disc
// changed on the PSP mounted in its place (docs/psp_disc.md). The decisions are umd_psp_logic.c's.
#pragma once

#include <stdio.h>

void umd_psp_tick();                                   // Main's poll loop, the UMD core only (umd_ctl_tick)
void umd_psp_away();                                   // another core: the scan stops
void umd_psp_note_mount(int index, int ok, const char *name);   // after every mount (umd_menu_mounted)
void umd_psp_stats(FILE *f);                           // the HIL's /tmp/umd_host.json
