#include "timing_watch.h"
#include <assert.h>
#include <stdio.h>

static int feed(struct timing_watch *w, unsigned num, unsigned den,
                int64_t start, double duration, int reorder)
{
    int bad = 0;
    for (unsigned i = 0; i < 64; ++i) {
        unsigned j = reorder ? (i ^ 1u) : i;
        /* Millisecond rounding, as used by Matroska. */
        int64_t pts = start + (int64_t)(j * duration / 90.0 + .5) * 90;
        bad |= timing_watch_sample(w, pts, num, den);
    }
    return bad;
}
int main(void)
{
    struct timing_watch w = {0};
    for (unsigned i = 0; i < 20; ++i)
        assert(!feed(&w, 24000, 1001, i * 64 * 3754LL, 3753.75, 1));
    timing_watch_reset(&w);
    assert(!feed(&w, 60000, 1001, 0, 1501.5, 1));
    assert(!feed(&w, 25, 1, 200000, 3600, 0));
    timing_watch_reset(&w);
    assert(feed(&w, 120, 1, 0, 3753.75, 1));
    timing_watch_reset(&w);
    assert(feed(&w, 30000, 1001, 0, 3753.75, 1));
    timing_watch_reset(&w);
    assert(!feed(&w, 24000, 1001, 0, 3753.75, 1));
    assert(feed(&w, 24000, 1001, 300000, 3003, 1));
    timing_watch_reset(&w);
    int hit = 0;
    for (unsigned i = 0; i < 128; ++i) {
        /* Half 24, half 30 in each window: persistent mixed timing. */
        unsigned n = i % 64;
        int64_t pts = (i / 64) * 220000LL + (n < 32 ? n * 3754LL : 32 * 3754LL + (n - 32) * 3003LL);
        hit |= timing_watch_sample(&w, pts, 24000, 1001);
        if (i < 127) assert(!hit);
    }
    assert(hit);
    timing_watch_reset(&w);
    for (unsigned i = 0; i < 64; ++i)
        assert(!timing_watch_sample(&w, i * 3754LL + (i == 30 ? 500 : 0), 24000, 1001));
    timing_watch_reset(&w);
    for (unsigned i = 0; i < 63; ++i) timing_watch_sample(&w, i * 3003LL, 24000, 1001);
    assert(!timing_watch_sample(&w, INT64_MIN, 24000, 1001));
    assert(w.count == 0 && w.bad_windows == 0);
    assert(!feed(&w, 24000, 1001, 100000000, 3753.75, 1));
    timing_watch_reset(&w);
    for (unsigned i = 0; i < 64; ++i)
        assert(!timing_watch_sample(&w, i * 3754LL + (i >= 32 ? 9000000 : 0), 24000, 1001));
    puts("timing watch PASS");
    return 0;
}
