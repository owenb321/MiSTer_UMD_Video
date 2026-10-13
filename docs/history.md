# Solved-problem history (condensed)

Each entry: *what was wrong*, *how it was fixed*, one paragraph each. The full
investigation lives in the docs note or PR it names; this file is the index a cold
session reads first.

---

## 1. The scaffold (P0)

**First fit (2026-09-23, `UMD_scaffold_20260923_0328.rbf`, SEED 1, first roll):** 7,190
ALMs of 41,910 (17 %), 10,720 registers, 62 M10K, 36 DSP (33 of them ascal's, 3 the
wave's tint multiplies); clk_dec 352.11 MHz @100 °C / 322.16 @−40 °C against the 86.0
gate (the domain holds one 24-bit counter, so this number says nothing about the decoder
to come); 2.4 MB compressed. No implicit nets, `lint_undriven` and `netlist_canary` PASS.
Per module: framework ~6.4K ALM, `emu` 833 (`xmb_wave` 232, `hps_io` 391,
`block_streamer` 101, `sync_gen` 30, `dec_stub` 12). The wave came in under its 250-ALM
target with 0 M10K.

*Hardware (same day):* loaded on the rig from the menu core; the idle wave came up in
September's tint (the HPS timestamp reached the month FSM), moved between two shots,
no black pixels. Screenshot-only gate; the OSD pop and the mount LED remain unverified.

*What the scaffold taught:* the `hps_io.sv` Icarus limitation (declaration order in the
stock file) means `umd/emu.sv` cannot be elaborated by iverilog with the real `hps_io`;
Quartus and verilator (`lint_undriven`) are the checks for it. Two bench arms were wrong
before the RTL was: a whole-frame motion diff cannot see one frozen wave of three, and the
gradient test was confounded by the waves' own top/bottom asymmetry until the waves were
forced flat for that arm (`docs/idle_screen.md`).

## 2. The first release, v0.1.0 (2026-10-13)

**What shipped:** the release commit `9cfd145` on `main` (after GitHub PRs #1-#3: the move recorded,
chroma interpolated, a field store's vertical chroma step), `CORE_VERSION` `v0.1.0`; the core
`releases/UMD_20261013.rbf` from `build_release.sh --release` at the pinned SEED 5 (clk_dec 89.17 MHz @100 °C /
88.18 @−40 °C, 41,109 ALM, 98 %, RAM 507, DSP 92; every gate PASS) and the UMD Main `MiSTer_UMD` from the same
commit (Main_MiSTer `7317947`, host protocol 1), packed into one zip by CI (`package.yml`). The manual's
announcement bar, home, install and compatibility pages and the README say v0.1.0 instead of "no release
yet"; README's opening qualified (the ARM only serves SD blocks on a stock Main). The bring-up history up to
it is `docs/roadmap.md` and the Forgejo era's PRs `fj#1`-`fj#93`.

*The draft's zip found one defect:* `UMD_INSTALL.txt` (written by `tools/package_release.sh` at the
manifest's commit) still said the `MiSTer.ini` lines were "For SUBTITLES" -- A7's world, not A12's.
Fixed in `2dfb9e1`; the core and the UMD Main rebuilt there came out **bit-identical** to the smoke-tested
pair (the netlist and `BUILD_DATE` unchanged), so `2dfb9e1` is the release commit and the draft targets
it (`gh release edit --target`; `publish_draft.sh` sets it from the manifest since). Smoke test on .201
(stock Main: Akira plays, Subtitle shows "1 English" and the lines, Control Panel's "needs the UMD Main";
the UMD Main: the menus start the film, sound 466 -> 700 frames played with 0 errors, the panel, Stop's
disc screen); the OSD's About line itself was not looked at (a screenshot is upstream of the OSD): the
deployed file's sha256 was checked against the manifest instead.

