/* input -- the player's controls (input.h). */
#include <string.h>
#include "core.h"
#include "input.h"

/* a held d-pad direction or shoulder repeats its seek (the client adds the steps up and seeks once,
 * after the last: docs/jellyfin.md S10); the keyboard repeats by itself (PS/2 typematic) */
#define REPEAT_FIRST_MS 450
#define REPEAT_MS       180
#define SEEK_BUTTONS (H264RING_PAD_LEFT | H264RING_PAD_RIGHT | H264RING_PAD_UP | H264RING_PAD_DOWN | \
                      H264RING_PAD_LB | H264RING_PAD_RB)

/* PS/2 set-2 make codes (hps_io's ps2_key: [7:0] the code, [8] E0, [9] pressed) */
#define K_SPACE 0x29
#define K_ENTER 0x5A
#define K_ESC   0x76
#define K_K     0x42
#define K_Q     0x15
#define K_S     0x1B
#define K_A     0x1C
#define K_I     0x43
#define K_N     0x31
#define K_P     0x4D
#define K_BKSP  0x66
#define KE_LEFT  0x6B   /* E0 */
#define KE_RIGHT 0x74
#define KE_UP    0x75
#define KE_DOWN  0x72
#define KE_PGUP  0x7D
#define KE_PGDN  0x7A

/* a list's keys */
static enum cl_action key_nav(unsigned code, unsigned ext)
{
    if (ext) {
        switch (code) {
        case KE_UP: return ACT_UP;
        case KE_DOWN: return ACT_DOWN;
        case KE_PGUP: return ACT_PAGE_UP;
        case KE_PGDN: return ACT_PAGE_DOWN;
        case KE_RIGHT: case K_ENTER: return ACT_OK;
        case KE_LEFT: return ACT_CANCEL;
        }
        return ACT_NONE;
    }
    switch (code) {
    case K_ENTER: case K_SPACE: return ACT_OK;
    case K_ESC: case K_BKSP: return ACT_CANCEL;
    case K_Q: return ACT_STOP;
    }
    return ACT_NONE;
}

static enum cl_action key(unsigned code, unsigned ext)
{
    if (ext) {
        switch (code) {
        case KE_LEFT: return ACT_BACK;
        case KE_RIGHT: return ACT_FWD;
        case KE_UP: case KE_PGUP: return ACT_FWD_BIG;
        case KE_DOWN: case KE_PGDN: return ACT_BACK_BIG;
        case K_ENTER: return ACT_PAUSE;     /* the keypad's Enter */
        }
        return ACT_NONE;
    }
    switch (code) {
    case K_SPACE: case K_K: case K_ENTER: return ACT_PAUSE;
    case K_ESC: case K_Q: return ACT_STOP;
    case K_S: return ACT_SUBS;
    case K_A: return ACT_AUDIO;
    case K_I: return ACT_INFO;
    case K_N: return ACT_NEXT;
    case K_P: return ACT_PREV;
    }
    return ACT_NONE;
}

/* a pad's newly pressed buttons -> actions (Back + Start together is stop, so Start alone acts on
 * its release-free press only when Back is not held); a seek button held repeats */
static unsigned pad(uint64_t *repeat_ms, uint32_t was, uint32_t now, enum cl_action *out, unsigned cap, int nav)
{
    uint32_t down = now & ~was;
    unsigned n = 0;
    uint64_t t = now_ms();
    if (!(now & SEEK_BUTTONS)) *repeat_ms = 0;
    else if (down & SEEK_BUTTONS) *repeat_ms = t + REPEAT_FIRST_MS;
    else if (*repeat_ms && t >= *repeat_ms) {        /* held: the held seek buttons again */
        down |= now & SEEK_BUTTONS;
        *repeat_ms = t + REPEAT_MS;
    }
#define EMIT(a) do { if (n < cap) out[n++] = (a); } while (0)
    if ((now & H264RING_PAD_BACK) && (now & H264RING_PAD_START) &&
        (down & (H264RING_PAD_BACK | H264RING_PAD_START))) { EMIT(ACT_STOP); return n; }
    if (nav) {                                       /* a list: the same edges and repeats, other meanings */
        if (down & H264RING_PAD_UP) EMIT(ACT_UP);
        if (down & H264RING_PAD_DOWN) EMIT(ACT_DOWN);
        if (down & H264RING_PAD_LB) EMIT(ACT_PAGE_UP);
        if (down & H264RING_PAD_RB) EMIT(ACT_PAGE_DOWN);
        if ((down & (H264RING_PAD_A | H264RING_PAD_RIGHT)) ||
            ((down & H264RING_PAD_START) && !(now & H264RING_PAD_BACK))) EMIT(ACT_OK);
        if (down & (H264RING_PAD_B | H264RING_PAD_LEFT)) EMIT(ACT_CANCEL);
        return n;
    }
    if (down & H264RING_PAD_A) EMIT(ACT_PAUSE);
    if ((down & H264RING_PAD_START) && !(now & H264RING_PAD_BACK)) EMIT(ACT_PAUSE);
    if (down & H264RING_PAD_LEFT) EMIT(ACT_BACK);
    if (down & H264RING_PAD_RIGHT) EMIT(ACT_FWD);
    if (down & (H264RING_PAD_LB | H264RING_PAD_DOWN)) EMIT(ACT_BACK_BIG);
    if (down & (H264RING_PAD_RB | H264RING_PAD_UP)) EMIT(ACT_FWD_BIG);
    if (down & H264RING_PAD_X) EMIT(ACT_SUBS);
    if (down & H264RING_PAD_Y) EMIT(ACT_AUDIO);
    if (down & H264RING_PAD_B) EMIT(ACT_INFO);
#undef EMIT
    return n;
}

unsigned input_poll(struct cl_input *in, h264ring *r, enum cl_action *out, unsigned cap)
{
    struct h264ring_input w;
    if (h264ring_input(r, &w)) return 0;
    unsigned n = 0;
    if (!in->started) {                     /* events before the client began are not its */
        in->count = (uint32_t)H264RING_IN(&w, EV_COUNT);
        for (unsigned i = 0; i < 6; i++) in->pads[i] = (uint32_t)w.w[1 + i] & 0xFFFFu;
        in->started = 1;
        return 0;
    }
    uint16_t ev[H264RING_IN_Q_LEN];
    uint32_t lost = 0;
    unsigned k = h264ring_input_events(&w, &in->count, ev, H264RING_IN_Q_LEN, &lost);
    for (unsigned i = 0; i < k && n < cap; i++) {
        unsigned t = H264RING_EV_TYPE(ev[i]);
        if (t == H264RING_EV_KEY && H264RING_EV_PRESSED(ev[i])) {
            enum cl_action a = (in->nav ? key_nav : key)(H264RING_EV_CODE(ev[i]), H264RING_EV_EXT(ev[i]));
            if (a != ACT_NONE) out[n++] = a;
        } else if (t == H264RING_EV_ACTION) {
            out[n++] = H264RING_EV_CODE(ev[i]) == 0 ? ACT_STOP : in->nav ? ACT_CANCEL : ACT_INFO;
        }
    }
    int osd = (int)H264RING_IN(&w, OSD_OPEN);
    for (unsigned i = 0; i < 6; i++) {
        uint32_t now = (uint32_t)w.w[1 + i] & 0xFFFFu;   /* words 49-54: the pads' buttons */
        if (!osd) n += pad(&in->repeat_ms[i], in->pads[i], now, out + n, cap - n, in->nav);
        in->pads[i] = now;
    }
    return n;
}

const char *input_action_name(enum cl_action a)
{
    static const char *const names[] = {"none", "pause", "back 10 s", "forward 30 s", "back 5 min",
                                        "forward 5 min", "stop", "subtitles", "audio", "info", "next",
                                        "previous", "up", "down", "page up", "page down", "ok", "cancel"};
    return (unsigned)a < sizeof names / sizeof names[0] ? names[a] : "?";
}
