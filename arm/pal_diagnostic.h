/* Diagnostic-only Annex B parameter-set capture. Never records slices, SEI,
 * URLs, tokens or audio. Bounds apply even to malformed/untrusted streams. */
#ifndef PAL_DIAGNOSTIC_H
#define PAL_DIAGNOSTIC_H
#include <stddef.h>
#include <stdint.h>
#include <string.h>
struct pal_headers { uint8_t last[2][512]; size_t len[2]; unsigned emitted; };
typedef void (*pal_header_log)(unsigned type, const uint8_t *data, size_t len);
static void pal_capture_headers(struct pal_headers *s, const uint8_t *p, size_t n,
                                pal_header_log emit)
{
    size_t start = 0;
    while (start + 3 < n && s->emitted < 16) {
        size_t at = start;
        for (; at + 3 < n; ++at)
            if (!p[at] && !p[at+1] && (p[at+2] == 1 || (!p[at+2] && p[at+3] == 1))) break;
        if (at + 3 >= n) break;
        size_t head = at + (p[at+2] == 1 ? 3 : 4), end = head;
        if (head >= n) break;
        for (; end + 3 < n; ++end)
            if (!p[end] && !p[end+1] && (p[end+2] == 1 || (!p[end+2] && p[end+3] == 1))) break;
        if (end + 3 >= n) end = n;
        unsigned type = p[head] & 31;
        if ((type == 7 || type == 8) && end-head <= 512) {
            unsigned slot = type-7; size_t len = end-head;
            if (len != s->len[slot] || memcmp(p+head, s->last[slot], len)) {
                memcpy(s->last[slot], p+head, len); s->len[slot] = len;
                ++s->emitted; emit(type, p+head, len);
            }
        }
        start = end;
    }
}
#endif
