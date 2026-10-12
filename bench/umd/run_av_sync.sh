#!/usr/bin/env bash
# run_av_sync.sh -- the audio path's gate: ps_demux -> aud_ring -> at3p_top -> aud_out
# (bench/umd/av_sync_tb.sv) on program streams from tools/av_sync_golden.py, scored on
# the tags, every PCM pair, and when every pair plays against the STC.
# docs/at3p_decoder.md S7.
#
# GREEN (Akira clip 1, its first 8 AUs):
#   S1 disc      the clip's own packs; the STC starts 5,000 ticks after the first PTS:
#                the stale head is discarded pair by pair, the release lands inside a pair
#   S2 split     re-packetised (FAP 5 realign, a PES on an AU's 0xD0 byte, a PES with no
#                AU, PTS-less PES: derived tags); the STC starts 100 ms early: the gate waits
#   S3 garbage   split + 7 garbage bytes after AU 3: framer and decoder slide alike
#   S4 underrun  split; the decoder's input stalls 4M cycles mid-stream: the FIFO runs
#                dry, the gate re-arms, and the audio comes back at its PTS
#   S5 deadlock  all the audio ahead of the video, a 2 KB ring: the STC can only start if
#                the gate yields audio from its stale end before it runs (pre-anchor drops;
#                AUs 0-2 go that way, so the STC starts in AU 3: an anchor past where the
#                audio stands would leave the decoder behind the clock to the stream's end)
#   S6 jump      split; the STC jumps +100 ms during frame 1: the next frame start is
#                50 ms off, the gate re-arms on it and re-phases
#   S7 pause     split; frozen 6M cycles (0.22 s at 27 MHz) once 2 frames have played:
#                the STC and the sample tick held together, nothing played or dropped,
#                the FIFO and the ring fill; on resume every frame start in step, no re-arm
#   S8 pausepre  S5's deadlock, frozen from the reset for 3M cycles: before the STC runs
#                the pre-anchor discard must hold too (P6b3: a pause during a seek's landing)
#   S9 left      split; once 2 frames have played the display leaves the audio's item (P6b3i):
#                nothing plays after it, every later pair is a left item's discard
#   S11 tag      S2 with every byte tagged item 1: the tag rides demux -> ring -> gate (P6b3i:
#                the rig found the demux clearing it every cycle, which no arm could see)
#   S10 stall    split, a 2 KB ring, the STC 10 s behind the audio and the picture stalled:
#                the breaker yields the early audio instead of hanging (P6b3i; the rig's MCR hang)
#   S12 switch   (P6b7) Akira clip 1's own packs, both its tracks, a 2 KB ring: 2 frames of track 0,
#                then the switch as player_ctl makes it (the chain reset, then the track and the
#                demux's realign); track 1 from the AU the new chain takes, at its PTS. Frame 0
#                after it is timed, not compared: the decoder's history RAMs survive a reset (as
#                ffmpeg's, which has no flush), so its first half blends the old track's tail;
#                frames 1-2 bit-exact with the golden decoded cold from that AU
#
# --red [MUTS="M1 M4" to run only those]: mutations on a COPY, each caught by its own arm:
#   M1  the tag of a PES that starts on an AU's 0xD0 byte goes to THAT AU (S2)  -> [tag]
#   M2  a derived tag adds 3,841 ticks (S2)                                    -> [tag]
#   M3  the ring accepts when full: bytes lost (S5)                            -> [tag|pcm|count|live]
#   M4  release 120 ticks early (S2)                                           -> [start]
#   M5  no pre-anchor discard (S5)                                             -> [live]
#   M6  no underrun re-arm: RUN waits out the gap, and the late frame start is
#       re-armed as a resync instead (S4)                                      -> [count]
#   M7  no resync re-arm on a 50 ms error (S6)                                 -> [sync]
#   M8  the framer's frame length forgets the +8 (S1)                          -> [tag|count]
#       (the framer slides back onto every header, so the tags can stay right: the
#       slide count is the evidence)
#   M9  the framer drops the whole window on a mismatch (S3)                   -> [tag|count]
#   M10 the sample tick wraps at 1124: 48.04 kHz (S2)                          -> [sync]
#   M11 a pair is 16 eighth-ticks, not 15 (S1)                                 -> [start|drop]
#   M12 release without a frame buffered: the start underruns (S3)             -> [count]
#   M13 the sample tick runs through a pause (S7)                              -> [pause]
#   M14 the gate decides while frozen: the pre-anchor discard runs (S8)        -> [pause]
#   M15 a left item's frames not discarded (S9)                                -> [left|live]
#   M16 no stall breaker: the early audio waits forever (S10)                  -> [live|yield]
#   M17 the ring loses the item tag (S11)                                      -> [tag]
#   M18 the realign keeps an old-track payload in flight (S12)                 -> [tag|pcm|count|switch]
#   M19 the new track forwarded from its first PES byte, mid-AU (S12)          -> [tag|pcm|count|switch]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}
DISC="Akira (PSP Video).iso"
RTL="umd/sfifo.sv umd/ps_demux.sv umd/aud_ring.sv umd/aud_out.sv umd/at3p/at3p_seq.sv umd/at3p/at3p_vec.sv umd/at3p/at3p_top.sv"
TB=bench/umd/av_sync_tb.sv
mkdir -p "$GEN"

if [ ! -f "$ISO/$DISC" ]; then echo "SKIP: no $DISC in $ISO"; exit 0; fi

echo "== GREEN: goldens =="
for s in disc split garbage deadlock switch; do
  python3 tools/av_sync_golden.py --disc "$ISO/$DISC" --aus 8 --stream $s --out "$GEN/avs_$s" \
      > "$GEN/avs_$s.golden.log" 2>&1 &
done
wait
for s in disc split garbage deadlock switch; do
  if [ -f "$GEN/avs_$s.meta" ] && grep -q "first PTS" "$GEN/avs_$s.golden.log"; then
    echo "  $s: $(tail -1 "$GEN/avs_$s.golden.log" | sed "s|^$GEN/||" | cut -c1-150)"
  else echo "  FAIL golden $s: $(tail -2 "$GEN/avs_$s.golden.log")"; fail=1; fi
done
[ $fail = 0 ] || { echo "== FAILURES =="; exit 1; }

# arm | stream | ring AW | sim args
ARMS=(
  "S1|disc|15|+anchor_vb=32768 +anchor_ofs=5000"
  "S2|split|15|+anchor_vb=2048 +anchor_ofs=-9000"
  "S3|garbage|15|+anchor_vb=2048 +anchor_ofs=0"
  "S4|split|15|+anchor_vb=2048 +anchor_ofs=0 +dstall_at=3000 +dstall_len=4000000 +exp_under=1 +min_played=2048"
  "S5|deadlock|11|+anchor_vb=4096 +anchor_ofs=12754 +exp_pre=1 +min_played=2048"
  "S6|split|15|+anchor_vb=2048 +anchor_ofs=0 +jump_frame=2 +jump=9000 +exp_resync=1 +min_played=2048"
  "S7|split|15|+anchor_vb=2048 +anchor_ofs=0 +pause_frame=2 +pause_len=6000000 +min_played=2048"
  "S8|deadlock|11|+anchor_vb=4096 +anchor_ofs=12754 +exp_pre=1 +min_played=2048 +pause_at0=3000000"
  "S9|split|15|+anchor_vb=2048 +anchor_ofs=0 +left_frame=2 +min_played=2048"
  "S10|split|11|+anchor_vb=2048 +anchor_ofs=-900000 +vstall +exp_yield +min_played=0"
  "S11|split|15|+anchor_vb=2048 +anchor_ofs=-9000 +ep_in=1"
  "S12|switch|11|+anchor_vb=2048 +anchor_ofs=0 +switch_frame=2"
)

build() {   # dir -> sims sim15 / sim11 inside it
  local d=$1
  # shellcheck disable=SC2086
  (cd "$d" && iverilog -g2012 -o sim15 $RTL $TB 2>>build.log && \
              iverilog -g2012 -P av_sync_tb.RING_AW=11 -o sim11 $RTL $TB 2>>build.log)
}
run_arm() {   # dir arm-line -> dir/<arm>.log
  local d=$1 name stream aw args
  IFS='|' read -r name stream aw args <<<"$2"
  # shellcheck disable=SC2086
  (cd "$d" && vvp -n "sim$aw" +stem="$ROOT/$GEN/avs_$stream" $args 2>&1 | grep -v 'readmem\|Not enough' > "$name.log")
}

echo "== GREEN: the chain =="
build . || { echo "  FAIL build: $(head -3 build.log)"; exit 1; }
mv sim15 sim11 .sim/ 2>/dev/null; rm -f build.log
for a in "${ARMS[@]}"; do
  IFS='|' read -r name stream aw args <<<"$a"
  # shellcheck disable=SC2086
  vvp -n ".sim/sim$aw" +stem="$ROOT/$GEN/avs_$stream" $args 2>&1 | grep -v 'readmem\|Not enough' > ".sim/avs_$name.log" &
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  if grep -q "^PASS: av_sync_tb" ".sim/avs_$name.log"; then
    echo "  PASS $name: $(grep '^av_sync_tb:' ".sim/avs_$name.log" | sed 's/^av_sync_tb: //')"
  else echo "  FAIL $name: $(grep -m1 FAIL ".sim/avs_$name.log")"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  arm_line() { for a in "${ARMS[@]}"; do [ "${a%%|*}" = "$1" ] && echo "$a"; done; }
  mut() {   # name file old new arm-pattern arm
    local name=$1 file=$2 old=$3 new=$4 pat=$5 arm=$6
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/at3p" "$d/bench/umd"
    cp umd/sfifo.sv umd/ps_demux.sv umd/aud_ring.sv umd/aud_out.sv "$d/umd/"
    cp umd/at3p/*.sv umd/at3p/*.svh umd/at3p/*.mem "$d/umd/at3p/"
    cp $TB "$d/bench/umd/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # compile and run from inside the copy: `include and $readmemh resolve there
    if [ $? != 0 ] || ! build "$d"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    run_arm "$d" "$(arm_line "$arm")"
    if grep -q "^PASS: av_sync_tb" "$d/$arm.log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL $pat" "$d/$arm.log"; then
      echo "  $name: caught by $arm $(grep -m1 -E "FAIL $pat" "$d/$arm.log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/$arm.log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  R=umd/aud_ring.sv; O=umd/aud_out.sv
  mut M1 $R "wire [32:0] t_pts    = pend_v ? pend_pts : next_pts;" \
            "wire [32:0] t_pts    = (in_frame_start && in_pts_valid) ? in_pts : pend_v ? pend_pts : next_pts;" '\[tag\]' S2 &
  mut M2 $R "localparam [32:0] AU_TICKS = 33'd3840;" "localparam [32:0] AU_TICKS = 33'd3841;" '\[tag\]' S2 &
  mut M3 $R "assign in_ready = !byte_full && !tag_full;" "assign in_ready = 1'b1;" '\[(tag|pcm|count|live)\]' S5 &
  mut M4 $O "else if (d >= 36'sd0 && buffered) release_now = 1'b1;" "else if (d >= -36'sd960) release_now = 1'b1;" '\[start\]' S2 &
  wait
  mut M5 $O "end else if (h_valid && !stc_run && ring_blocked && pcm_full) begin" \
            "end else if (1'b0) begin" '\[live\]' S5 &
  mut M6 $O "if (!h_valid)                 rearm_u  = 1'b1;" "if (!h_valid)                 rearm_u  = 1'b0;" '\[count\]' S4 &
  mut M7 $O "wire        far    = (d > THR_Q3) || (d < -THR_Q3);" "wire        far    = 1'b0;" '\[sync\]' S6 &
  mut M8 $R "wire [13:0] flen     = {par_sz, 3'b000} + 14'd8;" "wire [13:0] flen     = {par_sz, 3'b000};" '\[(tag|count)\]' S1 &
  wait
  mut M9 $R "win_hi <= in_byte;              // slide one byte" "fst <= F_SYNC0;" '\[(tag|count)\]' S3 &
  mut M10 $O "end else if (nco >= 11'd1123) begin
            nco <= nco - 11'd1123; sample_tick <= 1'b1;" "end else if (nco >= 11'd1122) begin
            nco <= nco - 11'd1122; sample_tick <= 1'b1;" '\[sync\]' S2 &
  mut M12 $O "wire  buffered = (fill >= MIN_FILL_W) || (&dry_tmr);" "wire  buffered = 1'b1;" '\[count\]' S3 &
  mut M11 $O "({21'd0, ridx, 4'b0000} - {25'd0, ridx})" "{21'd0, ridx, 4'b0000}" '\[(start|drop)\]' S1 &
  wait
  mut M13 $O "end else if (freeze) begin
            sample_tick <= 1'b0;" "end else if (1'b0) begin
            sample_tick <= 1'b0;" '\[pause\]' S7 &
  mut M14 $O "            if (freeze) begin
            end else if (h_left) begin" "            if (1'b0) begin
            end else if (h_left) begin" '\[pause\]' S8 &
  mut M15 $O "            end else if (h_left) begin
                discard = 1'b1; d_left = 1'b1;" "            end else if (1'b0) begin
                discard = 1'b1; d_left = 1'b1;" '\[(left|live)\]' S9 &
  mut M16 $O "else if (d < 36'sd0 && ring_blocked && pcm_full && vid_stalled) begin" "else if (1'b0) begin" '\[(live|yield)\]' S10 &
  mut M17 $R "wire [1:0]  t_ep     = pend_v ? pend_ep : last_ep;" "wire [1:0]  t_ep     = 2'd0;" '\[tag\]' S11 &
  D=umd/ps_demux.sv
  mut M18 $D "            if (state == S_AUDIO_DATA) begin
                if (consume && pes_length == 16'd1)" "            if (1'b0) begin
                if (consume && pes_length == 16'd1)" '\[(tag|pcm|count|switch)\]' S12 &
  mut M19 $D "if (!(rlgn_pend || aud_realign)) begin" "if (1'b1) begin" '\[(tag|pcm|count|switch)\]' S12 &
  wait
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
