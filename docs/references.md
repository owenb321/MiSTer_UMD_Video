# References

## The formats

- **ITU-T H.264 / ISO/IEC 14496-10** — the spec. Main profile (§A.2.2), Level 3.0
  (Table A-1), CABAC (§9.3 incl. the context init tables 9-12 to 9-33 and `rangeTabLPS`
  Table 9-44), the display process and `pic_struct` (§D.2.3), Annex B byte streams. Free
  from ITU-T.
- **ATRAC3plus** — no public specification. The reference is **ffmpeg's decoder**
  (`libavcodec/atrac3plus*.c`, `atrac3plusdec.c`, `atrac3plusdsp.c`), reverse-engineered
  by Maxim Poliakovski, plus the PSP homebrew notes on the OMA/AT3 header word
  (`0x4855` etc.). ffmpeg is LGPL: it is the oracle this core's decoder is checked
  against, and its code is never copied. Its **tables** are transcribed with credit
  (the maintainer, 2026-09-25; NOTICE): `tools/gen_at3p_tables.py` from the pinned
  source below. `docs/at3p_decoder.md` S1.
- **PSMF / UMD Video containers** — undocumented by Sony. The `.MPS` is an ordinary MPEG-2
  program stream (ISO/IEC 13818-1) with a private substream numbering; `PLAYLIST.UMD`
  (`UMDV0088`), `CLIPINF/*.CLP` (`CLPI0088`) and `RESOURCE/*.RCO` (RCO + VSMX) are
  described only by PSP homebrew tooling (JPCSP, PPSSPP's `sceMpeg`/`scePsmf`, rcomage for
  RCO/VSMX). `docs/umd_video_format.md` records what this project measured itself.
- **ISO9660** (ECMA-119), the disc filesystem. **PNG** (RFC 2083) and **DEFLATE**
  (RFC 1951) for the subtitle images; zlib (RFC 1950) wraps each IDAT stream.
- **puff** (Mark Adler, zlib's `contrib/puff`): the canonical-Huffman decode method
  `umd/png/inflate.sv` implements (count / first / index, a code bit at a time), and the
  layout of `tools/inflate_ref.py`. **zlib** and **libpng** are the oracles of the PNG
  decoder (`docs/png_decode.md` §5): the system libraries, not vendored.

## Papers the decoder is sized against

- L. V. Agostini, A. P. Azevedo Filho, W. T. Staehler, V. S. Rosa, B. Zatt, A. C. M.
  Pinto, R. E. Porto, S. Bampi, A. A. Susin, *Design and FPGA Prototyping of a H.264/AVC
  Main Profile Decoder for HDTV*, 2007 (journal version, pp. 25-36; conference version
  FPL 2006). Module architectures and per-module resource figures on a Virtex-II Pro;
  the entropy decoder was not completed. Local copy in `$UMD_REFS_DIR` (below).
- A. Petrovsky, A. Stankevich, A. Petrovsky, *Pipeline processing in real-time of CABAC
  decoder based on FPGA*, ICSES 2012. A complete H.264 CABAC decoder at 1 bin/cycle,
  96 MHz, 12.6K LUTs on a Virtex-6, verified against JM. Its reference [12] (Eeckhaut et
  al., FPT 2006) is an Altera Stratix II study of the engine's critical loop.
- K. Xu, *nova: a H.264/AVC Baseline Decoder*, 2008 (opencores; `nova_spec.doc` and
  Verilog in `$UMD_REFS_DIR/nova`). A low-power ASIC design, also proven on a Virtex-4:
  204 cycles / MB, 4-pixel column parallelism, a 4x16 block / macroblock "hybrid
  pipeline", bS decided at parse time, a 5-stage single-port-SRAM deblocking filter,
  zero-block-aware residual, plane mode by incremental adders. **No licence in the
  repository: ideas only, no code** (the ideas P4 takes: `roadmap.md` Phase 4).
- D. Marpe, H. Schwarz, T. Wiegand, *Context-Based Adaptive Binary Arithmetic Coding in
  the H.264/AVC Video Compression Standard*, IEEE TCSVT 13(7), 2003 — the clearest
  description of CABAC outside the spec.

## The local reference set: `$UMD_REFS_DIR` (default `~/umd-refs`)

Third-party material is never committed; benches and tools find it through
`${UMD_REFS_DIR:-~/umd-refs}` and SKIP loudly without it (the `$UMD_ISO_DIR` rule).
Assembled 2026-09-23 for P3:

| path | what |
|---|---|
| `T-REC-H.264-202606.pdf` | the spec (2026-06 edition): CABAC tables 9-12..9-33 and 9-44 are transcribed from here, never from memory |
| `T-REC-H.264.1-201602.pdf` | the conformance spec: which streams a Main decoder must decode (its Table 1) |
| `design_and_fpga_prototyping_of_a_h264_decoder.pdf`, `Pipeline processing in real-time of CABAC decoder based on FPGA.pdf` | the two FPGA papers above |
| `JM/` | JM 18.4 (FRExt) source, a research fork (VQ codebooks, residual dumps: off with `-p VQdim=0 -p ResidualsOutput=0`). `tools/jm_build.sh` builds the `TRACE 1` decoder into `JM/build_trace/bin/ldecod.exe` (the tree's MSVC-isms via `tools/jm_posix_compat.h`), and `--lencod` the encoder into `JM/build_enc/bin/lencod.exe` for the P4 control-path fixtures (`tools/jm_fixtures.py`: its VQ extension off with `VQdim 0`, `VQcblen 0`); `2` would add per-bin context detail. Pixel-exact vs the H.264.1 YUVs and vs ffmpeg on discs; `h264_frontend.md` §1 |
| `ffmpeg-9.0.1/` | the ffmpeg **n9.0.1** release source (`ffmpeg.org/releases/ffmpeg-9.0.1.tar.xz`, the same version as the oracle binary): `libavcodec/atrac3plus.c`, `atrac3plus.h`, `atrac3plus_data.h`, `atrac3plusdsp.c`, `atrac3plusdec.c`, `atrac.c`, `sinewin_tablegen.h` are what the ATRAC3plus model was written from and what `tools/gen_at3p_tables.py` transcribes (`--check` SKIPs without it) |
| `ffmpeg/libavcodec/h264_cabac.c` | ffmpeg's CABAC decoder source (LGPL, never copied): its `cabac_context_init_I/PB` tables, indexed by ctxIdx, are the cross-check for `tools/cabac_tables.py`'s transcription of the spec PDF (`tools/gen_cabac_tables.py`) |
| `H.264.1_bitstreams/AVCv1/` | the H.264.1 "Constrained Baseline, Baseline, Extended and Main" package, 136 zips. Each holds the Annex-B stream (`.jsv`/`.264`/`.26l`), the reference decode (`.yuv`) and usually a `-trace.txt` syntax trace made at donation time -- a second SE golden independent of our JM build |

Only this package is needed: a Main decoder's requirement is H.264.1 Table 1; Table 4 adds
Constrained Baseline (CAVLC) streams, which this core refuses. The other packages are
profiles UMD never uses (High/FRExt 8x8 transform, SVC, MVC, professional, 3D).

## Oracles and tools

- **ffmpeg / ffprobe** — H.264 decode (bit-exact reference for reconstruction), header
  traces (`-bsf:v trace_headers`), ATRAC3plus decode (float; bounded-error reference).
- **JM reference software** (`ldecod`) — syntax-element traces for the CABAC gate, the
  only decoder that has them (ffmpeg traces headers only). In `$UMD_REFS_DIR/JM`
  (`$H264_JM_DIR` overrides); `tools/h264_trace_ref.py` runs and normalises it. JM 18.4
  vs the last release 19.0: no difference for Main-profile decoding (unchanged since 2003).
- **PPSSPP / JPCSP** — the PSP emulators, for how the PSMF/CLPI structures are consumed.
- **Disc menus (Phase 9), ranked** (`menus.md` §2):
  1. **A real PSP** with custom firmware (ARK-4 plays UMD Video ISOs from `/ISO/VIDEO/`),
     the ground truth.
  2. **JPCSP** `jpcsp.format.rco` (the VSMX interpreter, the player objects `MoviePlayer`,
     `Controller`, `Resource`, `Timer`) and `jpcsp.GUI.UmdVideoPlayer`: the only open
     implementation of the player API, a draft reconstruction, and runnable for trace diffs.
  3. **rcomage**: the RCO / VSMX decompiler, for reading scripts.
  4. **PPSSPP** is *not* a menu reference: it is HLE, runs no firmware, and has no UMD
     Video player (its docs say to use a real PSP).
- Local UMD images: `$UMD_ISO_DIR` (never commit media; fixtures are cut slices).

## MiSTer

- **MiSTer_DVD** — the sibling project this core was scaffolded from: framework edits,
  build gates, process, the HIL harness, and the modules listed in `harvest.md`.
- Template_MiSTer and Main_MiSTer (`hps_io`, `user_io.cpp`, `menu.cpp`, `mra_loader.cpp`
  for the MGL rules), mister-devel's MkDocs documentation.
- Quartus 17.0.2 via `raetro/quartus:mister`.
