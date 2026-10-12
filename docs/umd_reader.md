# The P2 image reader (`umd/umd_reader.sv`)

**Status:** P2 walk ✅ MERGED (PR fj#3) · ✅ HW-CONFIRMED 2026-09-23 (on the rig the walk
picked the right playlist on four discs, `docs/roadmap.md` Phase 2). **P6b2, IN / OUT and
the navigation port: ✅ MERGED (PR fj#18, 2026-09-28)** (`docs/transport.md`
§2.4 has the port's contract, §9 the status). Benched by `bench/umd/run_umd_reader.sh
--red`: 16 synthetic images + 2 restarts, every disc image in the library with a
navigation script each, the reader->demux chain, 39 mutations each caught by its own arm.

## What it does

A mounted `.iso` goes in over the hps_io `sd_*` port (one 2048-byte sector per request);
the main title's MPEG program-stream packs come out, back to back, on the same
`stream_data / stream_valid / busy` contract as `block_streamer` (which it replaces).
The walk, and what each step keeps:

| step | reads | keeps |
|---|---|---|
| volume descriptors | LBA 16.. up to the first type-1 (PVD) | the root directory record at PVD 156 |
| root/ | directory records | `UMD_VIDEO/` |
| UMD_VIDEO/PARAM.SFO | header, the entry table, key names | TITLE, **found by key**, first 128 bytes -> `title_mem` |
| UMD_VIDEO/PLAYLIST.UMD | every playlist's items | the **longest** playlist (sum of OUT-IN; first on a tie) |
| per item: CLIPINF/<clip>.CLP | header, stream_info, the EP map (P6b2) | PTS range, EP-map offset, audio/subtitle presence + language, video attribute bytes; where the item starts and stops |
| per item: STREAM/<clip>.MPS | its extents | the stream, from the entry at or before IN to the first entry at or after OUT |

Each file is found by name in its directory (`tname`/`tlen`, one comparator; a `;N`
version suffix is accepted though no surveyed disc has one, and directories are not
name-sorted on real discs). Outputs: `umd_reader.sv`'s port list; the stable error codes
are at the top of the module.

## Kept from MiSTer_DVD, and what changed

The skeleton is `dvd_iso_reader.sv`'s (`docs/harvest.md`): a sector read into a 2 KB
synchronous `parse_buf` (one M10K), a register shadow `rbuf` filled from it one byte per
cycle, field taps that only ever read the shadow (async multi-offset reads of the parse
buffer blew a MiSTer_DVD fit to 226 % ALM), the sector-crossing shadow fetch, the 16 KB
circular stream cache, and `block_streamer`'s two-stage output pipe. Everything
IFO/PGC/VM-shaped (about 90 % of that module) is gone; the walk is new.

- `FETCH_N` 45 -> **48**: a name starts at record byte 33 and the longest one matched
  (`PLAYLIST.UMD` or an 8-character clip name + `.CLP`) plus a `;N` suffix ends at 46.
- **The shadow never crosses where it must not**: out of a directory sector (records
  never straddle, ECMA-119 6.8.1.1) or past a file's last sector. Those bytes read as 0
  and no stray sector is requested (the bench fails any read outside the walk's regions).
- **File-relative fetches** (`S_FOPEN`): `fo_off` into the current file; a fetch at or
  past the file's size goes to `S_OOB` instead, which is what bounds every walk (below).
- The sd handshake runs outside the state case. Every request site issues only on
  `!rq_busy && !rq_done`, so a new mount in the middle of a transfer lets the old block
  land (into a buffer nothing trusts: `pb_valid` cleared, `wr_ptr` reset) before its
  own request goes out. A second lock in `S_INIT` was removed: with both, removing
  either survived the mutation run (R10), so only one of them was load-bearing.

## Design to the spec maximum

Counters are the fields' own widths: playlists u16, items u32, streams u16, SFO entries
u32, offsets u32. Every loop terminates without a cycle budget because each step moves a
u32 offset strictly forward (an item or entry length whose sum carries past 2^32 is
malformed: `E_PL`) and a fetch at or past the file's size is refused.

**A multi-extent `.MPS` has no extent table.** When an extent is exhausted and its record
has the multi-extent flag, the reader resumes the `STREAM/` directory walk just past that
record and streams the next record with the same name. ECMA-119 allows any number of
extents, in any order, anywhere; this handles all of that (the bench's `syn_multi` has
three gapped, out-of-order extents whose records straddle two directory sectors). Rejected:
MiSTer_DVD's `ext_mem` table, which would need a bound and a refusal past it.

Two bounds are smaller than the format, and both are visible:

- `title_trunc`: a TITLE over 128 bytes keeps 128. 128 is the key's `max_len` on every
  disc; the longest title seen is 55 bytes.
- `dur_sat`: a playlist duration sum over 2^64 ticks saturates (it would take more than
  65,536 items of 2^48 ticks each).

Refused loudly, never streamed as garbage (`err_code`): no PVD, no `UMD_VIDEO/`, a missing
or malformed PLAYLIST.UMD or CLP, a missing clip, an interleaved (file-unit) `.MPS`, a
multi-extent navigation file. A missing or malformed PARAM.SFO only costs the title
(`sfo_warn`).

## The bench (`bench/umd/umd_reader_tb.sv`, `run_umd_reader.sh`)

Fixtures are `--nav` fixtures (`tools/umd_fixture.py`): the sectors of every region the
walk may read, the stream sectors in order, and the expected outputs from
`umd_fixture.reader_expect()` -- the P1 parsers (`umd_sfo`, `umd_playlist`, `umd_clpi`),
never the RTL. Synthetic edges come from `tools/umd_reader_cases.py`; every disc image
under `$UMD_ISO_DIR`, subdirectories included, gets one: the walk, the first 64 packs,
and a navigation script. Since P6b2 the stream goldens (the walk's and every seek's) come
from `tools/umd_nav_ref.py` through `umd_fixture.NavScript`: each item from the entry at
or before IN to the first entry at or after OUT.

**Order is a dependency mask, not a sequence.** The first fixture design recorded the
exact LBA sequence of one reference walk. That scores one implementation's choices (how
often it re-reads `UMD_VIDEO/`, whether it reads `STREAM/` before or after the CLP), not
the format. A single rank per region was tried next and failed the same way: it forced
`STREAM/` before the CLP, which nothing requires. Each region now carries a bit mask of
the regions whose first read must precede its own (`umd_fixture.REGION_DEPS`): what the
data forces (a directory before the files it lists; the playlist before the clip it
names) plus one reader contract, an item's CLP before its stream (the track table has to
describe a clip before its bytes flow). Once a command has been issued, a second mask
applies, without "items play in order": a seek plays them in any order.

Arms: `[walk] [order] [pick] [title] [stream] [done] [tracks] [clip] [nav] [err]
[thrash]`, `+restart` (a second mount mid-transfer, then the whole walk re-scored), and
since P6b2 `[seek] [chap] [op]`.

**The navigation script** (`<stem>.nav.hex`, `umd_fixture.NAV_WORDS`). Commands are
issued in order, each when its trigger holds: after the phase (a complete phase ends in
`title_done`), mid-transfer (an `.MPS` block in flight), or halfway through the phase.
The phase switches at a SEEK's accepting edge. The bench flips at the negedge after it,
so a request or byte sampled at that posedge still counts as the old phase's; every
byte after must be the landing's (`.nseq.hex`). A CHAP runs inside the phase, so the
stream across it must stay unbroken, and one scan may read at most PLAYLIST.UMD's
sectors + 2. Each disc runs `umd_fixture.disc_script`, seeded by its file name:

- a query during the walk's stream;
- eight seeks at random keys, half of them mid-transfer, plus a chapter's landing;
- the tail of item 0 (on a multi-item title, across into item 1) and of the last item,
  to OUT and the title's end;
- a seek after `title_done`, a query past the last chapter, and a bad item.

`syn_nav` has the edges no disc has: IN between entries and OUT exactly on one, the
video map behind a subtitle map, a straddling entry, a one-entry map, OUT past 2^32, an
entry past its clip, unsorted, duplicate and dangling marks. `syn_marks_max` has 65,535
marks. The mutation list is in the runner's header.

## IN / OUT and the navigation port (P6b2)

Every item start is two binary searches of the CLP's video EP map, read through the same
shadow fetch as everything else (an entry that straddles a sector uses the cross fetch):

- **the start**: the last entry at or before IN (or a seek's target, clamped into
  [IN, OUT)); the first entry for an earlier target. P6b4 made the clamp exclusive: a
  target at or past OUT is OUT - 1, the item's last picture. Before, it was OUT itself,
  which lands on an entry exactly AT OUT (none of the library's 120 items has one, but the
  format allows it), or makes the display's skip drop the picture ending at OUT. Either
  way the display's OUT drops the rest and nothing is shown until the 3 s watchdog. A walk's
  item start still takes IN itself, unclamped. `run_umd_reader.sh` N27;
  **since `fix/skip-last-picture` (2026-10-04) the clamp is OUT - 4** (`END_GUARD`): OUT - 1 lay
  inside the display skip's one-tick tolerance of an untagged last picture's estimated end, and
  Akira's last picture was dropped. `umd_nav_ref.Title.clamp` derives the 4 (`display.md` §11;
  N27 is now END_GUARD 1, N33 a clamp to OUT itself);
- **the stop**: the first entry at or after OUT (OUT is exclusive); none means the
  clip's end. A stop at or before the start streams nothing.

The start sector is clip-relative. `S_MPS` finds it through the `.MPS` extents by the
same directory walk that continues a multi-extent stream (`S_MPS_NEXT`). A separate
counter stops the item at its stop sector, whichever extent that falls in. The video map
is the one whose stream id is `0xE0`, searched for rather than assumed to be map 0 (it is
map 0 on all 721 clips in the library). A clip with no video map streams whole from
sector 0, as P2 did, and is flagged. An entry past its clip skips the item, flagged.

The two commands, `NAV_SEEK` and `NAV_CHAP`, their results and the `nav_err` codes are in
`transport.md` §2.4. What they share with the walk, and what they must not touch:

- A seek is the walk's own item start, entered from an item-record walk. It keeps the
  walk's fatal refusals (a malformed CLP in a seek is `E_CLP`, as at a mount).
- A chapter query runs only between stream sector reads (`S_STREAM` with no transfer in
  flight, `S_DRAIN`, `S_DONE`) and only through the fetch states. So the multi-extent
  continuation's directory position (`p`, `dir_lba`, `fd_rl`, `fd_flags`) survives it.
  Its run-off is `FILE_MRK`'s own verdict in `S_OOB` (`NE_OOB`), never the playlist's
  fatal `E_PL`.
- The bad-item and reserved-op refusals answer from beside the state case, not ahead of
  it. A priority branch there would skip one cycle of the case, and an `rq_done` in
  that cycle would be lost with `rd_wait` stuck high.
- The fetch length follows what is fetched: 10 bytes for an EP entry or map header, 40
  for a mark, 48 otherwise (`transport.md` §2.4 has the measurement).

## Bare stream files (P8, `docs/bare_streams.md`)

The first read is sector 0 (`S_SNIFF`, before the image's 17-sector minimum): a pack header is a
bare `.MPS`, `PSMF` a `.PMF` (its header checked as JPCSP checks it: `E_BARE`), anything else an
image (LBA 16 next, as before; no library image's sector 0 matches). A bare file enters `S_MPS` as
one extent (the whole file; a `.PMF` skips its header with `S_MPS`'s skip counter and stops at
its size with the item's stop counter) with the item the mount reset: one of one, IN 90000, OUT
at the end of time, no duration, no map (`ep_flags[0]`); no title, CLP or marks (`pmf_warn` when
a PSMF's size disagrees with the file). Bound: < 4 GB. Area: `bare_streams.md` §3 (a state arm
costs a mux input on every bit it writes -- the first version's was +907 LUTs, as built +327).
SEEK / TIME / PLAY are answered `NE_NOMAP` with nothing flushed, CHAP with no chapter.
Outputs `bare` (1 `.MPS`, 2 `.PMF`) and `pmf_warn`. Bench: `run_umd_reader.sh`'s `[sniff]` and
`[bare]` arms, the `syn_bare_*` / `syn_pmf*` / `err_pmf_*` cases and every disc's head as a bare
`.MPS` and its `ICON1.PMF`; RED B1-B11.

## Known limitations

- **Multi-item playlists** (support by design; three main titles in the library,
  `transport.md` §1): the next item's CLP is parsed while the previous item's tail is
  still in the cache, so the track outputs flip a few KB early. The item boundary is
  P8's handoff (D8).
- **An EP PTS is u32**: a target at or past 2^32 ticks (13.25 h) lands on the map's last
  entry, flagged (`ep_flags[2]`, `NE_WIDE`), never wrapped. The longest title is 2.5 h.
- **A chapter query scans every mark**: at the u16 maximum (65,535 marks, 2.6 MB) that
  is ~1,300 sector reads, seconds of latency, never truncated. The library's largest is
  74 marks (two sectors).
- **The EP binary search assumes strictly increasing PTS**, as every map in the library
  is (`umd_clpi.py --verify`). An unsorted map still lands on some entry of the item,
  never outside it.
