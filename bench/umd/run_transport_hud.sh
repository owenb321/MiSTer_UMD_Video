#!/usr/bin/env bash
# run_transport_hud.sh -- the transport HUD (P6b5, docs/transport_hud.md S6): umd/transport_hud.sv
# pixel-exact against tools/transport_layout.py in every state (bench/umd/transport_hud_tb.sv),
# Verilator --timing (a state is ~1-2 M cycles: minutes each in Icarus).
#
# GREEN: every state of transport_layout.bench_states() -- the approved mockups (the pop-ups
# reached through the RTL's own triggers: a state edge, a speed change, a press, an event)
# and the edges no mockup shows (Prev, Next with no chapter, a two-digit track rank and a
# language outside the table with an unprintable letter, a total past 999:59:59, an elapsed
# past a two-digit hour field, a zero total, a truncated short title, Display while stopped,
# `show` low, a 66- and a 67-cell title; P6c: Go To's editor). Each frame: all 720 x 480 pixels, !==.
#
# --red [MUTS="H1 H4"]: mutations on a COPY (compiled and run from inside it: the .svh include
# and the $readmemh paths resolve against the working directory), each caught by its state:
#   H1  a glyph row of 'C' changed (the font ROM)            10_display    ('Chapter')
#   H2  the accent colour                                    10_display    (the elapsed time, the bar)
#   H3  the bar's fill rounds up, not down                   10_display
#   H4  a pop-up lasts one frame                             01_play       (it ends before the frame)
#   H5  a stray continuation byte makes no cell              19_display_badutf8
#   H6  the placeholder drawn as '?'                         15_display_utf8
#   H7  three hour digits never used                         14_display_max
#   H8  a saturated total shows no '+'                       b04_sat_total
#   H9  the box reaches 2 px past its cells, not 3           10_display
#   H10 the header wash at a quarter, not a half             10_display
#   H11 the 67th cell writes no ellipsis                     b12_title67
#   H12 elapsed without its item's base                      10_display
#   H13 the track's rank counts the track itself             07_track
#   H14 the message one column right                         09_message
#   H15 no icon while paused (Display off)                   02_pause
#   H16 `show` ignored                                       b09_hidden
#   H17 a truncated title's ellipsis never drawn             b07_trunc_short
#   H18 the chapter's leading zeros drawn                    b01_prev
#   H23 A7: the host messages swapped (stale for none)       b15_no_host
#   H24 A7: a host message's own column ignored              b16_old_host
#   H25 A11: the unplay pulse showing another message         b17_cannot_play
#   H26 A11: "cannot be played" drawn from another string     b18_cannot_play_display
#   P6c, Go To's editor (the approved mockups goto_01-06 and the edges g01-g08: three hour digits,
#   a five- and a four-digit chapter, Display + a message over the arrows, a Next pop-up and a
#   track pop-up under it, Chapter 0, trick play, a zero total):
#   H42 a disc's SUB_SET event pops the subtitle tag (P9 M4b, The Island) b19_disc_sub
#   P6d, the control panel's messages (docs/panel.md F4):
#   H43 the two panel messages swapped                        b21_panel_no_host
#   H44 "Update ... control panel." at the other's column     b22_panel_old_host
#   H45 the string ROM's address left at 8 bits (wraps past 255) b21_panel_no_host
#   P6d follow-up, the first Audio / Subtitle press shows the current track:
#   H46 a show of the audio track ignored                      b23_show_audio / [tags]
#   H47 a show of Off drawn as a track                         b24_show_sub_off
#   H48 the audio show not the current track                   b23_show_audio
#   P8, bare stream files (docs/bare_streams.md):
#   H49 UNAVAIL showing another message                        b26_unavailable
#   H50 the unavailable message's own column ignored           b27_unavailable_display
#   H51 the audio tag's level up for the subtitle tag too      [tags]   (was a second H49)
#   A-B Repeat's tag (docs/ab_repeat.md §4; the approved mockups ab_01-09 and the edges ab10-ab14: a
#   Next pop-up's icon with A set, Display + REW 3 with A set, the loop stopped, the bare file's
#   message by ab_ctl's pulse, the loop under a track pop-up):
#   H52 the tag at column 3 after trick play's 3-cell icon       ab_07_a_ff
#   H53 the B's blink ignored                                    ab_02_a_off
#   H54 the loop's tag drawn without an icon                     ab_04_loop
#   H55 A set not holding the icon up                            ab_01_a_on
#   H56 A-B's bare-file pulse showing another message            ab13_unavailable
#   H27 the focused box's tint                                goto_01_open
#   H28 the edited field's tint                               goto_02_chapter
#   H29 a field's padding not over the cell after it          goto_04_minutes
#   H30 the marker's lines narrower                           goto_01_open
#   H31 the marker at the bar's fill, not its own quotient    goto_01_open
#   H32 a hidden marker drawn                                 g01_hours3
#   H33 one-cell arrows over a two-digit field                goto_04_minutes
#   H34 the target time in the accent                         goto_01_open
#   H35 a chapter caption drawn under the editor              g06_next_popup
#   H36 the up-arrow over the message                         g05_display_msg
#   H37 the chapter box hidden at Chapter 0                   g07_chap0_track
#   H38 three hour digits edited as two                       g01_hours3
#   H39 the time row shows elapsed, not the target            goto_04_minutes
#   H40 the marker's rows at 480p's bar on the 480i layout    il:goto_01_open
#   H41 a marker that is the total's (q = 512) skipped        g02_min3
#   480i, the title-safe layout (il:NAME = scored on the 480i set; docs/analog.md S8):
#   L1  the grid not narrowed (69 columns at 480i)            il:10_display
#   L2  the grid not inset (x0 12)                            il:04_ff3
#   L3  the icon slot not moved up                            il:01_play
#   L4  the message strip unbounded below (P6b5's band)       09_message
#   L5  the bar not moved in                                  il:10_display
#   L6  the title's room fixed at 66 cells                    il:b12_title67
#   L7  a message's 480i column ignored                       il:09_message
#   L8  the header wash not deepened                          il:10_display
#   fj#71 Zoom (docs/zoom.md): the title-safe layout on the 480p raster (+safe; safe:NAME = scored on
#   the 480i set's frames, run with +safe):
#   Z1  the grid's inset keyed on il, not safe                safe:04_ff3
#   Z2  the icon slot keyed on il, not safe                   safe:01_play
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/transport_hud
mkdir -p $W
fail=0
red=0; jobs=6
for a in "$@"; do case $a in --red) red=1;; esac; done
command -v verilator >/dev/null || { echo "run_transport_hud: SKIP -- no verilator"; exit 2; }
RTL="umd/transport_hud.sv"
DATA="umd/transport_hud.svh umd/transport_font.mem umd/transport_str.mem"
TB="bench/umd/transport_hud_tb.sv"
build() {   # src-root obj-dir -> 0 on success
  local src=$1 obj=$2 files=""
  for f in $RTL; do files="$files $src/$f"; done
  for f in $TB; do files="$files $ROOT/$f"; done
  rm -f "$obj/Vtransport_hud_tb"
  # shellcheck disable=SC2086
  (cd "$src" && verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -j 8 --top-module transport_hud_tb \
      -I"$src" --Mdir "$obj" $files) > "$obj.log" 2>&1
}
# the generated files must be the model's (a stale .svh / .mem is a harness failure, not a pass)
python3 tools/transport_font.py > /dev/null && python3 tools/transport_layout.py --gen > /dev/null || { echo "FAIL: generate"; exit 1; }
if ! git diff --quiet -- $DATA 2>/dev/null; then echo "  (note: $DATA differ from the commit)"; fi
python3 tools/transport_layout.py --bench "$ROOT/$W/states" > "$W/gen.log" 2>&1 || { echo "FAIL: model"; cat "$W/gen.log"; exit 1; }
# the 480i (title-safe) layout: the same states, the inset geometry (docs/analog.md S8)
python3 tools/transport_layout.py --bench "$ROOT/$W/states_il" --il > "$W/gen_il.log" 2>&1 || { echo "FAIL: model --il"; cat "$W/gen_il.log"; exit 1; }
# fj#71 Zoom: the same title-safe set drawn on the 480p raster (+safe) is scored on those frames
echo "== build =="
build "$ROOT" "$ROOT/$W/obj" || { echo "FAIL: build"; tail -20 "$W/obj.log"; exit 1; }
echo "  built $W/obj/Vtransport_hud_tb"
echo "== GREEN: $(wc -l < $W/states/states.txt) states =="
( timeout 3600 "$W/obj/Vtransport_hud_tb" +dir="$ROOT/$W/states" > "$W/green.log" 2>&1 ) &
( timeout 3600 "$W/obj/Vtransport_hud_tb" +dir="$ROOT/$W/states_il" +il > "$W/green_il.log" 2>&1 ) &
( timeout 3600 "$W/obj/Vtransport_hud_tb" +dir="$ROOT/$W/states_il" +safe > "$W/green_safe.log" 2>&1 ) &
wait
NST=$(wc -l < $W/states/states.txt)
for g in green green_il green_safe; do
  # every state the model wrote must have been run (the bench once stopped at 64 without a word)
  if grep -q "^PASS: transport_hud_tb" "$W/$g.log" && grep -q "^transport_hud_tb: $NST states" "$W/$g.log"; then
    echo "  PASS ($g): $(grep -m1 '^transport_hud_tb:' "$W/$g.log" | sed 's/^transport_hud_tb: //')"
  else
    echo "  FAIL ($g)"; grep "FAIL\|rror" "$W/$g.log" | head -20 | sed 's/^/    /'; fail=1
  fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own state) =="
  RES=$(mktemp -d)
  mut() {   # name file old new state
    local name=$1 file=$2 old=$3 new=$4 st=$5 d
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    d=$(mktemp -d)
    for f in $RTL $DATA; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
if old.startswith("@LINE:"):                   # replace line N (1-based) of a data file
    lines = s.split("\n")
    n = int(old[6:]) - 1
    assert lines[n] != new, "the mutation changes nothing"
    lines[n] = new
    s = "\n".join(lines)
else:
    assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
    s = s.replace(old, new)
open(path, "w").write(s)
PYEOF
    if [ $? != 0 ] || ! flock "$ROOT/$W/build.lock" bash -c "$(declare -f build); ROOT='$ROOT' RTL='$RTL' TB='$TB' build '$d' '$d/obj'"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # a state named il:NAME is scored on the 480i (title-safe) set
    local sd=states pa=""
    case $st in il:*) st=${st#il:}; sd=states_il; pa=+il;; safe:*) st=${st#safe:}; sd=states_il; pa=+safe;; esac
    (cd "$d" && timeout 3600 "$d/obj/Vtransport_hud_tb" +dir="$ROOT/$W/$sd" $pa > "$d/log" 2>&1)
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($st)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($st)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$st]:"; grep -m2 "FAIL\|rror" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  # H1: row 10 of 'C' (glyph 35): word 35 * 24 + 10, on line + 2 (after the header comment)
  mut H1 umd/transport_font.mem "@LINE:$((35 * 24 + 10 + 2))" "00000" 10_display &
  mut H2 umd/transport_hud.svh "localparam [23:0] INK1    = 24'h409CFF;" "localparam [23:0] INK1    = 24'h409CFE;" 10_display &
  mut H3 umd/transport_hud.sv "(({9'd0, (job == 3'd5) ? qb : q} * 19'd438) >> 9)" "(({9'd0, (job == 3'd5) ? qb : q} * 19'd438 + 19'd511) >> 9)" 10_display &
  mut H4 umd/transport_hud.sv "kind <= tkind; mid <= tmid; pfr <= POPUP_FRAMES[7:0];" "kind <= tkind; mid <= tmid; pfr <= 8'd1;" 01_play &
  mut H5 umd/transport_hud.sv "    b_cont = (title_q[7:6] == 2'b10) && (need != 2'd0);" "    b_cont = (title_q[7:6] == 2'b10);" 19_display_badutf8 &
  mut H6 umd/transport_hud.sv "title_q[6:0] - 7'd32 : G_TOFU;" "title_q[6:0] - 7'd32 : 7'd31;" 15_display_utf8 &
  wait
  mut H7 umd/transport_hud.sv "hdig3 <= (s_tot >= T100H);" "hdig3 <= 1'b0;" 14_display_max &
  mut H8 umd/transport_hud.sv "sat_t <= (s_tot >= T1000H);" "sat_t <= 1'b0;" b04_sat_total &
  mut H9 umd/transport_hud.svh "localparam BOX_PAD      = 4'd3;" "localparam BOX_PAD      = 4'd2;" 10_display &
  mut H10 umd/transport_hud.svh "localparam HDR_SHIFT    = 1;" "localparam HDR_SHIFT    = 2;" 10_display &
  mut H11 umd/transport_hud.sv "else if (tcnt == troom) begin pw_v <= 1'b1;" "else if (1'b0) begin pw_v <= 1'b1;" b12_title67 &
  mut H12 umd/transport_hud.sv "wire [39:0] el_sum = {1'b0, it_q[38:0]} +" "wire [39:0] el_sum = 40'd0 +" 10_display &
  wait
  mut H13 umd/transport_hud.sv "if (ri < trk && rk_mask[ri])" "if (ri <= trk && rk_mask[ri])" 07_track &
  mut H14 umd/transport_hud.svh "localparam MSG_COL0     = 7'd19;" "localparam MSG_COL0     = 7'd20;" 09_message &
  mut H15 umd/transport_hud.sv "s_trick || s_state == ST_PAUSE ||" "s_trick ||" 02_pause &
  mut H16 umd/transport_hud.sv "wire        on  = show && de_in;" "wire        on  = de_in;" b09_hidden &
  mut H17 umd/transport_hud.sv "pw_v <= 1'b1; pw_col <= 7'd4 + tcnt; pw_g <= G_ELLIPSIS;" "pw_v <= 1'b1; pw_col <= 7'd4 + tcnt; pw_g <= G_SPACE;" b07_trunc_short &
  mut H18 umd/transport_hud.sv "ch_nd <= (dg_c[0] != 4'd0) ? 3'd5 :" "ch_nd <= (1'b1) ? 3'd5 :" b01_prev &
  wait
  # P7: the subtitle tag (docs/subtitles.md §7)
  mut H19 umd/transport_hud.sv "c_g = G_BALLOON + {6'd0, ck[0]};" "c_g = G_BALLOON;" p7_01_sub_on &
  mut H20 umd/transport_hud.sv "6'd16 + {1'b0, trk}" "6'd0 + {1'b0, trk}" p7_05_sub_ja &   # (p7_01's audio entry is "en" too)
  mut H21 umd/transport_hud.sv "5'd3: c_g = 7'd47;" "5'd3: c_g = 7'd48;" p7_03_sub_off &
  mut H22 umd/transport_hud.sv "for (ri = 0; ri < 32; ri = ri + 1)" "for (ri = 0; ri < 16; ri = ri + 1)" b13_sub_rank32 &
  wait
  # A7: the Subtitle button without the UMD Main (docs/hps_host.md §5)
  mut H23 umd/transport_hud.sv "tmid = ev_data[0] ? 3'd2 : 3'd1;" "tmid = ev_data[0] ? 3'd1 : 3'd2;" b15_no_host &
  mut H24 umd/transport_hud.sv "3'd2:    begin m_str = STR_MSG2; m_col = msg_col2;" "3'd2:    begin m_str = STR_MSG2; m_col = msg_col1;" b16_old_host &
  # A11: the core stopped on the disc (the unplay pulse)
  mut H25 umd/transport_hud.sv "if (unplay) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd3; end" "if (unplay) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd0; end" b17_cannot_play &
  mut H26 umd/transport_hud.sv "3'd3:    begin m_str = STR_MSG3;" "3'd3:    begin m_str = STR_MSG2;" b18_cannot_play_display &
  # P6d: the control panel's messages (docs/panel.md F4)
  mut H43 umd/transport_hud.sv "tmid = (pmsg == 2'd1) ? 3'd4 : 3'd5;" "tmid = (pmsg == 2'd1) ? 3'd5 : 3'd4;" b21_panel_no_host &
  mut H44 umd/transport_hud.sv "3'd5:    begin m_str = STR_MSG5; m_col = msg_col5;" "3'd5:    begin m_str = STR_MSG5; m_col = msg_col4;" b22_panel_old_host &
  mut H45 umd/transport_hud.sv "reg  [8:0]  c_a;" "reg  [7:0]  c_a;" b21_panel_no_host &
  # P6d follow-up: Audio / Subtitle show the current track first
  mut H46 umd/transport_hud.sv "if (show_aud || show_sub) begin trig = 1'b1;" "if (show_sub) begin trig = 1'b1;" "b23_show_audio|tags" &
  mut H47 umd/transport_hud.sv "toff <= !sub_on_cur;" "toff <= 1'b0;" b24_show_sub_off &
  mut H48 umd/transport_hud.sv "if (show_aud) begin trk <= {1'b0, aud_cur};" "if (show_aud) begin trk <= 5'd0;" b23_show_audio &
  mut H49 umd/transport_hud.sv "EV_UNAVAIL) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd6; end" "EV_UNAVAIL) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd0; end" b26_unavailable &
  mut H50 umd/transport_hud.sv "3'd6:    begin m_str = STR_MSG6; m_col = msg_col6;" "3'd6:    begin m_str = STR_MSG6; m_col = msg_col5;" b27_unavailable_display &
  mut H51 umd/transport_hud.sv "assign tag_aud  = (kind == K_TRACK) && !tsub;" "assign tag_aud  = (kind == K_TRACK);" tags &
  wait
  # A-B Repeat's tag (docs/ab_repeat.md §4)
  mut H52 umd/transport_hud.sv "(!i_nx && s_trick) ? 7'd4 : 7'd3;" "(!i_nx && s_trick) ? 7'd3 : 7'd3;" ab_07_a_ff &
  mut H53 umd/transport_hud.sv "s_abb ? 7'd34 : G_SPACE;" "7'd34;" ab_02_a_off &
  mut H54 umd/transport_hud.sv "wire        ab_vis = s_abu || (s_abl && i_on);" "wire        ab_vis = s_abu || s_abl;" ab_04_loop &
  mut H55 umd/transport_hud.sv "(s_kind != K_NONE && s_kind != K_MSG) || s_abu;" "(s_kind != K_NONE && s_kind != K_MSG);" ab_01_a_on &
  mut H56 umd/transport_hud.sv "if (ab_na) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd6; end" "if (ab_na) begin trig = 1'b1; tkind = K_MSG; tmid = 3'd0; end" ab13_unavailable &
  wait
  # P6c: Go To's editor (docs/p6c.md §9)
  mut H42 umd/transport_hud.sv "if (ev_valid && ev_code == EV_SUB && !ev_data[6]) begin trig = 1'b1;" "if (ev_valid && ev_code == EV_SUB) begin trig = 1'b1;" b19_disc_sub &
  mut H27 umd/transport_hud.svh "localparam [23:0] SEL_K   = 24'h344470;" "localparam [23:0] SEL_K   = 24'h344471;" goto_01_open &
  mut H28 umd/transport_hud.svh "localparam [23:0] EDIT_K  = 24'h70707C;" "localparam [23:0] EDIT_K  = 24'h70707D;" goto_02_chapter &
  mut H29 umd/transport_hud.sv "wire [1:0]  k_first = (kl > km) ? kl : km;" "wire [1:0]  k_first = km;" goto_04_minutes &
  mut H30 umd/transport_hud.sv "wire [3:0]  mk_hw = (MARK_H[3:0] - 4'd1 - mk_r[3:0]) >> 1;" "wire [3:0]  mk_hw = (MARK_H[3:0] - 4'd1 - mk_r[3:0]) >> 2;" goto_01_open &
  mut H31 umd/transport_hud.sv "wire [10:0] mk_x  = bar_x0 + {2'd0, l_mfill};" "wire [10:0] mk_x  = bar_x0 + {2'd0, l_fill};" goto_01_open &
  mut H32 umd/transport_hud.sv "l_mark <= s_go && s_mv;" "l_mark <= s_go;" g01_hours3 &
  wait
  mut H33 umd/transport_hud.sv "    aw2 = !fn[0];" "    aw2 = 1'b0;" goto_04_minutes &
  mut H34 umd/transport_hud.sv "c_c = (tk < le && !s_go) ? C_ACCENT : C_WHITE;" "c_c = (tk < le) ? C_ACCENT : C_WHITE;" goto_01_open &
  mut H35 umd/transport_hud.sv "cap_len <= (s_chap != 16'd0 && !s_go) ?" "cap_len <= (s_chap != 16'd0) ?" g06_next_popup &
  mut H36 umd/transport_hud.sv "if (s_kind == K_MSG && mc >= m_col && mc < m_col + m_len) begin" "if (s_kind == K_MSG && mc >= m_col && mc < m_col + m_len && !a_hit) begin" g05_display_msg &
  mut H37 umd/transport_hud.sv "chap_on <= s_go ? s_nch :" "chap_on <= s_go ? (s_nch && s_chap != 16'd0) :" g07_chap0_track &
  mut H38 umd/transport_hud.sv "3'd2:    begin fc <= tcol; fn <= hdig3 ? 3'd3 : 3'd2; end" "3'd2:    begin fc <= tcol; fn <= 3'd2; end" g01_hours3 &
  wait
  mut H39 umd/transport_hud.sv "wire [38:0] s_tv  = s_go ? s_gt : s_el;" "wire [38:0] s_tv  = s_el;" goto_04_minutes &
  mut H40 umd/transport_hud.sv "wire [9:0]  mk_y0 = bar_y0 - 10'd2 - MARK_H;" "wire [9:0]  mk_y0 = BAR_Y0 - 10'd2 - MARK_H;" il:goto_01_open &
  mut H41 umd/transport_hud.sv "if (s_go && s_mv) begin qb <= 10'd512; job <= 3'd5;" "if (1'b0) begin qb <= 10'd512; job <= 3'd5;" g02_min3 &
  wait
  # the 480i (title-safe) layout and the message strip (docs/analog.md S8)
  mut L1 umd/transport_hud.sv "wire [6:0]  cols    = safe ? COLS_I : COLS;" "wire [6:0]  cols    = COLS;" il:10_display &
  mut L2 umd/transport_hud.sv "wire [10:0] x0      = safe ? X0_I : X0;" "wire [10:0] x0      = X0;" il:04_ff3 &
  mut L3 umd/transport_hud.sv "sy3 = safe ? SLOT_Y3_I : SLOT_Y3;" "sy3 = SLOT_Y3;" il:01_play &
  mut L4 umd/transport_hud.sv " && v_pos[9:0] < band_y1;" ";" 09_message &
  wait
  mut L5 umd/transport_hud.sv "wire [10:0] bar_x0  = safe ? BAR_X0_I : BAR_X0," "wire [10:0] bar_x0  = BAR_X0," il:10_display &
  mut L6 umd/transport_hud.sv "wire [6:0]  troom   = cols - 7'd3;" "wire [6:0]  troom   = 7'd66;" il:b12_title67 &
  mut L7 umd/transport_hud.sv "msg_col0 = safe ? MSG_COL0_I : MSG_COL0," "msg_col0 = MSG_COL0," il:09_message &
  mut L8 umd/transport_hud.sv "wire [9:0]  hdr_y1  = safe ? HDR_Y1_I : HDR_Y1;" "wire [9:0]  hdr_y1  = HDR_Y1;" il:10_display &
  wait
  # fj#71 Zoom: the layout keyed on safe, not il (docs/zoom.md)
  mut Z1 umd/transport_hud.sv "wire [10:0] x0      = safe ? X0_I : X0;" "wire [10:0] x0      = il ? X0_I : X0;" safe:04_ff3 &
  mut Z2 umd/transport_hud.sv "sy3 = safe ? SLOT_Y3_I : SLOT_Y3;" "sy3 = il ? SLOT_Y3_I : SLOT_Y3;" safe:01_play &
  wait
  cat "$RES"/* 2>/dev/null
  grep -q MUTFAIL "$RES"/* 2>/dev/null && fail=1
  rm -rf "$RES"
fi

if [ $fail = 0 ]; then echo "== ALL GREEN =="; else echo "== FAILURES =="; exit 1; fi
