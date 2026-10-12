# The overlay plane compositor (P7 subtitles, P9 menus)

The fabric contract of `menus.md` §4 items 1-2, built for the subtitle plane first. The
four modules were built and benched **standalone** (2026-09-26) and ✅ MERGED (PR fj#28,
2026-09-30). The `emu` wiring, the STC and the core fit: ✅ MERGED (PR fj#29), ✅ HW-CONFIRMED (§8).

| module | clock | what |
|---|---|---|
| `umd/plane_reader.sv` | clk_sys raster + mclk fetch | one premultiplied ARGB8888 plane from ram2: a source rectangle scaled bilinearly onto a destination rectangle; 1:1 passes through |
| `umd/plane_blend.sv` | clk_sys | `out = src + (1 - a) dst`, exact rounding, saturating |
| `umd/sub/sub_flip.sv` | mclk / clk_sys | the subtitle plane's flip and hide requests (`sub_sched`'s `d_*`), latched in the vertical blank, acknowledged after; the rectangle clipped |
| `umd/rd_merge2.sv` | mclk | the video's display reader and the plane reader as one read master on ram2's B side |

`umd/ddr_mux2.sv` gained a parameter, `B_FIRST` (§5). It defaults to off, so ram1 is
unchanged.

## 1. The plane

The plane is a buffer of 720-pixel pitch (360 64-bit words a row). Each pixel is `{A, R, G, B}`
premultiplied, with A in [31:24]. Two pixels share a word, the even x in [31:0]. This is
`sub_plane_wr`'s layout. A buffer is never cleared: what lies outside the rectangle is
whatever an earlier image left there, and the compositor draws it as transparent.

**The geometry** (clk_sys) is changed only in the vertical blank (raster lines 480-523,
where no line is requested):

- `vis` and `base`;
- the source rectangle `sx, sy, sw, sh` in the buffer;
- the destination rectangle `dx, dy, dw, dh` on the raster;
- `hstep / vstep` (U10.16, source pixels per destination pixel);
- `hstart / vstart` (S11.16, the source position of the rectangle's first dot and line,
  relative to `(sx, sy)`).

A geometry whose source rectangle is empty or runs past the 720x480 buffer is refused.
Nothing is shown and `geo_bad` is raised: a fetch past column 719 would read the next
row. The destination can run off the raster; the part outside is simply never scanned.

## 2. The algorithm (the golden is `tools/plane_golden.py`)

**The owner computes the steps.** The mapping is centre-aligned, so destination pixel `i`
samples source position `(i + 1/2) sw / dw - 1/2`:

    hstep = round(65536 sw / dw)        hstart = (hstep - 65536) >> 1     (likewise v)

1:1 is `step = 65536, start = 0`. That is `sub_flip`'s plane, hard-wired at the
integration.

**The reader, per line and per dot:**

    line n of the rectangle (k = n - dy):  Y = vstart + k vstep     (accumulated, per line request)
    dot h (j = h - dx):                    X = hstart + j hstep     (accumulated, per dot)
    clamp(P, size):  P < 0            -> index 0,        weight 0
                     P >> 16 >= size-1 -> index size - 1, weight 0
                     else              -> index P >> 16, weight (P >> 8) & 255
    p00 = src(c, r), p01 = src(c+1, r), p10 = src(c, r+1), p11 = src(c+1, r+1)
          (a neighbour of weight 0 is replaced by its partner)
    top = 256 p00 + (p01 - p00) fx          bot = 256 p10 + (p11 - p10) fx      (exact, 16 bits)
    out = (256 top + (bot - top) fy + 32768) >> 16                              per channel, A too

Three properties follow:

- **At 1:1 every weight is 0 and `out = p00` exactly.** The horizontal result is kept
  unrounded into the vertical stage, so the pass-through holds by construction, not by
  luck. It is a bench arm (`[pass]`), scored against plain slicing of the buffer.
- **The premultiplied invariant survives.** Every channel is the same combination with the
  same weights and one monotonic rounding, so colour <= alpha in gives colour <= alpha
  out. The blend below never clips a valid plane.
- **A weight-0 neighbour is never read.** The row below is fetched only when `fy != 0`,
  and the column right of the rectangle is never in the line buffer. Both are muxed to
  their partner rather than multiplied by 0: an unfetched word is X in simulation and
  stale in silicon.

**How close is it to "real" bilinear?** The golden bounds its model against two
independent filters on the bench's images, which include noise, the worst gradient:

| reference | max difference measured | bound |
|---|---|---|
| float bilinear at the exact positions, clamped | 1.77 (up), 1.83 (placed downscale) | 2 |
| PIL `resize(BILINEAR)` per channel (upscale only: PIL widens its filter to downscale) | 2.0 | 2 |

The error comes from 8-bit weights and a step rounded to 1/65536: the position drifts by
at most `dw / 2^17`, about 0.006 pixel across the raster.

**Line buffers.** At one dot a clock (clk_sys *is* the 27 MHz dot clock), a dot needs its
four neighbours in one read. There are four RAMs: {top row, row below} x {even pixels, odd
pixels}. Each is 2 halves (the line's parity) x 512 words x 32 bits. The neighbour pair
is `E[(col + 1) >> 1], O[col >> 1]` whichever the column's parity. The span fetched is
the source rectangle's words `sx >> 1 .. (sx + sw - 1) >> 1`, written at their absolute
word index. An odd `sx` therefore brings the pixel left of the rectangle along, and it is
never selected (the bench's rectangles have odd x and odd width).

**Clocks.** The reader works like `disp_reader`. At the first dot of each line it requests
the next one, with line 0 requested at line 524. The request carries its source row,
whether the row below is needed, whether the line is inside the rectangle, and its
parity. It crosses as a toggle, with those fields quasi-static; the geometry is captured
with it. The dot pipeline has LAT 5: X, then clamp, then the RAM read, then horizontal,
then vertical. **A request that arrives while the previous line is still being fetched
is lost** and `n_late` counts it. That line shows the half's old contents.

## 3. The blend (`plane_blend.sv`)

    out = min(255, s + ((t + 128 + ((t + 128) >> 8)) >> 8)),   t = d (255 - a)

The second term is `round(d (255 - a) / 255)` exactly, the same idiom as the plane
writer's premultiply. The min only acts on a plane that is not validly premultiplied: a
menu owner might write one, and it saturates instead of wrapping. It has LAT 2, and src
and dst arrive aligned. Chained per layer, it gives video → subtitle → menu. The HUD
and OSD stay where they are, above.

## 4. The subtitle latch (`sub_flip.sv`)

`sub_sched` raises `d_req` with `{d_buf, d_vis, d_x, d_y, d_w, d_h}` and holds them until
`d_ack`. The plane it replaces is free from `d_ack` on (`subtitles.md` §2), so `d_ack`
must mean that the display shows the new state from the next frame and never reads the
old plane again. `sub_flip` latches the request at `vbl`, a clk_sys strobe in the blank
after the last line request (emu's picture snapshot point, h_pos 0 of line 500). Only
then does it acknowledge.

**Why a toggle handshake, not `d_req` as a level.** After `d_ack`, `sub_sched` drops
`d_req` for one mclk cycle and can raise the next request at once, for example a hide
right after a late flip. An 11 ns low is invisible to a 27 MHz synchroniser, so a level
handshake would either deadlock on the lost edge or latch the old request twice. The mclk
side instead:

- captures the request into holding registers;
- flips a toggle and takes nothing else until the acknowledgement toggle returns;
- pulses `d_ack`, ignoring `d_req` in that cycle, since it still belongs to the old
  request.

The bench raises the hide exactly one cycle after the flip's `d_ack` (`[flip]`, mutation
F2).

**The clip is here.** `d_w / d_h` are the PNG's size. The plane writer clips *pixels*,
not the rectangle, and a fetch past column 719 reads the next row. So `w' = min(w, 720 -
x)`, likewise `h`; `x >= 720`, `y >= 480` or an empty image hides the plane (`[clip]`).

## 5. ram2: the B side, and why the readers come first

On ram2, `ddr_mux2`'s A is `sub_mem` (the ring writer, ring reader and plane writer) and
B is `rd_merge2`: P is the video's `disp_reader`, Q is the plane reader.

- **`rd_merge2`**:
  - fixed priority, the video first;
  - a presented command is held until accepted (`[proto]`);
  - responses are routed by its own (owner, beats) FIFO, with its own full guard at 16
    bursts.
- **`ddr_mux2 #(.B_FIRST(1))`.** The mux alternated: B got the channel after each A
  command and gave it back after each B command, and it cut in ahead of a blocked A write
  only once. An A write must wait for every outstanding read, so each A write burst cost
  B a whole read drain.
  `bench/umd/sub_ram2_tb.sv` measured it with A saturating (8-beat reads and writes back
  to back):

| cycles to finish a line (of 2,860), A saturating | alternation | B_FIRST |
|---|---|---|
| video alone (180 words), slow model (70 % waits, latency 20-120) | 1,785 | 394 |
| video + one plane row (360 words), slow model | plane 3,670: **misses** | video 381, plane 742 |
| video + two plane rows (720 words, bilinear), default model | video 542, plane 2,289 | video 287, plane 999 |
| video + two plane rows, slow model | plane 5,555: **misses** | video 400, plane 1,136 |
| A's words a line, two rows (the floor is 32; the demux delivers at most ~10) | 902 (default) | 1,073 (default), 296-304 (slow) |

  With `B_FIRST`, B cuts in ahead of **every** blocked A write, not once. A is elastic:
  `sub_in`'s 4 KB FIFO holds ~50 lines of the fastest demux. A command A has *presented*
  is still never withdrawn. **Measured and rejected:** B also keeping the channel between
  its own commands. With the cut-in it gains nothing (plane 1,189 vs 1,136 on the slow
  model); alone it is worse (plane 1,896). The mutation X2 (`run_sub.sh`) restores the
  once-only cut and misses lines on the slow model.

**Rejected: a row cache** (at upscale, at most one new source row a line). It would halve
the plane's words. The measurement says two whole rows fit with 60 % of the line to
spare under the slow model, so the cache's tags and hazards buy nothing yet. A second
reader (the menu plane) is where to measure again.

## 6. Verification (`bench/umd/run_plane.sh [--red]`)

`bench/umd/plane_tb.sv` composes the modules as `emu` will: `sync_gen`'s raster;
`disp_reader` on a random store (`tools/disp_golden.py`) and the plane reader through
`rd_merge2` into `ddr_mux2 (B_FIRST)`, whose A is a subtitle master that never stops;
the blend over the video. Frame 0 warms up and frames 1-3 are scored at every active
dot: 1,036,800 plane dots and as many composite dots per run.

| arm | against | exact? |
|---|---|---|
| `[pass]` | the buffer sliced to the clipped rectangle, 0 outside (no filter involved) | exact, independent |
| `[scale]` | the fixed-point model of §2 (480x272 up, a placed downscale) | exact vs the model; the model bounded vs float bilinear and PIL (§2) |
| `[blend]` | the integer formula; at 1:1 also PIL `alpha_composite` of the straight image | exact vs the formula; within 1 of PIL (the two roundings) |
| `[flip]` | each request latched at the first blank after it and acknowledged within 40 mclk cycles of it; the latch count equals the requests raised; the geometry changes only at the strobe | exact |
| `[clip]` | the golden's clip of the raw rectangle | exact |
| `[geo]` | `geo_bad` exactly for the refused geometry | exact |
| `[late]` | `n_late == 0` throughout (a control run with a 2,000-cycle model must fire it) | — |
| `[proto]` | the merge's command held under waitrequest | — |

The sub mode's requests are a flip to a 603x389 rectangle at odd x (flush with the
bottom edge, two dots short of the right, so a rectangle one dot too wide shows), a flip
to one past both edges (clipped to 19x20: flush with the right), and the hide one
cycle after that flip's ack. Each is raised mid-frame. The scale mode has 480x272 at
(33, 17) up to the whole raster, a 720x480 source down to 301x203 at (411, 250), and a
refused geometry. The menu source carries an additive patch (colour > alpha) so the
clip is exercised.

`--red` runs 15 mutations and one control (listed in the runner's header), and
`bench/umd/run_sub.sh --red` adds X2, G2 and G3 on `sub_ram2_tb`.

## 7. Area and timing (measured 2026-09-26)

Each module is fitted alone with `USE_DOCKER=1 tools/fit_unit.sh` (virtual pins, SEED 1).
The Fmax figures are at the slow corners, 100 / -40 C.

| module | clocks: target -> Fmax | ALM | M10K | DSP |
|---|---|---|---|---|
| `plane_reader` (`SCALE` 1, the ports free) | clk 27 -> 63.9 / 61.6; mclk 90 -> 154.7 / 148.4 | 739 | 16 | 12 |
| `rd_merge2` | mclk 90 -> 137.8 / 131.3 | 261 | 0 | 0 |
| `sub_flip` | mclk 90 -> 339.8 / 348.0; clk 27 -> 293.1 / 301.3 | 130 | 0 | 0 |
| `plane_blend` | clk 27 -> 135.1 / 127.3 | 92 | 0 | 3 |
| **the subtitle plane, all four** | | **1,222** | **16** | **15** |

Against `menus.md`'s estimate of ~700-1,000 ALM, 4-6 M10K and 4-8 DSP per plane:

- **The ALMs are about as estimated.** The reader alone is 739; the merge is shared by
  every plane, and the latch is the subtitle plane's own.
- **The M10K is 16, not 4-6.** The estimate assumed a 480-wide source and one read a dot.
  A 720-wide source with its four neighbours read in one clock needs four banks of 2 x
  512 x 32 bits. M10K is not the scarce resource (`hw_budget_and_lessons.md`).
- **The DSPs are 12 + 3, not 4-8.** That is eight horizontal products and four vertical
  ones, all 4 channels, plus the blend's three. **Check the core's DSP total at
  integration**: the reconstruction uses DSPs too, and the device has 112. If DSPs bind,
  a subtitle-only plane (1:1, no filter) needs none of the twelve. **Built (2026-09-30,
  `area_plan.md` A3): `plane_reader`'s `SCALE` parameter; `sub_overlay` instantiates `SCALE` 0**
  (below; `run_plane.sh`'s sub mode runs on it too, arms S1 / S2).
- **Timing is not a concern on its own.** The reader's clk_sys side has 2.3x margin and
  its mclk side 1.6x. `ddr_mux2`'s `B_FIRST` adds one OR term to its grant condition.

**The whole overlay, `sub_overlay` (the chain + the compositor, one fit, 2026-09-26):**

| clock | target | first fit | after the writer's address stage |
|---|---|---|---|
| sclk (the demux; clk_sys in `emu`) | 27 | 150.8 / 146.6 | 166.8 / 163.3 |
| pclk (`png_top`; clk_sys) | 27 | 49.6 / 48.5 | 50.7 / 50.0 |
| clk (the raster; clk_sys) | 27 | 67.8 / 64.4 | 69.9 / 66.9 |
| **mclk** | 90 | **100.4 / 92.6** | **108.8 / 107.5** |

It uses **4,744 ALM, 72 RAM blocks and 18 DSP**. That is less than the chain's 3,985 plus
the compositor's 1,222 measured apart, since the synthesis shares logic across the
boundary.

- **The first fit left mclk 3 % of margin.** The binding path ran from `sub_sched`'s
  unit position through `sub_plane_wr`'s `(y + uy) * 360 + (x + ux) / 2` into `s0_word`.
- **The fix.** The position is quasi-static: it is set as the unit is taken, hundreds of
  cycles before its first pixel. The writer now registers it and precomputes `uy * 360`,
  which gives 19 %.
- **Next worst path:** `sub_ring`'s read pointer into its engine state, 1.8 ns of slack
  at -40 C.
- **Treat mclk as the overlay's clock to watch in the first core fit**, beside the
  decoder: this fit had the device to itself.

**After the catch-up with `main` and A3 (2026-09-30, `area_plan.md` §6):** same flow, same
clocks, `.sim/fit_ovl.sh` (the file list of `run_overlay.sh`).

| fit | ALM | RAM | DSP | mclk (100 / -40 C) | clk (raster) |
|---|---|---|---|---|---|
| the branch after merging `main` | 4,840 | 72 | 18 | **78.5 / 76.8** (target 90) | 89.9 / 86.0 |
| + the 1:1 reader (weights pinned), `png_chunks`' trims | 4,790 | 72 | 18 | 80.2 / 76.3 | 86.0 / 86.9 |
| **+ no multiplier at 1:1, `sub_mem`'s output register** | **4,691** | 72 | **6** | **96.5 / 93.4** | 102.4 / 95.4 |

- **mclk regressed with the merge.** `main`'s `ddr_mux2` now checks the whole held A
  command (the write data included) to drive A's waitrequest (its orphan guard, the reload
  hang's fix). `sub_mem`'s grant and write-data mux were combinational into the port, so the
  path ran grant → mux → the guard's compare → A's waitrequest → `sub_q`'s push adders:
  12.8 ns against 11.1. **Fixed in `sub_mem`: one output register** (`subtitles.md` §2),
  +40 ALM.
- **The plane reader at 1:1 (`SCALE` 0)** is 250 ALM in the overlay, down from 347. In the
  baseline, `sub_overlay`'s constant geometry had already pruned the bottom-row buffers (8
  M10K, not the unit fit's 16). The 12 multipliers stayed until a parameter select removed
  them at elaboration: stuck-at-zero weights do not remove an inferred DSP.

## 8. The integration (P5e and after)

**One instance: `umd/sub/sub_overlay.sv` (2026-09-26).** It holds everything the
subtitles put on ram2 and on the raster: `sub_top`, `sub_flip`, the plane reader at 1:1,
`rd_merge2`, `ddr_mux2 #(.B_FIRST(1))` and the blend. It has four sets of ports:

- the demux's `sp_*`;
- the STC, `flush` and DDRAM2 on mclk;
- the video reader's read port `v_*` (rd_merge2's P);
- the raster with the video in at LAT 4 and the composite out at LAT 7, plus the counters.

`emu`'s part is then:

- one instance, with `disp_reader`'s master moved from DDRAM2 to `v_*`;
- clk_sys on `sclk`, `pclk` and `clk`;
- the pipeline moves below, the `umd.sdc` bounds and the HUD row.

**Resets.** `mrst_n` is power-on only. A mount, seek or track change is `flush`,
because the port must never be reset mid-burst (P4's lesson on ram1). So `ddr_mux2`'s
abort is tied off inside: nothing in the instance leaves a burst open.

**`bench/umd/run_overlay.sh [--red]`** (`bench/umd/sub_overlay_tb.sv`) runs it as `emu`
will:

- one 27 MHz clock for the demux, `png_top` and the raster;
- mclk at 90 MHz;
- the video from `disp_reader` on `v_*`;
- one DDR3 model;
- the STC at the real 90 kHz, jumping over quiet stretches but never while a request
  waits for its blank or a frame is being scored.

The first whole frame after every acknowledgement is scored at every dot, for both the
plane (LAT 5) and the composite (LAT 7). The expected images come from
`tools/sub_overlay_golden.py`: each unit's plane is rebuilt from libpng's plane words,
placed where the tool says, and composited over the video.

The cases:

- the synthetic set: RGBA8, Adam7, RGB16, clipped at two edges, a refused PNG;
- the corpus's extremes:
  - The Animatrix 0x81 #73, 636 wide with its right edge at 680, the widest fetch;
  - Stargate 0x80 #71, 349x441, the tallest;
  - The Animatrix 0x80 #514, 33x369 at x 612: vertical text;
- **two flushes**:
  - one inside a write burst of the first unit's plane. That unit is never shown; the
    later ones are, exactly, and `[hang]` checks the port holds no open burst;
  - one as a flip is requested. The flip is shown for one frame and hidden at the very
    next blank (`[flush]`).

**Found by composing it** (2026-09-26), all three fixed:

- **`sub_plane_wr` abandoned a DDR3 write burst on `flush`.** The controller would wait
  for the missing beats forever, and `ddr_mux2` keeps the channel inside a write burst,
  so a seek during a decode would have hung ram2 and frozen the video with it. The burst
  on the port now runs to its last beat, and the fill side restarts in the other
  ping-pong buffer, the one the engine takes next (O3 restores the old behaviour:
  `[hang]`).
- **A flip requested when a flush came was shown for the dropped unit's whole
  duration.** It cannot be withdrawn, since the display may be latching it. Now it is
  hidden as soon as it is acknowledged (`sub_sched`'s `fl_hide`, O4: `[flush]`).
- **One stale pixel.** `sub_png` resets one cycle after the flush, so the writer could
  take one more pixel from the old image. It now sees the flush for both cycles. The
  pixel would have landed at the dropped unit's position in the back plane, outside any
  later rectangle, so no bench can see this one; the fix is defensive.

**Still `emu`'s, after P5e:**

- **Layer order and latency.** `disp_reader` is LAT 4, the plane is LAT 5, the blend
  adds 2. The video is delayed 1 into the blend, the composite comes out at LAT 7, and
  `emu`'s sync, HUD and wave pipelines move from 4 to 7. The HUD composes over the
  composite as it does over the video today.
- `vbl` = h_pos 0 of line 500, the picture snapshot's strobe.
- `umd.sdc`: these are quasi-static captures like `disp_reader`'s and need the same
  bounds:
  - the plane reader's request fields and geometry (clk_sys -> mclk);
  - `sub_flip`'s held request (`hb, hv, hx, hy, hw, hh`: mclk registers read on clk_sys
    at the latch);
  - the first stages of the `req_tog` / `ack_tog` synchronisers.
- **HUD:** `n_late`, `geo_bad`, `n_flips` (a bound that is hit must be visible).
- **The menu plane (P9) is a third raster reader.** `rd_merge2` takes two, so it becomes
  a merge of three or two merges in cascade, video first either way. Measure the line
  budget again with three readers.

## 9. Rejected alternatives

- **Interpolating straight RGBA.** It drags transparent pixels' colour into soft edges
  (`menus.md` §4). The planes are premultiplied for this reason.
- **Nearest neighbour.** Uneven strokes at 1.5x and 1.7647x (`menus.md` §4, decided
  2026-09-25).
- **One 64-bit line buffer read twice a dot.** It needs a 54 MHz read side; four
  32-bit banks read once a dot cost the same M10K.
- **A level handshake for the flips.** It loses sub_sched's one-cycle gap (§4).
- **Alternation on ram2.** Measured in §5.
- **A row cache.** §5.

## 10. Known limitations

- One dot per clk_sys cycle (`sync_gen` with `clk_en = 1`), as `disp_reader` assumes.
- The line-request rule (lines 1-479 requested at v 0-478, line 0 at v 524) is the
  525-line progressive raster's, shared with `disp_reader`. When the 480i raster lands
  (roadmap), both readers change together.
- The buffer pitch is fixed at 720 pixels, and every source is inside a 720x480 buffer.
- Downscaling is bilinear point sampling: past 2x it aliases. No owner downscales today.
  The subtitle plane is 1:1 and the menus scale up.
- A late line shows the buffer half's old contents for one line and is counted.
