// umd/umd_telem.sv -- core -> HPS telemetry over hps_io's EXT_BUS (HIL only;
// docs/hil_harness.md "Telemetry"). The wire format is tools/telem_layout.py's table,
// generated into umd/umd_telem_words.svh; main/support/umd/umd_ctl.cpp is the reader.
//
// HARVESTED from MiSTer_DVD dvd/dvd_telem.sv (the protocol and its reasons):
//   * EXT_BUS, not status_in: stock Main polls UIO_GET_STATUS every frame into
//     cur_status, so a core driving status_in would overwrite the user's OSD settings.
//     hps_io drives HPS_BUS[15:0] from EXT_BUS[15:0] whenever EXT_BUS[32] is set.
//   * io_enable frames a transaction, io_strobe clocks one 16-bit word, and the FIRST
//     strobe carries the command in io_din. Only for CMD do we take the bus (drive) --
//     a core answering Main's own commands (0x00-0x44, 0x61-63, 0xF0-F9) would corrupt
//     its protocol; 0x7A is free today, re-check on a Main bump (tools/telem_layout.py).
//   * word 0 is MAGIC, checked by the reader before use.
// CHANGED: every source is already a clk_sys register -- disp_ctl's counters, or a
// cdc_snap copy of a clk_dec / clk_mem one (the handshake snapshot: never torn) -- so the
// DVD's stability-filtering sampler (for raw asynchronous counters moving at <= 60 Hz)
// is not needed, and could not work here: SE words move every few cycles. The rate pairs
// (refreshes, pickups, decided / fetched changes, STC) are latched together on the
// command strobe; the rest are read live. Every word is 16 bits: a fast counter is sent
// pre-divided (the table's scale), so it wraps no faster than every ~3 s against the 4 Hz
// poll -- the first cut (53 words, 32-bit lo / hi pairs) cost 568 ALM. Word 1 = {FORMAT,
// NWORDS}.
//
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

module umd_telem (
    input  wire         clk,               // clk_sys (hps_io's)
    // EXT_BUS (hps_io)
    input  wire         io_enable,         // EXT_BUS[34]
    input  wire         io_strobe,         // EXT_BUS[33]
    input  wire  [15:0] io_din,            // EXT_BUS[31:16]
    output logic        drive,             // -> EXT_BUS[32]
    output logic [15:0] dout,              // -> EXT_BUS[15:0]
    // sources (all clk_sys)
    input  wire         refresh,           // one pulse a raster refresh
    input  wire  [31:0] t_pickups,
    input  wire  [31:0] t_dc,
    input  wire  [31:0] t_ft,
    input  wire  [32:0] t_stc,
    input  wire  [15:0] t_late,
    input  wire  [15:0] t_starve,
    input  wire  [15:0] t_cadence,
    input  wire  [7:0]  t_reanchor,
    input  wire         t_ended,
    input  wire  [2:0]  t_sflags,
    input  wire  [15:0] t_lag_ms,
    input  wire  [31:0] t_emitted,
    input  wire  [4:0]  t_dpb_fill,
    input  wire  [2:0]  t_oq_flags,
    input  wire  [19:0] t_wait4k,
    input  wire  [31:0] t_pics,
    input  wire  [31:0] t_mbs,
    input  wire  [31:0] t_rerr,
    input  wire  [3:0]  t_rcode,
    input  wire  [31:0] t_slices,
    input  wire  [31:0] t_se,
    input  wire  [31:0] t_ferr,
    input  wire  [3:0]  t_fcode,
    input  wire  [31:0] t_packs,
    input  wire  [31:0] t_vstall,
    input  wire  [15:0] t_d1_wr,
    input  wire  [15:0] t_d1_rdb,
    input  wire  [15:0] t_d1_busy,
    input  wire  [15:0] t_d1_busy_max,
    input  wire  [15:0] t_d1_owed,
    input  wire  [15:0] t_d2_rdb,
    input  wire  [15:0] t_d2_busy,
    input  wire  [15:0] t_d2_busy_max,
    input  wire  [15:0] t_d2_owed,
    input  wire  [31:0] t_pt,
    input  wire  [31:0] t_pts,
    // P6a: the audio path (aud_ring, at3p_top, aud_out)
    input  wire  [15:0] t_af,
    input  wire  [15:0] t_ar,
    input  wire  [7:0]  t_ak,
    input  wire  [15:0] t_aplayed,
    input  wire  [7:0]  t_under,
    input  wire  [7:0]  t_resync,
    input  wire  [15:0] t_av_err,
    input  wire  [15:0] t_adrop,
    input  wire         t_arun,
    input  wire         t_stc_run,
    input  wire         t_aerr_seen,
    input  wire  [7:0]  t_afb,
    input  wire  [7:0]  t_amiss,
    input  wire         t_apre_nz,
    input  wire  [15:0] t_rfill,
    input  wire  [15:0] t_rmax,
    input  wire  [31:0] t_rbp,
    input  wire  [15:0] t_rslides,
    input  wire  [15:0] t_rjumps,
    // P6a: the compressed-video buffer (vbuf)
    input  wire  [31:0] t_vfill,
    input  wire  [31:0] t_vmax,
    input  wire  [31:0] t_vbp,
    input  wire  [15:0] t_vlate,
    // P6b2: the image reader (state, err_code, the playing item's EP lookup flags)
    input  wire  [5:0]  t_rdst,
    input  wire  [3:0]  t_rdec,
    input  wire  [1:0]  t_rbare,           // P8: the file's mode (umd_reader bare)
    input  wire         t_rpw,             // P8: pmf_warn
    input  wire  [2:0]  t_epf,
    // P6b3 / P6b3i: the transport (player_ctl, disp_ctl's items, aud_out's item rules)
    input  wire  [2:0]  t_xstate,
    input  wire         t_xseek,
    input  wire  [1:0]  t_xshep,
    input  wire  [3:0]  t_xleft,
    input  wire         t_xstall,
    input  wire         t_xhold,
    input  wire  [2:0]  t_xnerr,
    input  wire  [15:0] t_chap,
    input  wire  [15:0] t_seeks,
    input  wire  [7:0]  t_holds,
    input  wire  [32:0] t_shpts,
    input  wire  [15:0] t_aleft,
    input  wire  [15:0] t_ayield,
    input  wire  [1:0]  t_tkspd,           // P6b4: trick play's speed, direction, one_frame
    input  wire         t_tkrev,
    input  wire         t_tkone,
    input  wire  [3:0]  t_hud,             // P6b7: the transport HUD {display, placeholder, malformed, cut}
    input  wire  [32:0] t_land,            //   the landing's first picture (player_ctl land_pts)
    input  wire  [19:0] t_slat,            //   the last seek's latency, 90 kHz ticks (player_ctl seek_lat)
    input  wire  [7:0]  t_wd,              //   seeks the watchdog ended
    input  wire  [2:0]  t_rlead,           //   since the last landing: leading pictures skipped (sat 7),
    input  wire  [2:0]  t_rpre,            //   pictures before the first I (sat 7),
    input  wire         t_rnidr,           //   a non-IDR start,
    input  wire         t_rmmco,           //   an MMCO naming a picture from before the entry
    input  wire  [3:0]  t_lone,            // lone PTS the display disbelieved (sat 15; display.md S10)
    input  wire         t_il,              // the 480i raster (docs/analog.md)
    input  wire  [15:0] t_pdefer,          // 480i: pickups deferred for field order (V6)
    input  wire  [1:0]  t_aa,              // 480i: the Analog Aspect in effect (S2)
    // 2026-10-03 (area_plan.md A11): what only the diagnostic HUD showed
    input  wire  [7:0]  t_frn,             // streams the front end refused (mod 256)
    input  wire  [3:0]  t_frc,             //   the last refusal's code
    input  wire  [3:0]  t_rzn,             // pictures refused for their size (mod 16)
    input  wire  [2:0]  t_rwarn,           // the reader's warnings {dur_sat, title_trunc, sfo_warn}
    input  wire  [3:0]  t_odir,            // output queue: direct releases (mod 16)
    input  wire  [7:0]  t_odrp,            // output queue: stores dropped (mod 256)
    input  wire  [7:0]  t_sdrop,           // subtitle units dropped (sat 255)
    input  wire  [7:0]  t_slate,           // subtitle flips / lines late (sat 255)
    // fj#80 field matching (docs/telecine.md S5): disp_ctl's lock
    input  wire         t_flk,             // locked
    input  wire  [2:0]  t_fslot,           // the cadence slot (7: no phase)
    input  wire  [3:0]  t_fconf,           // the confidence
    input  wire  [15:0] t_flost            // locks lost (wrapping)
);

    // the refresh count (the one source counted here)
    logic [15:0] t_refreshes = 16'd0;
    always_ff @(posedge clk) if (refresh) t_refreshes <= t_refreshes + 16'd1;

    // 7 bits (2026-10-07): 6 saturated at word 63 while the table grew to 67 words with A11 (PR fj#40),
    // so `refused`, `warn` and `subs` read word 63 (`pdefer`) on hardware; the bench's 64-entry arrays
    // compared X with X past it (docs/transport.md "D8, the handoff measured"). WIDX = telem_layout's.
    logic [6:0]  w_idx;
    logic [15:0] w_val;
    `include "umd/umd_telem_words.svh"

    logic [6:0] wcnt = 7'd0;
    logic       active = 1'b0;
    logic [15:0] dout_r = 16'd0;
    assign w_idx = wcnt;
    always_ff @(posedge clk) begin
        if (!io_enable) begin
            wcnt <= 7'd0; active <= 1'b0; dout_r <= 16'd0;
        end else if (io_strobe) begin
            if (wcnt == 7'd0) begin
                active <= (io_din == T_CMD);
                `UMD_TELEM_LATCH
            end
            dout_r <= w_val;
            if (wcnt != 7'h7F) wcnt <= wcnt + 7'd1;
        end
    end
    assign drive = active;
    assign dout  = dout_r;

endmodule

`default_nettype wire
