#!/usr/bin/env python3
"""host_layout.py -- the host port's wire format, written down once (docs/hps_host.md §2):
umd/umd_host.sv answers HOST_RD and takes HOST_WR on hps_io's EXT_BUS; the UMD Main
(main/support/umd/, B4) is the other side.

Generated from these tables (committed, like the telemetry's):
  umd/umd_host_words.svh               the RTL: the commands, MAGIC / PROTO, the HOST_RD
                                       word mux (a case on the word index) and the HOST_WR
                                       word indices
  main/support/umd/umd_host_proto.h    the same for Main's C

    host_layout.py           write both
    host_layout.py --check   exit 1 if a generated file differs from the tables

HOST_RD (core -> host), one transaction a poll. The whole record is LATCHED at the command
strobe, so every word of one read is one snapshot (umd_host crosses the request from the DDR3
clock continuously; a transaction is ~60 us of strobes). Word 0 MAGIC, word 1 {PROTO, NWORDS}.
HOST_WR (host -> core): the first strobe is the command, then the words below, one a strobe.
Word 1's PROTO is the heartbeat: a match sets host_ok for ~2.5 s; a mismatch sets host_bad.
The completion is taken at its last word, only with the PROTO matching.

P9 (docs/p9.md §3.2) appends the menu rows: the player's state, the host's commands, the button
grab, `ui` / `menu`, the host's flip, the PCM one-shot, the event FIFO. APPENDED, so the B4 Main's
transactions (HOST_RD's first 13 words, HOST_WR's first 4) mean what they meant: PROTO stays 1 and
NWORDS is the capability (a Main that finds NWORDS 13 runs without menus). PROTO changes only on an
incompatible change.

ONCE-ONLY (HOST_WR is re-sent every poll: it is the heartbeat): the player command, the flip and
the PCM trigger each carry a seq u8 in their first word and are taken at their LAST word when the
seq differs from the last one taken (and the PROTO of the transaction matched); HOST_RD's `acks` /
`pcm_ack` echo the last seq taken, so the host sends the next only after its echo. At start the
host adopts the echoed seqs (a core load resets them to 0; the host never reuses 0 after a
command). The event FIFO is read by count: HOST_RD gives the write count and the read count
(mod 256) and the first 4 unread events; HOST_WR's `ev_rp` is the read count the host has consumed
up to, and the core pops until its own equals it (idempotent: a repeated or lost write is
harmless). The levels (`grab`, `ctl`) hold their last value and fall to 0 while host_ok is low. Commands 0x7B / 0x7C are free in stock Main at MAIN_MISTER_REF (it uses
0x00-0x44, 0x61-0x63, 0xF0-0xF9; the telemetry takes 0x7A): re-check on a Main bump.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CMD_RD = 0x7B
CMD_WR = 0x7C
MAGIC = 0xB057
PROTO = 1

# HOST_RD: (name, RTL expression over umd_host's latched record r_*, what it is)
RD = [
    ("magic", "16'hB057", "MAGIC"),
    ("proto", "{8'd%d, 8'd%d}", "{PROTO, NWORDS}"),     # filled in below
    ("gen", "{8'd0, r_gen}", "[7:0] the subtitle side's flush count: a request of an older gen is abandoned"),
    ("req", "{r_req, r_buf, 6'd0, r_seq}", "[15] a request is outstanding [14] its plane [7:0] its seq"),
    ("req_x", "r_x", "the unit's x on the plane"),
    ("req_y", "r_y", "the unit's y"),
    ("req_start_lo", "r_start[15:0]", "the unit's first 64-bit word in the ring, [15:0]"),
    ("req_start_hi", "{12'd0, r_start[19:16]}", "... [19:16]"),
    ("req_len_lo", "r_len[15:0]", "the unit's PNG length, bytes, [15:0]"),
    ("req_len_hi", "r_len[31:16]", "... [31:16]"),
    ("shown", "{r_vis, 7'd0, r_shown}", "[15] the front plane is shown [7:0] the seq of the unit in it"),
    ("stale", "r_stale", "completions the core ignored (no request, or not its seq), 16-bit counter"),
    ("status", "{r_ok, r_bad, r_ui, r_menu, r_win, r_win_bad, r_goto_open, r_sub_any, r_ui_sub, 7'd0}", "[15] the core sees the heartbeat (host_ok) [14] a PROTO mismatch (host_bad) [13] ui [12] menu (the levels in force) [11] the video window on [10] its geometry refused (empty, or off the raster) [9] Go To's editor is open [8] the title has a subtitle track [7] ui_sub (P6d, docs/panel.md F2 / F5: the level in force)"),
    # ---- P9 (docs/p9.md §3.2): the player (player_ctl's outputs, umd_reader's playlist) ----
    ("play", "{r_state, r_seeking, r_tk_speed, r_tk_rev, r_sub_on, r_pts_v, 2'd0, r_sub_track}",
     "[15:13] state (0 idle 1 play 2 pause 3 stop) [12] seeking [11:10] trick speed [9] reverse [8] subtitles on [7] a picture shown (the key valid) [4:0] subtitle track (0x80 + n)"),
    ("audio", "{r_pcm_busy, r_pic_known, r_pic_wide, r_menu_aa, r_zoom, 6'd0, r_aud_track}", "[15] the PCM one-shot is playing [14] the shown picture's aspect is known (its VUI) [13] it is 16:9, else 4:3 [12:11] a menu's fit to a 4:3 CRT (the 480i raster): 0 Fit (480p, or Analog Aspect Fit), 1 Letterbox (Auto, Letterbox: the scene into 720 x 360 at line 60), 2 Crop (the scene's centre 640 x 480 onto the raster) [10] Zoom in force (fj#71, docs/zoom.md: only raster lines 60 .. 419 are shown; a subtitle the host places goes inside them) [3:0] the audio track (0xBD00 + n)"),
    ("acks", "{r_cmd_ack, r_flip_ack}", "[15:8] the last player command's seq taken [7:0] the last flip's seq latched at a vblank"),
    ("pcm_ack", "{r_pcm_ack, r_win_ack}", "[15:8] the last PCM trigger's seq taken [7:0] the last video window's seq written"),
    ("chapter", "r_chapter", "the shown chapter (from 1; 0 none)"),
    ("n_chapters", "r_n_chapters", "chapters in the playlist"),
    ("playlist", "r_playlist", "the playlist playing (the longest at a mount; a PLAY's)"),
    ("n_items_lo", "r_n_items[15:0]", "its items [15:0]"),
    ("n_items_hi", "r_n_items[31:16]", "... [31:16]"),
    ("key_lo", "r_key_item[15:0]", "the shown picture's item [15:0]"),
    ("key_hi", "r_key_item[31:16]", "... [31:16]"),
    ("pts_lo", "r_pts[15:0]", "the shown picture's PTS [15:0] (90 kHz)"),
    ("pts_mid", "r_pts[31:16]", "... [31:16]"),
    ("pts_hi", "{15'd0, r_pts[32]}", "... [32]"),
    # ---- the event FIFO (player_ctl's events, teed, and the grabbed buttons) ----
    ("ev_w", "{r_ev_lost, r_ev_wc}", "[15:8] events lost to a full FIFO (saturating) [7:0] events written, mod 256"),
    ("ev_r", "{8'd0, r_ev_rc}", "[7:0] events consumed, mod 256: unread = ev_w[7:0] - this (<= 8)"),
    ("ev0_code", "{12'd0, ev_q0[19:16]}", "the first unread event's code (player_ctl's EV_*, 15 KEY)"),
    ("ev0_data", "ev_q0[15:0]", "... its data (KEY: the grabbed buttons pressed, joystick bit order)"),
    ("ev1_code", "{12'd0, ev_q1[19:16]}", "the second"),
    ("ev1_data", "ev_q1[15:0]", ""),
    ("ev2_code", "{12'd0, ev_q2[19:16]}", "the third"),
    ("ev2_data", "ev_q2[15:0]", ""),
    ("ev3_code", "{12'd0, ev_q3[19:16]}", "the fourth"),
    ("ev3_data", "ev_q3[15:0]", ""),
    ("pcm_under", "r_pcm_under", "the PCM one-shot's late words: ticks that played silence, wrapping"),
    # ---- P6d (docs/panel.md F1): the control panel's press record ----
    ("press_ack", "{8'd0, r_press_ack}", "[7:0] the last press record's seq taken"),
    # ---- A12 SD2 (docs/nav_engine.md §10): the fabric decodes; the unit on show, for the panel's compositor ----
    ("sub_plane", "{r_sbuf, 15'd0}", "[15] the plane (0 / 1) holding the unit `shown` names (sub_sched's front, at the flip's acknowledgement)"),
    ("sub_x", "r_sx", "its rectangle on the plane: x"),
    ("sub_y", "r_sy", "y"),
    ("sub_w", "r_sw", "w"),
    ("sub_h", "r_sh", "h"),
]
# HOST_WR: (name, what) -- word 0 is the command itself
WR = [
    ("cmd", "the command, 0x7C"),
    ("proto", "{PROTO, the host's version}: the heartbeat"),
    ("done", "[15] a completion [12:8] err (0 decoded, 1 libpng refused it, 2 no memory: umd_sub_err) [7:0] the seq it completes"),
    ("done_w", "the image's width, saturating at 0xFFFF (only its clip to 720 matters)"),
    ("done_h", "its height, saturating at 0xFFFF"),
    # ---- P9 (docs/p9.md §3.2) ----
    ("pcmd", "a player command: [15:8] seq (once-only) [7:4] player_ctl's code [3:0] its arg"),
    ("pcmd_pl", "PLAYLIST (13): the playlist"),
    ("pcmd_item_lo", "SEEK (7) / PLAYLIST (13): the item [15:0]; SUB_SET (14): [5] on [4:0] the track"),
    ("pcmd_item_hi", "... [31:16]"),
    ("pcmd_pts0", "SEEK / PLAYLIST: the PTS [15:0]"),
    ("pcmd_pts1", "... [31:16]"),
    ("pcmd_pts2", "... [47:32]: the command is taken at this word"),
    ("grab", "the buttons the host takes (joystick bit order: [3:0] the D-pad, [15:4] the J1 list): pressed, they are KEY events and not the transport's"),
    ("ctl", "[15] ui: the host owns the plane [14] menu: the transport HUD hidden, the stop screen black [13] mute: the film's audio silent (a play() with its audio off; the PCM one-shot still heard) [12] ui_sub (P6d): the host owns the plane, the subtitles still running (docs/panel.md §2)"),
    ("ev_rp", "[7:0] the read count the host has consumed up to (the core pops to it)"),
    ("flip", "the host's plane flip: [15:8] seq (once-only) [2:1] the plane (0 / 1 the subtitles' planes, 2 / 3 the panel's, P6d) [0] shown"),
    ("flip_x", "its x on the screen"),
    ("flip_y", "its y"),
    ("flip_w", "its width"),
    ("flip_h", "its height: the flip is taken at this word, latched at the next vblank"),
    ("pcm", "the PCM one-shot: [15:8] seq (once-only) [0] stereo"),
    ("pcm_start_lo", "its first 64-bit word in the PCM region [15:0]"),
    ("pcm_start_hi", "... [23:16]"),
    ("pcm_len_lo", "its length in sample frames [15:0] (0 stops a sound playing)"),
    ("pcm_len_hi", "... [23:16]: the trigger is taken at this word"),
    # ---- the video window (P9 item 6): a LEVEL, written in place (the reader latches it once a
    #      frame, never during a HOST_WR); its seq only echoes. Steps and starts Q10.16, the
    #      rectangle in raster pixels / frame lines (the host clips it to 720 x 480) ----
    ("win", "[15:8] seq (echoed) [0] the window on"),
    ("win_x", "the rectangle's x"),
    ("win_y", "its y (frame lines)"),
    ("win_w", "its width"),
    ("win_h", "its height"),
    ("win_hs_lo", "source columns a pixel, Q10.16 [15:0]"),
    ("win_hs_hi", "... [25:16]"),
    ("win_vs_lo", "source rows a frame line, Q10.16 [15:0]"),
    ("win_vs_hi", "... [25:16]"),
    ("win_x0_lo", "the first pixel's source column, Q10.16 [15:0]"),
    ("win_x0_hi", "... [25:16]"),
    ("win_y0_lo", "the first line's source row, Q10.16 [15:0]"),
    ("win_y0_hi", "... [25:16]"),
    # ---- P6d (docs/panel.md F1): a press record -- buttons the core acts on as if pressed, ORed in
    #      after the grab and Go To's take. Taken once by its seq at its last word, as a one-cycle
    #      pulse (a press needs no holding: nothing can refuse it), and echoed at once ----
    ("press", "a press record: [15:8] seq (once-only)"),
    ("press_mask", "the buttons pressed (joystick bit order: [3:0] the D-pad, [15:4] the J1 list): taken at this word"),
]
RD[1] = ("proto", "{8'd%d, 8'd%d}" % (PROTO, len(RD)), RD[1][2])

SVH = os.path.join(ROOT, "umd", "umd_host_words.svh")
HDR = os.path.join(ROOT, "main", "support", "umd", "umd_host_proto.h")


def gen_svh():
    out = ["// umd/umd_host_words.svh -- GENERATED by tools/host_layout.py: do not edit.",
           "// The host port's wire format (docs/hps_host.md §2). `include'd inside umd_host.sv.",
           "/* verilator lint_off UNUSEDPARAM */      // the table names every word; the RTL uses some",
           "localparam logic [15:0] H_CMD_RD = 16'h%04X;" % CMD_RD,
           "localparam logic [15:0] H_CMD_WR = 16'h%04X;" % CMD_WR,
           "localparam logic [7:0]  H_PROTO  = 8'd%d;" % PROTO,
           "localparam int          H_NWORDS = %d;" % len(RD)]
    for i, (n, _) in enumerate(WR):
        out.append("localparam logic [5:0]  H_WR_%s = 6'd%d;" % (n.upper(), i))
    out.append("/* verilator lint_on UNUSEDPARAM */")
    out.append("always_comb begin")
    out.append("    case (w_idx)")
    for i, (n, e, _) in enumerate(RD):
        out.append("        6'd%d: w_val = %s;   // %s" % (i, e, n))
    out.append("        default: w_val = 16'd0;")
    out.append("    endcase")
    out.append("end")
    return "\n".join(out) + "\n"


def gen_hdr():
    out = ["// umd_host_proto.h -- GENERATED by tools/host_layout.py: do not edit.",
           "// The host port's wire format (docs/hps_host.md §2): umd/umd_host.sv is the other side.",
           "#pragma once",
           "",
           "#define UMD_HOST_CMD_RD  0x%02X" % CMD_RD,
           "#define UMD_HOST_CMD_WR  0x%02X" % CMD_WR,
           "#define UMD_HOST_MAGIC   0x%04X" % MAGIC,
           "#define UMD_HOST_PROTO   %d" % PROTO,
           "#define UMD_HOST_NWORDS  %d" % len(RD),
           "",
           "// HOST_RD word indices (the first word is the reply to the command strobe)"]
    for i, (n, _, what) in enumerate(RD):
        out.append("#define UMD_HOST_RD_%-14s %2d   // %s" % (n.upper(), i, what))
    out.append("")
    out.append("// HOST_WR word indices (word 0 is the command)")
    for i, (n, what) in enumerate(WR):
        out.append("#define UMD_HOST_WR_%-14s %2d   // %s" % (n.upper(), i, what))
    out.append("#define UMD_HOST_WR_NWORDS         %d" % len(WR))
    return "\n".join(out) + "\n"


def main():
    check = "--check" in sys.argv[1:]
    bad = 0
    for path, text in ((SVH, gen_svh()), (HDR, gen_hdr())):
        cur = open(path).read() if os.path.exists(path) else None
        if check:
            if cur != text:
                print("host_layout: %s differs from the tables (run tools/host_layout.py)" % os.path.relpath(path, ROOT))
                bad = 1
        elif cur != text:
            with open(path, "w") as f:
                f.write(text)
            print("host_layout: wrote %s" % os.path.relpath(path, ROOT))
    if check and not bad:
        print("host_layout: OK -- %d HOST_RD words, %d HOST_WR words" % (len(RD), len(WR)))
    return bad


if __name__ == "__main__":
    sys.exit(main())
