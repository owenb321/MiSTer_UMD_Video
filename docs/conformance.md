# Conformance matrix

The durable "what is correct / what is missing" map. Each row marks a feature
*implemented / partial / missing* with the reference oracle for it. Keep it current in
the same change that closes a gap (the stale-marker rule).

Legend: ✅ implemented and gated · 🔧 partial · ❌ missing · ⛔ deliberately out of scope

## How to use the oracles

Verify in increasing order of authority and cost. "ffmpeg does X" is a hypothesis to
check against the spec, not a conclusion; but for reconstruction ffmpeg is bit-exact by
the standard's own definition and is the gate.

1. **ffmpeg / JM** — executable baselines: pixels (bit-exact), syntax-element traces.
2. **The spec** (H.264) — for anything the oracle and the RTL disagree on.
3. **A real PSP** — the only oracle for PSMF/CLPI/RCO behaviour where nothing is written.

## Rows

Legend addition: 📐 **golden only** — the offline tool (the oracle for the RTL) exists
and is gated; the fabric implementation does not yet.

| area | feature | status | oracle |
|---|---|---|---|
| container | ISO9660 walk to `UMD_VIDEO/` | 📐 (P1) | `umd_iso.py`; `umd_fixture.py --nav` (sparse image + LBA sequence) |
| container | `PLAYLIST.UMD` items, marks, main playlist (the longest) | 📐 (P1) | `umd_playlist.py --verify` |
| container | CLPI stream table, EP map | 📐 (P1) | `umd_clpi.py --verify` |
| demux | PS packs, PES, PTS, substream routing 0x00-0x0F / 0x80-0x9F | 📐 (P1) | `psmf_ref.py` (byte accounting exact on every clip) |
| demux | 0xBF per-GOP index packs | 📐 (P1) — not needed to play | `umd_index_packs.py --verify` |
| video | NAL/SPS/PPS/slice header, Main profile | 📐 (P3: `h264_fe_ref.py` == JM and == ffmpeg `trace_headers`, frame and field) | JM trace; ffmpeg `trace_headers`; H.264.1 Table 1 streams |
| video | CABAC (all Main SE classes) | 📐 (P3: `cabac_ref.py` + `h264_fe_ref.py` == JM on 3 streams / 8.2 M records; tables from the spec PDF == ffmpeg == JM; the H.264.1 sweep `h264_conformance.py`) | JM trace + each conformance stream's `-trace.txt`; `CABACI3_Sony_B` for `cabac_init_idc` 1/2 |
| video | intra 4x4/16x16/chroma | ❌ | ffmpeg pixels |
| video | inter: MV prediction, spatial direct, 6-tap/bilinear, weighted P, bi-pred | ❌ | ffmpeg pixels |
| video | deblocking | ❌ | ffmpeg pixels |
| video | DPB / POC output order, `pic_struct` 3:2 | ❌ | ffmpeg + scheduler model |
| video | field pictures (PAFF) | ❌ — planned P3/P4/P5 (12 of 33 main titles) | ffmpeg pixels; `umd_census.py` finds them |
| video | CAVLC / MBAFF / FMO | ⛔ refused loudly (none on 33 discs) | `umd_census.py` |
| audio | ATRAC3plus stereo 48 kHz, frame size per AU header | ❌ (AU extraction 📐 P1) | `at3p_extract.py` → ffmpeg (bounded error) |
| subtitles | PNG units, timing, position | ❌ (unit extraction 📐 P1) | `umd_sub_extract.py` → PIL |
| navigation | chapters, seek, resume, multiple items | ❌ | — |
| menus | RCO/VSMX | ❌ — designed, roadmap Phase 9 (`menus.md`) | a real PSP (captures); JPCSP (VM / API trace); rcomage (decompile) |
