# Display (roadmap Phase 5)

The display path from a decoded picture in the DPB to the raster: which picture, when,
through which port, and how a field pair is shown. `docs/roadmap.md` Phase 5 is the plan;
this note is the design as built, stage by stage. Status per stage at the end.

## 1. Scope and the decisions behind it

**Phase 5's scope (decided with the maintainer 2026-09-25): the core
display path on the 480p raster.** The 480i raster + csync, the analog vertical scaler
(Letterbox / Crop), a Film 24p raster and `av_sync` are later work (roadmap).

**ascal cannot blend.** Fed a 480i raster (`VGA_F1` toggling), ascal detects interlace
from the flag and **weaves** (default) or **bobs** (`HDMI_BOB_DEINT = 1`: the newest field
read twice with a half-line offset, no interpolation; `sys/ascal.vhd` 1217-1258,
2150-2168). There is no blend. MiSTer_DVD built its Blend in the core
(`dvd/field_blend.sv`, progressive raster only) and used ascal for Bob / Weave on its 480i
raster.

**The in-core deinterlacer here is cadence-exact for free.** H.264 says bitstream-exactly
which pictures were coded as field pairs (`field_pic_flag`). The census
(`umd_video_format.md`): film 3:2 and progressive titles are frame-coded, interlaced video
is field-coded. So the deinterlacer filters only stores decoded as fields; film and
progressive pictures pass untouched in every mode -- which ascal, blind to the content,
cannot do. Limitation: frame-coded interlaced pictures (legal, `pic_struct` 3/4 on a
frame; none in the census) are shown woven in every mode.

**The menu never offers what the raster cannot do** (the maintainer: "it's confusing to a
user to select blend but actually see bob"). This branch: `O[4:3] Deinterlace: Weave /
Bob / Blend`, in the core, 480p. At 480i (`feature/480i`, `docs/analog.md`) that line is swapped for an
ascal `Bob / Weave` line (bit `[5]`, `HDMI_BOB_DEINT`) with CONF_STR hide prefixes (`H0`/`h0`
on `status_menumask[0]`, the effective raster), and `[7:6]` is Video Output. `tools/docs_check.py` accepts the prefixes (it silently skipped them before
P5). ⚠ Verify stock Main's lowercase `h` (hide when the bit is clear) in `menu.cpp` before
relying on it.

## 2. The port: `ram2` (P5a)

The display reader is a read-only master on its own f2sdram port, `ram2` (`DDRAM2_*`, a
`UMD-FORK` in `sys/sys_top.v`: `architecture.md`). Why: MiSTer_DVD measured that a
second read master on the decoder's port costs the decoder by **occupancy**, not
bandwidth (`hw_budget_and_lessons.md` §2) -- the P4 smoke display shared `ram1` through
`ddr_mux2`. `ddr_mux2` stays in front of `ram1` for its mount abort, master B tied off.
The three ports share one DDR3 device and one address map: the display reads the DPB
stores at word `0x0600_0000 + store << 17` exactly as the decoder writes them.

## 3. The reader (`umd/disp_reader.sv`)

Born as the P4 smoke display (`h264_recon.md` §4): at the first dot of each raster line
it requests the next line (a toggle + line number to clk_mem), clk_mem fetches the luma
row (2W words) and the two chroma rows (W words each) in bursts of <= 8 into dual-clock
line buffers, and the clk_sys side converts BT.601 limited range to RGB, LAT 4. Chroma is
interpolated, not repeated, since 2026-10-12 (§12).

**Field-aware chroma (P5a).** A store of fields holds them line-interleaved in every
plane (`h264_recon.md` §2.2): luma line y is field (y & 1)'s line y >> 1, chroma row c
is field (c & 1)'s row c >> 1. A field's own 4:2:0 siting puts its line k on its chroma
row k >> 1, so luma line y of a field store takes chroma row `2 (y >> 2) + (y & 1)`; a
frame store takes `y >> 1`. The smoke display took `y >> 1` for both: on field content,
lines 4k+1 and 4k+2 took the other field's colour (chroma bleed on motion). The flag
(`pic_field`) is the completed picture's `done_struct != frame`, carried with the store
through emu's snapshot to the display's per-frame latch.

The golden for that siting is not the formula: `tools/disp_golden.py` has ffmpeg
`separatefields` split the woven store into its two fields (every plane), converts each
field with the plain 4:2:0 rule, and weaves the RGB back (`run_disp_reader.sh`,
`disp_field` arm; mutations D4 frame siting on a field store, D5 the other field's
chroma).

## 4. The VUI and the aspect (P5b)

**The front end parses the whole VUI** (E.1.1) and its `hrd_parameters()` (E.1.2) in
`sps_pps.sv` and emits every field as a header word, like every other SPS field (41 new
ids in `tools/h264_fields.py`, appended so the earlier ids stay). The model
(`h264_fe_ref.parse_vui`) records the same fields in the same order; the JM trace
normaliser keeps its `VUI:` fields now (aliases for JM's three non-spec names and the HRD
loop's `[i]`); `test_h264_fe_ref.py` compares the model's headers with ffmpeg's
`trace_headers`, VUI included. What is stored (`h264_pkg` `sps_t`): the picture-timing
SEI's delay lengths, `CpbDpbDelaysPresentFlag` and `pic_struct_present_flag` (the front
end's, P5c), the aspect, the timing and `max_dec_frame_buffering` (the reconstruction's
copy in `recon_hdr`, P5d). u(32) fields are read as two u(16) (`rbsp_reader` serves 31
bits) and emitted as one word.

Range errors (`ERR_RANGE`, the SPS not stored) only on what is stored or looped over:
`cpb_cnt_minus1` > 31, `num_units_in_tick` or `time_scale` 0, the two structures'
lengths differing, `max_dec_frame_buffering` > 16, `max_num_reorder_frames` above it.
The model raises at the same field. `chroma_loc` > 5 and the other unstored fields are
not checked (nothing aliases).

The fixtures no encoder makes come from `tools/h264_synth.py`, which rewrites an x264
stream's SPS with a VUI built bit by bit from the syntax table: `max` (every part present
at its maximum: two HRD structures of 32 CPBs, u(32) values of 2^32 - 1, ue(v) values of
2^32 - 2, 255s -- and EPBs inside the VUI), and one stream per range error. The maximal
SPS parses to the same 254 fields in the model and in ffmpeg's `trace_headers`.

**Aspect (`umd/aspect_vui.sv`).** The shown picture's `aspect_ratio_idc` (and its
Extended_SAR) travels with the store to the display latch; Table E-1 gives the SAR; the
display aspect sar_w W : sar_h H is rounded to the nearer of 4:3 and 16:9 (16:9 iff
9 sar_w W > 14 sar_h H; W, H in macroblocks). Unspecified (no VUI, idc 0 or reserved, a
0 in Extended_SAR) keeps the P4 rule, 16:9. `run_aspect_vui.sh`: Table E-1 read from the
spec PDF, the rounding checked against the table's own 25 labelled examples, every idc,
both sides of each entry's decision boundary, Extended_SAR edges. Cropping is not
applied to the aspect (no disc crops). ⚠ A HUD flag for "aspect unspecified, fallback" is
not built: it goes on the P5 HUD row (P5e).

**The aspect's hardware gate moves to P5e.** The harness screenshot is the core's raw
raster, upstream of ascal: `VIDEO_ARX/ARY` cannot be seen in it, so "Akira shows 16:9" is
not measurable in P5b (a round that never reached the state is not a measurement). The
P5e HUD row shows the aspect Auto chose (and the unspecified fallback); the gate reads it
on Akira (`aspect_ratio_idc` 5 -> 16:9) and on Family Guy or Short Circuit (idc 3 ->
4:3: their main titles' SPS, read 2026-09-26 -- every rig disc's SPS also says
`max_dec_frame_buffering` 3, timing 4004 / 240000, `pic_struct_present_flag` 1).

**The VUI oracles.** ffmpeg `trace_headers` (the x264 clip and the maximal VUI, 254 SPS
fields) and JM `ldecod`'s trace (`test_h264_trace_ref.py`: the maximal VUI, 1,614 records
identical to the model). JM holds the u(32) fields in an int and prints 2^32 - 1 as -1:
the normaliser reads `num_units_in_tick`, `time_scale` and the HRD values unsigned.

## 5. The picture timing SEI, the PTS, end of stream (P5c)

Every per-picture display fact reaches the reconstruction IN BAND, as header words after
the picture's first slice header (`first_mb_in_slice` 0), in this order: the picture
timing SEI's `cpb_removal_delay`, `dpb_output_delay` (when `CpbDpbDelaysPresentFlag`),
`pic_struct` (when `pic_struct_present_flag`), then the access unit's PTS as
`au_pts_lo` (bits 31..0) and `au_pts_hi` (bit 32). A picture without them simply has no
such words; the display infers (P5d). After the stream's last NAL unit: one
`K_EOS_WORD` (kind 19) -- in band, so it can never overtake the words before it. The
reconstruction's router consumes it (P5d gives it its meaning).

**The SEI (`umd/h264/sei_pt.sv`).** A byte-level walker over the SEI RBSP (0xFF runs for
payloadType / payloadSize; `nal_parser` has already removed the EPBs, so payloadSize
counts right). It keeps the first **9 bytes** of the last complete `pic_timing` payload:
the fields up to `pic_struct` are at most 32 + 32 + 4 = 68 bits. The clock timestamps
after `pic_struct` are NOT parsed -- nothing downstream uses them, and the walker skips
them by payloadSize (the rest of a known payload, not a bound). The payload waits because
its syntax depends on the SPS its access unit's first slice activates, which follows the
SEI (D.2.3 NOTE 1); `h264_top` interprets it after that slice's header, with that SPS.
The needed length is checked up front: too short emits nothing (`pt_short`). `pic_struct`
is emitted, then checked against Table D-1 (reserved values, `field_pic_flag` /
`bottom_field_flag`): a mismatch counts `pt_struct`, the display decides. A malformed
unit (a type or size cut by the unit's end, a payload running into its last byte, a
non-0x80 last byte at a message boundary) counts `sei_malformed`; a pic_timing it cut
leaves nothing pending. A picture that should have one (either flag set) and has none
counts `pt_missing`. None of these is a decode error: they never damage a picture. A
first draft (the session stopped mid-P5c) kept 64 bytes and parsed every clock timestamp
field; it had a width bug (a 64-byte payload's bit count, 512, wrapped to 0 in 9 bits)
and more area for no function.

**The PTS (`umd/h264/au_pts.sv`, positions from `nal_parser`).** The source-neutral input
is {byte, mark, PTS}: `ps_demux` marks the first payload byte of every video PES that
carried a PTS, and `vid_pts` (held from that header) rides with the byte through
`vidfeed_cdc`, now 42 bits wide -- the PTS cannot be sent separately, because PTS pulses
and marks are not 1:1 (`ps_demux.sv`: a PES of length 1 sets the PTS but marks nothing).
`nal_parser` counts its input bytes (24 bits, modulo) and reports each NAL unit's 3-byte
start code position. The rule (ISO/IEC 13818-1 2.4.3.7): a PES's PTS belongs to the first
access unit that COMMENCES at or after its first payload byte; an access unit commences
at its first NAL's start code (7.4.1.2.3: an AUD / SEI / SPS / PPS / 14..18 NAL after a
VCL NAL, else the picture's first slice). At each access unit start, `au_pts` pops every
stamp at or before it; the latest is the tag, earlier ones are counted (`pts_drops`: a PES
with no access unit of its own). The queue holds 4 stamps; a fifth evicts the OLDEST,
counted -- by then it can only be superseded, the newest can still be a tag (a draft
dropped the newest and lost the right tag on `--synth-marks`). UMD streams carry a PTS only on the PES that opens a GOP
(about every half second); the rest are untagged and the display extrapolates (P5e).

**Verification.** The model (`h264_fe_ref.decode_stream(..., marks=)`) against
independent oracles: its per-picture PTS equals ffprobe's per-packet PTS at the same
decode index on every tagged picture of the Akira and Family Guy windows; its SEI fields
equal ffmpeg `trace_headers` on the rewritten x264 streams. `tools/h264_synth.py`
rewrites an x264 stream's picture timing SEIs: every `pic_struct` value on frames
(`ps_all`), a 300-byte message full of EPBs + a payloadType >= 255 + an over-long
`pic_timing` (`sei_edge`), short / malformed / missing, and an SPS with other delay
lengths between an SEI and its slice (`sps_after_sei` -- where ffmpeg itself parses the
first such SEI with the old SPS, reading `cpb_removal_delay` 0 for 12: the fixture tells
the two strategies apart). `--synth-marks` puts PES marks at -1 / 0 / +1 / +2 around every
start code (a mark inside a start code belongs to the NEXT access unit). The RTL is scored
word-exact on all of them plus the disc windows (`run_h264_top.sh` E1-E5, A1-A4, Z1) and
through the whole chain with the demux's real marks (`run_p3_chain.sh`).

## 6. The output order, the holds, end of stream (P5d)

**What is output, and when (Annex C.4).** After each picture's marking the DPB runs the
output process: C.4.4 first (an IDR empties the DPB -- without output when
`no_output_of_prior_pics_flag` is set, else by bumping everything; an MMCO 5 bumps
everything), then C.4.5 (a reference picture: bump while the DPB is full, then store; a
non-reference picture: bump while full and something waiting has a POC at or below its
own, else output it directly without storing). A bump (C.4.5.3) outputs the waiting
picture with the smallest POC. The DPB size is `max_dec_frame_buffering` when the VUI
has it (Max(1, it)), else MaxDpbFrames from Table A-1 by `level_idc`, capped at 16. Every
readable disc's main title (49 of 49, `umd_video_format.md`) codes
`max_dec_frame_buffering` 3: three pictures of output latency. Without it a 720x480 Level 3.0 stream gets 6 and a 480x272
one 15 -- more latency, the same order.

**The STORE is the output unit.** The spec outputs PICTURES: a field pair's two fields
may leave apart when another picture's POC falls between theirs, and a non-reference
first field output directly (C.4.5.2) is gone before its partner is decoded -- the
partner, not "still in the DPB", is then stored and output later on its own. The display
shows stores (a pair is one frame buffer, woven). So a store is emitted when the
bumping FIRST selects it, whole, once per allocation, and never before it is complete: a
first field output directly waits (`pend_emit`) and goes out with its second field, or
unpaired when the next picture does not pair with it. This changes WHEN a pair's second
field is shown, never the order of stores: `tools/dpb_output_ref.py` runs the spec's
per-picture process literally over the model's events and checks that each store's
first appearance there is the model's emitted order, counting the "splits". JM does
the same (its output writes a pair's frame when the pair completes).

**Choices, recorded as deviations** (`spec_hardening.md`): `no_output_of_prior_pics_flag`
is used AS CODED -- C.4.4's inference of 1 on a picture size change is not made (JM does
not either; the display never shows a picture of the old size into a new CVS's first
frame, it shows the old pictures, which is the more useful failure). Level 1b (coded as
`level_idc` 11 + `constraint_set3_flag` in the Baseline / Main / Extended profiles) is
read as 1.1: the front end does not keep `constraint_set3_flag`; 1.1's larger DPB only
adds latency.

**The RTL (`umd/h264/recon_dpb.sv`).** Per store three bits beside the marking:
`waiting` ("needed for output"), `emitted` (once per allocation) and `pend_emit`; all
three keep a store busy. The process runs in new states between the marking and
`D_POST_MARK`, i.e. BEFORE an MMCO 5's POC rewrite (the spec bumps with the old POCs):
`D_OUT_C44`, `D_OUT_FILL` (a registered fullness, a cycle after any change), `D_OUT_C45`,
`D_OUT_SCAN` (the minimum-POC scan, one store a cycle through the existing table port),
`D_OUT_ACT` (bump / direct output), `D_OUT_END` (a pending pair completed), and `D_EOS`.
The DPB size is computed serially when a picture opens (repeated subtraction of
PicSizeInMbs from MaxDpbMbs, at most 16 steps; decoding takes far longer). End of stream
(the front end's `K_EOS_WORD`, P5c): the router pulses `eos`, the DPB closes the last
picture like a new one would, emits a pending first field unpaired, then everything
waiting in POC order, and pulses `eos_done` -- the last picture's `pic_done` comes with
it (P4 never completed the last picture of a title).

**Deadlock and release safety.** A picture's output step runs before the NEXT picture
opens a store, so references + waiting <= the DPB size <= 16 when a store is chosen;
with 20 stores (`h264_pkg` NSTORE) at least four are free unless the DISPLAY holds some.
Then `D_OPEN` waits for a release (`stall_cycles` counts every cycle); a wait longer
than `STALL_LIMIT` (11 M cycles, ~4 frame periods) counts `err_no_store` (code 6) and
waits on -- a display that never releases is visible, never a silent hang, and never a
store overwritten on screen. The display always releases (it holds one store on screen
plus the queue, and pops one per refresh), so the wait ends.

**The queue (`umd/recon_out.sv`).** Per store a table of the picture's display facts,
written when it opens (the "a" half: size, cropping, aspect, `pic_struct`, PTS, IDR;
the "b" half: a pair's second field's `pic_struct` and PTS) on clk_dec and read by
clk_sys; a record FIFO (clk_dec -> clk_sys: store, frame / unpaired / first-bottom /
fields decoded; one END record after `eos_done`); a release FIFO back; and the holds,
`oq_hold` = recon_dpb's `disp_hold`: set when a store is emitted, cleared when its
release arrives. A queued store cannot be written (held), so its table row is stable
until it is released; at most 20 records are ever queued, the FIFOs are 32 deep (a
push into a full one sets `rec_ovf`, a release of a store not held `rel_bad`: both on
the HUD, both design errors). The timing SEI's `num_units_in_tick` / `time_scale` are not
in the table yet (P5e adds the field period there).

**The interim consumer (emu, until P5e).** At line 500 of every other refresh (~29.97
stores a second) it takes the next record and releases the store shown until then:
line 500 is after the last line's fetch and before line 0's, so no read of the
released store is still to come. 29.97 field-pair titles play at their rate; 24p film
plays 1.25x fast, and the decoder, faster than that, waits on the display's holds --
the path this stage exists to prove on the rig. The END record is taken and the last
picture stays up, held. An unpaired field is shown woven with whatever the store's
other field lines hold (P5f bobs it: §8).

**Not yet benched (P5e's verification):** the display's side of the hold contract -- a
read by `disp_reader` of a store it does not hold (the plan's `ddr_model.sv` / cosim
`$fatal`) -- and the seam recon_dpb -> recon_out -> the consumer in one simulation (each
half is benched alone; `recon_top_tb` and the cosim play the display themselves). P5e's
scheduler replaces the interim consumer and gets both. Until then the rig's HUD is the
instrument: `X` 0 (`rel_bad`), `OUT` trailing `P4 PIC` by the DPB size, `ERR` 0.

**The HUD** gains a row: `OUT` stores emitted, `DIR` non-reference pictures output
directly, `DRP` stores dropped by `no_output_of_prior_pics_flag`, `DPB` the fullness
(references + waiting), `WT` the cycles the decoder waited on the display (/4096), `X`
faults {DPB full of references alone (a non-conforming stream), queue overflow, bad
release}.

**Verification.** The model (`h264_recon_ref.output_step`) three ways: the spec's
per-picture process (`dpb_output_ref.py`: the store order equal, splits counted),
ffmpeg's display order (`framemd5`), and JM `ldecod`'s output (JM honours
`no_output_of_prior_pics_flag`, ffmpeg does not -- on `c44n` JM and the model output 7
stores, ffmpeg 14; ffmpeg also drops a cut window's trailing unpaired field, set aside
and counted). Fixtures (`run_recon_top.sh`): x264 B pictures with a VUI DPB of 2 (six
direct outputs), that stream's second IDR with `no_output_of_prior_pics_flag` set, a P
stream with an MMCO 5 spliced in (both through `tools/h264_synth.py`, the VUI dropped so
the size comes from Table A-1), a JM field stream whose B pairs are output directly
(`jdefer`, `jm_fixtures.py`: coverage-checked, order checked against the spec process
and JM), a conformance field stream cut after a first field (`fodd`: unpaired at the
end), and `r16s` -- 16 reference frames with display holds of up to 600,000 cycles, so
the decoder must wait (916,499 cycles of it) and still decode every picture exactly with
no error. `recon_top_tb [out]` scores every emission's store, shape and WHEN (the
pictures opened before it: a DPB-size error moves the timing, not the order); `[hold]`
fails any DDR3 write burst into a store the display holds. Mutations O1-O12 (order, the
two size sources, `no_output`, MMCO 5, direct output, the pending pair, the EOS scan, the
stall, the busy term, the unpaired flag, the wiring), each caught by its own arm.

**Found on the way.** The bench scored each completed picture by a counter read inside
a `fork ... join_none` after the parent had moved it (and in static variables shared by
overlapping scorers): harmless while pictures completed far apart, wrong on the first
field pair whose first field completed in the cycle its second field opened. The
scoring is now an in-order queue. And the bump path first emitted every store as paired:
a lone field bumped later (the stream's end, or a partner that never came) must go out
unpaired -- the `fodd` fixture and O11 pin it. The first mutation round found two
more: the scan's "at the end of stream, the current store too" term was dead code
(`D_POST_MARK` has already closed the last picture, so it is a candidate anyway: an
equivalent mutant, the term removed, O8 now skips the end-of-stream flush); and the
bench's `[hang]` arm excused EVERY cycle the DPB waited on a hold, so a DPB waiting on the
bench's own scoring hold (R9, NSTORE 16: no store ever free) ran to the 2-hour timeout --
a wait is now excused only while the bench-display holds a store it will release.

## 7. The scheduler: STC pacing and field cadence (P5e)

**The model.** A set-top box's: one 90 kHz clock (the STC) that just runs, from the same
27 MHz crystal as the raster (`clk_sys / 300`), so the RATE of display and content is
locked by construction and the scheduler owns only PHASE. It anchors the STC to a
picture's PTS and, at every refresh, decides whether the store at the head of the
output queue is due. `umd/disp_sched.sv` is MiSTer_DVD's scheduler with surgery (its
header lists what was kept and what was dropped, and why -- `harvest.md`);
`umd/disp_ctl.sv` is the control around it; both on clk_sys, so none of it costs the
decoder's timing. `tools/disp_sched_ref.py` is the reference, written from the rules
below.

**Duration** (Table E-6, DeltaTfiDivisor, checked against the spec text): a frame lasts 2
clock ticks, or by its `pic_struct` 0/3/4 -> 2, 5/6 -> 3, 7 -> 4, 8 -> 6; a field 1 (a
pair 1 + 1). A tick is `num_units_in_tick / time_scale` (C-1): `field_q3 = 720000 x nuit
/ ts` eighth-ticks of 90 kHz (UMD: 4004 / 240000 = 12012, 1/59.94 s; the 23.976
progressive discs 5005 = 15015). The division is serial (24 steps) on clk_sys when a
record reaches the head -- recon_out's table carries `timing_v`, `nuit` and `ts`, so
there is no write-after-emit window (a record's row is written when its picture opens).
No VUI timing: 12012 and flag 1. A quotient >= 2^24 eighth-ticks (a tick over 23 s) is
clamped, or `time_scale` 0 defaulted, flag 2 (`spec_hardening.md`). A `pic_struct` that
does not fit the store (1/2 on a frame, 0/3-8 on a field, 9-15) takes the default, flag 4.
A pair tagged only on its second field: that PTS minus one tick.

**The refresh contract** (exact to the tick, which is what lets the model score the RTL
refresh by refresh): the tick is phased to the raster -- P = 0 at the first (h 0, v 0)
after the mount reset, a tick at every P = 300 m -- so a 450,450-cycle refresh is 1501.5
ticks. At line 499 the head is EVALUATED with that cycle's STC; at line 500 a due head is
TAKEN: the store shown until then is released (its last line was fetched at line 478,
line 0's comes at 523 -- P5f's fetch two ahead, §8), the new one latched for the reader. **Due**: STC >= want - 750
(half a refresh), want = the head's PTS when tagged, else the timeline's next PTS (the
last one's plus its duration). **Anchor**: the first head, or a TAGGED head more than a
frame behind the timeline, more than 0.5 s ahead of it, or more than 2.7 s late.
**A lone PTS is disbelieved** (`fix/film-timing`, §10; the maintainer's rule A, 2026-09-29,
and rule B, `fix/lone-early`, §10.9): a tagged head more than half a refresh (750 ticks) and
at most 0.5 s AHEAD of the timeline or BEHIND it, not past LATE_MAX, is taken as untagged --
shown on the timeline -- unless the previous tag taken was disbelieved too (`susp`), so the
next tag is always believed and a real jump under 0.5 s is followed one tag (~0.5 s) later. The discs carry one-off PES PTS
1-8 ticks late with the next tag back on the old timeline (73 of 88 images, §10.6);
believing one held a picture up to 3x and then read its return as a backward jump.
A jump behind the timeline past 0.5 s still re-anchors at once. The edge is half a refresh, not a
frame: a +1-tick lone PTS believed repeats a picture for one refresh, and a +1-frame one
(23.976) comes back as a re-anchor. Counted: `lone` (telemetry `sched`[3:0], saturating
at 15).
**Lateness is not a discontinuity** (MiSTer_DVD's HW round B): a late head is shown at
once and the timeline continues from it; an overdue queue drains at one store a refresh,
and on this 59.94 raster every census content class has at least two refreshes a store,
so the display catches up without dropping. Not so for a stream of single 59.94 fields
(one tick each: the display's maximum rate) -- none in the census; a starve there would
recover only at LATE_MAX (`reference/compatibility.md`). DVD's catch-up drop is not
ported for that reason. **END**: the record is taken at a pickup; the last store stays
up, held.

**Parity**: a field store (a pair) shows `first_bot ^ (refreshes since its pickup) & 1`
-- first the field decoded first, then the other, alternating while it is held; a
single field its own; a frame 0. P5e carries it to `disp_reader` (`pic_parity`); P5f's
Bob and the future 480i raster use it.

**Instruments** (the HUD's last row, `DC FT LG RA LT CE F`): `DC` the (store, parity)
changes the control DECIDED; `FT` the ones `disp_reader` FETCHED, counted on clk_mem
from what it captured with each frame's line-0 request -- the independent half of the
judder gate: over any span of settled playback their deltas are equal (the reader resets
with the core, not per mount -- a DDR3 read master cannot be reset mid-burst -- so the
raw values differ after a remount; the gate compares deltas); `LG` the last pickup's
lag (want - STC) in ms; `RA` STC anchors (1 on a continuous title); `LT` late pickups: the
picture was ALREADY due at the previous refresh (a missed opportunity -- starved or
backlogged; judged with the previous eval's STC on the same timeline). The first
definition, STC - want > half a refresh at the pickup, counted the 2.5-refresh rhythm
of 23.976 film -- every other frame is taken ~750 ticks after its PTS, the best a 59.94
raster can do, and the phase noise of the disc's time stamps pushed some over: X-Men 2
read `LT` 21 a minute on the rig with the decoder ahead of the display (`WT` climbing),
while 3:2 film and field pairs, whole-refresh cadences, read 0; `CE` cadence errors: a store held a refresh count outside
{floor, ceil} of its duration / one refresh, judged at the next contiguous pickup -- a
self-consistency check (it shares the scheduler's `field_q3`; `FT` is the independent
one); `F` the flags above.

**Verification** (`run_disp_sched.sh`, Verilator `--timing`: a 300-refresh scenario is
~135 M clk_sys cycles on three clocks): `recon_out` -> `disp_ctl` + `disp_sched` ->
`disp_reader` over `ddr_model`, with the real raster (`sync_gen`), fed the model's
scenarios and scored at line 510 of EVERY refresh ({shown, store, parity, field}), then
the counters, `FT == DC`, and every reader burst from a store the display holds -- which
closes P5d's two open seams (the display-side hold contract, and the queue -> control ->
reader chain in one simulation). Scenarios: 3:2 film, 23.976 progressive (2.5 refreshes
a frame), TFF / BFF pairs, `pic_struct` 7 / 8, single fields, sizes + no VUI timing, a
late decoder, a backward PTS jump, a 0.3 s gap waited out, a 2 s gap re-anchored,
LATE_MAX after a 4 s still, and a 400 ms starvation that must NOT re-anchor (the DVD
regression [8b]).

**The transport (P6b3, 2026-09-28; `transport.md` §2.1, §9).** `disp_ctl` gained four
inputs from `umd/player_ctl.sv`:
- `freeze`, refresh-aligned: no eval, no pickup, no parity step, no STC tick. `frz` goes to
  the audio gate.
- `resync`, a seek. The queue is drained unseen, the scheduler is cleared through
  `disp_sched`'s `clr`, and the shown store is kept. The display then waits for the
  target.
- the target, `tgt_*`: records before it are skipped. The skipped run is timed in
  eighth-ticks with one tick of tolerance, and the first shown record anchors at its time.
- the stop at OUT, `stop_*`.

`sh_pts` (the scheduler's `want` at the pickup) is the shown picture's time.
`disp_sched_ref.py` learned the same rules from the plan; `run_disp_sched.sh` has seven
scenarios for them (pause, pausefld, seek, seekfrz, seeknoskip, mountin, stopout) and
mutations D15-D24.

## 8. The deinterlacer: Weave / Bob / Blend (P5f)

**One window, three kernels, in the reader.** Bob and Blend both need the lines above
(a) and below (d) the display line (b). `disp_reader` now fetches the line TWO ahead of
the raster (the blank lines 523 and 524 fetch lines 0 and 1; line v fetches v + 2) into a
ring of four line buffers, so a, b and d are all present while the next line lands. Each
plane has three copies written alike, one read port per window line: nine simple
dual-clock RAMs (196,608 bits; `synth_unit.sh`: all nine inferred, the reader 499 ALMs)
-- never one array read three ways, which Quartus leaves in registers. The kernel runs in
readout stage 2 on each channel's own samples (after the field-aware chroma siting: each
fetched line carries its own field's chroma row), so LAT stays 4 and emu's composition is
untouched. No bandwidth is added: still one line fetched per raster line.

| store | Weave (0, and the unused 3) | Bob (1) | Blend (2) |
|---|---|---|---|
| frame | b | b | b |
| field pair | b | keep `pic_parity`: its lines b, the other field's `(a + d + 1) >> 1` | `(a + 2b + d + 1) >> 2` |
| single field | bob, its own field | bob, its own field | bob, its own field |

- **Only stores of fields are filtered.** H.264 says which pictures are fields
  (`field_pic_flag`), so film and progressive pass untouched in every mode (§1).
  **It does not say which fields belong to one film frame.** Hard-telecined film (film
  coded as 59.94 field pairs, 15 main titles) is woven pair by pair and combs on 2 pairs in
  5. Field matching is planned in `telecine.md` (Forgejo fj#80). A
  frame-coded interlaced picture (`pic_struct` 3/4 on a frame, none in the census) is
  shown woven in every mode.
- **Bob is temporal for free.** `disp_ctl` already alternates `sh_parity` every refresh on
  a pair (the field decoded first, then the other): Bob keeps that field and rebuilds the
  other field's lines from the kept lines above and below, so a pair becomes two
  pictures 1/59.94 s apart. Not line doubling: a doubled field bounces half a field line
  between refreshes; the interpolated one keeps each field's lines where they are.
- **Blend is static**: the (1, 2, 1) mix is the same on every refresh a store is held
  (MiSTer_DVD's lesson, `dvd/field_blend.sv`: no per-refresh state, no shimmer).
- **A single field** (unpaired; the store's other lines hold nothing of it) is bobbed on
  its own field whatever the menu says -- the interim display showed it woven with stale
  lines (§6). `disp_ctl` exports it as `sh_single`.
- **Edges mirror** (a := d on line 0, d := a on the picture's last line), by the ring
  slot the copy reads -- an edge line keeps an interior line's balance of the two fields,
  and no line outside the picture is ever read. A picture taller than the raster
  (720x576, legal at Level 3.0: 1,620 macroblocks) is clipped at line 479, whose d is the
  picture's real line 480: the reader fetches it at raster line 478 when the picture has
  it (a mirror there would be wrong; a first draft mirrored at 479 and needed a special
  term an H <= 480 fixture could not see).
- **The mode** is `status[4:3]`, latched once a frame at line 524, so a menu change never
  splits a picture. **Fetch timing moved:** line 0 at raster 523 (was 524), line 479 at
  477, a taller picture's line 480 at 478: the last fetch is still before the line-500
  release and the next frame's first after it, so disp_ctl's hold contract is unchanged
  (`run_disp_sched.sh [hold]`).

**Blend's rounding is ffmpeg's**, `(1 + a + 2b + d) >> 2` (vf_tinterlace's
`lowpass_line_c`, measured: the `interlace=lowpass=linear` filter on a duplicated frame
matches it on every interior line), chosen so Blend has an independent oracle. DVD used
`+ 2`; the difference is invisible. ffmpeg clamps each FIELD's first and last lines to
themselves, which is not the reader's rule: `tools/disp_golden.py` feeds it the 4:4:4
planes padded with two mirrored lines each side and crops, so the filter's edge rule never
touches a scored line and the golden checks the reader's mirror too. Bob has no exact
ffmpeg equivalent (its bobs are temporal or edge-directed): its golden is the formula,
and its kept lines are the ffmpeg-split weave's.

**Verification** (`run_disp_reader.sh`): every dot `{de, R, G, B}` of a whole raster
against the golden, 13 arms -- `[rgb]` / `[field]` Weave (unchanged fixtures, byte for
byte); `[pass]` a frame in Bob and in Blend; `[blend]` at 720x480, 480x272 (the bottom
mirror inside the raster, black beyond) and 720x576 (the clip); `[bob]` both parities at
720x480 and 480x272 (the top mirror when the bottom field is kept, the bottom mirror when
the top is); `[single]` one field in Weave and in Blend. Mutations K1-K10 (rounding, Cb
left out, the kept field inverted, the rebuilt line's rounding, each mirror, line 480
unfetched, frames filtered, a single field following the menu, the mode never latched),
each caught by its own arm, with D1-D5 re-run (D3 re-anchored on the ring slot).
`run_disp_sched.sh` scores `sh_single` at every refresh against `disp_sched_ref.py`
(D14); `run_scaffold.sh` W33 / W34 pin the menu bits (`check_emu_wiring.py` reads them
from the CONF_STR line) and the single flag.

**Not built:** a HUD / telemetry readout of the kernel in use (the rig gate is the
screenshot itself, below); the 480i raster's Bob / Weave through ascal (§1, later).

**The rig gate** (`tools/comb_metric.py`): the mean absolute second difference down the
columns, `|2 b - a - d|`, over the picture in a raw screenshot, divided by the same over
two lines (within a field) -- the comb of a woven field pair. Its self-test proves it
separates a woven pan from a progressive, blended and bobbed one before it is trusted.

**✅ HW 2026-09-27** (`UMD_p5f-deint_20260927_0206.rbf`, Diagnostics Off, the mode
switched live with `mister.py osd`): **Family Guy** (field pairs), three rounds of
Weave / Bob / Blend with three shots each: Weave 0.41-0.50, Bob 0.33-0.35, Blend
0.33-0.36 -- every Weave shot above every Bob and Blend shot; then four triples with the
mode switched between consecutive shots of one scene: Weave highest in all four
(+0.07-0.13). Zoomed, static thin diagonals are sharp in Weave, stair-stepped in Bob (one
field: half the vertical detail) and soft in Blend -- each kernel as designed, no stray
lines or colour errors. **Akira** (3:2 film, frame-coded), the control: four triples with
no mode ordering (Weave lowest in one) -- film untouched. `telem --watch 30` in Bob:
Family Guy decided +1,918 = fetched +1,918 (59.94 changes a second: one field per
refresh), 29.97 pairs a second, 2.00 refreshes a pair; Akira +761 = +761, 2.50 refreshes
a picture; `late` / `starve` / `cadence` 0, one anchor, decode errors 0 on both.
Not exercised on the rig: a single field (none in the census; benched), a 720x576
picture (none in the library; benched), a menu change mid-title beyond the live switches
above.

## 9. Status

| stage | what | status |
|---|---|---|
| P5a | `ram2` fork, `disp_reader` on it, field-aware chroma, `VGA_DE` from the raster | ✅ MERGED (PR fj#8). ✅ benched (`run_disp_reader.sh --red`, `run_scaffold.sh --red` W12-W16, T1-T4); fit `UMD_p5display_20260926_0007.rbf` (SEED 1, clk_dec 91.09 / 89.65, 25,084 ALM, no 10236); ✅ HW 2026-09-26: Family Guy 98.1 fields/s (1.64x; 95.9 on ram1), The Office Disc 01 84.3 (1.41x; 83.1), ERR 0, pictures clean -- the port move cost the decoder nothing |
| P5b | VUI parsing, aspect from the VUI | ✅ MERGED (PR fj#8). ✅ HW 2026-09-26 (`UMD_p5display_20260926_0145.rbf`, `mister.py shot --scaled`): Family Guy (VUI idc 3) on Auto 1440x1080 = 4:3, identical to the forced 4:3 shot, forced 16:9 1920x1080; Akira (idc 5) on Auto 16:9; ERR 0, pictures clean. ✅ benched (+ `test_h264_trace_ref.py`: JM `ldecod` == the model on every field of the spec-maximum VUI): `run_h264_top.sh --red` (24 fixtures incl. the x264 VUI clip, the maximal synthetic VUI and five range errors; 23 mutations, V1-V6 new), `run_aspect_vui.sh --red` (5), `run_scaffold.sh --red` (W17 / W18), the model vs ffmpeg `trace_headers` VUI included; fit + HW pending |
| P5c | SEI `pic_timing`, PTS to the decoder, end-of-stream word | ✅ MERGED (PR fj#8). ✅ benched (§5; `run_h264_top.sh --red` 32 runs / 35 mutations, `run_p3_chain.sh --red`, `run_recon_top.sh`, `run_cosim.sh`, `run_diag_hud.sh --red`, the model vs ffmpeg / ffprobe in `test_h264_fe_ref.py`); fit `UMD_p5display_20260926_0501.rbf` (25,991 ALM, clk_dec 87.83 / 86.93 -- 0.93 MHz of margin; the 40 worst paths at -40C are all P4's `mv_pred` `sp_mode` / `b8` -> `mvp_q`, none of P5c's logic: placement at 62 %; the path to pipeline if P5d's fit misses); ✅ HW 2026-09-26: Akira `PT` = `P4 PIC` (every picture timed), `NO` / `BAD` / `SX` 0, one PTS per ~12 pictures (~0.5 s), 0 dropped, `PS` 5 / 6 (film); Family Guy the same with one PTS per ~28 fields, ERR 0 |
| P5d | output order (C.4.5.3), hold / release, EOS flush | ✅ MERGED (PR fj#8). ✅ benched (§6): `run_recon_top.sh --red --discs` (26 runs incl. `c44b/n/m`, `jdefer`, `fodd`, `r16s`; 32 mutations, O1-O12 new), `run_recon_out.sh --red` (3 seeds, 7), `run_cosim.sh` (Family Guy 1.65x, Akira 1.91x, order + holds scored) + `--red` (C7 / C8 new), `run_scaffold.sh --red` (W10, W21-W23), `run_diag_hud.sh --red`, `test_dpb_output_ref.py` (+4 RED; the model == the spec process == ffmpeg == JM); fit `UMD_p5display_20260926_1507.rbf` (SEED 1, clk_dec 87.25 / 87.31, 26,627 ALM, M10K 233); ✅ HW 2026-09-26: Akira `OUT` 3 behind `P4 PIC` (`DPB 03`), 29.5 stores/s (the interim consumer's rate), `WT` climbing (the decoder waits on the display: 24p decodes at 1.8x), the reader paced down with it; Family Guy 28.7 pairs/s, 3 pairs behind; `X` 0, `ERR` 0, pictures clean on both. The rig shows the process running and nothing written under the display; ORDER as seen is the cosim's (1 fps screenshots cannot see reordering). ✅ A title's end exercised on the rig at P5g (the P5g row). ✅ The whole-library `run_cosim.sh --sweep` since P5d (P5g: 88 of 89 bit-exact, order + holds scored); a subset of 8 (2026-09-26: The Office Disc 01, Ghost in the Shell 2.0, South Park, Tom & Jerry, The Dark Knight, Interstella 5555, Austin Powers, Goo Goo Dolls -- the slowest windows of the P4 sweep and five field-coded titles) all PASS, order and holds scored, 1.35-1.77x real time |
| P5e | the scheduler (STC, field cadence) | ✅ MERGED (PR fj#9) (§7): ✅ benched -- `run_disp_sched.sh --red` (16 scenarios refresh-exact vs the model; 13 mutations: D3 on the 200 ms backward jump -- on a 5 s one the LATE_MAX leg re-anchors too; D13 on single fields -- only they take a picture at the refresh right after an anchor), `run_recon_out.sh`, `run_disp_reader.sh`, `run_diag_hud.sh`, `run_scaffold.sh --red` (W24-W26); `disp_ctl` + `disp_sched` alone 1,132 LUTs / 862 registers / 5 DSP; fit `UMD_p5sched_20260926_1851.rbf` (SEED 1, clk_dec 90.99 / 89.44, 27,332 ALM, M10K 238, DSP 74 -- the first fit missed at 84.48 on P5d's output scan, now two stages); ✅ HW 2026-09-26, 60 s each on settled playback: Akira (3:2) +1,472 DC = +1,472 FT (24.1/s), X-Men 2 (23.976 progressive) +1,470 = +1,470, Family Guy (pairs) +3,678 = +3,678 (30.1 pairs/s); `LT` 0, `CE` 0, `RA` 1, `F` 0 on all three. (The first round's X-Men 2 read `LT` 21 a minute: the late definition, fixed -- §7.) |
| P5f | Weave / Bob / Blend | ✅ MERGED (PR fj#12) (§8): ✅ benched -- `run_disp_reader.sh --red` (13 arms, K1-K10 + D1-D5), `run_disp_sched.sh --red` (D14), `run_scaffold.sh --red` (W33 / W34); fit `UMD_p5f-deint_20260927_0206.rbf` (SEED 9, clk_dec 91.68 / 90.28, 28,062 ALM, M10K 256 (+18), DSP 74; SEED 1 missed at 85.95 on P4's `mv_pred`, none of P5f's paths); ✅ HW 2026-09-27: Family Guy Weave combs above Bob / Blend in every shot, Akira (film) the same in every mode, `DC` = `FT` in Bob on both, errors 0 (§8) |
| P5g | closeout | ✅ MERGED (PR fj#13), HW-CONFIRMED. (⚠ **P6b7's whole-film gate found a display-timing defect** at three points of Akira, reproducible: three pictures held twice their duration, then a re-anchor ~83 ms back, the decoder's store alarm tripping on the way. The decoder is bit-exact there. **Cause found 2026-09-29: a lone PES PTS on the disc, believed by the scheduler (§10.6); the two Family Guy re-anchors below were the same.** Fixed by the lone-PTS rule (§7, §10.7) on `fix/film-timing`. `transport.md` §9 "P6b7, as built", the Phase 6 gate.) **Timing:** `umd.sdc` bounds every `cdc_snap` at 8 ns (`hold -> dst_data`, the two synchroniser first stages): the three clk_mem -> clk_sys snapshots had sat at -0.28 / -0.09 ns since P5e, timed on the 3.7 ns 90 / 27 MHz edge window the handshake never uses; `fmax_check.sh` now warns on negative setup slack on any core-PLL clock; `disp_reader`'s dead `m_parity` gone. Fit `UMD_p5g_20260927_0308.rbf` (SEED 9, clk_dec 92.91 / 90.46, 28,073 ALM, M10K 256, DSP 74; every core clock positive, clk_sys +2.32 / +2.52 ns); ✅ HW 2026-09-27, 60 s of settled playback each (`telem --watch 60`, Bob): Family Guy 29.970 pairs/s, 2.000 refreshes a pair, decided +3,851 = fetched +3,851; Akira loaded over it, 23.976 pictures/s, 2.500 refreshes a picture, +1,541 = +1,541; `late` / `starve` / `cadence` 0, one anchor, decode errors 0 on both, Akira's picture clean (a first Akira window that began inside the launch transient read -1,541 ppm and a re-anchor: discarded, re-measured settled). ✅ `run_disp_reader.sh`, `run_scaffold.sh`. **✅ A title's end on the rig** (2026-09-27, the P5f build, Family Guy's whole 22.6 min main title in Bob): the END record taken (`sched` ended), every emitted store picked up (40,652 = 40,652), `late` / `starve` / `cadence` 0, decode errors 0, the judder gate equal throughout and after the end (a held pair still alternates its fields: `DC` = `FT` climbing ~60 / s); the last picture held -- two shots 12 s apart identical, black, and the stream's own last ~85 pictures are video black (ffmpeg: peak luma 16-18). Two re-anchors mid-title, at 521 s and 747 s of the title: the stream's timestamps skip a field and repeat one at seven edit points (351, 521, 747, 778, 1,010, 1,120, 1,349 s); the scheduler re-anchored at two of them, with nothing late or dropped (why only those two: **measured 2026-09-29, a lone PTS +5 ticks at 521.10 and 747.06 s**, §10.6; the other five are not). **✅ The whole-library `run_cosim.sh --sweep`** (2026-09-27): 88 of 89 disc images bit-exact over 300 frames of the main title with the output order and holds scored (Desperado SKIP: a zero-filled rip), 0 FAIL / REFUSED / ORACLE; every PASS >= 1.35x real time (the slowest The Office Disc 01 1.35x, as at P4; Red Hot Chili Peppers 1.40x next). Per disc against the P4 sweep (2026-09-25): no verdict changed but Astro Boy (FAIL -> PASS, P4's later fix); the library changed since (King Kong now two disc ISOs in a folder, My Chemical Romance two, Hellboy II's empty zip gone, Metallica and Now That's What I Call Music 2006 added). The runner globs only the top level: the two folders ran as their own sweeps (since fixed: `--sweep` descends one level, `fix/timing-tools`). |

## 10. The film-gate timing defect (`fix/film-timing`, PR fj#25) -- FIXED

**Status: ✅ FIXED, ✅ MERGED (PR fj#25), ✅ HW-CONFIRMED (2026-09-29): the whole-film gate passes** (§10.7). Rule B (lone EARLY PTS too, §10.9) ✅ MERGED (PR fj#26), ✅ HW-CONFIRMED. The
cause is the discs: a **lone PES PTS** (§10.6), and the display believed it. The fix is a rule
in `disp_sched` (§10.7, §7). Found by P6b7's whole-film gate
(`transport.md` §9 "P6b7, as built", the Phase 6 gate). The maintainer (2026-09-29): fix it
on this branch, then run the film gate again. That closes P6b's exit. The manual's
compatibility page states it as a known issue: remove that admonition when fixed.

### 10.1 The symptom (measured on the rig)

At three points of Akira (3:2 film, clip 1, IN 90,000), at PTS **3,352.06 s, 3,888.45 s,
6,758.27 s** (title time 55:51, 64:47, 1:52:37), the same sequence runs each time:

1. In one 0.25 s telemetry sample the display takes **3 pickups instead of 6**, while the
   shown PTS (`sh_pts`) still advances a full 0.25 s: three pictures on screen ~2x their
   duration. In the same sample the decoder opens 3 pictures, not 6 (`pics`), and
   `wait4k` says it spent ~65 % of it waiting on the display.
2. `recon_dpb` counts **error code 6** (`err_no_store`): one D_OPEN wait for a free store
   passed STALL_LIMIT (11M clk_dec cycles, ~122 ms). A release comes only with a pickup.
3. ~0.7 s later the STC steps **back ~83 ms** (the `stc` word advanced 941 x 16 ticks in a
   0.26 s sample instead of ~1,406 x 16). This is a re-anchor: a TAGGED head more than one
   frame BEHIND the timeline (`disp_sched_ref.py` "anchor"). `aud_out` re-arms on the
   step (`aud_rearm` resync +1); `av_err` reads -9,009 ticks in one sample, then 0-1 again.

`starve`, `late`, `cadence` and the flags stay 0 throughout. The rest of the 2 h 9 min film
is clean (`av_err` 0-1 tick, errors 0).

### 10.2 What is ruled out

- **A timestamp discontinuity**: the PES PTS run on, with no jump over 1 s and none backwards.
- **The decoder**: the cosim over 3,344-3,361.5 s is bit-exact on all 420 pictures, stores
  emitted in the model's order, no error, 1.96x real time. Its "display" releases every
  store within 5,000 cycles, so it cannot see a paced display's behaviour.
- **Accumulated state over hours**: the repro (§10.4) from a seek hits all three at the same PTS.

### 10.3 What the stream does there

The model's output order (`.sim/cosim/p6b7/ak3345.out`, "picture step frame unpaired" per
store) runs at a steady reorder delay of 3 / 5 pictures, until stores 223 and 224 are
emitted at steps 225 / 226 and the next store (225) only at step **229**: three pictures
decoded in a row with nothing emitted. The decode order there is "... B P B P P I B ..."
(ffprobe `pict_type`); `repeat_pict` alternates 0 / 1 throughout (the 3:2 cadence). The
same "P P I" shape appears elsewhere in the window without an event, so it is necessary
at most, not sufficient. P5g saw two unexplained re-anchors on Family Guy at stream edit
points (§9's P5g row): possibly the same defect.

**Working hypothesis:** the durations or times the display gives the pictures around
there are wrong: a picture timing SEI (`pic_struct`) or a PTS tag attached to the wrong
store (`sei_pt` / `au_pts` / `recon_hdr` -> `recon_top`'s picture info -> `recon_out`'s
per-store table), or the scheduler's timeline mis-stepping on such a record. Three pictures
held twice their duration, then a tagged head behind the timeline, fit "durations too long".

### 10.4 How to reproduce

The rig (the `hil-testing` skill; ask the other sessions first, `restore` after):

```bash
tools/mister.py deploy --rbf releases/<build>.rbf --agent --main main/.build/MiSTer_UMD_hil
tools/mister.py launch "/media/fat/cifs/games/DVD/umd/Akira (PSP Video).iso"
S="wait 8"; for tgt in 3322 3860 6730; do hi=$(( tgt*90000/65536 ))
  S="$S; mark ff$tgt; key right; wait 0.3; key right; wait 0.3; key right; until sh_pts_hi >= $hi 150; key left; mark play$tgt; wait 45"; done
tools/mister.py seq "$S" --out .sim/rig/repro_akira.jsonl      # ~5 min; then read the samples
```

(FF 3 to ~30 s before each point, play through it.) Read `pickups`, `pics`, `stc`,
`recon_err`, `aud_rearm` and `sh_pts_*` per sample around each point. `sched`[15:8]
(re-anchors) saturates at 255 after trick play: judge re-anchors by the STC step. The
first run's logs: `.sim/rig/film_akira_163244.jsonl`, `.sim/rig/repro_akira.jsonl`
(workstation only, gitignored).

Offline:

```bash
# the decoder over the first point (bit-exact; the .out file is the output order)
python3 tools/cosim_golden.py --disc "$UMD_ISO_DIR/Akira (PSP Video).iso" --out .sim/cosim/p6b7/ak3345 \
    --frames 420 --at 0.4448 --ep-start --packs 30000        # ~10 min; window 3,343.96-3,361.5 s
.sim/cosim/obj/cosim .sim/cosim/p6b7/ak3345 +label=ak3345     # ~15 min
# an ES cut for ffprobe (psmf_ref: every video PES whose PTS lies in [lo, hi) s)
python3 -c "import sys; sys.path.insert(0,'tools'); import psmf_ref
src=psmf_ref.Source('$UMD_ISO_DIR/Akira (PSP Video).iso',1); r=psmf_ref.parse(src.mm,src.start,src.end)
out=bytearray(); on=False
for p in r.packets:
    if p.kind!='video': continue
    if p.pts is not None: on = 3330*90000 <= p.pts < 3360*90000
    if on: out+=src.mm[p.payload_off:p.payload_off+p.payload_len]
open('e1.264','wb').write(out)"
ffprobe -f h264 -show_frames -of json e1.264
```

### 10.5 The plan (steps 1, 3, 4, 5 done; 2 dropped; 6 at merge)

1. ✅ (2026-09-29: the model re-anchors there too, §10.6) **The records the display should get.** From the model, for this window: each emitted
   store in output order with its PTS (the P5c position rule, `au_pts`), its pic_struct
   (the picture timing SEI of ITS picture) and nuit / ts. Feed them to
   `disp_sched_ref.simulate(recs)` (`W()`, the rules in its docstring). If the model
   re-anchors at 3,352.7 s, the stream's own timing is inconsistent there and the anchor
   rule is what needs a decision. If it does not, the RTL gives the display something else.
2. ❌ dropped: step 1 reproduced the rig's sequence from the stream's own records, so the
   RTL's records were not suspect. **The records the RTL gives.** Run `recon_top` + `recon_out` on the window (the cosim
   harness, or `run_recon_out.sh`'s bench) and dump each record's PTS / tag / pic_struct.
   Compare with step 1. Suspects, in order: `recon_hdr`'s parse of `F_au_pts_*` and the
   SEI words into `pinfo` (no bench below the rig: `transport.md` §9's P6b3i limitation),
   `recon_top`'s picture info per store, `recon_out`'s table halves (the record takes the
   tag of the half that carries the PTS).
3. ✅ (§10.7) **The fix**, plus a disc-record scenario in `run_disp_sched.sh` (today every scenario
   is synthetic, which is why no bench saw this), with a RED arm that re-creates it.
4. ✅ `disp_ctl` + `disp_sched` +21 LUTs / +8 registers in `tools/synth_unit.sh` (~15 ALM).
   **Area:** 55 ALM remain under 35K (`UMD_p6b7b_20260929_1758.rbf`, 34,945).
5. **Refit**, the repro on the rig (§10.4), then **the whole-film gate again**:
   `UMD_ISO_DIR=... tools/rig_gates.py film "Akira (PSP Video).iso"` (detached, ~2 h 10 min;
   score with `--score`). Announce the block to the other sessions and let short slots go
   first.
6. The H264 fork shares the display path: tell its session when fixed (`harvest.md`).

### 10.6 The cause: a lone PES PTS (2026-09-29)

**The stream, not the RTL.** The window's records (`au_pts`'s position rule, each
picture's `pic_struct`, the cosim's output order) fed to `disp_sched_ref.simulate` re-anchor
once, at 3,352.53 s. Picture 201 of the cosim window (a B, POC 15; decode order
"... P B P ..." at an lsb wrap) carries PES PTS **3,351.9810** (DTS 3,351.8975), but the
timeline from the previous tag (3,351.3970, 11 stores and 28 ticks earlier) puts it at
3,351.8642: **+7 ticks (117 ms)**. The next tag (3,352.5315, 16 stores on) sits exactly on the
OLD timeline. The SEI's HRD timing agrees with the timeline, not the PES: from the
buffering-period picture, `cpb_removal_delay` 33 + `dpb_output_delay` 0 against 0 + 5 gives
28 ticks, the pic_struct sum. So one PES time stamp is wrong. The display believed it: it
waited 7 ticks for that picture (the one before held ~3x its duration, `pickups` 3 of 6,
the decoder's D_OPEN wait passing STALL_LIMIT: code 6). The return tag then read as "more
than a frame behind the timeline", and the STC was re-anchored back (the ~83 ms step, audio
re-armed). The scheduler did what its rules said.

**The census** (`tools/umd_pts_census.py`, header-only, ~1 min a film; every image's main
title): **88 images, 14.15 M stores, 1.14 M tagged; 73 images carry 208 lone PTS**, each a
single tag off the timeline with the next tag (<= 21 stores on) back on it. Shifts (a
real change of timeline): none (one -0.4-tick step in Wanted, under any threshold).
- Akira: exactly three, **+7 / +8 / +8 ticks at 3,351.98 / 3,888.32 / 6,758.10 s**: the rig's
  three points.
- Family Guy: two, +5 ticks at **521.10 and 747.06 s**: P5g's two unexplained re-anchors
  (§9's P5g row) were this too. The other five edit points there are not lone PTS.
- Sizes (ticks of the VUI's tick): +1 x38, +2 x2 (23.976, i.e. exactly one frame), +3 x3,
  +4 x1, +5 x42, +6 x12, +7 x46, +8 x62; behind: **-3 x1 (The Simpsons Movie, 2,324.90 s,
  pairs), -2 x1 (The Transporter, 100.47 s, 23.976)**. So 206 of 208 are late (ahead).
- The closest two on one disc are 358 stores apart (~15 s; tags come every ~12): the
  "next tag is believed" memory of one tag is enough.

**Rejected alternatives.** Cross-checking each PES PTS against the SEI's HRD times (right in
principle) needs the cpb / dpb delays and the buffering-period anchor carried per store to
the display: area this branch does not have (55 ALM). Disbelieving both directions
(the maintainer's option B) would also cover the two behind, but a real small backward
edit would then be corrected one tag late, with the video up to 0.5 s ahead of the audio
meanwhile. The maintainer chose forward only (A), 2026-09-29.

### 10.7 The fix (RTL, model, bench; 2026-09-29)

- **The rule** (§7): `disp_sched.sv` gains one pipeline stage (`ev[1]`, `lone_pts`). A
  tagged head with `HALF_SCAN < d_pic_next <= FWD_MAX_TICKS`, not past LATE_MAX, while
  anchored and `!susp`, is disbelieved: `tag_e` = 0 and `want` = `next_pts`. The anchor,
  the due and `contig` use `tag_e`. `susp` is set by a pickup of a disbelieved head,
  cleared by a pickup of a believed tagged one, and by the reset or a resync.
  `disp_sched_ref.py` has the same rule in "THE RULES" (the model is the spec).
- **The edge was measured, not assumed.** A first draft used one frame. The census has
  38 lone PTS at +1 tick (believed: one refresh held too long, then a return inside a
  frame) and two at exactly +1 frame on 23.976 (believed; their returns, a frame and
  half a tick of 90 kHz behind, re-anchor). Half a refresh (8 ms) is far above time-stamp rounding (<= 1
  tick of 90 kHz; `prog24r` rounds up and reads 0 lone).
- **Instrument:** `n_lone` (4 bits, saturating) in `disp_ctl`, telemetry `sched`[3:0]
  (`telem_layout.py`, `umd_telem.sv` port `t_lone`; Main unchanged).
- **Bench** (`run_disp_sched.sh`): `lone7` (3:2 frames: +7 as at Akira 3,352 s, +600 ticks
  believed, +8, +1 tick), `lonefld` (pairs, +5 as Astro Boy's), `lone2` (a real +7-tick gap:
  the first tag disbelieved, the next believed). `gap03` now waits its 0.3 s one tag later
  (lone 1). Under the old rule `lone7` re-anchors 3 times and `lonefld` twice. RED D30-D36
  (the rule off, the next tag disbelieved, the flag never cleared, the edge at a frame,
  no upper edge, `want` not corrected, the counter dead). D2 / D4's anchors are now
  unique: the compares appear twice.
- **Area:** `disp_ctl` + `disp_sched` 1,704 -> 1,725 LUTs, 1,366 -> 1,374 registers
  (`synth_unit.sh`).
- **Fit** `UMD_filmtime_20260930_0009.rbf` (SEED 9 first roll, clk_dec 87.05 / 86.31, 34,949
  ALM: +4, 51 under 35K; M10K 419). `run_av_sync.sh` S1-S12 green.
- ✅ **The repro on the rig** (2026-09-29, .201 -- the second MiSTer, lent by the maintainer
  since the gate needs no HDMI capture; §10.4's sequence; `.sim/rig/repro_akira_fix.jsonl`):
  at each of the three points `lone` +1 and nothing else -- no STC step, `recon_err` 0 (no
  code 6), `aud_rearm` unchanged, `late` / `starve` / `cadence` 0. The old build's log,
  scored the same way, shows at each point a 0.15-0.17 s STC advance in a 0.25 s sample, a
  code 6 and an audio re-arm. `rig_gates.py`'s film scorer now reports the lone count.
- ✅ **The whole-film gate PASSES** (2026-09-29, .201, `rig_gates.py film "Akira (PSP
  Video).iso"`, 7,735 s at 4 Hz, a pause and a chapter jump in the first two minutes;
  `.sim/rig/film_akira_225021.jsonl`). Reconstruction and front-end errors 0 throughout,
  watchdogs 0. `av_err` 0 .. 2 ticks (+0.02 ms) over 30,877 samples; the failing run read
  -100 ms. END taken, the last picture 2:05:16. `lone` 0 -> 3 at shown PTS 3,351.9 /
  3,888.2 / 6,758.1 s. Re-anchors: the start and the chapter jump only. The STC runs
  true in every sample but the pause's frozen ones and the jump's. **The Phase 6 gate
  holds.**

### 10.8 Known limitations

- ~~A lone PTS behind the timeline still re-anchors~~ (The Simpsons Movie 2,324.90 s, The
  Transporter 100.47 s): **removed by rule B** (§10.9).
- **A real jump of 8 ms to 0.5 s, either way,** is followed one tag (~0.5 s) late, the
  video off the audio by the jump meanwhile. None in the census.
- **`STALL_LIMIT` (~122 ms at 90 MHz) is below `FWD_MAX` (0.5 s):** a legitimately
  waited-out gap still counts `err_no_store` (code 6) while the decoder waits on the
  display. It is an instrument issue that predates this fix, and no disc has such a gap.
  Not changed here.
- The flag's clear by a resync is not armed by a mutation (no scenario has a lone tag
  just before a seek).

### 10.9 Rule B: lone EARLY PTS too (`fix/lone-early`, PR fj#26, the maintainer 2026-09-29)

The maintainer chose to disbelieve a lone tag BEHIND the timeline as well: the band is
symmetric, `HALF_SCAN < |d_pic_next| <= FWD_MAX_TICKS` (`disp_sched.sv`, `disp_sched_ref.py`).
It covers the census's two:
- **The Simpsons Movie, 2,324.90 s (pairs, -3 ticks):** rule A re-anchored the STC 50 ms
  back and re-armed the audio, then waited 3 ticks at the next tag.
- **The Transporter, 100.47 s (23.976, one frame + half a tick early):** rule A did NOT
  re-anchor. The display's timeline carries whole 90 kHz ticks for untagged pictures (`want`
  = `next_pts`, the Q3 fraction dropped: -0.75 tick a 23.976 frame, ~9 ticks a GOP, each tag
  resetting it), so the tag reads -3,746, inside a frame. It was shown a frame early and its
  return (then ahead) disbelieved and waited for one tag later. The truncation is ~0.1 ms a
  GOP, far under a refresh: harmless, noted.

A real backward jump under 0.5 s is now followed one tag late instead of at once (`back200`,
`backfld`: lone 1, the same re-anchor one tag later); past 0.5 s it re-anchors at once
(`back1s`, new). Bench: `loneearly` (The Transporter's shape), `loneearlyfld` (The Simpsons
Movie's), `back1s`; RED D37 (the behind leg removed), D38 (the behind band unbounded); D33 /
D34's anchors moved with the expression.

- **Fit:** `UMD_loneearly_20260930_0446.rbf` (SEED 9 first roll, clk_dec 87.29 / 87.86, 34,961
  ALM: +12, 39 under 35K; M10K 419). `run_disp_sched.sh --red` (31 scenarios, 38 mutations) and
  `run_av_sync.sh` green.
- ✅ **HW-CONFIRMED** (2026-09-30, .201; `.sim/rig/lone_simpsons.jsonl`,
  `lone_transporter.jsonl`). The Simpsons Movie, 2,312-2,362 s: `lone` +1 at shown PTS
  2,325.09, no STC step, `aud_rearm` unchanged, errors 0. Rule A re-anchored there. The
  Transporter, 0-137 s: `lone` +1 at 100.56, no re-anchor after the start, no re-arm,
  errors 0. `late` / `starve` / `cadence` 0 on both. The discs were copied to the rigs' NAS share
  for this.

The code: `umd/disp_ctl.sv` (the timeline, `want` / `next_pts`, the item rules),
`umd/disp_sched.sv` (due, anchor, FWD_MAX / LATE_MAX, `head_frame_t`), `umd/recon_out.sv`
(the records), `umd/h264/recon_hdr.sv`, `umd/h264/sei_pt.sv`, `umd/h264/au_pts.sv`;
`tools/disp_sched_ref.py`, `tools/dpb_output_ref.py`, `tools/h264_recon_ref.py`.

## 11. A skip target inside the title's LAST picture (found 2026-10-03, P6c; ✅ MERGED PR fj#44, ✅ HW-CONFIRMED)

**Found on the rig** (`UMD_goto_20261003_2340.rbf`, Akira, the 480i layout): a Go To past the
title's end seeked the last item's OUT - 1 (P6b4's clamp). The skip dropped the last picture as
well, so it never ended; `ev_end` (`... && !skipping`) never took END; the pre-seek picture stayed
up, frozen; and no TITLE_END was posted. A jump to 2 s before the end landed, played out and ended
normally. P6c worked around it in `player_ctl`: a TIME clamped to the end lands without the skip
(`p6c.md` §10).

**The cause is the clamp, not `disp_ctl`.** Read off the disc (`.MPS` from the last EP entry,
`h264_fe_ref` for the headers): Akira's last GOP is 28 P frames, pic_struct 6 3 5 4, and the PES
carries a PTS on pictures 0 (676,392,627) and 14 (676,445,179) only. Picture 14's exact time is
676,445,179.5, and the PES PTS is its floor. The display extrapolates every untagged picture from
the last tag (`x_q3`, eighth-ticks), so it puts the last picture at [676,494,728.5, 676,497,731.5).
ffprobe rounds the same time to 676,494,729. OUT is 676,497,732, which is the true end. The target
OUT - 1 = 676,497,731 lies 0.5 tick before the estimated end. The skip drops a record that ends
less than one tick past its target (`d_skip < 8`: the tolerance that lets a chapter mark at a
picture's stored whole-tick PTS skip the picture before it). So `disp_ctl` dropped the last
picture exactly as its rule says. The tolerance and a target one tick below OUT are incompatible
whenever the last picture is untagged.

**The fix** (two parts in the reader and the display, two more in `player_ctl` that the rig found, below):

1. **The clamp is OUT - 4** (`umd_nav_ref.Title.clamp` derives it in its docstring; the reader's
   `END_GUARD`, `player_ctl`'s copy for its TIME rule). The target must sit more than 3 ticks
   below OUT: 1 tick for the skip's tolerance, under 1 for the floor of the tag that an untagged
   picture is extrapolated from, and under 1 for OUT's own rounding. OUT - 3 is exactly at that
   bound; OUT - 4 leaves a tick of margin. A picture lasts at least a field (1,501 ticks), so
   OUT - 4 always lies inside the last picture. An item shorter than 4 ticks clamps to IN.
2. **An END reached inside a skip ends the display** (`disp_ctl`'s `skip_eos`, the model's
   `judge`). END is taken, `ended` rises, and the picture on screen stays up. This guarantees
   liveness. OUT is a playlist field and nothing in the format bounds it by the stream's content,
   so an OUT far past a title's last picture would put any clamped target past every picture.
   Without this rule that is the same freeze.

**Benched:** `run_disp_sched.sh` scenario `seekend` [S5] uses Akira's last-GOP shape. At OUT - 4
the last picture is shown and END is taken. At OUT - 1 (`seekend1`) every picture is skipped, and
the END inside the skip ends the display with the old picture kept. The bench now scores `ended`
at the end of every scenario. D43 (the END inside a skip not taken) is caught by `seekend1`.
`test_umd_nav_ref.py` feeds the model's clamp into `disp_sched_ref.simulate` on the same shape.
The reader's N27 (END_GUARD 1) and N33 (a clamp to OUT itself), player_ctl's G10 (its END_GUARD not
the reader's) and `red_umd.py`'s END_GUARD 1 arm are its mutations.

**The library (2026-10-04, all 120 items of the 88 images).** For each item, OUT minus the display's
estimate of the end of the last picture that starts before OUT. That estimate is the PES PTS when the
picture is tagged, else extrapolated from the last tag as `disp_ctl` does it (`umd_pts_census.stores`,
header-only, output order). Results, in ticks:

| OUT - estimated end | items | at OUT - 1 | at OUT - 4 |
|---|---|---|---|
| 0 | 89 | kept | kept |
| +0.5 (22: Akira, Cowboy Bebop The Movie, Independence Day, Matrix Reloaded, Spider-Man, ...) / +0.75 (X-Men) | 23 | **last picture lost** | kept |
| -0.25 / -3.5 / -1501.5 / -3753.5 (OUT inside the last picture or earlier; Hackers' OUT is mid-clip) | 5 | kept | kept |
| **+750.75 (Wanted), +180,180.5 (A Few Good Men, 2.0 s), +270,270 (National Treasure, 3.0 s)** | 3 | everything skipped | **everything skipped** |

The clamp alone fixes 23 items. The last three have OUT past the content, so any target near OUT lies
past every picture, and only the END rule (part 2) keeps them live. A Few Good Men's and National
Treasure's OUT also lie past their clip's end PTS in the CLPI, by exactly that gap. Wanted's does not:
its clip end equals OUT. Bounding the clamp by `min(OUT, clip end)` would therefore rescue the last
picture on two of the three. It is **not built**: a seek to the end there is only reachable by Go To,
which lands without the skip and plays the last GOP out. P6c's no-skip rule compares `nav_skip`
against OUT - 4 and would have to follow the new bound. The END rule already guarantees the title
ends. If a menu's or a chapter's seek to such an end is ever seen showing the old picture, that bound
is the next step.

*(Measured with a scratch script over `umd_nav_ref.from_iso` + `umd_pts_census.stores`; its result is
this table.)*

**The rig (2026-10-04, `UMD_skipend_20261004_1859.rbf`, A Few Good Men, a Go To to 02:18:00 of
02:18:01: past its content, with the skip) found the third part.** The display ended (`ended` 1),
but `player_ctl` was still waiting for the landing's picture: its 3 s watchdog fired (`wd` 1) and no
TITLE_END was posted. The pre-seek picture stayed up and the player stayed in PLAY. Its TITLE_END rule
took `ended`'s rising edge only while no seek was in flight, and this END rose during one. (Before the
display rule, the watchdog's no-skip rewrite let END come later, on an edge. The display rule alone
traded the freeze for a missing title end.) Fixed in `player_ctl`:

3. **A landing completes on `ended`** as well as on a picture: SEEK_DONE, no watchdog, `land_pts`
   held (no picture was shown). Not for a hop (`one_frame`), whose entries take no skip.
4. **TITLE_END is posted once per END, when the seek machine is at rest.** It is a flag that the
   resync clears with `ended`, no longer an edge, so an END that came during a seek is posted when the
   seek is done.

`run_player_ctl.sh` gains script code 106 (ENDSKIP: the mock display ends the next landing with no
picture; one per script at the last item's end, others at random) and the [tend] arm: one TITLE_END
per such landing, and [wd] already requires that no watchdog fires. RED G11 (the landing waits for the
watchdog) and G12 (the edge-only TITLE_END). The new script timings also exposed two latent bench
races, both fixed in the bench. A walk's item start in the cycle of trick play's exit seek carries the
hop's no-skip, so [land] now judges an entry by the `one_frame` it was computed with. The SUB /
SUB_SET acceptance was judged against the title's track mask, not the reader's partial mask during a
CLP read.

**✅ On the rig (2026-10-04, `UMD_skipend_20261004_2035.rbf`, A Few Good Men, the same Go To to 02:18:00):**
with Disc Menus Off, within 1 s the display `ended`, the watchdog 0 and the seek done, errors 0. With Disc
Menus On (the feature from the disc's Play Movie): the TITLE_END reached the UMD Main
(`CALLBACK movieplayer.onPlayListEnd`, `controller.end() -> true (the disc's menu)`) and the disc's main
menu came back, the PSP's behaviour at a title's end (D16). The control was the previous fit
(`UMD_skipend_20261004_1859.rbf`, display rule only): the display ended, but the watchdog fired, there was
no TITLE_END, and the picture stayed frozen in PLAY.

**P6c's workaround stays, as a UX choice.** A TIME past the end still lands without the skip,
so the last GOP (up to ~2 s) plays out before the title ends, rather than showing the last
picture alone. A plain SEEK to the end (a chapter mark at or past OUT, a menu's play past OUT)
takes the skip and now shows the last picture.


## 12. Chroma interpolated (`feature/chroma-interp`, 2026-10-12; the H264 core's "chroma at the identity", ported) -- ✅ MERGED (PR #2), ✅ HW-CONFIRMED (.201)

**Why.** The reader showed 4:2:0 chroma NEAREST: each chroma sample repeated over its 2 x 2 luma
block. Beside saturated detail (red above all: the largest chroma excursion at a low luma, which
luma cannot mask) the colour error lands in one hard stripe one or two pixels wide, and the HDMI
scaler (720 -> 1920 is 2.67x) widens it into bands. The H264 core measured exactly this on its rig
in Native (its `display.md` §3 "Chroma at the identity", history §43: the raster matched a nearest
model on 99.99 % of a red test pattern, an interpolating player's on 77 %, up to 108 codes apart)
and fixed it the same way; nearest had come to it with the display from UMD (its notes say "UMD /
DVD": not so -- UMD's reader grew from its own P4 smoke display and never took MiSTer_DVD's output
stage, whose `resample_bilinear` has always interpolated both ways, per field on interlaced pictures,
its row choice fixed in MiSTer_DVD PR #142), never weighed as a quality choice. DVD's design is also
the reference for the limitation below: within-field vertical chroma there costs a two-row chroma
cache per plane. Asked by the maintainer 2026-10-12 ("go straight to the horizontal +
frame-vertical step"); not measured on UMD's rig before the change.

**The siting is H.264's default, type 0, fixed -- measured, not assumed.** Every one of the
library's 691 clips (head SPS, ffmpeg `trace_headers`, 2026-10-12) has a VUI with
`chroma_loc_info_present_flag` 0: E.2.1's inferred `chroma_sample_loc_type` 0. Chroma is
co-sited with even luma columns and centred between luma rows 2m and 2m + 1. A stream declaring
another siting would show a half-sample colour offset -- what every stream showed under nearest,
never garbage; it is the row in `spec_hardening.md` "Known deviations". The H264 core's full
version (its `chroma.md`: the siting from the SPS, eight chroma slots, bilinear at every scale,
+~900 ALM, +8 M10K, ~3 DSP) is not taken: no UMD disc needs the siting, every UMD picture is shown
1:1, and the device is at 95 % ALM.

**What changed, per path:**

| path | horizontal | vertical |
|---|---|---|
| 480p, a frame store | interpolated | interpolated: row 2m `(3 h[m] + h[m - 1] + 2) >> 2`, row 2m + 1 `(3 h[m] + h[m + 1] + 2) >> 2` |
| 480p, a field store (every deinterlace mode, the film weave / bob, the matched partner) | interpolated (rows a, b, d; the kernels run on them) | nearest within the field (rows a / d are the other field's: using them is P5a's chroma bleed) |
| 480i Fit / Letterbox | interpolated (rows b, d) | nearest (the frame's rows, or the field's own) |
| 480i Crop, the video window (both rasters) | unchanged: their own fractional taps on nearest chroma | unchanged |

Horizontally an odd column x is `(c[x >> 1] + c[(x + 1) >> 1] + 1) >> 1`, the picture's last
column replicated. Two roundings (horizontal, then vertical), as the H264 core: within one code of
ffmpeg's single-rounding upsample.

**How, at no RAM, no multiplier, LAT 4 unchanged:**

- **Rows b / d** already deliver chroma samples c0 and c0 + 1 in one read: Crop's even / odd
  halves (S2). Crop's horizontal blend `DR_HB` at weight 8 sixteenths is `(a + b + 1) >> 1`
  exactly, so the macro gains a weight argument and chroma its own (`s1_fc`: 8 on an odd column
  where interpolated, else the Crop / window weight as before). The right edge: no blend on the
  picture's last column (`ch_x`), whose c0 + 1 lies past the fetched row.
- **Row a** (the 480p kernels' line above) is a whole-word copy with one address: it reads the
  sample AHEAD, `(x + 1) >> 1` clamped to the picture's last chroma sample, and takes the previous
  dot's read as the left neighbour (480p: one dot a clock, and a line's first column is even, so
  no dot needs a neighbour from before the line). At 27 MHz the adder in front of the address is
  no timing matter (the H264 core's was, at 86).
  **Invariant relied on:** one raster dot a clock -- `emu` ties `sync_gen`'s `clk_en` to 1 (and
  `disp_reader_tb` does the same). A pixel enable there would need `p_ua` / `p_va` updated on it.
- **The vertical neighbour** of a frame store's line 2m is row a's chroma, of 2m + 1 row d's --
  both in the ring of four. The chroma d copy reads row a's slot on an even line (`bk_dc`): a
  frame store's kernel is b in every mode, so nothing else reads that copy there. The edges'
  mirror (line 0's a is line 1, the last line's d the line above) makes the neighbour row m
  itself, as the golden's edge rule states; a 720x576 picture's clipped line 479 takes the real
  row 240 (its d is the real line 480).

**Verification.** `tools/disp_golden.py`: `hup` / `up_h` / `up_ident` from the formulas above (not
the RTL); the frame's `up_ident` checked against ffmpeg's own 4:2:0 -> 4:4:4 upsampling at the
default siting (`scale=in_chroma_loc=left:flags=bilinear+full_chroma_int+accurate_rnd`, the
H264 core's impulse-validated oracle) within one code, and asserted NOT within one code of
nearest (an oracle that cannot tell them apart checks nothing). Field stores: each field's chroma
`up_h` after ffmpeg's `separatefields`, as before. New wants: `disp_want_frame_il.hex` (the 480i
frame arms), `disp_rgb_il.hex` (`plane_tb +il`'s video layer, `plane_golden.py`'s
`plane_s*_rgb_il.hex`). `run_disp_reader.sh` GREEN (53 arms), `--red` Z1-Z11 (the column parity,
row a's rounding / clamp / left tap, the vertical rows swapped, the vertical step on a field store,
the right edge, nearest, 480i, Crop and the window kept out).

**On the rig (.201, 2026-10-12, `UMD_chroma_20261012_0529.rbf`, the maintainer's go-ahead).** Six paused
pictures in Progressive / Weave, each the raw 720x480 raster against ffmpeg's decode of the same picture
(`tools/chroma_shot_check.py`: the clip and window from telemetry's `sh_pts`, the picture picked by each
field's luma, so the choice does not depend on the chroma model), rendered with this section's rules and with
the old nearest rule; the pause glyph's box (rows 436-460, columns 12-32) excluded:

| shot | store | interpolated: pixels differing | nearest: pixels differing (max) |
|---|---|---|---|
| Akira 398.6 s | frame | **0** of 345,075 | 72,701 (37) |
| Akira 423.7 s | frame | **0** | 96,732 (35) |
| Akira 448.7 s | frame | **0** | 109,701 (61) |
| Family Guy 61.6 s | field pair | **0** | 50,299 (67) |
| Family Guy 86.7 s | field pair | **0** | 65,978 (42) |
| Family Guy 111.7 s | field pair | **0** | 54,044 (56) |

Silicon equals the golden bit for bit on both store kinds -- including row a's previous-dot tap, which the
bench's tied `clk_en` could not prove; decode errors 0 throughout. (The first shots came back 720x405: .201's
`video_mode=2` is a 720x480 HDMI output, so ascal shrinks a 16:9 picture on its input side; a temporary
`video_mode=0` in the `[UMD]` section gave the raw raster -- `hil_harness.md` "Facts that bite".) Not looked
at: 480i on a CRT (horizontal only there; the benches' `[il]` / `[lb]` arms cover it).

**Known limitations.** Field stores stay nearest vertically (the ring holds the other field's
lines: within-field interpolation needs rows y +- 2, i.e. the H264 core's chroma slots); at 480i
a frame's rows stay nearest too (the walker's ring is by field line, row s - 1 is not kept). Crop
and the menu window keep nearest chroma under their own taps. A declared siting other than type 0
is not honoured (none in the library).

## 13. A field store's vertical chroma step (`feature/chroma-field`, 2026-10-12) -- ✅ MERGED (PR #3), ✅ HW-CONFIRMED (.201)

**Why.** §12 left a field store's chroma nearest vertically: its rows a / d are the other field's. Each
field's chroma row covers two of that field's lines, so in the woven picture a colour edge steps every
four frame lines, and the two fields step at different lines: along a horizontal colour edge the woven
picture alternates field by field, a fine comb in the colour alone, even on a still film frame (measured
on three Family Guy pictures from the rig, 2026-10-12: the step changes 15-22 % of the pixels, mean
0.8-1.3 codes, up to 31-38 -- about the size of §12's horizontal fix, its peaks smaller). The maintainer
asked for it after seeing the comparison crops ("start working on the vertical blend").

**Where a field's chroma sits: H.264 Figure E-1, not the field's centre.** For `chroma_sample_loc_type`
0 the top field's chroma row m lies between frame lines 4m and 4m + 1 (frame position 4m + 1/2) and the
bottom field's between 4m + 2 and 4m + 3 (4m + 5/2): together the progressive positions, MPEG-2's
interlaced 4:2:0 siting. In each field's own lines that is a QUARTER of the way from field line 2m to
2m + 1 (top) and THREE QUARTERS (bottom), not the half the frame rule uses. So a field line takes its
own row m and the row on its far side (an even field line 2m: row m - 1; an odd one: m + 1):

| field line | top field (p 0) | bottom field (p 1) |
|---|---|---|
| 2m | 7/8 row m + 1/8 row m - 1 | 5/8 row m + 3/8 row m - 1 |
| 2m + 1 | 5/8 row m + 3/8 row m + 1 | 7/8 row m + 1/8 row m + 1 |

i.e. the line nearer its row (field line parity = field parity; frame line y: `y[1] == y[0]`)
`(7 own + n + 4) >> 3`, the other `(5 own + 3 n + 4) >> 3`, after §12's horizontal step (two
roundings); the field's first / last chroma row replicated (n = own). ffmpeg agrees: libswscale's
`format.c` ("Fix vertical chroma position for interlaced frames") halves the vertical position for a
field and shifts the bottom field by a luma row -- 64 / 192 of 256 -- and the golden is checked against
its `scale=interl=1` within one code. **The H264 core's field rule (its `chroma.md` §2: "the field's
siting" applied in the field's coordinates, i.e. centred, 3/4 + 1/4) is off by an eighth on every field
line**: `harvest.md`, to port back.

**Where it applies:** a field store at 480p shown as stored -- Weave, and the film weave / matched pair
of fj#80 (each line's own store's field). Not under Bob (its kept lines included) or Blend, whose kernels
keep §12's rows; not at 480i, not in the window, not under Crop. Frames keep §12's step.

**How.** A field line's far-side row belongs to the field line two frame lines away -- a line the ring
of four has already overwritten (y - 2) or is still fetching (y + 2). So the 480p fetch of a field
store's line brings that row with it (`req_nb`): after the line's Y, Cb, Cr the set-up runs a second
time with the neighbour row (`f_nbp`; the store row is the line's own +- 2, or the same at the field's
edges: no second multiplier) and fetches its Cb / Cr as planes 3 / 4 into four neighbour RAMs beside
the slot (even / odd halves at row b's addresses, so §12's horizontal step applies to them through the
same `DR_HB`). The read-out selects `(7 b + n + 4) >> 3` / `(5 b + 3 n + 4) >> 3` (`s1_cf`, `s1_cfn`).
Cost: +4 M10K; a field title's 480p line reads 2W words more on ram2 (90 of 180: the display's reads
+50 % on field titles only); LAT unchanged.

**Verification.** `tools/disp_golden.py` `up_fv` (from the table above, not the RTL); `check_field_oracle`:
ffmpeg's interlaced upsampling within one code, and asserted NOT within one code of the field-centred
rule nor of the rows nearest. New wants: `disp_want_field` (Weave), `disp_want_s_field` (a 480x272 pair:
the field's last row inside the raster), `disp_want_field_il` (480i), the matched pairs. `run_disp_reader.sh`
GREEN; `--red` V1-V8 (the direction, Bob's kept lines, both replicates, the other field's row, the
weights' sides, the rounding, the fetch dropped).

**On the rig (.201, 2026-10-12, `UMD_chromafld_20261012_1940.rbf`; the same procedure as §12: Progressive /
Weave, paused, the raw raster, `tools/chroma_shot_check.py` now scoring every rule the reader has had):**

| shot | store | §13 field step | §12 along the line (the previous build) | nearest |
|---|---|---|---|---|
| Family Guy 64.0 s | field pair | **0** of 345,075 | 30,580 (max 43) | 58,508 (62) |
| Family Guy 89.0 s | field pair | **0** | 63,531 (45) | 98,810 (63) |
| Family Guy 114.0 s | field pair | **0** | 45,793 (41) | 69,772 (60) |
| Akira 273.9 s (the control) | frame | §12 both ways: **0** | -- | 34,769 (32) |

Pixels differing outside the pause glyph's box. The tool's control the other way: the previous build's shot
(§12's table) matches §12's rule and differs from §13's on 46,161 pixels. Decode errors 0; ram2's longest
BUSY run (`d2_busy_max`) 49 on Family Guy and on Akira alike -- the neighbour fetch shows no occupancy cost.

**Known limitations.** Bob and Blend keep the rows nearest within the field (their kernels mix the
fields' lines; giving each kernel line its own vertical step needs a neighbour per window line). 480i
(the walker's ring) and the window keep §12's rules.
