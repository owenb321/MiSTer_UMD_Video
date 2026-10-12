// umd/sub/sub_sched.sv -- when a subtitle is decoded, shown and hidden (docs/subtitles.md §2)
//
// Two planes: the FRONT one (what the display shows, or hides) and the BACK one (being
// decoded, or ready). The census (§1) gives the rules:
//   * decode when the back plane is free -- a unit is in the stream >= 0.57 s before its
//     PTS and the next PTS is >= 0.1 s later, so there is always time; no lead to tune;
//   * one subtitle on screen at a time (no disc overlaps two): a flip replaces the shown
//     one, and the hide time is the shown unit's PTS + duration.
// The display is told by REQUESTS {plane, visible, X, Y, w, h} it latches at vblank and
// ACKNOWLEDGES (req / ack, one outstanding): the old front plane is free only on that
// acknowledgement, never at the PTS -- the plane being scanned is never overwritten and a
// flip never tears. Times are the 33-bit STC (90 kHz), compared wrap-aware (the signed
// 33-bit difference); stc_valid low (no clock yet, or paused) holds everything.
//
// Verdicts per unit, counted: shown; late (its decode finished after its PTS: shown late);
// missed (its PTS + duration passed before it could be shown: never shown); refused (the
// PNG decoder's verdict err != 0: never shown). flush (a seek, a track change) drops the
// back plane's unit and hides the plane (a request like any other). A flip already
// requested cannot be taken back (the display may be latching it): it is hidden as soon
// as it is acknowledged (fl_hide), not left up for the dropped unit's duration.

`default_nettype none

module sub_sched (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         flush,

    input  wire  [32:0] stc,
    input  wire         stc_valid,

    // the ring's queue head
    input  wire         q_valid,
    input  wire  [32:0] q_pts,
    input  wire  [31:0] q_dur,
    input  wire  [15:0] q_x,
    input  wire  [15:0] q_y,
    output logic        q_take,

    // the image being written (to the plane writer; stable while it decodes)
    output logic        wr_buf,
    output logic [15:0] wr_x,
    output logic [15:0] wr_y,

    // the decode's end, once its pixels are in DDR3 (the plane writer's e_*)
    input  wire         e_valid,
    input  wire  [4:0]  e_err,
    input  wire  [15:0] e_w,
    input  wire  [15:0] e_h,
    output logic        e_ready,

    // to the display: the plane to show, latched at vblank
    output logic        d_req,              // a request is outstanding (level, until d_ack)
    output logic        d_buf,
    output logic        d_vis,
    output logic [15:0] d_x,
    output logic [15:0] d_y,
    output logic [15:0] d_w,
    output logic [15:0] d_h,
    input  wire         d_ack,              // a pulse: the display latched the request

    output logic [15:0] n_shown,
    output logic [15:0] n_late,
    output logic [15:0] n_missed,
    output logic [15:0] n_refused
);

    typedef enum logic [1:0] {B_FREE, B_DEC, B_READY} bstate_t;
    bstate_t bst;

    logic        front;                     // the front plane's index (the back is !front)
    logic        fvis;                      // the front plane is shown (as acknowledged)
    logic [32:0] fend;                      // when the shown one hides
    logic [32:0] bpts, bend;                // the back unit's PTS and PTS + duration
    logic [15:0] bx, by, bw, bh;
    logic        blate;                     // its decode finished after its PTS
    logic        pend_flip;                 // the outstanding request is a flip (else a hide)
    logic        fl_hide;                   // a flush came while that flip was outstanding

    // wrap-aware "STC has reached t": the 33-bit difference is not negative
    /* verilator lint_off UNUSEDSIGNAL */      // only the sign bits are used
    wire  [32:0] d_pts = stc - bpts;
    wire  [32:0] d_end = stc - bend;
    wire  [32:0] d_fe  = stc - fend;
    /* verilator lint_on UNUSEDSIGNAL */
    wire         at_pts = stc_valid && !d_pts[32];
    wire         at_end = stc_valid && !d_end[32];
    wire         at_fe  = stc_valid && !d_fe[32];

    assign wr_buf  = !front;
    assign wr_x    = bx;
    assign wr_y    = by;
    assign q_take  = (bst == B_FREE) && q_valid && !d_req && !flush;
    assign e_ready = (bst == B_DEC);

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            bst <= B_FREE; front <= 1'b0; fvis <= 1'b0; d_req <= 1'b0; pend_flip <= 1'b0; fl_hide <= 1'b0;
            n_shown <= '0; n_late <= '0; n_missed <= '0; n_refused <= '0;
        end else begin
            // -- take the next unit into the back plane
            if (q_take) begin
                bst  <= B_DEC;
                bpts <= q_pts;
                bend <= q_pts + {1'b0, q_dur};
                bx   <= q_x;
                by   <= q_y;
            end
            // -- its decode ends (pixels in DDR3)
            if (e_valid && e_ready) begin
                if (e_err != 5'd0) begin
                    n_refused <= n_refused + 16'd1;
                    bst       <= B_FREE;
                end else begin
                    bw    <= e_w;
                    bh    <= e_h;
                    blate <= at_pts;
                    bst   <= B_READY;
                end
            end
            // -- requests: a flip when the back plane's PTS comes, else a hide at the end
            if (!d_req && bst == B_READY && at_end) begin
                // its whole interval has passed: never shown
                n_missed <= n_missed + 16'd1;
                bst      <= B_FREE;
            end else if (!d_req && bst == B_READY && at_pts) begin
                d_req <= 1'b1; pend_flip <= 1'b1;
                d_buf <= !front; d_vis <= 1'b1; d_x <= bx; d_y <= by; d_w <= bw; d_h <= bh;
            end else if (!d_req && fvis && at_fe) begin
                d_req <= 1'b1; pend_flip <= 1'b0;
                d_buf <= front; d_vis <= 1'b0;
            end
            // -- the display took it (at vblank)
            if (d_req && d_ack) begin
                d_req <= 1'b0;
                if (pend_flip) begin
                    front   <= !front;      // the old front plane is free from now on
                    fvis    <= 1'b1;
                    fend    <= fl_hide ? stc : bend;    // flushed while requested: hide at once
                    fl_hide <= 1'b0;
                    bst     <= B_FREE;
                    n_shown <= n_shown + 16'd1;
                    if (blate) n_late <= n_late + 16'd1;
                end else fvis <= 1'b0;
            end
            // -- flush: drop the back plane's unit, hide the front one
            if (flush) begin
                bst <= B_FREE;
                if (fvis || (d_req && d_ack && pend_flip)) fend <= stc;      // hide at the next chance
                if (d_req && !d_ack && pend_flip) fl_hide <= 1'b1;         // ...or once its flip is taken
            end
        end
    end

endmodule

`default_nettype wire
