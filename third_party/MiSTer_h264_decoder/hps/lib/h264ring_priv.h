/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring_priv.h -- the library's handle (not part of the interface). */
#ifndef H264RING_PRIV_H
#define H264RING_PRIV_H
#include "h264ring.h"

struct h264ring {
    struct h264ring_backend be;
    uint16_t interface_version; /* core's version; 1.2-only calls check this individually */
    uint32_t w;          /* the write index (free-running bytes) */
    uint16_t seq;        /* the next record's sequence number */
    uint32_t nonce;      /* this program's session */
    int session;         /* a session was acknowledged */
    int need_disc;       /* END_OF_STREAM written: the next access unit carries DISCONTINUITY */
    unsigned colour;     /* (0.16) the colour code every VIDEO_AU carries (h264ring_set_colour; 0 auto) */
    uint8_t set_seq;     /* the last settings request's sequence number (interface 0.4) */
    uint32_t set_word;   /* word 35 as THIS program last wrote it (0: no request): re-written at each
                            session's start, never a previous program's (found 2026-10-02) */
    uint8_t geometry_seq; /* last geometry request sequence (interface 1.2) */
    uint8_t geometry_pending; /* request was committed but its ACK did not arrive before a timeout */
    struct h264ring_geometry pending_geometry;
    struct h264ring_geometry geometry; /* this program's saved request, reapplied on session start */
    uint32_t ctl;        /* word 34 as this program wants it: PAUSE, ATTEN (interface 0.5) */
    uint32_t ovl_gen;    /* the overlay descriptor's last generation (interface 0.9) */
    int ovl_on;          /* ... shown: ovl is this program's (re-written at every session's start) */
    struct h264ring_overlay ovl;
    /* (0.13) the rumble: words 36-38 as this program last wrote them (pad n in rum[n / 2] at bit
     * 16 (n % 2)); each pad's value asked for, as written (want, or the keepalive's step from it),
     * and when it was written (now_us); rum_taken: the words were written at this handle's first
     * session (h264ring_close then zeroes them) */
    uint32_t rum[3];
    uint16_t rum_want[H264RING_RUMBLE_PADS], rum_val[H264RING_RUMBLE_PADS];
    uint64_t rum_at[H264RING_RUMBLE_PADS];
    int rum_taken;
    /* the CAVLC -> CABAC rewrite of every VIDEO_AU (h264ring_cavlc.h, fj#20): created on the first
     * one, reset with the stream (a session, a flush, a DISCONTINUITY) */
    struct h264ring_cavlc *cv;
    int rewrite_off;     /* h264ring_set_rewrite(r, 0): access units written as given */
    /* the last unit rewritten and not yet written (a retry after -EAGAIN, or h264ring_prepare_au):
     * a COPY of its input -- programs reuse one buffer for every unit, so a pointer proves
     * nothing -- and the rewrite's output (the context's buffer, valid until its next call) */
    uint8_t *rc_in;
    size_t rc_in_n, rc_in_cap;
    const uint8_t *rc_out;
    size_t rc_out_n;
    int rc_valid;
    /* (0.15) pictures from the program: the store rule (docs/architecture.md "Pictures from the
     * program"). pic_ok: a session start or flush since the last VIDEO_AU (the stores are this
     * program's); pic_base_ok / pic_base: word 84's pic_emitted in the first status copy after it
     * that shows READY (the stream reset done); pic_sent: PICTURE records written since; a store
     * used since (pic_used) is free again when a status copy shows pic_emitted - pic_ord[k] >= 0
     * and its pic_held bit clear */
    int pic_ok, pic_base_ok;
    uint32_t pic_base, pic_sent, pic_used;
    uint32_t pic_ord[H264RING_DPB_STORES];
    unsigned pic_next;
    /* devmem only (released by `release`, set by h264ring_open_devmem) */
    void (*release)(struct h264ring *r);
    int mem_fd, lock_fd;
    void *map;
    size_t map_len;
    void *smap;          /* (0.15) the stores' mapping (H264RING_OPEN_PICTURES) */
    size_t smap_len;
};

#endif
