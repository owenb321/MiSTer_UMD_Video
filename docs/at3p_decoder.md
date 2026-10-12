# Phase 6 — the ATRAC3plus decoder (`umd/at3p/`)

Design notes for the fabric ATRAC3plus decoder: the demux's audio byte stream in, s16
stereo PCM out. Status and checklist: `roadmap.md` Phase 6. This note records the *why*,
what was measured, the fixed-point formats, and what is deliberately not built.

**Status (2026-09-27): ✅ MERGED (PR fj#17), ✅ HW-CONFIRMED (P6a).** Built standalone in parallel with P5
(the maintainer, 2026-09-25); after P5 merged (PR fj#13) the branch was rebased onto `main`
(2026-09-27, both gates still ALL GREEN) and the wiring into `emu` (P6a, S7) began.

| Piece | State |
|---|---|
| Tables from ffmpeg n9.0.1 (`tools/gen_at3p_tables.py` → `tools/at3p_tables.py`) | ✅ `--check` |
| Float reference model (`tools/at3p_ref.py`) vs the ffmpeg binary | ✅ 787 tracks, worst 0.016 LSB |
| Fixed-point model (`tools/at3p_fixed.py`) vs the ffmpeg binary | ✅ 787 tracks, worst 0.615 LSB (S4.3) |
| Microcode (`umd/at3p/*.uasm`) vs the models (`tools/at3p_emu.py`) | ✅ parse record and PCM bit-exact |
| RTL (`at3p_seq.sv`, `at3p_vec.sv`, `at3p_top.sv`) vs the emulator | ✅ `run_at3p_seq.sh`, `run_at3p.sh` (8 arms) |
| Area / timing, standalone (≤ 5K ALM) | ✅ 2,229 ALM, 87 M10K, 1 DSP, 40.1 MHz at -40 C (S6) |
| Model tests (`tools/tests/test_at3p_ref.py`, 6 RED arms in `red_umd.py`) | ✅ |
| In `emu` (audio ring, 48 kHz NCO, A/V gate, `AUDIO_L/R`, HUD row) | ✅ P6a, PR fj#17, rig-confirmed (S7) |

## 1. What ATRAC3plus is, and where its definition comes from

There is **no public specification**. The only description is ffmpeg's decoder,
reverse-engineered by Maxim Poliakovski (2010-2013): `libavcodec/atrac3plus.c` (the
bitstream parser), `atrac3plusdsp.c` (the DSP), `atrac3plusdec.c` (the frame loop),
`atrac.c` (gain compensation, shared with ATRAC3). Pinned to **n9.0.1**, the same version
as the installed oracle binary, in `$UMD_REFS_DIR/ffmpeg-9.0.1/` (`references.md`).

- **Logic** — written from reading ffmpeg, never copied: `tools/at3p_ref.py` is our own
  code, structured the way the RTL is, and is checked against ffmpeg's *output* only.
- **Tables** — the Huffman codebooks, weight / shape tables, quantiser steps, noise
  table and IPQF prototype are format facts a decoder cannot be built without. They are
  **transcribed with credit** (decided by the maintainer, 2026-09-25): LGPL-2.1-or-later
  may be carried under GPL-3.0-or-later (LGPL-2.1 §3). `tools/gen_at3p_tables.py` parses
  the pinned source and writes `tools/at3p_tables.py`; `--check` regenerates and
  compares. NOTICE and the manual's acknowledgements carry the credit.

A frame (one AU, 2048 samples a channel at 48 kHz, 23.4375 AUs a second) is: a start
bit (0), then channel units, each a 2-bit type (mono / stereo / extension / terminator).
A UMD stereo track is one stereo unit per frame. A unit carries, in order: the number
of quantisation units (≤ 32) and a mute flag; word lengths (4 coding modes, each with
per-channel variants, weights, fill modes); scale-factor indices (4 modes, VQ shapes,
weights); code-table indices; the Huffman-coded spectrum (112 tables, grouping, sign
bits); power-compensation levels; stereo swap / negate flags per subband; the IMDCT
window shape per subband; gain-control points (number, level, location, each with 4
coding modes); tonal components (GHA sine waves: envelope, count, frequency, amplitude,
phase); a global noise field (parsed, unused by ffmpeg).

Synthesis per channel: dequantise + power compensation (noise fill) → stereo swap /
negate → per 128-line subband a 256-point IMDCT with a sine or steep window → gain
compensation with overlap-add → tones added in the time domain → a 16-band inverse PQF
(a 16-point DCT and a 384-tap polyphase prototype) → 2048 samples.

**State that carries between frames** (each two frames deep: current and previous):
window shapes, gain data, tone envelopes and wave parameters, the overlap buffer, the
IPQF history. ffmpeg keeps these as pointer-swapped pairs and **does not clear what a
frame does not write** (e.g. a window-shape entry past this frame's subband count keeps
the value of two frames ago). The model keeps exactly that, stale entries included; the
RTL does it with bank = frame parity (S3.2).

**Surprises found reading the source:**
- `atrac3p_spectra_xlats` holds 8,987 entries but the 87 codebooks built from it
  consume 8,366; the trailing 621 carry copy-pasted comments and are never read.
- Power-compensation noise restarts at the subband's RNG index for **every** quantisation
  unit (the noise vector is not offset by the unit's position in the subband).
- The steep window zeroes 32 samples, ramps over 64 and leaves the last 32 of that half
  **unmultiplied** (a first fixed-point model zeroed them: 161 LSB on Godzilla).
- Scale factors, mantissa steps and power levels are exact short binary fractions
  (≤ 16-bit mantissas; power levels are multiples of 1/32); the noise table is Q15.
  The original is evidently a fixed-point design; the fixed model holds these exactly.

## 2. The oracle

### 2.1 The chain

```
disc .iso ─► psmf_ref / at3p_extract.split_aus ─► AUs ─┬─► at3p_ref.parse_frame ─► float synthesis ═══ ffmpeg (float, f32le)
                                                        │                        ─► at3p_fixed      ═══ ffmpeg ±N LSB (s16)
                                                        └─► at3p_extract.to_oma ─► ffmpeg -f oma
```

Comparisons are made on **ffmpeg's float output** (`-f f32le`), in units of an s16 LSB
(float × 32768), so the verdict is not blurred by ffmpeg's own s16 conversion. Each
window starts cold on both sides (a fresh decoder on the same cut).

### 2.2 The float path: the reading of the format is right

`tools/at3p_ref.py` mirrors ffmpeg's arithmetic with its tables rounded to float32 the
way ffmpeg rounds them (the transforms in float64). Gate: ≤ 0.05 LSB.
**Measured 2026-09-25 (`tools/at3p_sweep.py`, every clip and audio track of the 33+ disc
library, 3 windows × 48 AUs each): 787 tracks, worst 0.016 LSB, worst window RMS 0.0018
LSB, 0 refusals; 5 skipped (Desperado, a zero-filled rip).** A parse error desynchronises
the bitstream and shows as noise of hundreds of LSBs, so the float path agreeing to a
hundredth of an LSB on every track is the proof that the parser and the synthesis read
the format as ffmpeg does.

### 2.3 Coverage: what the library exercises

`at3p_ref.cov_universe()` lists 204 coding paths (every word-length / scale-factor /
code-table / gain / tone coding mode per channel, the weights, fills, VQ shapes, all 112
spectrum tables, skipped groups, master copies, swap / negate, steep windows, gain
points and replication, tone sharing / master swap, mute). Each counter counts what the
path *changed*, not that it ran. **The library reaches 203 of 204; never reached: the
mute flag** (a whole unit zeroed). No disc sets it, so `test_at3p_ref.py [mute]` sets
it: the flag sits at bit 8 of a frame (start bit, unit type, 5-bit unit count), and
flipped into six real frames ffmpeg is the oracle for the path (float and fixed within
their gates). Its `[refuse]` arm does the same for a mono unit: the model refuses and
ffmpeg drops the frame.

Unreached by construction: the refusal paths (S3.5) and bit overrun. **Unreached in
practice (scanned, ~36K frames on three discs):** power compensation in subband 0 while
its two lowest quantisation units are coded (ffmpeg skips those two units; no frame
has noise active there with them coded). Decoded as ffmpeg does, untested: a RED
mutation of that skip survives every arm, so it was replaced by one the data can see.

## 3. Architecture

### 3.1 Clock, throughput, one datapath

The decoder runs on **`clk_sys` (27 MHz)**: the demux's audio port is on `clk_sys`, as
MiSTer_DVD's audio ring, NCO and A/V gate are — no clock crossing, and no timing pressure
(`clk_dec` is the tight domain). Budget: 27 MHz / 23.4375 AU/s = **1,152,000 cycles a
stereo AU**. One 27×27 signed multiplier (one DSP block) and a wide accumulator do all
the arithmetic.

| Stage | MACs a stereo AU (16 subbands) |
|---|---|
| IMDCT, direct form, 128 × 128 per subband (the half transform; the other half mirrors) | 524,288 |
| IPQF DCT, 16 × 16 per output sample | 65,536 |
| IPQF FIR, 12 taps × 2 × 16 per output sample | 98,304 |
| dequantisation + noise, gain, windows, tones | ~25,000 |
| parse (bit-serial Huffman: ~1 cycle a coded bit) | ~6,000-9,000 |
| **total** | **~720,000 (63 % of the budget, 1.6x real time)** |

The plan's first target (≤ 575K, half the budget) is not met by the direct IMDCT. The
alternative is the N/4-point complex FFT (~1,300 multiplies a subband instead of 16,384),
at the cost of bit-reversed addressing, a twiddle ROM and butterfly sequencing (more
ALMs). Direct form first: least logic and the simplest to verify. Two cheap savings
remain if needed: skip a subband whose residual is all zero (its IMDCT is zero), and
process only the `num_subbands` the frame codes (already the case). The measured cycle
count decides.

### 3.2 Streaming parse; the parse record

The parser reads the frame's bits strictly in order, with at most a 12-bit look-ahead
for a Huffman code, so **it parses the byte stream as it arrives: no frame buffer**. A
frame buffer sized to the format's maximum (params' 10-bit size field: 8,192 bytes)
would cost 8 M10K for a buffer at most 1/8 full on these discs. The byte counter is sized
to the maximum (13 bits); after the terminator the rest of the frame is drained, and a
read past the frame's end returns zeros, is counted, and flags the frame.

The parse writes the **parse record** (per channel: word lengths, scale factors,
power levels, the 2 × 2048 quantised spectrum (6-bit), window shapes, gain data, tone
envelopes, the unit's wave parameters, swap / negate flags) into small RAMs. The
synthesis reads only the record. History that carries between frames is in two banks
selected by frame parity, so what a frame does not write keeps the value of two frames
ago, as in ffmpeg.

The bit reader is **bit-serial** (one byte held, one bit a cycle, as `rbsp_reader.sv`):
no barrel shifter, at ~5.5K parse bits a frame a few thousand cycles.

Canonical Huffman decoding: per codebook, the count of codes of each length (1..12) and
the symbols in order; the decoder walks the lengths **one bit a cycle, consuming as it
goes**: code = code << 1 | bit, found when code - first < count, else
first = (first + count) << 1. 121 codebooks (the 112 spectrum tables' 25 aliases
resolved in the header ROM), 9,355 symbols.

**A deliberate deviation from ffmpeg:** a code that is in no codebook (a "hole" of an
incomplete codebook; only a corrupt stream has one) cannot be un-read by a decoder that
consumed its bits, so the fabric **refuses the frame** (`E_VLC_HOLE`: silence, counted)
where ffmpeg returns -1, consumes nothing and decodes on. A peek-and-match decoder
would follow ffmpeg but needs a 12-bit window reader (two barrel shifters, ~250 ALM).
The emulator (`tools/at3p_isa.py`) implements the refusal; the model keeps ffmpeg's
behaviour. **No disc in the library has one:** `tools/at3p_scan.py` parsed every AU of
every track, 26,325,445 AUs of 787 tracks: 0 holes, 0 refusals (2026-09-26).

### 3.4 A microcoded sequencer, hardwired vector loops (decided 2026-09-25)

**The parse and the synthesis control run as a microcode program; the heavy inner loops
are hardwired "vector ops" on the one multiplier.**

- **Sequencer:** a 16 × 16-bit register file, an ALU (add / sub / logic / shifts /
  compares / sign-extend / log2 / abs / min / max), load / store to the parse record,
  constant-table reads, `GET n` from the bit reader, `VLC table`, branches, call /
  return, `ERR code`. The whole parse is a ROM program, the AU header and the byte-level
  resync included.
- **Vector ops (hardwired), args in r8-r15:** dequantise a quantisation unit; add its
  noise; normalise the subband's residual; the IMDCT with window and gain; one tone
  oscillator into a region; a window multiply on a region; add the regions into the
  time buffer; the IPQF of a channel. They share the multiplier, the accumulator and
  one rounding / saturating shifter.
- **Golden chain:** `tools/at3p_isa.py` holds the assembler and an instruction-level
  emulator.
  - The emulator's parse record is scored against `at3p_ref.parse_frame`, which ffmpeg
    validates (`tools/at3p_emu.py`: every field, stale history entries included).
  - Its PCM is scored bit-exact against `at3p_fixed.py`.
  - The sequencer RTL is scored against the emulator by trace: every register write
    and every store, in program order (`run_at3p_seq.sh`).
  - The whole decoder RTL is scored after **every vector op** by checksums of the engine
    buffers (residual, time signal, overlap, tone regions), and on every PCM pair
    (`run_at3p.sh`). That names the first engine that differs. The vector ops'
    semantics in the emulator are written against `at3p_fixed.py`'s functions, and
    the emulator's PCM equals the fixed model's frame by frame, so each op is anchored
    to the independent model, not to itself.

**Rejected: a hardwired parse FSM.** ffmpeg's parser has roughly 60 coding-mode variants
(four modes of word length, scale factor, code table and of each of the three gain
fields, each with master / slave forms, then the five tone fields). As one state machine
that is an estimated 2-3K ALM of muxes on its own. The ≤ 5K target
cannot carry that alongside the datapath. As microcode it is ROM words, debugged in
Python against the model before any RTL runs. The cost is interpretive cycles, about
25-40K a frame for the parse, against a 1.15M budget.

### 3.6 The RTL (`umd/at3p/`)

| File | What |
|---|---|
| `at3p.uasm` (+ `at3p_gain.uasm`, `at3p_tone.uasm`, `at3p_synth.uasm`) | the program: AU header and resync, the parse (every coding mode), the synthesis control; 2,133 words |
| `at3p_seq.sv` | the sequencer: one instruction a cycle for ALU / branch / store, two for a load; the bit reader; the Huffman unit; record RAM (2K × 16), constant ROM, spectrum (4K × 6), gain-exponent table; a trace port |
| `at3p_vec.sv` | the 14 vector ops on one 27 × 27 multiplier, a 64-bit accumulator, one rounding shifter / post-adder / saturator; one quarter-wave cosine ROM for every angle; the IPQF history as a 24-entry circle (ffmpeg's mod-23 lookup is exactly that) |
| `at3p_top.sv` | the two joined: AU bytes in, stereo pairs out, status (frames, refusals + last code, overruns, saturations, PCM clips) |
| `*.mem`, `at3p_ucode.svh` | generated by `tools/at3p_isa.py --asm` (`--check` in the runners): never edited |

Measured in simulation (`run_at3p.sh`, 2026-09-26): **638-725K cycles a frame**, the
worst 62.9 % of the 27 MHz budget (1.59x real time); the sequencer alone, with stub
engines, 69-107K. The IMDCT's 128 × 128 MACs a subband dominate; the IPQF is ~90K a
channel.

**The datapath is two stages.** The first standalone fit closed at only 27.9 / 27.4 MHz
(85 / -40 C): the worst paths ran from the cosine ROM through the multiplier, the
64-bit accumulate, the 64-bit rounding shifter, the post-adder and the saturator into a
RAM write, one cycle. The issue side now registers the product (in the DSP block) with
every control and write address; accumulate / round / saturate / write happen a cycle
later. Four result consumers gained a wait state, the IMDCT's output sample a write-back
cycle: +2-3 % cycles. **Refit: 41.1 / 40.1 MHz** (1.48x the clock at the binding corner).

Written to the Quartus 17 lessons (CLAUDE.md): no `function automatic` helpers and no
`N'(expr)` size casts in the synthesised RTL (the width helpers are named signals); every
RAM a power-of-two depth or a ROM; M10K buffers zeroed at power-up (as ffmpeg's context).

### 3.5 Refused, loudly

The fabric decodes 48 kHz stereo: one stereo channel unit per frame. It refuses (an
error counter and a code, the frame's samples muted) an AU header with another sample
rate or channel id, a mono or extension unit, and every check ffmpeg makes (start bit,
quantisation-unit count 29-31, word-length / scale-factor ranges, invalid positions,
gain location order, more than 48 tones, GHA amplitude mode 0). The model's `At3pError`
codes name them; the RTL uses the same names.

## 4. The fixed-point synthesis (`tools/at3p_fixed.py`)

The bit-exact golden of the RTL. Round-half-up at every shift; every stage boundary
saturates and counts. The PCM output saturates legitimately: ffmpeg's float output
passes full scale on loud passages (Aliens clip 2) and its own s16 conversion clips the
same samples, so the comparison clips ffmpeg's float too. Every other stage must never
saturate on a legal stream: the sweep fails if one does.

| Quantity | Format | Why |
|---|---|---|
| X, residual spectrum | Q20, 40 bits, block-normalised per subband to 27 bits | legal maximum ~87K (a 6-bit value × the largest step, plus noise); 27 bits is the multiplier port; see S4.2 |
| T, time domain (IMDCT out, overlap, gain out, tones) | Q6, 24 bits | full scale ≈ 25-30K; 17 integer bits are 4x headroom; 1/64 is ~0.02 output LSB |
| D, IPQF DCT out / history | Q16, 27 bits | measured ≤ ~12 at 0.47 full scale |
| out | s16, saturating | |
| COSQ, cos(πi/1024) × 2^25, i = 0..512 | 26 bits | one quarter-wave ROM serves the IMDCT (m = 2(2n+129)(2k+1)), the IPQF DCT (m = 16(2j+1)(31-2i) and 16(2j+1)(49+2i')), both sine windows, the tone oscillator and the Hann window |
| SF_M / SF_E, MANT_Q19, PWC_Q5 | exact | the tables are exact binary fractions |
| NOISE_Q15, IPQF prototype Q30, AMPQ Q10, F4 = 2^(r/4) Q25 | | |

Dequantisation: `qm = round(MANT_Q19[wl] × SF_M[sf] / 2^9)`, `X = round(spec × qm /
2^(SF_E - 10))` (Q20; a negative shift is an exact left shift). Noise: `qn = round(qm ×
PWC_Q5 / 2^7)`, `X += round(noise × qn / 2^(3 + SF_E + wl + gcv))`.

### 4.2 Gain compensation must not amplify a rounding

Gain control boosts a subband's time signal by up to 2^6 (a level code of 0) and the
next frame's scale by up to 2^6 more; the encoder attenuated those samples by the same
amount, so their residual and IMDCT output are *small*. Two consequences, both found by
the library sweep, not by the first three discs (0.6 LSB there):

1. **Rounding before the gain is amplified by it.** The first model rounded the IMDCT
   output to Q6 and then applied ffmpeg's `(in × scale + prev) × level`: 2-9 LSB on a
   third of the tracks. Every gain on a frame's samples is known *in that frame*: the
   first half gets this frame's scale and the previous frame's curve, the second half
   gets **this** frame's curve when ffmpeg overlaps it next frame. So each output sample
   is multiplied once by its whole factor, window × 2^(E/4) (E in quarter octaves), from
   the wide half transform (Q20, 40 bits; the RTL splits it into two 20-bit halves for
   the 27-bit port, two MACs), and **the overlap buffer stores gained, output-referred
   values** (Q6, 24 bits: nothing after it amplifies).
2. **The residual's own quantisation is amplified too.** With the residual at Q9
   (0.001 of a unit), Ace Ventura's boosted subbands came out 22.8 LSB off. The residual
   is now computed at Q20 (40 bits) and **block-normalised per subband**: shifted right
   by s = max(0, bitlen(max |X|) - 25) for the 27-bit port, the shift undone at the IMDCT
   output. A quiet subband keeps Q20, a loud one 25 significant bits. Worst cases after
   both fixes: 0.55 (Ace Ventura) and 0.59 LSB (Men in Black, all 472 frames of clip 3).

The sweep also scores the worst error under each synthesis condition (gain boost above
and below 2^6, gain cut, a steep window with gain points, noise fill in a swapped or
plain subband, one or both tone regions), because coding-path coverage cannot predict
this kind of failure.

### 4.3 Measured against ffmpeg

**Measured 2026-09-26 (`at3p_sweep.py --fixed`, every clip and audio track, 3 windows
× 48 AUs): 787 tracks, worst 0.615 LSB, worst window RMS 0.34 LSB, no internal
saturation.** The RMS is the error of rounding to s16 alone (1/√12 = 0.289): the fixed
datapath adds almost nothing on top. Worst per synthesis condition: gain boost 0.61, gain
boost above 2^6 0.60, gain cut 0.62, noise 0.61, noise in a swapped subband 0.57, steep
window with gain 0.58, tones in both regions 0.62, in one 0.61. The PCM clipped 5,822
samples, all where ffmpeg's own s16 clips. **The gate: `GATE_LSB = 1.0`.**

## 5. Verification

Units, then the chain, as P3 / P4 did (`bench/umd/README.md` rules: `$fatal`, a PASS
marker, `!==`, `--red` with each mutation caught by its own arm, mutants compiled from
inside their copy, a no-progress watchdog).

| Gate | Result (2026-09-26) |
|---|---|
| `tools/tests/test_at3p_ref.py` (+6 in `red_umd.py`) | ALL GREEN; the table transcription, one track per params word, mute and refusal against ffmpeg |
| `tools/at3p_sweep.py` (float / `--fixed`) | 787 tracks: float ≤ 0.016 LSB, fixed ≤ 0.615 LSB, no internal saturation |
| `tools/at3p_emu.py`, `at3p_sweep.py --emu` | the microcode's parse record = the model's, every field, on **109,740 frames of all 787 tracks** (the float sweep's windows: 203 of 204 coding paths); its PCM (the synthesis microcode) = the fixed model's, bit-exact, on **37,680 frames of all 787 tracks** (`--emu-full`, 2 × 24 AUs a track) |
| `bench/umd/run_at3p_seq.sh --red` | S1-S3 (Akira, Goo Goo Dolls with input gaps, Godzilla; 6 AUs each): every register write and store identical to the emulator (185-275K events an arm); **8/8 mutations caught** |
| `bench/umd/run_at3p.sh --red` | A1-A11 (a window per params word chosen by `tools/at3p_pick.py`; the mute flag; a refused frame; I/O stalls that bite; a tone envelope's start and stop ramps and an inverted tone phase, found by `tools/at3p_scan.py` after `tools/at3p_vop_tally.py` showed A1-A8 never reach them): every vector op's buffers and every PCM pair identical; ≤ 725K cycles a frame; **16/16 mutations caught** |

Every vector-op mode is exercised by some arm (the tally: all four IMDCT window pairs,
noise, a negative dequantisation shift, TZERO / RZERO with a count, RWIN +1 / +32 / -32,
WAVE at both offsets, RSAT invert, PCMZ). Findings the gates made along the way: stalls of 3 / 7 cycles changed no cycle count
(the decoder takes a byte every ≥ 8 cycles and a pair every ~26), so the stall arm now
uses 40 / 60; Akira's A1 window has no noise fill (the noise mutations survived there
and run on A4); a Huffman-walk mutation shows first as the silence of the frame it
refuses. Not yet: a Verilator sweep of the RTL over whole tracks (the emulator's
per-track parse sweep, `at3p_sweep.py --emu`, is the cheaper cover for the microcode).

## 6. Area

Target (decided by the maintainer, 2026-09-25): **≤ 5K ALM** for the decoder, tables in
M10K, one DSP-block multiplier.

### 6.1 Measured

**2026-09-26, a standalone fit (`tools/fit_unit.sh at3p_top clk 27`, every
port a virtual pin): 2,229 ALM, 1,128 registers, 87 M10K, 1 DSP block (27 × 27); 41.1 /
40.1 MHz at 85 / -40 C.** The target holds with room (the sequencer is ~1,080 ALUTs of
the ~3,300, the engines ~2,200). In the core the number moves with packing; the wiring's
fit records it in the SEED LEDGER.
The pre-fit M10K estimate: codebook symbols 10, codebook counts 3, spectrum 3, parse record 4,
constant tables 4, microcode 6, cosine 2, noise 2, IPQF prototype 2, time buffer 6,
overlap 12, IPQF history 4, residual / half-transform / tone-region buffers 4, the
channel-0 PCM buffer 4 — **~66 in the decoder**, plus the output ring the wiring adds
(S7: 4,096 stereo samples, 16) — **against the roadmap's +30 estimate for all of P6**.
The fit measured **87** (the microcode ROM alone is 2,133 × 40 bits, ~10 blocks): with the
PCM ring, ~103 for P6's audio.
325 are free today; ALM, not M10K, is the binding resource, but the estimate was wrong
and P7's inflate window (32 KB) and the menus' planes also want M10K.

## 7. Wiring into `emu` (P6a)

**Status (2026-09-27): 🔧 built, benched (`run_av_sync.sh --red` ALL GREEN, 6 arms, 12
mutations), fit (`UMD_p6a_20260927_1210.rbf`, SEED 9, 30,739 ALM, 393 M10K, clk_dec
87.07 / 86.48), on the rig: Akira in step, Family Guy NOT (7.8: the video path could
not run far enough ahead of the display). FIXED by the compressed-video buffer
(`umd/vbuf.sv`, `h264_frontend.md` S6b; `UMD_p6vbuf_20260927_1304.rbf`): Family Guy, Akira
and The Office Disc 01 all in step on the rig (7.9).**

```
ps_demux aud_* --> aud_ring (32 KB + AU tags) --> at3p_top --> aud_out (4,096 pairs,
      ^ aud_ready          | tag of every AU ------------------> per-frame tags, 48 kHz,
      +-- back-pressure    +-----------------------------------> gate vs disp_ctl's STC)
                                                                   --> AUDIO_L / AUDIO_R
```

All on `clk_sys`, reset per mount with the front end (`fe_rst_n`: the demux's realign,
the ring's framer and the decoder restart together). `umd/aud_ring.sv`, `umd/aud_out.sv`;
`disp_ctl` gained one output, `stc_run` (the STC is anchored and counting). Seams pinned
by `tools/check_emu_wiring.py` ("P6a", scaffold arms W35-W41).

### 7.1 What was harvested, and what was not

MiSTer_DVD's `dvd_audio_decode` contributed the *shape*: a gate that holds the output
while the decode chain fills and releases it when the clock reaches the head's PTS, an
underrun re-arm, a fallback release. Not harvested, each for a reason:
- `av_sync` (the clk_sys mirror of the STC): UMD's STC already lives on clk_sys
  (`disp_sched`, P5e).
- The NCO trim, the provisional anchor, the stale-skip / catch-up heuristics and the
  pre-anchor dispatch hold: DVD's history of fighting a phase reference it could only
  guess (one PTS per PES, a dispatch-side gate, a clock anchored on the parse front).
  Here every PCM frame carries its own PTS (7.2), so the gate reads the head's time
  exactly and none of that is needed.
- `audio_ring`'s per-PES descriptors, drop-on-overflow and splice drop: the ring is a
  plain byte FIFO with real back-pressure (the demux holds a byte it cannot hand over),
  so nothing is ever dropped in it.
- `aud_drain` (a natural-transition drain predicate): UMD has no cell navigation yet;
  P6's seek / chapter work decides whether it is needed.

### 7.2 The tags: every PCM frame knows its PTS (decided 2026-09-27)

The decoder turns every access unit it frames into exactly one PCM frame (2,048 pairs,
silent when refused), and every AU is exactly 3,840 ticks of the 90 kHz clock. A PES PTS
belongs to the first AU whose header starts in that PES (ISO 13818-1 2.4.3.7; the FAP
points at it). So `aud_ring` frames the byte stream **exactly as the microcode does**
(the two-byte `0F D0` window that slides one byte on a mismatch, six header bytes, then
`(params & 0x3FF) * 8 + 8` frame bytes) and pushes one tag per AU header: the pending
PES PTS (a PES that began at or before the header's `0x0F` byte), else the previous tag
+ 3,840 (`derived`). `aud_out` pops a tag at the first pair of every PCM frame it writes.
- The same framing on the same bytes: the Nth tag is the Nth PCM frame even through
  garbage the decoder resyncs over (arm S3, 7 garbage bytes: `slides` = 7 on both).
- Real discs need the derivation: a PTS names only 3 of Akira's first 8 AUs; the
  named PTSs agree exactly with the +3,840 derivation.
- A PES PTS that disagrees with the derivation is counted (`jumps`, telemetry): an audio
  discontinuity. A PES with a PTS but no AU start is illegal (2.4.3.7); the ring would
  give its PTS to the next AU and count a jump.
- Rejected: one PTS per PES descriptor (DVD's), with the phase taken at the first
  tagged dispatch: its error is up to one in-flight frame, and after an underrun it
  cannot re-phase exactly.
- The tag FIFO (512) is flow control: when full, `in_ready` drops. Only AUs under 64
  bytes (32 KB / 512) could reach it; the library's smallest is 344.

### 7.3 The gate (`aud_out`)

The head pair's time is `pos = PTS * 8 + 15 * index` eighth-ticks (a pair is 1.875
ticks). The sample tick is **exactly** `clk_sys * 2 / 1125` (48 kHz) and the STC exactly
`clk_sys / 300`: one crystal, an exact ratio, so once started at its PTS every later
pair stays at its PTS with nothing to slew (the bench measures every frame start at
`d = 0`). ARM:
- the STC runs and the head is tagged, `d = STC * 8 - pos`: `d >= 15` discard the pair
  (wholly past); `0 <= d < 15` release, **once a frame (2,048 pairs) is buffered behind
  the head** or the decoder has written nothing for ~155 ms (a dry source, a title's
  tail); `d < 0` wait. So the first pair plays within one pair of its PTS.
  - The buffer condition was found by the bench (2026-09-27): releasing on a part-frame
    as soon as the clock reached the head underran ~0.5 s later whenever the STC started
    before the decoder had a frame ahead (start, stutter, restart). Waiting costs only
    stale pairs, which the running STC would discard anyway; the decoder's 1.6-1.8x
    real time builds the frame in ~55 ms.
- **The deadlock rule** (the demux is shared): while the STC has not started and the
  ring is blocking the demux with the PCM FIFO full, discard the head pair. The first
  picture that starts the STC may sit behind audio the ring cannot take; audio yields
  from its stale end, the audio a late anchor would discard anyway. Arm S5 (all audio
  ahead of the video, a 2 KB ring) deadlocks without it (mutation M5).
- Fallback: a head that cannot be judged (no STC, or no PTS ever) for ~2.5 s releases
  anyway (counted; 0 in every arm).

RUN plays a pair a sample tick. A tagged frame start is checked first: `|d| > 50 ms`
(the display re-anchored, or the audio jumped) re-arms on that pair without playing it
(S6: the STC jumps 100 ms). Otherwise `d` is recorded: **`av_err`, the lip-sync
instrument**, measured and never re-based (MiSTer_DVD once re-based its instrument on
every re-anchor and it could no longer show the error it existed for). An empty FIFO at
a tick is an underrun: re-arm (S4).

**Pause (P6b3, 2026-09-28; `transport.md` §2.3).** `freeze` is the display's
refresh-aligned freeze (`ds_frz`), the level that holds the STC. While it is up:
- the sample tick does not run: RUN keeps its place and the head pair plays on resume;
- ARM decides nothing: no discard, release or fallback, including the pre-anchor discard;
- the dry and fallback timers hold.

A tick made the cycle before the freeze is still played, so no pair is lost at the edge.
S7 pauses 0.22 s mid-stream: the frame starts are at d = 24 eighth-ticks before and after,
with no re-arm. S8 pauses before the STC runs. M13 and M14 are the two mutations. The track
switch resets this chain with the demux's realign on the switch's last cycle (§2.3 there).

### 7.4 Sizing

- **The ring: 32 KB** (`tools/av_mux_lead.py`, 2026-09-27, 718 clips): the audio's lead
  over the video in the multiplex is at most ~1 s, 16,128 bytes (Ghost in the Shell 2.0;
  the rest <= 14,112). Before the first picture starts the STC the ring must hold that
  lead **plus** the video pipeline's depth, and 16 KB does not; 32 KB holds ~2 s at
  129 kbit/s. The one outlier (The Incredibles clip 3: 7.4 s, 121 KB) is the title's
  tail: the video ends at 6920 s and 7 s of audio follow, which back-pressure handles.
  Rule from S7's first draft kept: at least two maximum frames (2 x 8,200 bytes).
- **The PCM FIFO: 4,096 pairs** (a frame plus the decode latency, 16 M10K).
- M10K for P6a: the decoder 87, the ring 32, the PCM FIFO 16, the tags 2 = **~137**
  against the roadmap's +30 for all of P6 (the fit's number goes in the SEED LEDGER).

### 7.5 Verification: `bench/umd/run_av_sync.sh [--red]`

`ps_demux -> aud_ring -> at3p_top -> aud_out` on program streams from
`tools/av_sync_golden.py`, whose goldens do not come from the RTL: the tags from FAP (the
format's pointer; the RTL frames bytes instead), the PCM from `at3p_fixed.py`. Scored:
`[tag]` every tag; `[pcm]` every pair played at its index (discards count, so a lost or
repeated pair shifts everything); `[start]` every release inside its pair, from the
GOLDEN tags; `[drop]` every discard wholly past, or before the STC with the ring
blocking; `[sync]` every frame start within a pair plus a tick; `[count]`; `[live]`.
Six arms (S1 the disc's own packs ... S6 an STC jump), 12 mutations (M1-M12). ~4 min an
arm in Icarus, the arms in parallel. Since then: S7 / S8 pause (P6b3), S9-S11 the item tag
(P6b3i), **S12 the track switch (P6b7)**: both of Akira clip 1's tracks in its own packs,
the switch as `player_ctl` makes it, track 1 from the AU the new chain takes (M18 / M19).

### 7.6 The HUD and telemetry

HUD row `AT3 frames RF refused/code RA {resync, underrun} AV ms D discarded R ring-KB`
(the subtitle mask moved onto the `CRC` row). Telemetry words (`tools/telem_layout.py`):
`aud_frames`, `aud_err`, `aud_played`, `aud_rearm`, `av_err` (ticks), `aud_drop`,
`aud_state`, `ring_fill`, `ring_max`, `ring_bp`, `ring_tags`. The HIL Main must be
rebuilt to report the new words (its field table is compiled in).

### 7.8 On the rig (2026-09-27) -- and the defect it found

`UMD_p6a_20260927_1210.rbf`, `mister.py telem --watch 60` on settled playback:
- **Akira: in step.** Decoded and played 23.438 frames/s; `av_err` 2 ticks (0.02 ms) at
  every frame start for 60 s; no re-arm, no drop, nothing refused; the ring's high-water
  13 KB, the demux never waited on audio; the video unaffected (judder gate EQUAL, 0 late).
  The start discarded 0.66 s of audio that precedes the first picture (expected).
- **Family Guy: NOT in step.** 188 underrun re-arms in 60 s, 6.9 of 23.4 frames/s played,
  the rest discarded as late. Each frame that plays is in step (`av_err` 0-2 ticks):
  the gate is right; the audio ARRIVES after its time.

**Why.** The video path buffers almost nothing compressed (`vidfeed_cdc`'s 32-byte FIFO,
the 512-word SE FIFO); the decoder runs ahead of the display only into free picture
stores (20, ~16 usable). The display paces the decoder, the decoder paces the demux, so
the demux runs ahead of the display by ~16 pictures: ~0.6 s at Akira's 23.976 frames/s,
~0.45-0.5 s at Family Guy's 29.97 field pairs/s. UMD multiplexes put the audio BEHIND
the video carrying the same time: median 0.31 s, 5 % of the time 0.55 s, the same on both
discs (the first 40,000 packs, `av_mux_lead.py`'s metric). Audio for time T reaches the
decoder when the demux is at the video for T + lag, so it is late whenever the lag
exceeds the video's lead over the display. The bench could not see this: its STC is
started by video bytes, not paced by a display.

⚠ **The numbers do not close.** A lead of 0.45-0.5 s against a median lag of 0.31 s
predicts lateness a few per cent of the time, not the 70 % of frames lost on the rig.
Likely contributors, unmeasured: the metric's video time is the newest PTS, which runs
ahead of decode order by the reorder delay (~0.1 s), so the real lag is larger; the
usable stores may be fewer than 16 (references, the display's own); and **the re-arm
ratchet** -- after an underrun the gate waits for a whole frame buffered, and with
arrival only slightly ahead of real time it discards while waiting and may not
accumulate it, so the path is all-or-nothing around a one-frame margin (a property of
the gate a CPB would mask, not remove: a known limitation, 8). The direction and the fix
hold either way: a CPB removes the dependence on picture stores.

**The fix is a compressed video buffer** (the H.264 CPB, which the multiplex assumes the
decoder has: Level 3 MaxCPB = 10,000 kbit, 1.25 MB). Not in M10K at the spec maximum.
Options (for the maintainer, 2026-09-27):
- **A (recommended; CHOSEN by the maintainer 2026-09-27, built: `umd/vbuf.sv`,
  `h264_frontend.md` S6b): a DDR3 ES ring** between the demux and `vidfeed_cdc`, ~2 MB, on
  ram1 through `ddr_mux2`'s idle master B (MiSTer_DVD's VBUF is the harvest). ~10 Mbit/s
  in and out at the maximum is small against the DPB's traffic, but it shares the port
  (occupancy: measure with the probes).
- B: an M10K ES buffer of ~100 KB (0.6 s at Family Guy's ~1.3 Mbit/s). Not the spec
  maximum (a high-bitrate title fails the same way), and it spends most of the 160 M10K
  left, which P7's inflate window (32) and the menus' planes want.
- Rejected: holding the display back (DVD's pickup-hold): with no compressed buffer the
  decoder stalls, the demux stalls on video, and the audio does not arrive either.

What the CPB changes, to decide with it:
- Whichever buffer fills first paces the demux: the 32 KB audio ring holds ~2 s at
  129 kbit/s but 1.36 s at 192. Choose the run-ahead target and size the CPB and the ring
  together, not by accident.
- The deadlock rule's premise moves: before the first picture, the video no longer
  blocks the demux, a full audio ring does, and the pre-anchor drops then eat the head at
  the decoder's rate until the anchor. Check they cannot drop audio at or after the first
  picture's PTS on a real start: a bench arm with a DISPLAY-paced STC (the shape
  `av_sync_tb` lacks) is the proof.
- ram1's `ddr_mux2` master B is idle, but it shares the DPB's port -- the occupancy case
  `hw_budget_and_lessons.md` warns about: measure with the `ddr_probe`s.

### 7.9 With the compressed-video buffer, on the rig (2026-09-27)

`UMD_p6vbuf_20260927_1304.rbf` (SEED 9, clk_dec 89.86 / 88.13, 31,420 ALM, 401 M10K),
60 s of settled playback each (`mister.py telem --watch 60`):

| title | played frames/s | `av_err` | re-arms / drops | audio ring | vbuf now / max | video |
|---|---|---|---|---|---|---|
| Family Guy (field pairs) | 23.437 | 3 ticks (0.03 ms) | 0 / 0 | full, paces the demux 95 % | 339 / 1,272 KB | 59.94 fields/s, 0 late, judder EQUAL |
| Akira (3:2 film) | 23.439 | 3 ticks | 0 / 0 | full, 96 % | 271 / 1,367 KB | 23.97/s, 0 late, EQUAL |
| The Office Disc 01 | 23.438 | 2 ticks | 0 / 0 | full, 93 % | 638 / 907 KB | 59.94 fields/s, 0 late, EQUAL |

As sized (h264_frontend S6b): the audio ring is what paces the demux, the vbuf holds a
few hundred KB, the demux never waits on video. ram1's longest BUSY run 49-66 cycles
(54 before), the decoder never late: the second master costs nothing visible. Reloads:
0 hangs in 40, each title loaded over the other playing (`hil_harness.md`).

### 7.7 Not in P6a

Track selection (`aud_realign` stays 0; the lowest declared track plays), an A/V offset
setting, pause (the gate's ARM is its natural hold), seek, a de-click ramp on a
re-arm (the output holds its last sample), and the HUD stack: P6b and after
(`roadmap.md` Phase 6).

## 8. Known limitations

- ~~P6a: the audio arrives late on some titles~~ -- fixed by the compressed-video buffer
  (S7.9).
- **The bench cannot see run-ahead limits**: `av_sync_tb`'s STC is started by video bytes,
  not paced by a display, and `p3_chain_tb` composes the demux and the CDC without the
  vbuf between them (`run_vbuf.sh` proves the vbuf alone). The rig composes them.
- **P6a: the re-arm ratchet**: after an underrun the gate waits for a whole frame
  buffered while discarding stale pairs; arriving only just ahead of real time, it may
  not get there (S7.8).
- **P6a: the dry-timer release** (no PCM for ~155 ms: a title's tail) has no bench arm.
- **P6a: the bench's STC is started by video bytes, not paced by a display**: it cannot
  see run-ahead limits (S7.8).
- **A reset does not make the decoder cold** (found by P6b7's track-switch arm, S12 of
  `run_av_sync.sh`). The state that carries between frames (the overlap buffer, the IPQF
  history, the previous frame's window shapes and gain data) lives in RAM, which a reset
  does not clear. After a seek or a track switch, the first frame's first half blends the
  old stream's overlap tail: about 21 ms of the old audio, faded out by its own window,
  inside the first new frame. From the second frame on the state is the new stream's own,
  and the PCM is bit-exact with a decoder started cold at that access unit (S12 proves
  frames 1-2). **ffmpeg (n9.0.1) does the same**: `ff_atrac3p_decoder` has no `.flush`, so
  its history also survives a seek. Clearing the RAMs on reset would need a clear walk
  (area, and cycles before the first frame); not done while it matches the oracle and no
  listener has heard it.
- Stereo only (every UMD track in the census); mono and multichannel units are refused.
- The mute flag is decoded but no disc in the library sets it (S2.3).
- ffmpeg is the only oracle; a stream it decodes wrongly, we decode wrongly too.
