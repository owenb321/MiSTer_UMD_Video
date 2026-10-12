// umd/sub/sub_unit.sv -- subtitle units out of the demultiplexed PES payloads
// (docs/subtitles.md §2; the rules are tools/umd_sub_extract.py's, measured on every disc)
//
// In: the selected subtitle substream's payload bytes, one PES after another, each PES's
// first byte flagged (s_start) with its PTS (s_ptsv / s_pts), and s_gap on the first byte
// after bytes were LOST upstream (the crossing FIFO overflowed). Out: each unit's PNG
// bytes (u_last on the final one) after a begin request the ring answers (u_accept, the
// same cycle), and the unit's record {PTS, duration, x, y, PNG length} held from its
// header until u_last is taken.
//
// A unit (big-endian): u32 len (after itself), "0088", u32 duration (90 kHz), u16 0x0010,
// u16 x, u16 y, u16 0, then the PNG -- len - 16 bytes. It starts in a PES that carries a
// PTS and whose payload has the magic at bytes 4..7, and runs on through later PES until
// len + 4 bytes. Otherwise:
//   * a PES with a PTS whose bytes 4..7 are not the magic (or which ends before byte 7) is
//     a continuation: its bytes are replayed into the unit in progress;
//   * a new unit's header while one is in progress: the old one is aborted (truncated);
//   * bytes past a unit's end, in the same PES: dropped (overrun);
//   * a PES with no unit in progress and no header: dropped (orphan);
//   * a lost-bytes gap inside a unit: the unit is aborted (lost);
//   * the ring refuses a unit (no room): all of it dropped (refused).
// Each is counted. The unknown header fields are counted when they differ (0x0010, 0).
// One deviation from umd_sub_extract.py, on a stream no disc has: the magic decides at
// byte 7 even if the PES is shorter than the 20-byte header (the header then continues in
// the next PES); the tool would not start a unit there.
//
// Handshakes: s_* valid/ready (this module stalls its input while it replays), u_* valid /
// ready. u_begin is a one-cycle request; u_accept must answer in that cycle.

`default_nettype none

module sub_unit (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         flush,             // drop everything in progress (a seek, a track change)

    input  wire  [7:0]  s_byte,
    input  wire         s_start,
    input  wire         s_ptsv,
    input  wire  [32:0] s_pts,
    input  wire         s_gap,
    input  wire         s_valid,
    output logic        s_ready,

    output logic        u_begin,           // a unit's header is complete: may it be written?
    output logic [31:0] u_len,             // its PNG length (with u_begin, and held)
    output logic [31:0] u_words,           // ... in 64-bit words, rounded up (registered: timing)
    input  wire         u_accept,
    output logic [7:0]  u_byte,
    output logic        u_valid,
    output logic        u_last,
    input  wire         u_ready,
    output logic        u_abort,           // a pulse: discard the unit written so far

    output logic [32:0] rec_pts,           // the unit's record, held from u_begin to u_last
    output logic [31:0] rec_dur,
    output logic [15:0] rec_x,
    output logic [15:0] rec_y,

    output logic [15:0] n_units,           // units delivered whole
    output logic [15:0] n_truncated,
    output logic [15:0] n_overrun,
    output logic [15:0] n_orphan,
    output logic [15:0] n_lost,
    output logic [15:0] n_refused,
    output logic [15:0] n_badhdr,          // len < 16: no PNG at all
    output logic [15:0] n_oddfield         // the 0x0010 / 0 fields differ
);

    typedef enum logic [2:0] {U_IDLE, U_HDR, U_LEN, U_BEGIN, U_DATA, U_REPLAY, U_DROP} ustate_t;
    ustate_t state;

    logic        cur;                      // a unit is in progress (its bytes are being written)
    logic [7:0]  hb [0:19];                // the candidate header's bytes
    logic [4:0]  hk;                       // bytes held in hb
    logic [4:0]  rk;                       // replay index
    logic [31:0] left;                     // PNG bytes still to write
    logic [32:0] c_pts;                    // the candidate PES's PTS
    logic        ovr_arm;                  // a unit just ended: count this PES's rest once
    logic [31:0] len_r;                    // the header's PNG length, its words, and "no PNG",
    logic [31:0] words_r;                  // registered a cycle before the begin request (the
    logic        bad_r;                    // ring's room compare then starts from flops: mclk)

    // ---- the header, from hb (valid once 20 bytes are in) -------------------------------
    wire [31:0] h_len  = {hb[0], hb[1], hb[2], hb[3]};
    wire [31:0] h_dur  = {hb[8], hb[9], hb[10], hb[11]};
    wire [15:0] h_f12  = {hb[12], hb[13]};
    wire [15:0] h_x    = {hb[14], hb[15]};
    wire [15:0] h_y    = {hb[16], hb[17]};
    wire [15:0] h_f18  = {hb[18], hb[19]};
    // the magic as far as it has arrived, with the byte arriving now at index hk
    logic        mag_ok;
    always_comb begin
        case (hk)
            5'd4:    mag_ok = (s_byte == 8'h30);
            5'd5:    mag_ok = (s_byte == 8'h30);
            5'd6:    mag_ok = (s_byte == 8'h38);
            5'd7:    mag_ok = (s_byte == 8'h38);
            default: mag_ok = 1'b1;
        endcase
    end

    // ---- output byte mux ---------------------------------------------------------------------
    always_comb begin
        u_valid = 1'b0;
        u_byte  = s_byte;
        case (state)
            // a PES start without a PTS is plain data; one with a PTS may be a header
            U_DATA:   u_valid = s_valid && !s_gap && !(s_start && s_ptsv);
            U_REPLAY: begin u_valid = 1'b1; u_byte = hb[rk]; end
            default: ;
        endcase
        u_last = u_valid && (left == 32'd1);
        u_begin = (state == U_BEGIN);
        s_ready = 1'b0;
        case (state)
            U_IDLE, U_DROP: s_ready = 1'b1;
            // a new PES while an undecided candidate must be replayed first: hold it
            U_HDR: s_ready = !(s_start && !s_gap && cur && hk <= 5'd7);
            U_DATA: s_ready = (s_gap || (s_start && s_ptsv)) ? 1'b1 : u_ready;
            default: ;                     // U_BEGIN, U_REPLAY: hold the input
        endcase
    end
    wire take   = s_valid && s_ready;
    wire u_take = u_valid && u_ready;

    // a PES start (or a gap) seen in any byte-taking state
`define NEW_PES \
        begin \
            if (s_gap && cur) begin cur <= 1'b0; u_abort <= 1'b1; n_lost <= n_lost + 16'd1; end \
            if (s_ptsv) begin \
                hb[0] <= s_byte; hk <= 5'd1; c_pts <= s_pts; state <= U_HDR; \
            end else if (cur && !s_gap) begin \
                state <= U_DATA; \
            end else begin \
                if (!(s_gap && cur)) n_orphan <= n_orphan + 16'd1; \
                state <= U_DROP; \
            end \
        end

    // the unit continues with this byte (in U_DATA, as data)
    wire data_cont = (state == U_DATA) && take && !s_gap && !(s_start && s_ptsv);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            state <= U_IDLE; cur <= 1'b0; u_abort <= 1'b0;
            n_units <= '0; n_truncated <= '0; n_overrun <= '0; n_orphan <= '0;
            n_lost <= '0; n_refused <= '0; n_badhdr <= '0; n_oddfield <= '0;
        end else begin
            u_abort <= 1'b0;
            case (state)
                U_IDLE, U_DROP: if (take) begin
                    if (s_start || s_gap) `NEW_PES
                    // else: a byte of an orphan / overrun PES, dropped
                end

                U_HDR: if (s_valid && s_start && !s_gap && cur && hk <= 5'd7) begin
                    // the candidate was a continuation: replay it; the new PES waits
                    state <= U_REPLAY; rk <= 5'd0;
                end else if (take) begin
                    if (s_gap || (s_start && hk <= 5'd7)) begin
                        // the candidate PES ended before its magic (s_start with a unit in
                        // progress is held, not taken: see s_ready), or bytes were lost
                        if (!cur && !s_gap) n_orphan <= n_orphan + 16'd1;
                        `NEW_PES
                    end else if (s_start) begin
                        // past the magic: the header continues in this PES (the deviation)
                        hb[hk] <= s_byte;
                        hk     <= hk + 5'd1;
                        if (hk == 5'd19) state <= U_LEN;
                    end else begin
                        hb[hk] <= s_byte;
                        hk     <= hk + 5'd1;
                        if (hk >= 5'd4 && hk <= 5'd7 && !mag_ok) begin
                            // not a header: a continuation of the unit in progress, or an orphan
                            if (cur) begin state <= U_REPLAY; rk <= 5'd0; end
                            else begin n_orphan <= n_orphan + 16'd1; state <= U_DROP; end
                        end else if (hk == 5'd7 && cur) begin
                            // a new unit's header while one is in progress: truncated
                            cur <= 1'b0; u_abort <= 1'b1; n_truncated <= n_truncated + 16'd1;
                        end else if (hk == 5'd19) state <= U_LEN;
                    end
                end

                U_LEN: begin                        // one cycle: the length, registered
                    len_r   <= h_len - 32'd16;
                    words_r <= ((h_len - 32'd16) >> 3) + {31'd0, (h_len[2:0] != 3'd0)};   // (16 is a multiple of 8)
                    bad_r   <= (h_len <= 32'd16);
                    state   <= U_BEGIN;
                end

                U_BEGIN: begin
                    rec_pts <= c_pts;
                    if (bad_r) begin
                        n_badhdr <= n_badhdr + 16'd1;
                        state    <= U_DROP;
                    end else if (!u_accept) begin
                        n_refused <= n_refused + 16'd1;
                        state     <= U_DROP;
                    end else begin
                        if (h_f12 != 16'h0010 || h_f18 != 16'h0000) n_oddfield <= n_oddfield + 16'd1;
                        rec_dur <= h_dur;
                        rec_x   <= h_x;
                        rec_y   <= h_y;
                        left    <= len_r;
                        cur     <= 1'b1;
                        state   <= U_DATA;
                    end
                end

                U_DATA: begin
                    if (take && (s_gap || (s_start && s_ptsv))) `NEW_PES
                    else if (data_cont) begin
                        left <= left - 32'd1;
                        if (left == 32'd1) begin
                            cur     <= 1'b0;
                            n_units <= n_units + 16'd1;
                            state   <= U_DROP;          // the rest of this PES is overrun
                        end
                    end
                end

                U_REPLAY: if (u_take) begin
                    left <= left - 32'd1;
                    rk   <= rk + 5'd1;
                    if (left == 32'd1) begin
                        cur     <= 1'b0;
                        n_units <= n_units + 16'd1;
                        state   <= U_DROP;
                    end else if (rk + 5'd1 == hk) state <= U_DATA;
                end
                default: ;
            endcase

            // overrun: a byte after a unit ended, in the PES that ended it
            if (state == U_DROP && take && !s_start && !s_gap && !cur && ovr_arm) n_overrun <= n_overrun + 16'd1;

            if (flush) begin
                if (cur) u_abort <= 1'b1;
                cur   <= 1'b0;
                state <= U_IDLE;
            end
        end
    end

    // count an overrun once per unit: armed when a unit completes, disarmed by the next PES
    always_ff @(posedge clk) begin
        if (!rst_n || flush) ovr_arm <= 1'b0;
        else if ((data_cont || (state == U_REPLAY && u_take)) && left == 32'd1) ovr_arm <= 1'b1;
        else if ((take && (s_start || s_gap)) || (state == U_DROP && take && ovr_arm)) ovr_arm <= 1'b0;
    end

    assign u_len   = len_r;
    assign u_words = words_r;

`undef NEW_PES

endmodule

`default_nettype wire
