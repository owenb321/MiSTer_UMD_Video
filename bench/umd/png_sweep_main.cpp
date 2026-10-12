// bench/umd/png_sweep_main.cpp -- umd/png/png_top.sv (Verilator) over EVERY subtitle PNG
// of the corpus, the oracles computed in-process (bench/umd/run_png.sh --sweep;
// docs/png_decode.md §5). No fixtures: 336k units would be gigabytes of hex.
//
//   [inflate]  tap_inf, byte for byte, against zlib's inflate() of the first run of
//              IDAT chunks
//   [unfilter] tap_raw against libpng's rows read with NO transform (the unfiltered row
//              bytes, padding bits as the stream carries them) -- non-interlaced images;
//              an interlaced one is scored by the other arms only
//   [pixel]    x, y, RGBA against libpng expanded as tools/png_oracle.c does it (every
//              type to 16-bit RGBA, the tRNS key at the raw depth; the high byte kept),
//              in emission order (Adam7: pass order)
//   [err]      the verdict 0 and no warning (the corpus is clean: tools/png_corpus.py
//              --report audits it; a unit an oracle refuses is reported as ORACLE)
//   [hang]     done within 64 cycles a byte + 100k
//
//   png_sweep LIST [+stall=1] [+seed=N] [+label=TEXT]    (LIST: one PNG path a line)
// PASS marker: "PASS: png_sweep"; the first failure prints "FAIL [arm] ..." and exits 1.
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <png.h>
#include <zlib.h>

#include "Vpng_top.h"
#include "verilated.h"

static std::string g_unit;

static std::string fmt(const char* f, ...) __attribute__((format(printf, 1, 2)));
static std::string fmt(const char* f, ...) {
    char b[1024];
    va_list ap;
    va_start(ap, f);
    vsnprintf(b, sizeof b, f, ap);
    va_end(ap);
    return b;
}

static void fail(const char* arm, const std::string& msg) {
    printf("FAIL [%s] %s: %s\n", arm, g_unit.c_str(), msg.c_str());
    fflush(stdout);
    exit(1);
}

static bool read_file(const std::string& p, std::vector<uint8_t>& out) {
    FILE* f = fopen(p.c_str(), "rb");
    if (!f) return false;
    uint8_t buf[65536];
    size_t n;
    out.clear();
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) out.insert(out.end(), buf, buf + n);
    fclose(f);
    return true;
}

static uint32_t be32(const uint8_t* p) { return (uint32_t)p[0] << 24 | p[1] << 16 | p[2] << 8 | p[3]; }

// the zlib stream: the first run of consecutive IDAT chunks
static std::vector<uint8_t> idat_run(const std::vector<uint8_t>& png) {
    std::vector<uint8_t> z;
    size_t o = 8;
    bool seen = false;
    while (o + 12 <= png.size()) {
        uint32_t ln = be32(&png[o]);
        const uint8_t* t = &png[o + 4];
        if (!memcmp(t, "IDAT", 4)) {
            z.insert(z.end(), png.begin() + o + 8, png.begin() + o + 8 + ln);
            seen = true;
        } else if (seen || !memcmp(t, "IEND", 4)) break;
        o += 12 + (size_t)ln;
    }
    return z;
}

static bool zlib_inflate(const std::vector<uint8_t>& z, std::vector<uint8_t>& out) {
    z_stream s;
    memset(&s, 0, sizeof s);
    if (inflateInit(&s) != Z_OK) return false;
    s.next_in = const_cast<Bytef*>(z.data());
    s.avail_in = (uInt)z.size();
    uint8_t buf[65536];
    int rc;
    out.clear();
    do {
        s.next_out = buf;
        s.avail_out = sizeof buf;
        rc = inflate(&s, Z_NO_FLUSH);
        out.insert(out.end(), buf, buf + (sizeof buf - s.avail_out));
    } while (rc == Z_OK);
    inflateEnd(&s);
    return rc == Z_STREAM_END;
}

// ---- libpng from memory ------------------------------------------------------------------
struct Mem { const uint8_t* p; size_t n, o; };
static void mem_read(png_structp png, png_bytep out, png_size_t n) {
    Mem* m = (Mem*)png_get_io_ptr(png);
    if (m->o + n > m->n) png_error(png, "read past the end");
    memcpy(out, m->p + m->o, n);
    m->o += n;
}
static void on_err(png_structp png, png_const_charp msg) {
    fprintf(stderr, "libpng: %s\n", msg);
    longjmp(png_jmpbuf(png), 1);
}
static void on_warn(png_structp, png_const_charp) {}

struct Img {
    uint32_t w = 0, h = 0;
    int ctype = 0, depth = 0, il = 0;
    std::vector<uint16_t> rgba;       // w*h*4, raster order
    std::vector<uint8_t> raw;         // the unfiltered row bytes (non-interlaced)
};

// expand = true: tools/png_oracle.c's transforms; false: the rows as stored (raw)
static bool libpng_read(const std::vector<uint8_t>& png, bool expand, Img& im) {
    png_structp p = png_create_read_struct(PNG_LIBPNG_VER_STRING, nullptr, on_err, on_warn);
    png_infop info = png_create_info_struct(p);
    Mem m{png.data(), png.size(), 0};
    std::vector<png_bytep> rows;
    std::vector<uint8_t> buf;
    if (setjmp(png_jmpbuf(p))) {
        png_destroy_read_struct(&p, &info, nullptr);
        return false;
    }
    png_set_benign_errors(p, 1);
    png_set_read_fn(p, &m, mem_read);
    png_read_info(p, info);
    im.w = png_get_image_width(p, info);
    im.h = png_get_image_height(p, info);
    im.ctype = png_get_color_type(p, info);
    im.depth = png_get_bit_depth(p, info);
    im.il = png_get_interlace_type(p, info);
    if (expand) {
        png_set_expand(p);
        png_set_expand_16(p);
        png_set_gray_to_rgb(p);
        if (!(im.ctype & PNG_COLOR_MASK_ALPHA) && !png_get_valid(p, info, PNG_INFO_tRNS))
            png_set_add_alpha(p, 0xFFFF, PNG_FILLER_AFTER);
        png_set_interlace_handling(p);
    }
    png_read_update_info(p, info);
    size_t rb = png_get_rowbytes(p, info);
    buf.resize(rb * im.h);
    rows.resize(im.h);
    for (uint32_t y = 0; y < im.h; y++) rows[y] = &buf[rb * y];
    png_read_image(p, rows.data());
    png_read_end(p, nullptr);
    png_destroy_read_struct(&p, &info, nullptr);
    if (expand) {
        if (rb != (size_t)im.w * 8) return false;
        im.rgba.resize((size_t)im.w * im.h * 4);
        for (size_t k = 0; k < im.rgba.size(); k++) im.rgba[k] = (uint16_t)(buf[2 * k] << 8 | buf[2 * k + 1]);
    } else {
        im.raw = buf;
    }
    return true;
}

static const int AX0[7] = {0, 4, 0, 2, 0, 1, 0}, AY0[7] = {0, 0, 4, 0, 2, 0, 1};
static const int ADX[7] = {8, 8, 4, 4, 2, 2, 1}, ADY[7] = {8, 8, 8, 4, 4, 2, 2};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "usage: png_sweep LIST [+stall=1] [+seed=N] [+label=T]\n"); return 2; }
    int stall = 0;
    unsigned seed = 1;
    std::string label = argv[1];
    for (int i = 2; i < argc; i++) {
        if (!strncmp(argv[i], "+stall=", 7)) stall = atoi(argv[i] + 7);
        if (!strncmp(argv[i], "+seed=", 6)) seed = (unsigned)atoi(argv[i] + 6);
        if (!strncmp(argv[i], "+label=", 7)) label = argv[i] + 7;
    }
    srand(seed);
    FILE* lf = fopen(argv[1], "r");
    if (!lf) { fprintf(stderr, "png_sweep: cannot open %s\n", argv[1]); return 2; }

    Vpng_top* t = new Vpng_top;
    auto tick = [&]() {                     // one cycle: inputs already set at clk low
        t->clk = 1; t->eval();
        t->clk = 0; t->eval();
    };
    t->clk = 0; t->rst_n = 0; t->start = 0; t->in_valid = 0; t->in_last = 0; t->px_ready = 1;
    t->eval();
    for (int i = 0; i < 4; i++) tick();
    t->rst_n = 1; t->eval();

    uint64_t units = 0, bytes_in = 0, bytes_inf = 0, cycles = 0, pixels = 0, oracle_refused = 0, noraw = 0;
    char line[4096];
    std::vector<uint8_t> png, inf;
    while (fgets(line, sizeof line, lf)) {
        size_t n = strlen(line);
        while (n && (line[n - 1] == '\n' || line[n - 1] == '\r')) line[--n] = 0;
        if (!n) continue;
        g_unit = line;
        if (!read_file(line, png)) fail("harness", "cannot read the PNG");
        // oracles
        Img px, rw;
        bool z_ok = zlib_inflate(idat_run(png), inf);
        bool p_ok = libpng_read(png, true, px);
        bool r_ok = p_ok && !px.il && libpng_read(png, false, rw);
        if (!z_ok || !p_ok) {
            printf("ORACLE %s: zlib %s, libpng %s -- expected a refusal\n", line, z_ok ? "ok" : "refuses",
                   p_ok ? "ok" : "refuses");
            oracle_refused++;
        }
        if (px.il) noraw++;
        // the expected pixel order: raster, or Adam7 pass order
        std::vector<uint64_t> want;
        if (p_ok) {
            for (int pass = 0; pass < (px.il ? 7 : 1); pass++) {
                int x0 = px.il ? AX0[pass] : 0, y0 = px.il ? AY0[pass] : 0;
                int dx = px.il ? ADX[pass] : 1, dy = px.il ? ADY[pass] : 1;
                for (uint32_t y = y0; y < px.h; y += dy)
                    for (uint32_t x = x0; x < px.w; x += dx) {
                        const uint16_t* q = &px.rgba[((size_t)y * px.w + x) * 4];
                        want.push_back((uint64_t)x << 48 | (uint64_t)y << 32 | (uint64_t)(q[0] >> 8) << 24 |
                                       (uint64_t)(q[1] >> 8) << 16 | (uint64_t)(q[2] >> 8) << 8 | (q[3] >> 8));
                    }
            }
        }
        // run
        size_t ip = 0, ni = 0, nr = 0, np = 0;
        uint64_t cyc = 0, limit = 64ull * (png.size() + inf.size() + want.size()) + 100000;
        t->start = 1; tick(); t->start = 0;
        while (!t->done && cyc < limit) {
            t->in_valid = (ip < png.size()) && (!stall || (rand() % 4) != 0);
            t->in_byte = ip < png.size() ? png[ip] : 0;
            t->in_last = (ip + 1 == png.size());
            t->px_ready = !stall || (rand() % 3) != 0;
            t->eval();
            if (p_ok && z_ok) {
                if (t->tap_inf_valid) {
                    if (ni >= inf.size()) fail("inflate", fmt("more than %zu inflated bytes", inf.size()));
                    if (t->tap_inf_byte != inf[ni])
                        fail("inflate", fmt("byte %zu: %02x, zlib %02x", ni, t->tap_inf_byte, inf[ni]));
                    ni++;
                }
                if (t->tap_raw_valid && r_ok) {
                    if (nr >= rw.raw.size()) fail("unfilter", fmt("more than %zu row bytes", rw.raw.size()));
                    if (t->tap_raw_byte != rw.raw[nr])
                        fail("unfilter", fmt("row byte %zu: %02x, libpng %02x", nr, t->tap_raw_byte, rw.raw[nr]));
                    nr++;
                }
                if (t->px_valid && t->px_ready) {
                    uint64_t got = (uint64_t)t->px_x << 48 | (uint64_t)t->px_y << 32 | t->px_rgba;
                    if (np >= want.size()) fail("pixel", fmt("more than %zu pixels", want.size()));
                    if (got != want[np])
                        fail("pixel", fmt("pixel %zu: %016llx, libpng %016llx", np, (unsigned long long)got,
                                          (unsigned long long)want[np]));
                    np++;
                }
            }
            bool took = t->in_valid && t->in_ready;
            tick();
            if (took) ip++;
            cyc++;
        }
        if (!t->done) fail("hang", fmt("no done after %llu cycles (in %zu of %zu)", (unsigned long long)cyc, ip, png.size()));
        if (p_ok && z_ok) {
            if (ni != inf.size()) fail("inflate", fmt("%zu inflated bytes, zlib %zu", ni, inf.size()));
            if (r_ok && nr != rw.raw.size()) fail("unfilter", fmt("%zu row bytes, libpng %zu", nr, rw.raw.size()));
            if (np != want.size()) fail("pixel", fmt("%zu pixels, libpng %zu", np, want.size()));
            if (t->err != 0 || t->warn != 0) fail("err", fmt("verdict %d warn %02x on a clean unit", t->err, t->warn));
        } else if (t->err == 0) fail("err", "an oracle refuses it, the decoder does not");
        units++;
        bytes_in += png.size();
        bytes_inf += inf.size();
        cycles += cyc;
        pixels += want.size();
        tick();
    }
    fclose(lf);
    printf("png_sweep %s: %llu units identical (%llu PNG bytes, %llu inflated, %llu pixels; %llu interlaced "
           "without the row arm; %llu refused by an oracle); %.2f cycles an inflated byte\n",
           label.c_str(), (unsigned long long)units, (unsigned long long)bytes_in, (unsigned long long)bytes_inf,
           (unsigned long long)pixels, (unsigned long long)noraw, (unsigned long long)oracle_refused,
           bytes_inf ? (double)cycles / (double)bytes_inf : 0.0);
    printf("PASS: png_sweep\n");
    delete t;
    return 0;
}
