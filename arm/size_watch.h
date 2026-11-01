/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_SIZE_WATCH_H
#define JFPLAY_SIZE_WATCH_H
/* The size watch: whether the core is dropping the stream's pictures as too
 * large. A picture over the core's macroblock bound (word 81's cap_max_mbs)
 * whose sides are both within 128 macroblocks passes the SPS, and the core
 * then discards every slice of it: nothing is shown, no refusal code is
 * raised, and only RC_REF_SIZE (status word 20) counts. An Intel hardware
 * transcode at 720p, coded 1280x736, did that against the 3,600 bound.
 *
 * It takes RC_REF_SIZE once a status poll. Every picture of such a stream is
 * refused, so the counter climbs at the frame rate: a rise on SIZE_WATCH_RISES
 * polls in a row triggers. A poll where it stays or falls (paused, or the
 * core reset it with the stream at a start or seek) starts the count again. */

#define SIZE_WATCH_RISES 2u

struct size_watch {
    int seen;
    unsigned last, rises;
};

/* One poll's RC_REF_SIZE; returns 1 when the core is dropping the stream as too large. */
static inline int size_watch_sample(struct size_watch *w, unsigned ref_size)
{
    w->rises = w->seen && ref_size > w->last ? w->rises + 1 : 0;
    w->seen = 1;
    w->last = ref_size;
    return w->rises >= SIZE_WATCH_RISES;
}
#endif
