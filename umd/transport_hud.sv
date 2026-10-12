// umd/transport_hud.sv -- the transport HUD (P6b5; docs/transport_hud.md S6, the look the
// maintainer approved on the mockups, 2026-09-29)
//
// The golden is tools/transport_layout.py (compose() + render()); every constant comes from
// it through umd/transport_hud.svh and umd/transport_str.mem, and the font from
// tools/transport_font.py (umd/transport_font.mem). bench/umd/run_transport_hud.sh scores
// this module pixel-exact against the model in every state.
//
// WHAT IT DRAWS (S6.3): the state icon bottom-left (always with Display on; with it off
// while paused, stopped or in trick play, else as a pop-up); a boxed caption above it
// (`Forward n` / `Reverse n`, `Chapter n` after Next / Prev, `<note> n Language` after an
// audio switch); the message band (`There is no chapter available.`); the Display overlay
// (a header wash with the film mark and the title, `Chapter n` and the time boxed, the bar).
// Pop-ups last POPUP_FRAMES raster frames and cut hard; the latest event replaces the one on
// screen.
//
// THE PIXEL PATH (a pure function of (h, v), 480i-safe): LAT = 4 clocks from h_pos / v_pos /
// de_in to the registered layer / class / colour, like xmb_wave, so `bg` is the
// picture at that same stage and `rgb` = the HUD over it, COMBINATIONAL (emu registers it).
//   s1  the slot hit, col = hx / 10 (hx * 205 >> 11, exact below 1029), the layers' tests
//   s2  the plane: {glyph 7, colour 2, box 2} at {slot, col}
//   s3  the font row: glyph * 24 + row
//   s4  the pixel's class (2 bits, MSB pair = the leftmost pixel); the box from the cell's
//       box attribute: 1 the whole cell, 2 its first BOX_PAD pixels, 3 its last BOX_PAD
//   The plane's columns are the model's plus one (column 0 is x 2-11), so a box's padding
//   before the model's column 0 and after its column 68 has a cell to live in.
//   out under = bg -> header / band tint -> bar rim / bar / box; then the class over it:
//       1 under >> 2, 2 the ink, 3 (ink >> 1) + (under >> 1). Shifts and adds only.
//
// THE WRITER (event rate): an endless pass -- snapshot the inputs, convert the numbers,
// write every cell of the four slots with its FINAL value (one write a cell: the scan-out
// never sees a cell cleared and redrawn; the boxes are the cells' attributes), then latch the
// layers (the header, the band, the bar's fill). ~600 cycles a pass.
//   Numbers by ONE shared subtractor: a time's digits straight from its 90 kHz ticks by
//   repeated subtraction of each digit's weight (no divider), the chapter's and the track's
//   digits the same way, and the bar's 10-bit quotient min(el, tot) * 512 / tot by a
//   restoring division (the remainder shifts; the divisor is the total itself); the fill is
//   q * 438 >> 9.
//   The title (S6.3, D6): one cell a UTF-8 character, one placeholder for any non-ASCII
//   character, a malformed sequence a placeholder too; a title past 66 cells, or cut by
//   the reader at 128 bytes, ends in an ellipsis. Flags out: t_ph, t_bad, t_cut.
//
// GO TO (P6c, docs/p6c.md §9; goto_ctl.sv holds the editor): the Display layout with its time row
// the editor -- `Chapter n` (a title with chapters; n the editor's) and the TARGET time over the
// total, all white; the focused box in the lighter SEL tint, the field being edited in the EDIT
// tint with an up-arrow above it (the message row) and a down-arrow below (the icon row: one cell
// over an odd field, two over an even one); a blue down-arrow above the bar at the target
// (mark_v). The caption row is the editor's while it is open: no pop-up caption is drawn. A
// cell's box attribute is three kinds -- its first BOX_PAD pixels, its middle, its last BOX_PAD --
// so a field's padding over its neighbours wins, as the model's per-pixel strongest kind does. The
// marker's x is a second restoring division on the shared subtractor (job 5).
//
// A-B REPEAT (docs/ab_repeat.md §4, the PSP; ab_ctl.sv): `A-B` in the icon row one empty cell after
// the state icon (after the badge in trick play), white, no box. ab_up (A set, or B's 2 s hold) holds
// the icon and the tag up on their own; while it loops past the hold the tag shows only beside an icon
// up for its own reason (Display, paused, a pop-up). ab_b: the B drawn (A set: the 1 Hz blink's phase).
// ab_na: A-B pressed on a bare file -- the P8 message.
//
// ELAPSED (transport.md S2.7): the shown picture's item (its tag, sh_ep) -> {IN, base} from
// a 4-entry table written at every item start (umd_reader's item_in_pts and item_base, the
// sum of the earlier items' OUT - IN) -> base + max(sh_pts - IN, 0). Times are held in 39
// bits (1,696 h), saturating. The PTS is read live one cycle after the table: a pickup landing
// in exactly that cycle at an item change gives one pass (~25 us) a wrong time, never held.
//
// Quartus 17: no functions, no N'() casts; selects as cases.

module transport_hud #(
    parameter int POPUP_FRAMES = 180          // 3 s of the 60 Hz raster
) (
    input  wire         clk,                   // clk_sys
    input  wire         rst_n,
    input  wire         mount,                 // pulse: a new title
    input  wire         show,                  // draw (an image is loaded)
    input  wire         il,                    // the 480i raster: a frame top is each FIELD's (docs/analog.md V3)
    input  wire         safe,                  // the title-safe layout (_I): 480i, or Zoom's band (fj#71, docs/zoom.md)
    // the raster
    input  wire  [11:0] h_pos,
    input  wire  [11:0] v_pos,
    input  wire         de_in,
    input  wire  [23:0] bg,                    // the picture at LAT 4 ({r, g, b})
    output logic [23:0] rgb,                   // the HUD over it (combinational)
    // the player (player_ctl)
    input  wire   [2:0] state,                 // ST_IDLE 0, ST_PLAY 1, ST_PAUSE 2, ST_STOP 3
    input  wire   [1:0] tk_speed,              // trick play 1-3, 0 off
    input  wire         tk_rev,
    input  wire  [15:0] chapter,
    input  wire  [15:0] n_chapters,
    input  wire         ev_valid,              // player_ctl's event FIFO (popped every cycle)
    input  wire   [3:0] ev_code,
    input  wire  [15:0] ev_data,
    input  wire         cmd_next,              // pulses: a Next / Prev Chapter press
    input  wire         cmd_prev,
    input  wire         disp_toggle,           // pulse: the Display button
    input  wire         unplay,                // pulse: the core stopped on the disc (a refused stream, a reader error; A11)
    input  wire  [1:0]  pmsg,                  // P6d pulse: the Control Panel button refused -- 1 no UMD Main, 2 one that did not take it
    input  wire         ab_up,                 // A-B Repeat (ab_ctl): the icon and the tag up on their own
    input  wire         ab_b,                  //   the B drawn
    input  wire         ab_loop,               //   it loops: the tag beside an icon up for its own reason
    input  wire         ab_na,                 //   pulse: pressed on a bare file (the P8 message)
    // P6d follow-up (the maintainer, 2026-10-05): Audio / Subtitle SHOW the current track first. A press
    // while its tag is not up pops the tag with the current values (no change); emu sends the press on
    // as the cycle only while the tag is up (tag_aud / tag_sub)
    input  wire         show_aud,              // pulse: pop the audio tag with aud_cur
    input  wire         show_sub,              // pulse: pop the subtitle tag with sub_on_cur / sub_cur
    input  wire  [3:0]  aud_cur,               // player_ctl's audio track (0xBD00 + n)
    input  wire         sub_on_cur,            // player_ctl's subtitles on
    input  wire  [4:0]  sub_cur,               // ... and their track (0x80 + n)
    output wire         tag_aud,               // the audio tag is up
    output wire         tag_sub,               // the subtitle tag is up
    input  wire  [15:0] aud_present,           // the clip's declared audio tracks
    input  wire  [31:0] sub_present,           // P7: its declared subtitle tracks (0x80 + n)
    // the time
    input  wire  [32:0] sh_pts,                // the shown picture (disp_ctl)
    input  wire         sh_pts_v,
    input  wire   [1:0] sh_ep,                 //   its item tag
    input  wire         item_start,            // umd_reader: an item starts
    input  wire   [1:0] item_tag,              //   its index mod 4
    input  wire  [47:0] item_in,               //   its IN
    input  wire  [47:0] item_base,             //   the earlier items' durations
    input  wire  [63:0] pl_dur,                // the playlist's duration
    output wire  [38:0] el_ticks,              // P6c: the elapsed time of the last pass (goto_ctl opens on it)
    // Go To (P6c, goto_ctl)
    input  wire         goto_open,
    input  wire         goto_sel,              //   the focused box: 0 the chapter, 1 the time
    input  wire   [2:0] goto_edit,             //   0 none, 1 the chapter, 2 / 3 / 4 hours / minutes / seconds
    input  wire  [15:0] goto_chap,
    input  wire  [38:0] goto_t,                //   the target time
    input  wire         goto_mv,               //   the marker shown
    input  wire  [38:0] goto_mark,             //   its time
    // the title (umd_reader's second title port) and the track's language
    output logic  [6:0] title_addr,
    input  wire   [7:0] title_q,               // registered: title_mem[title_addr]
    input  wire   [7:0] title_len,
    input  wire         title_trunc,
    output wire   [5:0] lang_sel,
    input  wire  [15:0] lang_q,                // registered: {first letter, second}
    // status
    output logic        display,               // the overlay is on
    output logic        t_ph,                  // the title shows a placeholder
    output logic        t_bad,                 //   ... for a malformed sequence
    output logic        t_cut                  //   ... ends in an ellipsis
);

`include "umd/transport_hud.svh"
// The layout (docs/analog.md S8): the 480p set, or at 480i its title-safe twin (_I) -- the HUD
// moved as a block inside the 80 % area a CRT's overscan leaves; `safe` is quasi-static (a raster
// change restarts the raster; Zoom changes at the vblank), so a pass that straddles a change draws
// one frame in the old set. fj#71 (docs/zoom.md): under Zoom emu selects the same twin on the 480p
// raster (`safe` without `il`) and feeds v_pos 7 lines up -- the twin inside the band 60 .. 419.
wire [10:0] x0      = safe ? X0_I : X0;
wire [6:0]  cols    = safe ? COLS_I : COLS;
wire [6:0]  troom   = cols - 7'd3;          // the title's cells (66 / 54): from column 4 to cols
wire [9:0]  sy0     = safe ? SLOT_Y0_I : SLOT_Y0, sy1 = safe ? SLOT_Y1_I : SLOT_Y1,
            sy2     = safe ? SLOT_Y2_I : SLOT_Y2, sy3 = safe ? SLOT_Y3_I : SLOT_Y3;
wire [9:0]  hdr_y1  = safe ? HDR_Y1_I : HDR_Y1;
wire [9:0]  band_y0 = safe ? BAND_Y0_I : BAND_Y0, band_y1 = safe ? BAND_Y1_I : BAND_Y1;
wire [10:0] bar_x0  = safe ? BAR_X0_I : BAR_X0, bar_x1 = safe ? BAR_X1_I : BAR_X1;
wire [9:0]  bar_y0  = safe ? BAR_Y0_I : BAR_Y0, bar_y1 = safe ? BAR_Y1_I : BAR_Y1;
wire [6:0]  msg_col0 = safe ? MSG_COL0_I : MSG_COL0, msg_col1 = safe ? MSG_COL1_I : MSG_COL1,
            msg_col2 = safe ? MSG_COL2_I : MSG_COL2, msg_col3 = safe ? MSG_COL3_I : MSG_COL3,
            msg_col4 = safe ? MSG_COL4_I : MSG_COL4, msg_col5 = safe ? MSG_COL5_I : MSG_COL5,
            msg_col6 = safe ? MSG_COL6_I : MSG_COL6;

localparam [2:0] ST_PLAY = 3'd1, ST_PAUSE = 3'd2, ST_STOP = 3'd3;
localparam [3:0] EV_NO_CHAPTER = 4'd4, EV_TRACK = 4'd7, EV_SUB = 4'd9, EV_HOST = 4'd10, EV_UNAVAIL = 4'd11;
// the event on screen
localparam [2:0] K_NONE = 3'd0, K_PLAY = 3'd1, K_FF = 3'd2, K_REW = 3'd3, K_NEXT = 3'd4,
                 K_PREV = 3'd5, K_TRACK = 3'd6, K_MSG = 3'd7;
localparam [6:0] G_0 = 7'd16, G_COLON = 7'd26, G_SLASH = 7'd15, G_PLUS = 7'd11;
localparam [1:0] C_WHITE = 2'd0, C_ACCENT = 2'd1;
localparam [1:0] SL_HEAD = 2'd0, SL_MSG = 2'd1, SL_CAP = 2'd2, SL_ICON = 2'd3;

// =========================================================================================
// Memories: the plane (4 slots x 128 cells), the font, the strings, the item table
// =========================================================================================
reg  [14:0] plane [0:511];                    // {glyph 7, colour 2, box kinds: first pad 2, middle 2, last pad 2}
reg  [19:0] font  [0:3071];
reg  [6:0]  srom  [0:511];                    // (P6d: 256 -> 512, the control panel's two messages)
reg  [71:0] itab  [0:3];                       // {IN[32:0], base[38:0]}
initial begin
    $readmemh("umd/transport_font.mem", font);
    $readmemh("umd/transport_str.mem", srom);
end
integer ii, ri, si;
initial for (ii = 0; ii < 512; ii = ii + 1) plane[ii] = 15'd0;

// =========================================================================================
// The events: what pops up, for how long
// =========================================================================================
reg  [2:0]  kind;
reg  [2:0]  mid;                               // K_MSG's message: 0 no chapter, 1 no UMD Main, 2 a stale one (A7), 3 cannot be played (A11),
                                               // 4 / 5 the control panel's no UMD Main / a stale one (P6d)
                                               //   6 not available for this file (P8)
reg  [7:0]  pfr;                               // frames left
reg  [4:0]  trk;                               // the track the TRACK pop-up names
reg         tsub, toff;                        // P7: it is the subtitles' (the balloon); Off
reg  [2:0]  state_q;
reg  [1:0]  spd_q;
reg         top_q;
// (480i: v_pos is the frame line, a field starts at 0 or 1 -- the pop-up timer counts refreshes)
wire        top  = (h_pos == 12'd0) && (v_pos == 12'd0 || (il && v_pos == 12'd1));
wire        ftk  = top && !top_q;              // a frame starts (h_pos may hold for a few clocks)
// the triggers, the latest wins: an event over a press over a mode change
reg         trig;
reg  [2:0]  tkind;
reg  [2:0]  tmid;
always @(*) begin
    trig = 1'b0; tkind = K_NONE; tmid = 3'd0;
    if (state == ST_PLAY && state_q != ST_PLAY && tk_speed == 2'd0) begin trig = 1'b1; tkind = K_PLAY; end
    if (tk_speed != spd_q) begin
        if (tk_speed != 2'd0) begin trig = 1'b1; tkind = tk_rev ? K_REW : K_FF; end
        else if (state == ST_PLAY) begin trig = 1'b1; tkind = K_PLAY; end
    end
    if (cmd_next) begin trig = 1'b1; tkind = K_NEXT; end
    if (cmd_prev) begin trig = 1'b1; tkind = K_PREV; end
    if (ev_valid && ev_code == EV_NO_CHAPTER) begin trig = 1'b1; tkind = K_MSG; end
    // A7: the Subtitle button refused for want of the UMD Main (data[0]: one with the wrong PROTO)
    if (ev_valid && ev_code == EV_HOST) begin trig = 1'b1; tkind = K_MSG; tmid = ev_data[0] ? 3'd2 : 3'd1; end
    // P6d: the Control Panel button reached the core (emu: not taken by a UMD Main with the panel)
    if (pmsg != 2'd0) begin trig = 1'b1; tkind = K_MSG; tmid = (pmsg == 2'd1) ? 3'd4 : 3'd5; end
    // P8: a seek asked of a bare stream file (player_ctl's UNAVAIL)
    if (ev_valid && ev_code == EV_UNAVAIL) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd6; end
    if (ab_na) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd6; end      // (A-B Repeat on a bare file)
    // A11: the core stopped on the disc (emu: a new front-end refusal, or the reader's error)
    if (unplay) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd3; end
    if (ev_valid && ev_code == EV_TRACK) begin trig = 1'b1; tkind = K_TRACK; end
    if (show_aud || show_sub) begin trig = 1'b1; tkind = K_TRACK; end      // P6d follow-up: the current track
    // P7: the same tag, the balloon -- for the Subtitle button only: a disc's own SUB_SET (data[6]; The
    // Island sets subtitles off at every play) shows nothing, as on the PSP (P9 M4b, the maintainer on the rig)
    if (ev_valid && ev_code == EV_SUB && !ev_data[6]) begin trig = 1'b1; tkind = K_TRACK; end
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        kind <= K_NONE; mid <= 3'd0; pfr <= 8'd0; trk <= 5'd0; tsub <= 1'b0; toff <= 1'b0; state_q <= 3'd0; spd_q <= 2'd0; top_q <= 1'b0;
        display <= 1'b0;
    end else begin
        state_q <= state;
        spd_q   <= tk_speed;
        top_q   <= top;
        if (disp_toggle) display <= ~display;
        if (show_aud) begin trk <= {1'b0, aud_cur}; tsub <= 1'b0; toff <= 1'b0; end
        if (show_sub) begin trk <= sub_cur; tsub <= 1'b1; toff <= !sub_on_cur; end
        if (ev_valid && ev_code == EV_TRACK) begin trk <= {1'b0, ev_data[3:0]}; tsub <= 1'b0; toff <= 1'b0; end
        if (ev_valid && ev_code == EV_SUB && !ev_data[6]) begin trk <= ev_data[4:0]; tsub <= 1'b1; toff <= !ev_data[5]; end
        if (mount) begin
            kind <= K_NONE; pfr <= 8'd0;
        end else if (trig) begin
            kind <= tkind; mid <= tmid; pfr <= POPUP_FRAMES[7:0];
        end else if (ftk && pfr != 8'd0) begin
            pfr <= pfr - 8'd1;
            if (pfr == 8'd1) kind <= K_NONE;
        end
    end
end
// the language table: audio 0-15, subtitles 16-47 (umd_reader's lang_sel)
assign lang_sel = tsub ? 6'd16 + {1'b0, trk} : {1'b0, trk};
assign tag_aud  = (kind == K_TRACK) && !tsub;          // P6d follow-up: a press now cycles
assign tag_sub  = (kind == K_TRACK) && tsub;

// the item table: every item start, {IN, the earlier items' durations}
always @(posedge clk)
    if (item_start)
        itab[item_tag] <= {item_in[32:0], (item_base[47:39] != 9'd0) ? {39{1'b1}} : item_base[38:0]};

// =========================================================================================
// The writer
// =========================================================================================
localparam [4:0] W_SNAP = 5'd0, W_SNAP1 = 5'd1, W_SNAP2 = 5'd2, W_NUM = 5'd3, W_LEN = 5'd4,
                 W_EMIT = 5'd5, W_EDRAIN = 5'd6, W_TADDR = 5'd7, W_TW1 = 5'd8, W_TPROC = 5'd9,
                 W_TEND = 5'd10, W_FILL = 5'd11, W_COMMIT = 5'd12, W_LEN2 = 5'd13, W_LEN3 = 5'd14,
                 W_LEN4 = 5'd15;

reg  [4:0]  ws;
// the snapshot
reg         s_disp, s_trick, s_rev;
reg         s_abu, s_abb, s_abl;              // A-B Repeat's
reg  [2:0]  s_kind, s_state;
reg  [2:0]  s_mid;
reg  [1:0]  s_spd;
reg  [15:0] s_chap, s_lang;
reg         s_nch;                            // the title has chapters
reg  [5:0]  s_rank;
reg         s_tsub, s_toff;                   // P7
reg         s_ptsv;
reg  [38:0] s_tot, s_el;
reg         s_go, s_gsel, s_mv;               // P6c: Go To's
reg  [2:0]  s_gedit;
reg  [38:0] s_gt, s_mk;
wire        s_ovl = s_disp || s_go;           // the overlay layout (the header, the time row, the bar)
wire [38:0] s_tv  = s_go ? s_gt : s_el;       // the time the row shows
assign el_ticks = s_el;
reg  [71:0] it_q;
// the numbers
reg  [2:0]  job;                              // 0 total, 1 elapsed (Go To: the target), 2 chapter, 3 track, 4 bar, 5 the marker
reg  [2:0]  dk;                               // the digit being taken
reg  [3:0]  dcnt;
reg  [39:0] nv;                               // the value being converted / the remainder
reg  [9:0]  q;
reg  [3:0]  qi;                               // the quotient bit being taken
reg  [3:0]  dg_t [0:6];                       // total: h2 h1 h0 m1 m0 s1 s0
reg  [3:0]  dg_e [0:6];                       // elapsed
reg  [3:0]  dg_c [0:4];                       // chapter
reg  [3:0]  dg_r [0:1];                       // the track's rank
reg         hdig3, sat_t, sat_e;
reg  [8:0]  fill, mfill;
reg  [9:0]  qb;                               // P6c: the bar's quotient, kept while job 5 takes the marker's
reg  [6:0]  fc, ac;                           // P6c: the edited field's first column, the arrows'
reg  [2:0]  fn;                               //   its cells
reg         aw2;                              //   the arrows are the two-cell pair (combinational)
// the lengths and columns
reg  [2:0]  ch_nd;                            // the chapter's digits (1-5)
reg  [1:0]  tr_nd;                            // the rank's (1-2)
reg  [3:0]  nm_len;                           // the language name's length
reg  [2:0]  li;                               // its index in the name table
reg         li_v;
reg  [4:0]  cap_len;
reg  [4:0]  cl;                               // "Chapter n"
reg  [4:0]  tl, le;                           // the time field; its elapsed part
reg  [6:0]  tcol, ccol;
reg         chap_on;
// the emitter
reg  [1:0]  e_slot;
reg  [6:0]  e_col;
reg         e1_v, e1_rom;
reg  [1:0]  e1_slot;
reg  [6:0]  e1_col;
reg  [6:0]  e1_g;
reg  [1:0]  e1_c;
reg  [5:0]  e1_bx;
reg  [6:0]  rom_q;
// the title
reg  [7:0]  ta;
reg  [6:0]  tcnt;                             // cells made (saturates at 127)
reg  [1:0]  need;
reg         tph, tbad, tend;
reg  [6:0]  pend;                             // the 66th cell, held (it may become the ellipsis)
reg  [6:0]  fcol;
reg         pw_v;                             // a title-path plane write
reg  [6:0]  pw_col, pw_g;
// the layers, latched at a pass's end
reg         l_head, l_band, l_bar, l_mark;
reg  [8:0]  l_fill, l_mfill;

// ---- the shared subtractor ----------------------------------------------------------------
reg  [39:0] nw;                               // the operand: a digit's weight or the total
always @(*) begin
    nw = 40'd0;
    case (job)
    3'd0, 3'd1: case (dk)
        3'd0: nw = {1'b0, TW0}; 3'd1: nw = {1'b0, TW1}; 3'd2: nw = {1'b0, TW2};
        3'd3: nw = {1'b0, TW3}; 3'd4: nw = {1'b0, TW4}; 3'd5: nw = {1'b0, TW5};
        default: nw = {1'b0, TW6};
        endcase
    3'd2: case (dk)
        3'd0: nw = 40'd10000; 3'd1: nw = 40'd1000; 3'd2: nw = 40'd100; 3'd3: nw = 40'd10;
        default: nw = 40'd1;
        endcase
    3'd3: nw = (dk == 3'd0) ? 40'd10 : 40'd1;
    default: nw = {1'b0, s_tot};
    endcase
end
wire [40:0] nsub = {1'b0, nv} - {1'b0, nw};
wire        nge  = !nsub[40];

// the item table's read, every cycle (so its register is the RAM's own)
always @(posedge clk) it_q <= itab[sh_ep];
// the value the next number job starts from: elapsed, the chapter, the rank, elapsed again (the
// bar: its first step takes a quotient of 512 when elapsed >= total)
wire [39:0] nv_ld = (job == 3'd0) ? {1'b0, s_tv} : (job == 3'd1) ? {24'd0, s_chap} :
                    (job == 3'd2) ? {34'd0, s_rank} : {1'b0, s_el};

// elapsed = base + max(PTS - IN, 0) (the PTS live: the header's note)
wire [33:0] el_d   = {1'b0, sh_pts} - {1'b0, it_q[71:39]};
wire [39:0] el_sum = {1'b0, it_q[38:0]} + (el_d[33] ? 40'd0 : {7'd0, el_d[32:0]});

// the track's rank: its place among the clip's declared tracks, from 1
// (P7: a subtitle track's among the subtitle tracks, up to 32)
// (the mask chosen first: Quartus refuses aud_present[16..31] even behind a range guard)
wire [31:0] rk_mask = tsub ? sub_present : {16'd0, aud_present};
reg  [5:0]  rank_c;
always @(*) begin
    rank_c = 6'd1;
    for (ri = 0; ri < 32; ri = ri + 1)
        if (ri < trk && rk_mask[ri]) rank_c = rank_c + 6'd1;
end

// ---- a cell (the non-title slots and the header's first cells) -------------------------------
// e_slot / e_col (the PLANE's column: the model's + 1) -> {from the string ROM (its address) or
// a glyph, the colour, the box attribute}
reg         c_rom;
reg  [8:0]  c_a;
reg  [6:0]  c_g;
reg  [1:0]  c_c;
reg  [5:0]  c_bx;
wire [6:0]  mc    = e_col - 7'd1;             // the model's column (127: the pad cell before 0)
wire        mc_ok = (e_col != 7'd0) && (e_col <= cols);
wire [6:0]  mcl   = e_col - 7'd2;             // the model's columns either side
wire [6:0]  mcr   = e_col;
// in a box (the caption, the chapter, the time; P6c: Go To's field): the strongest kind over this
// cell, the one before (its last pad spills into this cell's first pixels), the one after
// (0 none, 1 a box, 2 the focused box -- Go To's SEL --, 3 the field being edited -- EDIT)
wire [1:0]  kb_c  = (s_go && !s_gsel) ? 2'd2 : 2'd1;          // the chapter box's kind
wire [1:0]  kb_t  = (s_go && s_gsel) ? 2'd2 : 2'd1;           // the time box's
wire        f_on  = s_go && s_gedit != 3'd0;
reg  [1:0]  km, kl, kr;
always @(*) begin
    km = 2'd0; kl = 2'd0; kr = 2'd0;
    if (mc_ok && e_slot == SL_CAP) begin
        if (mc < {2'd0, cap_len}) km = 2'd1;
        if (chap_on && mc >= ccol && mc < ccol + {2'd0, cl}) km = kb_c;
        if (s_ovl && mc >= tcol) km = kb_t;
        if (f_on && mc >= fc && mc < fc + {4'd0, fn}) km = 2'd3;
    end
    if ((e_col >= 7'd2) && (e_col <= cols + 7'd1) && e_slot == SL_CAP) begin
        if (mcl < {2'd0, cap_len}) kl = 2'd1;
        if (chap_on && mcl >= ccol && mcl < ccol + {2'd0, cl}) kl = kb_c;
        if (s_ovl && mcl >= tcol) kl = kb_t;
        if (f_on && mcl >= fc && mcl < fc + {4'd0, fn}) kl = 2'd3;
    end
    if ((e_col < cols) && e_slot == SL_CAP) begin
        if (mcr < {2'd0, cap_len}) kr = 2'd1;
        if (chap_on && mcr >= ccol && mcr < ccol + {2'd0, cl}) kr = kb_c;
        if (s_ovl && mcr >= tcol) kr = kb_t;
        if (f_on && mcr >= fc && mcr < fc + {4'd0, fn}) kr = 2'd3;
    end
end
always @(*) begin
    aw2 = !fn[0];
    ac  = fn[0] ? fc + {5'd0, fn[2:1]} : fc + {5'd0, fn[2:1]} - 7'd1;   // odd: the middle; even: the middle pair
end
wire [1:0]  k_first = (kl > km) ? kl : km;
wire [1:0]  k_last  = (kr > km) ? kr : km;
// the arrows (the message row's up, the icon row's down) over the field being edited
wire        a_hit = f_on && mc_ok && mc >= ac && mc < ac + (aw2 ? 7'd2 : 7'd1);
reg  [4:0]  ck;                               // the column within a field
reg  [3:0]  tj;                               // the time template's slot
reg  [3:0]  tdig;
reg  [4:0]  tk;
reg  [4:0]  ckt;                              // P7: the caption column past the icon's extra cell
// the icon row: the Next / Prev pop-up's icon, else the state's (trick play's with its badge: 3 cells),
// shown with Display, paused, stopped, in trick play, a pop-up -- or A-B's own (ab_up); A-B's tag one
// empty cell after it
wire        i_nx   = (s_kind == K_NEXT || s_kind == K_PREV);
wire        i_on   = i_nx || s_disp || s_trick || s_state == ST_PAUSE || s_state == ST_STOP ||
                     (s_kind != K_NONE && s_kind != K_MSG) || s_abu;
wire        ab_vis = s_abu || (s_abl && i_on);
wire [6:0]  ab_c0  = (!i_nx && s_trick) ? 7'd4 : 7'd3;      // the tag's first column
// the message on screen (s_mid): its string, column and length (centred: the model's)
reg  [8:0]  m_str;
reg  [6:0]  m_col, m_len;
always @(*) begin
    case (s_mid)
    3'd1:    begin m_str = STR_MSG1; m_col = msg_col1; m_len = MSG_LEN1; end
    3'd2:    begin m_str = STR_MSG2; m_col = msg_col2; m_len = MSG_LEN2; end
    3'd3:    begin m_str = STR_MSG3; m_col = msg_col3; m_len = MSG_LEN3; end
    3'd4:    begin m_str = STR_MSG4; m_col = msg_col4; m_len = MSG_LEN4; end
    3'd5:    begin m_str = STR_MSG5; m_col = msg_col5; m_len = MSG_LEN5; end
    3'd6:    begin m_str = STR_MSG6; m_col = msg_col6; m_len = MSG_LEN6; end
    default: begin m_str = STR_MSG0; m_col = msg_col0; m_len = MSG_LEN0; end
    endcase
end
always @(*) begin
    c_rom = 1'b0; c_a = 9'd0; c_g = G_SPACE; c_c = C_WHITE;
    ck = 5'd0; tj = 4'd0; tdig = 4'd0; tk = 5'd0; ckt = 5'd0;
    c_bx = {k_first, km, k_last};
    if (mc_ok) case (e_slot)
    SL_ICON: begin
        if (a_hit) c_g = aw2 ? G_DOWN2 + {6'd0, mc != ac} : G_DOWN;     // P6c: below the field
        else if (ab_vis && mc >= ab_c0 && mc < ab_c0 + 7'd3)
            c_g = (mc == ab_c0) ? 7'd33 : (mc == ab_c0 + 7'd1) ? 7'd13 : s_abb ? 7'd34 : G_SPACE;  // 'A' '-' 'B'
        else if (i_nx) begin
            if (mc < 7'd2) c_g = (s_kind == K_NEXT ? G_NEXT : G_PREV) + {6'd0, mc[0]};
        end else if (i_on) begin
            if (s_trick) begin
                if (mc < 7'd2) c_g = (s_rev ? G_REW : G_FF) + {6'd0, mc[0]};
                else if (mc == 7'd2)
                    c_g = (s_spd == 2'd1) ? G_BADGE1 : (s_spd == 2'd2) ? G_BADGE2 : G_BADGE3;
            end else if (mc < 7'd2)
                c_g = ((s_state == ST_PAUSE) ? G_PAUSE : (s_state == ST_STOP) ? G_STOP : G_PLAY) + {6'd0, mc[0]};
        end
    end
    SL_MSG: begin
        if (s_kind == K_MSG && mc >= m_col && mc < m_col + m_len) begin
            c_rom = 1'b1; c_a = m_str + {2'b0, mc - m_col};
        end else if (a_hit) c_g = aw2 ? G_UP2 + {6'd0, mc != ac} : G_UP;  // P6c: above the field
    end
    SL_HEAD: begin                            // the rest of the header is the title's path
        if (s_ovl && mc < 7'd2) c_g = G_FILM + {6'd0, mc[0]};
    end
    default: begin                            // SL_CAP
        if (mc < {2'd0, cap_len}) begin
            ck = mc[4:0];
            case (s_kind)
            K_FF, K_REW: begin
                if (ck < 5'd8) begin c_rom = 1'b1; c_a = (s_kind == K_FF ? STR_FORWARD : STR_REVERSE) + {4'd0, ck}; end
                else c_g = G_0 + {5'd0, s_spd};
            end
            K_NEXT, K_PREV: begin
                if (ck < 5'd8) begin c_rom = 1'b1; c_a = STR_CHAPTER + {4'd0, ck}; end
                else case (ck - 5'd8 + 5'd5 - {2'd0, ch_nd})
                    5'd0: c_g = G_0 + {3'd0, dg_c[0]}; 5'd1: c_g = G_0 + {3'd0, dg_c[1]};
                    5'd2: c_g = G_0 + {3'd0, dg_c[2]}; 5'd3: c_g = G_0 + {3'd0, dg_c[3]};
                    default: c_g = G_0 + {3'd0, dg_c[4]};
                endcase
            end
            default: begin                    // K_TRACK (P7: the subtitles' behind a two-cell balloon)
                ckt = s_tsub ? ck - 5'd1 : ck;
                if (s_tsub && ck < 5'd2) c_g = G_BALLOON + {6'd0, ck[0]};
                else if (!s_tsub && ck == 5'd0) c_g = G_NOTE;
                else if (s_toff) case (ck)            // "(balloon) Off"
                    5'd2: c_g = G_SPACE; 5'd3: c_g = 7'd47;   // 'O' (ASCII - 32)
                    default: c_g = 7'd70;                     // 'f'
                endcase
                else if (ckt == 5'd1) c_g = G_SPACE;
                else if (ckt < 5'd2 + {3'd0, tr_nd})
                    c_g = G_0 + ((tr_nd == 2'd2 && ckt == 5'd2) ? {3'd0, dg_r[0]} : {3'd0, dg_r[1]});
                else if (ckt == 5'd2 + {3'd0, tr_nd}) c_g = G_SPACE;
                else begin
                    tk = ckt - 5'd3 - {3'd0, tr_nd};
                    if (li_v) begin c_rom = 1'b1; c_a = STR_LANG + {3'b0, li, 3'd0} + {4'd0, tk}; end
                    else begin
                        c_g = (tk == 5'd0) ? ((s_lang[15:8] >= 8'd32 && s_lang[15:8] <= 8'd126) ? s_lang[14:8] - 7'd32 : G_TOFU)
                                           : ((s_lang[7:0]  >= 8'd32 && s_lang[7:0]  <= 8'd126) ? s_lang[6:0]  - 7'd32 : G_TOFU);
                    end
                end
            end
            endcase
        end else if (chap_on && mc >= ccol && mc < ccol + {2'd0, cl}) begin
            ck = mc[4:0] - ccol[4:0];
            if (ck < 5'd8) begin c_rom = 1'b1; c_a = STR_CHAPTER + {4'd0, ck}; end
            else case (ck - 5'd8 + 5'd5 - {2'd0, ch_nd})
                5'd0: c_g = G_0 + {3'd0, dg_c[0]}; 5'd1: c_g = G_0 + {3'd0, dg_c[1]};
                5'd2: c_g = G_0 + {3'd0, dg_c[2]}; 5'd3: c_g = G_0 + {3'd0, dg_c[3]};
                default: c_g = G_0 + {3'd0, dg_c[4]};
            endcase
        end else if (s_ovl && mc >= tcol) begin
            tk = mc[4:0] - tcol[4:0];            // tcol >= 48: the field lies in 48..68
            if (tk == le) c_g = G_SLASH;
            else begin
                c_c = (tk < le && !s_go) ? C_ACCENT : C_WHITE;    // (Go To's target: white)
                tj  = ((tk < le) ? tk[3:0] : (tk[3:0] - le[3:0] - 4'd1)) + (hdig3 ? 4'd0 : 4'd1);
                case (tj)
                4'd0: tdig = (tk < le) ? dg_e[0] : dg_t[0];
                4'd1: tdig = (tk < le) ? dg_e[1] : dg_t[1];
                4'd2: tdig = (tk < le) ? dg_e[2] : dg_t[2];
                4'd4: tdig = (tk < le) ? dg_e[3] : dg_t[3];
                4'd5: tdig = (tk < le) ? dg_e[4] : dg_t[4];
                4'd7: tdig = (tk < le) ? dg_e[5] : dg_t[5];
                default: tdig = (tk < le) ? dg_e[6] : dg_t[6];
                endcase
                c_g = (tj == 4'd3 || tj == 4'd6) ? G_COLON : (tj == 4'd9) ? G_PLUS : G_0 + {3'd0, tdig};
            end
        end
    end
    endcase
end

// the title's next cell (W_TPROC), from the byte in title_q
reg         b_cell, b_cont;
reg  [6:0]  b_g;
always @(*) begin
    b_cont = (title_q[7:6] == 2'b10) && (need != 2'd0);
    b_cell = !b_cont;
    b_g    = (title_q >= 8'd32 && title_q <= 8'd126) ? title_q[6:0] - 7'd32 : G_TOFU;
end

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ws <= W_SNAP; qi <= 4'd0; job <= 3'd0; dk <= 3'd0; dcnt <= 4'd0; nv <= 40'd0; q <= 10'd0;
        e_slot <= SL_ICON; e_col <= 7'd0; e1_v <= 1'b0; e1_rom <= 1'b0; e1_slot <= 2'd0; e1_col <= 7'd0;
        e1_g <= 7'd0; e1_c <= 2'd0; e1_bx <= 6'd0; ta <= 8'd0; tcnt <= 7'd0; need <= 2'd0; tph <= 1'b0; tbad <= 1'b0;
        tend <= 1'b0; pend <= 7'd0; fcol <= 7'd0; pw_v <= 1'b0; pw_col <= 7'd0; pw_g <= 7'd0;
        title_addr <= 7'd0; t_ph <= 1'b0; t_bad <= 1'b0; t_cut <= 1'b0;
        l_head <= 1'b0; l_band <= 1'b0; l_bar <= 1'b0; l_fill <= 9'd0;
        hdig3 <= 1'b0; sat_t <= 1'b0; sat_e <= 1'b0; fill <= 9'd0; mfill <= 9'd0; qb <= 10'd0;
        l_mark <= 1'b0; l_mfill <= 9'd0; fc <= 7'd0; fn <= 3'd1;
    end else begin
        e1_v <= 1'b0;
        pw_v <= 1'b0;
        case (ws)
        // ---- the snapshot ---------------------------------------------------------------
        W_SNAP: begin
            s_disp <= display; s_kind <= kind; s_mid <= mid; s_state <= state; s_trick <= (tk_speed != 2'd0);
            s_spd <= tk_speed; s_rev <= tk_rev; s_chap <= chapter; s_nch <= (n_chapters != 16'd0);
            s_lang <= lang_q; s_rank <= rank_c; s_ptsv <= sh_pts_v; s_tsub <= tsub; s_toff <= toff;
            s_tot <= (pl_dur[63:39] != 25'd0) ? {39{1'b1}} : pl_dur[38:0];
            s_go  <= goto_open; s_gsel <= goto_sel; s_gedit <= goto_edit; s_gt <= goto_t;
            s_mv  <= goto_mv; s_mk <= goto_mark;
            s_abu <= ab_up; s_abb <= ab_b; s_abl <= ab_loop;
            if (goto_open) s_chap <= goto_chap;          // (the caption row is the editor's)
            ws    <= W_SNAP1;
        end
        W_SNAP1: begin
            // elapsed = base + max(pts - IN, 0), saturating at 39 bits
            if (!s_ptsv) s_el <= 39'd0;
            else if (el_sum[39]) s_el <= {39{1'b1}};
            else s_el <= el_sum[38:0];
            hdig3 <= (s_tot >= T100H);
            sat_t <= (s_tot >= T1000H);
            ws    <= W_SNAP2;
        end
        W_SNAP2: begin
            sat_e <= (s_tv >= (hdig3 ? T1000H : T100H));
            job <= 3'd0; dk <= 3'd0; dcnt <= 4'd0; nv <= {1'b0, s_tot};
            ws  <= W_NUM;
        end
        // ---- the numbers: one subtraction a cycle ---------------------------------------
        W_NUM: begin
            if (job == 3'd4) begin
                // the bar: q = min(el, tot) * 512 / tot, a quotient bit a cycle (long division
                // of el by tot: the integer bit -- set, it is min(el, tot) = tot: q = 512, done --
                // then nine fraction bits)
                // (P6c: then job 5, the marker's, the same way; qb keeps the bar's)
                if (nge && qi == 4'd9) begin
                    q <= 10'd512;
                    if (s_go && s_mv) begin qb <= 10'd512; job <= 3'd5; nv <= {1'b0, s_mk}; q <= 10'd0; end
                    else ws <= W_LEN;
                end else begin
                    if (nge) begin nv <= {nsub[38:0], 1'b0}; q[qi] <= 1'b1; end
                    else nv <= {nv[38:0], 1'b0};
                    if (qi == 4'd0) begin
                        if (s_go && s_mv) begin
                            qb <= {q[9:1], nge}; job <= 3'd5; nv <= {1'b0, s_mk}; q <= 10'd0; qi <= 4'd9;
                        end else ws <= W_LEN;
                    end else qi <= qi - 4'd1;
                end
            end else if (job == 3'd5) begin
                if (nge && qi == 4'd9) begin q <= 10'd512; ws <= W_LEN; end
                else begin
                    if (nge) begin nv <= {nsub[38:0], 1'b0}; q[qi] <= 1'b1; end
                    else nv <= {nv[38:0], 1'b0};
                    if (qi == 4'd0) ws <= W_LEN; else qi <= qi - 4'd1;
                end
            end else if ((job == 3'd0 && sat_t) || (job == 3'd1 && sat_e)) begin
                // a saturated field: 9 9 9 5 9 5 9 (and the '+')
                for (si = 0; si < 7; si = si + 1) begin
                    if (job == 3'd0) dg_t[si] <= (si == 3 || si == 5) ? 4'd5 : 4'd9;
                    else             dg_e[si] <= (si == 3 || si == 5) ? 4'd5 : 4'd9;
                end
                job <= job + 3'd1; dk <= 3'd0; dcnt <= 4'd0;
                nv  <= nv_ld;
            end else if (nge) begin
                nv   <= nsub[39:0];
                dcnt <= dcnt + 4'd1;
            end else begin
                case (job)
                3'd0: dg_t[dk] <= dcnt;
                3'd1: dg_e[dk] <= dcnt;
                3'd2: dg_c[dk] <= dcnt;
                default: dg_r[dk[0]] <= dcnt;
                endcase
                dcnt <= 4'd0;
                if ((job <= 3'd1 && dk == 3'd6) || (job == 3'd2 && dk == 3'd4) || (job == 3'd3 && dk == 3'd1)) begin
                    job <= job + 3'd1; dk <= 3'd0;
                    nv <= nv_ld;
                    q  <= 10'd0;
                    qi <= 4'd9;
                end else dk <= dk + 3'd1;
            end
        end
        // ---- the lengths and columns ----------------------------------------------------
        W_LEN: begin
            // (job 5 ran: q is the marker's, qb the bar's)
            fill  <= (s_tot == 39'd0) ? 9'd0 : (({9'd0, (job == 3'd5) ? qb : q} * 19'd438) >> 9);
            ch_nd <= (dg_c[0] != 4'd0) ? 3'd5 : (dg_c[1] != 4'd0) ? 3'd4 : (dg_c[2] != 4'd0) ? 3'd3 :
                     (dg_c[3] != 4'd0) ? 3'd2 : 3'd1;
            tr_nd <= (dg_r[0] != 4'd0) ? 2'd2 : 2'd1;
            li_v  <= 1'b1;
            case (s_lang)
            LANG0: begin li <= 3'd0; nm_len <= 4'd7; end
            LANG1: begin li <= 3'd1; nm_len <= 4'd6; end
            LANG2: begin li <= 3'd2; nm_len <= 4'd7; end
            LANG3: begin li <= 3'd3; nm_len <= 4'd7; end
            LANG4: begin li <= 3'd4; nm_len <= 4'd6; end
            LANG5: begin li <= 3'd5; nm_len <= 4'd8; end
            LANG6: begin li <= 3'd6; nm_len <= 4'd7; end
            LANG7: begin li <= 3'd7; nm_len <= 4'd7; end
            default: begin li <= 3'd0; nm_len <= 4'd2; li_v <= 1'b0; end
            endcase
            le    <= (hdig3 ? 5'd9 : 5'd8) + {4'd0, sat_e};
            ws    <= W_LEN2;
        end
        W_LEN2: begin                         // the fields' lengths and columns
            mfill   <= (s_tot == 39'd0) ? 9'd0 : (({9'd0, q} * 19'd438) >> 9);   // P6c: the marker's
            cl      <= 5'd8 + {2'd0, ch_nd};
            tl      <= le + 5'd1 + (hdig3 ? 5'd9 : 5'd8) + {4'd0, sat_t};
            case (s_kind)
            K_FF, K_REW:    cap_len <= s_go ? 5'd0 : 5'd9;
            K_NEXT, K_PREV: cap_len <= (s_chap != 16'd0 && !s_go) ? 5'd8 + {2'd0, ch_nd} : 5'd0;
            K_TRACK:        cap_len <= s_go ? 5'd0 : s_toff ? 5'd6 : 5'd3 + {3'd0, tr_nd} + {1'b0, nm_len} + {4'd0, s_tsub};
            default:        cap_len <= 5'd0;
            endcase
            chap_on <= s_go ? s_nch : (s_disp && s_nch && s_chap != 16'd0);
            ws      <= W_LEN3;
        end
        W_LEN3: begin
            tcol   <= cols - {2'd0, tl};
            ccol   <= cols - {2'd0, tl} - 7'd2 - {2'd0, cl};
            ws     <= W_LEN4;
        end
        W_LEN4: begin                         // P6c: the edited field and its arrows
            case (s_gedit)
            3'd1:    begin fc <= ccol + 7'd8; fn <= ch_nd; end
            3'd2:    begin fc <= tcol; fn <= hdig3 ? 3'd3 : 3'd2; end
            3'd3:    begin fc <= tcol + (hdig3 ? 7'd4 : 7'd3); fn <= 3'd2; end
            default: begin fc <= tcol + (hdig3 ? 7'd7 : 7'd6); fn <= 3'd2; end
            endcase
            ws     <= W_EMIT;
            e_slot <= SL_ICON; e_col <= 7'd0;
        end
        // ---- the cells: one a cycle, through the string ROM's read -----------------------
        W_EMIT: begin
            e1_v <= 1'b1; e1_slot <= e_slot; e1_col <= e_col; e1_rom <= c_rom; e1_g <= c_g; e1_c <= c_c;
            e1_bx <= c_bx;
            if ((e_slot == SL_HEAD && s_ovl && e_col == 7'd3) || e_col == cols + 7'd1) begin
                e_col <= 7'd0;
                case (e_slot)
                SL_ICON: e_slot <= SL_CAP;
                SL_CAP:  e_slot <= SL_MSG;
                SL_MSG:  e_slot <= SL_HEAD;
                default: ws <= W_EDRAIN;
                endcase
            end else e_col <= e_col + 7'd1;
        end
        W_EDRAIN: begin
            ta <= 8'd0; tcnt <= 7'd0; need <= 2'd0; tph <= 1'b0; tbad <= 1'b0; tend <= 1'b0;
            if (s_ovl) ws <= W_TADDR;
            else ws <= W_COMMIT;                   // the header was all spaces
        end
        // ---- the title: a byte every three cycles (the address out, the reader's registered read) ---------------------------------------
        W_TADDR: begin
            if (ta >= title_len || ta[7]) ws <= W_TEND;
            else begin title_addr <= ta[6:0]; ws <= W_TW1; end
        end
        W_TW1: ws <= W_TPROC;                 // title_addr out; title_q arrives next cycle
        W_TPROC: begin
            ta <= ta + 8'd1;
            if (title_q == 8'd0) ws <= W_TEND;               // the SFO string's NUL
            else begin
                ws <= W_TADDR;
                if (b_cont) need <= need - 2'd1;
                else begin
                    // a stray continuation, or a sequence cut short, or a byte UTF-8 never uses
                    if ((title_q[7:6] == 2'b10) || need != 2'd0 || title_q[7:1] == 7'b1100000 ||
                        title_q >= 8'hF5) tbad <= 1'b1;
                    if (b_g == G_TOFU) tph <= 1'b1;
                    need <= (title_q >= 8'hC2 && title_q <= 8'hDF) ? 2'd1 :
                            (title_q >= 8'hE0 && title_q <= 8'hEF) ? 2'd2 :
                            (title_q >= 8'hF0 && title_q <= 8'hF4) ? 2'd3 : 2'd0;
                    if (tcnt != 7'd127) tcnt <= tcnt + 7'd1;
                    if (tcnt < troom - 7'd1) begin pw_v <= 1'b1; pw_col <= 7'd4 + tcnt; pw_g <= b_g; end
                    else if (tcnt == troom - 7'd1) pend <= b_g;
                    else if (tcnt == troom) begin pw_v <= 1'b1; pw_col <= cols; pw_g <= G_ELLIPSIS; end
                end
            end
        end
        W_TEND: begin
            if (need != 2'd0) tbad <= 1'b1;                   // the title ends inside a sequence
            if (tcnt >= troom) begin
                // the 66th cell: itself, or the ellipsis when the reader cut the title (a
                // 67th cell already wrote the ellipsis)
                if (tcnt == troom) begin pw_v <= 1'b1; pw_col <= cols; pw_g <= title_trunc ? G_ELLIPSIS : pend; end
                ws   <= W_COMMIT;
            end else if (title_trunc) begin
                pw_v <= 1'b1; pw_col <= 7'd4 + tcnt; pw_g <= G_ELLIPSIS;
                fcol <= 7'd5 + tcnt;
                ws   <= W_FILL;
            end else begin
                fcol <= 7'd4 + tcnt;
                ws   <= W_FILL;
            end
        end
        W_FILL: begin
            if (fcol > cols) ws <= W_COMMIT;
            else begin pw_v <= 1'b1; pw_col <= fcol; pw_g <= G_SPACE; fcol <= fcol + 7'd1; end
        end
        // ---- the layers, from this pass --------------------------------------------------
        W_COMMIT: begin
            t_ph   <= s_ovl ? tph : 1'b0;
            t_bad  <= s_ovl ? tbad : 1'b0;
            t_cut  <= s_ovl ? (title_trunc || tcnt > troom) : 1'b0;
            l_head <= s_ovl;
            l_band <= (s_kind == K_MSG);
            l_bar  <= s_ovl;
            l_fill <= fill;
            l_mark <= s_go && s_mv;
            l_mfill <= mfill;
            ws     <= W_SNAP;
        end
        default: ws <= W_SNAP;
        endcase
    end
end

// the plane's write port: the emitter (after the string ROM's read) or the title's path
always @(posedge clk) begin
    rom_q <= srom[c_a];
    if (e1_v)
        plane[{e1_slot, e1_col}] <= {e1_rom ? rom_q : e1_g, e1_c, e1_bx};
    else if (pw_v)
        plane[{SL_HEAD, pw_col}] <= {pw_g, C_WHITE, 6'd0};
end

// =========================================================================================
// The pixel path
// =========================================================================================
wire [11:0] hx  = h_pos - {1'b0, x0 - {7'd0, CW}};    // the plane's column 0 starts at x0 - CW
wire [18:0] hx205 = {7'd0, hx} * 19'd205;
wire [6:0]  col = hx205[17:11];
wire [11:0] px0 = hx - ({5'd0, col} * 12'd10);
wire [9:0]  vy0 = v_pos[9:0] - sy0, vy1 = v_pos[9:0] - sy1,
            vy2 = v_pos[9:0] - sy2, vy3 = v_pos[9:0] - sy3;
wire        hit0 = v_pos[11:10] == 2'd0 && v_pos[9:0] >= sy0 && vy0 < 10'd24;
wire        hit1 = v_pos[11:10] == 2'd0 && v_pos[9:0] >= sy1 && vy1 < 10'd24;
wire        hit2 = v_pos[11:10] == 2'd0 && v_pos[9:0] >= sy2 && vy2 < 10'd24;
wire        hit3 = v_pos[11:10] == 2'd0 && v_pos[9:0] >= sy3 && vy3 < 10'd24;
wire        ingrid = h_pos >= {1'b0, x0 - {7'd0, CW}} && hx < ({5'd0, cols} + 12'd2) * 12'd10;
wire        on  = show && de_in;
wire        hh  = h_pos[11] == 1'b0;
wire        vv  = v_pos[11:10] == 2'd0;

// P6c: the marker's rows and its half-width on this line
wire [9:0]  mk_y0 = bar_y0 - 10'd2 - MARK_H;
wire [9:0]  mk_r  = v_pos[9:0] - mk_y0;
wire [3:0]  mk_hw = (MARK_H[3:0] - 4'd1 - mk_r[3:0]) >> 1;
wire [10:0] mk_x  = bar_x0 + {2'd0, l_mfill};
// the layer at this pixel: 0 none, 1 header, 2 band | 3 rim, 4 bar rest, 5 bar fill (and the marker), 6 box
reg         in1, hd1, bd1;
reg  [2:0]  ly1;
reg  [8:0]  a1;
reg  [4:0]  row1;
reg  [3:0]  px1;
always @(posedge clk) begin
    in1  <= on && ingrid && (hit0 || hit1 || hit2 || hit3);
    a1   <= {hit0 ? SL_HEAD : hit1 ? SL_MSG : hit2 ? SL_CAP : SL_ICON, col};
    row1 <= hit0 ? vy0[4:0] : hit1 ? vy1[4:0] : hit2 ? vy2[4:0] : vy3[4:0];
    px1  <= px0[3:0];
    hd1  <= on && l_head && vv && v_pos[9:0] < hdr_y1;
    bd1  <= on && l_band && vv && v_pos[9:0] >= band_y0 && v_pos[9:0] < band_y1;
    ly1  <= 3'd0;
    if (on && hh && vv) begin
        if (l_bar && v_pos[9:0] >= bar_y0 - 10'd1 && v_pos[9:0] <= bar_y1 + 10'd1 &&
            h_pos[10:0] >= bar_x0 - 11'd1 && h_pos[10:0] <= bar_x1 + 11'd1) begin
            if (v_pos[9:0] < bar_y0 || v_pos[9:0] > bar_y1 || h_pos[10:0] < bar_x0 || h_pos[10:0] > bar_x1)
                ly1 <= 3'd3;
            else if (h_pos[10:0] < bar_x0 + {2'd0, l_fill})
                ly1 <= 3'd5;
            else
                ly1 <= 3'd4;
        end
        // P6c: Go To's marker, a down-arrow of MARK_H lines ending 2 above the bar, in the accent
        // (the fill's colour, so the fill's layer): line r is 2 * ((MARK_H - 1 - r) / 2) + 1 wide
        if (l_mark && v_pos[9:0] >= mk_y0 && v_pos[9:0] < bar_y0 - 10'd2 &&
            h_pos[10:0] + {7'd0, mk_hw} >= mk_x && h_pos[10:0] <= mk_x + {7'd0, mk_hw})
            ly1 <= 3'd5;
    end
end

reg         in2, hd2, bd2;
reg  [2:0]  ly2;
reg  [14:0] p2;
reg  [4:0]  row2;
reg  [3:0]  px2;
reg         in3, hd3, bd3;
reg  [2:0]  ly3;
reg  [19:0] f3;
reg  [1:0]  c3, bk4;
reg  [5:0]  bx3;
reg  [3:0]  px3;
wire [11:0] fa = {p2[14:8], 4'd0} + {1'b0, p2[14:8], 3'd0} + {7'd0, row2};   // glyph * 24 + row
reg         hd4, bd4;
reg  [2:0]  ly4;
reg  [1:0]  cls4, c4;
always @(posedge clk) begin
    p2 <= plane[a1];
    in2 <= in1; hd2 <= hd1; bd2 <= bd1; ly2 <= ly1; row2 <= row1; px2 <= px1;

    f3 <= font[fa];
    c3 <= p2[7:6];
    bx3 <= in2 ? p2[5:0] : 6'd0;
    in3 <= in2; hd3 <= hd2; bd3 <= bd2; ly3 <= ly2; px3 <= px2;

    hd4 <= hd3; bd4 <= bd3; c4 <= c3;
    // a box: the cell's first pad, middle or last pad, each with its kind (P6c: three tints)
    bk4 <= (px3 < BOX_PAD) ? bx3[5:4] : (px3 >= CW - BOX_PAD) ? bx3[1:0] : bx3[3:2];
    if (ly3 == 3'd0 && ((px3 < BOX_PAD) ? bx3[5:4] : (px3 >= CW - BOX_PAD) ? bx3[1:0] : bx3[3:2]) != 2'd0)
        ly4 <= 3'd6;
    else ly4 <= ly3;
    if (!in3) cls4 <= 2'd0;
    else case (px3)
        4'd0: cls4 <= f3[19:18]; 4'd1: cls4 <= f3[17:16]; 4'd2: cls4 <= f3[15:14];
        4'd3: cls4 <= f3[13:12]; 4'd4: cls4 <= f3[11:10]; 4'd5: cls4 <= f3[9:8];
        4'd6: cls4 <= f3[7:6];   4'd7: cls4 <= f3[5:4];   4'd8: cls4 <= f3[3:2];
        default: cls4 <= f3[1:0];
    endcase
end

// ---- the colour (combinational, per channel) ------------------------------------------------
wire [23:0] ink = (c4 == 2'd0) ? INK0 : (c4 == 2'd1) ? INK1 : (c4 == 2'd2) ? INK2 : INK3;
reg  [7:0]  u1 [0:2];
reg  [7:0]  u2 [0:2];
integer ch;
always @(*) begin
    for (ch = 0; ch < 3; ch = ch + 1) begin
        // the washes
        if (hd4)      u1[ch] = (bg[8*ch +: 8] >> HDR_SHIFT) + HDR_K[8*ch +: 8];
        else if (bd4) u1[ch] = (bg[8*ch +: 8] >> BAND_SHIFT) + BAND_K[8*ch +: 8];
        else          u1[ch] = bg[8*ch +: 8];
        // the bar, its rim, a box
        case (ly4)
        3'd3:    u2[ch] = u1[ch] >> 1;
        3'd4:    u2[ch] = BAR_REST[8*ch +: 8];
        3'd5:    u2[ch] = INK1[8*ch +: 8];
        3'd6:    u2[ch] = (bk4 == 2'd3) ? (u1[ch] >> EDIT_SHIFT) + EDIT_K[8*ch +: 8] :
                          (bk4 == 2'd2) ? (u1[ch] >> SEL_SHIFT) + SEL_K[8*ch +: 8] :
                                          (u1[ch] >> BOX_SHIFT) + BOX_K[8*ch +: 8];
        default: u2[ch] = u1[ch];
        endcase
        // the glyph
        case (cls4)
        2'd1:    rgb[8*ch +: 8] = u2[ch] >> 2;
        2'd2:    rgb[8*ch +: 8] = ink[8*ch +: 8];
        2'd3:    rgb[8*ch +: 8] = (ink[8*ch +: 8] >> 1) + (u2[ch] >> 1);
        default: rgb[8*ch +: 8] = u2[ch];
        endcase
    end
end

endmodule
