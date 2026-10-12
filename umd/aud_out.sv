// umd/aud_out.sv -- the PCM side of the audio path: the decoder's stereo pairs into a
// FIFO, out at 48 kHz, started and kept in step with the display's STC
// (docs/at3p_decoder.md S7). Harvested in spirit from MiSTer_DVD's dvd_audio_decode
// (the drain gate, the underrun re-arm, the fallback release), with its history removed:
// no NCO trim, no provisional anchor, no catch-up heuristics -- the STC here is the
// display's own clock on clk_sys (umd/disp_sched.sv), and every PCM frame carries its PTS.
//
// THE CLOCKS. The STC ticks at clk_sys / 300 (90 kHz); the sample tick here is EXACTLY
// clk_sys * 2 / 1125 (48 kHz: an 11-bit accumulator stepping by 2, wrapping at 1125).
// One crystal, an exact ratio: once a pair is started at its PTS, sample continuity
// keeps every later pair at its PTS (1.875 ticks a pair) with nothing to slew.
//
// THE TAGS. aud_ring tags every access unit; the decoder makes exactly one 2,048-pair
// PCM frame of each. The first pair of each frame written here pops one tag into a
// four-entry frame queue (the FIFO holds at most three frames in part), so the head pair
// always knows its time: pos = PTS * 8 + 15 * index, in eighth-ticks (q3).
//
// THE GATE (ARM / RUN). ARM holds the output (the last sample) and decides on the head:
//   * the STC runs and the head is tagged: d = STC * 8 - pos.
//       d >= 15  the head pair is wholly past: discard it (stale; a pair a cycle or two);
//       0 <= d < 15  the STC is inside the head pair: RUN (the release) -- once a whole
//                frame (MIN_FILL pairs) is buffered behind the head, or the decoder has
//                written nothing for 2**DRY_W cycles (~155 ms: its source is dry or the
//                title ended, so a tail still plays). Until then the STC runs on and the
//                head keeps going stale pair by pair while the decoder (1.6-1.8x real
//                time) builds the buffer: one clean start, not play / underrun / restart
//                (found by run_av_sync.sh: a release on a part-frame underran ~0.5 s later);
//       d < 0    early: wait (the STC runs, so this resolves itself).
//     So the first pair plays within one pair of its PTS, not within one AU (42.7 ms).
//   * the STC does not run yet (no picture shown since the mount) and the ring is
//     blocking the demux with this FIFO full: discard the head pair (pre-anchor). THE
//     DEADLOCK RULE: the demux is shared, the first picture that starts the STC may sit
//     behind audio the ring cannot take, and a held gate cannot drain -- so while the
//     clock is not running, audio yields from its STALE end (the earliest audio, which
//     is the audio a late anchor would discard anyway). Counted.
//   * the head cannot be judged (no STC, or no PTS ever seen) for 2**FB_W cycles
//     (~2.5 s): RUN anyway (fallback, counted); an underrun re-arms and tries again.
// RUN pops one pair at each sample tick. The first pair of every tagged frame is
// checked against the STC first: |d| > 50 ms (the display re-anchored, or the audio
// stream jumped) re-arms on that pair, WITHOUT playing it; otherwise d is recorded
// (the lip-sync instrument: it is measured, never re-based on a re-anchor -- MiSTer_DVD
// once did, and its instrument could no longer show the error it existed for). A tick
// with the FIFO empty is an underrun: re-arm.
//
// ITEMS (P6b3i, docs/transport.md S9): every frame carries its playlist item's tag (from the
// ring). left_mask (disp_ctl) names the items the display has LEFT: a frame of one is an
// old timeline's leftover -- its picture is gone -- and is discarded at once, counted
// (n_left); one reaching RUN re-arms first. Found on the rig (My Chemical Romance disc 2):
// item 0's audio past its OUT sat at the head, 53 s "early" on item 1's clock, the gate
// waited, the ring blocked the demux, the video starved: a hang.
// THE STALL BREAKER: the STC runs, the head is early, the ring is blocking the demux, the
// PCM FIFO is full and the display has starved a while (vid_stalled): nothing can move but
// the audio, so the gate yields it from its stale end, counted (n_yield) -- the running-STC
// sibling of the pre-anchor rule below. A hang is then impossible by construction, whatever
// put the audio early.
//
// PAUSE (P6b3, docs/transport.md S2.3): `freeze` is disp_ctl's refresh-aligned freeze --
// the level that holds the STC -- so both clocks stop and restart on the same cycles.
// While it is up the sample tick does not run (RUN holds its place: the head pair plays
// on resume), the gate decides nothing (no discard, release or fallback), and its timers
// (the dry release, the fallback) hold. The decoder still writes: the FIFO fills and then
// back-pressures. The output holds its last sample.

`default_nettype none

module aud_out #(
    parameter int AW   = 12,              // 4,096 pairs: S7 (a frame + the decode latency)
    parameter int FB_W = 26,              // the fallback release, 2**FB_W cycles
    parameter int MIN_FILL = 2048,        // pairs buffered before a release: a frame
    parameter int DRY_W = 22              // no PCM written for 2**DRY_W cycles: release anyway
) (
    input  wire          clk,
    input  wire          rst_n,           // per mount

    input  wire   [15:0] pcm_l,
    input  wire   [15:0] pcm_r,
    input  wire          pcm_valid,
    output logic         pcm_ready,

    input  wire          tag_valid,
    input  wire          tag_has,
    input  wire   [32:0] tag_pts,
    input  wire   [1:0]  tag_ep,          // P6b3i: the AU's item tag
    output logic         tag_pop,

    input  wire   [32:0] stc,
    input  wire          stc_run,         // the STC is anchored and counting
    input  wire          ring_blocked,    // aud_ring is refusing a byte the demux offers
    input  wire          freeze,          // pause: the STC's freeze (disp_ctl frz), above
    input  wire   [3:0]  left_mask,       // P6b3i: the item tags the display has left (disp_ctl)
    input  wire          vid_stalled,     // P6b3i: the display has starved a while (disp_ctl)

    output logic  [15:0] audio_l,
    output logic  [15:0] audio_r,

    output logic         running,         // RUN
    output logic  [15:0] frames_played,
    output logic   [7:0] under,           // underrun re-arms (saturating)
    output logic   [7:0] resync,          // |d| > 50 ms re-arms (saturating)
    output logic   [7:0] fallback,        // fallback releases (saturating)
    output logic   [7:0] tag_miss,        // a frame began with no tag waiting (never: a bug)
    output logic  [15:0] stale,           // pairs discarded as past (wrapping)
    output logic  [15:0] pre_drop,        // pairs discarded before the STC ran (wrapping)
    output logic signed [15:0] err_ticks, // the last frame start's STC - PTS, ticks (saturating)
    output logic         err_seen,        // err_ticks holds a measurement
    output logic         sample_tick,     // the 48 kHz tick (benches)
    output logic         play,            // a pair was played this cycle (benches)
    output logic [AW+1:0] fill,
    output logic  [15:0] n_left,          // pairs discarded as a left item's (wrapping)
    output logic  [15:0] n_yield          // pairs yielded by the stall breaker (wrapping)
);

    localparam signed [35:0] THR_Q3 = 36'sd36000;    // 50 ms = 4,500 ticks
    localparam logic [AW+1:0] MIN_FILL_W = MIN_FILL;   // sized, not a cast (Quartus 17)

    // ---- the 48 kHz tick: exactly 2 / 1125 of clk_sys ----
    logic [10:0] nco;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nco <= 11'd0; sample_tick <= 1'b0;
        end else if (freeze) begin
            sample_tick <= 1'b0;
        end else if (nco >= 11'd1123) begin
            nco <= nco - 11'd1123; sample_tick <= 1'b1;
        end else begin
            nco <= nco + 11'd2;    sample_tick <= 1'b0;
        end
    end

    // ---- the PCM FIFO and the frame tag queue ----
    logic        pcm_full, h_valid, pop;
    logic [31:0] h_pair;
    logic [10:0] widx, ridx;              // pair index within the frame, write / read side
    logic  [1:0] fq_wp, fq_rp;
    logic  [2:0] fq_n;
    logic        fq_has [0:3];
    logic [1:0]  fq_ep  [0:3];
    logic [32:0] fq_pts [0:3];

    assign pcm_ready = !pcm_full && ((widx != 11'd0) || (fq_n != 3'd4));
    wire   wr        = pcm_valid && pcm_ready;
    wire   fstart_wr = wr && (widx == 11'd0);
    assign tag_pop   = fstart_wr && tag_valid;

    sfifo #(.DW(32), .AW(AW)) u_pcm (
        .clk, .rst_n, .din({pcm_l, pcm_r}), .wr_en(wr), .full(pcm_full),
        .dout(h_pair), .dout_valid(h_valid), .rd_en(pop), .count(fill));

    // the head pair's time and its distance from the STC (q3, modulo 2**36)
    wire        h_has = fq_has[fq_rp];
    wire        h_left = h_valid && left_mask[fq_ep[fq_rp]];   // a left item's frame
    wire [35:0] h_pos = {fq_pts[fq_rp], 3'b000} + ({21'd0, ridx, 4'b0000} - {25'd0, ridx});
    wire signed [35:0] d = $signed({stc, 3'b000} - h_pos);
    wire        judged = h_valid && h_has && stc_run;
    wire        fstart = (ridx == 11'd0);
    wire        far    = (d > THR_Q3) || (d < -THR_Q3);

    // ---- the gate ----
    logic [FB_W-1:0] fb_tmr;
    logic [DRY_W-1:0] dry_tmr;            // cycles since the decoder last wrote a pair
    wire  buffered = (fill >= MIN_FILL_W) || (&dry_tmr);
    logic            discard, release_now, fb_now, rearm_u, rearm_s, play_now, d_left, d_yield, rearm_l;
    always_comb begin
        discard = 1'b0; release_now = 1'b0; fb_now = 1'b0;
        rearm_u = 1'b0; rearm_s = 1'b0; play_now = 1'b0; d_left = 1'b0; d_yield = 1'b0; rearm_l = 1'b0;
        if (!running) begin
            // ARM decides nothing while frozen (RUN needs no gate: the tick itself stops,
            // and a tick made before the freeze is still played)
            if (freeze) begin
            end else if (h_left) begin
                discard = 1'b1; d_left = 1'b1;                       // a left item's leftover
            end else if (judged) begin
                if (d >= 36'sd15)      discard     = 1'b1;
                else if (d >= 36'sd0 && buffered) release_now = 1'b1;
                else if (d < 36'sd0 && ring_blocked && pcm_full && vid_stalled) begin
                    discard = 1'b1; d_yield = 1'b1;                  // the stall breaker
                end
            end else if (h_valid && !stc_run && ring_blocked && pcm_full) begin
                discard = 1'b1;
            end else if (h_valid && (&fb_tmr)) begin
                fb_now = 1'b1;
            end
        end else if (h_left) begin
            rearm_l = 1'b1;                                          // re-arm: ARM discards it
        end else if (sample_tick) begin
            if (!h_valid)                 rearm_u  = 1'b1;
            else if (judged && fstart && far) rearm_s = 1'b1;
            else                          play_now = 1'b1;
        end
    end
    assign pop  = discard || play_now;
    assign play = play_now;

    wire signed [32:0] d_ticks = d[35:3];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            widx <= 11'd0; ridx <= 11'd0; fq_wp <= 2'd0; fq_rp <= 2'd0; fq_n <= 3'd0;
            for (int i = 0; i < 4; i++) begin fq_has[i] <= 1'b0; fq_pts[i] <= '0; fq_ep[i] <= '0; end
            n_left <= '0; n_yield <= '0;
            running <= 1'b0; fb_tmr <= '0; dry_tmr <= '0;
            audio_l <= 16'd0; audio_r <= 16'd0;
            frames_played <= 16'd0; under <= 8'd0; resync <= 8'd0; fallback <= 8'd0;
            tag_miss <= 8'd0; stale <= 16'd0; pre_drop <= 16'd0;
            err_ticks <= 16'sd0; err_seen <= 1'b0;
        end else begin
            // write side: a frame's first pair takes the next tag
            if (wr) widx <= widx + 11'd1;             // 2,048 pairs a frame: wraps to 0
            if (fstart_wr) begin
                fq_has[fq_wp] <= tag_valid && tag_has;
                fq_ep[fq_wp]  <= tag_ep;
                fq_pts[fq_wp] <= tag_pts;
                fq_wp         <= fq_wp + 2'd1;
                if (!tag_valid && !(&tag_miss)) tag_miss <= tag_miss + 8'd1;
            end
            // read side: the last pair of a frame retires its tag
            if (pop) ridx <= ridx + 11'd1;
            if (pop && (ridx == 11'd2047)) fq_rp <= fq_rp + 2'd1;
            fq_n <= fq_n + {2'd0, fstart_wr} - {2'd0, pop && (ridx == 11'd2047)};

            // the gate
            if (wr)                          dry_tmr <= '0;
            else if (!(&dry_tmr) && !freeze) dry_tmr <= dry_tmr + 1'b1;
            if (running || !h_valid || judged) fb_tmr <= '0;
            else if (!(&fb_tmr) && !freeze)     fb_tmr <= fb_tmr + 1'b1;
            if (release_now || fb_now) running <= 1'b1;
            if (fb_now && !(&fallback)) fallback <= fallback + 8'd1;
            if (rearm_u || rearm_s || rearm_l) running <= 1'b0;
            if (d_left)  n_left  <= n_left + 16'd1;
            if (d_yield) n_yield <= n_yield + 16'd1;
            if (rearm_u && !(&under))  under  <= under + 8'd1;
            if (rearm_s && !(&resync)) resync <= resync + 8'd1;
            if (discard && !d_left && !d_yield) begin          // (those two counted apart)
                if (stc_run) stale    <= stale + 16'd1;
                else         pre_drop <= pre_drop + 16'd1;
            end
            if (play_now) begin
                audio_l <= h_pair[31:16];
                audio_r <= h_pair[15:0];
                if (fstart) frames_played <= frames_played + 16'd1;
            end
            // the lip-sync instrument: every judged frame start, played or re-armed on
            if (sample_tick && running && judged && fstart) begin
                err_seen  <= 1'b1;
                err_ticks <= (d_ticks > 33'sd32767)  ? 16'sd32767 :
                             (d_ticks < -33'sd32768) ? -16'sd32768 : d_ticks[15:0];
            end
        end
    end

endmodule

`default_nettype wire
