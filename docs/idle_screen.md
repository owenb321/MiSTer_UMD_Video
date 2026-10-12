# The idle screen: an XMB-style wave (`umd/xmb_wave.sv`)

**Status: P0, sim-proven (`bench/umd/xmb_wave_tb.sv`, 9 mutations caught), ✅ seen on the
rig 2026-09-23 (September purple, moving).** Aesthetic tuning (wave scale, brightness) is
open: the first cut reads as a soft gradient with a slow highlight rather than distinct waves. Replaces MiSTer_DVD's bouncing logo, by decision: no user-logo upload path.

## Design

Per pixel, no framebuffer: three summed sines of `(h, v)` with slowly advancing phases
(`arg_i = KX_i·h + KY_i·v + ph_i`, all shift-add), a linear vertical gradient, a clamp,
and a 12-entry month tint ROM multiplied in. The sine is a 64-entry quarter-wave ROM in
logic, mirrored and negated by quadrant. Four pipeline stages (`LAT = 4`); `emu.sv`
delays sync by the same amount.

The month comes from `hps_io.TIMESTAMP` (UTC seconds; bit 32 toggles per delivery): a
~21k-cycle sequential FSM (subtract 86400 for days, a leap-aware year walk, a
cumulative-days walk). Keyed on the toggle, never on a non-zero value. Default month 7
until a timestamp arrives. `month_force` exists for the bench and a future OSD preview.

Budget target: < 250 ALM, 0 M10K, 0-3 DSP (the tint multiplies). **Measured on the first
fit: 232 ALM, 0 M10K, 3 DSP** (`history.md` §1).

⚠ The sine ROM is written as `case` blocks in an `always @*`, deliberately NOT a Verilog
function: MiSTer_DVD measured Quartus 17 silently miscompiling some `function automatic`
helpers (sim exact, silicon silent).

## The bench, and what each arm can and cannot see

`xmb_wave_tb` drives the real `sync_gen` and scores rendered frames: coverage/alignment,
motion, tint (distinct months, channel ordering), gradient **with the waves forced flat**
(the waves' own top/bottom asymmetry confounded the first version — it passed on RTL with
the gradient deleted), saturation, sine odd-symmetry, the date FSM on four dates including
the leap day, and `vis=0`. `run_scaffold.sh --red`: M1-M6 each caught by its own arm.

Known blind spot: **one frozen wave of three is not caught** (the whole-frame diff still
moves). Covered by the design's simplicity, not by the bench.
