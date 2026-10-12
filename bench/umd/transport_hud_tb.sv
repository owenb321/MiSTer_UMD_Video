// bench/umd/transport_hud_tb.sv -- umd/transport_hud.sv, pixel-exact against
// tools/transport_layout.py (P6b5; bench/umd/run_transport_hud.sh generates the states)
//
// For every state sNN of +dir=<dir>: replay sNN.stim.hex (a reset, the inputs, the pulses and
// events that pop the state's pop-up up -- the RTL's own triggers, so they are proven too --
// then a settle), then score ONE whole 720 x 480 frame against sNN.exp.hex: `rgb`, the HUD
// over the bench's background (the model's bench_bg(), computed here the same way), taken
// LAT = 4 clocks after (h, v) like emu's output register. Every mismatching state prints
// "FAIL [<name>] ..." and the run continues to the next, so a --red mutation is scored by the
// state its runner names; the run ends $fatal if any state failed, else a PASS line.
// Scored with !==: an X pixel fails.
`timescale 1ns/1ps

module transport_hud_tb;
reg         il = 1'b0;                   // +il: the 480i (title-safe) layout
reg         safe = 1'b0;                 // +il or +safe: the title-safe layout; +safe alone on the 480p
                                         // raster, as Zoom draws it (fj#71, docs/zoom.md; scored on the
                                         // 480i set's frames: the same pixels, frame lines)

localparam int POPUP = 6;                    // the pop-up's life here, in refreshes: the wait for
                                             // a frame's top and the frame scored fit inside it
                                             // (+il: a refresh is a FIELD, two a frame)
localparam int HT = 858, VT = 525;

reg clk = 1'b0;
always #5 clk = ~clk;
reg rst_n = 1'b0;

// the raster: one pixel a clock. +il: in FIELDS, as the 480i raster hands the HUD its lines (v
// the frame line: the top field's even lines 0..524, then the bottom field's odd ones 1..523), so
// the HUD's refresh (a field's first line, v 0 or 1) comes twice a frame, as on the rig
reg  [11:0] h = 12'd0, vc = 12'd0;
reg         fb = 1'b0;                       // +il: the bottom field
wire [11:0] v  = il ? {vc[10:0], fb} : vc;
wire        de = (h < 12'd720) && (v < 12'd480);
always @(posedge clk) begin
    if (h == HT - 1) begin
        h <= 12'd0;
        if (!il) vc <= (vc == VT - 1) ? 12'd0 : vc + 12'd1;
        else if (vc == (fb ? 12'd261 : 12'd262)) begin vc <= 12'd0; fb <= !fb; end
        else vc <= vc + 12'd1;
    end else h <= h + 12'd1;
end
// (h, v) four clocks on: the pixel whose rgb comes out now
reg [11:0] h1, h2, h3, h4, v1, v2, v3, v4;
reg        d1, d2, d3, d4;
always @(posedge clk) begin
    h1 <= h; h2 <= h1; h3 <= h2; h4 <= h3;
    v1 <= v; v2 <= v1; v3 <= v2; v4 <= v3;
    d1 <= de; d2 <= d1; d3 <= d2; d4 <= d3;
end
// the model's bench_bg()
wire [7:0]  bg_r = h4[7:0] * 8'd3 + v4[7:0];
wire [7:0]  bg_g = h4[7:0] ^ {v4[6:0], 1'b0};
wire [7:0]  bg_b = h4[8:1] + (v4[8:1] * 8'd3);
wire [23:0] bg   = {bg_r, bg_g, bg_b};

// the inputs
reg  [2:0]  state = 3'd0;
reg  [1:0]  speed = 2'd0;
reg         rev = 1'b0;
reg  [15:0] chapter = 16'd0, nch = 16'd0, aud_present = 16'd0;
reg  [31:0] sub_present = 32'd0;            // P7
reg  [32:0] sh_pts = 33'd0;
reg         sh_pts_v = 1'b0, show = 1'b0;
reg  [1:0]  sh_ep = 2'd0;
reg  [63:0] pl_dur = 64'd0;
reg  [7:0]  title_len = 8'd0;
reg         title_trunc = 1'b0;
reg         mount = 1'b0, disp = 1'b0, nxt = 1'b0, prv = 1'b0, unpl = 1'b0;
reg  [1:0]  pmsg = 2'd0;                      // P6d: the Control Panel button refused
reg         ab_up = 1'b0, ab_b = 1'b0, ab_loop = 1'b0, ab_na = 1'b0;   // A-B Repeat (ab_ctl's)
reg         show_aud = 1'b0, show_sub = 1'b0;  // P6d follow-up: the first Audio / Subtitle press
reg  [3:0]  aud_cur = 4'd0;
reg         sub_on_cur = 1'b0;
reg  [4:0]  sub_cur = 5'd0;
wire        tag_aud, tag_sub;
reg         ev_valid = 1'b0;
reg  [3:0]  ev_code = 4'd0;
reg  [15:0] ev_data = 16'd0;
reg         item_start = 1'b0;
reg  [1:0]  item_tag = 2'd0;
reg  [47:0] item_in = 48'd0, item_base = 48'd0;
// P6c: goto_ctl's outputs
reg         goto_open = 1'b0, goto_sel = 1'b0, goto_mv = 1'b0;
reg  [2:0]  goto_edit = 3'd0;
reg  [15:0] goto_chap = 16'd0;
reg  [38:0] goto_t = 39'd0, goto_mark = 39'd0;
wire [38:0] el_ticks;
// umd_reader's title and language stores (registered reads, as the reader's)
reg  [7:0]  tmem [0:127];
reg  [15:0] lmem [0:63];
wire [6:0]  title_addr;
wire [5:0]  lang_sel;
reg  [7:0]  title_q = 8'd0;
reg  [15:0] lang_q = 16'd0;
always @(posedge clk) begin
    title_q <= tmem[title_addr];
    lang_q  <= lmem[lang_sel];
end

wire [23:0] rgb;
wire        display, t_ph, t_bad, t_cut;
transport_hud #(.POPUP_FRAMES(POPUP)) dut (
    .clk(clk), .rst_n(rst_n), .mount(mount), .show(show), .il(il), .safe(safe),
    .h_pos(h), .v_pos(v), .de_in(de), .bg(bg), .rgb(rgb),
    .state(state), .tk_speed(speed), .tk_rev(rev), .chapter(chapter), .n_chapters(nch),
    .ev_valid(ev_valid), .ev_code(ev_code), .ev_data(ev_data),
    .cmd_next(nxt), .cmd_prev(prv), .disp_toggle(disp), .unplay(unpl), .pmsg(pmsg),
    .ab_up(ab_up), .ab_b(ab_b), .ab_loop(ab_loop), .ab_na(ab_na),
    .show_aud(show_aud), .show_sub(show_sub), .aud_cur(aud_cur), .sub_on_cur(sub_on_cur), .sub_cur(sub_cur),
    .tag_aud(tag_aud), .tag_sub(tag_sub), .aud_present(aud_present), .sub_present(sub_present),
    .sh_pts(sh_pts), .sh_pts_v(sh_pts_v), .sh_ep(sh_ep),
    .item_start(item_start), .item_tag(item_tag), .item_in(item_in), .item_base(item_base),
    .pl_dur(pl_dur), .el_ticks(el_ticks),
    .goto_open(goto_open), .goto_sel(goto_sel), .goto_edit(goto_edit), .goto_chap(goto_chap),
    .goto_t(goto_t), .goto_mv(goto_mv), .goto_mark(goto_mark),
    .title_addr(title_addr), .title_q(title_q), .title_len(title_len), .title_trunc(title_trunc),
    .lang_sel(lang_sel), .lang_q(lang_q),
    .display(display), .t_ph(t_ph), .t_bad(t_bad), .t_cut(t_cut)
);

// the script
localparam OP_WAIT = 1, OP_SET = 2, OP_PULSE = 3, OP_EVENT = 4, OP_ITEM = 5, OP_TITLE = 6,
           OP_LANG = 7, OP_FRAME = 8, OP_END = 9, OP_WAITPOP = 10, OP_RESET = 11;
reg  [31:0] sw [0:4095];
reg  [23:0] exp_px [0:720*480-1];
reg  [23:0] got_px [0:720*480-1];
localparam int MAXST = 128;            // states the bench holds; more is a harness FAIL, never a silent cut
string      dir, nm, names [0:MAXST-1];
integer     n_states, n_fail, pc, s, i, bad, fd, first_x, first_y;
reg  [23:0] first_got, first_want;

// every stimulus change lands #1 after an edge: set AT the edge, a DUT flop could see it twice
task cyc(input integer n); integer k; begin for (k = 0; k < n; k = k + 1) @(posedge clk); #1; end endtask

integer dfd;
task score_frame(input integer k);
    begin
        if ($test$plusargs("dump"))
            $display("  [dbg] ws %0d display %0d s_disp %0d l_head %0d job %0d dk %0d nv %0d kind %0d",
                     dut.ws, dut.display, dut.s_disp, dut.l_head, dut.job, dut.dk, dut.nv, dut.kind);
        dfd = $test$plusargs("dump") ? $fopen($sformatf("%0s/s%02d.got.hex", dir, k), "w") : 0;
        // from the top of the next frame, every active pixel (sampled #1 after the edge: the
        // pipeline's nonblocking updates have landed)
        @(posedge clk); #1;
        while (!(h4 == 12'd0 && v4 == 12'd0)) begin @(posedge clk); #1; end
        bad = 0;
        while (1) begin
            if (d4) begin
                got_px[v4 * 720 + h4] = rgb;
                if (rgb !== exp_px[v4 * 720 + h4]) begin
                    if (bad == 0) begin first_x = h4; first_y = v4; first_got = rgb; first_want = exp_px[v4 * 720 + h4]; end
                    bad = bad + 1;
                end
            end
            @(posedge clk); #1;
            if (h4 == 12'd0 && v4 == 12'd0) break;
        end
        if (dfd != 0) begin
            for (i = 0; i < 720 * 480; i = i + 1) $fwrite(dfd, "%06x\n", got_px[i]);
            $fclose(dfd);
        end
        if (bad != 0) begin
            $display("FAIL [%0s] %0d pixels differ; first at (%0d, %0d): %06x, want %06x", names[k], bad,
                     first_x, first_y, first_got, first_want);
            n_fail = n_fail + 1;
        end else
            $display("  ok %0s", names[k]);
    end
endtask

initial begin
    if (!$value$plusargs("dir=%s", dir)) begin $display("FAIL [harness] no +dir"); $fatal(1); end
    il = $test$plusargs("il");               // the 480i (title-safe) layout, docs/analog.md S8
    safe = il || $test$plusargs("safe");
    fd = $fopen({dir, "/states.txt"}, "r");
    if (fd == 0) begin $display("FAIL [harness] no states.txt"); $fatal(1); end
    n_states = 0;
    // (until P8 this stopped at 64 without a word: b26-b28 pushed g06-g08 off the end, and H35 / H37
    //  "survived" -- their only states were no longer run)
    while (!$feof(fd)) begin
        if ($fscanf(fd, "%s\n", nm) == 1) begin
            if (n_states == MAXST) begin
                $display("FAIL [harness] more than %0d states in states.txt", MAXST); $fatal(1);
            end
            names[n_states] = nm; n_states = n_states + 1;
        end
    end
    $fclose(fd);
    n_fail = 0;
    for (s = 0; s < n_states; s = s + 1) begin
        for (i = 0; i < 4096; i = i + 1) sw[i] = {OP_END[7:0], 24'd0};
        $readmemh($sformatf("%0s/s%02d.stim.hex", dir, s), sw);
        $readmemh($sformatf("%0s/s%02d.exp.hex", dir, s), exp_px);
        pc = 0;
        while (sw[pc][31:24] != OP_END) begin
            case (sw[pc][31:24])
            OP_RESET: begin
                rst_n = 1'b0; state = 3'd0; speed = 2'd0; rev = 1'b0; sh_pts_v = 1'b0; sub_present = 32'd0;
                goto_open = 1'b0; goto_sel = 1'b0; goto_mv = 1'b0; goto_edit = 3'd0; goto_chap = 16'd0;
                goto_t = 39'd0; goto_mark = 39'd0; ab_up = 1'b0; ab_b = 1'b0; ab_loop = 1'b0;
                for (i = 0; i < 128; i = i + 1) tmem[i] = 8'd0;
                for (i = 0; i < 64; i = i + 1) lmem[i] = 16'd0;
                cyc(4); rst_n = 1'b1; cyc(4); pc = pc + 1;
            end
            OP_WAIT: begin cyc(sw[pc][23:0]); pc = pc + 1; end
            OP_WAITPOP: begin cyc((POPUP + 1) * HT * VT); pc = pc + 1; end
            OP_SET: begin
                case (sw[pc][23:0])
                0: state = sw[pc+1][2:0];         1: speed = sw[pc+1][1:0];
                2: rev = sw[pc+1][0];             3: chapter = sw[pc+1][15:0];
                4: nch = sw[pc+1][15:0];          5: aud_present = sw[pc+1][15:0];
                6: sh_pts[31:0] = sw[pc+1];       7: sh_pts[32] = sw[pc+1][0];
                8: sh_pts_v = sw[pc+1][0];        9: sh_ep = sw[pc+1][1:0];
                10: pl_dur[31:0] = sw[pc+1];      11: pl_dur[63:32] = sw[pc+1];
                12: title_len = sw[pc+1][7:0];    13: title_trunc = sw[pc+1][0];
                14: show = sw[pc+1][0];          15: sub_present = sw[pc+1];   // P7
                16: goto_open = sw[pc+1][0];     17: goto_sel = sw[pc+1][0];   // P6c
                18: goto_edit = sw[pc+1][2:0];   19: goto_chap = sw[pc+1][15:0];
                20: goto_t[31:0] = sw[pc+1];     21: goto_t[38:32] = sw[pc+1][6:0];
                22: goto_mv = sw[pc+1][0];       23: goto_mark[31:0] = sw[pc+1];
                24: goto_mark[38:32] = sw[pc+1][6:0];
                25: aud_cur = sw[pc+1][3:0];     26: sub_on_cur = sw[pc+1][0];   // P6d follow-up
                27: sub_cur = sw[pc+1][4:0];
                28: ab_up = sw[pc+1][0];         29: ab_b = sw[pc+1][0];         // A-B Repeat
                30: ab_loop = sw[pc+1][0];
                default: begin $display("FAIL [harness] SET %0d", sw[pc][23:0]); $fatal(1); end
                endcase
                @(posedge clk); #1; pc = pc + 2;
            end
            OP_PULSE: begin
                case (sw[pc][23:0]) 0: mount = 1'b1; 1: disp = 1'b1; 2: nxt = 1'b1; 3: prv = 1'b1; 4: unpl = 1'b1;
                                    5: pmsg = 2'd1; 6: pmsg = 2'd2; 7: show_aud = 1'b1; 8: show_sub = 1'b1;
                                    9: ab_na = 1'b1;
                                    default: begin $display("FAIL [harness] PULSE %0d", sw[pc][23:0]); $fatal(1); end endcase
                @(posedge clk); #1; mount = 1'b0; disp = 1'b0; nxt = 1'b0; prv = 1'b0; unpl = 1'b0; pmsg = 2'd0;
                show_aud = 1'b0; show_sub = 1'b0; ab_na = 1'b0;
                cyc(2);
                // P6d follow-up: a show raises its own tag's level (emu sends the next press on as the cycle)
                if (sw[pc][23:0] == 7 && (tag_aud !== 1'b1 || tag_sub !== 1'b0)) begin
                    $display("FAIL [tags] after show_aud: tag_aud %b tag_sub %b, want 1 0", tag_aud, tag_sub); $fatal(1); end
                if (sw[pc][23:0] == 8 && (tag_sub !== 1'b1 || tag_aud !== 1'b0)) begin
                    $display("FAIL [tags] after show_sub: tag_sub %b tag_aud %b, want 1 0", tag_sub, tag_aud); $fatal(1); end
                pc = pc + 1;
            end
            OP_EVENT: begin
                ev_code = sw[pc][3:0]; ev_data = sw[pc+1][15:0]; ev_valid = 1'b1;
                @(posedge clk); #1; ev_valid = 1'b0; cyc(2); pc = pc + 2;
            end
            OP_ITEM: begin
                item_tag = sw[pc][1:0]; item_in = {sw[pc+2][15:0], sw[pc+1]}; item_base = {sw[pc+4][15:0], sw[pc+3]};
                item_start = 1'b1; @(posedge clk); #1; item_start = 1'b0; pc = pc + 5;
            end
            OP_TITLE: begin tmem[sw[pc][14:8]] = sw[pc][7:0]; pc = pc + 1; end
            OP_LANG: begin lmem[sw[pc][5:0]] = sw[pc+1][15:0]; pc = pc + 2; end
            OP_FRAME: begin score_frame(sw[pc][23:0]); pc = pc + 1; end
            default: begin $display("FAIL [harness] op %0d at %0d", sw[pc][31:24], pc); $fatal(1); end
            endcase
        end
    end
    if (n_fail != 0) begin
        $display("FAIL: transport_hud_tb: %0d of %0d states differ", n_fail, n_states);
        $fatal(1);
    end
    $display("transport_hud_tb: %0d states pixel-exact (%0d x 480 each)", n_states, 720);
    $display("PASS: transport_hud_tb");
    $finish;
end

endmodule
