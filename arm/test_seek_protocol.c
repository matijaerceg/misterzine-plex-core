/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>

#include "seek_protocol.h"

int main(void)
{
    int phase = 0;
    assert(!seek_protocol_can_process(1, phase));
    assert(seek_protocol_next(phase, 0, 1, 0) == 0); /* reader not parked */
    phase = seek_protocol_next(phase, 1, 1, 0);
    assert(phase == 1); /* flush/reset is now safe */
    assert(!seek_protocol_can_process(1, phase));
    assert(seek_protocol_next(phase, 1, 1, 0) == 1); /* awaiting reader ack */
    phase = seek_protocol_next(phase, 0, 0, 0);
    assert(phase == 2); /* new timeline can enter decoder */
    assert(seek_protocol_can_process(1, phase));
    assert(seek_protocol_next(1, 0, 0, -1) == -1); /* failed demux seek */
    assert(seek_protocol_can_process(0, 0)); /* normal playback */
    puts("seek protocol state transitions OK");
    return 0;
}
