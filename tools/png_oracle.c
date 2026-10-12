/* png_oracle.c -- libpng (the PNG reference library) as the pixel oracle for
 * umd/png/ (tools/png_golden.py compiles and runs it; docs/png_decode.md "Oracles").
 *
 * Why libpng and not PIL alone: measured 2026-09-25 (PIL 12.3, ffmpeg n9.0.1), PIL
 * clips 16-bit grey to 255 and compares an RGB16 tRNS key at 8 bits; PIL and ffmpeg both
 * ignore a grey tRNS key at 2 bits, and ffmpeg at 1 bit. libpng expands every colour
 * type and depth with the key compared at the raw sample depth, and keeps 16 bits.
 *
 *   png_oracle < file.png > out     (stdout: a header line, then raw pixels)
 *
 * stdout: "OK <w> <h> <ctype> <depth> <interlace>\n" then w*h RGBA pixels as 4 x u16
 * big-endian, raster order, full 16-bit precision (8-bit samples scaled by 257, as
 * libpng does, so the high byte is the 8-bit value). On a fatal libpng error: "ERR
 * <message>\n" and exit 2. Every libpng warning / benign error goes to stderr as
 * "WARN <message>" (benign errors are warnings here: png_set_benign_errors).
 */
#include <png.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void on_error(png_structp p, png_const_charp msg)
{
    printf("ERR %s\n", msg);
    fflush(stdout);
    longjmp(png_jmpbuf(p), 1);
}

static void on_warn(png_structp p, png_const_charp msg)
{
    (void)p;
    fprintf(stderr, "WARN %s\n", msg);
}

int main(void)
{
    png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, on_error, on_warn);
    png_infop info = png_create_info_struct(p);
    png_bytep *rows = NULL;
    if (setjmp(png_jmpbuf(p)))
        return 2;
    png_set_benign_errors(p, 1);
    png_init_io(p, stdin);
    png_read_info(p, info);
    png_uint_32 w = png_get_image_width(p, info), h = png_get_image_height(p, info);
    int ctype = png_get_color_type(p, info), depth = png_get_bit_depth(p, info);
    int il = png_get_interlace_type(p, info);
    png_set_expand(p);                     /* palette -> RGB, grey < 8 -> 8, tRNS -> alpha */
    png_set_expand_16(p);                  /* everything to 16 bits (8-bit v -> v * 257) */
    png_set_gray_to_rgb(p);
    if (!(ctype & PNG_COLOR_MASK_ALPHA) && !png_get_valid(p, info, PNG_INFO_tRNS))
        png_set_add_alpha(p, 0xFFFF, PNG_FILLER_AFTER);
    png_set_interlace_handling(p);
    png_read_update_info(p, info);
    size_t rb = png_get_rowbytes(p, info);
    if (rb != (size_t)w * 8) {
        printf("ERR oracle: row bytes %zu, expected %u\n", rb, (unsigned)w * 8);
        return 3;
    }
    rows = malloc(sizeof(png_bytep) * (h ? h : 1));
    for (png_uint_32 y = 0; y < h; y++)
        rows[y] = malloc(rb);
    png_read_image(p, rows);
    png_read_end(p, NULL);
    printf("OK %u %u %d %d %d\n", (unsigned)w, (unsigned)h, ctype, depth, il);
    for (png_uint_32 y = 0; y < h; y++)
        fwrite(rows[y], 1, rb, stdout);
    return 0;
}
