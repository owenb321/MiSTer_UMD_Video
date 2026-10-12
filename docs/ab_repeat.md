# A-B Repeat -- the plan (2026-10-07)

**Status: ✅ MERGED (PR fj#63, 2026-10-07), ✅ HW-CONFIRMED (.236; §7 "On the rig").** Branch `feature/ab-repeat` (`CORE_VERSION` `dev-abrepeat`). This
note replaces `p6c.md` §2.2 as the plan. §2.2 stays there as the record of the old cycle.
**The PSP measured** (the maintainer, 2026-10-07: §6); **every open decision taken as proposed** (the
maintainer, 2026-10-07). The HUD mockups ✅ approved (2026-10-07). **AB1-AB5 ✅ built** (§7): the fit SEED 3 PASS, the manual, the rig. Merged (PR fj#63).

## 0. What the maintainer decided (2026-10-07)

- **A-B only.** Chapter repeat and title repeat stay dropped, along with slow motion and frame
  advance (`p6c.md` §9).
- **In fabric**, so it works on a stock Main. That follows the stock-Main rule's spirit: the HPS
  route (`p6c.md` §8) would lose it on a stock Main and land up to ~0.25 s late at telemetry's
  4 Hz.
- **Panel + key, no new J1 button.** The old Repeat button became Control Panel in P6d
  (`panel.md` K3). `CONF_STR` does not change.

**Not done first: `area_plan.md` §10b** (`player_ctl`'s decisions as routines on the navigation
engine). Only §10a, the reader's parse, is on the engine (A12, PR fj#59). §10f called A-B "almost
free with §10b's routines". That is true only once §10b exists, and §10b means rewriting the
transport's hardest-won code. A-B is built hardwired instead, at an estimated 250-450 ALM (§5).

## 1. Where it lives: `umd/ab_ctl.sv`, beside `goto_ctl` (proposed, AB1)

The maintainer's answer said "in `player_ctl`". Proposed instead: **a sibling module on clk_sys,
built the way `goto_ctl` is**. It reads the shown key, keeps A and B, and issues a **SEEK (7)** on
`player_ctl`'s command port. `player_ctl` already lands a SEEK exactly (the freeze, flush and skip
to the target, D2), clamps it into IN..OUT through the reader, and refuses it on a bare file
(UNAVAIL).

- **Why a sibling:** `player_ctl`'s gate (`run_player_ctl.sh`, the decisions against
  `umd_nav_ref`) stays untouched, and its seek machine is reused rather than grown. Go To proved
  the pattern (P6c, ✅ HW-CONFIRMED).
- **What it needs from `emu`:** `pc_state`, `pc_seeking`, `pc_key_item`, `ds_sh_pts` /
  `ds_sh_pts_v`, `ds_pick_evt`, `is_bare`, `start_streaming` / `img_ejected`, the A-B press and
  CLEAR, and the chapter presses (which it takes during the loop, §2).
- **What it gives `emu`:** a mask over the presses `player_ctl` and `goto_ctl` see while the loop
  runs (§2), and its state for the HUD.
- **The command slot:** a cycle with no Go To jump and no button command. Priority:
  `gt_cmd_v` > `pc_cmd_v` > A-B > the host's (`hc_take` gains `& ~ab_cmd_v`). The request is held
  until it is taken, and raised only while `!pc_seeking` and the state is PLAY or PAUSE.
  `player_ctl` refuses a SEEK with a gesture or seek in flight, so A-B waits for that rather than
  having its SEEK refused. An EV_BAD that follows its own command anyway is retried once and
  counted.

## 2. The behaviour (the PSP, measured 2026-10-07; §6)

- **The cycle:** off → **set A** (the first press takes the shown key) → **set B** (the loop
  starts) → **off** (the third press clears it and normal playback resumes).
- **CLEAR** clears from any state; it is always available (it does nothing when off).
- **B not after A:** the PSP will not set B before A. A B press at a key not later than A is
  refused: nothing changes, the state stays at A, the press is counted.
- **Keys are (item, PTS):** `key_item` u32 and the shown picture's 33-bit PTS, compared
  item-first, as the chapter tracker's `reached` compares. A PTS alone is wrong on a multi-item
  title. Item numbers are kept at their u32 spec maximum.
- **The loop:** at each pickup with `sh_pts_v`, if the shown key is at or past B, issue
  SEEK(A). It re-arms only after `pc_seeking` falls and a fresh pickup arrives. Until the landing,
  the screen still shows a picture at or past B, so without that rule it would fire twice.
- **Every loop is a seek:** freeze, flush, an exact landing on A. The PSP's gap is under a second
  and varies with where the loop is, which looks like the seek's speed: a landing decodes from
  the EP entry before A. The core's seek does the same (the recovery-point start, then the skip
  to A), so its gap should vary the same way.
- **While the loop runs** (state A-B), the PSP:
  - **Stop clears it.** Play after the stop resumes there, without the loop.
  - **Next and Prev Chapter both jump to A** (a SEEK(A) from `ab_ctl`; `player_ctl` never sees
    the press).
  - **FF, REW and Play do nothing.** Their presses are masked from `player_ctl`.
  - **Pause pauses, and the loop stays.** Play/Pause then resumes it (Play's "nothing" was
    while playing).
- **Also cleared** (not PSP-measured; the core's own events): a mount, an eject, the title's
  end, and a disc menu's PLAYLIST (13).
- **A bare file:** the press posts UNAVAIL ("Not available for this file."), as the other
  seek-type actions do, and nothing is set. The gate is at the source, as `player_ctl` does it.

## 3. The controls

- **The keyboard (AB7):** bit 15 of `kbd_map`, the inert keyboard-only Frame Step on `.`, becomes
  **A-B Repeat**. Proposed key: **B** (free; "A-B"); `.` is dropped with Frame Step. No J1
  button, so `CONF_STR` and `jn` do not change. `controls.md`'s Frame Step row becomes A-B
  Repeat's. `docs_check.py` checks buttons, not keys, so the row is kept by hand.
- **The panel (AB8):** the PSP's row 3 (`panel.md` §1).
  - **A-B Repeat** is a press record with `hx_mask[15]`. The 16-bit record already reaches
    bit 15, so HOST_WR does not change.
  - **CLEAR** is always available (measured), so the panel needs no A-B state. It must still be
    an action of its own: in state A a press would set B. It is a host command, **code 0** on
    the command port (the one unused code). `ab_ctl` takes it, and `emu` keeps it from
    `player_ctl` (which would count it in `n_bad`).
  - **Repeat** stays out, along with chapter and title repeat (§0).
  - **The mockups (AB4, 2026-10-07):** `tools/panel_layout.py --mockups [--il]` (p12-p15): a third row
    under the transport row, 54 lines lower, `A-B Repeat` (the letters, as the PSP's item) and `Clear`
    (the word in a rounded pill, as the PSP's: the maintainer's photo of the panel, 2026-10-07, which
    also shows the caption `Clear`); the caption row moves to line 264, the box ends at line 298 (clear
    of 480i's message strip at 306). Both dark over a disc menu (K9). ✅ **Approved by the maintainer
    (2026-10-07)**, with ↑ / ↓ to the adjacent row, wrapping over the three rows, the column kept. A row
    with nothing available (row 3 over a disc menu) is skipped, as ← / → skip a dark item.
  - **As built (AB4):** `panel_ref.py` (the actions: A-B Repeat a press of bit 15, Clear the host's
    command 0; `_vert(step)`), `umd_panel.c` (three rows; the art regenerated, Clear's word drawn with a
    0.8 pen, `ICON_PEN`), `test_panel_ref.py` (the row-3 walks, the actions, the box's new place);
    `run_panel.sh --red` ALL GREEN, P28-P31 added (44 mutations caught). The runner sends any command
    code as it is (`umd_menu_logic.c`), so code 0 needs nothing there.
- **The press path:** `btn_all[15] | hx_press[15]`, the same shape as Go To's `k_goto`. It goes
  into neither `hk_press` nor the grab (`check_emu_wiring` pins that, as it does for Go To).
- **The loop's mask** applies to `btn_press` / `dpad_press` (so to the panel's presses too, which
  enter there): FF, REW and Play masked; Next / Prev taken by `ab_ctl`.

## 4. The HUD (the PSP measured; mockups before any RTL, AB9)

**The PSP** (the maintainer, 2026-10-07):
- After the first press: the play icon with **`A-B`** beside it, the **B blinking at 1 Hz** (on
  and off), until the second press.
- At the second press: **B solid for 2 s**, then the icon and `A-B` both go while it loops.
- (The third press: back to normal playback.)

**The PSP's photo** (the maintainer, 2026-10-07, state A): bottom-left, the white ▶ and, about
one icon's width to its right, **`A-B` in white text with a dark drop shadow, no box**, its baseline
on the icon's. The panel's row 3 shows `A-B` as text-on-icon, Repeat as a loop arrow, and the
caption `A-B Repeat` under the row (the UMD Main draws those, AB4).

**For the core:**
- The tag `A-B` in the icon slot after the state icon (one empty cell between, as the photo),
  white with the font's shadow, no box: text, not glyphs. The font's 11 spare
  glyphs (`transport_hud.md` §6.1) stay spare, and the ROM stays at 7 bits (`p6c.md` §3).
- State A: the icon and the tag held up, the B cell blinking on a 1 Hz square wave (0.5 s on,
  0.5 s off) from the HUD's frame count.
- Loop start: B solid for 2 s, then the icon and the tag go (unless the icon has its own reason
  to stay: Display on, paused).
- With Display on, or paused, during the loop: AB12 (§6).
- **The mockups** (AB0, 2026-10-07): `tools/transport_layout.py --mockups --ab [--il]` over the P6b5 rig
  shots (`.sim/p6b5_bg.sh --ab`), into `.sim/ab_mockups*`: A set (the blink's two phases), B's 2 s hold,
  the loop (nothing drawn), the loop with Display on and paused, A set in FF 2, a bright 4:3 title,
  a subtitle beside the tag; the 480i title-safe set too. ✅ **Approved by the maintainer (2026-10-07).**
- `transport_hud` is pixel-exact against its model: the model changes first, then
  `run_transport_hud.sh --red` gains the states.

## 5. Cost

| part | estimate (raw) |
|---|---|
| `ab_ctl`: two 65-bit keys, one item-first compare, a small FSM, counters | 150-250 |
| `emu`: a third input on the command port's item / PTS muxes, the slot, code 0's route, the loop's mask | 50-100 |
| `transport_hud`: the 3-cell tag, the blink, the 2 s hold | 50-100 |
| **total** | **~250-450** |

The device is at 39,425 ALM (94 %; SEED 3 pinned). 95 % is 39,815, so this sits at the line.
Measure first with `tools/synth_unit.sh` (`ab_ctl` alone, then the HUD's delta). If the fit
passes at the pinned SEED it ships, with no sweep for margin alone. A miss means a sweep
(`area_plan.md` §2, A2').

## 6. Decisions, and the PSP's answers

**Measured on the maintainer's PSP, 2026-10-07** (the old D17, owed since P6c):

| # | question | the PSP | the core |
|---|---|---|---|
| AB2 | The third press | clears, normal playback resumes | as the PSP |
| AB3 | B before A | cannot be set | refused, counted |
| AB5 | During the loop: Stop / chapters / FF / REW / Play / Pause | Stop clears (Play then resumes without the loop); Next and Prev both jump to A; FF, REW, Play do nothing; Pause pauses and the loop stays | as the PSP |
| AB8 | CLEAR | always available | always; host command 0 |
| AB9 | The HUD | play icon + `A-B`, B blinking 1 Hz until B; B solid 2 s; then nothing while looping | as the PSP (§4), by mockup |
| -- | The gap at a loop | < 1 s, varies with the place (looks like seek speed) | the core's seek, measured at AB5 |

**✅ Taken as proposed** (the maintainer, 2026-10-07):

| # | question | proposal |
|---|---|---|
| **AB1** | `ab_ctl` beside `goto_ctl`, or inside `player_ctl`? | **the sibling** (§1) |
| **AB4** | A first press while paused / stopped / in FF or REW | **paused: sets A; stopped or in trick play: ignored** |
| **AB6** | A bare `.MPS` | **UNAVAIL** |
| **AB7** | The key | **B** (`.` dropped with Frame Step) |
| **AB10** | Go To during the loop | **does nothing** (as FF / REW: the PSP's loop takes every other navigation away) |
| **AB11** | With A set and no B yet: do chapters, FF / REW, Go To and Stop act normally? | **yes, normally, A kept** (so a user can scrub to B); Stop clears |
| **AB12** | The HUD with Display on, or paused, during the loop | **the icon as usual, the tag `A-B` beside it** |
| **AB13** | UMD Menu (a disc's own menus) during the loop | **clears it** (a disc menu's PLAYLIST does) |
| AB14 | At the B press: does the PSP jump to A at once, or play on a moment first? | not measured; the core jumps at the next picture (found on the rig, 2026-10-07) -- a question for the maintainer's PSP, no change planned |

## 7. Stages

| stage | what | bench / gate |
|---|---|---|
| **AB0** | the decisions (§6), the HUD mockups approved | -- |
| **AB1** | `ab_ctl.sv` and its bench: a mock display walking keys, the command port with BAD and in-flight refusals, every rule of §2 (the chapter jumps, the masks, Stop, pause, the re-arm), multi-item keys, the u32 / 33-bit edges | `bench/umd/run_ab_ctl.sh --red`: decisions against the bench's reference written from §2, each mutation caught by its own arm |
| **AB2** | `emu`: the slot, the press path, the mask, code 0's route, `kbd_map` bit 15 | `run_scaffold.sh --red` / `check_emu_wiring` arms (bit 15 never in `hk_press`; the priority; the mask) |
| **AB3** | the HUD | `run_transport_hud.sh --red`, the new states |
| **AB4** | the UMD Main's panel row 3 (A-B Repeat, CLEAR) | `run_panel.sh --red`, `run_umd_host.sh --red`, `run_hps_host.sh` |
| **AB5** | the manual (`controls.md`, `on-screen-messages.md`, `troubleshooting.md`), the fit, the rig | `docs_check.py`, `mkdocs build --strict`; the rig gates below |

**AB1, as built (2026-10-07):** `umd/ab_ctl.sv`. The shown key is read straight from `key_item` /
`sh_pts`: they are one picture's on every cycle but a pickup's own (sh_pts new, key_item written at
its end), so a press in that cycle is ignored and counted, and the loop compares the cycle after.
The blink's and the hold's timers are one counter (A and the loop never coexist). A SEEK taken that
`seeking` never follows within `TAKE_WAIT` (64) cycles is asked again (`n_retry`). Synthesis alone
(`tools/synth_unit.sh ab_ctl`): ~233 ALM, 213 registers, the four diagnostic counters included
(unconnected in `emu`, so pruned there). `bench/umd/run_ab_ctl.sh --red`: ALL GREEN, three seeds of
3,000 steps (34-52 loops, 4-7 across items, 7-12 chapter jumps, 10-17 retries, every clear reason),
14 mutations each caught by its own arm (M11, the bare gate, by [state] before the directed [na]).

**AB2, as built (2026-10-07):** `kbd_map` bit 15 is B (`8'h32`; `.` dropped with Frame Step). In `emu`:
`ab_ctl` takes bit 15 as it reaches the transport (`btn_press[15]`: after the host's grab, the panel's
press record ORed in), Next / Prev likewise; `ab_loop` masks them from `player_ctl` (`btn_cmd`), FF /
REW (`dpad_cmd`) and Go To's open (`k_goto`). The command port's order is Go To's jump, the buttons,
A-B's SEEK (`ab_take = ab_req & ~pc_cmd_v & ~gt_cmd_v`), the host's (`hc_take` gains `& ~ab_req`).
The host's code 0 is CLEAR: taken (`hc_take`), never `player_ctl`'s (`hc_pc`); a host SEEK / PLAYLIST /
TIME taken clears A-B (`ab_hnav`). `check_emu_wiring` pins all of it; `run_scaffold.sh --red` ALL GREEN
with W132-W139 (each caught) and W111 / W115 / W124 re-anchored.

**AB3, as built (2026-10-07):** `transport_hud` gains `ab_up` / `ab_b` / `ab_loop` / `ab_na`: the tag
`A-B` (ASCII glyphs, no new font cells) one empty cell after the icon -- column 3, or 4 after trick
play's badge --, `ab_up` holding the state icon up, the loop's tag only beside an icon up for its own
reason; `ab_na` is the P8 message. The model (`transport_layout.py`) drives the bench through new SET
ids 28-30 and PULSE 9; bench states: the nine mockups and ab10-ab14. `run_transport_hud.sh`: 81 states
pixel-exact at 480p and 480i; H52-H56 added (H49's duplicate renamed H51). `emu` wires the four;
`check_emu_wiring` + W140 / W141.

**The rig gates** (from `p6c.md` §5): a 10 s loop on Akira run 5 times, every landing on A by the
telemetry's landing word, `av_err` in step after each, errors 0, and each gap's `seek_lat`
recorded; a loop across an item boundary on My Chemical Romance disc 2; Next / Prev jump to A;
FF / REW / Play do nothing; Pause holds and resumes the loop; Stop clears; a bare `.MPS` refuses;
with the UMD Main, the panel's A-B Repeat and CLEAR.

**AB5, the fit (2026-10-07):** SEED 3 PASS, clk_dec 91.6 / 88.72 MHz, 39,507 ALM (94 %, +162 over
`fix/pause-trick`), RAM 503, DSP 90; the router's first pass missed four signals and its retry routed
(`UMD_abrepeat_20261007_2225.rbf`, ledgered in `UMD.qsf`).

**On the rig (2026-10-07, .236, that build + the UMD Main from the same commit; `mister.py seq` on the
target, telemetry's `seeks` / `land_*` / `seek_lat` / `xport`):**
- **The loop (Akira, ~10 s):** five passes, each landing on the same picture (PTS 27.944 s), 10.0-10.2 s
  apart; the gap (`seek_lat`) 0.27 s -- the PSP's was under a second. The core's first loop fires at the picture
  after the B press (it is past B); whether the PSP jumps at the press or plays on a moment was not measured
  (AB14). Errors 0, `av_err` 0-2 ticks.
- **During the loop:** Next and Prev Chapter each a seek to A (3.4 s later the picture was at A + 3.4 s,
  not in another chapter); FF no trick play, no seek; Go To no editor (the control arm: the same key with
  A-B off opens it); Pause holds (state 2) and Play/Pause resumes the loop; Stop clears it -- Play then ran
  past B with no seek.
- **The HUD (screenshots):** A set -- ▶ `A-B`, the B on in one shot and off in the next two (the blink);
  at B solid; 3.8 s later nothing; paused in the loop ⏸ `A-B`.
- **Across items (My Chemical Romance disc 2, playlist 1):** Go To 2:06:40 landed at 7,599.46 s of item 1;
  A at 7,601.86 s (item 1), B at 1.7 s of item 2 (the 3.2 s tail); four passes, each crossing into item 2
  and seeking back to item 1's A -- B's PTS far below A's, so the item-first compare is what held. A long
  loop (A 20.9 s in chapter 2, B 199.7 s in chapter 3) also landed on A.
- **A bare `.MPS`** (Akira `00003.MPS` in `/tmp`, mounted in session): "Not available for this file.", no
  seek, nothing set.
- **The panel:** A-B Repeat (A, then B 5 s later: three passes on A at 124.62 s), the HUD's tag under the
  open panel, Clear (playback ran on past B, no seek); the panel as the approved mockups.
- **`seeks` read 8 at the bare file's mount after 7 at the end of the cross-item run:** one more loop pass
  (the loop was ~10 s, the copy of the 28 MB file took about as long) before the mount cleared it.
- **Not exercised on the rig** (the benches cover them): Disc Menus On (UMD Menu / a disc menu taking the
  screen clearing A-B, Stop grabbed by the host), FF / REW with only A set, the panel's third A-B Repeat
  press as the clear.

## 8. Known limitations (as planned)

- The loop is a seek: a visible and audible gap at each pass, as on the PSP (< 1 s there,
  varying with the place). The core's is measured at AB5 from telemetry's `seek_lat`.
- No chapter or title repeat (§0).
- A and B are not remembered across a stop or a disc change. Resume per disc (`resume.md`)
  keeps the place only.
