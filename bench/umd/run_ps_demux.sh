#!/usr/bin/env bash
# run_ps_demux.sh -- the P2 demux gate (umd/ps_stream_fifo.sv + umd/ps_demux.sv,
# bench/umd/ps_demux_tb.sv; goldens tools/psmf_golden.py <- tools/psmf_ref.py)
#
# GREEN:
#   * the synthetic streams of tools/umd_demux_cases.py (every path the P2 surgery
#     touched, incl. the ones no disc window is sure to hit);
#   * per disc in ${UMD_ISO_DIR:-~/umd-isos}: the main clip's first 120 packs (lowest
#     declared audio track) and, when the clip has a subtitle EP map, 120 packs around
#     its first subtitle unit with that track selected. SKIP, loudly, without images,
#     and per disc when a window is all zero bytes (a damaged image: Desperado).
# Each run must print the PASS marker.
#
# --red: mutations on a COPY of ps_demux.sv, each caught by its own arm on the synthetic
# streams (no media needed) -- per substream class:
#   D1  video stream id 0xE0 not recognised             -> [video]
#   D2  audio track compared on 3 bits (0x0D -> 0x05)   -> [audio]
#   D3  FAP taken 1-based (the DVD AC-3 convention)     -> [audio]
#   D4  aud_frame_start on every audio byte             -> [amark]
#   D5  subtitles 0x80-0x8F only                        -> [sub]
#   D6  subtitle sub-header 1 byte, not 2               -> [sub]
#   D7  vid_mark never armed                            -> [vmark]
#   D8  0xBF hunted through instead of skipped          -> [video]
#   D9  pes_hdr_ok armed for every PES of a pack        -> [stats]
#   D10 realign not armed out of reset                  -> [amark] (the stray first PES
#   D11 the video PTS's item tag latched as 0 (P6b3i)            -> [ep]
#   D12 the audio PTS's item tag latched as 0 (P6b3i)            -> [ep]
#   D13 the audio's item tag cleared every cycle (the rig's bug)  -> [ep]
#   D14 (P8) the subtitle tap never pulses                       -> [taps]
#   D15 (P8) the subtitle tap blind to 0x90-0x9F                  -> [taps] (0x9C)
#       opens with the same 8-byte AU header bytes; its PTS is what differs first)
# and on a COPY of es_probe.sv:
#   P1  CRC polynomial 0x04C11DB7 unreflected           -> [probe]
#   P2  the rate window loses its last cycle's pulse    -> [probe]
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
SRC="umd/ps_stream_fifo.sv umd/ps_demux.sv umd/es_probe.sv bench/umd/ps_demux_tb.sv"

python3 tools/umd_demux_cases.py --dir "$GEN" > .sim/demux_cases.txt || { echo "  FAIL case generation"; exit 1; }
SYN=$(cut -d' ' -f1 .sim/demux_cases.txt)

run_one() {   # sim stem -> 0 on PASS; log in .sim/demux_last.log
  vvp -n "$1" +stem="$2" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/demux_last.log
  grep -q "^PASS: ps_demux_tb" .sim/demux_last.log
}
report() {    # name
  if run_one .sim/ps_demux_sim "$GEN/$1"; then
    echo "  PASS $1: $(grep '^ps_demux_tb:' .sim/demux_last.log | sed 's/^ps_demux_tb: //')"
  else echo "  FAIL $1"; grep FAIL .sim/demux_last.log | head -3; fail=1; fi
}

# shellcheck disable=SC2086
iverilog -g2012 -o .sim/ps_demux_sim $SRC || { echo "  FAIL ps_demux_tb: build"; exit 1; }

echo "== GREEN: synthetic =="
for c in $SYN; do report "$c"; done

echo "== GREEN: disc windows (\$UMD_ISO_DIR) =="
n=0
shopt -s nullglob nocaseglob
for iso in "$ISO_DIR"/*.iso; do
  n=$((n + 1))
  python3 tools/psmf_golden.py --disc "$iso" --prefix "dmx_disc_$n" --dir "$GEN" > .sim/demux_fx.log 2>&1
  rc=$?
  if [ $rc = 3 ]; then          # an all-zero window: a damaged image, said out loud
    echo "  SKIP $(basename "$iso"): $(tail -1 .sim/demux_fx.log)"; continue
  elif [ $rc != 0 ]; then
    echo "  FAIL $(basename "$iso"): fixture: $(tail -1 .sim/demux_fx.log)"; fail=1; continue
  fi
  echo "  -- $(basename "$iso")"
  for w in $(cat .sim/demux_fx.log); do report "$w"; done
done
shopt -u nullglob nocaseglob
[ $n = 0 ] && echo "  SKIP: no disc image in $ISO_DIR (set UMD_ISO_DIR)"

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name old new arm-pattern
    local name=$1 old=$2 new=$3 pat=$4
    local d; d=$(mktemp -d)
    python3 - "$d" "$old" "$new" <<'PYEOF'
import sys, os
d, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open("umd/ps_demux.sv").read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(os.path.join(d, "ps_demux.sv"), "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" umd/ps_stream_fifo.sv "$d/ps_demux.sv" umd/es_probe.sv bench/umd/ps_demux_tb.sv 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local c caught=""
    for c in $SYN; do
      vvp -n "$d/sim" +stem="$GEN/$c" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
      if ! grep -q "^PASS: ps_demux_tb" "$d/log"; then caught=$c; break; fi
    done
    if [ -z "$caught" ]; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL $pat" "$d/log"; then
      echo "  $name: caught on $caught by $(grep -m1 "FAIL $pat" "$d/log" | cut -c1-72)" > "$RES/$name"
    else
      { echo "  $name: failed on $caught but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut D1 "if (in_byte == 8'hE0 || in_byte == 8'hBD)" "if (in_byte == 8'hE1 || in_byte == 8'hBD)" '\[video\]' &
  mut D2 "in_byte[7:4] == 4'h0 && in_byte[3:0] == aud_track" "in_byte[7:4] == 4'h0 && in_byte[2:0] == aud_track[2:0]" '\[audio\]' &
  mut D3 "bytes_remaining <= fap;" "bytes_remaining <= fap - 16'd1;" '\[audio\]' &
  mut D4 "assign aud_frame_start = (state == S_AUDIO_DATA) && in_valid && first_aud_byte;" "assign aud_frame_start = (state == S_AUDIO_DATA) && in_valid;" '\[amark\]' &
  mut D5 "else if (in_byte[7:5] == 3'b100) begin" "else if (in_byte[7:4] == 4'h8) begin" '\[sub\]' &
  wait
  mut D6 "                        state <= S_SP_SUBHDR;" "                        begin first_sp_byte <= 1'b1; state <= S_SP_DATA; end" '\[sub\]' &
  mut D7 "mark_pending  <= (pes_length != 16'd1);" "mark_pending  <= 1'b0;" '\[vmark\]' &
  mut D8 "                    else if (in_byte >= 8'hBB)\n" "                    else if (in_byte >= 8'hBB && in_byte != 8'hBF)\n" '\[video\]' &
  mut D9 "                pack_fresh <= 1'b0;\n" "\n" '\[stats\]' &
  mut D10 "rlgn_pend      <= 1'b1;     // UMD" "rlgn_pend      <= 1'b0;     // UMD" '\[amark\]' &
  mut D11 "vid_ep  <= in_ep;" "vid_ep  <= 2'd0;" '\[ep\]' &
  mut D12 "aud_ep  <= in_ep;   // P6b3i" "aud_ep  <= 2'd0;   // P6b3i" '\[ep\]' &
  mut D13 "        aud_pts_valid <= 1'b0;
        pes_hdr_ok    <= 1'b0;" "        aud_pts_valid <= 1'b0;
        aud_ep        <= 2'd0;
        pes_hdr_ok    <= 1'b0;" '\[ep\]' &
  mut D14 "        sub_ss_seen <= consume && obs_bd_sub;" "        sub_ss_seen <= 1'b0;" '\[taps\]' &
  mut D15 "                  (in_byte[7:5] == 3'b100);" "                  (in_byte[7:4] == 4'h8);" '\[taps\]' &
  pmut() {  # name old new -- es_probe mutations (the disc windows hold > 64 KiB of video)
    local name=$1 old=$2 new=$3 d; d=$(mktemp -d)
    python3 - "$d" "$old" "$new" <<'PYEOF'
import sys, os
d, old, new = sys.argv[1:4]
s = open("umd/es_probe.sv").read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(os.path.join(d, "es_probe.sv"), "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" umd/ps_stream_fifo.sv umd/ps_demux.sv "$d/es_probe.sv" bench/umd/ps_demux_tb.sv 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    vvp -n "$d/sim" +stem="$GEN/dmx_syn_ps" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: ps_demux_tb" "$d/log"; then { echo "  $name: SURVIVED"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL \[probe\]" "$d/log"; then echo "  $name: caught by $(grep -m1 'FAIL \[probe\]' "$d/log" | cut -c1-72)" > "$RES/$name"
    else { echo "  $name: failed but NOT in [probe]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"; fi
    rm -rf "$d"
  }
  pmut P1 "32'hEDB88320" "32'h04C11DB7" &
  pmut P2 "pes_rate <= pes_cnt + {15'd0, pes_hdr_ok};" "pes_rate <= pes_cnt;" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
