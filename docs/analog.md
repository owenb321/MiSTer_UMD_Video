# The 480i raster and Analog Aspect (✅ MERGED PR fj#37)

**Status: ✅ MERGED (PR fj#37, 2026-10-01); S1 + S2 benched, fitted (6 of 6 seeds), rig-checked over HDMI; ✅ HW-CONFIRMED on the CRT by the maintainer (2026-10-01: every item of §5).** Order of work: `docs/roadmap.md` "Where the work
stands" step 2, `docs/area_plan.md` §9 (480i with Analog Aspect, after A7's fit freed the room:
37,163 ALM, 89 %).

Two stages, two fits (each a 5-seed sweep under A2's rule, `area_plan.md` §7), one rig round each:

| stage | what | estimate |
|---|---|---|
| **S1** | the 480i raster (`sync_gen`'s interlaced branch, `csync_smpte`, Video Output, the menu swap), the readers on it, the scheduler's events per field, **field order** (V6), the pause still (V7) | +0.3-0.6K ALM |
| **S2** | Analog Aspect: Auto / Fit / Letterbox / Crop on the 480i raster | +0.4-0.8K ALM |

Harvested from two places (`docs/harvest.md`): **MiSTer_h264_decoder**'s P6 part 1 (the fork built
480i from this repo's display path: `sync_gen`, `csync_smpte`, `field_polarity.vh`, their benches;
its `docs/analog.md`) and **MiSTer_DVD**'s Analog Aspect and field-parity work (`docs/crt_anamorphic.md`,
`docs/field_parity.md` there). What each contributed and what differs is noted per decision.

## 1. Decisions

| # | decision | why / source |
|---|---|---|
| V1 | **One raster for HDMI and the analog pins**, `O[7:6] Video Output: Auto / Interlaced / Progressive`. Auto = Interlaced when the ini says analog (csync / YPbPr / SoG without `vga_scaler`, or `direct_video`), latched while a picture is shown (Main re-sends its cfg on every resolution report and on leaving the OSD: a live wire would switch the raster under a playing title). A forced mode applies at once. | DVD and the fork: a second simultaneous raster (480i analog + 480p HDMI) was built in DVD and deleted ("extremely wobbly"). Bits: this repo's own reservation (`emu.sv` since P5), not the fork's `[6:5]`. |
| V2 | **480i is pixel repetition on the 27 MHz clock**: 1716 dots a line, `CE_PIXEL` every other dot, 262 / 263-line fields with the vsync half a line off on one (the N64 model), `VGA_F1` = 0 on the TOP field, SMPTE field 1 = the v_pos-odd field (`field_polarity.vh`, never flipped locally). No 13.5 MHz clock. | The fork's `sync_gen` (c3c364b), DVD's measured constants. A mode change restarts the counters at the top field (no reset). |
| V3 | **Coordinates:** `h_pos` counts dots (0..1715 at 480i; a pixel is two), `v_pos` is the FRAME line (`{field line, ~odd_field}`). Modules with dot strobes (`disp_reader`, `plane_reader`, `disp_ctl`) take the raw `h_pos` and an `il` input; pure functions of position (`diag_hud`, `xmb_wave`, `transport_hud`) take the column `h_col` from `emu`. `transport_hud`'s pop-up timer counts FIELDS (its frame top is a field top at 480i) so a pop-up lasts as long on both rasters. | The fork's W40 failure (the idle screen squeezed into the left half). |
| V4 | **Composite sync:** `csync_smpte` (SMPTE 170M equalising and serrated pulses) at 480i only; 480p keeps the framework's csync. Its `h_sync` is the tap `VGA_HS`'s register takes. | sys_top's stock csync leaves the fields' broad pulses ~50 / ~18 us: TVs swap or pair fields (DVD). |
| V5 | **The menu never offers what the raster cannot do:** at 480i `O[4:3] Deinterlace` is hidden (`H0`) and `O[5] HDMI Deinterlace: Weave / Bob` (ascal's `HDMI_BOB_DEINT`) shown (`h0`), on `status_menumask[0]` = the effective raster. ascal cannot blend. | `display.md` §1; stock Main's `h` checked in `menu.cpp` (2026-10-01). |
| V6 | **Field order (the maintainer, 2026-10-01: fix it in S1, as DVD solved it).** At 480i a field store's first field must land on the raster field of its parity, else every pair plays its fields in reverse (judder on every field-coded disc: 12 of 33 main titles). **The rule:** a pickup of a field PAIR whose first field's parity differs from the raster field about to start is deferred one refresh (the shown store is held one more field). The scheduler is not told of the pickup that did not happen, so it evaluates the head again at the next refresh: an anchoring head anchors there (the STC takes its PTS one field later, so the timeline is now in phase and every contiguous pair after it lands right; no A/V offset). A non-anchor deferral (the stream's own parity break) is one field late, counted. Frames are never deferred (a frame's lines are taken by raster parity: film and progressive frames have no field order); a single field is not deferred (V7 shows it on both raster fields). | DVD (`field_parity.md`): its corrector is a feed-forward arm (a deferral at an alternation break) plus a feedback arm on a measured raster parity, because its mixer accepts a field top on either parity slot. Here `disp_ctl` runs on the raster's clock and knows both parities at every pickup, so the feed-forward rule alone is exact: no measurement, no feedback loop, no 0.5 s confirmation. Counted: `n_pdefer` (HUD / telemetry). |
| V7 | **One field on both raster fields** when the shown store is a single field, or a field pair while paused (the pause still: a paused pair would alternate its two moments at 30 Hz). The other raster field shows the kept field's lines interpolated half a line, `(a + d + 1) >> 1` -- the 480p Bob's rebuilt line, so no vertical bounce. | DVD's pause field still (`field_parity.md` §9); the fork left a single field's other lines stale at 480i. |
| V8 | **S2: Analog Aspect** `O[10:9]: Auto / Fit / Letterbox / Crop`, live at 480i only, and only on a 720 x 480 picture (every disc in the census; any other size is shown Fit). Auto = Letterbox for 16:9 (the shown picture's VUI aspect, `aspect_vui`), Fit for 4:3; **Auto never selects Crop**. While Letterbox or Crop is active `VIDEO_ARX/ARY` are 4:3 (HDMI shows the same raster; ascal must not stretch it back). | DVD's option and rules. |
| V9 | **Letterbox:** each field's 240 lines to 180, centred (30 field lines, 60 frame lines, of black above and below), a 2-tap vertical blend at the **exact per-field phase** (the maintainer, 2026-10-01): raster frame line Y of the band samples source frame position (Y - 60) * 4/3 from the source field of its own parity (§3), weights in sixths of a field line. | DVD resamples both fields at one phase (a 1/3-frame-line inter-field offset). |
| V10 | **Crop:** the centre 540 columns stretched to 720 (an exact 4/3: source column 90 + 3j/4, weights in quarters, no multiplier). | DVD crops whole macroblocks (528 -> 720, 11/15) because its address generator works in MBs; UMD's 720 is fixed. |
| V11 | **Subtitles in raw raster coordinates under Letterbox / Crop** (the maintainer, 2026-10-01): the plane is not scaled; a bottom subtitle lands in the lower bar under Letterbox. | DVD's user-accepted choice (`crt_anamorphic.md` §9a); no fabric cost. |

**Out of scope here** (each a later item): 60.00 Hz and PAL (the fork's `std`; no UMD is 576-line),
a Film 24p raster, anti-twitter (the fork measured it as a clear CRT win; our a / b / d Blend kernel on
a frame store at 480i is its identity case -- S1's fetch design keeps that cheap later).

## 2. The readers at 480i (S1)

**`disp_reader`.** The deinterlacer (Weave / Bob / Blend) stays the 480p raster's. At 480i the
output line is built from **source field lines** of one parity `ps`:

- Fit: `ps` = the raster field's parity `q`; line i of the field shows source field line i.
- V7 (single field, or a paused pair): `ps` = the kept field; on the raster field of the other
  parity, the line between two kept lines: the average of source field lines s, s + 1.
- S2's Letterbox: two source field lines s, s + 1 with a weight in sixths.

One walker covers all three: N = the source position in sixths of a field line (§3); s = N div 6,
the weight (N mod 6) / 6 on line s + 1. The line ring is indexed by **source field line** (slot
s & 3) at 480i (at 480p by frame line, as before), and a raster line requests the lines its NEXT
output line needs that are not yet in the ring (0, 1 or 2 lines: Letterbox advances 4/3 lines a
line). While line i reads slots s, s + 1, lines s + 2, s + 3 are written: four slots suffice. The
blanking before a field fetches its first two lines. Source line s is store line 2s + ps (a field
store's lines are interleaved; a frame's field ps is its lines of that parity), past the last line
clamped (the edge mirrors). Chroma: each fetched line takes its chroma row by the existing rule.

**`plane_reader`** (subtitles, 1:1): line Y of the raster shows plane line Y; at 480i it requests
the field's next line (v_pos + 2), its buffer half by field line, and the field's first line in the
previous field's last blank line.

**`disp_ctl`.** Events per field on the model's 450,450-cycle grid (the fork's placement): the eval
at field line 249 and the pickup at 250, each at dot 0 on the short field and at the half-line
(dot 858) on the long one -- so they stay exactly 450,450 cycles apart and
`tools/disp_sched_ref.py` holds unchanged at 480i, plus V6.

## 3. The walker (S1 Fit and V7; S2 Letterbox)

Raster frame line Y = 2i + q (field line i, raster parity q). Source parity ps. In sixths of a
source field line:

- Fit: N = 3 (Y - ps) = 6i + 3 (q - ps). q = ps: s = i, weight 0. q = 1, ps = 0: s = i, weight
  1/2. q = 0, ps = 1: s = i - 1, weight 1/2 (i = 0: s = 0, weight 0 -- the top edge).
- Letterbox (S2): the band is field lines 30..209; Y' = Y - 60 = 2o + q. Source frame position
  Y' * 4/3, source field line (Y' * 4/3 - ps) / 2, so N = 4 Y' - 3 ps = 8o + 4q - 3ps. With
  ps = q: N = 8o + q -- field 0 samples 4o/3, field 1 4o/3 + 1/6 (DVD: 4o/3 in both).
- Weights (Q0.8): 0, 43, 85, 128, 171, 213 for N mod 6 = 0..5; out = a + (((b - a) * w + 128) >> 8).
  At w = 128 that is (a + b + 1) >> 1, the 480p Bob's rebuilt line (bit-exact).

## 4. Benches (planned; each with RED arms)

- `run_scaffold.sh`: `sync_gen_il_tb` (harvested; S3-S9) ✅; wiring arms W41+ for the 480i wiring
  (`check_emu_wiring.py`): `interlaced` tied 0, Auto from the live ini, the HUD column, `CE_PIXEL` /
  `VGA_F1` / csync on the wrong delay tap, csync always on, the readers' `il` tied 0.
- `run_csync_field.sh` (harvested; G1-G8, 5 RED arms) ✅ green against this repo's `sys_top`.
- `run_disp_reader.sh`: 480i arms (a frame, a pair, a single field, a paused pair) scored on both
  dots against `tools/disp_golden.py`'s field mapping.
- `run_disp_sched.sh`: every scenario again at 480i (+il), the model with V6; scenarios with the
  anchor on both raster phases; refreshes counted from the TOP field (the fork's bench bug).
- `run_plane.sh` / `run_overlay.sh`: 480i arms.

## 5. The rig

`.236`: HDMI capture of ascal's output of the one raster; the analog output to a CRT
(`vga_mode=svideo` since 2026-10-01) that only the maintainer can see. Measurable on the rig: the
1716 x 525i lock, HDMI Bob vs Weave (`tools/comb_metric.py`), S2's geometry, `n_pdefer`. The CRT
checklist for the maintainer: field order on a field-coded disc (Family Guy), the pause still,
Letterbox / Crop, csync lock. ⚠ The capture reads ascal's frame buffer, where fields are stored
woven: Bob and field order must be judged on the CRT (the fork's `history.md` §7).

**The CRT checklist (the maintainer's eyes; Video Output = Interlaced or Auto with an analog ini):**

1. **Lock**: the picture is stable and interlaced (no rolling, no paired lines) on both a
   field-coded title (Family Guy) and film (Akira) -- csync_smpte's broad pulses.
2. **Field order (V6)**: Family Guy, a pan or fast motion: smooth, no back-and-forth judder.
   Then a chapter jump (a re-anchor, often a deferral: telemetry `pdefer` +1) and the same
   check -- the jump must not leave it juddering.
3. **Pause still (V7)**: pause on Family Guy motion: a steady picture, no 30 Hz flicker
   between two moments. Unpause: motion resumes without judder.
4. **Analog Aspect (S2)** on Akira (16:9): Auto = Letterbox (bars top and bottom, round
   shapes round); Fit (tall); Crop (full screen, sides cut); a 4:3 title untouched in Auto.
   Letterbox's exact phase: on a still with sharp horizontal edges, no extra shimmer against
   Fit (the comparison DVD could take, `docs/harvest.md`).
5. **HDMI at 480i**: HDMI Deinterlace Weave vs Bob on Family Guy (Weave combs on motion, Bob
   does not); the HDMI picture is 4:3 under Letterbox / Crop.

## 6. Status

- **S1 ✅ MERGED (PR fj#37; built 2026-10-01).** `sync_gen` (480i), `field_polarity.vh`,
  `csync_smpte` harvested from the fork (c3c364b); the `emu` wiring (V1-V5); `disp_ctl`'s
  per-field events and V6; `disp_reader`'s walker and V7; `plane_reader` at 480i; the HUD's
  field timer; telemetry `pdefer` + `trick`[7]. Benches, every one green:
  - `run_scaffold.sh --red`: `sync_gen_il_tb` (S3-S9), wiring W72-W85, all caught;
  - `run_csync_field.sh --red`: G1-G8 against this repo's `sys_top` csync, 5 RED caught;
  - `run_disp_reader.sh --red`: 8 arms at 480i (691,200 dots each: both fields, both dots),
    I1-I7 caught. I2 was first a survivor: at 480i in play the window is one line, so every
    kernel gives b; the mode is now latched at 480i too and I2 aims at a paused pair;
  - `run_disp_sched.sh`: every scenario also at 480i against `disp_sched_ref.py --il`; checked
    so far `tff` (1 deferral at the anchor), `pausefld` (1, none after the pause), `film32` (0),
    `unpaired` (21: the stream's parity breaks, §7) identical to the model; **the full sweep: 64
    of 64 runs identical to the model** (`latefld.il` 1 deferral, its backlog drained as at
    480p); **D1-D42 all caught** (run in the S1 worktree, `b8dee01`: `disp_ctl` / `disp_sched`
    unchanged since) -- D39-D42 by [refresh]; D16's anchor was the `ev_pulse` line the 480i freeze
    rule changed (re-aimed; caught by [count] on `pause` and `pause.il`, run by hand);
  - `run_plane.sh --red`: `+il` (2,073,600 plane + composite dots, the flips at the blank);
    SI1-SI3 caught; SI4 (the fields' first lines swapped) SURVIVED: no subtitle in the fixture
    reached lines 0-1 -- the first request now spans the full height (115, 0, 603, 480), re-run;
  - `run_overlay.sh`, `run_transport_hud.sh`, `run_telem.sh`, `lint_undriven`: green.
  - Found by the benches: `plane_tb` / `sub_overlay_tb` left `disp_reader`'s `pic_parity` /
    `pic_single` / `deint_mode` floating since P5 (harmless at 480p, X video at 480i); the
    subtitle flip strobe at line 500 fell between a 480i frame's fields (moved to 501 there).
- **S1 on silicon (2026-10-01, `UMD_480i_20261001_1541.rbf`, SEED 11 first roll: clk_dec
  89.97 / 89.49, 37,560 ALM (90 %, +397), 83 DSP; clk_mem -0.092 ns on the reader's new
  crossing, unbounded -- `umd.sdc` fixed, refit pending).** On the rig (`.236`, HDMI capture):
  Family Guy at 480i plays, full width, colours right; `trick`[7] = 480i; the judder gate equal;
  late / starve / cadence / errors 0; `av_err` 2-3 ticks; **V6 on silicon**: 5 chapter jumps
  (re-anchors) took 4 deferrals, none in steady play, nothing late after; Akira (film) 23.97
  pictures/s, `pdefer` 0, judder equal, `av_err` 1; subtitles at 480i correct; the transport
  HUD's Display overlay and the idle wave full width. Not measurable on the rig: field order and
  the pause still on a CRT (the screenshot is ascal's woven buffer; Family Guy's motion too
  gentle for the comb metric), csync -- the maintainer's CRT checklist (§5).
- **S2 🔧 built**: the reader's incremental walker (Fit / Letterbox), the b / d buffers in
  even / odd halves (Crop), the datapath; `emu`'s O[10:9] Analog Aspect, Auto, the 4:3 HDMI
  aspect while in effect, telemetry `trick`[6:5]; golden `tools/disp_golden.py` `il_aspect`
  (it also asserts the S1 premise: the 480i Fit walker is the woven / Bob raster).
  `run_disp_reader.sh`: 9 new arms green first run (Letterbox / Crop on a frame, a pair, a kept
  field; the 720x480 gate; 480p ignores it), every earlier arm unchanged; A1-A10 caught. The
  rewrite moved I2 / I3 / I4 / I6's anchors (re-aimed); I4 then SURVIVED on a fixture blind
  spot: the golden picture's top 40 rows were a horizontal ramp, and a field store's first two
  lines share a chroma row, so blending them changed nothing -- the ramp band moved to rows
  40-79 (`disp_golden.py`).
- **S2 fit (d4a2362, SEED 11 first roll): clk_dec 93.21 / 92.76, 37,612 ALM (+52 over S1;
  area_plan.md §9 estimated 0.55-0.8K), DSP 86 (+3), every line-buffer half inferred as RAM.**
  `UMD_480i_20261001_1625.rbf`. **The sweep (A2): 6 of 6 seeds pass** (1 90.16 / 91.02, 3 91.67 /
  88.66, 5 88.72 / 88.53, 7 91.14 / 92.20, 9 92.37 / 90.11, 11 93.21 / 92.76); SEED 11 stays pinned.
- **The shipping netlist on silicon for field pairs (2026-10-01, the S2 build d4a2362, SEED 11)**: S2's
  walker rewrite replaced S1's field selection, so Family Guy at 480i was played again on it: Auto
  stays Fit (a 4:3 title, `aa` 0), 3 chapter jumps took 2 deferrals and none in play, late /
  cadence / errors 0, the judder gate equal; paused, the comb metric read 0.34 against 0.46-0.47
  playing (one 1.07): consistent with V7's one interpolated field, not proof (other frames; the
  capture is ascal's woven buffer).
- **What is NOT verified on silicon: field order (V6) and the pause still (V7) as a viewer sees
  them, csync's lock, Letterbox's per-field phase.** The HDMI capture cannot show them; the
  telemetry shows V6's mechanism only. ✅ **The maintainer ran the CRT checklist (§5) on
  `UMD_480i_20261001_1625.rbf` (2026-10-01): every item good on hardware** -- lock, field order
  in motion and after jumps, the pause still, the three aspect modes, HDMI Weave / Bob.
  **Found there: the transport HUD is not inside the title-safe area** -- its 720-wide layout (the
  grid x 12-701, the header at line 6, the icon / bar at lines 436-450) is cut by a CRT's
  overscan. Open: an inset layout at 480i (§8).
  ⚠ The rig's ini is `vga_mode=svideo`: Auto does NOT pick 480i there (no cfg bit reaches the
  core) -- set Video Output = Interlaced, or `composite_sync=1`, or the CRT shows 480p.
- **S2 on silicon (2026-10-01, the rig):** Akira (16:9) at 480i, Auto = Letterbox (`trick`[6:5]
  = 1): the picture on rows 60..419 exactly (360 lines), black above and below; paused, Fit /
  Letterbox / Crop on the same frame each as designed (the whole picture in the band; full
  height; the centre widened, the sides cut); Video Output = Progressive with Crop selected:
  `aa` 0 and the picture identical to 480i Fit (mean |diff| 0.0); subtitles at their raw place
  under Letterbox (the second line in the lower bar, V11); judder gate equal, late / starve /
  cadence / errors 0, `av_err` 0. The CRT checklist (§5) is the maintainer's.

**Done (was the next step):** the maintainer's CRT checklist (§5) on `UMD_480i_20261001_1625.rbf` (SEED 11,
d4a2362; Video Output = Interlaced on the rig's S-Video ini) passed every item on 2026-10-01; ✅ MERGED (PR fj#37). The
scheduler's D1-D42 ran in the S1 worktree (`b8dee01`: `disp_ctl` / `disp_sched` unchanged since);
the GREEN pass re-run on the final tree (S2's reader): 64 of 64 green.

## 7. Known limitations

- **A stream whose fields stop alternating** (a lone field between pairs, as at an edit) puts
  the 480i display a field behind its timeline from there: each pair is deferred once and taken
  late the next refresh, in the right order (`pdefer` and `late` count it), until the next
  anchor (a seek) or the next such break. Re-phasing the timeline would step the STC and the
  audio with it; a field of lag (16.7 ms) is the lesser cost.
- **A frame-coded interlaced picture** (`pic_struct` 3 / 4 on a frame: none in the census) is
  never deferred: a frame's lines are taken by raster parity.
- **A Video Output change mid-title** restarts the raster at a top field; the first field after
  it has no set-up (one field of stale lines).
- **`plane_reader`'s SCALE 1** (P9's menu plane) is not 480i-ready: its accumulators step per
  requested line and per clock.
- **S-Video / composite**: `vga_mode=svideo` / `cvbs` reach no bit the core sees, so Auto
  cannot pick 480i for them (the manual says so).
- **A disc menu (P9) on a 4:3 CRT** (the maintainer, 2026-10-03: "the menus should default to
  letterboxed ... authored for 16:9"): the reader's Letterbox / Crop move the video and not the
  menu plane over it, so under a menu `aa_mode` stays Fit and the HOST fits the menu instead.
  `emu` tells it `menu_aa` (HOST_RD AUDIO [12:11]): at 480i, Analog Aspect **Auto or Letterbox ->
  1 Letterbox** (a menu is 16:9, so Auto letterboxes it), **Crop -> 2 Crop** (an explicit Crop crops
  the menu too, the maintainer's call; Auto never crops), **Fit -> 0** (a 16:9 set); at 480p
  always 0. The host then draws the 854 x 480 scene into 720 x 360 at line 60 (Letterbox) or its
  centre 640 x 480 onto the whole raster (Crop), and maps the video through the P9 video window
  into the same box (a full-screen menu clip is windowed too). `VIDEO_ARX/ARY` are 4:3 while a
  menu is fitted (`menu_aa_on`), as for the reader's Letterbox. On the rig's 480i raster
  (2026-10-03, `UMD_p9s3sweep_20261003_0304.rbf`, the harness's screenshots) Family Guy's main menu and
  an episode page sit in the band, the menu clip windowed into it with the art. ✅ **Crop HW-CONFIRMED on
  the CRT** by the maintainer (2026-10-03: "cropped menus look good now"); ⏳ Letterbox on the CRT.

## 8. The HUD inside the title-safe area at 480i (V12, the maintainer, 2026-10-01)

The CRT checklist passed with one note: the transport HUD (`transport_hud.md` §6, laid out for the
full 720 x 480 frame -- the PSP's screen has no overscan) was partly cut off by the CRT's overscan.

| # | decision |
|---|---|
| V12a | At 480i the transport HUD moves as a block inside the **title-safe area** (80 % of 4:3 SD: x 72-647, y 48-431): 57 columns from x 75, the header 48 lines down (its wash to line 83), the message / caption / icon slots and the bar 48 lines up, the bar the same 438 pixels with its right end at the grid's. The title's room is 54 cells (66 at 480p). |
| V12b | **The message strip on both rasters**: P6b5's band from the message to the bottom covered half a 480i screen once inset; the maintainer chose (over the message replacing the title) one row just above the caption row on a 36-line strip -- 480p lines 354-389 (the message at 360), 480i 306-341 (at 312). |
| V12c | The diagnostic readout keeps its full-frame layout (an engineering readout; 16 rows cannot fit title safe at its size). |
| V12d | Subtitles stay where the disc places them (V11); whether a CRT cuts a bottom subtitle is to be checked at the maintainer's next CRT session. |

Built in the model (`tools/transport_layout.py`: `LAYOUT_I`, `set_layout`, `--il` mockups with the
safe area drawn), generated into `transport_hud.svh` as `_I` twins chosen on `il` in
`transport_hud.sv`. `run_transport_hud.sh`: the 40 states pixel-exact on both layouts (the 480i run
scans real fields, so the HUD's refresh comes twice a frame as on the rig -- the first try scanned
progressive with `il` set and its pop-ups expired at twice the rate); RED L1-L8.
**fj#71 (2026-10-09, `docs/zoom.md` §3):** the layout is now selected by its own port, `safe` (`interlaced_eff |
zoom`), and `il` keeps only its field timing: Zoom draws this title-safe layout on the 480p raster, 7 lines
down, inside its band (60 .. 419); RED Z1 / Z2.
✅ **HW-CONFIRMED on the CRT by the maintainer (2026-10-01, `UMD_480i_20261001_2203.rbf`, a02466d,
SEED 11: 37,829 ALM, clk_dec 89.37 / 86.42): "well within the overscan area now".** Accepted as the
build by the maintainer (no sweep: stopped after SEED 1's 90.63 / 89.15; SEED 11 stays pinned). On the rig the
header at line 54 / x 75, the time to x 644, the bar x 207-644 at line ~400, as the model.

## 9. Analog Dither (V13, 2026-10-06; from MiSTer_DVD PR #164 and the H264 core's fj#35 / fj#38)

**Why.** The DE10-Nano's classic analog I/O board ("18-bit") drives its VGA DAC from the top **6 bits**
of each channel (`sys_top`: `VGA_R = vga_o[23:18]`; S-Video's Y / C from `yc_out` likewise; the low
two bits reach only the SDIO pins of boards with an 8-bit DAC). 64 steps band film's dark gradients
on a CRT: a Y 16 -> 64 ramp is RGB 0 -> 56, 14 DAC steps. Both sibling cores measured it on .236's
CRT (the 18-bit board, S-Video) and shipped the same fix; a SuperStation's 24-bit analog output
(.201) shows no banding. Taken here as an OSD option, **`O[16] Analog Dither: Off / On`, Off by
default**.

| # | decision | why / source |
|---|---|---|
| V13a | **The analog output only**: `umd/dac_dither.sv`, a `UMD-FORK` edit in `sys/sys_top.v` on the core-raster VGA path's last word (`vga_o`, after `vga_out` and the `yc_out` mux: RGB, YPbPr, S-Video / composite alike), feeding all six DAC drivers (`VGA_R/G/B`, `vga_r/g/b`) as `vga_od`. HDMI and the scaler-to-VGA path (`vgas_o`, `vga_scaler=1`) never see it. | Both forks. Dithering in `emu` would put it on HDMI. |
| V13b | **A 4 x 4 Latin square of thresholds 0..3** added to each channel, saturating at 255, before the DAC drops the low two bits. Every line and every column holds 0..3 once, so by Hermite's identity (`sum_{t=0..3} floor((v + t) / 4) = v`) every 4 clocks of a line and every 4 lines of a column average to `v / 4` exactly (`v <= 252`). Rows the lines, columns the clocks: `3 0 2 1 / 2 1 3 0 / 0 3 1 2 / 1 2 0 3`. | DVD #164: the first matrix (a Bayer's top two bits = a 2 x 2 `{0 2; 3 1}`) was exact per cell, not per line -- alternate lines half a DAC step apart, a line texture on the CRT. |
| V13c | **DVD's module, not H264's.** The pattern is keyed on CLOCKS: here `CLK_VIDEO = clk_sys`, 27 MHz (V2: a 480p pixel a clock, a 480i pixel two) -- DVD's clocking exactly. DVD's choice of Latin square alternates high and low thresholds clock by clock, so a 480i pixel holds one of each at either phase against DE (the bench's T9); H264's 81 MHz `clk_vid` needs no such choice. The fundamental is 6.75 MHz, above NTSC luma bandwidth. | `dac_dither.sv`'s header. |
| V13d | **Inverted (3 - t) every vs**: at 480p consecutive frames are complementary (a still's pattern cancels at 30 Hz); at 480i the two fields are, so the pattern is spatially fixed on a still. | DVD's call, CRT-confirmed there (per-frame inversion at 480i would be a 15 Hz alternation, likelier to shimmer). |
| V13e | **Active video only** (`de`): blanking, sync levels and the burst untouched; a multiple of 4 (black 0, YPbPr's Pb / Pr 128) is unchanged at 6 bits whatever the threshold. `en` = 0 is bit-exact bypass. | Both forks. |
| V13f | **Bit 16, never bit 8.** Bit 8 was Diagnostics until A11 (2026-10-03) and a saved config may still hold it set (Diagnostics Off), which would turn the dither on unasked; 16 has never been allocated. `emu.sv`'s status-bit comment now says bit 8 is retired. The row is not hidden at either raster (it applies to both). | `emu.sv` "Bits are allocated once". |
| V13g | **No clock crossing, no `umd.sdc` entry**: `status` is on clk_sys, the same net as `clk_vid` here. `dac_dither` keeps its two `en` flops anyway, so a future CLK_VIDEO change cannot create an unsynchronised path silently. | DVD. H264 needs a false path (its `clk_vid` is its own PLL). |

**Gates.** `bench/umd/run_dac_dither.sh --red` (DVD's bench, taken as is: a small raster through the
module, every level scored against the DAC's contract -- T1 the field's 6-bit mean exact, T2 multiples
of 4, T3 saturation, T4 blanking bit-exact, T5 the bypass, T6 the fields complementary, T7 every line,
T8 every column, T9 every 480i pixel pair; 10 mutations each caught by its own arm, the old Bayer
matrix by T7). The wiring, which no module bench can see (DVD's `check_dac_dither_wiring.py` folded
into `tools/check_emu_wiring.py`): `VGA_DITHER = status[16]`, bit 16 owned by exactly the one row,
sys_top's `.VGA_DITHER(vga_dither_en)`, the instance's seven ports, all six DAC drivers on `vga_od`;
`run_scaffold.sh --red` W130 / W131 (emu), T5-T8 (sys_top).

**Status: ✅ MERGED (PR fj#56), ✅ HW-CONFIRMED (2026-10-06).** Built and benched 2026-10-06; fit SEED 5 first roll PASS, clk_dec
92.44 / 91.42 MHz, 39,291 ALM (94 %; `dac_dither` itself 17 ALM), `UMD_dither_20261007_0110.rbf`. ✅ **The regression guard on .236** (2026-10-06, that build, Akira at
480i, Disc Menus Off): 30 s of play Off and 25 s On, `recon_err` / `fe_err` / `aud_err` / `late` 0,
`av_err` 2 ticks; paused, the screenshot identical Off -> On -> Off (the live OSD bit, `[16]`). That is
true by construction -- `mister.py shot` reads the scaler's input, upstream of the dither -- so it shows
nothing else moved, not that the dither works. ✅ **HW-CONFIRMED on .236's CRT by the maintainer (2026-10-06, the same build, 480i, S-Video, the
18-bit board):** "the wave idle screen already looks better", and Akira A/B'd Off / On shows the
improvement over the 18-bit DAC's plain output.

**Known limitations.** The scaler-to-VGA path (`vga_scaler=1`) is not dithered (this core's users have
no reason to use it). On an 8-bit analog DAC (a SuperStation, a 24-bit board) On adds `v + 0..3`, a
1.5 LSB mean: invisible, and nothing to fix -- the manual says to leave it Off there. No NTSC setup
(7.5 IRE) is involved: the dither leaves black at black.
