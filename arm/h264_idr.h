/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef JFPLAY_H264_IDR_H
#define JFPLAY_H264_IDR_H
#include <stddef.h>
#include <stdint.h>

/* Inspect framing as well as the NAL header. AVC length bytes can resemble an
 * Annex-B start code, so the caller must select the container's known framing. */
static inline int h264_nal_header(uint8_t header, int *idr)
{
    unsigned type = header & 31u;
    if ((header & 128u) || !type || type >= 24) return 0;
    if (type == 5) {
        if (!(header & 96u)) return 0;
        *idr = 1;
    }
    return 1;
}

static inline int h264_packet_idr(const uint8_t *data, size_t size, unsigned length_size)
{
    int idr = 0;
    if (!data || !size) return 0;
    if (length_size) {
        size_t at = 0;
        if (length_size > 4 || length_size == 3) return 0;
        while (at < size) {
            uint32_t length = 0;
            if (size - at < length_size) return 0;
            for (unsigned j = 0; j < length_size; ++j)
                length = (length << 8) | data[at++];
            if (!length || length > size - at || !h264_nal_header(data[at], &idr)) return 0;
            at += length;
        }
        return idr;
    }
    int found = 0;
    size_t zeros = 0;
    for (size_t at = 0; at < size; ++at) {
        if (!data[at]) { ++zeros; continue; }
        if (data[at] == 1 && zeros >= 2) {
            if (++at >= size || !h264_nal_header(data[at], &idr)) return 0;
            found = 1;
        } else if (!found) {
            return 0;
        }
        zeros = 0;
    }
    return found && idr;
}
#endif
