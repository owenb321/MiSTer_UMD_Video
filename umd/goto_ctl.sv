// umd/goto_ctl.sv -- Go To's editor (P6c, docs/p6c.md §9; the look approved on the mockups,
// tools/transport_layout.py --mockups --goto, 2026-10-03), on clk_sys beside player_ctl.
//
// THE BEHAVIOUR (the maintainer's walk-through, transport.md §3 "Found with the answers"; D15 /
// D16 measured on the PSP, p6c.md §6):
//   * The Go To button opens it while a picture plays or is paused (not stopped, not under a
//     disc menu): two boxes, `Chapter n` and the time; a title without chapters has the time
//     alone. The chapter box is focused first; <- / -> move the focus.
//   * x (Pause) opens the focused box for editing: the chapter box steps its number with
//     up / down (inside [1, n], no wrap); the time box edits hours, minutes and seconds, <- / ->
//     between them, up / down stepping one with wrap (hours 0-99, or 0-999 on a title of 100 h
//     or more, as the HUD's digits). x again confirms: a chapter is a SEEK (7) to its key, a
//     time a TIME (15) -- the playing playlist's time (D15); past the end the reader lands on
//     the last picture and the title ends (D16). Either way the editor closes.
//   * Stop (the PSP's circle) backs out: it closes without a jump, as do the Go To button
//     again and UMD Menu (which emu passes on to the disc's menu as well). A mount, an eject,
//     a stop, a disc menu taking the screen or the picture going away close it too.
// The time box opens on the shown picture's title time (the HUD's elapsed, floored to the
// second); the chapter box on the chapter shown.
//
// THE CHAPTER SELECTOR: one NAV_CHAP on player_ctl's Go To query port per step (gq_req held
// until gq_done; the answer is read from the reader's ch_* outputs that cycle):
//   open  from the shown key: the chapter holding it (cur, its rank), else the first (next, 1)
//   up    from the candidate: the first chapter after it (next, rank + 1)
//   down  from the candidate's key - 1: the last chapter before it (cur, its rank)
// A step pressed while a query is in flight is dropped (a query takes ~2 ms; the presses are
// a person's). Equal chapter keys (duplicated marks) count as one step; their number is the
// reader's rank going down, rank + 1 going up (one short of the tracker's after a duplicate:
// a known limitation, docs/p6c.md §9).
//
// THE MARKER (the blue down-arrow above the bar): the time box's target is the typed time;
// the chapter box's is the candidate's title time -- the reader's item_base + clamp(pts, IN,
// OUT) - IN (umd_nav_ref.Title.marker) -- shown only while the candidate's item is the one
// streaming (D15: elsewhere it would take an item walk per step; mark_v low hides it).
//
// THE TIME: h / m / s and t_ticks (90 kHz, 39 bits as the HUD holds times) move together on
// one adder (t +/- a field's weight, or the wrap's multiple); opening derives h / m / s from
// the elapsed time by repeated subtraction (<= 1,117 cycles), so nothing divides.
//
// Quartus 17: no functions, no N'() casts.

`default_nettype none

module goto_ctl (
    input  wire         clk,                // clk_sys
    input  wire         rst_n,
    input  wire         mount,              // pulse: a new title (closes it)
    input  wire         eject,
    // the presses (one-cycle edges, emu's routing: while open the D-pad, Pause and Stop are
    // this block's alone; the Go To button always)
    input  wire         k_goto,
    input  wire         k_up,
    input  wire         k_down,
    input  wire         k_left,
    input  wire         k_right,
    input  wire         k_ok,               // Pause (x): open the box / confirm
    input  wire         k_back,             // Stop (o): close
    input  wire         k_menu,             // UMD Menu: close (the press goes on to the host)
    // what may open it
    input  wire  [2:0]  state,              // player_ctl: ST_PLAY 1, ST_PAUSE 2
    input  wire         sh_pts_v,
    input  wire         host_ui,            // a disc menu has the screen (P9)
    // where the picture is
    input  wire  [31:0] key_item,           // player_ctl: the shown picture's item
    input  wire  [32:0] sh_pts,
    input  wire  [15:0] chapter,            // player_ctl: the chapter shown
    input  wire  [15:0] n_chapters,
    input  wire  [38:0] el_ticks,           // transport_hud: the shown picture's title time
    input  wire  [63:0] pl_dur,             // umd_reader: the playlist's duration
    // the reader: the streaming item (the marker), the chapter answer
    input  wire  [31:0] rd_item_idx,
    input  wire  [47:0] rd_item_in,
    input  wire  [47:0] rd_item_out,
    input  wire  [47:0] rd_item_base,
    input  wire  [15:0] ch_rank,
    input  wire  [2:0]  ch_valid,           // [0] cur, [2] next
    input  wire  [63:0] ch_cur,
    input  wire  [63:0] ch_next,
    // player_ctl's Go To query port
    output logic        gq_req,
    output logic [63:0] gq_key,
    input  wire         gq_done,
    // the jump (one cycle; emu gives it player_ctl's command port that cycle)
    output logic        cmd_v,
    output logic [3:0]  cmd_code,           // 7 SEEK, 15 TIME
    output logic [31:0] cmd_item,
    output logic [47:0] cmd_pts,
    // the HUD
    output logic        open,
    output logic        sel,                // the focused box: 0 the chapter, 1 the time
    output logic [2:0]  edit,               // E_* below: the field being edited
    output logic [15:0] g_chapter,          // the chapter box's number (0: none reachable)
    output logic [38:0] t_ticks,            // the time box's target
    output logic        mark_v,
    output logic [38:0] mark_ticks
);

    localparam [2:0] ST_PLAY = 3'd1, ST_PAUSE = 3'd2;
    localparam [2:0] E_NONE = 3'd0, E_CHAP = 3'd1, E_H = 3'd2, E_M = 3'd3, E_S = 3'd4;
    localparam [1:0] Q_OPEN = 2'd1, Q_UP = 2'd2, Q_DOWN = 2'd3;
    localparam [1:0] X_IDLE = 2'd0, X_H = 2'd1, X_M = 2'd2, X_S = 2'd3;
    localparam [3:0] C_SEEK = 4'd7, C_TIME = 4'd15;
    // a field's weight in 90 kHz ticks, and the wraps' multiples
    localparam [38:0] W_S = 39'd90_000, W_S59 = 39'd5_310_000, W_M = 39'd5_400_000, W_M59 = 39'd318_600_000,
                      W_H = 39'd324_000_000, W_H99 = 39'd32_076_000_000, W_H999 = 39'd323_676_000_000;
    localparam [63:0] H100 = 64'd32_400_000_000;      // 100 h: the HUD's third hour digit

    wire       can_open = sh_pts_v && (state == ST_PLAY || state == ST_PAUSE) && !host_ui && (pl_dur != 64'd0);
    wire       h3       = (pl_dur >= H100);
    wire [9:0] hmax     = h3 ? 10'd999 : 10'd99;

    logic [9:0]  hh;
    logic [5:0]  mm, ss;
    logic [63:0] cand;                      // the chapter box's key {item u16, pts u48}
    logic [1:0]  q_kind;                    // the query in flight's purpose (0: none / dropped)
    logic        q_due;                     // the opening's query, issued once the port is ours
    logic [1:0]  ex;                        // the time's derivation at opening
    logic [38:0] ex_x;                      //   the time still to divide

    // ---- the one adder of the time: t +/- w (the derivation adds the weight it takes) ----------
    logic [38:0] w;
    logic        w_sub;
    always_comb begin
        w = W_S; w_sub = 1'b0;
        case (ex)
            X_H: w = W_H;
            X_M: w = W_M;
            X_S: w = W_S;
            default: case (edit)
                E_H: begin
                    w_sub = k_up ? (hh >= hmax) : (hh != 10'd0);
                    w = k_up ? ((hh >= hmax) ? (h3 ? W_H999 : W_H99) : W_H) : ((hh == 10'd0) ? (h3 ? W_H999 : W_H99) : W_H);
                end
                E_M: begin
                    w_sub = k_up ? (mm == 6'd59) : (mm != 6'd0);
                    w = k_up ? ((mm == 6'd59) ? W_M59 : W_M) : ((mm == 6'd0) ? W_M59 : W_M);
                end
                default: begin
                    w_sub = k_up ? (ss == 6'd59) : (ss != 6'd0);
                    w = k_up ? ((ss == 6'd59) ? W_S59 : W_S) : ((ss == 6'd0) ? W_S59 : W_S);
                end
            endcase
        endcase
    end
    wire [38:0] t_nx  = w_sub ? t_ticks - w : t_ticks + w;
    // the derivation's compare: the time left holds another of the field's weight
    wire [39:0] ex_d  = {1'b0, ex_x} - {1'b0, w};
    wire        ex_ge = !ex_d[39];

    // ---- the marker: the candidate's title time, in the streaming item only --------------------
    wire        rd_lt_in  = (cand[47:0] < rd_item_in);
    wire        rd_gt_out = (cand[47:0] > rd_item_out);
    wire [47:0] m_pc      = (rd_lt_in || rd_item_out < rd_item_in) ? rd_item_in : rd_gt_out ? rd_item_out : cand[47:0];
    logic [47:0] m_d;
    logic        m_in;
    wire  [48:0] m_sum = {1'b0, rd_item_base} + {1'b0, m_d};

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            open <= 1'b0; sel <= 1'b0; edit <= E_NONE; g_chapter <= '0; t_ticks <= '0;
            mark_v <= 1'b0; mark_ticks <= '0; hh <= '0; mm <= '0; ss <= '0; cand <= '0;
            q_kind <= 2'd0; q_due <= 1'b0; ex <= X_IDLE; ex_x <= '0; gq_req <= 1'b0; gq_key <= '0;
            cmd_v <= 1'b0; cmd_code <= '0; cmd_item <= '0; cmd_pts <= '0; m_d <= '0; m_in <= 1'b0;
        end else begin
            cmd_v <= 1'b0;

            // ---- the query port: held until answered; the answer is read here, that cycle ----
            if (gq_done) begin
                gq_req <= 1'b0; q_kind <= 2'd0;
                case (q_kind)
                    Q_OPEN: if (ch_valid[0]) begin cand <= ch_cur; g_chapter <= ch_rank; end
                            else if (ch_valid[2]) begin cand <= ch_next; g_chapter <= 16'd1; end
                            else g_chapter <= 16'd0;
                    Q_UP:   if (ch_valid[2]) begin cand <= ch_next; g_chapter <= ch_rank + 16'd1; end
                    Q_DOWN: if (ch_valid[0]) begin cand <= ch_cur; g_chapter <= ch_rank; end
                    default: ;
                endcase
            end

            // ---- the time's derivation (opening): hours, minutes, seconds by subtraction ----
            case (ex)
                X_H: if (ex_ge && hh < hmax) begin ex_x <= ex_d[38:0]; hh <= hh + 10'd1; t_ticks <= t_nx; end
                     else ex <= X_M;
                X_M: if (ex_ge && mm != 6'd59) begin ex_x <= ex_d[38:0]; mm <= mm + 6'd1; t_ticks <= t_nx; end
                     else ex <= X_S;
                X_S: if (ex_ge && ss != 6'd59) begin ex_x <= ex_d[38:0]; ss <= ss + 6'd1; t_ticks <= t_nx; end
                     else ex <= X_IDLE;
                default: ;
            endcase

            if (!open) begin
                if (k_goto && can_open) begin
                    open <= 1'b1; sel <= (n_chapters == 16'd0); edit <= E_NONE; g_chapter <= chapter;
                    hh <= '0; mm <= '0; ss <= '0; t_ticks <= '0; ex_x <= el_ticks; ex <= X_H;
                    q_due <= 1'b1;               // (after a query still in flight from before: dropped)
                end
            end else if (mount || eject || !can_open || k_goto || k_back || k_menu) begin
                open <= 1'b0; edit <= E_NONE; ex <= X_IDLE;
                q_kind <= 2'd0; q_due <= 1'b0;                     // an answer in flight is dropped
            end else if (k_ok) begin
                if (edit == E_NONE) edit <= sel ? E_H : E_CHAP;
                else if (edit == E_CHAP) begin
                    if (g_chapter != 16'd0 && !gq_req && !q_due) begin
                        cmd_v <= 1'b1; cmd_code <= C_SEEK; cmd_item <= {16'd0, cand[63:48]}; cmd_pts <= cand[47:0];
                        open <= 1'b0; edit <= E_NONE;
                    end
                end else if (ex == X_IDLE) begin
                    cmd_v <= 1'b1; cmd_code <= C_TIME; cmd_item <= 32'd0; cmd_pts <= {9'd0, t_ticks};
                    open <= 1'b0; edit <= E_NONE;
                end
            end else if (k_left || k_right) begin
                case (edit)
                    E_NONE: if (n_chapters != 16'd0) sel <= k_right;
                    E_H:    if (k_right) edit <= E_M;
                    E_M:    edit <= k_right ? E_S : E_H;
                    E_S:    if (k_left) edit <= E_M;
                    default: ;
                endcase
            end else if (k_up || k_down) begin
                if (edit == E_CHAP) begin
                    if (!gq_req && !q_due && g_chapter != 16'd0 && (k_up || cand != 64'd0)) begin
                        gq_req <= 1'b1; q_kind <= k_up ? Q_UP : Q_DOWN;
                        gq_key <= k_up ? cand : cand - 64'd1;
                    end
                end else if (edit != E_NONE && ex == X_IDLE) begin
                    t_ticks <= t_nx;
                    case (edit)
                        E_H: hh <= k_up ? ((hh >= hmax) ? 10'd0 : hh + 10'd1) : ((hh == 10'd0) ? hmax : hh - 10'd1);
                        E_M: mm <= k_up ? ((mm == 6'd59) ? 6'd0 : mm + 6'd1) : ((mm == 6'd0) ? 6'd59 : mm - 6'd1);
                        default: ss <= k_up ? ((ss == 6'd59) ? 6'd0 : ss + 6'd1) : ((ss == 6'd0) ? 6'd59 : ss - 6'd1);
                    endcase
                end
            end
            // the opening's query: from the shown key (an item past u16 asks past every mark)
            if (open && q_due && !gq_req && !gq_done) begin
                gq_req <= 1'b1; q_kind <= Q_OPEN; q_due <= 1'b0;
                gq_key <= (key_item[31:16] != 16'd0) ? {64{1'b1}} : {key_item[15:0], 15'd0, sh_pts};
            end
            if (mount || eject) begin gq_req <= 1'b0; q_kind <= 2'd0; q_due <= 1'b0; end

            // ---- the marker (two registered stages; the candidate and the item move rarely) ----
            m_d  <= m_pc - rd_item_in;
            m_in <= (rd_item_idx[31:16] == 16'd0) && (cand[63:48] == rd_item_idx[15:0]) && (g_chapter != 16'd0);
            if (sel) begin
                mark_v <= 1'b1; mark_ticks <= t_ticks;
            end else begin
                mark_v <= m_in;
                mark_ticks <= (m_sum[48:39] != 10'd0) ? {39{1'b1}} : m_sum[38:0];
            end
        end
    end

endmodule

`default_nettype wire
