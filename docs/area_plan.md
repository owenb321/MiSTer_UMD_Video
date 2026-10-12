# The area plan after P6: P7, P6c, P9 and the device

**§10 (2026-10-06): where the engine + microcode pattern would reclaim logic -- a survey, nothing built.**

**Status: 📐 written 2026-09-30, ✅ MERGED (PR fj#28); decisions A1-A4 (§5) ✅ TAKEN by the
maintainer the same day** (A1: no framework switch; A2: the sweep rule; A3: P7's trims measured
before its wiring; A4: host B in the project's own Main fork, upstream not asked; the ISO move decided at P9 -- **resolved by A5: ISO stays in fabric**). **A3 done (§6); P7 ✅ MERGED (PR fj#29) at 40,875 ALM, 98 % (§7). §8: what may run on the HPS (A5-A10, the stock-Main rule, 2026-09-30); A10: A7 now, planned in `hps_host.md`.** Why now: P7's subtitle overlay measured
4,744 ALM alone, and `p6c.md` D11 put P7 before P6c. This note plans the rest of the
device in one pass, so each later phase does not re-plan it.

## 1. Where the core stands, and what is still to build

The last fit, `UMD_loneearly_20260930_0446.rbf`: **34,961 ALM of 41,910 (83 %), 419 M10K
of 553, 78 DSP of 112**; clk_dec 87.29 / 87.86 MHz against the 86 MHz floor.

| still to build | ALM | notes |
|---|---|---|
| **P7** subtitles | **>= 4,744 + the `emu` wiring**, measured at its fit | 4,744 is `sub_overlay`'s unit fit (`compositor.md` §7), a FLOOR: alone the placer has room it will not have beside the decoder (`fit_unit.sh`'s header; P6b5's fit placed `player_ctl` +118 with no change to it). The wiring: ram2 goes from `disp_reader` alone to `ddr_mux2` + `rd_merge2`, the OSD's subtitle option, the Subtitle button (inert since P6b6), telemetry words, a HUD row: est. +200-400. **DSP: 78 + 18 = 96 of 112** (84 if A3's 1:1 reader lands) |
| **P6c** Go To, A-B / Repeat, frame advance / slow motion | 1.3-2.5K calibrated (`p6c.md` §2) | parked behind P7 (D11) |
| **P9** the disc menus' contract, host B | 1.1-1.6K (`menus.md` §4-5) | the menu plane (a second `plane_reader`, bilinear) and the player-control-block commands |
| 480i + csync, the analog scaler | ~2K | moved out of P5 unbuilt, unscheduled (roadmap "Moved out of P5") |

**The arithmetic** (A1 declined: the framework stays whole):

| | ALM | of 41,910 |
|---|---|---|
| now | 34,961 | 83 % |
| + P7: `sub_overlay` **4,691 measured** (A3 done, §6) + the wiring (est. 200-400) | ~39.9-40.1K planned; **measured 39,563 (94 %) on the first core fit, 40,875 (98 %) after the retimes and fixes (§7)** | **94-98 %** |
| + P6c (1.3-2.5K) | ~41.2-42.6K | 98-102 % |
| + P9's contract (1.1-1.6K) | ~42.3-44.2K | 101-105 % |

(Planned with A3 at 350-600: it measured ~190 net of a timing fix, §6.)

What that means:

- **P7 fits the device**, at ~95-96 %. It overruns its old 37.5K checkpoint by
  ~2K; its checkpoint is now A2's rule (§2).
- **P6c does not follow P7 on fabric levers alone.** D11's "P6c after P7" means *P6c waits for
  an endgame lever* (§3, A4), not for P7's fit.
- **P9's host A** (a soft CPU in fabric, +2.5-4K beyond the contract) **is out by arithmetic.**
  The roadmap conditioned it on "P7 at or under budget", and P7 will not be. **P9 is host B**:
  a `support/umd/` module in the project's own Main fork (`main/`, A4).
- **480i** has no room without an endgame lever.

## 2. Timing: every fit from P7 on needs a seed sweep (amended 2026-10-01: A2', below)

> **The sweep rule, as amended (A2', the maintainer 2026-10-01):** one fit at the pinned SEED by default; a 5-seed sweep (`tools/seed_sweep.sh`, >= 3 of 5 must pass) only when that fit misses, or passes by less than 1.5 MHz at either slow corner (clk_dec < 87.5 MHz against the 86.0 gate), or the device is above 95 % ALM. Why: the per-fit sweep was set at 83-98 % fill, where clk_dec's margin was decided by the
> seed (one netlist spread 86.4-89.7 MHz; P7's went 0 of 5 at 98 %) and one passing seed could be
> luck. After A7 the device is at ~90 % and 480i's sweep passed 6 of 6 (worst corner 88.5 MHz),
> its pinned seed at 93.21 / 92.76: a sweep there measured nothing needed. The thin case still
> earns one -- the HUD inset's SEED 11 passed by 0.42 MHz cold, and its sweep's first seed reached
> 89.15. A sweep costs ~25 min a seed of a fit.

The measurement fit (§3, A1) is 551 ALM *smaller* than `main`'s, on the same SEED 9, and it
missed: clk_dec 86.17 / 85.24 MHz. P6b3i's five seeds spread 86.39-89.65 on their netlist.
So at 83 % clk_dec's margin is already decided by the seed, not by the area. That is what a
raised checkpoint really costs:

- **A sweep per fit** (`tools/seed_sweep.sh`, ~40 min a seed).
- **The rule, not a number** (A2): the ceiling is found when a fit's 5-seed sweep passes on
  fewer than 3 seeds at 86 MHz both corners. There is no crowding data past 90 % on this
  netlist. P4's fall (92 → 84 MHz at 91 %) was a different shape: the reconstruction then
  was twice today's.
- If the rule trips, the next step is retiming clk_dec's binding cluster (`recon_dpb`'s picture
  open, `h264_recon.md` §6.3), then an endgame lever.
- **The retimes to harvest first: MiSTer_h264_decoder's** (surveyed 2026-09-30). Its copy
  of our decoder closes clk_dec at ~104 MHz (from 81) with High profile added, by a written
  playbook: `tools/timing_census.py` / `timing_chain.py`, registered predicates in
  `recon_dpb` (the picture open over two cycles, the window scan, the output decision),
  `recon_lists`' marking, `mv_pred`, `mb_syntax`, the CABAC rLPS rows beside each context's
  state. Each costs registers, not cycles; each is ported by hand and scored in our cosim
  (`harvest.md` "Fixes exchanged with MiSTer_h264_decoder"). **It has no AREA to harvest:**
  every shared module is as large or larger there (the reconstruction 13,594 vs 11,879 ALM,
  High profile), the few smaller ones within placement noise.

## 3. The levers

| lever | ALM | M10K / DSP | what it costs users | status |
|---|---|---|---|---|
| **A1: the framework switches** `MISTER_DISABLE_ADAPTIVE`, `MISTER_DISABLE_YC`, `MISTER_DOWNSCALE_NN` (qsf macros, as `MISTER_DISABLE_ALSA` already is) | **-551 measured** for all three (ascal -191, yc_out -233, the rest placement); `DOWNSCALE_NN` alone **~30** (ascal synthesised alone, twice) | -3 / **-12** (NN alone ~6) | see below | **declined** (A1): measured 2026-09-30, `UMD.qsf` ledger |
| P7's own trims: a 1:1 `plane_reader` for subtitles (the bilinear kept as a parameter for P9's menu plane); `png_chunks`' 32-bit counters, `inflate`'s three count tables in one register file | est. 250-400 + 100-200, **unmeasured** | -12 DSP (the 1:1 reader) | none: subtitles are placed 1:1 on the 720 x 480 raster | needs the `SCALE` parameter built, then `fit_unit.sh` (A3) |
| `xmb_wave` (the idle screen's wave) as a flat fill | 234 | -- | the idle screen's look | not proposed |
| the reader's trims (`transport.md` §7) | 53 measured; 100-200 est. (register sharing, invasive) | -- | none | not proposed |
| instrumentation as a build option | up to ~1.2K | -- | the release is not the HIL-tested build; no Diagnostics HUD or telemetry in users' cores | **held in reserve** (the maintainer, 2026-09-30, `p6c.md` D11) |
| **ISO handling to the HPS** (the 2026-09-24 contingency) | ~3K (`umd_reader` 3,319 + 16 M10K, less a stream intake) | -16 / -- | **playback would need the project's Main fork in place of stock Main** (below) | A4 |

**A1, what each switch would cost, and why each was declined** (the maintainer, 2026-09-30):

- `MISTER_DISABLE_ADAPTIVE`: the scaler's adaptive scanlines. **Kept: scanlines can
  simulate the PSP's LCD grid.**
- `MISTER_DISABLE_YC`: composite and S-video from the analog port. **Kept** (the maintainer
  needs it; it matters with 480i).
- `MISTER_DOWNSCALE_NN`: `ascal` downscales whenever the picture's window in the HDMI mode
  (square pixels, the title's aspect) is smaller than 720 x 480. That happens on 640x480
  (4:3: width 720 → 640; 16:9: both axes), 720x480 (4:3: width; 16:9: height 480 → 405),
  720x576 and 800x600 (16:9: height); never at 720p and above. Its filter follows the user's
  scaler filter (bilinear unless they chose nearest).
  - NN would force nearest there: every 9th column or ~6th line dropped, so subtitle and HUD
    text break up and pans shimmer.
  - Those 480p-class modes are what SD / CRT users on an HDMI converter run, until 480i exists.
  - **Declined: ~30 ALM does not pay for it.**

**The endgame lever and P9 share one host: the project's Main fork.** The roadmap's first
principle is a self-contained `.rbf`. Its one exception (2026-09-25, amended 2026-09-30) is
core support code in Main for the menus. **The maintainer (2026-09-30): not upstream, but the
project's own Main fork** (`main/`, where the HIL Main already carries `support/umd/`),
shipped with the core (`roadmap.md` "Guiding principles", `menus.md` §3).

- P9 is host B by §1's arithmetic, so users who want the menus run the project's Main.
- Moving the ISO walk, the playlist / CLPI parsing and the navigation (IN / OUT, `NAV_SEEK`,
  `NAV_CHAP`) into the same `support/umd/` would **widen the exception to playback itself**:
  the core would then play nothing on a stock Main. Today it plays everything but the menus
  on a stock Main.
- No external gate: the fork is the project's. Its costs are keeping it in step with upstream
  Main's releases, and the install step (the project's Main in place of stock Main).

## 4. The proposed path

1. **P7 now:**
   - build and measure P7's own trims with `fit_unit.sh` (A3);
   - wire P7 into `emu`, fit, and sweep 5 seeds;
   - P7's checkpoint becomes that measurement, if A2's rule holds.
2. **Host B is the project's Main fork** (A4): P9's engine (M3) and, if taken at P9, the ISO
   handling go into `main/`'s `support/umd/`. Nothing external to wait on.
3. **P6c after P7, against what the fit leaves.** Most likely it waits for the endgame lever;
   a reduced P6c (A-B / Repeat plus frame advance, ~0.55-1.1K) might fit before it.
4. **At P9: host B, and, if A4 is taken, the ISO move in the same module.** That frees ~3K for
   P6c, P9's contract and 480i.

## 5. Decisions

| # | question | proposed |
|---|---|---|
| **A1** | The three framework switches for P7 | **DECIDED (the maintainer, 2026-09-30): none.** ADAPTIVE kept (scanlines as the PSP's LCD grid), YC kept, NN declined (~30 ALM against visibly worse 480p-class downscaling). Offered: all three (-551 measured) |
| **A2** | P7's checkpoint | **DECIDED (the maintainer, 2026-09-30): the rule of §2.** P7's checkpoint is its measured fit, provided a 5-seed sweep passes on >= 3 seeds at 86 MHz both corners. **Amended (A2', 2026-10-01): a sweep only for a fit that misses, passes by < 1.5 MHz at either corner, or above 95 % ALM (§2).** |
| **A3** | P7's own trims before its wiring | **DECIDED (2026-09-30): yes, measure first.** The `SCALE` parameter (1:1 for subtitles) and the two decoder trims, each measured with `fit_unit.sh`, benches RED-proven, before the `emu` wiring. **✅ Done 2026-09-30 (§6): ~190 ALM and 12 DSP, not 350-600** |
| **A4** | The endgame | **DECIDED (the maintainer, 2026-09-30): host B is the project's own Main fork (`main/`, as for telemetry); upstream Main_MiSTer is not asked. Whether ISO handling moves there is decided at P9.** Offered: widen the exception now; ask upstream; keep the principle and cut features **Resolved 2026-09-30 by A5 (§8): the ISO handling stays in fabric; host B hosts features only.** |

## 6. A3, measured (2026-09-30)

`sub_overlay`'s unit fit (`tools/fit_unit.sh`, SEED 1, the four clocks as in `emu`; the table
and the paths in `compositor.md` §7):

| step | ALM | DSP | mclk -40 C |
|---|---|---|---|
| the branch after merging `main` (the baseline) | 4,840 | 18 | **76.8** (target 90) |
| the 1:1 reader by pinned weights; `png_chunks`' trims | 4,790 | 18 | 76.3 |
| + no multiplier at 1:1 (a parameter select); `sub_mem`'s output register | **4,691** | **6** | **93.4** |

- **The reductions saved ~190 ALM and 12 DSP**, against the 350-600 ALM estimated. The
  estimate came from standalone fits whose geometry ports were free. In `sub_overlay`, the
  constant 1:1 geometry had already pruned most of the bilinear path (the bottom-row buffers
  included). What stayed was the 12 multipliers (-98 ALM with them) and `png_chunks`'
  registers (-75 registers, -6.5 ALM).
- **`inflate`'s count tables: not attempted.** On that evidence they would return tens of
  ALM for an intricate change to a decoder that is bit-exact over the whole corpus.
- **The merge had broken mclk** (`main`'s `ddr_mux2` orphan guard behind `sub_mem`'s
  combinational port). `sub_mem`'s output register fixes it for +40 ALM (`subtitles.md` §2).
- **The benches:**
  - `run_plane.sh --red`: the sub mode also on `SCALE` 0, arms S1 / S2;
  - `run_sub.sh --red`: M1-M3 on the registered `sub_mem`;
  - `run_png.sh --red`;
  - `run_overlay.sh`.

## 7. A2's rule, first tripped (2026-09-30, `feature/p7-subs`)

| netlist | ALM | clk_dec SEED 9 (100 / -40 C) |
|---|---|---|
| P7a + P7b, the first core fit | 39,563 (94 %) | 87.27 / 86.13 pass |
| + the CLP-mask fix (the rig's; ~no logic) | 39,538 (94 %) | 84.92 / 84.73; **a 5-seed sweep: 0 of 5 pass** (84.1-87.2) |
| + `recon_dpb` retimed (~150 registers, `h264_recon.md` §6.4) | 40,739 (97 %) | 88.70 / 86.35 pass; clk_mem -0.25 ns (the ram2 probe) |
| + `ddr_probe` registers its inputs (5 registers) | 40,875 (98 %) | 85.03 / 86.19 |

- **The rule tripped** on the fixed netlist: 0 of 5 seeds passed, binding on `recon_dpb`'s P6b1 probe.
  The planned response (§2) retimed it, and it left the top.
- **What that showed: at 97-98 % the fill, not a path, is the timing problem.**
  - Two netlists a handful of registers apart swing ~3 MHz either way.
  - ALMs "needed" rose ~1,300 for ~150 registers of logic (the fitter duplicating and
    spreading at the edge; `recon_dpb` itself shrank).
  - The margin is a flat wall again: `mv_pred`'s neighbour select, `intra_pred`, `recon_dpb`'s
    marking, `mb_syntax`'s mvd increment, all within ~0.7 ns.
  - Each further retime costs registers, which raises the fill.
- **The second sweep, on the last netlist: 5 of 5 PASS** (SEED 1 87.50 / 89.25, 3 89.73 / 89.67,
  5 89.23 / 87.37, 7 88.37 / 86.20, 11 87.53 / 86.64; SEED 9 alone missed). **A2's rule holds:
  P7's checkpoint is 40,875 ALM (98 %)**, SEED 3 pinned. The retime turned the lottery back into
  margin; the fill's pull is still there, so the next netlist change re-rolls with less room
  than before.
- **The next margin, when P6c or P9 need it:** the H264 fork's newer zero-cycle retimes
  (`feature/clk-dec-up`, 2026-09-30: `c63a195`, `7340353`, `e125f75`: `sfifo`'s full, `mb_syntax`'s
  neighbour table, `recon_dpb`'s frame_num wrap, `recon_lists`' parity, type-1 POC set-up). They
  hit today's wall almost cluster for cluster, and the fork's ledger shows them area-neutral
  (32,526 -> 32,457 ALM over three rounds, clk_dec 111.77 / 110.41 at 77 %). Harvest them before
  any user-visible area lever; the ones that add macroblock cycles only against the cosim's 1.35x.

## 8. What may run on the HPS (the maintainer, 2026-09-30)

With the device at 98 % after P7, every remaining feature (P6c, P9, 480i) needs room. The
maintainer set the rule that decides what may leave the fabric:

| # | decision |
|---|---|
| **A5** | **The stock-Main rule.** The core must play a UMD ISO on a **stock** Main, with no forked Main installed. Everything that takes: the ISO reader and its navigation, the demux, H.264, ATRAC3plus, the display path, the transport (play / pause / stop, chapters, FF / REW, the audio track). **Features beyond that may be hosted on the HPS**, in the project's own Main fork (`main/`, `support/umd/`, shipped with the core; upstream is not asked, A4). A stock-Main user loses only those features. |
| A4 (resolved) | **ISO handling stays in fabric**: it is part of playing a disc (A5). The ISO-to-HPS contingency of 2026-09-24 is retired. |
| **A6** | **P6c (Go To, A-B / Repeat, frame advance, slow motion) is an HPS feature.** Its UI and logic run on the HPS. The fabric keeps what it already has (`player_ctl`'s SEEK, the display's freeze), plus the minimum hooks a feature needs (`p6c.md`). |
| **A7** | **Subtitle decoding moves to the HPS when P9 needs the room** (P9 builds the HPS PNG path anyway). It moves the PNG decoder and the plane writer. |
| **A8** | **Both HUDs and the instrumentation stay in fabric** until something forces them out: they are what stock-Main testers see and report bugs with. **Reversed for the diagnostic HUD by A11 (2026-10-03)**; the transport HUD and telemetry stay. |
| A9 (engineering order) | **Superseded by A10 for its order.** ~~The H264 fork's zero-cycle retimes are harvested before any feature lands at 98 %** (§7): margin against the seed lottery, no user-visible cost.~~ They are harvested after A7's fit frees room. **Harvested 2026-10-05** (`h264_recon.md` §6.5): 5 of 5 seeds pass at 92 %, +52 ALM over P6d (38,676 -> 38,728). |
| P8 (bare `.MPS`, 2026-10-05) | **+399 ALM** (38,728 -> 39,127, 93 %; SEED 5 89.99 / 89.29): `umd_reader` +252 (the sniff, a bare file through `S_MPS`, `bare_streams.md` §3: the first version, a setup state writing ~40 registers, was +519 / +899 at 95 %), `player_ctl`'s UNAVAIL gate and late track rule, the HUD's seventh message, `ps_demux`'s subtitle tap, `emu`'s stream-learned masks. |
| **A11** | **(the maintainer, 2026-10-03) The diagnostic HUD leaves the core to make room for Go To in fabric -- A8 reversed for it.** ✅ MERGED (PR fj#40); Go To followed (PR fj#41: 38,755 ALM, 92 %). Measured on `measure/no-diag-hud` (SEED 9, the M4 netlist): 39,171 -> **37,749 ALM (-1,422)**, M10K -7, clk_dec 89.33 / 88.68 -- twice the 0.7-0.8K the per-entity numbers suggested (`p2_diag` 373 + `diag_hud` 18, and what only it read: `es_probe` 117, the HUD-only snapshot fields, their counters, plus the fitter's density). The room under 95 % goes from ~640 to ~2,070 ALM, which covers Go To's calibrated 0.75-1.9K (`p6c.md` §9). Kept: telemetry (it gains `refused`, `warn`, `subs`: what a bound hit is visible by, `spec_hardening.md`), the transport HUD (it gains "This disc cannot be played." on a refusal or a reader error, so a refused stream stays loud for a stock-Main user). Lost: the stock-Main tester's screenshot readout; the Diagnostics OSD option. A bug report's readout is now the diagnostic log (`/tmp/umd_telem.json`, the UMD Main with `umd_hil`). |
| **A12** | **(the maintainer, 2026-10-06) The reader's parse goes onto a navigation engine (§10a), and if that frees the room, the subtitle decode comes back into the fabric -- A7 reversed for the stock Main.** "The biggest missing feature for viewing a film in the core without the HPS extras." Planned in `docs/nav_engine.md` (stages N0-N3, SD1-SD3). N0 measured: the parse is ~95 % of the reader, est. −2.0-2.7K ALM. **E1 / E2 taken the same day: the hardwired PNG decoder comes back; the fabric always decodes, and the UMD Main composites its panel over the fabric's plane.** **✅ MERGED (PR fj#59, 2026-10-07), ✅ HW-CONFIRMED (`nav_engine.md` §9-§11): the reader 3,749 -> 1,016 ALM; the decoder back; the core 39,117 ALM (93 %), RAM 503 (91 %); merged with main at SEED 3, 39,425 ALM (94 %).** |
| **A10** | **(the maintainer, 2026-09-30) Area before more decoder work: A7 is taken NOW**, ahead of P6c and ahead of A9's retimes. At 98 % every netlist change re-rolls the seed lottery. The plan: `docs/hps_host.md` (stages B0-B5, decisions H1-H8 taken the same day). **Q1, the surface:** one plane (H5, second round): nothing but subtitles is HPS-drawn during playback, and P9's menus take the plane over while a menu is up. **P6c is cut to Go To, on the core if A7 frees the room** (G1, `p6c.md` §9); A-B / Repeat, slow motion and frame advance dropped for now. |

**A7 in numbers** (the P7 fit, `UMD_p7subs_sweep2_20260930_2056.rbf`):

| moves to the HPS | ALM | M10K |
|---|---|---|
| `sub_png` (the PNG decoder `png_top` + its FIFOs) | 2,225 | 47 |
| `sub_plane_wr` (the plane writer; the HPS writes the plane) | 209 | 2 |
| **frees** | **~2.4K** | **~49** |

What stays, ~1.1K ALM:
- `sub_in`, `sub_unit` and `sub_ring`: units into the DDR3 ring. The HPS reads them there.
- `sub_sched` and `sub_flip`: the show / hide timing against the 90 kHz STC, which HPS
  polling cannot match.
- The compositor: `plane_reader`, `plane_blend`, `rd_merge2`, `ddr_mux2`.

A stock-Main user then has no subtitles; the Subtitle button says why. That message is owed
with A7: `on-screen-messages.md` and `troubleshooting.md`, its text designed then. The manual
carries a "Planned" note meanwhile (`reference/compatibility.md`).

**The consequence found writing this down (2026-09-30).** Even an HPS feature needs a fabric
contract (`menus.md` §4):
- a command path from the HPS into `player_ctl` (`hps_io` / `EXT_BUS`, as the telemetry
  already uses; est. ~100-300 ALM);
- a surface to draw its UI on (a plane: ~250 ALM for a 1:1 reader, measured in P7, plus a
  third input to the read merge).

At 98 % even that does not fit. So **the first HPS feature needs room freed first**. The
natural source is A7 itself: it frees ~2.4K AND makes the subtitle plane HPS-owned. The HPS
could then draw P6c's editor, and later the menus, into that same plane, with no second
plane reader. That would move A7 ahead of P9, to P6c. Q1 was open for the maintainer at the
planning session: take A7 with P6c, or find P6c's contract elsewhere. **Answered (A10): A7 now;
P6c is cut to Go To, which moves back to the fabric if A7 frees the room (G1), so it needs no
surface; P9's menus share the subtitle plane (`hps_host.md` §3.4).**

**Written: `docs/hps_host.md` (2026-09-30, A10).** It answers each item below. **Next concrete
step:** its B1 (the host decoder on the PC) and B2 (the rig measurements); H1-H8 are taken. The list it was written against:
- the Main fork's `support/umd/` beside the HIL Main's `umd_ctl.cpp`, and its release packaging;
- the command path into `player_ctl`;
- one HPS-owned plane vs a second plane (Q1);
- the subtitle-decode handoff: the ring's unit records, the plane buffers and `sub_sched`'s
  flip protocol, with the HPS as the writer;
- what a stock-Main user sees for each HPS feature.


## 9. After A7: 480i, Go To and the host side together? (2026-09-30, the maintainer's question)

**The maintainer (2026-09-30): 480i stays on the FPGA side** (it is the raster: the stock-Main
rule, A5). The question: do 480i, Go To (`p6c.md` §9, G1) and the logic for talking to the
Main side all fit at once?

**480i is far cheaper than the "~2K" carried since P5.** That figure was csync plus an analog
vertical scaler. MiSTer_h264_decoder built both (its P6 part 1, ✅ HW-CONFIRMED on a RetroTINK
and a CRT), and its ledger (`H264.qsf`, 2026-09-28 / 29, SEED 1) separates them:

| the fork's step | ALM | DSP / M10K |
|---|---|---|
| the 480i raster, `csync_smpte`, Video Output (28,118 → 28,355) | **+237** | +2 / -1 |
| field selection at 480i, with a `mv_pred` retime (→ 28,412) | +57 | -- |
| **every picture fitted to the raster** (the fitting reader, `disp_fit`, Analog Aspect: Letterbox / Crop / Fit) (28,488 → 30,478) | **+1,990** | +12 / +6 |
| anti-twitter, 60.00 Hz, PAL (part 2) | ~0 | -- |

- **So 480i itself is ~300 ALM** on the fork's netlist. Called 0.3-0.6K here, since our netlist
  is fuller.
- The ~2K is the fitter. Every UMD picture is 720 x 480, so at 480i it is shown 1:1 with no
  fitter. What a fitter would add on analog is **Letterbox / Crop of a 16:9 disc on a 4:3 CRT**:
  without it, an anamorphic picture fills the 4:3 screen stretched vertically, as a DVD player
  set to 16:9 output would show it.

**Analog Aspect is wanted (the maintainer, 2026-09-30): Auto / Letterbox / Fit / Crop for a
CRT**, MiSTer_DVD's option.
- **UMD's case is DVD's, not the fork's.** Every UMD picture is 720 x 480, 4:3 or 16:9
  (`aspect_vui.sv` rounds to those). For a 16:9 disc on the 4:3 raster:
  - Letterbox is a fixed 3/4 vertical downscale (480 → 360 lines, 240 → 180 a field);
  - Crop is a fixed 4/3 horizontal stretch of the centre 540 columns;
  - Fit is the picture as it is, stretched;
  - Auto is Letterbox at 480i.

  A 4:3 disc needs none of it. MiSTer_DVD built exactly this (`disp_vscale`, `disp_hstretch`,
  `aspect_ctl`: `docs/harvest.md`'s DVD side). The fork's +1,990 is a general fitter (any size,
  both axes, per-store dividers), which UMD does not need.
- **Measured in MiSTer_DVD's last fit** (`output_files/DVD.fit.rpt`, "Fitter Resource
  Utilization by Entity", placed in a full core):

  | DVD entity | ALMs needed | M10K | DSP |
  |---|---|---|---|
  | `disp_vscale` (Letterbox, 2-tap vertical blend) | 244 | 6 | 3 |
  | `disp_hstretch` (Crop, 2-tap horizontal) | 251 | 1 | 3 |
  | `aspect_ctl` (the mode) | 38 | -- | -- |
  | **total** | **533** | **7** | **6** |

  Called **0.55-0.8K** here (UMD's display path is `disp_reader`, so the port is surgery, not
  a copy; and our netlist is fuller).
- **Subtitles under Letterbox / Crop:** the plane is composited in raster space. Since the
  HPS writes the plane, it can place or scale the subtitle for the mode in software, with no
  fabric cost.

**Measured (2026-10-01, `feature/480i`, `docs/analog.md`):** A7's fit was 37,163; 480i with field order
(S1) **+397** (37,560); Analog Aspect (S2) **+52** (37,612, 90 %; DSP 86) -- the reader's existing three-line
window and an even / odd split of its line buffers took the place of DVD's separate scalers and FIFOs.
Against the table below: 480i + Analog Aspect cost ~0.45K, not 0.85-1.4K, so the G1 cap is computed from
**37,612** (6 of 6 seeds pass at it, the worst corner 88.53 MHz).

**The sum** (every figure an estimate except today's fit and DVD's measurement; calibrated
ranges as `p6c.md` §2):

| | ALM | running total |
|---|---|---|
| today (P7, SEED 3) | 40,875 | 40,875 (98 %) |
| A7: the subtitle decode to the HPS, net of its host port (`hps_host.md` §3.1) | -2.2K to -2.6K | 38.3-38.7K (91-92 %) |
| 480i + csync + field selection (the fork's measurement) | +0.3K to +0.6K | 38.6-39.3K |
| Analog Aspect: Auto / Letterbox / Fit / Crop (DVD's measurement) | +0.55K to +0.8K | 39.2-40.1K (93-96 %) |
| P9's host-port rows (buttons, commands, events, `ui`) + the PCM one-shot (`menus.md` §4) | +0.45K to +1.0K | **39.6-41.1K (95-98 %)** |
| Go To in fabric (`p6c.md` §2.1, calibrated) | +0.75K to +1.9K | **40.4-43.0K (96-103 %)** |

DSP: ~84 today, -3 (A7) +2 (480i) +6 (Analog Aspect) = ~89 of 112. M10K is not scarce (A7
frees ~50).

**What that says:**
- **480i, Analog Aspect and the Main-side logic fit together:** 39.6-41.1K, 95-98 %. The high
  end is today's fill, where clk_dec's margin is a seed lottery (§7).
- **Go To on top fits only at the low end of every estimate** (~40.4K, 96 %). At the
  midpoint (~41.7K, 99.5 %) it does not close timing, and at the high end it is past the
  device.
- **Fill cuts both ways.** At 97-98 % the fitter spent ~1,300 ALM on ~150 registers (§7). A7
  may free more than its per-entity numbers, or a full core may pay more than unit costs.

**The order, ✅ ACCEPTED by the maintainer (2026-09-30)** (each step measured before the next is
planned):
1. **A7**: its fit measures what it really freed.
2. **480i, with Analog Aspect** (one display stage; DVD and the fork as the harvest).
3. **Go To designed to a cap** (as P6b5's HUD was, which landed inside its 800): the cap is
   what the fit after step 2 leaves, minus a reserve for P9's rows (~0.5-1.0K). If the cap is
   below a usable Go To (~0.75K), Go To is dropped (G1), unless a lever below is taken for it.
4. **P9's rows** when P9 starts.

**Levers still in hand, if the sum comes out high:**
- the H264 fork's zero-cycle retimes: timing margin at high fill, not area (A9);
- `xmb_wave` as a flat fill: 234;
- the reader's trims: 100-200, invasive;
- instrumentation as a build option, ~1.2K: held in reserve, against A8. **That is the one
  lever big enough to buy Go To outright.**

## 10. Where the engine pattern fits (2026-10-06 survey, nothing built)

**Status:** analysis only. No branch of RTL, no fit; every saving below is an **estimate** unless
it says "measured". Source: the fit of `main` at PR fj#48 (`UMD_bare_20261005_1945.rbf`, SEED 5,
`output_files/UMD.fit.rpt` §20): **39,127 / 41,910 ALM (93 %), 438 / 553 M10K (115 free), 88 / 112
DSP**; `emu` 32,589, the framework outside it 6,537.

**The question.** MiSTer_DVD moved DTS, its AC-3 parse and MP2 onto one microcoded engine (its PRs
#148-#150; its `docs/ac3_engine.md`, `mp2_engine.md`, `logic_reclaim.md` §10), and the engine's
pattern was this core's ATRAC3plus decoder (`at3p_seq` + `at3p_vec`, `tools/at3p_isa.py`,
`docs/at3p_decoder.md` §3.4). Measured there: MP2's move −825 ALM by entity; the AC-3 parse +688 ALM
on the engine against −2,687 hardwired. Where else in this core does the same move pay? DVD's survey
named three conditions the replaced logic met, used here unchanged:
1. **Rate:** at most a few hundred thousand operations per unit of work, so ~1 operation a cycle keeps up.
2. **Shape:** the area is control -- next-state and register-write muxes across mutually exclusive
   states. This core has its own measurement of that cost (CLAUDE.md, P8: a sniff plus one setup
   state was +907 LUTs in `umd_reader`).
3. **Exclusivity:** the jobs never run at once, so they can share one datapath.

**Three things DVD did not face:**
- **clk_dec.** Every `umd/h264/*` control block runs on clk_dec at >= 86 MHz with thin margin.
  `at3p_seq` closes 40.1 MHz cold on the 27 MHz clock (`at3p_decoder.md`). A sequencer on clk_dec
  is a new, deeper-pipelined design, not a second `at3p_seq`; the alternative, control on clk_sys,
  puts a crossing between it and the tables the macroblock pipeline reads. Open for §10c / §10d.
- **The fork.** MiSTer_h264_decoder owns a copy of `umd/h264/*`, fixes ported by hand both ways
  (`harvest.md`). A microcoded rewrite of any of it is a permanent divergence unless both trees
  take it, and the fork runs Level 3.1 at ~1 % throughput margin.
- **Less pressure.** DVD did this to fit DTS. Here the stock-Main rule already moved the large
  discretionary features to the HPS (§8), the device is at 93 %, and no DTS-sized fabric feature
  is pending. The value is headroom under 95 % (§2, A2': a sweep per netlist change above it) and a
  cheaper change path for navigation fixes. **M10K does not bind** (115 free; DVD had 34), so a
  program ROM costs little.

**Where the area is (`emu`, own ALM unless "tree"):**

| class | entities (ALM) | candidate? |
|---|---|---|
| clk_sys, event rate | `umd_reader` 3,749 (one module, 62 states) · `player_ctl` 1,406 · `goto_ctl` 503 · `disp_ctl` 686 + `disp_sched` 284 · `umd_host` 629 · `umd_telem` 283 | §10a, §10b |
| clk_dec, per NAL | `sps_pps` 846 · `slice_hdr` 334 · `sei_pt` 263 | §10c |
| clk_dec, per slice / picture | `recon_dpb` 2,038 · `recon_lists` 855 · `recon_hdr` 823 · `recon_slice_tab` 363 (tree 417) | §10d |
| clk_dec, per bin / MB / pixel | `mb_syntax` 1,851 · `recon_mb` tree 6,945 · `mb_intake` 444 | no (§10e) |
| pixel / byte rate | `disp_reader` 1,068 · `sub_overlay` tree 1,634 · `transport_hud` 1,058 · `vbuf` 373 · `ddr_mux2` 255 · `xmb_wave` 235 · `pcm_shot` 167 | no (§10e) |
| already an engine | `at3p_top` tree 2,055 (`at3p_seq` 778, `at3p_vec` 1,258) | the template |

### 10a. The reader's parse onto a navigation engine (★ first candidate)

`umd_reader` is **3,749 ALM, 20 M10K, on clk_sys** -- the largest single control module in the core,
and every navigation feature has grown it (P6b2's navigation port ~+1.4K, `transport.md` §7; P8's
sniff +252 after trimming from +907 LUTs, `bare_streams.md` §3). About ten of its 62 states move
or stream sectors (`S_IDLE`, `S_INIT`, `S_SECREAD`, `S_LOAD`, `S_STREAM`, `S_DRAIN`, `S_MPS`,
`S_MPS_NEXT`, `S_DONE`, `S_ERROR`); the other ~50 parse PARAM.SFO, PLAYLIST.UMD, the CLPs, the EP
maps' binary searches, the marks, the item walks, seeks, Go To by time and the P8 sniff -- `S_FETCH`
(the shadow fetch that feeds the parse's taps) and `S_OOB` (a parse refusal) among them. That split is by state name, not by area: **unmeasured**.

- **The conditions.** Rate: a mount, an item start, a seek or a query (Go To's ~2 ms a step,
  `goto_ctl.sv`). Shape: the P8 lesson above. Exclusivity: one navigation command at a time
  (`nav_ready`), and the walk never runs beside one.
- **The clock is the engine's.** clk_sys is where `at3p_seq`'s design is proven, so the sequencer,
  the assembler and the trace-equal emulator (`tools/at3p_isa.py`) carry over nearly as they are,
  less the Huffman unit and the vector ops, plus a byte load from `parse_buf`'s read port. ⚠ The
  datapath is the design question: `at3p_seq` is 16 x 16-bit registers; the reader handles 33-bit
  PTS, u32 offsets and LBAs and 64-bit duration sums (`dur_sat`). Multi-word operations cost cycles
  (free at this rate); a wider register file costs ALMs.
- **⛔ Not the ATRAC3plus engine's silicon.** It is 63 % busy on the worst frame (`at3p_decoder.md`),
  and item starts and seeks happen during playback. The method is shared, not the hardware (DVD's
  §10b reached the same verdict for its audio engine).
- **Stays hardwired:** the sd_* request handshake, the `parse_buf` write, the 16 KB stream cache
  and its output pipe, the stream sector pump.
- **The gate survives the move.** `run_umd_reader.sh` scores verdicts -- the walk's sectors, the
  first 64 packs, every navigation answer against the P1 parsers and `tools/umd_nav_ref.py` -- not
  a cycle trace (DVD's reader gate was cycle-identical, and that was a cost there). A Python
  emulator of the program could be scored against `umd_nav_ref` over the whole library before any
  RTL runs.
- **Estimate:** first guessed at −1,000 … −1,800 ALM (two thirds of the module parse). **Measured
  2026-10-06 (`nav_engine.md` §3): the pump alone is 297 of the reader's 6,098 LUTs, so the parse is ~95 %;
  the estimate becomes −2.0 … −2.7K ALM** net of the engine and the output registers, +2-4 M10K for the
  program.
- **What it buys beyond area:** the open parse-side items -- resume per disc (`feature/resume`,
  design only), seek on a bare file (`bare_streams.md` §5), a reader defect from a bug bundle
  (`bug_reports.md`) -- become program words, not next-state muxes.
- **✅ Done (2026-10-06, `nav_engine.md` §3), was the first step:** attribute the module's area to the
  pump and the parse with `tools/synth_unit.sh` on a wrapper exposing only the outputs `emu`
  connects (the P8 method, `bare_streams.md` §3), splitting the module if attribution needs it.
  That number decides whether §10a is worth a branch.

### 10b. The transport cluster (clk_sys)

`player_ctl` 1,406 · `goto_ctl` 503 · `disp_ctl` 686 (+ `disp_sched` 284) · `transport_hud` 1,058.

- **Resource sharing (DVD's §10c) is mostly done already.** `transport_hud` draws every number with
  ONE shared subtractor (digits by repeated subtraction, the bar's and the marker's quotients by
  restoring division); `goto_ctl` turns ticks into h:m:s by repeated subtraction (<= 1,117 cycles);
  `disp_ctl` has a restoring divide for Table E-6 durations. Pooling these across modules would save
  the duplicate subtractors only: est. −100 … −300, and the HUD's is pixel-timed. Not worth a branch.
- **Routines on §10a's engine, after §10a.** `player_ctl` is a command interpreter (15 stable codes,
  a Python golden `tools/player_ctl_ref.py`) whose seek sequence already waits on the reader's
  navigation port, and `goto_ctl` issues one NAV_CHAP a step and waits: both are serial with the
  reader by construction. But `player_ctl` also runs concurrent sub-machines (the press gesture,
  the seek sequence, trick play's timed hops, the exits) and answers display events within cycles,
  so one sequencer needs a scheduling rule, as DVD found for its VM.
- **Stays hardwired:** the HUD's pixel side; `disp_ctl` / `disp_sched`, the display's timeline
  (rules A / B, the skip, `display.md` §10-§11) -- the hardest-won timing in the core.
- `umd_host` / `umd_telem` are register windows on EXT_BUS, not control: not this pattern.

### 10c. The H.264 front end's header parsers (clk_dec)

`sps_pps` 846 · `slice_hdr` 334 · `sei_pt` 263 = **1,443 ALM** (`rbsp_reader`, 129, is already shared).

- **The closest analog of DVD's AC-3 parse.** Fields read in syntax order and emitted as
  `K_HDR_WORD`s; `sps_pps.sv`'s header says each field is "one generic request/response/emit round
  (S_REQ / S_WAIT / S_EMIT with a return state)" -- a hand-written microprogram in FSM form, 66 and
  69 states. Rate: per NAL unit (the front end parsed whole titles at 8-9.5x real time on the rig).
  Exclusive: one NAL unit at a time.
- **The best gate of any candidate:** `run_h264_top.sh` scores the whole record list against
  `tools/h264_fe_ref.py`, trace-exact, so a move is proven field for field.
- **Against:** clk_dec and the fork (above); and an engine's fixed cost eats most of 1,443 if it hosts
  only this. Est. −300 … −600 net as a general engine. A cheaper middle: a descriptor ROM (kind
  ue / se / u(n), field id, range check) driving the existing REQ / WAIT / EMIT round, the
  conditional structure left in the FSM. **Low priority.**

### 10d. The reconstruction's per-slice control (clk_dec)

`recon_dpb` 2,038 · `recon_lists` 855 · `recon_hdr` 823 · `recon_slice_tab` 417 (tree) = **4,133 ALM**,
26 M10K, 3 DSP: the largest H.264 pool that fits the shape.

- **For:** a strict handoff -- `recon_hdr` -> `recon_dpb` (marking, the picture open, POC, the output
  bumps) -> `recon_lists` -> `recon_slice_tab` -> `mb_slice_go` -- so exclusive by construction; each
  stage already SCANS one store a cycle (the parallel versions cost ~5,000 and 8,100 LUTs,
  `h264_recon.md` §6); `recon_dpb` alone is 43 states with its own serial divide and multiply for POC
  type 1. On UMD discs it is nearly free in time: one slice a picture, two references, no MMCO
  (`umd_video_format.md`), against ~2M cycles a picture.
- **Against, more than §10c:**
  - **The setup is in series with decoding.** A new picture waits for `pipe_idle`, and `recon_top`'s
    `R_TAB_WAIT` holds `mb_slice_go` until the tables are built. At the spec maximum a Main Level 3.0
    frame may carry **~61 slices** (A.3.3 b), SliceRate 22 in Table A-4: 40,500 x 1/30 / 22), the fork's
    Level 3.1 ~60 at ~1 % margin. A sequencer slower than today's scans multiplies a series term.
    **Unmeasured: the cycles a slice spends in setup today** (the cosim can count them).
  - clk_dec and the fork (above). The tables the macroblock pipeline reads (`recon_slice_tab`'s code
    / POC RAMs, `recon_dpb`'s store table) are already RAMs, so dual-clock M10Ks could carry a
    clk_sys engine: plausible, unexamined.
  - `recon_dpb`'s picture open has bound clk_dec since P6b3i: a rewrite there moves the timing wall.
- **Estimate:** −1,500 … −2,500 if the engine's scratch RAM takes the 20 stores' state now held in
  registers for parallel reads (a guess). The largest H.264 payoff, the largest risk.

### 10e. Not candidates

- **`mb_syntax`** (1,851): CABAC, every bin pays its context derivation (0.16-0.26 bins a cycle);
  condition 1 fails.
- **The macroblock pipeline** (`recon_mb` and its stages, `mb_intake`): per MB and per partition, under
  the throughput doctrine (`roadmap.md`); `mv_pred` has been the binding path.
- **Pixel and byte rate:** the display, the compositor, `vbuf`, `aud_ring`, `ddr_mux2`, `pcm_shot`,
  `xmb_wave`.
- **`at3p_top`:** already the engine; its silicon is not shared (§10a).
- **`sys/`** (6,537 outside `emu`): the framework, edited only as marked.

### 10f. The other direction: HPS features back into the fabric

The stock-Main rule (§8, A5) let three features leave the fabric; a stock-Main user loses them.
Could an engine make any of them cheap enough to come back? (Asked by the maintainer, 2026-10-06.)

**Subtitle decode (A7, on the HPS since PR fj#34-fj#35) -- the only real candidate.** It left as
`sub_png` 2,225 ALM / 47 M10K + `sub_plane_wr` 209 / 2 (§8, "A7 in numbers").
- **Why it fits.** PNG is inflate (canonical Huffman codes -- the walk `at3p_seq` already does in
  hardware: `code - first < count`), then a per-byte unfilter and a pixel conversion. The split is
  the ATRAC3plus decoder's own: a sequencer for the Huffman and the block structure, hardwired
  "vector" ops for the byte-rate parts (an LZ77 match copy, a row's unfilter, a palette expansion
  into the plane). Rate: one unit per subtitle change.
- **The time it must meet** (`hps_host.md` §6): a unit is in the ring 0.57-1.0 s before its PTS, and
  consecutive PTS come as close as 0.1 s (The Mummy), hence the HPS path's 50 ms budget. The
  hardwired decoder ran 4.4-4.6 cycles an inflated byte (`png_decode.md`); an engine with a sequenced
  literal path is perhaps 2-4x that (a guess: two cycles a code bit plus the op). On clk_sys, a
  spec-maximum unit (720 x 480 RGBA, 1.38 MB inflated) at ~10-15 cycles a byte takes 0.5-0.8 s, at or
  past the lead: **the spec maximum is not met in time** unless the literal path is hardwired too.
  (The hardwired decoder took that case in ~0.22 s.) The library's largest unit inflates to 105,750
  bytes (17 ms on the hardwired decoder, `png_decode.md` "Throughput"): ~40-60 ms on an engine, inside
  the lead and under the 0.1 s step. **Unmeasured:** each unit's inflated size against its lead and
  its successor's gap, over the library (`run_png.sh --sweep` already decodes every unit; it would
  need to report the pair), and the spec-maximum case's verdict (late, counted) designed in.
- **Not the ATRAC3plus engine's silicon** (subtitles decode during playback, beside the audio).
  **§10a's engine, if built, is mostly idle during playback** (item starts, seeks, Go To queries),
  and a seek flushes the units pending in the ring anyway (the track stays on); one engine for both needs a rule for an item start or a
  query arriving mid-decode (wait up to a decode, ~50 ms on the library, or preempt). Two instances of one design
  is the safe form.
- **Estimate (a guess):** an engine + Huffman unit + the copy / unfilter ops ~1.2-1.8K ALM, plus the
  32 KB LZ77 window (~16 M10K, which do not bind) and the plane writer back (209): **+1.4-2.0K ALM net
  against today**, ~0.4-1.0K less than A7 freed. That is about what §10a might free, so the trade
  §10a opens is "subtitles on a stock Main for roughly the reader's saving". The maintainer's call:
  A7 was taken for area (A10), and the stock-Main rule lets subtitles be an HPS feature. The HPS path
  stays either way for the UMD Main (it also owns the plane for the panel and the menus).

**What A10 cut rather than hosted: A-B / Repeat, slow motion, frame advance** (P6c, `p6c.md` §9).
(**2026-10-07: A-B alone taken, hardwired as `umd/ab_ctl.sv` beside `goto_ctl` -- §10b is not
built; `docs/ab_repeat.md`.**) They are on neither side today. On §10a's engine, A-B / Repeat is a `player_ctl` routine -- at B, a
seek back to A, gated by `umd_nav_ref` -- the cheapest thing the pattern could add for a stock-Main
user. Slow motion and frame advance also need display hooks that `disp_ctl` would still own (a
held STC stepping a picture at a time), so they stay hardware work whatever hosts the decision.

**The △ panel (P6d) -- weak.** Its fabric estimate was 0.45-1.0K ALM calibrated (`panel.md`, the
2026-10-04 entry), most of it drawing: the art (icons, the HUD-tinted box) and a pixel-rate overlay.
An engine would take its item navigation, not its pixels. Every action already has a button (D10);
the panel only helps a user find them. Not worth its area on a stock Main.
- A broader idea, **not estimated**: an engine-written text / tile layer read by one generic renderer
  could carry the transport HUD, Go To's editor, the messages and a panel together, turning layout
  logic into program words. The HUD is 1,058 ALM, pixel-exact against `transport_layout.py` in 31
  states and recently HW-confirmed: a rewrite with a weak payoff unless a panel or more HUD were
  wanted in fabric.

**The disc menus (P9) -- no.** VSMX is a script language (objects, strings, floats, tweens, a 3-D
scene) over a renderer that composites RCO PNGs and JPEGs with alpha, ~4K lines of C. That needs a
general CPU, not a fixed program: the fabric host was a RISC-V soft CPU at ~2.5-4K ALM and 20-70 M10K
beyond the contract (`menus.md` §5, host A), out by arithmetic. Even on the A9 the renderer needed
damage tracking to reach 33 frames a second (`p9.md` M4d).

### 10g. Suggested order

1. **Measure §10a** (the pump / parse split): it alone decides whether the pattern pays here.
2. **If it does: a navigation engine on clk_sys**, forked from `at3p_seq` and `tools/at3p_isa.py`.
   Pilot on the navigation port (NAV_SEEK / CHAP / PLAY / TIME: the binary searches and item walks
   with `umd_nav_ref` as the golden), where the reader has grown most; the mount walk follows.
3. **§10b** only on top of §10a.
4. **§10c / §10d** only when a fabric feature needs the room, with the fork's agreement and a clk_dec
   sequencer design; measure the setup cycles a slice first.
5. **§10f's subtitles** only if §10a frees the room and the maintainer wants them on a stock Main;
   measure each unit's inflated size against its lead first. A-B / Repeat comes almost free with
   §10b's routines, if wanted.
