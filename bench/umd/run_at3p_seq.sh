#!/usr/bin/env bash
# run_at3p_seq.sh -- the ATRAC3plus sequencer gate (umd/at3p/at3p_seq.sv, bench/umd/
# at3p_seq_tb.sv; goldens tools/at3p_seq_golden.py <- the emulator tools/at3p_isa.py,
# itself checked against tools/at3p_ref.py's parse on the same AUs). docs/at3p_decoder.md S5.
#
# GREEN: every register write and store, in program order, identical to the emulator:
#   S1 Akira, 6 AUs (the parse and the synthesis control, a stub vector engine)
#   S2 Goo Goo Dolls, 6 AUs with random input gaps (+stall=40: longer than its byte spacing)
#   S3 Godzilla (0x483F), 6 AUs
#
# --red [MUTS="V1 V4" to run only those]: mutations on a COPY of the RTL, each caught by its own arm (on S1):
#   Q1  ALU sub computes add                   -> [trace]
#   Q2  a signed compare taken unsigned        -> [trace]
#   Q3  the bit reader serves the byte's LSB first -> [trace]
#   Q4  the Huffman count read one length late -> [trace] / [hang]
#   Q5  RET returns to the call, not after it  -> [trace] / [hang]
#   Q6  BLEFT counts bytes, not bits           -> [trace]
#   Q7  a load returns the address, not the data -> [trace]
#   Q8  FEND drains one byte short             -> [trace]
set -u
cd "$(dirname "$0")/../.."
ROOT=$(pwd)
mkdir -p .sim
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}
RTL=umd/at3p/at3p_seq.sv
TB=bench/umd/at3p_seq_tb.sv
mkdir -p "$GEN"

ARMS=(
  "S1|Akira (PSP Video).iso|2000|6|"
  "S2|Goo Goo Dolls - Live in Alaska (2005).ISO|3898|6|+stall=40"
  "S3|Godzilla (PSP Video).ISO|95|6|"
)
declare -A STEM SIMARGS
echo "== GREEN: goldens =="
for a in "${ARMS[@]}"; do
  IFS='|' read -r name disc skip aus sx <<<"$a"
  STEM[$name]=$GEN/at3p_seq_$name; SIMARGS[$name]=$sx
  if [ ! -f "$ISO/$disc" ]; then echo "  SKIP $name: no $disc"; STEM[$name]=; continue; fi
  python3 tools/at3p_seq_golden.py --disc "$ISO/$disc" --skip "$skip" --aus "$aus" \
      --out "${STEM[$name]}" > "${STEM[$name]}.golden.log" 2>&1 &
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if grep -q "matches the model" "${STEM[$name]}.golden.log"; then
    echo "  $name: $(tail -1 "${STEM[$name]}.golden.log" | cut -c1-140)"
  else echo "  FAIL $name golden: $(tail -1 "${STEM[$name]}.golden.log")"; fail=1; STEM[$name]=; fi
done

iverilog -g2012 -o .sim/at3p_seq_sim $RTL $TB 2>&1 | grep -v "sorry" | grep . && { echo "  FAIL build"; exit 1; }
echo "== GREEN: the sequencer =="
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  # shellcheck disable=SC2086
  vvp -n .sim/at3p_seq_sim +stem="${STEM[$name]}" ${SIMARGS[$name]} 2>&1 \
      | grep -v 'readmem\|Not enough' > ".sim/at3p_seq_$name.log" &
done
wait
for a in "${ARMS[@]}"; do
  IFS='|' read -r name _ <<<"$a"
  [ -z "${STEM[$name]}" ] && continue
  if grep -q "^PASS: at3p_seq_tb" ".sim/at3p_seq_$name.log"; then
    echo "  PASS $name: $(grep '^at3p_seq_tb:' ".sim/at3p_seq_$name.log" | sed 's/^at3p_seq_tb: //')"
  else echo "  FAIL $name: $(grep -m1 FAIL ".sim/at3p_seq_$name.log")"; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  mut() {   # name old new arm-pattern
    local name=$1 old=$2 new=$3 pat=$4
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi   # MUTS="V1 V4": only those
    local d; d=$(mktemp -d)
    mkdir -p "$d/umd/at3p" "$d/bench/umd"
    cp umd/at3p/*.sv umd/at3p/*.svh umd/at3p/*.mem "$d/umd/at3p/"
    cp $TB "$d/bench/umd/"
    python3 - "$d/$RTL" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! (cd "$d" && iverilog -g2012 -o sim $RTL $TB 2>build.log); then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    (cd "$d" && timeout 600 vvp -n sim +stem="$ROOT/${STEM[S1]}" 2>&1 | grep -v 'readmem\|Not enough' > log)
    if grep -q "^PASS: at3p_seq_tb" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -qE "FAIL $pat" "$d/log"; then
      echo "  $name: caught by $(grep -m1 -E "FAIL $pat" "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in the expected arm ($pat):"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  mut Q1 "5'd1:  alu_y = vrs - alu_b;" "5'd1:  alu_y = vrs + alu_b;" '\[trace\]' &
  mut Q2 "wire        br_lt = \$signed(vrs) < \$signed(br_b);" "wire        br_lt = vrs < br_b;" '\[trace\]' &
  mut Q3 "bit_ok = 1'b1; bit_val = cur[cur_n - 4'd1];" "bit_ok = 1'b1; bit_val = cur[4'd8 - cur_n];" '\[trace\]' &
  mut Q4 "v_len <= v_len + 4'd1;" "v_len <= v_len + 4'd2;" '\[(trace|hang)\]' &
  wait
  mut Q5 "O_CALL: begin stack[sp] <= pc + 12'd1;" "O_CALL: begin stack[sp] <= pc;" '\[(trace|hang)\]' &
  mut Q6 "wire [17:0] bl_raw  = {1'b0, fbytes, 3'd0} - {1'b0, fbits};" "wire [17:0] bl_raw  = {3'd0, fbytes} - {1'b0, fbits};" '\[trace\]' &
  mut Q7 "S_LD: begin w_en = 1'b1; w_val = ld_const ? crom_q : rec_q; end" "S_LD: begin w_en = 1'b1; w_val = maddr; end" '\[trace\]' &
  mut Q8 "in_ready = ftaken != fbytes;" "in_ready = ftaken + 16'd1 < fbytes;" '\[(trace|hang)\]' &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
