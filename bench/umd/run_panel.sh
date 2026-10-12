#!/usr/bin/env bash
# run_panel.sh -- P6d C2 (docs/panel.md §4): the UMD Main's control panel on the PC.
# main/support/umd/umd_panel.c, through bench/umd/panel/panel_check.c, against tools/panel_ref.py (the
# decisions, written from the PSP measurements) and tools/panel_layout.py's page() (the pixels, the
# approved mockups' model), scored by bench/umd/panel/panel_bench.py: directed scripts per rule group,
# 40 seeded random walks (their coverage checked), every item drawn in playback and over a disc menu,
# over an empty page, a subtitle and a random page, in both byte orders, the rectangle.
# The model's own tests are tools/tests/test_panel_ref.py (run first: a stale art file fails there).
# [run] (C4): the panel inside the UMD Main's runner (umd_menu_run.c), no disc, through
# bench/umd/panel/panel_run_check.c: the levels, the keys' routing, the actions, the page (planes 2 / 3,
# the subtitle under it, the union rectangle), the close.
# --red: mutations of a COPY of umd_panel.* (compiled inside the copy), each caught by its own arm;
# R1-R12 the same for umd_menu_run.c against [run] (R13 A12 SD2's core rectangle; R14-R17 fj#71 Zoom: the
# subtitle under the panel placed inside the band, its vacated rows cleared, a Zoom change redrawing, the tall case). P28-P31 A-B Repeat's row 3 (docs/ab_repeat.md AB8): ^ walking
# down, a dark row not skipped, A-B Repeat's press and Clear's command. P32 the Pause item injecting Select
# (a toggle since 2026-10-07) instead of the command PAUSE.
set -u
cd "$(dirname "$0")/../.."
O=.sim/panel
mkdir -p $O
fail=0
red=0; [ "${1:-}" = "--red" ] && red=1

build() {   # out srcdir
  cc -O2 -std=c99 -Wall -Wextra -Werror -I"$2" -o "$1" bench/umd/panel/panel_check.c "$2/umd_panel.c" "$2/umd_panel_art.c"
}
build_run() {   # out srcdir (a copy of main/support/umd with menu/)
  local m=$2
  cc -O2 -std=c99 -Wall -Wextra -Werror -D_FILE_OFFSET_BITS=64 -D_POSIX_C_SOURCE=200809L -I"$m" -I"$m/menu" -o "$1" \
     bench/umd/panel/panel_run_check.c "$m/menu/rco.c" "$m/menu/vsmx.c" "$m/menu/menu.c" "$m/menu/vag.c" \
     "$m/menu/umd_iso.c" "$m/menu/umd_playlist.c" "$m/umd_menu_host.c" "$m/umd_menu_logic.c" "$m/umd_menu_run.c" \
     "$m/umd_panel.c" "$m/umd_panel_art.c" "$m/umd_disc_screen.c" -lz -lm
}

echo "== the model =="
if python3 tools/tests/test_panel_ref.py > $O/model.log 2>&1 && grep -q "ALL GREEN" $O/model.log; then echo "  PASS"
else echo "  FAIL"; head -5 $O/model.log; fail=1; fi

echo "== GREEN =="
rm -f $O/check
build $O/check main/support/umd 2>&1 | head -10
if [ -x $O/check ] && python3 bench/umd/panel/panel_bench.py $O/check $O/tmp > $O/green.log 2>&1 \
   && grep -q "^PASS panel_bench" $O/green.log; then
  grep "^PASS" $O/green.log | sed 's/^/  /'
else echo "  FAIL"; grep "^FAIL" $O/green.log | head -5; fail=1; fi

echo "== [run]: the panel in the runner =="
rm -f $O/run_check
build_run $O/run_check main/support/umd 2>&1 | head -10
if [ -x $O/run_check ] && $O/run_check > $O/run.log 2>&1 && grep -q "^PASS: panel_run_check" $O/run.log; then
  grep "^panel_run_check:" $O/run.log | sed 's/^/  /'; echo "  PASS"
else echo "  FAIL"; grep "^FAIL" $O/run.log | head -5; fail=1; fi

if [ $red = 1 ]; then
  echo "== RED: mutations of main/support/umd/umd_panel.c (each caught by its own arm) =="
  # id | arms (/-separated) | old -> new (python replace in umd_panel.c, exactly once, \n \t unescaped; no "|" inside)
  while IFS='|' read -r id arms old new; do
    [ -z "$id" ] && continue
    d=$O/red/$id; rm -rf "$d"; mkdir -p "$d"; cp main/support/umd/umd_panel.[ch] main/support/umd/umd_panel_art.[ch] "$d/"
    if ! python3 - "$d/umd_panel.c" "$old" "$new" <<'EOF'
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
    python3 bench/umd/panel/panel_bench.py "$d/check" "$d/tmp" > "$d/run.log" 2>&1
    arms=${arms//\//|}
    if grep -Eq "^FAIL \[($arms)\]" "$d/run.log"; then echo "  caught $id by $(grep -Em1 "^FAIL \[($arms)\]" "$d/run.log" | cut -c1-110)"
    else echo "  SURVIVED $id (want [$arms]): $(grep -m1 '^FAIL\|^PASS' "$d/run.log" | cut -c1-110)"; fail=1; fi
  done <<'MUT'
P1|open|p->sel = UMD_PANEL_START;     // K8|p->sel = UMD_PI_MENU;     // K8
P2|walk|((c + step * k) % n + n) % n|(c + step * k < 0 ? 0 : c + step * k >= n ? n - 1 : c + step * k)
P3|walk|if (umd_panel_available(p, cand)) { p->sel = cand; return; }|{ p->sel = cand; return; }
P4|walk|d < bd) { best = j; bd = d; }|d <= bd) { best = j; bd = d; }
P5|act/close|p->sel == UMD_PI_STOP) close_panel(p);|p->sel == -1) close_panel(p);
P6|goto|if (p->quiet >= UMD_PANEL_RETURN_READS) {|if (p->quiet >= 1) {
P7|goto|now - p->g_since >= UMD_PANEL_GOTO_OPEN_MS|now - p->g_since > UMD_PANEL_GOTO_OPEN_MS
P8|act|a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_PLAY; break;|a->arg = B(UMD_PB_PLAYPAUSE); break;
P9|open|*grab = UMD_PANEL_GRAB_OPEN;|*grab = UMD_PANEL_GRAB_OPEN & ~B(UMD_PB_STOP);
P10|close|(!rd->menu_up != !prev.menu_up)|(!rd->menu_up != !prev.menu_up && 0)
P11|goto|*grab = B(UMD_PB_PANEL);          // the editor|*grab = UMD_PANEL_GRAB_OPEN;          // the editor
P12|act|case UMD_PI_FF:      a->arg = B(UMD_PB_RIGHT); break;|case UMD_PI_FF:      a->arg = B(UMD_PB_LEFT); break;
P13|menu|if (p->menu_mode) a->kind = UMD_PA_QUIT;|if (0) a->kind = UMD_PA_QUIT;
P14|dark|if (!umd_panel_available(p, p->sel)) return 0;              // (it went dark|// (it went dark
P15|goto|if (p->hidden) return 0;\n\tswitch (b) {|switch (b) {
P16|goto|if (!p->hidden && rd->goto_open) hide(p);|(void)0;
P17|menu|return (i == UMD_PI_MENU && p->rd.engine)|return (i == UMD_PI_MENU && p->rd.engine) + (i == UMD_PI_GOTO)
P18|open|if (b == UMD_PB_PANEL && (p->rd.state != 0|if (b == UMD_PB_PANEL && (1
P19|pixels|else if (c == 3) over(|else if (c == 4) over(
P20|pixels|+ UMD_PANEL_HALO_DEN / 2) / UMD_PANEL_HALO_DEN;|) / UMD_PANEL_HALO_DEN;
P21|pixels|(n * UMD_PANEL_BOX_A8 + 8) / 16);|(n * UMD_PANEL_BOX_A8) / 16);
P22|plane|int ir = layout == UMD_PANEL_PX_PLANE ? 2 : 0, ib = 2 - ir;|int ir = layout == UMD_PANEL_PX_PLANE ? 0 : 0, ib = 2 - ir;
P23|under|int v = s[c] + rnd255(q[ix[c]] * (255 - a));|int v = s[c] + q[ix[c]] * (255 - a) / 255;
P24|pixels|const int *rgb = umd_panel_available(p, p->sel) ? WHITE : DARK;|const int *rgb = WHITE;
P25|rect|*w = UMD_PANEL_BOX_W;|*w = UMD_PANEL_BOX_W - 8;
P26|random/walk/open|1u << (8 + i);|0u;
P27|pixels|rgb = umd_panel_available(p, i) ? GREY : DARK;|rgb = GREY;
P28|walk|int r = ((r0 + step * k) % NROWS + NROWS) % NROWS, n = row_n(r);|int r = (r0 + k + 0 * step) % NROWS, n = row_n(r);
P29|walk/menu/random|if (best >= 0) { p->sel = item_at(r, best); return; }|if (best >= 0) p->sel = item_at(r, best);\n\t\treturn;
P30|act|case UMD_PI_AB:      a->arg = B(UMD_PB_AB); break;|case UMD_PI_AB:      a->arg = B(UMD_PB_PANEL); break;
P31|act|case UMD_PI_CLEAR:   a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_AB_CLEAR; break;|case UMD_PI_CLEAR:   a->arg = B(UMD_PB_AB); break;
P32|act|case UMD_PI_PAUSE:   a->kind = UMD_PA_CMD; a->arg = UMD_PANEL_PC_PAUSE; break;|case UMD_PI_PAUSE:   a->arg = B(UMD_PB_PAUSE); break;
MUT
  echo "== RED: mutations of main/support/umd/umd_menu_run.c against [run] =="
  while IFS='|' read -r id arms old new; do
    [ -z "$id" ] && continue
    d=$O/red/$id; rm -rf "$d"; mkdir -p "$d/m"; cp -r main/support/umd/menu "$d/m/"; cp main/support/umd/*.[ch] "$d/m/"
    if ! python3 - "$d/m/umd_menu_run.c" "$old" "$new" <<'PYMUT'
import sys
p = sys.argv[1]
old, new = (x.encode().decode("unicode_escape") for x in sys.argv[2:4])
s = open(p).read()
if s.count(old) != 1:
    sys.exit("the mutation's text is found %d times" % s.count(old))
open(p, "w").write(s.replace(old, new))
PYMUT
    then echo "  FAIL $id: did not apply"; fail=1; continue; fi
    if ! build_run "$d/check" "$d/m" 2> "$d/build.log"; then echo "  FAIL $id: the mutant does not build"; fail=1; continue; fi
    "$d/check" > "$d/run.log" 2>&1
    arms=${arms//\//|}
    if grep -Eq "^FAIL \[($arms)\]" "$d/run.log"; then echo "  caught $id by $(grep -Em1 "^FAIL \[($arms)\]" "$d/run.log" | cut -c1-110)"
    else echo "  SURVIVED $id (want [$arms]): $(grep -m1 '^FAIL\|^PASS' "$d/run.log" | cut -c1-110)"; fail=1; fi
  done <<'RMUT'
R1|levels/route|uint32_t pk = e.data & pg;|uint32_t pk = 0;
R2|levels|	lv->ui_sub = (show == UMD_PS_UI_SUB);|	lv->grab = 0; lv->ui_sub = (show == UMD_PS_UI_SUB);
R3|levels|lv->ui_sub = (show == UMD_PS_UI_SUB);|lv->ui_sub = 0;
R4|act|umd_menu_push_press(r->L, (uint16_t)a[k].arg);|(void)0;
R5|page|		if (sx < x0) x0 = sx;|		(void)0;
R6|page|			r->sv.plane_get(r->sv.ud, sb, sx, sy, sw, sh, r->pframe);|			(void)0;
R7|page|return r->pfront == 2 ? 3 : 2;|return 2;
R8|page|if (lv->ui_sub && !r->uis_was) r->pneed = 1;|(void)0;
R9|page|	if (!r->pneed && umd_panel_view(&r->P) == r->pview_was && sub_now(r) == r->psub_was &&\n	    (r->have_rd && r->rd.zoom) == r->pz_was) return -1;\n|
R10|page|	for (int y = y0; y < y1; y++) memset(|	for (int y = y0; y < y0; y++) memset(
R11|close|	if (show != UMD_PS_UI_SUB) return -1;\n	if (!umd_menu_flip_idle(r->L)) return -1;|	(void)show;\n	if (!umd_menu_flip_idle(r->L)) return -1;
R12|act|c.code = (uint8_t)a[k].arg;|c.code = 1;
R13|core|	if (sub >= 0 && r->rd.sub_rect_v) {|	if (0) {
R14|zoom|	if (have && zoom) zoom_place(sy, sh, &dy, &dh);|	if (have && zoom && 0) zoom_place(sy, sh, &dy, &dh);
R15|zoom|memset(r->pframe + (size_t)y * row + off, 0, n);|(void)0;
R16|zoom|	    (r->have_rd && r->rd.zoom) == r->pz_was) return -1;|	    1) return -1;
R17|zoom|	*zh = h < UMD_ZOOM_Y1 - UMD_ZOOM_Y0 ? h : UMD_ZOOM_Y1 - UMD_ZOOM_Y0;|	*zh = h;
RMUT
fi

[ $fail -eq 0 ] && echo "== ALL GREEN ==" || echo "== FAILURES =="
exit $fail
