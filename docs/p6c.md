# P6c — Go To, A-B / Repeat, frame advance and slow motion

**Status (2026-10-11): Go To ✅ MERGED (PR fj#41, 2026-10-04), ✅ HW-CONFIRMED, in fabric (§9-§10); A-B Repeat built
separately (`ab_repeat.md`, PR fj#63); slow motion, frame advance and chapter / title repeat dropped.** The history:
📐 planned 2026-09-30. RE-SCOPED 2026-09-30: an HPS feature on host B
(`area_plan.md` §8 A6; §8 below); then CUT TO GO TO, on the core if A7 frees the room (§9, G1).
G1 DECIDED 2026-10-03: Go To in fabric, in the room the diagnostic HUD's removal makes (A11, §9).** §1-§5 are the fabric plan it replaces, kept for the
behaviour, the constraints and the gates, which still hold; their ALM costs do not. D15 / D16 were measured
on the maintainer's PSP (2026-10-03, §6); D12-D14 / D17 went with the dropped features.
Planned on `feature/p6c`, ✅ MERGED (PR fj#27). Roadmap: Phase 6. Behind it: `transport.md` (P6b, whose
§8 D10 dropped the pop-up panel and gave each of these features a button, the D-pad or a key)
and `transport_hud.md` (the PSP reference; §1 and §3 describe Go To's editor).

**Scope (D10, the maintainer 2026-09-29).** P6c builds the features the panel would have
carried, with no panel:

- **Go To**: a chapter selector and a time editor, a blue ▼ on the bar at the target, × to
  confirm, the landing exact (D2).
- ~~**A-B / Repeat**: one Repeat button stepping off → set A → set B (A-B) → chapter → title →
  off.~~ **Dropped for now** (the maintainer, 2026-09-30, `hps_host.md` H8). §2.2, D17 and the
  A-B rig gate stay as the record, not the plan; the Repeat button stays inert.
- **Frame advance and slow motion** while paused.

The J1 buttons (Go To, Repeat) and the keys (G / F2, L, `.`) exist since P6b6, inert.

## 1. The area: P6c's budget is P7's budget too

`transport.md` §7 required this budget to be planned with the maintainer before P6c starts.
The last fit leaves **39 ALM** under P6's 35K checkpoint. The bigger fact is P7's measurement:

| | ALM | of 41,910 |
|---|---|---|
| now (`UMD_loneearly_20260930_0446.rbf`) | 34,961 | 83 % |
| + P6c, calibrated (§2: 1.3-2.5K) | 36.3-37.5K | 87-89 % |
| + P7's `sub_overlay`, **measured** in a unit fit (`feature/p7-png`, `compositor.md` §7) | +4,744 | |
| **= P6c then P7** | **41.0-42.2K** | **98-101 %** |
| P7 without P6c | 39.7K | 95 % |
| the roadmap's P7 checkpoint | 37.5K | 89 % |

- **P7 alone overruns its 37.5K checkpoint by ~2.2K.** The roadmap planned "+~2-3K" for it.
  The unit fit came in near 4.7K (the PNG decoder with its 32 KB window, the subtitle chain,
  the compositor), and it is not yet placed inside the core.
- **P6c then P7 does not fit.** At 91 % the P4 front end fell from 92 to 84 MHz; clk_dec
  closes today at 87.29 / 87.86 MHz against an 86 MHz floor.
- **P9's contract (host B, the HPS engine) adds ~1.1-1.6K on top** (`menus.md` §4-5).

So area must be found before P7 whatever P6c does. **Followed up in `area_plan.md` (2026-09-30):** the
framework switches measured -551 and were declined (A1), P7's checkpoint is a seed-sweep rule
(A2), P7's own trims come first (A3), host B is the project's Main fork, upstream not asked (A4). **The levers, measured on the last fit**
(`output_files/UMD.fit.rpt`, "Fitter Resource Utilization by Entity"):

| lever | gives back | what it costs |
|---|---|---|
| **ISO handling to the HPS**, the recorded contingency (roadmap "Resource checkpoints", the user's decision 2026-09-24) | `umd_reader` 3,319 ALM + its 16 M10K cache, less the intake that replaces it (estimated, not measured) | **Playback would then need the project's Main fork in place of stock Main** (`area_plan.md` §3, A4: decided at P9; upstream not asked). A helper beside Main hands the core the stream. The navigation moves with it: IN / OUT, `NAV_SEEK`, `NAV_CHAP` and the §2.1 time lookup. `run_umd_reader.sh`'s gate becomes a host-side test. The largest single piece of work here |
| **Instrumentation as a build option** (a release build without it) | up to ~1.2K: `p2_diag` 392, `umd_telem` 287, the `cdc_snap`s ~225, the `ddr_probe`s 171, `es_probe` 120, `diag_hud` 21 (which of them only instruments feed is to be checked) | **The release build is then not the build the HIL gates tested.** The Diagnostics OSD option and the telemetry are gone from users' cores, and a field report loses its HUD. It changes the verification discipline: the maintainer's call |
| `xmb_wave` (the idle screen's wave) as a flat fill | 234 | the look of the idle screen |
| the reader's trims (`transport.md` §7) | 53 measured; sharing the walk's registers with the navigation's ~100-200 (estimated), invasive | nothing visible |
| P7: a 1:1 subtitle plane (no bilinear filter) | 12 DSP; the ALMs unmeasured | `compositor.md` §7 offers it as a parameter; P9's scaled menu plane still needs the filter |

**Timing:** clk_dec's worst corner has ~1.3 MHz of margin. P6c is all on clk_sys (27 MHz,
wide margin), and the reader's time lookup (§2.1) is on the reader's clock. What P6c
threatens is clk_dec through crowding, not its own paths.

## 2. The features, and what each costs

**The calibration.** P6b's estimates ran low wherever the state was spec-width registers
(32-bit items, 48-bit PTS):

- P6b2 came in at ~2x its range.
- Trick play was planned at 200-400; `player_ctl` went 347 → 962 (1,104 as placed today).
- P6b7 came in at ~2x.
- Only P6b5's HUD, which was designed to a cap (800), landed inside it (776).

Each raw range below is multiplied by 1.5-2 for the calibrated one, and **each feature
should be designed to a cap**, as the HUD was.

### 2.1 Go To

**The behaviour** (`transport_hud.md` §3, `transport.md` §8 "Found with the answers"):

- The Go To button opens two boxes above the bar: `Chapter n`, then the time `hh:mm:ss`. A
  title without chapters shows only the time.
- ← / → move between the boxes and, inside the time box, between its fields. ▲ / ▼ step a
  value.
- A blue ▼ above the bar marks the target. × (Pause, Enter) confirms. The Go To button
  again, or Stop, cancels (**proposed**, D16).

**Where it lives:**

- **The editor** is a small state machine: the box, the field, a chapter number (u16), and
  h / m / s. It sits in `player_ctl` or in its own `goto_ctl` beside it. Its exit is the
  existing `SEEK` command (7, `cmd_item` / `cmd_pts`), which already lands exactly (D2).
- **The chapter selector** steps ±1 inside `[1, n_chapters]`. Each step runs one `NAV_CHAP`
  from the candidate chapter's key; its `ch_next` / `ch_prev` give the next step's key and
  the marker's position.
- **The time target needs a new reader operation, `NAV_TIME`** (`nav_op` 3, free). It maps
  the title's time to (item, PTS) by walking the items and summing `OUT - IN`. The seek's
  item walk already accumulates `base_acc` / `base_sum` (`umd_reader.sv` ~1572), so the op
  reuses that walk. Items are u32 (spec maximum): **Go To by time is never restricted to the
  playing item.**
- **The marker's position** is the target's title time over the playlist's duration. For a
  time target it is the typed time. For a chapter in **another item** it needs that item's
  `item_base`, which only the walk knows. Either `NAV_CHAP` returns it (a walk per step, on
  the 3 multi-item titles only) or the marker is placed approximately there (D15).
- **The HUD:**
  - the two boxes, the lighter field being edited, ▲ / ▼, and the ▼ marker;
  - the time box reuses the overlay's `hh:mm:ss` path, with the target in place of the
    elapsed time;
  - hours up to 999, as the overlay shows (`spec_hardening.md`'s HUD row): a target past
    999:59:59 cannot be typed (a deviation row, D16).

**Cost:** the editor 250-400 raw, `NAV_TIME` 100-250, the HUD 150-300; **500-950 raw,
0.75-1.9K calibrated**. It is the largest of the three features.

### 2.2 A-B / Repeat

**Superseded (2026-10-07): A-B alone is planned in `docs/ab_repeat.md`** (in fabric, beside
`goto_ctl`; chapter and title repeat stay dropped). This section is the record of the old cycle.

**The cycle** (D10): off → set A (at the shown key) → set B (A-B repeats) → chapter →
title → off. The exact order and what the HUD shows at each step are D17.

- **A and B are keys, (item, PTS)**, compared the way the chapter tracker compares (`reached`
  in `player_ctl.sv`: the item first, then the PTS). A PTS alone is wrong on a multi-item
  title.
- **A-B:** when the shown key reaches B, seek to A.
- **Chapter:** the tracker's `reached` (the next chapter's key) becomes a seek to the current
  chapter's start, `ch_cur`, instead of a chapter change.
- **Title:** at `ended` (the title's END, or OUT on its last item), seek to the title's start
  (item 0, PTS 0, clamped to IN by the reader).
- **Every repeat is a seek** (the whole discontinuity: freeze, flush, exact landing). The
  PSP's repeat point will not be seamless either; how long its gap is, is to measure.
- **Seeks and the repeat.** A chapter press or Go To inside A-B keeps the loop or cancels it
  (**proposed: it cancels A-B**; chapter and title repeat stay on). Trick play suspends it.
- **The HUD:** a tag bottom-left, `A-`, `A-B`, `Repeat Chapter`, `Repeat Title`, `Repeat
  Off`, beside the play-state glyph (`transport_hud.md` §1); an icon or two from the spare
  glyphs (§3).

**Cost:** `player_ctl` 150-300 raw (two 65-bit keys and their compare), the HUD 40-80;
**190-380 raw, 300-600 calibrated**.

### 2.3 Frame advance and slow motion

**Frame advance** (while paused): release the display's freeze until the next pickup (a new
store on screen), then freeze again.

- On a 3:2 film one refresh does not always show a new picture, so "until the next pickup" is
  the rule, not "one refresh".
- A field-coded title has two choices: a pair, or one field a press. D14.
- **The audio stays silent.** `aud_out` freezes on `disp_ctl`'s `frz`, so an unfrozen refresh
  would play one refresh of sound.

**Slow motion** (while paused, ↑ / ↓): the STC counts a fraction of its ticks (the 90 kHz
tick gated to 1/2, 1/4, ..., D13) in `disp_ctl`. The scheduler then holds each picture
longer by its own rule.

- **The audio chain is held in reset**, as trick play holds it (`aud_rst`), since the sound
  cannot play at a fraction of its rate here.
- **Leaving it is a seek to the shown key**, as leaving trick play is (exact, D2). The audio
  starts again in step.
- **The instruments.** `n_cadence` (a store held outside {floor, ceil} of its duration) and
  `n_late` would count every slowed picture, and the HUD's P5 row would read as a fault.
  They are gated while slow or stepping. P6b3i's pause bug (`err_no_store` counted ~8 a
  second while paused) is the precedent.
- `rig_gates.py` scores errors, `av_err` and the landing, not the cadence counters; the
  cadence counters stay in the HUD and telemetry.

**Cost:** `player_ctl` 100-200 raw, `disp_ctl` 30-60, the HUD 30-60 (two icons);
**160-320 raw, 250-500 calibrated**.

**Total: 850-1,650 raw; 1.3-2.5K calibrated** (the figure §1 uses).

## 3. Constraints the code already imposes

- **→ while paused conflicts.** D10's table says it is frame advance. `player_ctl` (P6b4,
  ✅ HW-CONFIRMED) enters FF "from play or pause". Taking D10 changes a shipped behaviour and
  the manual's controls page (D12). The keyboard's `.` (Frame Step) is free either way.
- **↑ / ↓ are free**: nothing reads the D-pad's Up / Down today (`emu.sv`, only
  `joystick_0[1:0]`). During Go To they edit, and while paused they give slow motion (D10).
  Their press edges are gated with the OSD open, as ← / → are.
- **The glyphs: 11 spare** (117-127 of the 128, `transport_hud.md` §6.1). Go To needs ▲ ▼ and
  the marker ▼ (1-3). Slow motion and frame advance need two cells each (4). A-B and Repeat
  can be text, or 2-4 cells. **It fits in 7 bits only if the repeat marks are text.** An
  8-bit index doubles the font ROM (6 → 12 M10K; M10K is not scarce: 419 of 553).
- **Keys are (item, PTS)** for A, B and Go To's chapter targets; the marks carry a u16 item
  (`ch_cur` = {item u16, pts u48}).
- **`NAV_TIME` and the spec maximum:** items u32, the sum of `OUT - IN` saturating (as
  `item_base` does). A target past the title's end clamps to the last item's `OUT - 4`, as
  the seek clamp does (D16; `OUT - 1` until `fix/skip-last-picture`, `display.md` §11).
- **The event FIFO and the HUD's captions:** Go To's cancel / confirm, a repeat's loop and
  each repeat mode post an event (new codes 9-12), counted when lost, as today.

## 4. The stages

Each stage has a bench that goes RED and an independent oracle, as P6b's did.

| stage | what | oracle / bench |
|---|---|---|
| **P6c0** | The PSP measurements (§6's list); the HUD mockups (`tools/transport_layout.py`: Go To's two boxes and marker, the repeat tags, the slow / step glyphs), approved before any RTL | the maintainer's PSP; the mockups rendered on rig screenshots, as P6b5's were |
| **P6c1** | The models: `umd_nav_ref.py` gains the time lookup, `player_ctl_ref.py` gains Go To, the repeat decisions, step and slow | `test_umd_nav_ref.py` / `test_player_ctl_ref.py` + RED arms; the time lookup vs the P1 tools' playlists on every disc image |
| **P6c2** | The reader's `NAV_TIME` | `run_umd_reader.sh --red`: a seeded time script on every disc image, the synthetic multi-item and saturating edges |
| **P6c3** | `player_ctl`: Go To, repeat, step / slow | `run_player_ctl.sh --red`: the decisions vs the model (the A-B loop, chapter repeat at the last chapter, title repeat at OUT, Go To across items) |
| **P6c4** | The display and the audio: step, slow, the instruments gated | `run_disp_sched.sh` scenarios vs `disp_sched_ref.py` (a step shows exactly one new pickup; slow holds each store n times its duration); `run_av_sync.sh`: silent while slow, in step within a frame after leaving |
| **P6c5** | The HUD | `run_transport_hud.sh --red`: the new states pixel-exact vs the model |
| **P6c6** | The buttons and keys (Go To, Repeat, ↑ / ↓, `.`), the manual (`controls.md`, `on-screen-messages.md`, `troubleshooting.md`), the fit, the rig gates (§5) | `docs_check.py`, `mkdocs build --strict`, `check_emu_wiring.py`; the rig |

## 5. The rig gates

- **Go To.** Ten time targets on Akira, and three across My Chemical Romance's items: each
  lands on the target's picture (the telemetry's landing vs the model), errors 0.
  **Random-time seeks** were planned in `transport.md` §6 and waited for Go To; they are
  run here.
- **Chapter Go To.** ±1 steps to the first and last chapters, and every chapter of one disc,
  each landing on its mark.
- **A-B.** A 10 s loop run 5 times: each loop lands on A, `av_err` in step after each one.
  Chapter repeat at the last chapter, and title repeat at Hackers' OUT (not at the clip's
  end).
- **Frame advance.** Ten presses on a film and ten on Family Guy's fields: one new picture
  (or field, D14) each, no sound.
- **Slow motion.** Each rate for 10 s: the clock's rate within 5 %, silent, and play resumes
  in step.

## 6. Decisions for the maintainer

| # | question | options / proposal |
|---|---|---|
| **D11** | **The area path** (§1): P6c then P7 does not fit the device | **DECIDED (the maintainer, 2026-09-30): (d) P7 first, P6c after.** Instrumentation as a build option: decided later, only if the other levers fall short. Offered: (a) find the area first (ISO to the HPS, and/or instrumentation as a build option), then P6c whole; (b) P6c whole now against a raised ceiling (~37.5K), P7's overrun solved when P7 starts; (c) a reduced P6c now (which of §2.1-§2.3), the rest after P7; (d) P7 first, P6c after. **Proposed: (a) with ISO-to-HPS decided now**: P7 needs it anyway, and it frees ~3K for P6c, P7 and P9's contract together |
| **D12** | → while paused: FF (as built, P6b4) or frame advance (D10's table)? | measure on the PSP; if frame advance, the manual's controls page changes |
| **D13** | Slow motion: which rates, how many steps, does ↑ speed it up or step it back to pause, and how does it end | measure on the PSP |
| **D14** | Frame advance on a field-coded title: a field or a pair each press? | measure on the PSP |
| **D15** | Go To on a multi-item title: the title's time (proposed, `NAV_TIME`) or the item's? The ▼ for a chapter in another item: exact (a walk per step) or approximate? | **MEASURED (the maintainer's PSP, My Chemical Romance disc 2, 2026-10-03): the PLAYING PLAYLIST's time** -- a video picked from the menu shows its own length from 0:00:00, Play All a 2-hour timeline with each video a chapter. So `NAV_TIME` maps the playing playlist's time (what the core plays, a menu's NAV_PLAY included). **The marker:** exact for a time target and for a chapter in the item now streaming; for a chapter in another item it is HIDDEN (its place needs an item walk per step: a measured follow-up if wanted, not built against the cap) |
| **D16** | Go To past the title's end; a target past 999:59:59; how Go To is cancelled | **MEASURED (2026-10-03): past the end it acts as if playback COMPLETED** (the PSP returned to the disc's menu): the target clamps to the last item's `OUT - 4` (`OUT - 1` until `fix/skip-last-picture`; as built: landed with no skip, so the last GOP plays out to the title's END -- §10 "D16 as built"), and the end takes the usual path (TITLE_END: a disc's menus get onPlayListEnd; a stock Main stops as at any title's end). **Cancel: Circle** (the core's Stop button) backs out; the Go To button again also closes it (not measured; harmless). Hours past 999 cannot be typed (the HUD's three digits: a deviation row) |
| **D17** | The Repeat cycle's order and each step's tag; does a chapter press / Go To cancel A-B? | measure on the PSP; proposed: the order of D10, A-B cancelled by a seek, chapter / title repeat kept |

**Measure on the PSP** (D12-D17): → while paused; the slow-motion rates and their exit; one
frame advance press on a field title; Go To on My Chemical Romance across its items, and past
the end; the Repeat button's cycle and tags; how long a repeat's jump takes.

## 7. Status

| stage | state |
|---|---|
| plan | ✅ written 2026-09-30; D11 decided (P7 first); D12-D17 open |
| P6c0-P6c6 | Go To alone (§9): ✅ MERGED (PR fj#41, 2026-10-04), ✅ HW-CONFIRMED (§10); A-B / Repeat, slow motion, frame advance dropped for now (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**) |

**Next concrete step (2026-09-30; done: P7 merged PR fj#28 / fj#29, Go To PR fj#41):** P7 (subtitles). Its own overrun (39.7K against its 37.5K checkpoint)
is planned when P7 starts: the levers of §1. P6c resumes after P7's fit:
- re-cost §2 against the area that fit leaves;
- take the PSP measurements (§6);
- then P6c0 (the mockups).

## 8. Re-scoped: P6c on the HPS (the maintainer, 2026-09-30; `area_plan.md` §8 A6)

**Superseded by §9 the same day:** P6c is cut to Go To, which goes to the core if A7 frees the
room. This section is kept as the record of the HPS plan.

The stock-Main rule (A5): P6c is a feature beyond playing a disc, so it runs in the project's
Main fork (`main/`, `support/umd/`). A stock-Main user keeps its buttons inert, and the manual
already calls them "not yet implemented" (the wording will say "needs the UMD Main").

**What the move changes against §2-§3:**
- **Go To.**
  - The HPS reads the playlist from the image itself, so it maps a title time to (item, PTS)
    in software. §2.1's `NAV_TIME` reader op is **not needed**.
  - The landing uses `player_ctl`'s existing SEEK (command 7, `cmd_item` / `cmd_pts`), which
    already lands exactly (D2). It needs only a way in from the HPS (below).
  - The editor and the ▼ marker are drawn by the HPS.
- **The buttons.** Go To, Repeat and frame step can reach the HPS through Main's own input
  layer, since Main reads the pad and the keyboard before the core does. **To confirm in the
  plan:** how a `support/` module taps them (read `main/.build/Main_MiSTer`'s input.cpp).
  If it can, no fabric input path is needed and the J1 bits stay as they are. **Then the
  fabric side of Go To and Repeat stays inert for good** (they are the HPS's): no later phase
  adds a fabric handler for J1 B10 / B11, or a press would act twice.
- ~~**A-B / Repeat.**~~ **Dropped for now (H8).** (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**) Was: the HPS holds A and B as (item, PTS) keys and seeks to A when the shown
  picture reaches B.
  - Telemetry reads the shown key at 4 Hz, so a repeat could land up to ~0.25 s late.
  - **Design question for `docs/hps_host.md`** (answered there, §4 / H8: the host port is polled
    every few ms, not at telemetry's 4 Hz; no fabric compare if B2 measures it under 10 ms):
    accept that, poll faster, or give `player_ctl`
    a one-shot "seek to X when the shown key reaches Y" (a 65-bit compare, est. ~50-100 ALM).
- **Frame advance and slow motion stay fabric hooks** (§2.3). The display must release its
  freeze for exactly one pickup and gate the STC's tick, which only `disp_ctl` can do.
  - Est. ~100-200 ALM with `player_ctl`'s part, commanded from the HPS.
  - Leaving slow motion is a seek to the shown key, as in trick play.
- **The fabric contract it needs** (`menus.md` §4, `area_plan.md` §8):
  - a command path from the HPS into `player_ctl` (`EXT_BUS`, as the telemetry's `umd_telem`;
    est. ~100-300 ALM);
  - a surface to draw on: ~~a UI plane of the host's own above the subtitle plane~~ (withdrawn, §9; H5:
    subtitles and the editor share the screen as on the PSP; `hps_host.md` §3.4, ~350-500 ALM est.).

**Still owed before any RTL:** the PSP measurements of §6 (D12-D16; D17 went with A-B). The
host-B plan is written (`docs/hps_host.md`, 2026-09-30, H1-H8 taken):
- A7 first (`area_plan.md` A10).
- §4 there fixes what P6c takes from the host port: buttons forwarded by the fabric (no Main
  input patch), SEEK over HOST_WR, the shown key in every HOST_RD, and ~~the UI plane~~ (withdrawn, §9),
  over the subtitles as on the PSP.
- P6c is re-cut against that port once A7's fit is measured.


## 9. Cut to Go To (the maintainer, 2026-09-30, second round of `hps_host.md`'s decisions)

- **Dropped for now:** A-B / Repeat (with chapter and title repeat), slow motion, frame
  advance (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**). §2.2, §2.3, their rig gates and D12-D14 / D17 stay as the record, not the plan. The
  Repeat button and the `.` key stay inert; → while paused stays fast forward (P6b4), so D12 is
  moot.
- **P6c is Go To alone**, and §8's move to the HPS is reversed for it. The maintainer asked
  whether Go To can live on the core, beside the transport HUD it extends; if not, it is dropped
  too. **It can (`hps_host.md` §4, G1):** §2.1's fabric plan (the editor, `NAV_TIME`, the HUD's
  boxes and marker) at 500-950 ALM raw, 0.75-1.9K calibrated, against the ~2.0-2.6K that A7
  frees (estimated). **The decision is taken at A7's fit**, against the area it actually frees.
  In fabric Go To works on a stock Main.
- **Then open for Go To, since MEASURED (2026-10-03, §6):** D15 (title time vs item time on a multi-item title; the
  marker for a chapter in another item) and D16 (past the end, past 999:59:59, cancel).
- **Next:** A7 (`hps_host.md` B1-B5); then G1.
- **G1 decided (the maintainer, 2026-10-03): Go To in fabric**, the room found by dropping the
  diagnostic HUD (`area_plan.md` A11: measured -1,422 ALM, 37,749 = 90 %, so ~2,070 under 95 %).
  Built on its own branch after the HUD's removal merges, designed to a cap written here before
  any RTL (P6c0: the mockups approved, D15 / D16 measured or the proposals taken). Scope: Go To
  alone (A-B / Repeat, frame advance and slow motion stay dropped (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**)).
- **THE CAP: 1,500 ALM** (written 2026-10-03, before any RTL). The HUD's removal fitted at 37,754
  (SEED 9, `UMD_nohud_20261003_2040.rbf`); the 95 % line is 39,815, so 2,061 of room; 1,500 keeps
  ~560 against the fitter's density growth (A7's removal freed 1.5x its parts). Go To is designed to
  it, as P6b5's HUD was to its 800: the editor in `player_ctl` (a few states, the chapter u16, h / m / s
  in BCD-free binary), `NAV_TIME` in the reader reusing the seek's item walk, the HUD's box kinds,
  two-glyph arrows and the marker compare.
- **P6c0, the mockups** (`tools/transport_layout.py --mockups --goto [--il]`, `.sim/goto_mockups*`,
  over rig screenshots): the Display layout with its time row the editor -- `Chapter n`, then the
  target time over the total; the focused box lighter, the edited field light grey with ▲ above and ▼
  below (the ▼ drawn in the top lines of the icon row, clear of the bar); a blue ▼ above the bar at the
  target (the chapter's start, or the time typed). ✅ **APPROVED by the maintainer (2026-10-03).** D15 /
  D16 measured the same day (§6).
- **The design, after review (2026-10-03):** `NAV_TIME` (`nav_op` widened to 3 bits, op 4: a seek
  whose target is the playing playlist's time, the seek's item walk stopping at the item whose span holds
  it -- past the end the last item, clamped to OUT - 4 since `fix/skip-last-picture`: D16); `NAV_CHAP`'s answer gains each key's title
  time when its item is the one streaming (`item_base + pts - IN`: the marker, no new query); `player_ctl`
  command 15 = the time seek; a `goto_ctl` beside it holds the editor; `emu` gives it the D-pad, Pause and
  Stop while it is open, BEFORE the host's grab (P9-6's Circle) and the D-pad's FF / REW; Square closes Go
  To and is then the UMD Menu press. Order: P6c1 models, P6c2 the reader, P6c3 `player_ctl` + `goto_ctl` +
  the `emu` mux, P6c5 the HUD, P6c6 the buttons, the manual, the fit, the rig.
- **The △ control panel (D10 revisited, the maintainer 2026-10-03): on the HPS** (the UMD Main draws it on
  the plane, as the disc menus do; every item sends a command the fabric already takes). A later feature,
  after Go To; no fabric cost; absent on a stock Main (it adds no capability: every action keeps its
  button). **Planned 2026-10-04 as P6d: `docs/panel.md`** (a small fabric delta after all: a host press
  record so each item IS its button, two HOST_RD bits, the button's rename, a panel mode keeping the
  subtitles under it; K1-K15 taken 2026-10-04).

## 10. As built (P6c1-P6c6, 2026-10-03; ✅ MERGED PR fj#41, 2026-10-04, ✅ HW-CONFIRMED)

**The pieces** (the design of §9's "after review", one module each):

- **The model** (`tools/umd_nav_ref.py`): `Title.time_seek(ticks)` = `seek(key_at(ticks))` -- the
  playing playlist's time to (item, PTS), an item's span `[start, start + OUT - IN)`, past the end
  the last item's OUT (the seek's clamp then OUT - 1, OUT - 4 since `fix/skip-last-picture`); `Title.marker(key, streaming)` = the
  chapter's `elapsed()` in the streaming item, else None. `test_umd_nav_ref.py` +14 checks
  (boundaries, empty items, past the end, the 48-bit saturation, the marker's clamps), 3 RED arms
  in `red_umd.py`.
- **The reader's `NAV_TIME`** (`umd_reader.sv`, `nav_op` 3 bits, op 4): the seek's flush and item
  walk; in time mode `S_SK_IT` reads every record it passes and `S_SK_IT2` subtracts its span
  (`tm_left`, whose borrow says the span holds the time), stopping there at IN + the rest, or at the
  last record at its OUT. Refused only on a playlist with no item. **The bench found a bug at once:**
  the output pipe's flush (line ~1783) listed `seek_take` / `play_take` but not the new op -- stale
  bytes after a TIME. `run_umd_reader.sh --red`: syn_nav's TIME script (0, each boundary and the tick
  before it, inside the item past 2^32, past the end, 2^48 - 1, the trailer's own time and its
  largest, the empty playlist, ops 5-7) and every disc image's (random, 0, boundaries, the end and
  past it, the other playlist); arms T1-T7. (`MAXCMD` 32 -> 64.)
- **`player_ctl`**: command 15 `TIME` (as `SEEK`, through `NAV_TIME`; during trick play its exit
  `EX_TIME`); a TIME's landing becomes the pending key (`tm_land`: a press during the seek is judged
  from where the reader put it); a TIME past the end lands with no skip (below, "D16 as built"); **the Go To query port** (`gq_req` / `gq_key` / `gq_done`: a
  `NAV_CHAP` of goto_ctl's while no gesture is in flight, the tracker first). `SEEK` now sets the
  projected chapter to the shown one (it kept a stale press's before: shown only during the seek).
  `run_player_ctl.sh --red`: every script runs TIMEs (random, 0, boundaries, the end, past it, from
  pause, from stop -- refused --, a press during one, one ending trick play) checked against
  `umd_nav_ref.time_seek`; the bench drives the query port at random ([goto]); arms G1-G7. The
  reserved code the bench injects is 0 now (15 is TIME).
- **`goto_ctl.sv`** (new): the editor -- open conditions, the two boxes, the fields, the chapter
  selector (open: from the shown key; up: from the candidate, its next; down: from the candidate's
  key - 1, its cur), h / m / s with their wraps on one adder with t_ticks, the opening's time by
  repeated subtraction, the jumps (SEEK 7 / TIME 15), the closes, the marker (two registered
  stages). `bench/umd/run_goto_ctl.sh --red`: a 3,000-press random walk on three seeds against the
  bench's own reference written from the spec, a mock reader by NAV_CHAP's contract, directed wraps
  and a dropped step; arms M1-M13.
- **`emu`**: `gt_take` -- Go To's button always, and while open the D-pad, Pause and Stop -- masked
  from `hk_press` (the UMD Main) and from the transport, so it comes BEFORE the host's grab and
  FF / REW; goto_ctl's one-cycle command first on `player_ctl`'s port; the HUD's Go To ports.
  `check_emu_wiring` pins it all; `run_scaffold.sh --red` W109-W112.
- **`transport_hud`**: Go To's layout (the Display layout, its time row the editor), the plane's box
  attribute widened to three kinds per cell (first pad / middle / last pad; the plane 11 -> 15 bits),
  the SEL / EDIT tints, the arrows over the field (one cell over an odd field, the two-cell pair over
  an even one; the message over the up-arrow), the marker (a second restoring division, job 5;
  drawn on the fill's layer), the caption row given to the editor (no pop-up caption while open),
  `el_ticks` out for goto_ctl. `run_transport_hud.sh --red`: 57 states (+14: the six approved
  mockups and g01-g09), pixel-exact at 480p and 480i; arms H27-H41.
- **The manual**: `controls.md` (Go To's section; the admonition now Repeat and frame step only),
  `on-screen-messages.md` (the editor), `disc-menus.md`, the README's status.

**D16 as built -- past the end plays the last moment, then the title ends.** The first fit
(`UMD_goto_20261003_2340.rbf`) seeked a past-the-end TIME to the last item's OUT - 1 with the skip,
as §9 planned ("the title ends within a picture"). **On the rig (Akira) that froze:** the display's
skip dropped the last picture too, so it never stopped skipping, END was never taken, the pre-seek
picture stayed up and no TITLE_END reached a disc menu (`display.md` §11: the cause in `disp_ctl` not
yet found; a jump to 2 s before the end played out and ended normally). **Fixed in `player_ctl`:** a
TIME the reader clamped to the last item's OUT - 1 lands with NO skip -- the last entry's I picture
and the rest of its GOP (up to ~2 s) play out to the title's END, which then takes the usual path.
The reader and the model are unchanged (the landing is the same entry); `run_player_ctl.sh`'s
`[land]` arm wants the no-skip entry for such a landing (G8). **✅ On the rig** (refit
`UMD_goto_20261004_0031.rbf`, SEED 9 91.96 / 89.45, 38,772 ALM; Akira, the telemetry Main): a jump
past the end (99:xx:xx) -- one seek, the watchdog 0, the display `ended`, the shown picture the last
(PTS 676,494,725), Chapter 36, `02:05:15/02:05:15`, errors 0; a jump back from there (01:05:15) landed
and played, Chapter 21.

**The cause found, and the workaround kept as a UX choice (`fix/skip-last-picture`, 2026-10-04,
`display.md` §11).** The clamp, not `disp_ctl`: OUT - 1 lay 0.5 tick before the display's estimate of
Akira's untagged last picture's end, inside the skip's one-tick tolerance. The reader's clamp is now
OUT - 4, and an END reached inside a skip ends the display. A TIME past the end could now take the
skip and show the last picture. It still lands without it (`player_ctl` compares `nav_skip` with
`OUT - END_GUARD`), so the last GOP plays out before the title ends. That is the closer of the two to
the PSP's "as if playback completed", and it was already on the rig. G8 is now that choice's arm; G10
catches `player_ctl`'s `END_GUARD` drifting from the bench's mock reader. `run_umd_reader.sh` checks the reader's
against `umd_nav_ref`.

**✅ The maintainer's own test on the rig (2026-10-04, progressive 16:9): "go to options work great, those
tests are good on HW"** (Akira and My Chemical Romance disc 2 offered: chapter / time jumps, past the end,
the playing playlist's time).

**The rig sessions (2026-10-03 / 04, Akira, 480i layout, stock Main then the telemetry Main):** the editor
opens on the shown time and chapter; a time jump (3:20), a chapter jump (5: landed at the model's 0:10:20),
an hours-field jump (1:10:51) and a jump 2 s before the end all land and play; Stop closes it with
playback going on; the arrows, the field tint and the marker as the mockups.

**Decisions taken in the build (recorded for the maintainer):**

- **Stop backs out in one press** (the maintainer's "circle backs out of Go To", read literally),
  from a box or from editing; Go To again closes too; UMD Menu closes it and goes on to the disc.
- **x opens a box, x again jumps** (the walk-through: "selecting a box opens it ... x confirms").
- **The time box opens on the shown picture's time** (floored to the second), the chapter box on
  the chapter holding it (the first chapter before any).
- **Every field wraps** (hours 0-99, or 0-999 on a title of 100 h or more, as the HUD's digits);
  the chapter number does not (1 .. n).
- **The caption row is the editor's while it is open** (a Next / Prev or track caption is not drawn
  then; the state icon still is).
- **While open, the other buttons act as usual** (a chapter press seeks; the editor stays open).

**Known limitations:**

- **Duplicated chapter keys** (two marks at one (item, PTS)): a step treats them as one; going up
  the number shown is the rank + 1 of the chapter left, one short of the tracker's after a
  duplicate. None in the library.
- **The marker of a chapter in another item is hidden** (D15; an item walk per step would place it).
- **A step pressed while a chapter query is in flight is dropped** (a query takes ~2 ms).
- **A button pressed in the very cycle of Go To's jump is lost** (one command a cycle).
