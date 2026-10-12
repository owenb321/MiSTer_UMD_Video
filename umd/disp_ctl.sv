// umd/disp_ctl.sv -- the display's control (roadmap P5e, docs/display.md S7): which store
// the raster shows at each refresh, and which field of it, paced by the scheduler
// (umd/disp_sched.sv). clk_sys, the raster's clock; tools/disp_sched_ref.py is the model.
//
//   the tick      90 kHz = clk_sys / 300, phased to the raster: counting starts at the
//                 first (h 0, v 0) after the mount reset (P = 0), a tick every 300 cycles
//                 after it (P = 300 m) -- so a refresh, 450,450 cycles, is 1501.5 ticks
//                 and the model knows every tick.
//   preparation   the queue's head record (umd/recon_out.sv, registered: stable until
//                 taken) becomes {tag, PTS, duration}: the duration is DeltaTfiDivisor
//                 (Table E-6: a frame 2, or its pic_struct's 0/3/4 -> 2, 5/6 -> 3, 7 -> 4,
//                 8 -> 6; a field 1, a pair 1 + 1) times the VUI tick, field_q3 =
//                 720000 * num_units_in_tick / time_scale eighth-ticks (C-1), by a 24-step
//                 serial division (~30 cycles against a 16.7 ms refresh). No VUI timing:
//                 12012 (59.94) and flag 1; a tick over 2^24 eighth-ticks (23 s) or a
//                 time_scale of 0: clamped / 12012 and flag 2; a pic_struct that does not
//                 fit the store (1/2 on a frame, 0/3-8 on a field, 9-15): the default and
//                 flag 4. A pair tagged only on its second field: PTS - one tick.
//   the refresh   line 499 dot 0: eval (the scheduler decides with that cycle's STC);
//                 line 500 dot 0: the pickup -- a due head is taken (rec_take), the store
//                 shown until then released (rel_*: its last line was fetched at line 478,
//                 line 0's comes at 523), the new store latched for the reader (sh_*).
//                 The END record is taken the same way; the last store stays, held.
//   the parity    a field store shows field first_bot ^ (refreshes since its pickup)[0];
//                 a single field its own (sh_single: the reader bobs it in every mode);
//                 a frame 0. (P5f's Bob keeps it; the future 480i raster needs the same.)
//   instruments   dc: the decided (store, parity) changes -- disp_reader counts the ones
//                 it FETCHED, independently (the judder gate: equal); reanchors; late
//                 pickups; starved refreshes; cadence errors (a store held for a refresh
//                 count outside {floor, ceil} of its duration / one refresh, judged at the
//                 next contiguous pickup); flags; the last lag in ms.
//   the transport (P6b3, docs/transport.md S2.1-S2.3; umd/player_ctl.sv drives it):
//     freeze   pause, and a seek's hold. Sampled at each refresh's eval (line 499): a
//              frozen refresh has no eval and no pickup, the shown store's parity does not
//              step, and the STC does not count (the tick is gated from that eval to the
//              next). `frz` is that refresh-aligned level -- the audio gate freezes on the
//              SAME cycles, so the STC and the sample clock stop and restart together.
//     resync   a seek's discontinuity (a level, held through the pipeline's flush): every
//              queued record is taken and released unseen (the drain), the preparation and
//              the scheduler are cleared (it anchors afresh), and the shown store stays up,
//              held. Its rising edge arms the WAIT: no head is considered until the
//              landing's target arrives.
//     the ITEMS (P6b3i, D8): every record carries its playlist item's tag, the item index
//              mod 4 (rec_ep: a PTS-carrying picture's own; a picture without a PTS inherits
//              the current one). player_ctl writes a 4-entry table (ep_*) at every item start
//              and at a seek's landing: {IN or the seek's target, OUT, last, skip}. A head
//              whose tag differs from the current one ENTERS a new item: it waits (`waiting`)
//              until that item's entry is valid, then the item's target and OUT apply:
//     the target  with skip, a record whose interval [t, t + duration) ends at or before
//              the entry's IN is taken and released unseen (the skip-until of D2 -- a
//              chapter opens on its mark's picture; every item opens at its IN). "At or
//              before" with one tick of tolerance: see d_skip. t is the record's PTS, else
//              the last skipped record's end (the pictures between PTS-carrying ones have
//              none); the first record shown is given its t as a PTS, so it anchors the STC
//              where it belongs. A record with no t to judge ends the skip and is shown.
//              The END reached inside a skip (a target past every picture: an OUT far past
//              the title's content) is taken and the display ends, the shown store kept --
//              never a skip waiting for ever (fix/skip-last-picture, docs/display.md S11).
//     OUT      a record whose time is at or after its item's OUT is taken and released
//              unseen; on the title's LAST item the display ends there (ended, out_hit),
//              the last store held, else the next item's records follow. Its time: its
//              PTS, else the timeline's.
//              A resync's rising edge clears the table (a write during the drain survives).
//     sh_pts   the shown store's time (the scheduler's want at its pickup): player_ctl's
//              key for the chapter queries.
//   480i (`il`, docs/analog.md S2): a refresh is a FIELD. The eval and the pickup sit in each
//              field's blanking at field line 249 / 250, at dot 0 on the short field and at the
//              half-line (dot 858 of 1716) on the long one, so they stay exactly 450,450 cycles
//              apart (the fork's placement, MiSTer_h264_decoder c3c364b) and the model holds
//              unchanged. A change of `il` drops the alignment (the raster restarts); it is
//              found again at the next top field's first dot.
//     field order (V6): a pickup of a field PAIR whose first field's parity differs from the
//              raster field about to start is DEFERRED one refresh (the shown store is held one
//              more field; n_pdefer counts it). The scheduler is not told (its `pickup` is
//              `pick`), so it evaluates the same head at the next refresh: an anchoring head
//              anchors there, a field later, and the timeline is in phase from then on. A
//              LATE head (a starve's backlog) is taken at once, so the queue still catches up.
//              Frames and single fields are never deferred. The freeze is sampled only at a
//              top field's eval: a pause spans whole frames and keeps the phase.
//
//   FIELD MATCHING (Forgejo fj#80, docs/telecine.md S5; 480p): umd/film_lock.sv, stepped at every
//              pickup, decides per refresh whether the shown field is woven with a neighbouring
//              store's other field. The PARTNERS: the previous store, HELD one pickup longer --
//              a field pair taken after a field pair of the same field order, size and item
//              (np) keeps the outgoing store as `prev` instead of releasing it, and releases the
//              one it held (a second release in one cycle waits a cycle in rel_pend) -- and the
//              queue's head (next_ok: a prepared
//              pair of the same kind in the current item, not skipped, not past OUT, so nothing
//              takes it before the next pickup). The evidence is disp_reader's comb sums of the
//              refresh just shown (cm_*). Its choice reaches the reader a cycle after the pickup
//              (sh_match / sh_pstore / sh_film; long before line 0's request at line 523) and is
//              cleared by a resync (the shown store stays up, in-store) and at 480i. A resync
//              (or the 480i raster) drops the hold, and its drain takes the head; a line the
//              reader requested in that very cycle may still fetch from either, so both are
//              released at that refresh's pickup (line 500: rp0 the held store, rp1 the drained
//              head when it was the NEXT partner), never before -- the reader has nothing in
//              flight between line 479 and line 523. One slot each: a second deferral before the
//              first is released needs a second resync within two cycles of a pickup that
//              picked after the first (the drained queue refills first) -- not a seek's shape.
//
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none
`include "umd/field_polarity.vh"

module disp_ctl (
    input  wire         clk,               // clk_sys
    input  wire         rst_n,             // the per-mount reset (fe_rst_n)
    input  wire  [11:0] h_pos,             // the dot (480i: 0..1715)
    input  wire  [11:0] v_pos,             // the frame line (480i: {field line, parity})
    input  wire         il,                // the 480i raster (docs/analog.md)
    // the queue's head (umd/recon_out.sv)
    input  wire         rec_valid,
    output logic        rec_take,
    input  wire         rec_end,
    input  wire  [4:0]  rec_store,
    input  wire         rec_frame,
    input  wire         rec_unpaired,
    input  wire         rec_first_bot,
    input  wire         rec_dec_t,
    input  wire         rec_dec_b,
    input  wire  [7:0]  rec_w_mbs,
    input  wire  [7:0]  rec_hf_mbs,
    input  wire  [39:0] rec_aspect,
    input  wire         rec_timing_v,
    input  wire  [31:0] rec_nuit,
    input  wire  [31:0] rec_ts,
    input  wire  [3:0]  rec_ps_a,
    input  wire         rec_ps_a_v,
    input  wire  [3:0]  rec_ps_b,
    input  wire         rec_ps_b_v,
    input  wire  [32:0] rec_pts,
    input  wire         rec_pts_v,
    input  wire  [32:0] rec_pts_b,
    input  wire         rec_pts_b_v,
    output logic        rel_valid,
    output logic [4:0]  rel_store,
    // the shown store, for disp_reader (latched at line 500)
    output logic        sh_valid,
    output logic        sh_field,
    output logic [4:0]  sh_store,
    output logic [7:0]  sh_w,
    output logic [7:0]  sh_hf,
    output logic        sh_parity,
    output logic        sh_single,         // the shown store is ONE field (unpaired)
    output logic [39:0] sh_aspect,
    // instruments
    output logic [31:0] n_dc,
    output logic [31:0] n_pick,
    output logic [7:0]  n_reanchor,
    output logic [3:0]  n_lone,            // lone PTS disbelieved (saturating; display.md S10)
    output logic [15:0] n_late,
    output logic [15:0] n_starve,
    output logic [15:0] n_cadence,
    output logic [2:0]  flags,
    output logic signed [15:0] lag_ms,
    output logic [32:0] stc,
    output logic        stc_run,           // P6: the STC is anchored and counting (the audio gate's clock)
    output logic        ended,
    // the transport (P6b3; above)
    input  wire         freeze,
    output logic        frz,               // the refresh-aligned freeze (aud_out's)
    input  wire         resync,
    input  wire         rec_ep_v,          // the head record's item tag (P6b3i): valid when it
    input  wire  [1:0]  rec_ep,            //   carries a PTS (recon_out)
    input  wire         ep_we,             // the item table (player_ctl): an entry written
    input  wire  [1:0]  ep_wi,
    input  wire  [32:0] ep_in,             //   IN, or a seek's target
    input  wire  [32:0] ep_out,            //   OUT
    input  wire         ep_last,           //   the title's last item: OUT ends the display
    input  wire         ep_skip,           //   0: show from the first record (no target)
    output logic [32:0] sh_pts,
    output logic        sh_pts_v,
    output logic [1:0]  sh_ep,             // the shown store's item tag
    output logic [3:0]  left_mask,         // P6b3i: the item tags the display has left (aud_out)
    output wire         vid_stalled,       // P6b3i: 64 starved refreshes in a row (aud_out's breaker)
    output logic        waiting,           // the head enters an item whose entry is not written
    output logic        skipping,          // dropping records before the target
    output logic        out_hit,           // the stop at OUT ended the display (until a resync)
    output logic [15:0] n_pdefer,          // 480i: pickups deferred a field for field order (V6)
    output logic [15:0] n_skip,            // records skipped before a target (wrapping)
    output logic [15:0] n_drain,           // records drained by a resync (wrapping)
    // fj#80 field matching (above)
    input  wire  [24:0] cm_c,              // disp_reader's comb sums of the refresh just shown
    input  wire  [23:0] cm_r,
    input  wire         cm_v,
    output logic        sh_match,          // the reader weaves pic_pstore's other field
    output logic [4:0]  sh_pstore,
    output logic [1:0]  sh_film,           // 0 the menu's kernel, 1 woven, 2 bobbed
    output wire         fl_locked,
    output wire  [2:0]  fl_slot,
    output wire  [3:0]  fl_conf,
    output logic [15:0] n_flost            // locks lost (a break, a pair break; wrapping)
);

    // ---- the tick, phased to the raster ------------------------------------------------------
    logic       aligned, il_q;
    logic [8:0] tdiv;
    wire        tick = aligned && (tdiv == 9'd0);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aligned <= 1'b0; tdiv <= '0; il_q <= 1'b0;
        end else begin
            il_q <= il;
            if (il != il_q) aligned <= 1'b0;   // the raster restarts: align again
            else if (!aligned) begin
                if (h_pos == 12'd0 && v_pos == 12'd0) begin aligned <= 1'b1; tdiv <= 9'd1; end
            end else tdiv <= (tdiv == 9'd299) ? 9'd0 : tdiv + 9'd1;
        end
    end
    // the events: 480p lines 499 / 500 at dot 0; 480i field lines 249 / 250 (see the header)
    wire [10:0] fl      = v_pos[11:1];
    wire        f_short = (v_pos[0] == `FIELD1_VPOS);
    wire ev_at = il ? (fl == 11'd249 && h_pos == (f_short ? 12'd0 : 12'd858))
                    : (v_pos == 12'd499 && h_pos == 12'd0);
    wire pk_at = il ? (f_short ? (fl == 11'd249 && h_pos == 12'd858) : (fl == 11'd250 && h_pos == 12'd0))
                    : (v_pos == 12'd500 && h_pos == 12'd0);
    wire ev_raw   = aligned && (il == il_q) && ev_at;
    wire pk_raw   = aligned && (il == il_q) && pk_at;
    // the freeze, refresh-aligned: sampled at the eval, held until the next one
    // (480i: only at a top field's eval -- v_pos even -- so a pause spans whole frames and the
    // timeline's phase to the raster survives it: V6)
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n)      frz <= 1'b0;
        else if (ev_raw && !(il && v_pos[0])) frz <= freeze;
    wire ev_pulse = ev_raw && !(il && v_pos[0] ? frz : freeze);
    wire pk_pulse = pk_raw && !frz;
    wire tick_g   = tick && !frz;
    logic resync_q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) resync_q <= 1'b0;
        else        resync_q <= resync;
    wire resync_rise = resync && !resync_q;

    // ---- preparation: the head's tick (field_q3), its duration, its PTS -----------------------
    // states: 0 idle (nothing, END, or prepared), 1 the range check, 2 the 24 division
    // steps, 26 the quotient, 27 the duration and PTS -- then prep until the take
    logic [4:0]  pst;
    logic [51:0] num;
    logic [32:0] rem;
    logic [23:0] quo;
    logic [4:0]  dstep;
    logic [23:0] fq;                       // field_q3 of the head
    logic [2:0]  hflag;
    logic        prep;                     // the head is prepared
    logic [26:0] dur_q3;
    logic [32:0] pts_eff;
    logic        tag;
    logic [2:0]  nt;
    logic        ps_err;
    // Table E-6 (a head that is not END)
    always_comb begin
        ps_err = 1'b0;
        if (rec_frame) begin
            nt = 3'd2;
            if (rec_ps_a_v) begin
                case (rec_ps_a)
                    4'd0, 4'd3, 4'd4: nt = 3'd2;
                    4'd5, 4'd6:       nt = 3'd3;
                    4'd7:             nt = 3'd4;
                    4'd8:             nt = 3'd6;
                    default:          begin nt = 3'd2; ps_err = 1'b1; end
                endcase
            end
        end else begin
            nt = rec_unpaired ? 3'd1 : 3'd2;
            if (rec_ps_a_v && !(rec_ps_a == 4'd1 || rec_ps_a == 4'd2)) ps_err = 1'b1;
            if (!rec_unpaired && rec_ps_b_v && !(rec_ps_b == 4'd1 || rec_ps_b == 4'd2)) ps_err = 1'b1;
        end
    end
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pst <= '0; num <= '0; rem <= '0; quo <= '0; dstep <= '0; fq <= 24'd12012; hflag <= '0; prep <= 1'b0;
            dur_q3 <= '0; pts_eff <= '0; tag <= 1'b0;
        end else begin
            case (pst)
                5'd0: if (rec_valid && !rec_end && !prep && !rec_take && !resync) begin
                    num <= rec_nuit * 20'd720000;
                    pst <= 5'd1;
                end
                5'd1: begin
                    // the quotient must fit 24 bits: num < ts << 24
                    if (!rec_timing_v) begin fq <= 24'd12012; hflag <= 3'd1; pst <= 5'd27; end
                    else if (rec_ts == 32'd0 || num >= {rec_ts, 24'd0}) begin
                        fq <= (rec_ts == 32'd0) ? 24'd12012 : 24'hFFFFFF; hflag <= 3'd2; pst <= 5'd27;
                    end else begin
                        rem <= {5'd0, num[51:24]}; quo <= '0; dstep <= 5'd23; hflag <= 3'd0; pst <= 5'd2;
                    end
                end
                5'd2: begin : divide
                    logic [32:0] t;
                    t = {rem[31:0], num[dstep]};
                    if (t >= {1'b0, rec_ts}) begin rem <= t - {1'b0, rec_ts}; quo[dstep] <= 1'b1; end
                    else rem <= t;
                    if (dstep == 5'd0) pst <= 5'd26; else dstep <= dstep - 5'd1;
                end
                5'd26: begin
                    if (quo == 24'd0) begin fq <= 24'd12012; hflag <= 3'd2; end
                    else fq <= quo;
                    pst <= 5'd27;
                end
                5'd27: begin
                    // the duration (nt x fq: shifts and adds), the effective PTS
                    case (nt)
                        3'd1:    dur_q3 <= {3'd0, fq};
                        3'd3:    dur_q3 <= {2'd0, fq, 1'b0} + {3'd0, fq};
                        3'd4:    dur_q3 <= {1'd0, fq, 2'b0};
                        3'd6:    dur_q3 <= {1'd0, fq, 2'b0} + {2'd0, fq, 1'b0};
                        default: dur_q3 <= {2'd0, fq, 1'b0};
                    endcase
                    if (rec_pts_v) begin tag <= 1'b1; pts_eff <= rec_pts; end
                    else if (rec_pts_b_v && !rec_frame && !rec_unpaired) begin
                        tag <= 1'b1; pts_eff <= rec_pts_b - {12'd0, fq[23:3]};
                    end else begin tag <= 1'b0; pts_eff <= '0; end
                    hflag <= hflag | (ps_err ? 3'd4 : 3'd0);
                    prep <= 1'b1;
                    pst <= 5'd0;
                end
                default: pst <= 5'd0;
            endcase
            if (rec_take) prep <= 1'b0;
            if (resync) begin pst <= 5'd0; prep <= 1'b0; end
        end
    end

    // ---- the scheduler -----------------------------------------------------------------------
    logic ev_head, ev_end;                 // what the eval saw at the head
    logic due, anchor_now, late, contig, next_due, anchored, next_valid, lone;
    logic signed [33:0] disp_lag;
    logic pick;                            // the pickup takes the head
    logic        tag_ovr;                  // the skip's first shown record: its time as a PTS
    logic [32:0] ovr_pts;
    logic [32:0] want, nx_pts;
    // ---- the items (P6b3i): the table, the current item, the head's tag -----------------------
    logic [3:0]  t_v, t_last, t_skip;
    logic [32:0] t_in [0:3];
    logic [32:0] t_out [0:3];
    logic [1:0]  cur_ep;
    logic        cur_v;
    logic [6:0]  starve_run;               // starved refreshes in a row (saturating at 64)
    assign vid_stalled = starve_run[6];
    wire  [1:0]  h_ep     = rec_ep_v ? rec_ep : cur_ep;            // an untagged picture inherits
    wire         h_ep_v   = rec_ep_v || cur_v;
    // the head enters a new item (its tag differs, or none is current after a resync)
    wire         need_ent = rec_valid && !rec_end && h_ep_v && (!cur_v || h_ep != cur_ep);
    wire         wait_now = need_ent && !t_v[h_ep];
    // the head, as the scheduler sees it: prepared, in the current item, not being skipped
    wire head_ok = rec_valid && !rec_end && prep && !ended && !need_ent && !skipping;
    wire         h_tag = tag || tag_ovr;
    wire  [32:0] h_pts = tag_ovr ? ovr_pts : pts_eff;
    disp_sched u_sched (
        .clk(clk), .rst_n(rst_n), .clr(resync), .tick(tick_g), .eval(ev_pulse), .pickup(pick),
        .head_valid(head_ok), .head_tag(h_tag), .head_pts(h_pts),
        .head_dur_q3(dur_q3), .head_frame_t({1'b0, fq[23:2]}),
        .due(due), .anchor_now(anchor_now), .late(late), .contig(contig), .next_due(next_due), .lone(lone),
        .stc(stc), .anchored(anchored), .next_valid(next_valid), .disp_lag(disp_lag),
        .want(want), .next_pts(nx_pts));
    // V6 (480i): a pair whose first field is not the parity of the raster field that starts
    // after this pickup (the next field: ~v_pos[0]) waits one refresh
    wire   pdefer = il && pk_pulse && ev_head && due && !late && head_ok && !rec_take &&
                    !rec_frame && !rec_unpaired && (rec_first_bot == v_pos[0]);
    assign pick = pk_pulse && ev_head && due && head_ok && !rec_take && !pdefer;
    assign stc_run = anchored;

    // ---- the refresh: take, release, latch, count ---------------------------------------------
    logic [15:0] idx;                      // refreshes since the shown store's pickup
    logic        cur_pair, cur_first_bot, cur_single_bot;
    logic [27:0] c_lo, c_hi;               // idx x R and (idx + 2) x R: the cadence window
    // the last pickup's lag (want - STC) in ms: ticks x 728 / 65536 (1 / 90.02)
    logic signed [45:0] lag_p;
    always_ff @(posedge clk) begin
        lag_p  <= disp_lag * 46'sd728;
        lag_ms <= lag_p[31:16];
    end
    logic [26:0] cur_dur;
    logic        starved, have_cur;
    localparam [27:0] R_Q3 = 28'd12012;

    // ---- the transport's judgements on the prepared head (P6b3) --------------------------------
    // x_q3: the end of the last skipped record, the time of the next untagged one
    logic [35:0] x_q3;
    logic        x_v;
    wire  [32:0] tgt      = t_in[cur_ep];
    wire  [32:0] stop_pts = t_out[cur_ep];
    // (a skipped run is timed in eighth-ticks: the fraction of 1501.5 ticks a refresh is kept)
    wire  [35:0] est_q3  = tag ? {pts_eff, 3'b000} : (skipping ? x_q3 : {nx_pts, 3'b000});
    wire  [32:0] est     = est_q3[35:3];
    wire         est_v   = tag || (skipping ? x_v : next_valid);
    wire  [35:0] est_end = est_q3 + {9'd0, dur_q3};
    // < 8 (one tick): the record is before the target (a stream stores its PTS in whole
    // ticks, the extrapolated time keeps the fraction: a mark at a picture's stored PTS must
    // not leave the picture before it on screen)
    wire signed [35:0] d_skip = $signed(est_end - {tgt, 3'b000});
    wire signed [33:0] d_stop = $signed({1'b0, est}) - $signed({1'b0, stop_pts});
    // (never a head the eval chose, between the eval and its pickup: ev_pend)
    logic  ev_pend;
    wire   judge      = rec_valid && !rec_end && prep && !rec_take && !resync && !ev_pend && !pk_raw;
    wire   enter      = judge && need_ent && t_v[h_ep];
    wire   in_item    = judge && !need_ent;
    wire   skip_drop  = in_item && skipping && est_v && (d_skip < 36'sd8);
    wire   skip_end   = in_item && skipping && !(est_v && (d_skip < 36'sd8));
    wire   stop_drop  = in_item && !skipping && !ended && cur_v && t_v[cur_ep] && est_v && (d_stop >= 34'sd0);
    // taken unseen: the drain, a skipped record, the stop at OUT, anything after the display ended
    // the END inside a skip: taken, the display ended (judged as a record is)
    wire   skip_eos   = rec_valid && rec_end && skipping && !rec_take && !resync && !ev_pend && !pk_raw;
    wire   drain_take = resync && rec_valid && !rec_take;
    wire   after_end  = !resync && ended && rec_valid && !rec_take && !pk_pulse;

    // ---- fj#80: field matching (see the header) ---------------------------------------------------
    logic        prev_v, rel_pend, fl_q, fl_was;
    logic [4:0]  prev_st, rel_pst, nx_st;
    logic        sh_next;                          // the shown refresh weaves the queue's head
    logic        rp0_v, rp1_v, rp_go, nxp_v;       // the releases a resync defers to the pickup
    logic [4:0]  rp0, rp1, nxp_st;
    // the head continues the shown pairs: the same field order, size and item
    wire   same_kind = !rec_frame && !rec_unpaired && (rec_first_bot == cur_first_bot) &&
                       (rec_w_mbs == sh_w) && (rec_hf_mbs == sh_hf);
    wire   np_now    = have_cur && cur_pair && same_kind && (cur_ep == sh_ep) && !il;
    // the head as the next store's partner: nothing takes it before the next pickup
    wire   stop_now  = cur_v && t_v[cur_ep] && est_v && (d_stop >= 34'sd0);
    wire   nx_ok     = rec_valid && !rec_end && !rec_take && prep && !need_ent && !skipping && !ended &&
                       !stop_now && !resync && same_kind;
    wire   fl_step   = pk_pulse && !il;
    wire   fl_first  = pick || idx[0];             // the coming refresh shows the first field
    wire   fl_prev   = pick ? np_now : prev_v;
    wire  [11:0] fl_lines = ({sh_hf, 4'd0} > 12'd480) ? 12'd480 : {sh_hf, 4'd0};
    wire  [19:0] fl_npix  = {8'd0, fl_lines} * {11'd0, sh_w, 1'b0};
    wire  [2:0]  fl_show;
    film_lock u_film (
        .clk(clk), .rst_n(rst_n), .clr(resync || il), .step(fl_step), .pick(pick), .np(np_now),
        .first(fl_first), .prev_ok(fl_prev), .next_ok(nx_ok), .mv(cm_v), .mc(cm_c), .mr(cm_r), .npix(fl_npix),
        .show(fl_show), .locked(fl_locked), .slot(fl_slot), .conf(fl_conf));
    // a release this cycle besides the pending one (that waits)
    wire   rel_busy  = drain_take || skip_drop || stop_drop || after_end || (pk_pulse && pick && have_cur);
    // the drain reaches the head the reader may still be fetching as the NEXT partner
    // (in the resync's first cycle the shown refresh's own choice: the drain may take the head then)
    wire         nxp_now_v = resync_rise ? (sh_match && sh_next) : nxp_v;
    wire  [4:0]  nxp_now   = resync_rise ? sh_pstore : nxp_st;
    wire   drain_nxp = drain_take && nxp_now_v && (rec_store == nxp_now);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rec_take <= 1'b0; rel_valid <= 1'b0; rel_store <= '0;
            sh_valid <= 1'b0; sh_field <= 1'b0; sh_store <= '0; sh_w <= '0; sh_hf <= '0; sh_parity <= 1'b0; sh_single <= 1'b0;
            sh_aspect <= '0; ev_head <= 1'b0; ev_end <= 1'b0; ended <= 1'b0;
            idx <= '0; cur_pair <= 1'b0; cur_first_bot <= 1'b0; cur_single_bot <= 1'b0; c_lo <= '0; c_hi <= '0;
            cur_dur <= '0; starved <= 1'b0; have_cur <= 1'b0;
            n_dc <= '0; n_pick <= '0; n_reanchor <= '0; n_late <= '0; n_starve <= '0; n_cadence <= '0; n_lone <= '0;
            flags <= '0;
            sh_pts <= '0; sh_pts_v <= 1'b0; sh_ep <= '0; waiting <= 1'b0; skipping <= 1'b0; out_hit <= 1'b0;
            n_skip <= '0; n_drain <= '0; ev_pend <= 1'b0; n_pdefer <= '0;
            prev_v <= 1'b0; rel_pend <= 1'b0; fl_q <= 1'b0; prev_st <= '0; rel_pst <= '0; nx_st <= '0;
            sh_next <= 1'b0; rp0_v <= 1'b0; rp1_v <= 1'b0; rp_go <= 1'b0; nxp_v <= 1'b0; rp0 <= '0; rp1 <= '0; nxp_st <= '0;
            sh_match <= 1'b0; sh_pstore <= '0; sh_film <= 2'd0; n_flost <= '0; fl_was <= 1'b0;
            // the table starts all valid with no skip and no OUT: a mount's pictures never
            // wait for player_ctl (which writes item 0's entry at its item start, first)
            t_v <= 4'hF; t_last <= '0; t_skip <= '0; cur_ep <= '0; cur_v <= 1'b0; left_mask <= '0; starve_run <= '0;
            for (int i = 0; i < 4; i++) begin t_in[i] <= '0; t_out[i] <= '1; end x_q3 <= '0; x_v <= 1'b0; tag_ovr <= 1'b0; ovr_pts <= '0;
        end else begin
            rec_take <= 1'b0; rel_valid <= 1'b0;
            if (pk_raw) ev_pend <= 1'b0;
            if (pdefer) n_pdefer <= n_pdefer + 16'd1;
            if (ev_pulse) begin
                ev_pend <= head_ok;
                ev_head <= head_ok;
                ev_end  <= rec_valid && rec_end && !ended && !skipping;
            end
            // ---- the transport (P6b3) ----
            if (drain_take || skip_drop || stop_drop || after_end) begin
                rec_take <= 1'b1;
                if (!rec_end && !drain_nxp) begin rel_valid <= 1'b1; rel_store <= rec_store; end
            end
            // fj#80: the drained NEXT partner, released at the pickup (rp1)
            if (drain_nxp) begin rp1_v <= 1'b1; rp1 <= rec_store; nxp_v <= 1'b0; end
            if (skip_eos) begin rec_take <= 1'b1; ended <= 1'b1; skipping <= 1'b0; end
            if (drain_take) n_drain <= n_drain + 16'd1;
            if (skip_drop) begin
                n_skip <= n_skip + 16'd1;
                x_q3   <= est_end; x_v <= 1'b1;
            end
            if (skip_end) begin
                skipping <= 1'b0;
                if (!tag && est_v) begin tag_ovr <= 1'b1; ovr_pts <= est; end
            end
            // OUT: the records after it are dropped; on the last item the display ends
            if (stop_drop) begin
                n_skip <= n_skip + 16'd1;
                if (t_last[cur_ep]) begin ended <= 1'b1; out_hit <= 1'b1; end
            end
            // a new item: its entry's target applies from the next judgement
            waiting <= wait_now;
            if (enter) begin
                cur_ep <= h_ep; cur_v <= 1'b1; skipping <= t_skip[h_ep]; x_v <= 1'b0; tag_ovr <= 1'b0;
                // the item left behind: its audio leftovers are dropped (aud_out)
                if (cur_v) left_mask[cur_ep] <= 1'b1;
                left_mask[h_ep] <= 1'b0;
            end
            if (resync_rise) begin
                t_v <= '0; cur_v <= 1'b0; skipping <= 1'b0; x_v <= 1'b0; tag_ovr <= 1'b0; left_mask <= '0;
            end
            if (resync) starve_run <= '0;
            // the table (after the resync's clear: a write in that cycle survives); a rewrite
            // of the current item without a skip (the watchdog's) ends its skip
            if (ep_we) begin
                t_v[ep_wi] <= 1'b1; t_in[ep_wi] <= ep_in; t_out[ep_wi] <= ep_out;
                t_last[ep_wi] <= ep_last; t_skip[ep_wi] <= ep_skip;
                left_mask[ep_wi] <= 1'b0;             // a new item on that tag (item_hold: the old one is gone)
                if (!ep_skip && cur_v && ep_wi == cur_ep && !resync_rise) skipping <= 1'b0;
            end
            if (resync) begin
                ended <= 1'b0; out_hit <= 1'b0; starved <= 1'b0; ev_head <= 1'b0; ev_end <= 1'b0; ev_pend <= 1'b0;
            end
            if (pk_pulse) begin
                if (ev_end) begin
                    rec_take <= 1'b1; ended <= 1'b1;
                end
                if (pick) begin
                    rec_take <= 1'b1;
                    tag_ovr  <= 1'b0;
                    sh_pts   <= want; sh_pts_v <= 1'b1; sh_ep <= cur_ep;
                    n_pick <= n_pick + 32'd1;
                    n_dc   <= n_dc + 32'd1;
                    // the previous store's cadence, judged at a contiguous pickup
                    if (have_cur && !anchor_now && !starved && contig &&
                        !(({1'b0, cur_dur} > c_lo) && ({1'b0, cur_dur} < c_hi)))
                        n_cadence <= n_cadence + 16'd1;
                    if (late) n_late <= n_late + 16'd1;
                    if (anchor_now && n_reanchor != 8'hFF) n_reanchor <= n_reanchor + 8'd1;
                    if (lone && n_lone != 4'hF) n_lone <= n_lone + 4'd1;
                    flags <= flags | hflag;
                    // fj#80: the outgoing store held as the next one's partner (np), else released
                    if (have_cur) begin
                        if (np_now) begin
                            prev_v <= 1'b1; prev_st <= sh_store;
                            if (prev_v) begin rel_valid <= 1'b1; rel_store <= prev_st; end
                        end else begin
                            rel_valid <= 1'b1; rel_store <= sh_store;
                            if (prev_v) begin rel_pend <= 1'b1; rel_pst <= prev_st; prev_v <= 1'b0; end
                        end
                    end
                    have_cur <= 1'b1;
                    sh_valid <= 1'b1; sh_field <= !rec_frame; sh_store <= rec_store; sh_w <= rec_w_mbs;
                    sh_hf <= rec_hf_mbs; sh_aspect <= rec_aspect;
                    cur_pair <= !rec_frame && !rec_unpaired; cur_first_bot <= rec_first_bot;
                    cur_single_bot <= rec_dec_b && !rec_dec_t;
                    sh_parity <= rec_frame ? 1'b0 : rec_unpaired ? (rec_dec_b && !rec_dec_t) : rec_first_bot;
                    sh_single <= !rec_frame && rec_unpaired;
                    cur_dur <= dur_q3;
                    idx <= '0; c_lo <= '0; c_hi <= R_Q3 + R_Q3;
                    starved <= 1'b0; starve_run <= '0;
                end else begin
                    if (have_cur) begin
                        idx <= idx + 16'd1;
                        c_lo <= c_lo + R_Q3; c_hi <= c_hi + R_Q3;
                        if (cur_pair) begin
                            n_dc <= n_dc + 32'd1;
                            sh_parity <= cur_first_bot ^ !idx[0];     // (idx + 1)[0]
                        end
                    end
                    // starved: no head at the eval while the timeline was due (the END
                    // record's refresh is the title's end, not a starve)
                    if (!ev_head && !ev_end && !ended && next_due) begin
                        starved <= 1'b1; n_starve <= n_starve + 16'd1;
                        if (!starve_run[6]) starve_run <= starve_run + 7'd1;
                    end
                end
            end
            // ---- fj#80: the lock's choice, a cycle after the pickup; the hold's drop ----
            fl_q <= fl_step;
            if (fl_step) nx_st <= rec_store;
            if (fl_q) begin
                sh_match  <= (fl_show == 3'd2) || (fl_show == 3'd3);
                sh_next   <= (fl_show == 3'd3);
                sh_pstore <= (fl_show == 3'd2) ? prev_st : nx_st;
                sh_film   <= (fl_show == 3'd1 || fl_show == 3'd2 || fl_show == 3'd3) ? 2'd1 :
                             (fl_show == 3'd4) ? 2'd2 : 2'd0;
            end
            if (fl_step) fl_was <= fl_locked;
            if (fl_q && fl_was && !fl_locked) n_flost <= n_flost + 16'd1;
            if (resync || il) begin sh_match <= 1'b0; sh_next <= 1'b0; sh_film <= 2'd0; end
            // a resync drops the hold and marks the NEXT partner for its drain; the 480i raster
            // drops the hold: both released at the next pickup (see the header)
            if (resync_rise || (il && prev_v)) begin
                if (prev_v) begin rp0_v <= 1'b1; rp0 <= prev_st; prev_v <= 1'b0; end
                if (resync_rise) begin nxp_v <= sh_match && sh_next && !drain_nxp; nxp_st <= sh_pstore; end
            end
            if (pk_raw && (rp0_v || rp1_v)) rp_go <= 1'b1;
            if (pk_raw) nxp_v <= 1'b0;
            // the release that waited (a second one in a pickup), then the deferred ones
            if (!rel_busy) begin
                if (rel_pend) begin rel_valid <= 1'b1; rel_store <= rel_pst; rel_pend <= 1'b0; end
                else if (rp_go && rp0_v) begin
                    rel_valid <= 1'b1; rel_store <= rp0; rp0_v <= 1'b0;
                    if (!rp1_v) rp_go <= 1'b0;
                end else if (rp_go && rp1_v) begin rel_valid <= 1'b1; rel_store <= rp1; rp1_v <= 1'b0; rp_go <= 1'b0; end
            end
        end
    end

endmodule

`default_nettype wire
