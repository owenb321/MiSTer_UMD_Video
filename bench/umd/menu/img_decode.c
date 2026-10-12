// img_decode.c -- see img_decode.h.
#include "img_decode.h"

#include <stdio.h>             // (before jpeglib.h, which uses FILE)
#ifndef BENCH_NO_JPEG          // (the A9 build, run_menu_arm.sh: no libjpeg in the Main's toolchain; a JPEG refused)
#include <jpeglib.h>
#endif
#include <png.h>
#include <setjmp.h>
#include <stdlib.h>
#include <string.h>

int bench_dec_png(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out)
{
    png_image im;
    memset(&im, 0, sizeof(im));
    im.version = PNG_IMAGE_VERSION;
    if (!png_image_begin_read_from_memory(&im, d, n)) return -1;
    im.format = PNG_FORMAT_RGBA;
    *out = (uint8_t *)malloc(PNG_IMAGE_SIZE(im));
    if (!*out || !png_image_finish_read(&im, NULL, *out, 0, NULL)) { free(*out); *out = NULL; png_image_free(&im); return -1; }
    *w = (int)im.width; *h = (int)im.height;
    return 0;
}
#ifndef BENCH_NO_JPEG
struct jerr { struct jpeg_error_mgr pub; jmp_buf jb; };
static void jerr_exit(j_common_ptr c) { longjmp(((struct jerr *)c->err)->jb, 1); }
static int dec_jpeg(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out)
{
    struct jpeg_decompress_struct c;
    struct jerr je;
    uint8_t *rgb = NULL;
    *out = NULL;
    c.err = jpeg_std_error(&je.pub);
    je.pub.error_exit = jerr_exit;
    if (setjmp(je.jb)) { jpeg_destroy_decompress(&c); free(rgb); free(*out); *out = NULL; return -1; }
    jpeg_create_decompress(&c);
    jpeg_mem_src(&c, (unsigned char *)d, (unsigned long)n);
    jpeg_read_header(&c, TRUE);
    c.out_color_space = JCS_RGB;
    jpeg_start_decompress(&c);
    *w = (int)c.output_width; *h = (int)c.output_height;
    rgb = (uint8_t *)malloc((size_t)*w * 3);
    *out = (uint8_t *)malloc((size_t)*w * (size_t)*h * 4);
    while (c.output_scanline < c.output_height) {
        uint8_t *row = rgb;
        int y = (int)c.output_scanline;
        jpeg_read_scanlines(&c, &row, 1);
        for (int x = 0; x < *w; x++) {
            uint8_t *o = *out + 4 * ((size_t)y * (size_t)*w + (size_t)x);
            o[0] = rgb[3 * x]; o[1] = rgb[3 * x + 1]; o[2] = rgb[3 * x + 2]; o[3] = 255;
        }
    }
    jpeg_finish_decompress(&c);
    jpeg_destroy_decompress(&c);
    free(rgb);
    return 0;
}
#else
static int dec_jpeg(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out)
{
    (void)d; (void)n; (void)w; (void)h; *out = NULL;
    return -1;
}
#endif
int bench_decode_image(void *ud, int fmt, const uint8_t *d, size_t n, int *w, int *h, uint8_t **rgba)
{
    (void)ud;
    return fmt == 0 ? bench_dec_png(d, n, w, h, rgba) : fmt == 1 ? dec_jpeg(d, n, w, h, rgba) : -1;
}
