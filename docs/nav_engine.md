# The navigation engine, and subtitles back in the fabric (A12)

**Status: ✅ MERGED (PR fj#59, 2026-10-07), ✅ HW-CONFIRMED.** N0 ✅ measured (§3); N1 ✅ the model (§8); N2 ✅ the RTL (§9: the reader's bench ALL GREEN on every fixture, 25 + 63 arms); N3 ✅ the fit (§9): 36,384 ALM (87 %, -2,743), clk_dec 89.72 / 89.06, ✅ HW-CONFIRMED (§9); SD1-SD3 ✅ (§11): subtitles on a stock Main, ✅ HW-CONFIRMED; merged with main and pinned at SEED 3 (§11), the merged build ✅ on the rig (§11). Decided by the
maintainer the same day (`area_plan.md` §8, A12): the reader's parse goes onto a microcoded engine
(`area_plan.md` §10a), and if that frees the room, the subtitle decode comes back into the fabric, so
a stock Main shows subtitles again. In the maintainer's words, subtitles are "the biggest missing
feature for viewing a film in the core without the HPS extras".

The pattern is this core's own ATRAC3plus decoder (`at3p_seq` + `tools/at3p_isa.py`,
`at3p_decoder.md` §3.4), as MiSTer_DVD reused it for DTS, AC-3 and MP2 (its PRs #148-#150).

## 1. What moves, what stays

**Onto the engine (program words):** everything in `umd_reader` that parses -- the ISO9660 walk,
PARAM.SFO, PLAYLIST.UMD and the longest-playlist pick, the CLPs (streams, languages, the EP map
headers), the EP maps' binary searches (IN / OUT, seeks, P6b4's clamp), the marks (NAV_CHAP), the
item walks (NAV_SEEK / NAV_PLAY / NAV_TIME), the multi-extent `.MPS` continuation, P8's sniff, every
`err_code` / `nav_err` verdict.

**Stays hardwired (the pump):** the `sd_*` handshake, the sector write into `parse_buf`, the 16 KB
stream cache with its per-slot item tag (D8), the stream sector loop and its stop counters, the
output pipe. The engine drives it with a few commands (read a sector into `parse_buf`; stream an
extent with a stop count and an item tag) and reads `parse_buf` a byte at a time.

**Unchanged outside:** `umd_reader`'s port list as `emu` sees it -- `player_ctl`, `ps_demux`, the HUD,
telemetry and the host port do not know the reader changed. Not in the H.264 fork's code.

## 2. Bounds the program is written to

- **The item start.** Today's handoff (`transport.md` "D8, the handoff measured") keeps the picture
  continuous across item starts; its cost is an audio resync, not the reader's speed. An item start is
  dominated by sector reads through the HPS (~1,200 a second on the rig, P2: ~0.8 ms, ~21,600 clk_sys
  cycles each). **The engine must spend fewer cycles between two of its sector reads than one read
  takes**, so the sd port, not the program, stays the bound. N1's emulator counts it.
- **The spec maximum, kept** (CLAUDE.md): u16 playlists, u32 items, u16 marks (65,535, `syn_marks_max`),
  u32 EP entries, u32 file offsets; every walk moves a u32 offset strictly forward; no table sized to a
  census. The two visible bounds stay as they are (`title_trunc`, `dur_sat`).
- **The datapath:** 33-bit PTS (carried in 48), u32 offsets and LBAs, 64-bit duration sums (E3).

## 3. N0, the measurements (2026-10-06)

| what | result | how |
|---|---|---|
| the reader, pump vs parse | **whole reader 6,098 LUTs / 3,594 registers; pump only 297 / 226** (149,248 vs 132,096 RAM bits: the pump keeps the 16 KB cache; `parse_buf` goes with the parse here, but stays in the design as the engine's input). **The parse is ~95 % of the reader** | `tools/synth_unit.sh` on P8's wrapper (only the outputs `emu` connects, XOR-folded), the current reader against a pump-only copy (the parse states, the shadow fetch and the navigation states cut; commands only flush, so the pump is if anything overstated). Scratch: `.sim/area/` |
| the engine's floor | **`at3p_seq` alone 1,151 LUTs / 590 registers** (778 ALM in the core fit), with its Huffman unit, bit reader and vector-op arguments (128 bits), none of which a navigation engine needs; it would add a byte port on `parse_buf`, the pump commands and wider arithmetic | `synth_unit.sh at3p_seq` |
| what stays registers | the reader's outputs: ~1,220 bits (PTS, durations, chapter keys, track masks, counts), engine-written | the port list |
| the files | `.sim/area/` (gitignored): `wrap_main.sv` (P8's wrapper), `base/` and `pump/umd_reader_main.sv`, `base.map.rpt`, `pump.map.rpt` | |
| the item start's bound | ~21,600 clk_sys cycles between sector reads; **N1: at most 11,666 on the library, 8,550 on 65,535 marks** | §2, §8 |
| the subtitle decode's time | the largest library unit inflates to 105,750 bytes (17 ms on the hardwired decoder, `png_decode.md`); decode starts after the previous flip and the next PTS is >= 0.1 s later (`subtitles.md` §1) | measured in P7 |

Earlier numbers (P6b2, 2026-09-27, `.sim/synth_rdr_*`): the P2 reader (walk + pump, no navigation)
3,052 LUTs; with the navigation port 5,429; 6,357 since P8 (`bare_streams.md` §3).

**What N0 says (an estimate, the fit decides):** the pump (~300 LUTs) + an engine core (~700-1,000)
+ the output registers (~1,000 bits and their write decode) is ~1,200-1,700 LUTs, ~1.0-1.4K ALM at the
reader's own LUT-to-ALM ratio (3,749 ALM for 6,098 LUTs in the fit). **The reader's move saves ~2.0-2.7K
ALM** (`area_plan.md` §10a guessed 1.0-1.8K). From today's 39,127, that is ~36.4-37.1K before the
subtitles, and **~38.8-39.5K (93-94 %) with the hardwired decoder back** -- under the 95 % line. E1's
option (a) becomes affordable, which removes (b)'s only argument.

## 4. Decisions (E1 / E2 the maintainer's, taken 2026-10-06; E3 an engineering call in N1)

| # | question | options |
|---|---|---|
| **E1** | the subtitle decoder -- **✅ TAKEN (the maintainer, 2026-10-06): (a), the hardwired decoder back** | **(a) the hardwired `png_top` back** (`sub_png` 2,225 ALM / 47 M10K + `sub_plane_wr` 209 / 2, as removed by PR fj#34): built, bit-exact on every library unit and all 6,150 RCO PNGs, the spec-maximum unit (720 x 480 RGBA) in ~0.22 s. **(b) on an engine:** est. ~1.2-1.8K ALM + the 32 KB window (~16 M10K), a new inflate to verify; the library's units in ~40-60 ms, the spec maximum late (counted). The area difference is (b)'s only argument. |
| **E2** | with the UMD Main present, who decodes? -- **✅ TAKEN (the maintainer, 2026-10-06): (a), the fabric always; the host composites the panel over the fabric's plane, `umd_sub`'s decode retires** | **(a) the fabric always**; under the panel (`ui_sub`) the host reads the shown plane back from DDR3 (B2 proved a fabric-written plane reads back word for word) and composites the panel over it; the HPS decoder (`umd_sub`) retires. **(b) the fabric on a stock Main, the HPS with the UMD Main**: both decoders kept alive. **(c) the panel and the menus take the plane** and subtitles pause under them (loses the PSP's behaviour, K13). |
| **E3** | the engine's register width | 16-bit (`at3p_seq`'s) with multi-word operations (cycles, free at this rate) or 32-bit (ALMs). Not priced in N0: N1's emulator counts the cycles of each, a synthesis of the core at both widths prices the ALMs. An engineering call, made in N1 |
| **E4** | one engine or two | **moot since E1 (a).** Was: only if E1 is (b): the navigation program and the decode share one engine (a rule for an item start arriving mid-decode) or run on two instances of one design |

## 5. Stages

- **N0, the measurements** (§3).
- **N1, the model (no RTL)** -- ✅ (§8). The ISA, a Python emulator (the `at3p_isa.py` pattern: assembler,
  emulator, cycle charges), the walk and navigation programs. Scored against the P1 parsers and
  `tools/umd_nav_ref.py` on every synthetic case and all library images, with the cycles between
  sector reads checked against §2's bound.
- **N2, the RTL.** The pump split into its own module; the engine trace-equal to the emulator
  instruction by instruction (`run_at3p_seq.sh`'s method); `run_umd_reader.sh --red` and the chain
  (`p2_chain_tb`) green unchanged -- the reader's gate scores verdicts, not cycles, so it survives the
  move; `run_player_ctl.sh` green; the rig: a mount, chapters, seeks, Go To, the item handoff re-measured.
- **N3, the fit.** It measures the room freed and picks E1's path.
- **SD1, the subtitle decode back** -- `sub_png` + `sub_plane_wr` as PR fj#34 removed them (E1), with their benches (`run_png.sh`, `run_sub.sh`, `run_overlay.sh`); the stock-Main gate on SUB
  (B3) lifted.
- **SD2, the UMD Main side** (E2): the host stops decoding; under `ui_sub` it reads the plane `sub_flip` shows back from DDR3 and composites the panel over it (`panel.md` §2); `run_hps_host.sh` / `run_panel.sh` re-scored.
- **SD3, the manual:** the Subtitle button's stock-Main message retired, `reference/compatibility.md`,
  `playback/on-screen-messages.md`, `reference/troubleshooting.md`; `docs_check.py` and
  `mkdocs build --strict`; the rig on a stock Main.

## 6. Branching

The survey and this plan: `docs/engine-survey`. The RTL: `feature/nav-engine` from it, `CORE_VERSION`
`dev-naveng` in its first commit.

## 7. The ISA (N1; E3 decided: 32-bit, multi-cycle)

**Why multi-cycle and 32-bit.** N0 gives ~21,600 clk_sys cycles between two sector reads, and the
reader's area is control, not throughput. `at3p_seq` spends its LUTs on a one-instruction-a-cycle
pipeline and a 16-bit register file in fabric; this engine takes **four cycles an instruction** (ROM
read, register read, execute, write back) and keeps its **register file in M10K** (two simple-dual-port
copies: two read ports), so its storage costs no ALMs and every path has a cycle to spare at 27 MHz.
32 bits because the reader's quantities are u32 (offsets, LBAs, counts, EP entries); the wider ones
(48-bit PTS, 64-bit durations, 65-bit mark keys) are register pairs through a **carry flag**. The
33-bit "a carry is out of bounds" guards of the RTL (`p_plus`, `q_plus`, `pl_mk`, `vm_base`, `mk_o`,
`map_addr`) stay explicit carry branches: they are spec-maximum guards.

**Word: 40 bits** (`at3p_isa.py`'s layout): `op[39:34] rd[33:30] rs[29:26] rt[25:22] imm[21:6]
aux[5:0]`. Registers r0..r15, 32 bits, r0 reads 0. Flag C. Call stack 8 deep.

| instruction | effect |
|---|---|
| `alu rd, rs, rt` / `alui rd, rs, imm` | `rd = rs FN rt` (or the zero-extended imm16); FN in aux: `add sub adc sbc and or xor shl shr sltu seq sne`. `add / adc` set C to the carry out, `sub / sbc` to the borrow (`rs < rt` unsigned, with the incoming borrow for `sbc`) |
| `lui rd, imm` | `rd = imm << 16` (`li` of a 32-bit constant is `lui` + `ori`) |
| `ld rd, imm[rs]` / `st rd, imm[rs]` | a word of the data space (below) at `rs + imm` |
| `lbf rd, imm[rs], n` | **a file load:** n bytes (1-4) big-endian at byte offset `rs + imm` of the current file; `lbl` little-endian. Each byte: sector `F_LBA + off >> 11`; past `F_LAST` it reads **0** (the RTL's no-cross rule); otherwise the sector is made resident in one of **two sector slots** (by LBA, the older replaced; an sd read if neither holds it) |
| `b<c> rs, rt, label` | c in `eq ne ltu geu`; `b<c>i rs, k, label` against a 10-bit constant |
| `bcs / bcc label` | on C |
| `jmp / call / ret` | |
| `wait mask` | stall until `(STATUS & mask) != 0`; resumes the cycle after |

**Cycles (the emulator's charges; N2's RTL must not be slower, §8):** 4 a word, **+2 a file byte**
already in a slot (an sd read when it is not: the pump's ~4,200 on the bench), a `wait` as long as its
condition. **The engine is strictly sequential** -- one word completes (fetch, register read, execute,
write back) before the next is fetched -- so the M10K register file's one-cycle write needs no
forwarding: an `st` / `ld` / ALU word reading a register the previous word wrote sees the new value.

**The data space (32-bit words):** 0x000-0x1FF scratch RAM (an M10K pair): the walk's variables.
0x800 up: **I/O** -- reads give the inputs (`file_size`, the latched navigation command, `item_hold`,
the pump's status, the mode bits); writes set the reader's output registers (`main_pl`, `n_items`,
`item_in_pts`, `ch_cur`, ...: ~1,220 bits), strobe the pulses (`item_start`, `nav_done`), write
`title_mem` / `lang_mem` (an address range each), set the current file (`F_LBA`, `F_LAST`) and drive
the pump.

**The pump (hardware).** The program loads `STRM_LBA`, `STRM_LEFT`, `CLIP_LEFT`, `CLIP_LIM` and the
item tag, then strobes STREAM: the pump requests sectors into the cache while there is room, counts
`secs_streamed`, tags each slot, and stops itself at `CLIP_LIM && CLIP_LEFT == 0` or `STRM_LEFT == 0`,
reporting which. PAUSE (a NAV_CHAP's scan) lets an in-flight request land, then idles the sd port
for the file loads; RESUME continues. FLUSH empties the cache and the output pipe. The sd handshake
and its in-flight lock stay as they are (an abandoned block lands in an uncounted slot).

**The navigation take: acceptance in hardware, at the edge, as today.** `nav_ready` is an
engine-written level (`&& !pending`). The bench requires a SEEK's effects ON its accepting edge
(`title_done` down, no byte or request of the old phase after it), so the hardware keeps the RTL's
acceptance rule: SEEK `nav_item < ACC_ITEMS`, TIME `ACC_ITEMS != 0`, PLAY `nav_pl < n_playlists`, each
`&& bare == 0`, where `ACC_ITEMS` is a register the program writes with the chosen playlist's item
count (`best_n`; not `n_items`, which keeps P8's constant 1 until an item starts). An accepted
SEEK / TIME / PLAY flushes the cache and the output pipe, drops `streaming` and `title_done` and
freezes the pump in that cycle; every command is latched with its accepted bit and raises pending.
The program then answers (a refusal's NE_ITEM / NE_NOMAP / NE_OP included) and strobes `nav_done`.
A CHAP flushes nothing: the program pauses the pump at the next sector boundary, scans, resumes.
(First drafted as "hold the output, decide in the program": it cannot drop `title_done` on the
edge, and needed a squash and rewind of the output pipe on a refusal.)

**`item_hold` (P6b3i) is a same-cycle guard on one write:** a write of `STATE` = 28 (S_ITEM2: the
next item's record) while `STATE` is 27 (S_ITEM) is ignored in a cycle `item_hold` is up; every other
state write is taken (S_ITEM -> the drain at the title's end does not wait for `item_hold`, as in the
RTL). `umd_reader_tb`'s `[hold]` samples `item_hold` in the cycle the state changes, so the guard must
too. The program writes 28 and reads the state back (`I_STATE`) until it moved, then reads the record.
`state_o` keeps the RTL's codes where they mean something to telemetry (27, the stream, the drain,
done, error); `active` is derived from it.

**Start / stop are a hardware restart:** the engine's PC to its vector, the pump cleared and the
status outputs the downstream reads at once (`streaming`, `title_done`, `err_code`, `nav_ready`)
cleared in the same cycle, as today; the program's first instructions write the rest (P8's bare
defaults included).

**A reset is a stop (fj#64, fixed 2026-10-08, ✅ MERGED PR fj#78, ✅ HW-CONFIRMED).** `nav_seq` reset `pc` to 0, the
START vector, so every `rst_n` ran a whole mount walk. The OSD's Reset is part of `reset_n` (`emu.sv`
`user_rst_qn`) and hps_io still holds `img_size` (no eject comes), so the walk found the disc and played
it -- while `media_seen`, cleared by the same reset and set only by a mount edge, kept the idle screen
over the picture: the title's audio from its start behind the XMB wave (the maintainer, 2026-10-07; the
UMD Main sent nothing). Before A12 the reader's FSM reset to its idle state 0. Now the reset sends `pc` to
1, the STOP vector (INIT, `O_STATE` = 0, halt): an OSD Reset leaves an idle, silent core until the next
load, as the manual has always said (`playback/settings.md`: "Unloads the image and returns to the idle
screen"). The same walk ran at every core load too, there ending in E_SMALL (no image) behind the idle
screen; gone with it. `tools/nav_isa.py`'s cold `pc` is 1 for parity (its runs always restart first).
Bench: `run_umd_reader.sh`'s `syn_basic +hold` (20,000 cycles after the reset with `file_size` held and no
start: no sector read, nothing streamed, state 0, no error), RED arm **E10** (the reset to pc 0, caught by
`[reset]`). `stopped` (`eng_status`' ST_STOPPED) still resets to 0: the program never reads it (STOP_HALT
waits on mask 0), so it is left as it was.
**✅ On the rig (.236, 2026-10-08, `UMD_resetfix_20261008_0525.rbf`, SEED 5):** telemetry at 0.5 s steps
around a Reset sent as the OSD sends it (`status[0]` pulsed): Akira playing (pics 1,100 -> 1,145), paused
(`xport` 0x4000, pics flat) and The Transporter stopped -- every one to `pics` / `dc` / `aud_played` /
`reader` / `xport` 0 at the first sample after, held for 6 s, the idle screen on the raster; the image
loaded again afterwards plays (pics 159 -> 774 in 10 s).

**The files:** the assembler and emulator `tools/nav_isa.py` (forked from `at3p_isa.py`, the Huffman
and vector ops removed); the program `umd/nav/nav.uasm`; N1's harness scores the emulator against the
fixtures `run_umd_reader.sh` uses (§5).

## 8. N1, as built (2026-10-06, `feature/nav-engine`)

**What exists.**
- `tools/nav_isa.py`: §7's ISA, the assembler, the instruction-level emulator, a sector-level model
  of the pump (the 16 KB cache, the output drain, the sd port, the take at the edge with its
  acceptance rule), and a harness that applies `umd_reader_tb`'s own arms to the fixtures it reads:
  `[walk] [order] [sniff] [pick] [bare] [title] [stream]` (each stream request in the golden order,
  each sector's item tag) `[done] [tracks] [clip] [base] [nav] [err] [thrash] [seek] [time] [play]
  [chap]`. Outputs are write-only, as in the hardware (a read-back mux would cost ~60 x 32 bits):
  reading one is an emulator error.
- `umd/nav/nav.uasm`: the walk and navigation, label for label with `umd_reader.sv`'s states:
  **1,441 words** (40 bits: 8 M10K at 2K deep; a trim is possible, M10K does not bind).
- `bench/umd/run_nav_model.sh [--red]`: the gate. Every synthetic case of `umd_reader_cases.py`, and
  per disc image the `--nav` fixture with the RTL bench's seed and the two bare files, all generated by
  the same commands as `run_umd_reader.sh`.

**Results.** 26 of 26 synthetic cases; all 88 disc images (their navigation fixture, 29 commands
each on most, and their bare `.MPS` / `.PMF`): **267 of 267 PASS**. The longest stretch of engine
work between two of its sector reads: **11,666 cycles** on the library, 8,550 on `syn_marks_max`
(65,535 marks), against §2's bound of one sector read (~21,600). **`--red`: 52 mutations of the
program, named after the RTL bench's arms they mirror (R* / N* / P* / T* / B*), each caught by its own
arm.**

**What the model found.**
- **The bench's timing is part of its contract.** `run_umd_reader.sh`'s W_MID trigger wants a stream
  transfer in flight; on a short tail phase (Sin City, Astro Boy) that holds only if a CHAP issued at
  W_HALF is served before the phase's last sector is requested. The model reproduces the RTL bench's
  pacing (an sd read ~4,200 cycles; the output a byte every **2.33** cycles: two a byte, then `busy`
  at 25 %), and the engine's CHAP must keep up: its mark loop keeps i / n / the offset / `best_n` in
  registers (~9 instructions for a mark that is not a chapter). **N2's RTL engine must be at least as
  fast as the emulator's cycle charges** (4 a word, 2 a loaded byte) or those two discs fail the RTL
  bench the same way.
- Results before the strobe: the program writes every result word before `nav_done` (an early draft
  strobed it before the "past the clip" flag; `syn_nav` caught it).
- A mutation that survived (R11) showed the program computed an extent's sector count twice; it is
  computed once now (`V_FD_NSEC`), so the count the pump streams and the skip test cannot disagree.
- The bound's metric first counted an sd read's latency as engine work (reported 17,292); fixed.

**Added after review (2026-10-06):** the model drives `item_hold` as the RTL bench does (up one
cycle in three, re-drawn every instruction, seeded by the fixture), with the hardware's guard and the
bench's own `[hold]` check on the state register, so the program's read-back loop runs. Arms added:
the program's read-back (N26), its `ACC_ITEMS` write the take depends on (A1), R13 `[order]` (a clip
streamed before its CLP is read), and **seven hardware mutations of the model** (`--hw-mut`: no sector
slot R14 `[thrash]`, the take's rule N10 / P1 / T6 / B5, no flush N9, no guard N26h `[hold]`): **62
arms, each caught by its own.**

**Not covered by N1 (they are hardware; N2's RTL bench keeps them):** `[hold]` (the state-write
guard), `+restart`, the take's acceptance rule and flush (the RTL arms N9, N10, P1, P4, T5, T6, B5),
the cache and its tags (R6, N25), the sd request lock (R10), the sector slots (R14's `[thrash]`).
`run_umd_reader.sh`'s mutation list names `umd_reader.sv` text: in N2 its program arms move to
`run_nav_model.sh` (done: they are the 52 above) and its hardware arms are re-anchored on the pump.

**N2, the next step.** `umd/nav/nav_seq.sv` (the engine: four cycles a word, the register file in
M10K, the file-load unit over two sector slots), the reader split into the pump and the engine behind
`umd_reader`'s unchanged port list, `nav_ucode.mem` from the gate; `bench/umd/run_nav_seq.sh` (the
engine's register-write and I/O trace equal to the emulator's, the `run_at3p_seq.sh` method);
`run_umd_reader.sh` and `p2_chain_tb` green unchanged; then the fit (N3).

## 9. N2, as built (2026-10-06, `feature/nav-engine`)

**RTL.**
- `umd/nav/nav_seq.sv`: the engine. Four cycles a word (A: the ROM reads pc; B: the register file
  reads rs / rt; C: execute, the data address, a file load, a `wait`; D: write back), the program
  ROM (2K x 40), the register file as two M10K copies (a store's data register is placed in `rt`
  by the assembler, so the second read port serves it: no third copy), 512 x 32 scratch RAM, an
  8-deep call stack, one 33-bit adder for add / sub / adc / sbc / sltu, one shifter (shl as shr of
  the bit-reversed operand). A data load reads its address in C and takes the word in D: the
  scratch RAM reads C's address, and the reader answers an I/O read combinationally.
- `umd/umd_reader.sv`: the same port list; its body is now the hardware of §7 -- the sd handshake,
  the two sector slots (one M10K each) and the file-load unit (a slot hit answers two cycles after
  the request: the emulator's charge), the pump, the cache and output pipe (unchanged), the take
  (acceptance and flush on the edge, as before), item_hold's guard, the output registers, and the
  engine. `umd/nav/nav_io.svh` (the I/O map) is generated by `tools/nav_isa.py --svh`.
- `UMD.qsf` names `umd/nav/nav_seq.sv`.

**Verified.**
- `bench/umd/run_umd_reader.sh`, the reader's bench, its arms unchanged: every synthetic case, the four
  `+restart` runs, the chain (`p2_chain_tb`), all 88 disc images and their bare files -- **ALL
  GREEN** (271 PASS lines), `item_hold` driven at random as always.
- Its `--red` list is rewritten for the split (the walk's and the navigation's arms are the program's,
  in `run_nav_model.sh --red`): the reader's hardware (R6, R10, R14, N9, N10, P1, T6, B5, N25, N26,
  P4, N23 and H1-H4: the past-F_LAST zero, the pump's clip stop, the drain's empty status, the
  the drain's empty status) and the engine's instruction set (E1-E9: the carry into adc / sbc, a
  little-endian load, ret, shl, wait, a branch constant, the unsigned compare, the carry's write),
  plus C1 through the chain: **25 arms, each caught by its own** (synthetic fixtures).
- **Found by the arms, and fixed:**
  - **No fixture carried across 32 bits.** With the carry into `adc` forced to 0, the program still
    passed every fixture and every disc image: PTS and durations stay under 2^32 ticks (13.25 h) on
    real discs, though the format allows 48-bit PTS and 64-bit sums. New case `syn_wide`
    (`tools/umd_reader_cases.py`): two items of 0xC0000000 ticks (the playlist's duration and an
    item's title time carry) and an item at IN 0xFFFF0000 (a Go To by time landing in it carries).
    Its goldens are the P1 parsers' and `umd_nav_ref`'s; **the hardwired reader passes it too**.
    Arms E1 (RTL) and W1 (the program) now catch a dropped carry, by `[base]`.
  - **A `title_done` raised with bytes still in the cache was invisible:** the bench counted the
    bytes before waiting for `title_done`. `umd_reader_tb.sv` now checks, at `title_done`'s rise on a
    complete phase, that every byte is out within 8 cycles (the old reader passes it too). Arm H3.
  - R10, the sd request lock after a mid-transfer restart, is the file-load unit's now (the engine's
    first read is the sniff); the pump's own lock cannot be reached by the bench (the pump is armed
    only after the walk's reads, which wait out an in-flight block).
- **Arms dropped, with the reason:** the slots' replacement order (it changes only how many sectors
  are read, and `[thrash]`'s 3x bound is loose by design); a byte past a file's last sector reading 0
  (H1: no fixture reads a field that crosses a file's end -- a known gap, as it was for the old
  reader's no-cross rule); `sltu` (the program does not use it: arm E8 mutates the branch compare
  instead).
- `tools/lint_undriven.sh` PASS.

**Area (`tools/synth_unit.sh`, the N0 wrapper):** the reader with its engine **1,350 LUTs / 1,609
registers** (the engine 773 / 384), against **6,098 / 3,594** for the hardwired reader; RAM bits
264,960 (the ROM 81,920; the cache 131,072; the slots 32,768). The program ROM's contents were checked
in the synthesis database (word 0 = `0x3000003740`, as `nav_ucode.mem`).

**N3, the fit (2026-10-07, `UMD_naveng_20261007_0425.rbf`, SEED 5, commit 335a5ba):** **36,384 ALM
(87 %), -2,743 from 39,127**; `umd_reader` **1,002 ALM** (was 3,749; the engine `nav_seq` 471); RAM
452 (+14: the ROM, the register file, the scratch, the slots); DSP 88; clk_dec **89.72 / 89.06 MHz**
(PASS, > 1.5 MHz margin at both corners: no sweep, A2'). The saving is the top of N0's 2.0-2.7K
estimate. With the hardwired subtitle decoder back (SD1: PR fj#34 measured -3,704 when it left, more than
its 2.4K by entity) the device would come to ~39.6-40.1K (94-96 %): SD1's own fit decides.

**The rig (2026-10-07, .236, `UMD_naveng_20261007_0425.rbf`, stock Main): ✅ HW-CONFIRMED.**
Screenshots of the core's raster (`.sim/rig/`, not kept):
- Akira mounts and plays; the HUD: the title (PARAM.SFO), Chapter 1, 00:00:18 / 02:05:15 (the
  playlist's duration, the program's 64-bit sum);
- Next chapter x2, FF (the hop's indicator), play resumes (Chapter 4, 00:08:21), Prev chapter;
- Go To: the editor opens on the shown chapter (a NAV_CHAP), steps 4 -> 7 (three more queries),
  lands in Chapter 7 (00:16:47); Go To by time (+1 h) lands at 01:16:54 (NAV_TIME);
- Now That's What I Call Music 2006 (30 items): Go To by time across item 0's end (lands in item 1,
  Chapter 2); two Next chapters cross items 1 -> 3; **the natural item handoff**: played through
  item 0's end at 3:11 -- 2:42, 2:53, 3:05 in Chapter 1, then 3:16 in Chapter 2, the HUD's time
  continuous (the item base).
The rig restored after (MENU core, stock Main).

**A dedicated trace bench (`run_nav_seq.sh`, planned in §8) was not built:** the engine's output is
only meaningful against the world it reacts to, so an instruction trace would need the emulator's
I/O replayed into the RTL. Instead the reader's bench drives the engine through every program path
on real data (267 fixtures' worth), and E1-E9 prove that bench sees defects in the engine's
instruction set. The cycle charges are held by the same bench: Sin City and Astro Boy (§8) pass only
if the RTL is no slower than the emulator.

## 10. SD1-SD3, the plan (2026-10-07; E1 / E2 taken)

**SD1, the decode back in the fabric, behind the host handshake as it is.** PR fj#34 (A7, B3) took the
decode out of `sub_top` and put a handshake in its place (`sub_top.sv`'s header: `h_req` with
{seq, buf, x, y, start, len}, answered by `h_done` with {seq, err, w, h}; a stale completion ignored
and counted; `h_gen` per flush). **SD1 answers that handshake in fabric**, with a new `umd/sub/sub_dec.sv`
doing what the UMD Main does today: read the unit's `len` bytes from the DDR3 ring at word `start`,
decode them with `png_top` (the hardwired decoder, E1: `umd/png/`, still in the tree and benched),
write plane `buf` at (x, y) through `sub_plane_wr` (restored from `1109398^1`), and complete with the
image's err / w / h -- only once every burst is written, as before. Why behind the handshake rather
than restoring the pre-fj#34 `sub_top`:
- `sub_sched`'s timing, the flush and stale-completion rules, `sub_flip` and P6d's `ui_sub` (planes 2 / 3,
  built on top of fj#34) stay exactly as benched and rig-confirmed;
- the decoder is one module with one contract, the same contract the HPS decoder met, so
  `run_sub.sh` / `run_overlay.sh` can score it against libpng as before.

The DDR3 side: the ring writer, the ring reader and the plane writer share ram2's A master again
(`sub_mem`'s merge of three, as before fj#34; the plane readers keep `B_FIRST`).

**SD2, the UMD Main (E2: the fabric always decodes).**
- `umd_host` stops carrying the subtitle request to the HPS; its HOST_RD row gains what the panel's
  compositor needs: the shown plane's buffer and its rectangle (x, y from the request, w, h from the
  completion).
- The panel's compositor (`ui_sub`, `panel.md` §2) reads that rectangle of the shown plane back from
  DDR3 (B2 proved the read-back word for word) instead of the RGBA it kept from its own decode;
  `umd_sub`'s decode retires. `run_hps_host.sh` / `run_panel.sh` re-scored.

**SD3, the stock Main and the manual.** The SUB gate on the UMD Main (B3: `player_ctl`'s `host_ok`)
comes out, with the transport HUD's message that went with it; `reference/compatibility.md`,
`playback/on-screen-messages.md`, `reference/troubleshooting.md`; `docs_check.py`,
`mkdocs build --strict`; the rig on a stock Main (subtitles shown) and with the UMD Main (subtitles
under the panel).

## 11. SD1-SD3, as built (2026-10-07, `feature/nav-engine`)

**Stage names.** §10 first called these S1-S3; "S1" is already 480i's stage (`analog.md`), so they are
**SD1-SD3** (the subtitle decode) everywhere since.

**SD1, the decode in the fabric (E1).**
- `umd/sub/sub_dec.sv` answers `sub_top`'s host handshake as the UMD Main did: the unit's bytes read from the
  DDR3 ring (bursts of <= 8 words, never across the ring's end, into a 16-word FIFO, unpacked byte 8k+i =
  bits [8i+7:8i]), decoded by `png_top` through `sub_png` (restored from `1109398^1`, on clk_sys as before A7),
  written premultiplied by `sub_plane_wr` (restored), completed with {seq, err, w, h} only once every burst is
  written. A unit of length 0 completes refused (E_TRUNC). A flush drops the decode, resets the PNG side,
  drains the read beats in flight, and never completes the dropped request.
- `sub_top` takes it behind `FABRIC_DEC` (default 1); with 0 it answers an external host as since A7, so the
  mock-host benches keep testing the scheduler and the handshake. `sub_mem` is three clients again (the ring
  writer first, the decoder's reads, its plane writes; no write burst starts while read beats are out).
  `sub_overlay` passes `FABRIC_DEC`, `pclk` and the A master's read return (ddr_mux2 always had it).
- `emu`: `pclk` = clk_sys; `umd_host`'s `h_req` tied 0 -- the UMD Main is never asked, so it never writes a
  plane the fabric writes. `UMD.qsf` names the PNG decoder and the three modules.

**SD2, the UMD Main (E2).**
- `sub_top` reports the shown unit's plane and rectangle, captured at the flip's acknowledgement with the seq
  (`h_sbuf`, `h_sx` / `sy` / `sw` / `sh`); `umd_host` carries them in its snapshot; HOST_RD **appends** words
  39-43 (`sub_plane`, `sub_x` .. `sub_h`; `tools/host_layout.py`; PROTO stays 1, NWORDS 44).
- The Main: `umd_menu_decode` needs only the P9 rows (an older core still runs the menus) and reads the new
  words when NWORDS says they are there; the panel's compositor (`umd_menu_run.c`) takes the core's rectangle,
  falling back to the host's own record of a unit it decoded (an older core). The read-back itself
  (`plane_get`) is unchanged. `umd_sub`'s decode stays in the Main, unused with this core.

**SD3, the stock Main.** `player_ctl`'s `host_ok` tied 1 in `emu` and the Subtitle button's tag no longer
waits for the UMD Main: subtitles on a stock Main. `player_ctl` and its bench are unchanged (the HOST path is
pruned in synthesis); the HUD's two subtitle messages stay in its ROM, unreachable. The manual: the Subtitle
row, the two messages and their troubleshooting sections removed, Compatibility / Install / Building /
acknowledgements / README say the UMD Main is for the disc menus and the control panel.

**Verified.**
- `bench/umd/sub_dec_tb.sv` (new, `run_sub.sh`): the units laid into a 32 KB ring (they wrap), each requested
  as `sub_top` would; every completion (seq, err as libpng's verdict, w x h) and every word of the plane
  (libpng's premultiplied pixels, zero elsewhere): synthetic (RGBA8, Adam7, RGB16, clipped, refused), Akira's
  first 12 units, The Mummy's tightest window; `+flush=1` (a decode dropped mid-way, then decoded again
  exact). The decoder's two masters through `sub_mem` into `ddr_model`'s Avalon checks.
- `run_overlay.sh`: the same bench in fabric mode (`-DFABRIC`, no mock host): the plane and the composite on
  the raster exact, synthetic, both flushes, The Animatrix (636 wide) and Stargate (349 x 441).
- `run_sub.sh` (the mock-host arms unchanged) + `sub_top_tb`'s new `[shown]` arm; `run_umd_host.sh --red`
  (words 39-43 against driven values); `run_panel.sh --red` (a new `[core]` arm in the runner check, R13
  catches a compositor that ignores the core's rectangle); `check_emu_wiring.py` (the new seams pinned);
  `lint_undriven.sh`; the UMD Main builds clean; `docs_check.py`, `mkdocs build --strict`.

**The fit (2026-10-07, `UMD_naveng_20261007_0601.rbf`, SEED 5, 52f18d8's RTL): 39,117 ALM (93 %)** -- +2,733
over N3, and **10 under P8's 39,127 without it**: the reader's saving paid for the decoder whole. clk_dec
**91.83 / 92.09 MHz** (PASS; > 1.5 MHz margin under 95 %: no sweep, A2'). `sub_dec` 2,582 ALM (the decoder
and its FIFOs, as `sub_png` was before A7), the subtitle side 4,275. **RAM 503 of 553 (91 %, +51)**, DSP 91
(+3): M10K, not ALMs, is now the tighter resource -- 50 blocks left.

**The rig (2026-10-07, .236, `UMD_naveng_20261007_0601.rbf`): ✅ HW-CONFIRMED.**
- **A stock Main:** the Subtitle button turns the track on ("1 English"; the old core answered "Subtitles
  need the UMD Main."), and Akira's lines show, change and hide on time over the picture -- the fabric's
  decode (Chapter 7's council scene, twelve shots 2 s apart).
- **The UMD Main (this branch's build), the control panel open:** the subtitle stays under the panel ("So
  you and your friends went out at night on your bikes to visit your dying mother,"): the host read the
  fabric's plane back by the rectangle HOST_RD reports (SD2) and drew the panel over it; the next line shows
  after the panel closes. The panel opens and closes over playback as before.
The rig restored after (MENU core, stock Main, the HIL Main removed).

**Merged with main (2026-10-07, 5ba3615: Analog Dither PR fj#56, the telemetry word index PR fj#58; eb41c95).**
`run_scaffold.sh --red`, `run_umd_reader.sh`, `run_sub.sh` ALL GREEN on the merge. The fit at main's pinned
SEED 1 passed clk_dec (89.68 / 89.79) but missed clk_mem by 0.027 ns at -40 C, on sub_mem's held write data
through `ddr_mux2`'s command compare into `sub_q`'s `dout_valid` -- the subtitle side's ring writer, the
path main's 78d2ed5 had missed on before SD1 existed (not the decoder's). The sweep (`tools/seed_sweep.sh`,
now failing a seed on any core clock's negative slack): **SEED 3 pinned, clk_dec 90.58 / 86.96, clk_mem
96.48 at -40 C, 39,425 ALM (94 %), RAM 503, DSP 90** (`UMD_naveng_20261007_0726.rbf`). Known: that clk_mem
path recurs seed to seed (two of the last four fits); if it binds again, register `ddr_mux2`'s
waitrequest to master A or give `sub_mem` a skid stage rather than sweep.

**The merged build on the rig (2026-10-07, .236, `UMD_naveng_20261007_0726.rbf`, SEED 3, a stock Main): ✅.**
Akira: six Next Chapter presses land in the police-station scene; the Subtitle button shows "Off", a second
press "1 English", and the lines ("It *couldn't* be these bozos.", "You can tell that just by looking.") show
and change on time over the picture. The rig restored after (MENU core, stock Main, the harness removed).
