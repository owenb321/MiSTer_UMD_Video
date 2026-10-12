#!/usr/bin/env bash
# run_disp_sched.sh -- the display path from the output queue to the reader (roadmap P5e,
# docs/display.md S7): recon_out -> disp_ctl + disp_sched -> disp_reader over ddr_model,
# three real clocks and the real raster (bench/umd/disp_sched_tb.sv), Verilator --timing
# (a 300-refresh scenario is ~135 M clk_sys cycles: hours in Icarus, ~7 min here), scored
# refresh by refresh against tools/disp_sched_ref.py.
#
# GREEN, one per scenario (tools/disp_sched_ref.py --list):
#   film32 (C1 3:2 film)   prog24 (C2 23.976 progressive: 2.5 refreshes a frame)
#   prog24r (the same, time stamps rounded up: every other frame taken ~750 ticks after
#     its PTS -- not late)
#   tff / bff (C3 field pairs)   ps78 (C4 pic_struct 7 / 8)   unpaired (C5 single fields)
#   geom (C6 sizes, no VUI timing: the default and its flag)   late ([5] a late decoder)
#   back ([7a] a backward PTS jump)   back200 ([7d] 200 ms back: only the backward leg)   backfld ([7e] the same on single fields)   gap03 ([7b] 0.3 s waited out)   gap2s ([7c] re-anchors)
#   held ([8] LATE_MAX after a 4 s still)   starve400 ([8b] a 400 ms starvation is NOT a
#   re-anchor -- MiSTer_DVD's HW round B defect)
#   lone PTS (fix/film-timing, docs/display.md S10; the discs' shape, 206 of 208 in the census):
#   lone7 ([L1] 3:2 film, lone tags +7 / +8 / +1 tick, a +600-tick one believed between)
#   lonefld ([L2] the same on field pairs, +5)   lone2 ([L3] a real +7-tick gap: its first tag
#     disbelieved, the next believed -- waited out one tag later)
#   loneearly ([L4] rule B, fix/lone-early: 23.976, a lone tag a frame early -- The Transporter)
#   loneearlyfld ([L5] rule B: pairs, 3 ticks early -- The Simpsons Movie)
#   back1s ([7f] 1 s back: past the band, re-anchors at once)
#   fj#80 field matching (docs/telecine.md S5; [film] at every refresh: the lock's choice and its
#   partner store against the model's FilmLock fed by the comb sums this reader fetched):
#   telecine / telecinebff ([F1] 3:2 film on 176x96 field pairs: the lock forms and matches every
#     split pair, the previous store held, the queue's head read -- [hold] sees every partner burst)
#   telecineseek ([F2] a seek while locked: the hold dropped and the drained NEXT partner released
#     at the resync refresh's pickup, not before; another item locks afresh)
#   every other scenario is black (unwritten stores) and never locks: [film] 0 at every refresh
#   C7 (release after the last fetch) and C8 (the last picture held) are every scenario's
#   [hold] arm and END record.
#   the transport (P6b3, docs/transport.md S2.1-S2.3):
#   pause ([P1] 1 s frozen mid-film: the STC and the cadence resume)   pausefld ([P2] frozen
#     on field pairs: the parity holds)   seek ([S1] a resync drains the queued records, the
#     display waits for the target, 17 records skipped, the 18th -- untagged -- anchors at
#     its extrapolated time)   seekfrz (the same, frozen through the target)   seeknoskip
#     (a target without a skip)   mountin ([S2] IN at the mount: 9 skipped, one tick of
#     tolerance at a stored PTS)   stopout ([S3] OUT: the display ends before it)
#   seekend ([S5] fix/skip-last-picture, docs/display.md S11: a seek clamped to the title's end
#     on Akira's last GOP -- PES PTS on pictures 0 and 14 of 28 -- at the reader's OUT - 4: the
#     last picture shown, the END taken)   seekend1 (the same at P6b4's OUT - 1: every picture
#     skipped, the END inside the skip ends the display, the old picture kept)
#   items ([S4] P6b3i: two playlist items -- A cut at its OUT, B opened at its IN, B's OUT
#     ends the title; every record carries its item tag)
#   trick ([T1] P6b4: four trick-play hops -- each a resync, an entry without a skip, ONE
#     picture and the END word: shown at the first pickup after it arrives, held, the END
#     taken; then play resumed by a seek to the last hop's picture. No untimed mode: the
#     resync's anchor shows each hop's picture on arrival)
# --red [MUTS="D1 D4" to run only those]: mutations on a COPY, each caught by its own arm
# (--red-only: the mutations without the GREEN scenarios -- they take ~1.5 h on eight cores):
#   D1  due at STC >= PTS (the half-refresh rounding lost)       film32   -> [refresh]
#   D2  lateness re-anchors (LATE_MAX -> half a refresh)         starve400 -> [count]
#   D3  the backward-jump leg removed                            back200  -> [refresh]|[count]
#       (on `back`, 5 s back, the LATE_MAX leg re-anchors too: it cannot tell them apart)
#   D4  the forward-gap leg widened to 100 s                     gap2s    -> [refresh]|[count]
#   D5  pic_struct 5 / 6 last 2 ticks (Table E-6)                film32   -> [refresh]
#   D6  pic_struct 8 lasts 4 ticks                               ps78     -> [refresh]
#   D7  the VUI tick division starts from 0                      prog24   -> [refresh]
#   D8  a pair's parity sequence inverted                        tff      -> [refresh]
#   D9  the pickup releases the NEW store                        film32   -> [hold]|[queue]
#   D10 the reader's fetched-change counter dead                 film32   -> [judder]
#   D11 the END record never taken                               film32   -> [count]
#   D12 the cadence window one refresh short                     film32   -> [count]
#   D13 late judged across a re-anchor (the old timeline's STC)  backfld  -> [count]
#   D14 a single field not flagged single (P5f: woven, not bobbed) unpaired -> [refresh]
#       (only single fields take a picture at the refresh right after an anchor)
#   D15 the STC counts through a pause                           pause    -> [refresh]|[count]
#   D16 a frozen refresh still evaluates (a false "late")        pause    -> [refresh]|[count]
#   D17 a frozen refresh still steps the parity                  pausefld -> [refresh]|[count]|[judder]
#   D18 no drain: the old queue shown / its stores kept held     seek     -> [refresh]|[xport]|[hold]|[queue]
#   D19 the scheduler not cleared by the resync                  seek     -> [refresh]|[count]|[xport]
#   D20 the resync leaves the item table valid (no wait)         seek     -> [refresh]|[xport]|[count]
#   D21 the skip without its one tick of tolerance               mountin  -> [refresh]|[xport]|[count]
#   D22 the skip's time loses the eighth-tick fraction           seek     -> [xport]
#   D23 the first shown record not given its time (anchors at 0) seek     -> [refresh]|[xport]|[count]
#   D24 the stop at OUT never applied                            stopout  -> [refresh]|[xport]|[count]
#   D25 an item change never entered (B's IN not applied)       items    -> [refresh]|[xport]|[count]
#   D26 a middle item's OUT ends the display                     items    -> [refresh]|[xport]|[count]
#   D27 the item left behind never marked (its audio would wait)  items    -> [xport]
#   D28 the stall never raised (the audio's breaker blind)        held     -> [xport]
#   D29 an entry's no-skip ignored (P6b4: a hop's I dropped)      trick    -> [refresh]|[xport]|[count]
#   D30 no lone PTS rule (every tag believed: the film gate's defect) lone7  -> [refresh]|[count]
#   D31 the tag after a disbelieved one disbelieved too            lone2    -> [refresh]|[count]
#   D32 the flag never cleared by a believed tag (84 believed)     lone7    -> [refresh]|[count]
#   D33 the band's lower edge at a frame (+1 tick believed)        lone7    -> [refresh]|[count]
#   D34 the band's upper edge removed (a 2 s gap disbelieved)      gap2s    -> [refresh]|[count]
#   D35 a disbelieved tag still shown at its own PTS               lone7    -> [refresh]
#   D36 the lone counter dead (telemetry blind)                    lone7    -> [count]
#   D37 rule B's behind leg removed (an early lone tag believed)   loneearlyfld -> [refresh]|[count]
#   D38 the behind band unbounded (a 1 s backward jump disbelieved) back1s  -> [refresh]|[count]
#   (the flag's clear by a resync is not armed: no scenario has a lone tag before a seek)
#   480i (docs/analog.md; every scenario also runs as NAME.il: +il, the model's --il):
#   latefld ([5b] a late decoder on field pairs: a late pair is taken at once)
#   D39 no field-order deferral (V6)                              tff.il    -> [refresh]|[count]
#   D40 a LATE pair deferred too (the backlog never drains)       latefld.il -> [refresh]|[count]
#   D41 the freeze sampled at every 480i eval (odd pauses)        pausefld.il -> [refresh]|[count]
#   D42 the field line read as the frame line (the fork's I1)     film32.il -> [refresh]|[count]|[harness]
#   D43 the END inside a skip not taken (the rig's freeze)        seekend1 -> [xport]
#   fj#80 field matching:
#   H1  the outgoing store never held (released at every pickup)   telecine -> [hold]|[film]
#   H2  the held store never released (a store leaks)              telecine -> [queue]|[hold]
#   H3  the drain releases the NEXT partner at once                telecineseek -> [hold]
#   H4  the resync releases the held store at once                 telecineseek -> [hold]|[queue]
#   H5  the coming refresh's field order inverted (first / second) telecine -> [film]
#   H6  the partner always the held store (never the head)         telecine -> [film]|[hold]
#   H7  the reader's sums never reach the lock (mv tied 0)          telecine -> [film]
#   (480i never matches by four gates -- the lock's clr, its step, np's !il, the reader's own
#    request path: run_disp_reader.sh M3; one alone removed changes nothing, so none is armed here;
#    telecine.il checks the whole: [film] 0 at every 480i refresh)
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
W=.sim/disp_sched
mkdir -p $W
fail=0
red=0; jobs=8; green=1
for a in "$@"; do case $a in --red) red=1;; --red-only) red=1; green=0;; esac; done
command -v verilator >/dev/null || { echo "run_disp_sched: SKIP -- no verilator"; exit 2; }
RTL="umd/fifo_dc.sv umd/recon_out.sv umd/disp_sched.sv umd/film_lock.sv umd/disp_ctl.sv umd/disp_reader.sv umd/sync_gen.sv"
TB="bench/umd/ddr_model.sv bench/umd/disp_sched_tb.sv"
build() {   # src-root obj-dir -> 0 on success
  local src=$1 obj=$2 files=""
  for f in $RTL; do files="$files $src/$f"; done
  for f in $TB; do files="$files $ROOT/$f"; done
  # shellcheck disable=SC2086
  (cd "$src" && verilator --binary --timing -Wno-fatal -Wno-lint -Wno-style -j 8 --top-module disp_sched_tb \
      -I"$src" --Mdir "$obj" $files) > "$obj.log" 2>&1
}
SC0=$(python3 tools/disp_sched_ref.py --list)
SC=""
for s in $SC0; do
  python3 tools/disp_sched_ref.py --scenario "$s" --out "$W/$s" > "$W/$s.ref.log" 2>&1 || { echo "FAIL: model $s"; cat "$W/$s.ref.log"; exit 1; }
  python3 tools/disp_sched_ref.py --scenario "$s" --out "$W/$s.il" --il > "$W/$s.il.ref.log" 2>&1 || { echo "FAIL: model $s --il"; cat "$W/$s.il.ref.log"; exit 1; }
  SC="$SC $s $s.il"
done
# a stem NAME.il runs the 480i raster
ilarg() { case $1 in *.il) echo "+il";; esac; }
echo "== build =="
build "$ROOT" "$ROOT/$W/obj" || { echo "FAIL: build"; tail -20 "$W/obj.log"; exit 1; }
echo "  built $W/obj/Vdisp_sched_tb"
[ $green = 1 ] && echo "== GREEN: $(echo $SC | wc -w) scenarios =="
[ $green = 1 ] && for s in $SC; do
  (timeout 3600 "$W/obj/Vdisp_sched_tb" +stem="$W/$s" $(ilarg "$s") > "$W/$s.log" 2>&1) &
  while [ "$(jobs -rp | wc -l)" -ge "$jobs" ]; do wait -n; done
done
wait
[ $green = 1 ] && for s in $SC; do
  if grep -q "^PASS: disp_sched_tb" "$W/$s.log"; then
    echo "  PASS $s: $(grep -m1 '^disp_sched_tb:' "$W/$s.log" | sed 's/^disp_sched_tb: //')"
  else echo "  FAIL $s"; grep -m3 "FAIL\|Error" "$W/$s.log" | sed 's/^/    /'; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new scenario arm
    local name=$1 file=$2 old=$3 new=$4 sc=$5 arm=$6 d
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    d=$(mktemp -d)
    # (the include travels with the copy: a mutant compiles from inside its tree -- the fork's
    #  trees lacked field_polarity.vh)
    for f in $RTL umd/field_polarity.vh; do mkdir -p "$d/$(dirname "$f")"; cp "$f" "$d/$f"; done
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! flock "$ROOT/$W/build.lock" bash -c "$(declare -f build); ROOT='$ROOT' RTL='$RTL' TB='$TB' build '$d' '$d/obj'"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    timeout 3600 "$d/obj/Vdisp_sched_tb" +stem="$ROOT/$W/$sc" $(ilarg "$sc") > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 "FAIL\|rror" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut D1 umd/disp_sched.sv "(an || (d_stc_want >= -HALF_SCAN))" "(an || (d_stc_want >= 34'sd0))" film32 refresh &
  mut D2 umd/disp_sched.sv "(d_stc_pic > LATE_MAX_TICKS));" "(d_stc_pic > HALF_SCAN));" starve400 count &
  mut D3 umd/disp_sched.sv "((d_pic_next < -\$signed({11'd0, head_frame_t})) ||" "((1'b0) ||" back200 "refresh|count" &
  mut D4 umd/disp_sched.sv "(d_pic_next > FWD_MAX_TICKS) ||" "(d_pic_next > 34'sd9000000) ||" gap2s "refresh|count" &
  mut D5 umd/disp_ctl.sv "4'd5, 4'd6:       nt = 3'd3;" "4'd5, 4'd6:       nt = 3'd2;" film32 refresh &
  mut D6 umd/disp_ctl.sv "4'd8:             nt = 3'd6;" "4'd8:             nt = 3'd4;" ps78 refresh &
  wait
  mut D7 umd/disp_ctl.sv "rem <= {5'd0, num[51:24]};" "rem <= '0;" prog24 refresh &
  mut D8 umd/disp_ctl.sv "sh_parity <= cur_first_bot ^ !idx[0];" "sh_parity <= cur_first_bot ^ idx[0];" tff refresh &
  mut D9 umd/disp_ctl.sv "                            rel_valid <= 1'b1; rel_store <= sh_store;" \
         "                            rel_valid <= 1'b1; rel_store <= rec_store;" film32 "hold|queue" &
  mut D10 umd/disp_reader.sv "fetch_changes <= fetch_changes + 32'd1;" "fetch_changes <= fetch_changes + 32'd0;" film32 judder &
  mut D11 umd/disp_ctl.sv "ev_end  <= rec_valid && rec_end && !ended && !skipping;" "ev_end  <= 1'b0;" film32 count &
  mut D12 umd/disp_ctl.sv "c_hi <= R_Q3 + R_Q3;" "c_hi <= R_Q3;" film32 count &
  mut D13 umd/disp_sched.sv "prev_ok <= prev_run && !re_anch;" "prev_ok <= prev_run;" backfld count &
  mut D14 umd/disp_ctl.sv "sh_single <= !rec_frame && rec_unpaired;" "sh_single <= 1'b0;" unpaired refresh &
  wait
  mut D15 umd/disp_ctl.sv "wire tick_g   = tick && !frz;" "wire tick_g   = tick;" pause "refresh|count" &
  mut D16 umd/disp_ctl.sv "wire ev_pulse = ev_raw && !(il && v_pos[0] ? frz : freeze);" "wire ev_pulse = ev_raw;" pause "refresh|count" &
  mut D17 umd/disp_ctl.sv "wire pk_pulse = pk_raw && !frz;" "wire pk_pulse = pk_raw;" pausefld "refresh|count|judder" &
  mut D18 umd/disp_ctl.sv "wire   drain_take = resync && rec_valid && !rec_take;" "wire   drain_take = 1'b0;" seek "refresh|xport|hold|queue" &
  mut D19 umd/disp_ctl.sv ".clr(resync)" ".clr(1'b0)" seek "refresh|count|xport" &
  mut D20 umd/disp_ctl.sv "t_v <= '0; cur_v <= 1'b0; skipping <= 1'b0;" "cur_v <= 1'b0; skipping <= 1'b0;" seek "refresh|xport|count" &
  wait
  mut D21 umd/disp_ctl.sv "    wire   skip_drop  = in_item && skipping && est_v && (d_skip < 36'sd8);
    wire   skip_end   = in_item && skipping && !(est_v && (d_skip < 36'sd8));" "    wire   skip_drop  = in_item && skipping && est_v && (d_skip <= 36'sd0);
    wire   skip_end   = in_item && skipping && !(est_v && (d_skip <= 36'sd0));" mountin "refresh|xport|count" &
  mut D22 umd/disp_ctl.sv "(skipping ? x_q3 : {nx_pts, 3'b000})" "(skipping ? {x_q3[35:3], 3'b000} : {nx_pts, 3'b000})" seek xport &
  mut D23 umd/disp_ctl.sv "if (!tag && est_v) begin tag_ovr <= 1'b1; ovr_pts <= est; end" "if (1'b0) begin tag_ovr <= 1'b1; ovr_pts <= est; end" seek "refresh|xport|count" &
  mut D24 umd/disp_ctl.sv "t_v[cur_ep] && est_v && (d_stop >= 34'sd0)" "t_v[cur_ep] && est_v && 1'b0" stopout "refresh|xport|count" &
  mut D25 umd/disp_ctl.sv "h_ep_v && (!cur_v || h_ep != cur_ep);" "h_ep_v && !cur_v;" items "refresh|xport|count" &
  mut D26 umd/disp_ctl.sv "if (t_last[cur_ep]) begin ended <= 1'b1;" "if (1'b1) begin ended <= 1'b1;" items "refresh|xport|count" &
  mut D27 umd/disp_ctl.sv "if (cur_v) left_mask[cur_ep] <= 1'b1;" "if (1'b0) left_mask[cur_ep] <= 1'b1;" items xport &
  mut D28 umd/disp_ctl.sv "if (!starve_run[6]) starve_run <= starve_run + 7'd1;" "if (1'b0) starve_run <= starve_run + 7'd1;" held xport &
  mut D29 umd/disp_ctl.sv "t_last[ep_wi] <= ep_last; t_skip[ep_wi] <= ep_skip;" "t_last[ep_wi] <= ep_last; t_skip[ep_wi] <= 1'b1;" trick "refresh|xport|count" &
  wait
  mut D30 umd/disp_sched.sv "ln = tag_q && anchored" "ln = 1'b0 && anchored" lone7 "refresh|count" &
  mut D31 umd/disp_sched.sv "if (lone) susp <= 1'b1;" "if (1'b0) susp <= 1'b1;" lone2 "refresh|count" &
  mut D32 umd/disp_sched.sv "else if (tag_e) susp <= 1'b0;" "else if (1'b0) susp <= 1'b0;" lone7 "refresh|count" &
  mut D33 umd/disp_sched.sv "((d_pic_next > HALF_SCAN) ||" "((d_pic_next > \$signed({11'd0, head_frame_t})) ||" lone7 "refresh|count" &
  mut D34 umd/disp_sched.sv "!(d_pic_next > FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS)" "1'b1 && !(d_pic_next < -FWD_MAX_TICKS)" gap2s "refresh|count" &
  mut D35 umd/disp_sched.sv "if (ln) want <= next_pts;" "if (1'b0) want <= next_pts;" lone7 refresh &
  mut D36 umd/disp_ctl.sv "if (lone && n_lone != 4'hF) n_lone <= n_lone + 4'd1;" "if (1'b0) n_lone <= n_lone + 4'd1;" lone7 count &
  mut D37 umd/disp_sched.sv "|| (d_pic_next < -HALF_SCAN)) &&" "|| 1'b0) &&" loneearlyfld "refresh|count" &
  mut D38 umd/disp_sched.sv "!(d_pic_next > FWD_MAX_TICKS) && !(d_pic_next < -FWD_MAX_TICKS)" "!(d_pic_next > FWD_MAX_TICKS) && 1'b1" back1s "refresh|count" &
  wait
  mut D39 umd/disp_ctl.sv "!rec_frame && !rec_unpaired && (rec_first_bot == v_pos[0]);" "1'b0;" tff.il "refresh|count" &
  mut D40 umd/disp_ctl.sv "due && !late && head_ok && !rec_take &&" "due && head_ok && !rec_take &&" latefld.il "refresh|count" &
  mut D41 umd/disp_ctl.sv "else if (ev_raw && !(il && v_pos[0])) frz <= freeze;" "else if (ev_raw) frz <= freeze;" pausefld.il "refresh|count" &
  mut D42 umd/disp_ctl.sv "wire [10:0] fl      = v_pos[11:1];" "wire [10:0] fl      = v_pos[10:0];" film32.il "refresh|count|harness" &
  mut D43 umd/disp_ctl.sv "if (skip_eos) begin rec_take <= 1'b1; ended <= 1'b1;" "if (1'b0) begin rec_take <= 1'b1; ended <= 1'b1;" seekend1 xport &
  wait
  mut H1 umd/disp_ctl.sv "                        if (np_now) begin
                            prev_v <= 1'b1; prev_st <= sh_store;" "                        if (1'b0) begin
                            prev_v <= 1'b1; prev_st <= sh_store;" telecine "hold|film" &
  mut H2 umd/disp_ctl.sv "if (prev_v) begin rel_valid <= 1'b1; rel_store <= prev_st; end" "if (1'b0) begin rel_valid <= 1'b1; rel_store <= prev_st; end" telecine "queue|hold" &
  mut H3 umd/disp_ctl.sv "if (!rec_end && !drain_nxp) begin rel_valid" "if (!rec_end) begin rel_valid" telecineseek hold &
  mut H4 umd/disp_ctl.sv "if (pk_raw && (rp0_v || rp1_v)) rp_go <= 1'b1;" "if (rp0_v || rp1_v) rp_go <= 1'b1;" telecineseek "hold|queue" &
  mut H5 umd/disp_ctl.sv "wire   fl_first  = pick || idx[0];" "wire   fl_first  = pick || !idx[0];" telecine film &
  mut H6 umd/disp_ctl.sv "sh_pstore <= (fl_show == 3'd2) ? prev_st : nx_st;" "sh_pstore <= prev_st;" telecine "film|hold" &
  mut H7 umd/disp_ctl.sv ".mv(cm_v)" ".mv(1'b0)" telecine film &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
