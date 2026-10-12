# Solved-problem history (condensed)

Each entry: *what was wrong*, *how it was fixed*, one paragraph each. The full
investigation lives in the docs note or PR it names; this file is the index a cold
session reads first.

---

## 1. The scaffold (P0)

**First fit (2026-09-23, `UMD_scaffold_20260923_0328.rbf`, SEED 1, first roll):** 7,190
ALMs of 41,910 (17 %), 10,720 registers, 62 M10K, 36 DSP (33 of them ascal's, 3 the
wave's tint multiplies); clk_dec 352.11 MHz @100 °C / 322.16 @−40 °C against the 86.0
gate (the domain holds one 24-bit counter, so this number says nothing about the decoder
to come); 2.4 MB compressed. No implicit nets, `lint_undriven` and `netlist_canary` PASS.
Per module: framework ~6.4K ALM, `emu` 833 (`xmb_wave` 232, `hps_io` 391,
`block_streamer` 101, `sync_gen` 30, `dec_stub` 12). The wave came in under its 250-ALM
target with 0 M10K.

*Hardware (same day):* loaded on the rig from the menu core; the idle wave came up in
September's tint (the HPS timestamp reached the month FSM), moved between two shots,
no black pixels. Screenshot-only gate; the OSD pop and the mount LED remain unverified.

*What the scaffold taught:* the `hps_io.sv` Icarus limitation (declaration order in the
stock file) means `umd/emu.sv` cannot be elaborated by iverilog with the real `hps_io`;
Quartus and verilator (`lint_undriven`) are the checks for it. Two bench arms were wrong
before the RTL was: a whole-frame motion diff cannot see one frozen wave of three, and the
gradient test was confounded by the waves' own top/bottom asymmetry until the waves were
forced flat for that arm (`docs/idle_screen.md`).
