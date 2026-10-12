# MGL launch

Engineering note. The user-facing page is `site/content/getting-started/loading.md`.

An MGL is MiSTer's shortcut: a small XML file that loads a core and mounts a file into it.

```xml
<mistergamedescription>
  <rbf>_Other/UMD</rbf>
  <file delay="2" type="s" index="0" path="/media/fat/games/UMD/Movie.iso"/>
</mistergamedescription>
```

`type="s" index="0"` matches the `S0,ISOMPS,Load Video` row (P8: a bare `.MPS` too; the reader sniffs the file, so the extension does not matter); `<rbf>` resolves to the
lexicographically greatest `UMD*.rbf` in `_Other/` (not the newest).

## What MiSTer_DVD learned, and this core inherits

1. **A running MGL owns the whole UI.** While `mgl->done == 0`, Main never calls
   `menu_key_get()`, and the MGL's only forward edge requires `menustate == MENU_NONE2`.
   Anything that raises `Info`/`InfoMessage` from a poll tick during that window freezes
   the launch with no timeout. The core has had Main-side code since A7 / P9 (the UMD Main,
   `main/support/umd/`); checked 2026-10-06, none of it calls `Info` / `InfoMessage` (the one
   key it injects is the disc menu's own OSD request, `umd_menu.cpp`, never at a launch), and
   the launch completes on the rig (below). Keep it so: a new message from the UMD Main goes
   to the plane or the core's HUD, not to Main's `Info`. **The one exception** (2026-10-10,
   `psp_disc.md` §3): the PSP disc scanner (`umd_psp.cpp`) raises `Info` with slot 0 empty, where
   no plane can show; its tick does nothing at all while `mgl_get()->done` is 0, and two MGL
   launches with a PSP attached completed on the rig (`psp_disc.md` §6).
2. **A mount with no media is not a mount.** Main sends `UIO_SET_SDSTAT` even when the
   open failed, with size 0, and `hps_io` raises `img_mounted` for it — which is also how
   an EJECT arrives. `emu.sv` gates `start_streaming` on `img_size != 0` and treats the
   size-0 pulse as `img_ejected`. `tools/check_emu_wiring.py` pins it.
3. **The virtual OSD button is a pulse, gated on `~status[0]`.** A held button of ≥ 3 s
   means "enter Bluetooth pairing". The 0.9 s wait-then-100 ms-pulse from MiSTer_DVD is
   reproduced verbatim.
4. **The `boot.rom` trap.** A `boot.rom` transfer re-enters `HandleUI()` before the MGL
   timer is armed, and `CheckTimer(0)` reads as expired, consuming the `delay`. This core
   ships no `boot.rom` (no user logo), so it is not exposed.
5. **Reading the screen colour splits three bugs apart** before any instrument is added
   (from `yuv2rgb`): **black** = nothing is scanning (reader wedged / decoder in reset);
   **green** (0,136,0) = a framestore slot scanned that was never written; **grey**
   (130,130,130) = an intra picture decoded from mis-framed bytes (H.264 has no fixed DC
   predictor reset like MPEG-2, so the grey signature will differ here — re-derive it
   when the decoder exists).

## On the rig (2026-10-06)

The second MiSTer (.201), installed as `site/content/getting-started/install.md` says: the core
as `_Other/UMD_20261005.rbf` (`UMD_bare_20261005_1945.rbf`, netlist = `main` `eb026df`), the UMD
Main rebuilt clean from `eb026df` as `/media/fat/MiSTer_UMD`, and the manual's MGL verbatim
(`<rbf>_Other/UMD</rbf>`, `delay="2" type="s" index="0"`, an image on the NAS share). Each MGL
was sent as `load_core <mgl>` on `/dev/MiSTer_cmd`, which calls the same `xml_load` as choosing
the file in the menu's browser (`menu.cpp`, `input.cpp`).

| case | result |
|---|---|
| A. stock Main, no `[UMD]` section, from the menu | `_Other/UMD` resolved to `UMD_20261005.rbf`; Akira mounted and its feature played at once (two shots 5 s apart, different pictures) |
| B. `[UMD] main=MiSTer_UMD`, from the menu (stock Main) | Main's hand-over ran `MiSTer_UMD <rbf> <mgl>` (`user_io.cpp`'s `app_restart` passes the MGL); the mount landed and the disc's own startup chain played (the warnings, the Geneon logo) to Akira's main menu, animating |
| C. a second MGL (Family Guy) over B's running session | the UMD Main reloaded the core with the new MGL; Family Guy's main menu |
| a bare `.MPS` by MGL | confirmed in P8 on this build (`bare_streams.md` §4b) |

Not covered: an MGL whose `<rbf>` matches more than one `UMD*.rbf` (Main takes the
lexicographically greatest, above; the zip installs one).
