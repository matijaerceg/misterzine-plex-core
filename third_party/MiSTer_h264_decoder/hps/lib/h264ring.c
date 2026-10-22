/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring.c -- the HPS interface's protocol (docs/architecture.md "The HPS interface,
 * v0.1"), over a backend: the same code writes /dev/mem on the MiSTer, a test's buffer and
 * the Verilator cosim's DDR model. Written as C that also compiles as C++ (the cosim).
 *
 * The rules this file keeps (each one is why the interface looks as it does):
 *   * Every store into the mapping is an ALIGNED 32- or 64-bit store: never memcpy into it
 *     (an unaligned store to strongly-ordered memory faults on ARMv7; glibc's memcpy makes
 *     them). Payload bytes are assembled into a local word first.
 *   * The payload, then a barrier, then the write index (one aligned 32-bit store). The core
 *     never reads past the write index, so it never sees a record half written.
 *   * The write index and the nonce are never written together (the core reads both in one
 *     poll and may land between two stores): a session is started by the nonce ALONE, and
 *     the core starts it at the write index it read in that same poll.
 *   * The status block is read as a seqlock: seq_tail (word 31), the words, seq_head (word 3).
 */
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>
#include "h264ring.h"
#include "h264ring_cavlc.h"
#include "h264ring_priv.h"
#if defined(__ARM_NEON) && !defined(H264RING_NO_NEON)
#include <arm_neon.h>                 /* the store copy's interior (put_row) */
#endif

static void def_barrier(void *u) { (void)u; __sync_synchronize(); }
static void def_sleep(void *u, unsigned us) { (void)u; usleep(us); }
static uint64_t def_now(void *u)
{
    struct timespec ts;
    (void)u;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static inline uint32_t ctrl_lo(h264ring *r, unsigned w)
{
    return ((volatile uint32_t *)(r->be.ctrl + w))[0];      /* one aligned 32-bit load */
}
static inline uint32_t ctrl_hi(h264ring *r, unsigned w)
{
    return ((volatile uint32_t *)(r->be.ctrl + w))[1];
}
static inline void ctrl_lo_store(h264ring *r, unsigned w, uint32_t v)
{
    ((volatile uint32_t *)(r->be.ctrl + w))[0] = v;         /* one aligned 32-bit store */
}
static inline void ring_store(h264ring *r, uint32_t index, uint64_t v)
{
    r->be.ring[(index & (r->be.ring_size - 1u)) >> 3] = v;  /* index is 8-aligned */
}
static inline uint64_t now_us(h264ring *r) { return r->be.now_us(r->be.user); }
static inline void nap(h264ring *r, unsigned us) { r->be.sleep_us(r->be.user, us); }
static int ovl_write(h264ring *r, int on);       /* (0.9) the overlay's descriptor, below */
int h264ring_set_geometry(h264ring *r, const struct h264ring_geometry *g, unsigned timeout_ms);

int h264ring_attach(h264ring **out, const struct h264ring_backend *be)
{
    h264ring *r;
    uint64_t w1, w2;
    *out = NULL;
    if (!be || !be->ctrl || !be->ring || be->ring_size == 0 || (be->ring_size & (be->ring_size - 1u)))
        return -EINVAL;
    r = (h264ring *)calloc(1, sizeof(*r));
    if (!r)
        return -ENOMEM;
    r->be = *be;
    if (!r->be.barrier) r->be.barrier = def_barrier;
    if (!r->be.sleep_us) r->be.sleep_us = def_sleep;
    if (!r->be.now_us) r->be.now_us = def_now;
    r->lock_fd = r->mem_fd = -1;
    if (r->be.ctrl[0] != H264RING_MAGIC) {
        free(r);
        return -ENODEV;                   /* no core, or not this one */
    }
    w1 = r->be.ctrl[1];
    w2 = r->be.ctrl[2];
    r->interface_version = (uint16_t)(w1 & 0xFFFFu);
    if (!h264ring_version_ok(r->interface_version, H264RING_MIN_VERSION) || /* common API: same major, 1.1+ */
        ((w2 >> 32) & 0xFFFFFFFFu) != be->ring_size) {
        free(r);
        return -EPROTONOSUPPORT;          /* another interface version, or another geometry */
    }
    *out = r;
    return 0;
}

int h264ring_status(h264ring *r, struct h264ring_status *st)
{
    for (int tries = 0; tries < 200; tries++) {
        uint32_t tail = ctrl_lo(r, 31);
        for (unsigned i = 0; i < H264RING_STATUS_WORDS; i++)     /* 40-47 (0.5), 80-87 (0.10) are written before 31 */
            st->w[i] = (i < H264RING_CORE2_WORD + H264RING_CORE2_WORDS || i >= H264RING_CORE3_WORD) ? r->be.ctrl[i] : 0;
        if (ctrl_lo(r, 3) == tail && (uint32_t)st->w[3] == tail && (uint32_t)st->w[31] == tail)
            return 0;
        nap(r, 200);                      /* a frame's write was in progress */
    }
    return -EAGAIN;
}

int h264ring_input(h264ring *r, struct h264ring_input *in)
{
    const unsigned last = H264RING_IN_WORDS - 1u;
    for (int tries = 0; tries < 200; tries++) {
        uint32_t tail = ctrl_lo(r, H264RING_IN_WORD + last);          /* in_tail FIRST */
        for (unsigned i = 0; i < H264RING_IN_WORDS; i++)
            in->w[i] = r->be.ctrl[H264RING_IN_WORD + i];
        if (ctrl_lo(r, H264RING_IN_WORD) == tail && (uint32_t)in->w[0] == tail && (uint32_t)in->w[last] == tail)
            return 0;                                                /* in_head LAST, equal */
        nap(r, 50);                       /* a write of the region was in progress (a few us) */
    }
    return -EAGAIN;
}

unsigned h264ring_input_events(const struct h264ring_input *in, uint32_t *count, uint16_t *ev,
                               unsigned cap, uint32_t *lost)
{
    uint32_t evc = (uint32_t)H264RING_IN(in, EV_COUNT);
    uint32_t n = evc - *count;            /* free-running: the difference is right across a wrap */
    unsigned k = 0;
    if (n > 0x80000000u)                  /* count ahead of the core's: a reset core, start over */
        n = 0, *count = evc;
    if (n > H264RING_IN_Q_LEN) {          /* overwritten before this read: counted, skipped */
        if (lost)
            *lost += n - H264RING_IN_Q_LEN;
        *count = evc - H264RING_IN_Q_LEN;
        n = H264RING_IN_Q_LEN;
    }
    for (; k < n && k < cap; k++) {
        uint32_t e = *count + k;
        unsigned slot = e % H264RING_IN_Q_LEN;
        ev[k] = (uint16_t)(in->w[H264RING_IN_Q_WORD - H264RING_IN_WORD + slot / 4u] >> (16u * (slot % 4u)));
    }
    *count += k;
    return k;
}

int h264ring_alive(h264ring *r, unsigned timeout_ms)
{
    uint64_t t0 = now_us(r);
    uint32_t s0 = ctrl_lo(r, 3);
    if (r->be.ctrl[0] != H264RING_MAGIC)
        return -ENODEV;
    do {
        nap(r, 5000);
        if (ctrl_lo(r, 3) != s0)
            return 0;
    } while (now_us(r) - t0 < (uint64_t)timeout_ms * 1000u);
    return -ETIMEDOUT;                    /* the words are there, the core is not running */
}

/* a new nonce, and the core's acknowledgement: the core starts the session at the write
 * index it reads with the nonce, so everything written and not yet read is dropped */
static int new_session(h264ring *r, unsigned timeout_ms)
{
    struct h264ring_status st;
    struct h264ring_geometry saved_geometry = r->geometry;
    uint32_t ack, cur, nonce;
    uint64_t t0;
    int rc;
    if ((rc = h264ring_status(r, &st)))
        return rc;
    ack = (uint32_t)H264RING_ST(&st, ACK_NONCE);
    cur = ctrl_lo(r, H264RING_W_NONCE);
    nonce = (uint32_t)(now_us(r) * 2654435761u) ^ (uint32_t)getpid() ^ (uint32_t)(uintptr_t)r;
    while (nonce == 0 || nonce == ack || nonce == cur)
        nonce++;
    r->session = 0;
    if (r->cv)
        h264ring_cavlc_reset(r->cv);                  /* a new stream: the rewrite starts afresh */
    r->rc_valid = 0;                                  /* and nothing rewritten before it is reused */
    ctrl_lo_store(r, H264RING_W_PAUSE, r->ctl);       /* (0.5) this program's pause / volume, not a stale one */
    /* (0.4, fixed 2026-10-02 on the rig) the settings request: this program's own, or none -- a
     * new session applies word 35 once, so a stale word re-asserted the PREVIOUS program's
     * settings; and the numbering continues from what the core last consumed, so this
     * program's first request is new (from 1 it repeated the last program's and was ignored) */
    if (!r->set_word)
        r->set_seq = (uint8_t)H264RING_ST(&st, SET_SEQ);
    ctrl_lo_store(r, H264RING_W_SETTINGS, r->set_word);
    /* (1.2) clear the core's active geometry while it resets. A request accepted by this
     * handle is restored after the new session is acknowledged (seek/switch on this handle).
     * A newly attached handle is calloc'd, so it starts with no saved request. */
    ctrl_lo_store(r, H264RING_W_GEOMETRY_CLIP, 0);
    ((volatile uint32_t *)(r->be.ctrl + H264RING_W_GEOMETRY_CLIP))[1] = 0;
    ctrl_lo_store(r, H264RING_W_GEOMETRY, 0);
    ((volatile uint32_t *)(r->be.ctrl + H264RING_W_GEOMETRY))[1] = 0;
    r->geometry_seq = (uint8_t)H264RING_ST(&st, GEOMETRY_ACK_SEQ);
    r->geometry_pending = 0;
    memset(&r->pending_geometry, 0, sizeof(r->pending_geometry));
    /* (0.13) the rumble: at this handle's first session, this program's values (0 unless it set
     * some) -- never an earlier program's. Never at a later one: a flush keeps the rumble, and an
     * input thread may be writing these words (h264ring_rumble) beside it */
    if (!r->rum_taken) {
        for (unsigned k = 0; k < 3; k++)
            ctrl_lo_store(r, H264RING_W_RUMBLE + k, r->rum[k]);
        r->rum_taken = 1;
    }
    /* (fixed 2026-10-06 on the rig) a misaligned stale write index rounded down to 16 -- where the core
     * starts reading -- before the nonce: the core checks the write index's alignment at every poll of
     * the session, and this program stores its own only with its first record, so a cold boot's random
     * DDR3 (the first power-up after .201 was moved) put every session in WIDX_ALIGN at once and nothing
     * ever played. An aligned index (any earlier program's) is left as it is: no race with a core still
     * reading behind it */
    {
        uint32_t wi = ctrl_lo(r, H264RING_W_WRITE_INDEX);
        if (wi & 15u)
            ctrl_lo_store(r, H264RING_W_WRITE_INDEX, wi & ~15u);
    }
    r->be.barrier(r->be.user);
    ctrl_lo_store(r, H264RING_W_NONCE, nonce);        /* the nonce ALONE starts the session */
    r->be.barrier(r->be.user);
    t0 = now_us(r);
    for (;;) {
        if (h264ring_status(r, &st) == 0 && (uint32_t)H264RING_ST(&st, ACK_NONCE) == nonce) {
            r->nonce = nonce;
            r->w = (uint32_t)H264RING_ST(&st, READ_INDEX);   /* where the core starts reading */
            r->seq = 0;
            r->need_disc = 0;
            r->session = 1;
            /* (0.15) a new stream: the stores are this program's once a status copy shows the
             * reset done (READY); none is in use */
            r->pic_ok = 1;
            r->pic_base_ok = 0;
            r->pic_sent = 0;
            r->pic_used = 0;
            r->pic_next = 0;
            ovl_write(r, r->ovl_on);                  /* (0.9) publish only after the core reset: this
                                                         program's overlay, or none, never a prior page */
            if (saved_geometry.width || saved_geometry.height || saved_geometry.x || saved_geometry.y) {
                if ((rc = h264ring_set_geometry(r, &saved_geometry, timeout_ms)) != 0)
                    return rc;
            }
            return 0;
        }
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u)
            return -ETIMEDOUT;
        nap(r, 1000);
    }
}

int h264ring_start_session(h264ring *r, unsigned timeout_ms)
{
    int rc = h264ring_alive(r, timeout_ms);
    return rc ? rc : new_session(r, timeout_ms);
}

static int geometry_valid(const struct h264ring_geometry *g)
{
    if (!g) return 0;
    if (!g->x && !g->y && !g->width && !g->height && !g->clip_x && !g->clip_y &&
        !g->clip_width && !g->clip_height) return 1; /* clear */
    if (g->x < -4096 || g->x > 4095 || g->y < -4096 || g->y > 4095 ||
        g->width == 0 || g->width > 8191 || g->height == 0 || g->height > 8191 ||
        (g->x & 1) || (g->y & 1) || (g->width & 1u) || (g->height & 1u)) return 0;
    if (g->clip_width == 0 || g->clip_height == 0 || g->clip_x > 720 || g->clip_y > 576 ||
        g->clip_width > 720 || g->clip_height > 576 ||
        g->clip_x + g->clip_width > 720 || g->clip_y + g->clip_height > 576 ||
        (g->clip_x & 1u) || (g->clip_y & 1u) || (g->clip_width & 1u) || (g->clip_height & 1u)) return 0;
    return 1;
}

int h264ring_set_geometry(h264ring *r, const struct h264ring_geometry *g, unsigned timeout_ms)
{
    struct h264ring_status st;
    uint64_t t0, clip, request;
    uint8_t seq;
    int rc;
    if (!r || !geometry_valid(g)) return -EINVAL;
    if (r->interface_version < 0x102u) return -ENOTSUP;
    if (!r->session) return -ENOTCONN;
    if (r->geometry_pending) {
        if (memcmp(&r->pending_geometry, g, sizeof(*g)) != 0) return -EBUSY;
        seq = r->geometry_seq;
    } else {
        if ((rc = h264ring_status(r, &st))) return rc;
        seq = (uint8_t)((uint8_t)H264RING_ST(&st, GEOMETRY_ACK_SEQ) + 1u);
        if (!seq) seq = 1;
        clip = (uint64_t)g->clip_x | ((uint64_t)g->clip_y << 12) |
               ((uint64_t)g->clip_width << 24) | ((uint64_t)g->clip_height << 36);
        request = (uint64_t)seq << H264RING_GEOMETRY_SEQ_LSB;
        if (g->width || g->height || g->x || g->y) {
            request |= ((uint64_t)((uint32_t)g->x & 0x1FFFu) << H264RING_GEOMETRY_X_LSB) |
                       ((uint64_t)((uint32_t)g->y & 0x1FFFu) << H264RING_GEOMETRY_Y_LSB) |
                       ((uint64_t)g->width << H264RING_GEOMETRY_W_LSB) |
                       ((uint64_t)g->height << H264RING_GEOMETRY_H_LSB);
        }
        ctrl_lo_store(r, H264RING_W_GEOMETRY_CLIP, (uint32_t)clip); /* viewport first */
        ((volatile uint32_t *)(r->be.ctrl + H264RING_W_GEOMETRY_CLIP))[1] = (uint32_t)(clip >> 32);
        r->be.barrier(r->be.user);
        ctrl_lo_store(r, H264RING_W_GEOMETRY, (uint32_t)request);
        r->be.barrier(r->be.user);
        ((volatile uint32_t *)(r->be.ctrl + H264RING_W_GEOMETRY))[1] = (uint32_t)(request >> 32); /* seq commits */
        r->be.barrier(r->be.user);
        r->geometry_seq = seq;
        r->geometry_pending = 1;
        r->pending_geometry = *g;
    }
    t0 = now_us(r);
    for (;;) {
        if ((rc = h264ring_status(r, &st)) == 0 &&
            (uint8_t)H264RING_ST(&st, GEOMETRY_ACK_SEQ) == seq) {
            unsigned err = (unsigned)H264RING_ST(&st, GEOMETRY_ERROR);
            r->geometry_pending = 0;
            if (err == 0) { r->geometry = *g; return 0; }
            return err == 1 ? -ERANGE : -EPROTO;
        }
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u) return -ETIMEDOUT;
        nap(r, 1000);
    }
}

/* a seek or a switch that must not wait for what is queued: a new session drops every
 * record not yet read, and resets the stream (decoder, pictures waiting, display) */
int h264ring_flush(h264ring *r, unsigned timeout_ms)
{
    if (!r->session)
        return -ENOTCONN;
    return new_session(r, timeout_ms);
}

int h264ring_session_ok(h264ring *r)
{
    return r->session && ctrl_hi(r, 5) == r->nonce;
}

uint32_t h264ring_free(h264ring *r)
{
    uint32_t used = r->w - ctrl_lo(r, 5);     /* read_index: one aligned 32-bit load */
    return used > r->be.ring_size ? 0 : r->be.ring_size - used;
}

/* one record at the write position; the index is published by the caller */
static void put_record(h264ring *r, unsigned type, unsigned flags, uint64_t pts,
                       const uint8_t *p, uint32_t len, unsigned colour)
{
    uint32_t n = 16u + ((len + 15u) & ~15u);
    uint64_t w0 = (uint64_t)(type & 0xFFu) | ((uint64_t)(flags & 0xFFu) << 8) |
                  ((uint64_t)r->seq << 16) | ((uint64_t)len << 32);
    uint64_t w1 = (pts & ((1ull << 33) - 1u)) | ((uint64_t)(colour & 7u) << H264RING_HDR_COLOUR_LSB) |
                  ((uint64_t)H264RING_SYNC << 48);      /* (0.16) [35:33] the colour code */
    uint32_t at = r->w;
    ring_store(r, at, w0);
    ring_store(r, at + 8u, w1);
    for (uint32_t off = 0; type != H264RING_T_PAD && off < n - 16u; off += 8u) {   /* a PAD's payload is never read */
        uint64_t v = 0;
        if (p && off < len) {
            uint32_t k = len - off < 8u ? len - off : 8u;
            uint8_t b[8] = {0, 0, 0, 0, 0, 0, 0, 0};
            memcpy(b, p + off, k);                    /* into a LOCAL word, never the mapping */
            for (int i = 7; i >= 0; i--)
                v = (v << 8) | b[i];
        }
        ring_store(r, at + 16u + off, v);
    }
    r->w = at + n;
    r->seq = (uint16_t)(r->seq + 1u);
}

/* (fj#20) the CAVLC -> CABAC rewrite of one VIDEO_AU: *out / *out_len the bytes to write (the
 * input itself for CABAC, or the rewrite), cached so a retry or a write after
 * h264ring_prepare_au() costs a compare. disc: the unit starts a new stream */
static int rewrite_au(h264ring *r, const uint8_t *in, uint32_t len, int disc, const uint8_t **out,
                      uint32_t *out_len)
{
    const uint8_t *o;
    size_t on;
    int rc;
    *out = in;
    *out_len = len;
    if (r->rewrite_off)
        return 0;
    if (r->rc_valid && r->rc_in_n == len && memcmp(r->rc_in, in, len) == 0) {
        *out = r->rc_out;
        *out_len = (uint32_t)r->rc_out_n;
        return 0;
    }
    r->rc_valid = 0;
    if (!r->cv && !(r->cv = h264ring_cavlc_new()))
        return -ENOMEM;
    if (disc)
        h264ring_cavlc_reset(r->cv);
    rc = h264ring_cavlc_au(r->cv, in, len, &o, &on);
    if (rc == H264RING_CAVLC_REFUSED)
        return -EOPNOTSUPP;
    if (rc == H264RING_CAVLC_ERROR)
        return -EBADMSG;
    if (rc == H264RING_CAVLC_REWRITTEN) {
        if (on > H264RING_MAX_PAYLOAD)
            return -EMSGSIZE;
        if (len > r->rc_in_cap) {
            uint8_t *c = (uint8_t *)realloc(r->rc_in, len);
            if (!c)
                return -ENOMEM;
            r->rc_in = c;
            r->rc_in_cap = len;
        }
        memcpy(r->rc_in, in, len);
        r->rc_in_n = len;
        r->rc_out = o;
        r->rc_out_n = on;
        r->rc_valid = 1;
        *out = o;
        *out_len = (uint32_t)on;
    }
    return 0;
}

int h264ring_prepare_au(h264ring *r, const void *au, uint32_t len, unsigned flags)
{
    const uint8_t *o;
    uint32_t on;
    if (!au || len == 0)
        return -EINVAL;
    return rewrite_au(r, (const uint8_t *)au, len, (flags & H264RING_F_DISCONTINUITY) || r->need_disc, &o, &on);
}

void h264ring_set_rewrite(h264ring *r, int on)
{
    r->rewrite_off = !on;
    r->rc_valid = 0;
}

const char *h264ring_rewrite_why(const h264ring *r)
{
    return r->cv ? h264ring_cavlc_why(r->cv) : "";
}

void h264ring_rewrite_stats(const h264ring *r, struct h264ring_cavlc_stats *st)
{
    if (r->cv)
        h264ring_cavlc_get_stats(r->cv, st);
    else
        memset(st, 0, sizeof *st);
}

/* (0.16) the colour code a record carries: a VIDEO_AU the stream's (h264ring_set_colour), a PICTURE its own */
static int try_write_c(h264ring *r, unsigned type, unsigned flags, int64_t pts, const void *payload, uint32_t len,
                       unsigned colour);

int h264ring_try_write(h264ring *r, unsigned type, unsigned flags, int64_t pts,
                       const void *payload, uint32_t len)
{
    return try_write_c(r, type, flags, pts, payload, len, type == H264RING_T_VIDEO_AU ? r->colour : 0u);
}

int h264ring_set_colour(h264ring *r, unsigned code)
{
    if (!r || code > H264RING_COLOUR_2020_FULL)
        return -EINVAL;
    r->colour = code;
    return 0;
}

static int try_write_c(h264ring *r, unsigned type, unsigned flags, int64_t pts, const void *payload, uint32_t len,
                       unsigned colour)
{
    uint32_t n, to_end, pad, need, state;
    unsigned allowed;
    if (!r->session)
        return -ENOTCONN;
    if (type == H264RING_T_VIDEO_AU || type == H264RING_T_PICTURE)    /* 0.15: a PICTURE takes the same */
        allowed = H264RING_F_PTS_VALID | H264RING_F_DISCONTINUITY | H264RING_F_END_OF_STREAM | H264RING_F_LOW_LATENCY |
                  H264RING_F_GRAPHICS;                                   /* 0.4 */
    else if (type == H264RING_T_AUDIO)
        allowed = H264RING_F_PTS_VALID;
    else
        return -EINVAL;                   /* PAD is the library's; CONTROL is reserved */
    if (pts >= 0)
        flags |= H264RING_F_PTS_VALID;
    if ((type == H264RING_T_VIDEO_AU || type == H264RING_T_PICTURE) && r->need_disc)
        flags |= H264RING_F_DISCONTINUITY;
    if ((flags & ~allowed) || (pts >= 0 && pts >= (1ll << 33)) || (type == H264RING_T_VIDEO_AU && len == 0) ||
        (type == H264RING_T_AUDIO && (len == 0 || (len & 3u))) ||     /* 0.5: whole 4-byte frames */
        (type == H264RING_T_PICTURE && (len != H264RING_PIC_PAYLOAD || !payload)))   /* 0.15: the descriptor */
        return -EINVAL;
    if (type == H264RING_T_PICTURE) {    /* 0.15: the stores are this program's only in a picture stream */
        if (!r->pic_ok)
            return -EBUSY;
        if (!r->pic_base_ok)
            return -EINVAL;               /* h264ring_picture_acquire first: it numbers the pictures */
    }
    if (type == H264RING_T_VIDEO_AU) {   /* (fj#20) CAVLC -> CABAC; audio never touches the rewrite */
        const uint8_t *o;
        uint32_t on;
        int rc = rewrite_au(r, (const uint8_t *)payload, len, (flags & H264RING_F_DISCONTINUITY) != 0, &o, &on);
        if (rc)
            return rc;
        payload = o;
        len = on;
    }
    n = 16u + ((len + 15u) & ~15u);
    if (len > H264RING_MAX_PAYLOAD || n > r->be.ring_size)
        return -EMSGSIZE;
    state = ctrl_lo(r, 4) & 0xFFu;
    if (state == H264RING_S_ERROR)
        return -EPROTO;
    if (ctrl_hi(r, 5) != r->nonce) {
        r->session = 0;                   /* an OSD Reset, or another program: start again */
        return -ENOTCONN;
    }
    to_end = r->be.ring_size - (r->w & (r->be.ring_size - 1u));
    pad = n > to_end ? to_end : 0u;
    if (pad) {
        /* the PAD goes out on its own as soon as it fits: a record plus the PAD before it can
         * need more than the whole ring, and waiting for both at once would never end */
        if (pad > h264ring_free(r))
            return -EAGAIN;
        put_record(r, H264RING_T_PAD, 0, 0, NULL, to_end - 16u, 0u);   /* its payload is never read */
        r->be.barrier(r->be.user);
        ctrl_lo_store(r, H264RING_W_WRITE_INDEX, r->w);
        r->be.barrier(r->be.user);
    }
    need = n;
    if (need > h264ring_free(r))
        return -EAGAIN;
    put_record(r, type, flags, pts >= 0 ? (uint64_t)pts : 0u, (const uint8_t *)payload, len, colour);
    r->be.barrier(r->be.user);            /* the record before the index that publishes it */
    ctrl_lo_store(r, H264RING_W_WRITE_INDEX, r->w);
    r->be.barrier(r->be.user);
    if (type == H264RING_T_VIDEO_AU || type == H264RING_T_PICTURE) {
        if (type == H264RING_T_VIDEO_AU) {
            r->rc_valid = 0;              /* written: the next unit is a new one */
            r->pic_ok = 0;                /* (0.15) a coded stream: the stores are the decoder's */
        } else {                          /* (0.15) the store rule: this store's picture's number */
            unsigned k = ((const uint8_t *)payload)[0] & 31u;
            r->pic_used |= 1u << k;
            r->pic_ord[k] = r->pic_base + ++r->pic_sent;
        }
        if (flags & H264RING_F_END_OF_STREAM)
            r->need_disc = 1;
        else if (flags & H264RING_F_DISCONTINUITY)
            r->need_disc = 0;
    }
    return 0;
}

int h264ring_try_write_au(h264ring *r, const void *au, uint32_t len, int64_t pts, unsigned flags)
{
    return h264ring_try_write(r, H264RING_T_VIDEO_AU, flags, pts, au, len);
}

/* ------------------------------------------------------------------ (0.15) pictures
 * docs/architecture.md "Pictures from the program": the store's layout, the store rule, the
 * descriptor. */
int h264ring_picture_layout(const struct h264ring_picture *p, struct h264ring_pic_layout *l)
{
    unsigned w, hf, pair;
    if (!p || !l || p->width == 0 || p->height == 0 || p->width > 16u * H264RING_PIC_MAX_SIDE ||
        p->height > 16u * H264RING_PIC_MAX_SIDE || p->structure > H264RING_PIC_STRUCT_PAIR_BOT ||
        p->colour > H264RING_COLOUR_2020_FULL)        /* (0.16) */
        return -EINVAL;
    pair = p->structure != H264RING_PIC_STRUCT_FRAME;
    if (pair ? p->pic_struct != -1
             : !(p->pic_struct == -1 || p->pic_struct == 0 || (p->pic_struct >= 3 && p->pic_struct <= 8)))
        return -EINVAL;
    w = (p->width + 15u) / 16u;
    hf = pair ? 2u * ((p->height + 31u) / 32u) : (p->height + 15u) / 16u;   /* a pair: whole field macroblocks */
    if (w > H264RING_PIC_MAX_SIDE || hf > H264RING_PIC_MAX_SIDE || w * hf > H264RING_CAP_MAX_MBS)
        return -EINVAL;
    l->w_mbs = w;
    l->hf_mbs = hf;
    l->y_stride = 16u * w;
    l->c_stride = 8u * w;
    l->cb_off = 256u * w * hf;
    l->cr_off = 320u * w * hf;
    l->bytes = 384u * w * hf;
    l->crop_r = (16u * w - p->width) / 2u;           /* an odd remainder shows one replicated column */
    l->crop_b = (16u * hf - p->height) / 2u;
    return 0;
}

volatile uint64_t *h264ring_picture_store(h264ring *r, unsigned k)
{
    if (!r || !r->be.stores || k >= H264RING_DPB_STORES)
        return NULL;
    return r->be.stores + (size_t)k * (H264RING_DPB_STORE / 8u);
}

int h264ring_picture_acquire(h264ring *r, unsigned *k)
{
    struct h264ring_status st;
    uint32_t held, emitted, cap;
    int rc;
    if (!r->be.stores)
        return -ENODEV;
    if (!r->session)
        return -ENOTCONN;
    if (!r->pic_ok)
        return -EBUSY;                    /* a coded stream since the last flush: the decoder's stores */
    if ((rc = h264ring_status(r, &st)))
        return rc;
    if ((uint32_t)H264RING_ST(&st, ACK_NONCE) != r->nonce) {
        r->session = 0;
        return -ENOTCONN;
    }
    if (H264RING_ST(&st, STATE) == H264RING_S_ERROR)
        return -EPROTO;
    held = (uint32_t)H264RING_ST(&st, PIC_HELD);
    emitted = (uint32_t)H264RING_ST(&st, PIC_EMITTED);
    cap = (uint32_t)H264RING_ST(&st, CAP_PIC_STORES);
    if (cap > H264RING_DPB_STORES)
        cap = H264RING_DPB_STORES;
    if (cap == 0)
        return -EAGAIN;                   /* no status frame yet */
    if (!r->pic_base_ok) {
        /* the numbering starts at a copy that shows the stream reset done: READY (no video record
         * since it) -- before it, the previous stream's decoder or display may still hold a store */
        if (H264RING_ST(&st, STATE) != H264RING_S_READY)
            return -EAGAIN;
        r->pic_base = emitted;
        r->pic_base_ok = 1;
    }
    for (uint32_t i = 0; i < cap; i++) {
        unsigned c = (r->pic_next + i) % cap;
        if (!((r->pic_used >> c) & 1u) ||
            ((int32_t)(emitted - r->pic_ord[c]) >= 0 && !((held >> c) & 1u))) {
            *k = c;
            r->pic_next = (c + 1u) % cap;
            return 0;
        }
    }
    return -EAGAIN;
}

/* the last source row of row y's parity (a pair's fields stay apart) or the last row */
static unsigned src_row(unsigned y, unsigned n, int pair)
{
    if (y < n)
        return y;
    if (!pair || n < 2)
        return n - 1u;
    return (((n - 1u) ^ y) & 1u) ? n - 2u : n - 1u;
}

/* BT.601 full range -> limited: 16 + (m v + 127) / 255, m 219 (luma, 16-235) or 224 (chroma, 16-240).
 * (x + 1 + (x >> 8)) >> 8 is x / 255 exactly for every x it meets here (m v + 127 <= 57,247; checked
 * for each v): no division, and it fits a 16-bit lane, so NEON does eight at once (docs/uvc.md U2) */
static inline uint8_t to_limited(unsigned v, unsigned m)
{
    unsigned x = m * v + 127u;
    return (uint8_t)(16u + ((x + 1u + (x >> 8)) >> 8));
}

/* one store row of dw bytes (a multiple of 8) from source row a -- or the rounded average of a and
 * b -- of sw samples, the last sample replicated, converted full -> limited range when m (219 / 224).
 * Assembled into a local word, one aligned 64-bit store each (little-endian: the ARM and the host).
 * The words wholly inside the source take a loop per case with no per-sample clamp (NEON on the ARM:
 * vrhadd is (a + b + 1) >> 1 exactly, to_limited lane by lane); the rest (the edge replicated) the
 * general one. Same bytes on every path: hps/tests/run_copy_arm.sh compares the ARM's NEON build
 * with its scalar one on the rig, and the host tests score the scalar one against a model.
 * (docs/uvc.md U2: a full-range 4:2:2 MJPEG camera at 640x480 cost 14.3 ms a picture through the
 * general loop alone -- 0.42 of the A9 at 30 frames/s, on the core it shares with everything else.) */
static void put_row(volatile uint64_t *d, unsigned dw, const uint8_t *a, const uint8_t *b, unsigned sw,
                    unsigned m)
{
    unsigned x = 0, in = sw & ~7u;
    uint8_t t[8];
    uint64_t v;
    if (in > dw)
        in = dw;
#if defined(__ARM_NEON) && !defined(H264RING_NO_NEON)
    if (b || m) {
        const uint8x8_t k = vdup_n_u8((uint8_t)m);
        for (; x < in; x += 8u) {
            uint8x8_t s = vld1_u8(a + x);
            if (b)
                s = vrhadd_u8(s, vld1_u8(b + x));
            if (m) {
                uint16x8_t y = vmlal_u8(vdupq_n_u16(127), s, k);
                y = vaddq_u16(vaddq_u16(y, vshrq_n_u16(y, 8)), vdupq_n_u16(1));
                s = vadd_u8(vshrn_n_u16(y, 8), vdup_n_u8(16));
            }
            d[x >> 3] = vget_lane_u64(vreinterpret_u64_u8(s), 0);
        }
    }
#endif
    if (!b && !m)
        for (; x < in; x += 8u) {
            memcpy(&v, a + x, 8);
            d[x >> 3] = v;
        }
    else
        for (; x < in; x += 8u) {
            for (unsigned i = 0; i < 8u; i++) {
                unsigned c = b ? (a[x + i] + b[x + i] + 1u) >> 1 : a[x + i];
                t[i] = m ? to_limited(c, m) : (uint8_t)c;
            }
            memcpy(&v, t, 8);
            d[x >> 3] = v;
        }
    for (; x < dw; x += 8u) {
        for (unsigned i = 0; i < 8u; i++) {
            unsigned sx = x + i < sw ? x + i : sw - 1u;
            unsigned s = b ? (a[sx] + b[sx] + 1u) >> 1 : a[sx];
            t[i] = m ? to_limited(s, m) : (uint8_t)s;
        }
        memcpy(&v, t, 8);
        d[x >> 3] = v;
    }
}

int h264ring_picture_copy(volatile uint64_t *store, const struct h264ring_picture *p,
                          const uint8_t *const planes[3], const int strides[3], unsigned fmt)
{
    struct h264ring_pic_layout l;
    unsigned cw, chs, pair, c422, full, pfull, my, mc;
    if (!store || !p || !planes || !strides || fmt > H264RING_PIX_YUVJ422P || h264ring_picture_layout(p, &l) ||
        !planes[0] || !planes[1] || !planes[2])
        return -EINVAL;
    full = fmt == H264RING_PIX_YUVJ420P || fmt == H264RING_PIX_YUVJ422P;
    c422 = fmt == H264RING_PIX_YUV422P || fmt == H264RING_PIX_YUVJ422P;
    pair = p->structure != H264RING_PIC_STRUCT_FRAME;
    /* (0.16, docs/colour.md D-C8) a picture whose code says full range keeps its samples: the core converts
     * them. Otherwise a full-range source is converted to limited here, as 0.15 did (the matrix unchanged). */
    pfull = p->colour == H264RING_COLOUR_601_FULL || p->colour == H264RING_COLOUR_709_FULL ||
            p->colour == H264RING_COLOUR_2020_FULL;
    if (pfull && !full)
        return -EINVAL;                               /* a limited-range source with a full-range code */
    my = full && !pfull ? 219u : 0u;                  /* full range -> limited (16-235 / 16-240) */
    mc = full && !pfull ? 224u : 0u;
    for (unsigned y = 0; y < 16u * l.hf_mbs; y++)
        put_row(store + (size_t)y * (l.y_stride / 8u), l.y_stride,
                planes[0] + (size_t)src_row(y, p->height, pair) * strides[0], NULL, p->width, my);
    cw = (p->width + 1u) / 2u;
    chs = c422 ? p->height : (p->height + 1u) / 2u;  /* the source's chroma rows */
    for (unsigned c = 1; c <= 2; c++) {
        volatile uint64_t *d = store + (c == 1 ? l.cb_off : l.cr_off) / 8u;
        for (unsigned y = 0; y < 8u * l.hf_mbs; y++) {
            const uint8_t *a, *b = NULL;
            if (!c422)
                a = planes[c] + (size_t)src_row(y, chs, pair) * strides[c];
            else {                                    /* 4:2:2 -> 4:2:0: two rows a row, a field's own */
                unsigned r0 = pair ? 4u * (y >> 1) + (y & 1u) : 2u * y;
                unsigned r1 = pair ? r0 + 2u : r0 + 1u;
                a = planes[c] + (size_t)src_row(r0, chs, pair) * strides[c];
                b = planes[c] + (size_t)src_row(r1, chs, pair) * strides[c];
            }
            put_row(d + (size_t)y * (l.c_stride / 8u), l.c_stride, a, b, cw, mc);
        }
    }
    return 0;
}

static uint64_t gcd64(uint64_t a, uint64_t b)
{
    while (b) {
        uint64_t t = a % b;
        a = b;
        b = t;
    }
    return a;
}

/* a / b in at most `bits` bits each, never 0 */
static void ratio_fit(uint64_t a, uint64_t b, unsigned bits, uint32_t *oa, uint32_t *ob)
{
    uint64_t g = gcd64(a, b), lim = (1ull << bits) - 1u;
    a /= g;
    b /= g;
    while (a > lim || b > lim) {
        a = (a + 1u) / 2u;
        b = (b + 1u) / 2u;
    }
    *oa = (uint32_t)(a ? a : 1u);
    *ob = (uint32_t)(b ? b : 1u);
}

int h264ring_try_write_picture(h264ring *r, unsigned k, const struct h264ring_picture *p, int64_t pts,
                               unsigned flags)
{
    struct h264ring_pic_layout l;
    uint64_t d[4];
    uint8_t b[32];
    uint32_t sw = 0, sh = 0, nuit = 0, ts = 0;
    unsigned idc = 0, tv = 0;
    if (k >= H264RING_DPB_STORES || h264ring_picture_layout(p, &l))
        return -EINVAL;
    if (p->sar_w && p->sar_h) {
        ratio_fit(p->sar_w, p->sar_h, 16, &sw, &sh);
        idc = 255;                        /* Extended_SAR (H.264 Table E-1) */
    }
    if (p->rate_num && p->rate_den) {     /* frames a second = time_scale / (2 num_units_in_tick) */
        uint32_t two_num;
        ratio_fit(2ull * p->rate_num, p->rate_den, 32, &two_num, &nuit);
        ts = two_num;
        tv = 1;
    }
    d[0] = (uint64_t)k | ((uint64_t)l.w_mbs << 8) | ((uint64_t)l.hf_mbs << 16) | ((uint64_t)p->structure << 24) |
           (p->pic_struct >= 0 ? (((uint64_t)p->pic_struct << 32) | (1ull << 36)) : 0u) | ((uint64_t)idc << 40);
    d[1] = (uint64_t)sw | ((uint64_t)sh << 16) | ((uint64_t)tv << 32);
    d[2] = (uint64_t)nuit | ((uint64_t)ts << 32);
    d[3] = ((uint64_t)l.crop_r << 10) | ((uint64_t)l.crop_b << 30);   /* left and top 0 */
    for (unsigned i = 0; i < 32u; i++)
        b[i] = (uint8_t)(d[i / 8u] >> (8u * (i % 8u)));
    return try_write_c(r, H264RING_T_PICTURE, flags, pts, b, sizeof b, p->colour);   /* (0.16) its own code */
}

int h264ring_write_picture(h264ring *r, unsigned k, const struct h264ring_picture *p, int64_t pts,
                           unsigned flags, unsigned timeout_ms)
{
    uint64_t t0 = now_us(r);
    for (;;) {
        int rc = h264ring_try_write_picture(r, k, p, pts, flags);
        if (rc != -EAGAIN)
            return rc;
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u)
            return -ETIMEDOUT;
        nap(r, 500);
    }
}

int h264ring_write_au(h264ring *r, const void *au, uint32_t len, int64_t pts, unsigned flags,
                      unsigned timeout_ms)
{
    uint64_t t0 = now_us(r);
    for (;;) {
        int rc = h264ring_try_write_au(r, au, len, pts, flags);
        if (rc != -EAGAIN)
            return rc;
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u)
            return -ETIMEDOUT;
        nap(r, 500);
    }
}

int h264ring_try_write_audio(h264ring *r, const void *pcm, uint32_t len, int64_t pts)
{
    return h264ring_try_write(r, H264RING_T_AUDIO, 0, pts, pcm, len);
}

int h264ring_write_audio(h264ring *r, const void *pcm, uint32_t len, int64_t pts, unsigned timeout_ms)
{
    uint64_t t0 = now_us(r);
    for (;;) {
        int rc = h264ring_try_write_audio(r, pcm, len, pts);
        if (rc != -EAGAIN)
            return rc;
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u)
            return -ETIMEDOUT;
        nap(r, 500);
    }
}

/* ---- the overlay plane (interface 0.9, program words 72-79) ---- */
int h264ring_overlay_check(const struct h264ring_overlay *o)
{
    uint32_t bpp, end;
    if (!o || o->format > H264RING_OVL_FMT_8888)
        return H264RING_OVL_E_CTL;
    if (o->width < 1 || o->width > H264RING_OVL_MAX_W || o->height < 1 || o->height > H264RING_OVL_MAX_H)
        return H264RING_OVL_E_SIZE;
    bpp = o->format == H264RING_OVL_FMT_8888 ? 4u : 2u;
    if (o->stride % 8u || o->stride < o->width * bpp)
        return H264RING_OVL_E_STRIDE;
    if (o->base % 8u)
        return H264RING_OVL_E_ALIGN;
    if (o->band_first > o->band_last || o->band_last >= o->height)
        return H264RING_OVL_E_BAND;
    end = (uint32_t)(o->height - 1u) * o->stride + o->width * bpp;       /* < 576 x 65,536: no overflow */
    if (o->base < H264RING_FB_BYTE || o->base > H264RING_FB_BYTE + H264RING_FB_SIZE ||
        end > H264RING_FB_BYTE + H264RING_FB_SIZE - o->base)
        return H264RING_OVL_E_RANGE;
    return H264RING_OVL_E_NONE;
}

/* the descriptor under a new generation: gen_hi (79) FIRST, the fields, gen_lo (72) LAST --
 * the core's burst reads 72 first and 79 last, and takes the words only when the two agree */
static int ovl_write(h264ring *r, int on)
{
    const struct h264ring_overlay *o = &r->ovl;
    uint32_t g = r->ovl_gen = (r->ovl_gen + 1u) & 0x7FFFFFFFu;
    if (g == 0)
        g = r->ovl_gen = 1;
    ctrl_lo_store(r, H264RING_W_OVL_GEN_HI, g);
    r->be.barrier(r->be.user);
    ctrl_lo_store(r, H264RING_W_OVL_CTL, on ? (1u << H264RING_OVL_CTL_ENABLE_BIT) |
                                              ((uint32_t)o->format << H264RING_OVL_CTL_FMT_LSB) : 0u);
    ctrl_lo_store(r, H264RING_W_OVL_BASE, on ? o->base : 0u);
    ctrl_lo_store(r, H264RING_W_OVL_SIZE, on ? ((uint32_t)o->height << 16) | o->width : 0u);
    ctrl_lo_store(r, H264RING_W_OVL_STRIDE, on ? o->stride : 0u);
    ctrl_lo_store(r, H264RING_W_OVL_BAND, on ? ((uint32_t)o->band_last << 16) | o->band_first : 0u);
    ctrl_lo_store(r, H264RING_W_OVL_RSVD, 0u);
    r->be.barrier(r->be.user);
    ctrl_lo_store(r, H264RING_W_OVL_GEN_LO, g);
    r->be.barrier(r->be.user);
    return (int)g;
}

int h264ring_overlay_show(h264ring *r, const struct h264ring_overlay *o)
{
    if (!r || h264ring_overlay_check(o))
        return -EINVAL;
    r->ovl = *o;
    r->ovl_on = 1;
    return ovl_write(r, 1);
}

int h264ring_overlay_hide(h264ring *r)
{
    if (!r)
        return -EINVAL;
    r->ovl_on = 0;
    return ovl_write(r, 0);
}

int h264ring_overlay_wait(h264ring *r, int gen, unsigned timeout_ms)
{
    struct h264ring_status st;
    uint64_t t0;
    if (!r || gen <= 0)
        return -EINVAL;
    t0 = now_us(r);
    for (;;) {
        /* at or past gen: every session start re-writes the program's descriptor with a newer
         * generation, so after a flush the one waited for may never be reported itself */
        if (h264ring_status(r, &st) == 0 &&
            (int32_t)((uint32_t)H264RING_ST(&st, OVL_GEN) - (uint32_t)gen) >= 0)
            return H264RING_ST(&st, OVL_STATE) == H264RING_OVL_S_REFUSED ? -EPROTO : 0;
        if (now_us(r) - t0 > (uint64_t)timeout_ms * 1000u)
            return -ETIMEDOUT;
        nap(r, 1000);
    }
}

/* ---- the pause and the volume (interface 0.5, program word 34: [0] PAUSE, [15:8] ATTEN) ---- */
int h264ring_set_pause(h264ring *r, int paused)
{
    if (!r)
        return -EINVAL;
    r->ctl = (r->ctl & ~(1u << H264RING_CTL_PAUSE_BIT)) | ((paused ? 1u : 0u) << H264RING_CTL_PAUSE_BIT);
    ctrl_lo_store(r, H264RING_W_PAUSE, r->ctl);
    return 0;
}

int h264ring_set_atten(h264ring *r, unsigned half_db)
{
    if (!r || half_db > 255u)
        return -EINVAL;
    r->ctl = (r->ctl & ~(0xFFu << H264RING_CTL_ATTEN_LSB)) | (half_db << H264RING_CTL_ATTEN_LSB);
    ctrl_lo_store(r, H264RING_W_PAUSE, r->ctl);
    return 0;
}

/* ---- the rumble (interface 0.13, program words 36-38: two pads a u32, {large, small}) ---- */
static void rum_write(h264ring *r, unsigned pad, uint16_t v)
{
    unsigned k = pad / 2u, sh = 16u * (pad & 1u);
    r->rum_val[pad] = v;
    r->rum_at[pad] = now_us(r);
    r->rum[k] = (r->rum[k] & ~(0xFFFFu << sh)) | ((uint32_t)v << sh);
    ctrl_lo_store(r, H264RING_W_RUMBLE + k, r->rum[k]);   /* one aligned store: both pads at once */
}

int h264ring_rumble(h264ring *r, unsigned pad, unsigned large, unsigned small)
{
    uint16_t v;
    if (!r || pad >= H264RING_RUMBLE_PADS || large > 255u || small > 255u)
        return -EINVAL;
    v = (uint16_t)((large << H264RING_RUMBLE_LARGE_LSB) | small);
    r->rum_want[pad] = v;
    if (v != r->rum_val[pad])
        rum_write(r, pad, v);
    return 0;
}

/* Main plays a value for 32.767 s and re-uploads it only when it changes: a pad held at one
 * nonzero value for H264RING_RUMBLE_KEEPALIVE_MS is written one step away from it (the large
 * motor's lowest bit, the small's when the large is 0; 1 alternates with 2: never 0), then back */
static unsigned rum_step(unsigned x)
{
    return (x ^ 1u) ? (x ^ 1u) : 2u;
}

int h264ring_rumble_keepalive(h264ring *r)
{
    int n = 0;
    uint64_t now;
    if (!r)
        return -EINVAL;
    now = now_us(r);
    for (unsigned pad = 0; pad < H264RING_RUMBLE_PADS; pad++) {
        unsigned want = r->rum_want[pad], large = want >> H264RING_RUMBLE_LARGE_LSB, small = want & 0xFFu;
        uint16_t alt;
        if (!want || now - r->rum_at[pad] < (uint64_t)H264RING_RUMBLE_KEEPALIVE_MS * 1000u)
            continue;
        alt = (uint16_t)(large ? ((rum_step(large) << H264RING_RUMBLE_LARGE_LSB) | small)
                               : rum_step(small));
        rum_write(r, pad, r->rum_val[pad] == want ? alt : (uint16_t)want);
        n++;
    }
    return n;
}

void h264ring_close(h264ring *r)
{
    if (!r)
        return;
    if (r->rum_taken)                                 /* (0.13) this program's rumble stops with it */
        for (unsigned k = 0; k < 3; k++)
            ctrl_lo_store(r, H264RING_W_RUMBLE + k, 0);
    if (r->release)
        r->release(r);
    h264ring_cavlc_free(r->cv);
    free(r->rc_in);
    free(r);
}

void h264ring_raster(const struct h264ring_status *st, struct h264ring_raster *rs)
{
    rs->w = (unsigned)H264RING_ST(st, RASTER_W);
    rs->h = (unsigned)H264RING_ST(st, RASTER_H);
    rs->mode = (unsigned)H264RING_ST(st, RASTER_MODE);
    rs->interlaced = (int)H264RING_ST(st, RASTER_IL);
    rs->ar_x = (unsigned)H264RING_ST(st, AR_X);
    rs->ar_y = (unsigned)H264RING_ST(st, AR_Y);
    rs->aspect = (!rs->interlaced && rs->ar_x && rs->ar_y) ? (double)rs->ar_x / (double)rs->ar_y : 4.0 / 3.0;
    rs->lb = (int)H264RING_ST(st, RASTER_LB);
    unsigned x0 = (unsigned)H264RING_ST(st, PIC_X0), y0 = (unsigned)H264RING_ST(st, PIC_Y0);
    rs->pic_x0 = (x0 & 0x1000u) ? (int)x0 - 0x2000 : (int)x0;              /* 13-bit two's complement */
    rs->pic_y0 = (y0 & 0x1000u) ? (int)y0 - 0x2000 : (int)y0;
    rs->pic_w = (unsigned)H264RING_ST(st, FIT_OW);
    rs->pic_h = (unsigned)H264RING_ST(st, FIT_OH);
}

void h264ring_caps(const struct h264ring_status *st, struct h264ring_caps *c)
{
    c->max_mbs = (unsigned)H264RING_ST(st, CAP_MAX_MBS);
    c->mb_rate = (unsigned)H264RING_ST(st, CAP_MB_RATE);
    c->native_h = (unsigned)H264RING_ST(st, CAP_NATIVE_H);
    if (!c->max_mbs || !c->mb_rate || !c->native_h) {   /* no status frame yet: 0.10's limits */
        c->max_mbs = 1620;
        c->mb_rate = 97200;
        c->native_h = 480;
    }
}

unsigned h264ring_video_out(const struct h264ring_status *st)
{
    unsigned v = (unsigned)H264RING_ST(st, VIDEO_OUT);           /* (0.14) as resolved */
    if (v) return v;
    v = (unsigned)H264RING_ST(st, OSD_VIDEO_OUT);                 /* before 0.14: the menu's ... */
    if (v) return v;
    return H264RING_ST(st, RASTER_IL) ? H264RING_VOUT_INTERLACED : H264RING_VOUT_PROGRESSIVE;   /* ... Auto */
}

const char *h264ring_state_name(unsigned s)
{
    static const char *const names[] = {"UNWRITTEN", "NO_SESSION", "READY", "PLAYING", "ENDED", "ERROR"};
    return s < sizeof(names) / sizeof(names[0]) ? names[s] : "?";
}

const char *h264ring_error_name(unsigned e)
{
    static const char *const names[] = {"NONE", "WIDX_ALIGN", "WIDX_RANGE", "HDR_SYNC", "HDR_TYPE",
                                        "HDR_FLAGS", "HDR_LENGTH", "HDR_WRAP", "HDR_SEQ",
                                        "NEED_DISCONT", "CONTROL_UNSUPPORTED",
                                        "STREAM_KIND", "PIC_FIELD", "PIC_STORE", "PIC_SIZE", "PIC_CROP",
                                        "PIC_BUSY",                       /* 0.15 (missing here until 0.16) */
                                        "HDR_COLOUR"};                    /* 0.16 */
    return e < sizeof(names) / sizeof(names[0]) ? names[e] : "?";
}

/* the refusal codes (word 18's FE_REFUSED_CODE): h264/dec/h264_pkg.sv's REF_*, in order */
const char *h264ring_refusal_name(unsigned code)
{
    static const char *const names[] = {
        "none", "chroma format (not 4:2:0)", "bit depth (not 8)", "scaling lists",
        "MBAFF interlacing", "CAVLC (not CABAC)", "FMO (slice groups)", "8x8 transform",
        "redundant pictures", "SP / SI slices", "data partitioning", "SVC / MVC",
        "picture dimension (more than 128 macroblocks)",
    };
    return code < sizeof(names) / sizeof(names[0]) ? names[code] : "?";
}

/* ---- the core's OSD settings (interface 0.4, docs/architecture.md: the settings request) ----
 * One u32 store into program word 35: the values in the mirror's order (word 27 [44:32],
 * shifted down by 32), the mask at REQ_MASK_LSB, the sequence number at REQ_SEQ_LSB. */
int h264ring_request_settings(h264ring *r, unsigned mask, const unsigned values[H264RING_OPT_COUNT])
{
    static const unsigned width[H264RING_OPT_COUNT] = {2, 2, 2, 1, 2, 2, 2};
    static const unsigned count[H264RING_OPT_COUNT] = {3, 3, 4, 2, 4, 4, 3};   /* (0.10) Video Output: + Native (HDMI) */
    uint32_t word = 0;
    unsigned lsb = 0;
    if (!r || !values || mask == 0 || mask >> H264RING_OPT_COUNT)
        return -EINVAL;
    if (!r->session)
        return -ENOTCONN;
    for (unsigned i = 0; i < H264RING_OPT_COUNT; i++) {
        if (mask >> i & 1u) {
            if (values[i] >= count[i])
                return -EINVAL;
            word |= (uint32_t)values[i] << lsb;
        }
        lsb += width[i];
    }
    r->set_seq = (uint8_t)(r->set_seq == 255 ? 1 : r->set_seq + 1);    /* 1..255: 0 is "no request" */
    word |= (uint32_t)mask << H264RING_REQ_MASK_LSB;
    word |= (uint32_t)r->set_seq << H264RING_REQ_SEQ_LSB;
    ctrl_lo_store(r, H264RING_W_SETTINGS, word);
    r->set_word = word;
    return r->set_seq;
}

int h264ring_request_display(h264ring *r, unsigned mask, unsigned profile,
                            unsigned match, unsigned lowres, unsigned film)
{
    if (!r || !mask || (mask & ~15u) || ((mask & 1) && profile > 4) ||
        ((mask & 2) && match > 2) || ((mask & 4) && lowres > 1) ||
        ((mask & 8) && film > 1)) return -EINVAL;
    if (!r->session) return -ENOTCONN;
    if (r->interface_version < 0x103) return -ENOTSUP;
    uint32_t word = (1u << 23) | (mask << H264RING_REQ_MASK_LSB);
    if (mask & 1) word |= profile;
    if (mask & 2) {
        word |= (match != 0) << 3; /* preserve the interface 1.3 enabled bit */
        /* new clients leave bit 6 clear; the core accepts it as a legacy 50/60 marker */
    }
    if (mask & 4) word |= lowres << 4;
    if (mask & 8) word |= film << 5;
    r->set_seq = (uint8_t)(r->set_seq == 255 ? 1 : r->set_seq + 1);
    word |= (uint32_t)r->set_seq << H264RING_REQ_SEQ_LSB;
    ctrl_lo_store(r, H264RING_W_SETTINGS, word);
    r->set_word = word;
    return r->set_seq;
}

int h264ring_clear_settings(h264ring *r)
{
    if (!r)
        return -EINVAL;
    ctrl_lo_store(r, H264RING_W_SETTINGS, 0);
    r->set_word = 0;
    return 0;
}
