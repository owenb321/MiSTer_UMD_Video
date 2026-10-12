#!/usr/bin/env bash
# run_umd_reader.sh -- the reader gate (umd/umd_reader.sv, bench/umd/umd_reader_tb.sv):
# the P2 walk, and P6b2's IN / OUT and navigation port (docs/transport.md S2.4)
#
# GREEN:
#   * every synthetic case of tools/umd_reader_cases.py (edges no disc has, one image
#     per refusal, and the navigation cases: syn_nav, syn_marks_max -- 65,535 marks, ~90 s
#     -- syn_badmarks, syn_oobmarks), and syn_basic / syn_multi again with +restart (a
#     second mount in the middle of a stream transfer), and syn_basic with +hold (fj#64: the reset
#     with the image's size held and no start leaves the reader idle: no read, nothing streamed);
#   * every disc image under ${UMD_ISO_DIR:-~/umd-isos} (subdirectories too: multi-disc
#     sets): an --nav fixture per disc -- the walk's sectors, the first 64 stream packs
#     (IN / OUT applied), and a navigation script (umd_fixture.disc_script, seeded by the
#     file name): chapter queries, eight seeks (half of them mid-transfer), a chapter's
#     landing, the tail of the first and last items to OUT / the title's end, a seek
#     after title_done, P9's PLAY (a playlist that does not exist; another playlist of
#     the disc, chosen by the seed, with a chapter query and a seek on it, an item past
#     its last; the feature again), P6c's Go To by time (random, 0, each item boundary and the
#     tick before it, the end and past it, one on the other playlist), a bad item. Goldens from
#     the P1 parsers and tools/umd_nav_ref.py.
#     SKIP, loudly, when there is no image. UMD_JOBS discs at a time (default 6).
#     P8 (docs/bare_streams.md): per disc also two BARE files -- the main clip's first 64
#     packs as a bare .MPS, and the disc's UMD_VIDEO/ICON1.PMF whole (a real PSMF, Sony's
#     own; none on 23 of 88 discs) -- each a fixture whose image is that file
#     (umd_fixture.bare_fixture: goldens from psmf_ref), with the refused navigation script.
#   * the CHAIN (bench/umd/p2_chain_tb.sv): umd_reader -> ps_stream_fifo -> ps_demux ->
#     es_probe as emu.sv composes it, on syn_basic and on every disc's fixture, scored on
#     es_probe's byte counts and video CRC against psmf_ref (tools/psmf_golden.py --chain)
# Each run must print the PASS marker (a bench that dies early prints nothing, and a
# `$finish` on a failure path exits 0). The simulators are deleted before they are built:
# a failed build must not leave the last run's binary to "pass".
#
# --red [MUTS="N6 N13" to run only those]: each mutation is applied to a COPY of umd_reader.sv and must make the arm named
# for it FAIL, on the synthetic set (no media needed):
#   R1  the first playlist wins, not the longest     -> [pick]    syn_basic
#   R2  a ";1" version suffix never matches          -> [nav]     syn_basic (no PLAYLIST.UMD)
#   R3  TITLE taken by entry index, not by key        -> [title]   syn_basic (PSP_SYSTEM_VER)
#   R4  the shadow fetch never crosses a sector       -> [pick]    syn_multi (straddling item)
#   R5  every extent ends the item (no continuation)  -> [stream]  syn_multi
#   R6  cache write address 9 bits (P0 alias bug)     -> [stream]  syn_basic
#   R7  subtitles 0x80-0x8F only                      -> [tracks]  syn_basic (0x9C)
#   R8  missing UMD_VIDEO reported as "not ISO"       -> [err]     err_no_umdv
#   R9  title_done never raised                       -> [done]    syn_basic
#   R10 S_SECREAD issues over a transfer in flight    -> [restart] syn_basic +restart (only: the
#       plain run's mid-transfer seek meets the same lock first, as [nav])
#   R11 an extent's sector count rounds up once more  -> [walk]    syn_basic (reads past the .MPS)
#   R12 the clip's end PTS read from its start field  -> [clip]    syn_basic
#   R13 the CLP skipped: straight to STREAM/          -> [order]   syn_basic
#   R14 parse_buf residency ignored (re-read always)  -> [thrash]  syn_basic
#   P6b2, the navigation port and IN / OUT:
#   N1  IN not applied: the walk starts every item at its first entry -> [stream] syn_nav
#   N2  OUT not applied: no stop                       -> [stream]  syn_nav (the stop, then item 1)
#   N3  the video map assumed to be map 0              -> [stream]  syn_nav (a subtitle map first)
#   N4  the stop at the first entry AFTER OUT, not at   -> [stream]  syn_nav (OUT on an entry)
#   N5  a start lookup at the last entry BEFORE t      -> [seek]    syn_basic (an exact hit)
#   N6  no floor at entry 0 for a target before it     -> [seek]    syn_nav (a one-entry map; since P6b5
#       [base] may see it first: the wrong landing starts the wrong item)
#   N7  a seek's target not clamped to IN               -> [seek]    syn_nav
#   N8  a start beyond the first extent is "past"      -> [seek]    syn_multi (entries in extents 2, 3; since
#       P8's sniff read shifts the bench's random latencies [base] may see it first: the wrong landing
#       starts the wrong item)
#   N9  a seek does not empty the cache                 -> [stream]  syn_basic (mid-transfer)
#   N10 a seek to a missing item is not refused         -> [seek]    syn_basic (answered as landed: NE_NONE)
#   N11 Endmarks counted as chapters                    -> [chap]    syn_nav
#   N12 marks on a missing item counted                 -> [chap]    syn_nav
#   N13 prev not moved down when cur is replaced        -> [chap]    syn_nav
#   N14 next keeps the LARGEST key after the query      -> [chap]    syn_nav
#   N15 the scan reads the last playlist's marks        -> [chap]    syn_basic (#2 has none)
#   N16 marks fetched 48 bytes, not 40                  -> [chap]    syn_marks_max (sector reads)
#   N17 a marks run-off is fatal (E_PL)                 -> [nav]     syn_oobmarks
#   N18 the marks length not checked                    -> [chap]    syn_badmarks
#   N19 OUT >= 2^32 not flagged                         -> [seek]    syn_nav
#   N20 an entry past the clip streams anyway           -> [seek]    syn_nav (not NE_PAST)
#   N21 a reserved op never answered                    -> [op]      syn_nav
#   N22 the seek's item walk drops the length field     -> [nav]     syn_nav (a misread record: E_PL)
#   N23 a seek leaves title_done up                     -> [done]    syn_basic (checked at the accepting edge)
#   N24 a chapter query never served from S_DONE        -> [chap]    syn_nav (queries after the end)
#   N25 every byte tagged item 0 (P6b3i)                -> [stream]  syn_multi (3 items)
#   N26 the walk starts an item under item_hold (P6b3i) -> [hold]    syn_multi
#   N27 a seek's target clamped to OUT - 1, not OUT - 4 (P6b4's clamp: the display skipped the
#       title's last picture; fix/skip-last-picture)  -> [seek]  syn_nav
#   N33 a seek's target clamped to OUT itself (an entry at OUT: nothing shown) -> [seek] syn_nav
#   N28 a seek's walk keeps the stream's base (P6b5)    -> [base]    syn_nav (seeks into every item)
#   N29 a seek's walk adds nothing for the items it passes (P6b5) -> [base] syn_nav
#   N30 the stream's next item adds nothing (P6b5)      -> [base]    syn_multi (3 items walked)
#   N31 the chapter scan's prev step ignores its compare (P6b5's one comparator) -> [chap] syn_nav
#   N32 the key's + 1 lost: a mark AT the key counted after it (P6b5)          -> [chap] syn_nav
#   P9's NAV_PLAY (docs/p9.md S3.2, P9-2), all on syn_nav (a trailer playlist sharing the
#   feature's clip, an empty playlist, the feature again):
#   P1  a playlist that does not exist is not refused   -> [nav]     (the forced table walk finds none: E_PL)
#   P2  the longest playlist chosen, not the forced one -> [play] / [stream]
#   P3  an item past the playlist's last not clamped    -> [nav]     (the item walk runs off the table: E_PL)
#   P4  a PLAY does not flush the output pipe           -> [stream]  (stale bytes: found by this bench)
#   P5  the clamp's NE_ITEM overwritten at the landing  -> [play]
#   P6  an empty playlist never answered                -> [play]
#   P7  an empty playlist reports the old item count    -> [play]
#   P8  the landing's item_base keeps the old walk's    -> [play]
#   P6c's NAV_TIME (Go To by the playlist's time), all on syn_nav:
#   T1  a time ON an item boundary taken as the earlier item -> [time]
#   T2  the walk never subtracts the spans it passes     -> [time]
#   T3  past the end: no stop at the last item           -> [time] / [nav] (the walk runs off the table)
#   T4  past the end: IN + the rest, not OUT (wraps)     -> [time]  (the trailer: one item, the largest time)
#   T5  a TIME does not flush the output pipe            -> [stream]
#   T6  a TIME accepted on a playlist with no item       -> [time] / [nav]
#   T7  a TIME stops at the seek's item (nav_item)       -> [time]
#   P8, bare streams (the synthetic syn_bare_* / syn_pmf* / err_pmf_* / err_bare_huge):
#   B1  a .PMF streamed from sector 0 (its header as stream bytes) -> [walk]  syn_pmf (the header
#       sector is no stream region)
#   B2  an unaligned PSMF stream offset accepted         -> [err]     err_pmf_unaligned
#   B3  an image's 17-sector minimum before the sniff     -> [nav]     syn_bare_small (E_SMALL)
#   B4  pmf_warn never raised                             -> [bare]    syn_pmf_cut
#   B5  a SEEK taken on a bare stream (a flush, a playlist walk) -> [walk] syn_bare_mps
#   B6  a CHAP on a bare stream scans marks                -> [chap]    syn_bare_mps (never answered)
#   B7  no sniff: the walk starts at LBA 16                -> [sniff]   syn_basic
#   B8  a PSMF stream not stopped at its header's size     -> [walk]    syn_pmf_short
#   B9  a bare stream's SEEK refused as NE_ITEM            -> [seek]    syn_bare_mps
#   B10 a bare file's IN not 90000 (the mount's constant)  -> [clip]    syn_bare_mps
#   B11 a bare file's item count (best_n) not the mount's 1 -> [walk]|[done] syn_bare_mps (the title
#       not ended after its one item)
#   B12 a bare file's item count not the mount's 1         -> [clip]    syn_bare_mps
#   E10 (fj#64) the engine's reset to the START vector (pc 0): a reset with the image held -- the
#       OSD's Reset -- walks and plays the disc   -> [reset]   syn_basic +hold
#   C1  umd_reader ignores busy                        -> [chain]   syn_basic (bytes pushed
#       into a full FIFO are dropped). NOT a mutation of the FIFO's almost_full margin:
#       the reader reads busy combinationally and issues one byte per two clocks, so a
#       FIFO flagging full only at DEPTH still never overflows -- tried, and it survived,
#       because it is not a defect for this pair (the DEPTH-2 margin is for a
#       registered-busy source like MiSTer_DVD's streamer).
set -u
cd "$(dirname "$0")/../.."
mkdir -p .sim/reader
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1
GEN=bench/umd/fixtures/gen
ISO_DIR=${UMD_ISO_DIR:-$HOME/umd-isos}
JOBS=${UMD_JOBS:-6}

python3 tools/umd_reader_cases.py --dir "$GEN" > .sim/reader_cases.txt || { echo "  FAIL case generation"; exit 1; }
SYN=$(cat .sim/reader_cases.txt)

run_one() {   # sim  log  stem  [plusargs]  -> 0 on PASS
  local sim=$1 log=$2 stem=$3; shift 3
  vvp -n "$sim" +stem="$stem" "$@" 2>&1 | grep -v '^VCD\|readmem\|Not enough words' > "$log"
  grep -q "^PASS: umd_reader_tb" "$log"
}

rm -f .sim/umd_reader_sim .sim/p2_chain_sim
iverilog -g2012 -o .sim/umd_reader_sim umd/nav/nav_seq.sv umd/umd_reader.sv bench/umd/umd_reader_tb.sv \
  || { echo "  FAIL umd_reader_tb: build"; exit 1; }

CHAIN_SRC="umd/nav/nav_seq.sv umd/umd_reader.sv umd/ps_stream_fifo.sv umd/ps_demux.sv umd/es_probe.sv bench/umd/p2_chain_tb.sv"
# shellcheck disable=SC2086
iverilog -g2012 -o .sim/p2_chain_sim $CHAIN_SRC || { echo "  FAIL p2_chain_tb: build"; exit 1; }
chain_one() {   # stem label log  -> prints one line; returns 1 on FAIL
  local L=$3
  python3 tools/psmf_golden.py --chain "$GEN/$1" > "$L.cfx" 2>&1
  local rc=$?
  if [ $rc = 3 ]; then          # all-zero stream packs: a damaged image, said out loud
    echo "$2 SKIP: $(tail -1 "$L.cfx")"; return 0
  elif [ $rc != 0 ]; then
    echo "$2 FAIL: golden: $(tail -1 "$L.cfx")"; return 1
  fi
  vvp -n .sim/p2_chain_sim +stem="$GEN/$1" +golden="$GEN/${1}_chain" 2>&1 | grep -v 'readmem\|Not enough' > "$L.chain"
  if grep -q "^PASS: p2_chain_tb" "$L.chain"; then
    echo "$2 PASS: $(grep '^p2_chain_tb:' "$L.chain" | sed 's/^p2_chain_tb: //')"
  else echo "$2 FAIL"; grep FAIL "$L.chain" | head -3; return 1; fi
}

# one job: a synthetic case (and its +restart run)
syn_job() {   # case  -> .sim/reader/<case>.sum
  local c=$1 L=.sim/reader/$1 ok=0
  {
    if run_one .sim/umd_reader_sim "$L.log" "$GEN/$c"; then
      echo "  PASS $c: $(grep '^umd_reader_tb:' "$L.log" | sed 's/.*gen\/[a-z_]* //' | tr -s ' ')"
    else echo "  FAIL $c"; grep FAIL "$L.log" | head -3; ok=1; fi
    if [ "$c" = syn_basic ]; then
      if run_one .sim/umd_reader_sim "$L.hold.log" "$GEN/$c" +hold; then echo "  PASS $c +hold (fj#64: idle after a reset, the image held)"
      else echo "  FAIL $c +hold"; grep FAIL "$L.hold.log" | head -3; ok=1; fi
    fi
    case $c in syn_basic|syn_multi|syn_bare_mps|syn_pmf)
      if run_one .sim/umd_reader_sim "$L.rs.log" "$GEN/$c" +restart; then echo "  PASS $c +restart"
      else echo "  FAIL $c +restart"; grep FAIL "$L.rs.log" | head -3; ok=1; fi ;;
    esac
    [ "$c" = syn_basic ] && { chain_one syn_basic "  chain syn_basic:" "$L" || ok=1; }
  } > "$L.sum"
  return $ok
}

# one job: a disc image
disc_job() {   # n iso  -> .sim/reader/disc_<n>.sum
  local n=$1 iso=$2 L=.sim/reader/disc_$1 seed ok=0
  seed=$(basename "$iso" | cksum | cut -d' ' -f1)
  {
    if ! python3 tools/umd_fixture.py "$iso" --nav --stream-packs 64 --nav-seed "$seed" \
           --out "disc_$n" --dir "$GEN" > "$L.fx" 2>&1; then
      echo "  FAIL $(basename "$iso"): fixture: $(tail -1 "$L.fx")"; exit 1
    fi
    if run_one .sim/umd_reader_sim "$L.log" "$GEN/disc_$n"; then
      echo "  PASS $(basename "$iso"): $(grep '^umd_reader_tb:' "$L.log" | sed 's/.*disc_[0-9]* //' | tr -s ' ')"
    else echo "  FAIL $(basename "$iso")"; grep FAIL "$L.log" | head -3; ok=1; fi
    chain_one "disc_$n" "  chain" "$L" || ok=1
    # P8: the main clip's head as a bare .MPS, and ICON1.PMF as a bare .PMF
    local b rc
    for b in mps pmf; do
      if [ $b = mps ]; then python3 tools/umd_fixture.py "$iso" --bare-mps 64 --out "discb${b}_$n" --dir "$GEN" > "$L.$b.fx" 2>&1
      else python3 tools/umd_fixture.py "$iso" --bare-pmf --out "discb${b}_$n" --dir "$GEN" > "$L.$b.fx" 2>&1; fi
      rc=$?
      if [ $rc = 3 ]; then echo "  bare $b: none on this disc"; continue
      elif [ $rc != 0 ]; then echo "  FAIL bare $b fixture: $(tail -1 "$L.$b.fx")"; ok=1; continue; fi
      if run_one .sim/umd_reader_sim "$L.$b.log" "$GEN/discb${b}_$n"; then
        echo "  PASS bare $b: $(grep '^umd_reader_tb:' "$L.$b.log" | sed 's/.*discb[a-z]*_[0-9]* //' | tr -s ' ')"
      else echo "  FAIL bare $b"; grep FAIL "$L.$b.log" | head -3; ok=1; fi
    done
    exit $ok
  } > "$L.sum"
}

# JOBS at a time; every job's summary printed in order afterwards
throttle() { while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do wait -n; done; }

rm -f .sim/reader/*.sum
# one pool for both sets (syn_marks_max's ~90 s must not hold the discs back)
mapfile -t ISOS < <(find "$ISO_DIR" -type f -iname '*.iso' 2>/dev/null | sort)
for c in $SYN; do throttle; syn_job "$c" & done
n=0
for iso in "${ISOS[@]}"; do n=$((n + 1)); throttle; disc_job "$n" "$iso" & done
wait
echo "== GREEN: synthetic =="
for c in $SYN; do cat ".sim/reader/$c.sum"; done
grep -q FAIL $(for c in $SYN; do echo ".sim/reader/$c.sum"; done) && fail=1

echo "== GREEN: disc images in \$UMD_ISO_DIR =="
for k in $(seq 1 $n); do cat ".sim/reader/disc_$k.sum"; done
[ $n -gt 0 ] && grep -q FAIL .sim/reader/disc_*.sum && fail=1
[ $n = 0 ] && echo "  SKIP: no disc image in $ISO_DIR (set UMD_ISO_DIR)"

if [ $red = 1 ]; then
  echo "== MUTATIONS (each must be caught by its own arm) =="
  echo "  (A12: the walk's and the navigation's arms are the program's -- bench/umd/run_nav_model.sh --red;"
  echo "   here: the reader's hardware -- the pump, the slots, the take, the guard -- and the engine)"
  RES=$(mktemp -d)
  mut() {   # name  file  old  new  arm-pattern  fixture-runs...   (file: umd_reader.sv or nav_seq.sv)
    local name=$1 file=$2 old=$3 new=$4 pat=$5; shift 5
    if [ -n "${MUTS:-}" ] && ! echo " $MUTS " | grep -q " $name "; then return; fi
    local d; d=$(mktemp -d)
    cp umd/umd_reader.sv umd/nav/nav_seq.sv "$d/"
    python3 - "$d" "$file" "$old" "$new" <<'PYEOF'
import sys, os
d, f, old, new = sys.argv[1:5]
old = old.replace('\\n', '\n'); new = new.replace('\\n', '\n')
p = os.path.join(d, f)
s = open(p).read()
assert s.count(old) == 1, f"mutation anchor not unique/found: {old!r}"
open(p, "w").write(s.replace(old, new))
PYEOF
    if [ $? != 0 ] || ! iverilog -g2012 -o "$d/sim" "$d/nav_seq.sv" "$d/umd_reader.sv" bench/umd/umd_reader_tb.sv 2>"$d/build.log"; then
      { echo "  $name: harness failure (anchor or build)"; echo MUTFAIL; } > "$RES/$name"; rm -rf "$d"; return
    fi
    local run caught="" rs
    for run in "$@"; do                 # "stem" or "stem +plusarg"
      read -r -a rs <<< "$run"
      vvp -n "$d/sim" +stem="$GEN/${rs[0]}" "${rs[@]:1}" 2>&1 | grep -v '^VCD\|readmem\|Not enough' > "$d/log"
      if ! grep -q "^PASS: umd_reader_tb" "$d/log"; then caught=$run; break; fi
    done
    if [ -z "$caught" ]; then
      { echo "  $name: SURVIVED -- the bench cannot see this defect"; echo MUTFAIL; } > "$RES/$name"
    elif grep -q "FAIL $pat" "$d/log"; then
      echo "  $name: caught on $caught by $(grep -m1 "FAIL $pat" "$d/log" | cut -c1-90)" > "$RES/$name"
    else
      { echo "  $name: failed on $caught but NOT in the expected arm ($pat):"; grep -m2 "FAIL" "$d/log"; echo MUTFAIL; } > "$RES/$name"
    fi
    rm -rf "$d"
  }
  R=umd_reader.sv; E=nav_seq.sv
  # ---- the reader's hardware (the RTL bench's names where the defect is the same) ----
  mut R6 $R "cache_mem[{wr_ptr[CACHE_AW-1:11], sd_buff_addr[10:0]}]" "cache_mem[{wr_ptr[CACHE_AW-1:11], 2'b00, sd_buff_addr[8:0]}]" '\[stream\]' syn_basic &
  mut R10 $R "FB_MISS: if (!rq_busy && !rq_done) begin" "FB_MISS: if (!rq_done) begin" '\[restart\]' "syn_basic +restart" "syn_multi +restart" &
  mut R14 $R "end else if (hit0 || hit1) begin" "end else if ((hit0 || hit1) && fb_sec[31:0] == 32'd0) begin" '\[thrash\]' syn_basic syn_multi &
  mut N9 $R "                    wr_ptr <= 0;                        //   streaming, title_done; the pump" "                    //   streaming, title_done; the pump" '\[stream\]' syn_basic &
  mut N10 $R "(nav_op == NAV_SEEK && nav_item < acc_items)" "(nav_op == NAV_SEEK)" '\[seek\] command [0-9]*: nav_err' syn_basic &
  mut P1 $R "(nav_op == NAV_PLAY && nav_pl < n_playlists)" "(nav_op == NAV_PLAY)" '\[nav\] walk ended in err_code 6' syn_nav &
  mut T6 $R "(nav_op == NAV_TIME && acc_items != 32'd0)" "(nav_op == NAV_TIME)" '\(\[time\]\|\[nav\]\)' syn_nav &
  mut B5 $R "wire   take_acc  = nav_take && (bare == 2'd0) &&" "wire   take_acc  = nav_take &&" '\(\[walk\]\|\[nav\]\|\[seek\]\)' syn_bare_mps &
  mut N25 $R "slot_ep[wr_ptr[CACHE_AW-1:11]] <= p_tag;" "slot_ep[wr_ptr[CACHE_AW-1:11]] <= 2'd0;" '\[stream\]' syn_multi &
  mut N26 $R "if (!(state == 6'd27 && io_wdata[5:0] == 6'd28 && item_hold))" "if (1'b1)" '\[hold\]' syn_multi &
  mut P4 $R "end else if (start || stop || take_acc) begin   // an accepted SEEK / TIME / PLAY flushes" "end else if (start || stop) begin" '\[stream\]' syn_nav &
  mut N23 $R "                    title_done <= 1'b0;\n                end\n            end" "                end\n            end" '\[done\]' syn_basic &
  mut H2 $R "if ((p_clip_lim && p_clip_left == 32'd0) || p_left == 32'd0)" "if (p_left == 32'd0)" '\(\[stream\]\|\[walk\]\)' syn_nav &
  mut H3 $R "assign eng_status = {9'd0, stopped, accepted, item_hold, !item_hold, !cache_has_data, pump_idle, pend};" "assign eng_status = {9'd0, stopped, accepted, item_hold, !item_hold, 1'b1, pump_idle, pend};" '\[done\]' syn_basic &
  # ---- the engine (nav_seq.sv): its instruction set as tools/nav_isa.py defines it ----
  mut E1 $E "wire        cin   = (fn == F_ADC) ? c :" "wire        cin   = (fn == F_ADC) ? 1'b0 :" '\[base\]' syn_wide &
  mut E2 $E "(fn == F_SBC) ? !c : subop;" "(fn == F_SBC) ? 1'b1 : subop;" '\[' syn_basic syn_multi syn_nav &
  mut E3 $E "else             lb_acc <= lb_acc | ({24'd0, fb_byte} << {lb_k, 3'b000});" "else             lb_acc <= {lb_acc[23:0], fb_byte};" '\[' syn_basic &
  mut E4 $E "O_RET: begin npc <= stk[sp - 3'd1]; sp <= sp - 3'd1; end" "O_RET: begin npc <= stk[sp]; sp <= sp - 3'd1; end" '\[' syn_basic &
  mut E5 $E "sh_in[k] = (fn == F_SHL) ? ra[31 - k] : ra[k];" "sh_in[k] = ra[k];" '\[' syn_basic &
  mut E6 $E "O_WAIT: if ((status & imm) == 16'd0) st <= SC;   // stall" "O_WAIT: ;" '\[' syn_basic &
  mut E7 $E "wire [31:0] cmp_b = (op == O_BR) ? rb : {22'd0, rt, aux};" "wire [31:0] cmp_b = (op == O_BR) ? rb : {22'd0, aux, rt};" '\[' syn_basic &
  mut E8 $E "wire        ltu   = (ra < cmp_b);" "wire        ltu   = (ra <= cmp_b);" '\[' syn_basic syn_multi syn_nav &
  mut E9 $E "        if (c_we) c <= c_next;" "" '\[' syn_basic syn_multi syn_nav &
  mut E10 $E "st <= SA; pc <= 11'd1; sp <= 3'd0; c <= 1'b0;" "st <= SA; pc <= 11'd0; sp <= 3'd0; c <= 1'b0;" '\[reset\]' "syn_basic +hold" &
  wait
  # C1: the reader ignores busy -- on a COPY of umd_reader.sv, through the chain
  d=$(mktemp -d)
  sed 's/if (!busy \&\& !read_valid_pipe \&\& cache_has_data) begin/if (!read_valid_pipe \&\& cache_has_data) begin/' umd/umd_reader.sv > "$d/umd_reader.sv"
  if cmp -s umd/umd_reader.sv "$d/umd_reader.sv"; then { echo "  C1: anchor missed"; echo MUTFAIL; } > "$RES/C1"
  else
    iverilog -g2012 -o "$d/sim" umd/nav/nav_seq.sv "$d/umd_reader.sv" umd/ps_stream_fifo.sv umd/ps_demux.sv umd/es_probe.sv bench/umd/p2_chain_tb.sv
    vvp -n "$d/sim" +stem="$GEN/syn_basic" +golden="$GEN/syn_basic_chain" 2>&1 | grep -v 'readmem\|Not enough' > "$d/log"
    if grep -q "^PASS: p2_chain_tb" "$d/log"; then { echo "  C1: SURVIVED -- the chain cannot see a reader that ignores busy"; echo MUTFAIL; } > "$RES/C1"
    elif grep -q "FAIL \[chain\]" "$d/log"; then echo "  C1: caught on syn_basic by $(grep -m1 'FAIL \[chain\]' "$d/log" | cut -c1-70)" > "$RES/C1"
    else { echo "  C1: failed but NOT in [chain]"; grep -m2 FAIL "$d/log"; echo MUTFAIL; } > "$RES/C1"; fi
  fi
  rm -rf "$d"
  for f in $(ls "$RES" | sort -V); do grep -v '^MUTFAIL$' "$RES/$f"; grep -q '^MUTFAIL$' "$RES/$f" && fail=1; done
  rm -rf "$RES"
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
