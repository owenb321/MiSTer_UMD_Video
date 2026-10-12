# P6b — transport: seek, pause, chapters, the audio track, the HUD

**Status: ✅ complete (every stage MERGED and HW-CONFIRMED; P6c, planned in `p6c.md`, is parked behind P7); decisions D1-D8 taken 2026-09-27, D9 2026-09-28, D10 (the panel dropped) 2026-09-29 (§8). P6b0-P6b2 ✅ MERGED (PR fj#18,
2026-09-28); P6b3 ✅ MERGED (PR fj#19); P6b3i ✅ MERGED (PR fj#20); P6b4 ✅ MERGED (PR fj#21); P6b5 ✅ MERGED (PR fj#22);
P6b6 ✅ MERGED (PR fj#23); P6b7 ✅ MERGED (PR fj#24), the whole-film gate ✅ after its fix (`fix/film-timing`, ✅ MERGED (PR fj#25): a lone PES PTS on the disc that the display believed, `display.md` §10).** The stages and their state are in §9. The visual reference, measured from the PSP player, is
`transport_hud.md`; this note is the engineering plan behind it. Roadmap: Phase 6.

**Scope (the maintainer, 2026-09-27; `transport_hud.md`).** P6b builds the direct buttons
and the Display overlay: play / pause, stop, chapter skip, FF / REW, audio track, the
icon pop-ups, and the overlay (disc title, chapter, elapsed / total time, the blue
progress bar). It also builds what they stand on: the seek, the decoder's discontinuity,
the reader's navigation, and the player control block of `menus.md` §4. **P6c** was the
pop-up panel on top; **the panel is dropped (D10, 2026-09-29)**. Every action gets a button,
the D-pad or the OSD instead, and P6c builds only the features: Go To, A-B / Repeat, frame
advance and slow motion. The subtitle button arrives with P7, UMD Menu with P9.

## 1. What a seek lands on (measured 2026-09-27, `tools/umd_seek_census.py`)

The census covers the main title of every disc image in the library: 89 titles, 402,530
entries.
`umd_video_format.md` "Entry points and marks" has the numbers; these are the facts
that shape the design:

- **Every video EP entry is a recovery point.** It is an I picture carrying a recovery
  point SEI with `recovery_frame_cnt 0`, `exact_match_flag 1` and `broken_link_flag 0`,
  and its access unit repeats the SPS and PPS.
- **59 % of entries are non-IDR I pictures.** IDRs are up to **160 s apart** (Ghost in
  the Shell 2.0; Tom & Jerry 60 s; typically 10-17 s).
  - So a seek that waited for an IDR would land up to minutes from its target.
  - **The decoder must start at a non-IDR recovery point.** P4's model refuses that
    start today (the frame_num gap), and the RTL has never run it (`h264_recon.md`
    §5).
- **Leading pictures.** One B frame, or one B field pair, follows a non-IDR entry's I
  picture in decode order but precedes it in output order.
  - Its references are from before the entry, so a decode that starts there cannot
    reconstruct it. `exact_match_flag` promises only the pictures from the I on, in
    output order.
  - They are **dropped, by definition**. ffmpeg's "Missing reference picture" on open
    GOPs is the same fact.
  - An IDR entry has none.
- **Entries are at most 1.97 s apart** (~1.4 s on average). So an EP-granular seek
  lands at most 2 s before its target.
- **Chapters are the type-5 marks.** The first is always at 0.0 s.
  - Type 16 is an `Endmark` at the title's tail on 17 discs, and never a chapter (The
    Rock has two).
  - A mark lies up to 1.94 s after the EP entry at or before it.
  - Every disc stores its marks in (item, PTS) order. PTS alone is not in order on a
    multi-item title. Nothing in the format promises the order, so the walk does not
    assume it (MiSTer_DVD's program-order lesson, `harvest.md`).
- **Multi-item main titles exist: 3 of 89.**
  - My Chemical Romance's two discs have 2 and 3 items (a transition clip, the concert,
    a trailer).
  - Now That's What I Call Music 2006 has 30, one per music video.
  - 73 playlists in the library have more than one item. The P1 census (33 discs) saw
    one item everywhere.
  - A mark names its item (u16), and its PTS is on that item's clip's timeline.
  - The PTS alone does not say where in the title a picture is.
- **IN / OUT cut the clip on 4 main titles.** The reader streamed whole clips until P6b2
  applied them (`umd_reader.md`), which P1's 33 discs allowed (only Terminator 2's OUT was 2.8 s
  early). Now:
  - Hackers' OUT stops 436 s before its clip ends.
  - My Chemical Romance's item 0 is 1.9 s of a 70 s clip on one disc, and on the other
    a 1.5 s window starting 54.6 s in.

  Playing whole clips shows a minute of transition there, and elapsed = PTS - IN goes
  negative.
- **Audio tracks: 53 of 89 main titles declare 2-5.** The language is two ASCII letters
  (ISO 639-1: en fr es it de ja zh ca). Several discs have two `en` tracks (a
  commentary), so a track is named by its number and its language.
- **The Astro Boy note corrected.** `roadmap.md` and `h264_recon.md` say Astro Boy's IDRs
  do not repeat the parameter sets. That is true of its IDRs **between** entry points
  (892 IDR slices, 398 IDR entries). Every one of its 879 entries carries an SPS and a
  PPS.
  - A seek still keeps the parameter sets it holds: the format permits sending them
    once, and a kept set costs nothing.

## 2. The architecture

One new module owns every transport decision: `umd/player_ctl.sv` (clk_sys). It has its
own bench from day one. MiSTer_DVD kept this logic as inline glue in `emu.sv` with no
bench, and a non-blocking ordering bug in a pause latch shipped from there.

`player_ctl` is the **player control block** of `menus.md` §4 item 3. The contract:

- **Commands:** play, pause, resume, stop, seek to a time, chapter +/-n or n, audio
  track next or n, trick speed. Codes for play playlist / mark and the subtitle track
  are reserved for P8 / P7.
- **Status:** the state, the chapter, the shown PTS, the track.
- **An event FIFO:** chapter change, seek done, title end.
- **Clients:** the buttons and keys (P6b), the panel (P6c), the menu engine (P9).

Gesture state (merge windows, pending targets) resets with the core (`reset_n`), never
with the pipeline flush it causes: a pending gesture must survive its own seek
(MiSTer_DVD's reset-domain rule).

### 2.1 The seek: one discontinuity, everything together

A seek is the pipeline's discontinuity. `es_discont` was planned in P5 and never built
(`roadmap.md`, the split decision), so it is built here. The sequence:

1. **Freeze.** The display keeps the store on screen, `disp_ctl` takes no pickups, and
   `aud_out` goes silent. The HUD shows the pending target.
2. **Resolve.**
   - A time: the reader's EP lookup (§2.4) gives the last entry at or before it.
   - A chapter: the reader's mark query (§2.4) gives the mark's PTS, then its entry.
3. **Flush, all at once, released together.** MiSTer_DVD found on its rig that every
   partial flush is a permanent A/V error: VBUF alone left the audio late; load plus
   audio left it early by the VBUF's depth (`dvd/flush_ctl.sv`). Each block and what it
   keeps:

| block | on the discontinuity | keeps |
|---|---|---|
| `umd_reader` | stops streaming, empties its 16 KB cache, clears `title_done` | the walk's results (title, playlist, clip, the tables' offsets) |
| `ps_stream_fifo` (16 deep) | emptied (today it is never flushed: 16 stale bytes would enter the demux) | — |
| `ps_demux` | reset, `aud_realign` armed | `aud_track` |
| `vbuf` | its clear handshake (benched mid-stream: `run_vbuf.sh`), `flush_out` cleared | the DDR3 engine's reset rules |
| `vidfeed_cdc` | both sides reset | — |
| `h264_top` | **the mount's reset** (`rst_n`, `fe_rst_dec_n`): every parse state and FIFO | **the parameter sets**: `sps_pps`'s valid bits have their own reset, `ps_rst_n`, which only a mount pulls (P6b1) |
| `recon_top` / `recon_dpb` / `dpb_mem` | **the mount's reset**, and `ddr_mux2`'s abort of master A, as a mount does (below). The DPB is empty after it; the reset **arms the recovery-point start** (§2.2) | **`recon_hdr`'s parameter sets** (`ps_rst_n`, as above); **the stores the display holds**: the holds live in `recon_out`, not in the decoder, so a reset decoder never allocates a held store |
| `recon_out` | every queued record released and its tag cleared | the store on screen |
| `disp_ctl` / `disp_sched` | `resync`: the next head anchors the STC; `ended` cleared | the shown store, until the first new pickup replaces it |
| `aud_ring`, `at3p_top`, `aud_out` | reset | — |

   **The decoder's quiesce is the mount's reset (decided in P6b1, 2026-09-27).** A seek
   arrives mid-picture: macroblocks in flight, DDR3 write bursts open, half a picture in
   the SE FIFO. The plan first called for a new request / acknowledge handshake that would
   let the reconstruction finish its open bursts. The mount already solves exactly this,
   proven on the rig (0 hangs in 60 reloads over a playing title, `hil_harness.md`):
   `ddr_mux2` aborts master A, completes an open write burst with byteenable 0, and
   swallows A's outstanding read beats; the decoder and `dpb_mem` reset. So a seek pulls
   the same reset.
   - What must survive is kept by giving it its own reset. The parameter sets: `ps_rst_n`
     on `sps_pps` and `recon_hdr` (a type-1 SPS's POC cache slot is invalid while it is
     rewritten, so a seek mid-SPS never leaves a half-written table valid).
   - Nothing else needs keeping: the display's holds are in `recon_out`.
   - The reset arms the recovery-point start, so a mount and a seek start the same way: a
     title's first picture is an IDR, which the start takes as it is.
   - One seam, counted, never silent: `recon_hdr` commits a parameter set at the NAL word
     AFTER it. A seek landing between an SPS's last word and the next NAL loses that set in
     `recon_hdr` while `sps_pps` holds it. A slice using it then counts P4's code 2. Every
     disc's entries re-send their SPS / PPS, which heals it at the landing.

   The stale-tag trap (MiSTer_DVD, fixed 2026-09-18) was a pre-flush picture whose PTS
   tag anchored the clock on the old timeline and threw ~1.1 s of new audio away. Here
   no pre-flush record survives `recon_out`, and `disp_ctl` anchors only on a record
   that arrived after the resync.
4. **Restart.** The reader streams from the entry's sector: `.MPS`-relative, mapped
   through the file's extents (§2.4).
5. **Land.** The decoder starts at the entry's I picture (§2.2), and the first new store
   anchors the STC. The audio gate's pre-anchor rules (`at3p_decoder.md` §7.3) release
   the first pair at its PTS. Lip sync is then what P6a measured, with nothing
   re-based.
6. **Watchdog.** No picture within 3 s of the restart is a counted, visible failure
   (`SEEK` on the HUD, a telemetry word). The display then resumes from whatever
   arrives, never hangs.

The decoder lands on the entry. **A chapter or a Go To target is then shown exactly**
(D2): the display skips the stores before the target (the skip-until path, also IN's).

### 2.2 The decoder: a recovery-point start

`recon_dpb` gains a start state that a discontinuity arms and the first picture clears:

- **The first picture must be an I picture**, IDR or not.
  - A non-IDR first picture sets `PrevRefFrameNum` from its own `frame_num`, so no gap
    is seen (the frame_num gap rule is for a stream in progress; 8.2.5.2 does not apply
    to a start).
  - Its POC MSB is taken as 0.
  - A P or B picture before any I is skipped and counted (never at an entry).
  - The first P after a non-IDR I has one picture in its DPB, so its initial list has
    empty slots. Those stay legal while unused: codes 11 / 12 count only a partition
    that USES an empty slot, and no refusal on an empty-but-unused slot is added.
- **Leading pictures** (POC below the start I's, until the next I) are parsed but not
  reconstructed or output, and counted (`lead_drop`). Their references do not exist.
  Decoding them against empty slots would write garbage into a store the display may
  soon show.
- **An MMCO naming a picture from before the entry is ignored and counted**, from a
  non-IDR start until the next IDR. A stream in progress would hold that picture; here
  it never existed.
  - No disc uses MMCOs. x264's open GOPs do: its first P after a keyframe unmarks a
    picture from before it. The model refused that until P6b0.
  - The RTL counts such an MMCO as error code 8. P6b1 must count it separately after a
    start and never let it stop decoding.
- Nothing else changes. From the I on the stream is conforming, which is what
  `exact_match_flag 1` promises.

The model (`tools/h264_recon_ref.py`) learns the same start first (P6b0). **The oracle is
ffmpeg on the same cut bytes.** The pictures ffmpeg emits from the I on are scored
bit-exact. Which pictures it drops is checked against the model's leading-picture set,
never assumed.

### 2.3 Pause, stop, the audio track

- **Pause** is a freeze, not a stall (MiSTer_DVD's first rig build froze only the display
  and its sync drifted with the length of the pause). One `pause` level gates, together:
  - `disp_ctl`'s 90 kHz tick: the STC holds, no head comes due, the shown store stays
    up;
  - `aud_out`'s 48 kHz sample tick: RUN holds its position, and the head pair plays on
    resume;
  - `aud_out`'s timers: the ~155 ms dry release and the ~2.5 s fallback.

  The decoder, the vbuf and the rings fill and back-pressure the reader. Nothing resets,
  resume is instant, and `av_err` must read the same across it (the gate). `HDMI_FREEZE`
  stays 0: the raster keeps running over a held store, the same path as a held last
  picture.
- **Stop** (D5): the reader stops and the display returns to the idle screen
  (`wave_vis` grows a term).
  - The PSP's Stop leaves the player for the XMB, and relaunching the disc resumes the
    film; there is no second Stop.
  - Here the idle screen is the XMB's analogue, and **Play resumes** from the stop
    point: the (item, PTS) of the last shown picture, landed on exactly like a chapter.
  - A second Stop does nothing. The point is kept until another image is mounted
    (P8's per-disc resume carries it across loads).
- **The audio track** is a register in `player_ctl`: Audio steps to the next declared
  track (`aud_present`, wrapping). The switch is audio-only:
  - `ps_demux`'s `aud_track` changes and `aud_realign` pulses;
  - the audio chain resets;
  - the video plays on and the gate re-arms against the running STC.

  The new track's first pair is the demux's position, which runs ahead of the display
  by the audio ring's depth (1.4-2 s: `h264_frontend.md` §6b). So **the switch is
  silent for up to that long.** Measured on the rig and accepted, or a seek to "now"
  instead. **Decided (D7): the silence is accepted.** The tag reads `♪ 2 English`: its ordinal among the declared
  tracks, and the language from `lang_mem` through a small name ROM, with the raw
  two-letter code as the fallback for any code not in it.

### 2.4 The reader's navigation port

`umd_reader` today keeps only `ep_map_off` and never reads the marks
(`umd_reader.md`). P6b adds a query port, served between stream sector reads (the stream
cache and the 2 MB vbuf cover the gap):

- **EP lookup (time → entry).** A binary search over the video map's entries. They are
  10 bytes each in the video map's table (`ep_map_off` locates it), read a sector at a
  time through `parse_buf`: 13 reads for 6,360 entries, 32 for the u32 maximum.
  - An entry that straddles a sector boundary uses the existing shadow fetch.
  - A target before the first entry gives the first entry. A target past the last gives
    the last.
- **Chapter query ((item, t) → rank, this chapter's start, the next one's).** A **full
  scan** of the playlist's marks, 40 bytes each, filtered to type 5, ordered by the key
  (item, PTS):
  - rank = the count of chapter marks at or before the key;
  - start = the largest at or before it;
  - next = the smallest after it.

  A chapter in another item is a seek into that item: the reader re-reads that item's
  CLP (it finds each by name already), then does its EP lookup.

  A scan handles unsorted marks by construction. The u16 maximum (65,535 marks,
  2.6 MB) is ~1,300 sector reads: slow (seconds), visible as latency, never truncated.
  The census's 74 marks are two sectors. A mark cache in M10K was rejected: it would
  need a bound and a refusal behind it.
- **Seek to (item, sector).** A new entry into `S_STREAM` with `strm_lba` / `strm_left`
  rewritten for the target. For a multi-extent `.MPS` (none in the library; supported
  since P2) the extent holding the sector is found by re-walking `STREAM/`'s records,
  as the stream does today. The request-site lock already covers a re-entry
  mid-transfer (`umd_reader.md`).
- **IN / OUT applied.** Each item starts with a seek to the entry at or before IN (the
  same EP lookup); the reader stops the item at the entry after OUT. The display then
  skips the stores before IN and ends the item at OUT, using D2's skip-until path and a
  stop-at-PTS. That closes the limitation P2 recorded (`umd_reader.md`), first real on
  Hackers and My Chemical Romance.
- **Limits, refused loudly.** An EP PTS is u32. A clip past 2^32 ticks (13.25 h) cannot
  be seeked by the map: flagged, not wrapped. The longest title is 2.5 h.

**The port as built (P6b2, 2026-09-27; `NAV_PLAY` P9, 2026-10-01; `umd_reader.sv`'s header
has the same).** Three commands, one at a time, on `clk_sys`. A command is taken on a cycle where `nav_req` and
`nav_ready` are both high. `nav_ready` = the title is streaming, draining or done, and no
command is pending. The key is always `(nav_item u32, nav_pts u48)`.

| command | what the reader does | results, with the `nav_done` pulse |
|---|---|---|
| `NAV_SEEK` (1) | **Atomic.** At the accepting edge every byte not yet delivered is dropped (the 16 KB cache and the output pipe flush, `title_done` falls). The item record is found by walking the item list from the first, and its CLP is re-read, so the track outputs follow the landed clip. Both lookups run: the last entry at or before the target clamped into [IN, OUT - 4] (P6b4 clamped to OUT - 1; `fix/skip-last-picture` to OUT - 4, `display.md` §11), and the first entry at or after OUT. The stream restarts at the entry's sector, found through the `.MPS` extents. | `nav_land` (the item), `nav_ep_idx` / `nav_ep_pts` / `nav_ep_sec` (the entry), `nav_skip` (the clamped target: the display shows from there, D2), `ep_flags`, `nav_err`. Pulsed when the stream starts. |
| `NAV_CHAP` (2) | Waits for the next stream sector boundary, then makes one pass over the main playlist's marks. The stream resumes exactly where it was. | `ch_rank` (chapters at or before the key), `ch_count`, and `ch_cur` / `ch_prev` / `ch_next` as `{item u16, pts u48}` with `ch_valid`. `ch_prev` is there so Prev's 1 s rule needs no second query. |
| `NAV_TIME` (4) | **P6c** (`p6c.md` §9, D15 / D16): Go To by time -- a seek whose target is the PLAYING playlist's time (`nav_pts`, 90 kHz ticks; `nav_op` is 3 bits since). **Atomic** as a seek. The seek's item walk subtracts each record's OUT - IN until the item whose span `[start, start + OUT - IN)` holds the time (a time on a boundary is the next item's IN; an item of no duration holds none) and lands there at IN + the rest; past the end the last item at its OUT, which the start lookup's clamp makes OUT - 4 (the title ends within a picture). Refused (`NE_ITEM`, nothing flushed) only on a playlist with no item. The model: `umd_nav_ref.Title.time_seek`. | As `NAV_SEEK`. |
| `NAV_PLAY` (3) | **P9** (`docs/p9.md` §3.2, P9-2): play playlist `nav_pl` (u16) from the key, a disc menu's `movieplayer.play`. **Atomic** as a seek, flushed at the accepting edge. PLAYLIST.UMD's table is read again with `nav_pl` forced in place of the longest, so the items, IN / OUT, the marks (`NAV_CHAP`), `pl_dur`, `n_items` and `main_pl` all follow it, then the seek's item walk lands on the key. The playlist stays chosen until the next `NAV_PLAY` or mount. | As `NAV_SEEK`. A target item past the playlist's last plays it from its first item at IN, flagged `NE_ITEM`; a playlist with no item lands on its end (`nav_land` 0, nothing streamed, `NE_ITEM`). |

`nav_err` codes (stable; player_ctl, the HUD and telemetry quote them). A navigation
error never stops the stream:

| code | name | meaning |
|---|---|---|
| 0 | `NE_NONE` | |
| 1 | `NE_ITEM` | SEEK: no such item. Answered at once; nothing is flushed or changed. PLAY: no such playlist (the same: answered, nothing flushed), or no such item in it (played from its first item) |
| 2 | `NE_MARKS` | CHAP: the marks section's length is not 2 + 40 n |
| 3 | `NE_OOB` | CHAP: the marks run past PLAYLIST.UMD |
| 4 | `NE_NOMAP` | SEEK: the clip has no video EP entry. It streams whole from sector 0 (P2's rule) |
| 5 | `NE_PAST` | SEEK: the entry's sector lies past the clip. The item is skipped |
| 6 | `NE_WIDE` | SEEK: a lookup target at or past 2^32 ticks. The map ends there |
| 7 | `NE_OP` | a reserved `nav_op` (0, 5-7; 3 was reserved until P9's `NAV_PLAY`, 4 until P6c's `NAV_TIME`). Answered, nothing done |

The walk's own refusals still apply inside a seek: a malformed CLP is `E_CLP`, as at a
mount. `ep_flags` (no map, past, wide) describe the playing item's lookups, whether a
seek's or the walk's; they reach telemetry as the `reader` word.

**The boundary with P6b3.** The reader guarantees only that every byte delivered after
the accepting edge comes from the landing. The rest of the discontinuity (§2.1: the
demux, the vbuf, the decoder, the display, the audio) is `player_ctl`'s job. It holds
the reader's `busy` until that flush is released, and the reader fills its cache and
waits.

Found while building it:
- The video map is map 0 on all 721 clips in the library. The reader still searches
  for stream `0xE0`; the bench puts a subtitle map first.
- Every main title's first entry is at sector 0, so applying IN moves only one start:
  My Chemical Romance disc 2's item 0 (entry 44, sector 3,947). OUT stops four titles
  early: Hackers (727,536 of 762,737 sectors), Terminator 2 (47 sectors early), and
  item 0 of both My Chemical Romance discs.
- A 48-byte shadow fetch of a 40-byte mark crosses into the next sector for bytes
  nobody reads. At every fifth boundary the next mark then re-reads two sectors
  (~1.4 reads a sector over 65,535 marks). The fetch length now follows what is
  fetched: 10 bytes for an entry or map header, 40 for a mark, 48 otherwise. That also
  saves each EP probe 38 cycles.

### 2.5 Chapter skip

The rules, as measured on the maintainer's PSP (D3):

- **Next** goes to the next chapter mark after the shown picture's (item, PTS). At the
  last chapter it does not seek. It shows the message `There is no chapter available.`
  (§3's message band) and playback goes on.
- **Prev** restarts the current chapter, unless the picture is **less than 1 s** after
  the chapter's start; then it goes to the one before. The PSP restarted a chapter
  starting at 0:12 when Prev was pressed at 0:13.
  - So two quick presses go back a chapter: the first restarts, the second lands inside
    the second.
  - At the first chapter, Prev restarts it.
- **Exact landing** (D2): a chapter opens on its mark's picture, not at the entry before
  it. The display skips the stores before the mark (§2.1 step 5, the skip-until path).
  That costs up to ~1-1.5 s longer on the held picture while the decoder (1.35-1.8x)
  catches up.

 Presses within 500 ms merge into one seek
of the net count (MiSTer_DVD). The HUD shows the projected `Chapter n` at once and holds
it until the landing, so it never flickers back. During playback `player_ctl` keeps the
next chapter's PTS; when the shown PTS passes it, it re-queries, bumps the chapter and
posts the event.

### 2.6 FF / REW

The PSP's model is three speeds each way (`Forward 1-3`), the picture moving. **Decided
(D1): I-picture trick play, the PSP's behaviour.** Every EP entry is a
clean recovery-point I, so a hop is one cheap discontinuity (§2.1) that decodes only the
I, and the display shows each store on arrival, audio silent. The
front end drops everything after the entry's first picture until the next hop. The
index pack at the entry lists the AU sizes, but mod 65,536, and large I pictures wrap;
so the I's end is the next access unit delimiter.

**As built (P6b4; `player_ctl.sv`'s header has the same):**

- **The front end's cut.** While a hop is the landing, `player_ctl`'s `one_frame` (through
  two clk_dec flops) makes `h264_top` end the stream after the first FRAME: one frame
  picture, or two field pictures (a pair is two access units). The cut is at the next
  access unit's opener (an AUD, SEI, SPS or PPS after a VCL NAL; every disc access unit
  opens with an AUD). There it emits the end-of-stream word and drops every byte after it
  until the next reset.
  - The end-of-stream word is what makes the I appear: C.4's bumping would otherwise hold
    it until three more pictures were decoded.
  - A stream whose next picture opens with no opener is not cut: it decodes on and shows
    what arrives. That is a known limitation, never a hang.
- **No untimed mode.** Each hop is a seek, so the display resyncs, and the first record
  after a resync anchors the STC and shows at the next pickup. The END that follows holds
  it. `run_disp_sched.sh`'s `trick` scenario proves it.
- **The hop.** A hop is the seek of §2.1 (the flush, the decoder's reset with `ddr_mux2`'s
  abort) to a target carried from hop to hop.
  - The target moves by the speed's rate times the wall time since the last hop was
    issued. A 90 kHz strobe adds rate x ticks, so a speed change applies from its press.
  - Every hop lands at or before its clamped target, in both directions: the reader has
    one lookup. `umd_nav_ref.hop` first landed forward hops at or after the target; the
    carried target keeps the rate either way, and the picture lags the target by at most
    1.97 s.
  - The landing writes its item entry without a skip, so the entry's I shows.
  - Hops are at least `HOP_MIN` (125 ms) apart, so each advances past the widest entry
    gap even at 20x (1.97 s / 20 = 98.5 ms). A hop is issued only after the last one's
    picture was shown.
  - Between hops the reader's stream is held (`rd_hold`).
  - The audio chain is held in reset while a hop is the landing: silent, and the demux's
    audio is taken and dropped. No TITLE_END is posted, since every hop's stream ends.
- **The items.** `player_ctl` knows no item's duration, so the reader's clamp is the only
  boundary it sees. The carried target is the reader's clamped `nav_skip`. A clamp that
  moved the target marks the item's EDGE: forward, down to OUT - 4 (OUT - 1 until
  `fix/skip-last-picture`); reverse, up to IN, or
  a request that saturated at PTS 0. The next hop then crosses: to the next item's IN (a
  request of PTS 0, clamped up), or to the previous item's end (PTS all ones, clamped down
  to OUT - 4). The overshoot is dropped at a crossing. Past the title's last item forward,
  or its first reverse, play resumes (D9). `umd_nav_ref.hop_request` / `hop_land` are the
  rule and the golden.
- **Leaving it** (D9). Play resumes by a seek to the shown key, which is the last hop's I:
  exact (D2) and landed like any seek.
  - PLAY, PLAYPAUSE, PAUSE (the PSP's ×: fj#57, D9), the opposite arrow and the title's ends
    resume at once.
  - STOP holds the I; the next PLAY makes the seek.
  - A chapter press keys its burst from the picture on screen at the press. The key is
    kept aside until the hop in flight lands.
  - A Go To seeks to its key.
  - A reader error on a hop ends trick play.

**The rates, measured on the maintainer's PSP (Akira, 2026-09-27).** The overlay's clock
was read at 1 s intervals, two intervals at each speed:

| speed | content seconds per real second | rate |
|---|---|---|
| `Forward 1` | 16, 28 | ~20x (noisy) |
| `Forward 2` | 34, 33 | ~33x |
| `Forward 3` | 46, 61 | ~55x |

Reverse reads as the same speeds (by eye, not timed).

**So a hop is chosen by time, not by count.** At the sustained rate, speed k advances a
target `t += rate_k x (the hop's wall time)`. The hop lands on the entry at or after
the target (at or before it in reverse). The rate then holds whatever a hop costs.
- A counted hop (2^(k-1) entries) would need 12-15 I pictures a second at `Forward 1`
  (entries ~1.4 s apart).
- A hop costs a reader seek, ~15-30 sectors of I picture, and one intra decode (~35 ms
  at 1,350 MBs). That is more than the ~70 ms a counted hop would get.
- A faster hop only shows more pictures at the same speed.

The rate constants live in `player_ctl` beside the measurement, rounded to 20 / 33 /
55. Play then seeks to the last shown entry.

The time and the chapter follow the shown I picture while Display is on: the PSP's
overlay kept counting during `Forward 3` (photo `akira_7`). As built, the chapter tracker
re-asks after every hop's picture, and `sh_pts` is the I's PTS.

MiSTer_DVD's hold-to-scrub (the picture frozen while held, one seek on release) was
rejected: it is not what the PSP does.

### 2.7 The time and the bar

- **Elapsed** = the shown store's PTS (`disp_ctl` latches it at pickup; a new output)
  minus its item's IN, plus the durations of the items before it. On a multi-item title
  that prefix sum comes from a scan of the playlist's items (u32 of them: never a
  table), made once per item change like a mark query.
- **Total** = the playlist's duration (the reader already sums it to pick the title).
- **The item tag.** On a multi-item title the display must know which item a store
  belongs to. The item index rides the path the PTS already takes: the vbuf's stamp
  queue, `au_pts`, `recon_out`'s record, `disp_ctl` (decision D8).
  - Single-item titles (86 of 89) need none of it.
- **The bar's fill** = elapsed x width / total, computed at event rate (once a second, on
  a seek) by **one shared serial divider**. MiSTer_DVD's `seek_bar` spent 1,033 ALM,
  most of it a free-running divider.
- **Seconds → h:mm:ss** by `secs_bcd` (harvested verbatim; the one shared converter, since
  a duplicate once masked mutations there).

## 3. The HUD (`transport_hud.md` is the look)

- **Our own glyphs, approved as pictures first.** `tools/transport_font.py` draws the
  rounded font and the icon set (▶ ‖ ■ ▶▶ ◀◀ |◀◀ ▶▶| ♪, the speed badge, the film mark)
  as bitmaps. `tools/transport_layout.py` renders every HUD state as PNGs over real
  frames from the discs.
  - **The maintainer approves the look on those pictures before any RTL** (inspiration,
    not recreation: `transport_hud.md`).
  - The layout model is also the bench's golden.
- **The elements in P6b:**
  - the operation pop-up bottom-left: the state icon; the FF / REW label and the speed
    digit in its circle;
  - the track tag;
  - **the message band** (D3): a full-width translucent band over the lower picture with
    one centred line, e.g. `There is no chapter available.`. Every message it can show
    is a row in the manual's `on-screen-messages.md` and `troubleshooting.md`;
  - the Display overlay: a translucent header bar with the disc title (`title_mem`),
    `Chapter n`, elapsed (blue) / total, and the progress bar with its blue fill.

  The pop-ups go after ~3 s; the overlay persists until Display is pressed again.
- **The pixel path** is `diag_hud`'s:
  - a text / icon plane written at event rate (every string, BCD and divide happens
    there);
  - a registered pipeline that is a pure function of (h, v), LAT 4, 480i-safe;
  - boxes as flat translucent fills: the half-dim the diagnostic HUD already does, plus
    a blue tint.

  Fades as a few alpha steps or a hard cut: decided on the mockups.
- **Composition:** into `emu`'s final mux, over the picture and under the diagnostic HUD.
  P9's plane compositor may take it over (`menus.md` §6).
- **Title glyphs.** PARAM.SFO's TITLE is UTF-8 and non-ASCII titles exist (the imports).
  The HUD font covers printable ASCII. Any other character is drawn as one visible
  placeholder glyph and a flag is set, never dropped silently (decision D6).

## 4. Inputs

**Decided (D4): follow the PSP.** Its shortcuts, from its panel captions and the
maintainer's checks (2026-09-27):

| PSP | action | MiSTer default |
|---|---|---|
| START | play / pause (`Play [START]`) | Start |
| × | pause; confirm inside Go To (P6c). **Since 2026-10-07 play / pause as START** (the J1 list's Select, §9 "Select") | A |
| ○ | stop | B |
| R / L | next / previous chapter | R / L |
| → / ← | fast forward / reverse, a speed a press | d-pad → / ← |
| △ | the control panel (P6c) | reserved: the panel's button |
| □ | the disc's menu (UMD Menu: P9) | reserved |

- Audio and Display have **no PSP shortcut**: the PSP reaches them only through its
  panel. Until P6c's panel exists they get their own `J1` buttons. A MiSTer pad has
  more buttons than the PSP's shortcuts use, and they stay after P6c.
- The MiSTer defaults assume a pad whose A / B sit where × / ○ do on a PSP (bottom /
  right). "Define buttons" remaps them.

**As built in P6b6 (D10: every action on a button and a key).**
- **The `J1` list** is Play/Pause, Pause, Stop, Prev Chapter, Next Chapter, Audio, Display,
  UMD Menu, Subtitle, Go To, Repeat. Its order is the joystick bits (B1 = bit 4), which
  `kbd_map.sv` and `emu`'s command wiring follow; `check_emu_wiring` pins all three together.
  FF / REW are the D-pad, the framework's own bits.
- **`jn,Start,A,B,L,R,Select,X,Y,,,`** gives each button its default on MiSTer's virtual SNES
  pad (A bottom, B right, X top, Y left):
  - D4's PSP layout: START Play/Pause, x Pause, o Stop, L / R chapters;
  - Display on X, the triangle, which was the dropped panel's button;
  - UMD Menu on Y (the square);
  - Audio on Select;
  - Subtitle, Go To and Repeat get no default (the keyboard, or "Define buttons").
- **Pause is the PSP's x** (`player_ctl`'s PAUSE: freeze, nothing when already paused);
  Play/Pause toggles. Until P6b6 the one button was PLAYPAUSE. **Superseded 2026-10-07:** the x
  button is named Select and issues PLAYPAUSE, as Play/Pause does (§9 "Select").
- **Inert until their features:** UMD Menu, Subtitle, Go To, Repeat and the keyboard-only
  Frame Step (`.`, `kbd_map` bit 15). The manual marks them "not yet implemented".
- **Every action has a default key** (§8 "The keyboard carries every action too"). `kbd_map` is
  harvested: PS/2 into the virtual joystick, press edges only. Keyboard FF / REW are never on
  a hold path, because IR remotes send ~9 taps a second.
- **The CONF_STR change landed once, with its manual rows** (`controls.md`; `docs_check.py`
  enforces them): it re-rolls the fitter seed.

## 5. The stages

Each stage ends with its bench green under `--red`, and where it changes the netlist, a
fit in the ledger. The oracles are independent of the RTL: the P1 parsers, ffmpeg and the
spec's processes.

| stage | builds | proven by | est. ALM |
|---|---|---|---|
| **P6b0** tooling, no netlist | `umd_seek_census.py` (done); `tools/umd_nav_ref.py`: EP lookup, chapter queries by (item, PTS), the Prev rule, from `umd_clpi` / `umd_playlist`; the recovery-point start and leading-picture drop in `h264_recon_ref.py`, checked against ffmpeg on cut bytes (§2.2); `cosim_golden.py --ep-start` cuts at the entry itself (today it hunts the next IDR) | `tools/tests` + `--red`; the model == ffmpeg from the I on, at a non-IDR entry of every disc | 0 |
| **P6b1** the decoder's discontinuity | `discont` into `h264_top` (sparing `sps_pps`), `recon_top` (the quiesce handshake, the start of §2.2, the drops without output, the holds kept), `recon_out` (drain, tags cleared) | `run_recon_top.sh`: two windows spliced with a discontinuity between them, a store held across it (`[hold]` fails any write into it); a discontinuity landing **mid-picture** at swept cycle offsets (bursts open, the SE FIFO half full), scored by `[hold]` and by `ddr_model` failing any orphaned or withdrawn burst; a start at a non-IDR entry (fields: Family Guy; 3:2: Akira; a leading frame: xXx); a spliced stream with its second window's SPS / PPS stripped (`h264_synth.py`). RED: the parameter sets wiped, the leading pictures decoded, the gap refused, a held store written, a stale record shown. **The whole-library cosim with `--ep-start`**: every disc from a non-IDR entry, bit-exact from the I | 150-300 |
| **P6b2** the reader's navigation | §2.4: the query port, EP lookup, the mark scan, seek to (item, sector), extents | `run_umd_reader.sh` new arms vs `umd_nav_ref`: `[seek]` every byte from the entry (8 per disc, synthetic edges), `[ep]` (before the first, past the last, an exact hit, a one-entry map, an entry straddling a sector, a synthetic map of many sectors), `[marks]` (unsorted, Endmarks, no chapters, marks on several items, 65,535 marks), `[item]` (a seek into another item of a multi-item title), `[mseek]` (the multi-extent fixture), `[inout]` (an item started at IN's entry, stopped at the entry after OUT: the Hackers and My Chemical Romance windows), a seek mid-transfer, a seek after `title_done` | 400-700 |
| **P6b3** `player_ctl` + pause + track | §2.1's sequencer, §2.3, §2.5, the event FIFO, the status; the display's skip-until and stop-at-PTS (IN / OUT, and D2) | `run_player_ctl.sh` (vs a Python model of the command → flush / hold sequence: the trio together, the release order, the merges, the pause gating, the reset domains); `run_av_sync.sh` + pause (the STC and the sample tick frozen, `av_err` unchanged across it, no re-arm) + a track switch (the new track's pairs at their PTS); `run_disp_sched.sh` + resync (the last store held through the seek, the first new one anchors, no pre-seek record shown); **`run_cosim.sh --seek`**: play, seek, and every picture after the landing bit-exact vs the golden from that entry | 300-450 |
| **P6b3i** the item tag (D8) | §2.7's item tag: a small wrapping item number rides the PTS path (the demux's marked byte, the vbuf's stamp queue, `vidfeed_cdc`, `au_pts`, `recon_top`'s picture record, `recon_out`, `disp_ctl`); `player_ctl` maps it back to the u32 item through a table filled at each item start, and the reader waits at an item start while that table is full (back-pressure, never aliasing: item k's last pictures need only item k+1's first to leave the DPB, so this cannot deadlock). The display's key, the stop at OUT and the skip from IN then hold in every item | `run_vbuf.sh`, `run_p3_chain.sh`, `run_recon_out.sh`, `run_disp_sched.sh` with the tag; a synthetic title of items shorter than the pipeline (the table full); the cosim across an item boundary. RED: the tag dropped at each seam, the table overrun | 100-200 (a guess) |
| **P6b4** FF / REW | §2.6: I-picture trick play, hops chosen by a time target at 20 / 33 / 55x | the cosim's trick arm (every shown store is its entry's I, bit-exact); `run_player_ctl.sh` the hop targets vs the model (forward and reverse, a slow hop, the title's ends); `run_disp_sched.sh` untimed mode (as built: no untimed mode was needed; the `trick` scenario proves the resync's anchor shows each hop, §9) | 200-400 (trick play) |
| **P6b5** the HUD | §3: mockups approved first, then `umd/transport_hud.sv`, the font and icon `.mem`s, the shared divider, `secs_bcd` | `run_transport_hud.sh`, pixel-exact vs `transport_layout.py` in every state. RED: a glyph row, the accent colour, the bar's rounding, a fade step, the title placeholder, the pop-up timer | 700-1,100 |
| **P6b6** inputs + manual | §4: `CONF_STR`, `kbd_map`, the wiring; `controls.md`, `on-screen-messages.md`, `troubleshooting.md`, `compatibility.md` | `docs_check.py`, `mkdocs build --strict`, `check_emu_wiring.py`, `run_scaffold.sh` wiring arms | ~50 |
| **P6b7** telemetry + the rig | ~8 of the 15 free words (state, shown PTS, chapter, seeks, seek latency, lead drops, nav errors, watchdog); the HIL Main rebuilt; `mister.py` presses | the rig gates (§6) | ~60 |

**P6b0 comes first, then P6b1.** P6b1 is the riskiest part (a decoder change on the
binding clock) and every later stage stands on it. P6b2 can run beside P6b1. P6b5's
mockups can go to the maintainer any time.

## 6. The rig gates (the P6b exit)

Each disc stresses one thing:

| disc | why it is on the list |
|---|---|
| Ghost in the Shell 2.0 | IDRs 160 s apart: every seek is a recovery-point start |
| Family Guy | field pairs |
| Akira | 3:2 film; en / ja, so also the track gate |
| X-Men 2 | 23.976 progressive |
| Now That's What I Call Music 2006 | 30 items: a chapter per item, the time across items (needs P6b3i, D8a) |
| The Rock | two Endmarks |
| Astro Boy | parameter sets |
| My Chemical Romance | multi-item, and item 0 a 1.5-1.9 s window of its clip (IN / OUT) |
| Hackers | OUT 436 s before the clip's end: the title ends there |

The measurements:

- **Seeks.** 20 each, both directions, random targets. Each lands on the entry
  `umd_nav_ref` names (the shown PTS in telemetry). `av_err` is within one frame 3 s
  after the landing. P4 `ERR` 0, no watchdog, no hang. The latency is measured and
  reported.
- **Chapters.** Next x5 and Prev x5: each lands on its chapter's entry; the HUD's chapter
  equals the model's.
- **Pause.** 3 x 10 s: `av_err` the same before and after, no re-arm, the picture held.
- **FF / REW.** Each speed each way for 10 s with Display on: the clock's rate within
  20 % of the PSP's (20 / 33 / 55x), no hang, Play lands on the last shown picture.
- **Track.** Every declared track of Akira in turn: each audible, `av_err` within a
  frame once it plays; the silence measured.
- **IN / OUT.** My Chemical Romance plays only its item 0's window, then the concert;
  Hackers ends at its OUT, not 436 s later.
- **HUD.** Screenshots of every state against the approved mockups.
- **The roadmap's Phase 6 gate.** A whole film with lip sync within one frame, with the
  above in it.

## 7. Budget and timing

- **ALM.** The latest fit is 31,400 ALM (`UMD_p6vbuf2_20260927_1317.rbf`). The P6 ceiling
  is 35K, so ~3.6K remains for **P6b and P6c together**. §5 sums to ~1.9-3.1K (~2.0-3.2K with
  D8's item tag), which leaves ~0.4-1.6K for the panel.
  - If P6b lands at the top of its range, the panel's budget is re-planned with the
    maintainer before P6c starts (P7's checkpoint is 37.5K).
  - **P6b2 came in at ~2x its range (§9); accepted by the maintainer, 2026-09-28.** The
    reader's ~+1.4K (once driven) against the plan's 400-700 leaves ~2.2K of the 35K for
    P6b3-P6b7 (planned 1.5-2.4K) and the panel. So the panel's budget IS re-planned with
    the maintainer before P6c starts, against the fit P6b7 leaves.
  - **After P6b3 (33,213 ALM; decided by the maintainer, 2026-09-28):** ~1.8K remains
    under 35K for P6b3i-P6b7 (planned ~1.1-1.8K) and the panel.
    - **P6b5's HUD is capped at ~800 ALM.** Its mockups are drawn to that budget: flat
      fills, hard cuts rather than fades, one shared glyph plane.
    - **The reader's cheap trims (P6b2's list below; estimated ~300-400 ALM, MEASURED ~50:
      see "After P6b5") were held in reserve for P6c's panel**, rather than raising the
      ceiling into P7's 37.5K checkpoint.
  - **After P6b4 (33,847 ALM; the maintainer, 2026-09-29):** `player_ctl`'s 962 ALM stays as
    built, not trimmed. ~1.15K remains under 35K for P6b5 (capped ~800), P6b6, P6b7 and the
    panel.
  - **After P6b5 (34,880 ALM, `UMD_p6b5_20260929_1305.rbf`):** `transport_hud` is 776 ALM
    (inside its cap). The core grew +1,033: the fitter placed `player_ctl` 118 ALM larger with
    no change to it, and the reader gained `item_base`. **~120 ALM remain under 35K** for P6b6
    (~50) and P6b7 (~60). The panel (P6c) has none, so its budget is re-planned with the
    maintainer before P6c starts, as §7 already required. **Decided (D10, 2026-09-29): the
    panel is dropped**, so 35K holds through P6b7; P6c's features (Go To, A-B / Repeat, frame
    stepping) get their budget when P6c is planned. **Planned 2026-09-30: `p6c.md`** (§1 there:
    P6c and P7's measured 4,744 ALM together do not fit; D11 is the area path).
  - **The reader's trims, measured (2026-09-29, the maintainer asked for them):** P6b2's list
    was an estimate, ~300-400 ALM. Standalone synthesis of `umd_reader` says otherwise:
    3,648 → 3,595 ALM (-53) and 4,015 → 3,908 registers, for the three worth taking:
    - `lk_t` a wire;
    - the seek's item walk on the mount walk's `it_j` / `it_q` and its `q_plus` adder;
    - one 65-bit comparator for the chapter scan's four compares (up to 3 cycles a mark,
      against a fetch per mark).

    The other two lose area: one adder for the map and entry addresses trades a 33-bit adder
    for two 32-bit multiplexers, and a carry-free `mk_o` needs a 33-bit bound check once.
    The reader's area is ~4,000 register bits spread over ~100 spec-width (32- to 64-bit)
    fields: no single cheap cut exists. What remains is sharing the mount walk's registers
    (SFO, playlist, `dur`: ~430 bits) with the navigation's (`lk_*`, `vm_*`, `mk_*`, `sk_*`:
    ~400 bits), perhaps 100-200 ALM, invasive; or ISO handling to the HPS.
  - **M10K 419 (+16; the plan said +6-10):** the HUD's font takes 10 blocks where its 3,072 x
    20 bits need 6 (Quartus's split of a non-power-of-two depth); three explicit 1,024-word
    banks would return 4 if M10K ever binds.
- **M10K:** +6-10 (the font and icons, the text plane, the language names). 401 are
  used, of 553.
- **Timing.** clk_dec closed at 86.04 MHz at -40 C on the last fit: 0.04 MHz of margin.
  - P6b1 changes `recon_dpb`, which is P6a's binding cluster (its reference marking).
    Expect a seed sweep, and retime `recon_dpb` inside P6b1 if the sweep misses.
  - Any retime is scored in the cosim against The Office Disc 01's 1.35x floor.
  - Everything else in P6b is on clk_sys.

## 8. Decisions (the maintainer, 2026-09-27)

| # | question | decided |
|---|---|---|
| D1 | FF / REW: I-picture trick play, or hold-to-scrub? | **I-picture trick play, the PSP's behaviour** (§2.6), at the PSP's measured ~20x / 33x / 55x, hops chosen by time |
| D2 | Land a chapter or Go To at the entry, or exactly? | **Exactly** (§2.5): the display skips the stores before the target. FF / REW's return to play lands on its last shown entry, which is exact by construction |
| D3 | Prev's rule; Next at the last chapter | **Prev goes back only within 1 s of the chapter's start**, else it restarts the chapter (measured: 1 s after the start restarts). **Next at the last chapter shows `There is no chapter available.`** and does nothing else (photo `no_chapter_message`) |
| D4 | The button map | **Follow the PSP** (§4): START play / pause, × pause, ○ stop, L / R chapters, ← / → REW / FF, △ panel, □ disc menu; Audio and Display, panel-only on the PSP, get their own buttons |
| D5 | Stop | **The idle screen; Play resumes** from the stop point, kept until another image is mounted (the PSP: Stop leaves to the XMB, relaunching resumes). **The resume releases Stop's freeze, not a seek back** (P6b3; ratified by the maintainer, 2026-09-28). A second Stop changes nothing in the core; with the UMD Main's disc screen up, the Main takes it and forgets the disc's place (`resume.md` R7, 2026-10-10) |
| D6 | Title glyphs | **Printable ASCII plus a visible placeholder, flagged**; a deviation row in `spec_hardening.md` when P6b5 lands |
| D7 | The track switch's silence (up to ~2 s) | **Accepted** |
| D8 | Multi-item titles | **The item index is carried to the display in P6b** (§2.7). The item boundary itself stays P8's handoff: a short audio gap at an item change on these discs is not a seek bug |
| D9 | FF / REW's buttons and ends (asked 2026-09-28, P6b4) | **The opposite arrow returns to normal play** (the maintainer, measured on the PSP: ← during `Forward n`, → during `Reverse n`, play at normal speed, never the other direction); **speed 3 stays** at a further press; **either end of the title resumes normal play** (FF plays the tail from the last I shown, then the title ends as usual; REW plays from the title's start). **Revised 2026-10-06 (the maintainer, fj#57): × (PAUSE, the Select/Pause button) during FF / REW resumes normal play too**, as the PSP's × does; only ○ (STOP) holds the picture (`fix/pause-trick`, §9 "fj#57") |
| D10 | The pop-up panel (asked 2026-09-29, when P6b5's fit left ~120 ALM under 35K and the reader's trims measured ~50) | **Dropped.** Every action the UMD player's panel carries gets a button, the D-pad or the OSD instead (the table below). The J1 list (11 buttons) lands whole in P6b6's one CONF_STR change, the later features' buttons named but inert until they land. The keyboard covers every action. Main allows 28 named buttons; a modern pad has ~12, and an 8-button pad leaves a few actions to the keyboard. What it gives up: the PSP's △ panel and its discoverability; the HUD's pop-up captions say what each press did. **Revisited (the maintainer, 2026-10-03): the panel comes back on the HPS** (the UMD Main draws it; every button stays) -- P6d, planned in `docs/panel.md` |
| D8a | When the item tag lands (asked 2026-09-28) | **Its own stage, P6b3i, after P6b3** (§5), not inside P6b3; built in P6b3i (§9), which retired the interim below. Until then `player_ctl`'s key uses the item of the last landing (a mount or a seek): exact on the 86 single-item titles, and on a multi-item title until the picture crosses an item boundary by itself. From that point an `item uncertain` flag is up (`player_ctl`'s `item_unsure`): a status output in P6b3, made visible by P6b7's telemetry and P6b5's HUD; the manual's compatibility page says it to users now. The display's stop at OUT applies only while the landed item is the title's last (Hackers, Terminator 2), its skip from IN only to the landed item. The rig gate on Now That's What I Call Music (§6) waits for P6b3i |

**D10's map, every action without a panel** (the maintainer, 2026-09-29):

| action | where | P6b6 J1 button |
|---|---|---|
| Play/Pause, Pause, Stop, Prev / Next Chapter | buttons (D4) | 5 |
| Fast Forward / Reverse | D-pad → / ← (P6b4) | -- |
| Audio, Display | buttons | 2 |
| UMD Menu (P9) | a button (□) | 1, inert until P9 |
| Subtitle (P7) | a button stepping through the tracks, as Audio does | 1, inert until P7 |
| Go To (P6c) | a button; its editor on the D-pad (↑ / ↓ the value, ← / → the field), Pause (×) confirms | 1, inert until P6c |
| A-B Repeat, Repeat, CLEAR (P6c) | ONE Repeat button stepping off → set A → set B (A-B) → chapter → title → off | 1, inert until P6c; **its button became Control Panel (P6d, `panel.md` K3, 2026-10-04)**: A-B / Repeat was dropped (H8); A-B alone built 2026-10-07 on the panel's row 3 and the keyboard's B (`ab_repeat.md`) |
| Frame Advance, Slow Motion (P6c) | while paused: → a frame, ↑ / ↓ slow motion (the D-pad is free while paused) | -- |
| Screen Mode | the OSD's Aspect Ratio option (exists) | -- |
| Help | dropped: the manual's controls page | -- |
| Angle | none: no disc surveyed has multi-angle video | -- |
| Volume Boost | left out (MiSTer's Main has it, 2026-09-27) | -- |

**The keyboard carries every action too** (the maintainer, 2026-09-29, after D10): so a
FLIRC (which learns any IR remote in its firmware and types keys), a 2.4 GHz media remote, a
console dock's receiver or a keyboard reaches everything with nothing configured. MiSTer_DVD's
choices (`dvd/kbd_map.sv`, its `docs/ir_remote.md`) are kept wherever the action is the same;
a TV remote's HDMI-CEC buttons arrive as some of these keys (Main injects CEC as keyboard
events). Every code is below 256 and in Main's PS/2 table (Main drops a keycode of 256 or
more before a core sees it; MiSTer_DVD's media-key remap lives in its own Main, not here).
Built in P6b6 with the J1 list.

| action | keys |
|---|---|
| Play/Pause | Space (CEC Play/Pause) |
| Pause (freeze); Go To's confirm (x) -- Select since 2026-10-07, PLAYPAUSE (§9 "Select") | Enter, keypad Enter (CEC OK) |
| Stop | Q, Esc (CEC Stop) |
| Prev / Next Chapter | P / N, Page Up / Page Down (CEC) |
| Fast Forward / Rewind | → / ←, F / R, Tab / Backspace (CEC FF / Rewind) |
| Up / Down (Go To's value, slow motion while paused) | ↑ / ↓ (CEC) |
| Frame Advance (while paused) | →, `.` (MiSTer_DVD's Frame Step) |
| Audio | A, F3 (CEC Green) |
| Subtitle (P7) | S, F4 (CEC Yellow) |
| Display | D |
| UMD Menu (P9) | M, F1 (CEC Blue) |
| Go To (P6c) | G, F2 (CEC Red; MiSTer_DVD's Angle / Title, neither on UMD) |
| Repeat (A-B / Repeat, P6c) | L (MiSTer_DVD's A-B, VLC's loop) |

Never bound (MiSTer_DVD verified each against Main): F12 and the Menu key (the OSD), Pause/Break
(no break code), NumLock / ScrollLock (Main's keyboard-emulation toggles), Alt / Meta.

**Found with the answers: Go To also selects a chapter** (P6c, the panel's item; photos
`goto_chapter_30` / `goto_chapter_6`, and the maintainer's walk-through, 2026-09-27):

- **Two boxes, above the bar:** `Chapter n`, then the time `hh:mm:ss`. On a title with
  no chapters only the time box shows.
- **Moving between boxes.** The chapter box is highlighted first, and ← / → move
  between the two.
- **Editing.** Selecting a box opens it: ▲ / ▼ step its value.
  - The time box edits hours, minutes and seconds as separate fields, with ← / →
    between them.
- **The target marker.** A blue ▼ above the bar marks where the jump will land, and ×
  confirms.

What the build needs:
- The chapter selector steps ±1, so it needs only this plan's next / previous queries.
  Each step's query also gives the marker's position.
- A time target uses the EP lookup and lands exactly (D2).
- The marker is the bar's divide with the target instead of the elapsed time
  (`transport_hud.md` §3).

## 9. Status

| stage | state |
|---|---|
| P6b0 | ✅ MERGED (PR fj#18); done 2026-09-27, no netlist change. Details below. |
| P6b1 | ✅ MERGED (PR fj#18); done 2026-09-27: built, benched, the whole library bit-exact from a non-IDR entry in RTL, fit, rig-checked. Below. |
| P6b2 | ✅ MERGED (PR fj#18); built 2026-09-27: IN / OUT applied, `NAV_SEEK` and `NAV_CHAP`, benched on the synthetic edges and every disc image. Area about 2x the plan, accepted by the maintainer (2026-09-28); P6c's budget re-planned before it starts. |
| P6b3 | ✅ MERGED (PR fj#19, 2026-09-28), ✅ HW-CONFIRMED: built, benched, fit, rig-checked. Below. |
| P6b3i | ✅ MERGED (PR fj#20, 2026-09-28), ✅ HW-CONFIRMED: the item tag (D8), split out of P6b3 (§5). Below. |
| P6b4 | ✅ MERGED (PR fj#21, 2026-09-29), ✅ HW-CONFIRMED: FF / REW, benched, fit, rig-checked. Below. |
| fj#57 | ✅ MERGED (PR fj#62, 2026-10-07), ✅ HW-CONFIRMED: × (PAUSE) during FF / REW plays, as the PSP's (D9 revised). Below. |
| P6b5 | ✅ MERGED (PR fj#22, 2026-09-29), ✅ HW-CONFIRMED: the mockups ✅ approved by the maintainer (`transport_hud.md` §6.5, every proposal taken); `umd/transport_hud.sv` pixel-exact vs the model in 31 states (`run_transport_hud.sh --red`, 18 mutations), the reader's `item_base`; fit `UMD_p6b5_20260929_1305.rbf` (SEED 9 first roll, clk_dec 87.23 / 87.31, 34,880 ALM, the HUD 776; §7); ✅ rig-checked (Akira, Family Guy, My Chemical Romance's items: `transport_hud.md` §6.7). As built: `transport_hud.md` §6.6. |
| P6b6 | ✅ MERGED (PR fj#23, 2026-09-29), ✅ HW-CONFIRMED: built D10's 11-button J1 list with its PSP default pad map, every action on a default keyboard key (§4, §8); `check_emu_wiring` + W61-W63; the manual's controls page and its remote-controls section. Fit `UMD_p6b6_20260929_1517.rbf` (SEED 9 first roll, clk_dec 87.40 / 88.16, 34,814 ALM). ✅ Rig (Akira): Enter pauses (a second Enter stays paused), Space plays; Tab (CEC FF) Forward 1, Backspace (CEC Rewind) back to play; F3 (CEC green) `♪ 2 Japanese`; Page Down chapter 2; G / M / S / L / `.` inert; Esc stops, Space resumes where it stopped. |
| P6b7 | ✅ MERGED (PR fj#24, 2026-09-29), ✅ HW-CONFIRMED except the film gate: the telemetry, `mister.py seq`, `tools/rig_gates.py`, fit `UMD_p6b7b_20260929_1758.rbf`; every §6 gate ✅ on the rig **except the Phase 6 film gate: ❌ FAIL**, a display-timing defect at three points of Akira (below), fixed on `fix/film-timing` (the maintainer, 2026-09-29; `display.md` §10). The gates also found and fixed a chapter flicker and an audio-switch seam. Below. **Caveat (P7c, 2026-09-30): the track gate stepped the tracks without a seek between them, so it could not see that a seek reset a chosen track to the lowest; the defect was real, found on the rig in P7c and fixed (§9's end).** |

### P6b0, as built (2026-09-27)

- **`tools/umd_seek_census.py`** measures what a seek lands on (§1).
- **`tools/umd_nav_ref.py`** is the navigation model, the golden for P6b2 and P6b3. It
  resolves positions as keys (item, PTS), and covers:
  - the EP lookup;
  - the chapters, including Next past the last and Prev's 1 s rule;
  - a burst of presses, each judged from the pending target;
  - IN / OUT: an item starts at the entry at or before IN; the reader stops at the first
    entry at or after OUT, because OUT is exclusive;
  - the elapsed time across items, and Go To's time → key;
  - the trick-play hops at 20 / 33 / 55x.

  `--chapters` lists where each chapter lands, which is useful on the rig. Akira's agree
  with the PSP photos: chapter 5 from 10:20, chapter 7 from 16:41 to 20:24.
- **`tools/h264_recon_ref.py`** gains the recovery-point start (§2.2):
  - `Decoder(rp_start=True)` and `arm_recovery_start()`;
  - leading pictures skipped;
  - MMCOs naming pictures from before the entry ignored;
  - `discontinuity()`: waiting stores dropped, references unmarked, the parameter sets
    kept, a start armed;
  - `--rp-start` on its command line.
- **`tools/cosim_golden.py --ep-start [--non-idr]`** cuts the window at the entry itself.
  **`bench/umd/run_cosim.sh --ep-start`** passes that on, and **`--model-only`** scores
  the golden alone: the model against ffmpeg, with no Verilator.
- **The gate, the whole library** (`run_cosim.sh --sweep --ep-start --model-only --frames
  90`): **88 of 89 disc images bit-exact against ffmpeg** from the first non-IDR entry
  after 40 % of the main title. Desperado is SKIP, a zero-filled rip. ffmpeg drops the
  leading pictures too, so the frame counts agree.
  - Leading pictures skipped: none on 8 titles (closed GOPs at that entry), one frame on
    62, one field pair on 18.
  - The table is in `.sim/cosim/sweep_ep_model.tsv`, not committed.
- **`tools/tests/test_umd_nav_ref.py`**:
  - `[nav]`: hand-built titles, with expectations taken from the format and the PSP.
  - `[x264]`: an open-GOP clip cut at its non-IDR keyframe. The leading pictures skipped
    must equal `umd_seek_census`'s independent POC scan, the MMCO is ignored, and the
    result is bit-exact with ffmpeg.
  - `[x264]`, a spliced discontinuity: the cut's SPS / PPS stripped. The output must be
    the head's emitted frames followed by the cut, bit-exact with ffmpeg.
- **RED:** 12 mutations in `tools/tests/red_umd.py` (7 navigation, 5 decoder start), each
  caught by this test.
- **Next: P6b1**, the decoder's discontinuity in RTL. Its cosim gate is
  `run_cosim.sh --ep-start` without `--model-only`.

### P6b1, as built (2026-09-27)

- **The decoder's discontinuity is the mount's reset** (§2.1): nothing new for the quiesce.
  - `ps_rst_n` on `h264_top` / `sps_pps` and `recon_top` / `recon_hdr` resets only the
    parameter sets' validity. `emu` ties it to the mount reset until P6b3's sequencer
    splits the two.
  - A type-1 SPS's POC cache slot is invalid while it is rewritten.
- **`recon_dpb`, the recovery-point start** (§2.2; the header comment has the rules). It
  is armed by the reset and `clear`:
  - pictures before the first I are skipped;
  - at a non-IDR start, PrevRefFrameNum and the POC state come from the I itself;
  - leading pictures are found by a POC **probe**: the POC states run with no store
    written, between `D_POST_MARK` and the store's allocation in `D_OPEN`;
  - after a start, an MMCO naming no picture is counted, not an error.
- `slice_skip` sends a skipped slice to the router's `R_DISCARD`, as a size refusal does.
- Counters out of `recon_top`: `rp_starts`, `rp_non_idr`, `rp_pre`, `rp_lead`, `rp_mmco`.
- **Gates:**
  - `run_cosim.sh --ep-start` (Akira 3:2, Family Guy fields, 90 frames from a non-IDR
    entry): every macroblock, every picture and every emission identical to the model,
    and the start's counts equal the model's (`STEM.rp`). 1.91x / 1.70x real time.
  - `run_cosim.sh --seek`: window A from an IDR; the decoder reset half-way through
    A's last picture; window B from a non-IDR entry at 70 % with its SPS **stripped**
    (A's is byte-identical), so only a kept SPS decodes it. The cosim now reaches the DDR
    model through `ddr_mux2` with emu's reset chain (`cdc_reset`, the two-flop abort).
    - Six reset points per title; three wait for the mux to hold an open write burst,
      one for outstanding reads.
    - The coverage harness also polices `dpb_mem`'s own rule (no write presented while
      its reads are out) at the mux's A side. The mux enforces that rule for the port,
      so once the cosim went through the mux, a client that broke it (C6) became
      invisible at the DDR model and survived. It is caught again.
    - All twelve pass: every picture after the seek identical, the display's holds kept
      through the reset (`[hold]`), no Avalon violation.
    - The abort completed open write bursts and swallowed read beats (the harness
      counts both). A seek set where it never met an open burst FAILs as coverage.
      Blind delays met none in 12 seeks, which is why `+seek_on` exists.
  - `run_recon_ctl.sh`: an x264 open-GOP clip cut at its non-IDR keyframe. Lists and
    DPB identical to the model with `--rp-start`, and the start's counts equal:
    1 start, non-IDR, 1 leading picture, 1 MMCO tolerated.
  - The regressions: `run_recon_ctl.sh` (x264, conformance, discs),
    `run_recon_top.sh` (x264, the output process, conformance, the JM streams),
    `run_h264_top.sh`, `run_p3_chain.sh`, `run_scaffold.sh` (the emu wiring, lint).
  - **Fit** `UMD_p6b_20260927_2222.rbf` (SEED 9, first roll): clk_dec 88.26 / 87.05 MHz
    (+1.0 at -40 C over the last fit), ALM 31,351, M10K 401, DSP 76, every gate PASS.
  - **Rig** (2026-09-27, that build, 60 s settled each; no seek source yet, so this is
    the regression): Family Guy 59.94 fields/s, the judder gate equal, `av_err` 0.02 ms;
    Akira 3:2 at 2.499 refreshes a picture, equal, 0.02 ms. HUD: the reconstruction's
    pictures == the front end's (nothing skipped at an IDR start), every error 0.
- **RED:**
  - `run_cosim.sh` C9-C15: leading pictures decoded; the old PrevRefFrameNum; a
    skipped slice not discarded; the parameter sets reset with the decoder in `sps_pps`
    and in `recon_hdr`; no abort (on an open burst); the reset not arming the start.
  - `run_recon_ctl.sh` D7 / D8: the MMCO tolerance and the leading skip, on the x264
    cut.
- **Found on the way:**
  - `run_recon_ctl.sh` checked only that its simulator binary EXISTED. A failed build
    left the previous run's binary in place, and it "passed". The runner now deletes
    the binary before building.
  - The disc streams re-send PPS 0 with different contents per GOP. So a seek golden
    may strip only a parameter set equal to the LAST of its type before the seek.
- **Known limitations:**
  - `recon_hdr` commits a parameter set at the NEXT NAL word, so a seek between an SPS
    and the next NAL loses that set in the reconstruction. It is counted as code 2,
    and healed by the entry's own SPS (§2.1).
  - A picture complete when the seek lands, whose last writes have not landed, loses
    them. The display can only be showing such a store in the same race as normal
    playback (writes landing before a pickup reads). The harness counts these
    ("cut by the reset"); 0 in every seek so far.
- **The whole library in RTL** (`run_cosim.sh --sweep --ep-start --frames 90`): **88 of
  89 disc images bit-exact from a non-IDR entry** (Desperado SKIP, a zero-filled rip).
  Every one's start counts equal the model's.
  - All are >= 1.48x real time but one: The Office Disc 01 at **1.32x** on this window
    (90 frames from the first non-IDR entry after 40 %; its decode time includes parsing
    the skipped leading field pair).
  - Its standard 300-frame window, rerun under the new bench, is still **1.35x**, as at
    P4 / P5g. So the decoder did not slow, and the mux costs nothing measurable. It is a
    different window of content, still faster than real time, which the 2 MB CPB
    absorbs. Recorded, not rounded away.
  - Found by the sweep: the cosim's `[hang]` arm fired on 25 titles, a false alarm. A
    skipped leading picture reconstructs nothing while the front end parses it; a dense
    one (Hackers' B) outlasts 200,000 cycles. Progress now includes SE words taken, and
    a real stall (C11) still hangs. All 25 pass rerun.
- **Next: P6b2**, the reader's navigation.

### P6b2, as built (2026-09-27)

- **`umd_reader.sv`**: IN / OUT applied at every item start, `NAV_SEEK`, `NAV_CHAP`. The
  contract and the `nav_err` codes are in §2.4; the design notes in `umd_reader.md`. A
  telemetry word, `reader` ({state, `err_code`, `ep_flags`}), makes the lookup flags
  visible (50 words; the HIL Main rebuilt).
- **The golden** is `tools/umd_nav_ref.py`, extended with `from_raw` (a title from its
  tables, for the synthetic images), `chapter_query`, `item_span` and `stream_plan`
  (hand-checked in `test_umd_nav_ref.py`, +2 RED). `umd_fixture.NavScript` turns it into
  commands, results and the streams each seek must produce.
- **The bench** (`run_umd_reader.sh --red`):
  - Command phases in `umd_reader_tb`: `[seek] [chap] [op]`. The phase switches at the
    accepting edge. A chapter query must leave the stream unbroken and read at most
    PLAYLIST.UMD's sectors + 2.
  - `syn_nav` has the EP-map edges: IN between entries and OUT exactly on one, the video
    map behind a subtitle map, a straddling entry in a 20-sector map, a one-entry map,
    OUT past 2^32, an entry past its clip. It also has unsorted, duplicate and dangling
    marks, a bad item and a reserved op.
  - `syn_marks_max` scans 65,535 marks twice (one read a sector); `syn_badmarks` and
    `syn_oobmarks` have broken marks sections and playback must survive them.
  - `syn_multi` seeks into its second and third extents, and into a clip with no video
    map.
  - **Every disc image in the library (88, subdirectories included)** runs a seeded
    script of 15-16 commands: seeks at random keys (half mid-transfer), a chapter's
    landing, the tails of the first and last items to OUT, a seek after `title_done`, and
    chapter queries. All pass, with the P2 chain on the walk's stream.
  - **39 mutations, each caught by its own arm** (R1-R14 kept, N1-N24 new, C1). Three
    needed the arm moved or the bench sharpened: a seek leaving `title_done` up survived
    until `title_done` was checked at the accepting edge.
- **Found on the way:**
  - Now That's What I Call Music's fixture had never run: its 67 regions overflowed the
    bench's 32-bit dependency mask. The format now holds 128 regions, in two masks: the
    walk's, and one without "items in order" for after a seek.
  - A seek fixture's sectors leaked into the P2 chain bench: the walk ran on into them
    when a seek landed just past phase 0. The chain now serves only phase 0's `.MPS`
    sectors.
  - The runner did not delete its simulator before building. A failed build ran the
    previous binary, which misread the new fixtures and printed PASS. It deletes them
    now, as `run_recon_ctl.sh` learned in P6b1.
- **Fit** `UMD_p6b_20260928_0246.rbf` (SEED 9, first roll): clk_dec 87.63 / 87.56 MHz,
  ALM 32,152 (77 %, +801), M10K 401, DSP 76, every gate PASS.
- **Rig** (2026-09-27, that build, 60 s settled each; no seek source yet, so this is the
  regression): Family Guy 59.94 fields/s, the judder gate equal, `av_err` +0.03 ms;
  Akira 3:2 at 2.50 refreshes a picture, equal, +0.01 ms. Reconstruction, front-end and
  audio errors 0; the `reader` word reads state 37 (`S_STREAM`), lookups clean. Hackers'
  OUT needs the whole film.
- **Rig, IN applied** (2026-09-28, My Chemical Romance disc 2, whose item 0 is a 1.5 s
  window from 54.6 s of a 62 s clip). Control arm, P6b1's build: the HUD reads `ITEM 0/3`
  at 15 s and still at 30 s (2,569 packs), the transition clip playing from its start.
  P6b2's build: at 3 s the reader is already in item 1 while the screen shows item 0's
  window. At 6 s the concert (item 1) is on screen. Errors 0, the judder gate equal,
  `av_err` +0.01 ms. The item boundary's PTS jump (~57 s back to 1 s) costs one display
  re-anchor and one audio resync: that is the item handoff D8 leaves to P8, not a seek
  defect.
- ⚠ **Area: about twice the plan (400-700 ALM).** In `emu` the reader went from 1,926 to
  2,699 ALM (+773) with the port tied off. The walk's lookups are live, and the seek and
  chapter states stay in its FSM with their registers. Driven by P6b3, the calibrated
  standalone synthesis puts the whole at **~+1,400 ALM** (umd_reader 2,055 -> 3,546
  estimated, x0.94 as the last fit placed it). Splitting it by disabling the accept paths
  proved meaningless: Quartus keeps the unreachable states and their registers. Where
  it goes: 32- to 48-bit spec-width arithmetic (the search, the extent skip, the clamp,
  the stop counter), ~900 register bits of state and results, and P2's FSM style (a mux
  per bit per assignment site). Against §7's ~3.6K for P6b and P6c together, this leaves
  ~2.2K for P6b3-P6b7 (planned 1.5-2.4K) and the panel. **Decided (the maintainer,
  2026-09-28): accept it, and re-plan P6c's budget** (§7). The options were:
  - accept it and re-plan P6c's budget (chosen);
  - take the cheap trims, ~300-400 ALM (an estimate; MEASURED in P6b5 at ~50: §7): `lk_t` as a wire; one adder for the map and
    entry addresses; the dead playlist-walk registers reused for the seek's; the marks'
    bound checked once, so `mk_o` needs no carry; the four 64-bit mark compares through
    one comparator (the scan is fetch-bound: +3 cycles a mark costs nothing);
  - or the standing contingency, ISO handling to the HPS. The reader is now ~2.7-3.3K
    of fabric.
- **Known limitations:** `umd_reader.md` "Known limitations" (the item boundary's early
  track flip, the u32 EP PTS, the scan's latency at the u16 maximum, strictly increasing
  maps assumed).
- **Next: P6b3**, `player_ctl` on this port.

### P6b3, as built (2026-09-28)

- **`umd/player_ctl.sv`**, the player control block (§2; its header has the contract).
  - Commands with stable codes: PLAYPAUSE, PAUSE, PLAY, STOP, NEXT, PREV, SEEK (Go To),
    AUDIO, AUDIO_SET. 10-15 are reserved and counted.
  - Status outputs, and an 8-deep event FIFO: CHAPTER, SEEK_DONE, TITLE_END, NO_CHAPTER,
    SEEK_WD, NAV_ERR, TRACK, BAD.
  - It runs on the core reset, so a gesture survives its own flush.
- **The seek** (§2.1):
  - A burst's key is latched at its first press. Each press is judged from the pending key
    through NAV_CHAP, and presses less than 500 ms apart merge.
  - The display freezes once a press finds a target: Next at the last chapter leaves
    playback alone and posts NO_CHAPTER.
  - NAV_SEEK follows. At its accepting edge `seek_flush` rises; it is held at least 16
    cycles and until the output queue has been idle 8 in a row, and `rd_hold` stays up
    4 cycles longer.
  - The landing's `nav_skip` goes to the display as the target. OUT goes too when the
    landed item is the title's last.
  - A watchdog (3 s unfrozen with no picture) shows whatever arrives, counted.
- **The display** (`disp_ctl` / `disp_sched`; `disp_ctl`'s header):
  - `freeze` is sampled at each refresh's eval and held until the next one. A frozen
    refresh has no eval, no pickup, no parity step and no STC tick. `frz` is that level,
    which `aud_out` freezes on, so both clocks stop and restart together.
  - `resync` is the seek's flush. Every queued record is taken and released unseen and the
    scheduler is cleared. Its rising edge makes heads wait for the target; the shown store
    stays up, held.
  - **The skip to the target** (D2): a record whose [t, t + duration) ends before the target
    plus one tick is dropped unseen.
    - t is the record's PTS, else the end of the last skipped record, kept in eighth-ticks.
    - The one tick is needed because a stream stores its PTS in whole ticks while an
      extrapolated time keeps the fraction. Without it a mark at a picture's stored PTS
      left the picture before it on screen; the model found this.
    - The first record shown is given its t as its PTS, so it anchors where it belongs.
  - The stop at OUT: the first record at or after OUT, and everything after it, is
    dropped; the display ends there.
  - `sh_pts` is the shown store's time.
- **`emu`**:
  - The resets split. `fe_rst_n` / `fe_rst_dec_n` stay the mount's: the parameter sets, the
    output queue and the display. `pipe_rst_n` / `pipe_rst_dec_n` / `pipe_rst_mem_n` are a
    mount or a seek: the FIFO, the demux, the vbuf's clear, the CDC, the decoder and the
    DPB's abort. `aud_rst_n` adds the track switch.
  - Not resetting `recon_out` on a seek is forced by its dual-clock FIFOs, whose two sides
    must reset together. The display drains it instead, and the store on screen stays
    held.
  - The reader's navigation port is `player_ctl`'s, and so is `aud_track`.
  - Stop puts the wave over the held picture.
  - The J1 buttons CONF_STR already lists (Pause as PLAYPAUSE, Prev / Next Chapter, Stop)
    and `umd/kbd_map.sv` (harvested; Space, P / PgUp, N / PgDn, Q / Esc, the arrows) drive
    it. `CONF_STR` is unchanged (P6b6).
- **Decided on the way:**
  - **Stop resumes by releasing the freeze, not by a seek** (ratified by the maintainer,
    2026-09-28; §2.3 planned a seek back to
    the stop point). The freeze holds the same picture and PTS, so the resume is exact and
    instant with nothing re-landed, and D5 is met as the maintainer stated it. A seek from
    pause resumes play.
  - **The item (D8a)**: `key_item` is the landed item. `item_unsure` rises once the reader
    starts a later item.
- **Gates:**
  - `run_player_ctl.sh --red`: 10 scenarios (nochap / multi / dup synthetic, Akira and Now
    That's What I Call Music, two seeds each), 17 mutations each caught by its own arm.
    `tools/player_ctl_ref.py` checks every burst's seek, every NO_CHAPTER and every settled
    chapter against `umd_nav_ref`. BADSYNC and PRESSSYNC put a reserved command or a press
    on the exact cycle of an answer.
  - `run_disp_sched.sh --red`: 7 new scenarios (pause, pausefld, seek, seekfrz, seeknoskip,
    mountin, stopout) and mutations D15-D24.
  - `run_av_sync.sh --red`: S7 (a 0.22 s pause mid-stream: frame starts at d = 24
    eighth-ticks before and after, no re-arm) and S8 (a pause before the STC runs: the
    pre-anchor discard holds), with M13 / M14.
  - `run_scaffold.sh --red`: `check_emu_wiring.py` pins the reset split and the transport
    seams, W45-W51.
- **Found by the benches** (all RTL, all fixed before the first fit):
  - The merge timer's reset was overridden by its own increment later in the block. Seeks
    went out 70 cycles after a press.
  - The event arbiter tested last cycle's push, so a sporadic event could overwrite an
    answer's.
  - A press queued in the cycle its burst's head was answered was lost: the pop's `pq_n`
    won. The queue now updates in one place.
  - After a watchdog the tracker asked with the key of the picture held BEFORE the
    landing, so it never updated. It now waits for the first new picture.
- **Known limitations:**
  - The multi-item key (D8a, until P6b3i). `item_unsure` reaches no instrument yet: P6b7
    (telemetry) and P6b5 (the HUD) wire it; the manual states the limitation.
  - "Pause" (the CONF_STR button's name) toggles pause and play until P6b6 relabels the
    buttons: the OSD's name for it is narrower than what it does.
  - `build_release.sh`'s manifest records the qsf's SEED when it packs, so a sweep's rbf
    says the old seed (the ledger has the right one). A tool fix, to do.
  - The track switch's silence (D7, accepted).
  - Two buttons pressed in the very same cycle: one wins.
  - `run_av_sync.sh`'s track-switch arm (the new track's pairs at their PTS) is not built.
    It needs a two-track golden from `av_sync_golden.py`: P6b7, before the rig's track
    gate.
  - `run_cosim.sh --seek` is unchanged. The decoder's side of the flush is P6b1's reset,
    already covered there.
- **Fit:**
  - SEED 9 first roll missed at -40 C: 86.35 / 83.33, binding on P4's `mv_pred` median.
    No P6b3 logic was in the top 60 clk_dec paths.
  - The sweep's first seed, **SEED 1**, passes: clk_dec 87.09 / 86.84 MHz, **33,213 ALM**
    (79 %, +1,061), M10K 401, DSP 76, `UMD_p6b3_20260928_0556.rbf`.
  - Where the area went: `player_ctl` 347 ALM and `kbd_map` 5. `umd_reader` went 2,699 ->
    3,280 now that its port is driven: this is P6b2's accepted cost, which the estimate put
    at ~+700 more. The rest is `disp_ctl` / `aud_out`'s transport.
  - Against §7, ~1.1K of the ~2.2K left for P6b3-P6b7 and the panel is now spent (33.2K of
    35K).
- **Rig** (2026-09-28, that build, stock Main + the HIL Main). The measurements use the
  telemetry's STC/16 word, which wraps every 11.65 s, so a landing is read by its offset
  from the chapter's PTS mod 2^20.
  - **Akira, regression:** 23.98 pictures/s, the judder gate equal, `av_err` +0.02 ms.
  - **Next Chapter** from 0:40: 4 s after the press, 3.36 s past chapter 2's start and
    advancing at 1.00 s/s. So the press-to-picture time is under 1 s, merge window
    included. The decoder restarted, one re-anchor, `av_err` +0.03 ms, errors 0.
  - **Pause 4.25 s:** the STC frozen, no pickup, no decode (back-pressure), two
    pixel-identical screenshots. On resume, `av_err` the same (2-3 ticks) and no re-anchor.
  - **Stop:** the idle wave over the picture and the STC frozen. Pause resumes with no
    re-anchor.
  - **Prev** more than 1 s into chapter 2 restarted it. **Next x2** in one ssh command made
    one seek (one re-anchor).
  - **Next into chapter 5** (its mark 1.068 s after its entry), then pause: the frozen STC
    says mark + 1.38 s, and the screenshot's best ffmpeg match is frame 58, exactly the
    frame due at that STC.
    - This shows the picture, the clock and the chapter agree.
    - It cannot separate "skipped to the mark" from "started at the entry and played 1 s
      longer": ssh timing is too coarse. The skip is proven in simulation (`mountin`,
      `seek`, D21-D23). The exact rig check needs the shown-PTS telemetry word (P6b7).
  - **Next + Prev** in one command landed 2.5 s past chapter 5's start: the Prev judged
    from the pending target (chapter 6's start, within 1 s of it), in one merged seek.
  - **Family Guy (field pairs):** Next landed (one re-anchor, `av_err` 2 ticks), pause gave
    pixel-identical shots, and on resume 2.000 refreshes a pickup, the judder gate equal,
    59.96 fields/s, `av_err` +0.01 ms, no re-arm.
  - Not measured yet: OUT on Hackers (it needs the whole film), the track switch (no button
    until P6b6), and a landing's exact PTS (P6b7).
- **Next:** the maintainer's review and merge of P6b3; then P6b3i (the item tag) or P6b4
  (FF / REW).

### P6b3i, as built (2026-09-28)

- **The tag (D8)** is the playlist item index mod 4. It is born in the reader and rides
  the PTS to the display:
  - `umd_reader`: a tag per cache slot, written when the sector is requested; every byte
    leaves with its sector's tag (`stream_ep`);
  - `ps_stream_fifo`: a `DW` parameter, 10 bits in `emu`;
  - `ps_demux`: `in_ep`, latched as `vid_ep` on the register that loads `vid_pts`, from
    the PES header's own byte, so it is exact by construction;
  - `vbuf`: the stamps carry it;
  - `vidfeed_cdc`: 44 bits;
  - `h264_top` / `au_pts`: a `VW` parameter, 35 in `h264_top`. The tag goes into the
    spare bits [2:1] of the `F_au_pts_hi` header word, so the syntax-element stream keeps
    its shape and every golden with the tag tied 0 is byte-identical;
  - `recon_hdr` -> `recon_top`'s `pinfo_ep` -> `recon_out`: both table halves hold it, and
    the record takes the tag of the half that carries the PTS;
  - `disp_ctl`.
  - A picture without a PTS inherits the current item. Every item's first picture is its
    entry's, which carries one.
- **The display's item table** replaces P6b3's single target and stop ports. It has 4
  entries {IN or a seek's target, OUT, last, skip}, written by `player_ctl`.
  - It starts all valid, with no skip and no OUT, so a mount's pictures never wait.
  - A resync's rising edge clears it.
  - A head whose tag differs from the current item enters that item: it waits until the
    item's entry is valid, then that entry's skip and OUT apply.
  - A record at or after its item's OUT is dropped unseen. The display ends only on the
    title's last item; otherwise the next item's records follow.
  - A rewrite of the current item without a skip (the watchdog's) ends a skip.
- **`player_ctl`:**
  - Every item start (the mount's, the walk's, a seek's landing) writes that item's entry
    and keeps tag -> item.
  - `key_item` is the shown picture's item: its tag, read at each pickup. `item_unsure` is
    gone.
  - **The hold** (`item_hold`, combinational): the reader may not start item j while the
    shown item is j - 4 or earlier. After a seek's landing it measures from the landed
    item, which shows next. It is lifted only while a seek waits for the reader or its
    landing is not yet known (a Go To must reach the reader). It is counted (`n_hold`).
  - It cannot deadlock: item j - 4's last pictures need only item j - 3's first picture to
    leave the DPB.
  - The chapter tracker judges a pickup by the new picture's item, and compares keys in
    order.
- **Gates:**
  - `run_player_ctl.sh --red`: 12 scenarios, adding `short` (ten 2 s items: the mock walk
    runs ahead and the display crosses items by itself; 14-47 holds a run). Now That's What
    I Call Music (30 items) holds 36-39 times a run, and every settled chapter matches
    `umd_nav_ref` across real item crossings.
    - New arms: `[key]` (after every pickup the transport's item is the one on screen) and
      `[hold]` (up exactly when the next item would be the fifth in flight).
    - `[land]` became "every item start writes its entry".
    - Mutations P18-P22.
  - `run_disp_sched.sh`: the `items` scenario (A cut at its OUT without ending, B opened at
    its IN and re-anchored, B's OUT ending the title), and every record carries a tag
    (`[xport]` scores the shown tag). D20 / D24 re-anchored, D25 / D26 new.
  - `run_recon_out.sh` U8, `run_ps_demux.sh` `[ep]` + D11, `run_vbuf.sh` V9,
    `run_h264_top.sh` `+ep_from_pts` + T4, `run_umd_reader.sh` (every byte's tag against
    its fixture region; `[hold]` driven at random) + N25 / N26, `run_scaffold.sh`
    W52-W54 with `check_emu_wiring.py` pinning the tag at every seam.
- **Found by the benches:**
  - The hold was one cycle late when registered: the walk tests it in the same cycle
    `item_idx` moves on, and the mock started a fifth item through it. It is combinational
    now.
  - Two aliasing holes around a seek. The hold was lifted for a whole landing, including
    the watchdog's 3 s wait, and after a watchdog it measured from the picture held before
    the seek. Both let the walk overwrite the landing's own tag.
  - The tracker lagged one picture at an item change, because it judged by the old item.
- **The rig found a hang** (My Chemical Romance disc 2, the first fit,
  `UMD_p6b3i_20260928_1030.rbf`).
  - Decode and pickups stopped about 1.5 s in, right after item 0's window, while the STC
    ran on. The raw telemetry: `vbuf_fill` 0, `ring_fill` 32,770 (full), 455 starved
    refreshes, `av_err` saturated.
  - The mechanism:
    1. The display now cuts item 0 at its OUT and re-anchors on item 1's clock (~1 s).
    2. Item 0's audio past OUT, stamped ~54 s on its own clip's clock, sat at the gate's
       head, 53 s "early". The gate waited.
    3. The full ring blocked the demux, and the video starved.
  - P6b3's build hid it by showing item 0's tail past OUT, which let that audio play out.
  - **The fix, two parts:**
    - **The audio carries the item tag too:** `ps_demux`'s `aud_frame_ep`, then
      `aud_ring`'s tags, then `aud_out`. `disp_ctl` keeps `left_mask`, the tags of the
      items it has left: set as it enters the next item, cleared when that tag's entry is
      rewritten or at a resync. `aud_out` discards a left item's frames at once, and one
      reaching RUN re-arms first (`n_left`).
    - **A stall breaker:** the STC runs, the head is early, the ring blocks the demux, the
      PCM FIFO is full, and the display has starved 64 refreshes in a row (`vid_stalled`).
      Then the gate yields audio from its stale end (`n_yield`). This is the running-STC
      sibling of the pre-anchor rule, so a hang is impossible by construction whatever put
      the audio early.
  - Benched:
    - `run_av_sync.sh` S9 (the display leaves the audio's item mid-stream: nothing plays
      after, every pair is a left discard) and S10 (the STC 10 s behind the audio, the
      picture stalled: the breaker yields). M15 / M16. `[drop]` exempts the two new
      discards, and `[yield]` fails any yield without a stall.
    - `run_disp_sched.sh` scores `left_mask` and `vid_stalled` at every refresh (D27 /
      D28).
    - `run_ps_demux.sh` `[ep]` checks the audio PTS's tag too (D12).
    - W55.
- **The rig then found the sound missing after the item change** (the same disc,
  `UMD_p6b3i_20260928_1336.rbf`).
  - The video ran on, but no audio played after the change. The new telemetry (below)
    showed the display right: shown tag 1, `left_mask` `0001`. Yet `a_left` climbed at the
    decoder's full rate: item 1's audio was arriving tagged 0.
  - The cause: my edit put `aud_ep <= 0` in `ps_demux`'s per-cycle default block, not its
    reset block. The tag lived one cycle after the audio PTS latched it, and was 0 by the
    time the ring read it at the PES's first byte.
  - `ps_demux_tb`'s `[ep]` arm could not see it: it checked the cycle after the latch, the
    one cycle such a tag is right. It now checks each tag where its consumer reads it (D13
    re-creates the bug and is caught).
  - `av_sync_tb` had tied the audio's tag to 0 from the demux to the gate. It now carries
    it as `emu` does (S11: every byte tagged 1 must reach the gate as 1; M17).
- **Telemetry pulled forward from P6b7** (the diagnosis needed it; 58 words, the HIL Main
  rebuilt):
  - `xport`: state, seeking, the shown item tag, the items left, stalled, the reader held,
    `nav_err`;
  - `chapter`, `seeks`, `holds`;
  - `sh_pts_lo` / `sh_pts_hi`: the shown picture's PTS, one latch, so a landing reads
    exactly and the STC/16 word's 11.65 s wrap is gone;
  - `a_left`, `a_yield`.
  - `run_telem.sh --red`: ALL GREEN. The bench's source array grew past 64 ports.
- **The rig discriminator for the tag itself** (the same disc):
  - Play into the concert (item 1) by itself, then press Next.
  - P6b3's build (the control arm) keyed the press by the landed item 0, and went back to
    the concert's start (chapter 2).
  - P6b3i's went to chapter 3 (3:16): 3.19 s past it 4.3 s after the press.
  - This is D8's exit on hardware.
- **The rig, with the audio tag fixed** (`UMD_p6b3i_20260928_1436.rbf`: the fixed netlist,
  SEED 1, 89.24 / 89.37; 2026-09-28):
  - My Chemical Romance disc 2, 20 s settled in the concert after the item change: audio
    decoded and played both 23.438 frames/s (the nominal rate), `av_err` 0.01 ms, nothing
    dropped. `a_left` stayed at 14,283 across the window: item 0's tail was discarded
    once, at the change. `a_yield` 0.
  - Akira, 20 s settled (the regression arm): 23.99 pickups/s, the judder gate equal,
    audio at the nominal rate, `a_left` / `a_yield` 0, errors 0.
  - Next, then paused Prev, on Akira: chapter 2 each time. The first picture read after the
    paused Prev was 15,547,942, the mark's 15,543,438 plus 4,504 ticks. That is three
    fields, exactly the next picture of the 3:2 cadence, and a seek from pause resumes
    play. A later reading sat exactly 224 frame periods past the mark, so the timeline is
    on the mark's grid.
  - **Not provable on the rig:** that the mark's own picture was shown. The HIL Main reads
    telemetry at 4 Hz and the mark's I picture is on screen 50 ms. `run_disp_sched.sh`
    scores the landing exactly. A rig check would need a latch of the first PTS shown after
    a resync (a P6b7 telemetry word).
  - **Found: a pause counts decode errors.** With the display frozen, it holds its stores,
    `recon_dpb`'s D_OPEN waits for a release, and every `STALL_LIMIT` (11M cycles, ~125 ms)
    of that wait counts `err_no_store` (code 6) and waits on. Nothing is decoded wrongly,
    but the HUD's `ERR` and `recon_err` climb ~8 a second through any pause: seen as
    1, 2, 4 errors of code 6 during the seek's freeze, cleared by the flush's reset. P5d
    meant the alarm for a display that never releases; a freeze is a legitimate hold.
    **Fixed** (folded into P6b3i by the maintainer, 2026-09-28): `disp_ctl`'s freeze
    (`ds_frz`) reaches `recon_dpb` through two clk_dec flops (`disp_frz`). The bound
    restarts while the display is frozen and runs from the release, so a display that
    never releases unfrozen still counts. `run_recon_top.sh` builds a second simulator
    with the bound at 20,000 cycles for two arms on r16's holds: r16f (frozen: a wait
    outlasts the bound, no error, `[frz]`) and r16a (unfrozen: the alarm counts code 6 and
    every picture is still exact, `[alarm]`). F1-F3, W56. Until then no bench's hold
    had ever outlasted the 11M-cycle bound, so the alarm itself had never been exercised.
    Fit `UMD_p6b3i_20260928_1606.rbf` (SEED 9, 90.79 / 90.44). On the rig: Akira paused
    ~20 s, then Next, with `recon_err` 0 throughout (the build before counted 1, 2, 4
    during a seek's freeze), and the resume's `av_err` unchanged.
- **The model found a scenario error of mine:** in `items`, the queue is in order, so B's
  records cannot arrive before A's dropped tail. A decoder emits that tail right behind
  A's last picture.
- **Known limitations:**
  - `recon_hdr`'s parse of `au_pts_hi` into `pinfo` has no bench below the rig. P5c's PTS
    parse there has the same gap; the reconstruction's fixtures carry no PTS words. A lost
    tag is visible on the rig (the transport's item stops following the picture).
  - The item boundary itself stays P8's handoff (D8): the decoder is not reset between
    items, and the new item's leading pictures are dropped by its IN. A short audio GAP at
    the change is D8's; a HANG was a bug (below), fixed here.
  - At an item change the previous item's last picture gets one refresh, not its full
    duration: the new item's first picture re-anchors at once, which is P5's rule for a
    timeline jump.

### D8, the handoff measured (2026-10-06, P8)

On .201 (`UMD_bare_20261005_1945.rbf`, the HIL Main, Disc Menus Off), Now That's What I Call Music
2006 (30 items, each a whole clip, IN 1.0 s): 430 s of telemetry on the target through the crossings
item 0 -> 1 (at 3:11) and 1 -> 2 (at 6:46), the stretches between them the control.

| per crossing | measured |
|---|---|
| picture | continuous: `starve` / `late` / `cadence` 0, 29.95-30.01 pictures/s and 59.9-60.0 refreshes/s through the 20 s around it, one display re-anchor (`sched`), `recon_err` 0 |
| sound dropped | ~0.1 s of the old item's end (`a_left` +5,067 / +4,859 pairs) and ~85 ms of the new item's start (`aud_drop` +4,080 / +4,090, stale against the re-anchored STC) |
| silence | ~40 / ~65 ms (the played-frame deficit over the 20 s around it, +/- a frame of sampling); `aud_rearm` 0; `av_err` 0-2 ticks after |

So the handoff costs only sound: at a cut between two music videos ~0.2 s of audio goes missing and
~50 ms is silent. **Inaudible on this disc** (the maintainer listened at 3:11, 2026-10-06): its clips
begin and end in digital silence -- decoded with `at3p_extract.py --wav`, clip 1's last 0.2 s and
clips 2 / 3's first 0.3 s are all zero samples, the music in by ~1 s -- so the dropped audio is
silence. My Chemical Romance disc 2 (its 1.5 s transition into the concert), listened to by the maintainer
on .236 the same day: the transition is silent too, and nothing is audibly missing from the
concert's start. **Closed as acceptable** (2026-10-06): the handoff stays a resync, not gapless; reopen
if a disc whose items join inside continuous sound shows an audible gap (the fix: `aud_out`
carrying its timeline across the item's PTS jump instead of resyncing).

**Found with it -- NOT a decoder fault, a telemetry bug (resolved 2026-10-07, ✅ MERGED PR fj#58, ✅ HW-CONFIRMED):**
`refused` and `warn` seemed to count one picture refused for its size and one output store dropped
at the title's start and at item starts of this title (never on Akira). An instrumented build
(`recon_top` latching the refused slice's view into four new telemetry words) read 1 in all four,
and `pdefer`, `refused`, `warn`, `subs` read the same value in every log: **every word from 63 on
read word 63.** `umd_telem`'s word counter was 6 bits and saturates at 63, while A11 (PR fj#40,
2026-10-03) had grown the table to 67 words -- so `refused`, `warn` and `subs` have read `pdefer`
on hardware ever since. `pdefer` (480i: a pickup deferred a field for field order) counts one at
each display anchor of a bottom-field-first title: the title's start and each item start here,
none on Akira's progressive film. Nothing was refused, nothing dropped.

Why no bench saw it: `telem_tb`'s expected / read arrays were `[0:63]`, so words 64-66 compared
out of range on both sides, `X !== X` false -- a bench that could not fail (and Icarus warned
"numeric constant truncated to 6 bits" on every label past 63). Fixed: the counter and the
generated labels are 7 bits (`telem_layout.py` WIDX, which refuses a table that does not fit),
the bench's arrays are sized from the table, `test_telem` checks the counter's width covers it,
and `run_telem.sh --red` arm T6 (the counter saturating at 63 again) is caught by [words].
✅ On the rig (2026-10-07, .236, `UMD_itemstart_20261007_0341.rbf`): across the title's start and two
Next presses into items 1 and 2, `refused`, `warn` and `subs` read 0 while `pdefer` counted its
anchors (1, then 2) -- each word its own value.

What the chase left behind, kept: the cosim feeds `h264_top`'s PES sideband (`es_mark` / `es_pts`
/ `es_ep`, `+marks=` from `cosim_golden.py --raw --marks`) -- `recon_hdr`'s PTS / item-tag parse
had no bench below the rig (§9's known limitation) -- and `[count]` fails on `recon_top`'s
`ref_size` (it scored no size refusal before). `cosim_golden.py` gained `--clip`, `--raw` (a clip
from its first byte, as the reader feeds an item's start), `--raw-from` / `--then-clip` (a
play-through item crossing) and `--no-oracle`. On this title: clips 1-3 from their first byte and
the crossing clip 1 -> 2 (no reset, the tag 0 then 1) bit-exact, no refusal, with and without the
sideband, under long holds and slow DDR3. At that crossing ffmpeg outputs 2 frames fewer than the
model (`--no-oracle`): its own way of joining two clips; the model follows C.4.4. Both new checks have RED arms
(`run_cosim.sh --red`, ALL GREEN with them): C19 (a size refusal counted on every I slice, the decode
unchanged) caught by [count]; C20 (the PTS word sent as a NAL word) caught by [hang] on `akm`, a control
window fed the sideband (Akira's main title from its first byte, `--raw --marks`) -- the unmarked
windows cannot see it.

### P6b4, as built (2026-09-28)

The design is §2.6's "As built". The maintainer's answers are D9 (§8).

- **RTL.**
  - `player_ctl`: FF / REW (codes 10 / 11), the hop machine (`SK_HOP`), the exits, and
    `one_frame`, `tk_speed` and `tk_rev` out.
  - `h264_top`: `one_frame` (T_SINK).
  - `umd_reader`: a seek's clamp into [IN, OUT).
  - `emu`: the D-pad Right / Left, gated while the OSD is open (`OSD_STATUS`), with the
    keyboard's arrows ORed in; `one_frame` through two clk_dec flops; the telemetry's
    `trick` word ({speed, reverse, one_frame}; 59 words, the HIL Main rebuilt).
  - The display is unchanged: no untimed mode was needed.
- **Found on the way: a seek clamped to OUT showed nothing.** The clamp took a target at
  or past OUT to OUT itself. The lookup then lands on an entry AT OUT, which the
  display's OUT drops, or the skip drops the picture ending at OUT. Either way the 3 s
  watchdog followed.
  - None of the 120 items in the library's 88 images has OUT on an entry, and no mark
    lies at or past OUT. The format allows both, and P6c's Go To past an item's end, and
    trick play's reverse crossing, would reach it.
  - The clamp is now OUT - 1 in the reader and the model; the walk's own start is still
    IN. (`fix/skip-last-picture`, 2026-10-04: OUT - 4, since OUT - 1 lost an untagged last
    picture to the display skip's tolerance; and an END reached inside a skip now ends the
    display: `display.md` §11.)
- **Gates:**
  - `run_cosim.sh --trick`: Akira (frame) and Family Guy (field pair) bit-exact, and the
    **whole library: 88 of 88** images from a non-IDR entry. 64 entries are a frame I, 24
    a field pair; the first frame is emitted bit-exact and every picture after it is cut.
    `--red` C16-C18, with C1-C15 re-proven.
  - `run_player_ctl.sh --red`: every script carries trick runs, some random and six forced
    (both ends, a pause, all three speeds, the opposite arrow, and both crossings on a
    multi-item title). `player_ctl_ref.py` recomputes every hop's request from the carried
    target and the cycles spent at each speed (`umd_nav_ref.hop_request` / `hop_land`),
    and checks every exit's seek to the shown key. Coverage is required, never assumed:
    each script must reach both ends and the faster speeds, and a multi-item title must
    cross both ways.
    - New arms: `[trick]` (`one_frame` changes only at an accepting edge; audio in reset;
      the reader held; `HOP_MIN`; no TITLE_END); `[land]` (a hop's entry has no skip).
    - Mutations P23-P25 and P27-P35. P26 (TITLE_END's gate) was dropped: the gate cannot
      matter. The seek machine is idle on a hop's stream only while paused or stopped
      after trick play, when the display is frozen and takes no END, or for the one cycle
      before play's restoring seek.
    - The synthetic `nochap` title's IN is now PTS 0: reverse trick play finds that start
      by its request's saturation alone (P32).
    - A new synthetic title, `dense`, has a chapter every 3 s. Any hop crosses one, so a
      press during trick play keyed from the hop's target rather than the picture shown
      lands a chapter off (P35). On the other titles that mutation survived: random timing
      rarely put a mark between the two keys.
    - Found in the bench: an injected command (PRESSSYNC / BADSYNC) landing in the cycle of
      a scripted one was logged although only one reached the DUT. It now yields to the
      scripted one.
  - `run_disp_sched.sh` `trick`: four hops (one a field pair) and the restore, identical
    to the model at every refresh. D29 (an entry's no-skip ignored) is caught.
  - `run_umd_reader.sh`: all synthetic cases and 88 disc images with the new clamp; N27.
  - `test_umd_nav_ref.py` + 4 RED; `run_scaffold.sh --red` (W57 / W58 through the runner);
    `run_telem.sh`.
  - Re-proven on the changed RTL: `run_umd_reader.sh --red` (all 42 mutations, N27 among
    them); `run_disp_sched.sh` (all 25 scenarios, D29 through the runner);
    `run_player_ctl.sh --red` (34 mutations); `run_h264_top.sh`, `run_p3_chain.sh`,
    `tools/tests`. The decoder's gate `run_cosim.sh --sample`: 6 of 6 bit-exact over 300
    frames, each window's real-time factor unchanged (The Office Disc 01 1.35x).
- **Fit** `UMD_p6b4_20260929_0249.rbf` (SEED 9, first roll): clk_dec 90.42 / 89.37 MHz,
  **33,847 ALM** (81 %, +274), M10K 403, DSP 76, every gate PASS.
  - `player_ctl` went from 347 to 962 ALM. That is the 48-bit target arithmetic (the add,
    the subtract, the edge compares against the request), the carried target and the
    request registers, and the exits. The plan's 200-400 was for the whole stage; the
    core's net is +274 (the fitter placed the rest tighter).
  - Against §7, ~1.15K ALM now remains under 35K for P6b5-P6b7 and the panel. P6b5 is
    capped at ~800. **Decided (the maintainer, 2026-09-29): `player_ctl` is not trimmed.**
- **Rig** (2026-09-28, that build, the HIL Main; telemetry sampled on the target at 4 Hz):
  - **Akira, forward:** Forward 1 / 2 / 3 at 20.1x / 33.1x / 55.0x of content (the PSP's
    20 / 33 / 55), about 8 hops a second (the `HOP_MIN` floor). The chapter followed the
    pictures (8 -> 14). ← returned to play at 1.0x, `av_err` 0-2 ticks. Errors 0.
  - **Akira, reverse:** 20.1x / 33.3x / 54.9x into the title's start (PTS 90000, its IN),
    where play resumed by itself at 1.0x, `av_err` 3 ticks. The screenshot mid-rewind is a
    clean picture; the HUD's `P4 PIC 000001` is one picture decoded a hop.
  - **Family Guy (field pairs):** FF1 at 20.1x; Stop held the picture (state STOP,
    `one_frame` kept) and Pause resumed play from it at 1.0x. A Next Chapter press during
    FF landed on chapter 2's mark (24,507,393, `umd_nav_ref`'s). FF2 at 32.6x, then Pause
    to play. `av_err` <= 2 ticks, errors 0.
  - **My Chemical Romance disc 2 (three items):** FF3 through the 2 h concert at 55.0x
    (138 s), across into item 2 (the shown tag 1 -> 2), to the title's end. Play resumed
    from item 2's last I, and the trailer's last half second played out. The title ended
    before OUT (reader done, `FLUSH 1`). REW1 from there went to item 2's IN, crossed back
    to the concert's end and ran at 20.0x; Pause returned to play. Errors 0 throughout,
    `av_err` <= 1 tick.
  - **The OSD gate:** with the OSD open two Right presses did nothing (seeks 0); closed,
    one started Forward 1. The harness presses KEYBOARD arrows, which Main keeps for its
    menu while the OSD is open, so this proves that path. The joystick's gate on
    `OSD_STATUS` is pinned by `check_emu_wiring` (W58), not measured with a pad.
- **Known limitations:**
  - A stream whose next picture opens with no access-unit opener is not cut: it decodes on
    (§2.6). Every disc access unit has an AUD.
  - The overshoot is dropped at an item crossing (no durations known), so the rate dips at
    each crossing. On Now That's What I Call Music (30 items) that is one hop in each item.
  - A hop that crosses into an item lands at the entry at or before its IN. With no skip,
    that entry's I may be from up to 1.97 s before IN, outside the item: one picture of the
    clip's transition on My Chemical Romance's short item 0.
  - The Display overlay (the time, the chapter, the speed badge) is P6b5. Until then the
    speed is visible in telemetry only.
  - The only pause button today (`Pause`, PLAYPAUSE) resumes play from trick play. The
    PSP's × (PAUSE, freeze on the picture) arrives with P6b6's buttons; the command
    exists and is benched. (Since fj#57, PAUSE during trick play resumes play, as the PSP's ×
    does: D9.)
- **Next:** P6b5, the HUD (mockups first).

### P6b7, as built (2026-09-29)

- **Telemetry (63 words; `hil_harness.md` "Telemetry").** Most of §5's list was pulled
  forward in P6b3i / P6b4 (state, the shown PTS, the chapter, seeks, holds, nav errors,
  trick play). What P6b7 adds is what a landing needs to be read exactly:
  - `land_lo` / `land_hi`: `player_ctl`'s `land_pts`, the first picture a landing shows (a
    seek's, a hop's, the watchdog's late one, the mount's). P6b3i's rig round could not
    see the mark's own picture at 4 Hz (it is on screen 50 ms); this latch holds it.
  - `seek_lat`: 90 kHz ticks from the seek machine leaving idle (a press's query, the
    merge window included; a Go To's seek; a trick exit's restoring seek) to that
    picture, for a play landing (not a hop). The press itself is one tracker query
    earlier at most (microseconds in the reader).
  - `landing`: the watchdogs (`n_wd`, wired nowhere until now) and, since the last landing
    (the decoder's pipe reset), the recovery-point start: leading pictures skipped,
    pictures before the first I, a non-IDR start, an MMCO naming a pre-entry picture
    (`recon_dpb`'s `rp_*`, saturated at 7 on clk_dec and crossed in `rc_snap`).
  - `trick` [11:8]: the transport HUD's Display, and the title's placeholder / malformed /
    cut flags (D6's "flagged").
  - Not atomic: `land_*` moves only at a landing, so a read torn inside the ~100 µs
    transaction is corrected by the next poll (32 latch bits saved).
- **Gates:**
  - `run_player_ctl.sh --red`: `[landpts]` (every landing's first picture, the mock
    display's target, which `[land]` and the model tie to `umd_nav_ref`; it holds between
    landings) and `[lat]` (the latency equals the bench's own count from the seek machine
    leaving idle, for every play landing; it holds across hops and watchdogs). P36-P39.
  - `run_scaffold.sh --red`: `check_emu_wiring` pins `t_land` / `t_slat` / `t_wd` to
    `player_ctl`, `t_hud` to `transport_hud` in the table's bit order, and the four
    recovery-point words to `cdc_snap` copies (W64-W66).
  - `run_telem.sh --red`: 63 words.
  - **`run_av_sync.sh` S12, the track switch** (P6b3's open item): Akira clip 1's own packs
    with both tracks, a 2 KB ring, two frames of track 0, then the switch as `player_ctl`
    makes it; track 1 from the AU the new chain takes (found by its PTS), at its PTS
    (`[start]` / `[sync]`), frames 1-2 bit-exact with the golden decoded cold from that AU.
    M18 (an old-track payload kept through the realign), M19 (the new track forwarded
    mid-AU). It found two things:
    - **A reset does not make the ATRAC3plus decoder cold**: frame 0 after a switch or a
      seek blends ~21 ms of the old stream's overlap tail, frame 1 is within 1 LSB of a
      cold decode, frame 2 exact. ffmpeg's decoder does the same (no `.flush`): recorded
      in `at3p_decoder.md` §8, not changed. S12 times frame 0 and holds frames 1-2 to 4 LSB.
    - **An old-track byte entered the new chain**: `player_ctl` released the audio chain's
      reset in the cycle it pulsed the demux's realign, and the one byte the demux had on
      its output that cycle went into the fresh ring (the framer slid 1 byte). **Fixed:**
      the track and the realign now come in the reset's LAST cycle, the release the cycle
      after; `player_ctl_tb`'s `[audio]` pins it (P42), S12's `[count]` sees 0 slides. On
      the rig (the fixed build): two switches on Akira, 0 slides, 0 refusals.
- **Tools:**
  - `mister.py seq`: presses, marks, shots and the telemetry sampled ON the target in one
    timebase (`hil_harness.md`).
  - `tools/rig_gates.py`: the §6 gates as sequences, scored against `umd_nav_ref`
    (chapters, trick, pause, track, inout, film).
  - `build_release.sh` / `seed_sweep.sh`: a swept build's manifest records the seed and the
    area of the fit that built it (`BUILD_SEED`; the sweep keeps the fit summary with its
    `.sof` / `.sta.rpt` pair). P6b3's known limitation.
- **Fits** (SEED 9, first roll each, every gate PASS):
  - `UMD_p6b7_20260929_1608.rbf`: the telemetry; clk_dec 87.15 / 88.09, 34,865 ALM. The
    rig gates below ran on it.
  - `UMD_p6b7fix_20260929_1721.rbf`: + the chapter fix and the hop race; 87.64 / 86.69,
    34,987 ALM.
  - **`UMD_p6b7b_20260929_1758.rbf`** (the branch's build): + the switch's realign;
    **clk_dec 88.44 / 89.57 MHz, 34,945 ALM** (83 %, +131 on P6b6), M10K 419. **55 ALM
    remain under 35K**; P6c's budget is planned with the maintainer before it starts (§7).
- **§6's "seeks to random targets" without Go To.** Go To is P6c and inert, so a seek to a
  chosen time has no user input yet. The gate uses what exists: Next / Prev bursts from
  random points in the title (each a seek to a chapter's key, D2's exact landing, scored
  against the model) and FF / REW exits (a seek to the last hop's I, exact by
  construction). Random-time seeks come with P6c's Go To.
- **Hackers' OUT without playing the film:** FF 3 (55x) to about a minute before the
  title's end, then play through the end.
- **The Phase 6 gate, a whole film: ❌ FAIL** (Akira, `UMD_p6b7b`, 2026-09-29, 7,735 s of
  telemetry at 4 Hz, a pause and a chapter jump in the first two minutes;
  `.sim/rig/film_akira_163244.jsonl`). The title played to its end (END taken, the last
  picture shown, no hang), `av_err` 0-1 tick throughout **except at three points of the
  film, 3,352 s, 3,888 s and 6,758 s**, where the same sequence happens each time:
  1. the decoder waits more than 122 ms for a store (`recon_dpb`'s STALL_LIMIT: error code 6,
     `err_no_store`) -- the display released none in that time;
  2. in that 0.25 s sample the display took 3 pictures instead of 6 while the shown PTS
     advanced a full 0.25 s: three pictures held about twice their duration;
  3. ~0.7 s later the display re-anchors its timeline ~83 ms BACKWARDS (a tagged head more
     than a frame behind the timeline), and the audio's gate re-arms on the STC's step
     (`av_err` read -9,009 ticks, -100 ms, in one sample, then 0-1 again).
  What is known:
  - **Deterministic, driven by the content**: FF to 30 s before each point and play
    through it reproduces all three at the same PTS (`.sim/rig/repro_akira.jsonl`).
  - **No PTS discontinuity** there (the PES PTS run on, no jump over 1 s or backwards).
  - **The decoder is right**: `run_cosim.sh`'s harness over 3,344-3,361.5 s
    (`cosim_golden.py --at 0.4448 --ep-start --frames 420`): every picture bit-exact, 420
    stores emitted in the model's order, no error, 1.96x real time. Its "display"
    releases every store within 5,000 cycles, so it cannot see a paced display's holds.
  - **At each point the output order needs three pictures decoded in a row before the
    next store is emitted** (the model's `.out`: stores 223 and 224 emitted at steps 225 /
    226, then 225 only at step 229; decode order "P P I B" after an alternating B P run):
    the display gets nothing new while the decoder needs three free stores.
  - So the durations or times the display gives those pictures look wrong, not the
    decode. P5g saw two unexplained re-anchors on Family Guy's whole title at stream edit
    points (`display.md` §9 P5g row: "inferred, not proven"): possibly the same defect.
    `run_disp_sched.sh` plays only synthetic records, which is why no bench saw it.
  - **Next (its own branch, the maintainer 2026-09-29):** a real-disc record model -- each
    store's PTS (the P5c position rule), pic_struct and output order from the model --
    through `disp_sched_ref.simulate` over this window; compared with the RTL's records
    (`recon_out`, the scheduler) it says whether the stream's timing or the display's use
    of it is wrong. Then the fix, a disc-record scenario in `run_disp_sched.sh`, and the
    film gate again.
  - **Resolved on `fix/film-timing` (2026-09-29; `display.md` §10.6-§10.8):** the stream's
    timing is wrong, not the RTL. A single PES PTS 7-8 ticks late at each point, with the
    next tag back on the old timeline. The census found 208 such lone PTS on 73 of 88 images
    (Family Guy's two P5g re-anchors among them). The display now disbelieves a lone PTS
    ahead of the timeline (the maintainer's rule A). The "three pictures decoded in a row"
    above was a symptom, not the cause: the decoder was waiting on a display holding for
    the late tag.
  - ✅ **The film gate rerun PASSES** (2026-09-29, `UMD_filmtime_20260930_0009.rbf` on .201:
    errors 0, `av_err` 0 .. 2 ticks over the whole title, END taken, 3 lone PTS
    disbelieved, no re-anchor but the start and the chapter jump; `display.md` §10.7).
- **The HUD gate** stands from P6b5 (every state against the mockups on the rig,
  `transport_hud.md` §6.7): `transport_hud.sv` is unchanged here.
- **The rig logs** (`.sim/rig/*.jsonl`) live on the workstation only. The defect's repro is
  ~5 min of rig time: FF 3 to 30 s before each point, play through it, `until` on
  `sh_pts_hi` (the `mister.py seq` line is in this branch's session; the positions above).
- **Known limitations:**
  - The film gate's defect (above): ✅ fixed (`fix/film-timing`, MERGED PR fj#25), the gate passes. The two
    lone PTS BEHIND the timeline in the library (The Simpsons Movie, The Transporter) are
    disbelieved too since rule B (`fix/lone-early`, `display.md` §10.9).
  - A trick-play exit's landing is proven exact in the bench only: at 4 Hz the rig sees it
    within one hop of the last sampled one.
  - No seek to a chosen time until P6c's Go To; `seek_lat` then counts from its seek.
  - `seek_lat` starts when the seek machine leaves idle, not at the press (at most one
    tracker query earlier).
  - After a seek or a track switch the first audio frame carries ~21 ms of the old stream's
    overlap tail (the decoder is not cold after a reset; ffmpeg's is not either):
    `at3p_decoder.md` §8.
  - 55 ALM remain under 35K.
- **The rig gates (§6), 2026-09-29, `UMD_p6b7_20260929_1608.rbf`** (the HIL Main; every gate
  a `tools/rig_gates.py` run, its log in `.sim/rig/`). Errors, front-end errors and
  watchdogs 0 in every run.
  - **Chapters** (Next, Prev, a Prev pair inside the merge window, from random points;
    each landing's `land_pts` against `umd_nav_ref`'s target): Akira 10 bursts, Ghost in
    the Shell 2.0 10, Now That's What I Call Music 2006 10 (across items: the tag follows
    every landing), X-Men 2, The Rock, Astro Boy. **Every landing exact (D2)**: the shown
    picture is the target's or the one containing it (3:2 film: up to 3,004 ticks before
    the mark). `av_err` <= 2 ticks 3 s after each landing. Press-to-picture 570-1,450 ms,
    mean ~650 (the merge window's 500 ms is in it; a Prev pair ~830). Astro Boy's second
    chapter lies 0.17 s before OUT: the title ends at the landing, rightly.
    - **Found: a one-picture flicker to the previous chapter** (Akira chapters 5 and 6,
      Ghost in the Shell 3, The Rock 3): the landing's picture begins before its mark, and
      the tracker ranked it by its PTS, so the Display overlay read "Chapter 6 -> 5 -> 6".
      `player_ctl_tb`'s mock always landed on the target itself, so no arm could see it.
      **Fixed** (`player_ctl`: after a chapter press's landing the tracker's first answer
      may not lower the projected chapter; a Go To is exempt), the mock now starts such a
      picture up to one picture early, `[proj]` / P40. The new timing also exposed a hop
      issued in the cycle a PLAY arrived (one extra hop before the exit): fixed, P41.
      **Re-checked on `UMD_p6b7b`** with the same seeds: Akira, The Rock and Ghost in the
      Shell PASS, every landing's chapter word the target's (Akira chapters 5 and 6 land
      1,502 / 3,004 ticks before their marks and read 5 / 6).
  - **Trick play**, Display on: Akira 20.0 / 33.0 / 55.0x forward, 20.1 / 33.1 / 55.0x
    reverse; Ghost in the Shell 20.0 / 33.0 / 54.8x, 20.2 / 33.0 / 54.9x. Every exit lands
    on an EP entry within one hop of the last sampled hop picture (4 Hz cannot say which
    hop was last; `run_player_ctl.sh` proves it exact), 106-167 ms from the press; REW 3
    into the title's start resumes play by itself. On Ghost in the Shell the `landing` word
    shows non-IDR starts, some with one leading picture skipped, and play resumes clean.
  - **Pause** (Family Guy, 3 x 10 s): the STC, the picture and the pickups held; `av_err`
    1 -> 1 tick; no re-arm, no re-anchor.
  - **Track** (Akira, both tracks in turn): 2.00-2.04 s of silence (D7), then 23.47
    frames/s, `av_err` 1 tick; the diagnostic HUD's `AUD` row shows track 1 then 0.
    Audibility is the maintainer's to hear.
  - **IN / OUT:** My Chemical Romance disc 2 shows item 0 only inside [IN, OUT)
    (5,020,926 .. 5,141,046 of 5,005,911 .. 5,144,049), the concert, then the trailer, and
    ends 0.03 s before the last OUT. **Hackers ends at its OUT** (the last picture 4 ticks
    before it; the clip runs 436 s further), END taken.

### fj#57, × during FF / REW plays (2026-10-07, ✅ MERGED PR fj#62)

- **The report** (the maintainer, 2026-10-06, issue fj#57): Select/Pause (the PSP's ×,
  `PAUSE`) during FF / REW paused on the picture shown. The PSP's × ends the scrubbing and
  plays at normal speed from there, as the opposite arrow does. D9 is revised so (§8).
- **The fix**, in `player_ctl` (not in `emu`'s button map, so every `PAUSE` issuer agrees: the
  button and the control panel's Pause item, which injects that button; the disc menus' host
  never sends `PAUSE`): `C_PAUSE` during trick play asks `EX_PLAY`, the same exit as `PLAY` /
  `PLAYPAUSE` / the opposite arrow -- the seek to the shown key. `EX_PAUSE` is gone (its code
  3'd2 left unused); `STOP` still holds the I until the next `PLAY`. Outside trick play
  `PAUSE` is unchanged.
- **The model** (`player_ctl_ref.py`): `PAUSE` in trick play expects the restoring seek at
  once; only `STOP` is held. Every script runs a `pause` exit and (new) a forced `stop` exit,
  and the before-the-first-hop exit draws `PAUSE` too.
- **Bench:** `run_player_ctl.sh` P65 (`PAUSE` holding the picture, as a stop) -> `[model]`.
  **It first SURVIVED:** the model claimed seeks in order only, so a restore the DUT held made
  its seek at the next PLAY, still before the next request, and matched. The model now bounds
  every restore's seek to `RESTORE_MAX` (3 x `MERGE` = 6,000 cycles) after the restore is
  asked; the GREEN scripts need at most 2,470 (a burst's merge window and the seek), the
  held mutant 19,000 or more. `run_player_ctl.sh --red` ALL GREEN (the 14 scenarios, the host
  modes, the bare bench; 77 of 77 mutations caught by their own arm). G7's arm is now
  `[model]|[land]`: its mutant can never send a TIME past the end, so the tb's coverage check
  fails first -- on `main` too (checked), a stale label, not this change.
- **Fit** (pinned SEED 3): clk_dec 92.64 / 90.79 MHz, 39,345 ALM (94 %),
  `UMD_pausetrick_20261007_1549.rbf`.
- **✅ HW-CONFIRMED on .236** (Akira, `mister.py seq`, telemetry): Forward 1 -> 2 (258 s), then
  Select/Pause: state PLAY, speed 0, one restoring seek (71 -> 72), pickups at 23.6 / s, the
  picture clean; `av_err` 2 ticks, errors 0. Controls: Select/Pause in normal play still pauses
  (a second press stays paused, Play/Pause goes on); Stop during Reverse 1 holds the picture
  (state STOP, one pickup) and Play/Pause resumes from it by its seek.
  The tb's `[freeze]` check needed no change: it skips a command taken while `seeking`, which
  `SK_HOP` is.
- **The panel:** its Pause item, opened over FF / REW, resumes play too (its items are the
  buttons, `panel.md`): kept so (the maintainer, 2026-10-07).

### Select: the x button is Play/Pause (2026-10-07, the maintainer; ✅ MERGED PR fj#75)

- **The decision:** the J1 list's B2, "Select/Pause", is renamed **Select**, and in playback it
  does what Play/Pause does: pause, press again to play. It was `PAUSE` (a second press did
  nothing, Play/Pause went on). Its menu role (the PSP's x, P9) and Go To's confirm are unchanged:
  those take the button before the transport (the host's grab, `gt_take`).
- **Where:** `emu`'s button map, `btn_cmd[5]` -> `4'd1` (PLAYPAUSE), not `player_ctl`: `PAUSE`
  (code 2) stays a pure pause for the host's commands. `check_emu_wiring.py` pins the code and
  the J1 name.
- **What comes with PLAYPAUSE, decided with it:** from STOP, Select plays from where it
  stopped (the disc screen's Play line too: `umd_menu_run.c` keys its resume and R5f's relaunch on
  the state leaving STOP, not on the button); during FF / REW it plays, as fj#57 made `PAUSE` do.
- **The panel's Pause item** injected the x button's press (F1); it is now HOST_WR's `PAUSE`
  command (code 2, `umd_panel.c`, `panel_ref.py`, `panel.md` F1), so it stays a pause on a paused
  title (K7 offers it while paused). `run_panel.sh` [run] checks the command.
- **The harness:** `mister.py`'s key names come from CONF_STR: `key select/pause` is now
  `key select` (`rig_gates.py`'s pause gates: Select then Play/Pause still pause, then resume).
- **The name:** "Select" is also the pad's own Select button, Audio's default (D4); the manual's
  controls table says which is which.
- **Fit** (pinned SEED 3): clk_dec 88.62 / 88.29 MHz, 39,566 ALM (94 %), `UMD_select_20261008_0102.rbf`.
- **✅ HW-CONFIRMED on .201 (2026-10-08)** (Akira, Disc Menus Off, the UMD Main from 0859c11; `mister.py seq`,
  telemetry `xport` state and pickups): Select PLAY -> PAUSE (pickups stop) -> PLAY (22 / s) -> PAUSE, then
  Play/Pause plays; Stop, then Select: PLAY from the stopped place (the disc screen's "> Resume 0:00:45",
  no seek: the freeze released); Forward 1, then Select: normal play (one restoring seek). The panel's Pause
  on a paused title twice: stays PAUSE (0 pickups); after Play/Pause, the panel's Pause pauses. Errors 0.

## 10. Lessons carried in (MiSTer_DVD, surveyed 2026-09-27)

- **Every partial flush was a permanent A/V error on the rig.** Flush the trio together
  (§2.1).
- **The stale PTS tag.** Clear the tags on flush, and anchor only on post-flush records.
- **Pause freezes the display, both clocks and the audio together.** Freezing only the
  display drifts.
- **The gesture state lives on the core reset**, not the pipeline reset. Latch the base
  once, and never resolve against a table the flush is still refilling.
- **A landing must be a clean start.** DVD's landing between recovery points left a
  permanent 1 s audio lead. Here every entry is a recovery point, and §2.2 is what
  makes the start clean.
- **No flush per trick-play hop in DVD's pipeline** (black, watchdogs). Here a hop IS a
  seek's whole flush, `ddr_mux2`'s abort included (P6b1 made the decoder's quiesce the
  mount's reset). The cosim's trick arm and the rig prove it is cheap: the decoder is idle
  between hops, since each hop's stream ends after one frame.
- **The transport logic is a module with a bench**, not `emu` glue.
- **Anchor the HUD to the active picture window**, and check the instrument does not
  hard-code the answer (DVD's test instrument hard-coded X0).

**P7c found a P6b3 defect (2026-09-30, `subtitles.md` §7): a seek reset a chosen audio track.**
`player_ctl`'s audio default ("the lowest declared track, when the clip does not declare the
current one") was judged every cycle; `umd_reader` clears `aud_present` at every CLP header and
fills it stream by stream before the item start, so a seek's CLP re-read put a chosen track back
to the lowest whenever its bit came later in the CLP. P6b7's gate stepped Akira's tracks without
a seek between them and could not see it. Rig (control arm, the unfixed build): `AUD 1/0003`
before a chapter jump, `AUD 0/0003` after; fixed (judged at `rd_item_start` only): `AUD 1/0003`
through two jumps. `run_player_ctl.sh`'s mock reader models the transient now (P48 its RED arm).

