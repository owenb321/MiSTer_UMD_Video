#!/usr/bin/env bash
# run_hps_host.sh -- B4's host decisions on the PC (docs/hps_host.md §6): the UMD Main's
# main/support/umd/umd_host_logic.cpp against tools/hps_host_check.cpp's model of the fabric
# (umd/sub/sub_top.sv's acceptance rule, umd/umd_host.sv's heartbeat) -- normal play, flushes
# mid-decode, lost completions, core reloads (a MAGIC gap of 50 ms and 2 s, and none at all),
# a core of another PROTO, a long idle, a 1,000,000-wide image.
# The glue (umd_host.cpp: the SPI, the mappings, the worker thread) is the rig's B4 gate.
# --red: mutations of a COPY of main/support/umd/ (compiled inside the copy), each caught by
#   its own arm:
#   L1  no cancel when the job's request goes                    -> [cancel] / [stale]
#   L2  a cancelled job's completion sent                        -> [stale]
#   L3  a lost completion never resent                           -> [latency]
#   L4  no forget rule (a remembered pair is always "ours")      -> [served]
#   L5  MAGIC missing does not clear the remembered completion   -> [served]
#   L6  the heartbeat every 500 ms                               -> [heartbeat]
#   L7  the fast read period 50 ms                               -> [rate]
#   L8  w / h truncated, not saturated                           -> [sat]
#   L9  a request served while a job is in flight                -> [order]
#   L10 no active window (slow reads between units)              -> [rate]
set -u
cd "$(dirname "$0")/../.."
O=.sim/hps_host
mkdir -p $O
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

build() {   # out srcdir
  g++ -O2 -Wall -Wextra -Werror -I"$2" -o "$1" tools/hps_host_check.cpp "$2/umd_host_logic.cpp"
}

echo "== the table =="
python3 tools/host_layout.py --check | sed 's/^/  /' || fail=1

echo "== GREEN =="
rm -f $O/check
build $O/check main/support/umd 2>&1 | head -10
if [ -x $O/check ] && $O/check > $O/green.log 2>&1 && grep -q "^PASS hps_host_check" $O/green.log; then
  sed 's/^hps_host_check: /  /' $O/green.log | grep -v "^PASS"
  echo "  PASS"
else echo "  FAIL"; grep "^FAIL" $O/green.log | head -5; fail=1; fi

if [ $red = 1 ]; then
  echo "== RED: mutations of main/support/umd/umd_host_logic.* (each caught by its own arm) =="
  # id | arms (/-separated) | file | old -> new (python replace, exactly once, \n \t unescaped; no "|" inside a field)
  while IFS='|' read -r id arms file old new; do
    [ -z "$id" ] && continue
    d=$O/red/$id; rm -rf "$d"; mkdir -p "$d"; cp main/support/umd/umd_host_logic.* main/support/umd/umd_host_proto.h "$d/"
    if ! python3 - "$d/$file" "$old" "$new" <<'EOF'
import sys
p = sys.argv[1]
old, new = (x.encode().decode("unicode_escape") for x in sys.argv[2:4])
s = open(p).read()
if s.count(old) != 1:
    sys.exit("the mutation's text is found %d times" % s.count(old))
open(p, "w").write(s.replace(old, new))
EOF
    then echo "  FAIL $id: did not apply"; fail=1; continue; fi
    if ! build "$d/check" "$d" 2> "$d/build.log"; then echo "  FAIL $id: the mutant does not build"; fail=1; continue; fi
    "$d/check" > "$d/run.log" 2>&1
    arms=${arms//\//|}
    if grep -Eq "^FAIL \[($arms)\]" "$d/run.log"; then echo "  caught $id by $(grep -Em1 "^FAIL \[($arms)\]" "$d/run.log" | cut -c1-110)"
    else echo "  SURVIVED $id (want [$arms]): $(grep -m1 '^FAIL\|^PASS' "$d/run.log")"; fail=1; fi
  done <<'MUT'
L1|cancel/stale|umd_host_logic.cpp|rd->gen != s->job_gen))\n\t\t\t\tcancel_job(s, a);|rd->gen != s->job_gen))\n\t\t\t\t(void)0;
L2|stale|umd_host_logic.cpp|if (s->job && !s->cancel_sent && !wk->cancelled && wk->seq == s->job_seq && wk->gen == s->job_gen) {|if (s->job && wk->seq == s->job_seq && wk->gen == s->job_gen) {
L3|latency|umd_host_logic.cpp|&& s->resends < UMD_HOST_RESEND_MAX) {|&& 0) {
L4|served|umd_host_logic.cpp|if (same && t < UMD_HOST_FORGET_MS) {|if (same) {
L5|served|umd_host_logic.cpp|			s->n_nomagic++;\n			s->have_last = 0;|			s->n_nomagic++;
L6|heartbeat|umd_host_logic.h|#define UMD_HOST_HEARTBEAT_MS 100|#define UMD_HOST_HEARTBEAT_MS 500
L7|rate|umd_host_logic.h|#define UMD_HOST_READ_FAST_MS 2|#define UMD_HOST_READ_FAST_MS 50
L8|sat|umd_host_logic.h|return v > 0xFFFFu ? 0xFFFFu : (uint16_t)v;|return (uint16_t)v;
L9|order|umd_host_logic.cpp|if (!s->job && wk->state == UMD_W_IDLE && !a->consume && rd->req && !a->write) {|if (!a->consume && rd->req && !a->write) {
L10|rate|umd_host_logic.cpp|(s->have_req && age(now, s->t_req) < UMD_HOST_ACTIVE_MS);|0;
MUT
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
