// bench/umd/cosim_main.cpp -- the Verilator cosim of the decoder (bench/umd/cosim_top.sv:
// umd/h264/h264_top.sv -> umd/h264/recon_top.sv as emu composes them) over a disc window,
// scored against tools/cosim_golden.py (the model's decode-order pictures; the model is
// checked against ffmpeg on the same window first). The arms are recon_top_tb.sv's:
//
//   [pre]   every macroblock's pre-deblock samples (the bank the cycle recon_mb starts
//           deblocking it) equal the model's: the first mismatch by picture, macroblock,
//           plane, x, y
//   [post]  every picture's store in the DDR model equals the model's post-deblock
//           picture once its writes have landed
//   [count] the pictures and macroblocks the window holds; no error or refusal counted by
//           the front end or the reconstruction
//   [hang]  progress within 200,000 clk_dec cycles: a macroblock, a wait on the display, or
//           SE words taken (a skipped picture is discarded, never reconstructed: P6b1)
//   [ddr]   the Avalon rules ddr_model.sv polices (a write beat with reads outstanding, a
//           read inside a write burst, a burst of 0 or > 8 beats, reads without credit,
//           an address outside the window); since P6b1 the DPB client reaches the model
//           through ddr_mux2 (as in emu), which holds a write while reads are out, so the
//           client's own rule is policed at the mux's A side too (a_wr_early)
//   [out]   P5d, the output process: every store emitted is, in order, the model's
//           (STEM.out: its first picture, WHEN -- the pictures opened before it -- and its
//           shape), and the end-of-stream word flushes every one (eos_done, once)
//   [hold]  no write burst into a store the display holds (emitted, not yet released)
//   [avalon] a request held under waitrequest is presented unchanged until accepted
// P6b1, THE SEEK (STEM.seek, cosim_golden.py --seek): the ES is window A then window B.
// Once the decoder has reconstructed `abandon_mbs` macroblocks of picture `a_pics` (A's
// last), the harness pulls seek_rst_n for 20 clk_dec cycles -- the decoder's reset, the
// memory-clock reset and ddr_mux2's abort, as emu's mount path makes them; ps_rst_n
// stays high -- drops the rest of A's bytes (the reader's cache flush) and feeds B from
// b_offset. B's parameter sets are stripped where they equal A's: the decoder must have
// kept them. Scored: that picture's macroblocks are not ([pre]: it is abandoned, the
// golden has none); a picture complete but whose writes had not landed at the reset is
// cut from [post] (counted, and which of them the display held); every arm runs across
// the reset -- the display's holds persist through it ([hold]), the abort keeps the port
// legal ([ddr], [avalon]), B decodes bit-exact from its non-IDR entry ([pre], [post],
// [out], the start's counts in [count]).
//
// P6b4, TRICK PLAY (+one_frame +es=LONG.es): h264_top's one_frame is set, and the ES fed is
// LONG.es (a longer window from the same entry) while every arm scores STEM -- a golden of
// that entry's FIRST FRAME alone (cosim_golden.py --ep-start --frames 1). So the front end
// must end the stream after the first frame (a field pair is one) of a longer stream: every
// picture after it absent ([count], [pre]), the end-of-stream word emitted once at the cut
// ([out]: the entry's I flushed out of the DPB, bit-exact), the bytes after it taken and
// dropped (the window's end reached, the front end not busy).
//
// The harness is the display: it holds each emitted store for a random 0..+hold=N clk_dec
// cycles (default 5000), then releases it; a store being scored is held too.
//
// Clocks: clk_dec 81 MHz (12.346 ns), the DDR3 bridge 90 MHz (11.111 ns). The DDR model
// is ddr_model.sv's: random waitrequest (wait_pct %), a random read latency per burst
// (lat_min..lat_max mclk cycles from acceptance), bursts in flight returned in order.
//
//   cosim STEM [+seed=N] [+wait_pct=N] [+lat_min=N] [+lat_max=N] [+hold=N] [+label=TEXT] [+prof]
//         [+one_frame] [+es=PATH]
// +prof: per clk_dec cycle from the first macroblock to the last, histograms of recon_mb's
// front state (ms), recon_inter's two (fetch st, interpolation k), the back engine's (es) and the residual engine's
// (rs), printed as "PROF <unit> <state> <cycles>" (tools/cosim_prof.py names them).
// PASS marker: "PASS: cosim"; every failure prints "FAIL [arm] ..." and exits 1.
#include <cstdarg>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <string>
#include <vector>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "Vcosim_top.h"
#include "verilated.h"

static const uint32_t BASE = 0x06000000u;          // the DPB window (word address)
static const int AW = 22;                          // 32 MB: 20 stores of 1 MB + slack
static const uint64_t T_CLK = 12346, T_MCLK = 11111;   // ps

static void fail(const char* arm, const std::string& msg) {
    printf("FAIL [%s] %s\n", arm, msg.c_str());
    fflush(stdout);
    exit(1);
}

static std::string fmt(const char* f, ...) __attribute__((format(printf, 1, 2)));
static std::string fmt(const char* f, ...) {
    char b[1024];
    va_list ap;
    va_start(ap, f);
    vsnprintf(b, sizeof b, f, ap);
    va_end(ap);
    return b;
}

struct Map {                                       // a read-only file mapping
    const uint8_t* p = nullptr;
    size_t n = 0;
    void open(const std::string& path) {
        int fd = ::open(path.c_str(), O_RDONLY);
        if (fd < 0) fail("harness", "cannot open " + path);
        struct stat st;
        fstat(fd, &st);
        n = st.st_size;
        if (n) p = (const uint8_t*)mmap(nullptr, n, PROT_READ, MAP_PRIVATE, fd, 0);
        ::close(fd);
    }
    uint64_t word(size_t i) const {
        if ((i + 1) * 8 > n) fail("harness", fmt("golden word %zu beyond the file", i));
        uint64_t w;
        memcpy(&w, p + 8 * i, 8);
        return w;
    }
};

struct Pic { int st, w, h; size_t off; };

// xorshift64*: the DDR model's randomness, seeded
static uint64_t rng_s = 0x9E3779B97F4A7C15ull;
static uint32_t rnd(uint32_t lo, uint32_t hi) {
    rng_s ^= rng_s >> 12; rng_s ^= rng_s << 25; rng_s ^= rng_s >> 27;
    return lo + (uint32_t)((rng_s * 0x2545F4914F6CDD1Dull) >> 32) % (hi - lo + 1);
}

struct Ddr {
    std::vector<uint64_t> mem;
    std::vector<uint8_t> wrt;
    int wait_pct = 30, lat_min = 4, lat_max = 20;
    bool waitreq = true, rdv = false;
    uint64_t rdata = 0;
    std::deque<std::pair<uint32_t, uint64_t>> rq;  // (address, due cycle)
    uint64_t now = 0;
    int wr_left = 0;
    uint32_t wr_addr = 0;
    uint64_t unwritten = 0;
    Ddr() : mem(1u << AW, 0), wrt(1u << AW, 0) {}
    uint32_t idx(uint32_t a) const {
        if (a < BASE || a >= BASE + (1u << AW)) fail("ddr", fmt("address %08x outside the model's window", a));
        return a - BASE;
    }
    uint64_t peek(uint32_t a) const { uint32_t i = idx(a); return wrt[i] ? mem[i] : 0; }
    // one mclk rising edge: the port's inputs as they were before the edge
    // [avalon] (ddr_model.sv's): a request held under waitrequest stays unchanged until
    // accepted -- never withdrawn, never retargeted (the reload hang, docs/hil_harness.md)
    bool p_valid = false, p_rd = false, p_wr = false, p_first = false;
    uint32_t p_a = 0, p_bc = 0, p_be = 0;
    uint64_t p_wd = 0;
    void edge(uint32_t address, uint32_t burst, bool read, bool write, uint64_t wdata, uint32_t be) {
        if (p_valid && (read != p_rd || write != p_wr || (p_first && (address != p_a || burst != p_bc)) ||
                        (p_wr && (wdata != p_wd || be != p_be))))
            fail("avalon", fmt("a %s request withdrawn or changed while waitrequest held it (address %08x, burst %u)",
                               p_rd ? "read" : "write", p_a, p_bc));
        p_valid = (read || write) && waitreq;
        p_rd = read; p_wr = write; p_first = wr_left == 0;
        p_a = address; p_bc = burst; p_be = be; p_wd = wdata;
        bool accept = !waitreq;
        waitreq = rnd(0, 99) < (uint32_t)wait_pct;
        rdv = false;
        now++;
        if (accept) {
            if (read) {
                if (burst == 0 || burst > 8) fail("ddr", fmt("read burstcount %u", burst));
                if (wr_left) fail("ddr", fmt("read accepted with %d beats of a write burst to come", wr_left));
                if (rq.size() + burst > 256) fail("ddr", fmt("read accepted with %zu beats queued (no credit)", rq.size()));
                uint64_t due = now + rnd(lat_min, lat_max);
                for (uint32_t i = 0; i < burst; i++) rq.push_back({address + i, due});
            } else if (write) {
                if (!rq.empty()) fail("ddr", fmt("write accepted with %zu read beats outstanding", rq.size()));
                if (wr_left == 0) {
                    if (burst == 0 || burst > 8) fail("ddr", fmt("write burstcount %u", burst));
                    wr_left = burst;
                    wr_addr = address;
                }
                uint32_t i = idx(wr_addr);
                uint64_t cur = wrt[i] ? mem[i] : 0;
                for (int b = 0; b < 8; b++)
                    if (be & (1u << b)) cur = (cur & ~(0xFFull << (8 * b))) | (wdata & (0xFFull << (8 * b)));
                mem[i] = cur;
                wrt[i] = 1;
                wr_addr++;
                wr_left--;
            }
        }
        if (!rq.empty() && now >= rq.front().second) {
            uint32_t i = idx(rq.front().first);
            if (wrt[i]) rdata = mem[i];
            else { rdata = 0; unwritten++; }
            rdv = true;
            rq.pop_front();
        }
    }
};

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2 || argv[1][0] == '+') fail("harness", "usage: cosim STEM [+seed=N] ...");
    std::string stem = argv[1], label = stem;
    Ddr ddr;
    uint64_t seed = 1;
    bool prof = false;
    bool one_frame = false;                          // P6b4: trick play
    std::string es_path;                             // P6b4: the ES fed, when not STEM.es
    std::string marks_path;                          // P8: STEM.marks -- the PES sideband (cosim_golden.py --marks)
    uint32_t hold_max = 5000;
    long seek_mbs_ovr = -1, seek_delay = 0;          // P6b1: where the seek's reset lands
    int seek_on = 0;                                 // +seek_on=burst (1) / reads (2): the reset waits for
                                                     // the mux to hold an open write burst / A reads
    std::vector<uint64_t> h_ms(256, 0), h_in(256, 0), h_ik(256, 0), h_es(256, 0), h_rs(256, 0);
    for (int i = 2; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char* k) { return a.rfind(k, 0) == 0 ? a.c_str() + strlen(k) : nullptr; };
        if (auto v = val("+seed=")) seed = strtoull(v, nullptr, 10);
        else if (auto v = val("+wait_pct=")) ddr.wait_pct = atoi(v);
        else if (auto v = val("+lat_min=")) ddr.lat_min = atoi(v);
        else if (auto v = val("+lat_max=")) ddr.lat_max = atoi(v);
        else if (auto v = val("+label=")) label = v;
        else if (auto v = val("+hold=")) hold_max = (uint32_t)atoi(v);
        else if (auto v = val("+seek_mbs=")) seek_mbs_ovr = atol(v);
        else if (auto v = val("+seek_delay=")) seek_delay = atol(v);
        else if (auto v = val("+seek_on=")) seek_on = !strcmp(v, "burst") ? 1 : !strcmp(v, "reads") ? 2 : -1;
        else if (a == "+prof") prof = true;
        else if (a == "+one_frame") one_frame = true;
        else if (auto v = val("+es=")) es_path = v;
        else if (auto v = val("+marks=")) marks_path = v;
    }
    rng_s ^= seed * 0x9E3779B97F4A7C15ull;
    if (!rng_s) rng_s = 1;

    // ---- P8: the PES sideband, "es_offset pts ep" a line (cosim_golden.py --raw --marks): the
    // byte at es_offset is fed with es_mark and that PTS / item tag, as ps_demux marks the
    // first payload byte of a PES with a PTS. Without it the sideband stays 0 (every other arm).
    struct Mark { size_t off; uint64_t pts; uint32_t ep; };
    std::vector<Mark> marks;
    if (!marks_path.empty()) {
        FILE* f = fopen(marks_path.c_str(), "r");
        if (!f) fail("harness", fmt("cannot open %s", marks_path.c_str()));
        unsigned long long o, p; unsigned e;
        while (fscanf(f, "%llu %llu %u", &o, &p, &e) == 3) marks.push_back({(size_t)o, (uint64_t)p, e & 3u});
        fclose(f);
    }
    size_t mk_i = 0;

    // ---- the golden -------------------------------------------------------------------
    Map es, pre, post;
    es.open(es_path.empty() ? stem + ".es" : es_path);
    if (!es_path.empty()) {
        // the ES fed must be the golden's window and more: STEM.es a strict prefix of it
        Map g;
        g.open(stem + ".es");
        if (g.n >= es.n || memcmp(g.p, es.p, g.n) != 0)
            fail("harness", fmt("%s does not extend %s.es (%zu vs %zu bytes)", es_path.c_str(), stem.c_str(), es.n, g.n));
    }
    pre.open(stem + ".pre");
    post.open(stem + ".post");
    std::vector<Pic> pics;
    struct Out { long pic, step; int frame, unpaired; };
    std::vector<Out> outs;
    {
        FILE* f = fopen((stem + ".out").c_str(), "r");
        if (!f) fail("harness", "no " + stem + ".out");
        long n = 0;
        if (fscanf(f, "%ld", &n) != 1) fail("harness", "bad .out header");
        for (long i = 0; i < n; i++) {
            Out o;
            if (fscanf(f, "%ld %ld %d %d", &o.pic, &o.step, &o.frame, &o.unpaired) != 4) fail("harness", "bad .out line");
            outs.push_back(o);
        }
        fclose(f);
    }
    // P6b1: the recovery-point start's counts (STEM.rp, written by cosim_golden.py --ep-start:
    // starts, of them non-IDR, pictures skipped before the first I, leading pictures skipped,
    // MMCOs naming a picture from before the entry) -- scored in [count] when present
    long rp_want[5] = {0, 0, 0, 0, 0};
    bool rp_have = false;
    {
        FILE* f = fopen((stem + ".rp").c_str(), "r");
        if (f) {
            rp_have = fscanf(f, "%ld %ld %ld %ld %ld", &rp_want[0], &rp_want[1], &rp_want[2], &rp_want[3], &rp_want[4]) == 5;
            if (!rp_have) fail("harness", "bad .rp line");
            fclose(f);
        }
    }
    long seek_a_pics = -1, seek_abandon = 0, seek_b_off = 0;
    bool seek_have = false;
    {
        FILE* f = fopen((stem + ".seek").c_str(), "r");
        if (f) {
            seek_have = fscanf(f, "%ld %ld %ld", &seek_a_pics, &seek_abandon, &seek_b_off) == 3;
            if (!seek_have) fail("harness", "bad .seek line");
            fclose(f);
            if (seek_mbs_ovr >= 0) seek_abandon = seek_mbs_ovr;
        }
    }
    long n_pics = 0, n_mbs = 0, n_frames = 0, n_fields = 0, play_us = 0;
    {
        FILE* f = fopen((stem + ".pics").c_str(), "r");
        if (!f) fail("harness", "no " + stem + ".pics");
        char hdr[256];
        if (!fgets(hdr, sizeof hdr, f) || sscanf(hdr, "%ld %ld %ld %ld %ld", &n_pics, &n_mbs, &n_frames, &n_fields, &play_us) < 4)
            fail("harness", "bad .pics header");
        for (long i = 0; i < n_pics; i++) {
            Pic p;
            if (fscanf(f, "%d %d %d %zu", &p.st, &p.w, &p.h, &p.off) != 4) fail("harness", "bad .pics line");
            pics.push_back(p);
        }
        fclose(f);
    }

    // ---- the model --------------------------------------------------------------------
    VerilatedContext* ctx = new VerilatedContext;
    Vcosim_top* d = new Vcosim_top{ctx};
    d->clk = 0; d->mclk = 0; d->rst_n = 0; d->ps_rst_n = 0; d->mrst_n = 0; d->seek_rst_n = 1;
    d->es_valid = 0; d->es_byte = 0; d->es_flush = 0; d->disp_hold = 0; d->one_frame = one_frame;
    d->es_mark = 0; d->es_pts = 0; d->es_ep = 0;
    d->ddr_waitrequest = 1; d->ddr_readdatavalid = 0; d->ddr_readdata = 0;
    d->eval();

    // ---- state of the arms ----------------------------------------------------------------
    size_t es_i = 0;
    bool flushed = false;
    int flush_hold = 0;
    long cur_pic = -1, n_pre = 0, n_post = 0, n_done = 0, n_emit = 0, eos_seen = 0;
    uint64_t wr_issued = 0, cycles = 0, since = 0, first_mb_cycle = 0, last_mb_cycle = 0;
    uint32_t hold = 0;                               // stores held for scoring
    uint32_t dhold = 0;                              // stores the display holds (emitted, not released)
    uint64_t rel_at[32] = {0};
    std::vector<int> store_of;                       // each picture's store (pic_done k is picture k)
    long first_pic_of[32];
    for (int i = 0; i < 32; i++) first_pic_of[i] = -1;
    uint32_t stall_q = 0, se_q = 0;
    struct Score { long p; int store, st; uint64_t target; };
    std::deque<Score> pend;
    // P6b1, the seek
    int seek_phase = 0, seek_cnt = 0;              // 0 before, 1 in the reset, 2 after
    long opened = 0, mbs_in_pic = 0, mb_base = 0, cut_pics = 0, cut_held = 0, seek_wait = -1;
    uint64_t flush_wb = 0, flush_rd = 0;            // mclk cycles the abort held an open write burst / A reads

    auto golden_pre = [&](long p, int pl, int x_word, int y) -> uint64_t {
        const Pic& g = pics[p];
        size_t o = g.off;
        if (pl == 0) return pre.word(o + (size_t)y * 2 * g.w + x_word);
        o += 16 * (size_t)g.h * 2 * g.w;
        if (pl == 2) o += 8 * (size_t)g.h * g.w;
        return pre.word(o + (size_t)y * g.w + x_word);
    };
    auto check_pre = [&]() {
        if (cur_pic < 0 || cur_pic >= n_pics) fail("count", fmt("a macroblock of picture %ld; the window has %ld", cur_pic, n_pics));
        int mx = d->pre_mbx, my = d->pre_mby;
        for (int k = 0; k < 48; k++) {
            uint64_t got = ((uint64_t)d->pre_words[2 * k + 1] << 32) | d->pre_words[2 * k];
            int pl, y, xw;
            if (k < 32) { pl = 0; y = my * 16 + (k >> 1); xw = 2 * mx + (k & 1); }
            else if (k < 40) { pl = 1; y = my * 8 + (k - 32); xw = mx; }
            else { pl = 2; y = my * 8 + (k - 40); xw = mx; }
            uint64_t want = golden_pre(cur_pic, pl, xw, y);
            if (got != want) {
                int bi = 0;
                while (bi < 8 && ((got >> (8 * bi)) & 0xFF) == ((want >> (8 * bi)) & 0xFF)) bi++;
                fail("pre", fmt("picture %ld mb (%d, %d) plane %d x %d y %d: %d, model %d (word %d: %016llx vs %016llx)",
                                cur_pic, mx, my, pl, (pl == 0 ? mx * 16 + (k & 1) * 8 : mx * 8) + bi, y,
                                (int)((got >> (8 * bi)) & 0xFF), (int)((want >> (8 * bi)) & 0xFF), k,
                                (unsigned long long)got, (unsigned long long)want));
            }
        }
        n_pre++;
    };
    auto check_store = [&](long p, int store, int st) {
        if (p < 0 || p >= n_pics) fail("count", fmt("picture %ld completed; the window has %ld", p, n_pics));
        const Pic& g = pics[p];
        int fh = d->frame_height_mbs;
        for (int pl = 0; pl < 3; pl++) {
            int rows = pl == 0 ? 16 * g.h : 8 * g.h, words = pl == 0 ? 2 * g.w : g.w;
            size_t poff = pl == 0 ? 0 : pl == 1 ? 32 * (size_t)g.w * fh : 40 * (size_t)g.w * fh;
            size_t goff = pl == 0 ? 0 : pl == 1 ? 16 * (size_t)g.h * 2 * g.w : 16 * (size_t)g.h * 2 * g.w + 8 * (size_t)g.h * g.w;
            for (int y = 0; y < rows; y++) {
                int srow = st == 0 ? y : 2 * y + (st == 2 ? 1 : 0);
                for (int x = 0; x < words; x++) {
                    uint32_t a = BASE + ((uint32_t)store << 17) + (uint32_t)(poff + (size_t)srow * words + x);
                    uint64_t got = ddr.peek(a), want = post.word(g.off + goff + (size_t)y * words + x);
                    if (got != want) {
                        int bi = 0;
                        while (bi < 8 && ((got >> (8 * bi)) & 0xFF) == ((want >> (8 * bi)) & 0xFF)) bi++;
                        int xs = 8 * x + bi, sz = pl == 0 ? 16 : 8;
                        fail("post", fmt("picture %ld plane %d x %d y %d (mb %d, %d): %d, model %d", p, pl, xs, y,
                                         xs / sz, y / sz, (int)((got >> (8 * bi)) & 0xFF), (int)((want >> (8 * bi)) & 0xFF)));
                    }
                }
            }
        }
        n_post++;
    };

    // ---- the clocks -------------------------------------------------------------------------
    uint64_t t = 0, t_clk = T_CLK / 2, t_mclk = T_MCLK / 2;
    bool clk_hi = false, mclk_hi = false;
    uint64_t reset_until = 40000;                    // 40 ns
    uint64_t idle_run = 0;
    const uint64_t HANG = 200000;
    bool done = false, clk_pend = false, mclk_pend = false;
    while (!done) {
        bool do_clk = t_clk <= t_mclk, do_mclk = t_mclk <= t_clk;
        t = do_clk ? t_clk : t_mclk;
        if (t >= reset_until && !d->rst_n) { d->rst_n = 1; d->ps_rst_n = 1; d->mrst_n = 1; d->eval(); }
        bool clk_rise = do_clk && !clk_hi, mclk_rise = do_mclk && !mclk_hi;
        // ---- sample everything the edge acts on (the settled values before it) ----
        bool es_fire = false;
        uint32_t m_addr = 0, m_burst = 0, m_be = 0;
        bool m_rd = false, m_wr = false;
        uint64_t m_wd = 0;
        if (clk_rise && d->rst_n) {
            es_fire = d->es_valid && d->es_ready;
            cycles++;
            // [out] before this edge's pic_start: WHEN is the pictures opened before it
            if (d->emit_valid) {
                int s = d->emit_store;
                if (n_emit >= (long)outs.size())
                    fail("out", fmt("store %d emitted beyond the model's %zu", s, outs.size()));
                const Out& o = outs[n_emit];
                long step = opened;              // (an abandoned picture counts: the model's n_pictures)
                if (first_pic_of[s] != o.pic || step != o.step || d->emit_frame != o.frame || d->emit_unpaired != o.unpaired)
                    fail("out", fmt("emission %ld: picture %ld frame %d unpaired %d after %ld opened, want picture %ld "
                                    "frame %d unpaired %d after %ld", n_emit, first_pic_of[s], d->emit_frame,
                                    d->emit_unpaired, step, o.pic, o.frame, o.unpaired, o.step));
                if (dhold & (1u << s)) fail("out", fmt("store %d emitted while the display still holds it", s));
                dhold |= 1u << s;
                rel_at[s] = cycles + rnd(0, hold_max);
                n_emit++;
            }
            if (d->eos_done) eos_seen++;
            if (d->pic_start) {
                cur_pic++; opened++; mbs_in_pic = 0;
                hold |= 1u << d->cur_store;
                store_of.push_back(d->cur_store);
                if (!d->pinfo_second) first_pic_of[d->cur_store] = cur_pic;
            }
            if (d->pre_db && !(seek_have && seek_phase == 0 && cur_pic == seek_a_pics)) check_pre();
            if (d->wr_cmd) wr_issued++;
            if (d->pic_done) {
                // pictures complete in decoding order (the last one on the end of stream)
                if (n_done >= (long)store_of.size() || store_of[n_done] != d->done_store)
                    fail("count", fmt("pic_done %ld in store %d: not that picture's store", n_done, d->done_store));
                pend.push_back({n_done, d->done_store, d->done_struct, wr_issued});
                n_done++;
            }
            if (prof && first_mb_cycle) {
                h_ms[d->mb_state]++; h_in[d->inter_state]++; h_ik[d->interp_state]++; h_es[d->engine_state]++; h_rs[d->res_state]++;
            }
            // progress: a macroblock done, a wait on the display (not a hang), or SE words taken
            // by the reconstruction -- P6b1: a picture the recovery-point start SKIPS is read
            // and discarded while the front end parses it, reconstructing nothing (a dense one
            // outlasts HANG: Hackers' leading B, found by the library sweep)
            if (d->mb_done || d->stall_cycles != stall_q || d->se_words != se_q) {
                since = 0;
                stall_q = d->stall_cycles;
                se_q = d->se_words;
                if (d->mb_done) {
                mbs_in_pic++;
                if (!first_mb_cycle) first_mb_cycle = cycles;
                last_mb_cycle = cycles;
                }
            } else if (++since > HANG) {
                fail("hang", fmt("no progress for %llu cycles (after %u macroblocks, picture %ld; recon_mb %u, "
                                 "recon_dpb %u, router %u, front end %u, mb_syntax %u; ES byte %zu of %zu, SE words %u)",
                                 (unsigned long long)HANG, d->mb_count, cur_pic, d->mb_state, d->dbg_dpb_state,
                                 d->dbg_router_state, d->dbg_fe_state, d->dbg_mbs_state, es_i, es.n, d->se_words));
            }
        }
        if (mclk_rise && d->mrst_n) {
            if (d->abort_flush) { if (d->abort_wburst) flush_wb++; if (d->abort_reads) flush_rd++; }
            // [ddr] dpb_mem's own rule, policed at the mux's A side (the mux enforces it for the
            // port, so a client that broke it would be invisible at the DDR model)
            if (d->a_wr_early) fail("ddr", "the DPB client presents a write with its reads outstanding");
            m_addr = d->ddr_address; m_burst = d->ddr_burstcount; m_rd = d->ddr_read; m_wr = d->ddr_write;
            m_wd = d->ddr_writedata; m_be = d->ddr_byteenable;
            // [hold]: a write accepted into a store the display holds
            if (m_wr && !ddr.waitreq) {
                uint32_t rel = m_addr - BASE;
                if ((rel >> 22) == 0 && (dhold & (1u << (rel >> 17))))
                    fail("hold", fmt("a write to store %u while the display holds it (word %08x)", rel >> 17, m_addr));
            }
        }
        // ---- the harness's own registers: computed at a rising edge from what the edge
        // sampled, driven at the following falling edge (one eval per edge: the DUT's logic
        // is all rising-edge, so an input settles anywhere in the low half the same) ----
        if (mclk_rise && d->mrst_n) {
            ddr.edge(m_addr, m_burst, m_rd, m_wr, m_wd, m_be);
            mclk_pend = true;
        }
        if (clk_rise && d->rst_n) {
            if (es_fire) es_i++;
            clk_pend = true;
        }
        bool clk_fall = do_clk && clk_hi, mclk_fall = do_mclk && mclk_hi;
        if (mclk_fall && mclk_pend) {
            d->ddr_waitrequest = ddr.waitreq;
            d->ddr_readdatavalid = ddr.rdv;
            d->ddr_readdata = ddr.rdata;
            mclk_pend = false;
        }
        if (clk_fall && clk_pend) {
            clk_pend = false;
            // P6b1: the seek, once the decoder is half-way through A's last picture
            if (seek_have && seek_phase == 0 && cur_pic == seek_a_pics && mbs_in_pic >= seek_abandon && seek_wait < 0)
                seek_wait = seek_delay;                  // +seek_delay: that many clk_dec cycles later
            bool seek_cond = seek_on == 0 || (seek_on == 1 && d->abort_wburst) || (seek_on == 2 && d->abort_reads);
            if (seek_wait > 0) seek_wait--;
            if (seek_wait == 0 && seek_phase == 0 && seek_cond) {
                if (d->err_count || d->mb_err_count || d->fe_err_count || d->fe_refused_count)
                    fail("count", fmt("before the seek: errors recon %u (code %u), mb %u, front end %u, refusals %u",
                                      d->err_count, d->err_code, d->mb_err_count, d->fe_err_count, d->fe_refused_count));
                mb_base = (long)d->mb_count - mbs_in_pic;       // the abandoned picture's are not the golden's
                for (const Score& sc : pend) {                   // complete, writes not landed: cut by the reset
                    cut_pics++;
                    if (dhold & (1u << sc.store)) cut_held++;
                    hold &= ~(1u << sc.store);
                }
                pend.clear();
                hold &= ~(1u << store_of.back());               // the abandoned picture's store
                store_of.pop_back();
                cur_pic--;                                       // B's first picture is golden picture a_pics
                wr_issued = 0;
                if (es_i < (size_t)seek_b_off) es_i = (size_t)seek_b_off;   // the rest of A: flushed with the reader
                d->seek_rst_n = 0; seek_phase = 1; seek_cnt = 20;
            } else if (seek_phase == 1 && --seek_cnt == 0) {
                d->seek_rst_n = 1; seek_phase = 2;
            }
            size_t es_lim = (seek_have && seek_phase < 2) ? (size_t)seek_b_off : es.n;
            d->es_valid = es_i < es_lim;
            if (es_i < es_lim) d->es_byte = es.p[es_i];
            while (mk_i < marks.size() && marks[mk_i].off < es_i) mk_i++;
            d->es_mark = mk_i < marks.size() && marks[mk_i].off == es_i;
            d->es_pts = d->es_mark ? marks[mk_i].pts : 0;
            d->es_ep = d->es_mark ? marks[mk_i].ep : 0;
            // the end of the window: one flush pulse after the last byte was taken
            if (es_i == es.n && !flushed) { d->es_flush = 1; flushed = true; flush_hold = 1; }
            else if (flush_hold) { flush_hold--; if (!flush_hold) d->es_flush = 0; }
            // score the pictures whose writes have all landed; release their stores
            while (!pend.empty() && d->wr_landed >= pend.front().target) {
                Score s = pend.front();
                pend.pop_front();
                check_store(s.p, s.store, s.st);
                if (d->cur_store != s.store) hold &= ~(1u << s.store);
            }
            // the display: a store released when its time comes
            for (int i = 0; i < 20; i++)
                if ((dhold & (1u << i)) && cycles >= rel_at[i]) dhold &= ~(1u << i);
            d->disp_hold = hold | dhold;
            // the end: every byte taken and flushed, both halves idle for 2,000 cycles
            if (flushed && !flush_hold && eos_seen && d->idle && !d->fe_busy && pend.empty()) idle_run++;
            else idle_run = 0;
            if (idle_run > 2000) done = true;
            if (cycles && (cycles % 50000000) == 0)
                fprintf(stderr, "cosim %s: %llu cycles, picture %ld of %ld, %u macroblocks\n", label.c_str(),
                        (unsigned long long)cycles, cur_pic, n_pics, d->mb_count);
        }
        // ---- the edge ----
        if (do_clk) { clk_hi = !clk_hi; d->clk = clk_hi; t_clk += T_CLK / 2 + (clk_hi ? 0 : T_CLK % 2); }
        if (do_mclk) { mclk_hi = !mclk_hi; d->mclk = mclk_hi; t_mclk += T_MCLK / 2 + (mclk_hi ? 0 : T_MCLK % 2); }
        d->eval();
    }

    // (the last picture is closed by the end-of-stream word and scored like every other)
    if (eos_seen != 1) fail("out", fmt("end of stream: %ld eos_done pulses, want 1", eos_seen));
    if (n_emit != (long)outs.size()) fail("out", fmt("%ld stores emitted, the model emits %zu", n_emit, outs.size()));
    if (cur_pic + 1 != n_pics) fail("count", fmt("%ld pictures, the window has %ld", cur_pic + 1, n_pics));
    if (seek_have && seek_phase != 2) fail("count", fmt("the seek never happened (phase %d, picture %ld)", seek_phase, cur_pic));
    if (mb_base + (long)d->mb_count != n_mbs)
        fail("count", fmt("%ld macroblocks, the window has %ld", mb_base + (long)d->mb_count, n_mbs));
    if (d->err_count || d->mb_err_count)
        fail("count", fmt("errors: recon %u (code %u), mb %u", d->err_count, d->err_code, d->mb_err_count));
    if (d->fe_err_count || d->fe_refused_count)
        fail("count", fmt("front end: %u errors (code %u), %u refusals (code %u)", d->fe_err_count, d->fe_err_code,
                          d->fe_refused_count, d->fe_refused_code));
    // P8: a picture refused for its size (recon_top's R_SIZE) -- not scored until 2026-10-06; the rig
    // counted one at item starts of a 30-item title (docs/transport.md "D8, the handoff measured")
    if (d->ref_size) fail("count", fmt("%u pictures refused for their size (above MaxFS)", d->ref_size));
    if (n_post + cut_pics != n_pics) fail("count", fmt("%ld pictures scored (+ %ld cut by the seek) of %ld", n_post, cut_pics, n_pics));
    if (rp_have) {
        long got[5] = {d->rp_starts, d->rp_non_idr, d->rp_pre, d->rp_lead, d->rp_mmco};
        const char* nm[5] = {"starts", "non-IDR starts", "pictures before the first I", "leading pictures", "MMCOs before the entry"};
        for (int i = 0; i < 5; i++)
            if (got[i] != rp_want[i]) fail("count", fmt("recovery-point start: %ld %s, the model %ld", got[i], nm[i], rp_want[i]));
    }
    if (seek_have)
        printf("seek %s: after picture %ld's %ld of its macroblocks + %ld cycles%s; %ld complete pictures cut by the reset "
               "(%ld of them held by the display); the abort held an open write burst %llu mclk cycles, A reads %llu\n",
               label.c_str(), seek_a_pics, seek_abandon, seek_delay,
               seek_on == 1 ? " (on an open write burst)" : seek_on == 2 ? " (on outstanding reads)" : "", cut_pics, cut_held,
               (unsigned long long)flush_wb, (unsigned long long)flush_rd);
    if (n_pre != n_mbs) {
        // skipped macroblocks are reconstructed too: every macroblock reaches the deblocker
        fail("count", fmt("%ld macroblocks scored pre-deblock of %ld", n_pre, n_mbs));
    }
    uint64_t span = last_mb_cycle - first_mb_cycle;
    double per_mb = (double)span / (n_mbs > 1 ? n_mbs - 1 : 1);
    double fps = n_frames ? 81.0e6 / ((double)span / n_frames) : 0;
    // real time: the window's display time (its pic_struct SEI) against its decode time
    // at 81 MHz under this DDR model (the rig measured 4-7 % slower on Akira / Family Guy)
    double rt = (play_us && span) ? (play_us * 1e-6) / ((double)span / 81.0e6) : 0;
    printf("cosim %s: %ld pictures (%ld fields), %ld frames, %ld macroblocks, every pre-deblock macroblock and every "
           "picture identical, %ld stores emitted in the model's order; %.0f clk_dec cycles a macroblock, %.1f frames/s at 81 MHz, %.2fx real time; "
           "%llu unwritten reads\n",
           label.c_str(), n_pics, n_fields, n_frames, n_mbs, n_emit, per_mb, fps, rt, (unsigned long long)ddr.unwritten);
    if (prof) {
        const char* un[5] = {"ms", "inter", "interp", "es", "rs"};
        std::vector<uint64_t>* hs[5] = {&h_ms, &h_in, &h_ik, &h_es, &h_rs};
        printf("PROF macroblocks %ld span %llu\n", n_mbs, (unsigned long long)span);
        for (int u = 0; u < 5; u++)
            for (int i = 0; i < 256; i++)
                if ((*hs[u])[i]) printf("PROF %s %d %llu\n", un[u], i, (unsigned long long)(*hs[u])[i]);
    }
    printf("PASS: cosim\n");
    d->final();
    delete d;
    delete ctx;
    return 0;
}
