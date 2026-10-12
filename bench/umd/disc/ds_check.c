// ds_check.c -- R5's disc screen on the PC (bench/umd/run_disc_screen.sh): main/support/umd/
// umd_disc_screen.c's entry points for bench/umd/disc/ds_bench.py to score against
// tools/disc_screen_layout.py (the golden).
//   ds_check page OUT.raw LAYOUT FIT TITLE HINT [PIC1.raw W H | -] [ICON0.raw W H | -]
//       the page (720 x 480 x 4, LAYOUT 0 RGBA / 1 the plane's B G R A), straight RGBA8 inputs
//   ds_check sfo PARAM.SFO           the TITLE (or "-" none)
//   ds_check title SFO_TITLE IMAGE   the title shown (umd_ds_display_title)
//   ds_check hint RESUME MS          the Play line
//   ds_check png IN.png OUT.raw      the colour chunks dropped (umd_ds_png_plain), then libpng's simplified
//                                    API (the UMD Main's decoder) -> "W H DROPPED", straight RGBA8
#include "umd_disc_screen.h"
#include "umd_panel.h"

#include <png.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *slurp(const char *p, size_t *n)
{
	FILE *f = fopen(p, "rb");
	if (!f) { perror(p); exit(2); }
	fseek(f, 0, SEEK_END);
	long l = ftell(f);
	fseek(f, 0, SEEK_SET);
	uint8_t *b = (uint8_t *)malloc((size_t)l + 1);
	if (!b || fread(b, 1, (size_t)l, f) != (size_t)l) { fprintf(stderr, "%s: read\n", p); exit(2); }
	fclose(f);
	*n = (size_t)l;
	return b;
}

// an image argument: RAW W H, or "-" (none); returns the next argument's index
static int img_arg(char **argv, int i, umd_ds_img *im, int *have)
{
	if (!strcmp(argv[i], "-")) { *have = 0; return i + 1; }
	size_t n;
	im->rgba = slurp(argv[i], &n);
	im->w = atoi(argv[i + 1]); im->h = atoi(argv[i + 2]);
	if ((size_t)im->w * (size_t)im->h * 4 != n) { fprintf(stderr, "%s: %zu bytes, not %d x %d x 4\n", argv[i], n, im->w, im->h); exit(2); }
	*have = 1;
	return i + 3;
}

int main(int argc, char **argv)
{
	if (argc >= 3 && !strcmp(argv[1], "sfo")) {
		size_t n;
		uint8_t *b = slurp(argv[2], &n);
		char t[UMD_DS_TITLE_MAX];
		printf("%s\n", umd_ds_sfo_title(b, n, t, sizeof(t)) ? "-" : t);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "title")) {
		char t[256];
		umd_ds_display_title(argv[2], argv[3], t, sizeof(t));
		printf("%s\n", t);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "png")) {
		size_t n;
		uint8_t *b = slurp(argv[2], &n);
		int dropped = umd_ds_png_plain(b, &n);
		png_image im;
		memset(&im, 0, sizeof(im));
		im.version = PNG_IMAGE_VERSION;
		if (!png_image_begin_read_from_memory(&im, b, n)) { printf("-\n"); return 0; }
		im.format = PNG_FORMAT_RGBA;
		uint8_t *px = (uint8_t *)malloc(PNG_IMAGE_SIZE(im));
		if (!px || !png_image_finish_read(&im, NULL, px, 0, NULL)) { printf("-\n"); return 0; }
		FILE *f = fopen(argv[3], "wb");
		if (!f || fwrite(px, 1, PNG_IMAGE_SIZE(im), f) != PNG_IMAGE_SIZE(im)) { perror(argv[3]); return 2; }
		fclose(f);
		printf("%u %u %d\n", im.width, im.height, dropped);
		return 0;
	}
	if (argc >= 4 && !strcmp(argv[1], "hint")) {
		char t[64];
		umd_ds_hint(t, sizeof(t), atoi(argv[2]), (uint32_t)strtoul(argv[3], NULL, 10));
		printf("%s\n", t);
		return 0;
	}
	if (argc >= 9 && !strcmp(argv[1], "page")) {
		int layout = atoi(argv[3]) ? UMD_PANEL_PX_PLANE : UMD_PANEL_PX_RGBA, fit = atoi(argv[4]);
		umd_ds_img p1, i0;
		int h1, h0;
		int i = img_arg(argv, 7, &p1, &h1);
		if (i >= argc) { fprintf(stderr, "no ICON0 argument\n"); return 2; }
		img_arg(argv, i, &i0, &h0);
		uint8_t *px = (uint8_t *)malloc((size_t)UMD_DS_W * UMD_DS_H * 4);
		memset(px, 0xA5, (size_t)UMD_DS_W * UMD_DS_H * 4);       // (the draw must clear it)
		umd_ds_draw(px, UMD_DS_W * 4, layout, h1 ? &p1 : NULL, h0 ? &i0 : NULL, argv[5], argv[6], fit);
		FILE *f = fopen(argv[2], "wb");
		if (!f || fwrite(px, 1, (size_t)UMD_DS_W * UMD_DS_H * 4, f) != (size_t)UMD_DS_W * UMD_DS_H * 4) { perror(argv[2]); return 2; }
		fclose(f);
		return 0;
	}
	fprintf(stderr, "usage: ds_check page|sfo|title|hint ...\n");
	return 2;
}
