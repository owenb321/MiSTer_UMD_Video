#!/usr/bin/env bash
# run_umd_host.sh -- the host port's gate (umd/umd_host.sv; A7, docs/hps_host.md §2):
# tools/host_layout.py's generated files current, then bench/umd/umd_host_tb.sv (EXT_BUS as
# hps_io drives it; the subtitle side's mclk handshake played by the bench).
# --red: mutations on a COPY (compiled inside it), each caught by its own arm:
#   H1  the bus driven for any command                    -> [offbus]
#   H2  HOST_RD read live, not latched at the command     -> [snapshot]
#   H3  the heartbeat never times out                     -> [heartbeat]
#   H4  a completion taken with a mismatched PROTO        -> [bad]
#   H5  h_done a level of the toggle, not its change      -> [done]
#   H6  the done bit ignored                              -> [done]
#   P9 (docs/p9.md §3.2):
#   H7  a command taken whatever its seq                  -> [cmd]
#   H8  a command echoed when latched, not when taken     -> [cmd]
#   H10 the levels kept while the host is gone            -> [levels]  (restored by its return)
#   H11 a key press meeting an event is dropped (no skid) -> [events]
#   H12 every key press sent, grabbed or not              -> [events]
#   H13 a full FIFO overwritten                           -> [events]
#   H14 events pushed with the host gone                  -> [events]
#   H15 a flip taken whatever its seq                     -> [flip]
#   H16 a PCM trigger taken whatever its seq              -> [pcm]
#   H17 the player's record read live                     -> [snapshot]
#   H18 the window written with a mismatched PROTO        -> [win]
#   H19 win_hold low during a HOST_WR                     -> [win]
#   H20 the window kept when the host goes                -> [win]
#   H21 the shown picture's aspect not latched (P9: a 4:3 clip under a menu) -> [rows]
#   H22 mute not written (P9: a play() with its audio off)  -> [levels]
#   H23 mute kept when the host goes (the film silent for good) -> [levels]
#   H24 menu_aa's high bit not latched (P9: a menu cropped at 480i) -> [rows]
#   H32 Zoom not latched into AUDIO[10] (fj#71: the panel's subtitle placed raw) -> [rows]
#   P6d (docs/panel.md F1 / F2 / F5):
#   H25 a press taken whatever its seq                    -> [press]
#   H26 a press held, not a one-cycle pulse               -> [press]
#   H27 ui_sub not written                                -> [panel]
#   H28 ui_sub kept when the host goes                    -> [panel]
#   H29 the flip's plane one bit (planes 2 / 3 unreachable) -> [panel]
#   H30 Go To's editor not latched into the status word   -> [panel]
#   H31 a press taken with a mismatched PROTO             -> [press]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/host
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

echo "== the table =="
python3 tools/host_layout.py --check | sed 's/^/  /' || fail=1

run() {   # DIR -> PASS / FAIL line on stdout (the log in DIR/log)
  local d=$1
  if ! (cd "$d" && iverilog -g2012 -I . -o sim umd/cdc.sv umd/umd_host.sv "$OLDPWD/bench/umd/umd_host_tb.sv" 2> build.log); then
    echo "BUILD"; return
  fi
  (cd "$d" && timeout 600 vvp -n sim > log 2>&1)
}

echo "== GREEN =="
D=.sim/host/green; rm -rf $D; mkdir -p $D/umd
cp umd/cdc.sv umd/umd_host.sv umd/umd_host_words.svh $D/umd/
run $D
if grep -q "^PASS: umd_host_tb" $D/log; then echo "  PASS $(grep '^umd_host_tb:' $D/log | sed 's/^umd_host_tb: //')"
else echo "  FAIL umd_host_tb"; grep -m3 "FAIL\|rror" $D/log $D/build.log 2>/dev/null; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  mut() {   # name old new arm
    local name=$1 old=$2 new=$3 arm=$4 d
    d=$(mktemp -d); mkdir -p "$d/umd"
    cp umd/cdc.sv umd/umd_host.sv umd/umd_host_words.svh "$d/umd/"
    if ! python3 - "$d/umd/umd_host.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.encode().decode("unicode_escape"); new = new.encode().decode("unicode_escape")
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    run "$d"
    if grep -q "^PASS:" "$d/log" 2>/dev/null; then echo "  $name: SURVIVED -- the bench cannot see this defect"; fail=1
    elif grep -Eq "FAIL \[($arm)\]" "$d/log" 2>/dev/null; then echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)"
    else echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log" "$d/build.log" 2>/dev/null; fail=1; fi
    rm -rf "$d"
  }
  mut H1 "rd_act <= (io_din == H_CMD_RD);" "rd_act <= 1'b1;" offbus
  mut H2 "                dout_r <= w_val;" \
         "                {r_req, r_seq, r_buf, r_x, r_y, r_start, r_len, r_gen, r_vis, r_shown, r_stale, r_sbuf, r_sx, r_sy, r_sw, r_sh} <= snap;\n                dout_r <= w_val;" snapshot
  mut H3 "if (hb_cnt != '0)  hb_cnt  <= hb_cnt - 1'b1;" "if (1'b0)  hb_cnt  <= hb_cnt - 1'b1;" heartbeat
  mut H4 "if (wr_pok && c_done) begin" "if (c_done) begin" bad
  mut H5 "h_done <= (cm[45] != m_tog);" "h_done <= cm[45];" done
  mut H6 "if (wr_pok && c_done) begin" "if (wr_pok) begin" done
  mut H7 "if (wr_pok && t_cseq != cmd_ack && !hc_v) begin" "if (wr_pok && !hc_v) begin" cmd
  mut H8 "hc_item <= t_item; hc_pts <= {io_din, t_pts}; t_cseq_q <= t_cseq;" "hc_item <= t_item; hc_pts <= {io_din, t_pts}; t_cseq_q <= t_cseq; cmd_ack <= t_cseq;" cmd
  mut H10 "if (!host_ok) begin grab_r <= '0; ui_r <= 1'b0; menu_r <= 1'b0; mute_r <= 1'b0; uis_r <= 1'b0; win <= 1'b0; end" "if (!host_ok) begin win <= 1'b0; end" levels
  mut H11 "if (kp != 16'd0) begin ks_v <= 1'b1; ks_m <= (ks_v ? ks_m : 16'd0) | kp; end" "" events
  mut H12 "wire  [15:0] kp      = key_press & grab;" "wire  [15:0] kp      = key_press;" events
  mut H13 "if (!ev_full) begin evq[ev_wc[2:0]] <= ev_pw;" "if (1'b1) begin evq[ev_wc[2:0]] <= ev_pw;" events
  mut H14 "wire         ev_pv   = host_ok && (ev_in_v || ks_v);" "wire         ev_pv   = (ev_in_v || ks_v);" events
  mut H15 "if (wr_pok && t_fseq != flip_ack && t_fseq != t_fseq_q && !hf_req) begin" "if (wr_pok && !hf_req) begin" flip
  mut H16 "if (wr_pok && t_pseq != pcm_ack && t_pseq != t_pseq_q && !hp_req) begin" "if (wr_pok && !hp_req) begin" pcm
  mut H18 "H_WR_WIN_X:      if (wr_pok) win_x" "H_WR_WIN_X:      if (1'b1) win_x" win
  mut H19 "    assign win_hold = wr_act;" "    assign win_hold = 1'b0;" win
  mut H20 "mute_r <= 1'b0; uis_r <= 1'b0; win <= 1'b0; end" "mute_r <= 1'b0; uis_r <= 1'b0; end" win
  mut H21 "r_pic_wide <= pic_wide; r_pic_known <= pic_known;" "r_pic_wide <= pic_wide; r_pic_known <= 1'b0;" rows
  mut H22 "menu_r <= io_din[14]; mute_r <= io_din[13];" "menu_r <= io_din[14];" levels
  mut H24 "r_menu_aa <= menu_aa;" "r_menu_aa <= {1'b0, menu_aa[0]};" rows
  mut H32 "r_zoom <= zoom;" "r_zoom <= 1'b0;" rows
  mut H23 "if (!host_ok) begin grab_r <= '0; ui_r <= 1'b0; menu_r <= 1'b0; mute_r <= 1'b0;" "if (!host_ok) begin grab_r <= '0; ui_r <= 1'b0; menu_r <= 1'b0;" levels
  mut H25 "if (wr_pok && t_xseq != press_ack) begin" "if (wr_pok) begin" press
  mut H26 "hx_v <= 1'b0;                  // P6d: a press is one cycle" "// (held)" press
  mut H27 "uis_r <= io_din[12]; end" "end" panel
  mut H28 "mute_r <= 1'b0; uis_r <= 1'b0; win <= 1'b0; end" "mute_r <= 1'b0; win <= 1'b0; end" panel
  mut H29 "t_fbuf <= io_din[2:1];" "t_fbuf <= {1'b0, io_din[1]};" panel
  mut H30 "r_goto_open <= p_goto_open;" "r_goto_open <= 1'b0;" panel
  mut H31 "if (wr_pok && t_xseq != press_ack) begin" "if (t_xseq != press_ack) begin" press
  mut H17 "                dout_r <= w_val;" "                r_chapter <= p_chapter; r_pts <= p_pts; r_state <= p_state;\n                dout_r <= w_val;" snapshot
fi

echo "== lint =="
if verilator --lint-only -Wall -Wno-DECLFILENAME -Wno-PINCONNECTEMPTY -Wno-SYNCASYNCNET -I. --top-module umd_host \
     umd/cdc.sv umd/umd_host.sv > .sim/host/lint.log 2>&1; then
  echo "  PASS verilator --lint-only -Wall"
else echo "  FAIL lint"; grep -m8 "%Warning\|%Error" .sim/host/lint.log; fail=1; fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
