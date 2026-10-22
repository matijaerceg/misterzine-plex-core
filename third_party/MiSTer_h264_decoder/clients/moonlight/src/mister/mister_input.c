/* SPDX-License-Identifier: GPL-3.0-or-later */
/* clients/moonlight/src/mister/mister_input.c -- the "mister" platform's input: Main's keyboard,
 * mouse and pads, as the MiSTer H264 core mirrors them into its control block (interface 0.6,
 * h264ring_input), forwarded to the host. Design: docs/moonlight.md §7 and docs/architecture.md
 * "Input (interface 0.6)" in the MiSTer H264 core's repository.
 *
 * Why through the core: while a core runs Main holds an exclusive EVIOCGRAB on every input
 * device, so upstream's evdev input receives nothing; Main hands the core every key (PS/2 set
 * 2), the mouse and six pads (the core's J line: an Xbox-style pad), and the core copies them
 * where this program can read them.
 *
 * - A 1 ms timerfd on the main loop (the core rewrites the region at most every 1 ms).
 * - Keys: PS/2 set 2 (+E0) -> the Linux key code Main read (ps2_keys.h, the inverse of Main's
 *   table) -> upstream's keyCodes[] (the host's). A held-key set: a release of a key not held is
 *   dropped (Main sends NumLock / ScrollLock releases without their presses; a key held across
 *   the OSD). Pause arrives once, pressed, when the key is released: down and up at once.
 * - Mouse: the sums' differences since the last read (Y negated: PS/2 counts up, the host down);
 *   the wheel's (negated: PS/2 counts towards the user); a buttons event -> press / release for
 *   each changed bit (L R M, side = X1, extra = X2; forward, back and task have no host button).
 * - Pads: announced (Xbox type) on their first non-zero word, then sent whenever the word
 *   changes; LT / RT are digital (0 / 255): Main gives a core no analog trigger.
 * - The OSD: an OSD-open event releases everything the host holds and nothing is forwarded until
 *   the OSD-close event; the pads are then re-sent as they are. Events the queue no longer held
 *   (the program read more than 32 events late): the same release, counted.
 * - Quit: upstream's combos -- Ctrl+Alt+Shift+Q (once every modifier is up again) or
 *   Start+Back+LB+RB on a pad -- return LOOP_RETURN from the timer: the stream ends.
 * - The host's Guide (interface 0.8; docs/moonlight.md M11 / M12): no pad button reaches it (the
 *   pad's own Guide opens Main's OSD), so two ways. The OSD's action 0 ("Send Home to the
 *   program") -- an ACTION event, taken even while the OSD is open (Main queues it just before
 *   the OSD closes) and acted on once it is closed, so the host sees the Guide on a released
 *   pad; on the first announced pad (pad 0, announced, when none is). Action 1 ("Program menu")
 *   is reserved for this client's own menu (Phase 6b): counted, ignored. And a chord: Back +
 *   Start held GUIDE_CHORD_MS (LB and RB not held: that is the quit combo on its way) sends the
 *   Guide on that pad; Back and Start are then kept from the host until each is released (the
 *   game saw them pressed during the hold: the price of a chord). A Guide is a tap held
 *   GUIDE_TAP_MS, not a press and a release in one poll: a host that polls its virtual pad
 *   (XInput) could miss a shorter one. Both lengths count timer ticks (1 ms each).
 * - The host's rumble (interface 0.13; docs/architecture.md "Rumble (interface 0.13)"): the
 *   connection's callback (moonlight-common-c's callback thread) stores each pad's value,
 *   {lowFreqMotor >> 8, highFreqMotor >> 8}; the timer writes a changed one to the core
 *   (h264ring_rumble: this thread is the words' only writer) and, every RUMBLE_TICK_MS, keeps a
 *   held one going past Main's 32.767 s (h264ring_rumble_keepalive). Pad n is the host's
 *   controller n, which is Main's pad n (announced as such); a controller past the six is
 *   counted and dropped; trigger rumble has no motor on Main's pads. Every pad is stopped at
 *   mister_input_stop (and the library zeroes the words at close). Pads are announced with
 *   LI_CCAP_RUMBLE.
 * - The region is read without ring_mx: h264ring_input / h264ring_input_events only read the
 *   control block (no session state), and a session restart may hold the mutex for 2 s; the
 *   rumble's words likewise (the library's rule for them: one thread, after the first session).
 */
#include "mister.h"

#include "h264ring.h"
#include "ps2_keys.h"
#include "../input/keyboard.h"
#include "../loop.h"

#include <linux/input-event-codes.h>

#include <errno.h>
#include <poll.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/timerfd.h>
#include <unistd.h>

#define NPADS         6
#define POLL_NS       1000000                   /* 1 ms */
#define STICK_SCALE   258                       /* -127..127 -> -32766..32766 */
#define PS2_Q         0x15                      /* the quit key */
#define QUIT_MODS     (MODIFIER_CTRL | MODIFIER_ALT | MODIFIER_SHIFT)
#define QUIT_PAD      (H264RING_PAD_START | H264RING_PAD_BACK | H264RING_PAD_LB | H264RING_PAD_RB)
#define PAD_BUTTONS   (A_FLAG | B_FLAG | X_FLAG | Y_FLAG | UP_FLAG | DOWN_FLAG | LEFT_FLAG | RIGHT_FLAG | \
                       LB_FLAG | RB_FLAG | PLAY_FLAG | BACK_FLAG | LS_CLK_FLAG | RS_CLK_FLAG | SPECIAL_FLAG)
#define GUIDE_CHORD   (H264RING_PAD_BACK | H264RING_PAD_START)
#define GUIDE_CHORD_MS 1000                     /* the chord's hold: a deliberate second, not a tap of both */
#define GUIDE_TAP_MS  100                       /* the Guide held this long: longer than a host's pad poll */
#define PAD_GUIDE     (1u << 16)                /* in a forwarded pad word: the Guide (the core's pad is 16 bits) */
#define ACTION_HOME   0                         /* the OSD's actions (interface 0.8) */
#define ACTION_MENU   1
#define RUMBLE_TICK_MS 100                      /* the keepalive's period: the library asks for <= 1 s */

static bool started;            /* the first copy read: the counts' baselines are set */
static uint32_t ev_count;       /* the events handed on */
static uint32_t lost_total;
static bool osd;                /* Main's OSD is open: nothing is forwarded */
static bool held[2][256];       /* keys the host holds, by (extended, set-2 code) */
static char modifiers;
static bool quit_armed;         /* Ctrl+Alt+Shift+Q seen: quit once the modifiers are up */
static uint32_t dx0, dy0, wh0;  /* the sums as last forwarded */
static uint8_t mbtn;            /* the mouse buttons the host holds */
static uint64_t pad_sent[NPADS];
static uint16_t pad_mask;       /* the pads announced to the host */
static unsigned chord_ms[NPADS];        /* how long Back + Start have been held */
static unsigned chord_hide[NPADS];      /* Back / Start kept from the host after a chord, until released */
static int guide_pad = -1;              /* the pad the Guide tap is on */
static unsigned guide_ms;               /* the tap's time left */
static unsigned actions;                /* OSD actions taken, acted on once the OSD is closed */
static int tfd = -1;
static struct mister_input_counters ni;
static uint16_t rum_want[NPADS];        /* (0.13) the host's rumble, {large, small}: the callback's (__atomic) */
static uint16_t rum_sent[NPADS];        /* ... as written to the core */
static unsigned long rum_dropped;       /* (__atomic) rumble for a controller past the six */
static unsigned rum_ms;                 /* ticks since the last keepalive */

static const struct { uint8_t bit; int button; } mouse_map[] = {
    { 0, BUTTON_LEFT }, { 1, BUTTON_RIGHT }, { 2, BUTTON_MIDDLE }, { 3, BUTTON_X1 }, { 4, BUTTON_X2 },
};

static char modifier_of(unsigned linux_key) {
    switch (linux_key) {
    case KEY_LEFTSHIFT: case KEY_RIGHTSHIFT: return MODIFIER_SHIFT;
    case KEY_LEFTCTRL:  case KEY_RIGHTCTRL:  return MODIFIER_CTRL;
    case KEY_LEFTALT:   case KEY_RIGHTALT:   return MODIFIER_ALT;
    case KEY_LEFTMETA:  case KEY_RIGHTMETA:  return MODIFIER_META;
    default: return 0;
    }
}

static unsigned host_key(unsigned ext, unsigned code) {
    unsigned k = ps2_linux[ext & 1][code & 0xFF];
    return (k && k < sizeof(keyCodes) / sizeof(keyCodes[0])) ? (unsigned)keyCodes[k] : 0;
}

static void send_key(unsigned ext, unsigned code, bool down) {
    LiSendKeyboardEvent((short)(0x80 << 8 | host_key(ext, code)), down ? KEY_ACTION_DOWN : KEY_ACTION_UP, modifiers);
}

/* the pad's word -> the host's gamepad */
static void send_pad(int n, uint64_t w) {
    unsigned b = (unsigned)w & 0xFFFFu;
    int flags = 0;
    int8_t lx = (int8_t)(w >> 32), ly = (int8_t)(w >> 40), rx = (int8_t)(w >> 48), ry = (int8_t)(w >> 56);
    if (b & H264RING_PAD_RIGHT) flags |= RIGHT_FLAG;
    if (b & H264RING_PAD_LEFT)  flags |= LEFT_FLAG;
    if (b & H264RING_PAD_DOWN)  flags |= DOWN_FLAG;
    if (b & H264RING_PAD_UP)    flags |= UP_FLAG;
    if (b & H264RING_PAD_A)     flags |= A_FLAG;
    if (b & H264RING_PAD_B)     flags |= B_FLAG;
    if (b & H264RING_PAD_X)     flags |= X_FLAG;
    if (b & H264RING_PAD_Y)     flags |= Y_FLAG;
    if (b & H264RING_PAD_LB)    flags |= LB_FLAG;
    if (b & H264RING_PAD_RB)    flags |= RB_FLAG;
    if (b & H264RING_PAD_BACK)  flags |= BACK_FLAG;
    if (b & H264RING_PAD_START) flags |= PLAY_FLAG;
    if (b & H264RING_PAD_LS)    flags |= LS_CLK_FLAG;
    if (b & H264RING_PAD_RS)    flags |= RS_CLK_FLAG;
    if ((unsigned)w & PAD_GUIDE) flags |= SPECIAL_FLAG;
    /* Main's sticks: signed -127..127, Y down-positive (evdev's); the host's: up-positive */
    LiSendMultiControllerEvent((short)n, (short)pad_mask, flags,
                               (b & H264RING_PAD_LT) ? 0xFF : 0, (b & H264RING_PAD_RT) ? 0xFF : 0,
                               (short)(lx * STICK_SCALE), (short)(-ly * STICK_SCALE),
                               (short)(rx * STICK_SCALE), (short)(-ry * STICK_SCALE));
    ni.pad_sends++;
}

/* everything the host may think is held, released */
static void release_all(void) {
    for (unsigned ext = 0; ext < 2; ext++)
        for (unsigned code = 0; code < 256; code++)
            if (held[ext][code]) {
                held[ext][code] = false;
                modifiers &= ~modifier_of(ps2_linux[ext][code]);
                send_key(ext, code, false);
            }
    modifiers = 0;
    quit_armed = false;
    for (size_t i = 0; i < sizeof(mouse_map) / sizeof(mouse_map[0]); i++)
        if (mbtn & (1u << mouse_map[i].bit))
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, mouse_map[i].button);
    mbtn = 0;
    for (int n = 0; n < NPADS; n++) {
        if (pad_mask & (1u << n)) {
            send_pad(n, 0);
            pad_sent[n] = 0;
        }
        chord_ms[n] = 0;
        chord_hide[n] = 0;
    }
    guide_ms = 0;                       /* a tap cut short: its release was just sent */
    ni.releases++;
}

/* the host's Guide, as a tap on pad n (forwarded by the pad loop: a change of the word) */
static void guide(int n, const char *why) {
    guide_pad = n;
    guide_ms = GUIDE_TAP_MS;
    ni.guides++;
    printf("Guide sent to the host (%s)\n", why);
    fflush(stdout);
}

/* one key event; true: the quit combo completed */
static bool key_event(unsigned ext, unsigned code, bool pressed) {
    unsigned lk = ps2_linux[ext][code];
    char mod;
    if (!host_key(ext, code)) {
        ni.keys_unknown++;
        return false;
    }
    if (lk == KEY_PAUSE) {              /* Main sends it once, on the key's release */
        send_key(ext, code, true);
        send_key(ext, code, false);
        ni.keys += 2;
        return false;
    }
    if (!pressed && !held[ext][code]) { /* a break with no make (NumLock, a key held across the OSD) */
        ni.stray_up++;
        return false;
    }
    held[ext][code] = pressed;
    mod = modifier_of(lk);
    if (pressed) modifiers |= mod; else modifiers &= ~mod;
    if (pressed && ext == 0 && code == PS2_Q && (modifiers & QUIT_MODS) == QUIT_MODS) {
        quit_armed = true;              /* upstream's rule: quit once the modifiers are up */
        return false;
    }
    send_key(ext, code, pressed);
    ni.keys++;
    return quit_armed && modifiers == 0;
}

static void mouse_buttons(uint8_t now) {
    for (size_t i = 0; i < sizeof(mouse_map) / sizeof(mouse_map[0]); i++) {
        uint8_t m = 1u << mouse_map[i].bit;
        if ((now ^ mbtn) & m)
            LiSendMouseButtonEvent((now & m) ? BUTTON_ACTION_PRESS : BUTTON_ACTION_RELEASE, mouse_map[i].button);
    }
    mbtn = now & 0x1F;
    ni.buttons++;
}

/* ---- the host's rumble (interface 0.13) ---- */
void mister_rumble(unsigned short n, unsigned short low, unsigned short high) {
    if (n >= NPADS) {
        __atomic_add_fetch(&rum_dropped, 1, __ATOMIC_RELAXED);
        return;
    }
    __atomic_store_n(&rum_want[n], (uint16_t)((low & 0xFF00u) | (high >> 8)), __ATOMIC_RELAXED);
}

void mister_rumble_triggers(unsigned short n, unsigned short left, unsigned short right) {
    (void)n; (void)left; (void)right;   /* Main has no trigger motors for a core */
}

static void rumble_tick(struct h264ring *r, unsigned ms) {
    for (int n = 0; n < NPADS; n++) {
        uint16_t v = __atomic_load_n(&rum_want[n], __ATOMIC_RELAXED);
        if (v != rum_sent[n] && h264ring_rumble(r, (unsigned)n, v >> 8, v & 0xFFu) == 0) {
            rum_sent[n] = v;
            ni.rumbles++;
        }
    }
    rum_ms += ms;
    if (rum_ms >= RUMBLE_TICK_MS) {
        int k = h264ring_rumble_keepalive(r);
        rum_ms = 0;
        if (k > 0)
            ni.rumble_refreshes += (unsigned long)k;
    }
}

static int input_poll(unsigned ms) {
    struct h264ring *r = mister_ring();
    struct h264ring_input in;
    uint16_t ev[H264RING_IN_Q_LEN];
    uint32_t lost = 0;
    unsigned k;
    bool quit = false;
    if (r)
        rumble_tick(r, ms);             /* (0.13) whatever the OSD's state: Main plays it on every core */
    if (!r || h264ring_input(r, &in)) {
        ni.reads_failed++;
        return LOOP_OK;
    }
    ni.reads++;
    guide_ms = guide_ms > ms ? guide_ms - ms : 0;
    if (!started) {                     /* what happened before this program is not its */
        started = true;
        ev_count = (uint32_t)H264RING_IN(&in, EV_COUNT);
        dx0 = (uint32_t)H264RING_IN(&in, DX_SUM);
        dy0 = (uint32_t)H264RING_IN(&in, DY_SUM);
        wh0 = (uint32_t)H264RING_IN(&in, WHEEL_SUM);
        osd = H264RING_IN(&in, OSD_OPEN) != 0;
    }
    /* the events, in order */
    while ((k = h264ring_input_events(&in, &ev_count, ev, H264RING_IN_Q_LEN, &lost)) != 0) {
        if (lost) {
            lost_total += lost;
            ni.lost += lost;
            fprintf(stderr, "Input: %u events lost (read too late): every key released\n", lost);
            lost = 0;
            release_all();
        }
        for (unsigned i = 0; i < k; i++) {
            unsigned t = H264RING_EV_TYPE(ev[i]);
            ni.events++;
            if (t == H264RING_EV_OSD) {
                if (H264RING_EV_OPEN(ev[i]) && !osd) {
                    release_all();
                    osd = true;
                    ni.osd_opened++;
                    printf("The MiSTer menu is open: input paused\n");
                } else if (!H264RING_EV_OPEN(ev[i]) && osd) {
                    osd = false;                /* the pads: release_all left pad_sent at the host's
                                                 * zeros, so each is re-sent below if it differs */
                    printf("The MiSTer menu is closed: input resumed\n");
                }
                fflush(stdout);
            } else if (t == H264RING_EV_ACTION) {
                actions |= 1u << (H264RING_EV_CODE(ev[i]) & 31);   /* chosen in the OSD: acted on after it closes */
                ni.actions++;
            } else if (osd) {
                ni.osd_dropped++;               /* Main keeps them from the core anyway, but Alt / GUI releases */
            } else if (t == H264RING_EV_KEY) {
                quit |= key_event(H264RING_EV_EXT(ev[i]), H264RING_EV_CODE(ev[i]), H264RING_EV_PRESSED(ev[i]));
            } else if (t == H264RING_EV_MOUSE_BTN) {
                mouse_buttons((uint8_t)H264RING_EV_CODE(ev[i]));
            }
        }
    }
    /* the mouse's movement: the sums' differences (Main sends nothing while the OSD is open,
     * and the baselines follow regardless) */
    {
        int32_t dx = (int32_t)((uint32_t)H264RING_IN(&in, DX_SUM) - dx0);
        int32_t dy = -(int32_t)((uint32_t)H264RING_IN(&in, DY_SUM) - dy0);
        int32_t dw = -(int32_t)((uint32_t)H264RING_IN(&in, WHEEL_SUM) - wh0);
        dx0 = (uint32_t)H264RING_IN(&in, DX_SUM);
        dy0 = (uint32_t)H264RING_IN(&in, DY_SUM);
        wh0 = (uint32_t)H264RING_IN(&in, WHEEL_SUM);
        if (!osd) {
            while (dx || dy) {
                short sx = dx > 32767 ? 32767 : dx < -32767 ? -32767 : (short)dx;
                short sy = dy > 32767 ? 32767 : dy < -32767 ? -32767 : (short)dy;
                LiSendMouseMoveEvent(sx, sy);
                dx -= sx; dy -= sy;
                ni.mouse_moves++;
            }
            while (dw) {
                signed char c = dw > 127 ? 127 : dw < -127 ? -127 : (signed char)dw;
                LiSendScrollEvent(c);
                dw -= c;
            }
        }
    }
    /* the OSD's actions, once it is closed */
    if (actions && !osd) {
        if (actions & (1u << ACTION_HOME)) {
            int n = 0;
            while (n < NPADS - 1 && !(pad_mask & (1u << n))) n++;
            guide(pad_mask ? n : 0, "the MiSTer menu's Send Home");
        }
        if (actions & (1u << ACTION_MENU)) {
            printf("The MiSTer menu's Program menu: this client has no menu yet\n");
            fflush(stdout);
        }
        actions = 0;
    }
    /* the pads */
    for (int n = 0; n < NPADS && !osd; n++) {
        uint64_t raw = in.w[H264RING_PAD0_JOY_W - H264RING_IN_WORD + n] & 0xFFFFFFFF0000FFFFull;
        unsigned b = (unsigned)raw;
        uint64_t w;
        /* the chord: Back + Start held (not LB / RB: the quit combo), once until they are released */
        chord_hide[n] &= b;
        if ((b & GUIDE_CHORD) == GUIDE_CHORD && !(b & (H264RING_PAD_LB | H264RING_PAD_RB)) && !chord_hide[n]) {
            chord_ms[n] += ms;
            if (chord_ms[n] >= GUIDE_CHORD_MS) {
                chord_ms[n] = 0;
                chord_hide[n] = GUIDE_CHORD;
                guide(n, "Back + Start held");
            }
        } else
            chord_ms[n] = 0;
        w = raw & ~(uint64_t)chord_hide[n];
        if (n == guide_pad && guide_ms)
            w |= PAD_GUIDE;
        if (w == pad_sent[n])
            continue;
        if (!(pad_mask & (1u << n))) {
            if (w == 0) {
                pad_sent[n] = 0;
                continue;
            }
            pad_mask |= 1u << n;
            LiSendControllerArrivalEvent((uint8_t)n, pad_mask, LI_CTYPE_XBOX, PAD_BUTTONS, LI_CCAP_RUMBLE);
            ni.pads_announced++;
        }
        send_pad(n, w);
        pad_sent[n] = w;
        if ((b & QUIT_PAD) == QUIT_PAD) {
            send_pad(n, 0);
            quit = true;
        }
    }
    if (quit) {
        release_all();
        printf("Quit combo: the stream ends\n");
        fflush(stdout);
        return LOOP_RETURN;
    }
    return LOOP_OK;
}

int mister_input_poll(void) {
    return input_poll(1);
}

static int timer_fired(int fd) {
    uint64_t expirations;
    if (read(fd, &expirations, sizeof(expirations)) < 0)
        return LOOP_OK;
    return input_poll(expirations > 1000 ? 1000 : (unsigned)expirations);   /* the ticks: a late wakeup counts */
}

int mister_input_start(void) {
    struct itimerspec its = { { 0, POLL_NS }, { 0, POLL_NS } };
    tfd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (tfd < 0 || timerfd_settime(tfd, 0, &its, NULL) != 0) {
        int e = errno;
        fprintf(stderr, "Input: no timer (%s): nothing is forwarded\n", strerror(e));
        if (tfd >= 0) close(tfd);
        tfd = -1;
        return -e;
    }
    loop_add_fd(tfd, &timer_fired, POLLIN);
    printf("Input: Main's keyboard, mouse and pads through the core (Ctrl+Alt+Shift+Q or Start+Back+LB+RB quits; "
           "hold Back+Start, or the MiSTer menu's Send Home, for the host's Guide)\n");
    fflush(stdout);
    return 0;
}

void mister_input_stop(void) {
    struct h264ring *r = mister_ring();
    if (tfd >= 0) {
        release_all();
        loop_remove_fd(tfd);
        close(tfd);
        tfd = -1;
    }
    for (int n = 0; n < NPADS; n++) {   /* (0.13) every pad stopped (the host's last word may not be 0) */
        __atomic_store_n(&rum_want[n], 0, __ATOMIC_RELAXED);
        if (rum_sent[n] && r && h264ring_rumble(r, (unsigned)n, 0, 0) == 0)
            rum_sent[n] = 0;
    }
    ni.rumble_dropped = __atomic_load_n(&rum_dropped, __ATOMIC_RELAXED);
    printf("Input: %lu events (%lu keys, %lu unknown, %lu stray releases), %lu mouse moves, %lu button changes, "
           "%lu pads announced, %lu pad updates, %lu OSD openings, %lu OSD actions, %lu Guides, %lu lost, "
           "%lu rumble changes (%lu kept going, %lu for a pad past six)\n",
           ni.events, ni.keys, ni.keys_unknown, ni.stray_up, ni.mouse_moves, ni.buttons,
           ni.pads_announced, ni.pad_sends, ni.osd_opened, ni.actions, ni.guides, ni.lost,
           ni.rumbles, ni.rumble_refreshes, ni.rumble_dropped);
}

void mister_input_get_counters(struct mister_input_counters *c) {
    *c = ni;
    c->rumble_dropped = __atomic_load_n(&rum_dropped, __ATOMIC_RELAXED);
}
