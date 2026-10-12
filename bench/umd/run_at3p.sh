#!/usr/bin/env bash
# run_at3p.sh -- the ATRAC3plus decoder gate (umd/at3p/at3p_top.sv = at3p_seq + at3p_vec,
# bench/umd/at3p_top_tb.sv; goldens tools/at3p_top_golden.py <- the emulator
# tools/at3p_isa.py, itself checked against tools/at3p_fixed.py and tools/at3p_ref.py).
# docs/at3p_decoder.md S5.
#
# GREEN (every vector op's buffers by checksum, every PCM pair bit-exact, the counts):
#   A1 Akira 0x4855        big gain boosts, tones in both regions, swapped subbands
#   A2 Godzilla 0x483F     steep windows beside gain points, noise in swapped subbands
#   A3 Goo Goo Dolls 0x487F gain boosts, tones in both regions
#   A4 Ace Ventura 0x487F  negated subbands, noise in swapped subbands, tones
#   A5 The Animatrix 0x482A
#   A6 mute                the mute flag set in a real frame (no disc sets it)
#   A7 refuse              a mono unit: refused, 2,048 silent pairs, the stream goes on
#   A8 stalls              A1 with input gaps (up to 40 cycles a byte) and PCM back-pressure
#                          (up to 60 a pair): gaps longer than the decoder's own byte and pair
#                          spacing, so it does wait (3 / 7 changed no cycle count)
#   A9  28 Days Later      a tone envelope's start point (RZERO, the +32 Hann ramp)
#   A10 28 Days Later      a tone envelope's stop point (the -32 ramp, RZERO)
#   A11 28 Days Later      an inverted tone phase (RSAT invert)
#   (A1-A5: tools/at3p_pick.py; A9-A11: tools/at3p_scan.py's first frames of the modes
#   the others miss (tools/at3p_vop_tally.py); each starts a frame early)
#
# --red [MUTS="V1 V4" to run only those]: mutations on a COPY of the RTL, each caught by its own arm (on A1 unless named):
#   V1  the rounding shifter truncates              -> [vop]
#   V2  DQ ignores a negative shift (large scale factors) -> [vop]
#   V3  the IMDCT does not reverse odd subbands      -> [vop]
#   V4  a steep window's flat quarter is zero (A2)   -> [vop]
#   V5  the IMDCT output's high half enters unshifted -> [vop]
#   V6  the IPQF history never advances              -> [pcm]
#   V7  the oscillator starts at the wrong phase     -> [vop]
#   V8  the noise table index ignores rng (A4)       -> [vop]
#   V9  the Huffman walk forgets to double `first`   -> [vop] / [pcm] (a hole: the
#       frame is refused and its silence is the first thing that differs)
#   V10 sext by a register keeps the sign bit wrong  -> [vop]
#   V11 PCMZ emits 2,047 pairs (A7)                  -> [count] / [pcm] (every later
#       pair shifts by one)
#   V12 the IPQF DCT's second half is not negated    -> [pcm]
#   V13 the gain exponent's quarter step is ignored  -> [vop]
#   V14 NZ adds to zero, not to the residual (A4)    -> [vop]
#   (A1's window has no noise fill: V8 and V14 survived there, so they run on A4)
#   V15 RSAT ignores invert (A11)                    -> [vop]
#   V16 RWIN steps its Hann index by 1 always (A10)  -> [vop]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}
RTL="umd/at3p/at3p_seq.sv umd/at3p/at3p_vec.sv umd/at3p/at3p_top.sv"
TB=bench/umd/at3p_top_tb.sv
mkdir -p "$GEN"

echo "== GREEN: the microcode and tables are current =="
python3 tools/at3p_isa.py --asm --check | sed 's/^/  /' || fail=1

# arm name | disc | clip | skip | aus | extra golden args | extra sim args
ARMS=(
  "A1|Akira (PSP Video).iso|-|2365|4||"
  "A2|Godzilla (PSP Video).ISO|-|95|4||"
  "A3|Goo Goo Dolls - Live in Alaska (2005).ISO|-|3898|4||"
  "A4|Ace Ventura - Pet Detective (1994).ISO|-|447|4||"
  "A5|The Animatrix (2003).ISO|1|1000|3||"
  "A6|Akira (PSP Video).iso|-|2365|3|--mute 1|"
  "A7|Akira (PSP Video).iso|-|2365|3|--refuse 1|"
  "A8|Akira (PSP Video).iso|-|2365|4||+stall=40 +ostall=60"
  "A9|28 Days Later (2002).ISO|1|627|3||"
  "A10|28 Days Later (2002).ISO|1|670|3||"
  "A11|28 Days Later (2002).ISO|1|58699|3||"
)

echo "== GREEN: goldens =="
declare -A STEM SIMARGS
for a in "${ARMS[@]}"; do
  IFS='|' read -r name disc clip skip aus gx sx <<<"$a"
  stem="$GEN/at3p_$name"
  STEM[$name]=$stem; SIMARGS[$name]=$sx
  [ "$name" = "A8" ] && { STEM[$name]=$GEN/at3p_A1; continue; }
  if [ ! -f "$ISO/$disc" ]; then echo "  SKIP $name: no $disc"; STEM[$name]=; continue; fi
  cl=""; [ "$clip" != "-" ] && cl="--clip $clip"
  # shellcheck disable=SC2086
  python3 tools/at3p_top_golden.py --disc "$ISO/$disc" $cl --skip "$skip" --aus "$aus" $gx \
      --out "$stem" > "$stem.golden.log" 2>&1 &
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] || [ "$name" = "A8" ] && continue
  if [ -f "${STEM[$name]}.meta" ] && grep -q "matches the fixed model" "${STEM[$name]}.golden.log"; then
    echo "  $name: $(tail -1 "${STEM[$name]}.golden.log" | cut -c1-150)"
  else echo "  FAIL $name golden: $(tail -2 "${STEM[$name]}.golden.log")"; fail=1; STEM[$name]=; fi
done

# shellcheck disable=SC2086
iverilog -g2012 -o .sim/at3p_sim $RTL $TB 2>&1 | grep -v "sorry" | grep . && { echo "  FAIL build"; exit 1; }

run_arm() {   # sim name -> log .sim/at3p_<name>.log
  local sim=$1 name=$2
  # shellcheck disable=SC2086
  vvp -n "$sim" +stem="$ROOT/${STEM[$name]}" ${SIMARGS[$name]} 2>&1 | grep -v 'readmem\|Not enough' \
      > ".sim/at3p_${name}.log"
}
echo "== GREEN: the decoder =="
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -n "${STEM[$name]}" ] && run_arm .sim/at3p_sim "$name" &
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if grep -q "^PASS: at3p_top_tb" ".sim/at3p_${name}.log"; then
    echo "  PASS $name: $(grep '^at3p_top_tb:' ".sim/at3p_${name}.log" | sed 's/^at3p_top_tb: //')"
  else echo "  FAIL $name: $(grep -m1 FAIL ".sim/at3p_${name}.log")"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arm-pattern arm
    local name=$1 file=$2 old=$3 new=$4 pat=$5 arm=${6:-A1}
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi   # MUTS="V1 V4": only those
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/at3p" "$d/bench/umd"
    cp umd/at3p/*.sv umd/at3p/*.svh umd/at3p/*.mem "$d/umd/at3p/"
    cp $TB "$d/bench/umd/"
    python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    # compile and run from inside the copy: `include and $readmemh resolve there
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    # shellcheck disable=SC2086
    (cd "$d" && vvp -n sim +stem="$ROOT/${STEM[$arm]}" ${SIMARGS[$arm]} 2>&1 | grep -v 'readmem\|Not enough' > log)
    if grep -q "^PASS: at3p_top_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL $pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL $pat" "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  S=umd/at3p/at3p_seq.sv; V=umd/at3p/at3p_vec.sv
  mut V1 $V "rnd  = (x_rsh == 6'd0) ? rsrc : ((rsrc + (64'sd1 <<< (x_rsh - 6'd1))) >>> x_rsh);" "rnd  = rsrc >>> x_rsh;" '\[vop\]' &
  mut V2 $V "<<< qneg[5:0])" "<<< 0)" '\[vop\]' &
  mut V3 $V "xb_ra = a0[0] ? 7'd127 - k[6:0] : k[6:0];" "xb_ra = k[6:0];" '\[vop\]' &
  mut V4 $V "                else                wfl = 1'b1;" "                else                wze = 1'b1;" '\[vop\]' A2 &
  wait
  mut V5 $V "mb = mfac; p_sh20 = 1'b1;" "mb = mfac; p_sh20 = 1'b0;" '\[vop\]' &
  mut V6 $V "pos0 <= (pos0 == 5'd0) ? 5'd23 : pos0 - 5'd1;" "pos0 <= pos0;" '\[pcm\]' &
  mut V7 $V "- ((args[79:64] == 16'd0) ? {args[19:16], 7'd0} : 11'd0);" ";" '\[vop\]' &
  mut V8 $V "nz_ra = a0[9:0] + k[9:0];" "nz_ra = k[9:0];" '\[vop\]' A4 &
  wait
  mut V9 $S "v_first <= (v_first + {3'd0, v_cnt}) << 1;" "v_first <= v_first + {3'd0, v_cnt};" '\[(vop|pcm)\]' &
  mut V10 $S "sx_top = sx_mask & ~(sx_mask >> 1);" "sx_top = sx_mask & ~(sx_mask >> 2);" '\[vop\]' &
  mut V11 $V "if (k == 12'd2048) st <= V_DONE;" "if (k == 12'd2047) st <= V_DONE;" '\[(count|pcm)\]' A7 &
  mut V12 $V "mb = j[3] ? -cosv : cosv;" "mb = cosv;" '\[pcm\]' &
  wait
  mut V13 $V "mb = \$signed(f4[e_rdata[1:0]]); rsh = 6'd25;" "mb = \$signed(f4[2'd0]); rsh = 6'd25;" '\[vop\]' &
  mut V14 $V "addend = \$signed({{24{xb_q[39]}}, xb_q});" "addend = 64'sd0;" '\[vop\]' A4 &
  mut V15 $V "dsrc = a1[0] ? -rsat1 : rsat1;" "dsrc = rsat1;" '\[vop\]' A11 &
  mut V16 $V "if (vop == OP_RWIN) hj <= hj + a4[7:0];" "if (vop == OP_RWIN) hj <= hj + 8'd1;" '\[vop\]' A10 &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
