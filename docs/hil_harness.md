# Hardware-in-the-loop harness

**Status: the stock-Main subset of MiSTer_DVD's harness, untested on this core until P0's
hardware gate.** `tools/mister.py` deploys a build, launches an image, presses keys and
pulls back a screenshot over ssh, so a session can SEE the core instead of asking someone
to test and report. The operating manual is the `hil-testing` skill; this note records
what it relies on.

> Engineering note, not user documentation. The harness needs a repo checkout and ssh to
> your own MiSTer; it is not shipped and has no page in `site/`.

```bash
echo root@<mister-ip> > tools/.mister_host      # gitignored; or $MISTER_HOST
tools/mister.py state
tools/mister.py deploy --rbf releases/UMD_scaffold_<date>.rbf
tools/mister.py launch /media/fat/games/UMD/Movie.iso --opt "Aspect Ratio=16:9"
tools/mister.py shot -o /tmp/wave.png
tools/mister.py restore
```

## Why this needs no change to the core or to Main

Four stock mechanisms, verified on hardware by MiSTer_DVD before any code was written:

| | |
|---|---|
| **`load_core` an `.mgl`** | `/dev/MiSTer_cmd` is a FIFO Main polls; `load_core` accepts a `.mgl`, which loads a core **and** mounts media in one command. |
| **`screenshot`** | The same FIFO writes a PNG of the **core's raw raster**, read from ascal's *input* buffer, so it carries no OSD, no popups, no scaling. A name ending in `.png` is used verbatim under `screenshots/`. |
| **`config/UMD_v1.CFG`** | The core's saved settings are a raw 16-byte dump of Main's 128-bit `cur_status`, read at core init before reset is released. Writing it sets any OSD option for the next launch. `mister.py` derives the file name from the `"v,N"` line in `umd/emu.sv`, never a constant. `launch` backs an existing file up once (`.hilbak`) or, when there was none, marks the file as the harness's own (`.hilnew`); `restore` puts the backup back or deletes the harness's file. Without the marker a second launch backed up the first launch's file as the user's (found by the H264 fork, 2026-09-27). |
| **uinput** | Main enumerates new `/dev/input` devices; a virtual keyboard (`tools/mister_keyd.py`, fed from a FIFO on the target) reaches the core's PS/2 path. Nothing consumes it until `umd/kbd_map.sv` exists (P6); `key osd` works from day one. |

## Test images: trim them (`tools/umd_trim.py`)

A UMD image is 1.1-1.8 GB and the rig's card is nearly full (2.6 GB free on 2026-09-23).
`tools/umd_trim.py disc.iso --packs N -o out.iso` keeps the image up to the main title's
first N packs and patches that `.MPS`'s directory record to match; everything the reader
walks must lie below the cut, and the tool refuses otherwise. `--smallest DIR` lists the
discs whose feature starts earliest (Short Circuit: 0.8 MiB in, so 64 MiB of stream is a
65 MB image). The walk, title, playlist pick and the first MiB of video are the full
disc's: `tools/psmf_golden.py --crc` gives the same value for both (checked on Short
Circuit: `309FAFA7`). The reader simply finishes early (`title_done`) at the cut.

## Facts that bite (inherited, all measured on the same platform)

- **A plain `shot` is the raw raster only when ascal does not shrink its input** (2026-10-12, .201): with
  `video_mode=2` (a 720x480 HDMI output) a 16:9 picture is fitted as 720x405 and ascal downscales on its
  INPUT side, so the screenshot -- ascal's input buffer at its own size -- came back 720x405, resampled. Any
  pixel-exact shot comparison needs an output at least 720x480 tall for the picture: a temporary
  `video_mode=0` line in `[UMD]` (removed after), and check the PNG's size before scoring it.

- **A user's own `[UMD] main=` line beat the harness's** (2026-10-09, .236, fj#71): the maintainer installed the
  release's UMD Main (`main=MiSTer_UMD` in `[UMD]`), `deploy --main` inserted its line right after the
  header, and Main takes the LAST `main=` of a section -- the old Main ran and the new host code was silently
  absent (`state` showed `main=/media/fat/MiSTer_UMD`). Fixed: `deploy --main` writes its line last in the
  section; `restore` still removes only its own. After a `deploy --main`, check `state`'s `main=` at the first
  launch.

- **A "last value" read once a second is length-biased** (2026-10-08, P9 M4h): the UMD Main's `render_us` is the
  LAST frame's; polled at random instants it lands more often in a long frame, and slow frames cluster in an
  animation's heavy phase -- The Rock's menu read ~65-73 ms that way against a true mean of 41-47. Read a
  running sum at both ends of a window instead (`/tmp/umd_host.json` "menu" -> "prof": [count, wall us, thread
  CPU us] per step, `main/support/umd/umd_menu_run.h` THE PROFILE).

- **The OSD is not in a screenshot, and keys do not reach the core while it is open.**
  Options are set by writing the settings file, not by navigating menus.
- **MGL `<rbf>` resolution takes the lexicographically GREATEST match**, not the newest
  file, so the harness deploys under the fixed name `UMD_hil.rbf` and names it exactly.
- **One command per FIFO write.** A second command in the same write is discarded.
- **`seq`'s keys are paced by the daemon, not by `seq`: one per 170 ms.** Each `key` step is the
  daemon's `keys` command (a 50 ms hold, then a 120 ms sleep); faster steps queue in the FIFO and
  are delivered later, none lost. A state read at the end of a fast burst therefore sees only part of
  it (2026-10-05: 41 keys "50 ms apart" read at 3.65 s looked like half lost -- `panel.md` §3.10b).
  To test presses closer together, use the daemon's single `key <code> <hold_ms>` command, and read
  the state only after the burst's real duration.
- **A core load re-runs the RUNNING Main binary unless MiSTer.ini names one for that core.**
  On .201 (2026-09-29) `restore`'s menu load, and a second one, kept the HIL Main running
  (`state` read `main=MiSTer_UMD_hil_*` on the menu). A reboot brought stock Main back
  cleanly. On the original rig the swap has worked. Check `state` after `restore`, and
  reboot an idle rig if Main is still the harness's. **The cause (B2, 2026-09-30):** Main
  re-execs at a core load only when the resolved `main=` names an EXISTING file; .201's
  `[MiSTer] main=ConsoleMode/MiSTer_ConsoleMode` is missing, so the last Main stays.
  `restore` cannot fix that without touching the user's ini: reboot, then `rm` the harness
  binary (`restore` cannot delete it while it runs).
- **Backspace in the OSD's file browser UNMOUNTS the image** (stock Main: "Unmounting the
  image" plus a 1 s `sleep` on the poll thread). To browse during a measurement, use Home (a
  re-scan, selects `..`) and Enter; Esc three times closes the OSD from anywhere. `mister.py
  key` takes Linux keycodes (Home 102, Enter 28, Esc 1).
- **`screenshots/` is not created on the verbatim path** — `deploy` does the `mkdir -p`.
- **The PNG is written asynchronously** with no temp-and-rename: poll for existence AND a
  stable size (`shot` does).
- **The MiSTer has no `pkill` and no `killall`.** `kill_exact()` walks `/proc`.
- **Main is started from `/etc/inittab` with `&`; nothing respawns it.** Killing it needs a
  reboot.
- **`launch` overwrites the user's saved settings.** It backs them up once; `restore` puts
  them back. Never leave a session without `restore`.
- **Deleting the harness `.rbf` does not unload it.** `restore` now returns to the menu
  core when (and only when) `/tmp/CORENAME` is `UMD` -- found at the P2 gate, where the
  rig stayed on the UMD core after a restore.
- **Images can live on the rig's network share** (a CIFS mount under `/media/fat/cifs/`,
  read-write), which avoids the nearly full card entirely; `launch` takes that path.
- **The rig is the maintainer's.** Check `state` first; a disturbed run of theirs is void,
  not salvageable. **It is also shared with the sibling project's sessions** (2026-09-27,
  P5g): another core loaded at `state` may be a test in progress on the same
  workstation. A UMD load voided a DVD step and was itself overwritten a minute later.
  Find who drives it and agree an order before loading.
- **`/tmp/umd_telem.json` goes stale when another core loads**: the HIL Main that writes
  it is no longer running, so the last values stay on disk. A waiter that reads frozen
  counters as a stalled decode is wrong about which machine it is measuring. Check that
  `t` advances (and `/tmp/CORENAME`) before believing any count.
- **A target-side screenshot burst resolves ~1 s per frame.** For a defect that is a FLASH
  the instrument is a burst sequenced on the target; for one that HOLDS a settled shot is
  enough.
- **HIL latency is part of the instrument.** ssh-paced key presses cannot test a timing
  window under ~3 s; sequence them on the target.
- **Run the OLD build through the same script as the control arm** when a defect is
  intermittent, and change ONE thing per hardware round.
- **Ask "is the PICTURE frozen or is the MACHINE frozen?"** — it separates an HPS-side
  stall from a core-side one before any code is read.
- **An HPS DDR3 port can hang, and it survives loading another bitstream** (2026-09-26,
  P5e gate). Loading Akira over a playing X-Men 2 left every later launch stuck at the
  same place: 8 packs read (`PACKS/S 0`), the decoder's first picture done (`MB 0546`),
  nothing more, `STALL` climbing, no error -- the decoder waiting on its write-back to
  ram1 -- and the PREVIOUS build, which had played Akira that morning, froze identically.
  A reboot cured it; the same launch then played clean. Signature to recognise: a
  freeze at a fixed early point that follows the rig, not the build (the control arm
  shows it). Suspected trigger: an FPGA reload while the core's f2sdram ports carry
  traffic (MiSTer_DVD's bring-up saw the same accept-a-few-then-BUSY hang). The harness
  should stop the core's DDR3 traffic before loading another image; until then, a
  reboot (the maintainer's call) clears it. The `CRC ... 0` on such a screen is a
  PARTIAL checksum (the trailing 0 = incomplete), not evidence of corrupt data.
  **Measured with the telemetry (2026-09-26):** loading a title over a playing one hung
  3 times in 24 reloads (12.5 %); every hang the same -- ram1 accepted the new core's
  writes (~43 k beats) and 24 read beats, returned NONE (`d1_rdb` 0), and held BUSY for
  good (`d1_busy` = `d1_busy_max` = 0xFFFF). With the core held in its OSD reset for 1 s
  before each load: 0 in 16 -- consistent, not yet decisive (12 % by chance). Suspect,
  unproven: a request WITHDRAWN while the port still asserted waitrequest (Avalon forbids
  it). `ddr_mux2`'s abort drops a pending A read / first write beat the cycle it engages,
  the display reader drops a pending read when it resets, and sys `f2sdram_safe_terminator`
  only protects a request still asserted on the cycle it locks -- a two-flop race with the
  core's own reset. The framework's own note: a transaction cut mid-way leaves the f2sdram
  port broken until the SDRAM controller is reset, i.e. a reboot.
  **Fix (`fix/ddr-reload-hang`, 2026-09-26):** simulation now proves the withdrawal:
  `bench/umd/ddr_model.sv` (and the cosim's C++ copy) fail `[avalon]` when a request held
  under waitrequest is withdrawn or changed, and `ddr_mux2_tb`'s aborts 3 and 4 (a read
  and a first write beat caught under waitrequest) fail it on the old mux. Two changes:
  1. `umd/ddr_mux2.sv` HOLDS a request the port has not accepted: if master A withdraws
     it (its reset, the abort) the mux keeps presenting the held command, unchanged,
     until the port takes it; a held read's beats are then swallowed, a held write
     beat's burst completed masked (`run_disp_reader.sh` X7 removes the hold -> `[avalon]`).
  2. In `emu`, every master that drives a port directly -- the mux, its abort register,
     the display reader's fetch side -- resets with the PLL lock ALONE (`mem_lock_n`),
     never with RESET or the mount (`check_emu_wiring.py`, scaffold W7, W30-W32). On
     RESET the decoder's master is aborted and drained, the reader finishes its line
     and idles; neither withdraws anything.
  **Rig round (`UMD_reloadfix_20260926_2309.rbf`): NOT FIXED -- 2 hangs in 40 reloads**
  (the old build 5 in 40; Fisher p ~ 0.4, no evidence of a change). Both hangs carry the
  old signature exactly: Akira stopped at `packs=8 pics=2 mbs=5 d1_wr=337` -- the new
  core's writes accepted, its FIRST ram1 read never returned. So the port's read side is
  broken before the new core's first read; the withdrawal was real (the bench proves it)
  but is not what breaks the port. Main's load (`fpga_io.cpp fpga_load_rbf`): core reset
  (the terminators lock), read the rbf, `do_bridge(0)` (`fpgaportrst` 0, bridges reset),
  program, `do_bridge(1)` (`fpgaportrst` 0x3FFF): the old core has ~100 ms under the
  terminator before the fabric goes.
  **The cause, reproduced in simulation (2026-09-26):** `bench/umd/f2sdram_term_tb.sv` puts
  sys's `f2sdram_safe_terminator` (every core's last stage before the port) between a
  dpb_mem-shaped master and `ddr_model` and locks it mid-traffic. The STOCK terminator
  leaves the port beats short of a write burst ([owed], at the first aimed lock). Its
  write tracker counts a beat on every cycle a burst is open and waitrequest is low --
  no `write` term -- and ends a burst on the count alone. `dpb_mem` drops `write`
  between the beats of EVERY burst while it fetches the next one (legal Avalon), so the
  tracker is out of step on most bursts; when Main's core-load reset locks it inside a
  burst it completes the wrong number of beats and the port waits for the rest forever:
  the next core's writes are swallowed into the old burst and its first read never
  returns -- the rig's signature exactly. A quiesced load has no burst open at the lock,
  hence 0 in 16. (Even contiguous bursts desync it when the last beat meets waitrequest;
  rarer.) Fix: `sys/f2sdram_safe_terminator.sv` as a `UMD-FORK` that counts the beats
  the port ACCEPTS; `run_f2sdram_term.sh --red` (K0 = the stock module, caught).
  **Rig (`UMD_reloadfix_20260926_2349.rbf`): 0 hangs in 60 reloads** (Akira and Family
  Guy alternating, each loaded over the other playing), against 7 in 80 on every build
  without the fork (P(0 in 60) at 7/80 = 0.4 %). ✅ Fixed. The harness no longer needs
  to quiesce the core before a load.
  **P6a's vbuf (a new DDR3 master on ram1, `UMD_p6vbuf_20260927_1304.rbf`): 0 hangs in 40
  reloads** (Akira / Family Guy alternating over each other playing; every load checked
  for ram1 / ram2 BUSY stuck and packs, pictures and audio frames advancing). **From here
  the reload soak is NOT part of routine rig testing** (the maintainer, 2026-09-27): it
  comes back only if the hang's signature is seen again.

## Telemetry (2026-09-26)

The HUD is read by screenshot: two shots a minute apart give a rate, and nothing in
between. The telemetry bridge gives a time series at 4 Hz, fit for rates. It is built
from MiSTer_DVD's, which was built "when every OSD-reachable variable had been exhausted".

- **Core:** `umd/umd_telem.sv` answers command `0x7A` on hps_io's EXT_BUS with 16-bit
  words (34 at first; 50 since P6b2's `reader` word; 58 since P6b3i's transport words; 59 since P6b4's `trick`; 63 since P6b7's landing words) (`tools/telem_layout.py`, the one table the RTL mux, the Main's field
  table and the bench are generated from):
  - word 0 magic `0xB0D5`, word 1 `{format, words}`;
  - the display's rate pairs (refreshes, pickups, decided / fetched changes, STC) latched
    together on the command strobe;
  - fast counters sent PRE-DIVIDED (macroblocks /256, SE words /4096, the STC /16, DDR3
    beats /256 ...), each wrapping no faster than every ~3 s against the 4 Hz poll; the
    table carries the scale. The first cut (53 words, 32-bit lo / hi pairs) cost 568 ALM
    against a P5 line with ~100 to spare; this is option B, chosen with the maintainer;
  - the scheduler's instruments, the output process, the decoder, the reader (its
    packs; since P6b2 also a `reader` word: its state, `err_code`, and the playing
    item's EP lookup flags -- no video map, an entry past the clip, a target past 2^32);
  - the transport (P6b3i, `docs/transport.md` §9): `xport` (state, seeking, the shown item
    tag, the items left, stalled, the reader held, `nav_err`), `chapter`, `seeks`, `holds`,
    the shown picture's full PTS (`sh_pts_lo` / `sh_pts_hi`, one latch: an exact landing,
    no STC/16 wrap), and the audio's left-item drops and stall yields (`a_left`, `a_yield`);
  - P6b7, for the rig gates: `land_lo` / `land_hi` (the first picture a landing shows: a
    seek's, a hop's, the watchdog's, the mount's -- read against `umd_nav_ref`'s target, it
    proves D2's exact landing), `seek_lat` (90 kHz ticks / 16 from the seek machine leaving
    idle to that picture), `landing` (the watchdogs; since the last landing the leading
    pictures and the pictures before the first I skipped, a non-IDR start, an MMCO naming a
    pre-entry picture), and the transport HUD's flags in `trick` [11:8] (Display on, the
    title's placeholder / malformed / cut). One word (index 63) is left before the 6-bit
    index needs widening;
  - two `umd/ddr_probe.sv`, one per DDR3 port at emu's `DDRAM*` / `DDRAM2*` wires (what
    the HPS sees): accepted write beats, returned read beats, beats owed, the current and
    the longest BUSY run (saturating: `0xFFFF` = a hang).

  It stays in the release build: the counters only observe, the responder drives the bus
  only for its own command, and an `ifdef` would bring back a rebuild and a seed re-roll
  every time telemetry is wanted (MiSTer_DVD's reasoning).
- **Main:** `main/` builds `MiSTer_UMD` (named `MiSTer_UMD_hil` until B4: since A7 it is the one
  binary users run too, the host module always on under UMD), stock Main plus `support/umd/umd_ctl.cpp`
  (`main/README.md`). It is armed at run time by `/media/fat/umd_hil`; without that file
  it does nothing. It writes `/tmp/umd_telem.json` at 4 Hz and serves `/tmp/umd_ctl`
  (`osd`, `mount`, `ping`).
- **Host:** `mister.py deploy --main`, `telem [--watch N] [--csv F]`, `osd "Name=Value"`.
  `--watch` fits every rate by least squares: endpoint differencing carries +/-1 count
  at each end, MiSTer_DVD measured +/-270 ppm, while the fit is limited only by the
  counter's quantisation. It prints:
  - the raster against 59.94 in ppm;
  - pickups against the authored rate and refreshes per pickup (2.5 for 3:2 and
    23.976, 2.0 for pairs);
  - the STC against 90 kHz;
  - the judder gate (decided == fetched);
  - late / starve / cadence;
  - decode, reader and DDR3 rates, and the ports' BUSY state.

## Sequencing on the target: `mister.py seq` (P6b7)

ssh-paced presses land 1-2 s apart, and a host-side 4 Hz poll carries ssh's jitter too.
`seq` sends ONE python program to the target that presses (the key daemon's FIFO), marks,
screenshots and samples `/tmp/umd_telem.json` in one timebase: `time.monotonic()` is
`CLOCK_MONOTONIC`, the clock `umd_ctl` stamps `t` with. Steps: `wait S`, `key NAME..`,
`mark TEXT`, `shot NAME`, `until FIELD changes|>=|== V TIMEOUT`. `--detach` starts it and
returns (a whole film); `--fetch` pulls its log (`/tmp/umd_seq.jsonl`). `tools/rig_gates.py`
builds the transport's gates on it (`transport.md` §6 / §9).

## What is not here yet

The HUD decoder (`hud_read.py`), the capture card (`capture`, `lipsync_measure.py`) and the navigation
oracle diff. Each returns in the phase that needs it; the capture-card lesson worth
keeping now is that **a sampled capture measures OFFSETS, not RATES**.

## Seeing the aspect: `shot --scaled` (2026-09-26)

A plain `shot` is the core's raw 720x480 raster (ascal's input), where the aspect the
core reports (`VIDEO_ARX/ARY`) is invisible. `shot --scaled` sends Main's `screenshot
scaled`: the scaler's output, cropped to the active picture, so the image's WIDTH is the
measurement -- on a 1080p output 1440x1080 for 4:3 and 1920x1080 for 16:9. Validated
(P5b) on Family Guy (VUI `aspect_ratio_idc` 3): Auto 1440x1080 = the forced 4:3 shot,
forced 16:9 1920x1080. ⚠ A 16:9 result alone proves nothing about the VUI path: the
fallback for an unspecified SAR is also 16:9 -- test on a 4:3-declaring disc.


## HDMI capture: the scaler's output (`tools/hdmi_still.py`, 2026-10-02)

`shot` reads ascal's INPUT, so it cannot see a fault in ascal's output side, the `pll_hdmi`
domain whose slack the fitter reports as framework infrastructure. The capture card on the
workstation (a USB HDMI card, `/dev/video0`, 1920x1080 at 60 fps in YUYV) sees what the TV sees,
on the rig whose HDMI is wired to it (ask which; the rig is shared). `tools/hdmi_still.py` scores a
**still** picture: pause playback (the diagnostic HUD, whose `WT` counter counted while paused,
left the core: A11), and every frame of a digital capture must equal the reference. It streams luma, because
`/home` has no room for 60 s of raw 1080p, and drops 2 s while the card locks.

**First use (2026-10-02), `UMD_p9_20261002_0527.rbf`** (`pll_hdmi` -2.52 ns in ascal's
`o_vacpt` -> `o_adrs_pre` at 148.5 MHz): Akira paused at ~60 s on the rig at `video_mode=8`
(1080p60). 3,585 frames over 60 s were identical to the reference outside the masked counter;
without the mask, the counter's one-digit steps showed in every frame, so the score can see a small
change. No fault at room temperature: the build is trusted on HDMI. The slack is a slow-corner
figure. A later build that worsens it gets this check again.
