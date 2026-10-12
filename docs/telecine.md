# Hard-telecined film: field matching (Forgejo fj#80)

**Status: the model stage ✅ built (2026-10-08).**
- **The RTL ✅ built (2026-10-09, §5)**, benches green.
- **The fit:** SEED 5 PASS at 90.76 / 89.11 MHz, 39,718 ALM (95 %).
- **✅ HW-CONFIRMED on .236 (§7)**, and by the maintainer's own test.
- **✅ MERGED (PR fj#82).**
**Decided (§6):**
- **T1, Auto:** there is no OSD option.
- **T2:** before the lock the picture is the Deinterlace setting (Weave by default).
- **T3:** build the RTL.

The maintainer confirmed both interpretations on 2026-10-08.
The issue's own "next step" is done: the comb metric and the cadence lock were checked offline,
before any RTL. The lock was scored across the library (§4). It never locked on a true-video
window. The decisions the RTL needs are §6.

- **The model:** `tools/telecine_ref.py` (the future bench's golden).
- **Tests:** `tools/tests/test_telecine_ref.py`, with 8 RED mutations in `tools/tests/red_umd.py`.
- **The library sweep:** `tools/telecine_census.py`.

## 1. The case

By the census (§4), 15 of the 84 main titles are **hard-telecined film**, and so are the field stretches of
The Mummy and The Mummy Returns. Hard-telecined film is 23.976 fps film coded as 59.94
field pictures. They use `field_pic_flag 1` with `pic_struct` 1 / 2 and ct_type 1, the 3:2
pulldown is baked into the fields, and there is no repeat flag. **Nothing in the stream marks it.**

On the progressive output the deinterlacer treats each coded pair as interlaced:

- **Weave** combs **2 of every 5 pairs**: those pairs hold the tail of one film frame and the
  head of the next.
- **Bob** does not comb, but shimmers and loses half the vertical detail.
- **Blend** ghosts on the same 2 of 5 pairs.

The 480i output is already right: it carries the fields as authored.

This is not the soft 3:2 family. Those are frame pictures with `pic_struct` 3-6 (Akira and
others); they are frame stores, so every deinterlace mode passes them untouched (`display.md`
§8).

`display.md` §8's "H.264 says which pictures are fields, so the deinterlacer never guesses" is
true of WHICH pictures are fields. It is not true of WHICH FIELDS BELONG TOGETHER, and that is
this note's subject.

## 2. What the fabric can see (the model's constraints)

These were read from the RTL, not designed here.

**One store visible.** At 480p `disp_reader` fetches every line of the **one** store on screen
(`disp_reader.sv` L371-380; the store is `pic_store`, L628). In a field store the window's
a = v-1 and d = v+1 lines are the other field, and b = v is this field (L428-434). The
ring mirrors at the edges: line 0's a is line 1, and the last line's d is the line above it.
Luma `ya` / `yb` / `yd` are all present at readout stage 2 (L491-497).

**The observable** is computed per refresh over the **displayed** weave, as two luma
integer sums:

```
C = sum |2b - a - d|        R = sum |a - d|
```

- While unlocked it measures the in-store weave. The reader fetches every line in Bob too, so
  the measurement is the same whatever is shown.
- Under a lock it measures the cross-store weave being shown.
- It is complete at line 478 and known before the pickup at line 500. So refresh k's evidence
  steers refresh k+1.
- **There is no lookahead.** A pair's in-store comb is known only once that pair has been shown.

The ratio C / R is texture-normalised. Clean pictures read 0.6-1.1 and combed ones 1.4-10 on
the library (§4).

`comb_metric.py`, the rig gate, uses the same numerator, but its denominator is the
2-line second difference. That needs lines v ± 2, which the reader's a / b / d window does not
hold. The model scores what was SHOWN with the rig gate's ratio, so the two agree on what
"combed" means. The FSM decides on C / R, which the fabric can compute.

**The neighbouring stores.**

- The previous store is released at the pickup (`disp_ctl.sv` L462). Matching needs it held
  for one more pickup: one more store held, out of 20 stores against a DPB of 3.
- The "next" store is the queue head (`recon_out.sv` L19-21). It is held while queued, but it
  may be absent when the decoder is late.

**Candidates.** Only field pairs (`sh_field && !sh_single`). Frames and single fields pass
through as today.

## 3. The model

### 3.1 The matching rule (measured, not assumed)

In a pair whose two fields come from different film frames:

- refresh 0 shows the **first** field, and its partner is the **previous store's second
  field**;
- refresh 1 shows the **second** field, and its partner is the **next store's first field**.

The rule is uniform, so a pair needs only one binary decision: weave it in-store, or match it.
It holds whenever every film frame is a run of at least 2 contiguous fields. Then a split pair's
first field is the last of its run, and its second field the first of the next run.

**The truth cannot test the rule**, so the rule is measured on the pictures. `truth()` builds
its film frames out of 2- and 3-field runs, so a structural check made from it passes by
construction.

`score()` measures the rule instead. It takes every split pair (by the truth) that combs
in-store and has both partners present. It counts how often **both** of the rule's cross-store
weaves read clean (rig ratio ≤ 1). The results are in §4.1.

### 3.2 The cadence lock

The FSM has the shape of MiSTer_DVD's confidence FSM (`resample_addrgen.v` L1004-1070): it
counts up on confirming evidence and drops hard on a contradiction. The values are new, and
each one's source is in §4.

**Phase.** Each field pair has a slot 0..4. Slots 0 and 1 are predicted to hold two film
frames.

**Unlocked.**

- The pair is shown under the fallback (Bob, or Weave; a decision for §6).
- Its in-store C / R is classed **COMBED** (C ≥ 2.5 R, with C ≥ 1.0 per sampled dot: real
  motion), **CLEAN** (C ≤ 1.25 R) or **UNSURE**.
- Two adjacent COMBED pairs set the phase.
- A cycle counts up only if one of slots 0 / 1 combed and slots 2-4 did not. This is the
  informative gate: a still or a held drawing proves nothing.
- A COMBED pair at slot 2-4 resets the confidence and the phase.
- An UNSURE pair there costs DN_SOFT.
- At ENGAGE cycles the FSM locks.

**Locked.**

- Slots 0 / 1 are shown matched; slots 2-4 in-store.
- **Any** shown weave at C ≥ 1.5 R breaks the lock at once. Its next refresh is already the
  fallback. One combed refresh per edit is the accepted cost.
- Static scenes give no evidence either way, and the lock holds.

**The partner absent** (no next store, or a field-order change). That refresh is bobbed. It
is never woven alone.

**The bias is precision.** A false lock is a regression, because true video would be woven
across stores. A missed lock is today's picture.

**One limit, found by the synthetic arms.** Pure drawings on twos show only ONE combed pair a
cycle: the other split pair holds one drawing twice. Two adjacent COMBED pairs never occur, so
the phase never forms. That is safe (no wrong match), and real animation mixes enough motion to
lock (§4: The Simpsons Movie).

### 3.3 Truth (never C)

**The source of the truth is ffmpeg `idet`'s per-frame `repeated.current_frame`**: a field
equal to the same-parity field of the previous store.

- A repeat at field j means g[j-2 .. j] is one 3-field run.
- Between two such runs the fields are 2-runs only if they number 0, 2 or 4, as 3:2 and 2:3:3:2
  allow.
- Any other gap leaves its boundaries **unknown**: a static stretch where idet sees nothing, an
  edit, or an irregular cadence. `test_telecine_ref` checks it against the generator's own film
  frames.

**The cross-check: `own_repeats`.** It is the model's own same-parity field difference: a field
repeats when its difference from the previous store's same-parity field is under a quarter of
the other parity's. It is strict, so it may miss a repeat but never invents one.

- Over the census it agrees with idet on 99.3 % of stores in the clean 3:2 windows, 90.7 % in
  the noisy ones and 99.5 % in the video windows.
- **It never conflicts:** no store where the two name different repeated fields.
- The disagreements are repeats idet sees in low motion and this test does not.

**The oracle.** Per refresh it takes the least combed of the in-store weave and the rule's
cross-store weave, using lookahead the fabric does not have. It is reported only as a ceiling.

### 3.4 The synthetic arms (`test_telecine_ref.py`, no media)

Every checkpoint is sourced from the generator's own film frames (`synth`):

- **The observable** against a direct loop sum, every subsample variant.
- **The partner fields** picked by hand, both field orders.
- **The truth** for every phase and both field orders.
- **The matching rule, measured on the pictures:** at every split store the in-store weave
  combs and both rule weaves read clean.
- **Clean 3:2**, both orders and every phase:
  - it locks within 12 cycles;
  - it never matches a whole frame;
  - it never shows a combed refresh.
- **True video:** it never locks.
- **A still:** it never locks.
- **Film then a still:** it is phased, but never locks.
- **Twos:** no wrong match.
- **An edit:**
  - at most one combed refresh;
  - one break;
  - the lock comes back within 12 cycles.
- **The next store absent:** that refresh is bobbed.

**RED: 8 mutations, each caught by this test:**

1. the partner field;
2. the parity;
3. the break;
4. the informative gate;
5. the phase;
6. the normaliser;
7. the truth's gap rule;
8. the ring's mirror.

## 4. The census

`UMD_ISO_DIR=... tools/telecine_census.py --cache DIR --jobs 6` sweeps every image in the
library: 84 images, two windows of 6,000 packs each, at 45 % and 70 % of the main title.
That is 168 windows, with 0 errors. The decode is cached per window, so re-running the FSM
with other constants (`--param key=value`) takes seconds.

**Families.** Each window is classed by its truth, not by C:

| family | how it is classed |
|---|---|
| hard 3:2 | idet repeats a field on ≥ 25 % of stores (3:2 itself: 40 %) |
| clean | ≥ 90 % of stores have a known truth |
| noisy | below that: static stretches and held drawings leave gaps |
| irregular | repeats on 5-25 % of stores |
| video | repeats on < 5 % of stores |
| mixed | frame and field pictures in one window |
| frames | frame pictures only: soft 3:2 or progressive, never touched |

### 4.1 Results, as built (`PARAMS`)

Combed refreshes under each display policy, and how much of the time the lock holds:

| family | windows | refreshes | Weave | model, Bob unlocked | model, Weave unlocked | oracle | locked | combed while locked | breaks |
|---|---|---|---|---|---|---|---|---|---|
| frames | 121 | 332,032 | -- | -- | -- | -- | 0 % | -- | 0 |
| **video** (the controls) | 12 | 35,022 | 46.0 % | 0 | 46.0 % | 29.3 % | **0 %** | -- | 0 |
| hard 3:2 clean | 8 | 24,840 | **33.0 %** | **0.49 %** | **4.35 %** | 0.82 % | 86.2 % | **0.57 %** | 7 |
| hard 3:2 noisy | 21 | 71,470 | **15.2 %** | **0.26 %** | **4.81 %** | 0.98 % | 63.2 % | **0.41 %** | 24 |
| irregular | 3 | 11,382 | 17.1 % | 0 | 16.8 % | 5.0 % | 2.4 % | 0 | 0 |
| mixed | 3 | 11,944 | 7.7 % | 0.12 % | 2.19 % | 0.17 % | 23.5 % | 0.50 % | 0 |

The matching rule, measured at the split pairs that comb in-store:

| family | both rule weaves clean |
|---|---|
| hard 3:2 clean | 3,810 of 3,905 (97.6 %) |
| hard 3:2 noisy | 4,477 of 4,769 (93.9 %) |
| hard 3:2 without Interstella 5555 | 8,254 of 8,506 (97.0 %) |

How to read the columns:

- **"Combed"** means a shown refresh whose rig ratio (`comb_metric.py`) is above 1.
- **The two "model" columns are the unlocked fallback's choice (§6).**
  - Under Bob, an unlocked refresh is never combed; its cost is shimmer, not combing. The model
    can sit below the oracle for that reason: the oracle never bobs.
  - Under Weave, an unlocked refresh combs as today, so film still combs **4-5 %** of the time,
    almost all of it outside the lock.
- **"Combed while locked"** is field matching's own quality, whatever the fallback.
- **The rig gate itself reads ~0.5-1 % of clean film refreshes as combed.** That is the
  oracle's floor on these families.

**The controls never lock.**

- None of the 12 true-video windows locks: The Office Disc 01 and 02, Metallica, Nirvana,
  Now 2006, and Dawn of the Dead. **The margin:** the highest confidence any of them reaches is
  **1 cycle of the 8 that ENGAGE needs** (Now 2006).
- At an acquisition ratio of 2.0 or 1.5, they reach 3. No control locked anywhere in the
  constants grid: comb8 16-24, brk8 10-14, ENGAGE 4-12.
- The Office's in-store comb runs in a period-6 pattern up to ratio ~2.0. That is consistent
  with a 50 → 59.94 conversion: a British series, an inference, not measured. That is why the acquisition threshold (2.5) sits well above the break threshold
  (1.5).

**The matching rule holds where the cadence is 3:2.** Across the library, 97 % of the
measurable split pairs have both rule weaves clean.

- **The failures concentrate in Interstella 5555**: 135 of its 168 split pairs. Its cadence is
  not 3:2, the issue's own suspicion confirmed. The lock never forms there (0-0.1 % locked).
- **Elsewhere the remainder is mostly the rig gate's floor** on detailed pictures. Where a rule
  weave reads above 1, its ratio is a median 0.24 of the in-store weave's.

**The lock's speed.**

| | stores | seconds |
|---|---|---|
| first lock, the floor (2 + 8 cycles) | 42 | 1.4 s |
| first lock, median | 214 | ~7 s |
| first lock, p90 | 913 | ~30 s |
| relock after a break, median | 58 | ~1.9 s |
| relock after a break, p90 | 134 | |
| relock after a break, max | 381 | |

- The first-lock figures count from the window's start (27 of the 29 hard-3:2 windows lock).
- A first lock is slow on a window that opens on a still or an animated stretch: there is no
  evidence until something moves across a film-frame boundary.
- 25 of 31 breaks relocked inside their window.
- One break costs at most one combed refresh.

**Misses** leave today's picture: Weave or Bob, never worse.

- Tom & Jerry @45 %, Interstella 5555 and Astro Boy Vol. 1 do not lock. Astro Boy's oracle
  still combs 7-10 %, a cadence that is not 3:2.
- Family Guy locks only ~18 % of the time. Its weak combs (ratio 1.6-2.4) sit between the
  CLEAN and COMBED thresholds; Weave combs only 4-10 % there anyway.

**Matched where the truth says whole.** Cowboy Bebop (192 / 52), The Animatrix (66 / 228),
The Simpsons Movie (198 / 46), South Park and Family Guy match some pairs the truth calls a
single frame. These are animation: idet's repeats see held drawings as repeats, so its truth is
itself unsure there. The pictures were not combed: model combed ≤ 0.2 % on every one.

**Mixed windows are not modelled faithfully.** The Mummy, The Mummy Returns @45 % and
The Rock @70 % hold frame and field pictures together. The model treats every store as a pair;
the RTL passes frame stores untouched. Their field stretches do lock (28-38 %), so their field
parts are hard telecine too.

### 4.2 The observable's variant

The subsample barely matters. The figures for every dot ("x1") against every 8th dot of every
line ("x8"):

| variant | locked, clean | locked, noisy | model combed, clean | model combed, noisy |
|---|---|---|---|---|
| x1 | 86.3 % | 62.4 % | 0.55 % | 0.30 % |
| x8 (chosen) | 86.2 % | 63.2 % | 0.49 % | 0.26 % |
| every 4th line too | | 53.9 % | | |

**Chosen: (8, 1)**, every 8th dot of every line: 90 × 480 terms. C and R each fit in
**25 bits** (43,200 × 510). The full raster would need 28.

### 4.3 The constants, and where each comes from

| constant | value | source |
|---|---|---|
| `comb8` | 20 (2.5) | the controls' in-store peaks (The Office ~2.0); film's combed pairs read 1.4-10 |
| `clean8` | 10 (1.25) | film's clean pairs read 0.6-1.1 (The Dark Knight, The Simpsons Movie) |
| `brk8` | 12 (1.5) | above every clean film pair, below most controls' combs |
| `floor16` | 16 (1.0 a dot) | a combed pair needs motion; The Dark Knight's slowest combed pairs read 1.3 a dot, its clean ones 0.3-0.6 |
| `engage` | 8 cycles (~1.3 s) | a 7-cycle margin over the controls' best (1) |
| `dn_soft` | 2 | an UNSURE pair at a clean slot costs two cycles' gain |
| `conf_max` | 15 | 4 bits |

Of the two thresholds, `brk8` trades lock time against combing:

| `brk8` | locked, clean | model combed, clean |
|---|---|---|
| 10 | 79.7 % | 0.28 % |
| 12 (as built) | 86.2 % | 0.49 % |
| 14 | 88.0 % | 0.65 % |

`comb8` from 24 down to 16 lifts locked from 84.0 % to 89.9 % at ENGAGE 8, with the controls
still at 0. Both stay as built until the rig has a say.

## 5. The RTL (built 2026-10-09, branch `feature/telecine-model`)

**`umd/film_lock.sv`**, the cadence lock (clk_sys), mirrors `telecine_ref.FilmLock` step for
step. It has one step per 480p pickup, in this order:

1. the evidence of the refresh just shown;
2. a pick (acquisition on the store just left, then the slot steps, or everything resets if
   the new store does not continue the pairs: `np`);
3. the coming refresh's `show`: FALLBACK (the Deinterlace setting), IN (woven), PREV, NEXT,
   or BOB (the partner is absent).

The state is a 3-bit slot (7: no phase), a 4-bit confidence, the lock and two 2-bit classes.
The compares are `C·8` against `R·{20, 10, 12}` and `C·16` against `npix·16`, with constant
multiplies. `clr` is a resync or the 480i raster.

**`umd/disp_reader.sv`** gains three inputs:

- `pic_match`: a line whose parity differs from the shown field's (`pic_parity`) is requested
  from `pic_pstore` (`req_alt`, captured into `m_store` with the request). This is an address
  choice only: one line fetched a raster line, no bandwidth added, never at 480i or in the
  window.
- `pic_film`: 1 forces the weave (b), 2 bobs `pic_parity`, 0 is the menu's kernel.
- The comb sums: at stage 2 on every 8th dot of the picture's 480p lines, `C += |2b − a − d|`
  and `R += |a − d|`. The sums are latched at line 480 as `cm_c` (25 b) and `cm_r` (24 b), with
  `cm_v` set for a field pair, not single, outside the window. They are `observe()`'s (8, 1)
  exactly: the same mirrored edges, the same subsample.

`umd.sdc` bounds `req_alt` and `sh_pstore` like the other request fields.

**`umd/disp_ctl.sv`** steps the lock at every pickup with the reader's sums, and holds the
partners.

- **The previous store.**
  - When a field pair is picked after a field pair of the same field order, size and item
    (`np_now`), the outgoing store is held as `prev` instead of being released.
  - The store it held before is released then.
  - A second release in the same cycle (`prev` and a non-continuing outgoing store) waits a
    cycle in `rel_pend`. The cycle after a pick has no other release (`rec_take` blocks the
    judges).
- **The next store** is the queue's head (`nx_ok`): a prepared pair of the same kind, in the
  current item, not skipped, not past OUT, not ended. Nothing can take it before the next
  pickup.
- **The choice** reaches the reader one cycle after the pickup (`sh_match`, `sh_pstore`,
  `sh_film`), long before line 0's request at line 523.
- **A resync** clears the choice, drops the hold and drains the queue. A line the reader
  requested in that very cycle may still fetch from either partner. So the held store (`rp0`)
  and the drained head, if it was the NEXT partner (`rp1`), are released only at that refresh's
  pickup (line 500), when the reader has nothing in flight.
  - `run_disp_sched.sh telecineseek` found this race: `[hold]` caught a read of a released
    store at the resync refresh.
  - `tools/disp_sched_ref.py` defers the same two releases.

**Telemetry** has a new word, `film` (68 words): `[15]` locked, `[14:12]` slot,
`[11:8]` confidence, `[7:0]` locks lost (mod 256).

**Stores held.** At most one store more than before, and only during field-pair playback: 20
stores, a DPB of at most 16, the shown store, the held one, and the one being decoded.
`recon_dpb`'s stall is unchanged (a hold always ends at the next pickup).

**Benches.**

| bench | what it checks | RED |
|---|---|---|
| `run_film_lock.sh` | 28 vector arms (the model's walk over synthetic film, video, still, black, twos, five edit phases, and three library windows; each also perturbed: 1-4 refreshes a store, absent partners, pair breaks, no evidence, a clr). Every step identical. | F1-F13 |
| `run_disp_reader.sh` | `match` (both parities, a film-woven Blend), `film` (weave, bob), `match` at 480i (inert), the comb sums exact against `observe()` | M1-M10 |
| `run_disp_sched.sh` | `telecine`, `telecinebff`, `telecineseek`: real 3:2 content written into the stores. The whole chain (the reader's sums, `film_lock`, the partners, the reader's partner fetch) matches the model refresh by refresh (`[film]`). `[hold]` proves every partner burst is from a held store, and `[queue]` that every store the model frees is free. Every other scenario is black and never locks. | H1-H7 |

**Area** (`tools/synth_unit.sh`, map estimate):

| unit | before | after | difference |
|---|---|---|---|
| `disp_ctl` with `film_lock` | 1,062 ALM | 1,244 | +182 |
| `disp_reader` | 1,176 | 1,236 | +60 |
| total | | | ~+240 |

**Known limitations.**

- **The model treats every store of a window as a pair.** The RTL resets on a frame store or a
  single field (`np`); the vector bench's perturbed walks cover `np = 0`, but no disc window
  with mixed coding was compared.
- **The field order.** The RTL's `first_bot` is the pair's decode order, and the model's is
  ffprobe's `top_field_first`. The `disp_sched` arms run both orders, but not a pair whose two
  orders differ.
- **A taller picture's (720x576) sums** cover the raster's 480 lines (`observe()` likewise).

**The manual** (done with the RTL):

- `playback/settings.md`'s Deinterlace row: film is shown whole whatever the setting.
- `reference/compatibility.md`'s Video section: film stored as fields, recognised by its 3:2
  rhythm.

## 6. Decisions (the maintainer, 2026-10-08)

**T1, Auto.** No new OSD value, and `CONF_STR` does not change. On the 480p raster the field
matching runs by itself, whatever Deinterlace says.

- **Matching applies in Weave, Bob and Blend alike** (confirmed 2026-10-08). A locked film pair
  is a whole film frame, which beats every kernel.
- The 480i raster is untouched: it carries the fields as authored.
- The manual's "Film and progressive titles are never altered, whatever the setting" becomes
  true again. It needs a sentence saying that film coded as fields is recognised and shown
  whole.
- **Auto raises the precision bar:** a viewer cannot turn a false lock off. The controls' 0 locks
  with a 7-cycle margin (§4.1) are the bar any change to the constants must keep.

**T2, unlocked = Weave.** Before the lock, and on every title that never locks, the picture is
what the Deinterlace setting gives today. Weave is the default.

- Measured: film then combs 4.35 % (clean 3:2) and 4.81 % (noisy) of refreshes, against 33.0 %
  and 15.2 % today (§4.1, "model, Weave unlocked").
- True video is unchanged.
- **"Unlocked" means the setting, not Weave forced** (confirmed 2026-10-08). A viewer who chose
  Bob or Blend keeps that kernel before the lock.

**T3, build the RTL.** Decided 2026-10-08; built (§5).

## 7. On the rig (.236, 2026-10-09, `UMD_telecine_20261009_0424.rbf`)

Progressive output, Deinterlace Weave, Disc Menus Off. The figures come from telemetry `film`,
and the shots are the core's raster scored by `comb_metric.py`.

**Austin Powers – The Spy Who Shagged Me** (clean hard 3:2):

- Locked about 37 s into the title and held through 80 s of sampling. No lock lost, errors 0,
  `dc` equal to `ft`.
- **A / B at the same picture** against the previous build (`UMD_resetfix`), PTS 71.25 M,
  after four chapter jumps:

  | build | combed shots |
  |---|---|
  | this build | 0 of 7 |
  | the previous build | 1 of 6 |

- **Chapter 9, a dense effects shot (sparks and smoke):**
  - 18 s after eight chapter jumps, both builds combed the same pictures. The lock had not yet
    re-formed after the jumps: this build showed the plain weave, as T2 says.
  - Shot once telemetry reported the lock (`seq ... until film >= 32768`): **0 of 10 combed**.
    The previous build combed 3 of 8 there.

**The Simpsons Movie:** locked on 16 of 16 samples over a minute, no lock lost, errors 0.

**The controls never lock.** The Office Disc 01 and Now 2006 stayed at confidence 0 on 16 of 16
samples each, errors 0.

**Akira:**

- The feature (frame pictures) never phases: 60 s from the start, slot 7, confidence 0.
- Its trailer (playlist 1, 92 s) is field-coded hard 3:2. The UMD Main's saved place resumed
  into it, and it locked, losing the lock 6 times in 92 s. The model locks that trailer 67 % of
  the time, with breaks. That is correct behaviour, not a false lock.

**What the session also found:**

- **The rig hit the HPS DDR3 port hang mid-test.** A ram1 read was never returned (`d1_owed`
  1), the reader stopped at 8 packs and `vstall` climbed. It reproduced with the previous build
  and every disc, and survived reloads. The `sys/` terminator fork is intact. A reboot (the
  maintainer's call) cleared it. Not this branch.
- **An A / B on the rig needs the disc's saved place reset.** A launch over a playing title is a
  quit, which saves the place, and with Disc Menus Off the next launch resumes there.
  1. Load the menu core first (that is the quit, and it saves).
  2. Put the backed-up place file back.
  3. Launch.
