# Implementation Roadmap: MiSTer UMD Video Player Core

> Speculative "might-be-interesting" ideas that are **not** committed here live in
> [`docs/experiments.md`](experiments.md). Move an item over once it is decided.

> **How to read the checklists.** Four markers, kept honest because a stale one
> misdirects a cold session as surely as a wrong comment:
>
> - `- [x]` — done. Some carry a note where the outcome differed from the plan.
> - `- ⛔ **[superseded — why]**` — no longer wanted *as written*, because the approach
>   changed under it. Kept, not deleted: the reason is usually more useful than the item.
> - `- ⛔ **[dropped — why]**` — reviewed and decided against.
> - `- [ ]` — genuinely still open.
>
> Phase headings carry a status: `🔧 in progress`, `✅ MERGED (PR #n)`,
> `✅ HW-CONFIRMED`, `⏳ HW-confirm pending`. **Flip the marker in the same change that
> completes the work** (CLAUDE.md "Update status markers").

## Guiding principles

- **Self-contained `.rbf`, no HPS-side daemon.** Video and audio decode, navigation and
  presentation all run in FPGA fabric. The ARM only serves SD blocks through the standard
  framework interface. (MiSTer_DVD proved this feasible for a heavier format.)
  **The stock-Main rule (the maintainer, 2026-09-30; `area_plan.md` §8 A5): the core must
  play a UMD ISO on a STOCK Main.** The ISO reader and navigation, the demux, H.264,
  ATRAC3plus, the display and the transport (play / pause / stop, chapters, FF / REW, the
  audio track) stay in fabric, always.
  **Features beyond that may run on the HPS**, in core support code in **the project's own
  Main fork** (`main/`, `support/umd/`, beside the HIL Main's `umd_ctl.cpp`), shipped with
  the core as a release asset.
  - Upstream Main_MiSTer is not asked (2026-09-30).
  - Hosted there: P9's menus (host B), P6c (A6), and, when P9 needs the room, the subtitle
    decoding (A7).
  - A stock-Main user loses only those features, told by a message.
  - The fork follows upstream Main's releases. A separately installed daemon is still out.
  - (This replaces the 2026-09-25 exception, "upstream Main, for the menus only"; the ISO-to-HPS
    contingency is retired, A4.)
- **Never modify `sys/` except as marked `UMD-FORK` edits**, and prefer additive ones. The
  three inherited edits (SDRAM removal, composite-sync ports, ini exports) are documented
  in `architecture.md`.
- **Bench before hardware.** Every module ships with a bench that `$fatal`s, a runner that
  requires the PASS marker positively, and `--red` mutations caught by their own arms.
- **Each phase ends on hardware**, with a stated HW gate and a control arm where the
  defect is intermittent.
- **Design to the spec maximum** (CLAUDE.md). Where a bound must be smaller, the reason
  and the failure mode are written beside the code.


## Where the work stands (2026-10-11) -- start here in a new session

- **Going public on GitHub (decided 2026-10-11, the maintainer): steps 1-3 ✅, step 4 (the first release) next** (`CLAUDE.md` "Source
  control"). A fresh history, as MiSTer_DVD and MiSTer_h264_decoder did: every Forgejo commit carries a
  personal e-mail address, so none is pushed; the tree's files were audited clean (no paths, hosts or
  addresses in any version of any file).
  1. ✅ MERGED (PR fj#93): the pre-public branch: every Forgejo-era PR / issue reference written `fj#NN`
     (747 in 95 files, comments only in RTL: no netlist change), the hosting rules, `docs/README.md`'s note,
     the workflows on current actions with their "inactive" headers gone, `publish_draft.sh` uploading the
     UMD Main, the release and field-report skills on `gh`, the manual's bug-report link.
  2. ✅ The maintainer (2026-10-11): the private, empty GitHub repository; account e-mail privacy on (and "block pushes that
     expose my email").
  3. ✅ (2026-10-11, `ea7659e`) The import: one commit of Forgejo `main`'s tree under `owenb321@users.noreply.github.com` (this
     repository's `user.email`), pushed as GitHub `main`; `origin` -> GitHub, Forgejo kept as `forgejo`.
  4. The first release (the `release` skill): the one release commit, the timing-clean `.rbf` and the UMD
     Main from it, `publish_draft.sh`, CI's zip, the smoke test; public with it.

- **The resume point (Forgejo fj#88 / fj#89, 2026-10-11): ✅ MERGED (PR fj#91), ✅ HW-CONFIRMED** (`docs/resume.md` §7,
  `p9.md` M4n; the UMD Main only). The quit keeps the point before the disc script's `onExit`, the OSD Reset's
  quit keeps it, a used point lasts until its resumed play lands, the disc screen's Play line follows the point
  kept; R7 (the maintainer): Stop on the disc screen forgets the disc's place. No open issues after it.

- **Physical UMDs through a PSP (2026-10-10): ✅ MERGED (PR fj#84), ✅ HW-CONFIRMED** (`docs/psp_disc.md`; every
  rig check, and the maintainer's own test). A PSP with ARK-5's *USB Device = UMD*
  shares its disc as `UMD9660.ISO` on a read-only USB disk; it is an ordinary UMD Video ISO, played over
  USB as fast as needed (1.3 MB/s sequential; the reader sits blocked on a full audio ring; seeks
  0.6-1.9 s).
  - The UMD Main only, no fabric change (`CORE_VERSION` stays `dev-zoom`, no fit): `umd_psp.cpp`
    (a worker finds a PSP among `/media/usb0..7` by its SCSI inquiry in sysfs, reads its PVD each
    second) and `umd_psp_logic.c` (when to mount / unmount; `run_psp_scan.sh --red`, 80 checks, 17
    mutations). Decided with the maintainer: auto-mount + an MGL for stock Main (in the manual, not the zip);
    a disc swapped inside USB mode always asks for USB mode to be re-entered (the PSP's FAT keeps
    the old disc's size); the messages in Main's `Info` box, 2 s late (past the resolution box).
  - Done: the maintainer's own test passed (the manual's MGL under both Mains). Found by it: on a stock Main a
    disconnected PSP's disc plays on from the page cache (documented).

- **Zoom, a letterboxed 4:3 title filling a 16:9 screen (Forgejo fj#71, 2026-10-09): ✅ MERGED (PR fj#83), ✅ HW-CONFIRMED**
  (`docs/zoom.md`, `CORE_VERSION` `dev-zoom`). Aspect Ratio's fourth value (`O[2:1]` = 3, no new bit):
  - the 480p raster's lines 60 .. 419 at 16:9; DE dropped and the RGB blanked outside them (`umd/zoom_ctl.sv`);
  - off at 480i, under a disc menu, at STOP, on a 16:9 or non-720x480 picture;
  - the HUD in its title-safe layout moved 7 lines down; subtitles moved into the band (fabric and, under the
    panel, the UMD Main via HOST_RD AUDIO[10]).
  - Decided with the maintainer: Z1-Z4 (`zoom.md` §1). Benches green with RED: `run_zoom.sh`,
    `run_overlay.sh` (O5-O7), `run_transport_hud.sh` (Z1 / Z2), `run_umd_host.sh` (H32), `run_panel.sh`
    (R14-R17; its `[run]` stage, broken since PR fj#78 by `umd_menu_event`'s new field, fixed),
    `run_scaffold.sh` (W142-W152; the duplicate W127 / W128 renamed W153 / W154).
  - Fit SEED 5 PASS 88.50 / 88.07 (`UMD_zoom_20261009_2050.rbf`); its 98 % ALM is the fitter's packing
    estimate, the logic +208 ALUTs (`zoom.md` §6.1). ✅ On the rig (.236, 2026-10-09, `zoom.md` §6):
    Short Circuit fills 16:9, the HUD and subtitles (also under the panel) inside the band, STOP / menus /
    16:9 titles unzoomed, errors 0.
  - ✅ The maintainer's own test on .236 passed (2026-10-09). ✅ MERGED (PR fj#83).

- **Chroma interpolated, not nearest (2026-10-12): ✅ MERGED (PR #2), ✅ HW-CONFIRMED (.201)**
  (`docs/display.md` §12, `CORE_VERSION` `dev-chroma`): the H264 core's "chroma at the identity" ported -- an odd
  column `(c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1` at 480p and 480i Fit / Letterbox, a 480p frame store vertically
  `(3 h[m] + h[m -+ 1] + 2) >> 2`; field stores stay nearest vertically, Crop and the window unchanged. The siting
  fixed at type 0 (0 of 691 clips declare one: `spec_hardening.md`). `run_disp_reader.sh` GREEN + `--red` Z1-Z11
  (K9 / K10's dead anchors fixed); plane / overlay / zoom / scaffold green. Fit SEED 5 PASS 87.31 / 89.20, 40,926
  ALM (ALUTs -41), `UMD_chroma_20261012_0529.rbf`. ✅ On .201: six paused pictures (Akira's frames, Family Guy's
  field pairs) equal the golden on every pixel outside the pause glyph, nearest off by 50-110K pixels each
  (`display.md` §12, `tools/chroma_shot_check.py`). 480i on the CRT not looked at.
- **A field store's vertical chroma step (2026-10-12): ✅ MERGED (PR #3), ✅ HW-CONFIRMED (.201)**
  (`docs/display.md` §13, `CORE_VERSION` `dev-chromafld`): Weave / the film weave at 480p blend each field's chroma
  rows at H.264 Figure E-1's field siting (a quarter / three quarters down the field's line pair: 7/8 + 1/8, 5/8 +
  3/8), the far-side row fetched with the line (four neighbour RAMs). Golden checked against ffmpeg's interlaced
  upsampling (`scale=interl=1`); `run_disp_reader.sh` GREEN + `--red` V1-V8. Fit SEED 5 PASS 87.87 / 88.89, 41,130
  ALM (ALUTs +424), RAM +4, `UMD_chromafld_20261012_1940.rbf`. Found on the way: the H264 core's field rule is
  field-centred, an eighth off (`harvest.md`, to port back). ✅ On .201: three paused Family Guy pictures equal the
  golden on every pixel outside the pause glyph (the previous rule off by 30-64K pixels each), Akira's frame unchanged,
  `d2_busy_max` 49 on both.
- **Hard-telecined film, field matching (Forgejo fj#80, 2026-10-08/09): ✅ MERGED (PR fj#82), ✅ HW-CONFIRMED**
  (`docs/telecine.md`). 15 main titles are film coded as 59.94
  field pairs with the 3:2 baked in; Weave combs 2 pairs in 5 there.
  - `tools/telecine_ref.py` models what `disp_reader` can see: Σ|2b−a−d| / Σ|a−d| over the
    displayed weave, plus the cadence lock. `test_telecine_ref.py` passes, and 8 RED
    mutations are caught.
  - `tools/telecine_census.py` ran over 168 windows. **0 locks on the 12 true-video windows**
    (margin 1 of 8 cycles).
  - Combed refreshes on clean 3:2: 33.0 % → 0.49 % with Bob while unlocked, → 4.35 % with
    Weave.
  - Combed refreshes on noisy 3:2: 15.2 % → 0.26 % with Bob, → 4.81 % with Weave.
  - While locked: 0.4-0.6 % combed.
  - The matching rule is measured on the pictures: 97 % of split pairs read clean both ways.
    The exception is Interstella 5555, which is not 3:2 and never locks.
  - **Decided 2026-10-08 (`telecine.md` §6):**
    - T1: Auto. No OSD option; the matching runs in every 480p mode.
    - T2: unlocked shows the setting, Weave by default.
    - T3: build the RTL.
  - **The RTL ✅ built (2026-10-09, `telecine.md` §5)**: `umd/film_lock.sv`, `disp_ctl`'s partner hold,
    `disp_reader`'s partner fetch and comb sums, the telemetry word `film`.
    - Benches: `run_film_lock.sh` (28 arms, F1-F13), `run_disp_reader.sh` (M1-M10) and
      `run_disp_sched.sh` (74 of 74 scenarios, the new telecine ones included; H1-H7).
    - Fit: SEED 5 PASS 90.76 / 89.11 MHz, 39,718 ALM (95 %, +215).
    - **✅ HW-CONFIRMED on .236 (§7).** Austin Powers 2 and The Simpsons Movie lock; the shots
      after the lock are clean; The Office and Now 2006 never lock; Akira's feature never phases.
  - **✅ MERGED (PR fj#82)**, after the maintainer's own test on .236. (Earlier stage notes: `telecine.md` §6, a `Film` OSD value or
    Auto; Bob or Weave while unlocked; build or not). Then the RTL (`telecine.md` §5:
    `disp_ctl`'s release delay, `disp_reader`'s partner store and the accumulators, the FSM),
    with `synth_unit.sh` before any fit.

- **Select is Play/Pause (2026-10-07): ✅ MERGED (PR fj#75), ✅ HW-CONFIRMED on .201 (2026-10-08)** (`docs/transport.md` §9
  "Select"): the maintainer renamed the x button "Select/Pause" to **Select** and made it Play/Pause's
  toggle in playback (`emu`'s `btn_cmd[5]` -> PLAYPAUSE; from Stop it plays too); the panel's Pause item
  is now the command PAUSE (code 2), so it stays a pause. Benches: `run_scaffold.sh --red`, `run_panel.sh
  --red` (P32), `run_menu.sh`. Fit SEED 3 PASS 88.62 / 88.29, 39,566 ALM (`UMD_select_20261008_0102.rbf`).
  On .201: Select pauses / plays / resumes from Stop / ends FF; the panel's Pause stays a pause.

- **A-B Repeat (2026-10-07): ✅ MERGED (PR fj#63), ✅ HW-CONFIRMED** (`docs/ab_repeat.md`, branch
  `feature/ab-repeat`): the maintainer took A-B only, in fabric, on the panel's row 3 and the keyboard's B (no J1
  button); the PSP measured and every decision taken (§6); `umd/ab_ctl.sv` beside `goto_ctl`, the HUD's tag,
  the panel's A-B Repeat / Clear. Fit SEED 3 PASS 91.6 / 88.72, 39,507 ALM. On .236: loops, the controls during
  one, a loop across items, a bare file, the panel (§7).

- **P8, as of 2026-10-06:** bare `.MPS` loading ✅ (PR fj#48, HW); `.PMF` out of scope (fj#49); MGL
  launch validated end to end on .201 ✅ (fj#53, `mgl_launch.md`); the bug bundle
  `tools/umd_report.py` ✅ (fj#54, `bug_reports.md`). Open: the item handoff (measured, Phase 8
  below), seek on a bare file (a design choice: `bare_streams.md` §5), small pictures centred (low);
  resume per disc parked (`feature/resume`, design only).

- **Analog Dither (2026-10-06): ✅ MERGED (PR fj#56), ✅ HW-CONFIRMED** (the maintainer on .236's CRT) (`analog.md` §9). The
  H264 core's and MiSTer_DVD's OSD option (`O[16]`, Off by default), DVD's 27 MHz module: an ordered
  Latin-square dither ahead of the 18-bit I/O board's 6-bit DAC, analog only. `run_dac_dither.sh --red`,
  `check_emu_wiring` W130 / W131, T5-T8. Fit SEED 5 PASS 92.44 / 91.42, 39,291 ALM (`UMD_dither_20261007_0110.rbf`). The regression guard on .236 ✅ (errors 0, the paused shot identical Off / On). The maintainer's CRT A/B there ✅ (the idle wave and Akira better than the plain 18-bit output). Merged (PR fj#56).
- **Engine + microcode survey (2026-10-06, analysis only, `area_plan.md` §10):** where MiSTer_DVD's
  shared-engine move (its PRs #148-#150, patterned on this core's ATRAC3plus sequencer) would pay
  here. First candidate: `umd_reader`'s parse (3,749 ALM) on a clk_sys navigation engine. Back from
  the HPS: only the subtitle decode, and A-B / Repeat as a routine (§10f).
  **Taken (A12, the maintainer 2026-10-06): `docs/nav_engine.md`. ✅ MERGED (PR fj#59, 2026-10-07), ✅ HW-CONFIRMED.** N0 measured: the parse is ~95 % of
  the reader, the move saves an est. ~2.0-2.7K ALM, enough for the hardwired subtitle decoder back
  under 95 %. E1 / E2 taken: the hardwired decoder back, the fabric always decodes. **N1 ✅ (the model,
  `feature/nav-engine`): the program passes the reader's own gate on 267 of 267 fixtures, 62 mutations
  caught (`bench/umd/run_nav_model.sh --red`).** **N2 ✅ the RTL (the reader's bench ALL GREEN);
  N3 ✅ the fit: 36,384 ALM (87 %, -2,743), clk_dec 89.72 / 89.06; ✅ HW-CONFIRMED on the rig.** **SD1-SD3 built
  (`nav_engine.md` §11): the subtitle decode back in fabric, subtitles on a stock Main; fit 39,117 ALM (93 %), ✅ HW-CONFIRMED; merged with main, SEED 3 pinned (90.58 / 86.96, 39,425 ALM).**

- **P6d, the control panel on the HPS: ✅ MERGED (PR fj#46, 2026-10-05), ✅ HW-CONFIRMED** (`docs/panel.md`; the
  maintainer's own test on the rig: "the panel looks great and works fine"). The PSP's △ panel drawn by the UMD Main,
  each item its own button's press, subtitles kept under it (`ui_sub`, planes 2 / 3); after the test, Audio /
  Subtitle show the current track before they switch (buttons and panel). Fit SEED 1 88.04 / 87.82 MHz, 38,676 ALM.
  The rig checks owed after it ✅ done on .201 (PR fj#50, `panel.md` §3.10b): 480p, every item, Go To's cancel,
  the stale-Main message, the poll's cost (an apparent loss of fast presses was the HIL daemon's 170 ms pacing:
  §3.10b, corrected).

- **Done and HW-confirmed:** P0-P5, P6a, P6b, and P7 (subtitles, PR fj#29).
  - The core plays a disc end to end on a stock Main: picture, sound, chapters, pause / stop,
    FF / REW, the audio and subtitle tracks, the PSP-style HUD.
  - **The device was at 98 % ALM** after P7 (40,875; SEED 3 pinned), **~90 % since A7** (37,829
    with 480i). A netlist change gets one fit at the pinned seed; a 5-seed sweep only if it misses,
    passes by < 1.5 MHz at either corner, or the device is above 95 % (`area_plan.md` §2, A2').
- **Decided 2026-09-30 (`area_plan.md` §8):**
  - the stock-Main rule (A5; ISO handling stays in fabric);
  - P6c runs on the HPS (A6);
  - the subtitle decode moves to the HPS (A7), **taken now** (A10, below);
  - the HUDs and the instrumentation stay in fabric (A8).
- **The order of work** (re-ordered by the maintainer 2026-09-30, `area_plan.md` §8 A10: area
  before more decoder work; at 98 % every netlist change re-rolls the seed lottery; steps 1-3 and
  5 ✅ accepted as `area_plan.md` §9 orders them):
  1. **A7, the subtitle decode to the HPS**, planned in `docs/hps_host.md` (written 2026-09-30,
     📐 NOT built). Decisions H1-H8 + G1 taken 2026-09-30: libpng on the HPS; one plane
     (subtitles in playback, the host's pages in a P9 menu); P6c cut to Go To.
     - ✅ B1 MERGED (PR fj#32, 2026-09-30): the host decoder on the PC (libpng, the plane
       writer, the ring reader), `bench/umd/run_hps_sub.sh`: every subtitle unit and menu PNG
       equal to libpng, on this PC's libpng and the device's 1.6.37 (re-pinned by B2: the rig runs the Linux image's 1.6.37).
     - B2 measured (2026-09-30, `hps_host.md` §6 "B2, the results"): the readback, the poll
       (a NAS browse 33 ms at worst), the width bound and `main=` ✅; the device's libpng is
       1.6.37 (re-pinned); **the budget ❌ as built** (68 ms against 50 on a 720 x 480 unit).
       The maintainer took option 1: a palette fast path in `umd_sub` plus 64-bit stores (every
       subtitle unit is 4-bit palette). Built, bench green, **the budget met on the rig at
       31 ms**, the plane exact on silicon. ✅ B2 MERGED (PR fj#33).
     - ✅ B3 MERGED (PR fj#34, 2026-10-01; `hps_host.md` §6 "B3, as built"): `umd_host.sv`,
       the decode out of `sub_top` (the mock host in the benches), SUB gated on the UMD Main with
       its HUD message.
     - ✅ B4 MERGED (PR fj#35, 2026-10-01; `hps_host.md` §6 "B4, as built"): the UMD
       Main's host module (`umd_host.cpp`, its logic PC-benched), **subtitles end to end on the rig**
       (Akira, The Mummy's 0.1 s window, jumps, trick play, a browse, Aliens' tracks: `D00 L00`).
       5 of 5 seeds pass (SEED 11 pinned).
     - ✅ B5 MERGED (PR fj#36, 2026-10-01; `hps_host.md` §1 "Packaging"): one install zip
       with the core and the UMD Main from one commit, the manual's install / compatibility /
       troubleshooting pages, NOTICE's source pointer. **A7 completes with its merge; then G1.**
     - Then B3 (the fabric: `umd_host.sv`, `sub_overlay` without its decoder), B4 (the Main
       module, the fit, a 5-seed sweep, the rig) and B5 (packaging, the manual).
     - It frees ~2.0-2.6K ALM (estimated, `hps_host.md` §3.1).
  2. **480i with Analog Aspect** (Auto / Letterbox / Fit / Crop for a CRT; fabric, the maintainer
     2026-09-30; "Moved out of P5"): ~300 ALM for 480i as the H264 fork measured it, ~530 for
     the aspect modes as MiSTer_DVD measured them (`area_plan.md` §9).
     - ✅ **MERGED (PR fj#37, 2026-10-01), planned in `docs/analog.md`** (decisions V1-V11;
       the maintainer took V6 field order in S1 "as DVD solved it", raw-raster subtitles, and
       Letterbox's exact per-field phase). Two stages, both built, benched, fitted
       (S2: 37,612 ALM, +449 over A7's fit; 6 of 6 seeds, SEED 11 pinned) and rig-checked over HDMI;
       ✅ HW-CONFIRMED on the CRT by the maintainer (2026-10-01, `analog.md` §5). The HUD inside the
       title-safe area at 480i (`analog.md` §8, V12) ✅ HW-CONFIRMED on the CRT.
  3. **Go To on the core, designed to a cap, or dropped (G1)**: the cap is what the fit after
     480i leaves, minus a reserve for P9's host-port rows (`area_plan.md` §9, `p6c.md` §9; est.
     0.75-1.9K). A-B / Repeat, slow motion and frame advance are dropped for now (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**). D15 / D16 need
     a PSP measurement first.
  4. **Harvest the H264 fork's zero-cycle retimes** (A9, now after A7's fit) -- ✅ **MERGED (PR fj#47), 2026-10-05** (`h264_recon.md` §6.5): every bench green and RED, the cosim sample
     bit-exact at unchanged cycles, **5 of 5 seeds pass** (SEED 5 pinned, 89.50 / 89.05, 38,728 ALM,
     `UMD_retime_20261005_1520.rbf`); found on the way: `run_h264_top.sh` running a stale binary since
     P6b4, and P6d's kept subtitle request missing from `umd.sdc`. ✅ HW-CONFIRMED 2026-10-05 (Akira and Family Guy 60 s each, errors 0, the judder gate equal; subtitles and the panel). `../MiSTer_h264_decoder`
     `main` (the commits of the remote branch `feature/clk-dec-up`): `c63a195` (`sfifo`'s full,
     `mb_syntax`'s neighbour table, `recon_dpb`'s frame_num wrap, `slice_hdr`'s SliceQPY check),
     `7340353` (`recon_lists`' field parity), `e125f75` (type-1 POC set-up: one cycle a picture).
     - Hand ports, logged in `harvest.md`. Diff each file against ours first: the trees
       have diverged (checked 2026-09-30: our `umd/sfifo.sv` still has the pre-retime `full` /
       `rd_ok`, so `c63a195`'s change applies; bring its bench arms along, F3 / F4 and the
       `sfifo_tb` phase streaming from full).
     - Skip any that add macroblock cycles unless the cosim sample shows room (The Office
       Disc 01's 1.35x floor).
     - Fit, and sweep 5 seeds.
  5. **P9 on host B** (`menus.md`; the plan `docs/p9.md`). ✅ **M0-M3b MERGED (PR fj#38, 2026-10-03),
     ✅ HW-CONFIRMED on the three captured discs** (taken by the maintainer 2026-10-01, before steps
     3-4; decisions P9-1..P9-6 in `p9.md` §7). **M4b ✅ MERGED (PR fj#42, 2026-10-04)** (the maintainer's rig tests: iconOffset anchors, a 3-D scene, script tweens replacing, `Function.call`, short-way rotation; `p9.md` §3.3 "M4b"). **M4c ✅ MERGED (PR fj#43, 2026-10-04), ✅ HW-CONFIRMED**; **M4d ✅ MERGED (PR fj#45, 2026-10-04), ✅ HW-CONFIRMED**; **M4e ✅ MERGED (PR fj#77, 2026-10-08), ✅ HW-CONFIRMED** (the maintainer's rig session of 2026-10-07, Forgejo fj#70 / fj#72 / fj#68: `onExit` detached at a new image, the transport under an invisible page, focus at activation; `p9.md` §3.3 "M4e"); **M4f + fj#64 ✅ MERGED (PR fj#78, 2026-10-08), ✅ HW-CONFIRMED**; **M4g ✅ MERGED (PR fj#79, 2026-10-08), ✅ HW-CONFIRMED** (fj#74, the menu renderer's speed on the A9, every step exact: The Rock's menu 141 -> ~43 ms a frame on the rig; `p9.md` §3.3 "M4g"); **M4h ✅ MERGED (PR fj#81, 2026-10-08), ✅ HW-CONFIRMED** (the maintainer's hand test on .236, 2026-10-08: The Rock's menu, Letterbox / Crop on the CRT, the disc screen, the panel over a menu) (THE CANVAS: the menu drawn at the PSP's 480 x 272 and its damage stretched onto the plane on the A9, The Rock's menu 48.3 -> 33.9 ms a frame on the A9 bench, 47.3 -> 41.0 ms a frame in the real Main on the rig (THE PROFILE); the next frame drawn during the flip's 29 ms round trip and the engine ticked at most every 10 ms: The Rock's menu 15.2 -> 25.1 frames a second on the rig; the PSP's TV out measured to keep the video at 720 x 480 under a menu; the stretch in fabric a measured-later candidate; `p9.md` §3.3 "M4h"); **M4i ✅ MERGED (PR fj#85, 2026-10-10), ✅ HW-CONFIRMED (.236)** (fj#73: THE SIZE MODE -- a Plane's `unknownInt18` / a UButton's `unknownInt32` says whether an image fills its object's box (0) or is drawn at its own size (0xFFFF / -1): The Rock's scene titles as the maintainer's PSP photo shows them; gate `rock-scenes`, RED G57 G58, 83 of 88 library images the same pixels; `p9.md` §3.3 "M4i"); **M4j ✅ MERGED (PR fj#86, 2026-10-10), ✅ HW-CONFIRMED (.236)** (fj#68: ANOTHER ANIMATION'S STEP REPLACES -- an animation's step cancels the running tweens of that property another animation started: The Rock's main menu opens with PLAY focused as the maintainer's PSP photo shows; gate `rock-root-focus`, RED G59; `p9.md` §3.3 "M4j") **M4k ✅ MERGED (PR fj#87, 2026-10-10), ✅ HW-CONFIRMED (.236)** (the maintainer's PSP batch of 2026-10-10, fj#65 / fj#66: pauseMode 1 starts paused on the requested chapter's first picture -- The Animatrix's stills, Goldmember's Great Titles --; getPlayerStatus reports a play() not yet landed -- Goldmember's return to its main menu --; the system stops a menu's playback at a resource change -- A Few Good Men's warning cards over black; gates `animatrix-still-held`, `afgm-play-warnings`, `goldmember-gt-return`, RED H87-H89 G60 G61; `p9.md` §3.3 "M4k"; fj#67 and fj#68 closed by the same batch); **M4l ✅ MERGED (PR fj#90), ✅ HW-CONFIRMED** (fj#69: ALPHA IS WRITTEN DOWN, NOT INHERITED -- a parent's alpha write tweens its descendants to their own alpha times the value, no draw-time inheritance: Hackers', The Transporter's, The Fifth Element's options and X-Men's languages drawn as on the maintainer's PSP; gates `hackers-wheel`, `transporter-pivots`, `fifth-root-play`, `xmen-setup-langs`, `incredibles-setup-fade`, RED G62-G65; `p9.md` §3.3 "M4l"; ✅ on the rig, .236: Hackers, The Transporter, X-Men as the PSP); **M4m ✅ MERGED (PR fj#90), ✅ HW-CONFIRMED** (A PAGE'S ANIMATIONS END WITH IT: a closed page's animation runs stop -- The Animatrix's idle timer cut a chosen segment to the first; gate `animatrix-segment-timer`, RED G66; `p9.md` §3.3 "M4m"); **M4n ✅ MERGED (PR fj#91), ✅ HW-CONFIRMED (.236)** (fj#88 / fj#89: the quit keeps the resume point before the script's `onExit` -- Aliens' and The Animatrix's stop the film --, the OSD Reset's quit keeps it, a used point lasts until its resumed play lands, the disc screen's Play line follows the point kept; R7, Stop on the disc screen forgets the disc's place; gates `aliens-quit-resume`, `aliens-reset-resume`, `animatrix-relaunch-*`, `akira-*-discscreen-forget`, RED H90-H98; `resume.md` §7, `p9.md` §3.3 "M4n") (a CHAPTER read before the latest `play()` is stale: Aliens' continue opened no menu, Forgejo fj#76, `p9.md` §3.3 "M4f"; with the fabric's OSD Reset that walked and played the disc behind the idle screen, fj#64: `nav_seq` resets to the STOP vector, `nav_engine.md` §7; fit SEED 5 91.45 / 89.41, 39,503 ALM; ✅ on the rig, .236, 2026-10-08) (the renderer draws only the damage: Terminator 2's menu 8 -> 33 frames a second on the rig; `p9.md` §3.3 "M4d") (an animation plays once at a time: MCR disc 2's residual highlights after rapid presses, reproduced on the PC, gate `mcr2-rapid`, RED G54; `p9.md` §3.3 "M4c"). **M4 ✅ MERGED (PR fj#39, 2026-10-03), ✅ HW-CONFIRMED: every library disc
     (88 images) reaches its feature through its own menus (85) or startup chain (3) on host C, Square
     bringing a menu back on all (`tools/menu_lib.py`, `run_menu.sh --lib`); ten engine rules and a fabric
     gap (a menu over a stopped player) found and fixed, each with its RED arm (`p9.md` §3.3 "M4"); the rig
     sample matches the PC; fit SEED 9 PASS 90.56 / 92.17; ✅ the stopped-player menu on the rig:**
     - ✅ M0: the census and the disassembly (`tools/rco_census.py`); the first PSP captures read
       (Family Guy, Akira, Austin Powers 2: the startup file is `<lang>100000.RCO`, Circle at the
       top is the system's stop, Square brings the menu up in playback; `p9.md` §2).
     - M2, the fabric, items 1-5 ✅ built and benched (2026-10-01/02): `NAV_PLAY` in the reader,
       the host rows (PLAYLIST / SUB_SET in `player_ctl`), the button gate, the plane hand-over, the
       sound one-shot. **Fit SEED 11 PASS 90.19 / 90.11, 38,855 ALM (93 %, +1,026)**,
       `UMD_p9_20261002_0426.rbf` (not rig-checked: nothing drives the rows until M3's Main).
     - Item 6, the video window ✅ built and benched (2026-10-02: a scaler in `disp_reader`, the
       geometry a host-row level). **M2 complete: fit SEED 11 PASS 89.46 / 89.17, 39,097 ALM (93 %)**,
       `UMD_p9_20261002_0527.rbf`. ✅ `pll_hdmi` -2.52 ns inside `ascal` (framework; grew with the
       density) checked on the rig's HDMI at 1080p60 (2026-10-02): 3,585 captured frames of a paused
       picture identical (`tools/hdmi_still.py`, `hil_harness.md` "HDMI capture").
     - ✅ M1a (the RCO loader) and M1b (the VSMX VM and the engine, 2026-10-02): on the PC the
       three captured discs run their startup chains to their main menus and a key path each as the
       PSP did (`run_menu.sh --red`, `tools/menu_gate.py`, G1-G8; eight rules the bytecode settled,
       `p9.md` §3.3 -- a script's playlist number counts from 1).
     - ✅ M1c (the picture, 2026-10-02): `menu_render()` draws the scene (854 x 480, centre origin,
       y up, measured on the discs' own numbers) at any target and in the subtitle plane's own pixel
       layout; Family Guy's titles, Akira's menu bar and Austin Powers 2's language page and main
       menu land within 2 px of the PSP captures at 480 x 272 (`menu_gate.py` "draw", G9-G17);
       durations are ms, measured (`p9.md` §3.3 M1c). Austin Powers 2's "video in a window" turned
       out to be authored into its video (no P9-5 on the three discs).
     - ✅ M1d (relaunch, 2026-10-02): quitting calls the scripts' `onExit`, relaunching their
       `onContinuePlay` with the kept user data -- Akira back into its film, Austin Powers 2 back to
       its main menu, as captured (`menu_gate.py`'s relaunch scenarios, G18-G20). **M1 complete.**
     - ✅ M3 (the engine in the UMD Main), the leaves first, each benched on the PC: ✅ (A) the image
       reader, ✅ (B) PLAYLIST.UMD, ✅ (D) the host-row logic, ✅ (E1, 2026-10-02) the menu host
       (`umd_menu_host.c`: every captured scenario through the whole Main path against a core model,
       `menu_gate.py --host`, H1-H11; it found the mount race -- the engine now starts at the mount's
       landing). ✅ E2, the glue: the runner (`umd_menu_run.c`, benched: the mount, the quits, the
       OSD's Reset, the render rule; H16-H18), `umd_menu.cpp` (the worker, the mailbox, the plane, the
       decoders, the kept files) and Main's hooks (mount, core load); `MiSTer_UMD` builds with the
       menus. Also: the maintainer's PSP tests and the library sweep in the gate, MoveTo measured
       absolute, the OSD's Menu Language (fit SEED 11 PASS 89.38 / 88.45). ✅ (C) the sounds (VAG
       equal to ffmpeg on the library, the PCM one-shot). Three rig sessions on Family Guy (`p9.md`
       §3.3): the render's fast path, the field-store window, and from the third (2026-10-03) a page
       built afresh at each open (the black episode page), a page's own `children` (Previews),
       play()'s audio off muted (`ctl[13]`), the presentation following what a page draws (the CRT
       squeeze at an episode's start), menus fitted to a 4:3 CRT at 480i (Auto / Letterbox:
       letterboxed; Crop: cropped; `analog.md` §7), the Cross button named Select/Pause. Those on the rig
       and the CRT, M3b (Menus On / Off) and the other captured discs: all ✅ since (PR fj#38, fj#39).
     - ✅ The 8 MB PCM region taken by the maintainer (2026-10-02, `spec_hardening.md`).
     - ✅ **Menus: On / Off in the OSD** (the maintainer, 2026-10-03; MERGED PR fj#38, Off / On checked on the rig; `p9.md` §4 M3b):
       shown only when the UMD Main's menu host is present (a hide prefix on a status bit the host
       sets, so a stock Main never shows a choice that does nothing); Off with the UMD Main present
       behaves exactly as the bare `.rbf` on a stock Main -- the longest playlist plays at once, no
       engine, no plane hand-over, no menu sounds.
- **Open, the maintainer's call:** a first release (none has been cut; the `release` skill).

## Throughput doctrine

The whole design rests on how small the target is. Every UMD Video disc surveyed is
H.264 Main profile Level 3.0 at 720x480, 23.976 fps film, about 1.7 Mbit/s:

| | samples/s (4:2:0) |
|---|---|
| 720x480 @ 23.976 (every surveyed disc) | 12.4 M |
| Level 3.0 ceiling, 720x480 @ 30 | 15.5 M |
| clk_dec cycles available | 81 M |

So every decoder block is **serial**: one sample, one tap or one coefficient per cycle,
one datapath shared across states. That is where the logic savings against published
HDTV designs (which run 4 to 16 samples per cycle) come from. CABAC needs about
2 Mbins/s average and 13 Mbins/s at the Level 3 bitrate ceiling; one bin per two cycles
at 81 MHz is 40 Mbins/s, so no speculation is needed.

## Resource checkpoints

| after phase | ALM budget (cumulative) | M10K | notes |
|---|---|---|---|
| P0 | **7,190 measured** (framework 6.4K + emu 0.8K) | **62** | first fit, SEED 1; `UMD.qsf` ledger |
| P2 | +3-4K; **9,539 measured** (+2,349) | +10; **86 measured** (+24) | reader 2,041 ALM, 16 KB cache = 16 M10K, HUD 4 M10K; no ring yet (moved to P6) |
| P3 | ≤ 10K; **12,959 measured** | +8; **99 measured** | the front end 3,640 in the core |
| P4 | ≤ 20K; **38,259 measured 2026-09-24** (91 %: the reconstruction 24,639); **25,602 after the area work** (61 %: the reconstruction 11,930) | +40; **184 → 227** | ✅ every exit criterion met on one build: **25,054** (60 %: the reconstruction 11,470), clk_dec 93.67 / 92.18, real time on the rig (`UMD_p4recon_20260925_0016.rbf`, below) |
| P5 | ≤ 28K (re-planned); **28,073 measured** (the P5g fit, 67 %) -- 73 over | +10; **256 measured** (+29: the deinterlacer's nine line RAMs, +18) | +3,019 over P4's 25,054: the display path (~2.6K) **plus HIL telemetry (+394), which the plan did not hold**; csync and the vertical scaler (+~2K planned) moved out of P5 unbuilt: whichever phase builds them carries them against its own budget (P5g, 2026-09-27) |
| P6 (P6a-P6b) | ≤ 35K (re-planned); **34,961 measured** (`UMD_loneearly_20260930_0446.rbf`, 83 %) -- 39 under | +30; **419 measured** | ATRAC3plus, the compressed-video buffer, the transport, the HUD; 78 DSP. P6c is planned apart (below) |
| P7 | **the sweep rule** (`area_plan.md` A2, the maintainer 2026-09-30): P7's checkpoint is its measured fit, provided a 5-seed sweep passes on >= 3 seeds at 86 MHz both corners; **est. ~39.9-40.1K (95-96 %)**: `sub_overlay` 4,691 measured after A3 (`area_plan.md` §6) + its wiring. Was ≤ 37.5K | ~~+6~~ **+~44 for the decoder** (the 32 KB window is 32 alone) + 16 for the compositor | `sub_overlay` (the chain with the decoder + the compositor, emu's one instance) **4,744 ALM, 72 RAM, 18 DSP** in a unit fit (2026-09-26); **4,691 ALM, 72 RAM, 6 DSP after A3** (2026-09-30, `compositor.md` §7): a floor, plus the `emu` wiring (est. +200-400); DSP 84 of 112. No framework switch taken (A1) |
| P6c | **on the HPS** (A6, 2026-09-30): the fabric pays only the host-B contract it needs (a command path into `player_ctl`, a surface to draw on; `area_plan.md` §8), not the 1.3-2.5K a fabric P6c would have cost | -- | needs room at 98 %: Q1 (with A7) |
| P9 menus | **host B** (host A, the fabric soft CPU at +2.5-4K more, is out by arithmetic: `area_plan.md` §1); the contract ~~+~1.1-1.6K (incl. the bilinear plane scaler)~~: **the host port's P9 rows plus the PCM one-shot** (the menus draw into the 1:1 subtitle plane, which the host takes over while a menu is up, rendered at 720 x 480: no second plane, no bilinear scaler; `hps_host.md` §3.4) | +4-8 | estimates (`menus.md` §4-5). Host B lives in the project's Main fork (`main/`; upstream not asked). The ISO handling stays in fabric (A5). A7 (the subtitle decode to the HPS, frees ~2.0-2.6K ALM net, ~50 M10K) is taken NOW (A10) |

**Re-planned 2026-09-30 after P6 (`area_plan.md`):** P7's measured 4,744 ALM made the 37.5K
checkpoint unreachable; the rest of the device (P7, P6c, P9, 480i) is planned there in one
pass, with the levers measured.

**Re-planned 2026-09-24 from the P4 measurement** (the first plan assumed a 7-10K
reconstruction; the correctness-first one placed at 24.6K). The measured blocks at the
20-store build: framework (`sys/`) ~6,300 ALM, the reconstruction 24,639, the front end
3,571, the ISO reader 1,933, the rest of `emu` (demux, HUD, display smoke, CDC, mux)
~1,800. The P4 exit budget keeps everything but the reconstruction as measured.

**Decision (user, 2026-09-24): if area forces something off the FPGA, it is the ISO
handling, not A/V decode.** The disc read -- the ISO 9660 walk, `PLAYLIST.UMD` /
`CLIPINF` parsing, the sector reads (`umd/umd_reader.sv`, 1,933 ALM + its 16-M10K cache)
-- would move to the HPS (a helper beside Main, handing the core the main title's
stream), and the FPGA keeps everything from the program stream on: demux, H.264,
ATRAC3plus, subtitles, display. A contingency, not the plan: taken only if the
re-planned budget cannot be met by area work.

Device: 41,910 ALM, 553 M10K, 112 DSP. Gate on the measured `DVD.fit.rpt`-style numbers
after each phase, not on these estimates.

---

## Phase 0 — Scaffold ✅ MERGED (PR fj#1) · ✅ HW-CONFIRMED

**Goal:** the core compiles, loads, shows the idle wave on HDMI and analog, opens the OSD,
and streams a mounted image's blocks. Nothing decodes.

- [x] Framework (`sys/`) with the MiSTer_DVD edits kept: SDRAM removal, `VGA_CS`
      composite-sync ports, `hps_io` ini exports and `TIMESTAMP`; the bitstream
      passthrough muxes dropped; the unused Template PLL qip line removed.
- [x] `umd/emu.sv`: clocks (`sys_pll` 27/90/25/81), reset, CONF_STR v1 (`Aspect Ratio`,
      `Reset`, four transport buttons), `hps_io` at `BLKSZ=4`, mount handling, the startup
      OSD pop, idle aspect, registered output stage.
- [x] `umd/sync_gen.sv`: 720x480p @ 27 MHz in syncgen's coordinate convention.
- [x] `umd/xmb_wave.sv`: the procedural month-tinted wave, month from the HPS timestamp.
- [x] `umd/dec_stub.sv`: keeps a register in clk_dec so the Fmax gate has a row.
- [x] `umd/block_streamer.sv`: the sd-path proof (2048-byte blocks).
- [x] Build gates renamed (`build_release.sh`, `fmax_check`, `lint_undriven`,
      `netlist_canary`, `seed_sweep`, `timing_paths`), `docs_check` on `umd/emu.sv`,
      the HIL harness cut to its stock-Main subset.
- [x] `bench/umd/run_scaffold.sh --red`: raster measured, wave scored on pixels, emu seams
      checked, 9 mutations each caught by its own arm.
- [x] First Quartus fit: SEED 1 first roll, 7,190 ALM (17 %), 62 M10K, 36 DSP, clk_dec
      352/322 MHz, 2.4 MB `.rbf`; every gate PASS. Ledgered in `UMD.qsf` and `history.md` §1.
- [x] HW gate, partial (2026-09-23, rig idle on the menu core): deployed via
      `tools/mister.py`, `/tmp/CORENAME` read `UMD`, two screenshots 5 s apart showed the
      wave in **September's purple** (mean RGB 100/58/117, 0 black pixels, 99 % of pixels
      changed between shots = it moves). ⏳ Not exercised: the OSD pop (invisible in a
      screenshot), `LED_DISK` on a mount (no UMD image on the rig), the analog output.
      Since: the analog output ✅ (480i on the maintainer's CRT, PR fj#37, `analog.md` §5); images
      have mounted and played on the rig since P2. The startup OSD pop and `LED_DISK`
      on a mount ✅ (the maintainer, 2026-10-06, on .236: neither is visible to the harness).
- [x] PR merged (PR fj#1, 2026-09-23). **Next:** Phase 1, `tools/umd_iso.py`.

**Risks:** an emu/sys_top port mismatch (pinned by `check_emu_wiring.py`); the streamer's
2048-byte addressing is benched only in P2 (`block_streamer_tb`); a missing clk_dec row
(handled by `dec_stub`).

## Phase 1 — Offline format tooling (Python only) ✅ MERGED (PR fj#2)

**Goal:** every fact in `umd_video_format.md` reproduced by a tool, and every golden model
in place *before* the RTL that consumes it.

- [x] `tools/umd_iso.py` — ISO9660 walk (`UmdIso`), from MiSTer_DVD's `dvd_report.IsoWalk`;
      whole tree, visited-sector record, multi-extent joined + listed, `UMD_DATA.BIN`.
- [x] `tools/umd_sfo.py` — `PARAM.SFO`. TITLE by key (a third key sits between on 11 of 33 discs).
- [x] `tools/umd_playlist.py` — `PLAYLIST.UMD` decoded; `verify()` against CLIPINF;
      `main_playlist()` = the longest (#2 on three discs).
- [x] `tools/umd_clpi.py` — `CLIPINF/*.CLP` decoded (stream table incl. the video frame-rate
      and aspect nibbles, per-stream EP maps); `verify()` against the stream.
- [x] `tools/psmf_ref.py parse()` — pack/PES golden with exact byte accounting;
      audio 4-byte / subtitle **2-byte** sub-headers; substreams 0x00-0x0F / 0x80-0x9F.
- [x] `tools/at3p_extract.py` — AUs → OMA → ffmpeg. `0x4855` = 48 kHz stereo 688-byte
      frames confirmed; `0x483F`/`0x487F`/`0x482A` (512/1024/344-byte) found. 256/256
      tracks decode end to end.
- [x] `tools/umd_sub_extract.py` — subtitle units decoded (u32 length, "0088", duration,
      x, y, PNG); every PNG valid under PIL.
- [x] `tools/umd_index_packs.py` — the `0xBF` packs are a per-GOP index (reference-picture
      end sectors + per-AU pic_struct/size); `verify()` against the video.
- [x] `tools/umd_census.py` — per-disc feature vector over `$UMD_ISO_DIR` (33 discs) with
      ffmpeg header traces. ⛔ **[superseded — JM traces]**: ffmpeg `trace_headers` covers
      the census; JM (`$H264_JM_DIR`, not installed) is needed for P3's syntax-element
      golden and is built there.
- [x] `tools/umd_fixture.py` — EP-aligned pack cuts, and `--nav`: the sparse image +
      expected LBA sequence of the reference reader walk (P2's `run_umd_reader.sh`).
- [x] Gates: `tools/tests/test_umd_*.py` + `test_psmf_ref`/`test_at3p_extract` on synthetic
      bytes (`tools/tests/umd_synth.py`, built from the specs); `run_tests.sh --red`
      (9 mutations, each caught by its own test, plus an unmutated control);
      `tools/tests/corpus_umd.sh --full-audio`: no parser exception on any disc, byte
      totals exact, CLPI/playlist/index verifies, ffmpeg decodes every AT3+ track end to
      end — ALL GREEN over 33 discs (2026-09-23; Desperado exempt as damaged, by name).
- [x] Exit: `umd_video_format.md` rewritten with every fact tagged confirmed / measured /
      (?); `spec_hardening.md` + the `CLAUDE.md` maxima filled from field widths;
      `conformance.md` rows.
- [x] Merged (PR fj#2, 2026-09-23). No hardware gate: Phase 1 changes no RTL.

**Findings that change later phases** (details in `umd_video_format.md`):

- **Field pictures (P3/P4/P5).** 148 of 214 clips are field-coded (`field_pic_flag 1`),
  4 mix frame and field pictures, and so do the **main titles of 12 of 33 discs** (Astro
  Boy, Cowboy Bebop Vol. 1, Family Guy, Interstella 5555, both South Parks, The Dark
  Knight, The Office x2, The Simpsons Movie, Tom & Jerry; The Matrix Reloaded mixed):
  every TV-series disc and every import. MBAFF: none. See "Decision: field pictures" below.
- **Main title (P2).** Play `main_playlist()` (the longest), not playlist 0; walk
  `CLIPINF/` (an `.MPS` without a `.CLP` exists); clip numbers can have gaps. On
  TV-episode discs (up to 20 clips) the longest is one episode: item select is P8.
- **Substreams (P2/P7).** Subtitles are 0x80-0x9F with a 2-byte sub-header; audio keeps
  the 4-byte FAP sub-header. The `ps_demux` surgery in `harvest.md` is updated to match.
- **Audio (P6).** The AT3+ frame size comes from each AU header (344, 512, 688, 1024 bytes seen).
- **Subtitles (P7).** Images up to 605x389 and flush with the bottom edge; the compositor
  takes any rectangle inside 720x480, not a strip. (Over the whole corpus, 2026-09-25:
  638x441, right edge 680 -- still inside 720x480; `docs/png_decode.md` §1.)
- **Video (P3).** Every slice: CABAC, `cabac_init_idc 0`, one slice per picture, deblocking
  on, spatial direct only, explicit weighted P on some PPS, no weighted bi-pred, no
  long-term refs, no MMCO, list modification used (l0). Size to the spec anyway; these
  say what the benches must cover first.
- **Damaged media.** Desperado's image is zero-filled in clips 1-5; tools report it. A core
  fed such an image must fail visibly, not hang.

### Decision: field pictures — ✅ decided 2026-09-23: decode them (P3/P4/P5)

The P3/P4 plan refused field pictures on a survey that sampled features only. With 12 of
33 main titles field-coded or mixed (every TV-series disc, every import), the maintainer
chose to **decode PAFF field pictures in P3/P4 and present them in P5**; the work is in
those phases' checklists below. **MBAFF stays refused loudly** (none on 33 discs; a
positive control proves the census can see it). Rejected: shipping v1 frame-only, which
would leave a third of the library unplayable. Cost estimate: mostly reference
management, addressing and scan order — no new arithmetic datapath.

**Next concrete step (taken: P2 ✅ MERGED PR fj#3):** P2 (ISO reader + demux); it does not depend on field decoding.

## Phase 2 — ISO reader + program-stream demux in fabric ✅ MERGED (PR fj#3) · ✅ HW-CONFIRMED (2026-09-23)

**Goal:** "play" = stream the main title's bytes into elementary-stream FIFOs.

- [x] Harvest `dvd_iso_reader.sv`'s skeleton (`S_SECREAD`/`S_FETCH`/`S_CHK_VD*`/
      `S_STREAM`, the 16 KB cache, `ext_mem`) as `umd/umd_reader.sv`; rewrite the walk:
      root → `UMD_VIDEO/` → `PARAM.SFO` (TITLE by key, 128 bytes, to a small BRAM) →
      `PLAYLIST.UMD` (the LONGEST playlist → its item → clip name; not playlist 0) →
      `CLIPINF/NNNNN.CLP` (stream table; EP-map sector range noted) →
      `STREAM/NNNNN.MPS` extents. The walk order is `umd_fixture.nav_walk()`.
      Benched 2026-09-23 (`docs/umd_reader.md`). Differs from the plan: **no `ext_mem`**
      (a multi-extent `.MPS` resumes the directory walk, so nothing bounds the extent
      count); every item of the longest playlist plays, not only item 0; the stream
      table fills audio/subtitle presence bitmaps + a language RAM. Not yet in `emu.sv`.
- [x] `ps_demux.sv` surgery: substream table (0x00-0x0F audio with a 4-bit track and the
      4-byte FAP sub-header; 0x80-0x9F subtitles with a 2-byte sub-header, measured in
      P1), drop NAV/CSS/MP2/LPCM; keep `vid_*`,
      `aud_*`, `sp_*`, PTS outputs, `pes_hdr_ok`, `saw_pack`. Done 2026-09-23 as
      `umd/ps_demux.sv`; also dropped the MPEG-1, raw-ES and still-flush paths, and the
      audio realign is **armed out of reset** (the first audio byte is an AU start). The
      UMD FAP is 0-based (the DVD AC-3 pointer is 1-based): measured, every audio PES on
      33 discs starts an AU.
- [x] Harvest verbatim: `ps_stream_fifo` (header only).
- ⛔ **[moved — `es_stuff`, `flush_ctl`, `audio_ring`, `pts_cdc`, `stop_ctl`, `secs_bcd`]**:
      nothing in P2 consumes them (no seek, no stop, no audio decoder, no clk_dec
      consumer, no time readout), and `harvest.md`'s own rule is to bring a module over
      in the phase that wires it, bench and all. They move to P5 (`pts_cdc`), P6
      (`audio_ring` + the AT3+ type code, `flush_ctl`, `stop_ctl`, `secs_bcd`) and the
      first junction that needs `es_stuff` (P6 seek; its MPEG-2 rationale must be re-made
      for H.264 before it is copied).
- [ ] Goldens: `psmf_ref.parse()` over real `.MPS` slices; `umd_iso.py`'s sector sequence.
- [x] Gate `run_umd_reader.sh --red`: 12 synthetic images (`tools/umd_reader_cases.py`:
      the edges no disc has, one image per refusal) + two mid-transfer `+restart` runs +
      every disc in `$UMD_ISO_DIR` (33/33 PASS), 14 mutations each caught by its own arm.
      ⛔ **[superseded — the exact LBA sequence]**: it scored one implementation's read
      choices, not the format; regions carry a dependency mask instead
      (`docs/umd_reader.md` "The bench").
- [x] Gate `run_ps_demux.sh --red`: 2 synthetic streams (`tools/umd_demux_cases.py`) +
      59 windows of the 33 discs' main clips (Desperado SKIPs: its clip is zero-filled),
      byte-exact per class + PTS marks vs `psmf_ref.py`; 10 mutations across video /
      audio / subtitle, each caught by its own arm. Not covered yet: a mid-stream track
      switch (`aud_realign` is tied 0 until P6 adds the switch; the reset-armed path is).
- ⛔ **[superseded — `block_streamer_tb`]**: `block_streamer` retires with the reader, whose
      bench covers the 2048-byte addressing (mutation R6 is the P0 9-bit alias bug).
- [x] HUD for the gate: `umd/p2_diag.sv` + `umd/diag_hud.sv` (layout
      `tools/diag_layout.py`, font `tools/hud_font.py` harvested + `?&',!()`) show the
      title, the walk's state/error, the playlist pick, packs and packs/s, per-class ES
      bytes and `es_probe`'s video CRC (`docs/p2_chain.md`). Benched pixel-exact
      (`run_diag_hud.sh --red`, 6 mutations). `emu.sv` wired; `block_streamer` deleted.
- [x] Chain bench (`bench/umd/p2_chain_tb.sv` in `run_umd_reader.sh`): reader -> FIFO ->
      demux -> probe as emu composes it, with real FIFO backpressure; C1 mutation.
- [x] HW gate (2026-09-23, `UMD_p2reader_20260923_1505.rbf`, four full images from the
      rig's CIFS share): every readout matched its prediction from the P1 tools --
      `ST 25` `ERR 0`, title, playlist, clip, declared tracks, and the video CRC:
      Short Circuit `309FAFA7` (PL 0/6), **Interstella 5555 `BDDF9790` (PL 6/19, clip
      00007: the longest-playlist pick on silicon)**, Matrix `963523D3` (3 subtitle
      tracks, subtitle bytes flowing), Terminator 2 `CF6BF004`. Counters grew between
      shots (Short Circuit 13,432 -> 20,085 packs in ~5.5 s). **Throughput: 1,170-1,200
      A/V packs/s (~19 Mbit/s) from the network share**, about 2x the 610/s the Level 3.0
      10 Mbit/s ceiling needs: P3+ can stream in real time without a deeper reader.
      Not exercised on hardware: an eject mid-stream, a title running to its end
      (`title_done`), the analog output (all benched).

- [x] First fit (2026-09-23): SEED 1 first roll, 9,539 ALM (23 %), 86 M10K, clk_dec
      350.26/320.62 MHz, every gate PASS, `UMD_p2reader_20260923_1505.rbf`; ledgered.

- [x] Merged (PR fj#3, 2026-09-23).

**Next concrete step (taken: P3 ✅ MERGED PR fj#4):** P3 (`umd/h264/`): the Annex-B NAL
parser + CABAC front end behind `ps_demux`'s video output, starting with the JM
syntax-element golden (P1 deferred building JM to P3).

**Known limitations carried out of P2:** IN/OUT not applied (T2's last 2.8 s stream);
no mid-stream audio track switch (tied off to P6); with no decoder the stream runs at the
SD path's speed; the HUD is a development readout, replaced by the P6 status line.

**Risks:** multi-extent `.MPS` files (now handled: the directory walk resumes); a UDF-only
image (none seen: every surveyed disc carries an ISO9660 PVD).

## Phase 3 — H.264 bitstream front end (`umd/h264/`) ✅ MERGED (PR fj#4) · ✅ HW-CONFIRMED (2026-09-23)

**Goal:** NAL → SPS/PPS/slice header → CABAC → syntax elements and coefficients. No pixels.

- [x] `nal_parser.sv` (2026-09-23; `h264_frontend.md` §5): Annex-B start codes, EPB
      removal, trailing zeros, `out_first` / `out_last` on the RBSP bytes (the last byte
      held back until the next start code says it is the last). 38 ALMs.
- [x] `rbsp_reader.sv` (not in the original list; the bit reader the two header
      parsers share): bit-serial `u(n)` / `ue(v)` / `se(v)`, the alignment run,
      `more_rbsp_data()` from the last-byte flag; fetches only on demand so nothing of
      the slice data is buffered when the header ends. 230 ALMs.
- [x] `sps_pps.sv`: every field of 7.3.2.1.1 / 7.3.2.2 the model records, 32 SPS × 166
      bits and 256 PPS × 44 bits in RAM (`h264_pkg.sv`), valid bits, refusals by name
      plus the fabric's own (a side > 128 MBs, `REF_SIZE`), range errors for anything
      outside 7.4.2. The POC type 1 `offset_for_ref_frame` table is emitted, not
      stored (27 M10Ks at the spec maximum): 🚩 the P4 deviation decided below.
      1,156 ALMs.
- [x] `slice_hdr.sv`: the whole 7.3.3 header incl. `ref_pic_list_modification`,
      `pred_weight_table` (both lists), `dec_ref_pic_marking` (every MMCO), frame and
      field pictures, POC types 0/1/2, `SliceQPY` checked 0..51, the alignment run;
      every field out on the SE stream (`tools/h264_fields.py` ids) so P4 needs no
      second store. 608 ALMs.
- [x] `h264_top.sv`: the chain from Annex-B bytes to one SE stream (kinds 17 NAL and
      18 header field beside `mb_syntax`'s 1..16, 32-bit values), the NAL machine,
      FLUSH / INIT / start per slice, the drain, refused and error counters with codes.
      Gate `bench/umd/run_h264_top.sh` (`tools/h264_top_golden.py`): the RTL's stream
      identical to the model's whole record list on x264 Main I/P/B (2 slices/picture),
      an x264 fade (luma + chroma weights, list modification, an MMCO), four refused
      x264 streams (CAVLC, MBAFF, 8x8 transform, 2080 px wide), a lossless noise clip
      (16 I_PCM macroblocks carrying 258 EPBs), the Main clip truncated inside a slice
      header and inside slice data (the no-hang arm: one error, back to idle), CABACI3 /
      CAWP5 / Sharp PAFF (POC type 1, fields) / CAPM3 (I_PCM) / CAFI1 cut to their first
      NAL units, and Akira + Family Guy clips; counters and bin totals equal; 18 RED
      mutations. The no-hang arm found the unbounded unary binarisations (now capped at
      the spec maxima with `err_bins`) and the empty-slice INIT wait.
      Standalone fit of the whole front end: **3,919 ALMs, 16 M10K**, both slow corners
      ~87.5 MHz at the 81 MHz constraint. Not yet in `emu`.
- [x] **The Python reference of the whole front end** (2026-09-23, `h264_frontend.md`
      §2): `tools/cabac_ref.py` (engine, context init) + `tools/h264_fe_ref.py` (NAL,
      SPS/PPS/slice header, every Main SE with its ctxIdxInc derivation, frame and field
      pictures, I_PCM) with `tools/cabac_tables.py` transcribed from the spec PDF by
      `tools/gen_cabac_tables.py` and cross-checked against ffmpeg and JM. Identical to
      JM's trace on CABACI3_Sony_B (534,852 records), Akira (4.08 M) and Family Guy
      (3.58 M, field pictures); `tools/tests/test_h264_fe_ref.py` (+5 RED mutations)
      adds an x264-encoded clip checked against ffmpeg's `trace_headers` so the arm
      runs without the reference set. `tools/h264_conformance.py` sweeps the H.264.1
      package (results below).
- [x] `umd/h264/cabac_engine.sv` (2026-09-23; `h264_frontend.md` §3): decision in two
      cycles (compute, then renormalise in the next accept cycle), bypass/terminate in
      one, the I_PCM path (ALIGN/RAWBYTE/REINIT) and FLUSH at the engine level; bit-exact
      vs `cabac_ref.Cabac` on six random request sets (`bench/umd/run_h264_cabac.sh`,
      0.52 bins/cycle measured, 11 RED mutations). Standalone fit 402 ALM, 32.7 Kbit
      block RAM, every register path ≥ +2.2 ns at 81 MHz. Not yet in `emu` (nothing
      drives it until `mb_syntax`); listed in `UMD.qsf`.
- [x] `umd/h264/cabac_ctx.sv`: 460 × 7 bits in M10K, the (m, n) ROM for the four sets
      rendered from `cabac_tables.py` (`tools/cabac_mem.py`), a three-stage init
      sequencer (~464 cycles per slice), the field-coded significance ranges included.
- [x] `umd/h264/mb_syntax.sv` (2026-09-23; `h264_frontend.md` §4): every Main SE with its
      ctxIdxInc derivation, the residual with significance/last maps and level prefix/
      suffix, I_PCM, frame and field pictures (the field's own MB grid); the previous MB
      in registers, the row above in a 128-entry line memory with a valid vector.
      Word-exact SE stream against the model on CABACI3 I/P/B, CAPM3 (I_PCM), an Akira
      P slice, Family Guy I/P field slices and x264 I/P/B (`bench/umd/run_mb_syntax.sh`,
      12 RED mutations); 0.16-0.26 bins/cycle measured (13-21 Mbins/s at 81 MHz; the
      Level-3 ceiling is 13, UMD content ~2). The SE output is a held valid/ready stream,
      not yet a FIFO; not yet in `emu`.
- [ ] **`mb_syntax` throughput follow-up** — **not needed after the HW gate** (the front
      end ran Akira at ~8x and Family Guy at ~9.5x real time on silicon, 0.18 bins/cycle);
      kept as an optimisation to take only if P4's consumer is starved (today's 0.16-0.26
      bins/cycle is 1-1.6x the Level-3 ceiling and ~8x real content): (a) issue the next request in the cycle the current
      bin is consumed in every state, not only the hot loops — a dependent bin goes from
      four cycles to about 2.5 (Mealy outputs from the FSM, one path bin → next ctxIdx);
      (b) merge SE emission into the issuing states so a non-coefficient SE costs no
      two-cycle `S_EMIT` round trip. Measured baseline and the cycle accounting:
      `h264_frontend.md` §4 "Throughput"; `bench/umd/run_mb_syntax.sh` prints bins/cycle
      per fixture, so the gain is measured, not estimated.
- [ ] Main-profile subset only: CAVLC, MBAFF, FMO/ASO are **refused loudly** (a counter
      and an on-screen flag), never decoded as garbage. **Field pictures (PAFF) are
      decoded** (Phase 1 "Decision: field pictures").
- [x] Golden: JM `ldecod` syntax-element trace, normalised by `tools/h264_trace_ref.py`
      (2026-09-23; `h264_frontend.md` §1). `tools/jm_build.sh` builds the traced decoder;
      the normaliser is proven against `CABACI3_Sony_B`'s own 2004 trace (534,852 records
      identical; 296 `mb_type` wildcards where that tracer prints none for intra MBs in
      P/B) and JM's pixels are bit-exact vs the package YUV and vs ffmpeg on an Akira
      (frame, weighted P) and a Family Guy (field pictures) slice. Findings that bind the
      RTL: JM never decodes the picture-final `end_of_slice_flag` (the stream has it);
      `ffmpeg -fps_mode passthrough` for any pixel compare on a 3:2 disc. Open: I_PCM
      (`CAPM3_Sony_D`), the donated names for weight/marking/modification fields.
- [x] Conformance subset — **measured 2026-09-23** by `tools/h264_conformance.py` over all
      135 AVCv1 packages (`h264_frontend.md` §2): **33 streams decode** (every one identical
      to JM's trace and pixel-exact; Sony-format donated traces identical too), **102 are
      refused by name** (CAVLC `entropy_coding_mode_flag 0`, MBAFF
      `mb_adaptive_frame_field_flag`). The graded set for the RTL is the 33; what each
      exercises (measured, not from H.264.1's table): `cabac_init_idc` 1/2 — CABACI3_Sony_B,
      CABREF3_Sand_D, CAFI1_SVA_C, CANL4_SVA_B, Sharp_MP_PAFF_2r, cabac_mot_*; **field
      pictures** — CABREF3_Sand_D, CAFI1_SVA_C, CAPA1_TOSHIBA_B, Sharp_MP_PAFF_2r,
      cabac_mot_fld0_full, cabac_mot_picaff0_full; several slices per picture —
      CABACI3 (4), CABAST3/CABASTBR3 (4); spatial direct — CAFI1, CANL4, Sharp; weighted P
      — CAWP1_TOSHIBA_E, CAWP5_TOSHIBA_E (the latter with l0 list modification, 901 ops);
      mb QP — CAQP1_Sony_B, CACQP3_Sony_D; **I_PCM under CABAC** — CAPM3_Sony_D (4,123 MBs),
      CAPCM1/CAPCMNL1_Sand_E; POC type 1 — Sharp_MP_PAFF_2r; 720x480 — CAFI1, MV1_BRCM_D
      (19.9 M records), Sharp, cabac_mot_*. Corrections to the first list: `MR9_BT_B` is
      MBAFF and `HCMP1_HHI_A` is CAVLC (both refused), so **no CABAC stream in the package
      exercises MMCO / long-term references** — nor do the two disc slices; an oracle for
      `dec_ref_pic_marking` beyond the header parse is an open item (the P1 census can say
      whether any disc uses adaptive marking). Level 4.0 packages (`*_Sand_*`) are
      352x288 and decode fine; the fabric's limit is MaxFS/DPB, not `level_idc`.
- [x] Gates: `run_h264_cabac.sh` — engine vs a Python model over random bin sequences
      (bit-exact), context init vs the spec tables, `mb_syntax_tb` vs the model on I/P/B
      slices (bit-exact SE stream) — **frame AND field slices** (Family Guy; the Matrix
      Reloaded feature is a P3 HW-gate candidate, not a bench fixture), RED per SE class
      incl. a frame/field context-range swap (M12); `run_h264_top.sh` for the chain.
      Bins/cycle measured 0.16–0.26 (the engine alone 0.52; the "≥ 0.5" of the original
      item was the engine's figure — the throughput follow-up above covers the rest).
- [x] **`emu` integration** (2026-09-23; `h264_frontend.md` §6): `h264_top` on `clk_dec`
      behind the demux's video ES through the harvested `umd/vidfeed_cdc.sv` with an own
      `umd/fifo_dc.sv` (`harvest.md`; real backpressure: FIFO full → `vid_ready` →
      the demux → `ps_stream_fifo` → the reader's `busy`; `es_probe` now counts on
      valid AND ready), the end-of-title flush from `title_done` (4096 quiet clk_dec
      cycles after the level — the chain bench's first run caught it firing before the
      last pack had arrived), the whole front end reset per mount through
      `umd/cdc.sv`'s `cdc_reset`, an always-ready SE sink that counts words, the
      counters back through `cdc_snap` (a handshake snapshot, never a torn readout),
      the HUD grown to 16 plane rows with `H264 NAL/SLICE/PIC`, `SPS/PPS/REF/ERR` with
      codes, `SE/BINS/FLUSH` and `STALL`. Gates: `bench/umd/run_p3_chain.sh --red`
      (the chain with two real clocks on the x264 clip packed into synthetic packs,
      +stall, a 73 MHz ratio, 120 verbatim packs of Akira and Family Guy; 6 mutations),
      `run_diag_hud.sh --red` (16 rows, 32 fields), `run_scaffold.sh --red` (3 new
      wiring mutations: a tied-off `vid_ready`, a probe counting stalled cycles, the
      HUD reading a clk_dec counter raw). Fit (2026-09-23, ledgered): SEED 1 first
      roll, clk_dec 94.72/92.29 MHz, 12,959 ALM (31 %), 99 M10K, every gate PASS,
      `UMD_p3h264_20260923_2237.rbf`.
- [x] **HW gate — ✅ HW-CONFIRMED 2026-09-23** (`UMD_p3h264_20260923_2237.rbf`, both
      images from the rig's NAS share). **Akira (frame-coded, 3:2):** the whole film,
      806,611 packs, **180,198 pictures = its full 125 minutes, `ERR 0000/0`,
      `REF 0000/0`, `FLUSH 1`, `ST 27` (the reader done)**, CRC `34A0B6D0` = the P1
      tool; the counters moved at **188 slices/s ≈ 7.8-8.2x real time** (24/s) with
      ~14 Mbins/s = 0.18 bins/cycle, the bench's figure. **Family Guy (field-coded):**
      the whole 22.6-minute title, **81,304 field pictures, `ERR 0000/0`, `REF 0000/0`,
      `FLUSH 1`**, CRC `83699937`; **570 fields/s ≈ 9.5x real time** (59.94/s). SPS/PPS
      counts climb (the discs repeat them per GOP: 0x1554 SPS over Akira). `STALL`
      saturated at `FFFFFFFF` within minutes on both — the demux waited on the front
      end ~95 % of the time, i.e. the front end (not the SD path at ~800 packs/s) sets
      the pace, at 8-9x real time. **The `mb_syntax` throughput follow-up is therefore
      NOT needed for P4** (the doctrine's 13 Mbins/s ceiling is met with the engine at
      0.18 bins/cycle on real content); it stays listed as an optimisation. No hang,
      no error, on 15 GB of stream across two coding styles.

**Next concrete step (taken: P4 ✅ MERGED PR fj#6):** Phase 4 — the reconstruction (P3 merged 2026-09-23 as PR fj#4)
(`h264_frontend.md` §7: the typed SE FIFO with backpressure from P4 replaces the
counting sink; the POC type 1 offset-table decision to take with the user first).

**ALM checkpoint:** ≤ 5K for the front end — **3,919 measured standalone** (mb_syntax
2,731, sps_pps 1,157, slice_hdr 608, engine 559, reader 228, nal_parser 38); the `emu`
fit with the CDC, the snapshot and the 16-row HUD is ledgered in `UMD.qsf` once it
lands.
**🚩 P4 decision, taken 2026-09-23 with the user — a recorded deviation from the spec
maximum (`spec_hardening.md` "Known deviations"):** the POC type 1
`offset_for_ref_frame` table (255 × 32 bits × 32 SPS = 27 M10Ks at the spec maximum,
used by no disc in the census and by one conformance stream). P4 keeps the
full-length tables (as prefix sums) of the TWO most recently received type-1 SPSs, keyed
by id (1-2 M10K), and refuses loudly — a `REF` code on the HUD — a slice that activates
a type-1 SPS whose table was evicted. `sps_pps` stays as it is: the values go out on
the SE stream and P4's POC module captures them at SPS time. If it ever bites, the fix
is the number of cached tables, up to the 27 M10K full store; that is a fit-time
decision, not a design change.

## Phase 4 — Reconstruction + DPB

✅ **MERGED (PR fj#6, 2026-09-25); ✅ HW-CONFIRMED** (the whole title of The Office Disc 01,
Family Guy and Akira decode at 1.39x / 1.60x / 1.83x real time on the rig, ERR 0; 84 of
86 disc images bit-exact in the cosim; every exit criterion met on one build, below).
History -- 2026-09-24: the whole reconstruction was
bit-exact in simulation and wired into `emu` with the decode-order smoke display. The
first fits: it did not fit (4,807 of 4,191 LABs), then fit at 90 % after the area work
but closed clk_dec at 40.9 MHz -- so the smoke runs the reconstruction on clk_sys
(27 MHz). Open: timing closure at clk_dec, real-time throughput.
Design note: `h264_recon.md` (§4 smoke clocking, §5 verification, §6 open items,
§6.1 area, §6.2 timing).

- [x] `dequant_itrans.sv` (4x4 inverse integer transform + DC Hadamard for luma16/chroma,
      one coefficient per cycle; **zig-zag scan for frame MBs, field scan for field
      pictures**). 🔧 bit-exact vs the model, `run_dequant_itrans.sh --red`.
- [x] `intra_pred.sv` (4x4 nine modes, 16x16 four, chroma four; neighbour lines in M10K).
      🔧 `run_intra_pred.sh --red`.
- [x] inter prediction — split as `mv_pred.sv` (MV prediction, P_Skip, spatial and
      temporal direct, 8x8 inference, field co-located), `mc_interp.sv` (6-tap luma +
      bilinear chroma, one sample per cycle), `wpred.sv` (default / explicit / implicit)
      and `recon_inter.sv` (windows from the DPB, field references on alternate store
      lines, the Table 8-10 opposite-parity chroma offset). 🔧 `run_mv_pred.sh`,
      `run_mc.sh` (`--red`).
- [x] the DPB — split as `dpb_mem.sv` (the clk_dec ↔ clk_mem client, pipelined bursts),
      `recon_hdr.sv` / `recon_dpb.sv` / `recon_lists.sv` / `recon_slice_tab.sv` (params,
      POC types 0/1/2, sliding window + MMCO over frames and fields, field list init with
      alternating parity, modification, the direct / implicit tables). 🔧
      `run_dpb_mem.sh`, `run_recon_ctl.sh` (`--red`). 20 stores (16 references + the
      current + the display's 2: the spec maximum since 2026-09-24; r16 clip, R9).
- [x] deblocking — `deblock_bs.sv`, `deblock_filter.sv`, `recon_deblock.sv` (in-order per
      macroblock, the lagged writeback of `h264_recon.md` §2.3; a field picture on its own
      field lines). 🔧 `run_deblock.sh --red`.
- [x] `recon_top.sv` (+ `mb_intake.sv`, `recon_mb.sv`). 🔧 `run_recon_top.sh [--red]
      [--discs]`: [pre] every macroblock and [post] every picture in DDR3 identical to the
      model on x264 (every prediction mode, weights, slices), conformance (fields, PAFF,
      weights + modification, long-term + MMCOs) and the Akira / Family Guy windows.
- [x] Golden — **as built:** `tools/h264_recon_ref.py`, pixel-exact against ffmpeg and
      the H.264.1 YUVs (§1 of the note), scored by an Icarus chain bench per macroblock
      (first mismatch by picture, macroblock, plane, x, y). ✅ **The Verilator cosim
      (2026-09-25):** `bench/umd/run_cosim.sh` -- `h264_top` -> `recon_top` as `emu`
      composes them, fed ES bytes, 300 frames of each main title scored per macroblock
      and per picture against the model, the model checked against ffmpeg on the same
      window (`tools/cosim_golden.py`); `--red` C1-C6 each caught by its own arm; Akira
      300 frames PASS (1,914 cycles a MB). The library sweep (`--sweep`): 84 of 86 disc
      images bit-exact over 300 frames, 2 unreadable (`h264_recon.md` §5.1). ✅ **JM
      `lencod` streams (2026-09-25)** for the control paths no disc reaches: field MMCOs,
      long-term in frames, the list-1 swap, the modification's duplicate removal
      (`tools/jm_fixtures.py`, each written only when the model matches ffmpeg and its
      coverage counters show the path is reached). They found a `recon_lists` bug: a
      modification's later duplicate compared against the previous entry's FrameNumWrap
      (fixed 2026-09-25, `h264_recon.md` §5).
- [x] Gates: units bit-exact ✅; RED arms — 6-tap coefficient, bS rule, weighted
      prediction skipped, opposite-parity chroma offset, frame scan in a field picture —
      each caught by its own clip ✅ (`run_recon_top.sh --red` R1-R20, R17-R20 on the JM
      streams); ✅ 300 frames from every disc (the cosim sweep, 84 of 86, every window
      >= 1.35x real time; `run_cosim.sh --red` C1-C6); ✅ real-time throughput (on the rig:
      The Office Disc 01 1.39x, Family Guy 1.60x, Akira 1.83x -- the exit criteria below).
- [x] HW gate: first real pictures on HDMI in decode order — ✅ **HW-CONFIRMED
      2026-09-24** (smoke clocking: the reconstruction on clk_sys; `disp_smoke.sv`
      through `ddr_mux2.sv` on ram1, `h264_recon.md` §4): Akira's opening and Family
      Guy's field-coded title decoded clean on the rig, the P4 row's ERR 0, ~5 frames/s.
      Build `UMD_p4recon_20260924_1056.rbf` (a1a788c), clk_dec 89.5 / 88.5 MHz. The
      checkpoint: ❌ ≤ 15K ALM cumulative (36,885, 88 %: the reconstruction ~24K);
      clk_dec ≥ 86 MHz ✅ with the reconstruction off it — ❌ with it on (§6.2).
- [x] **EXIT CRITERIA (added 2026-09-24, the user):** P4 closes only when all three hold,
      measured on a fit: (1) **area** — the reconstruction ≤ 12K ALM, the core ≤ 26K
      cumulative (the re-planned "Resource checkpoints"); (2) **timing** — the
      reconstruction back on clk_dec, clk_dec ≥ 86 MHz at both slow corners; (3)
      **throughput** — ≤ 2,500 clk_dec cycles per macroblock on the disc windows (2,000
      for Level 3.0's 30 fps worst case), real-time playback measured on the rig.
      Area and timing are worked together (register stages add area; a crowded chip
      loses fmax: at 91 % the front end fell from 92 to 84 MHz). Then: 24,639 ALM,
      clk_sys smoke clocking, 3,095-3,834 cycles on the disc windows.
      **(1) ✅ met 2026-09-24:** the reconstruction 11,930 ALM, the core 25,602 (61 %),
      clk_dec 92.5 / 90.9 MHz with the front end alone (`UMD.qsf` ledger). **(2) ✅ met on
      the fit 2026-09-24:** the reconstruction back on clk_dec, 92.5 / 89.8 MHz at 25,545
      ALM (`UMD_p4recon_20260924_1934.rbf`; four register rounds from 51.0 / 48.9,
      `h264_recon.md` §6.2); ✅ **HW-CONFIRMED 2026-09-24** on the rig: Akira (frames)
      and Family Guy (fields) decode clean, P4 ERR 0, at **16.0 frames/s (0.67x real
      time)** and **34 fields/s (0.57x: interlaced titles are 59.94 fields/s, so they need
      ~2,000 cycles a MB, not 2,500)** -- 3,760 / 3,500 cycles a MB on the board. **(3) ✅ met 2026-09-24, HW-CONFIRMED:** the MB overlap, the weighting fold, four
      rows in flight, the double-buffered intake and the residual engine (disc windows
      1,843 / 1,639 cycles a MB in sim); on the rig (`UMD_p4recon_20260924_2353`)
      **Akira 29.2 frames/s (1.22x), Family Guy 62.0 fields/s (1.03x)**, ERR 0. That
      build is over the area criterion again (the reconstruction 12,786 ALM, the core
      26,380). **The library cosim (2026-09-25) found three 29.97 windows under real
      time** (The Office Disc 01 0.92x); **sixteen reference rows in flight** put every
      one of the 86 discs' windows at 1.08x or better in the cosim (`h264_recon.md` §5.1);
      ✅ **on the rig** (`UMD_p4recon_20260925_1106.rbf`): The Office Disc 01 66.1
      fields/s (1.10x), Family Guy 79.6 (1.33x), Akira 36.4 frames/s (1.52x), ERR 0.
      **The fetch / interpolation overlap** (2026-09-25): the library re-swept, 84 PASS
      bit-exact, every window at **1.35x real time or better** (median 1.83x); ✅ **on
      the rig** (`UMD_p4recon_20260925_1845.rbf`): The Office Disc 01 83.1 fields/s
      (1.39x), Family Guy 95.9 (1.60x), Akira 44.0 frames/s (1.83x), ERR 0. **All three ✅ on ONE build (2026-09-25):** `UMD_p4recon_20260925_0016.rbf`
      -- the reconstruction 11,470 ALM, the core 25,054 (60 %), clk_dec 93.67 / 92.18 MHz,
      every gate PASS; on the rig Akira 29.1 frames/s (1.21x), Family Guy 62.0 fields/s
      (1.03x), ERR 0 (the row buffers as byte lanes and the DC arrays in RAM,
      `h264_recon.md` §6.1).

**The exit work, planned 2026-09-24** (the user: implement as seen fit; tick each with its
measured effect — `tools/synth_unit.sh recon_top` for area, the profile probes for
cycles, `run_recon_top.sh` bit-exact for every step). Synthesis at the 20-store build,
own logic LUTs / registers: `recon_mb` 5,603 / 6,364, `recon_deblock` 4,708 / 730,
`mv_pred` 4,345 / 1,798, `recon_lists` 3,893 / 1,006, `recon_dpb` 3,197 / 3,414,
`recon_inter` 2,927 / 894, `recon_slice_tab` 2,744 / 1,894, `mb_intake` 1,796 / 1,311.

- [x] *Area:* state that is read one item at a time into M10K (block RAM 33 % used):
      the DPB store table's 32-bit fields (POC, FrameNumWrap, frame_num) behind one
      read port shared by `recon_dpb` / `recon_lists` / `recon_slice_tab` (they run one
      after another); `mb_intake`'s per-block mvds, read by `mv_pred` during its gather
      cycles; `map_col` and `tdir_dsf` read by `mv_pred`'s temporal pipeline; the two
      reference lists (walked by the swap / shift / compaction); `recon_mb`'s motion
      and `mv_pred`'s derived blocks (one record per partition + a block → entry map).
      recon_top 34,891 / 22,594 → 21,397 / 14,387 LUTs / registers (`h264_recon.md` §6.1).
The unticked items below are OPTIONAL levers kept for reference: every exit criterion is
met without them (area 11,524 / 12K, the core 25,107 / 26K; `h264_recon.md` §6.1 lists
what they would save).
- [ ] *Area, next:* the slice table's `code` (512 registers: a RAM per list, the
      lookup one cycle earlier in the motion read-back), the intra neighbour samples
      (`up_samp` / `left_samp`: read one at a time, aligned with the bank's two-cycle
      gather), `nb_above` / `nb_left` block fields (one reader at a time: `mv_pred`,
      the Intra_4x4 modes, the bS pre-pass), `recon_inter`'s row buffers,
      `dequant_itrans`' stages, `pps_valid`.
- [x] *Area:* `recon_mb`'s diagonal neighbours (above-right, above-left, the previous
      above) keep one 114-bit record each, not a 437-bit line-memory entry.
- [ ] *Area:* `recon_deblock`'s 8 x 8 byte buffer (scatter captures, gather feeds:
      4.7K LUTs) restructured -- e.g. the words kept as read and the lines gathered
      through one mux.
- [x] *Timing:* the chains of `h264_recon.md` §6.2, registered, then the reconstruction
      back on clk_dec: 51.0 / 48.9 -> 92.5 / 89.8 MHz in four rounds (2026-09-24).

**Ideas taken from Nova** (Ke Xu's Baseline decoder, `$UMD_REFS_DIR/nova`,
`docs/references.md`: 204 cycles / MB, ~32.7K 4-input LUTs for the whole decoder on a
Virtex-4. Ideas only -- the repository carries no licence, so none of its code). What
does NOT carry: CAVLC, one reference frame double-buffered (no DPB, lists, B, direct,
weights, fields) -- the Main-profile machinery that is most of our area.
- [x] *bS decided before the deblock* (Nova `bs_decoding.v`: from mvs and nonzero flags
      as the macroblock is parsed): all 32 edge strengths of a macroblock computed once
      when its motion is known (96 bits), so `recon_deblock` stops selecting 83-bit
      block records per line group (area, and a failing timing path). Done: a pre-pass
      over a 16-entry record RAM, `recon_deblock` 4,942 → 2,598 LUTs, ~70 cycles a MB
      saved.
- [x] *Overlap, not one pass per macroblock* (Nova's 4x16 "hybrid pipeline"): the
      deblock of macroblock n during the reconstruction of n+1 (a third sample bank),
      and at 4x4-block level the transform of block n+1 during the prediction / sum of
      block n. Done 2026-09-24/25: the MB overlap (the back engine), the residual engine
      (the transforms ahead of the prediction), the fetch / interpolation overlap.
- [x] *Zero-block shortcuts* (Nova `IQIT.v` / `sum.v`): an all-zero block skips the
      residual entirely (the residual engine's `res_zero`, done). Not taken: a DC-only
      block's residual as a constant (the transforms already run ahead, off the path).
- [ ] *A pipelined deblocking filter over single-port RAM* (Nova `DF_pipeline.v`: memory
      read, threshold decide, precompute, filter, write back): the stage split as the
      timing template for `deblock_filter` / `recon_deblock`.
- [ ] *Intra plane mode by incremental "seed" adders* (Nova `Intra_pred_PE.v`): no
      multipliers.
- [ ] (lower priority) *A reference sliding window per 4x4 block* (Nova
      `Inter_pred_sliding_window.v`): pixel reuse; our fetch cost is DDR3 latency, not
      repeated reads -- more rows in flight first.

**Risks:** DDR3 arbitration occupancy for reference reads (own port, measured with a
control arm — `hw_budget_and_lessons.md` §2); LUT-RAM explosion on neighbour arrays
(single synchronous M10K port only); deblock line-buffer sizing.

## Phase 5 — Display ✅ MERGED (PR fj#8, fj#9, fj#12, fj#13) · ✅ HW-CONFIRMED (2026-09-27)

Built in stages P5a-P5g (`docs/display.md` §9 has each stage's status, benches, fit and
rig result). Scope of this branch (the maintainer, 2026-09-25): the core display path on
the 480p raster -- ram2, the VUI, SEI `pic_timing`, the PTS, output order, the scheduler,
and a **Weave / Bob / Blend** deinterlacer in the core (ascal cannot blend; the 480i
raster swaps the menu line for ascal's Bob / Weave later). The 480i raster + csync, the
analog vertical scaler, a Film 24p raster, `frame_drop_ctl` and `av_sync` are later.
**P5a-P5d ✅ MERGED (PR fj#8, 2026-09-26).** ✅ P5a (ram2, field-aware chroma), ✅ P5b (the VUI, the aspect from the stream: Family
Guy's 4:3 declared and shown) and ✅ P5c (the picture timing SEI, the PES PTS per access
unit, the end-of-stream word) HW-confirmed 2026-09-26. ✅ P5d (output order C.4.4 /
C.4.5, the display's holds and releases through `umd/recon_out.sv`, the end-of-stream
flush; an interim consumer shows one store every other refresh) HW-confirmed 2026-09-26
(fit 26,627 ALM, clk_dec 87.25 / 87.31; on the rig `OUT` trails decode by the DPB's 3,
the decoder waits on the display, `X` / `ERR` 0). ✅ P5e MERGED (PR fj#9) (the scheduler: STC pacing
by the stream's PTS, Table E-6 durations, field parity, the judder gate's two counts)
HW-confirmed 2026-09-26 on 3:2 film, 23.976 progressive and field pairs (`display.md`
§7; fit 27,332 ALM, clk_dec 90.99 / 89.44). ✅ HIL telemetry MERGED (PR fj#10) (MiSTer_DVD's EXT_BUS
bridge and Main fork, harvested and trimmed; `hil_harness.md` "Telemetry"): it measured
the rig's reload hang (~1 in 8; the DDR3 port stops returning reads). ✅ The reload hang
FIXED, MERGED (PR fj#11), HW-CONFIRMED 2026-09-26 (0 in 60 reloads, the unfixed builds 7 in 80):
sys's `f2sdram_safe_terminator` miscounted write bursts whose `write` drops between beats
and completed them short when the core-load reset landed inside one -- forked
(`hil_harness.md` "Facts that bite", `run_f2sdram_term.sh`). ✅ P5f (Weave / Bob / Blend)
MERGED (PR fj#12, 2026-09-27): in `disp_reader` (a 3-line window, fetched two lines ahead; only field
stores filtered; Blend's golden is ffmpeg's `interlace` lowpass), benched (`display.md`
§8), fit SEED 9 (clk_dec 91.68 / 90.28, 28,062 ALM), ✅ HW-confirmed 2026-09-27 (on
Family Guy's field pairs the kernels engage -- Weave reads more combed than Bob / Blend
in every shot; on Akira's film no mode differs; the judder gate equal).
**P5g, the closeout — ✅ MERGED (PR fj#13, 2026-09-27), HW-CONFIRMED** (`display.md` §9): (1) `umd/umd.sdc` bounds
every `cdc_snap`'s crossing at 8 ns (`hold -> dst_data`, the two synchroniser first
stages): the three clk_mem -> clk_sys snapshots (`d1_snap`, `d2_snap`, `ft_snap`) had
shown -0.28 / -0.09 ns of clk_sys setup slack since PR fj#10 / P5e, analysed on the 3.7 ns
90 / 27 MHz edge window the handshake never uses; on the P5f placement STA with the new
SDC reads every clock positive (clk_sys +3.21 / +3.45 ns). `tools/fmax_check.sh` now warns
on negative setup slack on any core-PLL clock (it read clk_dec alone, which is why the gap
sat through three fits); `disp_reader`'s dead `m_parity` register and its unmatched SDC
filter are gone. (2) The whole-library `run_cosim.sh --sweep` since P5d's output order.
(3) A title's end on the rig: the END record, the last picture held. **Results:** fit
`UMD_p5g_20260927_0308.rbf` (SEED 9, clk_dec 92.91 / 90.46, 28,073 ALM, every core clock
positive at both corners); ✅ Family Guy's whole main title played to its end on the rig
(the END record taken, every store shown, the last picture held, errors 0 -- `display.md`
§9); ✅ the P5g fit on the rig (60 s settled each of Family Guy and Akira: the judder gate equal, nothing late, errors 0); ✅ the sweep: 88 of 89 disc images bit-exact over 300 frames of the main title with the output order and holds scored (Desperado SKIP: a zero-filled rip), 0 FAIL / REFUSED / ORACLE; every PASS >= 1.35x real time (the slowest The Office Disc 01 1.35x, as at P4; Red Hot Chili Peppers 1.40x next). Per disc against the P4 sweep (2026-09-25): no verdict changed but Astro Boy (FAIL -> PASS, P4's later fix); the library changed since (King Kong now two disc ISOs in a folder, My Chemical Romance two, Hellboy II's empty zip gone, Metallica and Now That's What I Call Music 2006 added). The runner globs only the top level: the two folders ran as their own sweeps (since fixed: `--sweep` descends one level, `fix/timing-tools`). **Left for P6's first fit:** clk_dec's margin is a flat wall, not one path (measured 2026-09-27 on the P5g fit at -40 C, `TIMING_TEMP=-40 tools/timing_paths.sh`): the worst 200 paths lie within 0.33 ns (+1.29 to +1.62) across four clusters -- `recon_inter` `cp_col` / `xi_q` -> its `RL` RAM (1.29), `mv_pred` -> `mvp_q` (1.35), `dequant_itrans` `b_m` / `p1_cls` -> `A` (1.51), `plane_mbs` -> `recon_mb` `wb_addr_q` (1.57); the seed picks which one tops the list. The earlier "`mv_pred` binds" came from one report, P5f's marginal SEED 1 fit at 100 C. Retiming one cluster moves the ceiling ~0.05 ns; two of the four end on M10K addresses, which P6's 87 M10K will crowd; and a register stage costs cycles a macroblock with The Office Disc 01 at exactly the 1.35x floor, so any retime is scored in the cosim on that window. P6's first fit names the cluster that binds under P6's pressure; that one is retimed. **✅ Done 2026-09-28 (P6b3i), after five seed sweeps in a row:** all four clusters retimed at zero cycles a macroblock (three ported from the H264 fork, `dequant_itrans` its own way), the cosim's cycles unchanged; the wall is now `recon_dpb`'s picture open (`h264_recon.md` §6.3).

**The checklist as P5 closes** (reconciled at P5g; what the phase did not build is
listed under "Moved out of P5" below, so nothing here is left open by accident):

- [x] ✅ Harvest `disp_sched.sv` → `umd/disp_sched.sv` + `umd/disp_ctl.sv` (P5e: the free-running
      STC phased to the raster; POC / DPB output order from P5d's `recon_out`; Table E-6
      durations: 3 / 2 for 3:2 film, one field a refresh for pairs, 2.5 refreshes for
      23.976 progressive); `pts_assoc.sv` → `umd/h264/au_pts.sv` (P5c: the position rule of
      ISO 13818-1, a PTS per access unit); `aspect_ctl.sv` → `umd/aspect_vui.sv` (P5b: the
      aspect from the VUI, rounded to 4:3 / 16:9). (`vidfeed_cdc.sv` + an own `fifo_dc`
      landed in P3.)
- [x] ✅ **A source-neutral input to the decoder and the scheduler** (decided 2026-09-25),
      held through P5: the decoder takes ES bytes, a PTS per access unit (`au_pts`) and
      the end-of-title flush; the scheduler takes its times from the records `recon_out`
      emits, never from PSMF or CLPI. ⚠ The discontinuity input (`es_discont`) the
      split decision below calls "reserved" is **not in the RTL**: it arrives with P6's
      seek (or before the split, if the general core goes first). The original note:
      The handoff from the stream source is {ES bytes, a PTS per access unit,
      discontinuity / flush}; the STC and A/V sync take their times from it, never from
      PSMF or CLPI structures directly. The ISO reader + demux is one producer of it. An
      HPS ring buffer in DDR3 could be another, so the same decoder could serve a
      **general H.264 player core**: an HPS app (a Plex / Jellyfin client) doing the
      networking, demux and audio (through `sys/alsa.sv`), the fabric decoding and
      scanning out, with no frames returned to the ARM. Nothing on the HPS side is built
      in this project; the cost now is keeping the UMD specifics (CLPI, PSMF packs) on
      the producer side of that line. This decoder's envelope is H.264 Main, Level 3.0,
      up to 720x576, up to 30 frames/s (Plex / Jellyfin transcode to what the client
      declares). The general core's own target is higher -- 720x480 at 60 frames/s at a
      high bitrate, for Moonlight (decided 2026-09-26) -- and 720p60 would need ~5x this
      decoder's throughput. When and how that core splits off, and its target: "Decision:
      the general H.264 player core splits off after P5" below.
- [x] ✅ Golden: a Python scheduler model (`tools/disp_sched_ref.py`, P5e; the output order
      `tools/dpb_output_ref.py`, P5d, == the spec process == ffmpeg == JM). The DVD-era
      `pts_map.walk_ps()` lives on as `tools/psmf_ref.py` (P1).
- [x] ✅ **Done as P5f** (HW-confirmed 2026-09-27, `display.md` §8): Weave / Bob / Blend
      in the core on the 480p raster; Bob interpolates the other field's lines (a + d) / 2
      rather than line-doubling (no half-line bounce). The original note:
      Interlaced sources on the progressive (HDMI 480p) raster: weave field pairs as
      decoded (exact), with a deinterlacer choice recorded as a later OSD option if
      combing proves objectionable on the TV-series discs. The first candidate is a
      **bob** (each field line-doubled at 59.94: never combs, half the vertical
      resolution, cheap in fabric), not a motion-adaptive filter (MiSTer_DVD abandoned
      one, `hw_budget_and_lessons.md`). It is likely what the PSP itself shows: 720x480
      streams on a 272-line screen, where one 240-line field loses almost nothing
      (unverified; a photo of a fast pan on real hardware would settle it). On 480i the
      decoded fields go out as fields: no deinterlacing at all.
- [x] ✅ Gates: `run_disp_sched.sh` (ported and rebuilt on Verilator; the cadence bench is
      its refresh-exact scoring -- {shown, store, parity, field} at every refresh against
      the model), `run_recon_out.sh`, `run_disp_reader.sh` (the kernels vs ffmpeg).
- [x] ✅ HW gate, 480p HDMI: 60 s each of 3:2 film, 23.976 progressive and field pairs
      with the judder gate equal (`DC` = `FT`: every store the scheduler decided was the
      one the reader fetched), `LT` / `CE` 0, one anchor (P5e, `display.md` §7; again in
      Bob on P5f).

**Moved out of P5** (the maintainer's P5 scope, 2026-09-25: the display path on the 480p
raster; each item keeps its note):

- [x] ✅ MERGED (PR fj#37, `docs/analog.md` S1), ✅ HW-CONFIRMED **The 480i raster:** harvest `csync_smpte.sv` + `field_polarity.vh` + `timescale.v`
      into `umd/`; `sync_gen`'s interlaced branch (the N64-model half-line, 262/263
      alternation); the menu swaps `Deinterlace` for ascal's Bob / Weave (`display.md`
      §1); gate `run_csync_field.sh`; HW gate on a CRT with MiSTer_DVD's field-parity
      screenshot method.
- [x] ✅ MERGED (PR fj#37, `docs/analog.md` S2: in `disp_reader`, not a separate scaler), ✅ HW-CONFIRMED An own vertical scaler for analog Letterbox / Crop (`disp_vscale` is bound to the
      MPEG-2 resample pipe). **Wanted (the maintainer, 2026-09-30): Auto / Letterbox / Fit / Crop,
      with 480i after A7; DVD's three modules measured 533 ALM, 7 M10K, 6 DSP (`area_plan.md` §9).**
- [ ] A Film 24p raster.
- [ ] `av_sync.sv` (P6, with the audio clock: `run_av_sync.sh` is a P6 gate) and
      `frame_drop_ctl.sv` (→ `nal_ref_idc == 0` skip; needed only when the decoder falls
      behind, which no disc does at >= 1.35x).
- [ ] PAL: `pal_detect.sv` (fed the SPS height) with a 50 Hz / 576-line raster. No UMD in
      the library is 576-line; a 720x576 picture is shown clipped at line 479 (benched,
      `display.md` §8). A general-core item (the split decision below).

### Decision: the general H.264 player core splits off after P5 (the maintainer, 2026-09-25) — forked, not shared (2026-09-27)

**Status (2026-09-27): split, as a fork.** The general core is its own repository,
**MiSTer_h264_decoder** (`../MiSTer_h264_decoder`; the core is named "H264"), started from
this repo's `main` at `75e3f37` (P5 closed, PR fj#14's timing tools; `sys/` copied
byte-identical). The maintainer chose to **fork instead of share** (the "How" paragraph at
the end of this section is superseded): that repo owns its copy of the decoder and the
display path outright, and grows it to its own target (480p60, probably High profile).
From here on **its** roadmap owns the general core's target, gap list, interface, audio
(its open decision D2) and name (D5); the rest of this section is the record as of the
split. What stays binding in this repo is the fix exchange (`docs/harvest.md` "Fixes
exchanged with MiSTer_h264_decoder").

The **split point is P5 merged and HW-confirmed**, not P6. A general player core (the HPS
client of the source-neutral bullet above) needs the decoder (P3 + P4) and the display
path (P5: display order, PTS / `pic_struct` pacing, the VUI, the display on `ram2`, the
deinterlacer), and nothing after it: ATRAC3plus (P6), subtitles (P7) and disc navigation
(P8) are UMD's own, and in that design the HPS app handles audio.

What the general core needs that this project does not build in P5 (list, so the split
starts from a known gap, not a surprise):

- **Flush / discontinuity.** Seek, pause and a clean restart after a stream jump: the
  `es_discont` input was planned as reserved in P5 but is **not in the RTL** at P5's
  close (checked at P5g): today only the end-of-title flush and the per-mount reset
  exist. It is built with P6's seek. A network client needs it from its first day, so
  either bring it across after P6 or build it before the split.
- **PAL: a 50 Hz / 576-line raster.** P5 builds the 720x480 59.94 raster only and shows a
  576-line picture clipped, with a HUD flag (`docs/display.md`); 25 and 50 frames/s content
  also judders on 59.94. MiSTer_DVD's PAL raster is the harvest.
- **The exact display aspect.** P5 rounds to the nearer of 4:3 and 16:9 (every UMD title is
  one of them; `umd/aspect_vui.sv`); a general core hands the scaler the exact
  `sar_w * W : sar_h * H` (2.35:1 and the like). A small change in that module.
- **The HPS producer** (the DDR3 ring buffer and the ARM-side app): out of this project.
  A provisional record format for it (one Annex-B access unit per record, a 33-bit PTS,
  DISCONTINUITY / LOW_LATENCY / END_OF_STREAM flags) was drafted with the maintainer for
  a Moonlight fork, 2026-09-26; the ring's address and handshake are the core's to define.
- Frame cropping is honoured in P5 already.

**The general core's target: 720x480 at 60 frames/s, high bitrate; video only in
fabric, audio on the HPS** (the maintainer, 2026-09-26; the audio half superseded
2026-09-27, below). The driving client is Moonlight
(game streaming); 480p60 at a high bitrate is the goal, and this decoder does not reach
it as built. What it takes, measured against this decoder:

| | 720x480p60, high bitrate | this decoder |
|---|---|---|
| macroblocks / s | 81,000 (Level 3.1; exactly 2x Level 3.0) | ~57-66k, on the rig, disc content at ~2-3 Mbit/s |
| CABAC bins / s | ~15-25 M at 10-17 Mbit/s | ~15-20 M (0.17-0.23 bins / cycle at ~89 MHz) |
| profile | High: hardware encoders (NVENC, the Sunshine default) emit the 8x8 transform, intra 8x8, 1,024 CABAC contexts | Main; High refused (`REF_T8X8`) |

- **Throughput:** ~1.4x the reconstruction at disc bitrates and more at game bitrates (the
  per-macroblock cost grows with coefficient density; this decoder was tuned on ~2 Mbit/s
  films), and ~1.3-1.5x the CABAC rate. Not from the clock (clk_dec closes at ~89 MHz
  against its 86 MHz gate): from parallelism, so area. **First step after P5: measure,
  don't extrapolate** -- run `bench/umd/run_cosim.sh` on a 720x480p60 Main-profile x264
  clip at 10-15 Mbit/s and read the cycles per macroblock; that sets the real gap.
- **Area:** the general core drops the UMD-only blocks (the ISO reader ~2K ALM, the demux,
  subtitles, and the ~6-8K the ATRAC3plus decoder was estimated to cost -- 2,229 ALM
  standalone as measured since): roughly framework 6.3K +
  decoder 15K + display 3K = 24-25K of 41.9K, so ~15-17K free -- room, on paper, for a
  second macroblock pipeline or wider stages and High profile. An estimate until the
  measurement above.
- **High profile** is probably required. **The one unknown that sets the difficulty:**
  whether the host can be made to send Main profile (CABAC, no 8x8 transform). If it can,
  the job is throughput alone. The Moonlight fork's first task is to find out
  (`trace_headers` on a captured stream: `profile_idc`, `entropy_coding_mode_flag`,
  `transform_8x8_mode_flag`); settle it before fixing the spinoff's scope.
- **Audio: superseded 2026-09-27.** The 2026-09-26 plan above ("audio on the HPS") had
  the ARM decode audio and play it through the framework's ALSA path (`sys/alsa.sv`).
  The design chat of 2026-09-27 moved **presentation** into fabric, and MiSTer_h264_decoder
  records that as a guiding principle: audio records with a PTS in the same DDR3 ring as
  the video, drained by a fabric audio ring, A/V gate and 48 kHz NCO (MiSTer_DVD's, as P6
  harvests them) against **one STC**; ALSA stays compiled out, so `ram2` is not shared.
  Why: `alsa.sv` already drains at an FPGA-clocked 48 kHz (no drift), but the offset
  through the Linux ALSA buffering is only estimable from its read pointer; one clock in
  fabric removes it. Where audio is **decoded** is that repo's open decision D2: PCM from
  the ARM is the floor; AAC-LC and CELT-only Opus in fabric on a microcoded DSP derived
  from this repo's ATRAC3plus decoder (2,229 ALM standalone, `docs/at3p_decoder.md`)
  are proposed. The catch is the transform: AAC-LC's and 20 ms
  CELT's long IMDCT is ~90-100 M MAC/s stereo in direct form against the one 27 MHz
  multiplier's 27 M, so ~4 multiplier lanes or an FFT IMDCT. Nothing in this repo
  changes: UMD decodes ATRAC3plus in fabric as planned (P6).

**How: fork, and exchange fixes by hand (the maintainer, 2026-09-27).** This replaces the
2026-09-25 plan, "share, do not fork": one shared directory (a git submodule or subtree)
holding `umd/h264/*`, the display modules and their benches, goldens and field table,
that both cores would build from. The reason recorded in that repo: the two trees will
drift, since the general core grows the decoder toward 480p60 and possibly High profile,
which UMD's discs do not need. The cost the old plan named is real: a fix like P4's
`recon_lists` duplicate-removal bug has to be found once and **made twice**. So:

- **A fix to anything the fork copied** (`umd/h264/*`, the display path, their benches,
  goldens and tools, the `sys/` forks) is checked against MiSTer_h264_decoder's copy and
  logged in `docs/harvest.md` "Fixes exchanged with MiSTer_h264_decoder" (here) and
  in its own harvest note (there), both ways. Before porting, check whether the other
  tree's code has changed under the fix.
- **The decoder and display modules are not in that repo yet:** they move in its Phase 2,
  copied from this repo at a commit its `docs/harvest.md` records. A fix made here before
  that copy needs no port (the copy picks it up); check its recorded commit first.
- **Its measurement runs here.** That repo's Phase 1, "measure the gap" (cycles per
  macroblock for a 720x480p60 x264 clip through `bench/umd/run_cosim.sh`), runs in this
  tree and is coordinated with this repo's work before it starts.

## Phase 6 — Audio, presentation, HUD, navigation basics

- [x] ✅ **MERGED (PR fj#17), HW-CONFIRMED** `umd/at3p/` (built standalone in parallel
      with P5, the maintainer, 2026-09-25; wired into `emu` in P6a, `at3p_decoder.md`): the AU header,
      the whole parse and the synthesis control as a **microcoded sequencer**
      (`at3p_seq.sv`, `at3p.uasm`: a hardwired parse FSM was estimated at 2-3K ALM alone),
      the inner loops as vector engines on one multiplier (`at3p_vec.sv`); streaming parse,
      no frame buffer; clk_sys; **stereo only, everything else refused loudly**. Bit-exact
      in simulation against the emulator, the fixed-point model and (≤ 0.62 LSB) ffmpeg;
      ≤ 725K cycles a frame (1.59x real time at 27 MHz). Standalone fit: **2,229 ALM**
      (target ≤ 5K), 87 M10K, 1 DSP, 40.1 MHz at -40 C.
- [x] ✅ **MERGED (PR fj#17, 2026-09-27), HW-CONFIRMED -- P6a, the audio path in `emu`**
      (`at3p_decoder.md` S7): the demux ->
      `umd/aud_ring.sv` (32 KB, sized by the measured mux lead, `tools/av_mux_lead.py`;
      real back-pressure; the tag of every AU: its PTS, the FAP rule read as the decoder
      frames bytes, +3,840 derived) -> `at3p_top` -> `umd/aud_out.sv` (4,096 pairs, a tag
      per PCM frame, an exact 48 kHz tick off clk_sys, the gate against `disp_ctl`'s STC:
      release inside the head pair with a frame buffered, underrun / 50 ms re-arms, the
      pre-anchor deadlock rule) -> `AUDIO_L/R`; the HUD's `AT3` row, 11 telemetry words.
      Harvested from `dvd_audio_decode` in shape only (S7.1 says what was left and why).
      `bench/umd/run_av_sync.sh --red` ALL GREEN (6 arms, 12 mutations). Fit
      `UMD_p6a_20260927_1210.rbf` (SEED 9, 30,739 ALM, 393 M10K, clk_dec 87.07 / 86.48;
      at -40 C the binding cluster is now P5d's `recon_dpb` reference marking, `ref_b` ->
      `pend_emit` / `ref_b` / `ref_t`, then `mv_pred`: retime `recon_dpb` if a fit
      misses). Rig: **Akira in step** (`av_err` 0.02 ms for 60 s, no re-arm); **Family
      Guy not**: the video path can run only ~16 pictures ahead of the display and UMD
      muxes put audio up to 0.55 s behind the video, so its audio arrives late
      (`at3p_decoder.md` S7.8). **Fixed by a compressed-video buffer** (the maintainer
      chose the DDR3 ring, 2026-09-27): `umd/vbuf.sv`, 2 MB at word `0x0628_0000` on ram1's
      `ddr_mux2` master B (which gained write bursts; its bench found a latent orphan /
      grant bug, fixed), `run_vbuf.sh --red` (8 mutations), `h264_frontend.md` S6b. Rig
      (`UMD_p6vbuf_20260927_1304.rbf`, clk_dec 89.86 / 88.13, 31,420 ALM, 401 M10K): Family
      Guy, Akira and The Office Disc 01 in step (`av_err` 0.02-0.03 ms, no re-arm), the
      video untouched. Then P6b: track select, pause / seek, the HUD stack.
- [ ] The transport HUD **in the PSP video player's design language**, not MiSTer_DVD's
      VCR / set-top look (the maintainer, 2026-09-27; the reference, measured from PSP
      captures: `transport_hud.md`). MiSTer_DVD's HUD stack (`transport_hud`, `seek_bar`,
      `seek_time`, `dpad_seek`, `scrub_ctrl`, `lin_rate`, `mode_realign`, `ab_repeat`,
      `kbd_map`) may still donate LOGIC (seek maths, time, input), not its look; DVD
      ports tied off or fed from the CLPI entry-point map.
      **Shortcuts; the panel dropped** (the maintainer: shortcuts and a panel 2026-09-27,
      the panel dropped 2026-09-29, `transport.md` D10): **P6b** the direct buttons
      (play / pause, stop, chapter skip, FF / REW at 3 speeds, the icon pop-ups) and the
      Display overlay (chapter, time, the blue progress bar); P6b6's J1 list carries every
      action (11 buttons: UMD Menu, Subtitle, Go To and Repeat named, inert until their
      features); **P6c** builds Go To (on the core if it fits, `p6c.md` §9), with no panel; ~~A-B / Repeat, frame stepping~~ dropped for now (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**).
- [x] **P6c = Go To, ✅ MERGED (PR fj#41, 2026-10-04), ✅ HW-CONFIRMED (the maintainer's own test too)**
      (`p6c.md` §9-§10; G1: in fabric, the room from A11; cap 1,500 ALM): the reader's `NAV_TIME`,
      `player_ctl`'s TIME (15) and Go To query port, `goto_ctl` (the editor), the HUD's editor and
      marker, `emu`'s key routing ahead of the host's grab. Gates: `run_umd_reader` (T1-T7), `run_player_ctl`
      (G1-G8), `run_goto_ctl` (M1-M13), `run_transport_hud` (57 states, H27-H41), `run_scaffold` (W109-W112).
      First fit `UMD_goto_20261003_2340.rbf` (SEED 9, 90.52 / 89.12, 38,782 ALM, +1,028); on the rig every
      jump lands and Stop backs out, but a jump PAST the end froze (the display's skip dropped the last
      picture: `display.md` §11) -- fixed in `player_ctl` (that landing has no skip: the last GOP plays out to
      END); refit `UMD_goto_20261004_0031.rbf` (SEED 9, 91.96 / 89.45, 38,772 ALM) ✅ on the rig: past the end
      ends on the last picture (telemetry: ended, watchdog 0). Known limitations: `p6c.md` §10.
- [x] **P6d, the control panel on the HPS -- ✅ MERGED (PR fj#46, 2026-10-05), ✅ HW-CONFIRMED** (`docs/panel.md`; D10 revisited by the
      maintainer 2026-10-03): the UMD Main draws the PSP's panel on the plane; each item is its button
      (a HOST_WR press record), `goto_open` / `sub_any` in HOST_RD, Repeat renamed Control Panel, subtitles kept
      under it (`ui_sub`, planes 2 / 3). Stages C0-C5; K1-K16 ✅ taken; C0 ✅ approved, C1-C4 ✅ built, C5 ✅ on the rig (2026-10-04 / 05); the maintainer's test passed; Audio / Subtitle show first (§3.11).
- [x] **The skip at a title's last picture, ✅ MERGED (PR fj#44, 2026-10-04), ✅ HW-CONFIRMED** (`display.md` §11): the cause
      is the reader's OUT - 1 clamp. It lay inside the display skip's one-tick tolerance of an untagged
      last picture's estimated end (23 of the library's 120 items lost their last picture; 3 have OUT past
      their content: `display.md` §11). Fixed: the clamp is OUT - 4
      (`umd_nav_ref.clamp` derives it; reader `END_GUARD`, `player_ctl`'s TIME rule), and an END reached
      inside a skip ends the display (`disp_ctl` `skip_eos`, the liveness backstop for an OUT past a
      title's content); the rig found `player_ctl` waiting for that landing's picture (the
      watchdog, no TITLE_END): a landing now completes on `ended`, and TITLE_END is posted once per END at rest
      (`run_player_ctl` [tend], G11 / G12). Benched: `run_disp_sched` seekend / seekend1 + D43 (`ended` now scored),
      `run_umd_reader` N27 / N33, `run_player_ctl` G10, `test_umd_nav_ref` (the clamp through
      `disp_sched_ref`). ✅ On the rig (A Few Good Men, a Go To past its content): the title ends, the disc's
      menu returns, no watchdog. Fit `UMD_skipend_20261004_2035.rbf` (SEED 9 87.43 / 86.11, the sweep skipped by the maintainer).
- [x] **P6c, planned 2026-09-30: `p6c.md`** -- **cut to Go To, ✅ MERGED (PR fj#41, 2026-10-04), ✅ HW-CONFIRMED, in fabric**
      (G1, the room from A11); A-B Repeat built on its own (`ab_repeat.md`, PR fj#63); slow motion and frame advance
      dropped. The history: 📐 re-scoped 2026-09-30 to an HPS feature on host B (`area_plan.md` §8 A6), then G1. Was: ⏸ parked behind P7, D11. Go To (a
      chapter selector, a time editor, a new reader op `NAV_TIME` for title time across
      items), A-B / Repeat (every repeat a seek to an (item, PTS) key), frame advance and slow
      motion (the display's freeze released per pickup, the STC at a fraction, the audio held
      as in trick play). Calibrated cost 1.3-2.5K ALM. **The area is the decision (D11):**
      34,961 today, and P7's `sub_overlay` measured 4,744 in a unit fit, so P6c then P7 is
      98-101 % of the device, and P7 alone overruns its 37.5K checkpoint. **Decided: P7 first**;
      P6c is re-costed against the fit P7 leaves; instrumentation as a build option decided later.
- [x] **P6b, planned 2026-09-27: `transport.md`** ✅ complete (PR fj#18-fj#26, HW-CONFIRMED) (staged P6b0-P6b7, each with its
      bench, oracle and estimate; eight decisions D1-D8, taken by the maintainer the same day:
      trick play, exact chapter landing, Prev back only within 1 s, the PSP's buttons, Stop
      then resume). What
      the discs say (`tools/umd_seek_census.py`, every main title): **every video EP entry
      is a recovery point** (the SEI with `recovery_frame_cnt 0`, `exact_match 1`, the
      SPS / PPS repeated), **59 % are non-IDR I pictures**, IDRs up to 160 s apart (Ghost
      in the Shell 2.0) -- so the decoder must start at a non-IDR recovery point, dropping
      the one leading B frame or field pair; entries <= 1.97 s apart; chapters are the
      type-5 marks (type 16 is an `Endmark`); 3 main titles have several items (My
      Chemical Romance, Now That's What I Call Music 2006: 30), so a mark is (item, PTS). (The P4 note that
      Astro Boy's IDRs lack the parameter sets holds only for IDRs BETWEEN entries.)
  - ✅ **P6b0-P6b2 MERGED (PR fj#18, 2026-09-28).**
  - [x] P6b0 tooling ✅ 2026-09-27: the census, `umd_nav_ref.py`, the recovery-point
        start and the discontinuity in `h264_recon_ref.py`, `cosim_golden.py --ep-start`,
        `run_cosim.sh --ep-start --model-only`: 88 of 89 disc images bit-exact vs ffmpeg
        from a non-IDR entry; `test_umd_nav_ref.py` + 12 RED (`transport.md` §9).
  - [x] P6b1 the decoder's discontinuity ✅ 2026-09-27: the mount's reset with the
        parameter sets kept (`ps_rst_n`), the recovery-point start in `recon_dpb`; 88 of
        89 disc images bit-exact in RTL from a non-IDR entry; `run_cosim.sh --seek`
        (mid-picture resets, `ddr_mux2`'s abort covered); RED C9-C15, recon_ctl D7/D8;
        fit `UMD_p6b_20260927_2222.rbf` (clk_dec 88.26 / 87.05); the rig unchanged on
        Family Guy / Akira (no seek source until P6b3).
  - [x] P6b2 the reader's navigation ✅ built 2026-09-27: IN / OUT applied in the walk
        (two binary searches of the video EP map per item start; Hackers, Terminator 2
        and both My Chemical Romance discs now stop at OUT), `NAV_SEEK` (atomic flush +
        restart at the entry, through the extents) and `NAV_CHAP` (a full scan of the
        marks: rank, cur / prev / next); the contract and `nav_err` codes in
        `transport.md` §2.4. `run_umd_reader.sh --red`: 16 synthetic images, every
        disc image with a seeded navigation script, 39 mutations. ⚠ **Area ~2x the
        plan** (the reader +~1.4K ALM by the calibrated synthesis estimate, spent in
        `emu` now even with the port tied off): fit `UMD_p6b_20260928_0246.rbf` (clk_dec
        87.63 / 87.56, 32,152 ALM, +801), the rig unchanged on Family Guy / Akira.
        Accepted by the maintainer (2026-09-28); P6c's budget is re-planned before P6c
        (`transport.md` §7, §9).
  - [x] P6b3 `player_ctl` (the control block below), pause, the audio track -- ✅ MERGED
        (PR fj#19, 2026-09-28), ✅ HW-CONFIRMED: the seek sequence, pause / stop as freezes,
        chapters, the track switch, the display's drain / skip / stop at OUT, the reset
        split; benched (`transport.md` §9); fit `UMD_p6b3_20260928_0556.rbf` (SEED 1, clk_dec
        87.09 / 86.84, 33,213 ALM); rig-checked on Akira and Family Guy.
  - [x] P6b3i the item tag (D8): the playlist item carried with each picture to the
        display; split out of P6b3 by the maintainer, 2026-09-28 (`transport.md` §5) --
        ✅ MERGED (PR fj#20, 2026-09-28), ✅ HW-CONFIRMED: built, benched; ✅ rig-checked
        (My Chemical Romance disc 2: the Next discriminator, the audio on after the item
        change; Akira, Family Guy, The Office clean); fit after the clk_dec retime SEED 9
        first roll 87.25 / 87.70 (`UMD_p6b3i_20260928_1506.rbf`; 5 of 5 seeds pass). A
        pause counted decode errors (`err_no_store`): fixed here (`transport.md` §9).
        The library cosim: 88 of 88 bit-exact, >= 1.35x (2026-09-29).
  - [x] P6b4 FF / REW (D1: I-picture trick play) -- ✅ MERGED (PR fj#21, 2026-09-29), ✅ HW-CONFIRMED
        (built 2026-09-28): hops by time at 20 / 33 / 55x, the front end's one-frame cut, the
        reader's [IN, OUT) clamp, the D-pad; the library 88 of 88 bit-exact in the trick
        cosim; fit `UMD_p6b4_20260929_0249.rbf` (SEED 9, clk_dec 90.42 / 89.37, 33,847 ALM);
        ✅ rig-checked (Akira both ways at 20.1 / 33.1 / 55.0x, the title's ends, Family Guy's
        fields, My Chemical Romance's item crossings; `transport.md` §9).
  - [x] P6b5 the transport HUD, mockups approved before RTL. ✅ MERGED (PR fj#22, 2026-09-29),
    ✅ HW-CONFIRMED:
    the mockups ✅ approved 2026-09-29 (`transport_hud.md` §6); the RTL built and benched
    (`run_transport_hud.sh --red`), fit `UMD_p6b5_20260929_1305.rbf` (34,880 ALM); ✅ rig-checked.
  - [x] P6b6 inputs (`CONF_STR` once, `kbd_map`) and the manual. ✅ MERGED (PR fj#23, 2026-09-29),
    ✅ HW-CONFIRMED: D10's 11-button J1 list, the PSP default pad map, every action on a key;
    fit `UMD_p6b6_20260929_1517.rbf` (34,814 ALM); ✅ rig-checked (`transport.md` §9).
  - [x] P6b7 telemetry and the rig gates (`transport.md` §6). ✅ MERGED (PR fj#24, 2026-09-29);
    (fit `UMD_p6b7b_20260929_1758.rbf`, 34,945 ALM): the landing telemetry, `mister.py seq`,
    `tools/rig_gates.py`, `run_av_sync.sh` S12; every §6 gate ✅ on the rig but **the whole
    film ❌**: a display-timing defect at three points of Akira (`transport.md` §9), fixed on
    its own branch after P6b7 merges (the maintainer, 2026-09-29).
  - [x] **Fix: the display-timing defect the film gate found** (re-anchor + store alarm at
    three points of Akira; `transport.md` §9), then the film gate again. ✅ MERGED (PR fj#25, `fix/film-timing`),
    `display.md` §10. ✅ Diagnosed (2026-09-29): a lone PES PTS on the disc (7-8 ticks late,
    the next tag back on the timeline; 208 on 73 of 88 images). ✅ Built: the display
    disbelieves a lone PTS ahead of its timeline (the maintainer's rule A), benched.
    ✅ HW-CONFIRMED (2026-09-29, `UMD_filmtime_20260930_0009.rbf`): the three-point repro
    clean, **the whole-film gate PASSES** (errors 0, `av_err` 0 .. 2 ticks, END taken).
    Rule B (lone EARLY PTS too, the maintainer 2026-09-29): ✅ MERGED (PR fj#26), ✅ HW-CONFIRMED
    at The Simpsons Movie and The Transporter's points (`display.md` §10.9).
- [ ] **Transport and navigation as commands on a player control block** (decided
      2026-09-25 for the Phase 9 menus, `menus.md` §4 item 3 and §6). Commands (play
      playlist / mark / time, stop, pause, resume, audio / subtitle select), status
      (state, playlist, chapter, time), and an event FIFO (playlist end, chapter, mark).
      The HUD transport is its first client; the disc menus' player API is its contract.
- [x] Golden: ffmpeg's ATRAC3plus decoder (floating point) → a **bounded-error** gate
      (±N LSB at s16, N measured); a Python parser model, bit-exact. ✅ 2026-09-25
      (`tools/at3p_ref.py` float within 0.016 LSB of ffmpeg on 787 tracks;
      `tools/at3p_fixed.py`, the RTL's arithmetic, at the s16 rounding floor, worst
      ~0.6 LSB; `at3p_decoder.md` §2, §4).
- [ ] Gates: `run_at3p.sh`, `run_av_sync.sh`, and P6b's (`transport.md` §5: `run_player_ctl.sh`,
      `run_transport_hud.sh`, new arms in `run_recon_top.sh`, `run_umd_reader.sh`,
      `run_disp_sched.sh`, `run_cosim.sh --ep-start / --seek`).
- [x] HW gate: a full film with lip-sync within ±1 frame; seek, chapters, pause; HUD. ✅
      2026-09-29 for P6b's scope: the film (Akira, `fix/film-timing`, `display.md` §10.7),
      chapters / trick / pause / track / IN-OUT (P6b7, `transport.md` §9; the track gate was blind to a seek resetting a chosen track -- found and fixed in P7c), the HUD (P6b5).
      P6c brings its own gates.

**ALM checkpoint:** ≤ 35K cumulative (the 2026-09-24 re-plan, "Resource checkpoints"
above; this line said 30K before it). **Risks:** ATRAC3plus semantics are documented only
by ffmpeg's reverse-engineered decoder; Huffman table volume; IMDCT precision against a
float oracle.

## Phase 7 — Subtitles · ✅ MERGED (PR fj#28 the pre-work, PR fj#29 the `emu` wiring, 2026-09-30), ✅ HW-CONFIRMED

**Planned (A7, `area_plan.md` §8):** the decode (`sub_png`, `sub_plane_wr`: ~2.4K ALM, ~49 M10K)
moves to the HPS when P9 needs the room. Unit extraction, the DDR3 ring, the STC timing and the
compositor stay in fabric. A stock-Main user then has no subtitles, told by a message.

- [x] ✅ **Pre-work done standalone (2026-09-25), MERGED (PR fj#28), not in `emu` yet**
      (`docs/png_decode.md`): the PNG decoder `umd/png/` -- `png_chunks` (CRC-32, IHDR /
      PLTE / tRNS), `inflate` (zlib + DEFLATE, bit-serial puff decode, 32 KB window),
      `png_unfilter` (filters 0-4, Adam7), `png_pixel` (every type / depth -> straight
      RGBA + (x, y)), `png_top`. **The whole PNG spec** (decided 2026-09-25: the menus'
      types, 16-bit, grey, Adam7), one bound (row bytes <= 8192, `spec_hardening.md`).
      Bit-exact vs zlib + libpng on 323 synthetic cases and every subtitle unit of the
      library; `bench/umd/run_png.sh [--red] [--sweep]`, 23 mutations incl. the named RED
      arm (the distance extra bits). Still owed for the phase: integration (below).
- [x] `inflate.sv` (DEFLATE: fixed + dynamic Huffman, 32 KB window in M10K) -- standalone.
- [x] `png_unfilter.sv` (filters 0-4; with `png_pixel.sv`: every colour type, PLTE/tRNS
      → RGBA) -- standalone.
- [x] ✅ **The subtitle chain standalone (2026-09-26), MERGED (PR fj#28), not in `emu` yet**
      (`docs/subtitles.md`): `umd/sub/` -- the demux's bytes into units (`sub_in`,
      `sub_unit`), a DDR3 ring of compressed units on ram2 (`sub_ring`; the demux cannot be
      stalled and a unit's length is u32), the PNG decoder between two dual-clock FIFOs
      (`sub_png`), premultiplied ARGB planes in DDR3 carrying their rectangle
      (`sub_plane_wr`), flips / hides as requests the display acknowledges at vblank
      (`sub_sched`), one master for ddr_mux2's A (`sub_mem`). `bench/umd/run_sub.sh --red`:
      units identical to `umd_sub_extract` on whole disc tracks, every plane word equal to
      libpng's premultiplied on Akira and The Mummy's 0.1 s window at the real STC rate, the
      display's line fetch inside its line against a saturating subtitle master; 3,830 ALM.
      Timing census (`tools/sub_timing_census.py`): units arrive 0.57-1.0 s ahead, PTS 0.1 s
      apart at the least, <= 7 units / 19.4 KB in flight, no overlaps.
- [x] ✅ **The plane compositor standalone (2026-09-26), MERGED (PR fj#28), not in
      `emu` yet** (`docs/compositor.md`): `plane_reader` (a premultiplied plane from ram2, a
      source rectangle bilinear onto a destination one, 1:1 passes through exactly),
      `plane_blend` (`src + (1 - a) dst`, exact rounding), `sub_flip` (flips / hides
      latched in the vertical blank, a toggle handshake: `sub_sched` can re-raise after a
      one-cycle gap), `rd_merge2` (the video and the plane on ram2's B side) and
      `ddr_mux2`'s `B_FIRST` (the readers first on ram2: the alternation missed lines under
      a slow model). `bench/umd/run_plane.sh --red`: every dot of 3 frames exact per mode
      over `disp_reader`'s real video with a saturating subtitle master, 15 mutations + a
      control. 1,222 ALM, 16 M10K, 15 DSP in unit fits (`compositor.md` §7). The `emu` wiring
      (LAT 7, the STC): ✅ MERGED (PR fj#29).
- [x] 🔧 **One instance for `emu`: `umd/sub/sub_overlay.sv` (2026-09-26)**, the chain and
      the compositor on ram2, benched from the demux's bytes to the composite over
      `disp_reader`'s video (`bench/umd/run_overlay.sh --red`): synthetic, the corpus's
      widest / tallest / vertical units, a flush inside a write burst and one at a flip
      request, every dot of the frame after each acknowledgement exact. It found two flush
      defects (an abandoned burst would have hung ram2; a pending flip left up), fixed.
      Fit alone: 4,744 ALM, 72 RAM, 18 DSP, mclk 107.5 MHz cold (`compositor.md` §7).
- [ ] `sub_timing.sv` (the header decoded in P1); track select 0x80-0x8F. **Shape decided 2026-09-25** (`menus.md` §4, §6):
      subtitles decode into a premultiplied-ARGB **plane in DDR3** (on ram2 through
      `ddr_arb`), read by a generic plane compositor (line fetch, DDA scale, blend), not
      straight into a private line buffer. The Phase 9 menu plane is a second instance of
      it, and `png_unfilter` is written with the menus' other colour types in mind.
- [x] Golden (the decoder): zlib + **libpng** (`tools/png_oracle.c`; PIL clips 16-bit
      grey and ignores low-depth grey keys, measured) over the synthetic cases and the
      extracted units; inflate bit-exact over the whole corpus (`--sweep`) + synthetic
      streams (RED: the distance-code extra bits dropped, M1). [x] The compositor
      pixel-exact standalone (`run_plane.sh`: 1:1 vs the buffer sliced, the blend within 1
      of PIL `alpha_composite`, the bilinear exact vs its model and within 2 of float /
      PIL bilinear). [ ] In `emu` (integration).
- [x] HW gate: subtitles at the right times on a known disc -- **✅ HW-CONFIRMED 2026-09-30** on the shipping
      fit (`subtitles.md` §7 P7c: Akira's lines in their second, a chapter jump, Aliens' five tracks, The
      Mummy's 0.1 s line, fast forward; `D00 L00` throughout). **Risk:** inflate is ~2K ALM +
      4-5 M10K; checkpoint before committing to fabric. **Checkpoint taken (2026-09-25):** the
      whole decoder synthesises to 2,221 ALM and ~44 M10K (the window is the spec maximum);
      the fit and timing come with integration.

## Phase 8 — Navigation polish

- [x] ✅ Multiple playlist items (trailers and warnings before the feature; item select) --
      the handoff measured and **closed as acceptable** (2026-10-06, below and `transport.md` "D8, the
      handoff measured"): no gapless rework unless a disc shows an audible gap.
      **They exist** (2026-09-27, `umd_seek_census.py`): 3 main titles of 89, up to 30
      items (Now That's What I Call Music 2006); P6b's navigation and time display handle
      them (`transport.md` §2.4, §2.7, D8), the item handoff's seamlessness stays here.
      **Measured on the rig 2026-10-06** (`transport.md` "D8, the handoff measured"): the picture
      is continuous across a crossing (no starved refresh, nothing late, 29.97 pictures/s held,
      one re-anchor); the sound loses ~0.1 s of the old item's end (`a_left`), ~85 ms of the new
      item's start (`aud_drop`) and plays ~40-65 ms of silence. Inaudible on this disc: its clips
      begin and end in digital silence (decoded, below); the maintainer heard nothing at 3:11, nor on
      My Chemical Romance disc 2 (a silent transition into the concert, nothing audibly cut). What looked like a picture
      refused at item starts was a telemetry bug: `umd_telem`'s 6-bit word counter read word 63
      (`pdefer`) for words 63-66 since A11 (PR fj#40) -- ✅ fixed, MERGED (PR fj#58), HW-CONFIRMED
      (`transport.md` "D8, the handoff measured").
- [x] ✅ **Resume per disc id (`UMD_DATA.BIN`) and the disc screen -- MERGED (PR fj#61), HW-CONFIRMED** (2026-10-07). Designed 2026-10-06 (`docs/resume.md`, R1-R4 taken: survives
      a power cycle -- a file per disc on the SD card --, automatic, always on, forgotten at the title's
      end; R6: saved at the stop-type actions only, no periodic save). UMD Main only, no fabric change.
      Stages RS1-RS3; **RS1, RS2 🔧 built** (the kept text on the SD card, the id before Disc Menus Off; the
      tracker and the mount-time resume with Disc Menus Off; bench); RS3 ✅ on the rig 2026-10-07 (a save lost by a
      reset within ~2 s of it: a known limitation, `resume.md` §4b). RS4, the disc screen: mockups ✅ approved
      2026-10-07 (the card; R5a revised to black -- no fabric; R5f after a menu disc's quit too); 🔧 built and
      ✅ on the rig 2026-10-07 (the raster pixel-exact against the golden; `resume.md` §5 RS4). The branch is complete. Reopened 2026-10-06 with **R5, the disc
      screen** (`resume.md` §6: the disc's `PIC1` / `ICON0` / title at a stop instead of the wave, as
      the XMB; R5a-R5d taken: the wave behind the art, play at once at a mount,
      a STOP and the disc screen at a title's end, static art only), stage RS4.
- [x] ✅ **MGL launch validated end to end** (2026-10-06, .201, `UMD_bare_20261005_1945.rbf` + the UMD
      Main from `eb026df`, installed as the manual says; `docs/mgl_launch.md` "On the rig"): the
      manual's MGL from the menu under stock Main (the feature at once), under the UMD Main (Main's
      hand-over carries the MGL; the disc's own menus), and over a running UMD session; a bare
      `.MPS` by MGL was confirmed in P8 (`bare_streams.md` §4b).
- [x] ✅ **Bare `.MPS` file loading -- MERGED (PR fj#48), HW-CONFIRMED** (2026-10-05; `docs/bare_streams.md`):
      the reader sniffs sector 0 (a pack header / `PSMF` / an image), a bare file is one
      synthesized item, play-only (UNAVAIL on FF / REW / Go To), tracks learned from the stream;
      `S0,ISOMPS`. The census of PSP game cutscenes is done (`tools/pmf_census.py`: 2,601 PMFs,
      video inside the disc limits, **audio 44.1 kHz on every track**).
- ~~`.PMF` offered~~ **Out of scope** (the maintainer, 2026-10-05): every game PMF's audio is
      44.1 kHz. The reader's PSMF path stays as built and benched, not offered (`bare_streams.md` B4).
- [ ] Seek / FF / REW on a bare file: a fabric index-pack probe or an HPS-built map (decide
      after the bare-stream fit; `bare_streams.md` §5).
- [ ] (low) A picture smaller than 720x480 centred in the raster (only rare small disc clips:
      The Simpsons Movie's 144x80 `00006.MPS`).
- [x] **Found 2026-10-05, fixed the same day (a bench bug, not `player_ctl`'s):** `run_player_ctl.sh`
      with `UMD_ISO_DIR` set failed `ntwicm_2` (`[hold] item_hold 1 with the reader at item 15 and item 14
      on screen`). The script's ENDSKIP landing (the stream's END inside the skip) left the mock display's
      item at the PRE-seek picture's (14) while `player_ctl` completes the landing at its own item (11):
      after it the mock reader walked 12-14 and the arm compared against the stale screen (15 - 14 vs the
      DUT's 15 - 11). The mock now puts its display in the landing's item (`player_ctl_tb.sv`). Unseen
      before because the runner SKIPs its disc scenarios without images, and only a 30-item title gives
      the walk room.
- [x] ✅ **`tools/umd_report.py`, the sparse-sector bug bundle -- MERGED (PR fj#54, 2026-10-06)** (`docs/bug_reports.md`, R1-R4): tables whole, the menus' scripts with
      their art blanked, each stream's head with its headers only; audited (a parser-free ceiling, the
      stand-ins re-derived), self-verified; 84 of 84 library images GREEN (`tools/tests/corpus_report.py
      --menus`); in the release zip, runs on the MiSTer (Akira 34.5 s); the manual's Reporting a bug.

## Phase 9 — Disc menus (RCO / VSMX) — design only (`menus.md`, decided 2026-09-25)

**Goal:** the disc's own menus (warnings, main menu, scene select, set-up) with an
authentic feel. **One engine in portable C** (the VSMX VM, the RCO loader, the scene graph
and animation, the player-API shim, a software renderer, VAG decode) runs on either of two hosts:
**A**, a soft RISC-V CPU in fabric, or **B**, a `support/umd/` module in the project's Main fork (`main/`; upstream not asked, 2026-09-30).
It also builds on the PC as the golden model. Both hosts share one fabric contract:
overlay planes in DDR3 with a plane compositor, the P6 player control block, a PCM
one-shot for sound effects. ~~Which host ships is decided once the P7 fit is known.~~ **Decided
2026-09-30: host B** (host A is out by arithmetic at 98 %; the stock-Main rule, `area_plan.md` §8,
lets features live there). Host B also hosts P6c (A6) and the subtitle decode (A7, taken first:
A10, 2026-09-30). The plan: `docs/hps_host.md`; its B1 C PNG decoder is this engine's PNG path.

- [ ] **M0**: `tools/rco_census.py` over all 33 discs. VSMX opcodes, API identifiers,
      PNG types, animation / timer use, VAG, the startup chain, language selection;
      maxima into `spec_hardening.md`.
- [ ] **M1**: the engine on the PC (host C). Frames plus an API trace, scored against PSP
      captures (ground truth: the maintainer's PSP with custom firmware plays the same
      ISOs) and an instrumented JPCSP, disc by disc, with RED arms.
- [ ] **M2**: the fabric contract (plane compositor, control block, PCM one-shot,
      `ddr_arb` on ram2), pixel-exact against a Python model. Lands inside P6 / P7
      where possible.
- [ ] **M3**: host B on the project's Main fork (`main/`, where the HIL Main already lives).
      Rig iteration without refits; proves the contract. Upstream is not asked (2026-09-30).
- [x] **M4**: host A (the soft CPU, the same C) if the fit allows; decide the shipping host.
      (Superseded: host B decided 2026-09-30, `area_plan.md` A4; `p9.md`'s M4 is the library's breadth.)

**Risks:** Sony's player API is known only from JPCSP's reconstruction and from the
scripts themselves; host A needs almost the whole post-P7 margin; host B needs users to run the
project's Main. **2026-09-30 (`area_plan.md` §1): host A is out by arithmetic (P7 lands at
~94-95 %), so P9 is host B, in the project's Main fork (A4; upstream not asked).**

## Phase 10 — Out of the first version (recorded in `experiments.md`)

- ~~Physical UMD discs (impossible: no PC or MiSTer drive exists).~~ Possible through a PSP shared over USB
  (2026-10-10, `psp_disc.md`; the status block above).
- 2352-byte images; `SND0.AT3`/`ICON1.PMF` menu media; ATRAC3 (non-plus).
