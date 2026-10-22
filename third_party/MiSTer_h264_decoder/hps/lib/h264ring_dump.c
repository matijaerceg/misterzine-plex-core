/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring_dump.c -- the status block as text: one JSON object (h264stat --json, the
 * HIL harness) or name=value lines, every field of the generated table (h264ring_layout.h),
 * so a field added in tools/ring_layout.py is printed without touching this file.
 */
#include <stdio.h>
#include "h264ring.h"

static const struct h264ring_field fields[] = H264RING_FIELDS;

void h264ring_dump(FILE *f, const struct h264ring_status *st, int json)
{
    unsigned i;
    unsigned state = (unsigned)H264RING_ST(st, STATE), err = (unsigned)H264RING_ST(st, ERR);
    if (json)
        fprintf(f, "{\"state_name\":\"%s\",\"err_name\":\"%s\"", h264ring_state_name(state),
                h264ring_error_name(err));
    else
        fprintf(f, "state %s  err %s\n", h264ring_state_name(state), h264ring_error_name(err));
    for (i = 0; i < H264RING_NFIELDS; i++) {
        uint64_t v = h264ring_get(st->w, fields[i].word, fields[i].lsb, fields[i].width);
        if (json)
            fprintf(f, ",\"%s\":%llu", fields[i].name, (unsigned long long)v);
        else
            fprintf(f, "%-16s %llu\n", fields[i].name, (unsigned long long)v);
    }
    if (json)
        fprintf(f, "}\n");
}
