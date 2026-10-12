# P6b — the transport HUD: design reference (the PSP video player)

The transport HUD (play / pause / seek / chapters, track select, the status overlay)
takes its **inspiration from the PSP video player's design language**, not MiSTer_DVD's
VCR / set-top HUD (decided by the maintainer, 2026-09-27). This note records what that
language is, measured from the maintainer's captures, before any planning. The plan
comes after it.

**Inspired by, not recreated (the maintainer, 2026-09-27).** The PSP player is the
reference for the FEEL -- flat and quiet, monochrome with one accent colour, a rounded
typeface, a panel of icons with a caption, the overlay's arrangement, how things appear
and go -- not a spec to reproduce. The icons are this core's own designs: the universal
transport symbols (▶ ‖ ■ ▶▶ ◀◀ |◀◀ ▶▶|) are everyone's, but the PSP's own pictograms
(Scene Search, Go To's curved arrow, the ⓘ+ Display badge, the Subtitle balloon, the A-B
and Repeat marks) get our own interpretations, and the whole set is drawn to fit this
core's raster and font. The positions and colours measured below are reference points
to design from, not values to match.

**Source.** A capture of a PSP playing a Memory Stick video (the PSP's firmware blocks
screenshots in the player; captured externally), and seven photos of the UMD player on
Akira (`umd_player/`), 2026-09-27, kept OUTSIDE this repo in
`${UMD_REFS_DIR}/psp_video_ui/`. They are Sony's artwork: never commit them, and never
trace their bitmaps -- this core draws its own glyphs in the same style. The Memory Stick
player and the UMD player share the control panel's layout; the UMD player's own items
and overlays are in §2 and §3.

**Superseded (D10, the maintainer, 2026-09-29): the panel is dropped**; every action gets a
button, the D-pad or the OSD (`transport.md` §8, D10's map). The panel sections below (§2)
stay as the reference measured from the PSP, not as a plan. The original decision follows.
**Revisited (the maintainer, 2026-10-03): the panel returns on the HPS** (the UMD Main draws it on
the plane; the buttons stay): P6d, planned in `panel.md`, which builds on §2 here.

**Decided (the maintainer, 2026-09-27): shortcuts AND a panel, as the PSP does.** Direct
buttons for the frequent operations, and a pop-up panel on one button for the rest.
Staged: **P6b** the direct buttons and the Display overlay (it builds the icon set, the
compositing and the command path to the player control block, `menus.md` §6); **P6c**
the panel on top of them, each item added only as the feature behind it exists. The
panel issues the same commands a button does.

Coordinates are in PSP pixels (480 x 272, square); on this core's 720 x 480 raster
(anamorphic 16:9) multiply x by 1.5 and y by 480 / 272 = 1.765.

## 1. The states

| State | What is on screen |
|---|---|
| Playing, idle | nothing but the picture |
| After a start or a state change | the play-state glyph bottom-left (a white ▶, ~16 x 10 at x 14, y 250-265) and a "△ Control Panel" prompt bottom-right (a rounded dark pill, grey 54, white text); both fade after a few seconds |
| A shortcut used (no panel) | **only that operation's icon pops** (bottom-left, where the play-state glyph sits); the progress bar does NOT appear (maintainer's note) |
| Fast forward / reverse | bottom-left: a label box ("Forward 1" ... "Forward 3") above the ▶▶ / ◀◀ icon, the speed as **a digit in a small filled circle beside it** (1-3); the same icon at every speed (the maintainer's note and photos) |
| A track or mode changed | a tag bottom-left: its icon + the new value, e.g. "♪ 2 Japanese" (audio: the track number and its language), "💬 Off" (subtitles), "A-B" beside the play-state glyph |
| Control Panel (△) | three rows of icons over the picture, a caption under them naming the selected icon and its shortcut button |
| Display (the panel's ⓘ+ item) | a header bar, the elapsed / total time and the progress bar, persistent until turned off |
| Go To | the time field becomes an editor, **or a chapter selector** (`Chapter 30`: the number in a light box, ▲ / ▼ above and below it); either way a blue ▼ above the bar marks the target, confirmed with × (below) |
| A refusal (Next at the last chapter) | **a message band**: a full-width translucent light band over the lower ~40 % of the picture, one centred line in white with a dark drop shadow: `There is no chapter available.` (photo `no_chapter_message`) |
| Screen Mode | a tag bottom-left: an icon + the mode's name ("Normal"), on a dark box |

## 2. The control panel

Three rows, centred in the upper half (row centres at y ≈ 59, 90, 122; caption at
y ≈ 153), icons ~22 px wide on a ~32 px pitch:

- **Row 1:** Scene Search, Go To, Audio Options (♪), Subtitle (a speech balloon; shown
  DIM when the title has none), Screen Mode, Display (ⓘ+), Help (?).
- **Row 2:** Previous (|◀◀), Next (▶▶|), Fast Reverse, Fast Forward, Slow Motion
  (|▶), Frame Advance (||▶), Play, Playback Speed (+), Playback Speed (−), Pause, Stop.
- **Row 3:** A-B Repeat, Repeat, SHUF, CLEAR. SHUF / CLEAR (and likely the speed
  controls) are the Memory Stick player's.
- **The UMD player's panel** (photos on Akira): row 1 is **UMD Menu** (where the Memory
  Stick player has Scene Search: it opens the disc's own menu -- P9's RCO menus,
  `menus.md`), Go To, Audio Options, **Angle** (a camera), Subtitle Options, **Volume Boost** (a
  magnifier with a speaker: cycles Normal / +1 / +2 -- **NOT built here**: MiSTer's stock
  Main already boosts a core's audio, the maintainer 2026-09-27), Screen Mode, Display,
  Help; row 2 is
  Previous, Next, Fast Reverse, Fast Forward, Slow Motion, Frame Advance, Play, Pause,
  Stop -- **no playback-speed controls**; row 3 is A-B Repeat, Repeat, CLEAR -- **no
  SHUF**. Items that do not apply at the moment are dimmed (Fast Reverse / Forward in one
  photo).
- **Selection:** the selected icon turns white (222) with a soft halo (~98 at its edge);
  the rest are grey (178); an unavailable one is dark grey. The caption names it with its
  direct shortcut: "Play [START]", "Fast Forward (→)", "Fast Reverse (←)", "Next [R]",
  "Scene Search [□]", "Playback Speed (−) (↓)", plain for the rest.

## 3. The Display overlay

- **Header bar:** full width, y 0-22. Memory Stick player: flat grey 46, film icon +
  file name left, date and time right. **UMD player: translucent over the picture (a
  light blue-grey wash), the film icon and the disc's title only** (no date or time).
- **Time:** bottom-right at y ≈ 233, `hh:mm:ss/hh:mm:ss`, **elapsed in blue (14, 51, 170)**,
  the slash and the total in white (~243). **UMD player: a "Chapter n" label to its
  left**, and every text element on a dark, blue-tinted translucent box so it reads over
  any picture (the chapter, the time, the track tags, the FF / REW label).
- **Progress bar:** x 176-474, y 256-260 (~5 lines), light grey (222). **In UMD playback
  the elapsed part fills solid blue, no tick or pointer** (the maintainer's note, and the
  photos: a mid blue fill, the rest light); the Memory Stick player shows it plain.
- **Play-state glyph** bottom-left as above.
- **Go To:** the time becomes a grey box (118) with the digit pair being edited lighter
  (142) and ▲ / ▼ above and below it; a small blue ▼ (14, 54, 223) above the bar marks
  the target position. **Go To also selects a chapter** (photos `goto_chapter_30`,
  `goto_chapter_6`, 2026-09-27): `Chapter` then the number in a lighter box with ▲ / ▼
  above and below it, placed where the chapter label sits, and the ▼ marker at that
  chapter's position on the bar. The maintainer's walk-through: both boxes show above
  the bar (`Chapter n`, then the time; the time alone on a title without chapters); the
  chapter box is highlighted first and ← / → move between them; selecting one opens it
  for ▲ / ▼; the time box edits hours, minutes and seconds separately, ← / → between
  them; × confirms.
- **The overlay keeps counting during fast forward** (`akira_7`: `Forward 3`, the time at
  00:20:14 and moving).

## 4. The style, reduced to what the fabric draws

- **Flat, monochrome, one accent:** white / greys on the picture, a single blue for
  "where you are" (elapsed time, progress fill, the Go To marker). No gradients beyond
  the selection halo and the header bar's slight shading.
- **Type:** a rounded sans in the spirit of the PSP's system font, drawn for this core;
  digits with open, round shapes.
  `umd/hud_font.mem` today is the diagnostic HUD's blocky font: the transport HUD needs
  its own glyph set (digits, `:` `/`, the letters of its captions) and an icon set, drawn
  for this core.
- **What costs what, in fabric:** icons and glyphs as 1- or 2-bit bitmaps in M10K (an
  icon set of ~25 at ~33 x 18 on the 720 x 480 raster is a few blocks); the halo as a
  2-level outline; the pill and boxes as flat rectangles (rounded corners as a few
  masked pixels); the header bar either opaque (as captured) or the half-dim the
  diagnostic HUD already does. Fades as a few alpha steps, not true blending.

## 5. Open, to settle when planning

**Planned 2026-09-27: `transport.md`** (the stages, the seek beneath the HUD, and the
decisions still open, D1-D8). The points below are settled there or carried as those
decisions.

- The UMD player's panel is known (§2). **Its options CYCLE in place** (the maintainer,
  2026-09-27): each press of Audio / Subtitle steps to the next value and the tag
  bottom-left shows it ("♪ 2 Japanese", "💬 Off") -- no list to open, so no menu logic
  beyond a counter per item. **Volume Boost is left out**: MiSTer's stock Main already
  has a core audio volume boost; reimplementing it in the core would only stack two gains
  (the maintainer, 2026-09-27).
- The controls: the PSP's △ / □ / START / L / R / the d-pad against MiSTer's gamepad
  mapping (`J1` in `CONF_STR`) and the keyboard.
- The subset P6b builds first (the progress bar, the time, the play-state / FF-speed
  icons, pause / seek / chapters) against the whole panel (P6b+).
- Where it composes: over the picture in `emu`'s final mux, beside the diagnostic HUD
  (P9's plane compositor, `menus.md` §6, may take it over).

## 6. The P6b5 design (2026-09-29; ✅ approved by the maintainer the same day)

The mockups come first (`transport.md` §3): **no RTL until the maintainer approves them.**
Two tools write the design down once:

- **`tools/transport_font.py`** draws the font and icons. It emits `umd/transport_font.mem`
  and a preview sheet in `.sim/`.
- **`tools/transport_layout.py`** is the layout and pixel model.
  - `--mockups --bg KEY=PNG ...` renders every state (its `MOCKUPS` list) over 720 x 480 rig
    screenshots (`mister.py shot`). It writes each state at the raster and at the displayed
    aspect (16:9 → 854 x 480, 4:3 → 640 x 480), plus a contact sheet, all to
    `.sim/p6b5_mockups/`.
  - The backgrounds are frames of the films, so they and the renders stay out of the repo.
  - Later the same model is the bench's golden (`run_transport_hud.sh`, pixel-exact).

**What is approved is what ships.** Every colour is the fabric's arithmetic on 8-bit channels
(shifts, adds, constants; never a float alpha). The golden and the RTL cannot drift apart by
rounding.

### 6.1 The font and the icons

- **Drawn for this core, not a typeface.** Each glyph is a few strokes (lines, rounded
  rectangles, arcs) stamped with a round pen and supersampled 8 x 8. The rounded look comes
  from the pen. Nothing is traced from the PSP captures, and no TTF is rasterised (no
  licence to credit).
- **The cell is 10 x 24 raster pixels, monospaced.**
  - The glyphs are designed on a 12 x 24 grid and drawn at x x 10/12. A 16:9 title shows a
    raster pixel ~1.19 wide, so there they read at about their designed proportions. On a 4:3
    title (Family Guy) they read narrower.
  - The first pass used 12-pixel cells: on 16:9 it read like a terminal (`A k i r a`).
  - The four widest letters (M W m w) use a thinner pen: three stems in ten pixels.
- **2 bits a pixel, four classes:**
  - 0 clear: the layer below.
  - 1 shadow: the layer below `>> 2`. It is the drop shadow at (+1, +1) and the digit cut
    out of a speed badge.
  - 2 ink: the cell's colour.
  - 3 edge: `(ink >> 1) + (under >> 1)`, one level of anti-aliasing.
- **128 glyphs, 7-bit index.**
  - 0-94 are ASCII 32-126 (a title byte maps by one subtraction).
  - 95-116 are the icons: ▶ ‖ ■ ▶▶ ◀◀ ▶▶| |◀◀ (two cells each), ♪, the film mark (two
    cells), the speed badges ①②③, the placeholder (a hollow box), the ellipsis.
  - 117-118: the subtitle tag's speech balloon (P7, an outline: `subtitles.md` §7 S5).
  - 119-127 are spare. (P6c's panel, now dropped, would have needed an 8-bit index.)
- **ROM:** 128 x 24 words of 20 bits, address = glyph x 24 + row: **6 M10K** (1024 x 10,
  two wide).

### 6.2 The layout (720 x 480 raster)

- **A grid of 69 columns at x = 12** (to x 701), and **four text slots**, each one row of
  cells at a fixed line:

| slot | top line | holds |
|---|---|---|
| header | 6 | the film mark and the title (Display) |
| message | 360 (was 328) | one centred line (the message strip, below) |
| caption | 396 | left: the pop-up caption, boxed; right: `Chapter n` and the time, boxed (Display) |
| icon | 436 | left: the state icon, and the speed badge in trick play |

- **The plane** holds 4 slots x 128 cells of {glyph 7, colour 2}, 512 x 9: **1 M10K**. It is
  written at event rate, as `p2_diag` writes `diag_hud`'s.
  - The colours are white (240,240,240), **the accent (64,156,255)**, grey (150,150,160) and
    dark (24,24,32).
  - The PSP's elapsed blue (14,51,170) was measured on black. On a dark box over a picture it
    does not read, so the accent is lighter. It is the one accent: the elapsed time and the
    bar's fill.
- **Box spans:** up to 4 of them, each {slot, x0, x1}, reaching 3 px past their first and
  last cells. The fill is `(under >> 2) + (12,28,72)`, a dark blue tint.
- **The header wash** (lines 0-35) is `(under >> 1) + (40,52,84)`.
- **The message strip** (lines 354-389: one text row just above the caption row) is
  `(under >> 2) + (40,48,76)`. Its line is white with the font's shadow. **Changed 2026-10-01
  (the maintainer, `docs/analog.md` §8):** P6b5 had a band from line 306 to the bottom (the PSP's
  lower ~40 %); once the 480i layout moved the HUD inside title safe it covered half the screen,
  and the strip was chosen for both rasters.
- **At 480i the whole layout moves inside the title-safe area** (80 %: x 72-647, y 48-431;
  `docs/analog.md` §8): 57 columns from x 75, the header at line 54 (its wash to line 83), the
  message / caption / icon slots at 312 / 348 / 388, the strip at 306-341, the bar at x 207-644,
  lines 398-402 (the same 438 pixels). Every constant has an `_I` twin in `transport_hud.svh`,
  chosen on `safe` (`il` until fj#71); the title's room is the grid's columns - 3 (66 / 54).
- **Under Zoom (fj#71, `docs/zoom.md` §3)** the same `_I` layout is drawn on the 480p raster (`safe` without
  `il`), emu feeding `v_pos` 7 lines up: lines 61 .. 418, inside the band the scaler shows.
  - The PSP's band is a light wash. The first pass copied that (`>> 1` + a light constant),
    and white text washed out over a bright picture (mockup 18, Family Guy). So the band is
    darker than the PSP's.
- **The bar:**
  - inner x 264-701, lines 446-450, opaque;
  - the fill is the accent, `elapsed x 438 / total` pixels (the shared serial divider,
    `transport.md` §2.7), and the rest is (200,204,212);
  - a 1-pixel rim of `under >> 1` around it keeps it readable on a bright picture.
- **Layer order**, from the bottom:
  - the picture;
  - the header wash or the band;
  - the bar and its rim;
  - a box;
  - the glyph's class, over what is below it.

### 6.3 The behaviour

- **Pop-ups last 3 s and cut hard** (no fades: the ~800 ALM cap, `transport.md` §7). The
  latest event replaces the one on screen.
- **The state icon (bottom-left):**
  - With Display on, it is always there. This is measured: the PSP capture shows ▶ beside the
    bar the whole time the overlay is up.
  - With Display off, it stays while paused, stopped or in trick play. Those are modes the
    picture alone does not tell (**proposed**; the capture never shows a pause with Display
    off).
  - After Play it shows for 3 s.
  - Next / Prev show ▶▶| / |◀◀ for 3 s.
- **The caption (above it, boxed, 3 s):**
  - trick play: `Forward n` / `Reverse n`. The icon and badge stay after the caption goes.
  - Next / Prev: `Chapter n`, the chapter it lands on (**proposed**: the PSP pops the icon
    alone, which leaves no way to see the chapter with Display off).
  - Audio: `♪ 2 Japanese`, the track's rank and its language.
- **The message band (3 s):** `There is no chapter available.` (D3), the only message P6b
  posts.
- **The Display overlay (a toggle):**
  - the header: the film mark and the title;
  - `Chapter n` and the time, right-aligned. The chapter box is left out on a title with no
    chapters: the time alone, as the PSP shows it;
  - the bar and the state icon.
  - While presses are pending, the chapter shows the projected one and the time holds the
    shown picture's (mockup 17).
- **The title (D6):** one cell a UTF-8 code point.
  - Printable ASCII shows as itself.
  - Any other character shows as ONE placeholder: continuation bytes add nothing (mockup 15:
    Tom & Jerry's `トム&ジェリー Vol.1`).
  - Past 66 cells, or when the reader kept only 128 bytes (`title_trunc`), the last cell is
    an ellipsis.
  - A malformed title is a placeholder too, flagged `malformed`: a stray continuation byte,
    a sequence cut short (the 128-byte cut can make one), or a byte UTF-8 never uses (C0,
    C1, F5-FF). A continuation byte adds nothing only while its lead byte's sequence is open
    (a 2-bit count in the writer). Mockup 19.
  - These are flags for the telemetry, never silent. The library's longest title is 54
    characters; `Spiderman 3™` and Ghost in the Shell 2.0 carry non-ASCII.
- **The time:** `hh:mm:ss/hh:mm:ss`, the elapsed part in the accent.
  - Both fields take 3 hour digits once the total reaches 100 h.
  - Past 999:59:59 a field shows `999:59:59+` (**proposed**). The format's durations are u64
    ticks, so the saturation must be visible.
  - The chapter goes to 65535 (mockup 14).

### 6.4 Budget (the ~800 ALM cap, `transport.md` §7)

| part | est. ALM |
|---|---|
| the pixel path: slot hit, the column / pixel counters, the plane and font reads | 70-90 |
| the under-layer: 4 box spans, the bar and its fill compare, 3 tints, the glyph blend | 150-190 |
| the writer: an FSM composing the strings into the plane (the title's UTF-8 walk, `Chapter n`, the time, the captions and the language names from a small string ROM, the right-alignment) | 250-350 |
| `secs_bcd` (harvested; its 9:59:59 clamp raised to 999:59:59) and the shared serial divider | 100-140 |
| the pop-up timer and the state edges | 30-50 |
| **total** | **600-820** |

- **M10K:** 6 (the font) + 1 (the plane) + 0-1 (the strings) = **7-8**, inside §7's +6-10.
- **If the fit lands over the cap, in order:**
  - the string ROM into the writer's case statement;
  - the edge class (the blend's adders);
  - the band's own tint (reuse the header's).
- **Not in this estimate: elapsed on a multi-item title.** `transport.md` §2.7 needs the sum
  of the earlier items' durations, a reader query that is not built (items are u32: never a
  table). `umd_nav_ref.elapsed` is its golden.
  - It lands in the reader, not the HUD (~100-150 ALM).
  - Single-item titles (86 of 89) need only `sh_pts - IN`.
- **The pipeline** will likely be LAT 5-6: the plane read, then the font read, then the blend.
  `xmb_wave` and `diag_hud` are LAT 4, so `emu` delays them to match.

### 6.5 The approval gate (✅ all seven taken as proposed, the maintainer 2026-09-29)

The maintainer approved the mockups and took every proposal below: monospace, the persistent
icons, `Chapter n` as the Next / Prev caption ("this change is better"), the language names,
the hour rule, hard cuts at 3 s.


1. **The look:** the font, the colours, the layout (the mockups).
2. **Monospace cells vs a proportional font.** Monospace (proposed) is the cheap path: a text
   plane, as `diag_hud` does. A proportional font needs the text drawn into a pixel line
   buffer at event rate: ~+10-14 M10K and a glyph-advance writer. The cost is loose spacing
   around the narrow letters (i, l, r).
3. **Persistent icons with Display off** while paused, stopped or in trick play (the PSP is
   unmeasured).
4. **`Chapter n` as the Next / Prev caption** (the PSP pops the icon alone).
5. **The language names:** the eight codes the census found (en fr es it de ja zh ca) by
   name; any other code as its two letters (mockup 8: `♪ 3 pt`).
6. **The time past 99 h:** 3 hour digits, then `999:59:59+`.
7. **Hard cuts at 3 s**, no fades.

### 6.6 As built (P6b5 RTL, 2026-09-29)

- **`umd/transport_hud.sv`** implements §6.1-§6.3. The constants and the string ROM come from
  the model (`tools/transport_layout.py --gen` → `umd/transport_hud.svh`,
  `umd/transport_str.mem`), the font from `tools/transport_font.py`.
  - **The pixel path** is LAT 4, like `diag_hud`: s1 the slot hit, the column (`hx * 205 >> 11`)
    and the layers; s2 the plane; s3 the font row (`glyph x 24 + row`); s4 the class and the box.
    `rgb` is the HUD over `bg`, combinational; `emu`'s output register takes it where the
    diagnostic HUD does not draw.
  - **The plane's columns are the model's plus one** (column 0 at x 2), and each cell carries a
    2-bit box attribute: the whole cell, or only the `BOX_PAD` pixels next to a box. Pixel
    spans were the first build: six 11-bit extents and their comparators, ~60 ALM more.
  - **The writer** writes every cell's final value once a pass (~600 cycles). The scan-out
    never sees a cell cleared and redrawn.
  - **Numbers without a divider.** A time's digits come straight from its 90 kHz ticks, by
    repeated subtraction of each digit's weight on one shared 40-bit subtractor. The chapter
    and the track rank use it too, and so does the bar's quotient: a long division of elapsed
    by the total, whose first step gives 512 when elapsed >= total. The plan's
    `secs_bcd` harvest (`transport.md` §2.7) was not needed.
  - **The pop-up timer counts raster frames** (`POPUP_FRAMES` = 180, 3 s). A 27-bit cycle
    counter was the first build.
  - **The triggers** are the RTL's own:
    - `state` entering PLAY without trick play, and trick play's end in PLAY, pop up ▶;
    - `tk_speed` changing to a speed pops up Forward / Reverse;
    - a Next / Prev press pops up its icon and chapter caption;
    - `player_ctl`'s NO_CHAPTER event shows the message band, its TRACK event the track tag.
  - **Elapsed** is `base + max(sh_pts - IN, 0)`, from a 4-entry table indexed by the shown
    picture's item tag. It is written at every item start from the reader's `item_in_pts` and
    its new **`item_base`**: the earlier items' OUT - IN, summed by the walk the reader already
    makes (sequential, or a seek's walk to its item), so no table of items is needed.
    `umd_reader_tb`'s `[base]` arm checks it at every item start against
    `umd_fixture.item_bases` (the P1 parser), and `pl_dur` against the playlist's sum.
- **The keys, interim until P6b6:** the keyboard's D toggles Display and A steps the audio
  track (`kbd_map` bits 8 / 9, no CONF_STR button yet). P6b6 gives both J1 buttons in the one
  CONF_STR change (`transport.md` §4).
- **Gates:**
  - `bench/umd/run_transport_hud.sh` (Verilator): 31 states pixel-exact over a synthetic
    background, whole 720 x 480 frames with `!==`. The states are the 19 mockups (their pop-ups
    reached through the RTL's triggers) and 12 edges. `--red`: 18 of 18 mutations caught, each by
    its own state.
  - `tools/tests/test_transport_layout.py`, the model's own test, checks hand-written
    expectations; `red_umd.py` has 8 mutations, all caught.
  - `run_umd_reader.sh`: the `[base]` arm, N28-N30.
  - `check_emu_wiring` checks the HUD's wiring; `run_scaffold.sh` adds W59 / W60.
- **Known limitations:**
  - **The shown PTS is read live**, one cycle after the item table's read. A pickup at an item
    change landing in exactly that cycle gives one pass (~25 µs) a wrong time. It is rewritten
    on the next pass, never held.
  - **A trick-play hop's I picture before its item's IN** shows the item's start time (the
    clamp at 0).
  - **The title flags** (`t_ph`, `t_bad`, `t_cut`) and `display` go to telemetry in P6b7.

### 6.7 The rig (2026-09-29, `UMD_p6b5_20260929_1305.rbf`)

Screenshots of the core's raster, Diagnostics Off. Every state looks like its mockup.

- **Akira:**
  - The Display overlay shows `Akira`, `Chapter 1` and `00:00:11/02:05:15`. The total is
    the PSP's own (photo `akira_7`).
  - Next pops up ▶▶| and `Chapter 2`, and the overlay shows the projected chapter while the
    seek is in flight.
  - Right x3 shows `Forward 2` (the third press still in flight), then ▶▶③ once the caption
    has gone. The clock ran 3:01 → 7:57 in ~5 s and the chapter followed.
  - Pause from trick play gives ▶ and play; Pause again gives a held ‖.
  - A gives `♪ 2 Japanese`, Akira's second track.
- **Family Guy (4:3):**
  - Chapter 2 lands at 00:04:35 (the model's 4:31, plus the seconds played).
  - The last chapter shows 22:36 of 22:36 with the bar full.
  - Next there shows `There is no chapter available.` on the band.
- **My Chemical Romance disc 2 (three items):** 27 merged Next presses land on chapter 29,
  in item 2. The time there reads `02:06:55/02:06:55` at the title's end, so the reader's
  `item_base` carried items 0 and 1. Without it the time would read ~00:00:03.

### 6.8 Next

P6b6 (the buttons, CONF_STR, the manual rows: D10's 11-button J1 list) and P6b7 (telemetry,
the rig gates), then P6c: Go To, A-B / Repeat and frame stepping, with no panel (D10).

## 7. P7: the subtitle tag (2026-09-30, `subtitles.md` §7)

The Subtitle button's pop-up is the audio track's tag with a two-cell speech balloon for the
note: `(balloon) 1 English`, or `(balloon) Off`. The rank counts among the clip's declared
subtitle tracks (up to 32), and the language comes from the reader's table at 16 + n. Mockups
on rig screenshots, with a real Akira subtitle under them: `tools/transport_layout.py --p7`
(`.sim/p7_mockups`). The maintainer chose the outline balloon (S5) and, with Display on, the
HUD drawn over a bottom subtitle (S6).

