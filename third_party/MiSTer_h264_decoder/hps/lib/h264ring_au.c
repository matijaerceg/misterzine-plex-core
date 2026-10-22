/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring_au.c -- Annex-B access units (the interface's rule: one VIDEO_AU record
 * carries exactly one complete access unit). Split as H.264 7.4.1.2.3 does for the streams
 * the core decodes: a new unit starts at an access unit delimiter, SPS, PPS, SEI or type
 * 14-18 NAL unit that follows a slice, and at a slice whose first_mb_in_slice is 0 (no
 * arbitrary slice order in Main / High). Start codes are part of the unit (a 4-byte one's
 * leading zero included). tools/tests/test_hps_lib.py checks it against ffprobe's parser.
 */
#include "h264ring.h"

size_t h264ring_split_annexb(const uint8_t *b, size_t n, struct h264ring_au *out, size_t cap)
{
    size_t i = 0, count = 0, cur = (size_t)-1;
    int vcl_seen = 0;
    while (i + 3 <= n) {
        size_t sc;
        uint8_t t;
        int new_au = 0;
        if (!(b[i] == 0 && b[i + 1] == 0 && b[i + 2] == 1)) { i++; continue; }
        sc = (i > 0 && b[i - 1] == 0) ? i - 1 : i;
        if (i + 3 >= n)
            break;
        t = b[i + 3] & 0x1F;
        if (cur == (size_t)-1)
            new_au = 1;
        else if (vcl_seen && (t == 9 || t == 7 || t == 8 || t == 6 || (t >= 14 && t <= 18)))
            new_au = 1;
        else if (vcl_seen && (t == 1 || t == 5) && i + 4 < n && (b[i + 4] & 0x80))
            new_au = 1;                                  /* first_mb_in_slice ue(v) == 0 */
        if (new_au) {
            if (cur != (size_t)-1) {
                if (out && count < cap) { out[count].off = (uint32_t)cur; out[count].len = (uint32_t)(sc - cur); }
                count++;
            }
            cur = sc;
            vcl_seen = 0;
        }
        if (t == 1 || t == 5)
            vcl_seen = 1;
        i += 3;
    }
    if (cur != (size_t)-1 && cur < n) {
        if (out && count < cap) { out[count].off = (uint32_t)cur; out[count].len = (uint32_t)(n - cur); }
        count++;
    }
    return count;
}
