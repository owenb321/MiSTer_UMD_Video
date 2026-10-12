#!/usr/bin/env bash
# run_film_lock.sh -- umd/film_lock.sv, the cadence lock of field matching (Forgejo fj#80,
# docs/telecine.md S5), step by step against tools/telecine_ref.py's FilmLock
# (bench/umd/film_lock_tb.sv).
#
# GREEN, one arm per vector file (telecine_ref.py --vectors): the model's walk over synthetic
# windows -- 3:2 film (both field orders; an edit at each of the new cadence's five phases),
# drawings on twos, true video, a still, a flat black picture -- and,
# with $UMD_ISO_DIR, over three library windows (The Dark Knight, The Simpsons Movie, The Office
# Disc 01); each walk twice, as the display runs it (two refreshes a store) and perturbed (a
# store held 1-4 refreshes, the next store absent, a store breaking the pairs, a refresh without
# evidence, a clr).
#
# --red [MUTS="F1 F2" to run only those]: mutations on a COPY, each caught by its own arm:
#   F1  the break at the acquisition ratio (COMB8, not BRK8)        lib_simpsons    -> [show]|[lock]
#       (a weave between 1.5 and 2.5 under the lock: no synthetic arm has one; SKIP without it)
#   F2  a matched weave cannot break the lock (IN only)             syn_film_e90_3  -> [show]|[lock]
#   F3  a cycle with no combed pair counts (the informative gate)   lib_office      -> [lock]|[show]
#       (SKIP without the library)
#   F4  the phase one store late (the two set slots 0 / 0)          syn_film_f0     -> [lock]|[show]
#   F5  an UNSURE pair at a clean slot costs nothing                lib_tdk_p       -> [lock]|[show]
#       (SKIP without the library)
#   F6  a store breaking the pairs does not reset                   syn_film_e90_2_p -> [lock]|[show]
#   F7  the motion floor dropped (a flat picture: C = R = 0)        syn_black       -> [lock]|[show]
#   F8  the partners swapped (the first field with the NEXT store)  syn_film_f0     -> [show]
#   F9  an absent partner woven in-store, not bobbed                syn_film_f0_p   -> [show]
#   F10 clr ignored                                                 syn_film_f0_p   -> [show]|[lock]
#   F11 evidence used when there is none (mv ignored)               syn_film_f0_p   -> [lock]|[show]
#   F12 a matched refresh's class recorded as the store's           syn_film_e90_3_p -> [lock]|[show]
#   F13 the state steps without a step                              syn_video       -> [hold]|[lock]|[show]
set -u
cd "$(dirname "$0")/../.."
W=.sim/film_lock
mkdir -p "$W"
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
find "$W" -maxdepth 1 -name '*.vec' -delete
python3 tools/telecine_ref.py --vectors "$W" > "$W/vectors.log" 2>&1 || { echo "FAIL: the model's vectors"; cat "$W/vectors.log"; exit 1; }
grep -q "SKIP" "$W/vectors.log" && echo "  (SKIP: the library arms -- set UMD_ISO_DIR)"
ARMS=$(cd "$W" && ls -- *.vec | sed 's/\.vec$//')
find "$W" -maxdepth 1 -name sim -delete
iverilog -g2012 -o "$W/sim" umd/film_lock.sv bench/umd/film_lock_tb.sv 2>&1 | grep -v "sorry" || true
[ -f "$W/sim" ] || { echo "FAIL: build"; exit 1; }
echo "== GREEN: $(echo $ARMS | wc -w) arms =="
for a in $ARMS; do
  if timeout 600 vvp -n "$W/sim" +vec="$W/$a.vec" +arm="$a" > "$W/$a.log" 2>&1 && grep -q "^PASS: film_lock_tb" "$W/$a.log"; then
    echo "  PASS $(grep '^film_lock_tb:' "$W/$a.log" | sed 's/^film_lock_tb: //')"
  else echo "  FAIL $a"; grep -m3 FAIL "$W/$a.log" | sed 's/^/    /'; fail=1; fi
done

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  RES=$(mktemp -d)
  F=umd/film_lock.sv
  mut() {   # name old new vector-arm fail-labels
    local name=$1 old=$2 new=$3 va=$4 lab=$5 d
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    [ -f "$W/$va.vec" ] || { echo "  $name: SKIP (no $va vectors)" > "$RES/$name"; return; }
    d=$(mktemp -d)
    cp $F "$d/"
    python3 - "$d/film_lock.sv" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(path, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/film_lock.sv" bench/umd/film_lock_tb.sv 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "${d:?}"; return
    fi
    timeout 600 vvp -n "$d/sim" +vec="$W/$va.vec" +arm="$va" > "$d/log" 2>&1
    if grep -q "^PASS:" "$d/log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "FAIL \[($lab)\]" "$d/log"; then
      echo "  $name: caught by $(grep -Em1 "FAIL \[($lab)\]" "$d/log" | cut -c1-110)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$lab]:"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "${d:?}"
  }
  mut F1 "wire  [31:0] r_bk = {8'd0, mr} * BRK8;" "wire  [31:0] r_bk = {8'd0, mr} * COMB8;" lib_simpsons "show|lock" &
  mut F2 "(show == S_IN || show == S_PREV || show == S_NEXT) && brk" "(show == S_IN) && brk" syn_film_e90_3 "show|lock" &
  mut F3 "if (n_hit && !n_bad) n_conf" "if (!n_bad) n_conf" lib_office "lock|show" &
  mut F4 "n_slot = 3'd1; n_conf = 4'd0; n_hit = 1'b1;" "n_slot = 3'd0; n_conf = 4'd0; n_hit = 1'b1;" syn_film_f0 "lock|show" &
  mut F5 "n_conf = (n_conf > DN_SOFT) ? n_conf - DN_SOFT : 4'd0;" "n_conf = n_conf;" lib_tdk_p "lock|show" &
  mut F6 "                n_locked = 1'b0; n_conf = 4'd0; n_slot = NOPH; n_prev = K_NONE;" "                n_prev = n_prev;" syn_film_e90_2_p "lock|show" &
  wait
  mut F7 "wire         is_comb  = (c8 >= r_cb) && (c16 >= p_fl);" "wire         is_comb  = (c8 >= r_cb);" syn_black "lock|show" &
  mut F8 "n_show = first ? (prev_ok ? S_PREV : S_BOB) : (next_ok ? S_NEXT : S_BOB);" "n_show = first ? (next_ok ? S_NEXT : S_BOB) : (prev_ok ? S_PREV : S_BOB);" syn_film_f0 show &
  mut F9 "n_show = first ? (prev_ok ? S_PREV : S_BOB) : (next_ok ? S_NEXT : S_BOB);" "n_show = first ? (prev_ok ? S_PREV : S_IN) : (next_ok ? S_NEXT : S_IN);" syn_film_f0_p show &
  mut F10 "        end else if (clr) begin" "        end else if (1'b0) begin" syn_film_f0_p "show|lock" &
  mut F11 "        if (mv) begin" "        if (1'b1) begin" syn_film_f0_p "lock|show" &
  mut F12 "if (!n_locked && (show == S_FALL || show == S_IN)) n_last = cls;" "if (!n_locked) n_last = cls;" syn_film_e90_3_p "lock|show" &
  mut F13 "        end else if (step) begin" "        end else if (1'b1) begin" syn_video "hold|lock|show" &
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "${RES:?}"
fi
[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
