# P6d: the control panel, on the HPS (host B)

> **A12 SD2 (2026-10-07, `nav_engine.md` §11):** the subtitle under the panel (§2) is now the FABRIC's
> decode: the compositor takes the shown unit's plane and rectangle from HOST_RD words 39-43 (its own
> record only from an older core) and reads it back as before. ✅ on the rig (Akira, the panel open over a
> line).

**Status: ✅ MERGED (PR fj#46, 2026-10-05), ✅ HW-CONFIRMED** (C0-C5 on the rig; the maintainer's own test: "the panel looks great and works fine"; Audio / Subtitle show first since §3.11).
- **Every decision is taken (2026-10-04):**
  - K2 and K5-K10 were measured on the maintainer's PSP (§1.1);
  - K1, K3, K4 and K11-K15 are the proposals, all accepted by the maintainer (§8).
- **Two measurements changed the design:**
  - the PSP keeps subtitles under its panel (§2);
  - the panel opens over a disc menu too (§3.4).
- **C0 ✅ APPROVED by the maintainer (2026-10-04):** the mockups (`tools/panel_layout.py --mockups [--il]`,
  §3.5 "C0, as rendered"). Also taken:
  - K16, the rounded box ("superior");
  - the cursor skips greyed items;
  - full names in the caption.
- **C1 ✅ built (2026-10-04):** the art for the UMD Main and the behaviour model (§3.6). `tools/tests`
  is green under `--red`.
- **C2 ✅ built (2026-10-04):** `umd_panel.c`, the logic and the renderer, on the PC (§3.7).
  `bench/umd/run_panel.sh --red` is ALL GREEN: 27 mutations, each caught by its own arm.
- **C3 ✅ built (2026-10-04)**: the fabric (§3.8). SEED 9 missed by 0.14 / 0.60 MHz; the sweep's SEED 1
  passes 87.79 / 87.52 MHz (38,732 ALM, 92 %), pinned.
- **C4 ✅ built (2026-10-05)**: the UMD Main (§3.9).
- **C5 ✅ on the rig (2026-10-05)** (§3.10; the owed checks §3.10b); the manual is current. ✅ MERGED (PR fj#46).

**Where it comes from:**
- **2026-09-27:** shortcuts AND a pop-up panel, as on the PSP (`transport_hud.md` "Decided").
- **2026-09-29:** the panel dropped for area (`transport.md` D10). Every action got a button, the
  D-pad or a key.
- **2026-10-03:** D10 revisited by the maintainer. The panel comes back, **on the HPS**: the UMD
  Main draws it on the plane as the disc menus do, and every item sends an action the fabric
  already takes (`p6c.md` §9).
- **2026-10-04:** the maintainer confirmed the HPS after a fabric estimate (0.45-1.0K ALM
  calibrated, against ~1,000 ALM left under the 95 % line). That estimate is not recorded
  elsewhere, by choice.

**What it is for:** to find things. Every action already has a button (D10), so the panel adds no
capability. It brings back the PSP's discoverability: one button opens it, the D-pad walks it,
and its caption names what is selected.

**The stock-Main rule holds** (`area_plan.md` §8 A5). On a stock Main the panel button shows a
message and nothing else. Everything the panel does stays reachable from the buttons and keys.

Behind it:
- `transport_hud.md` §2: the panel as measured on the PSP (the layout, the items, the selection,
  the caption).
- `hps_host.md` §2-§3.4: the host port and the plane hand-over.
- `p9.md` §3.2-§3.3: the grab, `ui`, `menu`, the flips and the runner.
- `p6c.md` §9-§10: Go To, which the panel opens.

---

## 1. What the panel is (the PSP, `transport_hud.md` §2)

- **Layout:** three rows of icons centred in the upper half, a caption under them naming the
  selected item.
- **Selection:** the selected icon white with a soft halo, the rest grey, an unavailable one dark
  grey.
- **The UMD player's items:**

  | row | items |
  |---|---|
  | 1 | UMD Menu, Go To, Audio Options, Angle, Subtitle Options, Volume Boost, Screen Mode, Display, Help |
  | 2 | Previous, Next, Fast Reverse, Fast Forward, Slow Motion, Frame Advance, Play, Pause, Stop |
  | 3 | A-B Repeat, Repeat, CLEAR |

- **Options cycle in place** (the maintainer, 2026-09-27). Audio and Subtitle step to their next
  value, and the HUD's tag shows it. There is no list to open.

**Which of these the core can do today:**

| built (the action exists) | not built |
|---|---|
| UMD Menu (with the UMD Main and disc menus on), Go To, Audio, Subtitle, Display, Previous, Next, Fast Reverse, Fast Forward, Play, Pause, Stop; A-B Repeat and CLEAR (2026-10-07, `ab_repeat.md`) | Angle (none on the 33-disc census), Volume Boost (left out: Main boosts a core's audio, 2026-09-27), Screen Mode (the OSD's Aspect option), Help, Slow Motion, Frame Advance, Repeat (dropped for now, `hps_host.md` H8) |

Which items appear is decision K1.

### 1.1 Measured (the maintainer's PSP, 2026-10-04)

- **Subtitles stay visible under the panel** (K2).
- **The panel stays up after × (confirm).** Only **UMD Menu and Stop close it**. **Go To hides it
  while the time / chapter editor is up, and it comes back after the jump's seek** (K5).
- **While it is up** (K6): ○ closes it, △ closes it, START, L / R and □ act as usual. □ is UMD
  Menu, which closes it (K5).
- **Nothing is greyed out by the play state:** playing, paused, stopped and in fast forward /
  reverse, every item is available (K7).
- **The cursor starts on Display** at an open (K8).
- **△ in a disc menu opens the panel**, with everything greyed out except UMD Menu, Volume Boost,
  Display, Help and Stop (K9).
- **No timeout:** the panel stays until it is closed (K10).

## 2. Subtitles under the panel: the panel's own pages, the subtitle composited by the host

> **fj#71 Zoom (2026-10-09, `docs/zoom.md` §3):** under Aspect Ratio's Zoom only raster lines 60 .. 419 are shown;
> the core says so on HOST_RD AUDIO[10], and `umd_mr_panel_frame` places the subtitle as the fabric places its
> own (`zoom_place`: y clamped to [60, 420 - h], at most 360 rows), its vacated rows cleared; a change of Zoom
> redraws the page. `run_panel.sh` [zoom], RED R14-R17.

**Revised: `hps_host.md` H5** ("nothing but subtitles is HPS-drawn during playback", 2026-09-30),
by the maintainer's 2026-10-03 decision. The panel is an HPS-drawn screen over playing video.

**Why the plane hand-over as built does not do.** `ui` gives the plane to the host
(`hps_host.md` §3.4 "As built"). It turns the demux's subtitle output off and flushes the
subtitle side at either edge. A panel on `ui` would therefore:
- hide the subtitle on screen when it opens;
- show none while it is up;
- lose that subtitle for good at the close. The flush also drops the units queued behind it.

The PSP keeps them (§1.1). Its panel has no timeout and stays up through ×, so a user may watch
with it open. A hidden subtitle there is a defect, not a blink.

**Proposed (K13): a panel mode in which the subtitle side keeps running and the host composites.**

- **A new level, `ui_sub`** ("the host's page, the subtitles still running"), beside `ui`:
  - the demux's subtitle output stays on;
  - neither edge flushes;
  - `sub_sched` runs as in playback. It requests each unit and the UMD Main decodes it into plane
    0 / 1 exactly as today: the subtitle host path does not change;
  - `sub_flip` latches and acknowledges `sub_sched`'s flips without applying them (as under
    `ui`). It **keeps the latest**, and when `ui_sub` falls it applies that one at the next vblank
    instead of hiding the plane.
- **The panel's pages live in two new plane buffers, planes 2 / 3:**
  - core words `0x0670_0000` / `0x0678_0000` (HPS `0x3380_0000` / `0x33C0_0000`), after the PCM
    region;
  - B2's bench scratch (`umd_b2.cpp`, a measurement tool, never run in play) sits at
    `0x0670_0000` today and moves past them;
  - the host flip's `buf` widens from 1 bit to 2.
- **The host composites:**
  - the panel over the subtitle that `sub_sched` is showing, into plane 2 / 3, then a host flip;
  - **what `sub_sched` shows is already in HOST_RD.** The `shown` row's `h_vis` / `h_shown_seq`
    come from `sub_sched`'s own flip requests at their acknowledgement (`sub_top.sv` ~188). They
    read through `ui`, so no new row is needed;
  - the UMD Main keeps each decoded unit's RGBA in memory, keyed by seq, for the compositor. It
    decodes the unit anyway; the extra cost is a copy;
  - the flip's rectangle is the union of the panel's region and the subtitle's.
- **The hand-back is exact.** Planes 0 / 1 held the right units all along. At the close, the
  fabric shows what `sub_sched` shows from the next vblank on.
  - **Why the restored plane is never half-written** (checked against the RTL before C3):
    - `sub_sched` decodes only into its BACK plane (`wr_buf = !front`, `sub_sched.sv` ~90);
    - it takes a new unit only when that plane is free (`q_take` needs `B_FREE`, ~93);
    - it flips to a plane only once its decode has completed (`B_READY`), and `front` changes only
      at the display's acknowledgement (~128, ~137).
    - `sub_flip` keeps acknowledging at vblank under `ui_sub`, so this bookkeeping runs as in
      playback. The plane restored is `sub_sched`'s front, which holds a whole unit.
    - A decode in flight at the close, or a flushed request's late pixels, can only land in the back
      plane, which is not shown.
  - `sub_flip_tb`'s arm for it: a unit decoded and flipped during `ui_sub`, then the fall. The
    restored frame is that unit, whole.
- **The one visible cost:** while the panel is up, a subtitle appears or changes up to ~1-2 frames
  late. That is the host's next read (≤ 10 ms while buttons are grabbed,
  `UMD_MENU_READ_KEYS_MS`), the composite and the next vblank. Measured on the rig (§4).
- **Area, estimated:** ~60-120 ALM raw: `sub_flip`'s kept request and the apply at the fall, a
  4-way base, the demux / flush gating on `ui_sub`, the level in HOST_WR. Measured with
  `synth_unit` (§3.2).

**Alternative, not proposed: a second plane in the fabric** for the host's UI, above the subtitle
plane. It was withdrawn with H5's first round at ~350-500 ALM. It would also add a third reader on
`ram2`, and occupancy is the scarce resource (`hw_budget_and_lessons.md`).

## 3. The design

### 3.1 Where each part runs

| part | where | why |
|---|---|---|
| the panel's state: open / close, the cursor, each item's availability, the action on confirm | the UMD Main: `main/support/umd/umd_panel.c` (new, pure C, PC-benched as `umd_menu_logic.c` is) | no area; a stock Main loses only the panel |
| drawing it, the subtitle under it | the UMD Main, into planes 2 / 3 (§2), through the runner's render / flip path (`umd_menu_run.h` "RENDER") | the plane is the host's under `ui_sub` |
| the panel button and the D-pad / × / ○ while open | the fabric forwards them: the host's `grab` mask, KEY events (`p9.md` §3.2 item 3) | already built |
| **the action an item triggers** | **the fabric's own button path, by a host "press" record** (§3.2) | every item then does exactly what its button does |
| the transport HUD (the pop-ups, Display, the tags) | the fabric, unchanged, drawn OVER the plane | `emu`'s compositing order (`th_rgb` takes `bg_*`, which already carries the plane) |

### 3.2 The fabric delta (stage C3, measured before a fit)

**F1. A HOST_WR "press" record.**
- `{seq, mask}`: a mask of J1 and D-pad bits in joystick bit order. It is once-only by seq and
  echoed in HOST_RD, as the command, the flip and the PCM trigger are (`hps_host.md` §2 "P9's
  rows").
- The mask is ORed in **after** the grab and Go To's take: into `btn_press`, `dpad_press`, and
  goto_ctl's `k_goto`.
- It is never ORed into `btn_all` / `hk_press`. A press there would come straight back to the host
  as a KEY event, because the panel grabs those buttons.

**Why a press, not a player command.** HOST_WR's player command (`player_ctl`'s port) reaches only
`player_ctl`. In `emu` several things hang off the button path alone:
- the HUD's `Chapter n` pop-up after Next / Prev (`cmd_next` / `cmd_prev` from `pc_cmd_v`);
- Display (`bp_disp`, the HUD's toggle, which is not a `player_ctl` command);
- opening Go To (`k_goto`, `btn_all[13]`).

A host command would skip Next's caption, and it could not reach Display or Go To at all. With
injection, each item is its button. That is how the 2026-09-27 decision put it: "The panel issues
the same commands a button does."

**The exceptions:**
- **UMD Menu** is the host's own action (the engine's `onMenu`). The panel calls the runner directly,
  with no injection.
- **Play** (found at C1) has no button: Play/Pause toggles, so it would pause a playing title. Play is
  HOST_WR's player command PLAY (code 3, `player_ctl`'s, which the disc menus already send). The HUD's
  Play pop-up fires on the state change, so it shows as for a button.
- **Pause** (2026-10-07) is HOST_WR's PAUSE (code 2) since the J1 list's Select (the PSP's ✕, the
  button the panel used to inject) became Play/Pause's toggle (`transport.md` D10): an injected press
  would resume a paused title, and K7 keeps Pause offered while paused.

**F2. Two HOST_RD status bits** (the `status` word's spare `[9:0]`):
- **`goto_open`.** `gt_take` masks Go To's keys out of `hk_press` before the grab, so once the
  editor is open the host gets no presses. The panel hides while the editor is up and comes back
  after the jump's seek (§1.1): once `goto_open` has fallen and `seeking` is clear. That covers
  one opened from the panel and one opened by the Go To button while the panel is up.
- **`sub_any`** (found at C1): the title has a subtitle track (`|rd_sub_present`). The Subtitles item is
  dark without one, and HOST_RD carried only the track in use. The host could read the CLPI itself,
  but the core's own view of the playing playlist is the one the Subtitle button acts on.
- ~~`il`, the 480i raster~~ **(dropped at C0):** the panel sits inside title safe and clear of every HUD
  slot at both rasters (§3.5), so one layout serves both and the host need not know the raster.

**F3. The panel's button.**
- Proposed (K3): **Repeat (B11, bit 14, inert since P6b6) is renamed `Control Panel`** and takes
  the X default (the PSP's triangle). Display loses that default; it is also a panel item.
- The keyboard key: `kbd_map` bit 14's, L (Repeat's today, "VLC's loop"). A better letter can
  be chosen with K3.
- This changes `CONF_STR`, so `docs_check.py`, `controls.md` and a fit follow; the seed re-rolls.

**F4. The stock-Main message.**
- The panel button without `host_ok`: a new `EV_HOST` data value, "The control panel needs the
  UMD Main."
- With `host_bad`: "Update the UMD Main for the control panel."
- These are `transport_layout.py`'s `MESSAGES`, so the HUD's bench covers them. Both go to
  `on-screen-messages.md` and `troubleshooting.md`.

**F5. The panel mode, `ui_sub`, and planes 2 / 3** (§2).

**Area, estimated:**

| part | raw ALM |
|---|---|
| F1: a record, its echo, and the ORs | ~40-80 |
| F2: 2 bits | ~5 |
| F3 | none |
| F4: a message and an event value | ~20-40 |
| F5 | ~60-120 |
| **total** | **~130-250** |

- Measured with `tools/synth_unit.sh` on `umd_host`, `sub_flip` and `transport_hud` before the fit.
- The last fit (38,815 ALM, 93 %) closed clk_dec 0.11 MHz above its floor cold. A fit that passes
  timing ships (the maintainer, 2026-10-04: no seed sweep for margin alone).

### 3.3 The UMD Main

**`umd_panel.c`, pure C, no Main dependency:**
- **Inputs:**
  - the decoded HOST_RD (`umd_menu_rd`: state, seeking, chapters, audio / subtitle tracks,
    `shown`, `goto_open`, `sub_any`);
  - KEY events;
  - the runner's state: is a disc menu up, does the engine run for this disc.
- **Outputs:**
  - the panel's grab mask and its level (`ui_sub` in playback, none over a disc menu: §3.4);
  - a press to inject (F1), or "call `onMenu`";
  - a dirty flag for the renderer.

**The behaviour (§1.1):**
- **Opens** on the panel button in playback (any play state) and over a disc menu.
- **The cursor starts on Display** at every open. ← / → wrap within a row, skipping dark items. ↑ / ↓
  go to the other row's nearest available item in the same column, clamped to a shorter row; a tie
  goes left. The cursor skips dark items (the maintainer, 2026-10-04).
- **× does the item, and the panel stays up**, except:
  - Stop: it stops, and the panel closes;
  - UMD Menu: the panel closes and the disc menu opens;
  - Go To: the panel hides while the editor is up and comes back after the jump's seek (F2).
- **Closes** on ○, the panel button, and Stop and UMD Menu from the panel. START and L / R act
  without closing it.
  - □ is the engine's (it grabs UMD Menu in playback), so the panel sees its effect, not the press:
    **a disc menu coming up or going away closes the panel**. That also covers a title's end starting
    a disc menu.
  - A mount (the core idle) closes it too.
- **Does not open with no title** (the core idle, no disc menu): the panel button is not grabbed then.
- **No timeout.**
- **Availability does not change with the play state.**
  - **By content:** Subtitle dark when the title has none (`transport_hud.md` §2's photo).
    Previous / Next with no chapters: the PSP is unmeasured; proposed available, with the HUD's
    `There is no chapter available.` as the answer.
  - **Over a disc menu:** only UMD Menu, Display and Stop (§3.4).

**The levels merge** (the runner, `umd_mr_levels`):
- `grab` = the engine's | the panel's. While the panel is up it takes the D-pad, ×, ○ and its own
  button; the engine gets none of them.
- In playback the panel raises `ui_sub`. Over a disc menu the engine already holds `ui`, and the
  panel draws into the engine's frame (§3.4).
- `menu` stays the engine's only. The panel never hides the transport HUD: the PSP's own pop-ups
  show over its panel.

**Drawing:**
- The runner's three-step render (`umd_mr_panel_want` locked, `_frame` unlocked, `_flip` locked), into
  planes 2 / 3 in playback. (The engine's own frames are pipelined since M4h: `umd_mr_draw_want` /
  `_draw_frame` / `_put_want` / `_put_frame` / `umd_mr_render_flip`, `p9.md` §3.3 "M4h".)
- It keeps the `sub_busy` wait only for the plane the engine draws, over a disc menu.
- A page is the panel's region (~600 x 200) over the current subtitle's image, if one is shown.
- **The layout stays clear of the HUD's slots**, which draw over the plane:
  - the header wash (lines 0-35; 480i 54-83) while Display is on;
  - the message strip (354-389; 480i 306-341), the caption (396), the icon row (436).
- **The PSP's panel** (rows at PSP y ≈ 59 / 90 / 122, caption at 153: raster lines ≈ 104 / 159 /
  215, caption 270) already sits between them.
- A subtitle can overlap the panel's region. The panel draws over it, as the PSP's does
  (to check on the captures in C0).

### 3.4 Over a disc menu (K9)

- **The engine owns the plane** (`ui`, its page). **The panel draws over the engine's frame**, in
  the same render, onto the same buffers. No `ui_sub`: subtitles do not run under a disc menu.
- **The engine keeps running** (its animations, its video window). It gets no keys while the panel
  is up.
- **Available:** UMD Menu, Display, Stop. Volume Boost and Help, available on the PSP, are not built
  (K1, K12).
  - UMD Menu: the engine's `onMenu`.
  - Display: toggles the overlay. The HUD is hidden under `menu`, so the toggle shows once the
    menu leaves (K15).
  - Stop: P9-6's quit: stop, and the file browser (K15).

### 3.5 Art and the model

- **The icons are this core's own** (`transport_hud.md`'s "Inspired by, not recreated"). They are
  drawn with `tools/transport_font.py`'s round pen at the PSP's proportion (~22 PSP px = ~33 x 39
  raster). They are never traced from the captures.
- **The caption uses the HUD's font** (10 x 24, 2 bits a pixel), from the same `transport_font.py`
  output: a generated C header, one source.
- **The HUD's four pixel classes map exactly onto the plane's premultiplied alpha**, so the panel
  and the HUD read as one design:
  - clear: α 0;
  - shadow (`under >> 2`): black at α ¾;
  - ink: the colour at α 1;
  - edge (`ink/2 + under/2`): ink/2 at α ½.
- The halo and the dimmed grey are the HUD's palette. New colours only if the mockups need them.
- **`tools/panel_layout.py`** (new, beside `transport_layout.py`) is the layout and the pixel
  model:
  - the mockups over rig screenshots, at 480p and 480i, at the displayed aspects, with a subtitle
    and over a disc menu;
  - later the renderer's golden, pixel-exact.

**C0, as rendered (2026-10-04)** (`tools/panel_layout.py --mockups [--il]` -> `.sim/panel_mockups[_il]/`:
each state at the raster and the displayed aspect, a 3x zoom of the panel, `sheet.png`, `icons.png`).
The backgrounds are the rig's own clean frames (Akira, Family Guy 4:3, Austin Powers 2, the Family Guy
and Akira disc menus), kept out of the repo as before.
- **The composite is the core's:** the video, the plane by `plane_blend`'s integer formula
  (`compositor.md` §3), the transport HUD over both by `transport_layout.render`.
- **The items (K1)** in two rows, 48 px apart. Row 1: UMD Menu, Go To, Audio, Subtitles, Display.
  Row 2: Previous Chapter, Next Chapter, Fast Reverse, Fast Forward, Play, Pause, Stop. The captions
  are those names (K4). **Since 2026-10-07 a third row, A-B Repeat and Clear** (`ab_repeat.md` AB8: the rows'
  tops 100 / 154 / 208, the caption row 264, the box to line 298; ↑ / ↓ wrap over three rows).
- **The icons**, drawn for this core with the HUD font's pen on a 34 x 28 canvas:
  - the transport shapes, as the HUD's, larger;
  - Audio, the quaver;
  - Subtitles, the HUD's balloon with two lines of text in it;
  - Display, an "i" in a rounded frame;
  - Go To, an arc jumping right onto a broken baseline;
  - UMD Menu, the disc (a ring and its hub).
- **The colours:**
  - selected: the HUD's white (240) over a soft white halo (peak alpha 120);
  - the rest: grey 176 (the PSP's ~178; the HUD's 150 grey read dim at this size);
  - unavailable: dark 84.
- **The geometry: one layout for both rasters.** The rows' centres are lines 114 / 168 and the
  caption's cell row 210: the PSP's places, 8 lines lower, so the box clears the 480i header wash
  (lines 54-83). The box spans x 185-534, lines 90-243: inside title safe, and clear of every HUD slot
  at 480p and 480i. So F2's `il` bit is dropped.
- **Found by the mockups: the PSP's look, the icons bare on the picture, fails on a TV.** Over a busy
  or bright frame the grey icons vanish: Akira's city, Family Guy's yellow menu, Akira's white menu,
  the "Created By" titles (the `a*_psp` tiles). The PSP's screen is small, ours is not.
  - **Proposed (K16): the panel on a rounded box in the HUD's own box tint**, `(under >> 2) + (12, 28,
    72)`, i.e. premultiplied black at alpha 191 plus the tint. Corner radius 10, anti-aliased. It
    reads over every frame tried, as the HUD's boxed captions do, and the two read as one design.
  - **The cost:** the box hides more of the picture, or of a disc menu's page, than bare icons do.
- **A subtitle placed high** (`p11`) lies under the box. It is dimmed there, still legible. The library
  places subtitles flush with the bottom (`CLAUDE.md`'s table), so this is the rare case.

### 3.6 C1, as built (2026-10-04)

- **The behaviour model: `tools/panel_ref.py`**, written from §1.1 and §8, not from any C. It is
  `umd_panel.c`'s golden (C2).
  - Inputs: `read(rd, now)` (a decoded HOST_RD) and `key(mask)` (a grabbed press). Outputs: the
    actions (`press`, `cmd`, `menu`, `quit`) and `levels()` (the grab mask; how it shows: `ui_sub`,
    `frame` over a disc menu, or nothing).
  - **Go To's return:** the panel shows again once the editor is closed and no seek is in flight, on
    two HOST_RD reads in a row (`RETURN_READS`). A jump's seek starts within cycles of the editor
    closing, so two reads cannot both fall in that gap. If the editor never opens (refused), the panel
    returns after 250 ms (`GOTO_OPEN_MS`). The cursor returns on Go To.
  - While hidden for Go To it grabs only its own button, which closes it. The editor has the keys
    (`gt_take`).
- **The art: `tools/panel_layout.py --gen`** -> `main/support/umd/umd_panel_art.{c,h}`.
  - Contents: the 12 icons' and 95 font glyphs' classes (2 bits a pixel), the captions, the
    geometry, the colours.
  - **The halo and the box's corners are integer rules** the C renderer recomputes exactly
    (`halo_rgba`, `box_rgba`), so no tables are needed. Against the approved mockups: at most one
    level on 32 corner pixels, the halo identical.
- **`tools/tests/test_panel_ref.py`** checks hand-written expectations for every rule of §1.1, §3.3
  and §3.4: arms `[open] [walk] [act] [close] [menu] [goto] [dark] [art]`, the last including the
  generated art being current. `red_umd.py` adds 14 mutations, each caught.

### 3.7 C2, as built (2026-10-04)

- **`main/support/umd/umd_panel.{c,h}`**, pure C (no Main dependency): `panel_ref.py` rule for rule,
  and `page()`'s drawing.
  - `umd_panel_read` (a HOST_RD), `umd_panel_key` (a grabbed press: the actions), `umd_panel_levels`
    (the grab mask; `UMD_PS_UI_SUB` / `UMD_PS_FRAME` / none).
  - `umd_panel_view`: one word for what the page shows. The runner redraws when it changes.
  - `umd_panel_draw`: the panel over a premultiplied page, in either byte order (`MENU_PX_RGBA`, or
    the plane's B, G, R, A). It touches only `umd_panel_rect`: the box, x 185, y 90, 350 x 154, the
    flip's rectangle. The halo (a two-pass 5 x 5 sum on a 46 x 40 canvas) and the box's corners are
    recomputed at each draw: integers only, no tables.
- **The UMD Main already compiles it**: the Makefile's `support/umd/*.c` wildcard
  (`apply_integration.py`) takes `umd_panel.c` and `umd_panel_art.c`. Nothing calls them before C4.
- **`bench/umd/run_panel.sh [--red]`** (`bench/umd/panel/panel_check.c` drives the C from a script,
  and `panel_bench.py` runs the same steps through the model and scores):
  - the model's own `tools/tests/test_panel_ref.py` first;
  - `[open] [walk] [act] [close] [menu] [goto] [dark]`: directed scripts, every answer (state,
    levels, view, actions) equal to the model's;
  - `[random]`: 40 seeded walks of 400 steps. Their coverage is checked: every state (open, hidden,
    both modes), every item selected and every kind of action reached, or the arm fails as vacuous;
  - `[pixels] [under] [plane]`: every item selected, in playback and over a disc menu, items dark
    and not (48 states over an empty page), over a real subtitle unit and a random premultiplied
    page, and in the plane's byte order. Byte-exact against `page()`;
  - `[rect]`: `umd_panel_rect` is the model's box, and neither the C nor the model draws outside it.
  - **27 mutations, each caught by its own arm** (P1-P27: the start, the wrap, the skip, the tie, what
    closes, Go To's return and timeout, Play's command, the grabs, a disc menu closing it, FF's press,
    the quit, the dark-item guard, the keys while hidden, the class mapping, the halo's and the box's
    rounding, the byte order, the blend's rounding, the caption's and the items' colours, the
    rectangle, the view).
- **Found by the RED pass:**
  - The box's `<=` on the radius cannot be told from `<`: a subsample centre sits on an odd eighth,
    so its distance never equals the radius. That mutation was replaced by the corners' rounding.
  - A directed Go To script had missed the 250 ms timeout's exact boundary (the hide took its time
    from an earlier read). It now reads at the hide.

### 3.8 C3, as built (2026-10-04)

**The host port** (`umd/umd_host.sv`, `tools/host_layout.py`; `hps_host.md` §2 "P6d's rows"):
- The rows are appended: HOST_RD 39 words, HOST_WR 40.
- **The press record:** a one-cycle pulse (`hx_v`, `hx_mask`), taken once by its seq and echoed at once
  in `press_ack`.
- `ui_sub` is `ctl[12]`; the flip's plane is `flip[2:1]`.
- HOST_RD's status gains `goto_open`, `sub_any` and `ui_sub`.

**`emu`:**
- `hx_press` (the pulse) is ORed into `btn_press`, `dpad_press` and goto_ctl's `k_goto`, after the grab
  and `gt_take`. It is never ORed into `hk_press` / `btn_all`, which `check_emu_wiring` pins.
- `gt_open`'s declaration moved above `umd_host`, which reads it.
- `show_pic` takes `host_uis`: the panel over a stop, on black (§7).
- `th_pmsg` (F4): the Control Panel button reaching the transport is the HUD's message. It shows 1
  with no host at all, and 2 with one that did not take the button (`host_ok | host_bad`): a mismatched
  PROTO, or a UMD Main older than the panel.

**`sub_flip`** (`umd/sub/sub_flip.sv`, through `sub_overlay`):
- `own = ui | ui_sub`, with the kept state `k_*` (`sub_sched`'s latest request, clipped).
- When the host gives the plane back from `ui_sub` alone, the kept state is restored at the next
  vblank. A menu's `ui` still hides, and both levels falling together hide too.
- `sub_sched`'s request and the host's flip each have their own clip path.
- `PLANE2` / `PLANE3` sit at core words `0x0670_0000` / `0x0678_0000`.
- B2's bench scratch moved to `0x0680_0000`.
- `emu`'s demux gate (`sp_on`) and its flush edges still see only `ui`: under `ui_sub` the subtitles
  keep running.

**The HUD** (F4):
- the string ROM 256 -> 512 entries, the message id 2 -> 3 bits;
- `STR_*` 9 bits, `MSG_*4` / `MSG_*5` the two panel messages at 256 / 304 (48 cells each);
- an input `pmsg`, as `unplay` is.

**F3:** `CONF_STR`'s J1 list ends in `Control Panel`, its default X (`jn,Start,A,B,L,R,Select,,Y,,,X`);
Display has no default now. `kbd_map`'s L is the panel's key. `controls.md`, `on-screen-messages.md`
and `troubleshooting.md` carry the button and the two messages, the panel itself "not yet implemented"
until C4.

**The benches, each green under `--red`:**

| bench | new arms | new mutations |
|---|---|---|
| `run_umd_host.sh` | `[press] [panel]` | H25-H31 (31 caught in all). H23 had been masked by the new arm, which rewrote the levels before the timeout: fixed, every level is now up into the timeout |
| `run_plane.sh` (`sub_flip_tb`) | `[panel]` | U7-U12, U1-U6 re-anchored; the race arm is U8 / U9 (the subtitle flipped during `ui_sub` restored whole; a hide restored as hidden) |
| `run_transport_hud.sh` | b21 / b22 | H43-H45, H23-H26 re-anchored |
| `run_scaffold.sh` (`check_emu_wiring`) | | W113-W122, W105 re-anchored |

`run_overlay.sh` and `run_hps_host.sh` are green too.

**The fit (SEED 9, the pinned seed, commit `a9383cf`):** 38,832 ALM (93 %, +17 over the last fit), RAM
438, DSP 87. clk_dec **MISSED** at 85.86 / 85.40 MHz against the 86 floor
(`UMD_panel_MARGINAL_20261005_0247.rbf`).
- The `CONF_STR` change re-rolls the seed, and the fit before it passed by 0.11 MHz cold, so the miss is
  the seed's, not the panel's logic (all of it on clk_sys).
- Per entity against that fit: `umd_host` 601 -> 656 (+55), `sub_flip` 86 -> 135 (+48), `emu`'s own
  215 -> 235, the HUD +2.5, `kbd_map` +2: about +130, the bottom of §3.2's 130-250 raw.
- A2': a 5-seed sweep (1 3 5 7 11, stopping at the first pass): **SEED 1 PASS 87.79 / 87.52 MHz, 38,732 ALM
  (92 %), SEED 1 pinned** (`UMD_panel_20261005_0314.rbf`).

### 3.9 C4, as built (2026-10-05)

**C4a, the host-row logic** (`umd_menu_logic.{c,h}`):
- a press channel: queue, seq, the echo, the seqs adopted at the start as the others;
- `ui_sub` in `ctl[12]`; the flip's plane 2 bits;
- HOST_RD's `goto_open`, `sub_any`, `ui_sub`, `press_ack` and the `shown` word (`sub_vis`, `sub_seq`)
  decoded.
- `host_menu_check`'s core model takes a press record at once by its seq. S6 scores every press exactly
  once and in order, every flip's plane, and `ui_sub` (28,102 presses over 200 seeds).
- `run_menu.sh` U12-U15, each caught.

**C4b, the runner** (`umd_menu_run.{c,h}`):
- The panel runs whatever the engine does.
- **Keys:** a grabbed press goes to the panel when its grab covers the button, else to the engine.
- **Actions:** a press record, PLAY as a player command, UMD Menu as the engine's own key (its
  `onMenu`), Stop over a disc menu as P9-6's quit.
- **Levels:** the panel's grab ORed into the engine's; `ui_sub` from its show mode.
- **Over a disc menu:** drawn onto a copy of the engine's frame, which stays the incremental renderer's
  base.
- **In playback:** `umd_mr_panel_want` / `_frame` / `_flip` draw the page into plane 2 / 3. The union of
  the panel's box and the subtitle's rectangle is cleared, the subtitle read back from its plane, the panel
  drawn over it, and the rectangle written and flipped. It is redrawn on a change of view or subtitle, or
  when `ui_sub` rises.
- A mount resets the panel.
- `bench/umd/panel/panel_run_check.c` (`run_panel.sh`'s `[run]`) drives the real runner with no disc. Its
  arms are `[levels] [route] [act] [page] [close]`; the page's box is checked against the panel on a
  cleared page. R1-R12, each caught.
- Over a disc menu, the panel is benched only through the engine-free arms: its frame path is the rig's
  (C5).

**C4c, the glue** (`umd_host.cpp`, `umd_menu.cpp`):
- `umd_host.cpp` keeps per subtitle plane the unit last decoded into it whole (seq, rectangle). A decode
  starting voids the entry; another core clears both. `umd_host_unit()` answers the runner's `sub_unit`.
- `plane_get` reads a rectangle of plane 0 / 1 back with uncached 32-bit loads (the front plane, which
  nothing writes meanwhile).
- `plane_put_rect` writes planes 2 / 3 (HPS `0x3380_0000` / `0x33C0_0000`), then a barrier.
- The worker draws the panel's page after the engine's.
- `/tmp/umd_menu.json` (the HIL's) gains `panel_open`, `panel_sel`, `panel_pages`, `panel_acts`,
  `presses`, and the read-back and write times.
- The UMD Main builds.

### 3.10 C5, on the rig (2026-10-05)

`UMD_panel_20261005_0314.rbf` (SEED 1) and the UMD Main from C4c, on the maintainer's rig. That rig
outputs **480i** to a CRT, so the HUD and the panel were seen in their title-safe layout. Shots are in
`.sim/rig_p6d/` (not committed: the films' frames).

**On Akira, Disc Menus Off (no engine), every gate passed:**
- **Open:** the panel opens on Display, as mocked; UMD Menu is dark (no engine). The page is written in
  4.4 ms.
- **The walk:** ↓, ← ← ← to Next Chapter.
- **Next Chapter:** × jumps to chapter 2, the HUD pops `Chapter 2` and its icon, and the panel stays up
  (K5).
- **Subtitles under the open panel** (K2 / K13): switched on with their own button while the panel was up.
  Four lines over 18 s, each composited under the box, none lost. Read-back 3.0 ms, the page write (the
  union) up to 19.5 ms.
- **Go To from the panel:** the panel hides, the editor opens, × ↑ × jumps to chapter 3, and after the seek
  the panel returns on Go To (K5 / K14's path).
- **○ closes it:** the picture is clean, with no leftover panel, and the subtitles go on.
- **Stop from the panel:** the title stops (the idle screen) and the panel closes. Reopened over the stop
  it shows on black (§7).
- **Play from the panel:** resumes the stopped title; the panel stays up.

**On Family Guy, Disc Menus On, over its main menu, every gate passed:**
- **Open:** the panel opens over the disc's page: UMD Menu, Display and Stop lit, the rest dark, the walk
  skipping them. The menu's text shows darkened under the box (the composite, checked zoomed).
- **UMD Menu:** × closes the panel, and the engine gets its Square key: the disc's `onMenu` runs (the
  trace).
- **Stop:** P9-6's quit: the disc's `onExit`, its kept data stored, the engine stopped, the OSD opened.

**On a stock Main**, Control Panel shows `The control panel needs the UMD Main.` in the message strip.

**After C5, on the PC:** `run_menu.sh` (the disc-menu gate, through the changed runner) is ALL GREEN over the
library: `[mhost]` 64 scenarios x 3 seeds, the 28-scenario gate, `[host]`. `tools/tests/run_tests.sh --red`
and the whole `run_scaffold.sh --red` are green too.

**Not covered on the rig:**
- the 480p layout (this rig is 480i; the mockups and benches cover both);
- `Update the UMD Main for the control panel.`;
- a press's latency, measured on the target: the cursor kept pace with ssh-paced presses, which bounds
  nothing below ~1 s;
- Go To cancelled (○ in the editor), whose panel should come back at once (K14): only the jump's path ran.
- Audio, Subtitles, Display, Fast Forward / Reverse and Pause from the panel. They are each a press record (Pause a
  command since 2026-10-07, F1's exceptions)
  as Next is, and `run_panel.sh` / `run_scaffold.sh` cover their bits.

### 3.10b The owed checks, on .201 (2026-10-05)

`UMD_bare_20261005_1945.rbf` (SEED 5, `main` 81dede1) and the UMD Main from `main/` (C4c's), on the
SuperStation One (.201, its analog out to a 480i CRT, so the Auto raster is 480i). Akira, Disc
Menus Off. Every item §3.10 left open:

- **The 480p layout:** the OSD's Video Output set to Progressive for ~40 s twice (the maintainer
  allowed it with the CRT attached; telemetry's `il` 0, the HUD's 480p geometry in the shots). The
  box at x 185-534, y 90-243 (`panel_layout.box_geom`, one layout for both rasters); the header
  wash at lines 0-35 above it, the chapter / time / bar along the bottom; Audio, Subtitles and
  Go To cancelled worked there as at 480i.
- **From the panel:** Pause, Play, Fast Forward (`Forward 1`, the panel up), Fast Reverse
  (`Reverse 1`), Display (the overlay under the panel), Audio (the first × shows `♪ 1 English`, the
  second `♪ 2 Japanese`), Subtitles (shows the state, then switches). ✅
- **Go To cancelled:** × hides the panel and opens the editor (the time box white, the marker over
  the bar); ○ closes it and the panel is back on Go To at once. ✅ (One shot at 480p, 1 s after ×,
  showed the panel hidden but the editor not drawn, a subtitle tag still up; not reproduced in four
  tries at 480p and 480i, with and without a subtitle change just before. Recorded, not chased.)
- **`Update the UMD Main for the control panel.`:** a UMD Main built from `a9383cf` (the panel's
  fabric, not the Main's side: host link up, the button not grabbed) shows it in the message strip
  at the button. ✅
- **The 10 ms poll:** `b2 poll 20` over 20 s of playback with the panel closed (the keys rate,
  subtitles on): 437,729 passes, median 39 us, p99 97 us, p99.9 3.3 ms, max 4.2 ms, none over
  50 ms -- Main stays responsive. (Main's own loop spins at 100 % of its core, as stock Main does:
  the poll is a coroutine on it; the other UMD threads 0-1.7 %.)
- **A press's latency:** not measurable from here (the state file is written every 250 ms; there
  are no per-press timestamps). By design it is ≤ 10 ms (the keys poll) + the page write (4.2-10.8
  ms measured, `pput_us`) + the next vblank. **Throughput:** 14 presses 100 ms apart and 14 at
  150 ms all land (the cursor exact after two laps of the 7-item row). 41 presses "50 ms apart"
  looked like half were lost -- **corrected the same day: none were.** `mister.py seq` sends each key
  as the HIL daemon's `keys` command, which holds 50 ms and then sleeps 120 ms, so the daemon
  delivers one key per 170 ms whatever the asked spacing, queueing the rest in its FIFO
  (`hil_harness.md` "Facts that bite"). The run lasted 3.65 s and was read at its end: ~(3.65 - 0.6) /
  0.17 = 18-21 keys delivered by then, and 21 pages were drawn, the cursor where 22 presses put it.
  The path itself is edge-exact: `kbd_map` makes a one-cycle pulse per make code, `umd_host` queues
  each grabbed press as a KEY event (8 deep, an overflow counted in `ev_lost`), the UMD Main posts
  one action per event.

### 3.11 After the maintainer's test (2026-10-05): Audio and Subtitle show first

**The maintainer, testing the panel on the rig: "the panel looks great and works fine". One change:**
subtitle and audio selection show the current selection at the first press, and the second press cycles.
- **Decided with the maintainer:** the dedicated buttons too, not only the panel's items. A second press
  cycles while that track's tag is up (about 3 s); after it has gone, the next press shows again (the PSP's
  pattern).
- **In the fabric, so the panel follows by construction** (its items are the buttons' presses). `emu`: an
  Audio / Subtitle press whose tag is not up becomes `th_show_aud` / `th_show_sub`, a HUD pulse that pops the
  tag with `player_ctl`'s current values (`aud_track`, `sub_on`, `sub_track`). It is not a command:
  `btn_cmd` drops it. A press while the tag is up (`transport_hud`'s `tag_aud` / `tag_sub`: the TRACK
  pop-up, by kind) goes on as AUDIO / SUB.
- Subtitle without the UMD Main goes straight to SUB, whose "needs the UMD Main" message is the answer.
- `player_ctl` is unchanged. Neither an AUDIO_SET of the current track nor a SUB_SET could have served:
  the first posts nothing, the second's tag is suppressed as the disc's (M4b).
- **Benches:**
  - `run_transport_hud.sh`: b23-b25, the tags reached through the show pulse, pixel-exact against the same
    model (`via_show`); the testbench's `[tags]` check of the levels; H46-H49.
  - `check_emu_wiring`: `th_show_*`, `btn_cmd`, the HUD's ports; W123-W126.
- **Fit:** SEED 1 PASS 88.04 / 87.82 MHz, 38,676 ALM (`UMD_panel_20261005_0444.rbf`, a clean tree at `172718a`).
- **On the rig (2026-10-05):**
  - Akira's Audio button: the first press showed `1 English` (nothing changed), the second (within ~1 s)
    switched to `2 Japanese`, and a press after the tag had gone showed `2 Japanese` again.
  - Subtitle (Aliens): `Off` shown, then `1 English`.
  - The panel's Audio item: × showed the current track, the next × switched it.
  - Aliens has one audio track: its second press changes nothing, as before.
- **Known:** while Go To's editor holds the caption row, a shown tag is not drawn, but its level still
  makes the next press a cycle. That is rare, and the second press's own tag then shows.

## 4. Verification

| what | how | RED |
|---|---|---|
| the panel's decisions (open / close, the cursor walk, availability in playback and over a menu, the action per item, Go To's hide and return, the levels merge) | `bench/umd/run_panel.sh`: `umd_panel.c` driven by scripted HOST_RD sequences and KEY events, vs `tools/panel_layout.py`'s behaviour model (written from §1.1's PSP measurements, not from the C) | each rule a mutation caught by its own arm |
| the pixels | the C renderer's page vs `panel_layout.py`, pixel-exact, every mockup state, 480p and 480i, with and without a subtitle | a class mapping, an icon, the halo, a 480i offset, the subtitle under it |
| F1 / F2 | `run_umd_host.sh`: the press record (once-only, echo, a press never looped back to KEY), `goto_open` | H-arms |
| F5 | `run_plane.sh` (`sub_flip_tb`): under `ui_sub` no flush, the latest request kept and applied at the fall, planes 2 / 3 addressed; the demux's subtitle output on under `ui_sub`, off under `ui` | U-arms |
| the `emu` wiring | `check_emu_wiring.py`, `run_scaffold.sh --red` (the injected press reaching `player_ctl`, `bp_disp`, `k_goto`, never `hk_press`) | W-arms |
| the runner | `menu_host_check.c`: the panel beside the engine (the panel over a disc menu, UMD Menu from the panel, `ui` / `ui_sub`), the subtitle under the panel following `shown` | M-arms |
| F4 | `run_transport_hud.sh`: the two messages, pixel-exact | H-arm |

**The rig gates:**
- Every item does what its button does (the HUD's pop-ups included).
- Go To from the panel (the panel hides, then returns after the seek), and the Go To button with
  the panel up.
- UMD Menu from the panel; the panel over a disc menu.
- The stock-Main message.
- 480i inside title safe (the CRT, the maintainer).
- **Subtitles under the open panel:** on, changing, and gone at their times. At the close, the one
  showing stays with no blink, and the next shows on time.
- **The latencies**, timestamped in the UMD Main's own stats. An ssh-paced press cannot measure
  them (CLAUDE.md's HIL lesson).
  - A press to the selection on screen (the KEY event's arrival, the flip's echo): within ~2
    frames.
  - `sub_sched`'s flip to the composite on screen, under the panel: ~1-2 frames (§2).

## 5. Stages

| stage | builds | gate |
|---|---|---|
| **C0** | `tools/panel_layout.py` + the icons; the mockups (playback, a subtitle under it, a disc menu, 480i) | ✅ approval of the mockups (K1-K15 ✅ taken 2026-10-04) |
| **C1** | the art header (icons + font) and the model's behaviour scripts | `tools/tests` |
| **C2** | `umd_panel.c` + its renderer and the subtitle composite, on the PC | `run_panel.sh --red` |
| **C3** | the fabric: F1-F5, the `CONF_STR` rename | `run_umd_host.sh`, `run_plane.sh`, `run_transport_hud.sh`, `run_scaffold.sh --red`; `synth_unit`; one fit |
| **C4** | the glue: the runner's levels merge, the render, planes 2 / 3, the kept subtitle images, `umd_menu.cpp` / `umd_host.cpp` | `menu_host_check`, `run_hps_host.sh`; the UMD Main builds |
| **C5** | the manual (`controls.md`: the button and the panel; `on-screen-messages.md`, `troubleshooting.md`, `compatibility.md`), the rig gates | `docs_check.py`, `mkdocs build --strict`; §4's rig gates |

## 6. Spec maximum

- **Chapters:** u16. Availability tests `n_chapters`, never a table.
- **Tracks:** the panel reads HOST_RD's track fields as the HUD does: audio 0x00-0x0F, subtitles
  0x80-0x9F.
- **The subtitle under the panel:** any rectangle inside 720 x 480, as the plane takes it. The
  flip's rectangle is the union with the panel's.
- The panel holds no format structure of its own.

## 7. Known limitations (planned)

- **Over a stopped title the panel sits on black, not on the idle wave** (decided at C3 as a known
  limitation; K7 needs it to open there). The plane is composited over the picture only (`emu`'s
  `show_pic`). A stop shows the wave instead, so the panel adds `ui_sub` to `show_pic`, as the disc
  menus' `ui` does over a stop, and the picture under it is the stop's black. Putting the plane over
  the wave would mean aligning `xmb_wave`'s LAT 4 with the overlay's LAT 7. The stop state was never
  mocked (p06 is paused); the rig judges it.
- **Subtitles under the open panel are ~1-2 frames late** (§2). Without the panel they are on the
  STC, as before.
- **Stock Main:** no panel, a message. Every action stays on its button.
- **The HOST_RD poll runs at the keys rate through all playback, with or without Disc Menus.** The
  closed panel grabs its own button whenever a title is up, so the host-row logic's `want_fast` /
  `keys_only` stays on: HOST_RD every 10 ms (`UMD_MENU_READ_KEYS_MS`). Before, with Disc Menus Off, the
  subtitle side's own rate applied: 50 ms without subtitles. B2 measured the poll thread at 47 % of a CPU
  at a 2 ms rate; the 10 ms cost is not measured (owed to the rig; the poll thread also serves the core's
  sector reads). Akira played without an artefact through C5, but no one was measuring it.
- **Not built, and not shown** (K1): Volume Boost, Help, Angle, Screen Mode, Slow Motion, Frame
  Advance, A-B Repeat, Repeat, CLEAR.
- **A panel press reaches the core ≤ 10 ms after the KEY** (`UMD_MENU_READ_KEYS_MS`, the poll
  rate while buttons are grabbed). Then a render and a flip at the next vblank.

## 8. Decisions

| # | question | answer / proposal |
|---|---|---|
| **K1** | Which items appear | **✅ TAKEN: the built features only** (§1's left column, 12 items, two rows; row 3 gone). The panel's job is discoverability, and permanently dark icons teach nothing. **Alternative:** the PSP's layout with the unbuilt ones dark, minus Volume Boost. Over a disc menu, 9 of the 12 are dark either way (§3.4) |
| **K2** | Subtitles under the panel | **MEASURED: they stay visible.** The design follows: §2, K13 |
| **K3** | The panel's button | **✅ TAKEN: Repeat (B11) renamed Control Panel, default X** (the PSP's triangle); Display loses its default (it is in the panel) |
| **K4** | The caption | **✅ TAKEN: the action's name alone** ("Next", "Fast Forward"). The PSP adds its fixed shortcut ("Next [R]"), but a MiSTer pad is remappable, and Main's mapping is not the core's to name |
| **K5** | × on an item | **MEASURED: the panel stays up.** Only UMD Menu and Stop close it. Go To hides it while the editor is up; it returns after the jump's seek |
| **K6** | Buttons while the panel is up | **MEASURED (the proposal held): ○ and △ close it; START, L / R and □ act as usual.** □ (UMD Menu) closes it by K5 |
| **K7** | Availability by state | **MEASURED: no change with the play state** (play, pause, stop, fast forward / reverse). Dark only by content (no subtitles) and over a disc menu (K9) |
| **K8** | The cursor at an open | **MEASURED: on Display.** The walk (wrap, column kept) is proposed, not measured |
| **K9** | △ in a disc menu | **MEASURED: the panel opens**, all dark but UMD Menu, Volume Boost, Display, Help and Stop: here UMD Menu, Display and Stop (§3.4) |
| **K10** | A timeout | **MEASURED: none** |
| **K11** | During trick play | **✅ TAKEN: opens, FF / REW keep running**; ← / → move the cursor, not the speed, while it is up |
| **K12** | Help and Screen Mode | **✅ TAKEN: out of v1.** Cheap on the HPS (Help a page of the button map, Screen Mode the OSD's Aspect from Main), but they are new features, not the panel |
| **K13** | How subtitles stay under the panel | **✅ TAKEN: §2**: the panel mode `ui_sub` (the subtitle side keeps running, no flush), the panel's pages in planes 2 / 3, the host compositing the shown subtitle under the panel; ~60-120 ALM raw; subtitles ~1-2 frames late while the panel is up. **Alternative:** a second fabric plane, ~350-500 ALM and a third `ram2` reader |
| **K14** | Go To cancelled (○) from the panel | **✅ TAKEN: the panel returns at once** (no seek to wait for) |
| **K15** | Over a disc menu: Display and Stop | **✅ TAKEN:** Display toggles the overlay, seen once the menu leaves; Stop is P9-6's quit (stop, the file browser), as Circle at a menu's top page |
| **K16** | The look (found at C0) | **✅ TAKEN (the maintainer, 2026-10-04: "superior"): the box** (§3.5 "C0, as rendered"): the HUD's box tint behind the panel, for a TV; **alternative:** bare, as the PSP draws it |

## 9. Status edits owed with each stage

- `docs/roadmap.md` "Where the work stands" and Phase 6;
- CLAUDE.md's status block;
- `p6c.md` §9's pointer;
- `transport_hud.md`'s "Superseded (D10)" header;
- `transport.md` D10's row;
- `hps_host.md` H5's row;
- `compatibility.md`.

These were all made with this plan, as 📐 planned. Each stage flips them.

**Done:** ✅ MERGED (PR fj#46, 2026-10-05). The checks owed at the time (the 480p layout, the stale-Main message, a
press's latency) were taken on .201 the same day (§3.10b; the latency not measurable from the harness).
Done in C5 (kept for the record):
- The core and `MiSTer_UMD` together, the rig gates of §4 (every item, Go To's hide and return, the
  subtitle under the open panel, the stop, 480i, the stock-Main message, the latencies from
  `/tmp/umd_menu.json`).
- Then the manual: the panel's "not yet implemented" admonitions go.
