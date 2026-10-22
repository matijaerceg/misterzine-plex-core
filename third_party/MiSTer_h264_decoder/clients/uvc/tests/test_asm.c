/* test_asm -- the UVC payload assembler (src/uvc.c, built with UVC_NO_LIBUSB) against synthetic payload
 * streams: each arm one way a frame is completed, lost or damaged (docs/uvc.md U3). Prints
 * "ARM <name> PASS" per arm and "ALL PASS" last; exits 1 on any failure. run_test.sh scores it and,
 * with --red, proves each arm fails under its own mutation of uvc.c. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "uvc.h"

static int fails;
#define CHECK(arm, cond) do { if (!(cond)) { printf("ARM %s FAIL: %s (line %d)\n", arm, #cond, __LINE__); fails++; return; } } while (0)

/* a fake MJPEG frame of n bytes: SOI, a pattern from seed, EOI */
static void mk_jpeg(uint8_t *b, size_t n, unsigned seed)
{
    b[0] = 0xFF; b[1] = 0xD8;
    for (size_t i = 2; i < n - 2; i++) b[i] = (uint8_t)(i * 7u + seed * 13u) & 0x7F;   /* no 0xFF inside */
    b[n - 2] = 0xFF; b[n - 1] = 0xD9;
}

/* one payload: a 12-byte header (PTS + SCR present, as most cameras send) and up to 1,000 bytes */
static int pay(struct uvc_asm *a, struct uvc_stats *s, int fid, int eof, int err, const uint8_t *d, size_t n,
               int status)
{
    uint8_t p[1100];
    memset(p, 0, 12);
    p[0] = 12;
    p[1] = (uint8_t)(fid | eof << 1 | 1 << 2 | 1 << 3 | err << 6 | 1 << 7);
    memcpy(p + 12, d, n);
    return uvc_asm_payload(a, p, 12 + n, status, s);
}

/* a whole frame in 1,000-byte payloads; the last carries EOF when eof */
static int send_frame(struct uvc_asm *a, struct uvc_stats *s, int fid, const uint8_t *f, size_t n, int eof)
{
    int done = 0;
    for (size_t o = 0; o < n; o += 1000) {
        size_t k = n - o < 1000 ? n - o : 1000;
        done |= pay(a, s, fid, eof && o + k == n, 0, f + o, k, 0);
    }
    return done;
}

static int got(struct uvc_asm *a, const uint8_t *want, size_t n)
{
    size_t len;
    const uint8_t *f = uvc_asm_frame(a, &len);
    return f && len == n && !memcmp(f, want, n);
}

static void a1_clean(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[5000];
    for (unsigned i = 0; i < 4; i++) {
        mk_jpeg(f, sizeof f - i * 333, i);
        CHECK("A1", send_frame(a, &s, (int)(i & 1), f, sizeof f - i * 333, 1) == 1);
        CHECK("A1", got(a, f, sizeof f - i * 333));
    }
    CHECK("A1", s.frames == 4 && s.frames_bad == 0 && s.fid_no_eof == 0);
    uvc_asm_free(a);
    printf("ARM A1 PASS (whole frames, EOF-ended, byte-exact)\n");
}

static void a2_fid_only(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[3000], g[2500];
    mk_jpeg(f, sizeof f, 1);
    mk_jpeg(g, sizeof g, 2);
    CHECK("A2", send_frame(a, &s, 0, f, sizeof f, 0) == 0);   /* no EOF: still open */
    CHECK("A2", send_frame(a, &s, 1, g, sizeof g, 0) == 1);   /* the toggle ends the first */
    CHECK("A2", got(a, f, sizeof f));
    CHECK("A2", s.fid_no_eof == 1 && s.frames == 1);
    uvc_asm_free(a);
    printf("ARM A2 PASS (a frame ended by the FID toggle)\n");
}

static void a3_packet_error(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[3000], g[3000];
    mk_jpeg(f, sizeof f, 3);
    mk_jpeg(g, sizeof g, 4);
    pay(a, &s, 0, 0, 0, f, 1000, 0);
    pay(a, &s, 0, 0, 0, f + 1000, 1000, 1);                  /* lost */
    pay(a, &s, 0, 1, 0, f + 2000, 1000, 0);
    CHECK("A3", uvc_asm_frame(a, &(size_t){ 0 }) == NULL);
    CHECK("A3", s.frames_bad == 1 && s.bad_packet == 1 && s.packet_errors == 1);
    CHECK("A3", send_frame(a, &s, 1, g, sizeof g, 1) == 1 && got(a, g, sizeof g));
    uvc_asm_free(a);
    printf("ARM A3 PASS (a lost packet drops its frame, the next is whole)\n");
}

static void a4_err_bit(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[2000];
    mk_jpeg(f, sizeof f, 5);
    pay(a, &s, 0, 0, 0, f, 1000, 0);
    pay(a, &s, 0, 1, 1, f + 1000, 1000, 0);                  /* the device's error bit */
    CHECK("A4", uvc_asm_frame(a, &(size_t){ 0 }) == NULL);
    CHECK("A4", s.bad_err_bit == 1 && s.frames_bad == 1 && s.frames == 0);
    uvc_asm_free(a);
    printf("ARM A4 PASS (the error bit drops the frame)\n");
}

static void a5_overflow(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 2500);
    uint8_t f[3000], g[2000];
    memset(f, 0, sizeof f);                                  /* EOI before the cut, padding past it: */
    mk_jpeg(f, 2000, 6);                                     /* only the overflow check can drop it */
    mk_jpeg(g, sizeof g, 7);
    send_frame(a, &s, 0, f, sizeof f, 1);                    /* larger than the committed maximum */
    CHECK("A5", uvc_asm_frame(a, &(size_t){ 0 }) == NULL);
    CHECK("A5", s.bad_overflow == 1 && s.frames_bad == 1);
    CHECK("A5", send_frame(a, &s, 1, g, sizeof g, 1) == 1 && got(a, g, sizeof g));
    uvc_asm_free(a);
    printf("ARM A5 PASS (a frame past dwMaxVideoFrameBufferSize is dropped)\n");
}

static void a6_shape(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[3000];
    mk_jpeg(f, sizeof f, 8);
    send_frame(a, &s, 0, f + 1000, 2000, 1);                 /* joined mid-frame: no SOI */
    CHECK("A6", uvc_asm_frame(a, &(size_t){ 0 }) == NULL && s.bad_shape == 1);
    uvc_asm_free(a);
    struct uvc_stats t = { 0 };
    a = uvc_asm_new(UVC_YUY2, 32, 16, 0);                    /* 1,024 bytes a frame */
    uint8_t y[1024];
    memset(y, 0x80, sizeof y);
    pay(a, &t, 0, 1, 0, y, 1000, 0);                         /* 24 bytes short */
    CHECK("A6", uvc_asm_frame(a, &(size_t){ 0 }) == NULL && t.bad_shape == 1);
    pay(a, &t, 1, 0, 0, y, 1000, 0);
    pay(a, &t, 1, 1, 0, y + 1000, 24, 0);
    CHECK("A6", got(a, y, sizeof y));
    uvc_asm_free(a);
    printf("ARM A6 PASS (MJPEG without SOI, YUY2 of the wrong length: dropped)\n");
}

static void a7_stray(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[2000], g[2000], junk[100];
    mk_jpeg(f, sizeof f, 9);
    mk_jpeg(g, sizeof g, 10);
    memset(junk, 0x11, sizeof junk);
    send_frame(a, &s, 0, f, sizeof f, 1);
    CHECK("A7", got(a, f, sizeof f));
    pay(a, &s, 0, 0, 0, junk, sizeof junk, 0);               /* after EOF, the old FID: not the next frame's */
    CHECK("A7", send_frame(a, &s, 1, g, sizeof g, 1) == 1 && got(a, g, sizeof g));
    CHECK("A7", s.stray_payloads == 1);
    uvc_asm_free(a);
    printf("ARM A7 PASS (data after EOF is not prepended to the next frame)\n");
}

static void a8_newest(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[2000], g[2100], h[2200];
    mk_jpeg(f, sizeof f, 11);
    mk_jpeg(g, sizeof g, 12);
    mk_jpeg(h, sizeof h, 13);
    send_frame(a, &s, 0, f, sizeof f, 1);
    send_frame(a, &s, 1, g, sizeof g, 1);
    send_frame(a, &s, 0, h, sizeof h, 1);                    /* three complete, none taken */
    CHECK("A8", got(a, h, sizeof h));                        /* the newest */
    CHECK("A8", uvc_asm_frame(a, &(size_t){ 0 }) == NULL);
    CHECK("A8", s.frames == 3 && s.frames_replaced == 2);
    uvc_asm_free(a);
    printf("ARM A8 PASS (the newest frame wins; the replaced counted)\n");
}

static void a9_held(void)
{
    struct uvc_stats s = { 0 };
    struct uvc_asm *a = uvc_asm_new(UVC_MJPG, 64, 64, 8192);
    uint8_t f[2000], g[2000], h[2000], keep[2000];
    mk_jpeg(f, sizeof f, 14);
    mk_jpeg(g, sizeof g, 15);
    mk_jpeg(h, sizeof h, 16);
    send_frame(a, &s, 0, f, sizeof f, 1);
    size_t len;
    const uint8_t *held = uvc_asm_frame(a, &len);            /* the consumer holds it ... */
    CHECK("A9", held && len == sizeof f);
    memcpy(keep, held, len);
    for (int i = 0; i < 4; i++) {                            /* ... while frames keep arriving */
        send_frame(a, &s, 1, g, sizeof g, 1);
        send_frame(a, &s, 0, h, sizeof h, 1);
    }
    CHECK("A9", !memcmp(held, keep, sizeof keep));
    CHECK("A9", got(a, h, sizeof h));
    uvc_asm_free(a);
    printf("ARM A9 PASS (a taken frame is never overwritten while held)\n");
}

int main(void)
{
    a1_clean();
    a2_fid_only();
    a3_packet_error();
    a4_err_bit();
    a5_overflow();
    a6_shape();
    a7_stray();
    a8_newest();
    a9_held();
    if (fails) { printf("FAILED %d\n", fails); return 1; }
    printf("ALL PASS\n");
    return 0;
}
