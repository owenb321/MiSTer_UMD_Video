#!/usr/bin/env bash
# run_disc_screen.sh -- R5, the disc screen (docs/resume.md §6, RS4): the UMD Main's page renderer
# main/support/umd/umd_disc_screen.c, through bench/umd/disc/ds_check.c, against
# tools/disc_screen_layout.py (the golden: the approved mockups' card, integers only) and tools/umd_sfo.py,
# scored by bench/umd/disc/ds_bench.py: [sfo] [title] [hint] [lib] (every library page, pixel-exact)
# [fit] (the 4:3 CRT's Letterbox / Crop) [syn] (odd sizes, random alpha, missing art, the wrap's edges).
# --red: mutations of a COPY of umd_disc_screen.c (compiled inside the copy), each must FAIL its own arm.
# ARMS="D1 D4 ...": with --red, only those mutations. Images: $UMD_ISO_DIR (the library arms SKIP without).
set -u
cd "$(dirname "$0")/../.."
O=.sim/disc_screen
mkdir -p $O
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
ISO=${UMD_ISO_DIR:-$HOME/umd-isos}

build() {   # out srcdir
  cc -O2 -std=c99 -Wall -Wextra -Werror -I"$2" -o "$1" bench/umd/disc/ds_check.c "$2/umd_disc_screen.c" "$2/umd_panel_art.c" -lpng
}

echo "== GREEN =="
rm -f $O/check
build $O/check main/support/umd 2>&1 | head -10
if [ -x $O/check ] && python3 bench/umd/disc/ds_bench.py $O/check $O/tmp --iso-dir "$ISO" > $O/green.log 2>&1 \
   && grep -q "^PASS ds_bench" $O/green.log; then
  grep -E "^(PASS|SKIP) " $O/green.log | grep -v "^PASS ds_bench" | sed 's/^/  /'
else echo "  FAIL"; grep "^FAIL" $O/green.log | head -5; fail=1; fi

if [ $red = 1 ]; then
  echo "== RED (each mutation must fail its own arm) =="
  dmut() {   # name arm old new
    [ -n "${ARMS:-}" ] && [[ " $ARMS " != *" $1 "* ]] && return
    local name=$1 arm=$2 old=$3 new=$4 d
    d=$(mktemp -d)
    cp main/support/umd/umd_disc_screen.[ch] main/support/umd/umd_panel.h main/support/umd/umd_panel_art.[ch] "$d/"
    if ! python3 - "$d/umd_disc_screen.c" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)"; fail=1; rm -rf "$d"; return; fi
    # (cc resolves a quoted include in the including file's own directory first: the copy's headers,
    # never the repo's -- ds_check.c's directory holds none)
    if ! build "$d/check" "$d" > "$d/build.log" 2>&1; then echo "  $name: harness failure (build)"; fail=1; rm -rf "$d"; return; fi
    python3 bench/umd/disc/ds_bench.py "$d/check" "$d/tmp" --iso-dir "$ISO" --arms "$arm" > "$d/log" 2>&1
    if grep -q "^FAIL $arm:" "$d/log"; then echo "  $name: caught by [$arm]: $(grep -m1 "^FAIL $arm:" "$d/log" | cut -c1-100)"
    elif grep -q "^SKIP $arm:" "$d/log"; then echo "  $name: SKIP ([$arm] has no images)"
    else echo "  $name: SURVIVED [$arm]"; fail=1; fi
    rm -rf "$d"
  }
  #   D1 the key not compared (the first entry's data taken: CATEGORY's). (Cutting the TITLE one byte
  #      short is EQUIVALENT: a UTF-8 TITLE's length counts its NUL.)
  dmut D1 sfo "if (ko + 6 > n || memcmp(sfo + ko, \"TITLE\", 6)) continue;" "if (ko + 6 > n) continue;"
  #   D2 fullwidth ASCII not folded (the title falls back to the file name)
  dmut D2 title "if (c >= 0xFF01 && c <= 0xFF5E)" "if (0)"
  #   D3 the (TM) sign not spelt out (Spiderman 3's title falls back)
  dmut D3 title "else if (c == 0x2122) rep = \"TM\";" "else if (0) rep = \"TM\";"
  #   D4 the Play line's minutes unpadded
  dmut D4 hint "> Resume %u:%02u:%02u" "> Resume %u:%u:%02u"
  #   D5 the sample point's half-pixel centring dropped (the scaling shifted)
  dmut D5 lib "((int64_t)(2 * d + 1) * sw) / (2 * (int64_t)n) - 32768;" "((int64_t)(2 * d + 1) * sw) / (2 * (int64_t)n);"
  #   D6 the source not premultiplied before scaling (random alpha)
  dmut D6 syn "t[k] = c == 3 ? p[k][3] : rnd255(p[k][c] * p[k][3]);" "t[k] = p[k][c];"
  #   D7 Crop's view off by one scene unit
  dmut D7 fit "W16 * 107 / 854" "W16 * 108 / 854"
  #   D8 Letterbox one line high
  dmut D8 fit "0, 60, UMD_DS_W, 360);" "0, 59, UMD_DS_W, 360);"
  #   D9 the box's corner radius a quarter-pixel larger. (`<` for `<=` is EQUIVALENT: a subsample's
  #      squared distance is 2 mod 8, the radius' square 0 mod 8 -- never equal.)
  dmut D9 lib "	const int r8 = 8 * UMD_PANEL_BOX_R;" "	const int r8 = 8 * UMD_PANEL_BOX_R + 2;"
  #   D10 the ellipsis one character too long (three-line titles)
  dmut D10 syn "\"%.*s...\", max_chars - 3," "\"%.*s...\", max_chars - 2,"
  #   D11 a thumbnail-less card's title at the icon's edge
  dmut D11 syn "	int tx = ix + 6;" "	int tx = ix + 8;"
  #   D12 the page not cleared first (what was in the buffer shows through the gaps)
  #   D13 gAMA kept (libpng's sRGB conversion from the file's gamma: Akira's art brightened)
  dmut D13 png "int drop = !memcmp(t, \"gAMA\", 4) || " "int drop = "
  #   D14 a dropped chunk's bytes left behind (the next chunk read from the wrong place)
  dmut D14 png "		else { if (w != r) memmove(png + w, png + r, whole); w += whole; }" "		else { w += whole; }"
  dmut D12 syn "	for (int y = 0; y < UMD_DS_H; y++) memset(px + (size_t)y * stride, 0, (size_t)UMD_DS_W * 4);" ""
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
