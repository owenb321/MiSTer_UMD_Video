# Host B: the HPS side of the core (the UMD Main)

> **A12 (2026-10-07, `nav_engine.md` §11): the subtitle decode is back in the fabric** (E1 / E2, the
> maintainer): `umd_host`'s request is tied off, so the UMD Main never decodes (its `umd_sub` stays, unused
> with this core); HOST_RD appends words 39-43 (the shown unit's plane and rectangle) for the panel's
> compositor. The host port, the menus and the panel below are otherwise as built.

**Status: 📐 planned 2026-09-30, ✅ MERGED (PR fj#31), **B1 ✅ MERGED (PR fj#32)** (the decoder, on the PC: §3.3, §6), **B2 ✅ MERGED (PR fj#33)** (§6 "B2, the results": the budget missed at 68 ms, then met at 31 ms by the maintainer's option 1, a palette fast path in `umd_sub`), **B3 ✅ MERGED (PR fj#34)** (§6 "B3, as built"), **B4 ✅ MERGED (PR fj#35), subtitles end to end on the rig, 5 of 5 seeds pass (SEED 11 pinned)** (§6 "B4, as built"), **B5 ✅ MERGED (PR fj#36)** (§1 "Packaging": one zip, the core and the UMD Main from one commit); decisions H1-H8 ✅ TAKEN by the
maintainer the same day, then revised in a second round (§7: no HPS-drawn screen during
playback, so one plane again; P6c cut to Go To, which goes to the fabric if A7 frees the room).** This note is the plan that `area_plan.md` §8 "Next concrete step"
asked for.

**The order of work was changed by the maintainer (2026-09-30; `area_plan.md` §8 A10):**
- **Area comes before more decoder work.** At 98 % ALM every netlist change re-rolls the
  seed lottery (`area_plan.md` §7).
- **A7 is taken now.** The subtitle decode moves to the HPS first, ahead of P6c and ahead of
  A9's retime harvest.
- **Nothing is drawn by the HPS during playback except subtitles** (the second round, §7).
  P6c is cut to Go To, which is proposed for the fabric's transport HUD (§4). The only other
  HPS-drawn screens are P9's menus, and subtitles do not play during a menu. **So one plane
  does both** (§3.4): the HPS writes subtitles into it on the fabric's clock, and takes it over
  while a menu is up.

What this note fixes:
- what the project's Main fork becomes, and how users install it (§1);
- the fabric's one door to it, the host port (§2);
- the subtitle handoff (§3);
- P6c, cut to Go To, and where Go To goes (§4);
- what a stock-Main user sees (§5);
- the stages and their gates (§6);
- the decisions it needs (§7).

Behind it:
- `area_plan.md` §8: the stock-Main rule, A5-A10.
- `subtitles.md`: the chain as built.
- `p6c.md` §8-§9: P6c re-scoped, then cut to Go To.
- `menus.md` §3-§5: the one C engine, host B.
- `main/README.md`: the HIL Main this grows from.

---

## 1. The UMD Main: one binary, beside stock Main

> **P9 (2026-10-02):** the port is SHARED with the disc menus (`docs/p9.md` M3 E2, "One port, two
> logics"): one HOST_RD feeds the subtitle logic and the menus'; a HOST_WR carries words 1-4 and,
> once the menu side has adopted, words 5-37. Below describes the subtitle side.

**The headline: installing it leaves the user's stock Main in charge of every other core.**
Main switches binaries per core. At a core load, `user_io.cpp` (~1462) compares
`MiSTer.ini`'s `main=` for that core's section with the running binary, and re-execs the
named one if it differs. The HIL harness installs this way today (`main/README.md`: a
`main=` line in `[UMD]`). A user's install is therefore:

1. copy `MiSTer_UMD` (the binary) to `/media/fat/`;
2. add `main=MiSTer_UMD` to the `[UMD]` section of `MiSTer.ini`.

**What the binary is:**
- stock `Main_MiSTer` at a pinned upstream commit (`MAIN_MISTER_REF` in `main/build_main.sh`);
- plus `support/umd/`, which does nothing unless the running core is UMD (`is_umd()`, as
  today).
- **One binary for users and for the HIL** (H1). The HIL module (`umd_ctl.cpp`: telemetry, the
  command FIFO) stays armed only by `/media/fat/umd_hil`, exactly as now. The host module
  (`umd_host.cpp`, new) is always on under the UMD core.
- Test builds therefore run the binary users run. The HIL Main stops being a separate
  artefact.

**What the fork costs:**
- It must follow upstream Main's releases. Under the UMD core it *is* the user's Main (the
  OSD, the scaler, input, the file browser), so a stale fork shows as stale Main features.
- After leaving the core, the fork can keep running. **Explained by B2 (§6):** Main switches
  binaries at a core load only when the `main=` it resolves for the new core names an
  EXISTING file. A global `main=` pointing at a missing binary (.201's ini) keeps whichever
  Main ran last, until a reboot. With no global `main=` (the default `MiSTer`), stock Main
  comes back. The module is inert outside UMD, so this is harmless as long as the fork is
  current.
- **Packaging (B5, ✅ MERGED PR fj#36, 2026-10-01):** ONE zip, the SD root's mirror.
  - **Contents:** `_Other/UMD_YYYYMMDD.rbf`, `MiSTer_UMD` at the root (executable),
    `MiSTer_UMD.json`, and `UMD_INSTALL.txt` (the two `MiSTer.ini` lines, updating, removing,
    the source pointer).
  - **Provenance:** `main/build_main.sh` writes `MiSTer_UMD.json` (sha256, the commit and a
    dirty flag, Main_MiSTer's ref, the host PROTO). `tools/package_release.sh` refuses a Main
    whose manifest is missing or whose binary differs from it. It also refuses either half
    from a dirty tree, and a Main from a different commit than the `.rbf`'s manifest: the
    same commit is what guarantees the same host PROTO.
  - **The `MiSTer.ini` edit is the user's**, as MiSTer_DVD's was: add the section, never
    replace the file, create the file if there is none. No script edits a user's ini.
  - **GPL:** the binary is a Main_MiSTer derivative. `NOTICE` and `UMD_INSTALL.txt` name its
    corresponding source (Main_MiSTer at `MAIN_MISTER_REF` plus this repository's `main/` at
    the manifest's commit).
  - **Elsewhere:** the `release` skill builds, smoke-tests and attaches the Main;
    `.github/workflows/package.yml` (the GitHub arm) downloads and passes it.
  - **Tested (2026-10-01):**
    - The Main built at d433a75 has the same sha256 as the binary B4 ran on the rig: the
      build is reproducible.
    - Paired with the SEED 11 `.rbf` (commit d3087fb), the packager refused: "different
      commits".
    - With a scratch copy relabelled to the Main's commit, it packed four entries:
      `MiSTer_UMD` (mode 755, 1,080,204 B), `MiSTer_UMD.json`, `UMD_INSTALL.txt`,
      `_Other/UMD_20261001.rbf`. 2.87 MB zipped.
    - The real pair is built at the release commit by the `release` skill.
  - Downloader / update_all integration is out of scope here: a later packaging question.

**Where each part runs on the HPS:**
- **All EXT_BUS traffic stays on Main's poll thread** (the `user_io_poll` coroutine), as
  stock Main's `mdplus.cpp` does. mdplus is the precedent: it polls its core over EXT_BUS
  every 5 ms and moves data through a `shmem_map` ring.
- **The work that is slow runs on a worker thread of its own**, pinned to CPU 0: the PNG
  decode, and the plane write through an uncached mapping.
  - The poll thread also services the core's sector reads. `umd_ctl.cpp`'s header warns that
    needless work there shows as a video artefact.
  - Main's `offload_add_work` queue (8 entries, shared with the scaler and video) is not
    used. A full queue would block the poll thread.
  - The hand-off is one single-producer / single-consumer slot each way.
- **DDR3 from the HPS.** The core's word address W is HPS physical byte address `W * 8`
  (`fpga_mem()`, `shmem.h`; mdplus: `0x0600_0000 << 3 = 0x3000_0000`):

  | region | core words | HPS physical | size |
  |---|---|---|---|
  | the subtitle ring | `0x0640_0000` + 2^20 | `0x3200_0000` | 8 MB |
  | plane 0 | `0x0650_0000` | `0x3280_0000` | 1,382,400 B used (720 x 480 x 4) |
  | plane 1 | `0x0658_0000` | `0x32C0_0000` | the same |
  | the PCM region *(P9)* | `0x0660_0000` + 2^20 | `0x3300_0000` | 8 MB: the menus' sounds, 16-bit PCM at 48 kHz (`umd/pcm_shot.sv`) |
  | plane 2 *(P6d)* | `0x0670_0000` | `0x3380_0000` | the control panel's pages (`docs/panel.md` §2), 720 x 480 x 4 |
  | plane 3 *(P6d)* | `0x0678_0000` | `0x33C0_0000` | the same |

  `shmem_map` opens `/dev/mem` with `O_SYNC`, so the mapping is uncached. The ring is read
  and the plane written through it with no cache maintenance. **Before a completion is sent,
  a store barrier (`__sync_synchronize()`, a `dmb`) drains the write buffer**, so the fabric
  never shows a plane whose last row is still in flight.

## 2. The host port: the fabric's one door (`umd/umd_host.sv`)

Every HPS feature talks to the core through one responder on hps_io's EXT_BUS, beside
`umd_telem`. **It is deliberately not the telemetry channel.** Telemetry is instrumentation
(A8), and if it is ever made a build option, host features must not go with it.

**Two new UIO commands** (H3):
- `0x7B` HOST_RD: the core's status to the host;
- `0x7C` HOST_WR: the host's words to the core.

Both are free in `user_io.h` at `MAIN_MISTER_REF` (used: 0x00-0x44, 0x61-0x63, 0xF0-0xF9;
the telemetry takes 0x7A). They are re-checked on any Main bump, as 0x7A is. The EXT_BUS
rules are `umd_telem.sv`'s: the responder drives the bus only for its own commands, and word
0 is a MAGIC.

**The word layout is generated from one table.** `tools/host_layout.py` generates
`umd/umd_host_words.svh` and `main/support/umd/umd_host_proto.h`, as `telem_layout.py` does
for telemetry. A PROTO version sits in word 1.

**HOST_RD (core → host)**, one transaction per poll:

| field | what |
|---|---|
| MAGIC, {PROTO, NWORDS} | as telemetry |
| `gen` | a counter bumped by every mount and every flush of the subtitle side. The host drops work whose `gen` is stale |
| player *(P9)* | `state`, `chapter`, `n_chapters`, the shown key {item u32, PTS 33}, `seeking`, `tk_speed` |
| subtitle request | {valid, seq u8, buf, x, y, ring start (word, 20 bits), length u32}: the unit to decode and the plane to write it into (§3) |
| subtitle state | the shown seq, visible (so the host knows what is on screen) |
| host events *(P9)* | a count, then up to 4 {code, data} from the host's own event FIFO (§4) |
| `ui` acknowledgement *(P9)* | the host's last plane flip, latched (§3.4) |

**HOST_WR (host → core):**

| field | what |
|---|---|
| {PROTO, host version} | **the heartbeat**: a HOST_WR whose PROTO matches sets `host_ok` for ~1 s (a 25-bit counter on clk_sys). A mismatched PROTO sets `host_bad` instead (§5) |
| subtitle completion | {valid, seq, err u5, w, h}: the plane holds unit `seq`'s image (§3) |
| player command *(P9)* | {valid, code, arg, item u32, PTS 48}: into `player_ctl`'s existing command port. It is muxed with `emu`'s button commands, buttons first, one per cycle |
| grab *(P9)* | a mask of the buttons forwarded to the host instead of acted on (§4) |
| `ui` and the host flip *(P9)* | `ui`: the host owns the plane; {valid, buf, visible, x, y, w, h}: a flip latched at the next vblank (§3.4) |
| event pops *(P9)* | how many host events were read |

**B3 builds only the subtitle rows** (MAGIC / PROTO, `gen`, the request and state, the
heartbeat, the completion). The rows marked *(P9)* are reserved in `tools/host_layout.py`'s
table and built with the menus, the first feature that needs them.

**P9's rows, as built (2026-10-01, `feature/p9-menus`; `docs/p9.md` §3.2 items 2-5).** APPENDED to
both tables, so B4's transactions (HOST_RD's first 13 words, HOST_WR's first 4) mean what they
meant: PROTO stays 1 and HOST_RD's NWORDS (38) is the capability -- a UMD Main that finds 13 runs
without menus. HOST_WR is 25 words. **The poll's cost:** B4's Main now reads all 38 words a HOST_RD
(25 more `spi_w` than B2 measured its poll thread with); unmeasured on the rig -- to measure with M3
(a menu needs the rows only while one is up; the Main can read the first 13 otherwise).
- **HOST_RD adds** the player (`player_ctl`'s state, seeking, trick speed, the subtitle and audio
  tracks, chapter / n_chapters, the playlist playing and its items, the shown picture's item and
  PTS), the echoes, and the event FIFO's window. All latched at the command strobe with the rest.
- **ONCE-ONLY.** HOST_WR is sent every poll (it is the heartbeat), so a player command, a flip and
  a PCM trigger each carry a **seq** in their first word and are taken at their last word only
  when the seq differs from the last one taken (and the transaction's PROTO matched). The core
  HOLDS a taken record until its consumer takes it (`player_ctl`, the plane's vblank, the
  one-shot) and only then echoes the seq in HOST_RD (`acks`, `pcm_ack`); the host sends the next
  after the echo. A new seq sent while one is held is not seen. At start the host adopts the
  echoed seqs.
- **The player command** goes into `player_ctl`'s command port in a cycle with no button command
  (buttons first). P9 adds two codes there: 13 PLAYLIST (a menu's `play`: the reader's
  `NAV_PLAY`, refused as BAD for a playlist that does not exist or with a gesture or seek in
  flight -- the host retries) and 14 SUB_SET (the subtitles set outright). Refusals post BAD
  events, which the host reads.
- **The levels** `grab` (the buttons the host takes, joystick bit order), `ui` (the plane is the
  host's) and `menu` (the transport HUD hidden, a stop black) hold their last value and are
  **cleared the cycle the heartbeat times out** -- a UMD Main that dies cannot leave the core deaf,
  the HUD hidden or a page up -- and not restored when it returns.
- **The event FIFO** (8 deep, in `umd_host`): `player_ctl`'s events, teed (the HUD still pops them),
  and the grabbed buttons' presses as code 15 KEY (data: the press mask). A key meeting an event
  in one cycle waits one (a one-deep skid; further presses merge into it). Nothing is pushed
  without the heartbeat; a push into a full FIFO is counted (`ev_w[15:8]`), never silent. **Read
  by count**: HOST_RD gives the write and read counts (mod 256) and the first four unread
  entries; HOST_WR's `ev_rp` is the count the host has consumed up to and the core pops to it --
  a repeated or lost write is harmless.
- **A command with no title mounted** is taken and echoed by `umd_host` and dropped by
  `player_ctl` (its commands need a title; no event, as for a button): the host reads `play`'s
  state 0 (idle) and sends no playback command before a mount.
- `pcm_under` (HOST_RD's last word): the one-shot's ticks that played silence for a late word.
- **The video window** (P9 item 6, `p9.md` §3.2): HOST_WR's last 13 words, a LEVEL written in place
  (the seq only echoes, in `pcm_ack[7:0]`); `disp_reader` never latches it during a HOST_WR
  (`win_hold`). The host computes the Q10.16 steps and starts and clips the rectangle to
  720 x 480 (the 854 x 480 movie space mapped first); a rectangle the fabric refuses shows nothing
  and sets HOST_RD status bit 10.
- `run_umd_host.sh --red`: arms `[rows] [cmd] [levels] [events] [flip] [pcm]`, H7-H17.

**P6d's rows (2026-10-04, `docs/panel.md` §3.2 F1 / F2 / F5), APPENDED, PROTO stays 1:** HOST_RD 38 -> 39
words, HOST_WR 38 -> 40.
- **HOST_WR:**
  - `press` / `press_mask` (words 38 / 39): a press record. It is taken once by its seq at the mask
    word, as a one-cycle pulse that `emu` ORs into the transport's presses and Go To's open after the
    grab. It is echoed at once in HOST_RD's `press_ack` (word 38). Unlike the other records it is never
    held: nothing downstream can refuse or delay a press.
  - `ctl[12]`: `ui_sub`, the panel's mode, a level cleared with the others when the heartbeat stops.
  - `flip[2:1]`: the plane, 0 / 1 the subtitles', 2 / 3 the panel's.
- **HOST_RD:** `status[9]` Go To's editor open, `[8]` the title has a subtitle track, `[7]` `ui_sub` in
  force.
- **The UMD Main's `nwords_ok` now needs 39 words:** the Main and the core ship from one commit (B5).
- `run_umd_host.sh --red`: arms `[press] [panel]`, H25-H31.

**Clocks.**
- The port is on clk_sys (hps_io's clock), with `player_ctl`.
- The subtitle request and completion cross to mclk (`sub_sched`) through the toggle
  handshakes already used for `sub_flip` and `cdc_snap`.
- Each is a record held until it is acknowledged, so nothing is torn.

**Cost, estimated:** for B3's subtitle rows, 100-200 ALM raw (the status word mux, the
completion register, the heartbeat, two crossings); calibrated as `p6c.md` §2 calibrates
spec-width state, **150-400**. P9's rows (the event FIFO, the command mux, the grab, `ui`)
add ~150-300 raw when they come.

## 3. The subtitle handoff (A7)

### 3.1 What moves, what stays

| block | today | after |
|---|---|---|
| `sub_in`, `sub_unit` | demux bytes → units, clk_sys | **stays** (the demux cannot be stalled) |
| `sub_ring` writer, the unit queue | the ring in DDR3, admission, the record FIFO | **stays** |
| `sub_ring` reader | streams a unit to `png_top`; frees its words as it reads | **goes**: the HPS reads the ring itself. The tail advances at the unit's **completion** (§3.2) |
| `sub_png` (`png_top` + FIFOs) | the decode | **goes** to the HPS (C, §3.3) |
| `sub_plane_wr` | premultiply, clip, write-combine into the plane | **goes** to the HPS |
| `sub_mem` | three clients: ring writer > ring reader > plane writer | **one client**, the ring writer. It is kept as the register stage in front of `ddr_mux2` (its output register fixed mclk, `area_plan.md` §6) |
| `sub_sched` | STC timing, the planes, flip / hide | **stays**. Its `wr_*` / `e_*` handshake goes to the host port instead of the plane writer |
| the compositor (`sub_flip`, `plane_reader`, `plane_blend`, `rd_merge2`, `ddr_mux2`) | reads the plane at 1:1 | **stays** unchanged |

**Area freed, estimated** (the P7 fit's per-entity numbers, `area_plan.md` §8):

| | ALM | M10K | DSP |
|---|---|---|---|
| `sub_png` | -2,225 | -47 | -- |
| `sub_plane_wr` | -209 | -2 | -3 (the premultiply) |
| the ring reader, `sub_mem`'s two lost clients | -150 to -300 | -2 (the read-data FIFO) | -- |
| the host port (§2) | +250 to +600 | +1 | -- |
| **net** | **~-2.0K to -2.6K** | **~-50** | **-3** |

These are estimates until the fit (B4).

### 3.2 The protocol

`sub_sched` is unchanged in what it decides: decode when the back plane is free and a unit is
queued; flip at the PTS; hide at PTS + duration; count late / missed / refused. Only its
decode partner changes.

1. **Request.** At `q_take`, the fabric latches the head record as the request: {seq, buf =
   the back plane, x, y, ring start, length}. `seq` counts requests, mod 256. The request
   stays up in HOST_RD until its completion or a flush.
2. **The host decodes it** on its worker thread:
   - it reads `length` bytes from the ring at `0x3200_0000 + start * 8`, wrapping at the
     ring's end (units wrap: `run_sub.sh`'s "a burst crossing the ring's end" arm);
   - it decodes the PNG (§3.3);
   - it writes the premultiplied, clipped rectangle into plane `buf`;
   - it issues the store barrier.
3. **Completion.** The poll thread sends {seq, err, w, h} in HOST_WR. The fabric takes it
   only if `seq` matches the outstanding request, and ignores it otherwise, counted as
   `n_stale`. It then:
   - frees the unit's ring words (the tail advances);
   - hands `sub_sched` its `e_valid` / `e_err` / `e_w` / `e_h`, as the plane writer did.
4. **Flush** (a seek, a track change, a mount). Exactly as today: the ring and the queue are
   emptied and the plane is hidden. In addition, `gen` is bumped and the outstanding request
   is dropped.
   - The host finishes whatever it was writing (at most one image) and sends its completion,
     which the fabric ignores.
   - **The host serves requests strictly one at a time, in order.** A later request's
     pixels therefore always land after an abandoned one's, and the fabric shows a plane only
     on the completion of the request that wrote it last. A stale write can land only in the
     back plane, and only before the completion that makes that plane visible.

**One completion per HOST_WR** (B3, `umd_host.sv`): the completion crosses to the DDR3 clock as
a toggle in a `cdc_snap` record, so two inside one snap round (~10 clk_mem cycles) would cancel.
The host sends at most one completion per transaction; B2 measured the poll at >= 36 µs, far
longer than a round. A host that batched completions would lose both.

**Why the tail moves at completion, not at the request.** The HPS is still reading the unit
until it completes. Freeing its words at the request would let the demux overwrite bytes the
host has not yet read. It stays safe across a flush: the flush resets the ring, and a
decode of overwritten bytes can only produce a completion that is ignored.

**The time budget.** A unit is in the ring 0.57-1.0 s before its PTS, and consecutive PTS are
at least 0.1 s apart (`subtitles.md` §1, The Mummy's 0x8B). The request is posted when the
previous plane's flip is acknowledged, so poll + decode + write must fit well under 0.1 s.

What needs measuring (B2):
- the poll period;
- the uncached write rate into the window;
- libpng's decode rate on the A9 (the largest measured unit is 7,214 B, a 638 x 441
  rectangle is 1.1 MB of plane).

If the budget does not hold, the late / missed counters show it, as they do today for the
spec-maximum case.

### 3.3 The decoder on the HPS: portable C, bit-exact to libpng (B1 ✅ built 2026-09-30)

**As built:** `main/support/umd/umd_sub.cpp` / `umd_sub.h` (plain C that also compiles as C++:
Main's Makefile globs only `support/*/*.cpp`), with libpng 1.6.37's headers in
`main/support/umd/libpng/` (copied into the Main tree by `main/build_main.sh`). It is not
called by anything yet: B4 wires it into the host module. Main's ARM cross-build compiles and
links it with no warnings (2026-09-30).

- **The PNG decode is libpng itself** (H4, decided 2026-09-30).
  - **Every MiSTer already has it.** Main is dynamically linked against `libpng16.so.16`
    (`readelf -d` on the built Main: a NEEDED library, through Imlib2), and every call the
    decoder makes is exported by it (`nm -D`). Nothing is added to the user's system.
  - **The device's libpng is 1.6.37** (April 2019), **measured by B2** (`b2 libpng`, §6): Main
    LINKS against its tree's `lib/imlib2/libpng16.so` (1.6.28 at `MAIN_MISTER_REF`, which B1
    first took for the device's), but the soname `libpng16.so.16` resolves at run time to the
    Linux image's `/usr/lib/libpng16.so.16.37.0`: the same file on a 2022 image and a 2026 one.
    This PC's is 1.6.58. `main/` vendors **1.6.37's** headers (`png.h`, `pngconf.h`,
    `scripts/pnglibconf.h.prebuilt`, its `LICENSE`; `NOTICE`), and B1 runs every case against
    both versions (§6; `run_hps_sub.sh`'s `DEV_VER`). They differ on one synthetic case: a bad
    IEND CRC, which 1.6.58 only warns about and **1.6.37 refuses (as 1.6.28 did), as the fabric
    decoder did** (`png_golden.py` `crc_iend`, `stricter=True`). On the device the HPS keeps the
    fabric's verdict.
  - **A palette image takes a fast path** (B2, option 1, 2026-09-30; every subtitle unit of the
    library is 4-bit palette):
    - libpng hands over the indices (`png_set_packing`), and a 256-entry table maps each
      to its premultiplied word.
    - The table entry is built from the PLTE entry (zero past the PLTE) and the tRNS alpha
      (255 past the tRNS).
    - This is the general path's pixel by construction, and `run_hps_sub.sh` holds it to the
      oracle's libpng expansion.
    - On the A9 it is ~2.4x faster.
    - The plane is written from a line buffer: contiguous pixels as 64-bit pairs, Adam7's
      spaced pixels one 32-bit store each. `plane` must be 8-byte aligned.
  - **The transforms are `tools/png_oracle.c`'s** (every other image), the oracle that scored the fabric decoder:
    `png_set_benign_errors`, `png_set_expand`, `png_set_expand_16`, `png_set_gray_to_rgb`, the
    filler alpha. The 8-bit value is the 16-bit sample's high byte, as the fabric's `png_pixel`
    takes it.
  - **Adam7 is placed by `umd_sub`, not by `png_set_interlace_handling`.** libpng's handling
    needs the whole image in memory; without it, libpng hands over each pass's reduced rows
    (skipping an empty pass, as the loop does), and memory is one row for any height.
  - **The size bounds** (`umd_sub.h`): height up to the PNG maximum, 2^31-1 (rows stream, so a
    tall image costs time, which a flush cancels, never memory); **width up to 1,000,000**
    (libpng's default user limit: a row is held whole, ~8 MB at the bound). A deviation from
    the PNG maximum, far looser than the fabric's (row bytes <= 8192): `spec_hardening.md`.
  - **Rejected: our own decoder over miniz's inflate** (Main compiles miniz in). It would
    avoid the headers but mean ~500 lines of new PNG code (chunks, five filters, every
    bit depth, palettes, tRNS, Adam7) to prove bit-exact against libpng.
- **The plane writer**, ported from `sub_plane_wr.sv`, in the same file.
  - Pixel (X, Y) is the little-endian `uint32` at byte `(Y * 720 + X) * 4` of the plane,
    `{A, R', G', B'}` with A in bits 31:24: the RTL's "two pixels a 64-bit word, the even x
    in [31:0]" seen from the ARM. B2 confirms it on the rig.
  - Premultiplied by the RTL's exact formula, `c' = (c*a + 128 + ((c*a + 128) >> 8)) >> 8`.
  - Clipped to 720 x 480, counted (`clipped`, saturating at 2^32-1: at the size bounds an
    image has up to ~2^51 pixels).
  - **One aligned 32-bit store a pixel, through a `volatile` pointer**: `shmem_map`'s mapping
    is uncached (strongly ordered on ARM), where a compiler-merged or unaligned wider store
    would fault. Nothing is cleared: the compositor draws outside the rectangle as
    transparent (`subtitles.md` §2).
  - The whole stream is decoded even past the plane's bottom, so the verdict is libpng's for
    the whole image (the fabric's rule).
- **The ring reader** (`umd_ring_copy`): the unit's bytes in address order from the ring's
  base + start x 8, wrapping at the ring's end, aligned 32-bit loads only.
- **A cancel hook**, polled once a row: a flush (a seek, a track change) stops a long decode
  (`UMD_SUB_CANCELLED`).
- **The same C is P9's PNG path** (`menus.md` §3: one C engine, three hosts). Host C, the
  PC, builds it natively for the tests.
- **Verdicts as libpng gives them.** A refusal is an `err` in the completion; `sub_sched` frees
  the plane and counts `n_refused`, as today.

### 3.4 One plane: subtitles in playback, the host's screens in a menu (H5)

**The maintainer (2026-09-30, second round):** the HPS draws nothing over playing video except
subtitles. Go To goes to the fabric's HUD or is dropped (§4), and the rest of P6c is dropped.
That leaves two users of the plane, and they do not overlap:

| when | the plane holds | written by | shown when |
|---|---|---|---|
| playback | subtitles | the HPS (§3.2) | `sub_sched`, on the STC |
| a disc menu (P9) | the menu page | the HPS | the host's flip, at the next vblank |

(The first round's answer, "subtitles and other elements share the screen, as on the PSP", had
led to a second UI plane, ~350-500 ALM. With no HPS-drawn screen during playback it is not
needed.)

**The hand-over, built with P9:** a `ui` bit in HOST_WR gives the plane to the host.
- While `ui` is set, `sub_sched` issues no requests and no flips. Units stay queued; a unit
  whose end passes while waiting is dropped and counted in `n_ui_skip`. It is kept out of the
  HUD's missed count, so a menu does not read as a fault (P6b3i's pause bug is the
  precedent).
- The host shows and hides its pages with an immediate flip, a second request source into
  `sub_flip`: the same vblank-latched, acknowledged handshake. The host draws into a buffer
  only after the flip away from it is acknowledged.
- **A flush under `ui` does not touch the plane.** Menus start clips while the page stays up,
  and each start reaches the overlay as a flush. While `ui` is set, a flush empties the
  subtitle ring and queue (and bumps `gen`), but it neither hides the plane nor drops a host
  flip in flight. Only the host hides its page, by a flip or by clearing `ui`.
- Clearing `ui` hides the plane, and `sub_sched` resumes with the next unit still in time.

**As built (2026-10-01, P9 M2; `umd/sub/sub_flip.sv`, `emu`):** the plan held but for the units.
While `ui` is set the demux's subtitle output is **off** (as during a subtitle change: `sp_on`),
so no unit is queued -- simpler than queueing and expiring them, and nothing reaches the missed
count. Either edge of `ui` is a subtitle flush (the side starts clean). `sub_flip` still latches
and acknowledges `sub_sched`'s requests under `ui` (it never waits) but does not apply them; the
host's flip is applied at the next vblank with an `hf_ack` pulse; any change of `ui` hides the
plane at the next vblank unless a host flip lands in that same one (no blank frame when a menu
opens with its first page). `bench/umd/sub_flip_tb.sv` in `run_plane.sh --red` (U1-U6).

**To check at P9's census (M0, `menus.md` §7):** that no disc's menu page sits over a clip
with its subtitles on. If one does, the host composites the subtitle under the page itself
(it decoded it), in software, with nothing changed in the fabric.

### 3.5 Considered: the H264 fork's overlay descriptor in DDR3

MiSTer_h264_decoder built an ARM-to-fabric overlay (its `docs/architecture.md`, "The overlay
plane", interface 0.9):
- a Linux program draws into a page;
- it describes the page in DDR3 control words, under a generation pair (`gen_hi` written
  first, `gen_lo` last);
- the core reads that descriptor once a refresh on `ram2`; a flip is a new `base`.

**Not taken as the channel here, for three reasons:**
- **The timing must stay in fabric.** A subtitle is shown at its PTS on the 90 kHz STC. In
  the fork, a flip is the program's and lands at the next refresh after it writes. Here the
  host only fills a plane, and `sub_sched` decides when it shows.
- **The host is inside Main.** The fork's program runs outside Main and has no EXT_BUS, so
  DDR3 is its only channel. Inside Main, EXT_BUS is the native path (mdplus). It costs no
  `ram2` reads, and occupancy is the scarce resource (`hw_budget_and_lessons.md` §2).
- **The planes are premultiplied** (`compositor.md`). The fork's formats are straight alpha.

**What carries over:**
- the discipline: the `seq` check stands in for its generation pair;
- a plane is never written while the core may read it, which here is the acknowledged flip.
- The menu mode (§3.4), whose flips ARE the host's, is close to the fork's model, carried over
  EXT_BUS instead of a DDR3 descriptor.
- If P9's menus ever need their own geometry or format, the fork's descriptor is the model for
  an additive extension.

## 4. P6c: cut to Go To, and Go To to the fabric

**The maintainer (2026-09-30):** A-B / Repeat, slow motion and frame advance are dropped for
now (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**). **P6c is Go To alone**, and the question was whether it can live on the core, beside the
transport HUD it extends (on the PSP it is part of the same overlay: `transport_hud.md` §3). If
not, it is dropped too.

**It can, at a price that A7's fit decides** (G1, §7):
- **What it is in fabric** (`p6c.md` §2.1, the fabric plan, written before the HPS re-scope):
  - the editor: a small state machine in or beside `player_ctl` (the box, the field, a chapter
    number, h / m / s), whose exit is the existing SEEK (command 7);
  - a reader operation `NAV_TIME` (title time to (item, PTS), reusing the seek's item walk);
  - the HUD: two boxes above the bar, the field being edited, ▲ / ▼, the ▼ marker. The time box
    reuses the overlay's `hh:mm:ss` path.
- **Its cost: 500-950 ALM raw, 0.75-1.9K calibrated** (P6b's estimates ran ~2x wherever the
  state was spec-width).
- **What A7 frees: ~2.0-2.6K net, estimated** (§3.1).
- So Go To fits after A7, but it can take most of what A7 frees. P9's fabric side is small
  (the port's *(P9)* rows and a PCM one-shot, a few hundred ALM). 480i (~2K) would then wait
  for another lever.
- **In fabric it works on a stock Main**, as the rest of the transport does (A5). It needs no
  host port.

**Proposed (G1):** build A7 first. At its fit, compare the ALM it actually freed (and the seed
sweep's margin) with Go To's calibrated range, and decide then: Go To in fabric, or dropped.
Until then P6c is parked, and the Go To button stays inert.

**The host port no longer serves P6c.** Its forwarded buttons, `grab`, commands and events are
P9's (the menus need the D-pad and drive playback). They are reserved in the word table and
built with P9 (§2):
- **Buttons are forwarded by the fabric, not tapped in Main.** The J1 bits and `kbd_map`
  already reach `emu`, with their edges and the OSD-open gating. While the host's `grab` mask
  covers a button, `player_ctl` does not act on it, and its press posts a host event instead.
  One path for pad, keyboard, FLIRC and CEC, with no Main input patch, and no press acts twice.
- **The event tap.** `player_ctl`'s event FIFO is popped every cycle by `emu` (`ev_pop` 1'b1)
  for the transport HUD. The host port keeps its own 16-entry FIFO, fed from the same
  `ev_valid` / `ev_code` / `ev_data` beside the forwarded presses. Its overflow is counted.

## 5. What a stock-Main user sees

`host_ok` low means no HOST_WR heartbeat in the last second. That is stock Main, or a UMD
Main that is not running.

| feature | UMD Main | stock Main |
|---|---|---|
| playing a disc: picture, sound, chapters, pause / stop, FF / REW, the audio track, both HUDs | ✅ | ✅ (the stock-Main rule, A5) |
| subtitles | ✅ | the Subtitle button shows a message and stays Off; nothing is written to the ring (`sp_on` needs `sub_on`, which the SUB command no longer sets without `host_ok`) |
| Go To (P6c), if G1 builds it | ✅ (fabric) | ✅ (fabric) |
| the disc menus (P9) | ✅ when built | the core plays the longest playlist, as today |

- **The message.** The transport HUD has one message kind today, `K_MSG` ("No chapters",
  `EV_NO_CHAPTER`). It gains a message id and a string:
  - "Needs the UMD Main" when `host_ok` is low;
  - "Update the UMD Main" when `host_bad` is set (a PROTO mismatch).
  - The wording and look are left to the implementation (H7, the maintainer 2026-09-30: no
    approval round). The mockups are still rendered and pixel-checked by `run_transport_hud.sh`.
  - It is owed to `on-screen-messages.md` and `troubleshooting.md` in the same change
    (CLAUDE.md's table).
- **If the host disappears mid-play** (Main restarted, `host_ok` times out) with subtitles
  on: the fabric turns them Off (a SUB-off with its flush) and shows the same message.
- **A UMD Main facing an older or newer core** (a PROTO mismatch seen in HOST_RD): the host
  stays silent on the port and shows Main's own info pop-up once per core load.

## 6. The stages

Each stage has a bench that can go RED and an independent oracle.

| stage | what | oracle / gate |
|---|---|---|
| **B0** | This plan; the decisions (§7) | the maintainer |
| **B1** ✅ MERGED (PR fj#32) | **The host decoder on the PC (host C).** `umd_sub.cpp` (libpng, the plane writer, the ring reader, §3.3), built natively against this PC's libpng (1.6.58) AND the device's libpng (1.6.28 at the merge; **re-pinned to 1.6.37 by B2**, the version the rig runs: the same sweep, equal), from its pinned source | `bench/umd/run_hps_sub.sh [--red] [--sweep]` (`tools/hps_sub_check.cpp`, `tools/hps_sub_cases.py`). Every case vs an in-process oracle written apart (`png_oracle.c`'s decode with libpng's own interlace handling, the premultiply as `(2ca + 255) / 510`, its own placement and clip): verdict, size, every pixel, the clipped count and **no write outside the image** (a sentinel plane and a guard band), the ring read back from a ring the unit wraps in, the cancel hook; the synthetic set also vs `sub_golden.py`'s plane words. **Measured:** 1,292 synthetic cases (`png_golden.py`'s 323 at four placements: the edges, one pixel on, wholly off; 337 Adam7; 221 refused), **all 336,181 subtitle units of 88 discs** and all 5,901 menu PNGs at two placements, on both versions: every one equal; the versions differ only on `crc_iend` (§3.3). 11 mutations, each caught by its own arm. The fabric decoder is not run again: it equals libpng on every image (`run_png.sh --sweep`), which this equals |
| **B2** ✅ MERGED (PR fj#33) (2026-09-30, "B2, the results" below: the budget missed as first built, met after option 1) | **The rig, before any RTL**, with the HIL Main (one probe module, not shipped) | measured on the current core. Main's poll period under UMD: OSD closed, open, and during a file browse. The uncached write and read rates into the window. B1's decode time on the A9 for the largest unit and a spec-maximum image. **A fabric-written plane read back from the HPS, compared word for word with B1's plane for the same unit** (it proves the address map and the byte order of §1 / §3.3). The `main=` switch in and out of the core with an MGL launch and a release-style install |
| **B3** ✅ MERGED (PR fj#34) (2026-10-01, "B3, as built" below) | **The fabric.** `umd_host.sv`; `sub_overlay` without `sub_png` / `sub_plane_wr` / the ring reader; `sub_sched`'s partner is the port; the SUB command gated on `host_ok`; the message; `emu` wiring, `UMD.qsf`, `check_emu_wiring.py` | `run_sub.sh` / `run_overlay.sh --red` with a **mock host** in the bench (below); a new `run_umd_host.sh --red` (the EXT_BUS protocol: MAGIC, PROTO, heartbeat timeout, event FIFO overflow, command mux); `run_player_ctl.sh` (SUB refused without `host_ok`, the grab); `run_transport_hud.sh --red` (the message states pixel-exact); `lint_undriven` |
| **B4** ✅ MERGED (PR fj#35), rig gates met, 5 of 5 seeds pass (2026-10-01, "B4, as built" below) | **The Main module and the fit.** `support/umd/umd_host.cpp` (the poll side, the worker, §1); `build_main.sh` builds the one binary; the fit and a **5-seed sweep** (A2) | the ALM freed, measured against §3.1's estimate; the rig: P7c's gates re-run under the UMD Main (Akira's timing burst, The Mummy's 0.1 s window, a chapter jump, trick play, a track step on Aliens), plus a seek mid-decode, the OSD open while subtitles run, a file browse while they run, and **stock Main: the message, playback unaffected** |
| **B5** ✅ MERGED (PR fj#36, 2026-10-01, §1 "Packaging") | **Packaging and the manual.** The release asset, `install.md`, `compatibility.md` (the "Planned" note becomes the requirement), `on-screen-messages.md`, `troubleshooting.md`, `controls.md` (the Subtitle button needs the UMD Main) | `docs_check.py`, `mkdocs build --strict` |

B1 and B2 need no RTL and can run in either order. B2's decode timing needs B1's code.

**B2, the procedure** (written 2026-09-30 so a new session can run it cold; branch
`feature/hps-b2`):

1. **The probe: FIFO commands in the HIL module** (`main/support/umd/umd_ctl.cpp`, armed only by
   `/media/fat/umd_hil`; not shipped). It links B1's `umd_sub.cpp` (already in the Main build).
   The commands, each answering in `/tmp/umd_ctl.log` (`mister.py shell -- cat ...`):
   - `b2 libpng`: `png_get_libpng_ver(NULL)` at run time -- **first**. If it is not the pinned version (1.6.28 when written; B2 found 1.6.37 and re-pinned),
     stop and re-pin `run_hps_sub.sh`'s `DEV_VER` and `main/support/umd/libpng/` to it.
   - `b2 poll <s>`: for `<s>` seconds, the gap between successive `umd_ctl_tick` calls (one a
     pass of Main's poll loop): count, median, p99, p99.9, max. Timestamp at the top of the
     tick, before the arm check.
   - `b2 bw`: through `shmem_map` of the **scratch region**, a 720 x 480 plane's 1,382,400
     bytes written with `volatile` 32-bit stores (as `umd_sub` writes), then read with 32-bit
     loads (as `umd_ring_copy` reads): MB/s each, best and worst of 10.
   - `b2 decode <png> <ux> <uy>`: `umd_sub_decode` of a file into the scratch region: wall
     time (CLOCK_MONOTONIC), `err`, w, h, clipped; `getrusage` max RSS before and after.
   - `b2 dump`: both subtitle planes (HPS `0x3280_0000`, `0x32C0_0000`, 1,382,400 bytes each)
     to `/tmp/umd_plane0.bin` / `umd_plane1.bin`.
   - These run on the poll thread (a measurement: a few ms of stall is accepted and said so).
2. **The scratch region: core word `0x0670_0000`, HPS byte `0x3380_0000`, 4 MB** (moved to `0x0680_0000` / `0x3400_0000` by P6d, whose planes 2 / 3 took `0x0670_0000`: `panel.md` §2). Nothing in
   the core uses it: the highest core address is plane 1's end, `0x065A_A300`
   (`subtitles.md` §7's map; the RTL's bases grepped 2026-09-30). Never write the planes or
   the ring from the probe: the core is reading them.
3. **Test images, copied to the rig's `/tmp`** (small; the card is nearly full):
   - the largest measured unit (Toy Story, 7,214 B; `bench/umd/fixtures/gen/png_corpus`);
   - a 720 x 480 RGBA16 PNG of noise (the spec-sized rectangle: the 50 ms budget's worst case);
   - a 1,000,000 x 1 RGBA16 PNG (**the width bound: decodes, its time and RSS**) and a
     1,000,001 x 1 one (refused at its IHDR);
   - make them with `tools/png_golden.py`'s builders, and check each with B1's
     `.sim/hps_sub/check_sys` first.
4. **The readback** (the address map and byte order on silicon): play Akira from the NAS
   share (`/media/fat/cifs/games/DVD/umd/`) with subtitles on (the Subtitle button: `mister.py
   key subtitle`), wait until a line is on screen, `b2 dump`, pull both planes. On the PC,
   for each unit of Akira's track in the corpus cache, decode it with `umd_sub` at its x, y
   into a blank plane and compare its rectangle with each dump: **a unit whose whole
   rectangle matches word for word is the pass** (the plane is never cleared, so compare the
   rectangle only). A small tool, `tools/hps_plane_match.py` or a mode of
   `tools/hps_sub_check.cpp`.
5. **The poll under a file browse:** `b2 poll 20`, and during it open the OSD and browse the
   NAS share's directory with raw keycodes (`mister.py key osd`, then `mister.py key 108` down
   / `103` up / `28` Enter: `mister.py key` takes Linux keycodes). Also once with the OSD
   closed and once with it open and idle.
6. **The `main=` switch:** `mister.py deploy --main` already installs by a `[UMD] main=` line.
   After the measurements, load the menu core and check `state` for which Main runs (on .201
   `restore` has never brought stock Main back: `hil_harness.md`).
7. **The rig:** .236 is shared with the DVD sessions (ask whichever is driving it: `ps` for
   `mister.py`, then SendMessage); .201 is H264's (ask it). B2 needs no HDMI capture. `state`
   first, `restore` after, say when it is free.

**B2's pass / fail** (a figure alone decides nothing):
- **The budget.** The worst case is a spec-maximum rectangle (720 x 480, 1.38 MB written) after
  the largest measured unit (7,214 B). For it, the poll period + the decode + the plane write +
  a HOST_WR must come to **<= 50 ms**: half of The Mummy's 0.1 s step.
- **The poll under a file browse.** The longest gap between two polls while browsing a large
  directory on the NAS share must be **<= 250 ms**. A longer gap still works, but the first
  subtitle after it can be late (the unit's 0.57 s lead covers the decode, not the flip).
- **The readback.** A fabric-written plane must equal B1's plane **word for word** (an
  address or byte-order error fails outright).
- **If B2 fails**, the plan comes back to the maintainer before B3. The fallbacks:
  - write only the rectangle's changed rows;
  - a cached mapping with explicit cache maintenance in place of `O_SYNC`;
  - move the plane write onto the worker thread's own core;
  - or keep the fabric plane writer (`sub_plane_wr`, -209 ALM less freed) and send only the
    decoded pixels.

**B2, the results (2026-09-30): ❌ the budget as first built, everything else ✅. The
maintainer took option 1 (below), and the budget is ✅ at 31 ms, measured on the rig.**

Where and how:
- **Rig:** .201, the second MiSTer (a SuperStation One; its Linux has the same libpng file as
  the original rig's).
- **Core:** `UMD_p7subs_sweep2_20260930_2056.rbf` (SEED 3: main's RTL; B2 changes no RTL).
- **Probe:** `main/support/umd/umd_b2.cpp`. The test images are from `tools/hps_b2_images.py`,
  each checked against B1's oracle first. `hps_b2_images.py .sim/hps_b2
  bench/umd/fixtures/gen/png_corpus` also writes `b2_toystory.png` and **`b2_budget.png`, the
  budget case**, byte-identical to the file the rig decoded.
- **Two conditions:** *idle* (the core loaded, no disc) and *playing* (Akira from the NAS share,
  subtitles on). Playing gave the same writes and decodes as idle within 1 %, and the reads within
  4 % (33.0 → 31.8 MB/s). The decoder's error counters
  stayed 0 through every probe command.

| criterion | measured | verdict |
|---|---|---|
| **libpng** | `b2 libpng`: run **1.6.37** (`/usr/lib/libpng16.so.16.37.0`; the same file on the original rig's 2022 image), headers 1.6.28. Main *links* against its tree's 1.6.28 `.so`, but the soname resolves at run time to the Linux image's copy | ✅ **re-pinned**, and re-read on the rig after it as `run=1.6.37 headers=1.6.37`: `DEV_VER`, the sha256s, the vendored headers and `LICENSE` are 1.6.37's. `run_hps_sub.sh --sweep` ALL GREEN on it (every unit and menu PNG; 1.6.37 refuses `crc_iend` as 1.6.28 did), `--red` 11 of 11 caught, the ARM Main builds and runs with them |
| **The readback** | `b2 dump` while a line was up. `tools/hps_plane_match.cpp` vs `umd_sub` over Akira's 1,251 units: plane 0 = unit 7 (182 x 33 at 269,410, 2,540 pixels), plane 1 = unit 6 (275 x 38 at 222,411, 4,176 pixels), **word for word as is**. No unit matches in full under a swapped reading. The matcher's selftest finds a planted unit under each reading, and only there | ✅ the address map (core word W = HPS byte W * 8) and the byte order hold on silicon |
| **The poll** | `b2 poll` gaps. Idle, OSD closed: mean 46 µs, p99.9 0.33 ms, max 0.6 ms. Playing: mean 36 µs, max 3.8 ms. OSD open, idle: max 8.6-9.1 ms. **Browsing the NAS share** (Home re-scans the directory, Enter up and down): max 10.6 ms warm, **32.8 ms with the page cache dropped** (at the browser's open). The OSD is in no screenshot, so the browse is inferred: a gap at each press, the cold directory scan at the open, and an earlier run in which Backspace unmounted the disc (Found on the way, below), which proves Enter had opened the browser | ✅ (<= 250 ms) |
| **HOST_WR** | `b2 spi`: an EXT_BUS command of 4 words (a HOST_WR's size) 6.3 µs mean (max 0.1 ms); the telemetry's 63 words 66 µs | the budget's last term: negligible |
| **Uncached rates** (a 720 x 480 plane, 1,382,400 B, 10 passes) | writes: **32-bit (`umd_sub`'s) 68 MB/s = 20.2 ms a plane**; **64-bit (`strd`) 137 MB/s = 10.1 ms**; 128-bit NEON `vst1` 104 MB/s = 13.3 ms. Reads (32-bit, the ring) 33 MB/s. Readback mismatches 0 (nothing else writes the scratch region) | 64-bit stores halve the write |
| **Decode** (`umd_sub` as built; ms into the scratch region, i.e. uncached as the host will write / into the heap = the decode alone) | largest real unit (Toy Story, 561 x 375, 4-bit palette, 7,194 B): **40.2** / 28.8. **The budget case** (that unit's picture on a 720 x 480 canvas, 4-bit palette, 7,346 B): **64.0-64.6** / 45.1-45.5. 720 x 480 RGBA16 noise, 2.8 MB: 130.9 / 112.6; low-entropy, 1.6 MB: 212.0 / 195.2 | see the budget |
| **The width bound** | 1,000,000 x 1 RGBA16: decodes in 131.8 ms, peak RSS 10.5 → 29.9 MB, freed after. 1,000,001: refused at its IHDR in 81 µs ("Invalid IHDR data") | ✅ **no issue on the MiSTer**: the maintainer's condition for keeping it (`spec_hardening.md`) is met |
| **The budget** (poll + decode + plane write + HOST_WR <= 50 ms) | largest real unit: 3.8 + 40.2 + 0.006 = **44 ms**. **The budget case: 3.8 + 64.6 + 0.006 = 68.4 ms.** The poll term is the playing maximum with the OSD closed; with it open (~9 ms) both sums grow by ~5 ms and neither verdict changes. (The 2.8 MB spec-maximum image, 131-214 ms, is §8's accepted limitation: late and counted. It is not the budget) | **❌ as built** (68 vs 50; it still fits The Mummy's 0.1 s step, with 32 ms of margin where the plan asked for 50) |
| **`main=` in and out** | In: every MGL launch ran the UMD Main. Out: on the menu core the UMD Main kept running. The cause (Main at `MAIN_MISTER_REF`, `user_io.cpp`): Main re-execs only when the resolved `main=` **exists** (`strcasecmp(main, getappname()) && FileExists(main)`). .201's `[MiSTer] main=ConsoleMode/MiSTer_ConsoleMode` names a missing file, so Main never switches back. With no global `main=` (the default `MiSTer`) it does | ✅ explained, config-dependent and harmless (the module is inert outside UMD); §1's risk closed. The release-style name (`MiSTer_UMD`) takes the same path as the HIL's hashed name, so it was not run separately |

**Ceilings, measured with the probe only** (`b2 bare8`, `b2 pal`; not decoders: their
bit-exactness is untested):
- **Bare libpng to RGBA8** plus the premultiply: the budget case 56.7 / 36.9 ms. So the 16-bit
  expansion costs only ~19 % on the A9: **libpng's per-pixel expansion dominates there** (on the
  PC `umd_sub`'s own layer looked like two thirds: the PC split misleads).
- **A palette path:**
  - **Every one of the library's 336,181 subtitle units is 4-bit palette, non-interlaced**
    (the corpus cache's IHDRs, 2026-09-30).
  - The path: libpng hands over indices (`png_set_packing`), a 256-entry premultiplied table
    comes from PLTE + tRNS, and the plane is written with 64-bit stores.
  - The budget case: **26.3-26.8 ms** uncached / 17.6 heap. Toy Story: 16.9 / 12.1.
  - **3.8 + 26.8 = 30.6 ms: inside the budget.**

**Found on the way** (stock Main's behaviour, `menu.cpp` at `MAIN_MISTER_REF`):
- **The menu sleeps on the poll thread.**
  - Backspace in the file browser unmounts the image and shows "Unmounting the image" with a
    `sleep(1)` (measured: one 1.004 s poll gap, and the disc stopped).
  - "Clearing the option" sleeps 2 s, and other menu screens sleep too.
  - Any of these during playback stalls the poll, and with it the sector reads, for that long
    (§8).

**The options for the maintainer** (the procedure's fallbacks first, then what B2 found):
- *Write only the rectangle's changed rows* does not apply: the plane is not cleared, so the
  whole rectangle must be written.
- *Move the plane write onto the worker's core* does not change the budget: the decode and the
  write already run there in sequence. It only moves the poll stall.
- *A cached mapping with explicit cache maintenance:* not measured. The 64-bit store already
  doubles the uncached rate.
- *Keep `sub_plane_wr` in fabric* (209 ALM less freed): the decode alone is still 45 ms (heap),
  plus a pixel hand-off. It does not reach the budget either.
- **Proposed: a palette fast path in `umd_sub`, plus 64-bit stores in the general path.**
  - The fast path covers every unit measured, at ~31 ms against 50.
  - It is bit-exact by construction: a table entry is the general path's pixel. An 8-bit
    palette sample expanded to 16 bits is v * 257, whose high byte is v. **Not yet measured:**
    the probe's output was never compared with `umd_sub`'s plane. It also wrote at x = 0 with
    an even width. Real units sit at odd x (Akira's unit 7 at 269) and have odd widths (Toy
    Story's 561), which adds one 32-bit store at each end of a row: negligible.
  - **Its rig round measures both:** `b2 decode b2_budget.png 0 0` for the time, and `b2 dump
    0x33800000 1382400 /tmp/x.bin` matched with `hps_plane_match` against the PC's decode
    for exactness.
  - `run_hps_sub.sh` gates it on every unit and on both libpngs, and gains a mutation for the
    table.
  - Every other image takes the general path, whose write the 64-bit stores halve: the budget
    case at ~54 ms, est.
  - No RTL, no change to §2-§3's protocol.
- **Or accept 68 ms:** the budget was set at half of The Mummy's 0.1 s step, and the unit's
  0.57 s lead covers a decode.

**Option 1, decided by the maintainer and built (2026-09-30):**
- **What changed:** `umd_sub.cpp`'s palette path and its 64-bit pair stores (§3.3).
- **The bench:** `run_hps_sub.sh --sweep` ALL GREEN on both libpngs (every subtitle unit, every
  menu PNG, the synthetic set). `--red`: 16 mutations, each caught by its own arm. M12-M16 are
  new (the table's alpha past tRNS, its premultiply, its colour past PLTE, the odd leading
  store, Adam7's spaced store); M2, M3 and M9 follow the new code.
- **On the rig** (.201, Akira playing, subtitles on, the decoder's errors 0):

  | case | before | after |
  |---|---|---|
  | the budget case, uncached / heap | 64.0-64.6 / 45.1-45.5 ms | **27.0-27.5** / 19.3 ms |
  | Toy Story, uncached | 40.2 ms | **16.9-17.4** ms |
  | 2.8 MB RGBA16 noise (the general path, now with 64-bit stores) | 130.9 ms | 120.9 ms |

- **Exact on silicon:** the scratch region was dumped after each decode and matched with
  `hps_plane_match` against the PC's decode, **word for word as is**:
  - the budget case's whole 720 x 480 rectangle (54,897 non-transparent pixels);
  - Toy Story at 77,31, an odd x, so each row starts with the leading 32-bit store.
- **The budget: 3.8 + 27.5 + 0.006 = 31.3 ms ✅** (about 36 ms with the OSD open; limit 50 ms).

**Verification must not shrink.** `run_sub.sh`'s arms that test the blocks that leave, and
where each goes:

| arm today | mutation | after |
|---|---|---|
| `[plane]` | the premultiply's rounding | ✅ B1: `run_hps_sub.sh` M1 `[pixel]` (`umd_sub.cpp` vs the oracle's premultiply and `sub_golden.py`'s planes) |
| `[plane]` | the odd/even pixel of a word | ✅ B1: M2 `[pixel]` (the pair swapped); and B2's readback of a fabric plane on the rig |
| `[tear]` | clipping removed | ✅ B1: M3 / M8 / M9 `[clip]` (every case at four placements, the count and a sentinel plane with a guard band). B3: the mock host writes only inside 720 x 480, and the fabric's `[tear]` still checks no write lands in the shown plane |
| `[plane]` | the decode aimed at the front plane | B3: a mutation of `sub_sched`'s `buf`. The mock host writes where it is told, and `[tear]` catches it |
| `[ddr]` | the plane writer let in with read beats outstanding | **retired with `sub_plane_wr`**. `sub_mem`'s remaining rule (the grant held under waitrequest, M2) keeps its arm |
| `[unit]` | the ring's byte order in a word | B3: the mock host reads the unit from `ddr_model` and compares it with the tool's bytes. ✅ B1: M7 `[ring]` (`umd_ring_copy` on a ring every unit wraps in) |

**New arms (B3):**
- a stale completion (the wrong `seq`) accepted;
- the tail freed at the request, not at the completion (a slow mock host whose unit the demux
  overwrites: `[unit]`);
- the heartbeat never timing out;
- the SUB command honoured without `host_ok`.

**The mock host (B3).** In the Icarus benches it is a behavioural SystemVerilog host:
- it reads the request over the port;
- it reads the unit's bytes from `ddr_model` and checks them against `umd_sub_extract.py`'s
  unit;
- it writes the **golden** plane (`sub_golden.py`, libpng's pixels) into `ddr_model` at a
  chosen latency, and completes.

So the fabric is scored against an independent oracle, and the C decoder is scored separately
(B1).

**B3, as built (2026-10-01, ✅ MERGED PR fj#34).** The fabric half of A7: no RTL decodes a PNG
any more.

- **`umd/umd_host.sv`**, the port (§2), on hps_io's EXT_BUS beside `umd_telem`.
  - Its strobe / drive / dout structure is `umd_telem`'s, unchanged.
  - **HOST_RD** latches its whole record at the command strobe: one snapshot a read. The
    request crosses from clk_mem through a `cdc_snap`.
  - **HOST_WR** words: 1 the heartbeat {PROTO, host version}; 2 {done, err, seq}; 3 w; 4 h.
    The completion is one clk_sys register write {toggle, seq, err, w, h}, copied to clk_mem by
    a `cdc_snap`; there a toggle change is one `h_done`.
  - **The word table** is `tools/host_layout.py`'s (13 HOST_RD words, 5 HOST_WR words). It
    generates `umd/umd_host_words.svh` and `main/support/umd/umd_host_proto.h`, for B4.
- **`sub_top`, changed:**
  - `sub_png` and `sub_plane_wr` are gone (the files are deleted); `umd/png/` stays in the tree
    with `run_png.sh` (H6) but leaves `UMD.qsf`.
  - The ring's reader is gone: `q_take` makes the head unit outstanding (`rd_busy`), and its
    words are freed only at the accepted completion (`done`).
  - `sub_sched` is untouched: its `wr_*` are the request, and its `e_*` are the completion.
  - A small block between them holds `seq` (counts requests, never reset by a flush) and `gen`
    (counts flushes). It accepts a completion only with a request up, the seq matching, and no
    flush that cycle; it counts the rest in `n_stale`. It also tracks the shown plane's seq.
  - `sub_mem` is one client behind its output register (the reason it existed: mclk).
  - The DDR3 port writes only: ddr_mux2's A has its read tied off.
- **`player_ctl`:**
  - SUB without `host_ok` changes nothing and posts **HOST (event 10, data[0] = host_bad)**.
  - Subtitles on while the host is gone turn off the flush's way (SUB off, then HOST).
- **`transport_hud`:** K_MSG has a message id. Its strings live in a 256-entry ROM, each
  message with its own centred column (`tools/transport_layout.py`).
- **`emu`:** `umd_host` on the lock-only resets; EXT_BUS[32] is the OR of the two responders'
  drives; `player_ctl.host_ok` / `host_bad`. `check_emu_wiring.py` pins all of it.

**The fit** (one, SEED 3, not B4's 5-seed sweep): `UMD_hpsb3_20261001_0153_20261001_0553.rbf`, commit
18600a7.
- Area: **37,171 ALM (89 %)**, **3,704 ALM freed** against P7's 40,875. That is more than §3.1's
  estimate of 2.0-2.6K. M10K 443 (-50), DSP 81 (-3).
- Timing: clk_dec 88.69 / 87.62 MHz (PASS at both corners), clk_mem 100.95 / 99.13.
- **G1 (Go To on the core) is decided against this freed area.** Its calibrated cost is
  0.75-1.9K (§4). The maintainer's call, once B4's sweep confirms the margin.

**On the rig, stock Main (2026-10-01, .201, this build):** B4's gate "stock Main: the message,
playback unaffected", taken early because it needs no Main module.
- Akira played, and Subtitle showed `Subtitles need the UMD Main.` in the message band over
  the film.
- The picture moved on, and the band was gone 8 s later.
- The diagnostic readout's `S` (subtitle bytes) stayed `00000000` and its subtitle row
  `U000 S000 D00 L00`: nothing reached the ring.
- Decoder errors 0.

**Decisions taken in B3** (each written beside its code):

| | decided | why |
|---|---|---|
| the heartbeat's timeout | **2^26 clk_sys cycles = 2.49 s**, not the plan's ~1 s | B2 found stock Main's menus sleep up to 2 s on the poll thread (§8): a 1 s timeout would read a "Clearing the option" screen as the host gone. `host_ok` starts low, so a stock Main's message is immediate anyway |
| the host lost mid-play | **subtitles off** (the flush's way), SUB off then HOST | nothing would decode the queued units: they would fill the ring (`n_ring_full`) and the scheduler would wait forever on its request. Judged as a level (`sub_on && !host_ok`): `sub_on` cannot rise without the host |
| the wording (H7) | `Subtitles need the UMD Main.` / `Update the UMD Main for subtitles.` | the existing message's style ("There is no chapter available."); the manual's `on-screen-messages.md` and `troubleshooting.md` carry both |
| `clipped` in the completion | **dropped** | B1 measures the clip (`run_hps_sub.sh` [clip]); the fabric only ever counted it, and no HUD showed it. `n_clipped` left with `sub_plane_wr` |
| `w` / `h` in the completion | **16 bits, saturating** at 0xFFFF on the host | `sub_flip` clips the rectangle to 720 x 480 from 16-bit fields; a 65,536-wide image truncated to 0 would hide. The HPS bound is 1,000,000 wide |
| the completion's crossing | a `cdc_snap` of {toggle, ...}, not a `cdc_pulse` plus data | the fields and the event land together by construction (the snapshot is atomic); completions are milliseconds apart, a snap round ~10 clk_mem cycles |

**Its benches** (every arm proven able to fail):
- `run_umd_host.sh --red`: the port alone.
  - Arms: [magic] [words] [snapshot] [offbus] [heartbeat] [bad] [done].
  - Mutations H1-H6.
- `run_sub.sh --red`: the chain with the mock host (`bench/umd/mock_host.svh`).
  - **The mock host** reads each unit out of the ring and checks it against the tool's bytes
    ([unit]). It backdoor-writes the golden plane into the plane it was told ([tear] if on
    screen), and completes after `+host_lat`.
  - New runs: a stale completion ([stale], K1), and the host holding each unit 3 ms on a
    64-unit ring, so the tail freed at the request is overwritten ([unit], R4).
  - The Mummy's 0.1 s window plays on time with the host at 30 ms (B2's worst, rounded up).
  - The plane writer's arms (P1-P3) and the two-client arbiter's (M1, M3) retired with the
    blocks.
- `run_overlay.sh --red`: the overlay with the mock host.
  - flush1 is now "while the host decodes": its late completion is ignored, `n_stale` 1.
  - O3 is now "a flush does not move gen", caught by a direct check ([flush]: gen moved 20
    cycles after the flush). Nothing downstream can see it: the seq rule alone keeps the plane
    right (the abandoned completion is ignored), and gen is only the host's cue to stop early.
    The first try at catching it through the mock host's [unit] survived, for that reason.
- `run_player_ctl.sh --red`: the host modes (`+no_host`, `+host_bad`, `+host_drop_on`) on four
  scenarios; mutations P49-P51 ([host]).
- `run_transport_hud.sh --red`: two states (`b15_no_host`, `b16_old_host`); mutations H23 / H24.
- `check_emu_wiring.py`: the port's clocks, resets, EXT_BUS bits, its handshake on the
  overlay's nets, `player_ctl.host_ok`, and the bus OR. Each rule was proven able to fail on a
  mutated copy.

**Found on the way:**
- `tools/disp_golden.py` had stopped writing `disp_rgb.hex` in P5f. `run_overlay.sh` and
  `run_plane.sh` (P7) still read it; they must have passed on a stale copy in the ignored
  fixtures folder. The output is restored.
- In a bench, an equality test on another always block's blocking variable can miss: the two
  blocks run in either order on one edge (`sub_overlay_tb`'s flush point; now a threshold).

**B4, as built (2026-10-01, ✅ MERGED PR fj#35).** The UMD Main's host module: subtitles work
end to end under it.

- **`main/support/umd/umd_host.cpp`**, the glue:
  - On Main's poll thread (CPU 1): every EXT_BUS transaction.
  - A worker thread pinned to CPU 0, like Main's offload thread. One job at a time: copy the
    unit out of the ring (uncached 32-bit loads), run `umd_sub_decode` into the plane, a store
    barrier, then DONE.
  - The hand-off is one slot and atomics. The cancel flag is polled once a row by the decode.
  - The ring and the planes are mapped once, by the worker. A length over the ring's 8 MB is
    refused before anything is allocated.
- **`umd_host_logic.cpp`**, the decisions, as a pure function (no I/O), PC-benched:
  - **Read rate:** HOST_RD every 2 ms while a request is up, a job runs, or a request was seen
    in the last 10 s; else every 50 ms.
    - The 10 s window was found writing the bench: between units no request is up. A slow
      period there would add up to 50 ms to the next unit, against The Mummy's 0.1 s step.
  - **Heartbeat:** HOST_WR at least every 100 ms (Main's menus sleep 2 s; the core times out
    at 2.49 s).
  - **One completion per HOST_WR.** A lost one is resent at 5 / 10 / 15 ms.
  - **Forgetting:** the remembered completion is dropped past 100 ms, or at MAGIC missing (a
    core reload restarts seq and gen at the same values).
  - **A cancelled job sends nothing.**
  - **w / h saturate** at 0xFFFF.
- **The hook:** `umd_ctl_tick`, still the integration's one patch. `umd_host_tick()` runs right
  after `is_umd()`, before the HIL arm check, so for every user. Under another core,
  `umd_host_away()` cancels and forgets.
  - With the HIL armed, the counters go to `/tmp/umd_host.json` at 4 Hz: served, cancelled,
    resent, forgot, refused, decode µs last / max, the largest unit.
- **The binary is `MiSTer_UMD`** (H2). The HIL install still names it by its hash
  (`mister.py deploy --main`), and the arm file is unchanged.

**Its bench:** `bench/umd/run_hps_host.sh --red` (`tools/hps_host_check.cpp`).
- **The fabric model** is `sub_top`'s acceptance rule and `umd_host`'s heartbeat, transcribed
  from the RTL. It is the independent side; `run_sub`'s mock host is the mirror image.
- **Nine scenarios:**
  - normal play, with units 100–400 ms apart;
  - flushes mid-decode;
  - lost completions;
  - core reloads with a 50 ms MAGIC gap, a 2 s gap, and none at all;
  - a core of another PROTO;
  - a long idle;
  - a 1,000,000-wide image.
- **Arms:** [served] [stale] [cancel] [order] [heartbeat] [rate] [latency] [reload] [proto]
  [sat].
- **The bench's expectations are its own numbers**, not the header's: L6 and L7 survived until
  they were.
- **Ten mutations, L1–L10**, each caught by its own arm.

**On the rig (2026-10-01, .201, this Main with B3's core `UMD_hpsb3_20261001_0153_20261001_0553.rbf`):**

| gate | result |
|---|---|
| Akira's timing burst | lines served from 106 s; at ~150 s `U00E S00D D00 L00` (one queued); decodes 0.4-18 ms (the first includes the mappings); the lines render cleanly at their placement (y 379, two lines) |
| a chapter jump | subtitles stay on; `U017 S016 D00 L00` |
| trick play | none during the hops, they resume with play: `U021 S01F D00 L00`, the host's `served` = `U` (33) |
| the OSD and a NAS browse during subtitles | `U027 S025 D00 L00`, nothing cancelled; Main's poll pass 41 µs mean (36-37 µs before the host module), max 10.6 ms at the OSD's open / close as in B2 |
| The Mummy's 0.1 s window (track 0x8B, past 240 s) | `U021 S020 D00 L00`, decode max 12.7 ms: P7c's count at the same point |
| Aliens' track step | `1 English, 2 da, 3 fi, 4 no, 5 sv, Off` |
| seeks during subtitles | twelve chapter jumps (gen 4 → 16), subtitles carry on, `D00 L00`. **No jump landed inside a decode** (decodes are 1-18 ms): the cancel path is the PC bench's (L1 / L2) and stays unexercised on silicon |
| stock Main: the message | B3's run (above) |
| resends, forgets, refusals | 0 throughout |

**The sweep (A2, 2026-10-01, d3087fb): 5 of 5 seeds pass.**

| SEED | clk_dec 100 °C / −40 °C (MHz) |
|---|---|
| 3 | 89.13 / 88.86 |
| 1 | 90.01 / 89.49 |
| 5 | 88.57 / 90.05 |
| 7 | 88.33 / 86.83 |
| 11 | 89.86 / 89.60 |

- **SEED 11 is pinned:** `UMD_hpsb4_sweep_20261001_1350.rbf`, 37,163 ALM (89 %), M10K 443, DSP 81.
  Checked on the rig under the UMD Main (.201, 2026-10-01): Akira's first lines
  `U008 S008 D00 L00`, decoder `ERR 0`, 9 served, nothing resent or refused.
- **A7's area is settled:** 3,704 ALM freed against P7's 40,875, with timing margin at every seed.
- **G1 (Go To on the core) is the maintainer's call** against that: its calibrated cost is
  0.75-1.9K (§4).

**The menu mode (with P9, §3.4)** gets its own arms then: `ui` not suppressing a subtitle
flip; a flush under `ui` hiding the host's page; a host flip taking effect before its vblank;
the acknowledgement before the latch (the host would draw into the shown buffer).

**The join** (the real C against the real RTL) is the rig's B4 gate. Optionally it is also a
Verilator bench that calls `umd_sub.cpp` through DPI, the repo's Verilator
cosims being the precedent.

**The fabric PNG decoder's RTL** (`umd/png/`, `run_png.sh`) leaves `UMD.qsf` but stays in the
tree with its benches green (H6). It is bit-exact over every image the library has, and it is
B1's independent oracle.

## 7. Decisions (✅ TAKEN by the maintainer, 2026-09-30, in two rounds)

| # | question | decided |
|---|---|---|
| **H1** | One Main binary for users and the HIL? | **Yes.** The HIL module stays armed by `/media/fat/umd_hil`. Testers and the harness run what users run |
| **H2** | The binary's name and the install | **Yes:** `MiSTer_UMD` in `/media/fat/`, `main=MiSTer_UMD` in `[UMD]`; stock Main untouched for every other core |
| **H3** | The host port's commands | **Left to the plan:** `0x7B` HOST_RD / `0x7C` HOST_WR, separate from the telemetry's 0x7A. Telemetry is instrumentation (A8), and a host feature must not depend on it |
| **H4** | The HPS PNG decoder | **libpng itself** (§3.3), decided after the reasoning was laid out. Main already loads `libpng16.so.16`; only the headers are vendored. The first proposal (our own PNG layer over miniz) is rejected |
| **H5** | Subtitles and the HPS's screens | **One plane** (§3.4), the second round: nothing but subtitles is HPS-drawn during playback, and subtitles do not play under a menu. The first round's "share the screen as on the PSP" had led to a second UI plane, withdrawn with the HPS screens it served. **Revised (the maintainer, 2026-10-03): the △ control panel is HPS-drawn over playback too** (P6d, `panel.md` §2): the PSP keeps subtitles under it (measured 2026-10-04), so it takes the plane in a mode that keeps the subtitle side running (`ui_sub`, its own planes 2 / 3, the host compositing the shown subtitle under it) |
| **H6** | The fabric PNG decoder after A7 | **Yes:** out of the netlist, kept in the tree with `run_png.sh` green (B1's independent oracle) |
| **H7** | The stock-Main message | **Left to the implementation, no approval round.** Proposed wording: "Needs the UMD Main" / "Update the UMD Main" on the transport HUD's `K_MSG` |
| **H8** | A-B / Repeat, and the rest of P6c | **Dropped for now: A-B / Repeat (chapter and title repeat with it), slow motion and frame advance.** (**2026-10-07: A-B alone built in fabric, `ab_repeat.md`**) P6c is Go To alone. The Repeat button and the `.` key stay inert |
| **G1** | Go To | **On the core, if it fits** (§4): decided at A7's fit, against the ALM actually freed; else dropped too. Proposed by the plan, on the maintainer's question |

**Also recorded (the maintainer, 2026-09-30):** A7 now, before P6c and before A9's retimes
(`area_plan.md` §8 A10).

## 8. Known limitations and risks

- **Subtitles need the UMD Main.** The one feature that moves *out* of stock Main's reach,
  by the maintainer's decision (A7). The manual has said so since 2026-09-30
  (`reference/compatibility.md`, "Planned").
- **Main's poll loop is shared.**
  - A long stall of the UI coroutine starves the poll: a large directory in the file browser,
    or a slow network share. That makes subtitles late or missed, and the counters show it.
  - **B2 measured them (§6):** browsing the NAS share stalls the poll at most 10.6 ms warm and
    32.8 ms cold; playing, 3.8 ms. B4 still runs a file browse during subtitles as a gate.
  - **Stock Main's menus sleep on the poll thread:** "Unmounting the image" 1 s (Backspace in
    the browser, which also stops the disc), "Clearing the option" 2 s, and others. Such a
    stall during playback delays subtitles (and the sector reads) by that long. This is upstream
    behaviour, left as it is.
- **The fork is a maintenance duty.** Every upstream Main release is merged, built, and
  re-checked for 0x7A-0x7C and for the integration anchors (`apply_integration.py` fails
  loudly on a moved anchor).
- **A spec-maximum image** (720 x 480 RGBA16, ~2.8 MB of PNG) is late on either host.
  `n_late` / `n_missed` count it, as today.
- **A menu page hides the subtitles** (§3.4), checked against the discs at P9's census.

**Done:** A7 is complete (B5 ✅ MERGED PR fj#36). The steps it named after it are done too: 480i with Analog Aspect
(✅ MERGED PR fj#37, `analog.md`), then G1, decided 2026-10-03 as Go To in fabric (✅ MERGED PR fj#41, `p6c.md` §10).
A12 (PR fj#59) later moved the subtitle decode back into fabric (`nav_engine.md` §11), so subtitles play on a
stock Main again.
