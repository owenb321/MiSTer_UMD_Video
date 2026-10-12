# PNG decode in fabric (P7 pre-work)

`umd/png/`: a PNG decoder that takes bytes and emits straight RGBA8888 pixels with
their (x, y). Built standalone as parallel pre-work for Phase 7 (subtitles), ✅ MERGED (PR fj#28,
2026-09-30); wired into `emu` ✅ MERGED (PR fj#29), ✅ HW-CONFIRMED. Phase 9's menus (`docs/menus.md` §4) reuse it for the RCO
art, which is why it covers the whole PNG spec and not only the subtitles' 4-bit indexed
images.

Status: ✅ bit-exact against zlib and libpng on 323 synthetic cases (straight and under
stalls), the 109-unit disc sample, **every one of the 336,339 subtitle units of the 70
discs with subtitles and every one of the 6,150 menu PNGs of the 89 discs' RCO files**
(`bench/umd/run_png.sh --sweep`); 23 mutations each caught by their own arm; area and
timing measured standalone (§6). Next: P7 integration (§8).

## 1. What the discs carry (measured, `tools/png_corpus.py`)

336,339 subtitle units over 70 of the 89 images in the local library, cached once
(`--dump`) and audited by a strict reader (`--report`): the CRC of every chunk, zlib's
Adler and stream end, bytes after the stream, the exact row-byte total.

- **Every unit is clean.** Not one CRC, Adler, trailing byte or short image. Refusing a
  damaged PNG therefore blanks no real subtitle.
- Every unit is a 4-bit indexed PNG with a 16-entry PLTE and a 16-entry tRNS. It has one
  IDAT, uses filter type 0 on every row, and is not interlaced.
- zlib streams with CINFO 0-7 (the encoder trims the window) and FLEVEL 3; one dynamic
  block each. **Match distances reach 32,486**, so the 32 KB window is needed in
  practice, not only by the spec.
- Largest: 638 wide (The Animatrix), 441 tall (Stargate), 105,750 bytes inflated, 7,194
  bytes of PNG (Toy Story). Right edge 680 (The Animatrix), bottom edge 480 (Hero): **all
  inside 720x480**. Longest duration 1,279,278 ticks = 14.2 s (Shaun of the Dead).

**The menu art** (`tools/rco_png.py`, 2026-09-26): every RCO's image region cut and
accounted for. This population exercises what the subtitles never do:

| type | count |
|---|---|
| 8-bit indexed | 4,058 |
| 8-bit indexed, **Adam7** | 1 |
| 4-bit indexed | 718 |
| 2-bit indexed | 14 |
| 1-bit indexed | 129 |
| RGBA8 | 1,148 |
| RGB8 | 82 |

- **Sizes:** up to 512 x 512; up to 42 IDAT chunks; 820 KB inflated; 339 KB of PNG.
- **Sweep result:** all 6,150 decode identically to libpng, the Adam7 one included. The
  sweep compares pixels in pass order; the unfiltered-row arm is skipped for an
  interlaced image.
- **The whole-spec decision paid off:** Adam7 is on a real disc, not only in the
  synthetic set.
- **Also 51 JPEGs:** those are not this decoder's (`docs/menus.md` §1).

## 2. Architecture

```
in_* --> png_chunks --z--> inflate --f--> png_unfilter --r--> png_pixel --> px_*
         (signature,        (zlib +         (filters 0-4,      (unpack, palette,
          CRC-32, IHDR,      DEFLATE,        Adam7 passes)      tRNS / key, 16->8)
          PLTE, tRNS)        32 KB window)
```

- **Handshakes:** valid/ready throughout. The input is a *unit*, with `in_last` on its
  final byte (the subtitle unit header gives its length). `start` begins a unit.
- **`done`** pulses once the unit is consumed to `in_last` AND every stage has drained,
  or once the unit is drained after the first fatal verdict.
- **`err`** is the first fatal verdict and **`warn`** holds the benign ones (§4).
- **Pixels stream out as they are decoded.** A verdict found later (a bad Adler, a bad
  IEND CRC, a short image) arrives after pixels went out: **the consumer holds the image
  until `done` and discards it when `err != 0`.**
- **Taps** for the bench: the inflated bytes as the unfilter takes them, and the
  reconstructed row bytes as the pixel stage takes them.

| Module | What | Memories |
|---|---|---|
| `png_chunks.sv` | signature; chunk framing; CRC-32 (reflected 0xEDB88320, 8 steps unrolled, a byte a cycle); IHDR checks and the size bound; PLTE -> palette RAM; tRNS (committed only after its CRC); the IDAT payload to inflate | (registers) |
| `inflate.sv` | zlib header + Adler-32; stored / fixed / dynamic blocks; puff's canonical decode, **one code bit a cycle**; tables rebuilt per block by a Kraft pass (15 cycles) and a counting sort (a symbol a cycle; fixed blocks go through the same builder) | window 32 KB, symbol table 512x9, code lengths 512x4 |
| `png_unfilter.sv` | filters 0-4 with a step of bpp = 1..8 bytes; the previous row read one column ahead (no forwarding); Adam7's 7 passes, empty passes skipped, "no previous row" at each pass start | previous row 8 KB |
| `png_pixel.sv` | samples unpacked MSB first, the row padding dropped; palette + tRNS alpha; grey below 8 bits by bit replication; 16-bit samples to their high byte; the tRNS key compared at the raw depth; (x, y) from the pass geometry | palette 256x24, alpha 256x8 |
| `png_top.sv` | composition; the first-verdict latch; `done` | -- |
| `png_pkg.sv` | the verdict codes (tools/png_golden.py's `E` / `W` must equal them) | -- |

**Output format:** straight (not premultiplied) RGBA, exactly as libpng expands it, so
PIL / libpng score it bit-exactly. The P7 shape (roadmap Phase 7, decided 2026-09-25)
puts a premultiplied ARGB plane in DDR3. Premultiplication and the DDR3 writes belong
to the plane writer (§8).

## 3. Scope and bounds

**The whole PNG spec** (decided with the maintainer, 2026-09-25): every colour type (0,
2, 3, 4, 6), every bit depth (1, 2, 4, 8, 16), and Adam7. Adam7 was first proposed as
"refused loudly". The maintainer asked why, and there was no good reason: its cost in
the decoder is a pass counter and a 7-entry table. Its real cost is downstream. Pixels
arrive in pass order, so the plane writer sees strided writes. For a once-per-image
decode that occupancy is small.

**The one bound, a deviation from the spec maximum** (width up to 2^31 - 1), approved
with the plan:

- **Row bytes <= 8192** (`png_pkg::MAX_ROW_BYTES`): the previous-row RAM, 8 M10K. That
  is 1,024 pixels even at 16-bit RGBA (2x the 720-wide frame), and 8,192 at 8 bits or
  fewer.
- **Width and height <= 65535**: 16-bit coordinates.

Past either bound, the PNG is refused with `E_SIZE` at its IHDR, before any data. It is
never truncated. Listed in `docs/spec_hardening.md` "Known deviations".

**Where the output follows libpng rather than the letter of the spec** (each measured
with `tools/png_oracle.c`):

- A tRNS key below 16 bits is **masked to the depth** before the compare. Key 7 at 2 bits
  matches the sample 3, and an RGB8 key 0x0101 matches 1 (libpng's `png_do_expand`).
- A palette index at or past the PLTE entries draws **opaque black** (`W_INDEX`). An
  index past the tRNS entries is opaque.
- 16-bit samples keep their **high byte** (libpng's `strip_16`, not the rounded
  x255/65535).

## 4. Verdicts

`err` is fatal: the image must not be shown. Each DEFLATE code is one of zlib's
messages, so the golden checks the RTL against zlib case by case. The PNG-level codes
are checked against libpng's verdict.

| code | name | meaning |
|---|---|---|
| 1 | SIG | not the PNG signature |
| 2 | CRC | a critical chunk's CRC-32 |
| 3 | IHDR | IHDR length, a field, or the type/depth combination |
| 4 | SIZE | our bound (§3) |
| 5 | CRITICAL | an unknown critical chunk, or a type byte that is not a letter |
| 6 | ORDER | length >= 2^31; IHDR not first or twice; PLTE after IDAT; a palette image without PLTE; IEND before IDAT |
| 7 | PLTE | a palette image's PLTE of 0 or > 256 entries, not 3n bytes, or twice |
| 8 | TRUNC | the unit ended (`in_last`) before IEND |
| 9-12 | ZCHECK / ZMETHOD / ZWINDOW / ZDICT | the zlib header (PNG forbids a preset dictionary) |
| 13-24 | BTYPE, STORED, NSYMS, CLSET, REPEAT, NOEOB, LITSET, DISTSET, LITCODE, DISTCODE, FAR, ADLER | zlib's messages, one each |
| 25 | ZSHORT | the IDAT data ended inside the zlib stream |
| 26 | FILTER | a filter type > 4 |
| 27 | SHORT | the zlib stream ended before the last row |

`warn` is benign (bits): ANC_CRC (an ancillary chunk's CRC; the chunk is discarded),
ZEXTRA (bytes after the zlib stream, including a later IDAT run), LONG (inflated bytes
past the last row), AFTER_IEND, IGNORED (a malformed or misplaced tRNS, a PLTE in a grey
image, data in IEND), INDEX.

**The first error in stream order wins.** This matches libpng: a corrupted IDAT byte
reports its inflate error, not the chunk's stale CRC. A chunk-level error waits
(`png_chunks` `C_PEND`) until the pipeline is *quiet*: inflate waiting for input or
finished, and its output taken. So an inflate or filter error in bytes already
delivered, still being decoded, is reported first. Without the wait, the verdict
depended on handshake timing (found by the `+stall` run). Two cases pin it, and each
goes RED alone when `quiet` is tied high (mutation M19):

- a unit that ends on the byte inflate refuses;
- an IDAT whose last byte completes a too-far distance, with a bad CRC.

**The IDAT data ends at the first chunk that is not IDAT.** If the zlib stream was not
complete, that is `E_ZSHORT`. If it was complete, a later IDAT run is extra data
(`W_ZEXTRA`). This matches libpng ("Not enough image data" / accepted).

**Stricter than libpng**, documented and marked so in the golden:

- a bad IEND CRC (libpng only warns);
- a short image, i.e. the zlib stream complete but rows missing (libpng: benign "Not
  enough image data");
- rows past 8192 bytes or dimensions past 65535 (§3).

**Not zlib's verdict, once:** a code-length code with no codes at all is refused as
`E_CLSET` when a length is decoded. zlib decodes it as zeros and then reports a missing
end-of-block. No encoder writes such a stream.

## 5. Verification

**Oracles, never a model written for this RTL:**

- **zlib**: the inflated bytes, and the verdict on every DEFLATE case.
- **libpng** (`tools/png_oracle.c`, compiled into `.sim/`; needs `cc` and the libpng16
  headers): every pixel at 16-bit precision, and the verdict on every PNG-level case.
- **PIL** cross-checks libpng where PIL is right, and supplies the palette indices for
  the row arm.
- **ffmpeg** cross-checks the 16-bit types.

Measured 2026-09-25: PIL clips grey16 to 255 and compares an RGB16 tRNS key at 8 bits.
PIL and ffmpeg both ignore a grey key at 2 bits, and ffmpeg at 1 bit. So neither can be
the oracle alone. The generator fails on any disagreement outside those documented gaps.

**`tools/png_golden.py`** writes the fixtures:

- A **DEFLATE bit writer** for the streams zlib's encoder never makes:
  - stored LEN 0 and 65535;
  - HLIT 286 / HDIST 30 / HCLEN 19;
  - distance 32768, and distance 20000 in a fixed block with length 258 coded as 284+31;
  - a single 1-bit distance code, and an empty distance tree;
  - 15-bit codes, both in a table and actually decoded;
  - a repeat-16 across the literal/distance boundary;
  - mixed stored/fixed/dynamic blocks with matches into earlier blocks.
- A **PNG writer** that forces the filter row by row. It covers every legal
  (type, depth), plain and Adam7, including sizes whose passes are empty. It also covers
  sub-byte widths ending mid-byte, split and zero-length IDAT, ancillary chunks, tRNS in
  every form, and the size bound exactly and one past it.
- **61 refused cases**, one defect each. Each verdict is checked against zlib's message,
  libpng's message (`IDAT: <zlib message>`, `CRC error`), or marked design-defined.

**Coverage** comes from `tools/inflate_ref.py` (a puff port, tested against zlib by
`tools/tests/test_inflate_ref.py`) and the encoder side of the filters. The DEFLATE and
filter counters count an event whose mis-handling **changes the output**:

- a match farther than 16 KB whose byte differs from what a 16 KB window would alias to;
- an Average sum over 255;
- the two Paeth ties that change a result (pa/pc with a != c, pb/pc with b != c; a pa/pb
  tie with a != b forces pc = 0 and cannot matter, found by an equivalent mutant);
- an Adam7 pass starting on Up / Average / Paeth after a nonzero pass;
- ... 36 items, all required (`png_golden.py` `need`).

Three of them are **construction markers, not measurements**: `trns_key_hit`,
`trns_key16_lowbyte_miss` and `trns_index_past_trns` are counted when the case is built,
not from the decoded image. What backs them is the mutations: M12 (the default alpha past
tRNS) and M23 (the key mask) each go RED on those cases.

**`bench/umd/run_png.sh`** (`png_tb.sv`, Icarus):

- The synthetic set runs straight and with random input gaps and output back-pressure.
- With `$UMD_ISO_DIR`, the disc sample: the largest unit of every disc, plus Akira's and
  Family Guy's first 20.
- `verilator --lint-only -Wall`.

The arms are `[inflate]`, `[unfilter]` (under the golden's padding mask), `[pixel]`
(header included), `[err]`, `[csum]`, `[warn]`, `[hang]` and `[stall]`.

**`--red`**: 23 mutations, each caught by its own arm:

- the distance extra bits dropped (the roadmap's named arm);
- the length-284 base;
- a 16 KB window;
- the repeat-17 base;
- the stored NLEN check;
- the over-subscription check;
- both Paeth ties;
- the Average sum at 8 bits;
- bpp for RGB16;
- the previous row kept across passes;
- the pass x0;
- the default alpha past tRNS;
- the nibble order;
- the 2-bit grey scale;
- the row padding;
- the key mask;
- `px_ready` ignored;
- the CRC and Adler checks;
- `quiet`;
- `W_ZEXTRA`;
- a `done` that never comes.

**`--sweep`**: every cached unit through Verilator (`bench/umd/png_sweep_main.cpp`), with
the oracles in-process: zlib's `inflate()`, libpng with no transform for the unfiltered
rows, and libpng expanded for the pixels. No fixtures, one job per disc.

Found by the benches:

- The pending-verdict race (§4).
- `png_tb`'s pixel array was smaller than a 532x365 subtitle, and `$readmemh` silently
  kept the previous case's pixels. The arrays now exceed a whole 720x480 frame, and an
  oversize fixture is fatal.

## 6. Measurements

**Throughput** (clock cycles per inflated byte, whole pipeline):

- 4.44 on the synthetic set;
- 4.43 on the disc sample;
- 4.55 on Akira's 1,251 units;
- worst unit 13.1 (a tiny image where fixed costs dominate).

The largest subtitle (105,750 bytes inflated) takes ~470k cycles: **17 ms at 27 MHz,
5 ms at 90 MHz**. A 512x463 RGBA8 menu texture (948 KB) takes ~0.16 s at 27 MHz.

**Area** (`USE_DOCKER=1 tools/synth_unit.sh png_top umd/png/*.sv`, Analysis & Synthesis
only, 2026-09-25): **2,221 ALMs (estimate), 3,263 LUTs, 2,023 registers, 342,528 block
bits** -- inside the roadmap's "+~2-3K" for P7 before the compositor.

| entity | LUTs | registers | memory |
|---|---|---|---|
| `inflate` | 1,638 | 879 | window 32768x8 (32 M10K), symbols 512x9, lengths 512x4 |
| `png_unfilter` | ~632 | ~325 | previous row 8192x8 (8 M10K) |
| `png_chunks` | 617 | 504 | -- |
| `png_pixel` | 350 | 308 | palette 256x24, alpha 256x8 |

Every RAM is inferred as a simple dual-port altsyncram (the map report's RAM summary lists
all six). `inflate`'s `offs` and count arrays stay in registers, which is intended: 15
entries, read at random each cycle. **M10K: ~44** (32 window + 8 row + 4 small). The
roadmap's P7 line said +6 M10K; the spec-maximum window alone is 32. M10K is not the
scarce resource (~270 of 553 in use after P6's estimate); the budget row is corrected.
Area left on the table if it is ever needed: `png_chunks` keeps 32-bit length / byte
counters and a 48-bit key shadow; `inflate`'s three count tables could share one
register file. **Taken (2026-09-30, `area_plan.md` A3):** IHDR's width / height as 16 bits
plus two flags each (the same E_IHDR / E_SIZE verdicts), and the tRNS key written straight to
its outputs under `key_valid` (a bad CRC leaves it 0; `seen_trns` ignores a later tRNS).
Measured in the overlay: -75 registers, **-6.5 ALM** (the registers packed into ALMs used
anyway). The 32-bit chunk counters stay (a chunk is u31 by the spec), and `inflate`'s tables
were not attempted: on this evidence they would return tens of ALM for an intricate change. Timing: a full fit of the subtitle chain around it (`tools/fit_unit.sh sub_top`,
2026-09-26, `docs/subtitles.md` §2) puts `png_top`'s clock at **61.9-63.0 MHz** when asked
for 90, and 49-51 MHz when asked for only 27. It does not close at 90: it runs on clk_sys
(27 MHz), where the largest subtitle takes ~17 ms.

## 7. Rejected alternatives

- **Table-lookup Huffman decode** (zlib's 9-bit first-level tables): several symbols a
  cycle, bought with area. Nobody needs the speed: a subtitle is decoded in
  milliseconds, once.
- **The window in DDR3**: saves 32 M10K, but costs occupancy and latency on every match
  byte, and M10K is not the scarce resource (~270 of 553 in use after P6's estimate).
- **The inflate window as the previous row**: it holds FILTERED bytes, and the filters
  need reconstructed ones.
- **A Python model of our own as the golden**: it would share our reading of the spec.
  zlib and libpng are the reference implementations. `inflate_ref.py` only counts
  coverage.
- **Refusing Adam7**: see §3.

## 8. Known limitations and the next step

- **Not integrated.** P7 proper, after P5 and P6 land:
  - `sub_timing` (the unit header, PTS);
  - the ram2 plane writer, which premultiplies and handles Adam7's strided writes;
  - the plane compositor;
  - `UMD.qsf` and `tools/lint_undriven.sh`;
  - the clock domain: clk_sys at 27 MHz is enough, and timing has not yet been closed
    in a fit.
- The row arm of the sweep covers non-interlaced images only. The corpus has none that
  are interlaced, and the synthetic set covers Adam7's rows.
- Ancillary chunks other than tRNS are skipped (no gAMA, sBIT, bKGD): libpng's
  `png_oracle` expansion ignores them too.
