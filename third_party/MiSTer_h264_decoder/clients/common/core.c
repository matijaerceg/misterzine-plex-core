/* core -- holding the H264 core (core.h). */
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include "core.h"

#define LAUNCH_MS   15000   /* loading the core and its first heartbeat */
#define SESSION_MS  2000    /* the core's acknowledgement of a session */
#define ALIVE_MS    1500    /* no heartbeat for this long: the core is not running */

uint64_t now_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000u + (uint64_t)ts.tv_nsec / 1000000u;
}

static void rebase(struct core *c)
{
    if (h264ring_status(c->r, &c->st) == 0) {
        c->have_st = 1;
        c->refused_base = (uint32_t)H264RING_ST(&c->st, FE_REFUSED);
        c->err_base = (uint32_t)(H264RING_ST(&c->st, FE_ERR) + H264RING_ST(&c->st, RC_ERR));
    }
}

#ifdef CLIENT_TEST
h264ring *client_test_ring;            /* the host test's ring, attached to its fake core (tests/) */
#endif

int core_open(struct core *c, const char *rbf) { return core_open2(c, rbf, 0); }

int core_open2(struct core *c, const char *rbf, unsigned open_flags)
{
    int rc;
    memset(c, 0, sizeof *c);
#ifdef CLIENT_TEST
    (void)rbf;
    (void)open_flags;                  /* the test's ring carries its stores (tests/) */
    c->r = client_test_ring;
    if (!c->r) return -ENODEV;
    if ((rc = h264ring_start_session(c->r, SESSION_MS))) return rc;
    c->sessions = 1;
    c->beat_ms = now_ms();
    rebase(c);
    return 0;
#endif
    if ((rc = h264ring_launch_core(rbf, LAUNCH_MS))) {
        fprintf(stderr, "core: the H264 core did not load (%s)\n", strerror(-rc));
        return rc;
    }
    if ((rc = h264ring_open_devmem(&c->r, open_flags))) {
        fprintf(stderr, "core: the core's interface: %s (another program holds it?)\n", strerror(-rc));
        return rc;
    }
    if ((rc = h264ring_alive(c->r, ALIVE_MS)) || (rc = h264ring_start_session(c->r, SESSION_MS))) {
        fprintf(stderr, "core: no session (%s)\n", strerror(-rc));
        return rc;
    }
    c->sessions = 1;
    c->beat_ms = now_ms();
    rebase(c);
    return 0;
}

int core_poll(struct core *c)
{
    if (c->gone) return -ENODEV;
    if (h264ring_status(c->r, &c->st)) return 0;      /* a torn copy: next loop */
    c->have_st = 1;
    uint32_t beat = (uint32_t)H264RING_ST(&c->st, SEQ_HEAD);
    if (beat != c->beat) {
        c->beat = beat;
        c->beat_ms = now_ms();
    } else if (now_ms() - c->beat_ms >= ALIVE_MS) {
        fprintf(stderr, "core: the H264 core is no longer running (another core was loaded)\n");
        c->gone = 1;
        return -ENODEV;
    }
    if (!h264ring_session_ok(c->r)) {                 /* an OSD Reset dropped it */
        int rc = h264ring_start_session(c->r, SESSION_MS);
        if (rc) {
            if (h264ring_alive(c->r, ALIVE_MS)) { c->gone = 1; return -ENODEV; }
            return 0;
        }
        c->sessions++;
        rebase(c);
    }
    return 0;
}

int core_new_stream(struct core *c)
{
    int rc = h264ring_flush(c->r, SESSION_MS);
    if (rc) fprintf(stderr, "core: flush: %s\n", strerror(-rc));
    rebase(c);
    return rc;
}

int core_refused(const struct core *c, const char **why)
{
    if (!c->have_st || (uint32_t)H264RING_ST(&c->st, FE_REFUSED) == c->refused_base) return 0;
    if (why) *why = h264ring_refusal_name((unsigned)H264RING_ST(&c->st, FE_REFUSED_CODE));
    return 1;
}

uint32_t core_errors(const struct core *c)
{
    return c->have_st ? (uint32_t)(H264RING_ST(&c->st, FE_ERR) + H264RING_ST(&c->st, RC_ERR)) - c->err_base : 0;
}

uint64_t core_stc(const struct core *c) { return c->have_st ? (uint64_t)H264RING_ST(&c->st, STC) : 0; }

int core_flag(const struct core *c, unsigned bit)
{
    return c->have_st && (H264RING_ST(&c->st, LIVE) & bit) != 0;
}

void core_close(struct core *c)
{
#ifndef CLIENT_TEST                    /* the test's ring is the harness's to close */
    if (c->r) h264ring_close(c->r);
#endif
    c->r = NULL;
}
