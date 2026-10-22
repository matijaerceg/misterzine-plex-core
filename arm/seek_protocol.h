/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_SEEK_PROTOCOL_H
#define JFPLAY_SEEK_PROTOCOL_H

/* reset_done phases used by the worker: 0 waits for reader park, 1 waits for
 * demux acknowledgement, 2 allows the new timeline to reach the decoder. */
static inline int seek_protocol_next(int phase, int reader_parked,
                                     int request_pending, int seek_rc)
{
    if (phase == 0) return reader_parked ? 1 : 0;
    if (phase == 1) {
        if (request_pending) return 1;
        return seek_rc < 0 ? -1 : 2;
    }
    return phase;
}

static inline int seek_protocol_can_process(int seeking, int phase)
{
    return !seeking || phase >= 2;
}

#endif
