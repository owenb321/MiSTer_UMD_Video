# The HIL Main (hardware-in-the-loop testing only)

A custom MiSTer *Main* used **only** by the test harness (`tools/mister.py`,
`docs/hil_harness.md`). It is never shipped, never needed to play anything, and the core
works identically under stock Main. **This changes with A7** (`docs/hps_host.md` §1, H1): the
same binary is the UMD Main users install for subtitles (`MiSTer_UMD`, B4), with the HIL parts still
armed only by `/media/fat/umd_hil`. Its host module, `support/umd/umd_host.cpp` (decisions in
`umd_host_logic.cpp`, benched by `bench/umd/run_hps_host.sh`), runs under the UMD core for every
user: it serves the core's subtitle requests on the host port (`umd/umd_host.sv`), decoding each
unit with `umd_sub.cpp` (B1) on a worker thread. With the HIL armed it writes its counters to
`/tmp/umd_host.json`.

It is stock `Main_MiSTer` at a pinned commit plus one small module,
`support/umd/umd_ctl.cpp`, called once per pass of Main's poll loop. The module does
nothing unless the file `/media/fat/umd_hil` exists and the UMD core is running. When
both hold it:

- **reads the core's telemetry** (`umd/umd_telem.sv`, command `0x7A` on hps_io's
  EXT_BUS) four times a second into `/tmp/umd_telem.json`;
- **serves a command FIFO**, `/tmp/umd_ctl`: `osd <[bits]> <value>` sets an OSD option
  live (no relaunch), `mount <path>`, `ping`. It logs to `/tmp/umd_ctl.log`.

The word format is `tools/telem_layout.py`'s table, which is also generated into the RTL
and into `support/umd/umd_telem_fields.h`.

Harvested from MiSTer_DVD's `main/` (its `dvd_ctl` telemetry channel and build
scaffolding), cut to what this needs. MiSTer_DVD's Main plays physical discs; this one
adds a few lines to `user_io.cpp`, one to `fpga_io.cpp` and the overlay's C sources to the
`Makefile` (`integration/apply_integration.py`, five steps):
1-2. the tick (`umd_ctl_tick`) and its header;
3. `support/umd/*.c` and `support/umd/menu/*.c` into `C_SRC` (the disc menus' engine, P9);
4. `umd_menu_mounted` after a mount is told to the core;
5. `umd_menu_shutdown` at the top of `fpga_load_rbf` (a core change: the disc menus quit first).

**The disc menus (P9, `docs/p9.md`)** run in the same binary: `support/umd/umd_menu.cpp` (the
worker, the files, the plane), over `umd_menu_run.c` (the state machine, benched by
`bench/umd/menu/menu_host_check.c`), `umd_menu_host.c`, `umd_menu_logic.c` and the engine in
`support/umd/menu/`. They share the host port with the subtitle decode.

**A PSP's UMD over USB** (`docs/psp_disc.md`): `support/umd/umd_psp.cpp` (a worker finds a PSP
sharing its disc as `UMD9660.ISO` on `/media/usb0..7` and reads its PVD; the tick mounts and
unmounts) over `umd_psp_logic.c` (the decisions, benched by `bench/umd/run_psp_scan.sh`). Its
tick runs from `umd_ctl_tick`, its mount hook from `umd_menu_mounted`: no new integration step.

## Build and deploy

```bash
USE_DOCKER=1 main/build_main.sh                       # -> main/.build/MiSTer_UMD
tools/mister.py deploy --main main/.build/MiSTer_UMD  # install + arm; next core load uses it
tools/mister.py telem --watch 60                      # rates over 60 s
tools/mister.py osd "Deinterlace=Bob"                 # live
tools/mister.py restore                               # disarm, [UMD] main= removed
```

`deploy --main` never overwrites a running Main: writing over it reboots the box. It
installs under a name derived from the binary's hash (`/media/fat/MiSTer_UMD_hil_<hash>`)
and adds `main=<that>` to the `[UMD]` section of `MiSTer.ini`, creating the section if
needed. The line is recognised by its value, so `restore` removes exactly it (and the
section, if the harness created it). Nothing else in `MiSTer.ini` is touched, including
another core's `main=`.

The stock base (`MAIN_MISTER_REF` in `build_main.sh`) is the commit MiSTer_DVD's
integration anchors were verified against. A bump that moves an anchor makes the patcher
fail, naming the step. Re-check that command `0x7A` is still unused by stock Main
(`user_io.h`) on any bump.
