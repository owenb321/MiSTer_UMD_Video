// umd/ab_ctl.sv -- A-B Repeat (docs/ab_repeat.md; the behaviour measured on the maintainer's PSP,
// 2026-10-07, the HUD approved on the mockups, tools/transport_layout.py --mockups --ab), on clk_sys
// beside player_ctl and goto_ctl.
//
// THE CYCLE (the A-B Repeat press: the keyboard's B, the panel's item): off -> A (the shown key) ->
// B (the loop starts) -> off (normal playback). CLEAR (the panel's, host command 0) clears from any
// state. A press that sets A or B is taken only while a picture plays or is paused (not stopped, not
// in trick play, not during a seek, a shown PTS); otherwise it changes nothing and is counted
// (n_ign). A B not after A -- the shown key at or before A, item first -- is refused, counted
// (n_refused), the state left at A (the PSP cannot set B before A). A bare file: the press posts
// `unavail` (the HUD's "Not available for this file."), nothing set.
//
// THE KEYS are {item u32, PTS 33}: the shown picture's item (player_ctl's key_item) and its PTS,
// compared item first -- a PTS alone is wrong on a multi-item title. The pair is one picture's on
// every cycle but a pickup's own (`pick` high: sh_pts is the new picture's, key_item -- written at
// the end of that cycle -- still the old one's): a press in that cycle is ignored (counted), and the
// loop compares the cycle after.
//
// THE LOOP: at each snapshot while armed, a shown key at or past B asks a SEEK (7) to A on
// player_ctl's command port (cmd_req held until emu's cmd_take: a cycle with no Go To jump and no
// button command), raised only while no seek is in flight and a picture plays or is paused. The
// request is disarmed when taken; the loop re-arms when player_ctl's `seeking`, seen high, falls
// (its landing's first picture, A's, has been shown) -- until then the screen still shows a picture
// at or past B, which would ask twice. A take that `seeking` never follows within TAKE_WAIT cycles
// (player_ctl refused it: BAD) asks again, counted (n_retry).
//
// WHILE IT LOOPS (the PSP): Next and Prev Chapter both jump to A (k_next / k_prev ask the same
// SEEK; emu masks them from player_ctl with `loop`); FF, REW and Go To do nothing (emu masks them
// with `loop`); Pause pauses and the loop stays; Stop clears it. In state A everything acts as
// usual and A is kept (AB11), Stop clears it.
//
// CLEARED by: the third press, CLEAR, a stop (state STOP, from any source), the title's end
// (`ended`), a disc menu taking the screen (host_ui's rise), a host seek (host_nav: SEEK / TIME /
// PLAYLIST from the UMD Main), a mount, an eject.
//
// THE HUD (the PSP): with A set the state icon and `A-B` stay up, the B blinking at 1 Hz (BLINK_CYC
// on, BLINK_CYC off, starting on); at B the B is solid for HOLD_CYC (2 s), then both go while it
// loops, unless the icon is up for its own reason (Display, paused): tag_up / tag_b below,
// transport_hud draws them.
//
// Quartus 17: no functions, no N'() casts.

`default_nettype none

module ab_ctl #(
    parameter int BLINK_CYC = 13_500_000,   // 0.5 s: the B's half-period in state A (1 Hz)
    parameter int HOLD_CYC  = 54_000_000,   // 2 s: the B solid after it was set
    parameter int TAKE_WAIT = 64            // cycles for a taken SEEK's `seeking` to rise
) (
    input  wire         clk,                // clk_sys
    input  wire         rst_n,
    input  wire         mount,              // pulse: a new title
    input  wire         eject,
    // the presses (one-cycle edges)
    input  wire         k_ab,               // A-B Repeat
    input  wire         k_clear,            // CLEAR (the panel's: host command 0)
    input  wire         k_next,             // Next / Prev Chapter as they reach the transport
    input  wire         k_prev,             //   (taken here only while it loops)
    // player_ctl
    input  wire  [2:0]  state,              // ST_PLAY 1, ST_PAUSE 2, ST_STOP 3
    input  wire  [1:0]  tk_speed,           // trick play: 0 off
    input  wire         seeking,
    input  wire  [31:0] key_item,
    input  wire         bare,               // P8: a bare stream file (no seek)
    // the display
    input  wire  [32:0] sh_pts,
    input  wire         sh_pts_v,
    input  wire         pick,               // pulse: a new store was shown
    input  wire         ended,              // the title ended
    // the host (the UMD Main)
    input  wire         host_ui,            // a disc menu has the screen (P9)
    input  wire         host_nav,           // pulse: a host SEEK / TIME / PLAYLIST taken
    // player_ctl's command port: SEEK (7) to A
    output logic        cmd_req,
    output logic [31:0] cmd_item,
    output logic [47:0] cmd_pts,
    input  wire         cmd_take,           // emu gave the port this cycle
    // status
    output logic [1:0]  ab_st,              // 0 off, 1 A set, 2 looping
    output wire         loop,               // ab_st == 2: emu's masks
    output wire         tag_up,             // the HUD: the icon and `A-B` up on their own (A, B's hold)
    output wire         tag_b,              //   the B drawn (A: the blink's phase)
    output logic        unavail,            // pulse: a press on a bare file
    output logic [15:0] n_loops,            // SEEKs taken (loops and chapter jumps)
    output logic [7:0]  n_refused,          // B presses not after A
    output logic [7:0]  n_ign,              // presses that could not set (stopped, trick play, ...)
    output logic [7:0]  n_retry             // taken SEEKs player_ctl did not start
);

    localparam [2:0] ST_PLAY = 3'd1, ST_PAUSE = 3'd2, ST_STOP = 3'd3;
    localparam [1:0] AB_OFF = 2'd0, AB_A = 2'd1, AB_LOOP = 2'd2;

    logic        pick_q;
    logic [31:0] a_item, b_item;
    logic [32:0] a_pts, b_pts;
    logic        armed, req, inflight, seen;
    logic [6:0]  twait;
    logic [25:0] tmr;                       // A: the blink's count up; the loop: the hold's count down
    logic        b_on, host_ui_q;

    wire playing  = (state == ST_PLAY || state == ST_PAUSE);
    wire can_set  = playing && tk_speed == 2'd0 && !seeking && sh_pts_v && !pick && !ended;
    wire after_a  = (key_item > a_item) || (key_item == a_item && sh_pts > a_pts);
    // (a stop or the end clears what is set; with nothing set a press then is only ignored, counted)
    wire clr      = mount || eject || k_clear || (host_ui && !host_ui_q) || host_nav ||
                    ((state == ST_STOP || ended) && ab_st != AB_OFF) || (k_ab && ab_st == AB_LOOP);

    assign loop   = (ab_st == AB_LOOP);
    assign tag_up = (ab_st == AB_A) || (loop && tmr != 26'd0);
    assign tag_b  = loop || b_on;
    assign cmd_req  = req && !seeking && playing && tk_speed == 2'd0;
    assign cmd_item = a_item;
    assign cmd_pts  = {15'd0, a_pts};

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            pick_q <= 1'b0;
            a_item <= '0; a_pts <= '0; b_item <= '0; b_pts <= '0;
            ab_st <= AB_OFF; armed <= 1'b0; req <= 1'b0; inflight <= 1'b0; seen <= 1'b0; twait <= '0;
            tmr <= '0; b_on <= 1'b1; host_ui_q <= 1'b0; unavail <= 1'b0;
            n_loops <= '0; n_refused <= '0; n_ign <= '0; n_retry <= '0;
        end else begin
            pick_q <= pick; host_ui_q <= host_ui; unavail <= 1'b0;
            // the HUD's timer: the B's blink in A, the 2 s hold after B
            if (ab_st == AB_A) begin
                if (tmr == BLINK_CYC[25:0] - 26'd1) begin tmr <= '0; b_on <= !b_on; end
                else tmr <= tmr + 26'd1;
            end else if (tmr != 26'd0) tmr <= tmr - 26'd1;

            // a SEEK taken: wait for player_ctl's seek to start, then to land
            if (cmd_req && cmd_take) begin
                req <= 1'b0; inflight <= 1'b1; seen <= 1'b0; twait <= '0;
                if (n_loops != 16'hFFFF) n_loops <= n_loops + 16'd1;
            end else if (inflight) begin
                if (seeking) seen <= 1'b1;
                if (seen && !seeking) begin inflight <= 1'b0; armed <= 1'b1; end
                else if (!seen && !seeking) begin
                    if (twait == TAKE_WAIT[6:0]) begin
                        inflight <= 1'b0; req <= 1'b1;
                        if (n_retry != 8'hFF) n_retry <= n_retry + 8'd1;
                    end else twait <= twait + 7'd1;
                end
            end

            if (clr) begin
                ab_st <= AB_OFF; armed <= 1'b0; req <= 1'b0; inflight <= 1'b0; tmr <= '0;
            end else if (k_ab) begin
                if (bare) unavail <= 1'b1;
                else if (!can_set) begin
                    if (n_ign != 8'hFF) n_ign <= n_ign + 8'd1;
                end else if (ab_st == AB_OFF) begin
                    a_item <= key_item; a_pts <= sh_pts; ab_st <= AB_A; tmr <= '0; b_on <= 1'b1;
                end else if (!after_a) begin
                    if (n_refused != 8'hFF) n_refused <= n_refused + 8'd1;
                end else begin
                    b_item <= key_item; b_pts <= sh_pts; ab_st <= AB_LOOP; armed <= 1'b1;
                    tmr <= HOLD_CYC[25:0];
                end
            end else if (loop) begin
                // a chapter press jumps to A; the shown key reaching B loops
                if ((k_next || k_prev) && !req && !inflight) begin req <= 1'b1; armed <= 1'b0; end
                else if (pick_q && armed && sh_pts_v &&
                         ((key_item > b_item) || (key_item == b_item && sh_pts >= b_pts))) begin
                    req <= 1'b1; armed <= 1'b0;
                end
            end
        end
    end

endmodule

`default_nettype wire
