# Bare stream files: `.MPS` (roadmap P8; `.PMF` out of scope)

**Status:** ✅ MERGED (PR fj#48), ✅ HW-CONFIRMED (2026-10-05, §4b): a bare `.MPS` is
offered in the OSD and plays. **`.PMF` is out of scope** (the maintainer, 2026-10-05, after the
census: its audio is 44.1 kHz on every game file). The fabric path that reads one stays as built
and benched (§3, B4 below) but is not offered, documented to users, or developed further.
Decisions taken with the maintainer 2026-10-05: play-only first (B1), `.MPS` now (B2), small
pictures placed later (B3); **B4: `.PMF` dropped from the scope -- docs and roadmap only, the
fabric path kept** (it costs little, is tested, and a `.PMF` mounted by path still shows its
picture; removing it would cost a refit and a rig round for ~50-100 ALM).

## 1. What the files are

- **A bare `.MPS`** is a UMD Video clip's `STREAM/NNNNN.MPS` taken out of its image: the MPEG-2
  program stream of `umd_video_format.md` "The stream", 2048-byte packs from byte 0. No CLP
  comes with it (no stream table, no EP map), no playlist (no IN / OUT, no marks).
- **A `.PMF`** is the same program stream behind a **PSMF header** (PSP game cutscenes; the
  XMB's `ICON1.PMF` on discs and in games). Layout from JPCSP (`scePsmf.java` `PSMFHeader`,
  `sceMpeg.java` `analyseMpeg`), checked against the library's 65 `ICON1.PMF` and the census
  below. Big-endian:

| Offset | Field |
|---|---|
| 0x00 | `"PSMF"` |
| 0x04 | version, ASCII: `0012` / `0013` / `0014` / `0015` seen |
| 0x08 | u32 the stream's byte offset in the file (0x800 on 2,596 files, 0x1000 on 5) |
| 0x0C | u32 the stream's size in bytes |
| 0x54 | u48 the first PTS (90000 on every file) |
| 0x5A | u48 the last PTS |
| 0x80 | u16 the stream count |
| 0x82 + 16 i | a stream entry: `u8 id, u8 sub`, then for video `u32 EP offset, u32 EP count, u8 width/16, u8 height/16`, for audio `channels, a rate code` at +14 / +15 |

JPCSP validates the offset (non-zero, 2048-aligned) and the size (2048-aligned). The EP
entries are 10 bytes (`u8, u8, u32 PTS, u32 offset in 2048-byte packets`), the CLP's entry size
but a different meaning in the first two bytes.

## 2. The census (`tools/pmf_census.py`, 2026-10-05)

Every `.PMF` inside the maintainer's 150 PSP game images (`.cso`, read through `tools/cso.py`)
and the 88 UMD Video images. Video measured by ffmpeg's `trace_headers` over the first 600
packs, audio by its ATRAC3plus decode of every track's sample. 2,601 files measured in 185
images (2,536 in 120 games, 65 `ICON1.PMF` on discs); 94 files of one game lie past its image's
end (a trimmed rip) and one image is not ISO 9660: counted, not measured.

| | measured |
|---|---|
| video | **all Main (77), Level 2.1, CABAC**, `frame_mbs_only` 1 (no field pictures), no cropping; POC type 2 on 2,553, 0 on 48; weighted P prediction on 201; no decode error |
| coded size | 480x272 2,169 · 144x80 190 · 240x272 123 · 480x224 46 · 160x160 43 · 320x240 30 |
| streams | `0xE0` always; 9 files carry four more video streams (`0xE1`-`0xE4`); up to 7 audio substreams (`bd00`-`bd06`); 433 game files have no audio |
| audio | **every one of 4,139 tracks 44.1 kHz** (the params word's rate index 1; ffmpeg agrees on each); 6 mono, all XMB icon loops |
| header | first PTS 90000 on all; the stream size agrees with the file on all; EP map non-empty on 396 game files |
| stream | byte accounting exact on all (`psmf_ref`); a pack header at the stream's start on all; 0xBF index packs on all |

The disc limits hold for the **video** (the decoder takes Main / CABAC / frames / any size up to
128 MBs wide; POC type 2 is conformance-tested). They do **not** hold for the **audio**: the
fabric decodes 48 kHz stereo only and refuses any other frame as silence (`at3p.uasm`
`E_RATE`, counted in telemetry's `refused`). Hence §5.

**The sniff's precondition** (`pmf_census.py --sector0`): sector 0 of all 88 library images
starts with neither `00 00 01 BA` nor `PSMF` (an ISO's sector 0 is its system area, zero on
UMD).

## 3. Design

**Detection: the content, not the extension.** `umd_reader` reads sector 0 first (`S_INIT` ->
`S_SNIFF`): a pack header is a bare `.MPS`, `PSMF` a `.PMF`, anything else an image walked as
before (LBA 16 next). The sniff precedes the image's 17-sector minimum (`E_SMALL`): an 8-sector
`.MPS` is a stream. The extension index hps_io receives was rejected: the HIL's `umd_ctl mount`
sends none (a stale index) and an MGL's is the list position, so it says nothing the bytes do not.

**One item, through the image walk's own `.MPS` state.** The sniff hands the file to `S_MPS` as a
one-extent file (the whole file; a `.PMF` skips its header there with `S_MPS`'s own skip counter
and stops at its header's size with the item's stop counter, `clip_lim` / `clip_left`), then
`S_STREAM` and `S_ITEM` end the title as ever (`S_DRAIN`, `title_done`). The item is what the
mount resets: one playlist of one item, IN 90000 (a CLP's start PTS, always; JPCSP's PSMF
validity rule, and every census file's first PTS) -- the HUD's time origin only --, OUT at the end
of time (the END record ends the title), no duration known (`pl_dur` 0: the bar stays empty, the
total reads 0:00:00). `ep_flags[0]` (no map). `player_ctl` writes the item's display entry with no
skip (the reader leaves `nav_skip` unwritten), so the display drops nothing. The CLP-shaped
outputs (clip name, PTS range, stream counts, attributes, EP-map offset) are left as they were:
`emu` does not connect them. `pmf_warn` when the header's size disagrees with the file (never in
the census).

**Area (measured, `tools/synth_unit.sh` on the reader with only the outputs `emu` connects):** the
first version, a sniff plus a state that wrote ~40 registers, cost **+907 LUTs** (+899 ALM in the
fit, 95 %). A new state arm costs a mux input on every bit it writes, reachable or not (a variant
with the bare states unreachable was still +478). As built -- constants at the mount (an image's
walk overwrites each), the file through `S_MPS`, a PSMF's offset through its skip counter, no new
wide adder -- it is **+327 LUTs** (6,357 vs `main`'s 6,030).

**Refused loudly** (`E_BARE`, code 12): a PSMF stream offset of 0, not 2048-aligned, or at or past
the file's end (JPCSP's own checks); a bare file of 4 GB or more (`S_MPS`'s extent is u32 bytes; a
UMD clip is under 1.8 GB). On screen: "This disc cannot be played." (the reader-error path, A11).

**No seek.** Neither file type gives a usable map (an `.MPS` has none; the game PMFs' are empty on
2,140 of 2,536). `player_ctl` (input `bare`) answers FF / REW, SEEK, TIME (Go To) and PLAYLIST
with an UNAVAIL event -- the HUD's "Not available for this file." -- and issues nothing: its own
seek sequence flushes the pipe, so the gate must sit there, not only in the reader. The reader
refuses them too (NE_NOMAP, nothing flushed). Chapter presses query as ever and find none
(NO_CHAPTER).

**Tracks from the stream.** No CLP declares them: `emu` ORs in the substreams the demux meets
(`ps_demux`'s audio tap, and a subtitle tap added for this), from the mount. `player_ctl` judges
its default track every cycle on a bare title (at an item start on an image: the CLP transient,
P7): the mask only grows, so a choice stays. No language: the HUD's tag shows the number (`emu`
feeds two spaces).

**Telemetry:** the `reader` word's spare bits carry the mode (`[5:4]`: 1 MPS, 2 PMF) and
`pmf_warn` (`[3]`).

**HPS side:** nothing. The UMD Main's menu engine opens the file as an ISO, fails, and leaves
the core to play (`umd_menu_run.c`); the subtitle host never reads the file.

## 4. Benches

- `bench/umd/run_umd_reader.sh --red`: ten synthetic bare files (`tools/umd_reader_cases.py`:
  `syn_bare_*`, `syn_pmf*`, `err_pmf_*`, `err_bare_huge`), and per disc image two real ones --
  the main clip's first 64 packs as a bare `.MPS`, and its `ICON1.PMF` whole (Sony's own PSMF) --
  goldens from `psmf_ref` (`umd_fixture.bare_fixture`), never the RTL. New arms `[sniff]` (the
  first read after every start is sector 0) and `[bare]` (the mode, `pmf_warn`, navigation
  refused with nothing flushed); RED B1-B11.
- `bench/umd/run_player_ctl.sh --red`: `player_ctl_bare_tb.sv` (directed): five seek commands
  each one UNAVAIL and nothing else; Next -> NO_CHAPTER; the default track following the stream;
  RED P62 / P63.
- `bench/umd/run_transport_hud.sh --red`: the message alone and under Display with a zero total,
  a track tag with no language (b26-b28); RED H49 / H50.
- `tools/tests`: `psmf_ref.psmf_header` (+4 RED), `umd_fixture.bare_expect` (+2 RED).

## 4b. On the rig (2026-10-05, `UMD_bare_20261005_1945.rbf`, .236, the UMD Main)

Files copied to the MiSTer's `/tmp` (cut from the library and one game image), mounted by an MGL
(the first) and in session through the UMD Main (`/tmp/umd_ctl`):

| file | result |
|---|---|
| Akira `00003.MPS` (a field-coded trailer, 28.6 MB), by MGL | reader mode 1, no map; 6,994 field pictures decoded = ffprobe's 3,497 pairs exactly; 59.94 pictures/s, the judder gate equal, A/V 0.03 ms, errors 0; `S_DONE` at the end. FF -> "Not available for this file.", Next -> "There is no chapter available.", Audio -> "♪ 1", Display -> no title, `00:01:08/00:00:00`, the bar empty; no seek issued, no trick play |
| The Simpsons Movie `00006.MPS` (8 sectors, 144x80) | plays (under an image's 17-sector minimum): 30 pictures = ffprobe; top-left, as documented |
| Akira's feature head (15,000 packs: audio 0x00 / 0x01, subtitle 0x80) | Audio's second press -> "♪ 2" (learned from the stream); subtitles on -> the line drawn by the UMD Main, in its time |
| Akira `ICON1.PMF` (Sony's PSMF, 144x80) | reader mode 2; 450 pictures decoded, emitted and shown = ffprobe |
| Crush `INTRO.PMF` (480x272, 44.1 kHz) | picture clean, top-left, errors 0, nothing late; every audio frame refused `E_RATE` (16) and played as silence of its length: why `.PMF` is not offered yet |

## 5. Known limitations and the next stages

- **`.PMF` is out of scope** (B4): not offered (`S0,ISOMPS`). Its audio is 44.1 kHz on every game
  file, which the fabric refuses frame by frame (silence; `aud_err`); a `.PMF` mounted by path
  plays its picture only. Should it ever come back, the audio stage it needs is: the sample tick
  (`clk_sys * 49 / 30000`), `aud_out`'s gate (a pair is 100/49 ticks, not 15/8), the ring's AU
  timing, the decoder's rate check -- then `S0,ISOMPSPMF`.
- **No seek / FF / REW / Go To on a bare file.** Two candidates, to decide after this fit: a fabric
  seek by a byte-rate estimate and a forward scan to the next 0xBF index pack (it carries no PTS:
  the video PES in the same sector does; a probe scans up to ~300 sectors at 10 Mbit/s), or a map
  the UMD Main builds by scanning the file (host side, stock Main loses it).
- **A small picture is shown top-left** in the 720x480 raster: only the rare small disc clips (The
  Simpsons Movie's 144x80 `00006.MPS`). Centring would be a display-path stage (`disp_reader`), low
  priority now that `.PMF` (mostly 480x272) is out of scope.
- **A bare file's duration is unknown** (the HUD's total 0:00:00, the bar empty). An `.MPS`'s last
  index pack's GOP would give it within a GOP.
- **No track languages** on a bare file; the track tag shows the number alone.
- **A subtitle track is offered once the stream has shown it**: its first unit passes before the
  track can be chosen (seen on the rig: Akira's head offers subtitle 1 from its first unit at
  106 s), so that unit is never shown. The same for an audio track the stream reaches late (a
  default is chosen from the first track seen).
- Go To's editor still opens on a bare file; its jump is refused (UNAVAIL).
