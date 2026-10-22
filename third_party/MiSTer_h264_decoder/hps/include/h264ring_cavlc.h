/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* h264ring_cavlc.h -- CAVLC streams for a core that decodes CABAC only (fj#20).
 *
 * The core decodes Main and High profile streams coded with CABAC. A stream coded with
 * CAVLC (entropy_coding_mode_flag 0: Constrained Baseline phone and web video, x264's
 * ultrafast preset, which a CPU-limited server may use for a transcode) is refused by the
 * core. This filter rewrites such a stream into CABAC on the ARM, access unit by access unit,
 * before it is written to the ring: the same syntax elements re-entropy-coded, so the
 * pictures are bit-exact. The ring, its records and the core do not change.
 *
 * The client library's write calls do this by themselves (below: "In the write call"); the
 * context on its own is for a program that wants the rewrite outside them:
 *
 *   h264ring_cavlc *cv = h264ring_cavlc_new();
 *   for each access unit (h264ring_split_annexb):
 *       const uint8_t *au; size_t len;
 *       switch (h264ring_cavlc_au(cv, in, in_len, &au, &len)) {
 *       case H264RING_CAVLC_PASS:       // CABAC already: au == in, nothing copied
 *       case H264RING_CAVLC_REWRITTEN:  // au = the rewritten unit, valid until the next call
 *           h264ring_write_au(r, au, len, pts, flags, timeout); break;
 *       case H264RING_CAVLC_REFUSED:    // a feature Main / High cannot carry (FMO, ASO, ...):
 *       case H264RING_CAVLC_ERROR:      // the stream cannot be played; h264ring_cavlc_why()
 *           ...
 *       }
 *   h264ring_cavlc_free(cv);
 *
 * Call it on every access unit of a stream, CABAC or not: CABAC units pass through untouched
 * (parameter sets and slice headers are read, nothing is copied), so a program need not
 * know in advance. Call h264ring_cavlc_reset() when a new, unrelated stream starts (it
 * forgets the parameter sets). Not thread-safe per context; contexts are independent.
 *
 * What is rewritten: each PPS's entropy_coding_mode_flag (0 -> 1); each SPS's profile_idc
 * 66 (Baseline) / 88 (Extended) -> 77 (Main), constraint_set0 / constraint_set2 cleared
 * (CABAC is not Baseline or Extended), constraint_set1 set for a former Baseline /
 * Extended stream; each slice of a CAVLC picture parameter set: cabac_init_idc (0) and the
 * alignment bits added to its header, its slice data re-coded (H.264 7.3.4 / 9.3), the
 * cabac_zero_words a picture needs (9.3.4.6) appended. Everything else is copied byte for
 * byte. Refused (H264RING_CAVLC_REFUSED, named by h264ring_cavlc_why()): what Main and High
 * cannot express -- slice groups (FMO), arbitrary slice order (ASO), redundant pictures,
 * data partitioning, SP / SI slices -- and what the core does not decode either: MBAFF,
 * chroma other than 4:2:0, more than 8 bits, the transform bypass. A malformed CAVLC slice
 * is an error (H264RING_CAVLC_ERROR): never passed through half-rewritten.
 *
 * Cost: ARM CPU (docs: the manual's integrating/ pages give the measured rate) and one
 * copy of each rewritten access unit; no added latency beyond the call itself.
 */
#ifndef H264RING_CAVLC_H
#define H264RING_CAVLC_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct h264ring_cavlc h264ring_cavlc;

enum h264ring_cavlc_result {
    H264RING_CAVLC_PASS = 0,        /* nothing to rewrite: *out == in */
    H264RING_CAVLC_REWRITTEN = 1,   /* *out: the rewritten access unit, until the next call */
    H264RING_CAVLC_REFUSED = 2,     /* a feature the core cannot be given: h264ring_cavlc_why() */
    H264RING_CAVLC_ERROR = 3,       /* malformed input or no memory: h264ring_cavlc_why() */
};

struct h264ring_cavlc_stats {
    uint64_t units;                 /* access units seen */
    uint64_t units_rewritten;
    uint64_t slices_rewritten;
    uint64_t slices_passed;         /* CABAC slices passed through */
    uint64_t mbs;                   /* macroblocks rewritten (skipped ones included) */
    uint64_t bins;                  /* CABAC bins written */
    uint64_t bytes_in;              /* of the rewritten slices, as received */
    uint64_t bytes_out;             /* of the rewritten slices, as written */
    uint64_t zero_words;            /* cabac_zero_words appended (9.3.4.6) */
    uint64_t t8_zero_blocks;        /* all-zero 8x8 blocks re-expressed (docs/cavlc.md) */
    uint64_t pcm_mbs;               /* I_PCM macroblocks (the engine restarted after each) */
    uint64_t p8x8ref0_mbs;          /* P_8x8ref0 macroblocks (coded as P_8x8, ref_idx 0) */
};

/* ---- In the write call (the usual way; interface 0.10) ----
 * h264ring_write_au() / h264ring_try_write_au() rewrite every access unit themselves: a program
 * sends CABAC or CAVLC as it has it. A CABAC unit passes untouched; a CAVLC one is rewritten
 * before it is queued. Two more results from the write calls:
 *   -EOPNOTSUPP  the rewrite refuses the stream (FMO, ASO, ...): h264ring_rewrite_why(r) says
 *                why. Nothing is written; the core's status block does NOT show it.
 *   -EBADMSG     a CAVLC unit that does not parse: h264ring_rewrite_why(r). Nothing is written;
 *                skip to the next IDR.
 * A retry of the same unit after -EAGAIN is not rewritten twice. The rewrite starts afresh with
 * each stream: a new session, h264ring_flush(), an access unit with DISCONTINUITY (also the one
 * after END_OF_STREAM). Its time is spent inside the write call; a program that paces its
 * writes calls h264ring_prepare_au() first (below). */
struct h264ring;
struct h264ring_cavlc_stats;
/* rewrite `au` now (the same flags the write will carry), so that writing the same bytes next
 * costs nothing: 0, -EOPNOTSUPP or -EBADMSG as above */
int h264ring_prepare_au(struct h264ring *r, const void *au, uint32_t len, unsigned flags);
/* 0: write every access unit as given (the core refuses CAVLC itself); 1 (default): rewrite */
void h264ring_set_rewrite(struct h264ring *r, int on);
/* why the last write / prepare returned -EOPNOTSUPP or -EBADMSG */
const char *h264ring_rewrite_why(const struct h264ring *r);
/* what the handle's rewrite did (all zero before the first access unit) */
void h264ring_rewrite_stats(const struct h264ring *r, struct h264ring_cavlc_stats *st);

/* ---- On its own (any buffer, any program; what the write call uses) ---- */
h264ring_cavlc *h264ring_cavlc_new(void);
void h264ring_cavlc_free(h264ring_cavlc *cv);
/* a new stream: forget the parameter sets and the picture in progress (the statistics stay) */
void h264ring_cavlc_reset(h264ring_cavlc *cv);
/* one Annex-B access unit (start codes included, as h264ring_split_annexb gives it) */
int h264ring_cavlc_au(h264ring_cavlc *cv, const uint8_t *in, size_t len,
                      const uint8_t **out, size_t *out_len);
/* why the last call refused or failed ("" after PASS / REWRITTEN) */
const char *h264ring_cavlc_why(const h264ring_cavlc *cv);
void h264ring_cavlc_get_stats(const h264ring_cavlc *cv, struct h264ring_cavlc_stats *st);

#ifdef __cplusplus
}
#endif

#endif
