# Fabric budget, memory ports, and the verification rules a failed feature earned

**Inherited from MiSTer_DVD** (its `docs/hw_budget_and_lessons.md`, written 2026-09-21
after an abandoned deinterlacer). §1 is this core's own budget plan. §2, §4, §5, §6 and §7
are that note's generic sections, reproduced with only path edits: every measurement in
them is about THAT core's netlist on the same device, and every rule in them is general.
Read §2 before designing anything that touches DDR3, and §4 before trusting any gate that
says a feature works.

---

## 1. This core's budget plan

Device: Cyclone V 5CSEBA6U23I7 — **41,910 ALM, 553 M10K, 112 DSP**. MiSTer_DVD ships at
~88-93 % ALM; that is the regime where every feature becomes a fit-rescue and it is the
regime this core should stay out of.

Estimates (to be replaced by measured checkpoints in `roadmap.md` after each phase):

| block | ALM | notes |
|---|---|---|
| framework (`sys/`: ascal, hps_io, OSD, audio_out) + raster + idle screen | 5-7K | measure at P0 |
| CABAC engine + context model + parser (P3) | 3-5K | contexts and neighbour state in M10K, ~1 bin / 2 cycles |
| serial reconstruction: itrans, intra, 1 px/cycle MC, deblock (P4) | 7-10K | one datapath shared across states |
| ATRAC3plus stereo decoder (P6) | 5-8K | tables in M10K; comparable to MiSTer_DVD's AC-3 after its reclaim |
| reader, demux, ring, A/V sync, HUD (harvested, trimmed) | 3-4K | |
| **total** | **23-34K** | 55-80 % of the device |

⚠ **Measured 2026-09-24:** the P4 reconstruction placed at 24,639 ALM (the core 38,259,
91 %) against the 7-10K estimate above; `roadmap.md` "Resource checkpoints" holds the
re-planned budget, the P4 exit criterion (reconstruction ≤ 12K, core ≤ 26K) and the
contingency the user chose if area cannot be found: the ISO reader moves to the HPS,
A/V decode stays in fabric.

Why the decoder can be this small: 12.4 Msamples/s of 4:2:0 at 23.976 fps against an
81 MHz compute clock (`roadmap.md` "Throughput doctrine"). Published HDTV decoders run
4-16 samples per cycle; this one runs one.

Memory: a Level 3.0 DPB (MaxDpbMbs 8100 → 6 frames of 1350 MBs) plus the current picture
is ~3.6 MB in DDR3; reference-read bandwidth at 720x480 is a small fraction of what the
MPEG-2 core already moves. The binding resource is **port occupancy** (§2), so the DPB
client gets `ram1` and everything else goes to the idle `ram2`.

Timing: `clk_dec` = 81 MHz is the domain the gate watches (`tools/fmax_check.sh`, 86.0 MHz
at both slow corners). Every block designed for clk_dec should be written registered-out
with the suppression terms at the capture register (§5), and the cold corner checked
(`TIMING_TEMP=-40`).

---

## 2. ★★ THE SCARCE RESOURCE IS ARBITRATION OCCUPANCY, NOT BANDWIDTH

Three independent measurements say the same thing, and it is the single most reusable
design rule here.

**(a) Direction matters far more than volume.** A write pump moving ~10 MB/s through
`ddr_arb` cost **nothing detectable** (lates/drops/vbuf unmoved over 10 alternating
windows). A *read* path of the **same byte rate** cost **+65 % lates**. Bandwidth
saturation cannot tell a read from a write; grant occupancy can.

**(b) Halving the traffic cut the cost 8.7×, not 2×.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| every line, on `ram1` | 5.375 | 2.683 | 22.33 |
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |

A linear response would mean a bandwidth budget being consumed. A strongly super-linear
one means a **contention threshold** being crossed.

**(c) The controlled version: same traffic, different port, zero cost.**

| | lates/s | drops/s | content fps |
|---|---|---|---|
| half the lines, on `ram1` | 0.620 | 0.312 | 24.70 |
| **half the lines, on `ram2`** | **0.000** | **0.000** | **25.03** |
| control arm (pump off) | 0.000 | 0.000 | 25.01 |

Nothing about the DDR3 device or the number of bytes changed — only which master had to
wait for a grant. **0 of 6 windows positive.**

### Why a read is so much more expensive than a write

A write is fire-and-forget into the bridge's buffer: the master hands over beats and is
done. A read holds the grant through **command + memory latency + every return beat**,
with the other master held off by `waitrequest` for the whole slot, because responses are
routed by grant and the grant cannot move while beats are outstanding.

### The rule for future features

> **If a new DDR3 master measurably hurts the decoder, do not reach for smaller data
> first. Ask whether it can have its own port.** Subsampling, lower precision and shorter
> bursts all trade a feature's quality against the wrong variable. `ram2` is free and
> costs no quality at all.

⚠ All three ports reach the **same DDR3 device**, so a port move buys **no bandwidth**.
It removes arbitration occupancy. That is a different (and, here, the binding) resource.

---

## 4. ★★★ HOW A FEATURE WITH A FULLY GREEN GATE SHIPPED AS A VISIBLE REGRESSION

Stage B had 42 green arms in `run_deint.sh --red`, 12 mutations each caught by exactly its
own arm in `run_hist_wr.sh --red`, a memory-path A/B, a wiring checker, and an offline
model predicting it would help. It was still a regression on a screen. Every reason below
is general.

### 4.1 The bit-exact model cosim never exercised the feature

`bench/dvd/ (MiSTer_DVD) deint_comb_tb.sv` is the **only** bench that compares the RTL bit-exactly
against `tools/deint_model.py` — the model whose numbers justified building Stage B at
all — over real disc frames. When Stage B's ports were added, that bench tied
`.hist_ok(1'b0)`, the no-history case.

So the feature was validated by: a directed arm (the veto zeroes a weight), a differential
chain arm on synthetic data, and a memory-path bench. **Not once was its output compared
against the model that predicted the benefit.**

> **RULE. When a feature is justified by an offline model, the bit-exact cosim against
> that model MUST exercise the feature. Otherwise the justification is untested, and a
> model/RTL divergence and a wrong model are indistinguishable.**

⚠ This is also why the abandonment is clean rather than frustrating: nobody can currently
say whether Stage B failed because the RTL diverged from the model, or because the model
measured the wrong thing. Closing that gap is the first step for anyone who revisits it.

### 4.2 A bench can PASS vacuously on X — and `!=` is how

`deint_chain_tb` was given four new ports and they were left unconnected. Icarus floats
those Z; `hist_ok` Z made a predicate X, which made the dilated weight X, and because
`mix8`'s multiply propagates X through a *zero* weight, the pass-through anchor lines went
X too — **~1552 of every scan's 4096 pixels, 37 % of everything the bench emitted**.

Every one of those pixels **passed every arm**, because scoring used `!=` and
`x != 169` evaluates to `x`, which `if` treats as false. The bench printed
`RESULT: PASS` with 12,028 X pixels in it, for several commits.

> **RULE. Score benches with `!==`, never `!=`.** It is the only thing that makes this
> class self-reporting rather than silent. Reach for it immediately when a bench reports a
> count of 0 for something that cannot be 0, or is green on RTL you know is incomplete.

⚠ And the general form of the trap: **adding a port to a shared module silently poisons
every bench that instantiates it without the port.** After adding one, grep the benches
and tie it off in the same commit. This happened *twice* in one week here, the second time
in the very bench written to gate the new port.

### 4.3 A fixture chosen to make an arm decisive can make it unrepresentative

The chain arm scored a *static* region against a *moving* region within one scan — a
differential design, deliberately immune to a detector that simply stopped firing. Good
design. But the "moving" region moved by a fixed **24 code values** per picture, well
above the threshold of 8, because that is what made the arm unambiguous.

Real content moving slowly changes by **less** than the threshold while still combing.
The arm could not have failed for the reason the feature actually failed.

> **RULE. Ask what range of the input space a synthetic fixture spans, and whether the
> failure you fear lives inside it.** A fixture tuned for a clean pass/fail boundary tends
> to sit far from that boundary.

### 4.4 The metric decides the verdict, so ask what it cannot see

The offline study scored *visible shimmer on static pixels* and a *global comb ratio*. It
never scored "comb left on slowly-moving edges", nor "the veto mask's edges are visible as
a one-frame trail" — the two things the maintainer reported. Both are invisible to both
metrics, so a favourable verdict was guaranteed regardless of those artifacts.

> **RULE. Before trusting a model's verdict, enumerate the artifact classes its metric is
> structurally blind to.** A number that cannot go bad for a given defect is not evidence
> about that defect.

### 4.5 When you reduce work, score the SET, not the COUNT

Halving the pump's reads (skipping lines whose history can never be consulted) was
implemented with the parity **inverted** — right algebra applied to the wrong line. It
fetched exactly the half that is never used.

The count was identical either way. The arm caught it in one run *only because* it scored
**which** lines were fetched. A count-based arm would have passed.

> **RULE. An optimisation that does half as much work must be gated on doing the RIGHT
> half. The wrong half has the same count.**

### 4.6 A measurement that can no longer detect its own subject

Once the pump moved to `ram2` its cost hit exactly zero, so the probe's two arms became
indistinguishable — **which is also precisely what a dead pump reads.** "No measurable
cost" and "not running" produce identical telemetry.

Liveness was proven separately: the DDR3 region *changes* with the pump on and *freezes*
with it off (with the decoder's own framestore as the control, to show playback was live),
and the pump's FSM is serial, so writes continuing proves its reads complete.

> **RULE. When an effect reaches zero, the instrument that measured it can no longer tell
> you the mechanism is present. Prove liveness by a different route before reporting
> "free".**

---

## 5. Timing technique that worked

### ★ Gate at the register, not inside the producing cone

A one-bit term was ANDed into a combinational result inside `deint_detect`. That put it in
the module's critical cone, which was already the binding path. Two consecutive builds
missed the gate (**91.42/85.08**, then **82.52/84.73** against 86.0) and each needed a
fitter seed sweep.

The term reached the output through exactly one gate, and the output was already zero
whenever that gate was false — so tying the input to `1'b1` and applying the term at the
**register** instead (`q <= term ? result : 0`) is algebraically identical, and lifts it
out of the cone entirely.

Result: **89.81 @100 °C / 88.36 @−40 °C, passing on the FIRST fit**, ~2.4 MHz of margin,
no sweep.

> **RULE. When a new term only ever *suppresses* an existing result, apply it at the
> register that captures the result, not inside the logic that produces it.**

### The cold corner usually binds, and the tool defaults to the hot one

`fmax_check` gates **both** slow corners and −40 °C is frequently the worse one, while
`tools/timing_paths.tcl` defaults to 100 °C. Pass `TIMING_TEMP=-40` or you will retime a
path that is not the one failing — which has cost this project two wasted retimes.

### A netlist change invalidates the pinned seed

`UMD.qsf`'s pinned `SEED` is tied to the exact synthesis netlist. A seed that closes one
build can be far below the gate on the next: **SEED 5 passed at 88.61/87.63 and then
returned 74.76/79.39** after the RTL changed. Expect to re-sweep after any real change,
and treat a first-fit pass as luck rather than entitlement.

---

## 6. Hardware-in-the-loop measurement discipline

- **An EMPTY `vbuf` is upstream starvation, not memory contention.** A decoder held off by
  the bus stops *consuming* and its buffer fills; a buffer that drains to zero means bytes
  are not arriving. Reading this correctly stopped a wrong diagnosis ("the pump is
  starving the arbiter") that was already half-written.
- **Test on LOCAL media.** The first probe attempt ran from a CIFS share and produced
  playback stalls that looked exactly like a core defect. A network hiccup and an arbiter
  bug present identically in telemetry. The stalls were never attributed and should not be
  cited in either direction.
- **A paired, alternating, within-build comparison cancels netlist quality.** That is what
  made it defensible to measure on a `_MARGINAL_` build: both arms run inside one netlist,
  so any weakness applies to both. ⚠ It licenses *relative* claims only — never picture
  quality, never anything cross-build.
- **Content drift is the same order as the effect.** Two consecutive same-arm windows on
  different scenes differed as much as the effect under test, which is why the arms must
  interleave rather than run as one Off block and one On block.
- **Check the feature is even engaged before measuring it.** Much of this work was
  measured on content where the deinterlacer never blended a pixel (`comb_density = 0`).
  That is fine for a *traffic* question and worthless for a *quality* one — and confusing
  the two is how a feature gets declared "free" the day before it is rejected.

---

## 7. Recurring papercuts, none of them interesting, all of them expensive

- **Verilog declaration-after-use** cost ~5 build/elaboration failures across this work,
  in both benches and `sys_top.v`. Icarus and Quartus both reject it; neither says
  "move the declaration up".
- **A port left as `input` while the module drives it internally** is a *multiple-driver*
  error that **neither the linter nor any bench can see** — `lint_undriven.sh` asks about
  nets with *no* driver, and every bench instantiates the leaf modules directly rather
  than the wrapper. Only the fitter catches it, as `Error (12014)`, ~30 seconds into a
  40-minute compile. When a signal stops leaving a module, delete it from the port list in
  the same edit.
- **`pgrep -f <pattern>`** matches the shell running the command that contains the
  pattern. An `until ! pgrep -f build.sh` loop waits forever on itself. Match on a
  container name or a PID.
- **A renamed OSD option must move with its manual row** (`tools/docs_check.py` enforces
  parity) — and, less mechanically, **a row whose description stops being true is a
  documentation bug**: this feature's row said it "changes only memory traffic, never the
  picture", which silently became false the moment the term consumed it.

---


---

## 8. What was left behind on purpose

The source note's §0, §1, §3 and §8 describe MiSTer_DVD's abandoned deinterlacer, its
measured per-module ALM table and its `ram2` wiring recipe. The recipe is reproduced in
`architecture.md` in outline; the rest is that core's history and is not carried here.
