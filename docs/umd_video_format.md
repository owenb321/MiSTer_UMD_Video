# The UMD Video format, as measured

Every fact here is reproduced by a Phase 1 tool (`tools/`, named per section) over the
local library: **33 UMD Video images** (2026-09-23; the first survey on 2026-09-22 read
nine). Tags: **confirmed** = a tool decodes it AND cross-checks it against an
independent source (the stream, ffmpeg, PIL, another table); **measured** = read on the
discs, no second source; **(?)** = a field carried raw and censused, meaning unknown.
The per-disc vector is `tools/umd_census.py` (run by `tools/tests/corpus_umd.sh`).

⚠ 33 discs is a sample, not the population (CLAUDE.md "design to the spec maximum").
Every width below is the FIELD's width; the census maxima say only what is common.

## The disc image — `umd_iso.py`, confirmed

An ordinary ISO9660 filesystem: PVD at LBA 16, **system identifier `UMD VIDEO`** (the
volume identifier is blank), 2048-byte blocks, no multi-extent file on any disc. No UDF.

```
UMD_DATA.BIN            48 B: "<product/title stub>|<disc id hex>|0002|V"
UMD_VIDEO/PARAM.SFO     PSF key/value file
UMD_VIDEO/PLAYLIST.UMD  UMDV0088
UMD_VIDEO/CLIPINF/NNNNN.CLP   CLPI0088, one per clip
UMD_VIDEO/STREAM/NNNNN.MPS    the media, one per clip; the feature ~1.1-1.7 GB
UMD_VIDEO/ICON0.PNG, PIC1.PNG, ICON1.PMF, SND0.AT3, RESOURCE/*.RCO   XMB art, menus
PSP_GAME/SYSDIR/UPDATE/  on 9 discs: a PSP firmware updater (ignored)
```

- 3-20 clips per disc (TV-episode discs carry one clip per episode). Clip numbers can
  have **gaps** (Dark Knight: 1, 3, 4; Tom & Jerry: ..., 4, 99).
- A `.MPS` can exist **without a `.CLP`** (The Simpsons Movie `00006.MPS`, 16 KB, a
  144x80 Level 2.1 stream no playlist references). Walk `CLIPINF/`, not `STREAM/`.
- **Desperado's image is damaged**: clips 1-4 are entirely zero-filled sectors and clip
  5 almost entirely, while every table is intact. Tools report "damaged image" instead
  of failing a parser (`umd_clpi.zero_fraction`).

## PARAM.SFO — `umd_sfo.py`, measured

Standard PSP PSF (little-endian header, key table, data table). `TITLE` (utf8z,
**max_len 128**) and `PARENTAL_LEVEL` (int32) always; 11 of 33 discs carry
`PSP_SYSTEM_VER` **between** them, so TITLE must be looked up **by key**. Titles
are UTF-8 and not always ASCII (`Spiderman 3™`, 3-byte U+2122); longest seen 55 bytes.

## PLAYLIST.UMD (`UMDV0088`) — `umd_playlist.py`, confirmed against CLIPINF

Big-endian. Header: magic, `u32 playlists_off` (0x130), a disc-info block at 0x28 (a
name: `UMDV-SAMPLE` on most discs — the authoring tool's default, not the title).
Playlists section: `u32 len, u16 n`, then `n` entries, each `u32 len`, `u16 items_off,
u16 marks_off` (relative to the entry), 28 bytes (?), an info block at +0x24 (BCD date
`20040815230000` on every disc, a name such as `Trailer01` — authoring labels, not
unique), items, marks:

- item: `u32 22, u16 name_len, char[8] clip name ("00001"), u48 IN, u48 OUT` (90 kHz).
- mark (40 B): `u8 5 (?), u8 flags (?) (0, 4-10), u16 item, u48 PTS, u48 (?)=0,
  char[24] name` (`Mark2731` = the mark's frame number at 29.97: a label).

Measured: 3-46 playlists, **every one of 398 playlists has exactly one item** on the
first 33 discs, up to 74 marks. **Not on the grown library** (2026-09-27, 89 images): 73
playlists have several items, and 3 main titles do (My Chemical Romance: 2 and 3; Now
That's What I Call Music 2006: 30, one per video). A mark names its item; its PTS is on
that item's clip. "Entry points and marks" below. **The feature is not always playlist 0**: Hero, Kill Bill Vol. 2 and The Incredibles
put a <20 s intro at #0 and the film at #2. `main_playlist()` picks the longest. (On a
PSP the RCO menu chooses; this core has no menu.) On TV-episode discs (Cowboy Bebop
Vol. 1: 17 clips) "the longest" is just one episode: item selection is P8.
`verify()`: every item names an existing CLP, IN/OUT lie in that clip's PTS range, every
mark in its item — OK on all 33; four OUTs overrun their clip's end by at most 9009
ticks (Hero, Family Guy, Interstella 5555 x2), tolerated (<= 1 s) and noted.

## CLIPINF (`CLPI0088`) — `umd_clpi.py`, confirmed against the stream

Big-endian. Header: magic, `u32 stream_info_off` (0x30), `u32 ep_map_off`,
`u32 extra_off` (a 2-byte section `00 00` (?)), 28 bytes (?) (zero on every disc).

- **stream_info**: `u32 len, u48 start PTS (always 90000), u48 end PTS, u16 n`, then `n`
  x 14 B: `u8 stream_id, u8 substream_id, u32 8 (?), 8 attribute bytes`:
  - video: byte0 low nibble **frame rate** (1 = 23.976 progressive, 4 = 29.97 — the
    Blu-ray codes), byte1 high nibble **aspect** (1 = 16:9 / SAR 40:33, 2 = 4:3 / SAR
    10:11). Agrees with the SPS on every clip.
  - audio: bytes 2-3 **language** (ASCII), byte 4 = 2 (channels (?)), byte 5 = 1 (?).
  - subtitle: bytes 2-3 language.
- **EP map**: `u32 len, u16 1 (?), u16 n_maps`, `n_maps` x `{u8 sid, u8 sub, u32 count,
  u32 offset}` (offsets from the `n_maps` field; the tables tile the section exactly),
  entries `{u16 flags, u32 PTS, u32 sector}` (sector relative to the `.MPS`).
  - video map: `verify()` confirms that sampled entries on every clip of every undamaged
    disc land on a video PES with exactly that PTS, opening AUD + SPS. Flags top 2 bits
    `11`; low 14 bits (?) — not the I-picture span nor any AU offset (tested).
  - subtitle maps (one per subtitle stream, flags 0): the sector of each subtitle unit.
- Widths: `n` u16, count u32, sector u32, **PTS u32** (a 33-bit PTS cannot be stored).
  Measured: up to **35 streams** in one clip, up to 6360 video EP entries (~1 per 1.4 s;
  a 60-90 KB table — too large for M10K, walked by sd reads in P6).

## The stream (`.MPS`) — `psmf_ref.py`, confirmed (byte totals exact on every clip)

An MPEG-2 program stream in 2048-byte packs, each pack one sector, every pack header on
the 2048 grid. Every byte of every undamaged clip is attributed to one class and the
totals equal the file size.

| stream | id | layout |
|---|---|---|
| video | `0xE0` | H.264 Annex-B; each access unit opens with an AUD |
| audio | `0xBD` sub `0x00-0x0F` | 4-byte sub-header `[sub, 0x00, FAP hi, FAP lo]`; FAP = offset, from after the sub-header, of the first AU header starting in this PES (confirmed: it lands on `0F D0` every time) |
| subtitles | `0xBD` sub `0x80-0x9F` | **2-byte** sub-header `[sub, 0x00]` (not 4: only then do unit lengths add up) |
| index | `0xBF` | one per GOP, at every video EP sector (below) |
| system header / padding | `0xBB` / `0xBE` | skipped by length |

Substreams: up to 3 audio tracks in a stream, 5 declared (Desperado 0x00-0x04: en fr de
it es); up to 10 subtitle tracks in a stream (xXx 0x80-0x89) and **29 declared**
(Desperado 0x80-0x9C) — the subtitle range is NOT 0x80-0x8F. Why ffprobe/VLC show no
audio: they map private-stream-1 by the DVD numbering and drop `0x00`.

**Video time stamps** (`umd_pts_census.py`, 2026-09-29, 88 images): a PTS only on the PES
that opens a GOP (~every 0.5 s; P5c). They agree with the pictures' `pic_struct` durations
to within a tick of 90 kHz, **except for lone PTS**. 73 of 88 images carry single time
stamps 1-8 VUI ticks off (208 in all; Akira 3, Family Guy 2, The Simpsons Movie 6), the
next tag back on the old timeline. 206 of 208 are late, two early. The SEI's HRD timing
agrees with the durations, not with the PES: a muxer defect. No real timeline shift in any
main title. The display disbelieves a lone PTS either way (`display.md` §7, §10.6,
§10.9).

## Audio (ATRAC3plus) — `at3p_extract.py`, confirmed by ffmpeg

Each AU: `0F D0 <u16 params> 00 00 00 00` + a frame of `(params & 0x3FF) * 8 + 8` bytes.
The params word read as ffmpeg's `omadec.c` reads it (rate index bits 15-13, channel id
12-10). Re-wrapped as OMA, **ffmpeg decodes every one of 256 tracks, end to end**, as
`atrac3p`, 48000 Hz, 2 channels, exactly 2048 samples per AU, with real signal (L/R correlation
and peak reported; a wrong params word or frames shifted by 100 bytes make ffmpeg fail).

- Four params words, all 48 kHz stereo, differing only in frame size: `0x4855` (688 B,
  ~129 kbit/s) on 231 tracks, **`0x483F`** (512 B, ~96 kbit/s) on 18 incl. Godzilla's
  feature, **`0x487F`** (1024 B, ~192 kbit/s) on 4 (the Goo Goo Dolls concert), **`0x482A`**
  (344 B, ~64 kbit/s) on 3 (Tom & Jerry). Take the frame size from each AU header,
  never a constant.
- Stereo on every track; more than two channels is refused loudly by design.

## Subtitles — `umd_sub_extract.py`, confirmed by PIL

A unit starts in a PES with a PTS and may continue into the next PES of the substream
(Akira has one continuation carrying a single byte: the PNG's last, `0x82`). Unit:
`u32 len (after itself), "0088", u32 duration (90 kHz; a unit ends one frame before the
next begins), u16 0x0010 (?), u16 x, u16 y, u16 0 (?)`, then a **PNG, 4-bit indexed,
16-colour palette with tRNS** on every unit (PIL decodes all of them).
Measured maxima: 605 wide, **389 tall** (full-screen captions, not a two-line strip), right edge 661, **bottom edge 480** (Hero: flush with the frame), duration
837837 (9.3 s). The compositor must accept any rectangle inside 720x480.

**The whole corpus, 2026-09-25** (`tools/png_corpus.py`, P7 pre-work, `docs/png_decode.md`
§1): 336,339 units on 70 of 89 images, every one audited by a strict reader (each
chunk's CRC, zlib's Adler and stream end, trailing bytes, the exact row-byte total) --
**all clean** (confirmed). Every unit has one IDAT, filter type 0 on every row, no
interlace, a 16-entry PLTE and a 16-entry tRNS (confirmed). Its zlib stream is one
dynamic block with CINFO 0-7 and FLEVEL 3, and **match distances reach 32,486**
(measured on a 1,570-unit sample: the 32 KB window is used). New maxima (measured):
- 638 wide (The Animatrix), **441 tall** (Stargate);
- right edge 680 (The Animatrix), bottom 480 (Hero): still **all inside 720x480**;
- 105,750 bytes inflated;
- 7,194 bytes of PNG (Toy Story);
- duration 1,279,278 ticks = 14.2 s (Shaun of the Dead).

## Index packs (`0xBF`) — `umd_index_packs.py`, confirmed against the video

At every video EP-map sector: `01 E0, u16 ref_end[4], u32 0, u16 2+4n, u16 n`, then `n`
x `{u8 pic_struct, u8 flags (?), u16 AU bytes}`, 4 zero bytes. `ref_end[k]` = end sector
of the GOP's k-th reference picture relative to the pack (0 = this sector, **0xFFFF =
none**); entries are the GOP's AUs in decode order with their SEI `pic_struct` and size
**mod 65536** (a 16-bit field: 3054 I-pictures over 64 KB wrap). Verified on all
166,215 GOPs of every undamaged clip. `ref_end` counts reference **fields** on field-coded GOPs of every disc but one, and
reference **frames** (field pairs, ending at the second field) on Tom & Jerry Vol. 1
(Japan): the unit follows the authoring house. Not needed to play; it is trick-play data and a free AU-size golden.

## The video — `umd_census.py` (ffmpeg `trace_headers` over two windows per clip)

| | every clip | notes |
|---|---|---|
| profile / level | Main (77), Level 3.0 | one 144x80 Level 2.1 orphan (Simpsons clip 6) |
| size | 720x480 (45 MBs wide) | `frame_cropping_flag 0` |
| entropy | CABAC; `cabac_init_idc 0` on every slice | no CAVLC anywhere |
| slices | **1 slice per picture** | |
| references | `max_num_ref_frames 2`; l0 up to 2 active, l1 1; no long-term, no MMCO; `ref_pic_list_modification_l0` used (0.5 % of slices) | |
| prediction | `direct_spatial_mv_pred 1` only; `weighted_pred_flag 1` on some PPS (explicit P, `luma_log2_weight_denom 5`); `weighted_bipred_idc 0` | |
| deblocking | `disable_deblocking_filter_idc 0` everywhere | |
| aspect | `aspect_ratio_idc` 5 (40:33, 16:9) or 3 (10:11, 4:3) | matches CLPI |
| timing | `time_scale 240000`; `num_units_in_tick` 4004 (29.97) or 5005 (23.976 progressive) | `pic_struct_present 1` |
| DPB | `bitstream_restriction_flag 1`, `max_dec_frame_buffering 3`, `max_num_reorder_frames 1` | the main title of 49 of 49 readable discs (2026-09-26, the model's SPS parse over the first 64 packs; P5d's output latency is 3 pictures) |

**Three coding families, all common** (per clip; the 214 undamaged clips with a CLP):

| family | SPS | slices | pic_struct | clips |
|---|---|---|---|---|
| progressive 23.976 | `frame_mbs_only 1` | frame | 0 | 41 (10 of them 29.97, ps 4) |
| film 3:2 | `frame_mbs_only 0` | **frame** | 3,4,5,6 cycling | 21 |
| interlaced video | `frame_mbs_only 0` | **field pictures** (`field_pic_flag 1`) | 1,2 | 148 |
| adaptive | `frame_mbs_only 0` | frame AND field, picture by picture | 1-6 | 4 |

**"Interlaced video" is two families, and the stream cannot tell them apart.** The split comes
from `tools/telecine_census.py` (2026-10-08, Forgejo fj#80, `telecine.md` §4). It reads the main
titles, two windows each, and classes them by ffmpeg `idet`'s repeated fields:

| main title family | titles |
|---|---|
| **hard 3:2**: film at 23.976, the 3:2 pulldown baked into 59.94 fields (ps 1 / 2, ct_type 1, no flag) | Armageddon, Audioslave - Live in Cuba, Austin Powers - The Spy Who Shagged Me, Austin Powers in Goldmember, Batman & Robin, Cowboy Bebop Vol. 1, Family Guy, GoldenEye, Interstella 5555 (irregular in places), South Park - Bigger, Longer & Uncut, South Park - When Technology Attacks!, The Animatrix, The Dark Knight, The Simpsons Movie, Tom & Jerry Vol. 1 |
| irregular, not 3:2 | Astro Boy Vol. 1 |
| hard 3:2 field stretches, in a title that is mostly frame pictures | The Mummy, The Mummy Returns |
| **true interlaced video** | The Office Disc 01 and 02, Metallica, Nirvana, Now That's What I Call Music 2006, Dawn of the Dead (a film that reads as video: unexplained) |

The progressive output's Weave combs 2 of every 5 pairs of hard 3:2. Field matching is
planned in `telecine.md`.

**Field pictures are not rare**: most trailers and extras, and the **main title of 12 of
33 discs** — field-coded: Astro Boy Vol. 1, Cowboy Bebop Vol. 1, Family Guy, Interstella
5555, South Park (both), The Dark Knight, The Office (both discs), The Simpsons Movie,
Tom & Jerry Vol. 1; mixed: The Matrix Reloaded. Every TV-series disc, every import
(EU and Japan) and the concert disc's extras are interlaced.
`mb_adaptive_frame_field_flag` is 0 everywhere: **no MBAFF** (33 discs; a positive
control — an x264 interlaced encode — shows the scan does see the flag when it is set).
This overturns the first survey's "frame pictures only" (it sampled features); field
pictures are decoded in P3/P4 (`roadmap.md`, "Decision: field pictures").

ffmpeg decodes every window of every undamaged clip without a bitstream error. It reports "Missing reference
picture" on some clips even decoded whole (xXx clip 2: 147 times, exact byte accounting):
open GOPs across edit points in the source, a property of the stream.

## Entry points and marks — `umd_seek_census.py` (2026-09-27, 89 main titles)

What a seek lands on. Every item of every main title, all 402,530 video EP entries
(Desperado's 4,514 unreadable), leading pictures sampled at 64 entries a clip:

- **Every entry is a recovery point.** An I picture whose access unit carries AUD, SPS,
  PPS and a recovery point SEI (D.2.8) with `recovery_frame_cnt 0`, `exact_match_flag 1`,
  `broken_link_flag 0`: 402,530 of 402,530.
- **59 % are non-IDR** (237,873). The largest gap between IDR entries is 159.9 s (Ghost in
  the Shell 2.0), then 59.7 s (Tom & Jerry Vol. 1), 43.5 s (The Animatrix); typically 10-17 s.
  Between entries there are more IDRs that do NOT repeat the parameter sets (Astro Boy:
  892 IDR slices, 398 IDR entries, 879 SPS, one per entry).
- **Leading pictures** (after the I in decode order, before it in output order: POC by
  8.2.1.1 from the I): 0 at an IDR; at a non-IDR entry one B frame or one B field pair
  (sampled: 0 x 4,615, 1 x 2,274, 2 x 1,218 fields; 9 undetermined, a NAL cut by the scan).
- **Entries are at most 1.97 s apart** (28 Days Later), ~1.4 s on average.
- **Marks.** Type 5 is a chapter, the first always at 0.0 of item 0. Type 16 is an
  `Endmark` / `Endmark2` / `EndmarkTest` at the tail (17 titles; The Rock has two), never
  a chapter. The `flags` byte varies (0-17) with no meaning found; one type-5 mark is
  named `END` (My Chemical Romance). A mark lies up to 1.94 s after the entry at or
  before it (Short Circuit). Stored in (item, PTS) order on every disc; PTS alone is not
  in order on a multi-item title.
- **Audio tracks:** 53 of 89 main titles declare 2-5, languages ISO 639-1 (`en fr es it de
  ja zh ca`); several declare two `en` (a commentary).

## Menus — measured (8 of the 33 discs, 2026-09-25)

`RESOURCE/*.RCO`: Sony RCO containers (`\0PRF`, version 0x70 or 0x71, 65-517 KB), each with
exactly one **VSMX** block (Sony's compiled JavaScript: a stack-machine bytecode, 8 bytes
an instruction, 482-14,888 instructions), plain PNG art (573 images: mostly 8- and 4-bit
indexed, 102 RGBA8, authored for 480x272), and 2-4 VAG sounds in some main menus. Files:
`EN000001` (startup: legal / FBI / title cards, then `PlayMain`), `EN100000` (the main
menu), `EN0000nn` / `EN00nnnn` (sub-pages). Language prefixes `EN`, `FR` (The Matrix), and `ES` in
the first survey. The first survey also found names such as `onInit_pageLegal`,
`SCENESEL_SEL`, `SNEAKPEEKS_PLAY`, `EASTEREGG_SEL`, `g_nCurrAudID`, `g_nResumePossible`,
`ChangeResource`, `SelectMenus`, and clips that are menu transitions.

Beside the table above: T2 also carries `PIC0.PNG`, and Short Circuit and T2 have no
`ICON1.PMF` / `SND0.AT3`. The script sizes, the API surface and the design are in `menus.md`
(roadmap Phase 9). `umd_census.py` does not yet look inside `RESOURCE/`: that is
Phase 9's M0 (`tools/rco_census.py`).

## Tools

| tool | reproduces |
|---|---|
| `umd_iso.py` | the filesystem, UMD_DATA.BIN, orphan/gap clips |
| `umd_sfo.py` | PARAM.SFO |
| `umd_playlist.py --verify` | playlists, items, marks, the main playlist |
| `umd_clpi.py --verify` | stream tables, EP maps against the stream, damaged-image detection |
| `psmf_ref.py` | pack/PES accounting, elementary streams with (offset, PTS, FAP) marks |
| `at3p_extract.py --wav` | AT3+ AUs → OMA → ffmpeg |
| `umd_sub_extract.py` | subtitle units → PNG |
| `umd_index_packs.py --verify` | 0xBF index packs against the video |
| `umd_census.py` | all of the above per disc, plus the H.264 syntax census |
| `umd_seek_census.py` | what a seek lands on: EP entries (IDR, recovery point, parameter sets, leading pictures), marks, items |
| `umd_pts_census.py` | each video PES PTS against the pic_struct timeline: lone PTS and shifts per main title |
| `tests/corpus_umd.sh` | the census as a pass/fail gate (`tests/corpus_gate.py`) |
| `umd_fixture.py` | bench fixtures: EP-aligned pack cuts; the `--nav` sparse image |
