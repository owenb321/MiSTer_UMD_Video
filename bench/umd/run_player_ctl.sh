#!/usr/bin/env bash
# run_player_ctl.sh -- umd/player_ctl.sv, the player control block (P6b3, docs/transport.md
# S2.1-S2.5), in bench/umd/player_ctl_tb.sv's mock of emu (a reader answering the
# navigation port by its contract, a display showing a picture a refresh), on scripts from
# tools/player_ctl_ref.py; the bench checks the sequence, the model its decisions vs
# tools/umd_nav_ref.py.
#
# GREEN: synthetic titles -- nochap (no chapter: the message, no seek), multi (chapters on
# three items), dup (a duplicated mark, one on IN), short (P6b3i: ten 2 s items -- the mock
# walk runs ahead and must be held, the display crosses items by itself), dense (P6b4: a
# chapter every 3 s, so a trick-play hop always crosses one) -- and
# Akira's and Now That's What I Call Music 2006's real chapter tables (SKIP without images),
# two seeds each. Every script: bursts of Next / Prev (1-3 presses, a Prev inside 1 s of a
# landing), Go To (1 in 5 outside IN..OUT), pause / stop / play, the audio track, presses
# during a seek, a landing with no picture (the watchdog), reserved commands, Next past the
# last chapter; P6c: Go To by time (TIME, 15), and Go To's chapter queries on their port.
#
# P8: bench/umd/player_ctl_bare_tb.sv, a bare stream file (directed): every seek-making command
# posts UNAVAIL and moves nothing; Next finds no chapter; the default track follows the stream.
#
# --red: mutations on a COPY, each caught by its own arm:
#   P1  a press does not restart the merge window            -> [model]
#   P2  Prev always restarts (the 1 s rule gone)             -> [model]
#   P3  Next past the last chapter seeks anyway              -> [model]
#   P4  the flush ends before the queue is idle              -> [flush]
#   P5  the flush's minimum length ignored                   -> [flush]
#   P6  the stream released with the flush (no tail)         -> [flush]
#   P7  not frozen while the seek waits for the reader       -> [freeze]
#   P8  the audio chain's reset a cycle short                -> [audio]
#   P42 the realign in the release's own cycle (an old-track
#       byte into the new ring: S12's slide, P6b7)           -> [audio]
#   P9  AUDIO goes to the lowest track, not the next         -> [audio]
#   P10 no watchdog                                          -> [wd]
#   P11 the tracker never re-asks at a chapter's crossing    -> [model]
#   P12 a press during a seek keyed from the old picture     -> [model]
#   P13 an item's IN not the reader's (clamped) target       -> [land]
#   P14 a reserved command posts no event                    -> [event]
#   P16 a sporadic event pushed over an answer's (the arbiter
#       reading last cycle's push; BADSYNC)                  -> [model]
#   P18 no hold: the walk runs a fifth item in (P6b3i)      -> [hold]|[key]
#   P19 the tracker judges a pickup by the old item          -> [model]
#   P20 the landing's hold measured from the old picture     -> [hold]|[key]
#       (a watchdog's wait lets the walk alias the landing)
#   P21 an item start writes no table entry                   -> [land]
#   P22 the watchdog leaves the hold measuring from the held  -> [hold]|[key]
#       picture (found by ntwicm_2 / short_2)
#   P17 a press queued in the cycle its burst's head is
#       answered is lost (found by nochap_1; PRESSSYNC)      -> [model]
#   P15 STOP without the idle screen                         -> [freeze]
#   P6b4, trick play:
#   P23 Forward 2's rate 20x, not 33x                        -> [model]
#   P24 the wall time not restarted at a hop's issue         -> [model]
#   P25 a hop's landing written with a skip                  -> [land]
#   (no P26: TITLE_END's gate on a hop's stream is defensive -- the seek machine is idle on
#    a hop's stream only paused / stopped after trick play, where the display is frozen and
#    takes no END, or for the one cycle before play's restoring seek; the mutation had
#    nothing to show)
#   P27 the audio chain not held through trick play          -> [trick]
#   P28 the reader not held between hops                     -> [trick]
#   P29 hops not spaced HOP_MIN apart                        -> [trick]
#   P30 the item's edge never found (no crossing, no end)    -> [model]
#   P31 the carried target is the request, not the clamped   -> [model]
#   P32 a reverse request saturated at 0 not an edge (nochap,
#       IN at PTS 0)                                         -> [model]
#   P33 play not resumed by a seek to the shown key          -> [model]
#   P34 the opposite arrow speeds up instead of playing      -> [model]
#   P35 a chapter press in trick play keyed from the hop's
#       target, not the picture shown                        -> [model]
#   P65 PAUSE in trick play holds its picture (fj#57: the PSP's
#       X plays at normal speed, as the opposite arrow)       -> [model]
#   P6b7, telemetry:
#   P36 land_pts latched at every pickup                     -> [landpts]
#   P37 land_pts not latched after a watchdog (or the mount) -> [landpts]
#   P38 seek_lat from the seek's accepting edge (the query,
#       the merge window and the reader's wait left out)     -> [lat]
#   P39 seek_lat latched at a hop's picture too              -> [lat]
#   P40 a chapter landing ranked by its picture's PTS (the
#       rig's flicker to the previous chapter)               -> [proj]
#   P41 a hop issued in the cycle an exit is asked (EXITSYNC, directed since P9; first found by
#       ntwicm_2 once P6b7's mock changed the timing)       -> [model]
#   P62 (P8) a seek asked of a bare stream issued           -> [unavail] (the bare bench)
#   P63 (P8) the default track judged at the item start only -> [audio]   (the bare bench)
#   P64 (P8) a bare file's item written with a skip          -> [land]    (the bare bench)
#   A7, the UMD Main (docs/hps_host.md §5; the host modes: +no_host, +host_bad, +host_drop_on):
#   P49 SUB honoured without host_ok                         -> [host]
#   P50 subtitles left on when the host goes                 -> [host]
#   P51 the HOST event's host_bad dropped                    -> [host]
#   P9 (docs/p9.md §3.2): PLAYLIST (13) and SUB_SET (14); every script plays playlists (1 in 6
#   one past the last: refused; 1 in 6 an item past the last: the mock clamps as the reader),
#   one from STOP, one during trick play, and sets the subtitles outright:
#   P52 a PLAYLIST asks a NAV_SEEK, not a NAV_PLAY           -> [model]|[port]
#   P53 a playlist past the last not refused                 -> [port]
#   P54 a PLAYLIST from STOP stays stopped                   -> [model]|[wd]|[event] (a later
#       Go To, refused while stopped, posts a BAD the bench did not predict)
#   P55 the port's playlist not driven                       -> [model]
#   P56 a PLAYLIST during trick play becomes a plain exit    -> [model]
#   P57 SUB_SET turns the subtitles on whatever it asks      -> [sub]
#   P58 SUB_SET takes a track the clip does not declare      -> [sub]|[event]
#   P59 a PLAYLIST during trick play ignored                 -> [model]
#   P60 a PLAYLIST's key taken from the picture shown        -> [model]
#   P61 SUB_SET applies the next track, not the one asked    -> [sub]
#   P6c (docs/p6c.md §9): TIME (15, Go To by time) -- every script runs Go To by time at random,
#   at 0, at each item boundary and the tick before it, at the end and past it, from pause, from
#   stop (refused), with a press during its seek, during trick play -- and Go To's query port:
#   G1  a TIME asks a NAV_SEEK                               -> [model]|[port]|[land]
#       ([land] first since G8's rule: the mock clamps the past-the-end TIME, sent as a SEEK, to
#        OUT - 4, player_ctl's TIME rule lands it without the skip, the mock's SEEK says skip)
#   G2  a TIME during trick play ends it but never seeks     -> [model]
#   G3  gq_done at every query's answer                      -> [goto]
#   G4  a press during a TIME's seek keyed from the time     -> [model]
#   G5  Go To's query never freed (the next one starves)     -> [goto]
#   G6  a TIME taken while stopped                           -> [model]|[event]
#   G7  a TIME's target the picture shown                    -> [model]|[land]
#       ([land] first: no TIME then reaches past the end, so the tb's own coverage check fails
#        before the model runs -- on main too since the check came in; relabelled in fj#57)
#   G9  a disc's SUB_SET event not marked (P9 M4b: the HUD's subtitle tag at every play of The Island) -> [sub]
#   G8  a TIME past the end lands with the skip (the last GOP does not play out: a UX
#       choice since fix/skip-last-picture; p6c.md §10)    -> [land]
#   G10 player_ctl's END_GUARD not the reader's (a TIME past the end not recognised) -> [land]
#   G11 a landing whose display ENDED with no picture waits for the watchdog (fix/skip-last-picture:
#       the END inside the skip; on the rig, A Few Good Men's OUT 2 s past its content) -> [wd]|[tend]|[land]
#       ([land] first: the watchdog's no-skip rewrite of the entry, which no NOPIC asked for)
#   G12 TITLE_END on the rising edge alone: an END that came during the seek is never posted -> [tend]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/player_ctl
mkdir -p $W
fail=0; red=0
for a in "$@"; do case $a in --red) red=1;; esac; done
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}
RTL="umd/player_ctl.sv"
TB="bench/umd/player_ctl_tb.sv"

echo "== scenarios =="
SC=""
for s in nochap multi dup short dense; do
  for seed in 1 2; do
    python3 tools/player_ctl_ref.py gen --synth $s --seed $seed --out "$W/${s}_$seed" > "$W/${s}_$seed.gen" 2>&1 \
      || { echo "FAIL gen $s"; cat "$W/${s}_$seed.gen"; exit 1; }
    SC="$SC ${s}_$seed"
  done
done
for d in "Akira (PSP Video).iso|akira" "Now Thats What I Call Music 2006 The UMD (2006).ISO|ntwicm"; do
  f=${d%%|*}; n=${d##*|}
  if [ -f "$ISO/$f" ]; then
    for seed in 1 2; do
      python3 tools/player_ctl_ref.py gen --disc "$ISO/$f" --seed $seed --out "$W/${n}_$seed" > "$W/${n}_$seed.gen" 2>&1 \
        || { echo "FAIL gen $n"; cat "$W/${n}_$seed.gen"; exit 1; }
      SC="$SC ${n}_$seed"
    done
  else echo "  SKIP $n: no $f in $ISO"; fi
done
for s in $SC; do echo "  $(cat "$W/$s.gen")"; done

xarg() { echo +want_trick; case $1 in short*) echo +want_hold;; esac; }   # the ten-item title must hold the reader
build() {   # dir -> dir/sim; compiled from inside the copy
  (cd "$1" && rm -f sim && iverilog -g2012 -o sim $RTL "$ROOT/$TB" 2> build.log)
}

echo "== GREEN =="
build . || { echo "FAIL build"; cat build.log; exit 1; }
mv sim build.log $W/ 2>/dev/null
# (scenarios run one after another here: each writes its STEM.log, which the model reads)
for s in $SC; do
  vvp -n "$W/sim" +stem="$W/$s" $(xarg "$s") > "$W/$s.out" 2>&1
  python3 tools/player_ctl_ref.py check --stem "$W/$s" > "$W/$s.model" 2>&1
  if grep -q "^PASS: player_ctl_tb" "$W/$s.out" && grep -q "^PASS: player_ctl_ref" "$W/$s.model"; then
    echo "  PASS $s: $(grep -m1 '^player_ctl_tb:' "$W/$s.out" | sed 's/^player_ctl_tb: //'); $(grep -m1 '^player_ctl_ref:' "$W/$s.model" | sed 's/^player_ctl_ref: //')"
  else
    echo "  FAIL $s"; grep -hm3 "FAIL" "$W/$s.out" "$W/$s.model" | sed 's/^/    /'; fail=1
  fi
done
# A7: the host modes on titles with subtitles (the scripts' SUB presses; the model as before)
for hm in "multi_1|+no_host" "nochap_1|+no_host +host_bad" "multi_2|+host_drop_on" "nochap_2|+host_drop_on +host_bad"; do
  s=${hm%%|*}; a=${hm##*|}
  cp "$W/$s.title" "$W/h_$s.title"; cp "$W/$s.script" "$W/h_$s.script"
  # shellcheck disable=SC2086
  vvp -n "$W/sim" +stem="$W/h_$s" $(xarg "$s") $a > "$W/h_$s.out" 2>&1
  python3 tools/player_ctl_ref.py check --stem "$W/h_$s" > "$W/h_$s.model" 2>&1
  if grep -q "^PASS: player_ctl_tb" "$W/h_$s.out" && grep -q "^PASS: player_ctl_ref" "$W/h_$s.model"; then
    echo "  PASS $s $a: $(grep -m1 '^player_ctl_tb:' "$W/h_$s.out" | sed 's/^player_ctl_tb: //' | sed 's/.*at the end, //')"
  else
    echo "  FAIL $s $a"; grep -hm3 "FAIL" "$W/h_$s.out" "$W/h_$s.model" | sed 's/^/    /'; fail=1
  fi
done

# P8: a bare stream file (bench/umd/player_ctl_bare_tb.sv, directed: no script, no model)
TBB="bench/umd/player_ctl_bare_tb.sv"
build_bare() { (cd "$1" && rm -f simb && iverilog -g2012 -o simb $RTL "$ROOT/$TBB" 2> buildb.log); }
build_bare . || { echo "FAIL build (bare)"; cat buildb.log; exit 1; }
mv simb buildb.log $W/ 2>/dev/null
vvp -n "$W/simb" > "$W/bare.out" 2>&1
if grep -q "^PASS: player_ctl_bare_tb" "$W/bare.out"; then
  echo "  PASS bare: $(grep -m1 '^player_ctl_bare_tb:' "$W/bare.out" | sed 's/^player_ctl_bare_tb: //')"
else echo "  FAIL bare"; grep -m3 FAIL "$W/bare.out" | sed 's/^/    /'; fail=1; fi

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  # P8, on the bare bench: P62 a seek asked of a bare stream issued -> [unavail]; P63 the default
  # track judged only at an item start (the mask still empty then) -> [audio]
  mutb() {   # name old new arm
    local name=$1 old=$2 new=$3 arm=$4 d
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    d=$(mktemp -d); mkdir -p "$d/umd"; cp $RTL "$d/umd/"
    python3 - "$d/umd/player_ctl.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! build_bare "$d"; then echo "  $name: harness failure (anchor or build)"; fail=1; rm -rf "$d"; return; fi
    vvp -n "$d/simb" > "$d/out" 2>&1
    if grep -qE "FAIL \[($arm)\]" "$d/out"; then echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/out" | cut -c1-110)"
    elif grep -q FAIL "$d/out"; then echo "  $name: failed but NOT in [$arm]: $(grep -m1 FAIL "$d/out")"; fail=1
    else echo "  $name: SURVIVED -- the bench cannot see this defect"; fail=1; fi
    rm -rf "$d"
  }
  mutb P62 "            if (cmd_valid && titled && bare &&" "            if (cmd_valid && titled && 1'b0 &&" unavail
  mutb P63 "end else if ((rd_item_start || bare) && trk_any" "end else if (rd_item_start && trk_any" audio
  mutb P64 "ep_skip <= !one_frame && !bare && !(tm_land" "ep_skip <= !one_frame && !(tm_land" land
  mut() {   # name old new arm
    local name=$1 old=$2 new=$3 arm=$4 d s hit=""
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    d=$(mktemp -d); mkdir -p "$d/umd"; cp $RTL "$d/umd/"
    python3 - "$d/umd/player_ctl.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! build "$d"; then echo "  $name: harness failure (anchor or build)"; fail=1; rm -rf "$d"; return; fi
    for s in $SC; do
      mkdir -p "$d/w"; cp "$W/$s.title" "$W/$s.script" "$d/w/"
      # shellcheck disable=SC2086
      vvp -n "$d/sim" +stem="$d/w/$s" $(xarg "$s") ${MARGS:-} > "$d/$s.out" 2>&1
      grep -q "^PASS: player_ctl_tb" "$d/$s.out" && python3 tools/player_ctl_ref.py check --stem "$d/w/$s" > "$d/$s.out" 2>&1
      hit=$(grep -Em1 "FAIL \[($arm)\]" "$d/$s.out") && { hit="$s: $hit"; break; }
    done
    if [ -n "$hit" ]; then echo "  $name: caught by $(echo "$hit" | cut -c1-110)"
    elif grep -qh "FAIL" "$d"/*.out; then echo "  $name: failed but NOT in [$arm]: $(grep -hm1 FAIL "$d"/*.out)"; fail=1
    else echo "  $name: SURVIVED -- the bench cannot see this defect"; fail=1; fi
    rm -rf "$d"
  }
  mut P1 "                        mtmr <= '0;
                    end
                    C_SEEK:" "                    end
                    C_SEEK:" model
  mut P2 "if (near_cur && ch_rank > 16'd1 && ch_valid[1]) begin" "if (1'b0) begin" model
  mut P3 "                    if (ch_valid[2]) begin
                        pend_item <= {16'd0, ch_next[63:48]};" "                    if (1'b1) begin
                        pend_item <= {16'd0, ch_next[63:48]};" model
  mut P4 "if (fcnt == 5'd0 && icnt >= IDLE_MIN[3:0]) begin" "if (fcnt == 5'd0) begin" flush
  mut P5 "if (fcnt == 5'd0 && icnt >= IDLE_MIN[3:0]) begin" "if (icnt >= IDLE_MIN[3:0]) begin" flush
  mut P6 "seek_flush <= 1'b0; htail <= HOLD_TAIL[2:0];" "seek_flush <= 1'b0; htail <= 3'd0;" flush
  mut P7 "(have_tgt && (sk == SK_QUERY || sk == SK_MERGE)) || (sk == SK_SEEK) || (sk == SK_FLUSH);" \
         "(have_tgt && (sk == SK_QUERY || sk == SK_MERGE)) || (sk == SK_FLUSH);" freeze
  mut P8 "                if (arst == 5'd1) aud_rst_q <= 1'b0;" "                if (arst == 5'd2) aud_rst_q <= 1'b0;" audio
  mut P42 "                if (arst == 5'd2) begin
                    aud_track <= trk_new;" "                if (arst == 5'd1) begin
                    aud_track <= trk_new;" audio
  mut P9 "trk_new <= (cmd_code == C_AUDIO) ? trk_nxt : cmd_arg;" "trk_new <= (cmd_code == C_AUDIO) ? trk_low : cmd_arg;" audio
  mut P10 "end else if (wtmr >= WD_CYC[26:0] && !rd_item_start) begin" "end else if (1'b0) begin" wd
  mut P11 "if (pick && (reached || tr_pick)) begin" "if (pick && tr_pick) begin" model
  mut P12 "if (pq_n != 4'd8 && sk == SK_NONE && pq_n == 4'd0) begin" "if (pq_n != 4'd8 && pq_n == 4'd0) begin" model
  mut P13 "ep_we <= 1'b1; ep_wi <= rd_item_idx[1:0]; ep_in <= nav_skip[32:0];" "ep_we <= 1'b1; ep_wi <= rd_item_idx[1:0]; ep_in <= pend_pts[32:0];" land
  mut P14 "                    default: begin
                        pe_bad <= 1'b1;" "                    default: begin
                        pe_bad <= 1'b0;" event
  mut P15 "idle_screen <= (state == ST_STOP);" "idle_screen <= 1'b0;" freeze
  mut P16 "            if (!ev_main) begin" "            if (!ev_push) begin" model
  mut P18 "assign item_hold = hold_ok && (rd_item_idx > hold_ref) && (rd_item_idx - hold_ref >= 32'd4);" "assign item_hold = 1'b0;" "hold|key"
  mut P19 "wire [31:0] pk_item  = pt_item[sh_ep];" "wire [31:0] pk_item  = key_item;" model
  mut P20 "(sk == SK_FLUSH || sk == SK_LAND || sk == SK_PIC) ? nd_land : key_item;" "key_item;" "hold|key"
  mut P22 "sk <= one_frame ? SK_HOP : SK_NONE; have_tgt <= 1'b0; tr_pick <= 1'b1; nxt_v <= 1'b0; key_item <= nd_land;" "sk <= one_frame ? SK_HOP : SK_NONE; have_tgt <= 1'b0; tr_pick <= 1'b1; nxt_v <= 1'b0;" "hold|key"
  mut P21 "            if (rd_item_start) begin
                ep_we <= 1'b1;" "            if (rd_item_start) begin
                ep_we <= 1'b0;" land
  mut P23 "TK_R2 = 33 * TICK_N" "TK_R2 = 20 * TICK_N" model
  mut P24 "                        tk_delta <= '0; tk_wall <= '0; tk_sat <= 1'b0;" "                        tk_wall <= '0; tk_sat <= 1'b0;" model
  mut P25 "ep_skip <= !one_frame && !bare && !(tm_land" "ep_skip <= !bare && !(tm_land" land
  mut P27 "assign aud_rst = aud_rst_q | one_frame;" "assign aud_rst = aud_rst_q;" trick
  mut P28 "                    // P6b4, between hops: the reader held; an exit, or the next hop when due
                    rd_hold <= 1'b1;" "                    // P6b4, between hops: the reader held; an exit, or the next hop when due" trick
  mut P29 "end else if (tk_wall >= HOP_MIN[26:0] && !nav_req && !q_busy && !(cmd_valid && titled)) begin" "end else if (!nav_req && !q_busy) begin" trick
  mut P30 "tk_edge <= tk_rev ? (tk_sat || nav_skip > tk_req) : (nav_skip < tk_req);" "tk_edge <= 1'b0;" model
  mut P31 "tk_item <= nav_land; tk_pts <= nav_skip;" "tk_item <= nav_land; tk_pts <= tk_req;" model
  mut P32 "tk_edge <= tk_rev ? (tk_sat || nav_skip > tk_req) : (nav_skip < tk_req);" "tk_edge <= tk_rev ? (nav_skip > tk_req) : (nav_skip < tk_req);" model
  mut P33 "                        pend_item <= key_item; pend_pts <= sh48; sk <= SK_SEEK; g_press <= 1'b0;
                    end
                end
                SK_HOP: begin" "                    end
                end
                SK_HOP: begin" model
  mut P34 "if (tk_rev == (cmd_code == C_REW)) begin" "if (1'b1) begin" model
  mut P65 "C_PAUSE:     if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_PLAY; end" "C_PAUSE:     if (trk) begin tk_speed <= 2'd0; tk_exit <= EX_STOP; end" model
  mut P35 "                            ck_item <= key_item; ck_pts <= sh48;" "                            ck_item <= pend_item; ck_pts <= pend_pts;" model
  mut P36 "if (pick && (ld_arm || sk == SK_PIC)) begin land_pts" "if (pick) begin land_pts" landpts
  mut P37 "if (pick && (ld_arm || sk == SK_PIC)) begin land_pts" "if (pick && sk == SK_PIC) begin land_pts" landpts
  mut P38 "if (sk == SK_NONE || sk == SK_HOP) lat_c <= '0;" "if (sk == SK_NONE || sk == SK_HOP || sk == SK_QUERY || sk == SK_MERGE || sk == SK_SEEK) lat_c <= '0;" lat
  mut P39 "ev_pd <= n_seeks; seek_lat <= lat_c; end" "ev_pd <= n_seeks; end seek_lat <= lat_c;" lat
  mut P40 "if (tr_land && ch_rank < chapter) begin" "if (1'b0) begin" proj
  mut P41 "!nav_req && !q_busy && !(cmd_valid && titled)) begin" "!nav_req && !q_busy) begin" model
  # P7: the subtitles (docs/subtitles.md §7, S1 / S2)
  mut P43 "sb_new_on  <= sub_on ? sb_more : sb_any;" "sb_new_on  <= sb_any;" sub
  mut P44 "if (rd_sub_present[i] && (i[4:0] > sub_track)) begin" "if (rd_sub_present[i] && (i[4:0] >= sub_track)) begin" sub
  mut P45 "                if (sfl == 5'd2) begin
                    sub_on <= sb_new_on;" "                if (sfl == 5'd1) begin
                    sub_on <= sb_new_on;" sub
  mut P46 "ev_pd <= {9'd0, sb_host, sub_on, sub_track}; pe_sub <= 1'b0;" "ev_pd <= {9'd0, sb_host, sub_on, sub_track + 5'd1}; pe_sub <= 1'b0;" sub
  # P7 (the rig, 2026-09-30): the clip's masks judged every cycle, not at the item start -- the
  # reader's CLP re-read (the mock's CLP transient) turns the subtitles off / resets the audio track
  mut P47 "end else if (rd_item_start && sub_on && !rd_sub_present[sub_track]) begin" "end else if (sub_on && !start_wait && !rd_sub_present[sub_track]) begin" sub
  mut P48 "end else if ((rd_item_start || bare) && trk_any && (!trk_v || !rd_aud_present[aud_track])) begin" "end else if (!start_wait && trk_any && (!trk_v || !rd_aud_present[aud_track])) begin" audio
  # A7: the UMD Main (docs/hps_host.md §5), in the host modes
  MARGS="+no_host" mut P49 "C_SUB: if (!host_ok) begin" "C_SUB: if (1'b0) begin" host
  MARGS="+host_drop_on" mut P50 "end else if (sub_on && !host_ok) begin" "end else if (1'b0) begin" host
  MARGS="+no_host +host_bad" mut P51 "ev_pd <= {15'd0, pe_host_b};" "ev_pd <= 16'd0;" host
  # P9: PLAYLIST and SUB_SET
  mut P52 "nav_op <= pl_next ? NAV_PLAY : tm_next ? NAV_TIME : NAV_SEEK;" "nav_op <= tm_next ? NAV_TIME : NAV_SEEK;" "model|port"
  mut P53 "C_PLAYL: if (cmd_pl < rd_n_playlists && sk == SK_NONE && !trk) begin" "C_PLAYL: if (sk == SK_NONE && !trk) begin" port
  mut P54 "if (state == ST_PAUSE || pl_next) state <= ST_PLAY;" "if (state == ST_PAUSE) state <= ST_PLAY;" "model|wd|event"
  mut P55 "nav_item <= pend_item; nav_pts <= pend_pts; nav_pl <= pend_pl;" "nav_item <= pend_item; nav_pts <= pend_pts;" model
  mut P56 "                            EX_PLAYL: begin" "                            3'd0: begin" model
  mut P57 "sb_new_on <= cmd_item[5]; sb_new_trk" "sb_new_on <= 1'b1; sb_new_trk" sub
  mut P58 "(!cmd_item[5] || rd_sub_present[cmd_item[4:0]])) begin" "1'b1) begin" "sub|event"
  # P9
  mut P59 "                        tk_speed <= 2'd0; tk_exit <= EX_PLAYL; ck_item <= cmd_item; ck_pts <= cmd_pts; ck_pl <= cmd_pl;" "" "model|event"
  mut P60 "pend_item <= cmd_item; pend_pts <= cmd_pts; pend_pl <= cmd_pl; pl_next <= 1'b1;" "pend_item <= key_item; pend_pts <= sh48; pend_pl <= cmd_pl; pl_next <= 1'b1;" model
  mut P61 "sb_new_on <= cmd_item[5]; sb_new_trk <= cmd_item[5] ? cmd_item[4:0] : sub_track;" "sb_new_on <= cmd_item[5]; sb_new_trk <= cmd_item[5] ? sb_nxt : sub_track;" sub
  # P6c: TIME (15) and Go To's query port
  mut G9 "ev_pd <= {9'd0, sb_host, sub_on, sub_track};" "ev_pd <= {10'd0, sub_on, sub_track};" sub
  mut G1 "nav_op <= pl_next ? NAV_PLAY : tm_next ? NAV_TIME : NAV_SEEK;" "nav_op <= pl_next ? NAV_PLAY : NAV_SEEK;" "model|port|land"
  mut G2 "EX_TIME:  begin pend_pts <= ck_pts; tm_next <= 1'b1; have_tgt <= 1'b1; sk <= SK_SEEK; g_press <= 1'b0; end" "" model
  mut G3 "assign gq_done = nav_done && q_goto;" "assign gq_done = nav_done;" goto
  mut G4 "                if (tm_land) begin pend_item <= nav_land; pend_pts <= nav_skip; tm_land <= 1'b0; end" "" model
  mut G5 "if (nav_done) begin q_busy <= 1'b0; q_goto <= 1'b0; end" "if (nav_done) begin q_busy <= 1'b0; end" goto
  mut G6 "C_TIME: if (sk == SK_NONE && state != ST_STOP && rd_n_items != 32'd0) begin" "C_TIME: if (sk == SK_NONE && rd_n_items != 32'd0) begin" "model|event"
  mut G7 "pend_pts <= cmd_pts; tm_next <= 1'b1; have_tgt" "pend_pts <= sh48; tm_next <= 1'b1; have_tgt" "model|land"
  mut G8 "!(tm_land && rd_item_idx == rd_n_items - 32'd1 &&" "!(1'b0 && rd_item_idx == rd_n_items - 32'd1 &&" land
  mut G10 "localparam [47:0] END_GUARD = 48'd4;" "localparam [47:0] END_GUARD = 48'd1;" land
  mut G11 "                    end else if (ended && !one_frame) begin" "                    end else if (1'b0) begin" "wd|tend|land"
  mut G12 "            if (!ended) ended_q <= 1'b0;
            else if (!ended_q && sk == SK_NONE && !one_frame)" "            ended_q <= ended;
            if (ended && !ended_q && sk == SK_NONE && !one_frame)" tend
  mut P17 "                    pq <= {1'b0, pq[7:1]};
                    pq[pq_n[2:0] - 3'd1] <= pq_dir;" "                    pq <= {1'b0, pq[7:1]}; pq_n <= pq_n - 4'd1;" model
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
