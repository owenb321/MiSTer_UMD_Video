#!/usr/bin/env bash
# run_psp_scan.sh -- a PSP's UMD over USB (docs/psp_disc.md §3): the UMD Main's scanner decisions,
# main/support/umd/umd_psp_logic.c, on scripted scan sequences (bench/umd/psp/psp_scan_check.c:
# appear, vanish, a re-enumeration, a swap inside USB mode (smaller or bigger: one rule), a game disc,
# the user's own image, the OSD's unmount, an MGL's mount, a failed open, the path test).
# The glue (umd_psp.cpp: the worker's stat / pread, the mount calls, Info) is the rig's gate.
# --red: mutations of a COPY of the logic (compiled inside the copy), each caught by its own arm:
#   P1  vanish does not unmount                          -> [vanish]
#   P2  a swap inside USB mode not seen (no hash test)   -> [swap]
#   P3  a swapped disc mounted under the stale FAT       -> [swap]
#   P4  a game disc mounted                              -> [game]
#   P5  a message every scan, not once per disc          -> [game]
#   P6  an edge does not clear foreign                   -> [foreign]
#   P7  the first view counts as an edge                 -> [foreign]
#   P8  the OSD's unmount does not suppress              -> [suppress]
#   P9  someone else's PSP mount not adopted             -> [adopt]
#   P10 a re-enumeration on another inode not seen       -> [reenum]
#   P11 a failed open retried every scan                 -> [failed]
#   P12 usb8 accepted                                    -> [path]
#   P13 a PVD read failure taken for a disc              -> [appear]
#   P14 the first view's size not judged                 -> [first]
#   P15 the size judged at every view, not the first     -> [first]
#   P16 an adopted game disc left mounted                -> [adopt]
#   P17 an adopted disc on a stale FAT left mounted      -> [adopt]
set -u
cd "$(dirname "$0")/../.."
O=.sim/psp_scan
mkdir -p $O
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

build() {   # out srcdir
  gcc -std=c99 -O2 -Wall -Wextra -Werror -I"$2" -o "$1" bench/umd/psp/psp_scan_check.c "$2/umd_psp_logic.c"
}

echo "== GREEN =="
rm -f $O/check
build $O/check main/support/umd 2>&1 | head -10
if [ -x $O/check ] && $O/check > $O/green.log 2>&1 && grep -q "^PASS psp_scan_check" $O/green.log; then
  grep "^psp_scan_check:" $O/green.log | sed 's/^/  /'
  echo "  PASS"
else echo "  FAIL"; grep "^FAIL" $O/green.log | head -5; fail=1; fi

if [ $red = 1 ]; then
  echo "== RED: mutations of main/support/umd/umd_psp_logic.c (each caught by its own arm) =="
  # id | arms (/-separated) | old -> new (python replace, exactly once, \n \t unescaped; no "|" inside a field)
  while IFS='|' read -r id arms old new; do
    [ -z "$id" ] && continue
    d=$O/red/$id; rm -rf "$d"; mkdir -p "$d"; cp main/support/umd/umd_psp_logic.* "$d/"
    if ! python3 - "$d/umd_psp_logic.c" "$old" "$new" <<'EOF'
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
P1|vanish|\t\tif (s->owned) unmount_(s, a);\n\t\tif (s->was_present) s->n_edge++;|\t\tif (s->was_present) s->n_edge++;
P2|swap|int swapped = !first && !appeared && !moved && v->fp && s->fp && v->fp != s->fp;|int swapped = 0;
P3|swap|\tif (s->stale) {\n\t\tif (s->owned) unmount_(s, a);  // adopted on|\tif (0) {\n\t\tif (s->owned) unmount_(s, a);  // adopted on
P4|game|\t\ttell(s, a, UMD_PSP_MSG_GAME, v->fp);\n\t\treturn;|\t\ttell(s, a, UMD_PSP_MSG_GAME, v->fp);
P5|game|\tif (s->fp_told == fp) return;|\t(void)0;
P6|foreign|\t\ts->n_edge++;\n\t\ts->foreign = 0;|\t\ts->n_edge++;
P7|foreign|int appeared = !first && !s->was_present;|int appeared = !s->was_present;
P8|suppress|\t\ts->suppressed = 1;             // whichever|\t\t(void)0;             // whichever
P9|adopt|\t\ts->owned = 1;\n\t\ts->fp_mounted = s->fp;|\t\ts->owned = 0;\n\t\ts->fp_mounted = s->fp;
P10|reenum|v->ino != s->ino);|0);
P11|failed|\ts->fp_mounted = 0;\n\ts->suppressed = 1;|\ts->fp_mounted = 0;
P12|path|p[0] >= '0' + UMD_PSP_NUSB|p[0] > '0' + UMD_PSP_NUSB
P13|appear|v->kind == UMD_PSP_K_ERR) {|0) {
P14|first|if (d > UMD_PSP_FAT_SLACK) s->stale = 1;|(void)d;
P15|first|\t\ts->first_pending = 0;\n\t\tuint64_t d|\t\tuint64_t d
P16|adopt|if (s->owned) unmount_(s, a);  // adopted from|(void)0;  // adopted from
P17|adopt|if (s->owned) unmount_(s, a);  // adopted on|(void)0;  // adopted on
MUT
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
