#include "size_watch.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    struct size_watch w = {0};
    /* A stream inside the bound: the counter never moves. */
    for (int i = 0; i < 20; i++) assert(!size_watch_sample(&w, 0));
    /* A status frame left from before the stream's reset, then the reset:
       neither is a rise. */
    w = (struct size_watch){0};
    assert(!size_watch_sample(&w, 40));
    assert(!size_watch_sample(&w, 0));
    assert(!size_watch_sample(&w, 0));
    /* Every picture refused: two rises in a row trigger. */
    assert(!size_watch_sample(&w, 7));
    assert(size_watch_sample(&w, 14));
    /* Paused between the rises: the count starts again. */
    w = (struct size_watch){0};
    assert(!size_watch_sample(&w, 0));
    assert(!size_watch_sample(&w, 6));
    assert(!size_watch_sample(&w, 6));
    assert(!size_watch_sample(&w, 12));
    assert(size_watch_sample(&w, 19));
    /* A seek resets the counter between the rises. */
    w = (struct size_watch){0};
    assert(!size_watch_sample(&w, 0));
    assert(!size_watch_sample(&w, 5));
    assert(!size_watch_sample(&w, 0));
    assert(!size_watch_sample(&w, 3));
    assert(size_watch_sample(&w, 9));
    puts("size watch checks passed");
}
