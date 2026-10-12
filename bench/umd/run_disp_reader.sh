#!/usr/bin/env bash
# run_disp_reader.sh -- the display plumbing: umd/ddr_mux2.sv (two masters on one DDRAM
# port with the mount abort; in emu only master A, the decoder, is live since the display
# moved to ram2 -- bench/umd/ddr_mux2_tb.sv), umd/disp_reader.sv (a DPB store on the
# 720x480 raster, frame and field pair, bench/umd/disp_reader_tb.sv) and umd/se_cdc.sv
# (the syntax elements clk_dec -> clk_sys, the retired P4 fallback, bench/umd/se_cdc_tb.sv).
# docs/display.md, docs/h264_recon.md S4. (Was run_disp_smoke.sh.)
#
# GREEN: ddr_mux2_tb twice -- the model's default latency, and a long one that fills the
# 16-entry owner FIFO (+need_full) -- every beat to its owner in order, the model's rules
# held (no write during reads, no read inside an open write burst), B served while A is
# busy, both aborts clean; disp_reader_tb on every deinterlace variant (P5f), each dot
# {de, R, G, B} against tools/disp_golden.py, LAT 4: [rgb] a frame (the BT.601 conversion
# of the store's samples, chroma interpolated both ways -- docs/display.md S12); [field] the
# same store as a field pair, woven (ffmpeg separatefields: each line's chroma from its own
# field, interpolated along the line); [il] the 480i frame arms want disp_want_frame_il (rows
# nearest); [pass] the frame in Bob and in
# Blend (untouched); [blend] the pair in Blend (ffmpeg's interlace lowpass) at 720x480,
# 480x272 (the bottom mirror inside the raster) and 720x576 (clipped: line 479's d is the
# real line 480); [bob] the pair in Bob keeping either field, at 720x480 and 480x272 (the
# top mirror on the kept bottom field, the bottom mirror on the top); [single] one field
# in Weave and in Blend (bobbed on its own field); se_cdc_tb twice
# (two stall mixes): 20,000 words in order across 81 -> 27 MHz, a word every 2 reader
# cycles unstalled.
#
# --red [MUTS="W1 W2" to run only those]: mutations on a COPY of the RTL, each caught by its own arm:
#   X1  mux: a write no longer waits for outstanding reads          -> [ddr]
#   X2  mux: an abort no longer swallows A's read beats              -> [abort]
#   X3  mux: an abort no longer completes the open write burst       -> [count] (the port hangs)
#   X4  mux: the completing beats written unmasked                   -> [abort]
#   X5  mux: the owner FIFO's full guard removed                     -> [data] or the model's credit rule [ddr]
#   X6  mux: B only when A is idle (no fairness)                     -> [count]
#   X7  mux: a request A withdraws under waitrequest is not held     -> [avalon] (the reload hang)
#   X8  mux: B's write burst no longer pins the grant (P6a)          -> [grant] / the model's [ddr]
#   X9  mux: B's write no longer waits for outstanding reads         -> [ddr]
#   X10 mux: a blocked B write gives the grant back (flip-flops)     -> [grant] / [count] (B starves)
#   X11 mux: B's write beats carry A's data                          -> [data] / [avalon] (the data
#       changes under waitrequest)
#   X12 mux: the grant handed to B while an orphan is re-presented   -> [ddr] (B's read inside A's
#       burst: the latent bug the live B found, 2026-09-27; the long-latency arm)
#   D1  disp: the Cr coefficient of R 409 -> 408                     -> [rgb]
#   D2  disp: the frame chroma row = the display line (not line / 2) -> [rgb]
#   D3  disp: the current line read from the next line's ring slot  -> [rgb]
#   D4  disp: a field store's chroma row = the frame's (y >> 1)      -> [field]
#   D5  disp: a field store's chroma from the OTHER field (y & 1 inverted) -> [field]
#   K1  disp: the blend's rounding +1 -> +2 (luma)                   -> [blend]
#   K2  disp: the blend leaves Cb unfiltered                         -> [blend]
#   K3  disp: bob keeps the other field                              -> [bob]
#   K4  disp: the bob's rebuilt line rounds down                     -> [bob]
#   K5  disp: no top mirror (line 0's a = the ring slot above)       -> [blend]
#   K6  disp: no bottom mirror (the 480x272 picture's last line)     -> [blend]
#   K7  disp: line 480 never fetched (the 720x576 clip)              -> [blend]
#   K8  disp: frames filtered too (the field gate dropped)           -> [pass]
#   K9  disp: a single field follows the menu (not always bobbed)    -> [single]
#   K10 disp: the mode never latched (always Weave)                  -> [blend]
#   fj#80 field matching (goldens disp_want_match0/1, disp_cm_*.args: tools/disp_golden.py's M):
#   M1  the partner's lines for the SHOWN field's parity              -> [match]
#   M2  the partner store ignored (every line from pic_store)         -> [match]
#   M3  matching at 480i (req_alt on the 480i walker's requests)      -> [match] (disp_match_il)
#   M4  the film weave ignored (Blend still applied)                  -> [film]
#   M5  the film bob ignored (Weave shown)                            -> [film]
#   M6  the comb's b from the d line (|2d - a - d|)                   -> [comb]
#   M7  every 4th dot summed                                          -> [comb]
#   M8  R as |a - b|                                                  -> [comb]
#   M9  cm_v on a single field                                        -> [comb] (disp_single_w)
#   M10 the sums never cleared at the latch                           -> [comb]
#   480i (docs/analog.md; +il: a whole frame, both dots of every pixel):
#   I1  the column not halved (h_pos read as pixels)                  -> [il]
#   I2  the 480p kernel's output at 480i (Blend asked: a paused pair)  -> [ilstill]
#       (on a pair in play the window is one line: every kernel is b)
#   I3  the kept-top field's other lines not rebuilt (q 1, ps 0)      -> [ilsingle]
#   I4  the top edge rule removed (q 0, ps 1: line 0 blended with 1)  -> [ilsingle]
#   I5  a paused pair shows both fields (pic_still ignored)           -> [ilstill]
#   I6  the blend partner past the picture's last field line          -> [ilsingle] (480x272)
#   I7  a request's second line never fetched                         -> [ilsingle]
#   (the clamp of s itself is hygiene: an unclamped s lies only below the picture, black)
#   480i Analog Aspect (S2, docs/analog.md V8-V10; goldens disp_want_il_*):
#   A1  Letterbox steps 6 sixths a line (no 3/4 scale)                -> [lb]
#   A2  one phase in both fields (DVD's: field 1's 1/6 line dropped)  -> [lb]
#   A3  a weight off by one (43 -> 42)                                -> [lb]
#   A4  the vertical blend's rounding (+128) dropped                  -> [lb]
#   A5  the band a line early (29)                                    -> [lb]
#   A6  Crop's origin a pixel right (364)                             -> [crop]
#   A7  Crop's rounding (+2) dropped                                  -> [crop]
#   A8  Crop's second chroma tap the first's                          -> [crop]
#   A9  the size gate removed (a 480x272 picture letterboxed)         -> [lb] (480x272)
#   A10 the even half read at t0 (t0 odd: the wrong word / lane)      -> [crop]
#   P9's video window (goldens disp_want_win_*, tools/disp_golden.py's WIN):
#   W1  a new row's slot not the allocator's (a slot being read)      -> [win] (29 %)
#   W2  the vertical weight in eighths, not sixteenths                -> [win]
#   W3  the horizontal start x0 ignored                              -> [win]
#   W4  no right clamp (a column past the picture blended in)         -> [win] (the upscale)
#   W5  no bottom clamp (a row past the picture)                      -> [win] (the upscale)
#   W6  a field store's rows read as frame lines (the kept field lost) -> [win] (keep1)
#   W7  a held row s + 1 read from the older slot                     -> [win] (the upscale)
#   W8  480i: the field's parity left out of the line                 -> [win] (480i)
#   W12 a field store's position not halved (the host's steps are frame rows: the rig's
#       squashed episode under a menu)                                -> [win] (keep1)
#   W9  a row past 511 fetched as 9 bits (720 x 576)                 -> [win] (tall)
#   W10 the window's columns not bounded (the picture beside it)     -> [win]
#   W11 a rectangle off the raster not refused                        -> [win] (bad)
#   (win_hold -- no latch during a HOST_WR -- is the host port's: run_umd_host.sh H19)
#   chroma interpolated (docs/display.md S12; the golden's hup / up_h / up_ident, the frame's checked
#   against ffmpeg's in_chroma_loc=left upsampling):
#   Z1  the odd / even column swapped                                 -> [rgb]
#   Z2  row a's horizontal rounding dropped                           -> [blend]
#   Z3  the vertical neighbour's rows swapped (2m takes d)            -> [rgb]
#   Z4  the vertical step on a field store                            -> [field]
#   Z5  the right edge not replicated (rows b / d)                    -> [rgb]
#   Z6  no interpolation (nearest)                                    -> [rgb]
#   Z7  row a's ahead read not clamped (the right edge)               -> [blend]
#   Z8  row a's left tap its own read (not the previous dot's)        -> [blend]
#   Z9  480i not interpolated                                         -> [il]
#   Z10 Crop interpolated too (its own taps)                          -> [crop]
#   Z11 the window interpolated too (its own taps)                    -> [win] (the upscale: the half
#       window's weight is 8 on every column, its chroma pairs equal -- it cannot see this)
#   C1  se_cdc: a pop while a word is in flight (the guard dropped)  -> [order]
#   C2  se_cdc: pop only into an empty register (no pop on take)     -> [rate]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
MODEL=bench/umd/ddr_model.sv
python3 tools/disp_golden.py > /dev/null || { echo "FAIL: golden"; exit 1; }

run_arm() {  # label sim-files tb marker plusargs
  local label=$1 files=$2 tb=$3 marker=$4 args=$5
  # shellcheck disable=SC2086
  rm -f .sim/${label}_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
  iverilog -g2012 -o .sim/${label}_sim $files $tb 2>&1 | grep -v "sorry\|warning"
  # shellcheck disable=SC2086
  if [ -f .sim/${label}_sim ] && timeout 1200 vvp -n .sim/${label}_sim $args > .sim/${label}.log 2>&1 && grep -q "^PASS: $marker" .sim/${label}.log; then
    echo "  PASS $label: $(grep "^$marker:" .sim/${label}.log | sed "s/^$marker: //")"
  else echo "  FAIL $label"; grep FAIL .sim/${label}.log | head -3; fail=1; fi
}
echo "== GREEN: ddr_mux2 =="
run_arm mux2 "umd/ddr_mux2.sv $MODEL" bench/umd/ddr_mux2_tb.sv ddr_mux2_tb ""
run_arm mux2_long "umd/ddr_mux2.sv $MODEL" bench/umd/ddr_mux2_tb.sv ddr_mux2_tb "+need_full +lat_min=60 +lat_max=90 +wait_pct=5"
echo "== GREEN: se_cdc =="
run_arm secdc "umd/fifo_dc.sv umd/se_cdc.sv" bench/umd/se_cdc_tb.sv se_cdc_tb ""
run_arm secdc_mix "umd/fifo_dc.sv umd/se_cdc.sv" bench/umd/se_cdc_tb.sv se_cdc_tb "+wr_gap=80 +rd_stall=5"
echo "== GREEN: disp_reader =="
G=bench/umd/fixtures/gen
DF="umd/sync_gen.sv umd/disp_reader.sv $MODEL"
DT=bench/umd/disp_reader_tb.sv
# shellcheck disable=SC2086
rm -f .sim/disp_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/disp_sim $DF $DT 2>&1 | grep -v "sorry\|warning"
disp_arm() {  # label plusargs -- one compile, the arms in parallel
  local label=$1 args=$2
  # shellcheck disable=SC2086
  if timeout 1200 vvp -n .sim/disp_sim $args > .sim/${label}.log 2>&1 && grep -q "^PASS: disp_reader_tb" .sim/${label}.log; then
    echo "  PASS $label: $(grep "^disp_reader_tb:" .sim/${label}.log | sed "s/^disp_reader_tb: //")" > .sim/${label}.res
  else { echo "  FAIL $label"; grep FAIL .sim/${label}.log | head -3; echo DISPFAIL; } > .sim/${label}.res; fi
}
# shellcheck disable=SC2034
DISP_ARMS=(
  "disp|+arm=rgb"
  "disp_field|+arm=field +field +want=$G/disp_want_field.hex $(cat $G/disp_cm_field.args)"
  "disp_match0|+arm=match +field +match +parity=0 +want=$G/disp_want_match0.hex $(cat $G/disp_cm_match0.args)"
  "disp_match1|+arm=match +field +match +parity=1 +mode=2 +film=1 +want=$G/disp_want_match1.hex $(cat $G/disp_cm_match1.args)"
  "disp_film_blend|+arm=film +field +mode=2 +film=1 +want=$G/disp_want_field.hex"
  "disp_film_bob|+arm=film +field +mode=0 +film=2 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_match_il|+arm=match +il +field +match +parity=0 +want=$G/disp_want_field.hex"
  "disp_pass_bob|+arm=pass +mode=1"
  "disp_pass_blend|+arm=pass +mode=2 +parity=1"
  "disp_blend|+arm=blend +field +mode=2 +want=$G/disp_want_blend.hex"
  "disp_blend_s|+arm=blend +small +field +mode=2 +want=$G/disp_want_s_blend.hex"
  "disp_blend_t|+arm=blend +tall +field +mode=2 +want=$G/disp_want_t_blend.hex"
  "disp_bob0|+arm=bob +field +mode=1 +parity=0 +want=$G/disp_want_bob0.hex"
  "disp_bob1|+arm=bob +field +mode=1 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_bob_s0|+arm=bob +small +field +mode=1 +parity=0 +want=$G/disp_want_s_bob0.hex"
  "disp_bob_s1|+arm=bob +small +field +mode=1 +parity=1 +want=$G/disp_want_s_bob1.hex"
  "disp_single_w|+arm=single +field +single +mode=0 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_single_l|+arm=single +small +field +single +mode=2 +parity=0 +want=$G/disp_want_s_bob0.hex"
  "disp_il|+arm=il +il +want=$G/disp_want_frame_il.hex"
  "disp_il_field|+arm=il +il +field +mode=2 +want=$G/disp_want_field.hex"
  "disp_il_still_frame|+arm=il +il +still +mode=1 +want=$G/disp_want_frame_il.hex"
  "disp_il_single0|+arm=ilsingle +il +field +single +parity=0 +want=$G/disp_want_bob0.hex"
  "disp_il_single1|+arm=ilsingle +il +field +single +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_il_single_s0|+arm=ilsingle +il +small +field +single +parity=0 +want=$G/disp_want_s_bob0.hex"
  "disp_il_still1|+arm=ilstill +il +field +still +mode=2 +parity=1 +want=$G/disp_want_bob1.hex"
  "disp_il_still_s0|+arm=ilstill +il +small +field +still +parity=0 +want=$G/disp_want_s_bob0.hex"
  "disp_il_lb|+arm=lb +il +aa=1 +want=$G/disp_want_il_lb.hex"
  "disp_il_lb_field|+arm=lb +il +aa=1 +field +want=$G/disp_want_il_lb_field.hex"
  "disp_il_lb_keep1|+arm=lb +il +aa=1 +field +still +parity=1 +want=$G/disp_want_il_lb_keep1.hex"
  "disp_il_lb_keep0|+arm=lb +il +aa=1 +field +single +parity=0 +want=$G/disp_want_il_lb_keep0.hex"
  "disp_il_lb_small|+arm=lb +il +aa=1 +small +field +single +parity=0 +want=$G/disp_want_s_bob0.hex"
  "disp_il_crop|+arm=crop +il +aa=2 +want=$G/disp_want_il_crop.hex"
  "disp_il_crop_field|+arm=crop +il +aa=2 +field +want=$G/disp_want_il_crop_field.hex"
  "disp_il_crop_keep0|+arm=crop +il +aa=2 +field +still +parity=0 +want=$G/disp_want_il_crop_keep0.hex"
  "disp_aa_480p|+arm=rgb +aa=2"
)
# P9's video window (docs/p9.md S3.2 item 6): every case of tools/disp_golden.py's WIN on both
# rasters (the 480i raster shows the same frame lines); the store / field flags per case
for c in half low edge one keep1 up tall bad; do
  case $c in keep1) st="+field +parity=1";; up) st="+small";; tall) st="+tall";; *) st="";; esac
  wa=$(cat $G/disp_win_$c.args)
  DISP_ARMS+=("disp_win_$c|+arm=win $st $wa +want=$G/disp_want_win_$c.hex")
  DISP_ARMS+=("disp_win_il_$c|+arm=win +il $st $wa +want=$G/disp_want_win_$c.hex")
done
for a in "${DISP_ARMS[@]}"; do disp_arm "${a%%|*}" "${a#*|}" & done
wait
for a in "${DISP_ARMS[@]}"; do
  l=${a%%|*}; grep -v '^DISPFAIL$' .sim/$l.res; grep -q '^DISPFAIL$' .sim/$l.res && fail=1
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new tb arm(s regex) other-files plusargs
    local name=$1 file=$2 old=$3 new=$4 tb=$5 arm=$6 others=$7 args=${8:-}
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    local d; d=$(mktemp -d)
    cp "$file" "$d/"
    python3 - "$d/$(basename "$file")" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # shellcheck disable=SC2086
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/$(basename "$file")" $others "$tb" 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    timeout 1200 vvp -n "$d/sim" $args > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($arm)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($arm)\]" "$d/log" | cut -c1-100)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arm]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  M=umd/ddr_mux2.sv; MT=bench/umd/ddr_mux2_tb.sv; D=umd/disp_reader.sv; DT=bench/umd/disp_reader_tb.sv
  BL="+arm=blend +field +mode=2 +want=$G/disp_want_blend.hex"
  mut X1 $M "wire a_wr_blocked = a_write && (a_wburst == 8'd0) && reads_out;" "wire a_wr_blocked = 1'b0;" $MT "ddr" "$MODEL" &
  mut X2 $M "reads_out && !own[o_rd] && !a_flush;" "reads_out && !own[o_rd];" $MT "abort" "$MODEL" &
  mut X3 $M "ddr_write = (a_wburst != 8'd0);" "ddr_write = 1'b0;" $MT "count" "$MODEL" &
  mut X4 $M "ddr_writedata = a_writedata; ddr_byteenable = 8'h00;" "ddr_writedata = a_writedata; ddr_byteenable = 8'hFF;" $MT "abort" "$MODEL" &
  mut X5 $M "wire         own_full  = o_cnt[4];" "wire         own_full  = 1'b0;" $MT "data|ddr" "$MODEL" "+need_full +lat_min=60 +lat_max=90 +wait_pct=5" &
  mut X6 $M "if (b_req && !orphan && ((a_rd_acc) ||" "if (b_req && !orphan && ((1'b0) ||" $MT "count" "$MODEL" &
  mut X7 $M "wire         orphan  = h_valid && !grant && (a_flush || !a_same);" "wire         orphan  = 1'b0;" $MT "avalon" "$MODEL" &
  wait
  mut X8 $M "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0)) grant <= 1'b0;" "if (b_rd_acc || b_wr_acc || !b_req) grant <= 1'b0;" $MT "grant|ddr" "$MODEL" &
  mut X9 $M "wire b_wr_blocked = b_write && (b_wburst == 8'd0) && reads_out;" "wire b_wr_blocked = 1'b0;" $MT "ddr" "$MODEL" &
  mut X10 $M "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0)) grant <= 1'b0;" "if (b_rd_acc || b_wlast || (!b_req && b_wburst == 8'd0) || b_wr_blocked) grant <= 1'b0;" $MT "grant|count" "$MODEL" &
  mut X11 $M "ddr_writedata = b_writedata; ddr_byteenable = 8'hFF;" "ddr_writedata = a_writedata; ddr_byteenable = 8'hFF;" $MT "data|avalon" "$MODEL" &
  mut X12 $M "if (b_req && !orphan && ((a_rd_acc)" "if (b_req && ((a_rd_acc)" $MT "ddr" "$MODEL" "+need_full +lat_min=60 +lat_max=90 +wait_pct=5" &
  mut D1 $D "p_ecr <= 20'sd409 * e2;" "p_ecr <= 20'sd408 * e2;" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut D2 $D "m_field ? {m_line_q[9:2], m_line_q[0]} : m_line_q[9:1];" "m_field ? {m_line_q[9:2], m_line_q[0]} : m_line_q[8:0];" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut D4 $D "m_field ? {m_line_q[9:2], m_line_q[0]} : m_line_q[9:1];" "m_line_q[9:1];" $DT "field" "umd/sync_gen.sv $MODEL" "+arm=field +field +want=$G/disp_want_field.hex" &
  mut D5 $D "m_field ? {m_line_q[9:2], m_line_q[0]} : m_line_q[9:1];" "m_field ? {m_line_q[9:2], !m_line_q[0]} : m_line_q[9:1];" $DT "field" "umd/sync_gen.sv $MODEL" "+arm=field +field +want=$G/disp_want_field.hex" &
  mut D3 $D "wire  [1:0]  bk_b = fw_on ? cur_sb : il ? cur_s[1:0] : v_pos[1:0];" "wire  [1:0]  bk_b = fw_on ? cur_sb : il ? cur_s[1:0] : v_pos[1:0] + 2'd1;" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut K1 $D "{1'd0, yb, 1'b0} + {2'd0, yd} + 10'd1;" "{1'd0, yb, 1'b0} + {2'd0, yd} + 10'd2;" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut K2 $D "(s1_k == 2'd2) ? ul[9:2]" "(s1_k == 2'd2) ? ub" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut K3 $D "(v_pos[0] == pic_parity)" "(v_pos[0] != pic_parity)" $DT "bob" "umd/sync_gen.sv $MODEL" "+arm=bob +field +mode=1 +parity=0 +want=$G/disp_want_bob0.hex" &
  mut K4 $D "wire  [8:0]  ym = {1'd0, ya} + {1'd0, yd} + 9'd1;" "wire  [8:0]  ym = {1'd0, ya} + {1'd0, yd};" $DT "bob" "umd/sync_gen.sv $MODEL" "+arm=bob +field +mode=1 +parity=1 +want=$G/disp_want_bob1.hex" &
  mut K5 $D "top  ? v_pos[1:0] + 2'd1 : v_pos[1:0] - 2'd1;" "v_pos[1:0] - 2'd1;" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut K6 $D "last ? v_pos[1:0] - 2'd1 : v_pos[1:0] + 2'd1;" "v_pos[1:0] + 2'd1;" $DT "blend" "umd/sync_gen.sv $MODEL" "+arm=blend +small +field +mode=2 +want=$G/disp_want_s_blend.hex" &
  mut K7 $D "else if (v_pos < 12'd479) begin" "else if (v_pos < 12'd478) begin" $DT "blend" "umd/sync_gen.sv $MODEL" "+arm=blend +tall +field +mode=2 +want=$G/disp_want_t_blend.hex" &
  mut K8 $D "                        !pic_field ? 2'd0 :" "                        1'b0 ? 2'd0 :" $DT "pass" "umd/sync_gen.sv $MODEL" "+arm=pass +mode=2 +parity=1" &
  mut K9 $D "(pic_single || pic_film == 2'd2 || (k_mode == 2'd1 && !film_w))" "(pic_film == 2'd2 || (k_mode == 2'd1 && !film_w))" $DT "single" "umd/sync_gen.sv $MODEL" "+arm=single +field +single +mode=0 +parity=1 +want=$G/disp_want_bob1.hex" &
  mut K10 $D "req_tog <= !req_tog; k_mode <= deint_mode;" "req_tog <= !req_tog; k_mode <= 2'd0;" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  # 480i (docs/analog.md)
  mut I1 $D "wire  [9:0]  x = il ? h_pos[10:1] : h_pos[9:0];" "wire  [9:0]  x = h_pos[9:0];" $DT "il" "umd/sync_gen.sv $MODEL" "+arm=il +il +want=$G/disp_want_frame_il.hex" &
  mut I2 $D "wire  [7:0]  yk = two ? iy :" "wire  [7:0]  yk = 1'b0 ? iy :" $DT "ilstill" "umd/sync_gen.sv $MODEL" "+arm=ilstill +il +field +still +mode=2 +parity=1 +want=$G/disp_want_bob1.hex" &
  mut I3 $D "2'b10:   begin s0_s = 11'sd0;  s0_r = 3'd3; end" "2'b10:   begin s0_s = 11'sd0;  s0_r = 3'd0; end" $DT "ilsingle" "umd/sync_gen.sv $MODEL" "+arm=ilsingle +il +field +single +parity=0 +want=$G/disp_want_bob0.hex" &
  mut I4 $D "wire  [2:0]  v_k    = (v_neg || v_s0 >= {1'b0, w_last}) ? 3'd0 : v_r;" "wire  [2:0]  v_k    = (v_s0 >= {1'b0, w_last}) ? 3'd0 : v_r;" $DT "ilsingle" "umd/sync_gen.sv $MODEL" "+arm=ilsingle +il +field +single +parity=1 +want=$G/disp_want_bob1.hex" &
  mut I5 $D "(pic_single || (pic_still && pic_field))" "(pic_single)" $DT "ilstill" "umd/sync_gen.sv $MODEL" "+arm=ilstill +il +field +still +mode=2 +parity=1 +want=$G/disp_want_bob1.hex" &
  mut I6 $D "wire  [2:0]  v_k    = (v_neg || v_s0 >= {1'b0, w_last}) ? 3'd0 : v_r;" "wire  [2:0]  v_k    = v_neg ? 3'd0 : v_r;" $DT "ilsingle" "umd/sync_gen.sv $MODEL" "+arm=ilsingle +il +small +field +single +parity=0 +want=$G/disp_want_s_bob0.hex" &
  mut I7 $D "if (f_more) begin" "if (1'b0) begin" $DT "ilsingle" "umd/sync_gen.sv $MODEL" "+arm=ilsingle +il +field +single +parity=0 +want=$G/disp_want_bob0.hex" &
  wait
  LBA="+arm=lb +il +aa=1 +want=$G/disp_want_il_lb.hex"
  CRA="+arm=crop +il +aa=2 +want=$G/disp_want_il_crop.hex"
  mut A1 $D "else             begin v_s = w_s + 11'sd1; v_r = w_r + 3'd2; end" "else             begin v_s = w_s + 11'sd1; v_r = w_r; end" $DT "lb" "umd/sync_gen.sv $MODEL" "$LBA" &
  mut A2 $D "2'b11:   begin s0_s = 11'sd0;  s0_r = 3'd1; end" "2'b11:   begin s0_s = 11'sd0;  s0_r = 3'd0; end" $DT "lb" "umd/sync_gen.sv $MODEL" "$LBA" &
  mut A3 $D "3'd1: w6 = 8'd43;" "3'd1: w6 = 8'd42;" $DT "lb" "umd/sync_gen.sv $MODEL" "$LBA" &
  mut A4 $D "ps8 = (pv + 18'sd128) >>> 8;" "ps8 = pv >>> 8;" $DT "lb" "umd/sync_gen.sv $MODEL" "$LBA" &
  mut A5 $D "if (w_j == 9'd30)" "if (w_j == 9'd29)" $DT "lb" "umd/sync_gen.sv $MODEL" "$LBA" &
  wait
  mut A6 $D "wire  [11:0] xq   = 12'd360 +" "wire  [11:0] xq   = 12'd364 +" $DT "crop" "umd/sync_gen.sv $MODEL" "$CRA" &
  mut A7 $D "(f[3] ? {dh[9], dh, 3'b0} : 14'sd0) + 14'sd8;" "(f[3] ? {dh[9], dh, 3'b0} : 14'sd0) + 14'sd0;" $DT "crop" "umd/sync_gen.sv $MODEL" "$CRA" &
  mut A8 $D "ub1 = !s1_t0o ? ub : (s1_c0o ? ub_e : ub_o);" "ub1 = ub;" $DT "crop" "umd/sync_gen.sv $MODEL" "$CRA" &
  mut A9 $D "(pic_w_mbs == 8'd45 && pic_hf_mbs == 8'd30 && aa_mode != 2'd3)" "(aa_mode != 2'd3)" $DT "lb" "umd/sync_gen.sv $MODEL" "+arm=lb +il +aa=1 +small +field +single +parity=0 +want=$G/disp_want_s_bob0.hex" &
  mut A10 $D "wire  [9:0]  t_e  = t0 + {9'd0, t0[0]};" "wire  [9:0]  t_e  = t0;" $DT "crop" "umd/sync_gen.sv $MODEL" "$CRA" &
  wait
  # fj#80 field matching
  MA0="+arm=match +field +match +parity=0 +want=$G/disp_want_match0.hex $(cat $G/disp_cm_match0.args)"
  MA1="+arm=match +field +match +parity=1 +mode=2 +film=1 +want=$G/disp_want_match1.hex $(cat $G/disp_cm_match1.args)"
  FLD="+arm=field +field +want=$G/disp_want_field.hex $(cat $G/disp_cm_field.args)"
  mut M1 $D "req_alt <= pic_match && (v_pos[0] != pic_parity);" "req_alt <= pic_match && (v_pos[0] == pic_parity);" $DT "match" "umd/sync_gen.sv $MODEL" "$MA0" &
  mut M2 $D "m_store <= req_alt ? pic_pstore : pic_store;" "m_store <= pic_store;" $DT "match" "umd/sync_gen.sv $MODEL" "$MA1" &
  mut M3 $D "        end else if (h_pos == 12'd1440 && (ini || v_pos == 12'd523 || v_pos == 12'd524 || fl < 11'd240)) begin
            req_alt <= 1'b0;" "        end else if (h_pos == 12'd1440 && (ini || v_pos == 12'd523 || v_pos == 12'd524 || fl < 11'd240)) begin
            req_alt <= pic_match;" $DT "match" "umd/sync_gen.sv $MODEL" "+arm=match +il +field +match +parity=0 +want=$G/disp_want_field.hex" &
  mut M4 $D "wire         film_w = (pic_film == 2'd1);" "wire         film_w = 1'b0;" $DT "film" "umd/sync_gen.sv $MODEL" "+arm=film +field +mode=2 +film=1 +want=$G/disp_want_field.hex" &
  mut M5 $D "(pic_single || pic_film == 2'd2 ||" "(pic_single ||" $DT "film" "umd/sync_gen.sv $MODEL" "+arm=film +field +mode=0 +film=2 +parity=1 +want=$G/disp_want_bob1.hex" &
  wait
  mut M6 $D "wire signed [10:0] cm_s = \$signed({2'b0, yb, 1'b0})" "wire signed [10:0] cm_s = \$signed({2'b0, yd, 1'b0})" $DT "comb" "umd/sync_gen.sv $MODEL" "$FLD" &
  mut M7 $D "s1_cm <= in_pic && !il && !fw_on && (x[2:0] == 3'd0);" "s1_cm <= in_pic && !il && !fw_on && (x[1:0] == 2'd0);" $DT "comb" "umd/sync_gen.sv $MODEL" "$FLD" &
  mut M8 $D "wire  [8:0]  cr_s = {1'b0, ya} - {1'b0, yd};" "wire  [8:0]  cr_s = {1'b0, ya} - {1'b0, yb};" $DT "comb" "umd/sync_gen.sv $MODEL" "$FLD" &
  mut M9 $D "cm_v <= pic_valid && pic_field && !pic_single && !fw_on;" "cm_v <= pic_valid && pic_field && !fw_on;" $DT "comb" "umd/sync_gen.sv $MODEL" "+arm=single +field +single +mode=0 +parity=1 +want=$G/disp_want_bob1.hex" &
  mut M10 $D "cm_c <= acc_c; cm_r <= acc_r; acc_c <= '0; acc_r <= '0;" "cm_c <= acc_c; cm_r <= acc_r;" $DT "comb" "umd/sync_gen.sv $MODEL" "$FLD" &
  wait
  # P9's video window (docs/p9.md S3.2 item 6)
  wa() { echo "+arm=win ${2:-} $(cat $G/disp_win_$1.args) +want=$G/disp_want_win_$1.hex"; }
  mut W1 $D "nxt_sb <= wal; nxt_sd <= (wn_f != 4'd0) ? wal1 : wal;" "nxt_sb <= ws1; nxt_sd <= (wn_f != 4'd0) ? wal1 : wal;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa low)" &
  mut W2 $D "if (s1_win) w6 = {s1_wf, 4'd0};" "if (s1_win) w6 = {1'b0, s1_wf, 3'd0};" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa half)" &
  mut W3 $D "wire  [35:0] wB   = {10'd0, fw_x0} +" "wire  [35:0] wB   = 36'd0 +" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa half)" &
  mut W4 $D "wire         wc_cl = (wB[35:16] >= {10'd0, fw_lastc});" "wire         wc_cl = 1'b0;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa up +small)" &
  mut W5 $D "wire         w_cl   = (wA_r >= {10'd0, fw_lastr});" "wire         w_cl   = 1'b0;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa up +small)" &
  mut W6 $D "wire  [9:0]  st_s   = fw_fld ? {wn_s[8:0], fw_kp} : wn_s;" "wire  [9:0]  st_s   = wn_s;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa keep1 '+field +parity=1')" &
  wait
  mut W7 $D "wire  [1:0]  sl_s1  = h1_s1 ? ws1 : ws0;" "wire  [1:0]  sl_s1  = ws0;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa up +small)" &
  mut W8 $D "wire  [9:0]  wY     = il ? {wj_n[8:0], wq_n} : wj_n;" "wire  [9:0]  wY     = il ? {wj_n[8:0], 1'b0} : wj_n;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa half +il)" &
  mut W12 $D "    wire  [19:0] wA_r   = fw_fld ? {1'b0, wA[35:17]} : wA[35:16];     // the row: a field store halves" "    wire  [19:0] wA_r   = wA[35:16];" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa keep1 '+field +parity=1')" &
  mut W9 $D "wire  [9:0]  st_s1  = fw_fld ? {wn_s1[8:0], fw_kp} : wn_s1;" "wire  [9:0]  st_s1  = fw_fld ? {wn_s1[8:0], fw_kp} : {1'b0, wn_s1[8:0]};" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa tall +tall)" &
  mut W10 $D "(fw_on ? (wx_in && cur_wi) :" "(fw_on ? (cur_wi) :" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa half)" &
  mut W11 $D "wire         w_ok    = (win_w != 10'd0) && (win_h != 10'd0) && (wxe <= 11'd720) && (wye <= 11'd480);" "wire         w_ok    = 1'b1;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa bad)" &
  wait
  # chroma interpolated (docs/display.md S12)
  mut Z1 $D "wire         ch_x = ch_h && x[0] &&" "wire         ch_x = ch_h && !x[0] &&" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut Z2 $D "{1'b0, p_ua} + {1'b0, ua} + 9'd1" "{1'b0, p_ua} + {1'b0, ua} + 9'd0" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut Z3 $D "wire  [1:0]  bk_dc = (ch_v && !v_pos[0]) ? bk_a : bk_d;" "wire  [1:0]  bk_dc = (ch_v && v_pos[0]) ? bk_a : bk_d;" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut Z4 $D "wire         ch_v = !il && !fw_on && !pic_field;" "wire         ch_v = !il && !fw_on;" $DT "field" "umd/sync_gen.sv $MODEL" "$FLD" &
  mut Z5 $D "x[0] && ({2'd0, x} + 12'd1 < {pic_w_mbs, 4'd0});" "x[0];" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  mut Z6 $D "wire         ch_h = !fw_on && !crop;" "wire         ch_h = 1'b0;" $DT "rgb" "umd/sync_gen.sv $MODEL" &
  wait
  mut Z7 $D "wire  [8:0]  ca   = (ca_u > ca_l) ? ca_l[8:0] : ca_u[8:0];" "wire  [8:0]  ca   = ca_u[8:0];" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut Z8 $D "{1'b0, p_ua} + {1'b0, ua} + 9'd1" "{1'b0, ua} + {1'b0, ua} + 9'd1" $DT "blend" "umd/sync_gen.sv $MODEL" "$BL" &
  mut Z9 $D "wire         ch_h = !fw_on && !crop;" "wire         ch_h = !fw_on && !crop && !il;" $DT "il" "umd/sync_gen.sv $MODEL" "+arm=il +il +want=$G/disp_want_frame_il.hex" &
  mut Z10 $D "wire         ch_h = !fw_on && !crop;" "wire         ch_h = !fw_on;" $DT "crop" "umd/sync_gen.sv $MODEL" "$CRA" &
  mut Z11 $D "wire         ch_h = !fw_on && !crop;" "wire         ch_h = !crop;" $DT "win" "umd/sync_gen.sv $MODEL" "$(wa up +small)" &
  wait
  C=umd/se_cdc.sv; CT=bench/umd/se_cdc_tb.sv
  mut C1 $C "assign f_rd = !f_empty && !pend && (!out_valid || take);" "assign f_rd = !f_empty && (!out_valid || take);" $CT "order" "umd/fifo_dc.sv" &
  mut C2 $C "assign f_rd = !f_empty && !pend && (!out_valid || take);" "assign f_rd = !f_empty && !pend && !out_valid;" $CT "rate" "umd/fifo_dc.sv" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
