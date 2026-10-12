#!/usr/bin/env bash
# run_nav_model.sh -- N1's gate (docs/nav_engine.md S5): the navigation engine's program
# (umd/nav/nav.uasm) on its emulator (tools/nav_isa.py), scored on the SAME fixtures and with the
# same checks as the reader's RTL bench (run_umd_reader.sh, bench/umd/umd_reader_tb.sv): every
# synthetic case of tools/umd_reader_cases.py, and per disc image under ${UMD_ISO_DIR:-~/umd-isos}
# its --nav fixture (the same seed: the navigation script is the RTL bench's) and its two bare
# files (P8). Goldens from the P1 parsers and tools/umd_nav_ref.py, never from the engine.
#
# The arms are umd_reader_tb's, those that are the program's: [walk] [order] [sniff] [pick]
# [bare] [title] [stream] [done] [tracks] [clip] [base] [nav] [err] [thrash] [seek] [time]
# [play] [chap]. [hold] and +restart are the pump's (hardware): N2's RTL bench keeps them.
# Each line also reports the longest stretch of engine cycles between two of its sector reads:
# docs/nav_engine.md S2's bound is one sector read (~21,600 clk_sys cycles).
#
#   bench/umd/run_nav_model.sh [--red]      (UMD_JOBS discs at a time, default 6)
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/navm
GEN=bench/umd/fixtures/gen
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
JOBS=${UMD_JOBS:-6}
red=0; [ "${1:-}" = "--red" ] && red=1
fail=0

python3 tools/nav_isa.py --asm umd/nav/nav.uasm -o umd/nav/nav_ucode.mem || { echo "  FAIL assembly"; exit 1; }
python3 tools/umd_reader_cases.py --dir "$GEN" > .sim/navm/cases.txt || { echo "  FAIL case generation"; exit 1; }
SYN=$(cat .sim/navm/cases.txt)

disc_job() {   # n iso -> .sim/navm/disc_<n>.sum
  local n=$1 iso=$2 L=.sim/navm/disc_$1 seed stems="" b rc
  seed=$(basename "$iso" | cksum | cut -d' ' -f1)
  {
    if ! python3 tools/umd_fixture.py "$iso" --nav --stream-packs 64 --nav-seed "$seed" \
           --out "disc_$n" --dir "$GEN" > "$L.fx" 2>&1; then
      echo "  FAIL $(basename "$iso"): fixture: $(tail -1 "$L.fx")"; exit 1
    fi
    stems="$GEN/disc_$n"
    for b in mps pmf; do
      if [ $b = mps ]; then python3 tools/umd_fixture.py "$iso" --bare-mps 64 --out "discb${b}_$n" --dir "$GEN" > "$L.$b.fx" 2>&1
      else python3 tools/umd_fixture.py "$iso" --bare-pmf --out "discb${b}_$n" --dir "$GEN" > "$L.$b.fx" 2>&1; fi
      rc=$?
      if [ $rc = 0 ]; then stems="$stems $GEN/discb${b}_$n"
      elif [ $rc != 3 ]; then echo "  FAIL bare $b fixture: $(tail -1 "$L.$b.fx")"; fi
    done
    # shellcheck disable=SC2086
    python3 tools/nav_isa.py --fixture $stems 2>&1 | sed "s/^/  $(basename "$iso" | sed 's/[&/\]/\\&/g'): /"
  } > "$L.sum"
}

throttle() { while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done; }
rm -f .sim/navm/*.sum
# shellcheck disable=SC2086
python3 tools/nav_isa.py --fixture $(for c in $SYN; do echo "$GEN/$c"; done) > .sim/navm/syn.sum 2>&1 &
mapfile -t ISOS < <(find "$ISO_DIR" -type f -iname '*.iso' 2>/dev/null | sort)
n=0
for iso in "${ISOS[@]}"; do n=$((n + 1)); throttle; disc_job "$n" "$iso" & done
wait
echo "== GREEN: synthetic =="
sed 's/^/  /' .sim/navm/syn.sum
grep -qv "^PASS" .sim/navm/syn.sum && fail=1
echo "== GREEN: disc images in \$UMD_ISO_DIR =="
for k in $(seq 1 $n); do cat ".sim/navm/disc_$k.sum"; done
[ $n -gt 0 ] && grep -q "FAIL" .sim/navm/disc_*.sum && fail=1
[ $n = 0 ] && echo "  SKIP: no disc image in $ISO_DIR (set UMD_ISO_DIR)"
echo "== the bound: the longest stretch between two sector reads (docs/nav_engine.md S2) =="
cat .sim/navm/syn.sum .sim/navm/disc_*.sum 2>/dev/null | grep -o "between sector reads [0-9]*" \
  | awk '{ if ($4 > m) m = $4 } END { printf "  %d cycles (bound ~21,600)\n", m; if (m > 21600) exit 1 }' || fail=1

if [ $red = 1 ]; then
  echo "== MUTATIONS of the program (each must be caught by its own arm; the RTL bench's R* / N* / P* / T* / B* names) =="
  RES=$(mktemp -d)
  mut() {   # name  old  new  arm-pattern  fixtures...
    local name=$1 old=$2 new=$3 pat=$4; shift 4
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    local d; d=$(mktemp -d)
    if ! python3 - "$d" "$old" "$new" <<'PYEOF'
import sys, os
d, old, new = sys.argv[1:4]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
s = open("umd/nav/nav.uasm").read()
assert s.count(old) == 1, "mutation anchor not unique/found: %r" % old
open(os.path.join(d, "nav.uasm"), "w").write(s.replace(old, new))
PYEOF
    then { echo "  $name: harness failure (anchor)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return; fi
    local fx caught=""
    for fx in "$@"; do
      python3 tools/nav_isa.py --uasm "$d/nav.uasm" --fixture "$GEN/$fx" > "$d/log" 2>&1
      if ! grep -q "^PASS" "$d/log"; then caught=$fx; break; fi
    done
    if [ -z "$caught" ]; then
      { echo "  $name: SURVIVED -- the gate cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL $pat" "$d/log"; then
      echo "  $name: caught on $caught by $(grep -m1 "FAIL $pat" "$d/log" | sed 's/^[^:]*: //' | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed on $caught but NOT in the expected arm ($pat):"; grep -m1 "FAIL" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  N='\n                '
  mut R1 "sbc r5, r1, r3${N}bcc PLC_SKIP" "sbc r5, r1, r3${N}jmp PLC_SKIP" '\[pick\]' syn_basic &
  mut R2 "bnei r2, 59, FIND_NEXT" "jmp FIND_NEXT" '\[nav\]' syn_basic &
  mut R3 "li r2, 0x5449544C${N}bne r1, r2, SFO_NEXT${N}lbf r1, 4[r10], 2${N}li r2, 0x4500${N}bne r1, r2, SFO_NEXT" "ld r1, V_SFO_I[r0]${N}bnei r1, 1, SFO_NEXT" '\[title\]' syn_basic &
  mut R5 "and r1, r1, 128${N}beqi r1, 0, ITEM_ADV" "and r1, r1, 128${N}jmp ITEM_ADV" '\[stream\]' syn_basic syn_multi &
  mut R7 "shr r3, r2, 5${N}bnei r3, 4, ST_UNK" "shr r3, r2, 4${N}bnei r3, 8, ST_UNK" '\[tracks\]' syn_basic &
  mut R8 "li r1, E_NO_UMDV" "li r1, E_NOT_ISO" '\[err\]' syn_basic err_no_umdv &
  mut R9 "st r1, O_TITLE_DONE[r0]" "st r0, O_TITLE_DONE[r0]" '\[done\]' syn_basic &
  mut R11 "sne r4, r4, r0${N}add r3, r3, r4${N}st r3, V_FD_NSEC[r0]" "li r4, 1${N}add r3, r3, r4${N}st r3, V_FD_NSEC[r0]" '\[walk\]' syn_basic &
  mut R12 "lbf r1, 10[r10], 2${N}st r1, O_CLIP_END_HI[r0]${N}lbf r1, 12[r10], 4" "lbf r1, 4[r10], 2${N}st r1, O_CLIP_END_HI[r0]${N}lbf r1, 6[r10], 4" '\[clip\]' syn_basic &
  mut N1 "LK_T:           ld r1, V_IN_HI[r0]${N}ld r2, V_IN_LO[r0]" "LK_T:           li r1, 0${N}li r2, 0" '\[stream\]' syn_nav &
  mut N2 "st r2, V_CLIP_LIM[r0]${N}st r2, P_CLIP_LIM[r0]" "st r0, V_CLIP_LIM[r0]${N}st r0, P_CLIP_LIM[r0]" '\[stream\]' syn_nav &
  mut N3 "bnei r1, 0xE0, EPM_NEXT" "nop" '\[stream\]' syn_nav &
  mut N4 "sub r6, r5, r4${N}sbc r6, r0, r3                  ; C: entry < OUT${N}bcc LK2_LEFT" "sub r6, r4, r5${N}sbc r6, r3, r0${N}bcs LK2_LEFT" '\[stream\]' syn_nav &
  mut N5 "sub r6, r4, r5${N}sbc r6, r3, r0                  ; C: t < entry${N}bcs LK2_LEFT" "sub r6, r5, r4${N}sbc r6, r0, r3${N}bcc LK2_LEFT" '\[seek\]' syn_basic &
  mut N6 "LKE_START:      beqi r1, 0, LKE_GET" "LKE_START:      nop" '\(\[seek\]\|\[base\]\)' syn_nav &
  mut N7 "sbc r7, r3, r1${N}bcs LKT_ST" "sbc r7, r3, r1${N}nop" '\[seek\]' syn_nav &
  mut N8 "bnei r1, 0, S_MPS_NEXT" "nop" '\(\[seek\]\|\[base\]\)' syn_multi &
  mut N11 "bnei r1, 5, MK_NEXT" "nop" '\[chap\]' syn_nav &
  mut N12 "bgeu r2, r8, MK_NEXT" "nop" '\[chap\]' syn_nav &
  mut N13 "st r3, V_PREV_HI[r0]${N}st r4, V_PREV_LO[r0]${N}and r1, r7, 1" "and r1, r7, 1" '\[chap\]' syn_nav &
  mut N14 "sbc r6, r11, r3${N}bcc MK_NEXT" "sbc r6, r11, r3${N}bcs MK_NEXT" '\[chap\]' syn_nav &
  mut N15 "ld r10, V_BEST_MK[r0]" "ld r10, V_PL_MK[r0]" '\[chap\]' syn_basic &
  mut N17 "beqi r1, FILE_MRK, MK_OOB" "nop" '\[nav\]' syn_oobmarks &
  mut N18 "beq r1, r3, MK_HDR_OK" "jmp MK_HDR_OK" '\[chap\]' syn_badmarks &
  mut N19 "ld r1, V_OUT_HI[r0]${N}beqi r1, 0, S_LK" "jmp S_LK" '\[seek\]' syn_nav &
  mut N21 "li r1, NE_OP                    ; a reserved op: answered, nothing done${N}jmp NAV_ANSWER" "jmp NAV_RET" '\[op\]' syn_nav &
  mut N22 "SK_PASS:        st r11, V_IT_Q[r0]" "SK_PASS:        sub r11, r11, 4${N}st r11, V_IT_Q[r0]" '\[nav\]' syn_nav &
  mut N24 "S_MK:           ld r1, V_RET[r0]                ; served between stream sectors${N}bnei r1, 1, MK_0" "S_MK:           ld r1, V_RET[r0]${N}beqi r1, 3, ERR_HALT${N}bnei r1, 1, MK_0" '\[chap\]' syn_no_sfo syn_multi &
  mut N27 "sub r4, r4, 4${N}sbc r3, r3, r0" "sub r4, r4, 1${N}sbc r3, r3, r0" '\[seek\]' syn_nav &
  mut N28 "st r0, V_BASE_HI[r0]${N}st r0, V_BASE_LO[r0]${N}jmp S_SK_IT" "jmp S_SK_IT" '\[base\]' syn_nav &
  mut N29 "call BASE_ADD${N}jmp S_SK_IT" "jmp S_SK_IT" '\[base\]' syn_nav &
  mut N30 "st r8, O_ITEM_BASE_LO[r0]${N}call BASE_ADD" "st r8, O_ITEM_BASE_LO[r0]" '\[base\]' syn_multi &
  mut N31 "sbc r6, r11, r3${N}bcs MK_NEXT\nMK_SETPREV:" "sbc r6, r11, r3${N}nop\nMK_SETPREV:" '\[chap\]' syn_nav &
  mut N32 "add r4, r4, 1${N}adc r3, r3, r0" "add r4, r4, 0${N}adc r3, r3, r0" '\[chap\]' syn_nav &
  mut P2 "beqi r1, 0, PLC_LONG${N}ld r1, V_PL_K[r0]" "jmp PLC_LONG${N}ld r1, V_PL_K[r0]" '\(\[play\]\|\[stream\]\)' syn_nav &
  mut P3 "bltu r1, r2, S_SK_IT${N}st r0, V_SK_ITEM[r0]" "jmp S_SK_IT${N}st r0, V_SK_ITEM[r0]" '\[nav\]' syn_nav &
  mut P5 "beqi r2, NE_ITEM, MPS_LD" "nop" '\[play\]' syn_nav &
  mut P6 "beqi r3, 0, ITEM_END" "jmp ITEM_END" '\[play\]' syn_nav &
  mut P7 "ld r2, V_BEST_N[r0]${N}st r2, O_N_ITEMS[r0]${N}ld r1, V_SK_ITEM[r0]" "ld r2, V_BEST_N[r0]${N}ld r1, V_SK_ITEM[r0]" '\[play\]' syn_nav &
  mut P8 "st r1, V_IT_Q[r0]${N}st r0, V_BASE_HI[r0]${N}st r0, V_BASE_LO[r0]${N}ld r2, V_BEST_N[r0]" "st r1, V_IT_Q[r0]${N}ld r2, V_BEST_N[r0]" '\[play\]' syn_nav &
  mut T2 "and r7, r7, 0xFFFF${N}st r7, V_SK_HI[r0]${N}st r8, V_SK_LO[r0]${N}jmp SK_PASS" "jmp SK_PASS" '\[time\]' syn_nav &
  mut T3 "beq r9, r12, SK_LAST" "nop" '\(\[time\]\|\[nav\]\)' syn_nav &
  mut T4 "SK_LAST:        mov r7, r3                      ; past the end: the last item, at its OUT" "SK_LAST:        jmp SK_HERE" '\[time\]' syn_nav &
  mut T7 "ld r1, V_SK_TM[r0]${N}bnei r1, 0, SK_READ" "ld r1, V_SK_TM[r0]${N}nop" '\[time\]' syn_nav &
  mut B1 "SB_SKIP:        st r1, V_SK_SKIP[r0]" "SB_SKIP:        st r0, V_SK_SKIP[r0]" '\[walk\]' syn_pmf &
  mut B2 "and r1, r6, 2047${N}bnei r1, 0, SNIFF_BARE_E" "and r1, r6, 2047" '\[err\]' err_pmf_unaligned &
  mut B4 "SB_WARN:        li r1, FL_PMF_WARN" "SB_WARN:        li r1, 0" '\[bare\]' syn_pmf_cut &
  mut B6 "ld r1, V_BARE[r0]${N}bnei r1, 0, S_NAV_END" "ld r1, V_BARE[r0]" '\(\[chap\]\|\[walk\]\)' syn_bare_mps &
  mut B8 "st r9, P_CLIP_LIM[r0]" "st r0, P_CLIP_LIM[r0]" '\[walk\]' syn_pmf_short &
  mut B9 "li r1, NE_NOMAP                 ; P8: a bare stream has no map" "li r1, NE_ITEM" '\[seek\]' syn_bare_mps &
  mut B10 "li r1, 90000${N}st r0, V_IN_HI[r0]" "li r1, 0${N}st r0, V_IN_HI[r0]" '\[clip\]' syn_bare_mps &
  mut B11 "st r1, V_BEST_N[r0]${N}st r1, O_ACC_ITEMS[r0]${N}st r1, O_N_ITEMS[r0]" "st r1, O_ACC_ITEMS[r0]${N}st r1, O_N_ITEMS[r0]" '\(\[walk\]\|\[done\]\|\[stream\]\|\[nav\]\)' syn_bare_mps &
  # the program's side of the take and of item_hold, and the walk's order
  mut N26 "ld r2, I_STATE[r0]${N}bne r1, r2, ITEM_GO" "nop${N}nop" '\[hold\]' syn_multi syn_nav &
  mut A1 "st r1, V_BEST_N[r0]${N}st r1, O_ACC_ITEMS[r0]${N}ld r1, V_PL_MK[r0]" "st r1, V_BEST_N[r0]${N}ld r1, V_PL_MK[r0]" '\(\[seek\]\|\[time\]\|\[play\]\|\[stream\]\)' syn_nav &
  mut W1 "adc r1, r1, r5${N}bcc PLI_ST" "add r1, r1, r5${N}bcc PLI_ST" '\[base\]' syn_wide &
  mut R13 "; S_CI${N}ld r1, V_FD_FOUND[r0]" "; S_CI${N}jmp S_EP_DONE" '\[order\]' syn_basic &
  wait
  # hardware mutations of the model (docs/nav_engine.md S7: the pump, the take, the guard)
  hmut() {   # name  hw-mut  arm-pattern  fixtures...
    local name=$1 hm=$2 pat=$3; shift 3
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    local fx caught="" log; log=$(mktemp)
    for fx in "$@"; do
      python3 tools/nav_isa.py --hw-mut "$hm" --fixture "$GEN/$fx" > "$log" 2>&1
      if ! grep -q "^PASS" "$log"; then caught=$fx; break; fi
    done
    if [ -z "$caught" ]; then
      { echo "  $name ($hm): SURVIVED -- the gate cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL $pat" "$log"; then
      echo "  $name ($hm): caught on $caught by $(grep -m1 "FAIL $pat" "$log" | sed 's/^[^:]*: //' | cut -c1-80)" > "$RES/$name"
    else
      { echo "  $name ($hm): failed on $caught but NOT in the expected arm ($pat):"; grep -m1 "FAIL" "$log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -f "$log"
  }
  hmut R14 slots0 '\[thrash\]' syn_basic syn_multi &
  hmut N10 seek_noitem '\[seek\] command [0-9]*: nav_err' syn_basic &
  hmut P1 play_nopl '\[nav\] walk ended in err_code 6' syn_nav &
  hmut T6 time_noitems '\(\[time\]\|\[nav\]\)' syn_nav &
  hmut B5 bare_accept '\(\[walk\]\|\[seek\]\|\[stream\]\|\[nav\]\)' syn_bare_mps &
  hmut N9 noflush '\[stream\]' syn_basic &
  hmut N26h guard_off '\[hold\]' syn_multi syn_nav &
  wait
  for f in "$RES"/*; do cat "$f"; done | grep -v '^MUTFAIL$'
  if cat "$RES"/* | grep -q '^MUTFAIL$'; then fail=1; echo "  RED: FAILED"; else echo "  RED: every mutation caught by its own arm"; fi
  rm -rf "$RES"
fi

[ $fail = 0 ] && echo "ALL GREEN" || echo "FAILED"
exit $fail
