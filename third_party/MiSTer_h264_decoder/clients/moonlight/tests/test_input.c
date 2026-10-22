/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/moonlight/tests/test_input.c -- the mister platform's input (src/mister/mister_input.c)
 * on the host: a control block in memory written the way the core writes its input region
 * (docs/architecture.md "Input (interface 0.6)"), the library reading it, and every LiSend* call
 * the backend makes recorded and checked. The expected host key codes are the Windows virtual-key
 * codes (the host's contract, not this backend's tables); the expected events are the ones the
 * design (docs/moonlight.md §7) says a user's action must produce.
 *
 *   test_input      one PASS / FAIL line per check, then "test_input: ALL GREEN"
 */
#include "mister.h"
#include "h264ring.h"
#include "../loop.h"

#include <Limelight.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int fails;
#define CHECK(label, cond) do { int ok_ = (cond); printf("  %s %s\n", ok_ ? "PASS" : "FAIL", label); \
                                if (!ok_) fails++; } while (0)

/* ---- the calls the backend makes ---- */
enum { C_KEY, C_MOVE, C_BTN, C_SCROLL, C_PAD, C_ARRIVE };
struct call { int kind; int a, b, c, d, e, f, g, h, i; };
static struct call calls[4096];
static int ncalls;
static void rec(int kind, int a, int b, int c, int d, int e, int f, int g, int h, int i) {
    if (ncalls < 4096) calls[ncalls++] = (struct call){ kind, a, b, c, d, e, f, g, h, i };
}
int LiSendKeyboardEvent(short keyCode, char keyAction, char modifiers) {
    rec(C_KEY, (unsigned short)keyCode, keyAction, modifiers, 0, 0, 0, 0, 0, 0); return 0;
}
int LiSendMouseMoveEvent(short dx, short dy) { rec(C_MOVE, dx, dy, 0, 0, 0, 0, 0, 0, 0); return 0; }
int LiSendMouseButtonEvent(char action, int button) { rec(C_BTN, action, button, 0, 0, 0, 0, 0, 0, 0); return 0; }
int LiSendScrollEvent(signed char clicks) { rec(C_SCROLL, clicks, 0, 0, 0, 0, 0, 0, 0, 0); return 0; }
int LiSendMultiControllerEvent(short n, short mask, int buttons, unsigned char lt, unsigned char rt,
                               short lx, short ly, short rx, short ry) {
    rec(C_PAD, n, mask, buttons, lt, rt, lx, ly, rx, ry); return 0;
}
int LiSendControllerArrivalEvent(uint8_t n, uint16_t mask, uint8_t type, uint32_t buttons, uint16_t caps) {
    rec(C_ARRIVE, n, mask, type, (int)buttons, caps, 0, 0, 0, 0); return 0;
}
static uint64_t now;                                      /* (0.13) the library's clock, us */
static uint64_t fake_now(void *u) { (void)u; return now; }
void loop_add_fd(int fd, FdHandler h, int ev) { (void)fd; (void)h; (void)ev; }
void loop_remove_fd(int fd) { (void)fd; }

/* ---- the core: its input region ---- */
static uint64_t ctrl[512], ringmem[8192];
static h264ring *ring;
struct h264ring *mister_ring(void) { return ring; }

static uint32_t seq, evc, dx, dy, wh;
static uint8_t btn, osd;
static uint64_t pads[6];
static uint16_t q[32];
static void publish(void) {       /* one write of the region, as the core makes it */
    seq++;
    ctrl[48] = seq | ((uint64_t)evc << 32);
    for (int n = 0; n < 6; n++) ctrl[49 + n] = pads[n];
    ctrl[55] = dx | ((uint64_t)dy << 32);
    for (int w = 0; w < 8; w++)
        ctrl[56 + w] = q[4 * w] | ((uint64_t)q[4 * w + 1] << 16) | ((uint64_t)q[4 * w + 2] << 32) | ((uint64_t)q[4 * w + 3] << 48);
    ctrl[64] = wh | ((uint64_t)btn << 32) | ((uint64_t)osd << 40);
    ctrl[71] = seq;
}
static void ev(uint16_t e) { q[evc % 32] = e; evc++; }
static void key(unsigned ext, unsigned code, int down) { ev((uint16_t)((down ? 0x200 : 0) | (ext ? 0x100 : 0) | code)); }
static void osd_ev(int open) { osd = (uint8_t)open; ev((uint16_t)(0x8000 | open)); }
static void action(int n) { ev((uint16_t)(0xC000 | n)); }     /* (0.8) an OSD action: type 3 */
static void mouse(int x, int y, int w, uint8_t b) {
    dx += (uint32_t)x; dy += (uint32_t)y; wh += (uint32_t)w;
    if (b != btn) { btn = b; ev((uint16_t)(0x4000 | b)); }
}
static int poll_once(void) { ncalls = 0; publish(); return mister_input_poll(); }

static int find(int kind, int a, int b) {        /* the index of the first matching call, or -1 */
    for (int i = 0; i < ncalls; i++)
        if (calls[i].kind == kind && calls[i].a == a && calls[i].b == b) return i;
    return -1;
}
static int pad_call(int n) { for (int i = ncalls - 1; i >= 0; i--) if (calls[i].kind == C_PAD && calls[i].a == n) return i; return -1; }
static int count(int kind) { int k = 0; for (int i = 0; i < ncalls; i++) k += calls[i].kind == kind; return k; }
static int last(int kind) { for (int i = ncalls - 1; i >= 0; i--) if (calls[i].kind == kind) return i; return -1; }

/* Windows virtual-key codes (the host's), with Moonlight's 0x80xx marker */
#define VK(v) (0x8000 | (v))
enum { VK_A = 0x41, VK_Q = 0x51, VK_LSHIFT = 0xA0, VK_LCTRL = 0xA2, VK_LALT = 0xA4, VK_UP = 0x26,
       VK_PAUSE = 0x13, VK_SNAPSHOT = 0x2C, VK_RETURN = 0x0D };

int main(void) {
    struct h264ring_backend be = { ctrl, ringmem, sizeof(ringmem), NULL, NULL, fake_now, NULL };
    ctrl[0] = H264RING_MAGIC;
    ctrl[1] = H264RING_VERSION;
    ctrl[2] = 0x31800000ull | ((uint64_t)sizeof(ringmem) << 32);
    /* the core has been running: 7 events before this program started */
    for (int i = 0; i < 7; i++) key(0, 0x1C, i & 1);
    dx = 1000; dy = 2000; wh = 5;
    if (h264ring_attach(&ring, &be)) { printf("attach failed\n"); return 1; }

    printf("test_input:\n");
    CHECK("T1 what happened before the program is not forwarded", poll_once() == LOOP_OK && ncalls == 0);

    /* T2 keys: 'A', Shift+A, an extended key, a stray release, Pause, PrintScreen */
    key(0, 0x1C, 1); key(0, 0x1C, 0);
    poll_once();
    CHECK("T2 A down, A up (VK 0x41)", ncalls == 2 && find(C_KEY, VK(VK_A), KEY_ACTION_DOWN) == 0 &&
          find(C_KEY, VK(VK_A), KEY_ACTION_UP) == 1);
    key(0, 0x12, 1); key(0, 0x1C, 1); key(0, 0x1C, 0); key(0, 0x12, 0);
    poll_once();
    CHECK("T2 Shift+A: the modifier on the A (VK_LSHIFT 0xA0)", ncalls == 4 && calls[0].a == VK(VK_LSHIFT) &&
          calls[1].a == VK(VK_A) && calls[1].c == MODIFIER_SHIFT && calls[3].a == VK(VK_LSHIFT) && calls[3].c == 0);
    key(1, 0x75, 1); key(1, 0x75, 0); key(0, 0x5A, 1); key(0, 0x5A, 0);
    poll_once();
    CHECK("T2 E0 75 is Up (0x26), 5A Enter (0x0D)", ncalls == 4 && calls[0].a == VK(VK_UP) && calls[2].a == VK(VK_RETURN));
    key(0, 0x77, 0);                                   /* NumLock's release without its press (Main) */
    poll_once();
    CHECK("T2 a release of a key not held is dropped", ncalls == 0);
    key(1, 0x77, 1);                                   /* Pause: one pressed event, on the key's release */
    poll_once();
    CHECK("T2 Pause: down and up at once (0x13)", ncalls == 2 && calls[0].a == VK(VK_PAUSE) &&
          calls[0].b == KEY_ACTION_DOWN && calls[1].b == KEY_ACTION_UP);
    key(1, 0x7C, 1); key(1, 0x7C, 0);
    poll_once();
    CHECK("T2 PrintScreen (E0 7C, 0x2C)", ncalls == 2 && calls[0].a == VK(VK_SNAPSHOT) && calls[1].b == KEY_ACTION_UP);

    /* T3 the mouse */
    mouse(10, 20, 0, 0); mouse(-3, 5, 0, 0);
    poll_once();
    CHECK("T3 movement: the sums' difference, Y negated (PS/2 counts up)", ncalls == 1 && calls[0].kind == C_MOVE &&
          calls[0].a == 7 && calls[0].b == -25);
    mouse(0, 0, -2, 0);
    poll_once();
    CHECK("T3 the wheel, negated (PS/2 counts towards the user)", ncalls == 1 && calls[0].kind == C_SCROLL && calls[0].a == 2);
    mouse(0, 0, 0, 0x01); mouse(0, 0, 0, 0x03); mouse(0, 0, 0, 0x02); mouse(0, 0, 0, 0x00);
    poll_once();
    CHECK("T3 buttons: L down, R down, L up, R up, in order", count(C_BTN) == 4 &&
          calls[0].a == BUTTON_ACTION_PRESS && calls[0].b == BUTTON_LEFT &&
          calls[1].a == BUTTON_ACTION_PRESS && calls[1].b == BUTTON_RIGHT &&
          calls[2].a == BUTTON_ACTION_RELEASE && calls[2].b == BUTTON_LEFT &&
          calls[3].a == BUTTON_ACTION_RELEASE && calls[3].b == BUTTON_RIGHT);
    mouse(0, 0, 0, 0x08); mouse(0, 0, 0, 0x28); mouse(0, 0, 0, 0x00);
    poll_once();
    CHECK("T3 side = X1; buttons 6-8 have no host button", count(C_BTN) == 2 && calls[0].b == BUTTON_X1 &&
          calls[0].a == BUTTON_ACTION_PRESS && calls[1].b == BUTTON_X1 && calls[1].a == BUTTON_ACTION_RELEASE);
    mouse(40000, 0, 0, 0);
    poll_once();
    CHECK("T3 a move beyond a short is split", count(C_MOVE) == 2 && calls[0].a + calls[1].a == 40000);

    /* T4 the pads: pad 1 announced on its first input */
    pads[1] = (uint64_t)(H264RING_PAD_A | H264RING_PAD_LT | H264RING_PAD_UP) | ((uint64_t)(uint8_t)127 << 32) |
              ((uint64_t)(uint8_t)-127 << 40);
    poll_once();
    CHECK("T4 pad 1: arrival (Xbox), then its state", ncalls == 2 && calls[0].kind == C_ARRIVE && calls[0].a == 1 &&
          calls[0].b == 0x2 && calls[0].c == LI_CTYPE_XBOX && calls[1].kind == C_PAD && calls[1].a == 1 && calls[1].b == 0x2);
    CHECK("T4 the arrival declares the Guide (SPECIAL) among its buttons", calls[0].kind == C_ARRIVE && (calls[0].d & SPECIAL_FLAG));
    CHECK("T4 the arrival declares rumble (0.13)", calls[0].kind == C_ARRIVE && calls[0].e == LI_CCAP_RUMBLE);
    CHECK("T4 A, Up and LT (255); the stick: X right, Y up-positive", (calls[1].c & (A_FLAG | UP_FLAG)) == (A_FLAG | UP_FLAG) &&
          !(calls[1].c & B_FLAG) && calls[1].d == 255 && calls[1].e == 0 && calls[1].f == 32766 && calls[1].g == 32766);
    poll_once();
    CHECK("T4 nothing changed: nothing sent", ncalls == 0);
    pads[1] = H264RING_PAD_B | H264RING_PAD_START | H264RING_PAD_RS;
    poll_once();
    CHECK("T4 a change: sent (B, Start = PLAY, RS click)", ncalls == 1 && calls[0].c == (B_FLAG | PLAY_FLAG | RS_CLK_FLAG) &&
          calls[0].f == 0 && calls[0].g == 0);

    /* T5 the OSD: everything the host holds released; nothing forwarded until it closes */
    key(0, 0x12, 1); mouse(0, 0, 0, 0x01);
    poll_once();
    osd_ev(1);
    poll_once();
    CHECK("T5 OSD opened: the key up, the button up, the pad zeroed", find(C_KEY, VK(VK_LSHIFT), KEY_ACTION_UP) >= 0 &&
          find(C_BTN, BUTTON_ACTION_RELEASE, BUTTON_LEFT) >= 0 && last(C_PAD) >= 0 && calls[last(C_PAD)].a == 1 &&
          calls[last(C_PAD)].c == 0);
    key(0, 0x1C, 1); key(0, 0x1C, 0); mouse(5, 5, 0, 0); pads[1] = H264RING_PAD_X; /* Alt's release reaches the core */
    poll_once();
    CHECK("T5 while it is open: nothing forwarded", ncalls == 0);
    osd_ev(0);
    poll_once();
    CHECK("T5 OSD closed: the pads re-sent as they are", ncalls == 1 && calls[0].kind == C_PAD && calls[0].c == X_FLAG);
    key(0, 0x12, 0);                                   /* Shift released after the OSD: already released */
    poll_once();
    CHECK("T5 a key released after the OSD closed is not sent again", ncalls == 0);

    /* T6 read too late: 40 events at once, the queue held 32 */
    key(0, 0x1C, 1);
    poll_once();
    for (int i = 0; i < 40; i++) key(0, 0x2A, i & 1 ? 0 : 1);   /* V down / up */
    {
        struct mister_input_counters c;
        poll_once();
        mister_input_get_counters(&c);
        CHECK("T6 8 events lost: counted, the held A released first", c.lost == 8 &&
              find(C_KEY, VK(VK_A), KEY_ACTION_UP) == 0);
    }

    /* T7 upstream's quit combo: Ctrl+Alt+Shift+Q, the stream ending once the modifiers are up */
    key(0, 0x14, 1); key(0, 0x11, 1); key(0, 0x12, 1); key(0, 0x15, 1);
    CHECK("T7 Ctrl+Alt+Shift+Q: Q not sent, no quit yet", poll_once() == LOOP_OK && find(C_KEY, VK(VK_Q), KEY_ACTION_DOWN) < 0);
    key(0, 0x15, 0); key(0, 0x14, 0); key(0, 0x11, 0); key(0, 0x12, 0);
    CHECK("T7 ... the modifiers up: the stream ends", poll_once() == LOOP_RETURN);

    /* T8 the pad's quit combo */
    pads[0] = H264RING_PAD_START | H264RING_PAD_BACK | H264RING_PAD_LB | H264RING_PAD_RB;
    CHECK("T8 Start+Back+LB+RB: the stream ends, the pad zeroed", poll_once() == LOOP_RETURN &&
          last(C_PAD) >= 0 && calls[last(C_PAD)].c == 0);
    pads[0] = 0;

    /* T9 a copy caught mid-write: nothing forwarded, counted */
    {
        struct mister_input_counters c0, c1;
        mister_input_get_counters(&c0);
        key(0, 0x1C, 1);
        publish(); ctrl[71] = seq - 1u; ncalls = 0;
        mister_input_poll();
        mister_input_get_counters(&c1);
        CHECK("T9 a torn copy: nothing forwarded, counted", ncalls == 0 && c1.reads_failed == c0.reads_failed + 1);
    }

    /* T10 (0.8) the OSD's Send Home: taken while the OSD is open, the Guide sent once it closes,
     * on the first announced pad (0: T8), held 100 polls (1 ms each), then released */
    {
        int held_ok = 1, p;
        osd_ev(1);
        poll_once();
        action(0);
        {
            int quiet = 1;                         /* the OSD left open longer than a Guide tap */
            for (int i = 0; i < 150; i++) { poll_once(); if (ncalls) quiet = 0; }
            CHECK("T10 an action while the OSD is open: nothing sent yet", quiet);
        }
        osd_ev(0);
        poll_once();
        p = pad_call(0);
        CHECK("T10 the OSD closed: the Guide pressed on pad 0", p >= 0 && calls[p].c == SPECIAL_FLAG);
        for (int i = 1; i < 100; i++) { poll_once(); if (count(C_PAD)) held_ok = 0; }
        poll_once();
        p = last(C_PAD);
        CHECK("T10 the Guide held 100 ms, then released", held_ok && p >= 0 && calls[p].a == 0 && calls[p].c == 0);
        action(0); osd_ev(0);                          /* the close in the same copy as the action */
        poll_once();
        p = pad_call(0);
        CHECK("T10 the action and the close in one read: the Guide sent", p >= 0 && calls[p].c == SPECIAL_FLAG);
        for (int i = 0; i < 100; i++) poll_once();
        action(1);
        poll_once();
        CHECK("T10 the Program menu (action 1): nothing sent", ncalls == 0);
    }

    /* T11 (0.8) the chord: Back + Start held a second sends the Guide on that pad; Back and Start
     * are then kept from the host until released; not with LB / RB (the quit combo) */
    {
        int early = 0, p;
        struct mister_input_counters c;
        pads[2] = H264RING_PAD_BACK | H264RING_PAD_START;
        poll_once();
        p = last(C_PAD);
        CHECK("T11 Back + Start reach the host at once", p >= 0 && calls[p].a == 2 && calls[p].c == (BACK_FLAG | PLAY_FLAG));
        for (int i = 1; i < 999; i++) { poll_once(); if (count(C_PAD)) early = 1; }
        poll_once();
        p = last(C_PAD);
        CHECK("T11 held a second: the Guide on pad 2, Back and Start released", !early && p >= 0 && calls[p].a == 2 &&
              calls[p].c == SPECIAL_FLAG);
        for (int i = 0; i < 100; i++) poll_once();
        pads[2] = H264RING_PAD_START;                  /* Back released: nothing to tell the host */
        poll_once();
        p = count(C_PAD);
        pads[2] = 0; poll_once();
        pads[2] = H264RING_PAD_START; poll_once();     /* Start pressed again: it is the game's */
        CHECK("T11 Back and Start kept from the host until released, then the game's again", p == 0 &&
              last(C_PAD) >= 0 && calls[last(C_PAD)].c == PLAY_FLAG);
        pads[2] = H264RING_PAD_BACK | H264RING_PAD_START | H264RING_PAD_LB;
        mister_input_get_counters(&c);
        for (int i = 0; i < 1200; i++) poll_once();
        {
            struct mister_input_counters c2;
            mister_input_get_counters(&c2);
            CHECK("T11 not with LB held (the quit combo on its way)", c2.guides == c.guides);
        }
        pads[2] = 0; poll_once();
    }

    /* T12 (0.13) the host's rumble: controller n's motors {low >> 8, high >> 8} into words 36-38 */
    {
        struct mister_input_counters c;
        #define RUM(n) ((uint16_t)(ctrl[H264RING_W_RUMBLE + (n) / 2] >> (16 * ((n) & 1))))
        mister_rumble(0, 0x80FF, 0x40FF);
        mister_rumble(3, 0xFFFF, 0x0100);
        CHECK("T12 nothing written before the timer (the callback's thread never writes the core)", RUM(0) == 0 && RUM(3) == 0);
        poll_once();
        CHECK("T12 rumble: pad 0 {0x80, 0x40}, pad 3 {0xFF, 0x01} -- the large motor is the host's low frequency",
              RUM(0) == 0x8040 && RUM(3) == 0xFF01 && RUM(1) == 0 && RUM(2) == 0 && ncalls == 0);
        mister_rumble(6, 0xFFFF, 0xFFFF);
        mister_rumble_triggers(0, 0xFFFF, 0xFFFF);
        poll_once();
        mister_input_get_counters(&c);
        CHECK("T12 a controller past six dropped and counted; trigger rumble ignored",
              RUM(0) == 0x8040 && RUM(4) == 0 && RUM(5) == 0 && c.rumble_dropped == 1 && c.rumbles == 2);
        osd_ev(1); poll_once();
        mister_rumble(1, 0x1000, 0);
        poll_once();
        CHECK("T12 written while Main's menu is open (Main plays it on every core)", RUM(1) == 0x1000);
        osd_ev(0); poll_once();
        mister_rumble(1, 0, 0);
        poll_once();
        now += (uint64_t)H264RING_RUMBLE_KEEPALIVE_MS * 1000u;
        for (int i = 0; i < 100; i++) poll_once();
        mister_input_get_counters(&c);
        CHECK("T12 a held rumble kept going past Main's 32.767 s (stepped by the keepalive), an off one not",
              RUM(0) == 0x8140 && RUM(3) == 0xFE01 && RUM(1) == 0 && c.rumble_refreshes == 2);
        mister_input_stop();
        CHECK("T12 every pad stopped when the input stops", RUM(0) == 0 && RUM(3) == 0 &&
              ctrl[H264RING_W_RUMBLE] == 0 && ctrl[H264RING_W_RUMBLE + 1] == 0 && ctrl[H264RING_W_RUMBLE + 2] == 0);
    }

    h264ring_close(ring);
    printf("test_input: %s\n", fails ? "FAILURES" : "ALL GREEN");
    return fails ? 1 : 0;
}
