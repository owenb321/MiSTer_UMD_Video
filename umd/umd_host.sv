// umd/umd_host.sv -- the host port: the fabric's one door to the UMD Main (A7,
// docs/hps_host.md §2). Two commands on hps_io's EXT_BUS, beside umd_telem's 0x7A:
//   HOST_RD (0x7B): the core's state to the host -- B3: the subtitle request
//   HOST_WR (0x7C): the host's words to the core -- B3: the heartbeat and the completion
// The word layout is tools/host_layout.py's table (umd/umd_host_words.svh, and
// main/support/umd/umd_host_proto.h for the Main). Deliberately NOT the telemetry channel:
// telemetry is instrumentation (A8), and a host feature must not depend on it.
//
// EXT_BUS, as umd_telem.sv (its reasons hold here): io_enable frames a transaction,
// io_strobe clocks one 16-bit word, the FIRST strobe carries the command in io_din; the bus
// is driven only for HOST_RD (a core answering Main's own commands would corrupt its
// protocol). HOST_RD's word 0 is MAGIC. The responder's strobe / drive / dout structure is
// umd_telem's, unchanged (rig-proven: B2 read 2,000 transactions, the magic never missing).
//
// HOST_RD is one snapshot: the request crosses from the DDR3 clock through a cdc_snap, whose
// copy refreshes every few cycles, and a transaction lasts ~60 us -- so the whole record is
// LATCHED at the command strobe (telemetry's ATOMIC rule) and every word of the read comes
// from that latch.
//
// HOST_WR, word by word (io_din of each strobe):
//   1 {PROTO, host version}: the HEARTBEAT. A matching PROTO reloads a 26-bit down-counter
//     (2^26 / 27 MHz = 2.49 s; host_ok while it runs); a mismatch reloads host_bad's instead
//     (a stale UMD Main: "Update the UMD Main"). 2.49 s, not the plan's ~1 s: stock Main's
//     menus sleep up to 2 s on the poll thread (B2, hps_host.md §8) and must not read as the
//     host gone. host_ok starts low: on a stock Main it never rises.
//   2 {done, err[12:8], seq[7:0]}, 3 w, 4 h: the completion, taken at word 4 if the PROTO of
//     this transaction matched and `done` is set: one clk_sys register write
//     {toggle, seq, err, w, h} that a cdc_snap copies to the DDR3 clock, where a toggle
//     change is one h_done pulse. sub_top decides whether to accept it (the seq rule).
//     THE CONTRACT: two completions inside one cdc_snap round (~10 clk_mem cycles) would flip
//     the toggle twice between copies and be lost together. The host sends at most ONE
//     completion per HOST_WR transaction, and its polls are >= 36 us apart (B2): rounds are
//     well under 1 us. A host that batched completions would break this (docs/hps_host.md §3.2).
//
// P9 (docs/p9.md §3.2; the rows are APPENDED, PROTO stays 1 -- tools/host_layout.py):
//   * the player's state, latched with the record (the ATOMIC rule);
//   * a PLAYER COMMAND, a FLIP and a PCM TRIGGER from the host, each once-only by its seq: taken
//     at its last word when the seq differs from the last taken one, then HELD (hc_v / hf_req /
//     hp_req) until its consumer takes it; the seq echoes in HOST_RD once taken. A new one sent
//     before the last was taken is not seen (the host waits for the echo);
//   * the LEVELS grab / ui / menu / mute, held from the last HOST_WR that carried them, all 0 while
//     host_ok is low (a UMD Main that dies must not leave the core deaf, the HUD hidden, a
//     page on the plane or the film silent);
//   * THE EVENT FIFO, 8 deep: player_ctl's events (teed: emu pops them every cycle for the HUD)
//     and the grabbed buttons' presses (code 15 KEY, data = the press mask), only while host_ok.
//     A key press meeting an event in the same cycle waits one cycle (a one-deep skid; a second
//     press meanwhile merges into its mask). A push into a full FIFO is counted, never silent.
//     Read by count: the unread entries never change (pushes go past them), so HOST_RD reads
//     them live at the latched read count; HOST_WR's ev_rp is the count consumed up to.
// P6d (docs/panel.md F1 / F2 / F5; rows APPENDED, PROTO stays 1):
//   * a PRESS RECORD {seq, mask}: taken once by its seq at its last word as a ONE-CYCLE pulse (hx_v,
//     hx_mask) that emu ORs into the buttons' press edges after the grab and Go To's take, and
//     echoed at once. Unlike the other records it is never held: nothing downstream can refuse or
//     delay a press, so there is nothing to wait for;
//   * ui_sub (ctl[12]): the host owns the plane with the subtitles still running (the panel's
//     mode), a level cleared with the others when host_ok falls;
//   * the flip's plane widened to 2 bits (planes 2 / 3: the panel's);
//   * HOST_RD's status gains Go To's editor open, the title's subtitle track, ui_sub in force.
// Resets: emu gives both sides the PLL-lock resets alone (power-on), so the completion's
// toggle and its mclk copy start together and a core reset never fakes a completion.
// No `function`, no N'(expr) cast (Quartus 17).

`default_nettype none

module umd_host #(
    parameter int RAW = 20,                 // the ring's log2 words (sub_top's h_start)
    parameter int HB_W = 26                 // the heartbeat's timeout: 2^HB_W clk_sys cycles (a bench shortens it)
) (
    input  wire         clk,               // clk_sys (hps_io's)
    input  wire         rst_n,
    // EXT_BUS (hps_io)
    input  wire         io_enable,         // EXT_BUS[34]
    input  wire         io_strobe,         // EXT_BUS[33]
    input  wire  [15:0] io_din,            // EXT_BUS[31:16]
    output logic        drive,             // -> EXT_BUS[32]
    output logic [15:0] dout,              // -> EXT_BUS[15:0]
    // the host, as the core sees it (clk_sys)
    output logic        host_ok,           // a matching heartbeat in the last ~2.5 s
    output logic        host_bad,          // a mismatched PROTO in the last ~2.5 s

    // the subtitle side (mclk: sub_top's handshake)
    input  wire         mclk,
    input  wire         mrst_n,
    input  wire         h_req,
    input  wire  [7:0]  h_seq,
    input  wire         h_buf,
    input  wire  [15:0] h_x,
    input  wire  [15:0] h_y,
    input  wire  [RAW-1:0] h_start,
    input  wire  [31:0] h_len,
    input  wire  [7:0]  h_gen,
    input  wire         h_vis,
    input  wire  [7:0]  h_shown_seq,
    input  wire         h_sbuf,             // A12 SD2: the shown unit's plane and rectangle (mclk)
    input  wire  [15:0] h_sx,
    input  wire  [15:0] h_sy,
    input  wire  [15:0] h_sw,
    input  wire  [15:0] h_sh,
    input  wire  [15:0] n_stale,
    output logic        h_done,
    output logic [7:0]  h_done_seq,
    output logic [4:0]  h_done_err,
    output logic [15:0] h_done_w,
    output logic [15:0] h_done_h,

    // ---- P9 (clk_sys) ----
    // the player's state (player_ctl, umd_reader)
    input  wire  [2:0]  p_state,
    input  wire         p_seeking,
    input  wire  [1:0]  p_tk_speed,
    input  wire         p_tk_rev,
    input  wire         p_sub_on,
    input  wire  [4:0]  p_sub_track,
    input  wire  [3:0]  p_aud_track,
    input  wire  [15:0] p_chapter,
    input  wire  [15:0] p_n_chapters,
    input  wire  [15:0] p_playlist,
    input  wire  [31:0] p_n_items,
    input  wire  [31:0] p_key_item,
    input  wire  [32:0] p_pts,
    input  wire         p_pts_v,
    input  wire         p_goto_open,       // P6d: Go To's editor is open (goto_ctl)
    input  wire         p_sub_any,         // P6d: the title has a subtitle track (umd_reader)
    // events: player_ctl's (a pulse each) and the buttons' press edges
    input  wire         ev_in_v,
    input  wire  [3:0]  ev_in_code,
    input  wire  [15:0] ev_in_data,
    input  wire  [15:0] key_press,         // joystick bit order, press edges (OSD-gated by emu)
    // the levels
    output logic [15:0] grab,
    output logic        ui,
    output logic        menu,
    output logic        mute,              // P9: the film's audio silent (a menu play()'s audio off)
    output logic        ui_sub,            // P6d: the host owns the plane, the subtitles still running
    // P6d: a press record -- buttons pressed, one cycle
    output logic        hx_v,
    output logic [15:0] hx_mask,
    // a player command, held until taken
    output logic        hc_v,
    output logic [3:0]  hc_code,
    output logic [3:0]  hc_arg,
    output logic [15:0] hc_pl,
    output logic [31:0] hc_item,
    output logic [47:0] hc_pts,
    input  wire         hc_take,
    // the host's flip, held until the plane latches it (hf_ack: a pulse)
    output logic        hf_req,
    output logic [1:0]  hf_buf,            // the plane: 0 / 1 the subtitles', 2 / 3 the panel's (P6d)
    output logic        hf_vis,
    output logic [15:0] hf_x,
    output logic [15:0] hf_y,
    output logic [15:0] hf_w,
    output logic [15:0] hf_h,
    input  wire         hf_ack,
    // the PCM trigger, held until the one-shot takes it (hp_ack: a pulse)
    output logic        hp_req,
    output logic        hp_stereo,
    output logic [23:0] hp_start,
    output logic [23:0] hp_len,
    input  wire         hp_ack,
    input  wire         pcm_busy,
    input  wire  [15:0] pcm_under,         // pcm_shot's n_under (HOST_RD)
    input  wire         pic_wide,          // the shown picture's aspect is 16:9 (aspect_vui; P9: a menu is
    input  wire         pic_known,         // always 16:9, the host pillarboxes a 4:3 clip under one)
    input  wire  [1:0]  menu_aa,           // P9: a menu's fit at 480i: 0 Fit 1 Letterbox 2 Crop (analog.md S7)
    input  wire         zoom,              // fj#71: Zoom in force (zoom_ctl; docs/zoom.md) -- the panel's subtitle placed as the fabric's
    // the video window (P9 item 6: disp_reader latches it once a frame, never while win_hold)
    output logic        win,
    output logic        win_hold,
    output logic [9:0]  win_x,
    output logic [9:0]  win_y,
    output logic [9:0]  win_w,
    output logic [9:0]  win_h,
    output logic [25:0] win_hs,
    output logic [25:0] win_vs,
    output logic [25:0] win_x0,
    output logic [25:0] win_y0,
    input  wire         win_bad,
    output logic [7:0]  ev_lost
);

    // ---- the request, mclk -> clk_sys (a continuous snapshot) --------------------------------------------
    localparam int SW = 1 + 8 + 1 + 16 + 16 + 20 + 32 + 8 + 1 + 8 + 16 + 1 + 4 * 16;   // 192 (A12 SD2: + the shown rectangle)
    logic [19:0]  start20;
    always_comb begin
        start20 = '0;
        start20[RAW-1:0] = h_start;
    end
    logic [SW-1:0] snap;
    cdc_snap #(.W(SW)) u_req (
        .src_clk (mclk), .src_rst_n (mrst_n),
        .src_data ({h_req, h_seq, h_buf, h_x, h_y, start20, h_len, h_gen, h_vis, h_shown_seq, n_stale,
                    h_sbuf, h_sx, h_sy, h_sw, h_sh}),
        .dst_clk (clk), .dst_rst_n (rst_n), .dst_data (snap), .dst_tick ()
    );

    // ---- the heartbeat -------------------------------------------------------------------------------------
    logic [HB_W-1:0] hb_cnt, bad_cnt;
    assign host_ok  = (hb_cnt != '0);
    assign host_bad = (bad_cnt != '0);

    // ---- the latched record HOST_RD answers from -------------------------------------------------------------
    logic        r_req, r_buf, r_vis, r_ok, r_bad;
    logic [7:0]  r_seq, r_gen, r_shown;
    logic        r_sbuf;                    // A12 SD2
    logic [15:0] r_sx, r_sy, r_sw, r_sh;
    logic [15:0] r_x, r_y, r_stale;
    logic [19:0] r_start;
    logic [31:0] r_len;

    // P9: the player's record
    logic [2:0]  r_state;
    logic        r_seeking, r_tk_rev, r_sub_on, r_pts_v, r_ui, r_menu, r_pcm_busy, r_pic_wide, r_pic_known;
    logic [1:0]  r_menu_aa;
    logic        r_zoom;
    logic [1:0]  r_tk_speed;
    logic [4:0]  r_sub_track;
    logic [3:0]  r_aud_track;
    logic [15:0] r_chapter, r_n_chapters, r_playlist;
    logic [31:0] r_n_items, r_key_item;
    logic [32:0] r_pts;
    logic [7:0]  r_cmd_ack, r_flip_ack, r_pcm_ack, r_ev_lost, r_ev_wc, r_ev_rc;
    logic [15:0] r_pcm_under;
    logic        r_win, r_win_bad;
    logic        r_goto_open, r_sub_any, r_ui_sub;  // P6d
    logic [7:0]  r_press_ack, press_ack;
    logic [7:0]  r_win_ack, win_ack;
    // ... the seqs taken, and the event FIFO (below)
    logic [7:0]  cmd_ack, flip_ack, pcm_ack;
    logic [19:0] evq [0:7];
    logic [7:0]  ev_wc, ev_rc;
    logic [19:0] ev_q0, ev_q1, ev_q2, ev_q3;
    always_comb begin
        ev_q0 = evq[r_ev_rc[2:0]];
        ev_q1 = evq[r_ev_rc[2:0] + 3'd1];
        ev_q2 = evq[r_ev_rc[2:0] + 3'd2];
        ev_q3 = evq[r_ev_rc[2:0] + 3'd3];
    end

    logic [5:0]  w_idx;
    logic [15:0] w_val;
    `include "umd/umd_host_words.svh"

    // ---- the transaction -------------------------------------------------------------------------------------
    logic [5:0]  wcnt;
    logic        rd_act, wr_act, wr_pok;
    // P9: the words before a record's last, kept until it
    logic [7:0]  t_cseq, t_fseq, t_pseq, t_cseq_q, t_fseq_q, t_pseq_q;
    logic [3:0]  t_code, t_arg;
    logic [15:0] t_pl, t_fx, t_fy, t_fw;
    logic [31:0] t_item;
    logic [31:0] t_pts;
    logic        t_fvis, t_pst;
    logic [1:0]  t_fbuf;
    logic [7:0]  t_xseq;                   // P6d: the press record's seq
    logic [23:0] t_pstart;
    logic [15:0] t_plen;
    logic [15:0] grab_r;
    logic        ui_r, menu_r, mute_r, uis_r;
    logic [7:0]  ev_rp_h;                  // the host's consumed-up-to count
    logic [15:0] dout_r;
    logic        c_done;
    logic [7:0]  c_seq;
    logic [4:0]  c_err;
    logic [15:0] c_w;
    // the completion record crossing to mclk: {toggle, seq, err, w, h}
    logic        c_tog;
    logic [7:0]  cr_seq;
    logic [4:0]  cr_err;
    logic [15:0] cr_w, cr_h;
    assign w_idx = wcnt;

    always_ff @(posedge clk) begin
        if (!rst_n) begin
            wcnt <= '0; rd_act <= 1'b0; wr_act <= 1'b0; wr_pok <= 1'b0; dout_r <= '0;
            hb_cnt <= '0; bad_cnt <= '0;
            cmd_ack <= '0; flip_ack <= '0; pcm_ack <= '0; grab_r <= '0; ui_r <= 1'b0; menu_r <= 1'b0; mute_r <= 1'b0;
            uis_r <= 1'b0; press_ack <= '0; t_xseq <= '0; hx_v <= 1'b0; hx_mask <= '0;
            ev_rp_h <= '0; t_cseq_q <= '0; t_fseq_q <= '0; t_pseq_q <= '0;
            win <= 1'b0; win_ack <= '0; win_x <= '0; win_y <= '0; win_w <= '0; win_h <= '0;
            win_hs <= '0; win_vs <= '0; win_x0 <= '0; win_y0 <= '0;
            hc_v <= 1'b0; hc_code <= '0; hc_arg <= '0; hc_pl <= '0; hc_item <= '0; hc_pts <= '0;
            hf_req <= 1'b0; hf_buf <= 2'd0; hf_vis <= 1'b0; hf_x <= '0; hf_y <= '0; hf_w <= '0; hf_h <= '0;
            hp_req <= 1'b0; hp_stereo <= 1'b0; hp_start <= '0; hp_len <= '0;
            c_tog <= 1'b0; cr_seq <= '0; cr_err <= '0; cr_w <= '0; cr_h <= '0;
            c_done <= 1'b0; c_seq <= '0; c_err <= '0; c_w <= '0;
        end else begin
            // P9: a held record leaves when its consumer takes it
            if (hc_take && hc_v) begin hc_v <= 1'b0; cmd_ack <= t_cseq_q; end
            hx_v <= 1'b0;                  // P6d: a press is one cycle
            if (!host_ok) begin grab_r <= '0; ui_r <= 1'b0; menu_r <= 1'b0; mute_r <= 1'b0; uis_r <= 1'b0; win <= 1'b0; end
            if (hf_ack && hf_req) begin hf_req <= 1'b0; flip_ack <= t_fseq_q; end
            if (hp_ack && hp_req) begin hp_req <= 1'b0; pcm_ack <= t_pseq_q; end
            if (hb_cnt != '0)  hb_cnt  <= hb_cnt - 1'b1;
            if (bad_cnt != '0) bad_cnt <= bad_cnt - 1'b1;
            if (!io_enable) begin
                wcnt <= '0; rd_act <= 1'b0; wr_act <= 1'b0; wr_pok <= 1'b0; dout_r <= '0;
            end else if (io_strobe) begin
                if (wcnt == 6'd0) begin
                    rd_act <= (io_din == H_CMD_RD);
                    wr_act <= (io_din == H_CMD_WR);
                    // HOST_RD: one snapshot for the whole read
                    {r_req, r_seq, r_buf, r_x, r_y, r_start, r_len, r_gen, r_vis, r_shown, r_stale,
                     r_sbuf, r_sx, r_sy, r_sw, r_sh} <= snap;
                    r_ok <= host_ok; r_bad <= host_bad;
                    // P9: the player's record
                    r_state <= p_state; r_seeking <= p_seeking; r_tk_speed <= p_tk_speed; r_tk_rev <= p_tk_rev;
                    r_sub_on <= p_sub_on; r_sub_track <= p_sub_track; r_aud_track <= p_aud_track;
                    r_pts_v <= p_pts_v; r_chapter <= p_chapter; r_n_chapters <= p_n_chapters;
                    r_playlist <= p_playlist; r_n_items <= p_n_items; r_key_item <= p_key_item; r_pts <= p_pts;
                    r_ui <= ui; r_menu <= menu; r_pcm_busy <= pcm_busy; r_pcm_under <= pcm_under;
                    r_pic_wide <= pic_wide; r_pic_known <= pic_known; r_menu_aa <= menu_aa; r_zoom <= zoom;
                    r_win <= win; r_win_bad <= win_bad; r_win_ack <= win_ack;
                    r_cmd_ack <= cmd_ack; r_flip_ack <= flip_ack; r_pcm_ack <= pcm_ack;
                    r_goto_open <= p_goto_open; r_sub_any <= p_sub_any; r_ui_sub <= uis_r; r_press_ack <= press_ack;
                    r_ev_lost <= ev_lost; r_ev_wc <= ev_wc; r_ev_rc <= ev_rc;
                end
                if (wr_act) begin
                    case (wcnt)
                        H_WR_PROTO: begin
                            wr_pok <= (io_din[15:8] == H_PROTO);
                            if (io_din[15:8] == H_PROTO) begin hb_cnt <= '1; bad_cnt <= '0; end
                            else bad_cnt <= '1;
                        end
                        H_WR_DONE: begin c_done <= io_din[15]; c_err <= io_din[12:8]; c_seq <= io_din[7:0]; end
                        H_WR_DONE_W: c_w <= io_din;
                        H_WR_DONE_H: if (wr_pok && c_done) begin
                            c_tog <= !c_tog; cr_seq <= c_seq; cr_err <= c_err; cr_w <= c_w; cr_h <= io_din;
                        end
                        // ---- P9: a player command (taken at its last word, once by its seq) ----
                        H_WR_PCMD:       begin t_cseq <= io_din[15:8]; t_code <= io_din[7:4]; t_arg <= io_din[3:0]; end
                        H_WR_PCMD_PL:    t_pl <= io_din;
                        H_WR_PCMD_ITEM_LO: t_item[15:0] <= io_din;
                        H_WR_PCMD_ITEM_HI: t_item[31:16] <= io_din;
                        H_WR_PCMD_PTS0:  t_pts[15:0] <= io_din;
                        H_WR_PCMD_PTS1:  t_pts[31:16] <= io_din;
                        H_WR_PCMD_PTS2:  if (wr_pok && t_cseq != cmd_ack && !hc_v) begin
                            hc_v <= 1'b1; hc_code <= t_code; hc_arg <= t_arg; hc_pl <= t_pl;
                            hc_item <= t_item; hc_pts <= {io_din, t_pts}; t_cseq_q <= t_cseq;
                        end
                        H_WR_GRAB:       if (wr_pok) grab_r <= io_din;
                        H_WR_CTL:        if (wr_pok) begin ui_r <= io_din[15]; menu_r <= io_din[14]; mute_r <= io_din[13]; uis_r <= io_din[12]; end
                        H_WR_EV_RP:      if (wr_pok) ev_rp_h <= io_din[7:0];
                        // ---- the host's flip ----
                        H_WR_FLIP:       begin t_fseq <= io_din[15:8]; t_fbuf <= io_din[2:1]; t_fvis <= io_din[0]; end
                        H_WR_FLIP_X:     t_fx <= io_din;
                        H_WR_FLIP_Y:     t_fy <= io_din;
                        H_WR_FLIP_W:     t_fw <= io_din;
                        H_WR_FLIP_H:     if (wr_pok && t_fseq != flip_ack && t_fseq != t_fseq_q && !hf_req) begin
                            hf_req <= 1'b1; hf_buf <= t_fbuf; hf_vis <= t_fvis;
                            hf_x <= t_fx; hf_y <= t_fy; hf_w <= t_fw; hf_h <= io_din; t_fseq_q <= t_fseq;
                        end
                        // ---- the PCM trigger ----
                        H_WR_PCM:        begin t_pseq <= io_din[15:8]; t_pst <= io_din[0]; end
                        H_WR_PCM_START_LO: t_pstart[15:0] <= io_din;
                        H_WR_PCM_START_HI: t_pstart[23:16] <= io_din[7:0];
                        H_WR_PCM_LEN_LO: t_plen <= io_din;
                        H_WR_PCM_LEN_HI: if (wr_pok && t_pseq != pcm_ack && t_pseq != t_pseq_q && !hp_req) begin
                            hp_req <= 1'b1; hp_stereo <= t_pst; hp_start <= t_pstart;
                            hp_len <= {io_din[7:0], t_plen}; t_pseq_q <= t_pseq;
                        end
                        // ---- the video window: written in place (win_hold covers the transaction) ----
                        H_WR_WIN:        if (wr_pok) begin win <= io_din[0]; win_ack <= io_din[15:8]; end
                        H_WR_WIN_X:      if (wr_pok) win_x <= io_din[9:0];
                        H_WR_WIN_Y:      if (wr_pok) win_y <= io_din[9:0];
                        H_WR_WIN_W:      if (wr_pok) win_w <= io_din[9:0];
                        H_WR_WIN_H:      if (wr_pok) win_h <= io_din[9:0];
                        H_WR_WIN_HS_LO:  if (wr_pok) win_hs[15:0] <= io_din;
                        H_WR_WIN_HS_HI:  if (wr_pok) win_hs[25:16] <= io_din[9:0];
                        H_WR_WIN_VS_LO:  if (wr_pok) win_vs[15:0] <= io_din;
                        H_WR_WIN_VS_HI:  if (wr_pok) win_vs[25:16] <= io_din[9:0];
                        H_WR_WIN_X0_LO:  if (wr_pok) win_x0[15:0] <= io_din;
                        H_WR_WIN_X0_HI:  if (wr_pok) win_x0[25:16] <= io_din[9:0];
                        H_WR_WIN_Y0_LO:  if (wr_pok) win_y0[15:0] <= io_din;
                        H_WR_WIN_Y0_HI:  if (wr_pok) win_y0[25:16] <= io_din[9:0];
                        // ---- P6d: the press record (a one-cycle pulse, echoed at once) ----
                        H_WR_PRESS:      t_xseq <= io_din[15:8];
                        H_WR_PRESS_MASK: if (wr_pok && t_xseq != press_ack) begin
                            hx_v <= 1'b1; hx_mask <= io_din; press_ack <= t_xseq;
                        end
                        default: ;
                    endcase
                end
                dout_r <= w_val;
                if (wcnt != 6'h3F) wcnt <= wcnt + 6'd1;
            end
        end
    end
    assign drive = rd_act;
    assign win_hold = wr_act;               // a HOST_WR in progress: the window may be half-written
    assign dout  = dout_r;

    // ---- P9: the levels (cleared the cycle host_ok falls, above: never restored by a return) --------------
    assign grab = grab_r;
    assign ui   = ui_r;
    assign menu = menu_r;
    assign mute = mute_r;
    assign ui_sub = uis_r;

    // ---- P9: the event FIFO (8 deep; pushes only while host_ok) ------------------------------------------------
    logic        ks_v;                     // the key skid: a press waiting for a cycle with no event
    logic [15:0] ks_m;
    wire  [15:0] kp      = key_press & grab;
    wire  [7:0]  ev_n    = ev_wc - ev_rc;
    wire         ev_full = (ev_n == 8'd8);
    wire         ev_pv   = host_ok && (ev_in_v || ks_v);
    wire  [19:0] ev_pw   = ev_in_v ? {ev_in_code, ev_in_data} : {4'd15, ks_m};
    always_ff @(posedge clk) begin
        if (!rst_n) begin
            ev_wc <= '0; ev_rc <= '0; ev_lost <= '0; ks_v <= 1'b0; ks_m <= '0;
        end else begin
            // pops: to the host's count, never past what was written
            if (ev_rc != ev_rp_h && ev_rc != ev_wc) ev_rc <= ev_rc + 8'd1;
            if (ev_pv) begin
                if (!ev_full) begin evq[ev_wc[2:0]] <= ev_pw; ev_wc <= ev_wc + 8'd1; end
                else if (ev_lost != 8'hFF) ev_lost <= ev_lost + 8'd1;
            end
            // the skid: taken this cycle unless an event had it; a press meanwhile merges
            if (!host_ok) begin ks_v <= 1'b0; ks_m <= '0; end
            else if (ev_in_v) begin
                if (kp != 16'd0) begin ks_v <= 1'b1; ks_m <= (ks_v ? ks_m : 16'd0) | kp; end
            end else begin
                ks_v <= (kp != 16'd0); ks_m <= kp;
            end
        end
    end

    // ---- the completion, clk_sys -> mclk: a toggle change is one h_done -------------------------------------
    logic [45:0] cm;
    cdc_snap #(.W(46)) u_done (
        .src_clk (clk), .src_rst_n (rst_n), .src_data ({c_tog, cr_seq, cr_err, cr_w, cr_h}),
        .dst_clk (mclk), .dst_rst_n (mrst_n), .dst_data (cm), .dst_tick ()
    );
    logic m_tog;
    always_ff @(posedge mclk) begin
        if (!mrst_n) begin
            m_tog <= 1'b0; h_done <= 1'b0;
        end else begin
            h_done <= (cm[45] != m_tog);
            m_tog  <= cm[45];
            {h_done_seq, h_done_err, h_done_w, h_done_h} <= cm[44:0];
        end
    end

endmodule

`default_nettype wire
