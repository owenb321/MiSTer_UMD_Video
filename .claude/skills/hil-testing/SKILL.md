---
name: hil-testing
description: Drive the maintainer's real MiSTer over ssh to test the UMD core — flash a build, launch an image, press keys, pull back a screenshot. Use whenever a question would otherwise be answered by asking the user to test something on hardware, or when a change needs confirming on the board.
---

# Hardware-in-the-loop testing

The rig is reachable over ssh and can be driven end to end: flash, launch an image, press
keys, screenshot. **Prefer this to asking the user to test something.** Design notes:
`docs/hil_harness.md`. This skill is the operating manual.

⚠ **The rig is the maintainer's.** Run `state` first and say what you found before
touching it; a disturbed run of theirs is void, not salvageable. `restore` when done.

## Setup (once per session)

```bash
cat tools/.mister_host          # e.g. root@<mister-ip>  (gitignored, never commit it)
tools/mister.py state           # core loaded, running Main, key daemon, deployed build
```

`tools/mister.py deploy --rbf releases/UMD_x.rbf` flashes a core; `--agent` (re)starts the
key daemon.

**Put the rig back when you are done:** `tools/mister.py restore` (harness files gone,
saved settings restored).

## The tools

| Command | What it does |
|---|---|
| `mister.py launch <iso> --opt "Name=Value"` | write settings, mount, load the core via MGL |
| `mister.py key osd` | press keys (names come from `umd/kbd_map.sv` once it exists; `osd` always) |
| `mister.py shot -o FILE` | screenshot of the core's raw raster |
| `mister.py options` | every OSD option and key name, derived from the RTL |
| `mister.py shell -- <cmd>` | run a command on the target |
| `mister.py deploy --main main/.build/MiSTer_UMD_hil` | install + ARM the HIL Main (telemetry, live OSD); takes effect at the next core load (`main/README.md`) |
| `mister.py telem --watch 60` | rates over 60 s by least-squares fit: pickups vs the authored rate, refreshes / pickup, the judder gate, DDR3 BUSY |
| `mister.py osd "Name=Value"` | set an OSD option LIVE (no relaunch; needs the HIL Main armed) |

**The HIL Main** is only needed for `telem` / `osd`; deploy it once per session. It is
installed under a hash name and pointed at by the `[UMD]` section's `main=` line only;
`restore` removes exactly that line and disarms it, and never touches another core's
`main=` (the maintainer's `[DVD] main=MiSTer_DVDcss` is theirs).

## Traps that have cost real time (inherited, same platform)

- **Screenshots are the CORE's raster, upstream of the OSD.** You cannot see the OSD; set
  options by writing the settings file (`launch --opt`), not by navigating menus.
- **HIL latency is part of the instrument.** ssh-paced presses land 1-2 s apart; a timing
  window under ~3 s must be sequenced ON the target in one session.
- **A screenshot burst resolves ~1 s per frame.** Read a missing frame as missing.
- **The MiSTer has no `pkill`**; use `kill_exact()`.
- **Never overwrite a running Main binary** (it reboots the box). This harness never
  touches the Main.
- **`launch` overwrites the user's saved settings**; it backs them up once; `restore`.
- **Run the OLD build through the same script as the control arm** when a defect is
  intermittent, and change ONE thing per hardware round.
- **A step that never reached the state was not measured.** Wait for a readiness signal
  before acting; a clean measurement of the wrong state reads like "did not reproduce".
- **Telemetry sampled across a launch transient is garbage.** Measure on settled playback.
- **A freeze at a fixed early point that the PREVIOUS build shares is the rig**, not the
  core: an HPS DDR3 port left hung (P5e, 2026-09-26). `telem` shows it as a port's
  `busy` at `0xFFFF` with the decoder stopped. A reboot clears it -- the maintainer's call.
- **Ask "is the PICTURE frozen or is the MACHINE frozen?"**

## Before believing a finding

1. Does it **reproduce**?
2. Would it change if you changed something **unrelated to the core** (settle time, image)?
3. Is the instrument **validated for the thing being claimed**?
4. Is the control arm **capable of failing**? Prove it with a deliberate mutation.
