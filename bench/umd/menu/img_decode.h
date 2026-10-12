// img_decode.h -- the menu benches' image decoders (P9): what the UMD Main does with libpng and
// Imlib2, done here with libpng and libjpeg -- the engine's decode_image hook (menu.h).
#pragma once
#include <stddef.h>
#include <stdint.h>

int bench_dec_png(const uint8_t *d, size_t n, int *w, int *h, uint8_t **out);
int bench_decode_image(void *ud, int fmt, const uint8_t *d, size_t n, int *w, int *h, uint8_t **rgba);
