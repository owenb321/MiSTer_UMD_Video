# Zoom: a letterboxed 4:3 title on a 16:9 screen (Forgejo fj#71)

Status: **✅ MERGED (PR fj#83, 2026-10-09), ✅ HW-CONFIRMED** (.236, §6; the maintainer's own test, 2026-10-09).
Fit SEED 5 PASS 88.50 / 88.07.

## 1. The case and the decisions

*Short Circuit*'s feature (`00001.MPS`) is a **letterboxed 4:3** encode: 720 x 480, SAR 10:11
(4:3), the ~2.35:1 film on rows 106-373 with black recorded above and below. Auto shows it at
4:3 (correct), so a 16:9 television windowboxes it: black on all four sides. The maintainer
asked for a Zoom (fj#71, 2026-10-07).

Decided with the maintainer, 2026-10-09:

| | Decision | Why |
|---|---|---|
| Z1 | **Aspect Ratio's fourth value**: `O[2:1],Aspect Ratio,Auto,4:3,16:9,Zoom;` (value 3) | The field had a spare value: no new status bit, no `v,1` bump. Zoom = Auto, except for a 4:3 picture. |
| Z2 | **Manual**: every 720 x 480 4:3 picture is zoomed while Zoom is selected; no letterbox detection | A TV's zoom button. A detector costs fabric at 95 % ALM, needs a threshold, and would change the aspect mid-title (a full-frame opening). A full-frame 4:3 title (Family Guy) loses its top and bottom 60 lines: the user's choice, said in the manual. |
| Z3 | **Subtitles moved into the band, never cut** | A bottom subtitle sits ~390-460, past the band. Best guess: *Short Circuit* has no subtitles, so no disc shows what the PSP does (Z4). |
| Z4 | **No PSP check first** | Recorded as an open comparison (§7), not a blocker. |
| Z5 | **The cut lines blanked in RGB too** (taken in review) | The analog pins are not DE-gated in `sys_top` (the fork's note: data not gated on `de_emu`, for the line-21 captions). Without it a 480p analog output shows the whole picture while the HUD and subtitles move up for no visible reason; with it the analog output shows the same band, letterboxed. It also means Analog Dither has nothing to skip (the cut lines are black). |

## 2. How: a fixed DE window in `emu`, not `video_freak`

The band is **raster lines 60 .. 419**, the middle 3/4. While Zoom is in force:

- DE is dropped outside the band (`de_dly <= {..., pixel_en & ~zoom_cut}`). ascal captures by DE
  (`sys_top`'s `hde_emu` -> `i_de`), so the scaler sees a 720 x 360 frame;
- `VIDEO_ARX:ARY` is 16:9 -- 4 x 480 : 3 x 360 = 16 : 9 exactly, so the film keeps its geometry;
- the cut lines' RGB is black (Z5, `cut_dly`, the same LAT 7 as DE).

`sys/video_freak.sv` (in `sys/sys.qip`, never instantiated here, nor in MiSTer_DVD or the H264
fork) does the same crop by measuring the frame's active lines and rescaling ARX / ARY with a
`sys_umul`. This raster is always 720 x 480 (`sync_gen`), so the window and the aspect are
constants: its counters and multiplier would re-derive what is known, at 95 % ALM. Rejected for
that reason; it remains the way if the raster ever stops being fixed.

`umd/zoom_ctl.sv` holds the decision and the band:

| Zoom is NOT in force (Zoom acts as Auto) when | Why |
|---|---|
| the 480i raster (`interlaced_eff`) | a 4:3 CRT shows a letterboxed 4:3 title as it should; Analog Aspect owns 480i |
| a disc menu is up (`host_menu`) | a menu is 16:9 already (P9) |
| no media (`~media_seen`) | the idle screen follows the display |
| **stopped** (`pc_idle`) | the wave or the disc screen (R5's 720 x 480 XMB art) shows over the held picture, and `sh_*` still describe the last 4:3 picture: the art would be cropped. NOT `host_ui`: the control panel raises it too, and the aspect would jump each time the panel opens |
| no shown picture (`~sh_valid`) | nothing to zoom |
| the picture is 16:9 or undeclared (`pic_wide`) | as Auto: an undeclared stream is 16:9 |
| the picture is not 720 x 480 (`sh_w != 45 \|\| sh_hf != 30`) | `aa_live`'s rule; the 144 x 80 clips |

`zoom` changes only at the vblank strobe (h 0 of line 500, the one `sub_overlay`'s flips use), so
DE, ARX / ARY, the subtitle clamp and the HUD's layout change together between frames. Seeks,
chapters and trick play do not toggle it: `disp_ctl`'s shown-picture record is reset by
`fe_rst_n` (the mount) alone, not by a seek's `pipe_rst_n`. It changes legitimately only where
Auto would (an item of another aspect, e.g. a 16:9 trailer before a 4:3 feature).

**Under `direct_video`** sys regenerates the HDMI DE from the syncs (`dv_de`): the scaler never sees the
crop. Auto's Video Output picks 480i there (Zoom off); forced Progressive, the HDMI picture is the analog
raster, which shows the band letterboxed (Z5's blank). The manual says so. With `vga_scaler=1` the analog pins carry the scaler's output, so the
analog output is zoomed too.

## 3. What moves inside the band

- **The transport HUD** (`transport_hud.sv`): a new `safe` port selects the title-safe layout
  (the 480i twin, `_I`, lines 54 .. 411) -- `interlaced_eff | zoom`; `il` keeps its field-timing
  meaning. Under Zoom emu feeds it `v_pos_l7 - 7` (`hud_v_pos`): the twin lands on 61 .. 418,
  inside the band with a line to spare at each end. The lines above wrap past 4095 - 6, which
  the HUD never draws (its `v_pos[11:10]` guard); they are cut anyway. The CRT's layout is
  unchanged. A generated `LAYOUT_Z` twin is the alternative if the shift reads badly on the rig.
  The control panel (lines 90-243) needs nothing.
- **The fabric's subtitle** (`sub_overlay.sv`, Z3): `plane_reader`'s destination y is clamped
  to `[60, 420 - h]`; a subtitle taller than the band (360 lines) is placed at 60 with its first
  360 rows (`dh`; the source rows still from `sy`: the image moves, it is not re-fetched).
  Combinational on the flip's latched rectangle (a register at the same vbl would take the
  previous one). Only the fabric's own plane: who owns the plane (`ui | ui_sub`) is taken at the
  same vbl (`f_host`), and the host's page (a menu, the panel) is never moved.
- **The subtitle under the △ panel** (the UMD Main composites it into its page,
  `umd_menu_run.c` `umd_mr_panel_frame`): the core reports Zoom on HOST_RD AUDIO[10]
  (`tools/host_layout.py`; an older core reads 0: no move), and the Main places the subtitle with
  the same rule (`zoom_place`), its vacated rows cleared; a change of Zoom redraws the page.

## 4. Known limitations

- `direct_video`: no Zoom on HDMI (§2).
- 480i: no Zoom (by design, §2).
- A full-frame 4:3 title loses its top and bottom 60 lines under Zoom (Z2, the user's choice).
- A subtitle taller than 360 lines shows its first 360 (the library's tallest is Stargate's
  441, a full-screen card: §5).
- An older UMD Main (before fj#71) places the panel's subtitle raw: under Zoom its part past the
  band is cut while the panel is open.
- The HUD's placement is the 480i twin at +7 (§3).

## 5. Benches

- `bench/umd/run_zoom.sh [--red]`: `zoom_ctl` against the gating table (written in the bench from
  the table above, not from the RTL): each gating input from the all-live set alone ([G-*]: nine
  arms), the vbl latch ([L]), the band's edges ([W0] 59 / 60, [W1] 419 / 420), nothing cut off
  Zoom ([C]), 1,000 random sets ([R]). RED Z1-Z12, each caught by its own arm.
- `bench/umd/run_overlay.sh [--red]`: `+zoom` with `tools/sub_overlay_golden.py --zoom` (the
  plane moved per the definition): the synth units (inside, two past the bottom), the
  `--zoom-synth` case (above the band, inside, 400 rows tall; host and FABRIC decode), Stargate's
  441-row card (FABRIC, with `$UMD_ISO_DIR`). RED O5 (the clamp gone), O6 (the top case), O7 (the
  360 bound). The host-plane exemption (`f_host`) needs the hand-over, which this bench ties off:
  checked on the rig (§6).
- `bench/umd/run_transport_hud.sh [--red]`: a third GREEN run, `+safe` (480p raster, the
  title-safe layout) scored on the 480i set's frames (81 states); RED Z1 / Z2.
- `bench/umd/run_umd_host.sh [--red]`: AUDIO[10]; RED H32.
- `bench/umd/run_scaffold.sh --red`: `check_emu_wiring.py`'s Zoom pins, W142-W152 (and the
  A12 SD pair renamed W153 / W154: W127 / W128 were defined twice, the first pair's results
  overwritten).

## 6. Status and next steps

- ✅ MERGED (PR fj#83; `CORE_VERSION` `dev-zoom`): RTL, benches, the UMD Main, the manual.
- **The fit** (`UMD_zoom_20261009_2050.rbf`, 828efb6): SEED 5 PASS, clk_dec 88.50 / 88.07 MHz, every gate
  PASS; ALM 40,948 (98 %) against `main`'s 39,718 -- see §6.1.
- **✅ On the rig (.236, 2026-10-09, `mister.py shot` = the scaler's capture, `--scaled` = its 1920 x 1080
  output; the library's 4:3 features with subtitles: Family Guy, Tom & Jerry, Cowboy Bebop vol. 1):**
  - *Short Circuit*, Zoom: the scaler captures 720 x 360; the film fills the 16:9 screen edge to edge (only
    its own 2.35:1 bars left). Auto (the control): 1440 x 1080, windowboxed, as before.
  - The HUD (Display) inside the band: header, caption, icon and bar all whole (the header's text one line
    under the band's top, as designed).
  - *Family Guy* (full-frame 4:3, subtitles on): the picture cropped (its burned-in credits cut: Z2, as the
    manual says); bottom subtitles whole at the band's foot, a top one (at the source's top) moved down into
    the band; under the HUD as without Zoom (S6).
  - Under the △ panel, with this commit's UMD Main: the subtitle placed the same way (both lines whole). With
    the maintainer's older installed Main the subtitle is placed raw and its second line falls past the band
    (§4's known limitation, seen).
  - STOP: the disc screen whole (720 x 480, not zoomed); Play: zoomed again. A chapter jump, FF and back to
    play: 720 x 360 at every shot; recon / fe / audio errors 0.
  - *The Matrix* (16:9) under Zoom: 720 x 480, untouched. *Family Guy*'s disc menu under Zoom: 720 x 480,
    untouched. (Akira resumed into a 4:3 trailer, which Zoom zoomed: correct.)
### 6.1 The fit's 98 %: the packing estimate, not the netlist

The fit reports "Logic utilization" 40,948 ALM (98 %) against `main`'s 39,718 (95 %): +1,230, against an
estimate of ~60-120. Measured (2026-10-09), `main` (56fbf8a) refitted at SEED 5 in a worktree (it reproduces
39,718 exactly):

| | `main` (56fbf8a) | Zoom (828efb6) | |
|---|---|---|---|
| Combinational ALUTs | 62,131 | 62,339 | **+208** |
| Dedicated registers | 51,602 | 51,609 | +7 |
| [A] ALMs used in final placement | 41,202 | 41,107 | -95 |
| [B] estimate recoverable by dense packing | 2,096.5 | 786.5 | -1,310 |
| [C] estimate unavailable | 613.5 | 628.5 | +15 |
| "Logic utilization" = A - B + C | 39,718 | 40,948 | +1,230 |

Synthesis alone (`quartus_map` on both trees): `emu` +106 LUTs (`sub_overlay` +81, the HUD -50, `zoom_ctl`
a handful), the framework's audio IIR +99 (untouched source). Both placements fill 98 % of the ALMs; the
headline moves with the fitter's estimate of what denser packing would recover (B), which this placement
put at 786 instead of 2,096 -- spread over every entity, the untouched `recon_top` (+349 "needed",
-398 recoverable) the largest. **The feature's real cost is ~+208 ALUTs (~100 ALM).** Read a ledger jump
like this against [A] and the ALUT count before planning area from it.

- **✅ HW-CONFIRMED by the maintainer's own test** on .236 (2026-10-09, the same build and this branch's UMD Main):
  "that all works".
- Not seen on the rig: the analog output at 480p (Z5's blank; the bench pins it), 480i (no change by
  design), `direct_video`.

## 7. Open: the PSP

The PSP's own screen modes on a letterboxed 4:3 UMD (and where its subtitles land under a zoom)
were not measured (Z4). If they differ in a way that matters, revisit Z3.
