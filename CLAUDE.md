# MiSTer UMD Video Player Core — Claude Code Context

## Project overview

A **PSP UMD Video player core for the MiSTer FPGA platform (DE10-Nano / Cyclone V)**:
H.264 Main-profile video and ATRAC3plus audio decoded **in FPGA fabric**, playing `.iso`
images of UMD Video discs. Scaffolded 2026-09-22 from the sibling project
**MiSTer_DVD** (`../MiSTer_DVD`), which contributes the framework edits, the build
gates, the verification discipline and, phase by phase, its reusable plumbing
(`docs/harvest.md`). Nothing from MiSTer_DVD's MPEG-2 decoder or DVD navigation is here.

`docs/roadmap.md` is the canonical plan. `docs/umd_video_format.md` is what the discs
actually contain, measured by the Phase 1 tools. **Current status: P0 scaffold + P1 offline
format tooling + P2 ISO reader and program-stream demux in fabric (all merged; P2
HW-confirmed: `docs/umd_reader.md`, `docs/p2_chain.md`). The core finds a disc's main
title and separates its streams. P3 (the H.264 bitstream front end) is merged (PR fj#4)
and HW-confirmed: the whole front end (NAL → SPS/PPS → slice header → CABAC → syntax
elements) runs in `emu` on `clk_dec` behind the demux with its HUD readout and parsed
two whole titles with zero errors (`docs/h264_frontend.md`). P4 (the reconstruction)
is merged (PR fj#6) and HW-confirmed: bit-exact in simulation, wired into `emu` with a
decode-order smoke display, **every P4 exit criterion met on one build** (the
reconstruction 11,524 ALM, the core 25,107, clk_dec 89.46 / 88.02 MHz, real time on the
rig: The Office Disc 01 1.39x, Family Guy 1.60x, Akira 1.83x), every disc image in the
library bit-exact in the cosim at >= 1.35x real time (`docs/h264_recon.md`).
P5 display ✅ MERGED, ✅ HW-CONFIRMED (`docs/display.md`): P5a-P5d (PR fj#8), P5e (PR fj#9),
P5f Weave / Bob / Blend (PR fj#12), P5g closeout (PR fj#13: the cdc_snap SDC bound, a title's
end on the rig, the whole-library cosim 88 of 89 bit-exact at >= 1.35x); HIL telemetry
(`docs/hil_harness.md` "Telemetry") done; the reload hang fixed (sys's f2sdram
terminator, below). P6a (ATRAC3plus sound in step with the picture, and the
compressed-video buffer in DDR3) ✅ MERGED (PR fj#17), ✅ HW-CONFIRMED (`docs/at3p_decoder.md`
§7, `docs/h264_frontend.md` §6b). P6b (seek, pause, chapters, the audio
track, the transport HUD), planned in `docs/transport.md` (stages P6b0-P6b7, decisions
D1-D8 taken 2026-09-27): P6b0-P6b2 ✅ MERGED (PR fj#18); P6b3 (`player_ctl`) ✅ MERGED (PR fj#19), ✅ HW-CONFIRMED;
P6b3i (the item tag) ✅ MERGED (PR fj#20), ✅ HW-CONFIRMED;
P6b4 (FF / REW, I-picture trick play) ✅ MERGED (PR fj#21), ✅ HW-CONFIRMED; P6b5 (the HUD) ✅ MERGED (PR fj#22), ✅ HW-CONFIRMED; P6b6 (the buttons and keys, D10) ✅ MERGED (PR fj#23), ✅ HW-CONFIRMED; P6b7 (telemetry and the rig gates) ✅ MERGED (PR fj#24), every rig gate ✅ except the whole film ❌ (a display-timing defect at three points of Akira); its fix (`fix/film-timing`) ✅ MERGED (PR fj#25), ✅ HW-CONFIRMED: a lone PES PTS on the disc, believed by the scheduler (208 on 73 of 88 images); the display now disbelieves one ahead of its timeline; **the whole-film gate PASSES** (`docs/display.md` §10). Rule B (the maintainer, 2026-09-29: lone EARLY time stamps disbelieved too; `display.md` §10.9) ✅ MERGED (PR fj#26), ✅ HW-CONFIRMED (fit `UMD_loneearly_20260930_0446.rbf`, 34,961 ALM). P7 (subtitles) ✅ MERGED (PR fj#28, fj#29), ✅ HW-CONFIRMED (`docs/subtitles.md` §7): **the core plays a disc end to end on a stock Main, at 98 % ALM** (SEED 3 pinned). **Decided 2026-09-30, the stock-Main rule** (below; `docs/area_plan.md` §8): P6c becomes an HPS feature (`docs/p6c.md` §8), the subtitle decode moves to the HPS, the HUDs and instrumentation stay in fabric. **Re-ordered 2026-09-30 (A10): area before more decoder work, A7 (the subtitle decode to the HPS) NOW**, planned in `docs/hps_host.md` (✅ MERGED PR fj#31; H1-H8 + G1 taken: the UMD Main beside stock Main, the host port, libpng on the HPS, one plane; P6c cut to Go To, on the core if it fits). **B1 ✅ MERGED (PR fj#32)** (`main/support/umd/umd_sub.cpp`, `bench/umd/run_hps_sub.sh`: every subtitle unit and menu PNG equal to libpng, 1.6.58 and the device's 1.6.37: B2 found the rig runs 1.6.37, not the 1.6.28 Main links against). **B2 ✅ MERGED (PR fj#33)** (`docs/hps_host.md` §6 "B2, the results"): readback, poll, width bound ✅; the device's libpng is 1.6.37 (re-pinned); the budget missed as first built (68 ms vs 50), then met at 31 ms on the rig by the maintainer's option 1 (a palette fast path in `umd_sub`, exact on silicon) -- **B3 (the fabric) ✅ MERGED (PR fj#34)** (`umd/umd_host.sv`, the decode out of `sub_top`, SUB gated on the UMD Main; `docs/hps_host.md` §6 "B3, as built") -- **B4 (the UMD Main's host module) ✅ MERGED (PR fj#35): subtitles end to end on the rig** (`main/support/umd/umd_host.cpp` + `umd_host_logic.cpp`, `bench/umd/run_hps_host.sh`; `docs/hps_host.md` §6 "B4, as built") , 5 of 5 seeds pass (SEED 11 pinned, 89.86 / 89.60, 37,163 ALM) -- **B5 (packaging, the manual) ✅ MERGED (PR fj#36)** (one zip: the core and the UMD Main from one commit; `docs/hps_host.md` §1 "Packaging") -- A7 completes with its merge (✅ MERGED PR fj#36). **The diagnostic HUD leaves the core (A11, the maintainer 2026-10-03: A8 reversed for it, to make room for Go To in fabric; measured -1,422 ALM): ✅ MERGED (PR fj#40)** -- its counters in telemetry (`refused`, `warn`, `subs`), "This disc cannot be played." on the transport HUD, the manual's readout replaced by the diagnostic log (`docs/area_plan.md` A11); then **Go To in fabric (P6c), ✅ MERGED (PR fj#41), ✅ HW-CONFIRMED** (on top of the HUD drop; `docs/p6c.md` §10: `NAV_TIME`, `player_ctl` TIME + the Go To query port, `goto_ctl`, the HUD's editor; fit 38,782 ALM, +1,028 of a 1,500 cap; on the rig every jump lands, a jump past the end froze -- the display's skip, `docs/display.md` §11 -- fixed in `player_ctl`; shipped at SEED 9 92.29 / 92.24, 38,755 ALM (`UMD_goto_20261004_0409.rbf`, with the disc's-own-subtitle-change fix); the maintainer's own HW test passes). **The skip at a title's last picture: ✅ MERGED (PR fj#44), ✅ HW-CONFIRMED** (`docs/display.md` §11): the cause was the reader's OUT - 1 clamp, inside the display skip's one-tick tolerance of an untagged last picture (23 of the library's 120 items; 3 more have OUT past their content, which only the END rule covers); the clamp is now OUT - 4 (`END_GUARD`), and an END reached inside a skip ends the display (`disp_ctl` `skip_eos`) -- with `player_ctl` completing such a landing on `ended` and posting its TITLE_END (the rig found both missing); P6c's no-skip TIME landing kept as a UX choice; on the rig A Few Good Men past its content ends the title (fit `UMD_skipend_20261004_2035.rbf`). **P6d, the △ control panel on the HPS (D10 revisited, the maintainer 2026-10-03): ✅ MERGED (PR fj#46), ✅ HW-CONFIRMED (the maintainer's own test)** (`docs/panel.md`, branch `feature/hps-panel`: drawn by the UMD Main on the plane, each item injected as its own button press, subtitles kept under it as on the PSP (`ui_sub`, planes 2 / 3, the host compositing) -- a ~130-250 ALM fabric delta --, H5 revised; the PSP measured, K1-K15 ✅ taken 2026-10-04; C0 mockups ✅ approved (K16: the HUD-tinted box), C1 ✅ built (`tools/panel_ref.py`, the art), C2 ✅ built (`umd_panel.c`, `run_panel.sh --red`), C3 ✅ built (the fabric; SEED 9 missed, the sweep's SEED 1 passes 87.79 / 87.52, 38,732 ALM, pinned), C4 ✅ built (the UMD Main: the host-row logic, the runner, the glue), C5 ✅ on the rig (Akira, Family Guy's menu, the stock-Main message; `panel.md` §3.10); Audio / Subtitle show the current track first since the maintainer's test, `panel.md` §3.11). **A9, the H264 fork's zero-cycle clk_dec retimes: ✅ MERGED (PR fj#47), 2026-10-05** (`docs/h264_recon.md` §6.5: `sfifo`, `mb_syntax`, `recon_dpb`, `slice_hdr`, `recon_lists`; benches green + RED, cosim sample bit-exact at unchanged cycles; 5 of 5 seeds pass, SEED 5 pinned 89.50 / 89.05, 38,728 ALM; `umd.sdc` now bounds P6d's kept subtitle request; ✅ HW-CONFIRMED on the rig: Akira and Family Guy, errors 0, subtitles and the panel). **480i with Analog Aspect ✅ MERGED (PR fj#37), ✅ HW-CONFIRMED on a CRT, the HUD inside title safe at 480i included** (`docs/analog.md`). **P9 (the disc menus, host B) M0-M3b ✅ MERGED (PR fj#38), ✅ HW-CONFIRMED on the three captured discs; M4b (the rig tests' engine fixes: iconOffset anchors, a 3-D scene, script tweens replacing, Function.call, short-way rotation) ✅ MERGED (PR fj#42); M4c (an animation plays once at a time: MCR disc 2's residual highlights after rapid presses) ✅ MERGED (PR fj#43), ✅ HW-CONFIRMED; M4d (the menu renderer draws only the damage, a draw list compared frame to frame: the rig's Terminator 2 menu 8 -> 33 frames a second) ✅ MERGED (PR fj#45), ✅ HW-CONFIRMED; M4e (the maintainer's rig session of 2026-10-07, the UMD Main only: a quit after which the core no longer holds the disc runs `onExit` detached -- Forgejo fj#70; the transport under a page that draws nothing and a closed page's focus taking no key -- fj#72; focus at activation -- fj#68) ✅ MERGED (PR fj#77), ✅ HW-CONFIRMED; M4f + fj#64 (a CHAPTER read before the latest play() is stale -- Aliens' continue opened no menu, fj#76, `docs/p9.md` §3.3 "M4f"; and the fabric: an OSD Reset walked and played the disc behind the idle screen -- `nav_seq` now resets to the STOP vector, fj#64, `docs/nav_engine.md` §7) ✅ MERGED (PR fj#78), ✅ HW-CONFIRMED (.236, 2026-10-08; fit SEED 5 pinned, 91.45 / 89.41, 39,503 ALM); M4g (fj#74: the menu renderer on the A9 -- the line cache, the vector step, the opaque step, the bands, the item cache, every step exact: The Rock's menu 141 -> ~43 ms a frame on the rig, 88 of 88 library images the same pixels, `docs/p9.md` §3.3 "M4g") ✅ MERGED (PR fj#79), ✅ HW-CONFIRMED (the maintainer, .236); M4h (THE CANVAS: the menu drawn at the PSP's 480 x 272, its damage stretched onto the 720 x 480 plane on the A9 by `menu_scale` (The Rock's menu 48.3 -> 33.9 ms a frame on the bench, 47.3 -> 41.0 in the real Main; with the next frame drawn during the flip and the tick capped, The Rock's menu 15.2 -> 25.1 frames a second on the rig); the PSP's TV out measured to keep the video at 720 x 480 under a menu; the stretch in fabric, `plane_reader`'s `SCALE` 1, a candidate when the area allows; `docs/p9.md` §3.3 "M4h") ✅ MERGED (PR fj#81), ✅ HW-CONFIRMED (the maintainer's hand test on .236, 2026-10-08: The Rock's menu, Letterbox / Crop on the CRT, the disc screen, the panel over a menu); M4i (fj#73, THE SIZE MODE: a Plane's `unknownInt18` / a UButton's `unknownInt32` -- 0 the image fills its box, 0xFFFF / -1 the image at its own size: The Rock's scene titles as the maintainer's PSP photo shows them, gate `rock-scenes`, RED G57 G58, `docs/p9.md` §3.3 "M4i") ✅ MERGED (PR fj#85), ✅ HW-CONFIRMED (.236); M4j (fj#68, ANOTHER ANIMATION'S STEP REPLACES: an animation's step cancels the running tweens of that property another animation started -- The Rock's main menu opens with PLAY focused as the maintainer's photo shows; gate `rock-root-focus`, RED G59, `docs/p9.md` §3.3 "M4j") ✅ MERGED (PR fj#86), ✅ HW-CONFIRMED (.236); M4k (fj#65 / fj#66, the maintainer's PSP batch of 2026-10-10: pauseMode 1 starts paused on the requested chapter's first picture; getPlayerStatus reports a play() not yet landed; the system stops a menu's playback at a resource change -- The Animatrix, Goldmember, A Few Good Men; gates `animatrix-still-held`, `afgm-play-warnings`, `goldmember-gt-return`, RED H87-H89 G60 G61, `docs/p9.md` §3.3 "M4k") ✅ MERGED (PR fj#87), ✅ HW-CONFIRMED (.236); M4l (fj#69, ALPHA IS WRITTEN DOWN, NOT INHERITED: a parent's alpha write tweens its descendants to their own alpha times the value, no draw-time inheritance -- Hackers', The Transporter's, The Fifth Element's options and X-Men's languages drawn as on the maintainer's PSP; gates `hackers-wheel` `transporter-pivots` `fifth-root-play` `xmen-setup-langs` `incredibles-setup-fade`, RED G62-G65, `docs/p9.md` §3.3 "M4l") ✅ MERGED (PR fj#90), ✅ HW-CONFIRMED (.236: Hackers, The Transporter, X-Men as the PSP; the maintainer's own test); M4m (A PAGE'S ANIMATIONS END WITH IT: a closed page's animation runs stop -- The Animatrix's idle timer cut a chosen segment to the first; gate `animatrix-segment-timer`, RED G66) ✅ MERGED (PR fj#90), ✅ HW-CONFIRMED; M4n (fj#88 / fj#89, THE RESUME POINT: the quit keeps it before the script's `onExit`, the OSD Reset's quit keeps it, a used point lasts until its landing, the disc screen's Play line follows it; R7, the maintainer 2026-10-10: Stop on the disc screen forgets the disc's place; gates `aliens-quit-resume` `aliens-reset-resume` `animatrix-relaunch-*` `akira-*-discscreen-forget`, RED H90-H98, `docs/resume.md` §7) ✅ MERGED (PR fj#91), ✅ HW-CONFIRMED (.236, the maintainer's test); the session's other findings are Forgejo issues fj#64-fj#76 (`needs-psp-check` for the PSP batch); M4 ✅ MERGED (PR fj#39), ✅ HW-CONFIRMED: all 88 library images reach their feature through their own menus on host C (`tools/menu_lib.py`, `run_menu.sh --lib`), ten engine rules + one fabric gap (a menu over a stopped player, `show_pic`) fixed, RED H36-H48 / W105, the rig sample matches; fit SEED 9 PASS 90.56 / 92.17 (39,171 ALM), ✅ on the rig** (`docs/p9.md` §3.3 "M4"; M0 done, the PSP captures read; M2, the fabric, complete -- `NAV_PLAY`, the host rows, the button gate, the plane hand-over, the sound one-shot, the video window -- fitted at 93 %; M1 complete on the PC (the RCO loader, the VSMX VM + engine, the renderer, relaunch): Family Guy, Akira and Austin Powers 2 run their startup chains to their main menus as captured, draw them where the PSP does and relaunch as it does, `run_menu.sh --red`; M3, the engine in the UMD Main: the image reader, PLAYLIST.UMD, the host-row logic and the menu host built and benched on the PC -- every captured scenario through the whole Main path, `menu_gate.py --host`; the maintainer's PSP tests and the library (84 of 84 discs run their first 90 s) in the gate; the OSD's Menu Language (O[14:11], fit SEED 11 PASS); E2, the glue: the runner `umd_menu_run.c` (benched) and `umd_menu.cpp` + Main hooks, `MiSTer_UMD` builds with the menus; the sounds (C); three rig sessions on Family Guy: the menus navigate, play, resume and sound on hardware; the third session's fixes (`docs/p9.md` §3.3: a page built afresh at each open, play()'s audio off muted, the presentation following what a page draws, menus letterboxed / cropped on a 4:3 CRT at 480i, Cross named Select/Pause) confirmed on the rig; the three captured discs (Family Guy, Akira, Austin Powers 2) match their captures on the rig; M3b, Disc Menus On / Off (O[15], shown only with the UMD Main), built and benched, its rig check next)
(`docs/analog.md`: S1 the raster + field order, S2 Analog Aspect; two fits) **Forgejo fj#80, hard-telecined film
(field matching): the model stage ✅ built (`docs/telecine.md`: `tools/telecine_ref.py`
+ `telecine_census.py`; 0 locks on the true-video controls; clean 3:2's combed refreshes 33 % -> 0.5 % with Bob while unlocked,
-> 4.4 % with Weave);
decided T1 Auto (no OSD option), T2 unlocked = the setting (Weave); the RTL ✅ built (`umd/film_lock.sv`, disp_ctl's
partner hold, disp_reader's partner fetch + comb sums; run_film_lock / run_disp_reader / run_disp_sched green + RED;
fit SEED 5 PASS 90.76 / 89.11, 39,718 ALM, 95 %) ✅ MERGED (PR fj#82), ✅ HW-CONFIRMED on .236 (`telecine.md` §7; the maintainer's own test too).** **Forgejo fj#71, Zoom (a letterboxed 4:3 title
filling a 16:9 screen; Aspect Ratio's fourth value): ✅ MERGED (PR fj#83), ✅ HW-CONFIRMED** (`docs/zoom.md`: `umd/zoom_ctl.sv`, lines
60 .. 419 at 16:9, the HUD and subtitles moved into the band; benches green; fit SEED 5 PASS 88.50 / 88.07 -- its 98 %
ALM is the fitter's packing estimate, the logic +208 ALUTs, `zoom.md` §6.1; ✅ HW-CONFIRMED on .236, the maintainer's own test
included). **Physical UMDs through a PSP (2026-10-10): ✅ MERGED (PR fj#84), ✅ HW-CONFIRMED** (`docs/psp_disc.md`: ARK-5's *USB Device = UMD* shares the disc as `UMD9660.ISO`; the UMD Main only, no fabric -- `umd_psp.cpp` finds a PSP among `/media/usb0..7` by its sysfs SCSI inquiry and mounts it, `umd_psp_logic.c` the decisions, `run_psp_scan.sh --red`; a disc swapped inside USB mode always asks for a re-entry; a stock-Main MGL in the manual, not the zip). (`docs/roadmap.md` "Where the work stands"). **P8 bare stream files: ✅ MERGED (PR fj#48), ✅ HW-CONFIRMED (2026-10-05)** (`docs/bare_streams.md`): the reader sniffs sector 0 (a pack header = a bare `.MPS`, `PSMF` = a `.PMF`, else an image), a bare file is one synthesized item, play-only (FF / REW / Go To post UNAVAIL: "Not available for this file."), its tracks learned from the stream; `S0,ISOMPS`. `.PMF` is out of scope (the maintainer, 2026-10-05): the census (`tools/pmf_census.py`, 2,601 game PMFs) found every audio track 44.1 kHz; the reader's PSMF path stays as built, not offered (`bare_streams.md` B4). **P8 the bug bundle (`tools/umd_report.py`): ✅ MERGED (PR fj#54, 2026-10-06)** (`docs/bug_reports.md`: R1-R4, 84 of 84 library images green, runs on the MiSTer). **P8 resume per disc + R5 the disc screen: ✅ MERGED (PR fj#61), ✅ HW-CONFIRMED (2026-10-07)** (`docs/resume.md`; the UMD Main only, no fabric): each disc's place on the SD card (`config/umd/<disc id>.txt`), saved at the stop-type actions (R6), resumed at the next load with Disc Menus Off (the tracker) and through `onContinuePlay` with them on; a stopped disc shows its own XMB art (`umd_disc_screen.c`, pixel-exact on the rig), a title's end stops to it (R5c), Play after a menu disc's quit relaunches it (R5f); the art's gamma chunks dropped (the PSP shows the stored values); `run_disc_screen.sh`, `menu_gate.py --host` akira-off-* / *discscreen*. **Select/Pause during FF / REW plays (fj#57, the PSP's ✕): ✅ MERGED (PR fj#62), ✅ HW-CONFIRMED** (`docs/transport.md` §9 "fj#57"). **A-B Repeat (the maintainer, 2026-10-07: A-B only, in fabric, the panel's row 3 + the keyboard's B): ✅ MERGED (PR fj#63), ✅ HW-CONFIRMED (.236)** (`docs/ab_repeat.md`): `umd/ab_ctl.sv` beside `goto_ctl` (a SEEK to A on `player_ctl`'s port; while it loops Next / Prev jump to A, FF / REW / Go To masked; Stop clears), the HUD's `A-B` tag, the panel's A-B Repeat / Clear (Clear = host command 0); the PSP measured by the maintainer; fit SEED 3 PASS 91.6 / 88.72, 39,507 ALM; `area_plan.md` §10b (the transport on the engine) is NOT built. **Select = Play/Pause** (the maintainer, 2026-10-07: the x button renamed from Select/Pause, a toggle in playback; the panel's Pause item the command PAUSE): ✅ MERGED (PR fj#75), ✅ HW-CONFIRMED on .201 (2026-10-08) (`docs/transport.md` §9 "Select"). **Analog Dither** (the H264 core's / MiSTer_DVD's option, `O[16]`, DVD's 27 MHz `dac_dither` in
`sys_top`'s VGA path): 🔧 ✅ MERGED (PR fj#56), ✅ HW-CONFIRMED on .236's CRT (the 18-bit board) by the maintainer
(`docs/analog.md` §9). **A12 (the maintainer, 2026-10-06): the reader's parse onto a microcoded navigation engine, and with the room it frees the hardwired subtitle decoder back in fabric (a stock Main shows subtitles again)** -- `docs/nav_engine.md`, **✅ MERGED (PR fj#59, 2026-10-07), ✅ HW-CONFIRMED**: N0 measured (the parse is ~95 % of the reader, est. -2.0-2.7K ALM), N1 ✅ (the program on its emulator passes the reader's own gate on all 267 fixtures, 62 mutations caught); N2 ✅ (`umd/nav/nav_seq.sv` + the reader's hardware; `run_umd_reader.sh` ALL GREEN); N3 ✅ fit SEED 5 89.72 / 89.06, **36,384 ALM (87 %, -2,743)**; ✅ HW-CONFIRMED on .236 (chapters, FF, Go To, a 30-item disc's handoff). **SD1-SD3 ✅** (`nav_engine.md` §11): the hardwired PNG decoder answers sub_top's host handshake in fabric (`umd/sub/sub_dec.sv`), the UMD Main composites its panel over the fabric's plane (HOST_RD words 39-43), subtitles on a stock Main; benches green (sub_dec_tb vs libpng, run_overlay in fabric mode); fit SEED 5 91.83 / 92.09, **39,117 ALM (93 %)** -- the decoder back for the reader's saving; ✅ HW-CONFIRMED on .236 (subtitles on a stock Main; under the panel with the UMD Main); merged with main, SEED 3 pinned (90.58 / 86.96, 39,425 ALM, 94 %). The general H.264 core
is forked (2026-09-27) into MiSTer_h264_decoder: fixes are ported by hand both ways
(below, "Repository structure").**

---

## Documentation discipline (read before starting work)

Every non-trivial design decision **must** be written down, in this file or under
`docs/`. Code without recorded rationale is treated as incomplete.

- **Where:** `CLAUDE.md` — durable, project-wide rules and the decisions an agent needs
  *before* touching code. `docs/*.md` — subject-specific design notes, measurements, FSM
  descriptions, rejected alternatives. A short per-module status lives here; full detail
  in `docs/`.
- **When:** at the same time as the code, not later. Commit docs with the change.
- **What:** the *why*, known limitations/TODOs, alternatives rejected and why, and
  anything that surprised you.

### Leave a trail to resume work in a new session

Sessions are stateless. Before finishing any feature: update the status block and
checklists, record the **next concrete step**, list **known limitations** explicitly,
cross-reference the relevant `docs/` section and the files/benches, and keep
`docs/roadmap.md` current.

### ★ Keep the user-facing docs current (mandatory)

Three documentation surfaces with three different jobs. Putting text in the wrong one is
a documentation bug:

- **`README.md`** — the landing page. What the core is, honest status, quick start,
  licensing. Deliberately short. **Not the manual.**
- **`site/content/`** — the **user manual** (MkDocs, `mkdocs.yml`, `site/README.md` for
  the authoring rules). Deployed only on a release publish (`.github/workflows/docs.yml`, GitHub Pages);
  built as a check on every PR and push otherwise. Write pages in the present
  tense as a feature lands; an unbuilt feature carries a short "not yet implemented"
  admonition.
- **`docs/`** — engineering design notes. **Not published, not user documentation.**
  Harvest user-facing sentences into the manual; never send a user into `docs/`.

| Change | Update |
|---|---|
| New or changed OSD option | `playback/settings.md` — **enforced by `tools/docs_check.py`** |
| New gamepad button | `playback/controls.md` — **enforced** |
| New accepted file extension | `getting-started/loading.md` — **enforced** |
| New on-screen message | `playback/on-screen-messages.md` **and** `reference/troubleshooting.md` |
| New format / limitation removed or found | `reference/compatibility.md`; README if headline |
| New install step or release asset | `getting-started/install.md`, README quick start |
| New external reference worth crediting | `about/acknowledgements.md` |

Two checks, run both before committing anything under `site/content/` or touching
`CONF_STR`:

```bash
.venv/bin/python3 tools/docs_check.py    # OSD options/buttons/extensions <-> manual parity
.venv/bin/mkdocs build --strict          # broken cross-link = build failure
```

⚠ `docs_check.py` parses the `CONF_STR` block by walking to its terminator and stripping
comments. Do not "simplify" it to a grep: commented-out CONF_STR history would invent
options that do not exist.

### ★ Update status markers when a feature completes (mandatory)

A stale marker is a bug. When work merges, flip `🔧`/`❌`/`[ ]` → `✅ MERGED (PR #n)` and,
after the board test, `✅ HW-CONFIRMED` (or `⏳ HW-confirm pending`) in `docs/roadmap.md`
and the feature's own note, in the SAME change. Retire dead branch names. When in doubt,
reconcile against `gh pr list --state closed` (for the Forgejo era, the `fj#NN` numbers already in the
prose), not the prose.

---

## ★ Before adding a feature: read `docs/hw_budget_and_lessons.md`

Inherited from MiSTer_DVD. Three things in it change how the next feature is designed:
a whole idle 64-bit DDR3 port (`ram2`) is free; **the scarce memory resource is
arbitration occupancy, not bandwidth** (give a new master its own port before shrinking
its data); and how a feature with a fully green gate shipped as a visible regression —
the verification rules in its §4 apply to every bench in this tree.

---

## ★ Design to the spec maximum (mandatory)

Every table, counter, index width and loop bound that holds a format structure is sized
for **the maximum the format allows**, not for what a sample of discs contained. Size to
the spec unless there is a **hard limitation** (M10K/ALM, timing); then **discuss it with
the user before deciding**, record the limit and what breaks past it beside the code and
in `docs/`. **Never truncate silently**: a bound that is hit must be visible (a log line,
a counter, an on-screen flag).

**Why:** MiSTer_DVD shipped this mistake twice (a 64-entry VOB table a disc exceeded with
91; 7-bit cell indices a "measured unreachable" note justified until 47 PGCs exceeded
them). A library sweep says what is *common*; it cannot say what is *possible*.

🚩 **Every deviation from the spec maximum that was decided is listed in
`docs/spec_hardening.md` "Known deviations"** (today: the POC type 1 offset tables,
cached for two SPSs instead of stored for 32). Read that table first when a stream
fails on something legal.

The 33-disc census (`docs/umd_video_format.md`) justifies **scoping** decisions (no
CAVLC, no MBAFF, stereo audio) only because the unsupported cases are **refused loudly**,
never decoded as garbage. **Field pictures (PAFF) ARE decoded** (decided 2026-09-23): the
census found them in most trailers and in the main title of 12 of 33 discs —
`docs/roadmap.md` "Decision: field pictures". Reference maxima (field widths from the P1 parsers; the full
table with measured values is `docs/spec_hardening.md`):

| Structure | Max |
|---|---|
| H.264 Level 3.0 MaxMBPS / MaxFS / MaxDpbMbs / MaxBR | 40500 / 1620 / 8100 (6 frames of 1350 MBs) / 10 Mbit/s |
| SPS / PPS ids | 32 / 256 |
| `num_ref_idx_active` | 32 |
| CABAC contexts (Main) | 460 |
| ATRAC3plus on UMD | stereo, 48 kHz (design for 2 channels; refuse more); frame size from each AU header (344-1024 bytes seen) |
| CLPI streams / EP maps / EP entries | u16 / u16 / u32 (35 streams, 6360 entries seen) |
| playlists / items per playlist / marks | u16 / u32 / u16 (46 / 1 / 74 seen); the feature is the LONGEST playlist, not #0 |
| audio / subtitle substreams | 0x00-0x0F / **0x80-0x9F** (up to 0x9C seen) |
| subtitle image | any rectangle inside 720x480 (638x441 / right edge 680 seen over 70 discs, flush with the bottom edge) |

---

## ★ The stock-Main rule (the maintainer, 2026-09-30)

**The core must play a UMD ISO on a stock Main**, with nothing extra installed. Everything that
takes stays in fabric: the ISO reader and navigation, the demux, H.264, ATRAC3plus, the
display, the transport (play / pause / stop, chapters, FF / REW, the audio track).

**Features beyond that may run on the HPS**, in the project's own Main fork (`main/`,
`support/umd/`, shipped with the core; upstream Main_MiSTer is not asked). Today that means
P9's menus, P6c and, when P9 needs the room, the subtitle decode. A stock-Main user loses only
those features, and is told so by a message.

Before building a feature, ask which side of the line it is on. The device is at 98 % ALM, so a
fabric feature needs area found first (`docs/area_plan.md` §7-§8).

---

## Repository structure

```
MiSTer_UMD_Video/
├── CLAUDE.md                  ← you are here
├── README.md                  ← landing page (not the manual)
├── NOTICE, LICENSE            ← GPL-3.0-or-later; component notes
├── UMD.qpf, UMD.qsf           ← Quartus project; the qsf carries the SEED LEDGER
├── build_release.sh           ← the only sanctioned way to build a loadable .rbf
├── mkdocs.yml                 ← docs_dir=site/content, site_dir=.site-build
├── umd/                       ← ALL core RTL (emu.sv, sys_pll, sync_gen, xmb_wave, ...)
├── sys/                       ← MiSTer framework; edit only as marked UMD-FORK
├── bench/umd/                 ← Icarus benches + run_*.sh runners (README.md = the rules)
├── tools/                     ← build gates, docs_check, the HIL harness, goldens (later)
│   └── tests/                 ← host-side python tests
├── docs/                      ← ENGINEERING NOTES — not published, not the manual
├── site/                      ← USER MANUAL source (content/, overrides/, README.md)
├── releases/                  ← built .rbf + .json manifests (gitignored, .gitkeep only)
├── .claude/                   ← skills (release, hil-testing, docs-sweep, field-report), /merge
└── .github/                   ← workflows (the manual's check + Pages, release packaging) + issue forms
```

> **`docs/` and `site/` are not the same thing and must not be merged.** MkDocs' default
> output directory is also called `site/`, which is why `mkdocs.yml` sets
> `site_dir: .site-build` — never let a build write into `site/`, and **never add a bare
> `site/` line to `.gitignore`**.

There is **no `rtl/` directory**: the split MiSTer_DVD kept existed to fence its upstream
MPEG-2 decoder, and nothing upstream is carried here. `sys/pll_q17.qip`'s Template line
for a generated `pll` IP is removed (marked); every clock comes from `umd/sys_pll.sv`.

`sys/` edits: only as `// UMD-FORK` marked, additive where possible, and listed in
`docs/architecture.md`. The `emu` port list must match `sys/sys_top.v`'s instance
exactly; `tools/check_emu_wiring.py` pins it.

**The decoder has a fork.** MiSTer_h264_decoder (`../MiSTer_h264_decoder`, the general
"H264" core) forked this repo's decoder and display path on 2026-09-27 (base `main`
`75e3f37`) and owns its copy outright. A fix to anything it copied (`umd/h264/*`, the
display path, their benches, goldens and tools, the `sys/` forks) is checked against that
tree and logged in `docs/harvest.md` "Fixes exchanged with MiSTer_h264_decoder", both
ways (`docs/roadmap.md`, the split decision).

---

## Toolchain

- **Quartus 17.0.2 exactly.** Native, or the pinned Docker image `raetro/quartus:mister`
  via `USE_DOCKER=1` (`tools/docker_reexec.sh`, wired into `build_release.sh` and
  `tools/seed_sweep.sh`). Fitter SEEDs are tied to the exact netlist a given Quartus
  version produces.
- **Device:** Cyclone V 5CSEBA6U23I7 — 41,910 ALM, 553 M10K, 112 DSP.
- **HDL:** SystemVerilog for new modules. **Simulation:** Icarus (`iverilog -g2012`);
  Verilator for `tools/lint_undriven.sh` and future cosims.
- **Manual:** MkDocs Material pinned in `site/requirements.txt`, in a local `.venv`
  (`python3 -m venv .venv && .venv/bin/pip install -r site/requirements.txt`).
- **Oracles:** ffmpeg/ffprobe (H.264 pixels, header traces, ATRAC3plus decode; libx264
  for the refs-free front-end test), the JM reference decoder and the H.264.1
  conformance streams (both in `${UMD_REFS_DIR:-~/umd-refs}`, with the spec PDFs,
  papers and ffmpeg's `h264_cabac.c`: `docs/references.md`), python3, `pdftotext`
  (the CABAC tables are transcribed from the spec PDF), zlib + **libpng** (the PNG
  decoder's oracles: `tools/png_oracle.c` and the sweep need `cc` and the libpng16 / zlib
  headers). Test images live in `${UMD_ISO_DIR:-~/umd-isos}`; fixtures are cut slices,
  never whole media.

---

## Hardware status

- ✅ **P0 scaffold — MERGED (PR fj#1, 2026-09-23); ✅ HW-CONFIRMED** (the startup OSD pop and `LED_DISK`: the maintainer, 2026-10-06). `umd/emu.sv` +
  `sync_gen`/`xmb_wave`/`dec_stub`/`block_streamer`; `bench/umd/run_scaffold.sh --red`
  green (9 mutations each caught by its own arm); `lint_undriven` PASS; docs parity PASS.
  ✅ First fit 2026-09-23: SEED 1 first roll, 7,190 ALM (17 %), 62 M10K, clk_dec 352/322,
  `releases/UMD_scaffold_20260923_0328.rbf` (2.4 MB). ✅ HW smoke 2026-09-23 on the
  maintainer's rig: the core loads, the wave shows in the month's tint (September purple,
  from the HPS clock) and moves between shots. ⏳ Not yet exercised: the OSD pop, `LED_DISK`
  on an ISO mount (no image on the rig), the analog output -- all three ✅ since (the analog: 480i
  on a CRT, PR fj#37; the OSD pop and the LED: the maintainer on .236, 2026-10-06).
- ✅ **P2 ISO reader + demux — MERGED (PR fj#3, 2026-09-23); ✅ HW-CONFIRMED.**
  `run_umd_reader.sh --red` (12 synthetic images, 33/33 discs, the reader->demux chain,
  15 mutations), `run_ps_demux.sh --red` (59 disc windows, 12 mutations),
  `run_diag_hud.sh --red` (pixel-exact, 6 mutations). Fit SEED 1 first roll: 9,539 ALM
  (23 %), 86 M10K, clk_dec 350/320, `releases/UMD_p2reader_20260923_1505.rbf`. On the
  rig, four discs from its network share: every readout (title, playlist incl.
  Interstella's #6, video CRC) matched the P1 tools; ~1,200 packs/s (~2x real time).
- ✅ **P3 H.264 front end — MERGED (PR fj#4, 2026-09-23); ✅ HW-CONFIRMED 2026-09-23** (Akira's whole film and Family Guy's whole title parsed
  on the rig with zero errors and refusals, `FLUSH 1` at each end, 8-9.5x real time;
  fit SEED 1, clk_dec 94.72/92.29, 12,959 ALM, `UMD_p3h264_20260923_2237.rbf`). The
  SE golden: `tools/jm_build.sh` (JM 18.4 `ldecod`, `TRACE 1`), `tools/h264_trace_ref.py`
  (JM and H.264.1 donated traces → one canonical SE stream), proven identical on
  `CABACI3_Sony_B` (534,852 records) and pixel-exact vs ffmpeg on a frame-coded and a
  field-coded disc slice; `tools/tests/test_h264_trace_ref.py` (+3 RED mutations).
  The Python reference of the whole front end (`tools/cabac_ref.py`, `h264_fe_ref.py`,
  `cabac_tables.py` from the spec PDF, cross-checked vs ffmpeg/JM) decodes those same
  streams to the identical SE stream; `test_h264_fe_ref.py` (+5 RED) needs only
  ffmpeg's libx264 for its main arm. First RTL: `umd/h264/cabac_engine.sv` +
  `cabac_ctx.sv`, bit-exact vs the model (`bench/umd/run_h264_cabac.sh --red`, 11
  mutations), 402 ALM standalone, timing-clean at 81 MHz. `umd/h264/mb_syntax.sv`: the
  macroblock layer, word-exact SE stream vs the model on conformance, disc (frame and
  field) and x264 slices (`bench/umd/run_mb_syntax.sh --red`, 12 mutations), 0.16-0.26
  bins/cycle. The front of the chain (2026-09-23): `nal_parser.sv`, `rbsp_reader.sv`,
  `sps_pps.sv` (32 SPS / 256 PPS in RAM), `slice_hdr.sv` and `h264_top.sv` — Annex-B
  bytes to one SE stream that also carries every header field (`tools/h264_fields.py`);
  `bench/umd/run_h264_top.sh --red` (x264, five conformance packages, two disc clips,
  17 mutations) identical to the model's whole record list. Standalone fit 3,919 ALM /
  16 M10K, ~87.5 MHz both corners. In `emu` (2026-09-23): `h264_top` on `clk_dec`
  behind the demux through the harvested `vidfeed_cdc` + an own `fifo_dc` (real
  backpressure to the reader; `es_probe` counts on valid AND ready), the end-of-title
  flush from `title_done` (4096 quiet cycles after the level), the front end reset per
  mount through `cdc_reset`, an SE-word-counting sink, the counters to the HUD through
  `cdc_snap` (a handshake snapshot, never torn), the HUD grown to 16 rows (`H264 NAL/
  SLICE/PIC`, `SPS/PPS/REF/ERR` + codes, `SE/BINS/FLUSH`, `STALL`);
  `bench/umd/run_p3_chain.sh --red` (the chain with two real clocks, 6 mutations),
  `run_diag_hud.sh --red`, `run_scaffold.sh --red` (+3 wiring mutations). Next: P4
  (`docs/roadmap.md`). `docs/h264_frontend.md`.
- ✅ **P4 reconstruction — MERGED (PR fj#6, 2026-09-25); ✅ HW-CONFIRMED.** The whole
  reconstruction (`umd/h264/recon_top.sv` over `recon_hdr/dpb/lists/slice_tab`,
  `mb_intake`, `recon_mb` + `mv_pred`, `recon_inter` + `mc_interp` + `wpred`,
  `intra_pred`, `dequant_itrans`, `recon_deblock` + `deblock_bs/filter`, `dpb_mem`) is
  bit-exact per macroblock and per picture in DDR3 against `tools/h264_recon_ref.py`
  (itself pixel-exact vs ffmpeg and the H.264.1 YUVs) on x264, conformance field / PAFF /
  weighted / long-term streams and the Akira and Family Guy windows
  (`bench/umd/run_recon_top.sh --red [--discs]`, the roadmap's named RED arms R1-R6).
  In `emu`: behind `h264_top` (real SE back-pressure), DPB on ram1 through `ddr_mux2`
  (the mount ABORTS the decoder's master instead of resetting the port), the smoke
  display `disp_smoke` (last completed picture, BT.601) under the HUD, whose new `P4`
  row shows pictures / MBs / errors / size refusals. First fits (2026-09-24): did not
  fit (4,807 of 4,191 LABs); after the area work (`tools/synth_unit.sh`, scans instead
  of parallel searches: recon 47,964 → 31,367 LUTs) it fit at 90 % but closed clk_dec at
  40.9 MHz, so the **smoke build runs the reconstruction on clk_sys (27 MHz)** through
  `umd/se_cdc.sv` (`docs/h264_recon.md` §4, §6.1, §6.2). ✅ **HW smoke 2026-09-24**
  (`UMD_p4recon_20260924_1056.rbf`, clk_dec 89.5 / 88.5 MHz, 88 % ALM, every gate PASS;
  `umd/umd.sdc` for the 27 / 90 MHz crossings): Akira's opening and Family Guy's fields
  decoded clean on the rig, ERR 0, ~5 frames/s. Throughput today: 7,660 → 3,724 cycles
  per intra MB, 4,168 → 2,659 P (segment deblock, pipelined coefficient feed, 4-byte
  window copy). **P4 exit criteria (the user, 2026-09-24):** the reconstruction ≤ 12K ALM
  and the core ≤ 26K cumulative; the reconstruction back on clk_dec at ≥ 86 MHz both
  corners; ≤ 2,500 cycles per MB on the disc windows, real time on the rig
  (`docs/roadmap.md` Phase 4). If area forces anything off the FPGA it is the ISO
  handling (to the HPS), never A/V decode. **Area ✅ met (2026-09-24):** the
  reconstruction 11,930 ALM, the core 25,602 (61 %), `UMD_p4recon_20260924_1636.rbf`
  (everything read one item at a time in RAM, the deblock streamed, index-times-constant
  selects as cases: `docs/h264_recon.md` §6.1). Disc windows now 3,611 (Akira) / 2,942
  (Family Guy) cycles per MB. **Timing ✅ met on the fit (2026-09-24):** the
  reconstruction back on clk_dec (`se_cdc` retired to a fallback), 92.5 / 89.8 MHz at
  25,545 ALM after four register rounds from 51.0 / 48.9 (`UMD_p4recon_20260924_1934.rbf`,
  §6.2); ✅ HW 2026-09-24: Akira 16.0 frames/s (0.67x), Family Guy 34 fields/s (0.57x of
  59.94: interlaced titles need ~2,000 cycles a MB), P4 ERR 0, pictures clean. **Throughput ✅ met, HW-CONFIRMED (2026-09-24):**
  the MB overlap, the weighting fold, four rows in flight, the double-buffered intake,
  the residual engine: disc windows 1,843 / 1,639 cycles a MB; on the rig
  (`UMD_p4recon_20260924_2353.rbf`) Akira 29.2 frames/s (1.22x), Family Guy 62.0
  fields/s (1.03x), ERR 0. **Area ✅ re-met (2026-09-25)** after that batch pushed it
  over (12,786 / 26,380): the row buffers as byte lanes, the DC arrays in RAM --
  `UMD_p4recon_20260925_0016.rbf`, the reconstruction 11,470 ALM, the core 25,054
  (60 %), clk_dec 93.67 / 92.18 MHz, the same rates on the rig (29.1 frames/s, 62.0
  fields/s, ERR 0). **All three exit criteria hold on that one build.** **The disc
  cosim ✅ (2026-09-25):** `bench/umd/run_cosim.sh` (Verilator, `h264_top` -> `recon_top`),
  84 of 86 disc images bit-exact over 300 frames (2 unreadable). It found 29.97 windows
  under real time (The Office Disc 01 0.92x), fixed by sixteen reference rows in flight
  and the fetch / interpolation overlap: every window >= 1.35x in the cosim;
  `UMD_p4recon_20260925_1845.rbf` (25,084 ALM, recon 11,504, clk_dec 87.11 / 87.87) on
  the rig: The Office Disc 01 1.39x, Family Guy 1.60x, Akira 1.83x, ERR 0. **JM `lencod`
  fixtures ✅ (2026-09-25):** field MMCOs, long-term in frames, the list-1 swap and the
  modification's duplicate removal, each coverage-checked (`tools/jm_fixtures.py`) and
  bit-exact in the RTL, R17-R20. **They found an RTL bug:** `recon_lists` compared each
  entry against the previous entry's FrameNumWrap when dropping a modification's later
  duplicate (fixed; no disc window, conformance stream or clip could see it; fit
  `UMD_p4recon_20260925_2000.rbf`, clk_dec 89.46 / 88.02, 25,107 ALM). Next: P5
  (`docs/roadmap.md`). `docs/h264_recon.md`.
- ✅ **P5 display — MERGED (P5a-P5d PR fj#8, P5e PR fj#9, P5f PR fj#12, P5g PR fj#13; 2026-09-27),
  ✅ HW-CONFIRMED** (`docs/display.md`, staged P5a-P5g, its §9 has each stage's status). ✅ **P5a HW-confirmed 2026-09-26:** the display reader on
  its own DDR3 port (`ram2`, a `UMD-FORK` in `sys_top.v`), field-aware chroma; the decoder
  unaffected on the rig (Family Guy 1.64x, The Office 1.41x). ✅ **P5b HW-confirmed
  2026-09-26:** the VUI parsed whole (model == ffmpeg == JM on a spec-maximum VUI from
  `tools/h264_synth.py`), Auto aspect from the stream (`umd/aspect_vui.sv`; Family Guy's
  declared 4:3 measured with `mister.py shot --scaled`), fit 25,474 ALM, clk_dec 93.61 /
  90.27. ✅ **P5c HW-confirmed 2026-09-26** (every picture timed on Akira and Family Guy, 0
  missing / bad, a PTS every ~0.5 s; fit 25,991 ALM, clk_dec 87.83 / 86.93 -- thin): the picture timing SEI (`sei_pt.sv`, 9 bytes kept, interpreted
  with the SPS its slice activates), the PES PTS to each access unit (`au_pts.sv`, the
  position rule of ISO 13818-1; the model == ffprobe on every tagged disc picture), the
  end-of-stream word, the HUD's `P5` row. Menu: `Deinterlace: Weave / Bob / Blend` (inert
  until P5f; ascal cannot blend, so the 480i raster will swap in ascal's Bob / Weave with
  a hide prefix) and `Diagnostics: On / Off`. The general H.264 core splits off after P5
  (`docs/roadmap.md`: 480p60; forked 2026-09-27, see "Repository structure"). Next: P5d (output order, hold /
  release). clk_dec's binding path is P4's `mv_pred` median (-> `mvp_q`), not P5 logic:
  pipeline it if P5d's fit misses. ✅ **P5d HW-confirmed 2026-09-26** (fit 26,627 ALM, clk_dec 87.25 / 87.31; Akira and
  Family Guy on the rig: `OUT` 3 behind decode, the decoder waiting on the display, `X` /
  `ERR` 0): the
  output order of Annex C.4 in `recon_dpb` (the STORE is the output unit; DPB size from
  the VUI -- 3 on all 49 readable discs -- else Table A-1; `no_output_of_prior_pics_flag`
  as coded; a bounded stall on the display's holds), `umd/recon_out.sv` (the per-store
  table, records to clk_sys, releases back as `disp_hold`), an interim consumer in emu
  (one store every other refresh), the HUD's `OUT` row; the model checked against the
  spec process, ffmpeg and JM (`tools/dpb_output_ref.py`). `docs/display.md` §6.
  ✅ **P5e MERGED (PR fj#9, 2026-09-26), HW-confirmed** (fit 27,332 ALM, clk_dec 90.99 /
  89.44): `umd/disp_sched.sv` (MiSTer_DVD's timeline with surgery) + `umd/disp_ctl.sv` on
  clk_sys -- every store at its PTS against a 90 kHz STC phased to the raster, Table E-6
  durations, field parity; the HUD's `DC FT LG RA LT CE F` row; 60 s each of Akira (3:2),
  X-Men 2 (23.976) and Family Guy (pairs) on the rig with `DC` = `FT`, `LT` / `CE` 0, one
  anchor (`docs/display.md` §7).
  ✅ **P5f MERGED (PR fj#12, 2026-09-27), HW-CONFIRMED** (`docs/display.md` §8): Weave / Bob / Blend in
  `disp_reader` -- the line two ahead into a ring of four, three RAM copies per plane (the
  a / b / d window), the kernel in readout stage 2 (LAT 4 kept); only field stores
  filtered, a single field always bobbed (`disp_ctl`'s new `sh_single`); edges mirrored,
  a 720x576 picture's line 480 fetched for the clipped line 479; Blend's rounding is
  ffmpeg's `interlace` lowpass (its golden). ✅ `run_disp_reader.sh --red` (13 arms, K1-K10),
  `run_disp_sched.sh --red` (D14), `run_scaffold.sh --red` (W33 / W34). Rig gate:
  `tools/comb_metric.py` on screenshots per mode. Fit SEED 9 (clk_dec 91.68 / 90.28,
  28,062 ALM, M10K 256; SEED 1 missed at 85.95 on P4's `mv_pred`). ✅ HW 2026-09-27:
  on Family Guy's field pairs the kernels engage (Weave reads more combed than Bob /
  Blend in every shot), on Akira's film no mode differs, `DC` = `FT` in Bob, errors 0.
  Found on the way: `umd.sdc` did not bound the clk_mem -> clk_sys `cdc_snap`s (-0.28 ns
  clk_sys setup on a 3.7 ns edge window the handshake never uses): fixed in P5g.
  ✅ **P5g closeout — MERGED (PR fj#13, 2026-09-27), HW-CONFIRMED** (`docs/display.md` §9): `umd.sdc` bounds
  every `cdc_snap` at 8 ns; `tools/fmax_check.sh` warns on negative setup slack on any
  core-PLL clock (it read clk_dec alone); `tools/seed_sweep.sh` restores a rewritten qsf;
  fit `UMD_p5g_20260927_0308.rbf` (SEED 9, clk_dec 92.91 / 90.46, 28,073 ALM, every core
  clock positive; ✅ HW 2026-09-27: Family Guy and Akira 60 s each, judder gate equal, errors 0). ✅ A title's end on the rig (Family Guy, P5f build): END taken, every
  store shown, the last picture held, errors 0. ✅ The whole-library cosim since P5d: 88 of 89 disc images bit-exact with the output order scored (Desperado a damaged rip), all >= 1.35x. The Phase 5 checklist reconciled (what
  P5 did not build moved to a "Moved out of P5" list: 480i + csync, the analog scaler,
  Film 24p, av_sync, PAL). P5 closed 62 ALM over its 28K checkpoint (telemetry's +394 was
  unplanned); csync and the scaler's ~2K go to whichever phase builds them. clk_dec's margin
  was a flat wall of four clusters within 0.33 ns at -40 C (`recon_inter`, `mv_pred`,
  `dequant_itrans`, `plane_mbs`; roadmap P5g), not `mv_pred` alone: all four retimed at
  zero cycles in P6b3i (`h264_recon.md` §6.3); `recon_dpb`'s picture open binds next.
- ✅ **HIL telemetry — MERGED (PR fj#10, 2026-09-26), HW-confirmed:** `umd/umd_telem.sv` on hps_io's EXT_BUS
  (34 16-bit words from `tools/telem_layout.py`), `umd/ddr_probe.sv` per DDR3 port, the
  HIL Main (`main/`, `MiSTer_UMD_hil` -- `MiSTer_UMD` since B4 --, armed by `/media/fat/umd_hil`), `mister.py deploy
  --main / telem --watch / osd`. +394 ALM (27,726).
- ✅ **The reload hang — FIXED, MERGED (PR fj#11, 2026-09-26), ✅ HW-CONFIRMED.** Loading a
  title over a playing one hung the HPS DDR3 port ~1 in 8 (ram1 accepted writes, returned
  no read, BUSY for good, until a reboot). The cause: sys's `f2sdram_safe_terminator`
  counted write bursts wrongly for a master that drops `write` between beats (dpb_mem, on
  every burst; legal Avalon) and completed a burst short when the core-load reset landed
  inside it. Fixed as a `UMD-FORK` (the burst counted at the port),
  `bench/umd/run_f2sdram_term.sh --red` (K0 = stock, caught). Also: `ddr_mux2` holds a
  withdrawn request, the DDR3 masters reset with the PLL lock alone (`mem_lock_n`),
  `[avalon]` in `ddr_model.sv` and the cosim (right, but not the cause: 2 in 40 alone).
  Fit 27,827 ALM, clk_dec 90.16 / 89.18 (`UMD_reloadfix_20260926_2349.rbf`); on the rig
  0 hangs in 60 reloads vs 7 in 80 unfixed (`docs/hil_harness.md` "Facts that bite").
  MiSTer_DVD has the same stock terminator and a gapped writer: exposed too.
- ✅ **P7 subtitles — MERGED (PR fj#28 the pre-work, PR fj#29 the `emu` wiring, 2026-09-30); ✅ HW-CONFIRMED.
  The pre-work: the PNG decoder in fabric (2026-09-25).** `umd/png/` (`png_chunks` -> `inflate` -> `png_unfilter` -> `png_pixel`,
  `png_top`): the whole PNG spec (every type / depth, Adam7), straight RGBA + (x, y),
  verdicts as zlib / libpng give them, one bound (row bytes <= 8192: `spec_hardening.md`).
  Bit-exact vs zlib + libpng on 323 synthetic cases and EVERY subtitle unit of the library
  (`bench/umd/run_png.sh [--red] [--sweep]`, 23 mutations), 4.4 cycles an inflated byte.
  **The subtitle chain around it (2026-09-26)**, `umd/sub/` (`docs/subtitles.md`): units
  from the demux's bytes into a DDR3 ring on ram2, decoded into premultiplied planes,
  shown / hidden on the STC by requests the display acknowledges at vblank; every plane
  word equal to libpng's on disc windows at the real STC rate (`bench/umd/run_sub.sh
  [--red]`, 14 mutations), 3,985 ALM with the decoder in a standalone fit
  (`tools/fit_unit.sh`): mclk (the DDR3 port) 102.8 / 95.7 MHz after two register stages,
  `png_top` ~50-63 MHz, so it runs on clk_sys. The menus' 6,150 RCO PNGs (8/4/2/1-bit,
  RGBA8, RGB8, one Adam7) decode identically too; the RCOs also carry 51 JPEGs
  (`docs/menus.md` §1). **The plane compositor (2026-09-26)**, standalone
  (`docs/compositor.md`): `plane_reader` (bilinear, 1:1 exact), `plane_blend`, `sub_flip`
  (flips latched at vblank), `rd_merge2` + `ddr_mux2`'s `B_FIRST` (the readers first on
  ram2: measured, the alternation missed lines); every dot exact over `disp_reader`'s
  video (`bench/umd/run_plane.sh [--red]`, 15 mutations); 1,222 ALM, 16 M10K, 15 DSP in unit
  fits, every clock with >= 1.45x margin. **`umd/sub/sub_overlay.sv`**: the chain and the
  compositor as ONE instance for `emu`, benched from the demux's bytes to the composite
  (`bench/umd/run_overlay.sh [--red]`: the corpus's extremes, two flushes; it found a
  flush that abandoned a DDR3 burst -- fixed); fit alone 4,744 ALM, 72 RAM, 18 DSP, mclk
  108.8 / 107.5 MHz after one address stage (was 92.6). **Caught up with `main` (2026-09-30,
  through P6b and PR fj#27)**; next: the `emu` wiring (LAT 7), `UMD.qsf`, the fit. P6c is parked behind
  P7 (`docs/p6c.md` D11). **Area planned (2026-09-30, `docs/area_plan.md`, A1-A4 taken):** no
  framework switch; P7's checkpoint is its fit if >= 3 of 5 seeds pass 86 MHz (est. ~39.9-40.1K).
  **A3 done:** `plane_reader`'s `SCALE` 0 (1:1, no multipliers) and `png_chunks`' trims, with
  `sub_mem`'s output register (the merge broke mclk; now 93.4 cold): `sub_overlay` 4,691 ALM, 6 DSP
  (`area_plan.md` §6). **The `emu` wiring (P7a) and the control (P7b), ✅ MERGED (PR fj#29)
  (2026-09-30, `docs/subtitles.md` §7: decisions S1-S7 -- off at a mount, the Subtitle button steps Off ->
  tracks -> Off, an outline balloon tag, the HUD over a bottom subtitle, the diagnostic row replacing the
  P2 CRC); the rig (P7c) found and fixed a seek turning subtitles off AND a P6b3 audio-track reset on seeks; `recon_dpb`
  retimed (h264_recon.md §6.4); **fit 40,875 ALM (98 %), a 5-seed sweep 5 of 5 PASS, SEED 3 pinned (89.73 / 89.67)**
  (`area_plan.md` §7). **P7's HW gate ✅ HW-CONFIRMED on the shipping build** (SEED 3). `run_player_ctl` / `run_transport_hud --red` ALL GREEN; the cosim sample bit-exact, The Office
  Disc 01 still 1481 cycles a MB (1.35x).** P9 is host B in the project's own Main fork (`main/`), upstream not asked. `docs/png_decode.md`, `docs/subtitles.md`.
- ✅ **P1 offline format tooling — MERGED (PR fj#2, 2026-09-23); no HW gate (no RTL).** Every
  container layout decoded and cross-checked (`tools/umd_*.py`, `psmf_ref.py`,
  `at3p_extract.py`); `tools/tests/run_tests.sh --red` green (9 mutations, each caught by
  its own test); the media gate `tools/tests/corpus_umd.sh --full-audio` ALL GREEN over 33
  local discs. Findings
  that change later phases are in `docs/roadmap.md` Phase 1; field pictures are decoded
  in P3/P4 (decided 2026-09-23).
- ✅ **P9 disc menus (RCO/VSMX) — M0-M3b MERGED (PR fj#38, 2026-10-03), ✅ HW-CONFIRMED on Family Guy,
  Akira and Austin Powers 2 (each against its PSP capture); M4 ✅ MERGED (PR fj#39) (the library: 88 of 88 to their feature on host C) (`docs/p9.md`).** Designed 2026-09-25 (`docs/menus.md`): one C engine
  for two hosts (a soft CPU in fabric, or `support/umd` in a Main); **host B, in the
  project's own Main fork (`main/`), decided 2026-09-30** (`docs/area_plan.md` A4: host A is out
  by arithmetic; upstream not asked). **Binds P6 and P7 now:** transport as commands on a player control block;
  subtitles into a DDR3 plane that a generic plane compositor reads (`menus.md` §6).
- 🔧 **P6 audio, presentation, navigation.** ✅ **P6a MERGED (PR fj#17, 2026-09-27),
  ✅ HW-CONFIRMED**: the ATRAC3plus decoder (built standalone in parallel with P5, the
  maintainer 2026-09-25) wired into `emu` with the compressed-video buffer. P6b next.
  `docs/at3p_decoder.md`.
  Tables transcribed from ffmpeg n9.0.1 with credit (the maintainer's call: NOTICE).
  - **Models:** `tools/at3p_ref.py` (float, within 0.016 LSB of ffmpeg on all 787
    library tracks) and `tools/at3p_fixed.py` (the RTL's arithmetic, at the s16
    rounding floor, ~0.6 LSB).
  - **RTL:** a microcoded sequencer (`umd/at3p/at3p_seq.sv` + `at3p.uasm`, assembled
    and emulated by `tools/at3p_isa.py`) and vector engines (`at3p_vec.sv`), one
    multiplier, clk_sys.
  - **Verified:** bit-exact in simulation (`bench/umd/run_at3p_seq.sh`,
    `run_at3p.sh`, 22 mutations caught); ≤ 725K cycles a frame (1.59x real time).
  - **Standalone fit** (`tools/fit_unit.sh`): 2,229 ALM (target ≤ 5K), 87 M10K, 1 DSP,
    40.1 MHz at -40 C on the 27 MHz clock (the datapath is two stages: one stage
    closed at 27.4).
  - **P6a, the audio path in `emu` (2026-09-27):** `umd/aud_ring.sv` (32 KB, the tag
    of every AU) -> `at3p_top` -> `umd/aud_out.sv` (the gate against the display's
    STC) -> `AUDIO_L/R`; `run_av_sync.sh --red` ALL GREEN; fit
    `UMD_p6a_20260927_1210.rbf` (SEED 9, 30,739 ALM, 393 M10K, clk_dec 87.07 / 86.48).
    Rig: Akira in step (0.02 ms); Family Guy's audio arrived late -- the video path had
    no compressed buffer (§7.8). **Fixed: `umd/vbuf.sv`**, the CPB as a 2 MB DDR3 ring
    on ram1's `ddr_mux2` master B (the maintainer's choice; `docs/h264_frontend.md` S6b,
    `run_vbuf.sh --red`); fit `UMD_p6vbuf_20260927_1304.rbf` (SEED 9, clk_dec 89.86 /
    88.13, 31,420 ALM, 401 M10K); rig: Family Guy, Akira, The Office Disc 01 in step
    (0.02-0.03 ms), video untouched.
  - **P6b ✅ complete (every stage MERGED, PR fj#18-fj#26, HW-CONFIRMED; planned 2026-09-27): `docs/transport.md`.** Every EP entry is a
    recovery-point I picture, 59 % non-IDR (IDRs up to 160 s apart): the decoder must
    start at a non-IDR recovery point (P6b1). `tools/umd_seek_census.py` measures it.
    ✅ **P6b0-P6b2 MERGED (PR fj#18, 2026-09-28).** ✅ **P6b0 done (2026-09-27)**: `tools/umd_nav_ref.py` (the navigation golden), the
    model's recovery-point start and discontinuity (88 of 89 disc images bit-exact vs
    ffmpeg from a non-IDR entry), `test_umd_nav_ref.py` + 12 RED.
    ✅ **P6b1 done (2026-09-27)**: a seek is the mount's reset with the parameter sets
    kept (`ps_rst_n`), the recovery-point start in `recon_dpb` (a POC probe skips
    leading pictures); **88 of 89 disc images bit-exact in RTL from a non-IDR entry**,
    `run_cosim.sh --seek` (mid-picture resets, `ddr_mux2`'s abort covered), RED C1-C15 +
    recon_ctl D7/D8; fit `UMD_p6b_20260927_2222.rbf` (SEED 9, clk_dec 88.26 / 87.05,
    31,351 ALM); rig: Family Guy / Akira unchanged.
    ✅ **P6b2 built (2026-09-27)**: the reader applies IN / OUT (two EP-map binary
    searches per item start; Hackers, Terminator 2, My Chemical Romance stop at OUT) and
    gains the navigation port, `NAV_SEEK` / `NAV_CHAP` (contract + `nav_err` codes in
    `docs/transport.md` §2.4); `run_umd_reader.sh --red` (every disc image with a seeded
    seek / chapter script, `syn_nav`, 65,535 marks, 39 mutations); telemetry `reader`
    word; fit `UMD_p6b_20260928_0246.rbf` (SEED 9, clk_dec 87.63 / 87.56, 32,152 ALM);
    rig unchanged. Area ~2x plan (~+1.4K ALM once driven): **accepted by the maintainer
    (2026-09-28)**, P6c's budget re-planned before P6c (`transport.md` §7, §9).
    ✅ **P6b3 (`player_ctl`, pause, the track) MERGED (PR fj#19, 2026-09-28), ✅ HW-CONFIRMED**: `umd/player_ctl.sv` (commands, the seek sequence, chapters from the
    pending key, the tracker, the track switch, events), the display's freeze / resync
    drain / skip to the target / stop at OUT, `aud_out`'s freeze, the reset split in `emu`
    (`pipe_rst_*`: a mount or a seek; the parameter sets and the output queue the mount's),
    `umd/kbd_map.sv`; `run_player_ctl.sh --red` (17 mutations, vs `umd_nav_ref`),
    `run_disp_sched.sh` + 7 scenarios, `run_av_sync.sh` S7 / S8. Stop resumes by releasing
    its freeze (not a seek: `transport.md` §9; ratified by the maintainer 2026-09-28). D8's item tag split out to its own stage,
    P6b3i (the maintainer, 2026-09-28; D8a). Fit `UMD_p6b3_20260928_0556.rbf` (SEED 1,
    clk_dec 87.09 / 86.84, 33,213 ALM); rig: Akira / Family Guy chapter jumps, pause (the
    STC and the picture held, `av_err` unchanged), stop / resume, merged presses.
    ✅ **P6b3i (the item tag, D8) MERGED (PR fj#20, 2026-09-28), ✅ HW-CONFIRMED**: the playlist
    item mod 4 born per reader cache slot, carried with the PTS through the demux, the vbuf,
    the CDC, `au_pts_hi`[2:1] and the output queue; the display's 4-entry item table (IN,
    OUT, last, skip per item: every part opens at its IN, ends at its OUT); `player_ctl`
    writes it at every item start, keys chapters by the shown picture's item, holds the
    reader so no tag aliases. Benched (`transport.md` §9: 5 RTL bugs found by the benches).
    The rig found two more (the audio item tag, a demux tag held one cycle), both fixed;
    ✅ rig-checked on My Chemical Romance disc 2 (the Next discriminator, audio after the
    item change), Akira, Family Guy, The Office. The rig also found that a pause counted
    `err_no_store` (~8 a second on the HUD's `ERR`; nothing decoded wrongly): fixed, the
    display's freeze reaches `recon_dpb` (`transport.md` §9).
    **clk_dec's wall retimed (2026-09-28)** at zero cycles (`h264_recon.md` §6.3): SEED 9
    first roll 87.25 / 87.70 (`UMD_p6b3i_20260928_1506.rbf`, 33,595 ALM); 5 of 5 seeds
    pass (86.39-89.65 worst corner); `recon_dpb`'s picture open binds now. The library
    cosim on it: 88 of 88 bit-exact, >= 1.35x (2026-09-29; the first census for
    `run_cosim.sh --sample`, 6 discs: `h264_recon.md` §5.2).
    ✅ **P6b4 (FF / REW) MERGED (PR fj#21, 2026-09-29), ✅ HW-CONFIRMED**: I-picture trick play
    (D1), a hop being a seek to a target carried by time at the PSP's 20 / 33 / 55x;
    `h264_top`'s `one_frame` ends a hop's stream after the entry's first frame (EOS, the
    rest sunk); the reader's seek clamp is now [IN, OUT); the D-pad (gated with the OSD
    open). The trick cosim 88 of 88; `run_player_ctl.sh` recomputes every hop vs
    `umd_nav_ref`. Fit `UMD_p6b4_20260929_0249.rbf` (SEED 9, clk_dec 90.42 / 89.37, 33,847
    ALM; `player_ctl` 347 -> 962). ✅ Rig: 20.1 / 33.1 / 55.0x both ways, the title's ends
    resume play, item crossings, errors 0 (`transport.md` §9). ✅ **P6b5 (the HUD) MERGED (PR fj#22,
    2026-09-29), ✅ HW-CONFIRMED:** mockups (`tools/transport_font.py`, `transport_layout.py`) ✅ approved
    by the maintainer 2026-09-29 (`transport_hud.md` §6.5, every proposal taken). Built:
    `umd/transport_hud.sv`, pixel-exact vs the model in 31 states (`run_transport_hud.sh
    --red`, 18 mutations), the reader's `item_base`, interim keys D (Display) / A (Audio).
    Fit `UMD_p6b5_20260929_1305.rbf` (SEED 9, clk_dec 87.23 / 87.31, 34,880 ALM, the HUD 776,
    M10K 419): ~120 ALM left under 35K (`transport.md` §7); **the pop-up panel is dropped**
    (D10, the maintainer 2026-09-29: every action a button, the D-pad or the OSD; P6b6 lands
    the 11-button J1 list). ✅ Rig-checked (every state, the
    time across items: `transport_hud.md` §6.7).
    ✅ **P6b6 (the buttons and keys) MERGED (PR fj#23, 2026-09-29), ✅ HW-CONFIRMED:** D10's
    11-button J1 list, its PSP default pad map, every action on a keyboard key (FLIRC / IR /
    CEC); fit `UMD_p6b6_20260929_1517.rbf` (SEED 9, clk_dec 87.40 / 88.16, 34,814 ALM).
    ✅ **P6b7 (telemetry and the rig gates, `transport.md` §5 / §6) MERGED (PR fj#24,
    2026-09-29):** 63 telemetry words (the landing's picture, the seek latency, the
    recovery-point start), `mister.py seq` + `tools/rig_gates.py`, `run_av_sync.sh` S12 (the
    track switch); fit `UMD_p6b7b_20260929_1758.rbf` (SEED 9, clk_dec 88.44 / 89.57, 34,945
    ALM: 55 under 35K). Rig: chapters on six discs, trick play, pause, track, IN / OUT ✅; the
    gates found and fixed a one-picture chapter flicker and an audio-switch seam. **The whole
    film ❌**: at 3,352 / 3,888 / 6,758 s of Akira three pictures are held twice their
    duration, the display re-anchors ~83 ms back and the decoder's store alarm trips
    (reproducible; the decoder bit-exact there). ✅ **Its fix: `fix/film-timing`, MERGED (PR fj#25)** (the maintainer, 2026-09-29): **the cause is the
    disc**, a single PES PTS 7-8 ticks late with the next tag back on the timeline (`tools/umd_pts_census.py`:
    208 such on 73 of 88 images; Family Guy's two P5g re-anchors too); the display now disbelieves a lone
    PTS ahead of its timeline (rule A, the maintainer 2026-09-29; `display.md` §7, §10.6-§10.8).
    ✅ HW-CONFIRMED: fit `UMD_filmtime_20260930_0009.rbf` (SEED 9, clk_dec 87.05 / 86.31, 34,949
    ALM); the three-point repro clean; **the whole-film gate PASSES** (errors 0, `av_err` 0 .. 2
    ticks, END taken, 3 lone PTS disbelieved).
  - ✅ **P6c, CUT TO GO TO, in fabric -- MERGED (PR fj#41, 2026-10-04), ✅ HW-CONFIRMED** (G1 decided: in fabric, the room from
    A11; D15 / D16 measured on the maintainer's PSP; the mockups approved): `p6c.md` §9-§10 (the design, as built, the
    decisions taken in the build, the known limitations). A-B built since (`ab_repeat.md`); chapter / title repeat, slow motion, frame advance stay dropped.
  - A Huffman code in no codebook refuses the frame (ffmpeg reads on): §3.2.

---

## ★ There is a real MiSTer you can drive — use it instead of asking

`tools/mister.py` (skill: `.claude/skills/hil-testing/`, note: `docs/hil_harness.md`)
flashes a build, launches an image, presses keys and pulls back a screenshot over ssh.
**Prefer measuring to asking.** The rig is the maintainer's: run `state` first, `restore`
after, and never overwrite their running Main or settings.

Bug reports arrive as sparse-sector bundles (`tools/umd_report.py`, `docs/bug_reports.md`, P8):
the tables whole, the menus' scripts with their art blanked, each stream's head with its headers
only, content-audited. `umd_report.py info|audit|unpack BUNDLE` on one received; the reconstruction
is an ISO of the original size that every tool here reads.

---

## Building a MiSTer-loadable core

**Use `./build_release.sh` — never bare `quartus_cpf`.** MiSTer's loader needs a
**compressed** `.rbf`; an uncompressed pack (~7 MB) silently fails to configure the FPGA
(no video on any output). `build_release.sh` runs the gates (Quartus 10236 implicit-net,
`tools/lint_undriven.sh`, `tools/fmax_check.sh` at **both** slow corners,
`tools/netlist_canary.sh`), packs, and writes a `.rbf.json` provenance manifest.

```bash
USE_DOCKER=1 ./build_release.sh --compile     # -> releases/UMD_<slug>_<date>_<time>.rbf
tools/seed_sweep.sh                            # A2': a miss, < 1.5 MHz margin at either corner, or > 95 % ALM
USE_DOCKER=1 tools/fit_unit.sh TOP "clk=MHz ..." files...   # one module alone: Fmax per clock
USE_DOCKER=1 tools/fit_unit_paths.sh TOP CLOCK             # ...and its worst paths
```

**Always build after completing a requested feature**, in the background, and report.
**Seed sweeps (A2', the maintainer 2026-10-01, `docs/area_plan.md` §2):** one fit at the pinned SEED
by default; a 5-seed sweep only when that fit misses, passes by less than 1.5 MHz at either slow
corner, or the device is above 95 % ALM. Not on every netlist change.
**Record every fit** in `UMD.qsf`'s SEED LEDGER (seed, clk_dec both corners, ALM %,
build name, commit).

Timing note: negative slack on PLL-reconfig / HPS-bridge paths is shared MiSTer
infrastructure; validate empirically. `clk_dec` is the gated domain.

### Versioning

`` `CORE_VERSION `` in `umd/emu.sv` (shown in the OSD as `UMD <version> <yymmdd>`):

> A bare semver lives in **exactly one commit per release**. Every other commit carries
> `dev-<slug>`, set in the branch's **FIRST commit**. Nothing resets it after a merge or a
> release; `build_release.sh` refuses a bare semver on a dev build and a `dev-` string on
> `--release`, so a branch that forgets fails fast.

Limits, enforced: **≤ 18 characters, none of `, ; "`**. Both `CORE_VERSION` and
`BUILD_DATE` are inside `CONF_STR` = inside the netlist: **any change re-rolls the fitter
seed**, so change it once per branch, never per commit, and never derive it from a SHA.
Bump rules: patch = fixes/docs; minor = any new user-visible capability; major reserved.
Judge against the whole unreleased delta on `main`. Builds for testers: the slug names
the build (`dev-slug2` for a second one the same day); never a release.

Publishing: the `release` skill -- a GitHub release draft (`tools/publish_draft.sh`), packaged by
`.github/workflows/package.yml`.

---

## Source control

**Hosting: GitHub** (`github.com/owenb321/MiSTer_UMD_Video`; private while it is staged, public
with the first release). The Forgejo repository holds the bring-up history (PRs fj#1 to fj#93,
issues to fj#89) and is not imported. Write everything as if it were public already (below).

- **Never commit directly to `main`.** Branch first (`feature/<slug>`, `fix/<slug>`).
- **Set `` `CORE_VERSION `` to `dev-<slug>` in that branch's first commit.**
- **Never push a branch or open a PR until explicitly asked.** A merge request is
  authorisation to publish THAT branch (push → PR → merge, the `/merge` command).
- PRs via `gh` (`--repo owenb321/MiSTer_UMD_Video`; the `/merge` command picks `gh` or `tea`
  from `origin`'s URL). Write PR bodies to a file, never inline.
- Commit often, with messages that say what and why.

**The move to GitHub (decided 2026-10-11, the maintainer): a fresh history.** The GitHub
repository starts from one import commit, as MiSTer_DVD's and MiSTer_h264_decoder's did; the
Forgejo history is not pushed (its commits carry a personal e-mail address). **This repository's
`user.email` is the GitHub noreply address (`owenb321@users.noreply.github.com`)**: never commit
with another, and never push a Forgejo-era commit, branch or tag to GitHub. **The import is made
(2026-10-11):** GitHub's first commit is `ea7659e` (Forgejo `main` `ceb0ec2`'s tree); `origin` is
GitHub, Forgejo the `forgejo` remote (the bring-up history, read only). Local backup branches
carry Forgejo history: never push them.

### ⚠ Historical `fj#NN` references — do not "fix" them

`docs/`, `CLAUDE.md` and the code's comments cite this project's Forgejo PRs and issues heavily.
GitHub's numbering restarts at 1, so a bare `#22` would one day point at an unrelated GitHub PR --
a reference that looks right and is wrong. Every Forgejo-era reference is therefore written
**`fj#NN`** (`PR fj#22`, `issue fj#71`), and so are MiSTer_h264_decoder's from its Forgejo era
(`the H264 core's fj#35`). These numbers have no GitHub equivalent: leave them alone, do not
renumber them, do not strip the prefix. MiSTer_DVD's references are its GitHub numbers and stay
plain, always named with the repository (`MiSTer_DVD PR #164`). **Since the move, a new reference
is this repository's GitHub number, plain `#NN`** -- the two namespaces distinguishable on sight.
Plain `#0` / `#2` next to "playlist" are playlist numbers, and `#5` after `always` / `@(...)` in a
bench is a Verilog delay: neither is a reference. Commit SHAs quoted in `docs/` before the move
refer to the Forgejo history and will not resolve on GitHub.

### ★ Never publish personal or workstation-specific information

No absolute paths from a machine, no hostnames/IPs/usernames/e-mails, no private
infrastructure. Repo-relative paths; environment variables with generic fallbacks
(`${UMD_ISO_DIR:-~/umd-isos}`, `root@<mister-ip>`); generic placeholders in examples.
`tools/.mister_host` and `tools/.notify_url` are gitignored for this reason.

---

## Lessons carried from MiSTer_DVD

Each earned by a shipped defect there; each names what enforces it here.

- **Bench that cannot fail.** A test whose setup makes failure impossible is not evidence.
  Every runner has `--red`; every arm is proven able to go RED.
- **RED/GREEN + per-arm mutation gating.** Each deliberate mutation must be caught by
  *its own* arm; one caught by everything says nothing (`bench/umd/run_*.sh --red`).
- **Score with `!==`, never `!=`.** X passes `!=` vacuously; a bench once printed PASS
  with 12,028 X pixels in it.
- **`!==` is vacuous too when BOTH sides are X**: an expected / read array smaller than the data
  reads X past its end on both sides. `telem_tb`'s `[0:63]` arrays passed a 67-word table whose
  responder saturated at word 63 -- `refused` / `warn` / `subs` were wrong on hardware for four days
  (2026-10-07, `transport.md` "D8, the handoff measured"). Size bench arrays from the data, and
  read the compiler's truncation warnings.
- **`$fatal` on failure, a positive PASS marker, never `$finish` on the failure path**
  (vvp exits 0). Runners never score on the absence of "FAIL".
- **A new port floats Z in every bench that instantiates the module** without it. Tie it
  off everywhere in the same commit.
- **Measure, don't ask.** Drive the rig (`tools/mister.py`) instead of asking the user to
  test.
- **An instrument derived from its subject reports health when the subject is absent.**
  Prefer instruments that can say "nothing real happened" (liveness, history).
- **Async-read arrays at many sites explode into LUT-RAM** (one design went 226 % ALM):
  one synchronous M10K read port and a pipeline. And after editing near a memory's
  writes, grep the map report for its "Inferred altsyncram" line before spending a fit.
  **A byte-enabled array of non-power-of-two depth (48 words) is left in registers
  with NO message** (neither inferred nor "uninferred"): size such memories to a power
  of two (P4's sample banks: 6,144 registers until 64). `tools/synth_unit.sh` checks one
  module in minutes.
- **A new state arm in a big FSM costs a mux input on every bit it writes, reachable or not**
  (P8: a sniff plus one setup state writing ~40 registers was +907 LUTs in `umd_reader`; with the
  states made unreachable still +478). Put constants in the mount / reset branch (an image's walk
  overwrites them), route a new mode through existing states, and measure with
  `tools/synth_unit.sh` on a wrapper exposing only the outputs `emu` connects
  (`docs/bare_streams.md` §3): +327 as built.
- **`vec[K*idx +: W]` with a variable index and a constant K that is not a power of two
  synthesises as a barrel shifter over the whole vector** (~200 LUTs per use at 437 bits:
  three such selects were 1,400 LUTs of the reconstruction). Select with a `case` on the
  index. Grep for it after touching wide records.
- **Quartus 17 silently miscompiles some `function automatic` helpers and `N'(expr)`
  size casts** (sim exact, silicon wrong). Use case blocks / part-selects; when sim says
  correct and silicon says broken, A/B two of your own builds first.
- **iverilog resolves `` `include "umd/..." `` against the working directory BEFORE any
  `-I`.** A mutation runner that copies the RTL and compiles from the repo root mutates
  the copy's `.svh` and compiles the repo's: three P4 arms "survived" that way. Compile a
  mutant from inside its copy.
- **`tools/netlist_canary.sh` + `tools/lint_undriven.sh`** catch the declared-but-undriven
  and constant-folded data path that no bench and no telemetry could see. Advisory on a
  dev build, fatal on `--release`.
- **Never edit `UMD.qsf` while a build runs, and check `git diff UMD.qsf` after one.** A
  quartus_map that died of low memory rewrote it (sys.tcl inlined, the ledger's new
  lines lost) and it was committed so; `build_release.sh` now restores such a rewrite,
  **`tools/seed_sweep.sh` does not** (P5f's sweep inlined 170 pin lines): revert the qsf
  and re-apply only the SEED line.
  Simulations and a fit at once exhaust this workstation's memory (the P4 chain bench
  takes ~0.7 GB a simulation, eight at a time): sequence them.
- **The `.qsf` file list gates everything.** A new `umd/*.sv` is invisible to Quartus AND
  to the lint until `UMD.qsf` names it. And `build_release.sh` once exited 0 on a failed
  compile: read the log.
- **The fitter SEED is tied to the netlist**; any CONF_STR change re-rolls it. Ledger
  every fit in `UMD.qsf`. **The cold corner (−40 °C) usually binds**; pass
  `TIMING_TEMP=-40` to `tools/timing_paths.sh` or you retime the wrong path (the knob
  existed only in this file until 2026-09-27: the tcl hardcoded 100 C).
- **Gate at the register, not inside the producing cone**: a suppress-only term belongs
  at the capture register.
- **Occupancy, not bandwidth**: a new DDR3 master that hurts the decoder gets its own port.
- **HIL latency is part of the instrument**: ssh-paced presses cannot test a window under
  ~3 s; sequence on the target. **Control arm first** for intermittent defects; **one
  change per hardware round**; **a step that never reached the state was not measured**
  (wait for a readiness signal, then act).
- **Independent oracle.** A golden model written from the RTL shares its bugs; use
  ffmpeg/JM/the spec. **A gate checkpoint copied from the subject's own trace is the subject
  checking itself** (P9 M1b: one menu checkpoint encoded the engine's bug until the PSP capture
  was re-read): name each checkpoint's source -- a capture time, a script constant -- beside it.
- **Fixture range and metric blindness.** Ask what inputs a fixture spans and what the
  metric structurally cannot see before trusting a verdict. When halving work, score
  WHICH half.
- **Derive a predicate from what it SELECTS, not from the cases it was written for.**
- **A coverage counter must count what the path CHANGES, not that it ran.** P4's list
  modification dropped 129 duplicates on a conformance stream and 15 on a JM fixture with
  a broken removal and no bench could tell: none of those drops changed an index in use.
  Counting partitions predicted from an index the removal changed found the bug
  (`tools/jm_fixtures.py`, `docs/h264_recon.md` §5).
- **Papercuts:** declaration after use; a constant index outside a vector's range inside a `for`
  loop, even behind a guard (`ri < 16 && aud_present[ri]` for ri up to 31) -- Icarus and Verilator
  accept it, Quartus stops elaboration (P7b, 2026-09-30): pick the vector first, index that; an `input` port driven internally (only the fitter
  sees it, 30 s into a 40-minute compile); `pgrep -f` matching its own shell — manage
  Quartus by the Docker container name; the MiSTer has no `pkill`.
- **On the A9 a NEON value must not cross to the core registers** (fj#74): a GCC vector filled by `memcpy`
  went through `ldr` / `stmia` / the stack / `vldr` (the step 70 ns a pixel), a lane read into a core register
  stalls the pipeline. Load and store vector types (`vld1` / `vst1`), keep counters in vectors, and read the
  disassembly (`objdump` in the Main's image) before believing a vector loop is vectorised.
- **Check the polarity of any active-low signal shown as a flag** before concluding a
  watchdog is firing.

---

## Simulation quick reference

```bash
bench/umd/run_scaffold.sh            # raster + idle screen + emu wiring + lint
bench/umd/run_scaffold.sh --red      # ...and prove every arm can fail
bench/umd/run_h264_cabac.sh [--red]  # the CABAC engine vs tools/cabac_ref.py
bench/umd/run_mb_syntax.sh [--red]   # the macroblock layer on real slices vs h264_fe_ref.py
bench/umd/run_h264_top.sh [--red]    # the whole front end on Annex-B streams vs h264_fe_ref.py
bench/umd/run_p3_chain.sh [--red]    # demux -> CDC -> front end as emu composes it, two clocks
bench/umd/run_recon_top.sh [--red] [--discs]  # the whole reconstruction vs h264_recon_ref.py, per MB + per picture + the output order (P5d)
bench/umd/run_recon_out.sh [--red]   # the output queue (records, holds, releases) on two clocks
bench/umd/run_disp_sched.sh [--red]  # Verilator: queue -> scheduler -> reader, every refresh vs disp_sched_ref.py
bench/umd/run_cosim.sh [--red] [--sweep]      # Verilator: front end + reconstruction, 300 frames of every disc's main title
bench/umd/run_cosim.sh --sample [--tail N]    # a chosen sample (FAILs, the slowest N, a cover of every stream feature) from the census a full --sweep writes; the gate unless cycles or decoding change (h264_recon.md S5.2)
bench/umd/run_cosim.sh --sweep --ep-start --model-only   # P6b0: the model vs ffmpeg from a non-IDR EP entry (a seek), no RTL
bench/umd/run_cosim.sh --ep-start | --seek   # P6b1: the RTL from a non-IDR entry; a mid-picture seek (6 reset points, the abort covered)
bench/umd/run_cosim.sh --trick [--sweep]     # P6b4: one_frame -- the first frame of a longer window, bit-exact, the rest cut
bench/umd/run_disp_reader.sh [--red] # ddr_mux2 (two masters, abort) + the display reader: frame, field pair, Weave / Bob / Blend (P5f) vs BT.601 + ffmpeg
bench/umd/run_f2sdram_term.sh [--red] # Verilator: sys's f2sdram terminator (UMD-FORK) locked mid-burst; K0 = stock (the reload hang)
bench/umd/run_dac_dither.sh [--red]  # the analog DAC's ordered dither (umd/dac_dither.sv, from DVD): every line / column / 480i pixel exact
bench/umd/run_aspect_vui.sh [--red]  # the VUI aspect -> 4:3 / 16:9 vs Table E-1 from the spec PDF
bench/umd/run_at3p.sh [--red]        # the ATRAC3plus decoder vs its emulator / at3p_fixed.py (run_at3p_seq.sh: the sequencer)
bench/umd/run_av_sync.sh [--red]     # the audio path: demux -> ring (AU tags) -> decoder -> gate vs the STC (P6a); + pause (P6b3)
bench/umd/run_player_ctl.sh [--red]  # the transport (P6b3; P6b4 trick play; P6c TIME + Go To's query port): player_ctl in a mock reader / display, decisions vs umd_nav_ref
bench/umd/run_goto_ctl.sh [--red]    # P6c: Go To's editor (umd/goto_ctl.sv), a random press walk vs the bench's reference from the spec, a mock NAV_CHAP
bench/umd/run_nav_model.sh [--red]  # A12 N1: the navigation engine's program (umd/nav/nav.uasm) on its emulator (tools/nav_isa.py), scored with umd_reader_tb's arms on the same fixtures
bench/umd/run_png.sh [--red] [--sweep]  # the PNG decoder vs zlib + libpng; --sweep: every subtitle unit (Verilator)
bench/umd/run_sub.sh [--red]         # the subtitle chain: units, the DDR3 ring, planes end to end, ram2 latency
bench/umd/run_hps_sub.sh [--red] [--sweep]  # A7's B1: the HPS subtitle decoder (main/support/umd/umd_sub.cpp) vs libpng, this PC's AND 1.6.37 (the device's)
bench/umd/run_umd_host.sh [--red]    # A7's B3: the host port (umd/umd_host.sv) on EXT_BUS: HOST_RD / HOST_WR, the heartbeat, the completion's crossing
bench/umd/run_hps_host.sh [--red]    # A7's B4: the UMD Main's host decisions (umd_host_logic.cpp) vs a C model of sub_top's acceptance rule
bench/umd/run_panel.sh [--red]       # P6d: the control panel (umd_panel.c) vs tools/panel_ref.py (decisions) + panel_layout.py (pixels, byte-exact); [run] the panel in the UMD Main's runner
bench/umd/run_plane.sh [--red]       # the plane compositor over disp_reader's video: 1:1, bilinear, blend, vblank flips; P9's hand-over (sub_flip_tb)
bench/umd/run_pcm_shot.sh [--red]    # P9: the menus' sound one-shot (umd/pcm_shot.sv) from DDR3, its own 48 kHz, retriggers
bench/umd/run_menu.sh [--red] [--lib] # P9 M1: the menu engine on the PC (--lib: M4's library sweep, tools/menu_lib.py, every image's class vs tools/menu_lib_classes.txt) (main/support/umd/menu/); M1a the RCO loader vs rco_census.py on every RCO; M1b-M1d the gate (tools/menu_gate.py): three captured discs' startup chains, key paths, pictures and relaunches; M3: [iso] [playlist] [host] and [mhost] (menu_gate.py --host: the same scenarios through umd_menu_host + umd_menu_logic against a core model, menu/menu_host_check.c); M4h: [scale] (menu/scale_check.c: the canvas's stretch, menu_scale, against its definition)
bench/umd/menu/build_arm.sh [-DMENU_PROF]  # fj#74: menu_host_check for the A9 (the Main's toolchain + flags): run it ON the MiSTer -- the renderer's real cost; MENU_PROF: per item / phase
tools/menu_render_ab.py --ref-commit SHA  # fj#74: every library image's menus, every frame hashed, against a reference build -- the exactness gate for a renderer change
bench/umd/run_overlay.sh [--red]     # sub_overlay (chain + compositor, emu's one instance): demux bytes -> composite, flushes
bench/umd/run_transport_hud.sh [--red] # Verilator: the transport HUD (P6b5), 31 states pixel-exact vs tools/transport_layout.py
UMD_ISO_DIR=... tools/telecine_census.py --cache DIR [--param k=v]  # fj#80: the field-matching model over the library (docs/telecine.md)
bench/umd/run_film_lock.sh [--red]  # fj#80: umd/film_lock.sv step by step vs telecine_ref.FilmLock (vectors; library arms with UMD_ISO_DIR)
bench/umd/run_zoom.sh [--red]       # fj#71: Zoom's decision and band (umd/zoom_ctl.sv) vs the gating table (docs/zoom.md); its clamp: run_overlay.sh +zoom
bench/umd/run_psp_scan.sh [--red]   # a PSP's UMD over USB: the UMD Main's mount / unmount decisions (umd_psp_logic.c) on scripted scans (docs/psp_disc.md)
tools/tests/run_tests.sh             # host-side python tests (no media)
tools/tests/run_tests.sh --red       # ...and prove each P1 test can fail
UMD_ISO_DIR=... tools/tests/corpus_umd.sh [--full-audio]   # the media gate (SKIP w/o images)
UMD_ISO_DIR=... tools/tests/corpus_report.py [--menus]     # P8: every image -> bug bundle -> reconstruction, read alike
```

Benches follow `bench/umd/README.md`. Fixture slices come from `$UMD_ISO_DIR`.
