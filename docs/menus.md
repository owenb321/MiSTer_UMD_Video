# Disc menus (RCO / VSMX): design for a fabric host and an HPS host

**Status: design only, decided 2026-09-25 (the user); no code. ⚠ Superseded for its milestones and host A by `docs/p9.md` (2026-10-01: M0 done, host B the plan); §1's measurements, §2's oracles and §4's contract stand as amended there.** **Amended 2026-09-30
(`area_plan.md` §8 A10, `hps_host.md` §3.4): the menus draw into the subtitle plane**, which the
HPS takes over while a menu is up (`ui`; subtitles do not play under a menu). Host B renders the menus at 720 x 480
(§4 item 1's "host B may instead render at 720x480" becomes the rule). No bilinear scaler is
built in fabric. Menus are roadmap
Phase 9 (after P7). This note fixes what P6 and P7 must leave room for **now**
(§6), so that menus later arrive as a new client of existing parts, not a rewrite.

Today the core plays the longest playlist and never looks at `UMD_VIDEO/RESOURCE/`.
The goal is the disc's own experience: warnings, the main menu, scene select, set-up,
sneak peeks. It must stay possible whichever way the final P5-P7 fit lands, so the
design has **two hosts** for one engine (§3).

---

## 1. What the menus are (measured 2026-09-25, 8 local discs)

Measured read-only with `tools/umd_iso.py` plus a throwaway VSMX header reader (the
rcomage field layout) on Akira, Austin Powers, Family Guy, Interstella 5555, The Matrix,
Short Circuit, Terminator 2 and The Office Disc 01. The other 25 discs of the census are
not yet measured: that is M0 (§7). ⚠ Eight discs are a sample, not the population
(CLAUDE.md "design to the spec maximum").

- **The menus are compiled, not JavaScript source.** Each `RESOURCE/*.RCO` (`\0PRF`,
  version 0x70 or 0x71, 65-517 KB) holds exactly one **VSMX** block: Sony's compiled
  ECMAScript, a stack-machine bytecode at 8 bytes per instruction. **No parser is needed.**
  The hard parts are the object model (dynamic types, properties, strings, floats,
  functions and closures, garbage) and Sony's player API. The language is not the problem.
- **Script size** ranges from 482 instructions (each of Austin Powers' 22 `EN0020xx`
  sub-pages) through 2,760 (Akira), 5,141-6,773 (Family Guy, The Matrix, The Office,
  T2) and 13,355 (the Austin Powers main menu) up to **14,888 (Interstella, 119 KB)**. String tables reach 145
  entries / 7,994 B (The Matrix); property tables 201 entries (Austin Powers).
- **The API surface**: 467 distinct identifiers over the eight discs. Those on at least
  four discs:
  - playback: `play`, `stop`, `resume`, `getPlayerStatus`, `playStatus`,
    `playListNumber`, `chapterNumber`
  - tracks: `audioNumber`, `audioLanguageCode`, `subtitleFlag`, `subtitleNumber`
  - state: `getResumeInfo`, `changeResumeInfo`, `getUserData`, `setUserData`
  - switching: `changeResource`, `animRetryChangeResource`
  - timers: `setInterval`, `clearInterval`
  - the scene graph: `root`, `pageRoot`, `children`, `pagetable`, `texturetable`,
    `animtable`, `setFocus`, `setPos/getPos`, `setSize/getSize`, `setScale`, `setColor`,
    `animPos`, `animScale`, `animColor`, `texture`, `open`, `close`, `activate`
  - callbacks: `onAutoPlay`, `onChangeResource`, `onChapter`, `onContinuePlay`, `onExit`,
    `onMenu`, `onPlayListEnd`

  On two or three discs: `onFocusUp/Down/Left/Right`, `onPush`, `onCancel`, `onMark`,
  `soundtable`, `fadein`, `fadeout`, `subtitleLanguageCode`, `prototype`, `floor`, `abs`, `min`.
- **Art: 573 plain PNGs** inside the containers (no GIM textures):
  - 351 8-bit indexed, 103 4-bit indexed, **102 RGBA8**, 10 1-bit, 5 RGB, 2 2-bit.
  - Authored for the PSP's **480x272** screen: 32 are full-screen 480x272. The largest is 512x463.
  - Common sizes: 46x34, 123x69, 400x30, 512x288, 8x8.
  - This is a wider population than the subtitles, which are all 4-bit indexed (P7's `png_unfilter` targets).
  - **The whole library, 2026-09-26** (`tools/rco_png.py`, every RCO on every disc, the
    image region accounted for byte by byte):
    - **6,150 PNGs** in 262 RCO files on 89 discs:
      - 4,058 8-bit indexed, plus 1 of them **Adam7-interlaced**;
      - 1,148 RGBA8;
      - 718 4-bit, 129 1-bit and 14 2-bit indexed;
      - 82 RGB8.
    - Up to **512 x 512**, 339 KB of PNG, 820 KB inflated, 42 IDAT chunks. Every one
      decodes in the fabric PNG decoder identically to libpng
      (`bench/umd/run_png.sh --sweep`, `docs/png_decode.md` §1).
    - **And 51 JPEGs** (JFIF) in 21 RCO files, e.g. Hellboy, Spider-Man 2, Toy Story and
      Transporter 2, ~2 MB. All are baseline (SOF0): 30 at 4:4:4, 21 at 4:2:0, the
      largest 512x341. The first survey's "no GIM textures" holds, but "plain PNGs" does
      not. **Host A (fabric) therefore also needs a baseline JPEG decoder**, or those
      images come from host B. It is an open item for M0 (§7).
- **Sound**: 2-4 **VAG** (PSX/PSP ADPCM) effects in some main-menu RCOs.
- **Files and languages**: `EN000001` (the startup chain: legal / FBI / title cards,
  then `PlayMain`), `EN100000` (the main menu), `EN0000nn` / `EN00nnnn` (sub-pages). Prefixes
  `EN`, `FR` (The Matrix), and `ES` in the first survey. **How the PSP chooses the first
  RCO, and the language, is unknown**: that is M0's first question.
- The first survey (`git show 4fa2354:docs/umd_video_format.md`) also noted names such as
  `onInit_pageLegal`, `SCENESEL_SEL`, `SNEAKPEEKS_PLAY`, `EASTEREGG_SEL`,
  `g_nCurrAudID`, `g_nResumePossible`, and clips that are menu transitions.
  **Menus drive playback**: motion menus loop clips, and transitions are clips.

## 2. Oracles, ranked

None of these is enough alone. Each has a separate job (CLAUDE.md "independent oracle"):

1. **A real PSP: the ground truth.** The UMD Video player is part of the PSP firmware.
   Custom firmware (ARK-4: `/ISO/VIDEO/`) plays **the same ISO files** this core loads, so
   captures compare like for like. The maintainer has one. It answers what each page
   looks like, focus and animation timing, the startup chain, language choice, and what
   every button does. Limits: manual, slow, and it cannot show internal state. M1 defines
   a capture protocol (a button script plus a video grab).
2. **JPCSP: the only open implementation of the player API.** `jpcsp.format.rco`
   (`anim/`, `object/`, `sound/`, `vsmx/interpreter/VSMXInterpreter`, `vsmx/objects/
   {MoviePlayer, Controller, Resource, GlobalVariables, Timer, Math}`) and
   `jpcsp.GUI.UmdVideoPlayer`. It runs, so an instrumented build can dump a VM and API-call
   trace for differential testing. It is a **reconstruction**: the authors call it a
   draft, and its issue tracker shows `EmptyStackException`s from the interpreter on some
   discs (jpcsp#445). It never outranks the PSP.
3. **rcomage: the decompiler.** VSMX to readable JS; RCO trees and animation tables to
   XML. For reading intent, measuring the API (M0), and triage. It does not execute.
4. **PPSSPP: not a menu oracle.** It is HLE, does not run the firmware, and has no UMD
   Video player. Its documentation says to use a real PSP. The open request for it
   (ppsspp#21027, 2025) proposes porting JPCSP's. It stays useful where it already is:
   PSMF / `sceMpeg` / ATRAC3plus behaviour (P6).

**Scoring runs on two independent axes:** pixels and timing against PSP captures, and the
VM / API trace against JPCSP. A disagreement between them is triaged with the rcomage
decompile before either side is "fixed".

## 3. The decision: one engine, two hosts, one fabric contract

The menu engine is written **once, in portable C**:
- the RCO loader
- the VSMX VM (values, objects, strings, functions, a collector)
- the scene graph and animation engine
- the player-API shim (§4 item 3)
- a software renderer into the menu plane
- VAG decode

It builds for three hosts:

| host | where | role |
|---|---|---|
| **A, fabric** | a RISC-V soft CPU in `emu` | keeps the self-contained `.rbf`; costs the whole post-P7 margin (§5) |
| **B, HPS** | a `support/umd/` module in **the project's Main fork** (`main/`; amended 2026-09-30, was upstream Main_MiSTer) | costs almost no fabric; **the host P9 ships on** (decided 2026-09-30: host A is out by arithmetic at 98 %). **Under the stock-Main rule** (`area_plan.md` §8 A5) it also hosts P6c (A6) and, when P9 needs the room, the subtitle decode (A7); playing a disc never depends on it |
| **C, PC** | the same C built natively | the golden model and the development loop: frames to PNG, traces to text |

Main_MiSTer carries per-core support code for 24 cores (`support/psx`, `n64`, `x86`,
`saturn`, `megacd`, ...). The 2026-09-25 plan put host B there, in stock Main. **Amended
2026-09-30 (the maintainer): upstream is not asked; host B lives in the project's own Main
fork** (`main/`, beside the HIL Main's `support/umd/umd_ctl.cpp`), shipped with the core.
Users who want the menus run the project's Main instead of stock Main, and the fork follows
upstream Main's releases. **Rejected: an opt-in HPS daemon.** It works, but
users would have to install it, which breaks the no-daemon principle (`roadmap.md`, amended
2026-09-25 to allow Main support code and nothing else; 2026-09-30: the project's Main fork).

None of the engine work is lost whichever host ships: host C is needed for testing
either way, and A and B differ only in their I/O layer.

## 4. The fabric contract (built once, used by both hosts)

1. **Overlay planes in DDR3.** Premultiplied ARGB8888 with geometry registers (source
   W x H, DDA steps, position) and a double buffer flipped at vblank. The menu plane is native
   **480x272** (522 KB a buffer; the PSP composites at that size). It scales to the 720x480
   raster: exactly 1.5x across, 1.7647x down by DDA. Premultiplied, so the blend is
   `out = src + (1 - a) * dst`: three multipliers. Premultiplied is also what makes the
   scaler's filter correct at soft edges: interpolating straight (non-premultiplied)
   ARGB drags the colour of transparent pixels into the edge and leaves dark fringes.

   **Scaling filter (decided 2026-09-25): bilinear, in both axes.** On the PSP the menu
   art was shown 1:1 and the video was scaled *down* to 480x272. This core shows the
   video at its full 720x480 and scales the menus *up*, by factors that are not whole
   numbers. Nearest-neighbour at 1.5x shows alternate columns once and twice; at
   1.7647x, rows once and twice in an irregular pattern. The result is uneven strokes in
   thin lines and text, the kind of detail menu art is made of. Bilinear is uniformly
   soft instead, which is roughly what ascal does to the whole picture after us anyway.
   Cost per plane: two source lines buffered (2 x 480 x 32 bit, inside the M10K estimate
   below) and separable interpolation, 8 more 9-bit multipliers (four channels, two
   axes). **Built (2026-09-26, `compositor.md`):** one dot a clock needs all four
   neighbours in one read, and a source can be 720 wide, so the line buffers are four
   banks of 2 x 512 x 32 bits. The measured cost is in `compositor.md` §7. A plane at 1:1 (the subtitle plane; a menu plane that host B pre-renders at
   720x480) has fractional weights of zero and passes through unchanged. The filter must
   show that as a bench arm.
   Host B may instead render at 720x480 with a better resampler (the geometry registers
   allow any source size), which moves the filtering into software and leaves the
   compositor 1:1. **Taken (2026-09-30, A10):** the menu plane is the 1:1 subtitle plane, taken over
   by the HPS while a menu is up (`hps_host.md` §3.4); the scaling is the renderer's. **Revisited (M4h, 2026-10-08,
   `p9.md` §3.3 "M4h"):** the renderer now draws the scene at 480x272 again -- the canvas this item first
   planned -- and stretches what changed onto the 720x480 plane on the A9 (2.2x faster on The Rock's menu); the
   PSP's TV out was measured to keep the video at 720x480 under a menu, as this core's planes do. The stretch in
   fabric (`plane_reader`'s `SCALE` 1, above) stays a measured-later candidate.
2. **The plane compositor**, in the display path. It fetches one line per plane on ram2
   through `ddr_arb`, with the video display reader first. Layer order: video → subtitle
   plane → menu plane → diagnostic HUD → OSD (OSD is `sys/`). It replaces the direct mux
   at `emu.sv`'s output (`vga_r_q <= ...`). **Estimate** ~700-1,000 ALM, ~4-6 M10K,
   4-8 DSP per plane (the blend plus the bilinear filter, item 1). **Built standalone
   (2026-09-26):** `umd/plane_reader.sv`, `plane_blend.sv`, `rd_merge2.sv`; measured in
   `compositor.md` §7. The ram2 line budget with the video and two plane rows is
   `compositor.md` §5; the menu plane is a third reader, to be measured there.
   Bandwidth is trivial (480x272x4 at 60 Hz ≈ 31 MB/s); occupancy is what
   `hw_budget_and_lessons.md` §2 says to watch.
3. **The player control block**:
   - commands: play playlist / mark / time, stop, pause, resume, audio and subtitle stream select
   - status: state, playlist, chapter, time
   - an event FIFO: playlist end, chapter change, mark reached

   Fabric host: MMIO. HPS host: `hps_io` UIO commands / `EXT_BUS`, the path other
   `support/` modules use. **Estimate** ~200-400 ALM.
4. **Sound effects**: a one-shot PCM buffer in DDR3 plus a trigger, mixed beside the
   ATRAC3plus output. VAG decode runs in software on either host. ~200 ALM.
5. **Input**: fabric host: the joystick bits to the CPU. HPS host: Main already owns
   the gamepad.
6. **RCO access**: fabric host: `umd_reader` lists `RESOURCE/` (it walks `UMD_VIDEO/`
   already) and serves sectors to the CPU. HPS host: Main reads the mounted image itself.
7. **Persistence** (`setUserData`, resume info): a small save through an `hps_io` save
   slot (fabric) or a file (HPS). It ties in with P8's per-disc resume.

## 5. The two hosts in detail

### Host A: fabric

- **CPU**: VexRiscv-class RV32IM with soft float (VSMX has float constants; animation
  arithmetic runs at menu rates, not pixel rates). ~1.5-2.5K ALM.
- **Firmware**: loaded by `ioctl` as the core's `boot.rom` during development; baked into
  M10K (`.mif`) for release, so the `.rbf` stays self-contained. Code either sits in M10K
  (~64 M10K for 64 KB) or runs from DDR3 behind 8 KB I$ + 8 KB D$ (~16 M10K).
- **Memory**: the heap and decoded textures live in DDR3. That is plenty: the DPB uses 20 MB of
  the 512 MB window.
- **PNG decode reuses P7's `inflate` + `png_unfilter`**, extended to every colour type
  (§1: 1/2/4/8-bit indexed, RGB, RGBA) and to writing RGBA into DDR3. The CPU commands
  the decoder; it never inflates in software.
- **Rendering**: the CPU draws dirty rectangles into the plane first. If a measured *(Built as P9 M4d, 2026-10-04: a draw list compared frame to frame; `docs/p9.md` §3.3 "M4d".)*
  full-screen fade misses 60 fps (estimated ~2M cycles a frame in software), add a
  **blitter**: texture → plane, colour multiply, nearest scale, ~1 px / cycle,
  ~1-1.5K ALM. Measure before building it.
- **Total beside the contract: ~2.5-4K ALM, 20-70 M10K.** The roadmap leaves ~4.4K ALM
  after P7 (≤ 37.5K of 41,910), so host A is feasible only if P7 lands at or under
  budget, and it would put the core in the 88-93 % fit-rescue regime (`hw_budget_and_lessons.md`).

**Rejected (fabric):**
- **VSMX executed directly in hardware.** Dynamic typing, property lookup and garbage
  collection are software problems; a hardware VM would be larger than a CPU and far
  harder to verify.
- **A scanline sprite engine with no framebuffer.** With many large, overlapping RGBA
  layers its worst-case line time is unbounded. The plane decouples rendering from raster
  timing, and a slow frame shows late instead of tearing.

### Host B: HPS

- The same C engine inside Main's loop, called when the UMD core is loaded.
- It writes the plane through Main's `shmem_map()` (an uncached `/dev/mem` mapping of the
  FPGA DDR3 window). No fabric port is involved. Software rendering at 480x272 is trivial
  on the Cortex-A9.
- Fabric cost is the contract only: **~1.1-1.6K ALM** (the compositor with its bilinear filter, the control block, the PCM one-shot).
- Costs outside fabric: the project's Main fork kept in step with upstream Main's releases,
  and an install step (the project's Main in place of stock Main) for users who want menus.

## 6. What this requires of P6 and P7 now

- **P6**: transport and navigation (pause, seek, chapters, audio track) are built as
  commands on the **player control block** (§4 item 3), with the menu API (§1) as its
  contract. The HUD transport is then its first client, and the menu engine a second.
- **P7**: subtitles decode into a **DDR3 plane** read by the generic plane compositor, not
  straight into a private line buffer. The menu plane is then a second instance of the
  same unit, and P7's `png_unfilter` is written with the other colour types in mind.
- **ram2**: `ddr_arb` goes onto ram2 with whichever of P6's audio or P7's subtitles comes
  first (`architecture.md` "Memory ports"). The plane reader and a CPU are later clients.

## 7. Milestones (Phase 9)

- **M0 census** (Python, read-only): `tools/rco_census.py` over all 33 discs.
  - the RCO object tree
  - VSMX decode with an opcode histogram
  - API identifiers per disc
  - PNG types and sizes, animation and timer use, VAG counts. **Started** (2026-09-26):
    `tools/rco_png.py` cuts every image out of every RCO's image region (6,150 PNGs,
    51 JPEGs, nothing unaccounted: §1). Still open: where each image is used, and
    whether the JPEGs are on screen in a menu a player reaches, which decides whether
    host A needs a JPEG decoder.
  - the startup chain

  It also answers which RCO runs first and how language is chosen: from the scripts,
  JPCSP and the PSP. Its maxima become `spec_hardening.md` rows.
- **M1 the engine on the PC** (host C). VM + scene graph + renderer, producing frames and an API
  trace. Scored against PSP captures and an instrumented JPCSP, disc by disc, with RED
  arms per `bench/umd/README.md`.
- **M2 the fabric contract**: plane compositor, control block, PCM one-shot, `ddr_arb`.
  Benched pixel-exact against a Python model. It lands inside P6/P7 where possible (§6).
- **M3 host B first**: rig iteration without refits, and it proves the contract on
  hardware.
- **M4 host A**: the soft CPU running the same C, once the P7 fit is known. Then decide which
  host ships.

## 8. Spec-maximum rule

VM limits (operand stack, call depth, heap, string length, objects, textures, timers, the
event FIFO) are sized from the VSMX / RCO field widths, or live in DDR3 where they are
effectively unbounded. A bound that is hit is **refused loudly**: an on-screen flag plus a
counter, never a silent stop. M0 measures the maxima; any decided deviation goes in
`spec_hardening.md` "Known deviations".

## 9. Open questions

- The startup RCO and the language choice (M0).
- How the 480x272 plane maps onto a 4:3 or anamorphic 16:9 output. The PSP's screen is
  16:9 square-pixel (480/272 = 1.765 against 1.778), and a 16:9 disc's anamorphic
  720x480 frame is also 16:9, so on those discs the plane can cover the whole frame
  without distortion. The open case is a 4:3 disc, presumably pillarboxed on the PSP:
  are its menus drawn across the full 16:9 screen, around the bars?
- Whether upscaled menu art looks acceptable. The PSP never showed its menus over a
  full-resolution video, so there is nothing to copy exactly: the art at 1.5x / 1.76x
  (bilinear, §4 item 1) will look softer than the video under it. Photos of the same
  page on the PSP and on this core's output settle whether the softness is acceptable,
  or whether host B's pre-rendered 720x480 path (a better resampler) is needed.
  Nearest-neighbour is rejected for the uneven rows and columns it produces at these
  factors (§4 item 1); keep it only as a debug view.
- Whether menu transitions need seamless playlist switching (no black gap), which would
  bind P8's item-to-item handoff.
- Whether any disc's scripts use features beyond those in §1 (`prototype` appears on some
  discs, which implies user-defined objects).
- ~~Upstream appetite for a `support/umd` module in Main_MiSTer.~~ Not asked: host B lives in the
  project's Main fork (the maintainer, 2026-09-30).
