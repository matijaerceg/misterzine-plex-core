/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/tests/test_ring.c -- the client library against a fake core (the protocol's core side,
 * written from docs/architecture.md: the boot rule, the nonce, the read index, the seqlocked
 * status block). The bytes the fake core consumes are written to a file that
 * tools/tests/test_hps_lib.py parses with tools/ring_model.py's consumer -- an oracle that
 * shares nothing with this library.
 *
 *   test_ring [OUT_STEM]   prints one PASS / FAIL line per check and "test_ring: ALL GREEN";
 *                          with OUT_STEM writes OUT_STEM.stream (the consumed bytes, from the
 *                          session's start index), OUT_STEM.pics / OUT_STEM.copyN (0.15: the
 *                          PICTURE records written and the store copies) and OUT_STEM.aus (one line per access unit
 *                          written: length and first byte, and its flags)
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "h264ring.h"
#include "h264ring_priv.h"       /* inspect version gating on the fake handle */
#include "h264ring_cavlc.h"
#include "cavlc_fixtures.h"        /* generated: tools/cavlc_synth.py --c-header */

#ifndef H264_PKG
#define H264_PKG "../h264/dec/h264_pkg.sv"   /* the decoder's refusal codes (run from hps/) */
#endif

#define RING (64u * 1024u)
static uint64_t ctrl[512], ringmem[RING / 8];
static int fails;

#define CHECK(label, cond) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "PASS" : "FAIL", label); \
                                if (!ok_) fails++; } while (0)

/* ---- the fake core ---- */
static struct {
    int booted, sess, consume, tear, error, alive;
    int widx_align;                                       /* the RTL's poll: a misaligned write index in a session */
    int ovl_refuse, ovl_blind;                            /* (0.9) refuse every descriptor / read none */
    unsigned ack_delay;                                    /* hold a new session's ACK for startup tests */
    int ready;                                            /* (0.15) report READY (no video record yet) */
    uint32_t pic_held, pic_emitted;                       /* (0.15) word 84 */
    uint32_t seen, rw, seq, ack;
    uint8_t geometry_ack;
    uint8_t *log; size_t log_n, log_cap; uint32_t log_start;
    uint64_t now;
} core;

static uint32_t lo(unsigned w) { return (uint32_t)ctrl[w]; }

static void core_status(void)
{
    if (!core.alive)
        return;
    core.seq++;
    ctrl[0] = H264RING_MAGIC;
    ctrl[1] = H264RING_VERSION | (32ull << 16) | (32ull << 32);
    ctrl[2] = 0x31800000ull | ((uint64_t)RING << 32);
    ctrl[3] = core.seq | ((uint64_t)H264RING_MAX_PAYLOAD << 32);
    ctrl[4] = (uint64_t)(!core.sess ? H264RING_S_NO_SESSION : core.error ? H264RING_S_ERROR :
                         core.ready ? H264RING_S_READY : H264RING_S_PLAYING);
    /* (0.15) word 84: the stores' holds, the store count, the pictures emitted */
    ctrl[84] = core.pic_held | ((uint64_t)H264RING_DPB_STORES << 24) | ((uint64_t)core.pic_emitted << 32);
    ctrl[5] = core.rw | ((uint64_t)core.ack << 32);
    /* (0.9) the overlay: a consistent descriptor (gen_lo == gen_hi) is read, its generation reported */
    if (!core.ovl_blind && lo(H264RING_W_OVL_GEN_LO) == lo(H264RING_W_OVL_GEN_HI))
        ctrl[46] = lo(H264RING_W_OVL_GEN_LO) | ((uint64_t)(core.ovl_refuse ? H264RING_OVL_S_REFUSED :
                   (lo(H264RING_W_OVL_CTL) & 1u) ? H264RING_OVL_S_ACCEPTED : H264RING_OVL_S_OFF) << 32);
    ctrl[31] = (core.tear ? core.seq - 1u : core.seq) | ((uint64_t)core.geometry_ack << 32); /* seq tail + geometry ACK */
    if (core.tear) core.tear--;
}

static void core_step(void)
{
    uint32_t wi = lo(H264RING_W_WRITE_INDEX), nonce = lo(H264RING_W_NONCE);
    if (!core.booted) {
        core.seen = nonce; core.booted = 1;               /* an earlier program's: ignored */
    } else if (nonce != core.seen) {
        core.seen = nonce; core.sess = 1; core.rw = wi & ~15u;
        if (!core.ack_delay) core.ack = nonce;
        core.log_start = core.rw; core.log_n = 0;
    } else if (core.sess && core.ack != nonce && core.ack_delay) {
        if (!--core.ack_delay) core.ack = nonce;
    } else if (core.sess && (uint8_t)(ctrl[H264RING_W_GEOMETRY] >> 56) != 0 &&
               (uint8_t)(ctrl[H264RING_W_GEOMETRY] >> 56) != core.geometry_ack) {
        core.geometry_ack = (uint8_t)(ctrl[H264RING_W_GEOMETRY] >> 56);
    } else if (core.sess && (wi & 15u)) {
        core.widx_align = 1;                               /* ring_rd's E_PEVAL: WIDX_ALIGN, every poll of a session */
    } else if (core.sess && core.consume) {
        while (core.rw != wi) {                            /* copy what the core would read */
            if (core.log_n == core.log_cap) {
                core.log_cap = core.log_cap ? 2 * core.log_cap : 65536;
                core.log = (uint8_t *)realloc(core.log, core.log_cap);
            }
            core.log[core.log_n++] = (uint8_t)(ringmem[(core.rw % RING) / 8] >> (8 * (core.rw % 8)));
            core.rw++;
        }
    }
    core_status();
}

static int ovl_probe_on, ovl_probe_seen;
static uint32_t ovl_probe_ctl, ovl_probe_base, ovl_probe_gen;
static void be_sleep(void *u, unsigned us)
{
    (void)u;
    if (ovl_probe_on && lo(H264RING_W_NONCE) != core.ack) {
        ovl_probe_ctl = lo(H264RING_W_OVL_CTL);
        ovl_probe_base = lo(H264RING_W_OVL_BASE);
        ovl_probe_gen = lo(H264RING_W_OVL_GEN_LO);
        ovl_probe_seen = 1;
    }
    core.now += us;
    core_step();
}
static uint64_t be_now(void *u) { (void)u; return core.now; }
/* (0.9) the barriers during an overlay write: words 72 (gen_lo) and 79 (gen_hi) at each */
static int bar_log_on, bar_n;
static uint32_t bar_lo[8], bar_hi[8];
static void be_barrier(void *u)
{
    (void)u;
    if (bar_log_on && bar_n < 8) { bar_lo[bar_n] = lo(H264RING_W_OVL_GEN_LO); bar_hi[bar_n] = lo(H264RING_W_OVL_GEN_HI); bar_n++; }
}

static h264ring *attach(void)
{
    struct h264ring_backend be;
    h264ring *r = NULL;
    memset(&be, 0, sizeof be);
    be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING;
    be.sleep_us = be_sleep; be.now_us = be_now; be.barrier = be_barrier;
    return h264ring_attach(&r, &be) ? NULL : r;
}

static uint32_t hdr_flags_at(uint32_t index) { return (uint32_t)(ringmem[(index % RING) / 8] >> 8) & 0xFF; }

/* (fj#20) the VIDEO_AU record written from index `from` (a PAD before it skipped): its payload */
static uint32_t record_from(uint32_t from, uint8_t *out, uint32_t cap)
{
    for (int k = 0; k < 2; k++) {
        uint64_t w0 = ringmem[(from % RING) / 8];
        uint32_t len = (uint32_t)(w0 >> 32), type = (uint32_t)(w0 & 0xFF);
        if (type == H264RING_T_PAD) {
            from += 16u + ((len + 15u) & ~15u);
            continue;
        }
        for (uint32_t i = 0; i < len && i < cap; i++) {
            uint32_t at = from + 16u + i;
            out[i] = (uint8_t)(ringmem[(at % RING) / 8] >> (8 * (at % 8)));
        }
        return len;
    }
    return 0;
}

/* write one access unit, return what the core would read (its payload): length, or -errno */
static int write_and_read(h264ring *r, const uint8_t *au, uint32_t len, unsigned flags, uint8_t *got, uint32_t cap)
{
    uint32_t w0 = lo(H264RING_W_WRITE_INDEX);
    int rc = h264ring_write_au(r, au, len, -1, flags, 1000);
    core_step();
    return rc ? rc : (int)record_from(w0, got, cap);
}

int main(int argc, char **argv)
{
    h264ring *r;
    struct h264ring_status st;
    int rc;
    FILE *aus = NULL;
    static uint8_t buf[RING];
    srand(7);
    for (size_t i = 0; i < sizeof buf; i++) buf[i] = (uint8_t)(rand() & 0xFF);

    /* attach: the magic, the version */
    memset(ctrl, 0, sizeof ctrl);
    { struct h264ring_backend be; h264ring *x; memset(&be, 0, sizeof be); be.ctrl = ctrl; be.ring = ringmem;
      be.ring_size = RING; CHECK("attach: no magic -> ENODEV", h264ring_attach(&x, &be) == -ENODEV); }
    core.alive = 1; core_status();
    /* (1.0) the version rule: the same major, the core's minor at least the library's (1.1 since
     * 2026-10-10: a 1.0 core lacks 1.1's guarantee, docs/architecture.md "Queued audio: ...") */
    { static const struct { uint32_t v; int ok; const char *what; } vt[] = {
          { 0x0011, 0, "attach: a 0.17 core -> EPROTONOSUPPORT" },
          { 0x0200, 0, "attach: a 2.0 core -> EPROTONOSUPPORT" },
          { 0x0100, 0, "attach: a 1.0 core refused by a 1.1 program -> EPROTONOSUPPORT" },
          { 0x0101, 1, "attach: a 1.1 core" },
          { 0x0102, 1, "attach: a 1.2 core serves a 1.1 program" },
          { 0x01FF, 1, "attach: a 1.255 core serves a 1.1 program" } };
      for (unsigned i = 0; i < sizeof vt / sizeof vt[0]; i++) {
          struct h264ring_backend be; h264ring *x = NULL; int rc;
          ctrl[1] = (ctrl[1] & ~0xFFFFull) | vt[i].v;
          memset(&be, 0, sizeof be); be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING;
          rc = h264ring_attach(&x, &be);
          CHECK(vt[i].what, vt[i].ok ? rc == 0 && x != NULL : rc == -EPROTONOSUPPORT);
          if (x) h264ring_close(x);
      } }
    CHECK("version: an older minor refused (a 1.3 program, a 1.2 core)", !h264ring_version_ok(0x0102, 0x0103));
    CHECK("version: the same minor (1.3, 1.3)", h264ring_version_ok(0x0103, 0x0103));
    CHECK("version: a newer minor (1.3 program, 1.4 core)", h264ring_version_ok(0x0104, 0x0103));
    CHECK("version: another major with a larger minor refused (1.3 program, 0.17 core)", !h264ring_version_ok(0x0011, 0x0103));
    core_status();

    /* a stale write index and nonce left by an earlier load; the boot rule ignores them */
    ctrl[H264RING_W_WRITE_INDEX] = 0x0012345Bu;           /* misaligned on purpose: the core rounds it */
    ctrl[H264RING_W_NONCE] = 0xABCD0001u;
    core_step();
    CHECK("boot: the stale nonce starts nothing", !core.sess);
    r = attach();
    CHECK("attach", r != NULL);
    if (!r) { printf("test_ring: FAILURES\n"); return 1; }

    /* alive: the heartbeat must move */
    core.alive = 0;
    CHECK("alive: a still heartbeat -> ETIMEDOUT", h264ring_alive(r, 50) == -ETIMEDOUT);
    core.alive = 1;
    CHECK("alive", h264ring_alive(r, 50) == 0);

    /* interface 0.4: a settings request needs a session */
    {
        unsigned v[H264RING_OPT_COUNT] = {0};
        CHECK("settings: no session -> ENOTCONN", h264ring_request_settings(r, 1u, v) == -ENOTCONN);
    }

    /* (0.13) an earlier program's rumble left in words 36-38 */
    for (unsigned k = 0; k < 3; k++) ctrl[H264RING_W_RUMBLE + k] = 0xDEADBEEFu;
    /* the session: the nonce alone; the core starts at the write index it read */
    rc = h264ring_start_session(r, 100);
    CHECK("rumble: the first session writes this program's (0), never an earlier program's",
          lo(H264RING_W_RUMBLE) == 0 && lo(H264RING_W_RUMBLE + 1) == 0 && lo(H264RING_W_RUMBLE + 2) == 0);
    CHECK("session acknowledged", rc == 0 && core.sess && core.ack == lo(H264RING_W_NONCE));
    {
        struct h264ring_geometry g = {10, 20, 700, 440, 10, 20, 700, 440};
        CHECK("geometry: a 1.2 request waits for its sequence ACK", h264ring_set_geometry(r, &g, 100) == 0 &&
              core.geometry_ack == 1u);
        CHECK("geometry: viewport word precedes the sequence commit",
              ctrl[H264RING_W_GEOMETRY_CLIP] == (10ull | (20ull << 12) | (700ull << 24) | (440ull << 36)) &&
              (uint8_t)(ctrl[H264RING_W_GEOMETRY] >> 56) == core.geometry_ack);
        CHECK("geometry: signed x/y and size occupy word 39", ((ctrl[H264RING_W_GEOMETRY] >> 39) & 0x1FFFu) == 10u &&
              ((ctrl[H264RING_W_GEOMETRY] >> 26) & 0x1FFFu) == 20u &&
              ((ctrl[H264RING_W_GEOMETRY] >> 13) & 0x1FFFu) == 700u &&
              (ctrl[H264RING_W_GEOMETRY] & 0x1FFFu) == 440u);
    }
    CHECK("the nonce is new", lo(H264RING_W_NONCE) != 0xABCD0001u && lo(H264RING_W_NONCE) != 0);
    core_step();                                           /* the core's next poll of the session */
    CHECK("a cold boot's misaligned write index rounded down to 16 before the nonce (the core polls its alignment)",
          lo(H264RING_W_WRITE_INDEX) == 0x00123450u && !core.widx_align);
    CHECK("the core started at the stale index rounded to 16", core.rw == 0x00123450u);

    /* interface 0.4: the settings request -- one u32 in program word 35: the values in the
     * mirror's order (word 27 [44:32] shifted down by 32), the mask, the sequence number */
    {
        unsigned v[H264RING_OPT_COUNT] = {0};
        uint32_t want, mirror_lsb = H264RING_OSD_REFRESH_LSB - H264RING_OSD_ASPECT_LSB;
        v[H264RING_OPT_ASPECT] = 1; v[H264RING_OPT_REFRESH_RATE] = 3; v[H264RING_OPT_ANTI_TWITTER] = 2;
        rc = h264ring_request_settings(r, (1u << H264RING_OPT_ASPECT) | (1u << H264RING_OPT_REFRESH_RATE) |
                                          (1u << H264RING_OPT_ANTI_TWITTER), v);
        want = 1u | (3u << mirror_lsb) | (2u << (H264RING_OSD_ANTI_TWITTER_LSB - H264RING_OSD_ASPECT_LSB)) |
               (((1u << 0) | (1u << 5) | (1u << 6)) << H264RING_REQ_MASK_LSB) | (1u << H264RING_REQ_SEQ_LSB);
        CHECK("settings: the request word, in the mirror's layout, sequence 1", rc == 1 && lo(H264RING_W_SETTINGS) == want);
        rc = h264ring_request_settings(r, 1u << H264RING_OPT_HDMI_DEINTERLACE, v);
        CHECK("settings: the next request, sequence 2", rc == 2 && (lo(H264RING_W_SETTINGS) >> H264RING_REQ_SEQ_LSB) == 2u);
        v[H264RING_OPT_ASPECT] = 3;
        CHECK("settings: a value past its option's last -> EINVAL", h264ring_request_settings(r, 1u, v) == -EINVAL);
        CHECK("settings: an empty mask -> EINVAL", h264ring_request_settings(r, 0u, v) == -EINVAL);
        CHECK("settings: an unknown option -> EINVAL", h264ring_request_settings(r, 1u << H264RING_OPT_COUNT, v) == -EINVAL);
        CHECK("settings: a refused request writes nothing", (lo(H264RING_W_SETTINGS) >> H264RING_REQ_SEQ_LSB) == 2u);
        CHECK("settings: clear -> the word is 0 (no request)", h264ring_clear_settings(r) == 0 && lo(H264RING_W_SETTINGS) == 0u);
        rc = h264ring_request_display(r, 2, 0, 0, 0, 0);
        want = (1u << 23) | (2u << 13) | (3u << 24);
        CHECK("display settings: legacy refresh-match Off encoding", rc == 3 && lo(H264RING_W_SETTINGS) == want);
        rc = h264ring_request_display(r, 2, 0, 1, 0, 0);
        want = (1u << 23) | (2u << 13) | (1u << 3) | (4u << 24);
        CHECK("display settings: legacy 50/60 encoding remains compatible", rc == 4 && lo(H264RING_W_SETTINGS) == want);
        rc = h264ring_request_display(r, 2, 0, 2, 0, 0);
        want = (1u << 23) | (2u << 13) | (1u << 3) | (5u << 24);
        CHECK("display settings: legacy mode 2 maps to 50/60", rc == 5 && lo(H264RING_W_SETTINGS) == want);
        CHECK("display settings: mode above 2 rejected", h264ring_request_display(r, 2, 0, 3, 0, 0) == -EINVAL);
        r->interface_version = 0x103;
        rc = h264ring_request_display(r, 2, 0, 1, 0, 0);
        want = (1u << 23) | (2u << 13) | (1u << 3) | (6u << 24);
        CHECK("display settings: interface 1.3 keeps the 50/60 encoding", rc == 6 && lo(H264RING_W_SETTINGS) == want);
        rc = h264ring_request_display(r, 2, 0, 2, 0, 0);
        want = (1u << 23) | (2u << 13) | (1u << 3) | (7u << 24);
        CHECK("display settings: legacy mode 2 maps safely on interface 1.3", rc == 7 && lo(H264RING_W_SETTINGS) == want);
        CHECK("display settings: legacy request leaves extension bit 6 reserved", (lo(H264RING_W_SETTINGS) & (1u << 6)) == 0);
        r->interface_version = 0x104;
        rc = h264ring_request_display(r, 15, 2, 1, 0, 1);
        want = (1u << 23) | (15u << 13) | 2u | (1u << 3) | (1u << 5) | (8u << 24);
        CHECK("display settings: extended request preserves legacy encoding", rc == 8 && lo(H264RING_W_SETTINGS) == want);
        CHECK("display settings: invalid profile rejected", h264ring_request_display(r, 1, 5, 0, 0, 0) == -EINVAL);
        CHECK("display settings: invalid mask rejected", h264ring_request_display(r, 16, 0, 0, 0, 0) == -EINVAL);
        CHECK("display settings: refresh-match range checked", h264ring_request_display(r, 2, 0, 3, 0, 0) == -EINVAL);
        CHECK("display settings: invalid request leaves word", lo(H264RING_W_SETTINGS) == want);
        CHECK("display settings: clear", h264ring_clear_settings(r) == 0 && lo(H264RING_W_SETTINGS) == 0u);
        /* (found on the rig 2026-10-02) a SECOND program after this one: the core last consumed
         * sequence 9 (word 30's set_seq) and word 35 still holds the previous program's request.
         * Its session must not re-assert that request, and its first request must be new (10, not
         * 1 -- a repeated number is ignored) */
        {
            h264ring *r2;
            ctrl[30] = (ctrl[30] & ~(0xFFull << 24)) | (9ull << 24);
            ctrl[H264RING_W_SETTINGS] = (2u << 4) | (1u << (H264RING_REQ_MASK_LSB + 2)) | (9u << H264RING_REQ_SEQ_LSB);
            core_status();
            r2 = attach();
            rc = r2 ? h264ring_start_session(r2, 100) : -1;
            CHECK("settings: a new program's session clears the previous program's request", rc == 0 && lo(H264RING_W_SETTINGS) == 0u);
            v[H264RING_OPT_VIDEO_OUTPUT] = 3;
            rc = h264ring_request_settings(r2, 1u << H264RING_OPT_VIDEO_OUTPUT, v);
            CHECK("settings: its first request numbered past the core's last (10), Native (HDMI) accepted",
                  rc == 10 && (lo(H264RING_W_SETTINGS) >> H264RING_REQ_SEQ_LSB) == 10u &&
                  ((lo(H264RING_W_SETTINGS) >> 4) & 3u) == 3u);
            h264ring_close(r2);
            rc = h264ring_start_session(r, 100);              /* the first program again: its own (none) */
            CHECK("settings: the first program's next session writes its own request (none)", rc == 0 && lo(H264RING_W_SETTINGS) == 0u);
            ctrl[30] &= ~(0xFFull << 24);
        }
    }

    /* the seqlock: a torn frame is never returned */
    core.tear = 3; core_status();
    rc = h264ring_status(r, &st);
    CHECK("status: a torn frame is retried, a consistent copy returned",
          rc == 0 && (uint32_t)st.w[3] == (uint32_t)st.w[31] && core.tear == 0);

    /* (0.10) the raster: word 80 (size, mode, A', the rectangle's origin: x0 negative), word 47
     * (the shape HDMI shows it at), word 30 (the rectangle's size); 48-79 never copied */
    {
        struct h264ring_raster rs;
        ctrl[80] = 720u | (480u << 12) | (1ull << 26) | ((uint64_t)(0x2000u - 5u) << 32) | (62ull << 48);
        ctrl[47] = 1920u | (1080u << 12);
        ctrl[30] = (720ull << 32) | (356ull << 48);
        ctrl[50] = 0xDEADu;
        core_status();
        rc = h264ring_status(r, &st);
        h264ring_raster(&st, &rs);
        CHECK("raster (0.10): word 80, 47 and 30 decoded (x0 two's complement)", rc == 0 &&
              rs.w == 720 && rs.h == 480 && rs.mode == H264RING_RASTER_FITTED && rs.lb == 1 && !rs.interlaced &&
              rs.pic_x0 == -5 && rs.pic_y0 == 62 && rs.pic_w == 720 && rs.pic_h == 356 &&
              rs.ar_x == 1920 && rs.ar_y == 1080 && rs.aspect > 1.777 && rs.aspect < 1.778);
        CHECK("status (0.10): words 80-87 copied, 48-79 (not the core's) read 0", st.w[80] == ctrl[80] && st.w[50] == 0);
        ctrl[30] |= 1ull << 21;                                       /* raster_il: the analog raster */
        core_status(); h264ring_status(r, &st); h264ring_raster(&st, &rs);
        CHECK("raster (0.10): interlaced -> shown 4:3", rs.interlaced && rs.aspect > 1.333 && rs.aspect < 1.334);
        ctrl[80] = ctrl[47] = ctrl[30] = ctrl[50] = 0;
    }

    /* (0.11) the capabilities: word 81 decoded; a word 81 of 0 reads as 0.10's limits */
    {
        struct h264ring_caps c;
        ctrl[81] = 3600u | (480u << 16) | (108000ull << 32);
        core_status(); h264ring_status(r, &st); h264ring_caps(&st, &c);
        CHECK("caps (0.11): word 81 decoded (3,600 MBs, 108,000 MB/s, native 480)",
              c.max_mbs == 3600 && c.mb_rate == 108000 && c.native_h == 480);
        ctrl[81] = 0;
        core_status(); h264ring_status(r, &st); h264ring_caps(&st, &c);
        CHECK("caps (0.11): no word 81 yet -> 0.10's limits (1,620 / 97,200 / 480)",
              c.max_mbs == 1620 && c.mb_rate == 97200 && c.native_h == 480);
    }

    /* (0.14) Video Output as resolved: word 80 [28:27]; a 0.13 core (0 there): the menu's value
     * (word 27 [37:36]), its Auto by word 30's raster_il */
    {
        ctrl[80] = 3ull << 27;                                        /* Auto resolved to Native */
        core_status(); h264ring_status(r, &st);
        CHECK("video_out (0.14): word 80's resolved Native read, the menu at Auto",
              h264ring_video_out(&st) == H264RING_VOUT_NATIVE);
        ctrl[80] = 2ull << 27; ctrl[27] |= 3ull << 36;                /* resolved wins over the menu */
        core_status(); h264ring_status(r, &st);
        CHECK("video_out (0.14): the resolved value, not the menu's", h264ring_video_out(&st) == H264RING_VOUT_PROGRESSIVE);
        ctrl[80] = 0;                                                 /* a 0.13 core: the menu's Native */
        core_status(); h264ring_status(r, &st);
        CHECK("video_out (0.14): a 0.13 core -> the menu's value", h264ring_video_out(&st) == H264RING_VOUT_NATIVE);
        ctrl[27] &= ~(3ull << 36); ctrl[30] |= 1ull << 21;            /* ... its Auto at 480i */
        core_status(); h264ring_status(r, &st);
        CHECK("video_out (0.14): a 0.13 core's Auto on the interlaced raster -> Interlaced",
              h264ring_video_out(&st) == H264RING_VOUT_INTERLACED);
        ctrl[30] &= ~(1ull << 21);
        core_status(); h264ring_status(r, &st);
        CHECK("video_out (0.14): a 0.13 core's Auto, progressive -> Progressive",
              h264ring_video_out(&st) == H264RING_VOUT_PROGRESSIVE);
    }

    if (argc > 1) {
        char path[512];
        snprintf(path, sizeof path, "%s.aus", argv[1]);
        aus = fopen(path, "w");
    }
    /* a full ring: nothing consumed -> EAGAIN, and the accounting is exact */
    core.consume = 0;
    {
        int n = 0;
        while ((rc = h264ring_try_write_au(r, buf, 1000, -1, 0)) == 0) {
            n++;
            if (aus) fprintf(aus, "1000 0 0 -1 0\n");
        }
        CHECK("full ring -> EAGAIN", rc == -EAGAIN);
        CHECK("full ring: used <= ring and nothing more fits", (uint32_t)(lo(32) - core.rw) <= RING &&
              (uint32_t)(lo(32) - core.rw) > RING - 2 * 1024u && n > 0);
    }
    core.consume = 1;
    core_step();

    /* access units across many wraps, with PTS on every other one, an EOS, a LOW_LATENCY run */
    {
        const uint32_t sizes[] = {1, 15, 16, 17, 999, 4096, 20000, 3, 60000, 7};
        uint32_t k = 0, eos_at = 0;
        int disc_ok = 1, gfx_ok = 1;
        unsigned col = 0;
        CHECK("set_colour (0.16): 7 -> EINVAL", h264ring_set_colour(r, 7) == -EINVAL);
        for (int i = 0; i < 300; i++) {
            /* (0.16) the colour: 3 for the first stream, 5 from the second's first AU (151), 1 from 200 on
             * (disagreeing with that stream's first: counted by the consumer, never obeyed) */
            unsigned c_now = i < 151 ? 3u : (i < 200 ? 5u : 1u);
            if (c_now != col) { rc = h264ring_set_colour(r, c_now); col = c_now; if (rc) break; }
            uint32_t len = sizes[i % 10] + (uint32_t)(rand() % 5);
            unsigned flags = (i == 150) ? H264RING_F_END_OF_STREAM : (i > 200 ? H264RING_F_LOW_LATENCY : 0);
            if (i > 250) flags |= H264RING_F_GRAPHICS;        /* interface 0.4 */
            uint32_t at;
            if (len > RING - 64) len = RING - 64;
            k = (k + 7919u) % (sizeof buf - len);
            rc = h264ring_write_au(r, buf + k, len, (i & 1) ? (int64_t)i * 1501 : -1, flags, 1000);
            if (rc) break;
            at = lo(H264RING_W_WRITE_INDEX) - 16u - ((len + 15u) & ~15u);
            if (i == 150) eos_at = at;
            if (i == 151 && !(hdr_flags_at(at) & H264RING_F_DISCONTINUITY)) disc_ok = 0;
            if (i == 152 && (hdr_flags_at(at) & H264RING_F_DISCONTINUITY)) disc_ok = 0;
            if (i > 250 && !(hdr_flags_at(at) & H264RING_F_GRAPHICS)) gfx_ok = 0;
            if (i <= 250 && (hdr_flags_at(at) & H264RING_F_GRAPHICS)) gfx_ok = 0;
            if (aus) fprintf(aus, "%u %u %u %d %u\n", len, k, flags | ((i & 1) ? H264RING_F_PTS_VALID : 0)
                             | (i == 151 ? H264RING_F_DISCONTINUITY : 0), (i & 1) ? i * 1501 : -1, col);
        }
        h264ring_set_colour(r, 0);
        (void)eos_at;
        CHECK("300 access units written across the wraps", rc == 0);
        CHECK("DISCONTINUITY added after END_OF_STREAM, once", disc_ok);
        CHECK("GRAPHICS (0.4) carried in the header exactly where it was asked for", gfx_ok);
        core_step();
        CHECK("everything written was consumed", core.rw == lo(H264RING_W_WRITE_INDEX));
    }
    if (aus) fclose(aus);
    if (argc > 1) {
        char path[512];
        FILE *f;
        snprintf(path, sizeof path, "%s.stream", argv[1]);
        f = fopen(path, "wb");
        fwrite(&core.log_start, 4, 1, f);
        fwrite(core.log, 1, core.log_n, f);
        fclose(f);
        snprintf(path, sizeof path, "%s.buf", argv[1]);
        f = fopen(path, "wb");
        fwrite(buf, 1, sizeof buf, f);
        fclose(f);
    }

    /* flush: records written and not read are dropped at once, the next session continues */
    core.consume = 0;
    {
        uint32_t w_before, seen_before = core.seen;
        uint8_t geometry_ack_before = core.geometry_ack;
        int n = 0;
        while (n < 5 && h264ring_try_write_au(r, buf, 3000, -1, n == 4 ? H264RING_F_END_OF_STREAM : 0) == 0) n++;
        w_before = lo(H264RING_W_WRITE_INDEX);
        CHECK("flush: records queued, unread", n == 5 && core.rw != w_before);
        rc = h264ring_flush(r, 100);
        CHECK("flush: a new session, acknowledged", rc == 0 && core.seen != seen_before && h264ring_session_ok(r));
        CHECK("flush: accepted calibration is replayed for the new session",
              rc == 0 && core.geometry_ack == (uint8_t)(geometry_ack_before + 1u) &&
              ((ctrl[H264RING_W_GEOMETRY] >> H264RING_GEOMETRY_X_LSB) & 0x1FFFu) == 10u &&
              ((ctrl[H264RING_W_GEOMETRY] >> H264RING_GEOMETRY_W_LSB) & 0x1FFFu) == 700u);
        CHECK("flush: everything unread dropped (the core reads on from the write index)", core.rw == w_before);
        CHECK("flush: the write index untouched by it", lo(H264RING_W_WRITE_INDEX) == w_before);
        core.consume = 1;
        rc = h264ring_try_write_au(r, buf, 100, -1, 0);
        CHECK("flush: the next record starts the new session (seq 0, no DISCONTINUITY owed)",
              rc == 0 && ((ringmem[(w_before % RING) / 8] >> 16) & 0xFFFF) == 0 &&
              !(hdr_flags_at(w_before) & H264RING_F_DISCONTINUITY));
        core_step();
    }

    /* (fj#20) the CAVLC -> CABAC rewrite inside the write call (fixtures: tools/cavlc_synth.py's
     * z8_mixed -- SPS + PPS + an IDR, then two P pictures --, redundant, badcode) */
    {
        struct h264ring_au a[8], ra[4], ba[4];
        size_t na = h264ring_split_annexb(cv_mixed, sizeof cv_mixed, a, 8);
        size_t nra = h264ring_split_annexb(cv_refused, sizeof cv_refused, ra, 4);
        size_t nba = h264ring_split_annexb(cv_bad, sizeof cv_bad, ba, 4);
        static uint8_t want[3][4096], got[4096], x[4096];
        size_t wn[3] = {0, 0, 0};
        struct h264ring_cavlc_stats s0, s1;
        h264ring_cavlc *ref = h264ring_cavlc_new();
        int ok = na == 3 && nra >= 1 && nba >= 2 && ref != NULL, n;
        for (size_t i = 0; ok && i < 3; i++) {            /* the expected bytes: the context on its own */
            const uint8_t *o;
            size_t ol;
            ok = h264ring_cavlc_au(ref, cv_mixed + a[i].off, a[i].len, &o, &ol) == H264RING_CAVLC_REWRITTEN &&
                 ol <= sizeof want[i];
            if (ok) { memcpy(want[i], o, ol); wn[i] = ol; }
        }
        h264ring_cavlc_free(ref);
        CHECK("rewrite: the fixtures (3 CAVLC units; a refused stream; a broken one)", ok);
        core.consume = 1;
        rc = h264ring_start_session(r, 100);
        int all = rc == 0;
        for (size_t i = 0; all && i < 3; i++) {
            n = write_and_read(r, cv_mixed + a[i].off, a[i].len, 0, got, sizeof got);
            all = n == (int)wn[i] && memcmp(got, want[i], wn[i]) == 0;
        }
        CHECK("rewrite: CAVLC units written as their CABAC rewrite (h264ring_cavlc_au's bytes)", all);
        n = write_and_read(r, want[0], (uint32_t)wn[0], 0, got, sizeof got);
        CHECK("rewrite: a CABAC unit written byte for byte", n == (int)wn[0] && memcmp(got, want[0], wn[0]) == 0);

        /* a retry after EAGAIN is not rewritten again; the unit is written once it fits */
        rc = h264ring_start_session(r, 100);
        n = write_and_read(r, cv_mixed + a[0].off, a[0].len, 0, got, sizeof got);   /* its SPS / PPS */
        core.consume = 0;
        while (h264ring_try_write_au(r, buf, a[1].len, -1, 0) == 0)
            ;                                              /* full for a unit this size (junk: passed) */
        h264ring_rewrite_stats(r, &s0);
        int r1 = h264ring_try_write_au(r, cv_mixed + a[1].off, a[1].len, -1, 0);
        int r2 = h264ring_try_write_au(r, cv_mixed + a[1].off, a[1].len, -1, 0);
        h264ring_rewrite_stats(r, &s1);
        CHECK("rewrite: a retry after EAGAIN is not rewritten again",
              r1 == -EAGAIN && r2 == -EAGAIN && s1.units_rewritten == s0.units_rewritten + 1);
        core.consume = 1;
        core_step();
        n = write_and_read(r, cv_mixed + a[1].off, a[1].len, 0, got, sizeof got);
        h264ring_rewrite_stats(r, &s0);
        CHECK("rewrite: ... and written from the cache once it fits",
              n == (int)wn[1] && memcmp(got, want[1], wn[1]) == 0 && s0.units_rewritten == s1.units_rewritten);

        /* h264ring_prepare_au: the rewrite before the write, the write free */
        h264ring_rewrite_stats(r, &s0);
        rc = h264ring_prepare_au(r, cv_mixed + a[2].off, a[2].len, 0);
        n = write_and_read(r, cv_mixed + a[2].off, a[2].len, 0, got, sizeof got);
        h264ring_rewrite_stats(r, &s1);
        CHECK("rewrite: prepare then write -- one rewrite, its bytes written",
              rc == 0 && n == (int)wn[2] && memcmp(got, want[2], wn[2]) == 0 &&
              s1.units_rewritten == s0.units_rewritten + 1);

        /* the same buffer with other bytes (programs reuse one): rewritten anew, not the cache's.
         * The other bytes are another picture -- frame_num 1 -> 9 (bit 7 of the slice header) --:
         * the same picture again would be a second first slice (refused as arbitrary slice order) */
        memcpy(x, cv_mixed + a[1].off, a[1].len);
        x[4] ^= 0x01;
        rc = h264ring_prepare_au(r, x, a[1].len, 0);
        n = write_and_read(r, x, a[1].len, 0, got, sizeof got);   /* the prepared bytes */
        CHECK("rewrite: the prepared unit written (its rewrite: frame_num 9 in the header)",
              rc == 0 && n == (int)wn[1] && got[4] == (want[1][4] ^ 0x01) && memcmp(got + 5, want[1] + 5, wn[1] - 5) == 0);
        rc = h264ring_prepare_au(r, cv_mixed + a[2].off, a[2].len, 0);  /* cached: frame_num 2 */
        memcpy(x, cv_mixed + a[2].off, a[2].len);
        x[4] ^= 0x01;                                      /* the same buffer, frame_num 10: other bytes */
        n = write_and_read(r, x, a[2].len, 0, got, sizeof got);
        CHECK("rewrite: a reused buffer with other bytes is rewritten anew, not served from the cache",
              rc == 0 && n == (int)wn[2] && got[4] == (want[2][4] ^ 0x01) && memcmp(got + 5, want[2] + 5, wn[2] - 5) == 0);

        /* a new stream forgets the old one's parameter sets: a P picture alone is then passed as
         * it is (its PPS never received), never rewritten with the old stream's */
        memcpy(x, cv_mixed + a[1].off, a[1].len);
        x[5] ^= 0x40;                                      /* frame_num 1 -> 5: a picture not yet seen */
        rc = h264ring_prepare_au(r, x, a[1].len, 0);
        rc |= h264ring_flush(r, 100);
        n = write_and_read(r, x, a[1].len, 0, got, sizeof got);
        CHECK("rewrite: a flush between prepare and write -- the cached rewrite not reused, the stream forgotten",
              rc == 0 && n == (int)a[1].len && memcmp(got, x, a[1].len) == 0);
        n = write_and_read(r, cv_mixed + a[0].off, a[0].len, 0, got, sizeof got);
        n = write_and_read(r, cv_mixed + a[1].off, a[1].len, H264RING_F_DISCONTINUITY, got, sizeof got);
        CHECK("rewrite: DISCONTINUITY starts afresh (the P picture passed as it is)",
              n == (int)a[1].len && memcmp(got, cv_mixed + a[1].off, a[1].len) == 0);
        n = write_and_read(r, cv_mixed + a[0].off, a[0].len, 0, got, sizeof got);
        n = write_and_read(r, cv_mixed + a[1].off, a[1].len, H264RING_F_END_OF_STREAM, got, sizeof got);
        n = write_and_read(r, cv_mixed + a[2].off, a[2].len, 0, got, sizeof got);
        CHECK("rewrite: ... and so does the DISCONTINUITY after END_OF_STREAM",
              n == (int)a[2].len && memcmp(got, cv_mixed + a[2].off, a[2].len) == 0);
        {
            static const uint8_t pcm[64];
            n = write_and_read(r, cv_mixed + a[0].off, a[0].len, 0, got, sizeof got);
            rc = h264ring_write_audio(r, pcm, sizeof pcm, -1, 1000);
            n = write_and_read(r, cv_mixed + a[1].off, a[1].len, 0, got, sizeof got);
            CHECK("rewrite: an AUDIO record between two units resets nothing",
                  rc == 0 && n == (int)wn[1] && memcmp(got, want[1], wn[1]) == 0);
        }

        /* refused, broken: an error, its reason, nothing written */
        rc = h264ring_start_session(r, 100);
        {
            uint32_t w0 = lo(H264RING_W_WRITE_INDEX);
            int rr = h264ring_try_write_au(r, cv_refused + ra[0].off, ra[0].len, -1, 0);
            CHECK("rewrite: a stream it cannot express -> EOPNOTSUPP, named, nothing written",
                  rr == -EOPNOTSUPP && strstr(h264ring_rewrite_why(r), "redundant") != NULL &&
                  lo(H264RING_W_WRITE_INDEX) == w0);
            n = write_and_read(r, cv_bad + ba[0].off, ba[0].len, 0, got, sizeof got);
            w0 = lo(H264RING_W_WRITE_INDEX);
            rr = h264ring_try_write_au(r, cv_bad + ba[1].off, ba[1].len, -1, 0);
            CHECK("rewrite: a CAVLC unit that does not parse -> EBADMSG, named, nothing written",
                  n > 0 && rr == -EBADMSG && strstr(h264ring_rewrite_why(r), "no such code") != NULL &&
                  lo(H264RING_W_WRITE_INDEX) == w0);
        }

        /* switched off: written as given */
        h264ring_set_rewrite(r, 0);
        rc = h264ring_start_session(r, 100);
        n = write_and_read(r, cv_mixed + a[0].off, a[0].len, 0, got, sizeof got);
        CHECK("rewrite: h264ring_set_rewrite(r, 0) -- a CAVLC unit written as given",
              rc == 0 && n == (int)a[0].len && memcmp(got, cv_mixed + a[0].off, a[0].len) == 0);
        h264ring_set_rewrite(r, 1);
        core_step();
    }

    /* the core refuses the stream -> EPROTO; an OSD Reset drops the session -> ENOTCONN */
    core.error = 1; core_status();
    CHECK("an ERROR state -> EPROTO", h264ring_try_write_au(r, buf, 10, -1, 0) == -EPROTO);
    core.error = 0; core.ack = 0; core_status();
    CHECK("a dropped session -> ENOTCONN", h264ring_try_write_au(r, buf, 10, -1, 0) == -ENOTCONN &&
          !h264ring_session_ok(r));
    CHECK("a new session after the drop", h264ring_start_session(r, 100) == 0 && h264ring_session_ok(r));
    CHECK("bad arguments -> EINVAL", h264ring_try_write_au(r, buf, 0, -1, 0) == -EINVAL &&
          h264ring_try_write_au(r, buf, 10, 1ll << 33, 0) == -EINVAL &&
          h264ring_try_write(r, H264RING_T_CONTROL, 0, -1, buf, 8) == -EINVAL);
    CHECK("a record larger than the ring -> EMSGSIZE", h264ring_try_write_au(r, buf, RING, -1, 0) == -EMSGSIZE);

    /* interface 0.5: AUDIO records -- whole 4-byte frames, PTS_VALID from pts */
    {
        uint32_t at = lo(H264RING_W_WRITE_INDEX);
        uint64_t h0;
        CHECK("audio: not whole frames -> EINVAL", h264ring_try_write_audio(r, buf, 6, -1) == -EINVAL &&
              h264ring_try_write_audio(r, buf, 0, 100) == -EINVAL);
        rc = h264ring_try_write_audio(r, buf, 16, 90000);
        h0 = ringmem[(at % RING) / 8];
        CHECK("audio: a tagged record (type AUDIO, PTS_VALID, its length)", rc == 0 &&
              (h0 & 0xFF) == H264RING_T_AUDIO && ((h0 >> 8) & 0xFF) == H264RING_F_PTS_VALID &&
              (h0 >> 32) == 16u && (ringmem[(at % RING) / 8 + 1] & ((1ull << 33) - 1)) == 90000u);
        at = lo(H264RING_W_WRITE_INDEX);
        rc = h264ring_write_audio(r, buf, 4 * 480, -1, 100);
        CHECK("audio: an untagged record follows the previous one (no flags)", rc == 0 &&
              ((ringmem[(at % RING) / 8] >> 8) & 0xFF) == 0);
        core_step();
    }
    /* interface 0.5: the pause and the volume, one word (34) the library shadows */
    CHECK("pause: word 34 [0]", h264ring_set_pause(r, 1) == 0 && lo(H264RING_W_PAUSE) == 1u);
    CHECK("atten: word 34 [15:8], the pause kept", h264ring_set_atten(r, 40) == 0 && lo(H264RING_W_PAUSE) == (1u | (40u << 8)));
    CHECK("atten: past 255 -> EINVAL, nothing written", h264ring_set_atten(r, 256) == -EINVAL && lo(H264RING_W_PAUSE) == (1u | (40u << 8)));
    CHECK("resume: the attenuation kept", h264ring_set_pause(r, 0) == 0 && lo(H264RING_W_PAUSE) == (40u << 8));
    ctrl[H264RING_W_PAUSE] = 0xFFFF0001u;                 /* a stale word (another program's, a crash) */
    CHECK("a new session writes this program's word 34 first", h264ring_start_session(r, 100) == 0 &&
          lo(H264RING_W_PAUSE) == (40u << 8));
    /* interface 0.13: the rumble -- two pads a u32 in words 36-38, {large, small} */
    {
        const uint64_t S10 = (uint64_t)H264RING_RUMBLE_KEEPALIVE_MS * 1000u;
        CHECK("rumble: pad 0 -> word 36 [15:0] {large, small}", h264ring_rumble(r, 0, 0x80, 0x40) == 0 &&
              lo(H264RING_W_RUMBLE) == 0x8040u);
        CHECK("rumble: pad 3 -> word 37 [31:16], word 36 kept", h264ring_rumble(r, 3, 0xFF, 0x01) == 0 &&
              lo(H264RING_W_RUMBLE + 1) == 0xFF010000u && lo(H264RING_W_RUMBLE) == 0x8040u);
        CHECK("rumble: pad 4 (large 1) and pad 5 (small 1 only) -> word 38", h264ring_rumble(r, 4, 1, 0) == 0 &&
              h264ring_rumble(r, 5, 0, 1) == 0 && lo(H264RING_W_RUMBLE + 2) == 0x00010100u);
        CHECK("rumble: pad 6, a motor past 255 -> EINVAL, nothing written",
              h264ring_rumble(r, 6, 1, 1) == -EINVAL && h264ring_rumble(r, 1, 256, 0) == -EINVAL &&
              h264ring_rumble(r, 1, 0, 256) == -EINVAL && lo(H264RING_W_RUMBLE) == 0x8040u);
        core.now += S10 - 1000u;
        CHECK("rumble keepalive: nothing before 10 s", h264ring_rumble_keepalive(r) == 0 &&
              lo(H264RING_W_RUMBLE) == 0x8040u && lo(H264RING_W_RUMBLE + 1) == 0xFF010000u);
        core.now += 1000u;
        CHECK("rumble keepalive: at 10 s each held pad one step away (large's lowest bit; small's when large is 0)",
              h264ring_rumble_keepalive(r) == 4 && lo(H264RING_W_RUMBLE) == 0x8140u &&
              lo(H264RING_W_RUMBLE + 1) == 0xFE010000u);
        CHECK("rumble keepalive: 1 steps to 2, never to 0", lo(H264RING_W_RUMBLE + 2) == 0x00020200u);
        core.now += S10 / 2u;
        CHECK("rumble keepalive: not again before another 10 s", h264ring_rumble_keepalive(r) == 0 &&
              lo(H264RING_W_RUMBLE) == 0x8140u);
        core.now += S10 / 2u;
        CHECK("rumble keepalive: then back to the value asked for", h264ring_rumble_keepalive(r) == 4 &&
              lo(H264RING_W_RUMBLE) == 0x8040u && lo(H264RING_W_RUMBLE + 1) == 0xFF010000u &&
              lo(H264RING_W_RUMBLE + 2) == 0x00010100u);
        CHECK("rumble: off -> 0, and an off pad is never refreshed", h264ring_rumble(r, 4, 0, 0) == 0 &&
              h264ring_rumble(r, 5, 0, 0) == 0 && lo(H264RING_W_RUMBLE + 2) == 0u &&
              (core.now += 3u * S10, h264ring_rumble_keepalive(r)) == 2 && lo(H264RING_W_RUMBLE + 2) == 0u);
        CHECK("rumble: the value asked for again after a step: written (a change: Main re-plays it)",
              h264ring_rumble(r, 0, 0x80, 0x40) == 0 && lo(H264RING_W_RUMBLE) == 0x8040u);
        ctrl[H264RING_W_RUMBLE + 2] = 0x12345678u;        /* left by the core's test only: a flush must not touch it */
        CHECK("rumble: a later session (a flush) leaves the words alone", h264ring_flush(r, 100) == 0 &&
              lo(H264RING_W_RUMBLE + 2) == 0x12345678u && lo(H264RING_W_RUMBLE) == 0x8040u);
        ctrl[H264RING_W_RUMBLE + 2] = 0;
    }
    /* interface 0.6: the input region (words 48-71), written here as the core would */
    {
        struct h264ring_input in;
        uint16_t ev[64];
        uint32_t count, lost = 0;
        unsigned n, ok;
        const unsigned Q = H264RING_IN_Q_WORD;
        #define IN_EVENT(e, v) (ctrl[Q + ((e) % 32u) / 4u] = (ctrl[Q + ((e) % 32u) / 4u] & ~(0xFFFFull << (16u * ((e) % 4u)))) | \
                                ((uint64_t)(v) << (16u * ((e) % 4u))))
        #define IN_SEQ(seq, evc) (ctrl[48] = (seq) | ((uint64_t)(evc) << 32), ctrl[71] = (seq))
        memset(&ctrl[48], 0, 24 * sizeof(ctrl[0]));
        for (uint32_t e = 0; e < 5; e++) IN_EVENT(e, 0x0200u + e);
        ctrl[51] = 0x1234u | (0xAB05ull << 32) | (0xCD06ull << 48);      /* pad 2 */
        ctrl[55] = 0xFFFFFFF0u | (7ull << 32);                          /* dx -16, dy 7 */
        ctrl[64] = 3u | (0x05ull << 32) | (1ull << 40);                 /* wheel 3, buttons L + M, the OSD open */
        IN_SEQ(9u, 5u);
        CHECK("input: a consistent copy", h264ring_input(r, &in) == 0 && H264RING_IN(&in, IN_HEAD) == 9u);
        CHECK("input: the fields where the layout puts them", H264RING_IN(&in, PAD2_JOY) == 0x1234u &&
              H264RING_IN(&in, PAD2_LSTICK) == 0xAB05u && H264RING_IN(&in, PAD2_RSTICK) == 0xCD06u &&
              (int32_t)H264RING_IN(&in, DX_SUM) == -16 && H264RING_IN(&in, DY_SUM) == 7u &&
              H264RING_IN(&in, WHEEL_SUM) == 3u && H264RING_IN(&in, MOUSE_BTN) == 5u && H264RING_IN(&in, OSD_OPEN) == 1u);
        ctrl[71] = 8u;                                                  /* a write caught half done */
        CHECK("input: a torn copy is refused (-EAGAIN)", h264ring_input(r, &in) == -EAGAIN);
        ctrl[71] = 9u;
        h264ring_input(r, &in);
        count = 0;
        n = h264ring_input_events(&in, &count, ev, 2, &lost);
        ok = n == 2 && ev[0] == 0x0200u && ev[1] == 0x0201u && count == 2u;
        n = h264ring_input_events(&in, &count, ev, 64, &lost);
        CHECK("input: the events in order, cap respected, the count advanced", ok && n == 3 && ev[0] == 0x0202u &&
              ev[2] == 0x0204u && count == 5u && lost == 0u);
        CHECK("input: nothing new -> 0", h264ring_input_events(&in, &count, ev, 64, &lost) == 0u && count == 5u);
        /* the u32 wrap: events 0xFFFFFFFE .. 2 */
        for (uint32_t e = 0xFFFFFFFEu, k = 0; k < 5; e++, k++) IN_EVENT(e, 0x4000u + k);
        IN_SEQ(10u, 3u);
        h264ring_input(r, &in);
        count = 0xFFFFFFFEu;
        n = h264ring_input_events(&in, &count, ev, 64, &lost);
        CHECK("input: across the u32 wrap", n == 5 && ev[0] == 0x4000u && ev[1] == 0x4001u && ev[2] == 0x4002u &&
              ev[4] == 0x4004u && count == 3u && lost == 0u);
        /* read too late: 50 new events, the queue holds the last 32 */
        for (uint32_t e = 50; e < 100; e++) IN_EVENT(e, e);
        IN_SEQ(11u, 100u);
        h264ring_input(r, &in);
        count = 50;
        n = h264ring_input_events(&in, &count, ev, 64, &lost);
        CHECK("input: 50 behind -> 18 counted lost, the last 32 delivered", n == 32 && lost == 18u && ev[0] == 68u &&
              ev[31] == 99u && count == 100u);
        CHECK("input: the event macros", H264RING_EV_TYPE(0x8001u) == H264RING_EV_OSD && H264RING_EV_OPEN(0x8001u) &&
              H264RING_EV_TYPE(0x0312u) == H264RING_EV_KEY && H264RING_EV_PRESSED(0x0312u) && H264RING_EV_EXT(0x0312u) &&
              H264RING_EV_CODE(0x0312u) == 0x12u && H264RING_EV_TYPE(0x4005u) == H264RING_EV_MOUSE_BTN);
        CHECK("input (0.8): an OSD action's type and number", H264RING_EV_TYPE(0xC001u) == H264RING_EV_ACTION &&
              H264RING_EV_CODE(0xC001u) == 1u && H264RING_EV_CODE(0xC000u) == 0u && H264RING_IN_ACTIONS == 2u);
        #undef IN_EVENT
        #undef IN_SEQ
    }

    /* interface 0.9: the overlay plane's descriptor (program words 72-79) */
    {
        const uint32_t FB = H264RING_FB_BYTE, END = H264RING_FB_BYTE + H264RING_FB_SIZE;
        struct h264ring_overlay o = { FB, 720, 480, 1440, H264RING_OVL_FMT_1555, 0, 479 }, x;
        int g, g2;
        CHECK("overlay: a full 1555 canvas passes the checks", h264ring_overlay_check(&o) == H264RING_OVL_E_NONE);
        x = o; x.format = 3;             CHECK("overlay: FORMAT 3 -> CTL", h264ring_overlay_check(&x) == H264RING_OVL_E_CTL);
        x = o; x.width = H264RING_OVL_MAX_W + 1;   /* (0.10) 1,025: one past the widest raster */
        CHECK("overlay: width OVL_MAX_W + 1 -> SIZE", h264ring_overlay_check(&x) == H264RING_OVL_E_SIZE);
        x = o; x.height = H264RING_OVL_MAX_H + 1;  /* 2,048 */
        CHECK("overlay: height OVL_MAX_H + 1 -> SIZE", h264ring_overlay_check(&x) == H264RING_OVL_E_SIZE);
        x = o; x.height = 0;             CHECK("overlay: height 0 -> SIZE", h264ring_overlay_check(&x) == H264RING_OVL_E_SIZE);
        x = o; x.stride = 1432;          CHECK("overlay: stride below width x 2 -> STRIDE", h264ring_overlay_check(&x) == H264RING_OVL_E_STRIDE);
        x = o; x.stride = 1444;          CHECK("overlay: stride not a multiple of 8 -> STRIDE", h264ring_overlay_check(&x) == H264RING_OVL_E_STRIDE);
        x = o; x.format = H264RING_OVL_FMT_8888;
                                         CHECK("overlay: 8888 at 1440 bytes a line -> STRIDE", h264ring_overlay_check(&x) == H264RING_OVL_E_STRIDE);
        x = o; x.base = FB + 4;          CHECK("overlay: base + 4 -> ALIGN", h264ring_overlay_check(&x) == H264RING_OVL_E_ALIGN);
        x = o; x.band_last = 480;        CHECK("overlay: band past the height -> BAND", h264ring_overlay_check(&x) == H264RING_OVL_E_BAND);
        x = o; x.band_first = 5; x.band_last = 4;
                                         CHECK("overlay: band first after last -> BAND", h264ring_overlay_check(&x) == H264RING_OVL_E_BAND);
        x = o; x.base = FB - 8;          CHECK("overlay: below the region -> RANGE", h264ring_overlay_check(&x) == H264RING_OVL_E_RANGE);
        x = o; x.base = END - 479u * 1440u - 1440u;
                                         CHECK("overlay: ending exactly at the region's end passes", h264ring_overlay_check(&x) == H264RING_OVL_E_NONE);
        x.base += 8;                     CHECK("overlay: 8 bytes further -> RANGE", h264ring_overlay_check(&x) == H264RING_OVL_E_RANGE);

        bar_log_on = 1; bar_n = 0;
        g = h264ring_overlay_show(r, &o);
        bar_log_on = 0;
        CHECK("overlay: show returns a generation", g > 0);
        CHECK("overlay: the fields where the layout puts them",
              lo(H264RING_W_OVL_CTL) == (1u | (H264RING_OVL_FMT_1555 << 1)) && lo(H264RING_W_OVL_BASE) == FB &&
              lo(H264RING_W_OVL_SIZE) == ((480u << 16) | 720u) && lo(H264RING_W_OVL_STRIDE) == 1440u &&
              lo(H264RING_W_OVL_BAND) == (479u << 16) && lo(H264RING_W_OVL_RSVD) == 0u &&
              lo(H264RING_W_OVL_GEN_LO) == (uint32_t)g && lo(H264RING_W_OVL_GEN_HI) == (uint32_t)g);
        CHECK("overlay: gen_hi written first -- at the first barrier gen_lo is still the old one",
              bar_n >= 2 && bar_hi[0] == (uint32_t)g && bar_lo[0] != (uint32_t)g);
        CHECK("overlay: gen_lo written last, behind a barrier", bar_lo[bar_n - 1] == (uint32_t)g && bar_lo[bar_n - 2] != (uint32_t)g);
        x = o; x.width = 0;
        CHECK("overlay: a refused show writes nothing", h264ring_overlay_show(r, &x) == -EINVAL &&
              lo(H264RING_W_OVL_GEN_LO) == (uint32_t)g && lo(H264RING_W_OVL_BASE) == FB);
        CHECK("overlay: wait -- the core read it", h264ring_overlay_wait(r, g, 100) == 0);
        o.base = FB + 0x100000u;
        g2 = h264ring_overlay_show(r, &o);
        CHECK("overlay: a flip is a new generation with the new base", g2 == g + 1 && lo(H264RING_W_OVL_BASE) == FB + 0x100000u);
        core.ovl_blind = 1;
        CHECK("overlay: wait -- never read -> ETIMEDOUT", h264ring_overlay_wait(r, g2 + 5, 20) == -ETIMEDOUT);
        core.ovl_blind = 0; core.ovl_refuse = 1;
        CHECK("overlay: wait -- refused -> EPROTO", h264ring_overlay_wait(r, g2, 100) == -EPROTO);
        core.ovl_refuse = 0;
        core.ack_delay = 2; ovl_probe_on = 1; ovl_probe_seen = 0;
        rc = h264ring_start_session(r, 100);
        ovl_probe_on = 0;
        CHECK("overlay: the prior descriptor remains published while the session ACK is pending",
              rc == 0 && ovl_probe_seen && ovl_probe_ctl == (1u | (H264RING_OVL_FMT_1555 << 1)) &&
              ovl_probe_base == FB + 0x100000u && ovl_probe_gen == (uint32_t)g2);
        CHECK("overlay: session ACK republishes this program's overlay at a new generation",
              (lo(H264RING_W_OVL_CTL) & 1u) && lo(H264RING_W_OVL_BASE) == FB + 0x100000u &&
              lo(H264RING_W_OVL_GEN_LO) == (uint32_t)(g2 + 1) &&
              lo(H264RING_W_OVL_GEN_HI) == (uint32_t)(g2 + 1));
        CHECK("overlay: wait for a flip a session start superseded -- a later generation counts",
              h264ring_overlay_wait(r, g2, 100) == 0);
        g = h264ring_overlay_hide(r);
        CHECK("overlay: hide -- ENABLE clear, a new generation", g == g2 + 2 && lo(H264RING_W_OVL_CTL) == 0u &&
              lo(H264RING_W_OVL_GEN_LO) == (uint32_t)g);
        ctrl[H264RING_W_OVL_CTL] = 1u;                    /* a previous program's descriptor, left shown */
        CHECK("overlay: a new session after hide writes it off (never a stale page)",
              h264ring_start_session(r, 100) == 0 && lo(H264RING_W_OVL_CTL) == 0u);
    }
    h264ring_close(r);
    CHECK("rumble: close zeroes this program's words (a session ran)", lo(H264RING_W_RUMBLE) == 0u &&
          lo(H264RING_W_RUMBLE + 1) == 0u && lo(H264RING_W_RUMBLE + 2) == 0u);
    /* the refusal names against h264/dec/h264_pkg.sv's REF_* codes (read from the RTL, so a
     * renumbering there fails here): each code's name carries its symbol's keyword */
    {
        static const struct { const char *sym, *word; } kw[] = {
            {"REF_NONE", "none"}, {"REF_CHROMA", "chroma"}, {"REF_BITDEPTH", "bit depth"},
            {"REF_SCALING", "scaling"}, {"REF_MBAFF", "MBAFF"}, {"REF_CAVLC", "CAVLC"},
            {"REF_FMO", "FMO"}, {"REF_T8X8", "8x8"}, {"REF_REDUNDANT", "redundant"},
            {"REF_SPSI", "SP / SI"}, {"REF_PARTITION", "partitioning"}, {"REF_SVC", "SVC"},
            {"REF_SIZE", "128 macroblocks"},
        };
        FILE *pkg = fopen(H264_PKG, "r");
        char line[512];
        unsigned found = 0, named = 0;
        while (pkg && fgets(line, sizeof line, pkg))
            for (unsigned k = 0; k < sizeof kw / sizeof kw[0]; k++) {
                char pat[64];
                snprintf(pat, sizeof pat, "%s = 4'd", kw[k].sym);
                const char *at = strstr(line, pat);
                if (!at) continue;
                unsigned code = (unsigned)atoi(at + strlen(pat));
                found++;
                named += strstr(h264ring_refusal_name(code), kw[k].word) != NULL;
            }
        if (pkg) fclose(pkg);
        CHECK("refusal names: every REF_* code in h264_pkg.sv named by its symbol",
              found == sizeof kw / sizeof kw[0] && named == found);
        CHECK("refusal names: a code past the table is \"?\"", strcmp(h264ring_refusal_name(15), "?") == 0);
        /* REF_SIZE is raised at the SPS for a DIMENSION past 128 macroblocks (sps_pps.sv), not for
         * the picture bound (0.11: 3,600 macroblocks, word 81; recon_top drops those slices, no
         * refusal: a program checks the SPS itself -- docs/player.md); REF_MBAFF only for MBAFF */
        CHECK("refusal names: REF_SIZE names the dimension, not the picture bound; MBAFF not \"field pictures\"",
              !strstr(h264ring_refusal_name(12), "1,620") && !strstr(h264ring_refusal_name(12), "3,600") &&
              !strstr(h264ring_refusal_name(4), "/ field"));
    }

    /* ---- (0.15) pictures from the program: the store rule, the layout, the descriptor, the copy.
     * The fake core reports READY / PLAYING and word 84 as each check sets them; the descriptors
     * written go to OUT_STEM.pics (with the picture each was written for) and the copies to
     * OUT_STEM.copyN (the source planes and the store), for test_hps_lib.py's model -- written from
     * docs/architecture.md "Pictures from the program", sharing nothing with this library. */
    {
        static uint64_t stores[(size_t)H264RING_DPB_STORES * H264RING_DPB_STORE / 8u];
        struct h264ring_backend be;
        h264ring *p = NULL;
        unsigned k = 99, i, got_all = 1, rr = 1;
        int rc;
        FILE *pf = NULL;
        char path[512];
        struct h264ring_picture pic = { 720, 480, H264RING_PIC_STRUCT_FRAME, -1, 32, 27, 30000, 1001, 0 };
        struct h264ring_pic_layout l;
        memset(&be, 0, sizeof be);
        be.ctrl = ctrl; be.ring = ringmem; be.ring_size = RING;
        be.sleep_us = be_sleep; be.now_us = be_now; be.barrier = be_barrier;
        be.stores = stores;
        CHECK("pictures: attach with stores", h264ring_attach(&p, &be) == 0 && p != NULL);
        CHECK("pictures: store k's mapping is k x DPB_STORE bytes in",
              h264ring_picture_store(p, 3) == stores + 3u * (H264RING_DPB_STORE / 8u) && !h264ring_picture_store(p, 20));
        CHECK("pictures: acquire with no session -> ENOTCONN", h264ring_picture_acquire(p, &k) == -ENOTCONN);
        if (argc > 1) {
            snprintf(path, sizeof path, "%s.pics", argv[1]);
            pf = fopen(path, "w");
        }
        core.ready = 0; core_status(); core.pic_held = 0; core_status(); core.pic_emitted = 0xFFFFFFF0u; core_status();     /* the count wraps below */
        rc = h264ring_start_session(p, 100);
        CHECK("pictures: a session", rc == 0);
        CHECK("pictures: no READY copy yet -> EAGAIN (the stream reset not seen: numbering waits)",
              h264ring_picture_acquire(p, &k) == -EAGAIN);
        CHECK("pictures: a record before acquire numbers nothing -> EINVAL",
              h264ring_try_write_picture(p, 0, &pic, 0, 0) == -EINVAL);
        core.ready = 1; core_status();
        rc = h264ring_picture_acquire(p, &k);
        CHECK("pictures: acquire after READY -> store 0", rc == 0 && k == 0);
        /* fill every store: none emitted yet */
        for (i = 0; i < H264RING_DPB_STORES; i++) {
            unsigned want = i;
            uint32_t at;
            if (i) { rc = h264ring_picture_acquire(p, &k); rr &= (rc == 0 && k == want); }
            core.ready = 0; core_status();                               /* PLAYING once a picture is written */
            at = lo(H264RING_W_WRITE_INDEX);
            pic.structure = i % 3u; pic.pic_struct = pic.structure ? -1 : (int)(i % 2u ? 5 : -1);
            pic.width = 720u - 2u * i; pic.height = pic.structure ? 480u - 4u * i : 476u + i;
            pic.sar_w = i % 4u ? 32u + i : 0u; pic.sar_h = i % 4u ? 27u : 0u;
            pic.rate_num = i % 5u == 4u ? 0u : (i % 2u ? 25u : 30000u); pic.rate_den = pic.rate_num == 25u ? 1u : 1001u;
            pic.colour = i % 7u;                          /* (0.16) every code, 0 auto among them */
            rc = h264ring_try_write_picture(p, k, &pic, i == 7 ? -1 : 3003ll * i, i == 2 ? H264RING_F_GRAPHICS : 0u);
            got_all &= rc == 0;
            if (pf && rc == 0) {                          /* the record written: its header word 0 and payload */
                uint32_t a = at, w0lo;
                if (((ringmem[(a % RING) / 8] & 0xFF)) == H264RING_T_PAD)
                    a += 16u + (((uint32_t)(ringmem[(a % RING) / 8] >> 32) + 15u) & ~15u);
                w0lo = (uint32_t)ringmem[(a % RING) / 8];
                fprintf(pf, "%u %u %u %d %u %u %u %u %u %lld", pic.width, pic.height, pic.structure, pic.pic_struct,
                        pic.sar_w, pic.sar_h, pic.rate_num, pic.rate_den, (w0lo >> 8) & 0xFFu,
                        (long long)(ringmem[((a + 8u) % RING) / 8] & ((1ull << 33) - 1u)));
                fprintf(pf, " %u", w0lo & 0xFFu);
                for (unsigned wd = 0; wd < 4; wd++)
                    fprintf(pf, " %llu", (unsigned long long)ringmem[((a + 16u + 8u * wd) % RING) / 8]);
                fprintf(pf, " %llu", (unsigned long long)(ringmem[((a + 8u) % RING) / 8] >> 33) & 7u);   /* (0.16) */
                fprintf(pf, "\n");
            }
        }
        CHECK("pictures: twenty stores acquired in turn and written", got_all && rr);
        CHECK("pictures: all twenty in use, none emitted -> EAGAIN", h264ring_picture_acquire(p, &k) == -EAGAIN);
        core.pic_emitted = 0xFFFFFFF0u + 1u; core_status(); core.pic_held = 1u; core_status();   /* the first emitted, still shown */
        CHECK("pictures: emitted but held -> still EAGAIN", h264ring_picture_acquire(p, &k) == -EAGAIN);
        core.pic_held = 0; core_status();
        rc = h264ring_picture_acquire(p, &k);
        CHECK("pictures: emitted and released -> that store (0)", rc == 0 && k == 0);
        core.pic_emitted = 0xFFFFFFF0u + 18u; core_status(); core.pic_held = 1u << 17; core_status();   /* across the count's wrap */
        rc = h264ring_picture_acquire(p, &k);
        CHECK("pictures: the next free in turn (1), the count wrapped past 0", rc == 0 && k == 1);
        {
            unsigned free_n = 0, seen = 0;
            for (unsigned t = 0; t < 40; t++) {           /* stores 0-16 free, 17 held, 18-19 not emitted */
                if (h264ring_picture_acquire(p, &k) == 0) { seen |= 1u << k; free_n++; }
            }
            CHECK("pictures: exactly stores 0-16 are free (17 held, 18-19 not yet emitted)",
                  free_n == 40 && seen == 0x1FFFFu);
        }
        /* a coded stream: the decoder's stores */
        CHECK("pictures: a VIDEO_AU written", h264ring_try_write_au(p, "\x00\x00\x01\x65\x88", 5, 1, 0) == 0);
        CHECK("pictures: after a VIDEO_AU -> EBUSY (acquire and write)", h264ring_picture_acquire(p, &k) == -EBUSY &&
              h264ring_try_write_picture(p, 0, &pic, 0, 0) == -EBUSY);
        core.ready = 0; core_status();
        rc = h264ring_flush(p, 100);
        CHECK("pictures: a flush -> the stores the program's again, once READY",
              rc == 0 && h264ring_picture_acquire(p, &k) == -EAGAIN);
        core.ready = 1; core_status(); core.pic_held = 0xFFFFFu; core_status();         /* the previous stream's holds: unused stores are free */
        rc = h264ring_picture_acquire(p, &k);
        CHECK("pictures: after the flush store 0 (none used since the reset)", rc == 0 && k == 0);
        pic.structure = H264RING_PIC_STRUCT_FRAME; pic.pic_struct = -1; pic.width = 720; pic.height = 480;
        core.ready = 0; core_status();
        rc = h264ring_try_write_picture(p, k, &pic, 10, H264RING_F_END_OF_STREAM);
        CHECK("pictures: a picture with END_OF_STREAM", rc == 0);
        core.pic_held = 0; core_status(); core.pic_emitted += 1u; core_status();
        rc = h264ring_picture_acquire(p, &k);
        {
            uint32_t at = lo(H264RING_W_WRITE_INDEX);
            int rc2 = rc ? rc : h264ring_try_write_picture(p, k, &pic, 20, 0);
            CHECK("pictures: the next one gets DISCONTINUITY automatically",
                  rc2 == 0 && (hdr_flags_at(at) & H264RING_F_DISCONTINUITY));
        }
        /* the layout */
        {
            struct h264ring_picture q = { 1, 1, H264RING_PIC_STRUCT_FRAME, -1, 0, 0, 0, 0, 0 };
            CHECK("layout: 1x1 -> 1 x 1 MB, crop 7 / 7", h264ring_picture_layout(&q, &l) == 0 && l.w_mbs == 1 &&
                  l.hf_mbs == 1 && l.crop_r == 7 && l.crop_b == 7 && l.cb_off == 256 && l.cr_off == 320);
            q.width = 1280; q.height = 720;
            CHECK("layout: 1280x720 -> 80 x 45 (3,600)", h264ring_picture_layout(&q, &l) == 0 && l.w_mbs == 80 && l.hf_mbs == 45);
            q.width = 1296;
            CHECK("layout: 1296x720 (3,645 MBs) -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
            q.width = 720; q.height = 490; q.structure = H264RING_PIC_STRUCT_PAIR_TOP;
            CHECK("layout: a 720x490 pair -> 32 frame MBs (whole field macroblocks), crop 11",
                  h264ring_picture_layout(&q, &l) == 0 && l.hf_mbs == 32 && l.crop_b == 11);
            q.height = 576;
            CHECK("layout: a 720x576 pair -> 36", h264ring_picture_layout(&q, &l) == 0 && l.hf_mbs == 36);
            q.pic_struct = 0;
            CHECK("layout: a pair with a pic_struct -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
            q.structure = H264RING_PIC_STRUCT_FRAME; q.pic_struct = 1;
            CHECK("layout: a frame with pic_struct 1 (a field) -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
            q.pic_struct = 8; q.width = 2049;
            CHECK("layout: 2,049 wide -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
            q.width = 720; q.structure = 3;
            CHECK("layout: structure 3 -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
        }
        /* the copy: four formats, a frame and a pair, odd sizes (the edges replicated) */
        {
            static uint8_t pl[3][64 * 64];
            static const unsigned fw[4] = { 33, 34, 21, 40 }, fh[4] = { 19, 22, 13, 30 };
            unsigned ok_all = 1;
            for (unsigned n = 0; n < 10; n++) {
                struct h264ring_picture q = { fw[n % 4], fh[n % 4], n % 2 ? H264RING_PIC_STRUCT_PAIR_TOP : H264RING_PIC_STRUCT_FRAME,
                                              -1, 0, 0, 0, 0, 0 };
                unsigned fmt = n < 8 ? n % 4 : (n == 8 ? H264RING_PIX_YUVJ420P : H264RING_PIX_YUVJ422P), c422 = fmt >= 2;
                /* (0.16, D-C8) copies 8 and 9: full-range sources under a full-range code -- kept as they are */
                if (n == 8) q.colour = H264RING_COLOUR_601_FULL;
                if (n == 9) q.colour = H264RING_COLOUR_709_FULL;
                const uint8_t *planes[3] = { pl[0], pl[1], pl[2] };
                int strides[3] = { 64, 48, 48 };
                volatile uint64_t *st = h264ring_picture_store(p, 5);
                FILE *cf;
                for (unsigned j = 0; j < sizeof pl[0]; j++) {
                    pl[0][j] = (uint8_t)(j * 37u + n * 11u);
                    pl[1][j] = (uint8_t)(j * 53u + 7u + n);
                    pl[2][j] = (uint8_t)(j * 91u + 201u - n);
                }
                for (unsigned j = 0; j < H264RING_DPB_STORE / 8u; j++)
                    st[j] = 0xA5A5A5A5A5A5A5A5ull;        /* what the copy must overwrite */
                rc = h264ring_picture_copy(st, &q, planes, strides, fmt);
                ok_all &= rc == 0;
                (void)c422;
                if (argc > 1 && rc == 0 && h264ring_picture_layout(&q, &l) == 0) {
                    snprintf(path, sizeof path, "%s.copy%u", argv[1], n);
                    cf = fopen(path, "wb");
                    if (cf) {
                        uint32_t hdr[8] = { q.width, q.height, q.structure, fmt | (q.colour << 8), 64, 48, 48, l.bytes };
                        fwrite(hdr, sizeof hdr, 1, cf);
                        fwrite(pl, sizeof pl, 1, cf);
                        for (uint32_t j = 0; j < l.bytes / 8u; j++) { uint64_t v = st[j]; fwrite(&v, 8, 1, cf); }
                        fclose(cf);
                    }
                }
            }
            CHECK("copy: ten copies (four formats, frames and pairs, odd sizes; 0.16: full range kept)", ok_all);
            {   /* (0.16) a limited-range source under a full-range code; a code past 6 */
                struct h264ring_picture q = { 32, 16, H264RING_PIC_STRUCT_FRAME, -1, 0, 0, 0, 0, H264RING_COLOUR_601_FULL };
                const uint8_t *planes[3] = { pl[0], pl[1], pl[2] };
                int strides[3] = { 64, 48, 48 };
                CHECK("copy (0.16): a limited source with a full-range code -> EINVAL",
                      h264ring_picture_copy(h264ring_picture_store(p, 5), &q, planes, strides, H264RING_PIX_YUV420P) == -EINVAL);
                q.colour = 7;
                CHECK("layout (0.16): colour 7 -> EINVAL", h264ring_picture_layout(&q, &l) == -EINVAL);
            }
            CHECK("copy: format 4 -> EINVAL", h264ring_picture_copy(h264ring_picture_store(p, 5), &pic,
                  (const uint8_t *const[3]){ pl[0], pl[1], pl[2] }, (const int[3]){ 64, 48, 48 }, 4) == -EINVAL);
        }
        if (pf) fclose(pf);
        h264ring_close(p);
        core.ready = 0; core_status();
    }

    printf("test_ring: %s\n", fails ? "FAILURES" : "ALL GREEN");
    return fails ? 1 : 0;
}
