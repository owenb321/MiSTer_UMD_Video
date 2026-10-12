// bench/umd/goto_ctl_tb.sv -- umd/goto_ctl.sv, Go To's editor (P6c, docs/p6c.md §9)
//
// A randomized walk of presses (+seed=N, +n=presses) against a REFERENCE of the behaviour kept
// here, written from the spec (goto_ctl.sv's header, transport.md §3's walk-through, D15 / D16),
// not from the RTL: the open conditions, the boxes and fields, the chapter selector (a sorted
// list of distinct chapter keys; the mock reader answers NAV_CHAP from it by its contract --
// rank = keys at or before the key, cur the last of them, next the first after -- 3-300 cycles
// later), the time's h / m / s with their wraps (hours 0-99, or 0-999 on a title of 100 h or
// more) and t = ((h * 60 + m) * 60 + s) * 90000, the opening's time (the elapsed time divided
// down, hours clamped to the field), the jumps (x on a chapter: SEEK 7 to its key; on the time:
// TIME 15 with t), the closes (Go To, Stop, UMD Menu, a stop, a disc menu, the picture gone, a
// mount) and the marker (the time box: t; the chapter box: base + clamp(pts, IN, OUT) - IN,
// hidden unless the candidate's item is the one streaming).
//
// Arms ($fatal; PASS marker "PASS: goto_ctl_tb"):
//   [state]  before every press (the port quiet, the opening's division done): open, the focused
//            box, the field, the chapter number, the target time -- vs the reference
//   [mark]   the marker shown / hidden and its time, at the same moments
//   [cmd]    every jump: exactly when the reference makes one, its code, item and time
//   [port]   gq_req held until gq_done; a step pressed while a query is in flight changes
//            nothing (directed: the opposite step, so a taken one would show)
//   (directed too: every field's wraps both ways, hours 0-99 and 0-999)
//   [cover]  every kind of press and every close reason happened, chapter jumps and time jumps
`timescale 1ns/1ps
`default_nettype none
module goto_ctl_tb;

`define FAIL(arm, msg) begin $display("FAIL [%0s] %0s", arm, msg); $fatal(1); end

reg clk = 0, rst_n = 0;
always #5 clk = ~clk;
integer cyc = 0;
always @(posedge clk) cyc <= cyc + 1;

localparam longint S_T = 90000, M_T = 5400000, H_T = 324000000;

// ---- the DUT --------------------------------------------------------------------------------
reg         mount = 0, eject = 0;
reg         k_goto = 0, k_up = 0, k_down = 0, k_left = 0, k_right = 0, k_ok = 0, k_back = 0, k_menu = 0;
reg  [2:0]  state = 3'd1;
reg         sh_pts_v = 1, host_ui = 0;
reg  [31:0] key_item = 0;
reg  [32:0] sh_pts = 0;
reg  [15:0] chapter = 0, n_chapters = 0;
reg  [38:0] el_ticks = 0;
reg  [63:0] pl_dur = 64'd1000000;
reg  [31:0] rd_item_idx = 0;
reg  [47:0] rd_item_in = 0, rd_item_out = 0, rd_item_base = 0;
reg  [15:0] ch_rank = 0;
reg  [2:0]  ch_valid = 0;
reg  [63:0] ch_cur = 0, ch_next = 0;
reg         gq_done = 0;
wire        gq_req, cmd_v, open, sel, mark_v;
wire [63:0] gq_key;
wire [3:0]  cmd_code;
wire [31:0] cmd_item;
wire [47:0] cmd_pts;
wire [2:0]  edit;
wire [15:0] g_chapter;
wire [38:0] t_ticks, mark_ticks;
goto_ctl dut (
    .clk(clk), .rst_n(rst_n), .mount(mount), .eject(eject),
    .k_goto(k_goto), .k_up(k_up), .k_down(k_down), .k_left(k_left), .k_right(k_right), .k_ok(k_ok),
    .k_back(k_back), .k_menu(k_menu), .state(state), .sh_pts_v(sh_pts_v), .host_ui(host_ui),
    .key_item(key_item), .sh_pts(sh_pts), .chapter(chapter), .n_chapters(n_chapters), .el_ticks(el_ticks),
    .pl_dur(pl_dur), .rd_item_idx(rd_item_idx), .rd_item_in(rd_item_in), .rd_item_out(rd_item_out),
    .rd_item_base(rd_item_base), .ch_rank(ch_rank), .ch_valid(ch_valid), .ch_cur(ch_cur), .ch_next(ch_next),
    .gq_req(gq_req), .gq_key(gq_key), .gq_done(gq_done), .cmd_v(cmd_v), .cmd_code(cmd_code),
    .cmd_item(cmd_item), .cmd_pts(cmd_pts), .open(open), .sel(sel), .edit(edit), .g_chapter(g_chapter),
    .t_ticks(t_ticks), .mark_v(mark_v), .mark_ticks(mark_ticks));

// ---- the chapters (sorted, distinct) and the mock reader ------------------------------------
integer    nch = 0;
reg [63:0] chap [0:63];
integer    q_lat = -1, q_rank, i;
reg [63:0] q_key;
reg        q_taken = 0;
always @(posedge clk) begin
    gq_done <= 1'b0;
    if (gq_req && !q_taken && !gq_done) begin
        q_taken <= 1'b1; q_key = gq_key; q_lat <= 3 + $urandom % 298;
    end else if (q_taken && q_lat > 0) q_lat <= q_lat - 1;
    else if (q_taken && q_lat == 0) begin
        q_rank = 0;
        for (i = 0; i < nch; i++) if (chap[i] <= q_key) q_rank = i + 1;
        ch_rank <= q_rank;
        ch_valid <= {q_rank < nch, q_rank >= 2, q_rank >= 1};
        ch_cur <= (q_rank >= 1) ? chap[q_rank - 1] : 64'hDEAD;
        ch_next <= (q_rank < nch) ? chap[q_rank] : 64'hBEEF;
        gq_done <= 1'b1; q_taken <= 1'b0; q_lat <= -1;
    end
    // [port]: held until answered
    if (q_taken && !gq_req) `FAIL("port", "gq_req dropped before its answer")
end

// ---- the reference -----------------------------------------------------------------------------
integer r_open = 0, r_sel = 0, r_edit = 0, r_chap = 0, r_idx = -1, r_h = 0, r_m = 0, r_s = 0;
integer hmax;
longint r_t;
integer exp_cmd = 0;                 // 0 none, 7 / 15 expected at the next cmd_v
reg [63:0] exp_key;
longint exp_t;
integer n_cmd_seek = 0, n_cmd_time = 0, n_close [0:7], n_press [0:8];
initial for (i = 0; i < 8; i++) n_close[i] = 0;
initial for (i = 0; i < 9; i++) n_press[i] = 0;

function automatic longint tof(input integer h, input integer m, input integer s);
    tof = ((longint'(h) * 60 + m) * 60 + s) * S_T;
endfunction

task ref_open;
    longint x; integer r;
    begin
        r_open = 1; r_sel = (nch == 0); r_edit = 0;
        hmax = (pl_dur >= 64'd32400000000) ? 999 : 99;
        x = el_ticks;
        r_h = x / H_T; if (r_h > hmax) r_h = hmax; x = x - longint'(r_h) * H_T;
        r_m = x / M_T; if (r_m > 59) r_m = 59;     x = x - longint'(r_m) * M_T;
        r_s = x / S_T; if (r_s > 59) r_s = 59;
        r_t = tof(r_h, r_m, r_s);
        r = 0;
        // (a shown item past u16 asks past every mark: a mark's item is u16)
        for (i = 0; i < nch; i++)
            if (key_item[31:16] != 16'd0 || chap[i] <= {key_item[15:0], 15'd0, sh_pts}) r = i + 1;
        if (r >= 1) begin r_idx = r - 1; r_chap = r; end
        else if (nch > 0) begin r_idx = 0; r_chap = 1; end
        else begin r_idx = -1; r_chap = 0; end
    end
endtask

// ---- the checks before a press ---------------------------------------------------------------
longint m_pc, w_mark;
task check_state;
    begin
        if (open !== (r_open != 0)) `FAIL("state", $sformatf("open %b, want %0d", open, r_open))
        if (r_open) begin
            if (sel !== r_sel[0] || edit !== r_edit[2:0] || g_chapter !== r_chap[15:0] || t_ticks !== r_t[38:0])
                `FAIL("state", $sformatf("sel %b edit %0d chapter %0d t %0d, want %0d %0d %0d %0d",
                                         sel, edit, g_chapter, t_ticks, r_sel, r_edit, r_chap, r_t))
            if (r_sel) begin
                if (mark_v !== 1'b1 || mark_ticks !== r_t[38:0])
                    `FAIL("mark", $sformatf("time box: marker %b at %0d, want at %0d", mark_v, mark_ticks, r_t))
            end else if (r_chap == 0 || chap[r_idx][63:48] != rd_item_idx[15:0]) begin
                if (mark_v !== 1'b0) `FAIL("mark", "a chapter outside the streaming item: the marker shown (D15)")
            end else begin
                m_pc = chap[r_idx][47:0];
                if (rd_item_out < rd_item_in || m_pc < rd_item_in) m_pc = rd_item_in;
                else if (m_pc > rd_item_out) m_pc = rd_item_out;
                w_mark = rd_item_base + (m_pc - rd_item_in);
                if (mark_v !== 1'b1 || mark_ticks !== w_mark[38:0])
                    `FAIL("mark", $sformatf("chapter %0d: marker %b at %0d, want %0d", r_chap, mark_v, mark_ticks, w_mark))
            end
        end
    end
endtask

// ---- the commands ----------------------------------------------------------------------------
always @(posedge clk) if (cmd_v) begin
    if (exp_cmd == 0) `FAIL("cmd", $sformatf("a jump (code %0d) the reference did not make", cmd_code))
    if (cmd_code !== exp_cmd[3:0]) `FAIL("cmd", $sformatf("code %0d, want %0d", cmd_code, exp_cmd))
    if (exp_cmd == 7 && (cmd_item !== {16'd0, exp_key[63:48]} || cmd_pts !== exp_key[47:0]))
        `FAIL("cmd", $sformatf("SEEK to (%0d, %0d), want (%0d, %0d)", cmd_item, cmd_pts, exp_key[63:48], exp_key[47:0]))
    if (exp_cmd == 15 && cmd_pts !== exp_t[47:0]) `FAIL("cmd", $sformatf("TIME %0d, want %0d", cmd_pts, exp_t))
    if (exp_cmd == 7) n_cmd_seek++; else n_cmd_time++;
    exp_cmd = 0;
end

// ---- one press: drive it, update the reference, wait for quiet ------------------------------
task settle;
    integer t;
    begin
        t = 0;
        // the port quiet and the opening's division done (<= 1,117 cycles)
        repeat (1300) @(posedge clk);
        while ((gq_req || q_taken) && t < 100000) begin @(posedge clk); t++; end
        repeat (6) @(posedge clk);
        #1;
    end
endtask

task press(input integer k);   // 0 goto 1 up 2 down 3 left 4 right 5 ok 6 back 7 menu
    integer was_open;
    begin
        @(negedge clk);
        n_press[k]++;
        was_open = r_open;
        // the reference first (the press is seen at the next edge)
        if (!r_open) begin
            if (k == 0 && sh_pts_v && (state == 1 || state == 2) && !host_ui && pl_dur != 0) ref_open;
        end else if (k == 0 || k == 6 || k == 7) begin
            r_open = 0; r_edit = 0; n_close[k == 0 ? 0 : k == 6 ? 1 : 2]++;
        end else if (k == 5) begin
            if (r_edit == 0) r_edit = r_sel ? 2 : 1;
            else if (r_edit == 1) begin
                if (r_chap != 0) begin exp_cmd = 7; exp_key = chap[r_idx]; r_open = 0; r_edit = 0; end
            end else begin exp_cmd = 15; exp_t = r_t; r_open = 0; r_edit = 0; end
        end else if (k == 3 || k == 4) begin
            case (r_edit)
                0: if (nch != 0) r_sel = (k == 4);
                2: if (k == 4) r_edit = 3;
                3: r_edit = (k == 4) ? 4 : 2;
                4: if (k == 3) r_edit = 3;
                default: ;
            endcase
        end else if (k == 1 || k == 2) begin
            if (r_edit == 1 && r_chap != 0) begin
                if (k == 1 && r_idx + 1 < nch) begin r_idx++; r_chap = r_idx + 1; end
                if (k == 2 && r_idx > 0) begin r_idx--; r_chap = r_idx + 1; end
            end else if (r_edit == 2) begin
                if (k == 1) r_h = (r_h >= hmax) ? 0 : r_h + 1; else r_h = (r_h == 0) ? hmax : r_h - 1;
            end else if (r_edit == 3) begin
                if (k == 1) r_m = (r_m == 59) ? 0 : r_m + 1; else r_m = (r_m == 0) ? 59 : r_m - 1;
            end else if (r_edit == 4) begin
                if (k == 1) r_s = (r_s == 59) ? 0 : r_s + 1; else r_s = (r_s == 0) ? 59 : r_s - 1;
            end
            r_t = tof(r_h, r_m, r_s);
        end
        case (k) 0: k_goto = 1; 1: k_up = 1; 2: k_down = 1; 3: k_left = 1; 4: k_right = 1;
                 5: k_ok = 1; 6: k_back = 1; default: k_menu = 1; endcase
        @(negedge clk);
        {k_goto, k_up, k_down, k_left, k_right, k_ok, k_back, k_menu} = 8'd0;
        settle;
        if (exp_cmd != 0) `FAIL("cmd", $sformatf("the reference's jump %0d never came", exp_cmd))
        check_state;
    end
endtask

// ---- the title and the walk ------------------------------------------------------------------
integer seed = 1, seed0, npress = 3000, step, k, j, c;
longint kk;
task new_title;
    begin
        nch = $urandom % 3 == 0 ? 0 : 1 + $urandom % 40;
        kk = 0;
        for (j = 0; j < nch; j++) begin
            // keys ascending, distinct, over items 0-2
            kk = kk + 1 + ($urandom % 3 == 0 ? (64'd1 << 48) : 64'd0) + $urandom % 2000000;
            chap[j] = kk;
        end
        n_chapters = nch;
        pl_dur = ($urandom % 2) ? 64'd32400000000 + $urandom : 64'd1 + {$urandom} * 4;
        rd_item_idx = $urandom % 3;
        rd_item_in = $urandom % 1000000; rd_item_out = rd_item_in + $urandom % 3000000;
        if ($urandom % 8 == 0) rd_item_out = rd_item_in - 5;       // OUT before IN: no duration
        rd_item_base = {$urandom} * 64;
    end
endtask
task new_picture;
    begin
        key_item = $urandom % 3; sh_pts = {$urandom} & 33'h1_FFFF_FFFF;
        if ($urandom % 10 == 0) key_item = 32'h0001_0000;          // past u16: past every mark
        el_ticks = ($urandom % 4 == 0) ? {7'd0, $urandom} * 128 : {7'd0, $urandom};
        chapter = $urandom % 50;
    end
endtask

initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    if (!$value$plusargs("n=%d", npress)) npress = 3000;
    seed0 = seed;
    k = $urandom(seed);
    new_title; new_picture;
    repeat (5) @(posedge clk);
    rst_n = 1;
    repeat (5) @(posedge clk);
    for (step = 0; step < npress; step++) begin
        c = $urandom % 100;
        if (c < 2) begin                                  // a new title: a mount closes it
            @(negedge clk); mount = 1; @(negedge clk); mount = 0;
            if (r_open) n_close[3]++;
            r_open = 0; r_edit = 0; new_title; settle; check_state;
        end else if (c < 4) begin                         // stopped, or a disc menu, or the picture gone
            @(negedge clk);
            j = $urandom % 3;
            if (j == 0) state = 3'd3; else if (j == 1) host_ui = 1; else sh_pts_v = 0;
            if (r_open) n_close[4 + j]++;
            r_open = 0; r_edit = 0;
            settle; check_state;
            @(negedge clk); state = ($urandom % 2) ? 3'd1 : 3'd2; host_ui = 0; sh_pts_v = 1;
        end else if (c < 8) begin                         // the picture moves (and the streaming item)
            @(negedge clk); new_picture;
            if ($urandom % 3 == 0) rd_item_idx = $urandom % 3;
            settle; check_state;
        end else if (!r_open && c < 60) press(0);
        else begin
            // while open: mostly edits; a close now and then
            j = $urandom % 100;
            press(j < 4 ? 0 : j < 7 ? 6 : j < 9 ? 7 : j < 30 ? 5 : j < 50 ? 3 + $urandom % 2 : 1 + $urandom % 2);
        end
    end
    // [port] directed: a step pressed while a query is in flight changes nothing
    begin : dropped
        integer t0;
        nch = 5; for (j = 0; j < 5; j++) chap[j] = 64'd1000 * (j + 1); n_chapters = 5;
        state = 3'd1; host_ui = 0; sh_pts_v = 1; key_item = 0; sh_pts = 2500; pl_dur = 64'd1000000;
        if (r_open) press(6);
        press(0); press(5);                               // the chapter box open (chapter 2)
        @(negedge clk); k_up = 1; @(negedge clk); k_up = 0;
        t0 = 0;
        while (!gq_req && t0 < 100) begin @(negedge clk); t0++; end
        if (!gq_req) `FAIL("port", "a step asked nothing")
        @(negedge clk); k_down = 1; @(negedge clk); k_down = 0;   // in flight: dropped (taken, it
        r_idx = 2; r_chap = 3;                                   //   would read the up's answer as down)
        settle; check_state;
    end
    // [state] directed: every field's wraps both ways (down from 0, down, up, up), checked at each
    // step -- the random walk seldom reaches a field's ends twice running
    begin : wraps
        integer f;
        for (f = 0; f < 3; f++) begin
            if (r_open) press(6);
            el_ticks = 0; pl_dur = (f == 2) ? 64'd32400000000 : 64'd1000000;
            press(0);
            if (!r_sel) press(4);                       // the time box
            press(5);                                   // its hours
            if (f >= 1) press(4);                       // the minutes (f 1), or 999 h's hours (f 2: back)
            if (f == 2) press(3);
            if (f == 1) begin press(2); press(2); press(1); press(1); press(4); end   // then the seconds
            press(2); press(2); press(1); press(1);
        end
    end
    for (i = 0; i < 8; i++) if (n_press[i] == 0) `FAIL("cover", $sformatf("press kind %0d never made", i))
    for (i = 0; i < 7; i++) if (n_close[i] == 0) `FAIL("cover", $sformatf("close reason %0d never seen", i))
    if (n_cmd_seek == 0 || n_cmd_time == 0) `FAIL("cover", $sformatf("%0d chapter jumps, %0d time jumps", n_cmd_seek, n_cmd_time))
    $display("goto_ctl_tb: seed %0d, %0d steps: %0d chapter jumps, %0d time jumps, closes %0d/%0d/%0d/%0d/%0d/%0d/%0d",
             seed0, npress, n_cmd_seek, n_cmd_time, n_close[0], n_close[1], n_close[2], n_close[3], n_close[4],
             n_close[5], n_close[6]);
    $display("PASS: goto_ctl_tb");
    $finish;
end

endmodule
`default_nettype wire
