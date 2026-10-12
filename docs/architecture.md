# Architecture

## Target data flow (what the roadmap builds toward)

```
 hps_io sd_* (2048 B blocks) --> umd_reader (ISO9660 walk, PLAYLIST/CLPI, MPS extents)
        --> ps_stream_fifo --> ps_demux --+--> video ES FIFO (vidfeed_cdc) --> h264 front end (clk_dec)
                                          |        --> recon (itrans, intra, inter/MC, deblock)
                                          |              <--> DPB in DDR3 (own f2sdram port, ddr_arb)
                                          |        --> disp_sched (STC, POC order, 3:2) --> raster + overlays
                                          +--> audio_ring --> at3p decoder --> NCO --> AUDIO_L/R
                                          +--> subtitle units --> inflate/png_unfilter --> subtitle plane (DDR3)

 raster: video --> subtitle plane --> menu plane (P9) --> diagnostic HUD --> (sys/ OSD)
         each plane premultiplied ARGB in DDR3, read a line at a time on ram2 (ddr_arb), DDA-scaled, blended
 menus (P9): one C engine (VSMX VM, scene graph) on a soft CPU (host A) or in Main's support/umd (host B)
         --> menu plane; --> player control block (P6: play / stop / select; status; events)
```

One presentation clock (a free-running 90 kHz STC, MiSTer_DVD's `disp_sched` design)
schedules video pickups, audio dispatch and subtitle windows against their PTS.

## Clock domains

| clock | rate | owns |
|---|---|---|
| `clk_sys` | 27 MHz | everything at pixel rate: raster, overlays, demux, reader, ring, presentation |
| `clk_mem` | 90 MHz | `DDRAM_CLK`; the f2sdram burst bridge (90 is the proven ceiling of that bridge) |
| `clk_dec` | 81 MHz | the H.264 front end and reconstruction; gated at 86.0 MHz both corners by `tools/fmax_check.sh` |

## Memory ports

`sys_top.v` exposes three f2sdram ports: `ram1` (64-bit, `DDRAM_*` on emu), `ram2`
(64-bit, `DDRAM2_*` on emu since P5a: a `UMD-FORK`, below), and ascal's `vbuf` (busy;
never a spare). MiSTer_DVD measured that the scarce resource is **arbitration
occupancy, not bandwidth** (`hw_budget_and_lessons.md` §2): a second read master on
`ram1` cost the decoder lates that the same traffic on `ram2` did not. So the DPB client
owns `ram1` (behind `ddr_mux2`, kept for the mount abort, its master B tied off) and
the display reader (`disp_reader`, `docs/display.md`) reads `ram2`; everything else that
needs DDR3 (subtitle scratch, an audio delay, the subtitle and menu planes' readers, a
menu CPU) shares `ram2` with the display, not `ram1`, through `ddr_arb` with the display
first (`menus.md` §4). A menu plane written by the HPS (host B) uses no fabric port: Main
writes it through `shmem_map()`. All three ports reach the same DDR3 device and the same
address map, so the display reads the DPB stores `ram1` writes. (Until P5a the
decode-order smoke display `disp_smoke` read `ram1` as `ddr_mux2`'s second master:
`h264_recon.md` §4.)

## What the build actually is (P4, in progress)

`emu.sv` → `sys_pll`, `hps_io` (BLKSZ=4), `umd_reader` (the image walk + the stream,
`docs/umd_reader.md`) → `ps_stream_fifo` → `ps_demux` → the video ES through
`vidfeed_cdc` + `fifo_dc` into clk_dec → `h264/h264_top` (the whole front end,
`docs/h264_frontend.md`) → `h264/recon_top` (the reconstruction, `docs/h264_recon.md`;
its DPB client `dpb_mem` on clk_mem) → `ddr_mux2` → `DDRAM_*` (ram1), with `disp_reader`
reading `DDRAM2_*` (ram2) the stores `recon_out` queues in output order (P5d); audio
and subtitles into `es_probe` (sinks that only count; `docs/p2_chain.md`); the front
end's counters back through `cdc.sv`'s `cdc_snap`, its reset through `cdc_reset`;
(`p2_diag` + `diag_hud`, the diagnostic readout over the raster, until 2026-10-03:
removed for Go To's room, `area_plan.md` A11; telemetry carries its counters), `sync_gen`
(720x480p), `xmb_wave` (the idle screen), `dec_stub` (the clk_dec heartbeat on
LED_USER), tie-offs for audio. `ddr_arb.sv` is listed in the qsf (so it is linted) but
not instantiated (its second master is write-only; kept for P6's audio). P0's
`block_streamer` is retired (deleted in P2).

## Clock-domain crossings (all in `umd/cdc.sv`, `umd/vidfeed_cdc.sv`, `umd/dec_stub.sv`)

| crossing | shape | why |
|---|---|---|
| video ES, clk_sys → clk_dec | `vidfeed_cdc` (dual-clock `fifo_dc`, one pop in flight) | a byte stream with backpressure both ways |
| the front end's reset, clk_sys → clk_dec | `cdc_reset` (async assert, two-flop release) | a per-mount reset released cleanly in the destination |
| `title_done`, clk_sys → clk_dec | two flops inside `vidfeed_cdc`, then a quiet window | a level that becomes one flush pulse |
| the counters, clk_dec → clk_sys | `cdc_snap` (four-phase handshake, all bits in one source cycle) | a readout that is never torn |
| `dec_alive`, clk_dec → clk_sys | two flops | a single slow bit |
| the display's freeze, clk_sys → clk_dec (`frz_dec_s`, P6b3i) | two flops | a level: `recon_dpb` does not count its wait on a frozen display's holds as an error. Timed as the 12.3 ns same-group pair, which a register-to-register hop meets: no bound |
| SE words → DDR3, clk_dec ↔ clk_mem | `dpb_mem` (three `fifo_dc`: commands, write data, read data; a read credit) | the DPB client's bursts on the port clock |
| the mount reset, clk_sys → clk_mem | `cdc_reset`, then two flops into `ddr_mux2.a_abort` | the decoder's DDR side resets per mount; the port never does (an open write burst would hang it) |
| the PLL lock, → clk_mem (`mem_lock_n`) | `cdc_reset` of `locked` alone | the reset of every master that drives a DDR3 port directly (`ddr_mux2`, its abort register, `disp_reader`'s fetch side): never RESET, never the mount -- a master reset under waitrequest withdraws its request and the f2sdram port stops returning reads (the reload hang, `docs/hil_harness.md`); `ddr_mux2` also holds a request its master withdraws |
| the syntax elements | none since 2026-09-24: the reconstruction is on clk_dec with the front end | (the P4 smoke clocking ran it on clk_sys through `se_cdc`, a 32-word `fifo_dc` + an output register; kept with its bench as the fallback, `h264_recon.md` §4) |
| ~~the newest completed picture / the display's latched store~~ | ~~two `cdc_snap`s~~ | **retired in P5d**: the P4 smoke crossing, replaced by `recon_out` (below), which also removed its ~6e-6-per-frame torn-frame race |
| display line requests, clk_sys → clk_mem | a toggle + a line number held for a whole line (`disp_reader`) | one request per raster line; dual-clock line buffers carry the samples back |
| the reconstruction's counters, clk_dec → clk_sys | `cdc_snap` (132 bits) | the HUD's `P4` row, never torn |
| the output queue, clk_dec ↔ clk_sys | `recon_out`: a per-store table (written clk_dec, read clk_sys), a record `fifo_dc`, a release `fifo_dc` back | a store is held from emission to release; its row cannot change while it is queued (P5d, `display.md` §6) |
| the reader's fetched-change count, clk_mem → clk_sys | `cdc_snap` (32 bits) | the judder gate's independent half on the HUD (P5e) |
| the DDR3 probes, clk_mem → clk_sys | `cdc_snap` (80 + 64 bits: the 16-bit views only) | HIL telemetry (`hil_harness.md` "Telemetry") |
| the telemetry responder | none: `umd_telem` runs on clk_sys with hps_io, and every source is already a clk_sys register or snapshot | |

`sys_top.sdc` keeps the PLL outputs in one exclusive group, so these transfers are
timed; the shapes are about one launch edge per captured value. Timed as same-group
transfers they get the tightest edge pair of the two clocks (3.7 ns for clk_sys /
clk_mem, 1.23 ns for clk_dec / clk_mem), which the shapes never use: `umd/umd.sdc`
bounds each shape's capture stages at 8 ns instead -- `fifo_dc`'s gray pointers,
`disp_reader`'s request and the fields it captures, and every `cdc_snap` (the copy
`hold -> dst_data` and the two synchroniser first stages; since P5g, 2026-09-27: the
three clk_mem -> clk_sys snapshots sat at -0.28 ns for three fits, P5e to P5f). A new
crossing needs its bound there in the same change; `tools/fmax_check.sh` warns on
negative setup slack on any core-PLL clock (it read clk_dec alone before P5g).

## Inherited `sys/` edits (all marked `UMD-FORK (inherited from MiSTer_DVD)`)

- SDRAM add-on board ports removed (`sys_top.v`, `sys.tcl`).
- `vol_boost` support and the `audio_out.sv` overflow/saturation fixes.
- `VGA_CS`/`VGA_CS_EN` emu ports + `CS_PIPE` delay + `vga_cs_osd` mux: composite sync from
  the core's own raster, for the P5 CRT work.
- `hps_io.sv`: `ini_vga_scaler/ini_csync/ini_ypbpr/ini_sog`, `cfg_seen/cfg_wr`,
  `TIMESTAMP[32:0]`.
- Scanlines DE gate removed (a no-op for a progressive core; kept for VBI use in P5).
- `sys/pll_q17.qip`: the Template's `rtl/pll.qip` line removed — no generated `pll` IP
  exists; every clock comes from `umd/sys_pll.sv`.
- **`ram2` to the core (P5a, 2026-09-25; `UMD-FORK (roadmap P5)`, this project's own, not
  inherited).** emu gains a second master `DDRAM2_CLK/ADDR/BURSTCNT/BUSY/DOUT/DOUT_READY/
  RD/DIN/BE/WE`; `sysmem_lite.ram2_clk` takes it (was `clk_audio`); the `ram2_*` nets are
  declared above `sysmem_lite` (declaration order). `ddr_svc` stays with its memory side
  on `svc_*` nets and its inputs tied idle: its `ram_bcnt` still feeds the palette
  address, and its two channels (ALSA, compiled out by `MISTER_DISABLE_ALSA`; the
  framebuffer palette, which needs `MISTER_FB`) never request. MiSTer_DVD wrote the
  recipe (`hw_budget_and_lessons.md` there) and never built it. `tools/check_emu_wiring.py`
  pins it: emu's port set equals the instance's (preprocessed with the qsf's macros),
  `ram2_address` declared above `sysmem_lite`, `ram2_clk` from emu, `ddr_svc` off `ram2`
  (run_scaffold.sh T1-T3).
- **`f2sdram_safe_terminator.sv`: the write burst tracked at the port (2026-09-26;
  `UMD-FORK`, this project's own).** Stock counted a beat on every cycle a burst was open
  and waitrequest low, with no `write` term, and ended a burst on the count alone; a
  master that drops `write` between beats (`dpb_mem` does on every burst: legal Avalon)
  or whose last beat meets waitrequest desynced it, and a core reset inside a write burst
  then left the HPS port short of beats for good -- the reload hang
  (`docs/hil_harness.md` "Facts that bite"). The fork counts the beats the port accepts,
  completes an open burst masked, keeps a held beat or read exactly as presented, and
  lets go only when nothing is being completed. `bench/umd/run_f2sdram_term.sh --red`
  (the stock module is its control arm, K0).
- **`sys_top.v`: the analog DAC's dither (2026-10-06; `UMD-FORK`, from MiSTer_DVD PR #164 and the
  H264 core).** `umd/dac_dither.sv` between the core-raster VGA path's last word (`vga_o`, after the
  `yc_out` mux) and all six DAC drivers (`VGA_R/G/B`, the SDIO low bits `vga_r/g/b`), as `vga_od`,
  enabled by emu's new output **`VGA_DITHER`** (the OSD's Analog Dither, `status[16]`, Off by
  default), connected inside `ifndef MISTER_DUAL_SDRAM` beside `VGA_DISABLE`. HDMI and the
  scaler-to-VGA path (`vgas_o`) untouched; no CDC (`clk_vid` is clk_sys here). `analog.md` §9;
  `check_emu_wiring.py` pins it (run_scaffold.sh W130 / W131, T5-T8).
- Dropped from MiSTer_DVD: the S/PDIF and HDMI IEC 61937 passthrough muxes (ATRAC3plus has
  no receiver bitstream format).
