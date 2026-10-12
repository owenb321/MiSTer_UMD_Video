# Subtitles in fabric (P7)

> **A12 (2026-10-07, `nav_engine.md` §11): the decode is in the fabric again.** From A7 (PR fj#34) the
> UMD Main decoded each unit; since SD1 `umd/sub/sub_dec.sv` answers `sub_top`'s host handshake with the
> hardwired `png_top` (`sub_png`, `sub_plane_wr` restored), so a stock Main shows subtitles. The chain,
> the ring, the scheduler and the compositor below are unchanged.

From the demultiplexer's subtitle bytes to a premultiplied ARGB plane in DDR3, shown and
hidden on the system time clock. The PNG decoder itself is `docs/png_decode.md`. Built
in parallel with P5, standalone, ✅ MERGED (PR fj#28, 2026-09-30); the `emu` wiring and the
core fit ✅ MERGED (PR fj#29), ✅ HW-CONFIRMED (§7). **A7, built in B3 (2026-10-01, ✅ MERGED PR fj#34;
`docs/hps_host.md` §3, §6 "B3, as built"):** the decode left the fabric. `sub_png` and `sub_plane_wr`
are deleted, and the ring's reader is gone. `sub_in` / `sub_unit` / `sub_ring`'s writer, `sub_sched`'s
STC timing and the compositor stay; the UMD Main reads each unit from the ring and writes the plane,
answering a request `sub_top` makes at `q_take` (the ring frees the unit at the completion).
§2-§4 below describe the chain as P7 built it; where they mention the PNG decoder, the plane
writer or the ring's reader, read "the host".

## 1. What the streams do (measured, `tools/sub_timing_census.py`, 2026-09-26)

590 subtitle tracks over 70 discs. Times are 90 kHz ticks.

| quantity | measured | where |
|---|---|---|
| lead = unit PTS - SCR of the pack carrying its first byte | **0.57 s .. 1.00 s** (50,915 .. 90,000) | The Incredibles / Akira |
| smallest step between consecutive PTS | **0.1 s** (9,009) | The Mummy, track 0x8B |
| largest unit | 7,214 bytes (the PNG 7,194) | Toy Story |
| display intervals that overlap | **none** | -- |
| units in flight (arrived, not yet ended), demux 0 / 0.5 / 1 / 2 / 5 s ahead of the clock | 3 / 4 / 4 / 4 / 7 units; at most 14,173 / 15,788 / 15,788 / 16,789 / 19,382 bytes | Akira, Cowboy Bebop, 28 Days Later / Toy Story |

Consequences:

- **A unit must be buffered whole.** `ps_demux` hands subtitle bytes over with **no
  back-pressure** (`sp_*` has no ready: stalling the demux would stall video and audio).
  They come at up to a byte a cycle, and the PNG decoder takes compressed bytes far more
  slowly.
- **Decode when the back plane is free, not at a lead before the PTS.** A unit is in the
  stream at least 0.57 s before its PTS, and the next PTS is at least 0.1 s later. The
  largest measured subtitle decodes in ~17 ms at 27 MHz. So decoding right after the
  previous flip always has time, and there is no lead parameter to tune wrong. Two planes
  are enough: one shown, one being decoded; the rest wait compressed.
- One subtitle on screen at a time. A new flip replaces the shown one; the hide time
  follows the shown unit.

## 2. Architecture

```
clk_sys (demux side)              |  mclk (the DDR3 port's clock)                   | pclk (png_top's; free choice)
                                  |                                                  |
ps_demux sp_* --> sub_unit ------fifo_dc bytes (4 KB, {kind, byte})--> sub_ring    |
                  (header parse, |  fifo_dc records ---------------> writer ---+    |
                   PES assembly)  |                                    |        |    |
                                  |      metadata FIFO (64 units) <----+        |    |
                                  |            |                                v    |
                                  |      sub_sched (STC, flip / hide) --> ring reader --fifo_dc--> png_top
                                  |            |                                     |                 |
                                  |      plane writer (premultiply, clip, <--fifo_dc pixels------------+
                                  |       write-combine)                             |
                                  |      sub_mem: ring writer > ring reader > plane writer = one master
                                  |            |                                     |
                                  |      ddr_mux2 (B_FIRST)  A = sub_mem, B = rd_merge2 {disp_reader, plane_reader}
                                  |            |                                     |
                                  |          DDRAM2 (ram2)                           |
```

- **`sub_unit`** (clk_sys, a byte a cycle). This is PES assembly by the rules
  `umd_sub_extract.py` measured:
  - a unit starts in a PES with a PTS whose payload opens with `u32 len, "0088"`, and
    runs across later PES until `len` bytes;
  - the header gives duration, x, y;
  - the unknown fields (0x0010, 0) are ignored but counted when different;
  - stray / orphan / truncated PES are counted and never glued.

  It writes the PNG bytes into the byte FIFO, and the unit's record {PTS, duration, x,
  y, PNG length} into the record FIFO when the unit is complete. A unit that cannot be
  written whole (the byte FIFO full) is dropped. An abort word tells the other side to
  rewind, and the drop is counted.
- **`sub_ring`** (mclk):
  - the **compressed-unit ring in DDR3**: bytes packed 8 to a 64-bit word, written in
    bursts, each unit starting on a word;
  - the metadata FIFO of units in the ring;
  - the reader that streams a unit back to `png_top` with `in_last` on its final byte.
  - A unit is admitted only when the ring and the metadata FIFO have room for all of
    it. Else it is dropped and counted.
- **`sub_sched`** (mclk). Takes a 33-bit STC with a valid flag and compares with
  wrap-aware signed subtraction.
  - When the back plane is free and a unit is queued, it starts its decode.
  - A clean decode makes the back plane ready. A refused one (`png_top` err != 0) frees
    it, and the refusal is counted.
  - At STC >= PTS a ready plane is flipped. The flip is a **request** the display side
    latches at vblank and **acknowledges**. The old front plane is free only on that
    acknowledgement, never at the PTS, so the plane being scanned is never overwritten
    and a flip never tears.
  - At STC >= PTS + duration the shown plane is hidden (also a request / acknowledge).
  - Late flips (decode finished after the PTS) and missed units (the PTS + duration
    passed before the decode finished) are counted.
  - `flush` (a seek, a track change) empties the ring and the queue and hides the plane.
  - There are no pause semantics: P5e's clock simply stops.
- **Plane writer** (mclk):
  - Pixels arrive from `png_top` as straight RGBA + (x, y). Each is placed at (x + X,
    y + Y) in a **720-pixel-pitch plane at absolute coordinates**.
  - Pixels outside 720x480 are clipped and counted. No disc does this, but the header's
    u16 x / y allow it.
  - Colour is **premultiplied**: c' = round(c * a / 255), computed exactly as
    (c*a + 128 + ((c*a + 128) >> 8)) >> 8. It is written as ARGB8888, 2 pixels a 64-bit
    word.
  - Consecutive pixels are combined into bursts of up to 8 words; anything else
    (Adam7's strided passes) is a byte-enabled single word.
  - **Each buffer carries its rectangle** {X, Y, w, h}, latched with the flip. The
    compositor draws everything outside it as transparent, so nothing is ever cleared.
- **`sub_mem`** (mclk): the subtitle side's own arbiter, one read / write master:
  - the ring writer first (the demux cannot be stalled);
  - then the ring reader;
  - then the plane writer.

  The grant moves only between commands: never inside a write burst, and never while the
  port holds a command off (Avalon). **Its output is a register** (2026-09-30): the port sees only a held command, and the grant
  and the write-data mux no longer reach `ddr_mux2`'s orphan guard combinationally (mclk
  76.8 → 93.4 MHz cold in the unit fit, +40 ALM: `compositor.md` §7). It is master A of
  `ddr_mux2` on ram2.
- **Where the plane reader goes (built 2026-09-26, `compositor.md` §5).** The
  compositor's plane reader is a second raster-paced reader. It joins the display reader
  on the B side through a read merge with an owner FIFO (`umd/rd_merge2.sv`), never inside
  A: behind ring and plane writes it could miss a line. With both readers on B, the mux's
  A/B alternation missed lines under a slow DDR3 model, so on ram2 the readers cut in
  ahead of every blocked subtitle write (`ddr_mux2 #(.B_FIRST(1))`). A keeps >= 296
  words a line with A saturating, and needs ~10.

**DDR3 regions** (64-bit word addresses; the DPB window starts at 0x0600_0000 and takes
32 MB):

| region | words | size |
|---|---|---|
| the unit ring | 0x0640_0000 .. + 0x10_0000 | 8 MB |
| plane 0 / plane 1 | 0x0650_0000 / 0x0658_0000 | 1.38 MB used of 4 MB each |

P6's audio buffer is also planned on ram2: the regions must be reconciled at the merge.
The bases and sizes are parameters.

**Why a DDR3 ring, not an M10K queue.** An M10K queue sized to the census (19.4 KB with
the demux 5 s ahead) would work on every disc, but the unit length field is u32: it
would be a deviation from the spec maximum (CLAUDE.md). An 8 MB ring holds any PNG that
fits the frame: 720x480 RGBA16 stored is ~2.8 MB. The plane needs a ram2 master anyway,
so the ring costs one more client of it.

**Clocks.** `png_top` has been synthesised but never timed. It sits between two
`fifo_dc`s (bytes in, pixels out), so the integration fit can run it on clk_sys, mclk or
anything else. Nothing crosses beside the data:
- a PNG starts at the first byte after a `last`;
- its end {verdict, w, h} travels **in band** after its last pixel. A separate pulse could
  overtake pixels still in the FIFO.

The spec-maximum unit (~2.8 MB) would take ~0.45 s at 27 MHz and miss a 0.1 s gap: that
is what the late / missed counters are for.

**Timing, measured** (`tools/fit_unit.sh sub_top`, a full fit of the chain alone with
virtual pins, 2026-09-26). The clocks' Fmax at the slow corners, 100 / -40 C:

| clock | target | first fit | now |
|---|---|---|---|
| sclk (the demux) | 27 MHz | 170.4 / 169.3 | 144.0 / 146.7 |
| **mclk (the DDR3 port)** | 90 MHz | **78.1 / 75.5: FAIL** | **102.8 / 95.7** |
| pclk (`png_top`) | the fit's choice | 63.0 / 61.9 (asked for 90) | 50.8 / 49.2 (asked for 27) |

- **`png_top` cannot run at 90 MHz.** It closes around 50-60 MHz: **run it on clk_sys
  (27 MHz)**, as the end-to-end bench already assumes.
- **mclk failed twice, each fixed by a register stage:**
  - the plane writer's pixel address, three adders deep, fed the word compare and the
    burst control in one cycle. The address, clip test and premultiply are now registered
    as a word is taken (`sub_plane_wr` s0);
  - `sub_unit`'s header length fed the ring's room compare, then the accept, then the
    unit count. The length, its word count and the "no PNG" verdict are now registered a
    cycle before the begin request (`U_LEN`, `u_words`).
- **The margin is ~6 % at the cold corner, on an otherwise empty device.** Beside the
  decoder the placer has less room: treat mclk as the chain's clock to watch in the first
  core fit (`tools/fit_unit_paths.sh sub_top mclk` names the worst paths).

## 3. Interfaces (`umd/sub/sub_top.sv`)

| side | clock | signals |
|---|---|---|
| the demux | sclk | `sp_byte / sp_valid / sp_frame_start / sp_pts / sp_pts_valid`: `ps_demux`'s own `sp_*`, unchanged (no ready) |
| png_top | pclk | nothing outside: png_top's clock only |
| the clock | mclk | `stc[32:0]`, `stc_valid` (P5e's STC, crossed to mclk by the integration); `flush` |
| the display | mclk | `d_req` (level) with `d_buf, d_vis, d_x, d_y, d_w, d_h`; `d_ack` (a pulse at the vblank that latched it). `umd/sub/sub_flip.sv` crosses them with a toggle handshake (`compositor.md` §4). |
| DDR3 | mclk | one Avalon master: `ddr_mux2`'s A on ram2 |
| counters | sclk / mclk | in: bytes / PTS lost. Units: whole, truncated, overrun, orphan, lost, ring full, bad header, odd header field. Plane: pixels clipped. Scheduler: shown, late, missed, refused. For a HUD row at integration. |

Parameters: the ring's base and size (`RAW`, default 2^20 words = 8 MB), the queue depth
(`MAW`, default 64 units) and the two planes' bases.

## 4. Verification (`bench/umd/run_sub.sh [--red]`)

Goldens (`tools/sub_golden.py`):
- **the units** are what `tools/umd_sub_extract.py` finds, the tool that measured every
  disc in P1;
- **the planes** are libpng's pixels (`tools/png_oracle.c`) premultiplied by the formula
  in §2, laid into the 720-pitch plane and clipped.

| bench | what | cases |
|---|---|---|
| `sub_unit_tb` | PES payloads -> units, record and bytes; every counter | six synthetic streams (a one-byte continuation, a PTS-bearing continuation, truncation, overrun, orphans, a lost-bytes gap, refusals, a header with no PNG, odd header fields), straight and under stalls; Akira's and The Mummy's whole tracks (1,251 + 1,048 units) |
| `sub_ring_tb` | `sub_unit` -> ring -> a consumer, through `ddr_model` (random waits / latencies); a 32 KB ring that wraps ~45 times on Akira | straight; stalled; the consumer held (the ring fills: 16 admitted, 1,235 refused, exactly per the admission rule); a flush mid-stream (only later units come out) |
| `sub_top_tb` | end to end on three clocks: sclk 27, mclk 90, pclk 27 MHz (png_top on the slowest clock the fit could give it). The STC runs at the real ratio (1,000 mclk cycles a tick) and jumps between events when nothing moves; input released 0.8 s before each PTS; vblank every 1,500 ticks | the synthetic set: RGBA8, Adam7 4-bit, RGB16, a rectangle clipped at the right and bottom edges (1,131 pixels, as the golden says), a bad IDAT CRC (refused, never shown); Akira's first 12 units; The Mummy's tightest window (a 0.1 s unit, then a 583x275 one) |
| `sub_ram2_tb` | the raster readers' line fetches -- the video's 180 words and the plane's 720 (two whole rows, the bilinear worst case) -- through `rd_merge2` and `ddr_mux2 (B_FIRST)` against a subtitle master that never stops; `[data]` every beat to its owner, `[proto]` a command held under waitrequest, `[share]` the subtitle master >= 32 words a line | every line of both readers inside its 2,860 cycles: worst plane 999 cycles with the model's defaults, 1,136 at 70 % waits and latency 20-120 (`compositor.md` §5); and the merge alone on the model at latency 150-200 (`-P DIRECT=1`), where its own FIFO guard binds |

Every acknowledged flip in `sub_top_tb` must:
- be the tool's next unit, with refused ones skipped;
- come no earlier than its PTS and before its end;
- carry the rectangle `{x, y, w, h}`;
- have **every plane word in DDR3 equal to the golden** under its byte mask.

A hide must come at or after the unit's end. `[tear]`: no write may ever land in the plane
the display holds. At the end: every unit shown, with refused / missed / late / clipped
counted exactly.

`--red`, each mutation caught by its own arm:

| mutation | arm |
|---|---|
| the PTS-bearing continuation not replayed | `[unit]` |
| overrun not counted | `[count]` |
| a gap not aborting its unit | `[count]` |
| the ring's byte order in a word | `[unit]` |
| admission ignoring the ring's room | `[count]` / `[unit]` |
| a burst crossing the ring's end | `[unit]` / `[ddr]` |
| the premultiply's rounding | `[plane]` |
| the odd/even pixel of a word | `[plane]` |
| clipping removed | `[tear]`: it spills into the plane on screen |
| a flip before its PTS | `[time]` |
| a hide before its end | `[time]` |
| the decode aimed at the front plane | `[plane]` |
| the plane writer let in with read beats outstanding | `[ddr]` |
| `ddr_mux2`'s fairness to the display removed | `[latency]` |
| `B_FIRST`'s cut-in only once again (the alternation), slow model | `[latency]` |
| the read merge's FIFO guard removed (alone on the model) | `[ddr]` (the model's credit rule, before a beat is misrouted) |
| the read merge recording the wrong owner | `[data]` |

**Found on the way:**
- A continuation PES *without* a PTS lost its first byte (`sub_unit`).
- Composing the overlay (`compositor.md` §8): `flush` abandoned the plane writer's DDR3
  burst on the port (a seek mid-decode would hang ram2), and a flip requested at a flush
  stayed up for the dropped unit's duration. Both fixed; `run_overlay.sh`'s two flush
  cases hold them.
- The ring wrote a burst with its own read beats outstanding, which breaks the port rule.
- `sub_mem` left the plane writer presented while reads were out.
- **`sub_mem` moved its grant under waitrequest** (2026-09-30, found when the branch caught
  up with `main`, whose `ddr_model` polices the Avalon rule since the reload-hang fix, PR fj#11).
  The plane writer's first write beat was held off by the port; the ring then asked, and the
  grant (combinational between commands) went to it, changing the held command. The Mummy's
  0.1 s window hit it (`[avalon]`, address 064234e7). Fixed: the grant is kept while the port
  holds a command off; RED arm M2 (`run_sub.sh`, The Mummy's window).
- Bench bugs, found before they could hide anything:
  - an acknowledgement carried across the reset between cases;
  - an STC jump over a decode in flight (the decoder can run long with no DDR3 command);
  - a 20x time compression that made a real-rate-safe window look late.

**Measured area** (`USE_DOCKER=1 tools/synth_unit.sh sub_top ...`, synthesis only,
2026-09-26): **3,830 ALMs** for the whole chain, the PNG decoder's 2,221 included. It uses
4,544 registers and 402,096 block bits, and every RAM is inferred. The full fit
(`tools/fit_unit.sh`, after the timing stages) places **3,985 ALMs and 64 RAM blocks**.

| entity | LUTs | registers | memory |
|---|---|---|---|
| `sub_png` (+ `png_top`) | 3,561 | 2,219 | the decoder's; two small `fifo_dc` |
| `sub_ring` | 830 | 1,000 | the record queue 64 x 150, read data 16 x 64, burst buffers 16 x 64 |
| `sub_unit` | 385 | 469 | -- (the 20-byte header in registers) |
| `sub_plane_wr` | 317 | 307 | burst buffers; 3 DSP (the premultiply) |
| `sub_sched` | 257 | 301 | -- |
| `sub_mem` | 180 | 18 | -- |
| `sub_in` | 135 | 227 | the 4 KB byte FIFO, the 16-entry PTS FIFO |

Found by the synthesis: the first `sub_q` muxed its bypass in front of the output
register. Quartus could not infer the RAM, and the 64 x 149-bit record queue became
9,500 registers: the chain synthesised to 10,491 ALMs. With the mux after the RAM it is
3,830. Room left if ever needed:
- the 32-bit counters and lengths;
- the 150-bit pending records;
- `sub_unit`'s 20 header registers.

The compositor comes on top: `compositor.md` §7 has its measured area.

## 7. The integration into `emu` (`feature/p7-subs`, planned 2026-09-30)

The display path that §7 used to wait for is done (P5, P6b). The overlay's own plan is
`compositor.md` §8; this section adds the `emu` side, the user's control and the stages.

**Decisions (the maintainer, 2026-09-30):**

| # | question | decided |
|---|---|---|
| S1 | Subtitles at a mount | **Off.** Nothing shows until the Subtitle button (J1 B9; keys S, F4) is pressed |
| S2 | The Subtitle button | **Steps Off → 1 → 2 → … → Off** through the declared tracks (0x80-0x9F, in id order), as Audio steps through its tracks; each press shows a tag bottom-left with the track number and its language. **Amended (the maintainer, 2026-10-05, P6d's rig test):** the first press SHOWS the current state (the tag, nothing changed); a press while that tag is up steps (`emu`'s `th_show_sub`, `panel.md` §3.11). Audio the same |
| S3 | The tag's icon | **A speech balloon, drawn into the transport HUD's spare glyphs (117-127), mockups approved before RTL** (P6b5's rule) |
| S4 | Shipping | P7a and P7b land in ONE PR: no build with subtitles forced on and no way to turn them off reaches a user |
| S5 | The balloon (after the mockups, `.sim/p7_mockups`) | **B, the outline** (over A, filled with three dots cut out); glyphs 117-118 |
| S6 | Display on over a bottom subtitle (mockup p7_07: the chapter / time box and the bar land on its second line) | **The HUD draws over the subtitle**, as mocked: no extra logic |
| -- | *(fj#71, 2026-10-09)* under Aspect Ratio's Zoom only raster lines 60 .. 419 are shown | the subtitle is placed with its y clamped into them (`sub_overlay`'s `z_dy` / `z_dh`; the UMD Main's `zoom_place` under the panel): `docs/zoom.md` Z3 |
| S7 | The diagnostic HUD's subtitle counters (its 14 visible rows were full) | **Row 6's P2-era video CRC gives its room**: `AUD {at}/{ap} SUB {sp}/{sq} U{su} S{ss} D{sd} L{sz}` (the CRC stays a field, unplaced; the field id widened to 7 bits) |
| S8 | (P9 M4b, the maintainer on the rig, 2026-10-04) A disc that sets the subtitles itself -- The Island's script turns them off at every play -- popped the subtitle tag each time | **The tag answers the Subtitle button only**: `player_ctl` marks a SUB_SET's SUB event (data[6]) and `transport_hud` draws no tag for it, as the PSP shows nothing when a disc changes them. `run_player_ctl` [sub] G9, `run_transport_hud` b19 / b20, H42 |

**The stages:**

| stage | what | gate |
|---|---|---|
| **P7a** | `sub_overlay` in `emu`: `disp_reader`'s master moved behind it (`v_*`), DDRAM2's write side live, clk_sys on sclk / pclk / clk, mclk = clk_mem; `flush` from the mount / seek reset (a `cdc_reset` onto clk_mem, as the pipeline's); the STC from `disp_ctl` (`stc`, `stc_run`); the raster moved to LAT 7 (below); `umd.sdc`'s bounds (`compositor.md` §8); the counters on the diagnostic HUD and in telemetry; `UMD.qsf`. The track: the demux's current lowest-declared selection, enabled only by an internal flag that P7b drives (so P7a's netlist shows nothing by default either) | `check_emu_wiring.py`; `run_scaffold.sh --red` + a wiring mutation that ties the overlay off; `lint_undriven`; the fit + a 5-seed sweep (`area_plan.md` A2), mclk read beside clk_dec |
| **P7b** | the control: `player_ctl` command 12 (SUB: the next of Off / the declared tracks, wrapping), `sub_track` / `sub_on` out; a track change is a subtitle-only flush (the overlay's `flush` + the demux's subtitle realign, never a torn unit into the ring: `sub_unit`'s `n_truncated` counts one if it happens); the transport HUD's tag with the balloon (mockups first, S3); the manual (controls, the on-screen messages, compatibility); telemetry | `run_player_ctl.sh` (the stepping vs its model), `run_transport_hud.sh --red` (the new states pixel-exact), `docs_check.py`, `mkdocs --strict` |
| **P7c** | the rig: subtitles at the right times on Akira and The Mummy (the corpus's tightest window), a seek / chapter / trick play / stop with subtitles on, a track step on a multi-track disc; the roadmap's P7 HW gate | `mister.py`, screenshots vs `umd_sub_extract`'s times |

**The raster at LAT 7.** `disp_reader`'s picture is LAT 4 and the composite comes out at LAT
7. The subtitles blend over the PICTURE only (Stop's wave covers everything, as today).
- The pixel-only consumers take a copy of the raster delayed 3 cycles (h_pos, v_pos,
  pixel_en, the syncs): `xmb_wave`, `diag_hud`, `transport_hud`, the output register. Their
  outputs then line up at LAT 7.
- `pic_de` / `pic_on` get the same 3-flop delay.
- **Everything that talks to the display scheduler or a reader stays on the undelayed raster**:
  `disp_ctl` (eval / pickup at lines 499 / 500), `disp_reader`, `sub_overlay` itself (its
  `vbl` = h_pos 0 of line 500), `sync_gen`'s frame tick, `player_ctl`'s `pick`.

**The DDR3 map** (64-bit word addresses on the core's window; every region checked,
2026-09-30):

| region | words | written by / read by |
|---|---|---|
| the DPB, 20 stores | `0x0600_0000`-`0x0628_0000` | ram1 (`dpb_mem`) / ram2 (`disp_reader`) |
| the compressed-video buffer | `0x0628_0000`-`0x062C_0000` | ram1 (`vbuf`, 2^18 words) |
| the subtitle ring | `0x0640_0000`-`0x0650_0000` | ram2 (`sub_ring`, 2^20 words = 8 MB) |
| the subtitle planes 0 / 1 | `0x0650_0000` / `0x0658_0000`, `0x2A300` words each | ram2 (`sub_plane_wr` / `plane_reader`) |
| the PCM region (P9: the menus' sounds) | `0x0660_0000`-`0x0670_0000` | ram2 (`pcm_shot`, read; the HPS writes it) |
| (the framework's scaler buffer) | `0x0400_0000`-`0x0410_0000` | sys's `ascal` |

**As built (2026-09-30, `feature/p7-subs`):**
- **P7a** in `emu`: `sub_overlay` on ram2 (the display reader behind its read merge);
  `lock_sys_n` (a `cdc_reset` of `locked` on clk_sys) for its clk_sys sides; the STC to
  clk_mem in a `cdc_snap`; the flush registered on clk_mem from the mount / seek reset OR a
  subtitle change; the raster's pixel consumers on `h_pos_l7` / `v_pos_l7` / `pixel_en_l7`
  and the syncs at LAT 7; the background from the composite while playing; `umd.sdc`'s
  `sub_flip` / `plane_reader` bounds; `UMD.qsf`. `check_emu_wiring.py` pins it all (the
  overlay owns ram2, its resets, its flush, the LAT 7 split); `run_scaffold.sh --red` W67-W71
  (W12 / W14 re-pointed).
- **P7b**: `player_ctl` command 12 SUB and event 9 (S1 / S2; `run_player_ctl.sh`'s `[sub]`
  arm, P43-P46; the bench's reserved-command probe moved from 12 to 13), `emu`'s Subtitle
  button (J1 bit 12) and the demux's `sp_on` (on, not flushing, not in trick play);
  the transport HUD's subtitle tag (the K_TRACK pop-up with `tsub` / `toff`, the rank over
  up to 32 tracks, the language at `lang_sel` 16 + n; `run_transport_hud.sh` states
  p7_* / b13 / b14, H19-H22); the diagnostic row (S7; `run_diag_hud.sh` H7 on the 7-bit id);
  the manual (controls, on-screen messages, compatibility, troubleshooting).
- **Known limitations:**
  - After a seek, a chapter or trick play, the unit covering the landing point was sent
    before the entry the demux restarts at, so it is not shown; the next unit is. (The
    census: units arrive 0.57-1.0 s ahead.)
  - A switch drops the rest of a unit in flight as orphan bytes (`n_orphan`, deliberately
    not in the HUD's `D`).
  - Not covered by a bench: the "off at a remount" rule (the scripts never remount after a
    SUB press) and "a clip that no longer declares the track turns them off" (the mock
    reader has one mask per title). Both are single assignments in `player_ctl`; the rig
    covers a multi-item title in P7c.

**P7c, the rig (2026-09-30, .236; `.sim/p7c`):**
- **The first build** (`UMD_p7subs_20260930_1536.rbf`): Akira's first ten lines appear and clear
  in the second the disc says (screenshot bursts with the Display clock: 106.1, 110.3, 113.7,
  117.3, 120.7-123.2, the 2 s gap, 125.3, 127.1-129.0, 130.6-132.3, nothing to 147.1), at their
  placement (y 379 two-line, y 411 one-line); the tag `(balloon) 1 English`; off at load (the
  diagnostic row `U000 S000`). **A chapter jump turned them off** (the tag `Off` unpressed): the
  reader's CLP re-read empties its masks before every item start and `player_ctl` judged them
  every cycle. **The audio default had the same defect since P6b3**, confirmed on the rig as a
  control arm: `AUD 1/0003` before a chapter jump, `AUD 0/0003` after. Fixed (both rules at
  `rd_item_start`; `transport.md` §9), the bench's mock reader now models the transient (P47 /
  P48).
- **The fixed build** (`UMD_p7subs_MARGINAL_20260930_1641.rbf`, clk_dec 84.92 / 84.73 on SEED 9:
  functional at clk_dec's 81 MHz, a seed sweep owed): `AUD 1/0003` through two chapter jumps;
  Aliens stepped `1 English, 2 da, 3 fi, 4 no, 5 sv, Off`; on Danish across a jump to chapter 2
  the subtitles stay on and Danish lines show on time (335.2 "- Forfærdeligt.", 338.3 "- Hvor er
  jeg?"); Stop shows the wave alone, play resumes the lines, Off clears them; The Mummy's 19
  tracks stepped to `12 Japanese` and its 0.1 s line (239.74-239.84) passed with `U021 S021 D00
  L00`; fast forward shows none during the hops and play resumes them (`U024 S024 D00 L00`).
  Every counter `D00 L00` throughout. **The roadmap's P7 HW gate (subtitles at the right times on
  a known disc) is met on this MARGINAL build (clk_dec 84.7 cold); it is re-run on the
  shipping fit (at least Akira's timing burst and the chapter jump) before it is marked
  HW-CONFIRMED.** **Re-run 2026-09-30 on the shipping fit** (`UMD_p7subs_sweep2_20260930_2056.rbf`,
  SEED 3, clk_dec 89.73 / 89.67, 5cf7c69): Akira's burst identical to round one (every line in its
  second, every gap clear); a chapter jump keeps the subtitles on (chapter 2's "Twin ceramic rotor
  drives on each wheel..." shown after it) and the chosen audio track (`AUD 1/0003`); `U00B S00B
  D00 L00`. **✅ HW-CONFIRMED.**

**The demux already selects a track.** `emu` gives `ps_demux` the lowest declared subtitle
substream today (`sp_track`), and `sub_take` counts the bytes for the diagnostic HUD. The
overlay adds a second consumer of the same `sp_*`; neither can stall the demux (the ring's
admission rule refuses a unit it cannot hold, counted).
