// umd_menu.h -- the UMD Main's disc menus (P9 M3 E2, docs/p9.md): the glue around umd_menu_run.c
// (the state machine, benched by bench/umd/menu/menu_host_check.c). Only what no bench can hold
// lives here: the worker thread, the mailbox, the image file, the plane mapping, the decoders on
// the device, the kept files, Main's calls. umd_host.cpp shares its port with it (one HOST_RD feeds
// both sides; a HOST_WR carries both: docs/p9.md M3 E2 "One port, two logics").
#pragma once

#include <stdint.h>
#include <stdio.h>

// the poll thread, every pass of umd_host_tick: rdw the HOST_RD's 38 words just read (NULL none this
// pass). Out: words 5..37 of the next HOST_WR in wr[], *want_write when they changed, *want_fast when
// the menu side needs the fast read rate. Also opens the OSD when the worker asked (P9-6).
void umd_menu_poll(uint32_t now, const uint16_t *rdw, uint16_t *wr, int *want_write, int *want_fast);
// the menu side has adopted the core's seqs: a HOST_WR carries words 5..37 (else B4's 4 words)
int  umd_menu_writes(void);
// the logic awaits only the grabbed buttons: the slower key rate (UMD_MENU_READ_KEYS_MS)
int  umd_menu_keys_only(void);
// a subtitle decode is in flight (the plane may be written by it): no menu frame is drawn
void umd_menu_sub_busy(int busy);
// Main's hooks (main/integration/apply_integration.py): an image mounted on slot `index` (ok 0: an
// eject), the name as user_io_file_mount had it; a core load (fpga_load_rbf), before Main re-execs:
// the disc quits and its kept text is written, waited for (bounded)
void umd_menu_mounted(int index, int ok, const char *name);
void umd_menu_shutdown(void);
// another core (or none) on a poll pass: the disc goes, nothing kept beyond what is stored
void umd_menu_away(void);
void umd_menu_stats(FILE *f);
