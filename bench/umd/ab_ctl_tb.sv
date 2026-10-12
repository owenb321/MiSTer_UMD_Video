// bench/umd/ab_ctl_tb.sv -- umd/ab_ctl.sv, A-B Repeat (docs/ab_repeat.md)
//
// A randomized walk (+seed=N, +n=steps) of a mock player against a REFERENCE kept here, written from
// docs/ab_repeat.md §2 (the maintainer's PSP, 2026-10-07), not from the RTL. The mock player shows
// pictures over titles of several items (each item's PTS restarting low, so a key compared by PTS
// alone goes wrong; items and PTS near their u32 / 33-bit tops on some titles), pauses, stops, trick
// play, foreign seeks (Go To or a chapter press in state A), the host's seeks and menus, the title's
// end, mounts and bare files; it serves the command port as player_ctl does -- a taken SEEK either
// starts a seek (`seeking` up, the landing's first picture at the target, `seeking` down) or is
// refused (BAD: `seeking` never rises).
//
// Arms ($fatal; PASS marker "PASS: ab_ctl_tb"):
//   [state]  after every step: ab_st (and loop) vs the reference -- the cycle, the press's
//            conditions, B not after A refused, every clear
//   [cmd]    the request: raised exactly when the reference loops (the shown key at or past B, item
//            first) or a chapter press jumps, never otherwise; every taken SEEK's item / PTS is A's;
//            none while the reference's seek is in flight (the re-arm)
//   [retry]  a refused SEEK is asked again within TAKE_WAIT + a few cycles, counted
//   [tag]    tag_up / tag_b against the reference: the B's blink exactly BLINK_CYC on / off from on,
//            the 2 s hold exactly HOLD_CYC (directed), and at every step
//   [na]     a press on a bare file pulses unavail and sets nothing
//   [cnt]    n_refused / n_ign / n_loops vs the reference's counts
//   [cover]  loops, chapter jumps, refusals, retries, each clear reason, an item-crossing loop
`timescale 1ns/1ps
`default_nettype none
module ab_ctl_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

localparam int BLINK = 20, HOLD = 50, TWAIT = 16;
localparam [2:0] ST_PLAY = 3'd1, ST_PAUSE = 3'd2, ST_STOP = 3'd3;

// ---- the DUT --------------------------------------------------------------------------------
reg         mount = 0, eject = 0, k_ab = 0, k_clear = 0, k_next = 0, k_prev = 0;
reg  [2:0]  state = ST_PLAY;
reg  [1:0]  tk_speed = 0;
reg         seeking = 0, bare = 0, sh_pts_v = 0, pick = 0, ended = 0, host_ui = 0, host_nav = 0;
reg  [31:0] key_item = 0;
reg  [32:0] sh_pts = 0;
reg         cmd_take = 0;
wire        cmd_req, loop, tag_up, tag_b, unavail;
wire [31:0] cmd_item;
wire [47:0] cmd_pts;
wire [1:0]  ab_st;
wire [15:0] n_loops;
wire [7:0]  n_refused, n_ign, n_retry;
ab_ctl #(.BLINK_CYC(BLINK), .HOLD_CYC(HOLD), .TAKE_WAIT(TWAIT)) dut (
    .clk(clk), .rst_n(rst_n), .mount(mount), .eject(eject), .k_ab(k_ab), .k_clear(k_clear),
    .k_next(k_next), .k_prev(k_prev), .state(state), .tk_speed(tk_speed), .seeking(seeking),
    .key_item(key_item), .bare(bare), .sh_pts(sh_pts), .sh_pts_v(sh_pts_v), .pick(pick), .ended(ended),
    .host_ui(host_ui), .host_nav(host_nav), .cmd_req(cmd_req), .cmd_item(cmd_item), .cmd_pts(cmd_pts),
    .cmd_take(cmd_take), .ab_st(ab_st), .loop(loop), .tag_up(tag_up), .tag_b(tag_b), .unavail(unavail),
    .n_loops(n_loops), .n_refused(n_refused), .n_ign(n_ign), .n_retry(n_retry));

// ---- the title: items of IT_LEN pictures, each item's PTS from its own base -------------------
reg  [31:0] it0;                       // the title's first item number
longint     pbase [0:3];               // each item's first PTS (item - it0, mod 4)
integer     n_it, it_len;
integer     pos;                       // the shown picture: (item - it0) * it_len + index
function automatic [31:0] pos_item(input integer p); pos_item = it0 + p / it_len; endfunction
function automatic [32:0] pos_pts(input integer p); pos_pts = pbase[(p / it_len) % 4] + (p % it_len) * 3003; endfunction

// the reference
integer     r_st;                      // 0 off, 1 A, 2 loop
integer     rA, rB;                    // positions
integer     r_ign = 0, r_ref = 0, r_loops = 0, r_retries = 0;
integer     tA = 0, tB = 0;            // the cycle the A / B press was taken (the tag's phase)
integer     n_pickpress = 0;
integer     n_cross = 0, n_jump = 0, n_loopseek = 0, n_refuse_cov = 0;
integer     n_clr [0:9];
integer     seed0, nsteps, step, i;
reg         in_seek = 0;               // the reference's seek in flight (from the take to the landing)

// a request outside the reference's expectation is caught on any cycle
reg         expect_req = 0;
always @(posedge clk) if (rst_n && cmd_req && !expect_req) `FAIL("cmd", $sformatf("cycle %0d: a request the reference did not make (st %0d)", cyc, r_st))

task automatic tick(input integer n = 1); repeat (n) @(negedge clk); endtask

task automatic show(input integer p);           // a pickup of picture p (player_ctl writes key_item next cycle)
    pos = p; sh_pts = pos_pts(p); sh_pts_v = 1; pick = 1; tick(); pick = 0; key_item = pos_item(p); tick();
endtask

function automatic bit key_ge(input integer p, input integer q);   // the key of p at or past q's (item first)
    key_ge = (pos_item(p) > pos_item(q)) || (pos_item(p) == pos_item(q) && pos_pts(p) >= pos_pts(q));
endfunction

function automatic [7:0] sat8(input integer v); sat8 = (v > 255) ? 8'd255 : v[7:0]; endfunction

task automatic check_state(input string where);
    if (ab_st !== r_st[1:0]) `FAIL("state", $sformatf("%0s: ab_st %0d, the reference %0d", where, ab_st, r_st))
    if (loop !== (r_st == 2)) `FAIL("state", $sformatf("%0s: loop %0b", where, loop))
    if (n_refused !== sat8(r_ref) || n_ign !== sat8(r_ign) || n_loops !== r_loops[15:0] || n_retry !== sat8(r_retries))
        `FAIL("cnt", $sformatf("%0s: refused %0d/%0d ign %0d/%0d loops %0d/%0d retry %0d/%0d", where, n_refused, r_ref,
                               n_ign, r_ign, n_loops, r_loops, n_retry, r_retries))
    begin : tagc
        bit eu, eb;
        eu = (r_st == 1) || (r_st == 2 && cyc - tB < HOLD);
        eb = (r_st == 2) || (((cyc - tA) / BLINK) % 2 == 0);
        if (tag_up !== eu) `FAIL("tag", $sformatf("%0s: tag_up %0b, expected %0b (%0d cycles after B)", where, tag_up, eu, cyc - tB))
        if (r_st == 1 && tag_b !== eb) `FAIL("tag", $sformatf("%0s: tag_b %0b, expected %0b (%0d cycles after A)", where, tag_b, eb, cyc - tA))
        if (r_st == 2 && tag_b !== 1'b1) `FAIL("tag", $sformatf("%0s: tag_b low while looping", where))
    end
endtask

// a SEEK on the port: the reference expects it; take it (stalled a few cycles, as a button's cycle
// takes the port); refused now and then (BAD), when the DUT must ask again
task automatic serve(input string why, input bit allow_refuse);
    integer t, lat, land;
    bit refuse;
    expect_req = 1;
    t = 0; while (!cmd_req && t < 8) begin tick(); t++; end
    if (!cmd_req) `FAIL("cmd", $sformatf("%0s: no request (st %0d, pos %0d, A %0d B %0d)", why, r_st, pos, rA, rB))
    tick($urandom % 3);
    if (cmd_item !== pos_item(rA) || cmd_pts !== {15'd0, pos_pts(rA)})
        `FAIL("cmd", $sformatf("%0s: the SEEK's target %0d/%0d, A is %0d/%0d", why, cmd_item, cmd_pts, pos_item(rA), pos_pts(rA)))
    refuse = allow_refuse && ($urandom % 4 == 0);
    cmd_take = 1; tick(); cmd_take = 0; r_loops++; in_seek = 1;
    if (refuse) begin
        expect_req = 0;                                   // nothing until the wait runs out
        tick(TWAIT - 2);
        expect_req = 1; r_retries++;
        t = 0; while (!cmd_req && t < 8) begin tick(); t++; end
        if (!cmd_req) `FAIL("retry", $sformatf("%0s: a refused SEEK was not asked again", why))
        cmd_take = 1; tick(); cmd_take = 0; r_loops++;
    end
    expect_req = 0;
    // a store the display had already taken is shown before the freeze: still at or past B (or
    // the chapter press's picture) -- the loop must not ask again until the landing
    if ($urandom % 2) begin
        pick = 1; tick(); pick = 0; tick();
        if (cmd_req) `FAIL("cmd", $sformatf("%0s: asked again before the seek started", why))
    end
    tick(2); seeking = 1; state = ST_PLAY;                // (a seek resumes play)
    lat = 3 + $urandom % 20;
    for (t = 0; t < lat; t++) begin
        tick();
        if (cmd_req) `FAIL("cmd", $sformatf("%0s: asked again during the seek", why))
    end
    show(rA); tick($urandom % 2); seeking = 0; in_seek = 0; tick(2);
endtask

task automatic clear_ref(input integer why); if (r_st != 0) n_clr[why]++; r_st = 0; endtask

task automatic press_ab;
    bit can;
    k_ab = 1; tick(); k_ab = 0;
    can = (state == ST_PLAY || state == ST_PAUSE) && tk_speed == 0 && !seeking && sh_pts_v && !ended;
    if (bare) begin
        // (unavail pulsed the cycle after the press: sampled below)
    end else if (r_st == 2) clear_ref(0);
    else if (!can) r_ign++;
    else if (r_st == 0) begin r_st = 1; rA = pos; tA = cyc; end
    else if (!(pos_item(pos) > pos_item(rA) || (pos_item(pos) == pos_item(rA) && pos_pts(pos) > pos_pts(rA)))) begin
        r_ref++; n_refuse_cov++;
    end else begin r_st = 2; rB = pos; tB = cyc; end
endtask

// pictures play on: a loop at B
task automatic play_on(input integer n);
    integer k;
    for (k = 0; k < n && state == ST_PLAY && tk_speed == 0 && !ended; k++) begin
        if (pos + 1 >= n_it * it_len) begin ended = 1; if (r_st != 0) clear_ref(6); tick(2); break; end
        show(pos + 1);
        if (r_st == 2 && key_ge(pos, rB)) begin
            if (pos_item(rA) != pos_item(rB)) n_cross++;
            n_loopseek++;
            serve("a loop at B", 1);
        end else begin
            tick(2);
            if (cmd_req) `FAIL("cmd", $sformatf("a request before B (pos %0d, B %0d)", pos, rB))
        end
    end
endtask

task automatic new_title;
    integer k;
    mount = 1; tick(); mount = 0; clear_ref(9);
    n_it = 1 + $urandom % 4; it_len = 20 + $urandom % 100;
    it0 = ($urandom % 3 == 0) ? 32'hFFFF_FFFF - n_it + 1 : $urandom % 1000;
    for (k = 0; k < 4; k++) pbase[k] = ($urandom % 3 == 0) ? 64'h1_FFFF_FFFF - it_len * 3003 : $urandom % 900000;
    bare = ($urandom % 8 == 0); ended = 0; state = ST_PLAY; tk_speed = 0; seeking = 0; sh_pts_v = 0;
    tick(2);
    show(0);
endtask

initial begin
    if (!$value$plusargs("seed=%d", seed0)) seed0 = 1;
    if (!$value$plusargs("n=%d", nsteps)) nsteps = 3000;
    begin : sd integer s; s = seed0; void'($urandom(s)); end
    for (i = 0; i < 10; i++) n_clr[i] = 0;
    r_st = 0; rA = 0; rB = 0;
    tick(3); rst_n = 1; tick(2);
    new_title;
    check_state("start");

    // [tag] directed: the blink from A (on BLINK, off BLINK, from on) and the hold after B, cycle by cycle
    begin : tags
        integer t, k;
        bare = 0; state = ST_PLAY; tk_speed = 0; ended = 0;
        if (pos + 6 >= n_it * it_len) new_title;
        bare = 0;
        press_ab; check_state("A for the blink");
        for (t = 0; t < 5 * BLINK; t++) begin
            if (tag_b !== (((cyc - tA) / BLINK) % 2 == 0)) `FAIL("tag", $sformatf("blink: %0d cycles after A, tag_b %0b", cyc - tA, tag_b))
            if (tag_up !== 1'b1) `FAIL("tag", "the tag not up in state A")
            tick();
        end
        show(pos + 1); press_ab; check_state("B for the hold");
        for (t = 0; t < HOLD + 5; t++) begin
            if (tag_up !== (cyc - tB < HOLD)) `FAIL("tag", $sformatf("hold: %0d cycles after B, tag_up %0b", cyc - tB, tag_up))
            tick();
        end
        k_clear = 1; tick(); k_clear = 0; clear_ref(1); tick(); check_state("cleared after the hold");
    end

    for (step = 0; step < nsteps; step++) begin
        int c;
        // (the walk leaves the states where nothing can be set before long)
        if (ended && $urandom % 2) new_title;
        if (state == ST_STOP && $urandom % 3 == 0) state = ST_PLAY;
        c = $urandom % 100;
        if (r_st == 1 && c >= 22 && $urandom % 3 == 0) c = 30;     // with A set, play on towards a B
        if (c < 22) press_ab;
        else if (c < 50) play_on(1 + $urandom % 12);
        else if (c < 55) begin k_clear = 1; tick(); k_clear = 0; clear_ref(1); end
        else if (c < 61) begin                                  // pause / play
            if (state == ST_PLAY && tk_speed == 0) state = ST_PAUSE; else if (state == ST_PAUSE) state = ST_PLAY;
        end else if (c < 64) begin                              // stop, play resumes there
            state = ST_STOP; tk_speed = 0; tick(); if (r_st != 0) clear_ref(2);
        end else if (c < 66) begin
            if (state == ST_STOP) state = ST_PLAY;
        end else if (c < 72) begin                              // trick play (emu masks it while it loops)
            if (r_st != 2 && state != ST_STOP) begin
                if (tk_speed == 0) begin tk_speed = 1 + $urandom % 3; state = ST_PLAY; end
                else begin                                       // a hop lands somewhere; play resumes
                    tick(); seeking = 1; tick(3); show($urandom % (n_it * it_len)); seeking = 0; tk_speed = 0;
                    ended = 0;
                end
            end
        end else if (c < 80) begin                              // Next / Prev Chapter
            if (r_st == 2) begin
                if ($urandom % 2) k_next = 1; else k_prev = 1;
                tick(); k_next = 0; k_prev = 0;
                if (state == ST_PLAY || state == ST_PAUSE) begin n_jump++; serve("a chapter press", 1); end
            end else if (state != ST_STOP) begin                 // a chapter jump as usual: a foreign seek (A kept)
                k_next = 1; tick(); k_next = 0;
                tick(); seeking = 1; tick(4); state = ST_PLAY; ended = 0;
                show($urandom % (n_it * it_len)); seeking = 0;
            end
        end else if (c < 83) begin                              // Go To in state A / off (masked in the loop)
            if (r_st != 2 && state != ST_STOP) begin
                tick(); seeking = 1; tick(5); state = ST_PLAY; ended = 0;
                show($urandom % (n_it * it_len)); seeking = 0;
            end
        end else if (c < 86) begin host_nav = 1; tick(); host_nav = 0; clear_ref(3); end
        else if (c < 89) begin                                  // a disc menu takes the screen, and leaves
            host_ui = 1; tick(); clear_ref(4); tick(3); host_ui = 0;
        end else if (c < 91) begin eject = 1; sh_pts_v = 0; tick(); eject = 0; clear_ref(5); end
        else if (c < 94) new_title;
        else if (c < 97) begin                                  // a jump back (REW then play): B before A next
            if (r_st == 1 && state != ST_STOP && rA > 0) begin
                tick(); seeking = 1; tick(3); show($urandom % (rA + 1)); seeking = 0;
            end
        end else if (c < 99) begin                              // the picture goes away (a landing's gap)
            sh_pts_v = 0; tick(); press_ab; show(pos);
        end else if (r_st != 2 && pos + 1 < n_it * it_len) begin
            // a press in a pickup's own cycle (the key half new): ignored, counted
            pos = pos + 1; sh_pts = pos_pts(pos); pick = 1; k_ab = 1; tick(); pick = 0; k_ab = 0;
            key_item = pos_item(pos); tick();
            if (!bare && !(r_st == 2)) r_ign++;
            n_pickpress++;
        end
        tick(2);
        if (unavail !== 1'b0) `FAIL("na", "unavail held")
        check_state($sformatf("step %0d (kind %0d)", step, c));
    end

    // [na] directed: a press on a bare file
    begin : na
        bit seen;
        while (!bare) new_title;
        k_ab = 1; tick(); k_ab = 0;
        seen = 0;
        repeat (3) begin if (unavail === 1'b1) seen = 1; tick(); end
        if (!seen) `FAIL("na", "a press on a bare file did not post UNAVAIL")
        check_state("bare");
    end

    for (i = 0; i < 7; i++) if (n_clr[i] == 0) `FAIL("cover", $sformatf("clear reason %0d never seen", i))
    if (n_pickpress == 0 || n_loopseek == 0 || n_jump == 0 || n_refuse_cov == 0 || r_retries == 0 || r_ign == 0 || n_cross == 0)
        `FAIL("cover", $sformatf("loops %0d jumps %0d refusals %0d retries %0d ignored %0d crossings %0d",
                                 n_loopseek, n_jump, n_refuse_cov, r_retries, r_ign, n_cross))
    $display("ab_ctl_tb: seed %0d, %0d steps: %0d loops (%0d across items), %0d chapter jumps, %0d refused, %0d ignored, %0d retries; clears %0d/%0d/%0d/%0d/%0d/%0d/%0d",
             seed0, nsteps, n_loopseek, n_cross, n_jump, r_ref, r_ign, r_retries,
             n_clr[0], n_clr[1], n_clr[2], n_clr[3], n_clr[4], n_clr[5], n_clr[6]);
    $display("PASS: ab_ctl_tb");
    $finish;
end

endmodule
`default_nettype wire
