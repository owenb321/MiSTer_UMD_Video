#!/usr/bin/env bash
# run_hps_sub.sh -- B1, the HPS subtitle decoder on the PC (docs/hps_host.md §3.3, §6):
# main/support/umd/umd_sub.cpp (libpng's decode, Adam7 placed a row at a time, the
# plane writer of sub_plane_wr.sv, the ring reader) against tools/hps_sub_check.cpp's
# in-process oracle (png_oracle.c's decode, the premultiply written apart) and
# tools/sub_golden.py's plane words.
#
# Built twice: against this PC's libpng, and against libpng $DEV_VER -- the version the
# MiSTer's Main runs with (/usr/lib/libpng16.so.16.37.0 of the MiSTer Linux image, measured
# by B2 on two rigs, 2026-09-30) -- from its source (fetched once into .sim/libpng,
# sha256-pinned), with the headers main/ vendors.
# The two runs' digests must agree except for KNOWN_DIFF below.
#
# GREEN:
#   * the synthetic set (tools/hps_sub_cases.py: png_golden.py's every type / depth /
#     filter / DEFLATE edge / refused case at four placements, sub_golden.py's units),
#     both libpngs, and the second golden (sub_golden.py's plane words) on it;
#   * with the caches (tools/png_corpus.py / rco_png.py, built from $UMD_ISO_DIR as
#     run_png.sh builds them): every 100th subtitle unit and every menu PNG, both libpngs;
#   * the version diff.
# --sweep: EVERY subtitle unit (336,181 on 88 discs, 2026-09-30; ~3 min a libpng).
# --red: mutations of a COPY of main/support/umd/ (compiled inside the copy), each caught
#   by its own arm on the synthetic set.
set -u
cd "$(dirname "$0")/../.."
fail=0; red=0; sweep=0
for a in "$@"; do
  case $a in --red) red=1;; --sweep) sweep=1;; *) echo "usage: $0 [--red] [--sweep]"; exit 2;; esac
done
O=.sim/hps_sub
GEN=bench/umd/fixtures/gen
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
mkdir -p $O
SRC="main/support/umd/umd_sub.cpp"
# libpng 1.6.37 (and 1.6.28 before it) refuses a bad IEND CRC; 1.6.58 only warns. The fabric
# decoder refused it too (tools/png_golden.py crc_iend, stricter=True): the device keeps the
# fabric's verdict.
KNOWN_DIFF='^crc_iend@'

# The device's libpng: the one Main RUNS with, not the one it links against. Main links
# against its tree's lib/imlib2/libpng16.so (1.6.28 at MAIN_MISTER_REF), but the soname
# libpng16.so.16 resolves at run time to the Linux image's /usr/lib/libpng16.so.16.37.0
# (B2's "b2 libpng" on the rig: run=1.6.37, the same file on a 2022 and a 2026 image;
# docs/hps_host.md §6 "B2, the results"). If a Linux release moves it, change DEV_VER (and
# the two sha256s) and re-vendor the headers.
# The official release tarball first (static; its sha computed 2026-09-30 -- libpng's
# published one -- its sources compared equal to the GitHub tag archive's), the tag archive
# as a fallback (GitHub has
# regenerated such archives before, so its sha can move: then this gate goes red LOUDLY,
# for a reason outside the code -- update the sha after re-checking the sources).
DEV_VER=1.6.37
DEV_URL1=https://download.sourceforge.net/libpng/libpng-$DEV_VER.tar.xz
DEV_SHA1=505e70834d35383537b6491e7ae8641f1a4bed1876dbfe361201fc80868d88ca
DEV_URL2=https://github.com/pnggroup/libpng/archive/refs/tags/v$DEV_VER.tar.gz
DEV_SHA2=ca74a0dace179a8422187671aee97dd3892b53e168627145271cad5b5ac81307
echo "== libpng $DEV_VER (the MiSTer's) =="
LP=.sim/libpng
LIBDEV=$LP/libpng$(echo $DEV_VER | tr -d .).a
havedev=0
if [ ! -f $LIBDEV ]; then
  mkdir -p $LP
  got=""
  for k in 1 2; do
    url=$([ $k = 1 ] && echo $DEV_URL1 || echo $DEV_URL2); sha=$([ $k = 1 ] && echo $DEV_SHA1 || echo $DEV_SHA2)
    f=$LP/$(basename "$url")
    [ -f "$f" ] || curl -sSLf -o "$f" "$url" || rm -f "$f"
    if [ -f "$f" ] && echo "$sha  $f" | sha256sum -c --quiet 2>/dev/null; then got=$f; break; fi
    echo "  (source $k: not fetched or checksum differs)"
  done
  if [ -n "$got" ]; then
    rm -rf $LP/libpng-$DEV_VER $LP/obj
    (cd $LP && tar xf "$(basename "$got")" && cd libpng-$DEV_VER && cp scripts/pnglibconf.h.prebuilt pnglibconf.h \
      && mkdir -p ../obj && for f in png pngerror pngget pngmem pngpread pngread pngrio pngrtran pngrutil pngset \
         pngtrans pngwio pngwrite pngwtran pngwutil; do cc -O2 -w -DPNG_ARM_NEON_OPT=0 -I. -c $f.c -o ../obj/$f.o || exit 1; done \
      && ar rcs ../$(basename $LIBDEV) ../obj/*.o)
  fi
fi
if [ -f $LIBDEV ]; then
  havedev=1
  for h in png.h pngconf.h; do
    cmp -s $LP/libpng-$DEV_VER/$h main/support/umd/libpng/$h || { echo "  FAIL main/support/umd/libpng/$h is not $DEV_VER's"; fail=1; }
  done
  cmp -s $LP/libpng-$DEV_VER/scripts/pnglibconf.h.prebuilt main/support/umd/libpng/pnglibconf.h \
    || { echo "  FAIL main/support/umd/libpng/pnglibconf.h is not $DEV_VER's prebuilt"; fail=1; }
  echo "  ok: built from the pinned source; the vendored headers are its own"
else
  echo "  FAIL (LOUD): libpng $DEV_VER could not be fetched or built -- the device's version is NOT checked"
  fail=1
fi

echo "== build =="
build() {   # out variant srcdir -> 0 on success
  if [ "$2" = sys ]; then
    g++ -O2 -Wall -Wextra -Werror -DUMD_SUB_SYSTEM_PNG -I"$3" -o "$1" tools/hps_sub_check.cpp "$3/umd_sub.cpp" -lpng16 -lz
  else
    g++ -O2 -Wall -Wextra -Werror -I"$3" -o "$1" tools/hps_sub_check.cpp "$3/umd_sub.cpp" $LIBDEV -lz
  fi
}
rm -f $O/check_sys $O/check_dev
build $O/check_sys sys main/support/umd 2>&1 | head -20 || true
[ -x $O/check_sys ] && echo "  ok: check_sys" || { echo "  FAIL build (system libpng)"; exit 1; }
if [ $havedev = 1 ]; then
  build $O/check_dev dev main/support/umd 2>&1 | head -20 || true
  [ -x $O/check_dev ] && echo "  ok: check_dev" || { echo "  FAIL build (libpng $DEV_VER)"; fail=1; havedev=0; }
fi

echo "== cases =="
CARGS=""
[ -d $GEN/png_corpus ] && CARGS="$CARGS --corpus $GEN/png_corpus"
[ -d $GEN/rco_png ] && CARGS="$CARGS --rco $GEN/rco_png"
if [ -z "$CARGS" ] && [ -d "$ISO_DIR" ]; then
  echo "  building the caches from $ISO_DIR (once)"
  python3 tools/png_corpus.py --dump $GEN/png_corpus --jobs 6 > .sim/png_corpus.log 2>&1
  python3 tools/rco_png.py --dump $GEN/rco_png --jobs 6 > .sim/rco_png.log 2>&1
  CARGS="--corpus $GEN/png_corpus --rco $GEN/rco_png"
fi
# shellcheck disable=SC2086
python3 -W ignore tools/hps_sub_cases.py lists --out $O $CARGS 2>&1 | sed 's/^/  /'
[ -s $O/synth.txt ] || { echo "  FAIL no synthetic cases"; exit 1; }
LISTS="synth"
if [ -s $O/corpus.txt ]; then
  if [ $sweep = 1 ]; then cp $O/corpus.txt $O/corpus_run.txt
  else awk 'NR % 100 == 1' $O/corpus.txt > $O/corpus_run.txt; fi
  LISTS="$LISTS corpus_run"
else
  echo "  SKIP corpus: no cache and no \$UMD_ISO_DIR ($ISO_DIR)"
fi
[ -s $O/rco.txt ] && LISTS="$LISTS rco"

run() {   # bin list variant -> PASS / FAIL lines
  if "$1" $O/$2.txt --digest $O/$2_$3.dg > $O/$2_$3.log 2>&1 && grep -q "^PASS hps_sub_check" $O/$2_$3.log; then
    echo "  PASS $2 ($3): $(grep '^hps_sub_check:' $O/$2_$3.log | sed 's/^hps_sub_check: //')"
  else
    echo "  FAIL $2 ($3)"; grep "^FAIL" $O/$2_$3.log | head -5; fail=1
  fi
}
for l in $LISTS; do
  echo "== $l =="
  run $O/check_sys $l sys
  [ $havedev = 1 ] && run $O/check_dev $l dev
  if [ $havedev = 1 ] && [ -f $O/${l}_sys.dg ] && [ -f $O/${l}_dev.dg ]; then
    d=$(diff $O/${l}_sys.dg $O/${l}_dev.dg | grep '^[<>]' | sed 's/^[<>] //' | awk '{print $1}' | sort -u)
    unk=$(echo "$d" | grep -v "^$" | grep -Ev "$KNOWN_DIFF" | head -5)
    if [ -n "$unk" ]; then echo "  FAIL versions differ on: $unk"; fail=1
    else echo "  PASS $(pkg-config --modversion libpng 2>/dev/null || echo system) == $DEV_VER ($(echo "$d" | grep -c .) known: $KNOWN_DIFF)"; fi
  fi
done
echo "== the second golden (sub_golden.py) =="
python3 -W ignore tools/hps_sub_cases.py golden $O/synth.txt $O/synth_sys.dg > $O/golden.log 2>&1
tail -3 $O/golden.log | sed 's/^/  /'
grep -q "^PASS \[golden\]" $O/golden.log || fail=1

if [ $red = 1 ]; then
  echo "== RED: mutations of main/support/umd/ (each caught by its own arm on the synthetic set) =="
  # id | arm | python replace (old -> new), applied exactly once; no "|" inside a field
  while IFS='|' read -r id arm old new; do
    [ -z "$id" ] && continue
    d=$O/red/$id; rm -rf "$d"; mkdir -p "$d"; cp -r main/support/umd/. "$d/"
    if ! python3 - "$d/umd_sub.cpp" "$old" "$new" <<'EOF'
import sys
p, old, new = sys.argv[1], sys.argv[2].encode().decode("unicode_escape"), sys.argv[3].encode().decode("unicode_escape")
s = open(p).read()
if s.count(old) != 1:
    sys.exit("the mutation's text is found %d times" % s.count(old))
open(p, "w").write(s.replace(old, new))
EOF
    then echo "  FAIL $id: did not apply"; fail=1; continue; fi
    if ! (g++ -O2 -w -DUMD_SUB_SYSTEM_PNG -I"$d" -o "$d/check" tools/hps_sub_check.cpp "$d/umd_sub.cpp" -lpng16 -lz) 2> "$d/build.log"; then
      echo "  FAIL $id: the mutant does not build"; fail=1; continue
    fi
    "$d/check" $O/synth.txt > "$d/run.log" 2>&1
    if grep -q "^FAIL \[$arm\]" "$d/run.log"; then echo "  caught $id by [$arm]: $(grep -m1 "^FAIL \[$arm\]" "$d/run.log" | cut -c1-110)"
    else echo "  SURVIVED $id (want [$arm]): $(grep -m1 '^FAIL\|^PASS' "$d/run.log")"; fail=1; fi
  done <<'MUT'
M1|pixel|uint32_t t = c * a + 128;|uint32_t t = c * a;
M2|pixel|(uint64_t)v[i + 1] << 32;|(uint64_t)v[i] << 32;
M3|clip|uint64_t fit = (UMD_PLANE_W - sx + dx - 1) / dx;|uint64_t fit = (UMD_PLANE_W + 8 - sx + dx - 1) / dx;
M4|pixel|premul(s[0], a) << 16|premul(s[1], a) << 16
M5|pixel|{1, 0, 2, 2}|{0, 0, 2, 2}
M6|verdict|r->err = status;|r->err = UMD_SUB_OK;
M7|ring|if (pos == ring_bytes)\n\t\t\tpos = 0;|if (pos == ring_bytes)\n\t\t\tpos = 8;
M8|clip|if (ay >= UMD_PLANE_H)\n\t\t\t\tcontinue;|if (ay >= UMD_PLANE_H + 1)\n\t\t\t\tcontinue;
M9|clip|written += n;|(void)0;
M10|cancel|if (cancel && cancel(cancel_arg))|if (0 && cancel && cancel(cancel_arg))
M11|size|r->w = w; r->h = h;|r->w = h; r->h = w;
M12|pixel|uint32_t a = i < ntrns ? trns[i] : 255;|uint32_t a = i < ntrns ? trns[i] : 0;
M13|pixel|premul(cr, a) << 16|cr << 16
M14|pixel|dst[ax] = v[0];|(void)0;
M15|pixel|dst[(uint32_t)sx + i * dx] = line[i];|dst[(uint32_t)sx + i] = line[i];
M16|pixel|uint32_t cr = 0, cg = 0, cb = 0;|uint32_t cr = 255, cg = 0, cb = 0;
MUT
fi

echo
if [ $fail = 0 ]; then echo "run_hps_sub: ALL GREEN"; else echo "run_hps_sub: FAILURES"; exit 1; fi
