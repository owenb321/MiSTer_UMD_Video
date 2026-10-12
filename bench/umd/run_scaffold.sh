#!/usr/bin/env bash
# run_scaffold.sh -- the P0 gate: raster + idle screen benches, GREEN then MUTATED, plus
# the emu.sv wiring check.
#
# GREEN: sync_gen_tb (measures the 480p raster), sync_gen_il_tb (the 480i raster, harvested
# from MiSTer_h264_decoder c3c364b: docs/analog.md) and xmb_wave_tb (scores rendered pixels)
# must print their PASS marker. A runner must look for the marker POSITIVELY: a bench that
# dies early prints nothing and a `$finish` on failure exits 0 (MiSTer_DVD lesson).
#
# --red: each mutation is applied to a COPY of the shipping source and must make the
# named arm FAIL. A mutation nobody catches means the bench cannot see that defect.
#   M1  wave phases never advance          -> [mot]  the wave does not move
#       (⚠ ONE frozen wave of three is NOT caught: the whole-frame diff still moves.
#        Covered by the design, not the bench.)
#   M2  tint index forced to month 1       -> [tint] December == January
#   M3  sine quadrant sign dropped         -> [sym]  s(a) + s(a+pi) != 0
#   M4  vertical gradient removed          -> [grad] flat with the waves forced to 0
#   M5  de_out one clock early             -> [cov]  de_out misaligned with de_in
#   M6  leap-year rule dropped             -> [date] 1972-03-01 reads as month 3 one day
#                                                    early / 02-29 as month 3
#   S1  hsync width 62 -> 61               -> sync_gen_tb hsync width
#   S2  vertical total 525 -> 524          -> sync_gen_tb dots per frame
#   480i (docs/analog.md, sync_gen_il_tb):
#   S3  interlaced hsync one dot late      -> sync_gen_il_tb hsync first dot
#   S4  the half-line two dots early       -> sync_gen_il_tb vsync edge spacing (not 262.5 lines)
#   S5  equal field totals (262 + 262)     -> sync_gen_il_tb the two field totals
#   S6  FIELD1_VPOS read inverted          -> sync_gen_il_tb the short field is the v_pos-odd one
#   S7  ce_pix on the odd dots             -> sync_gen_il_tb ce_pix
#   S8  the restart into the bottom field  -> sync_gen_il_tb restart
#   S9  the restart ticks twice (a spurious refresh at a mode switch) -> sync_gen_il_tb the first field is whole
#   W1  xmb_wave.timestamp tied off        -> check_emu_wiring (a constant month)
#   W2  umd_reader.busy tied off           -> check_emu_wiring (bytes dropped on a stall)
#   W3  ps_demux.vid_ready tied 1 (the P2 state) -> check_emu_wiring (video bytes dropped when
#                                                   the front end stalls)
#   (W4, W16, W71: retired with the diagnostic HUD and es_probe, 2026-10-03, area_plan.md A11)
#   W5  telemetry reads fe_slice from clk_dec directly -> check_emu_wiring (a torn readout; the HUD's row until A11)
#   W6  h264_top.se_ready tied 1 (the P3 sink)     -> check_emu_wiring (SEs dropped on a recon stall)
#   W7  ddr_mux2 reset per mount                   -> check_emu_wiring (a burst cut by a mount)
#   W8  ddr_mux2.a_abort tied 0                    -> check_emu_wiring (the same, by the abort)
#   W9  the reconstruction back on clk_sys        -> check_emu_wiring (recon_top is on clk_dec)
#   W10 the holds not from the output queue        -> check_emu_wiring (recon_out drives disp_hold)
#   W11 a counter left out of the HUD snapshot     -> check_emu_wiring (rc_pics crosses in cdc_snap)
#   W12 the display reads through ram1 again       -> check_emu_wiring (disp_reader on DDRAM2)
#   W13 the display's field flag tied 0            -> check_emu_wiring (field chroma on the frame grid)
#   W14 VGA_DE from the idle wave                  -> check_emu_wiring (the raster's own delay)
#   W15 master B cut from the vbuf's engine        -> check_emu_wiring (P6a: the CPB on ram1)
#   W17 aspect_vui fed a constant idc              -> check_emu_wiring (Auto ignores the VUI)
#   W18 Auto back to the P4 constant               -> check_emu_wiring
#   W21 the display's release tied off             -> check_emu_wiring (every store held: a stall)
#   W22 no emission reaches the queue              -> check_emu_wiring (recon_out takes emit_valid)
#   W23 telemetry's emitted count read raw         -> check_emu_wiring (the snapshot copy; the P5d row until A11)
#   W24 the display's control on clk_dec           -> check_emu_wiring (the raster's clock)
#   W25 the reader's parity tied 0                 -> check_emu_wiring (disp_ctl's decision)
#   W26 telemetry's fetched-change count read raw  -> check_emu_wiring (the clk_mem snapshot)
#   W27 the telemetry responder off EXT_BUS        -> check_emu_wiring
#   W28 a DDR3 probe on an inner wire              -> check_emu_wiring (what the HPS sees)
#   W29 the probe counters left in clk_mem         -> check_emu_wiring (the cdc_snap)
#   W30 ddr_mux2 reset with RESET                  -> check_emu_wiring (a held request withdrawn)
#   W31 the reader's fetch side reset with RESET   -> check_emu_wiring (a held read withdrawn)
#   W32 the abort register reset with RESET        -> check_emu_wiring (the abort cleared mid-reset)
#   W33 the deinterlace mode tied to Weave         -> check_emu_wiring (the menu's O[4:3])
#   W34 the single-field flag tied 0               -> check_emu_wiring (a lone field woven)
#   W35 the demux's aud_ready tied 1               -> check_emu_wiring (bytes lost when the ring fills)
#   (W36 retired with es_probe, A11)
#   W37 the audio gate's STC claimed running       -> check_emu_wiring (the display's STC)
#   W38 the gate never told the ring is blocking   -> check_emu_wiring (the deadlock rule)
#   W39 AUDIO_L tied 0                             -> check_emu_wiring (aud_out's audio_l)
#   W40 the decoder reset with RESET, not per mount -> check_emu_wiring (fe_rst_n)
#   W86-W94 P9: the sound mix, the grab mask, the host command's turn, the black stop under a
#       menu, the subtitle output and the flush under ui, the HUD hidden, NAV_PLAY's playlist,
#       the video window
#   W95-W97 P9, the aspect under a menu: Auto 16:9, Analog Aspect Fit, the picture's aspect to the
#       host (docs/p9.md M3, the first rig session)
#   W98-W99 P9, a play() with its audio off: the film heard through host_mute; umd_host's mute
#       tied off (docs/p9.md M3, the third rig session)
#   W100-W103 P9, a menu fitted at 480i: menu_aa ignoring Fit; Crop letterboxing a menu; the host
#       never told; HDMI left 16:9 over the fitted raster (docs/analog.md S7)
#   W104 P9 M3b: Disc Menus' h1 bit not the UMD Main's heartbeat (the option shown on a stock Main)
#   W105 P9 M4: a menu page over a STOPPED player not shown (Ghost in the Shell 2.0's chapter menu black)
#   W106 A11: the unplay pulse tied off (a refused stream silent: no "This disc cannot be played.")
#   W107 A11: telemetry's refusal code tied off       W108 A11: telemetry's reader warnings tied off
#   W109 P6c: Go To's keys reach the UMD Main (Stop grabbed by a disc as well as backing out)
#   W110 P6c: the reader's nav_op 2 bits (a TIME arrives as a reserved op)
#   W111 P6c: Go To's jump not on player_ctl's command port
#   W127 P8: player_ctl not told of a bare file (its seeks issued, its flush cutting the stream)
#   W128 P8: player_ctl given the reader's CLP mask (a bare file's tracks never seen)
#   W129 P8: the subtitle tap not reaching bare_sub
#   W130 Analog Dither (docs/analog.md S9): VGA_DITHER tied on (every board dithered)
#   W132-W139 A-B Repeat (docs/ab_repeat.md): its press cut; its SEEK over a button's; CLEAR reaching
#       player_ctl; FF / REW, a chapter press, Go To not masked while it loops; the SEEK's item not A's;
#       a host seek not clearing it; W140 / W141 its message and its tag cut from the HUD
#   W131 Analog Dither: its CONF_STR row on bit 15 (Disc Menus' bit switching the dither)
#   W112 P6c: Go To's editor not drawn (the HUD's goto_open tied off)
#   W113 P6d: the panel's press not into the transport's presses
#   W114 P6d: the panel's press into hk_press (it would come back to the panel as a KEY)
#   W115 P6d: Go To's open blind to the panel's press        W116 P6d: Go To's editor tied off in HOST_RD
#   W117 P6d: sub_flip blind to the panel's mode              W118 P6d: the panel never over a stop
#   W119 P6d: the flip's plane 1 bit (planes 2 / 3 lost)      W120 P6d: the press held, not a pulse
#   W121 P6d: the panel button's message tied off             W122 P6d: a stale UMD Main read as none
#   W123 P6d+: Audio always shows (never cycles)               W124 P6d+: the show press also cycles
#   W125 A12 SD3: Subtitle's tag gated on the UMD Main again; W153 SD1: the UMD Main asked to decode beside
#       the fabric; W154 SD3: SUB gated on the UMD Main again (W127 / W128 until fj#71: the names were taken
#       twice, so the P8 pair's results were overwritten and never reported). W126 P6d+: the HUD shows no current track
#   fj#71 Zoom (docs/zoom.md; zoom_ctl's own arms: run_zoom.sh): W142 the cut lines kept in DE (the scaler
#       sees the whole raster); W143 VIDEO_ARX not 16:9 under Zoom; W144 Zoom under a disc menu; W145 Zoom
#       at 480i; W146 the HUD's layout not inside the band; W147 the fabric's subtitle not moved; W148 the
#       cut lines' RGB not blanked (analog); W149 the Aspect Ratio row without Zoom; W150 Zoom over the
#       disc screen (STOP); W151 the HUD not moved down into the band; W152 the UMD Main not told
#   W72-W85 the 480i raster (docs/analog.md): the raster never interlaced; Auto from the live
#       ini wire; the wave fed raw dots; CE_PIXEL / VGA_F1 a clock early; csync from the raw
#       hsync / always on; disp_ctl / disp_reader / sub_overlay / transport_hud blind to 480i;
#       a paused pair's still dropped; the menumask not the raster; HDMI bob on 480p
#   W41 the gate's tag pop cut                     -> check_emu_wiring (the tags)
#   W42 the CDC fed by the demux, the vbuf bypassed -> check_emu_wiring (P6a)
#   W43 the vbuf's engine reset with RESET          -> check_emu_wiring (a held request withdrawn)
#   W44 the title's flush straight from the reader  -> check_emu_wiring (bytes still in the vbuf)
#   W45 the parameter sets reset by a seek          -> check_emu_wiring (P6b3: ps_rst_n the mount's)
#   W46 the output queue reset by a seek            -> check_emu_wiring (its FIFOs reset one side)
#   W47 the audio gate running through a pause      -> check_emu_wiring (aud_out.freeze = ds_frz)
#   W48 the reader streaming into a flush           -> check_emu_wiring (busy | pc_rd_hold)
#   W49 the transport reset per mount               -> check_emu_wiring (the core reset)
#   W50 Stop with no idle screen                    -> check_emu_wiring (wave_vis)
#   W51 the demux not reset by a seek               -> check_emu_wiring (dmx_rst_n = pipe_rst_n)
#   W52 the item tag dropped at the FIFO            -> check_emu_wiring (P6b3i)
#   W53 the front end's item tag tied off           -> check_emu_wiring (P6b3i)
#   W54 the reader never held at an item start      -> check_emu_wiring (P6b3i)
#   W55 the audio blind to the items the display left -> check_emu_wiring (P6b3i: the MCR hang)
#   W56 the decoder blind to the display's freeze   -> check_emu_wiring (P6b3i: a pause counted errors)
#   W57 the front end blind to a trick-play hop     -> check_emu_wiring (P6b4: decodes on past the I)
#   W58 the D-pad live while the OSD is open        -> check_emu_wiring (P6b4: FF / REW from the menu)
#   W59 the transport HUD never shown               -> check_emu_wiring (P6b5: the output skips th_rgb)
#   W60 the HUD's elapsed blind to the item bases   -> check_emu_wiring (P6b5: a multi-item title's time)
#   W61 two J1 buttons swapped in CONF_STR          -> check_emu_wiring (P6b6: every key and command a bit off)
#   W62 Select (x) issues PAUSE                     -> check_emu_wiring (2026-10-07: Select is Play/Pause's toggle)
#   W63 Display read from the Audio bit             -> check_emu_wiring (P6b6)
#   W64 the landing word fed the shown PTS          -> check_emu_wiring (P6b7: every pickup a "landing")
#   W65 two of the HUD's telemetry flags swapped    -> check_emu_wiring (P6b7)
#   W66 the recovery-point counts cross unsnapped   -> check_emu_wiring (P6b7: clk_dec read on clk_sys)
#   W19 h264_top's PTS input tied off              -> check_emu_wiring (no picture tagged)
#   W20 telemetry's picture-timing count read raw -> check_emu_wiring (a torn readout; the P5 row until A11)
#   T1  sys_top: ram2_clk back to clk_audio        -> check_emu_wiring (sys_top arm)
#   T2  sys_top: ram2's declarations below sysmem  -> check_emu_wiring (declaration order)
#   T3  sys_top: ddr_svc drives ram2 again         -> check_emu_wiring (two drivers)
#   T4  umd.sdc names a module that is gone        -> check_emu_wiring (a silent no-op exception)
#   T5  sys_top: one low-bit driver left on vga_o  -> check_emu_wiring (Analog Dither: a channel never dithered)
#   T6  sys_top: a 6-bit pin left on vga_o         -> check_emu_wiring (Analog Dither)
#   T7  sys_top: dac_dither fed before the yc mux  -> check_emu_wiring (Analog Dither: S-Video never dithered)
#   T8  sys_top: emu's VGA_DITHER unconnected      -> check_emu_wiring (Analog Dither: the OSD reaches nothing)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/xmb_wave
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

run_bench() {   # name  marker  sources...
  local name=$1 marker=$2; shift 2
  iverilog -g2012 -o ".sim/${name}_sim" "$@" || { echo "  FAIL $name: build"; fail=1; return; }
  if vvp ".sim/${name}_sim" 2>&1 | grep -v '^VCD\|sorry' | tee ".sim/${name}.log" | grep -q "^PASS: $marker"; then
    echo "  PASS $name"
  else
    echo "  FAIL $name"; grep "FAIL\|date:\|tint:" ".sim/${name}.log" | head -12; fail=1
  fi
}

echo "== GREEN =="
run_bench sync_gen sync_gen_tb umd/sync_gen.sv bench/umd/sync_gen_tb.sv
run_bench sync_gen_il sync_gen_il_tb umd/sync_gen.sv bench/umd/sync_gen_il_tb.sv
run_bench xmb_wave xmb_wave_tb umd/sync_gen.sv umd/xmb_wave.sv bench/umd/xmb_wave_tb.sv

echo "== WIRING =="
if python3 tools/check_emu_wiring.py; then :; else fail=1; fi

if command -v verilator >/dev/null 2>&1; then
  echo "== LINT =="
  if tools/lint_undriven.sh; then :; else fail=1; fi
fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name  file  old  new  bench-sources(with FILE placeholder)  marker  pattern
    local name=$1 file=$2 old=$3 new=$4 srcs=$5 marker=$6 pat=$7
    local d; d=$(mktemp -d)
    python3 - "$d" "$file" "$old" "$new" <<'PYEOF'
import sys, os
d, f, old, new = sys.argv[1:5]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')   # runner passes \n for newlines
s = open(f).read()
assert s.count(old) == 1, f"mutation anchor not unique/found in {f}: {old!r}"
open(os.path.join(d, os.path.basename(f)), 'w').write(s.replace(old, new))
PYEOF
    local msrc=${srcs//FILE/$d/$(basename "$file")}
    if ! iverilog -g2012 -o "$d/sim" $msrc 2>"$d/build.log"; then
      echo "  $name: DID NOT COMPILE (harness failure)" > "$RES/$name"; echo MUTFAIL >> "$RES/$name"; rm -rf "$d"; return
    fi
    vvp "$d/sim" 2>&1 | grep -v '^VCD\|sorry' > "$d/log"
    if grep -q "^PASS: $marker" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "$pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 "$pat" "$d/log" | cut -c1-60)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep FAIL "$d/log" | head -3; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  W="umd/sync_gen.sv FILE bench/umd/xmb_wave_tb.sv"
  S="FILE bench/umd/sync_gen_tb.sv"
  mut M1 umd/xmb_wave.sv "end else if (frame_tick) begin\n        ph0 <= ph0 + PH_INC0;" "end else if (1'b0) begin\n        ph0 <= ph0 + PH_INC0;" "$W" xmb_wave_tb "FAIL \[mot\]" &
  mut M2 umd/xmb_wave.sv "? month_force : month_q;" "? 4'd1 : 4'd1;" "$W" xmb_wave_tb "FAIL \[tint\]" &
  mut M3 umd/xmb_wave.sv "s0_q <= a0_q[15] ? -\$signed({1'b0, m0}) : \$signed({1'b0, m0});" "s0_q <= \$signed({1'b0, m0});" "$W" xmb_wave_tb "FAIL \[sym\]" &
  mut M4 umd/xmb_wave.sv "11'sd200 - \$signed({4'd0, v_s2[9:2]})" "11'sd140" "$W" xmb_wave_tb "FAIL \[grad\]" &
  mut M5 umd/xmb_wave.sv "de_out <= de_s3;" "de_out <= de_s2;" "$W" xmb_wave_tb "FAIL \[cov\]" &
  mut M6 umd/xmb_wave.sv "wire leap = (y4 == 2'd0) &&" "wire leap = 1'b0 &&" "$W" xmb_wave_tb "FAIL \[date\]" &
  mut S1 umd/sync_gen.sv "parameter H_SYNC   = 62," "parameter H_SYNC   = 61," "$S" sync_gen_tb "FAIL hsync width" &
  mut S2 umd/sync_gen.sv "parameter V_BP     = 30" "parameter V_BP     = 29" "$S" sync_gen_tb "FAIL dots per frame" &
  SI="FILE bench/umd/sync_gen_il_tb.sv"
  mut S3 umd/sync_gen.sv "localparam IH_SS     = 2 * (H_ACTIVE + H_FP);" "localparam IH_SS     = 2 * (H_ACTIVE + H_FP) + 1;" "$SI" sync_gen_il_tb "FAIL hsync first dot" &
  mut S4 umd/sync_gen.sv "localparam IH_HALF   = H_TOTAL;" "localparam IH_HALF   = H_TOTAL - 2;" "$SI" sync_gen_il_tb "FAIL vsync edge spacing" &
  mut S5 umd/sync_gen.sv "(v_cnt == (field1 ? IV_SHORT - 1 : IV_SHORT))" "(v_cnt == (IV_SHORT - 1))" "$SI" sync_gen_il_tb "FAIL the two field totals" &
  mut S6 umd/sync_gen.sv "wire field1 = ((~odd_field) == \`FIELD1_VPOS);" "wire field1 = ((~odd_field) != \`FIELD1_VPOS);" "$SI" sync_gen_il_tb "FAIL the short field is the v_pos-odd one" &
  mut S7 umd/sync_gen.sv "ce_pix     <= il_q ? ~h_cnt[0] : 1'b1;" "ce_pix     <= il_q ? h_cnt[0] : 1'b1;" "$SI" sync_gen_il_tb "FAIL ce_pix" &
  wait
  mut S8 umd/sync_gen.sv "v_cnt <= 12'd0;\n            odd_field <= 1'b1;\n        end else begin" "v_cnt <= 12'd0;\n            odd_field <= 1'b0;\n        end else begin" "$SI" sync_gen_il_tb "FAIL restart: the first field is the top one" &
  mut S9 umd/sync_gen.sv "(v_cnt == 12'd0) && !mode_chg;" "(v_cnt == 12'd0);" "$SI" sync_gen_il_tb "FAIL reset-interlaced first field whole" &
  wait
  # W1: the wiring checker on a mutated emu.sv (no bench: emu has none)
  d=$(mktemp -d)
  sed 's/\.timestamp   (hps_timestamp),/.timestamp   (33'"'"'d0),/' umd/emu.sv > "$d/emu.sv"
  if cmp -s umd/emu.sv "$d/emu.sv"; then echo "  W1: anchor missed" > "$RES/W1"; echo MUTFAIL >> "$RES/W1"
  elif python3 tools/check_emu_wiring.py "$d/emu.sv" >/dev/null 2>&1; then
    { echo "  W1: SURVIVED -- check_emu_wiring accepts a constant timestamp"; echo MUTFAIL; } > "$RES/W1"
  else echo "  W1: caught by check_emu_wiring" > "$RES/W1"; fi
  rm -rf "$d"
  # W2: the reader's backpressure tied off
  d=$(mktemp -d)
  sed 's/\.busy           (stream_busy | pc_rd_hold),/.busy           (1'"'"'b0),/' umd/emu.sv > "$d/emu.sv"
  if cmp -s umd/emu.sv "$d/emu.sv"; then echo "  W2: anchor missed" > "$RES/W2"; echo MUTFAIL >> "$RES/W2"
  elif python3 tools/check_emu_wiring.py "$d/emu.sv" >/dev/null 2>&1; then
    { echo "  W2: SURVIVED -- check_emu_wiring accepts a tied-off reader busy"; echo MUTFAIL; } > "$RES/W2"
  else echo "  W2: caught by check_emu_wiring" > "$RES/W2"; fi
  rm -rf "$d"
  wmut() {   # name  sed-expression  what-survived-means
    local d; d=$(mktemp -d)
    sed "$2" umd/emu.sv > "$d/emu.sv"
    if cmp -s umd/emu.sv "$d/emu.sv"; then echo "  $1: anchor missed" > "$RES/$1"; echo MUTFAIL >> "$RES/$1"
    elif python3 tools/check_emu_wiring.py "$d/emu.sv" >/dev/null 2>&1; then
      { echo "  $1: SURVIVED -- check_emu_wiring accepts $3"; echo MUTFAIL; } > "$RES/$1"
    else echo "  $1: caught by check_emu_wiring" > "$RES/$1"; fi
    rm -rf "$d"
  }
  wmut W3 's/\.vid_ready           (vid_ready),/.vid_ready           (1'"'"'b1),/' "a tied-off demux vid_ready"
  wmut W5 's/\.t_slices      (sn_slice),/.t_slices      (fe_slice),/' "telemetry reading a clk_dec counter raw"
  wmut W6 's/\.se_ready      (se_ready),/.se_ready      (1'"'"'b1),/' "a tied-off SE ready"
  wmut W7 's/\.rst_n             (mem_lock_n),/.rst_n             (fe_rst_mem_n),/' "the port mux reset per mount"
  wmut W8 's/\.a_abort           (dpb_abort_q\[1\]),/.a_abort           (1'"'"'b0),/' "a tied-off abort"
  wmut W9 's/\t\.clk              (clk_dec),/\t.clk              (clk_sys),/' "the reconstruction on clk_sys"
  wmut W10 's/\.oq_hold        (disp_hold),/.oq_hold        (),/' "holds not from the output queue"
  wmut W11 's/\.src_data  ({rc_pics, rc_mbs,/.src_data  ({32'"'"'d0, rc_mbs,/' "a counter left out of the snapshot"
  wmut W12 's/\.ddr_read        (DDRAM2_RD),/.ddr_read        (DDRAM_RD),/' "the display (the subtitle overlay's port, P7) on ram1"
  wmut W13 's/\.pic_field         (sh_field),/.pic_field         (1'"'"'b0),/' "a constant field flag"
  wmut W14 's/vga_de_q <= de_dly\[6\];/vga_de_q <= wave_de;/' "VGA_DE from the wave"
  wmut W15 's/\.b_read            (vbm_read),/.b_read            (1'"'"'b0),/' "master B cut from the vbuf"
  wmut W17 's/\.aspect_idc (sh_ar_idc),/.aspect_idc (8'"'"'d5),/' "a constant aspect_ratio_idc"
  wmut W18 's/^wire auto_wide  = media_seen ? (host_menu | (vui_sar_known ? vui_wide : 1'"'"'b1)) : idle_wide;/wire auto_wide  = media_seen | idle_wide;/' "Auto ignoring the VUI"
  wmut W19 's/\.es_pts        (es_data\[41:9\]),/.es_pts        (33'"'"'d0),/' "a PTS input tied off"
  wmut W20 's/\.t_pt          (sn_pt),/.t_pt          (fe_pt_seen),/' "telemetry's picture-timing count read raw"
  wmut W21 's/\.rel_valid      (rl_valid),/.rel_valid      (1'"'"'b0),/' "a release tied off"
  wmut W22 's/\.emit_valid     (em_valid),/.emit_valid     (1'"'"'b0),/' "no emission reaching the queue"
  wmut W23 's/\.t_emitted     (sn_oe),/.t_emitted     (oq_emit),/' "telemetry's emitted count read raw"
  wmut W24 '/^disp_ctl disp_ctl_inst/,/);/s/\.clk            (clk_sys),/.clk            (clk_dec),/' "the display's control on clk_dec"
  wmut W25 's/\.pic_parity        (sh_parity),/.pic_parity        (1'"'"'b0),/' "a constant parity"
  wmut W26 's/\.t_ft          (sn_ft),/.t_ft          (rd_fetch_changes),/' "telemetry's fetched count read raw"
  wmut W27 's/\.EXT_BUS        (ext_bus),/.EXT_BUS        (),/' "a responder off EXT_BUS"
  wmut W28 's/\.waitrequest   (DDRAM_BUSY),/.waitrequest   (dpb_waitrequest),/' "a probe on an inner wire"
  wmut W29 's/\.src_data  ({d1_wr\[23:8\], d1_rdb\[23:8\], d1_owed, d1_busy, d1_busy_max}),/.src_data  ({16'"'"'d0, d1_rdb[23:8], d1_owed, d1_busy, d1_busy_max}),/' "the probe counters left in clk_mem"
  wmut W33 's/\.deint_mode        (status\[4:3\]),/.deint_mode        (2'"'"'d0),/' "the mode tied to Weave"
  wmut W34 's/\.pic_single        (sh_single),/.pic_single        (1'"'"'b0),/' "a constant single flag"
  wmut W35 's/\.aud_ready           (aud_ready),/.aud_ready           (1'"'"'b1),/' "a tied-off demux aud_ready"
  wmut W37 's/\.stc_run       (ds_stc_run),/.stc_run       (1'"'"'b1),/' "a gate clock claimed running"
  wmut W38 's/\.ring_blocked  (aud_valid \& ~aud_ready),/.ring_blocked  (1'"'"'b0),/' "a gate never told the ring blocks"
  wmut W39 's/^assign AUDIO_L   = (mx_l\[16\] != mx_l\[15\]) ? {mx_l\[16\], {15{~mx_l\[16\]}}} : mx_l\[15:0\];/assign AUDIO_L   = 16'"'"'d0;/' "AUDIO_L tied 0"
  wmut W40 '/^at3p_top at3p_top_inst/,/);/s/\.rst_n      (aud_rst_n),/.rst_n      (reset_n),/' "the decoder reset with RESET"
  wmut W45 '/^h264_top h264_top_inst/,/);/s/\.ps_rst_n      (fe_rst_dec_n),/.ps_rst_n      (pipe_rst_dec_n),/' "the parameter sets reset by a seek"
  wmut W46 '/^recon_out #/,/);/s/\.rst_n          (fe_rst_dec_n),/.rst_n          (pipe_rst_dec_n),/' "the output queue reset by a seek (one FIFO side alone)"
  wmut W47 's/\.freeze        (ds_frz),/.freeze        (1'"'"'b0),/' "the audio gate running through a pause"
  wmut W48 's/\.busy           (stream_busy | pc_rd_hold),/.busy           (stream_busy),/' "the reader streaming into a flush"
  wmut W49 '/^player_ctl player_ctl_inst/,/);/s/\.rst_n          (reset_n),/.rst_n          (fe_rst_n),/' "the transport reset per mount"
  wmut W50 's/^wire       wave_vis = ~media_seen | (pc_idle \& ~host_menu);/wire       wave_vis = ~media_seen;/' "Stop with no idle screen"
  wmut W51 's/^wire dmx_rst_n = pipe_rst_n;/wire dmx_rst_n = fe_rst_n;/' "the demux not reset by a seek"
  wmut W52 's/\.wr_data     ({stream_ep, stream_data}),/.wr_data     ({2'"'"'d0, stream_data}),/' "the item tag dropped at the FIFO"
  wmut W53 's/\.es_ep         (es_data\[43:42\]),/.es_ep         (2'"'"'d0),/' "the front end's item tag tied off"
  wmut W54 's/\.item_hold      (pc_item_hold),/.item_hold      (1'"'"'b0),/' "the reader never held at an item start"
  wmut W55 's/\.left_mask     (ds_left),/.left_mask     (4'"'"'d0),/' "the audio blind to the items the display left"
  wmut W56 's/\.disp_frz         (frz_dec_s\[1\]),/.disp_frz         (1'"'"'b0),/' "the decoder blind to the display's freeze"
  wmut W57 's/\.one_frame     (one_dec_s\[1\]),/.one_frame     (1'"'"'b0),/' "the front end blind to a trick-play hop"
  wmut W58 's/ \& {4{~OSD_STATUS}})/)/' "the D-pad live while the OSD is open"
  wmut W59 "s/^\tvga_r_q  <= cut_dly\[6\] ? 8'd0 : th_rgb\[23:16\];/\tvga_r_q  <= cut_dly[6] ? 8'd0 : bg_r;/" "the transport HUD never shown"
  wmut W60 's/\.item_base   (rd_item_base),/.item_base   (48'"'"'d0),/' "the HUD's elapsed blind to the item bases"
  wmut W61 's/Next Chapter,Audio,Display,/Next Chapter,Display,Audio,/' "two J1 buttons swapped in CONF_STR"
  wmut W62 's/btn_cmd\[5\] ? 4'"'"'d1 :/btn_cmd[5] ? 4'"'"'d2 :/' "Select (x) issues PAUSE"
  wmut W63 's/wire       bp_disp   = btn_press\[10\];/wire       bp_disp   = btn_press[9];/' "Display read from the Audio bit"
  wmut W64 's/\.t_land        (pc_land),/.t_land        (ds_sh_pts),/' "the landing word fed the shown PTS"
  wmut W65 's/\.t_hud         ({th_disp, th_tph, th_tbad, th_tcut}),/.t_hud         ({th_disp, th_tbad, th_tph, th_tcut}),/' "two of the HUD's telemetry flags swapped"
  wmut W66 's/\.t_rlead       (sn_rlead),/.t_rlead       (rc_lead_s),/' "the recovery-point counts cross unsnapped"
  # P7: the subtitle overlay owns ram2 (docs/compositor.md §8, docs/subtitles.md §7)
  wmut W67 's/\.ddr_address       (vr_address),/.ddr_address       (DDRAM2_ADDR),/' "the display reader back on ram2, beside the overlay"
  wmut W68 's/\.srst_n          (lock_sys_n),/.srst_n          (reset_n),/' "the overlay's demux side reset by RESET, its mclk side by the lock"
  wmut W69 's/\.flush           (sb_flush_q\[1\]),/.flush           (1'"'"'b0),/' "a mount or a seek never flushes the subtitles"
  wmut W70 's/\.ddr_write       (DDRAM2_WE),/.ddr_write       (),/' "the subtitle writer cut off ram2"
  # the 480i raster (docs/analog.md)
  wmut W72 's/\.interlaced (interlaced_eff),/.interlaced (1'"'"'b0),/' "the raster never interlaced"
  wmut W73 's/^assign     interlaced_eff = (video_out_mode == 2'"'"'d1) | ((video_out_mode == 2'"'"'d0) \& analog_want_l);/assign     interlaced_eff = (video_out_mode == 2'"'"'d1) | ((video_out_mode == 2'"'"'d0) \& analog_want_raw);/' "Auto from the live ini wire"
  wmut W74 '/^xmb_wave xmb_wave_inst/,/);/s/\.h_pos       (h_col_l7),/.h_pos       (h_pos_l7),/' "the idle wave fed raw dots (squeezed left at 480i)"
  wmut W75 's/vga_ce_q <= ce_dly\[6\];/vga_ce_q <= ce_dly[5];/' "CE_PIXEL a clock early"
  wmut W76 's/vga_f1_q <= f1_dly\[6\];/vga_f1_q <= f1_dly[5];/' "VGA_F1 a clock early"
  wmut W77 's/\.h_sync (hs_dly\[6\]),/.h_sync (h_sync),/' "csync from the raw hsync"
  wmut W78 '/^csync_smpte csync_smpte_inst/,/);/s/\.en     (interlaced_eff),/.en     (1'"'"'b1),/' "csync_smpte always on (480p too)"
  wmut W79 's/\.il             (interlaced_eff),/.il             (1'"'"'b0),/' "disp_ctl's events on the 480p lines at 480i"
  wmut W80 's/\.il                (interlaced_eff),  /.il                (1'"'"'b0),  /' "the reader on the 480p walk at 480i"
  wmut W81 's/\.il              (interlaced_eff),/.il              (1'"'"'b0),/' "the subtitle plane on the 480p lines at 480i"
  wmut W82 's/\.pic_still         (ds_frz),/.pic_still         (1'"'"'b0),/' "a paused pair flickering both fields"
  wmut W83 's/\.il          (interlaced_eff),     \/\/ its pop-up/.il          (1'"'"'b0),     \/\/ its pop-up/' "the HUD's pop-ups twice as long at 480i"
  wmut W84 's/\.status_menumask ({14'"'"'d0, host_ok, interlaced_eff}),/.status_menumask ({14'"'"'d0, host_ok, 1'"'"'b0}),/' "the 480p deinterlace line offered at 480i"
  wmut W85 's/^assign HDMI_BOB_DEINT = interlaced_eff \& status\[5\];/assign HDMI_BOB_DEINT = status[5];/' "HDMI bob on a progressive raster"
  # P9 (docs/p9.md S3.2): the host's rows, the gate, the hand-over, the sound one-shot
  wmut W86 's/+ \$signed({ps_l\[15\], ps_l})//' "the menus' sound left out of the mix"
  wmut W87 's/btn_press = btn_all \& ~host_grab\[15:4\]/btn_press = btn_all/' "grabbed buttons still reaching the transport"
  wmut W88 's/assign     hc_take   = hc_v \& ~pc_cmd_v/assign     hc_take   = hc_v/' "a host command taken over a button's"
  wmut W89 's/(pc_idle \& ~host_menu)/pc_idle/' "the idle wave under a disc menu"
  wmut W90 's/(pc_tkspd == 2'"'"'d0) \& ~host_ui;/(pc_tkspd == 2'"'"'d0);/' "subtitles fed while the host owns the plane"
  wmut W91 's/ | (sb_ui_q\[2\] ^ sb_ui_q\[1\])//' "no flush at ui's edges"
  wmut W92 's/\.show        (media_seen \& ~host_menu)/.show        (media_seen)/' "the transport HUD over a disc menu"
  wmut W93 's/\.nav_pl         (pc_nav_pl),       \/\/ P9 NAV/.nav_pl         (16'"'"'d0),       \/\/ P9 NAV/' "the reader's NAV_PLAY playlist tied off"
  wmut W94 's/\.win               (host_win),/.win               (1'"'"'b0),/' "the video window tied off"
  wmut W95 's/^wire auto_wide  = media_seen ? (host_menu | (vui_sar_known ? vui_wide : 1'"'"'b1)) : idle_wide;/wire auto_wide  = media_seen ? (vui_sar_known ? vui_wide : 1'"'"'b1) : idle_wide;/' "Auto in the clip's aspect under a menu"
  wmut W96 's/^assign     aa_mode   = (!interlaced_eff || host_menu) ? 2'"'"'d0 :/assign     aa_mode   = !interlaced_eff ? 2'"'"'d0 :/' "Analog Aspect letterboxing under a menu"
  wmut W97 's/\.pic_wide    (vui_wide),/.pic_wide    (1'"'"'b1),/' "the picture's aspect to the host tied 16:9"
  wmut W98 's/^wire signed \[15:0\] am_l = host_mute ? 16'"'"'sd0 : ao_l;/wire signed [15:0] am_l = ao_l;/' "the film heard under host_mute"
  wmut W99 's/\.mute        (host_mute),/.mute        (),/' "umd_host's mute left open"
  wmut W100 's/(status\[10:9\] == 2'"'"'d1) ? 2'"'"'d0 : (status\[10:9\] == 2'"'"'d3)/(status[10:9] == 2'"'"'d3)/' "a menu fitted under Analog Aspect Fit"
  wmut W101 's/\.menu_aa     (menu_aa),/.menu_aa     (2'"'"'d0),/' "the host never told to fit a menu"
  wmut W102 's/^assign VIDEO_ARX = (aa_live | menu_aa_on) ? 13'"'"'d4/assign VIDEO_ARX = aa_live ? 13'"'"'d4/' "HDMI 16:9 over a fitted menu"
  wmut W104 's/\.status_menumask ({14'"'"'d0, host_ok, interlaced_eff}),/.status_menumask ({14'"'"'d0, 1'"'"'b1, interlaced_eff}),/' "Disc Menus shown without the UMD Main"
  wmut W103 's/(status\[10:9\] == 2'"'"'d3) ? 2'"'"'d2 : 2'"'"'d1;/(status[10:9] == 2'"'"'d3) ? 2'"'"'d1 : 2'"'"'d1;/' "Crop letterboxing a menu"
  wmut W105 's/^wire       show_pic = media_seen \& (~pc_idle | host_ui | host_uis);/wire       show_pic = media_seen \& (~pc_idle | host_uis);/' "a menu page over a stopped player not shown"
  wmut W106 's/^\t\.unplay      (th_unplay),/\t.unplay      (1'"'"'b0),/' "a disc the core stops on, silent (A11)"
  wmut W107 's/^\t\.t_frc         (sn_refused_code),/\t.t_frc         (4'"'"'d0),/' "telemetry blind to the refusal's code (A11)"
  wmut W108 's/^\t\.t_rwarn       ({rd_dur_sat, rd_title_trunc, rd_sfo_warn}),/\t.t_rwarn       (3'"'"'d0),/' "telemetry blind to the reader's warnings (A11)"
  wmut W109 's/^assign     hk_press   = {btn_all, dpad_all} \& ~gt_take;/assign     hk_press   = {btn_all, dpad_all};/' "Go To's keys reach the UMD Main too (P6c)"
  wmut W110 's/^wire  \[2:0\] pc_nav_op; /wire  [1:0] pc_nav_op; /' "a TIME reaches the reader as a reserved op (P6c)"
  wmut W111 's/\.cmd_valid      (gt_cmd_v | pc_cmd_v | ab_take | hc_pc),/.cmd_valid      (pc_cmd_v | ab_take | hc_pc),/' "Go To's jump never reaches player_ctl (P6c)"
  wmut W127 's/\.bare           (is_bare),/.bare           (1'"'"'b0),/' "player_ctl blind to a bare file (P8)"
  wmut W128 's/\.rd_aud_present (trk_aud),/.rd_aud_present (rd_aud_present),/' "a bare file's audio tracks never seen (P8)"
  wmut W129 's/if (sub_ss_seen) bare_sub\[sub_ss_id\] <= 1'"'"'b1;/if (1'"'"'b0) bare_sub[sub_ss_id] <= 1'"'"'b1;/' "a bare file's subtitle tracks never seen (P8)"
  wmut W130 's/^assign VGA_DITHER  = status\[16\];/assign VGA_DITHER  = 1'"'"'b1;/' "the dither on for every board (Analog Dither)"
  wmut W131 's/"O\[16\],Analog Dither,Off,On;",/"O[15],Analog Dither,Off,On;",/' "the dither's row on Disc Menus' bit (Analog Dither)"
  wmut W113 's/btn_press = btn_all \& ~host_grab\[15:4\] \& ~gt_take\[15:4\] | hx_press\[15:4\];/btn_press = btn_all \& ~host_grab[15:4] \& ~gt_take[15:4];/' "the panel's press never reaching the transport (P6d)"
  wmut W114 's/^assign     hk_press   = {btn_all, dpad_all} \& ~gt_take;/assign     hk_press   = {btn_all, dpad_all} \& ~gt_take | hx_press;/' "the panel's press looping back to it as a KEY (P6d)"
  wmut W115 's/\.k_goto       ((btn_all\[13\] | hx_press\[13\]) \& ~ab_loop),/.k_goto       (btn_all[13] \& ~ab_loop),/' "Go To blind to the panel's press (P6d)"
  wmut W116 's/\.p_goto_open (gt_open),/.p_goto_open (1'"'"'b0),/' "the panel never seeing Go To's editor (P6d)"
  wmut W117 's/\.ui_sub          (host_uis),/.ui_sub          (1'"'"'b0),/' "sub_flip blind to the panel's mode (P6d)"
  wmut W118 's/(~pc_idle | host_ui | host_uis)/(~pc_idle | host_ui)/' "the panel invisible over a stop (P6d)"
  wmut W119 's/^wire  \[1:0\] hf_buf; /wire        hf_buf; /' "the flip's plane 1 bit (P6d)"
  wmut W120 "s/hx_press  = hx_v ? hx_mask : 16'd0;/hx_press  = hx_mask;/" "the press record held, not a pulse (P6d)"
  wmut W121 's/^\t\.pmsg        (th_pmsg), /\t.pmsg        (2'"'"'d0), /' "the panel button silent on the stock Main (P6d)"
  wmut W122 "s/btn_press\[14\] ? ((host_ok | host_bad) ? 2'd2 : 2'd1) : 2'd0;/btn_press[14] ? (host_ok ? 2'd2 : 2'd1) : 2'd0;/" "a mismatched UMD Main read as none (P6d)"
  wmut W123 "s/th_show_aud = btn_press\[9\] \& ~th_tag_aud;/th_show_aud = btn_press[9];/" "Audio never cycling (P6d follow-up)"
  wmut W124 "s/^wire       pc_cmd_v  = |btn_cmd\[9:4\] | btn_cmd\[12\] | |dpad_cmd;/wire       pc_cmd_v  = |btn_press[9:4] | btn_press[12] | |dpad_cmd;/" "the first press also cycling (P6d follow-up)"
  wmut W132 's/^\t\.k_ab      (btn_press\[15\]),/\t.k_ab      (1'"'"'b0),/' "A-B Repeat's press cut (keyboard B, the panel's item)"
  wmut W133 's/^assign     ab_take   = ab_req \& ~pc_cmd_v \& ~gt_cmd_v;/assign     ab_take   = ab_req;/' "A-B's SEEK taken over a button's or Go To's command"
  wmut W134 "s/^wire        hc_pc     = hc_v \& (hc_code != 4'd0);/wire        hc_pc     = hc_v;/" "the panel's CLEAR (code 0) reaching player_ctl as a BAD command"
  wmut W135 's/^wire \[1:0\] dpad_cmd  = dpad_press \& ~{2{ab_loop}};/wire [1:0] dpad_cmd  = dpad_press;/' "FF \/ REW acting while A-B loops (the PSP: nothing)"
  wmut W136 's/btn_press\[8:7\] \& ~{2{ab_loop}}, btn_press\[6:4\]}/btn_press[8:4]}/' "a chapter press reaching player_ctl while A-B loops (the PSP: a jump to A)"
  wmut W137 's/\.k_goto       ((btn_all\[13\] | hx_press\[13\]) \& ~ab_loop),/.k_goto       (btn_all[13] | hx_press[13]),/' "Go To opening while A-B loops (the PSP: nothing)"
  wmut W138 "s/pc_cmd_v ? 32'd0 : ab_take ? ab_item : hc_item/pc_cmd_v ? 32'd0 : ab_take ? 32'd0 : hc_item/" "A-B's SEEK not carrying A's item"
  wmut W139 's/^\t\.host_nav  (ab_hnav),/\t.host_nav  (1'"'"'b0),/' "a host seek (a disc menu's PLAYLIST) leaving A-B looping"
  wmut W140 's/^\t\.ab_na       (ab_na), /\t.ab_na       (1'"'"'b0), /' "A-B on a bare file saying nothing"
  wmut W141 's/^\t\.ab_up       (ab_tag_up), /\t.ab_up       (1'"'"'b0), /' "A-B's tag never held up (A set shows nothing)"
  wmut W125 "s/th_show_sub = btn_press\[12\] \& ~th_tag_sub;/th_show_sub = btn_press[12] \& ~th_tag_sub \& host_ok;/" "Subtitle's tag gated on the UMD Main again (A12 SD3: it needs none)"
  wmut W153 "s/^\t\.h_req       (1'b0),  /\t.h_req       (sh_req),  /" "the UMD Main asked to decode beside the fabric (A12 SD1: two writers of one plane)"
  wmut W154 "s/^\t\.host_ok        (1'b1),  /\t.host_ok        (host_ok),  /" "SUB gated on the UMD Main again (A12 SD3)"
  # fj#71 Zoom (docs/zoom.md)
  wmut W142 's/pixel_en \& ~zoom_cut}/pixel_en}/' "the cut lines kept in DE (Zoom shows the whole raster stretched)"
  wmut W143 "s/^assign VIDEO_ARX = (aa_live | menu_aa_on) ? 13'd4 : (ar_wide | zoom) ? 13'd16 : 13'd4;/assign VIDEO_ARX = (aa_live | menu_aa_on) ? 13'd4 : ar_wide ? 13'd16 : 13'd4;/" "Zoom's band shown at 4:3 (squashed)"
  wmut W144 '/^zoom_ctl zoom_ctl_inst (/,/);/s/\.host_menu  (host_menu),/.host_menu  (1'"'"'b0),/' "Zoom cropping a disc menu"
  wmut W145 '/^zoom_ctl zoom_ctl_inst (/,/);/s/\.il         (interlaced_eff),/.il         (1'"'"'b0),/' "Zoom at 480i"
  wmut W146 's/\.safe        (interlaced_eff | zoom),/.safe        (interlaced_eff),/' "the HUD's 480p layout under Zoom (cut at both ends)"
  wmut W147 's/\.zoom            (zoom), /.zoom            (1'"'"'b0), /' "the fabric's subtitle cut by Zoom"
  wmut W148 "s/vga_g_q  <= cut_dly\[6\] ? 8'd0 : th_rgb\[15:8\];/vga_g_q  <= th_rgb[15:8];/" "the cut lines shown on the analog pins"
  wmut W149 's/"O\[2:1\],Aspect Ratio,Auto,4:3,16:9,Zoom;",/"O[2:1],Aspect Ratio,Auto,4:3,16:9;",/' "Aspect Ratio without Zoom"
  wmut W150 '/^zoom_ctl zoom_ctl_inst (/,/);/s/\.stopped    (pc_idle),/.stopped    (1'"'"'b0),/' "Zoom cropping the disc screen at STOP"
  wmut W151 's/\.v_pos       (hud_v_pos),/.v_pos       (v_pos_l7),/' "the HUD's header cut by Zoom's band"
  wmut W152 's/\.zoom        (zoom),             \/\/ fj#71/.zoom        (1'"'"'b0),             \/\/ fj#71/' "the UMD Main placing the panel's subtitle raw under Zoom"
  wmut W126 "s/^\t\.aud_cur     (pc_aud_track),/\t.aud_cur     (4'd0),/" "the show naming no track (P6d follow-up)"
  wmut W112 's/^\t\.goto_open   (gt_open), /\t.goto_open   (1'"'"'b0), /' "Go To's editor never drawn (P6c)"
  wmut W41 '/ aud_out_inst (/,/);/s/\.tag_pop       (at_pop),/.tag_pop       (),/' "the tag pop cut"
  wmut W42 's/\.wr_valid   (vb_valid),/.wr_valid   (vid_valid),/' "the vbuf bypassed"
  wmut W43 's/\.mrst_n          (mem_lock_n),/.mrst_n          (mem_rst_n),/' "the vbuf engine reset with RESET"
  wmut W44 's/\.wr_flush   (vb_flush),/.wr_flush   (rd_done),/' "the flush straight from the reader"
  wmut W30 '/^ddr_mux2 ddr_mux2_inst/,/);/s/\.rst_n             (mem_lock_n),/.rst_n             (mem_rst_n),/' "the mux reset with RESET"
  wmut W31 's/\.mrst_n            (mem_lock_n),/.mrst_n            (mem_rst_n),/' "the reader's fetch side reset with RESET"
  wmut W32 's/^always @(posedge clk_mem or negedge mem_lock_n) begin/always @(posedge clk_mem or negedge mem_rst_n) begin/' "the abort register reset with RESET"
  tmut() {   # name file(sys_top|sdc) sed-expression what-survived-means
    local d; d=$(mktemp -d)
    cp sys/sys_top.v umd/umd.sdc "$d/"
    sed "$3" "$2" > "$d/$(basename "$2")"
    if cmp -s "$2" "$d/$(basename "$2")"; then echo "  $1: anchor missed" > "$RES/$1"; echo MUTFAIL >> "$RES/$1"
    elif python3 tools/check_emu_wiring.py umd/emu.sv "$d/sys_top.v" "$d/umd.sdc" >/dev/null 2>&1; then
      { echo "  $1: SURVIVED -- check_emu_wiring accepts $4"; echo MUTFAIL; } > "$RES/$1"
    else echo "  $1: caught by check_emu_wiring" > "$RES/$1"; fi
    rm -rf "$d"
  }
  tmut T1 sys/sys_top.v 's/\.ram2_clk(ram2_clk),/.ram2_clk(clk_audio),/' "ram2 on clk_audio"
  tmut T2 sys/sys_top.v '/^wire \[28:0\] ram2_address;$/d' "ram2 declared after its use"
  tmut T3 sys/sys_top.v 's/\.ram_addr(svc_address),/.ram_addr(ram2_address),/' "ddr_svc driving ram2"
  tmut T4 umd/umd.sdc 's/disp_reader:/disp_smoke:/g' "an exception naming a retired module"
  tmut T5 sys/sys_top.v 's/: vga_od\[9:8\];/: vga_o[9:8];/' "vga_g's low bits undithered (Analog Dither)"
  tmut T6 sys/sys_top.v 's/: vga_od\[23:18\];/: vga_o[23:18];/' "VGA_R undithered (Analog Dither)"
  tmut T7 sys/sys_top.v 's/\.din(vga_o),/.din(vga_o_t),/' "the dither before the yc_out mux (Analog Dither)"
  tmut T8 sys/sys_top.v 's/\.VGA_DITHER(vga_dither_en),/.VGA_DITHER(),/' "emu's VGA_DITHER unconnected (Analog Dither)"
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
