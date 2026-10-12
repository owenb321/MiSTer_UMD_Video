# P2 after the reader: demux, probe, diagnostic HUD, and the hardware gate

**Status:** ✅ MERGED (PR fj#3) · ✅ HW-CONFIRMED 2026-09-23 (`docs/roadmap.md` Phase 2 has the
per-disc results): the readout's video CRC matched `tools/psmf_golden.py --crc` on all
four discs tried, and the SD path measured ~1,200 packs/s from a network share.
The reader itself is `docs/umd_reader.md`.

```
umd_reader -> ps_stream_fifo -> ps_demux -+-> video ES  --+
   (busy <- almost_full)                  +-> audio ES  --+--> es_probe (counts, CRC, rate)
                                          +-> subtitles --+
p2_diag (template ROM + live fields) -> text plane -> diag_hud -> over the raster in emu
```

## ps_demux (`umd/ps_demux.sv`)

MiSTer_DVD's demux with the UMD substream map; the surgery list is the module header.
Two decisions worth their reasons:

- **The UMD FAP is 0-based.** The DVD AC-3 first-access-unit pointer counts from 1; the
  UMD audio sub-header's FAP counts from the byte after it with 0 = the first payload
  byte (`psmf_ref.py`, confirmed: it lands on `0F D0` every time). Measured on 33 discs:
  every audio PES starts an access unit and the FAP always lies inside the payload. A
  FAP at or past the payload drops the PES, as the DVD code did for a nonsensical pointer.
- **The realign is armed out of reset.** The first audio byte forwarded after a mount is
  an AU header, never the tail of a frame the stream began inside. The mechanism is the
  DVD's track-switch realign, reused; mutation D10 proves the bench sees it.

Not covered yet: a mid-stream track switch (`aud_realign` is tied 0 until P6 builds the
switch; the DVD-era branch for it is kept and only the reset path is exercised).

## es_probe (`umd/es_probe.sv`)

Counts what the demux delivered and CRCs the first 1 MiB of video ES (zlib's CRC-32).
Since P3 the video sink stalls (`vidfeed_cdc`), so the probe's `vid_take` is valid AND
ready — `tools/check_emu_wiring.py` pins it: on valid alone every stalled cycle would
count as a byte and the CRC would match nothing.
It exists because P2 has no decoder: the sinks are always ready, so "bytes are moving"
proves little. A CRC that matches `tools/psmf_golden.py --crc <disc>` proves the whole
chain is byte-exact on silicon; a zero-filled, shifted or mis-routed stream cannot match.
The rate is pes_hdr_ok pulses per second (packs that carried an A/V PES).

## The diagnostic HUD (`umd/p2_diag.sv`, `umd/diag_hud.sv`, `tools/diag_layout.py`)

A text plane (8 x 64 cells, 44 shown) drawn at 2x over the raster, LAT 4 like
`xmb_wave` so emu merges both at the output register. The layout is written once, in
`tools/diag_layout.py`, which generates the formatter's template ROM AND renders the
bench's golden frame. The font is MiSTer_DVD's HUD font (`tools/hud_font.py`, glyphs
0-44 index-for-index, so its transport HUD harvests unchanged in P6) plus `?&',!()` in
spare slots; `?` stands for every byte the font cannot show (TITLE is UTF-8).

This is a development readout, not the P6 status line; the manual documents it
(`site/content/playback/on-screen-messages.md`) because a user sees it.

## Benches

- `run_ps_demux.sh --red`: synthetic streams + two windows per disc, byte-exact per class
  and PTS marks vs `psmf_ref.py`, plus es_probe's counts/CRC/rate; 12 mutations.
- `run_diag_hud.sh --red`: a whole frame, pixel-exact vs `diag_layout.py`; 6 mutations.
  Fixture-range lesson, twice: a title longer than the row hid "bytes past title_len
  shown" (H3 survived until the title was shortened), and the es_probe rate mutation
  survived a 5000-cycle window that no pulse happened to end.
- The chain (`bench/umd/p2_chain_tb.sv`, run by `run_umd_reader.sh`): reader -> FIFO ->
  demux -> probe as emu composes it, sinks ready one cycle in four so the FIFO really
  fills. **C1 finding:** mutating the FIFO's `almost_full` margin (DEPTH-2 -> DEPTH)
  SURVIVED, and correctly: umd_reader reads `busy` combinationally and issues one byte per
  two clocks, so one byte is ever in flight. The DEPTH-2 margin is for a registered-busy
  source (MiSTer_DVD's streamer). C1 is now "the reader ignores busy", which the chain
  catches through the CRC.

## The hardware gate (P2) -- passed 2026-09-23

Measured: 1,170-1,200 A/V packs/s (~2.4 MB/s, ~19 Mbit/s) from the rig's CIFS share, on
every disc -- the reader's one-request-in-flight design has about 2x headroom over the
Level 3.0 ceiling. A digit caught mid-update can look smeared in one screenshot (the
formatter rewrites cells live); it is not a render fault.


1. Build (`USE_DOCKER=1 ./build_release.sh --compile`), ledger the fit in `UMD.qsf`.
2. Flash with `tools/mister.py`, mount a disc image (the rig's images, or copy one).
3. Screenshot after a few seconds: `ERR 0`, the title, `PL` = the longest playlist
   (Hero: 0002), `PACKS` and `V/A/S` growing, `PACKS/S` = the SD path's throughput
   ceiling (it must exceed ~610 packs/s = the 10 Mbit/s Level 3.0 maximum for P3+ to
   stream in real time).
4. `CRC ... 1` equal to `tools/psmf_golden.py --crc <the same image>`.
