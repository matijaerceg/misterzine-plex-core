// bench/h264/cosim_main.cpp -- the Verilator cosim of the decoder (bench/h264/cosim_top.sv:
// h264/dec/h264_top.sv -> h264/dec/recon_top.sv as emu composes them) over a disc window,
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
//   [hang]  a macroblock within 200,000 clk_dec cycles of the previous one
//   [ddr]   the Avalon rules ddr_model.sv polices (a write beat with reads outstanding, a
//           read inside a write burst, a burst of 0 or > 8 beats, reads without credit,
//           an address outside the window)
//   [out]   P5d, the output process: every store emitted is, in order, the model's
//           (STEM.out: its first picture, WHEN -- the pictures opened before it -- and its
//           shape), and the end-of-stream word flushes every one (eos_done, once)
//   [hold]  no write burst into a store the display holds (emitted, not yet released)
//   [avalon] a request held under waitrequest is presented unchanged until accepted
// The harness is the display: it holds each emitted store for a random 0..+hold=N clk_dec
// cycles (default 5000), then releases it; a store being scored is held too.
//
// Clocks: clk_dec 81 MHz (12.346 ns), the DDR3 bridge 90 MHz (11.111 ns). The DDR model
// is ddr_model.sv's: random waitrequest (wait_pct %), a random read latency per burst
// (lat_min..lat_max mclk cycles from acceptance), bursts in flight returned in order.
//
//   cosim STEM [+seed=N] [+wait_pct=N] [+lat_min=N] [+lat_max=N] [+hold=N] [+label=TEXT] [+prof] [+ring]
// +ring (roadmap P3h): the window reaches the decoder through the HPS interface -- this
// harness links hps/lib (the rig's C) with the DDR model as its backend, splits the window
// into access units (h264ring_split_annexb), opens a session and writes one VIDEO_AU record
// each, PTS stamped (i x 1501), the last with END_OF_STREAM, as the ring allows; the
// library's waits advance simulated time. Added arms: [ring] the reader ends with no error
// in a live state; [count] every picture tagged with its PTS, none dropped. The cycles a
// macroblock then include ram1's occupancy by the ring's reads and polls.
// +prof: per clk_dec cycle from the first macroblock to the last, histograms of recon_mb's
// front state (ms), recon_inter's two (fetch st, interpolation k), the back engine's (es) and the residual engine's
// (rs), printed as "PROF <unit> <state> <cycles>" (tools/cosim_prof.py names them).
// PASS marker: "PASS: cosim"; every failure prints "FAIL [arm] ..." and exits 1.
#include <cerrno>
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

#include <functional>

#include "Vcosim_top.h"
#include "verilated.h"
#include "h264ring.h"

// ring mode: the library's hooks into the simulation (sleep advances it, now reads it)
static std::function<void(uint64_t)> g_step;
static std::function<uint64_t()> g_now;
static unsigned g_clk_khz = 96429;       // clk_dec, kHz: sys_pll's outclk_3 (+clk_khz=N / +clk_mhz=N)
static void ring_sleep(void*, unsigned us) { g_step((uint64_t)us * g_clk_khz / 1000); }
static uint64_t ring_now(void*) { return g_now(); }
static void ring_barrier(void*) {}

static const uint32_t BASE = 0x06000000u;          // the model's window (word address; byte 0x3000_0000)
static const uint32_t DPB = 0x06400000u;           // the DPB (byte 0x3200_0000, above the ring: emu's DPB_BASE)
static const int AW = 24;                          // 128 MB: the control block, the ring, 20 stores of 2 MiB
static const int STORE_SH = 18;                    // 2 MiB stores (docs/h264_recon.md S2.2)
// +clk_khz=N / +clk_mhz=N (P5b, docs/throughput.md): clk_dec at another frequency than the
// core's 96.43 MHz (from P5b; 103.85 on main from PR fj#17 until the macroblock pipeline; 81 before P5b) -- the DDR3 bridge stays at 90, so the latency-bound
// parts (the reference fetch) are modelled as they would be on the rig
static uint64_t T_CLK = 10370;          // ps: (1e9 + khz / 2) / khz
static const uint64_t T_MCLK = 11111;   // ps

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
    bool prof = false, ring = false;
    uint32_t hold_max = 5000;
    std::vector<uint64_t> h_ms(256, 0), h_in(256, 0), h_ik(256, 0), h_es(256, 0), h_rs(256, 0), h_as(256, 0), h_fe(256, 0), h_d8(256, 0), h_ki(256, 0), h_kn(256, 0), h_m0(256, 0);
    // +prof, per picture (docs/mb_pipeline.md S4i: the imbalance between the stages is per
    // picture type): the cycles since the previous picture completed, the bins, the slice
    // types its macroblocks were decoded in (a mask, 1 << slice_type), every unit's histogram
    std::vector<uint64_t> pic_cycles, pic_bins;
    std::vector<unsigned> pic_mask;
    std::vector<std::vector<uint64_t>> pic_h;
    std::vector<uint64_t> cur_h(11 * 256, 0);
    uint64_t pic_prev = 0, cur_bins = 0;
    unsigned cur_mask = 0;
    uint64_t fe_bins = 0;
    for (int i = 2; i < argc; i++) {
        std::string a = argv[i];
        auto val = [&](const char* k) { return a.rfind(k, 0) == 0 ? a.c_str() + strlen(k) : nullptr; };
        if (auto v = val("+seed=")) seed = strtoull(v, nullptr, 10);
        else if (auto v = val("+wait_pct=")) ddr.wait_pct = atoi(v);
        else if (auto v = val("+lat_min=")) ddr.lat_min = atoi(v);
        else if (auto v = val("+lat_max=")) ddr.lat_max = atoi(v);
        else if (auto v = val("+label=")) label = v;
        else if (auto v = val("+hold=")) hold_max = (uint32_t)atoi(v);
        else if (auto v = val("+clk_mhz=")) { g_clk_khz = 1000u * (unsigned)atoi(v); T_CLK = (1000000000ull + g_clk_khz / 2) / g_clk_khz; }
        else if (auto v = val("+clk_khz=")) { g_clk_khz = (unsigned)atoi(v); T_CLK = (1000000000ull + g_clk_khz / 2) / g_clk_khz; }
        else if (a == "+prof") prof = true;
        else if (a == "+ring") ring = true;
    }
    rng_s ^= seed * 0x9E3779B97F4A7C15ull;
    if (!rng_s) rng_s = 1;

    // ---- the golden -------------------------------------------------------------------
    Map es, pre, post;
    es.open(stem + ".es");
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
    d->clk = 0; d->mclk = 0; d->rst_n = 0; d->mrst_n = 0; d->ring_mode = ring;
    d->es_valid = 0; d->es_byte = 0; d->es_flush = 0; d->disp_hold = 0;
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
    uint32_t stall_q = 0;
    struct Score { long p; int store, st; uint64_t target; };
    std::deque<Score> pend;

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
                    uint32_t a = DPB + ((uint32_t)store << STORE_SH) + (uint32_t)(poff + (size_t)srow * words + x);
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
    auto edge = [&]() {
        bool do_clk = t_clk <= t_mclk, do_mclk = t_mclk <= t_clk;
        t = do_clk ? t_clk : t_mclk;
        if (t >= reset_until && !d->rst_n) { d->rst_n = 1; d->mrst_n = 1; d->eval(); }
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
                long step = cur_pic + 1;
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
                cur_pic++;
                hold |= 1u << d->cur_store;
                store_of.push_back(d->cur_store);
                if (!d->pinfo_second) first_pic_of[d->cur_store] = cur_pic;
            }
            if (d->pre_db) check_pre();
            if (d->wr_cmd) wr_issued++;
            if (d->pic_done) {
                // pictures complete in decoding order (the last one on the end of stream)
                if (n_done >= (long)store_of.size() || store_of[n_done] != d->done_store)
                    fail("count", fmt("pic_done %ld in store %d: not that picture's store", n_done, d->done_store));
                pend.push_back({n_done, d->done_store, d->done_struct, wr_issued});
                n_done++;
                if (prof) {
                    pic_cycles.push_back(cycles - pic_prev); pic_prev = cycles;
                    pic_bins.push_back(cur_bins); pic_mask.push_back(cur_mask); pic_h.push_back(cur_h);
                    cur_bins = 0; cur_mask = 0; std::fill(cur_h.begin(), cur_h.end(), 0);
                }
            }
            if (prof && first_mb_cycle) {
                h_ms[d->mb_state]++; h_in[d->inter_state]++; h_ik[d->interp_state]++; h_es[d->engine_state]++; h_rs[d->res_state]++; h_as[d->a_state]++; h_fe[d->fe_state]++; h_d8[d->dq8_state]++; h_ki[d->kitem]++; if (d->kitem_take) h_kn[d->kitem]++; h_m0[d->mc0_state]++;
                fe_bins += d->fe_bin; cur_bins += d->fe_bin;
                cur_h[d->mb_state]++; cur_h[256 + d->inter_state]++; cur_h[512 + d->interp_state]++; cur_h[768 + d->engine_state]++;
                cur_h[1024 + d->res_state]++; cur_h[1280 + d->a_state]++; cur_h[1536 + d->fe_state]++; cur_h[1792 + d->dq8_state]++; cur_h[2048 + d->kitem]++; if (d->kitem_take) cur_h[2304 + d->kitem]++; cur_h[2560 + d->mc0_state]++;
                if (d->mb_done) cur_mask |= 1u << d->mb_slice_type;
            }
            if (d->mb_done || d->stall_cycles != stall_q) {   // a wait on the display is not a hang
                since = 0;
                stall_q = d->stall_cycles;
                if (d->mb_done) {
                if (!first_mb_cycle) first_mb_cycle = cycles;
                last_mb_cycle = cycles;
                }
            } else if (ring && !first_mb_cycle) {
                since = 0;                              // the session opens first (the startup bound below)
                if (cycles > 200000000ull) fail("ring", "no macroblock in 200 M cycles: the ring never fed the decoder");
            } else if (++since > HANG) {
                fail("hang", fmt("no macroblock for %llu cycles (after %u, picture %ld, state %u)",
                                 (unsigned long long)HANG, d->mb_count, cur_pic, d->mb_state));
            }
        }
        if (mclk_rise && d->mrst_n) {
            m_addr = d->ddr_address; m_burst = d->ddr_burstcount; m_rd = d->ddr_read; m_wr = d->ddr_write;
            m_wd = d->ddr_writedata; m_be = d->ddr_byteenable;
            // [hold]: a write accepted into a store the display holds
            if (m_wr && !ddr.waitreq) {
                uint32_t rel = m_addr - DPB;
                if (m_addr >= DPB && (rel >> STORE_SH) < 20 && (dhold & (1u << (rel >> STORE_SH))))
                    fail("hold", fmt("a write to store %u while the display holds it (word %08x)", rel >> STORE_SH, m_addr));
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
            d->es_valid = !ring && es_i < es.n;
            if (es_i < es.n) d->es_byte = es.p[es_i];
            // the end of the window: one flush pulse after the last byte was taken
            if (!ring && es_i == es.n && !flushed) { d->es_flush = 1; flushed = true; flush_hold = 1; }
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
    };

    if (!ring) {
        while (!done) edge();
    } else {
        // ---- ring mode: the library feeds the window through the HPS interface ----
        const uint32_t CTRL_OFF = (H264RING_CTRL_BYTE >> 3) - BASE, RING_OFF = (H264RING_RING_BYTE >> 3) - BASE;
        if (RING_OFF + (H264RING_RING_SIZE >> 3) > (1u << AW)) fail("harness", "the ring is outside the DDR model's window");
        for (uint32_t i = CTRL_OFF; i < RING_OFF + (H264RING_RING_SIZE >> 3); i++) ddr.wrt[i] = 1;   // the ARM's writes
        g_step = [&](uint64_t n) { uint64_t c0 = cycles; while (!done && cycles < c0 + n) edge(); };
        g_now = [&]() { return cycles * 1000 / g_clk_khz; };
        size_t n_aus = h264ring_split_annexb(es.p, es.n, nullptr, 0);
        std::vector<h264ring_au> aus(n_aus ? n_aus : 1);
        h264ring_split_annexb(es.p, es.n, aus.data(), n_aus);
        while (ddr.mem[CTRL_OFF] != H264RING_MAGIC) {                  // the first status frame
            g_step(1000);
            if (cycles > 5000000) fail("ring", "no status block in 5 M cycles");
        }
        struct h264ring_backend be;
        memset(&be, 0, sizeof be);
        be.ctrl = (volatile uint64_t*)&ddr.mem[CTRL_OFF];
        be.ring = (volatile uint64_t*)&ddr.mem[RING_OFF];
        be.ring_size = H264RING_RING_SIZE;
        be.barrier = ring_barrier; be.sleep_us = ring_sleep; be.now_us = ring_now;
        h264ring* rr = nullptr;
        int rc = h264ring_attach(&rr, &be);
        if (rc) fail("ring", fmt("attach: %d", rc));
        if ((rc = h264ring_start_session(rr, 100))) fail("ring", fmt("session: %d (state %u err %u)", rc, d->ring_state, d->ring_err));
        size_t fed = 0;
        while (!done) {
            edge();
            if (fed < n_aus && (cycles & 255) == 0) {
                while (fed < n_aus) {
                    unsigned fl = fed + 1 == n_aus ? H264RING_F_END_OF_STREAM : 0;
                    rc = h264ring_try_write_au(rr, es.p + aus[fed].off, aus[fed].len, (int64_t)fed * 1501, fl);
                    if (rc == -EAGAIN) break;
                    if (rc) fail("ring", fmt("access unit %zu: %d (state %u err %u)", fed, rc, d->ring_state, d->ring_err));
                    fed++;
                }
                if (fed == n_aus) flushed = true;               // the END_OF_STREAM is written
            }
        }
        if (d->ring_err) fail("ring", fmt("the reader stopped: error %u (state %u)", d->ring_err, d->ring_state));
        if (d->ring_state != H264RING_S_PLAYING && d->ring_state != H264RING_S_ENDED)
            fail("ring", fmt("the reader's state %u", d->ring_state));
        if ((long)d->fe_pts_tag != n_pics || d->fe_pts_drop)
            fail("count", fmt("PTS: %u pictures tagged of %ld, %u dropped (every access unit carries one)",
                              d->fe_pts_tag, n_pics, d->fe_pts_drop));
        h264ring_close(rr);
    }

    // (the last picture is closed by the end-of-stream word and scored like every other)
    if (eos_seen != 1) fail("out", fmt("end of stream: %ld eos_done pulses, want 1", eos_seen));
    if (n_emit != (long)outs.size()) fail("out", fmt("%ld stores emitted, the model emits %zu", n_emit, outs.size()));
    if (cur_pic + 1 != n_pics) fail("count", fmt("%ld pictures, the window has %ld", cur_pic + 1, n_pics));
    if ((long)d->mb_count != n_mbs) fail("count", fmt("%u macroblocks, the window has %ld", d->mb_count, n_mbs));
    if (d->err_count || d->mb_err_count)
        fail("count", fmt("errors: recon %u (code %u), mb %u", d->err_count, d->err_code, d->mb_err_count));
    if (d->fe_err_count || d->fe_refused_count)
        fail("count", fmt("front end: %u errors (code %u), %u refusals (code %u)", d->fe_err_count, d->fe_err_code,
                          d->fe_refused_count, d->fe_refused_code));
    if (n_post != n_pics) fail("count", fmt("%ld pictures scored of %ld", n_post, n_pics));
    if (n_pre != n_mbs) {
        // skipped macroblocks are reconstructed too: every macroblock reaches the deblocker
        fail("count", fmt("%ld macroblocks scored pre-deblock of %ld", n_pre, n_mbs));
    }
    uint64_t span = last_mb_cycle - first_mb_cycle;
    double per_mb = (double)span / (n_mbs > 1 ? n_mbs - 1 : 1);
    double fps = n_frames ? g_clk_khz * 1.0e3 / ((double)span / n_frames) : 0;
    // real time: the window's display time (its pic_struct SEI) against its decode time
    // at clk_dec under this DDR model (the rig measured 4-7 % slower on Akira / Family Guy)
    double rt = (play_us && span) ? (play_us * 1e-6) / ((double)span / (g_clk_khz * 1.0e3)) : 0;
    printf("cosim %s: %ld pictures (%ld fields), %ld frames, %ld macroblocks, every pre-deblock macroblock and every "
           "picture identical, %ld stores emitted in the model's order; %.0f clk_dec cycles a macroblock, %.1f frames/s at %.2f MHz, %.2fx real time; "
           "%llu unwritten reads%s\n",
           label.c_str(), n_pics, n_fields, n_frames, n_mbs, n_emit, per_mb, fps, g_clk_khz / 1000.0, rt, (unsigned long long)ddr.unwritten,
           ring ? fmt(" [through the ring: %u polls]", d->ring_polls).c_str() : "");
    if (prof) {
        const char* un[11] = {"ms", "inter", "interp", "es", "rs", "as", "fe", "dq8", "kitem", "kitemn", "mc0"};
        std::vector<uint64_t>* hs[11] = {&h_ms, &h_in, &h_ik, &h_es, &h_rs, &h_as, &h_fe, &h_d8, &h_ki, &h_kn, &h_m0};
        for (size_t i = 0; i < pic_cycles.size(); i++) {
            printf("PROF pic %zu %u %llu %llu\n", i, pic_mask[i], (unsigned long long)pic_cycles[i], (unsigned long long)pic_bins[i]);
            for (int u = 0; u < 11; u++)
                for (int j = 0; j < 256; j++)
                    if (pic_h[i][256 * u + j]) printf("PROF pu %zu %s %d %llu\n", i, un[u], j, (unsigned long long)pic_h[i][256 * u + j]);
        }
        printf("PROF macroblocks %ld span %llu\n", n_mbs, (unsigned long long)span);
        printf("PROF bins %llu\n", (unsigned long long)fe_bins);
        for (int u = 0; u < 11; u++)
            for (int i = 0; i < 256; i++)
                if ((*hs[u])[i]) printf("PROF %s %d %llu\n", un[u], i, (unsigned long long)(*hs[u])[i]);
    }
    printf("PASS: cosim\n");
    d->final();
    delete d;
    delete ctx;
    return 0;
}
