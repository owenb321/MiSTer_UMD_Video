// panel_check.c -- bench/umd/run_panel.sh's harness: main/support/umd/umd_panel.c driven by a script on
// stdin, its answers on stdout. bench/umd/panel/panel_bench.py writes the script, runs the same steps
// through tools/panel_ref.py (the decisions) and tools/panel_layout.py (the pixels), and scores.
//
// THE SCRIPT, one step a line:
//   R state seeking goto_open sub_any menu_up engine now   a HOST_RD (umd_panel_read)
//   K mask                                                a grabbed press (umd_panel_key)
//   P open hidden menu_mode sel sub_any engine            set the state outright (the pixel arms)
//   D layout under out                                    draw over the 720 x 480 x 4 page in file
//                                                          `under`, write the result to `out`
//   Q                                                     the rectangle drawn (umd_panel_rect)
// THE ANSWERS: after R / K / P a line
//   S open hidden menu_mode sel grab show view n [kind arg]...
// after D a line "D ok"; after Q "Q x y w h"; at the end "END".
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "umd_panel.h"

#define W 720
#define H 480

static void state_line(const umd_panel *p, const umd_panel_act *a, int n)
{
	uint16_t grab;
	int show;
	umd_panel_levels(p, &grab, &show);
	printf("S %d %d %d %d %u %d %u %d", p->open, p->hidden, p->menu_mode, p->sel, grab, show,
	       umd_panel_view(p), n);
	for (int i = 0; i < n; i++) printf(" %d %u", a[i].kind, a[i].arg);
	printf("\n");
}

int main(void)
{
	static uint8_t px[W * H * 4];
	umd_panel p;
	umd_panel_init(&p);
	char line[1024];
	while (fgets(line, sizeof(line), stdin)) {
		umd_panel_act a[16];
		int n = 0;
		if (line[0] == 'R') {
			umd_panel_rd rd;
			unsigned now;
			if (sscanf(line + 1, "%d %d %d %d %d %d %u", &rd.state, &rd.seeking, &rd.goto_open, &rd.sub_any,
			           &rd.menu_up, &rd.engine, &now) != 7) { fprintf(stderr, "bad R: %s", line); return 2; }
			umd_panel_read(&p, &rd, now);
		} else if (line[0] == 'K') {
			unsigned mask;
			if (sscanf(line + 1, "%u", &mask) != 1) { fprintf(stderr, "bad K: %s", line); return 2; }
			n = umd_panel_key(&p, mask, a, 16);
		} else if (line[0] == 'P') {
			if (sscanf(line + 1, "%d %d %d %d %d %d", &p.open, &p.hidden, &p.menu_mode, &p.sel, &p.rd.sub_any,
			           &p.rd.engine) != 6) { fprintf(stderr, "bad P: %s", line); return 2; }
		} else if (line[0] == 'D') {
			int layout;
			char under[512], out[512];
			if (sscanf(line + 1, "%d %511s %511s", &layout, under, out) != 3) { fprintf(stderr, "bad D: %s", line); return 2; }
			FILE *f = fopen(under, "rb");
			if (!f || fread(px, 1, sizeof(px), f) != sizeof(px)) { fprintf(stderr, "cannot read %s\n", under); return 2; }
			fclose(f);
			umd_panel_draw(&p, px, W * 4, layout);
			f = fopen(out, "wb");
			if (!f || fwrite(px, 1, sizeof(px), f) != sizeof(px)) { fprintf(stderr, "cannot write %s\n", out); return 2; }
			fclose(f);
			printf("D ok\n");
			continue;
		} else if (line[0] == 'Q') {
			int x, y, w, h;
			umd_panel_rect(&x, &y, &w, &h);
			printf("Q %d %d %d %d\n", x, y, w, h);
			continue;
		} else
			continue;
		state_line(&p, a, n);
	}
	printf("END\n");
	return 0;
}
