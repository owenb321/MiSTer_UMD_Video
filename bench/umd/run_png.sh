#!/usr/bin/env bash
# run_png.sh -- the PNG decoder gate (umd/png/png_top.sv: png_chunks -> inflate ->
# png_unfilter -> png_pixel; bench/umd/png_tb.sv; goldens tools/png_golden.py:
# zlib's bytes, libpng's pixels via tools/png_oracle.c, PIL / ffmpeg cross-checks;
# docs/png_decode.md §5)
#
# GREEN:
#   * every synthetic case (tools/png_golden.py: every colour type x depth, plain and
#     Adam7, every filter, the DEFLATE edges zlib never writes, the size bounds, and the
#     refused cases -- each verdict checked against zlib's message / libpng's), once
#     straight and once with random input gaps and output back-pressure (+stall);
#   * with $UMD_ISO_DIR: the subtitle corpus (tools/png_corpus.py, cached under
#     fixtures/gen/png_corpus): the largest unit of every disc and the first 20 of
#     Akira and Family Guy;
#   * verilator --lint-only -Wall over umd/png/.
# --sweep: EVERY cached subtitle unit and every menu PNG of every disc's RCO files (Verilator;
# zlib + libpng in-process, no fixtures; ~35 min at 4 jobs). With --red too: one mutant (M13)
# through the sweep harness must fail [pixel].
# --red: mutations on a COPY of umd/png/, each compiled inside its copy and caught by
# its own arm (listed with the mut lines below).
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim
fail=0
red=0; sweep=0
for a in "$@"; do
  case $a in --red) red=1;; --sweep) sweep=1;; *) echo "usage: $0 [--red] [--sweep]"; exit 2;; esac
done
GEN=bench/umd/fixtures/gen
CACHE=$GEN/png_corpus
RCO=$GEN/rco_png                    # the menus' PNGs (tools/rco_png.py): the types subtitles never use
RTL="umd/png/png_pkg.sv umd/png/inflate.sv umd/png/png_chunks.sv umd/png/png_unfilter.sv umd/png/png_pixel.sv umd/png/png_top.sv"
TB=bench/umd/png_tb.sv
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}

echo "== fixtures =="
python3 -W ignore tools/png_golden.py --out $GEN/png --list synth > .sim/png_golden.log 2>&1 \
  && sed 's/^/  /' .sim/png_golden.log | cut -c1-240 || { echo "  FAIL golden"; tail -3 .sim/png_golden.log; exit 1; }
CORPUS=0
if [ -d "$ISO_DIR" ]; then
  python3 tools/png_corpus.py --dump $CACHE --jobs 6 > .sim/png_corpus.log 2>&1 || { echo "  FAIL corpus dump"; tail -3 .sim/png_corpus.log; fail=1; }
  python3 tools/rco_png.py --dump $RCO --jobs 6 > .sim/rco_png.log 2>&1 || { echo "  FAIL RCO dump"; tail -3 .sim/rco_png.log; fail=1; }
  if python3 -W ignore tools/png_golden.py --no-synth --corpus $CACHE --corpus-sel sample --out $GEN/png --list corpus > .sim/png_golden_c.log 2>&1; then
    CORPUS=1; sed 's/^/  corpus: /' .sim/png_golden_c.log | head -1
  else echo "  FAIL corpus golden"; tail -3 .sim/png_golden_c.log; fail=1; fi
else
  echo "  SKIP corpus: no \$UMD_ISO_DIR ($ISO_DIR)"
fi

# shellcheck disable=SC2086
rm -f .sim/png_sim   # a failed build must not run the last one (the stale-binary trap: h264_top, 2026-10-05)
iverilog -g2012 -o .sim/png_sim $RTL $TB 2>&1 | grep -v "sorry: constant selects"
[ -f .sim/png_sim ] || { echo "  FAIL png_tb: build"; exit 1; }

run() {   # sim list stall -> 0 on PASS; the log in .sim/png_last.log
  vvp -n "$1" "+list=$2" "+stall=$3" 2>&1 | grep -v 'readmem\|Not enough words' > .sim/png_last.log
  grep -q "^PASS: png_tb" .sim/png_last.log
}
report() {   # label list stall
  if run .sim/png_sim "$2" "$3"; then echo "  PASS $1: $(grep '^png_tb:' .sim/png_last.log | sed 's/^png_tb: //')"
  else echo "  FAIL $1"; grep "FAIL\|FATAL" .sim/png_last.log | head -3; fail=1; fi
}

echo "== GREEN =="
report "synthetic" $GEN/png/synth.txt 0
report "synthetic +stall" $GEN/png/synth.txt 1
[ $CORPUS = 1 ] && report "subtitle corpus sample" $GEN/png/corpus.txt 0

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm; straight first, then +stall) =="
  RES=$(mktemp -d)
  mut() {   # name file old new arms
    local name=$1 file=$2 old=$3 new=$4 arms=$5
    local d; d=$(mktemp -d)
    cp umd/png/*.sv "$d/"
    if ! python3 - "$d/$file" "$old" "$new" <<'PYEOF'
import sys
path, old, new = sys.argv[1:4]
s = open(path).read()
assert s.count(old) == 1, "anchor not unique/found: %r" % old
open(path, "w").write(s.replace(old, new))
PYEOF
    then echo "  $name: harness failure (anchor)" > "$RES/$name"; echo MUTFAIL >> "$RES/$name"; rm -rf "$d"; return; fi
    # compiled from inside the copy (CLAUDE.md: the include lesson), the bench from the tree
    ( cd "$d" && iverilog -g2012 -o sim png_pkg.sv inflate.sv png_chunks.sv png_unfilter.sv png_pixel.sv \
        png_top.sv "$OLDPWD/$TB" 2>build.log | grep -v sorry ) || true
    if [ ! -f "$d/sim" ]; then echo "  $name: harness failure (build)" > "$RES/$name"; echo MUTFAIL >> "$RES/$name"; rm -rf "$d"; return; fi
    local log=$d/log
    vvp -n "$d/sim" "+list=$MUTLIST" "+stall=0" > "$log" 2>&1
    if grep -q "^PASS: png_tb" "$log"; then vvp -n "$d/sim" "+list=$MUTLIST" "+stall=1" > "$log" 2>&1; fi
    if grep -q "^PASS: png_tb" "$log"; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -Eq "^FAIL \[($arms)\]" "$log"; then
      echo "  $name: caught by $(grep -Em1 "^FAIL \[($arms)\]" "$log" | cut -c1-130)" > "$RES/$name"
    else
      { echo "  $name: failed but NOT in [$arms]: $(grep -m1 "FAIL\|FATAL\|rror" "$log" | cut -c1-130)"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  MUTLIST=$GEN/png/synth.txt
  P=0
  go() { mut "$@" & P=$((P + 1)); if [ $P -ge 8 ]; then wait; P=0; fi; }
  # inflate
  go M1  inflate.sv "wire [15:0] dist_n  = dbase + acc;" "wire [15:0] dist_n  = dbase;" inflate
  go M2  inflate.sv "5'd27: begin lbase = 9'd227; lext = 3'd5; end" "5'd27: begin lbase = 9'd226; lext = 3'd5; end" inflate
  go M3  inflate.sv "src   <= wp - dist_n[14:0];" "src   <= wp - {1'b0, dist_n[13:0]};" inflate
  go M4  inflate.sv "else if (sym_r == 9'd17) rep_n = 8'd3 + {5'd0, acc[2:0]};" \
                    "else if (sym_r == 9'd17) rep_n = 8'd2 + {5'd0, acc[2:0]};" inflate
  go M5  inflate.sv "if (st_len != ~st_nlen) \`FAIL(E_STORED)" "if (1'b0) \`FAIL(E_STORED)" err
  go M6  inflate.sv "wire        set_bad = over || (left_n < 0) ||" "wire        set_bad = 1'b0 ||" err
  go M17 inflate.sv "wire [15:0] s1_n = (s1_a >= 17'd65521) ? (s1_a[15:0] - 16'd65521) : s1_a[15:0];" \
                    "wire [15:0] s1_n = s1_a[15:0];" csum
  # unfilter
  # (the pa/pb tie is an equivalent mutant: with a != b it forces pc = 0, c wins anyway)
  go M7  png_unfilter.sv "((pa <= pb) && (pa <= pc)) ? fa : (pb <= pc) ? fb : fc;" \
                         "((pa <= pb) && (pa < pc)) ? fa : (pb <= pc) ? fb : fc;" unfilter
  go M7b png_unfilter.sv "((pa <= pb) && (pa <= pc)) ? fa : (pb <= pc) ? fb : fc;" \
                         "((pa <= pb) && (pa <= pc)) ? fa : (pb < pc) ? fb : fc;" unfilter
  go M8  png_unfilter.sv "wire [7:0]  avg_half = avg_sum[8:1];" "wire [7:0]  avg_half = {1'b0, avg_sum[7:1]};" unfilter
  go M9  png_unfilter.sv "4'd6: begin a_bpp = a_hist[5]; c_bpp = c_hist[5]; end" \
                         "4'd6: begin a_bpp = a_hist[4]; c_bpp = c_hist[4]; end" unfilter
  go M10 png_unfilter.sv "wire        first_row = (j == 16'd0);" "wire        first_row = (j == 16'd0) && (pass == 3'd0);" unfilter
  # pixel
  go M11 png_pixel.sv "wire [15:0] cur_x = {13'd0, rx0} + (i << rldx);" "wire [15:0] cur_x = {14'd0, rx0[1:0]} + (i << rldx);" pixel
  go M12 png_pixel.sv "idx_in_trns ? alp_q : 8'd255" "idx_in_trns ? alp_q : 8'd0" pixel
  go M13 png_pixel.sv "default: v0 = {12'd0, hb[7:4]};" "default: v0 = {12'd0, hb[3:0]};" pixel
  go M14 png_pixel.sv "5'd2:    g8 = {4{s1_v0[1:0]}};" "5'd2:    g8 = {s1_v0[1:0], 6'd0};" pixel
  go M15 png_pixel.sv "else       hn <= ((rpw - i) < {12'd0, spb}) ? (rpw[3:0] - i[3:0]) : spb;" "else       hn <= spb;" pixel
  go M23 png_pixel.sv "5'd8:    kmask = 16'h00FF;" "5'd8:    kmask = 16'hFFFF;" pixel
  go M18 png_pixel.sv "wire out_free = !px_valid || px_ready;" "wire out_free = 1'b1;" stall
  # chunks / top
  go M16 png_chunks.sv "wire        crc_good = ({clen[23:0], in_byte} == crc_fin);" "wire        crc_good = 1'b1;" csum
  go M19 png_top.sv ".quiet     ((z_ready || i_done) && !f_valid)," ".quiet     (1'b1)," "err|csum"
  go M20 png_chunks.sv "K_IDAT: if (z_done && !abort && !z_ready) warn[W_ZEXTRA] <= 1'b1;" "K_IDAT: ;" warn
  go M21 png_top.sv "wire all_done = finished && (fatal || (i_done && complete && p_idle));" \
                    "wire all_done = finished && (fatal || (i_done && complete && p_idle && !warn_long));" hang
  wait
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

if [ $sweep = 1 ]; then
  echo "== SWEEP: every cached subtitle unit, Verilator + zlib + libpng in-process (bench/umd/png_sweep_main.cpp) =="
  ROOT=$(pwd)
  SW=.sim/png_sweep
  mkdir -p $SW
  command -v verilator >/dev/null || { echo "  FAIL: no verilator"; exit 1; }
  # shellcheck disable=SC2086
  if ! verilator --cc --exe --build -j 8 -O3 --x-assign fast --x-initial fast -Wno-fatal -Wno-lint -Wno-style \
       --top-module png_top -Mdir $SW/obj -o png_sweep -LDFLAGS "-lpng16 -lz" \
       -MAKEFLAGS 'OPT_FAST=-O2 OPT_SLOW=-O1 OPT_GLOBAL=-O2' $RTL "$ROOT/bench/umd/png_sweep_main.cpp" \
       > $SW/build.log 2>&1 || [ ! -x $SW/obj/png_sweep ]; then
    echo "  FAIL: build ($SW/build.log; needs libpng16 and zlib headers)"; tail -3 $SW/build.log; exit 1
  fi
  [ -d $CACHE ] || { echo "  FAIL: no corpus cache ($CACHE): run without --sweep with \$UMD_ISO_DIR first"; exit 1; }
  rm -f $SW/*.list $SW/*.out
  for d in $CACHE/${PNG_SWEEP_MATCH:-*}/; do
    n=$(basename "$d")
    find "$d" -name '*.png' | sort > "$SW/$n.list"
    [ -s "$SW/$n.list" ] || rm -f "$SW/$n.list"
  done
  # the menus' art too (every disc's RCO PNGs: 8 / 4 / 2 / 1-bit indexed, RGBA8, RGB8, Adam7)
  if [ -d $RCO ]; then
    for d in $RCO/${PNG_SWEEP_MATCH:-*}/; do
      n=rco_$(basename "$d")
      find "$d" -maxdepth 1 -name '*.png' | sort > "$SW/$n.list"
      [ -s "$SW/$n.list" ] || rm -f "$SW/$n.list"
    done
  fi
  jobs=${PNG_SWEEP_JOBS:-8}
  # shellcheck disable=SC2016
  ls $SW/*.list | xargs -P "$jobs" -I{} sh -c '"$0"/obj/png_sweep "$1" +label="$(basename "$1" .list)" > "${1%.list}.out" 2>&1' $SW {}
  for o in $SW/*.out; do
    if grep -q "^PASS: png_sweep" "$o"; then echo "  PASS $(grep '^png_sweep' "$o" | sed 's/^png_sweep //')"
    else echo "  FAIL $(basename "$o" .out): $(grep -m1 "FAIL\|rror" "$o" | cut -c1-200)"; fail=1; fi
  done
  grep -h "^ORACLE" $SW/*.out | head -5
  awk '/^png_sweep/ {u += $3; b += $10} END {printf "  sweep total: %d units\n", u}' $SW/*.out
  if [ $red = 1 ]; then
    # the sweep harness can fail too: M13 (nibble order) built into it, on the smallest disc
    MD=$SW/mut
    rm -rf $MD; mkdir -p $MD
    cp umd/png/*.sv $MD/
    sed -i 's/default: v0 = {12'"'"'d0, hb\[7:4\]};/default: v0 = {12'"'"'d0, hb[3:0]};/' $MD/png_pixel.sv
    small=$(ls -S $SW/*.list | tail -1)
    # shellcheck disable=SC2086
    if grep -q "hb\[3:0\]" $MD/png_pixel.sv && (cd $MD && verilator --cc --exe --build -j 8 -O1 -Wno-fatal -Wno-lint -Wno-style \
         --top-module png_top -Mdir obj -o png_sweep -LDFLAGS "-lpng16 -lz" \
         png_pkg.sv inflate.sv png_chunks.sv png_unfilter.sv png_pixel.sv png_top.sv "$ROOT/bench/umd/png_sweep_main.cpp" \
         > build.log 2>&1) && [ -x $MD/obj/png_sweep ]; then
      if $MD/obj/png_sweep "$small" > $MD/out 2>&1; then echo "  sweep RED: M13 SURVIVED the sweep harness"; fail=1
      elif grep -q "^FAIL \[pixel\]" $MD/out; then echo "  sweep RED: M13 caught by $(grep -m1 '^FAIL' $MD/out | cut -c1-120)"
      else echo "  sweep RED: M13 failed but not in [pixel]: $(grep -m1 'FAIL\|rror' $MD/out)"; fail=1; fi
    else echo "  sweep RED: harness failure (anchor or build)"; fail=1; fi
  fi
fi

echo "== lint =="
# shellcheck disable=SC2086
if verilator --lint-only -Wall -Wno-DECLFILENAME --top-module png_top $RTL > .sim/png_lint.log 2>&1; then
  echo "  PASS verilator --lint-only -Wall"
else echo "  FAIL lint"; grep -m8 "%Warning\|%Error" .sim/png_lint.log; fail=1; fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
