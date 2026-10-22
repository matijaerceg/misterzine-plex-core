/* h264check -- what the server cannot see (docs/jellyfin.md S2 "The client's check"): from an
 * access unit's SPS / PPS, whether the core will decode the stream. Jellyfin never reads a PPS
 * (CABAC is invisible to it) and cannot tell MBAFF from PAFF, so the client checks before the
 * first access unit reaches the ring and asks for a transcode instead of a refusal. */
#ifndef CLIENT_H264CHECK_H
#define CLIENT_H264CHECK_H

#include <stddef.h>
#include <stdint.h>

enum h264check {
    H264C_UNKNOWN = 0,      /* no SPS and PPS in what was seen yet */
    H264C_OK,
    H264C_CAVLC,            /* entropy_coding_mode_flag 0 (Baseline, or a CAVLC Main / High); said
                               only when nothing below is (the library's write call can rewrite it
                               since 0.10: a program that allows it must still be told the rest) */
    H264C_MBAFF,            /* mb_adaptive_frame_field_flag 1 */
    H264C_CHROMA,           /* not 4:2:0 */
    H264C_BITDEPTH,         /* not 8 bits */
    H264C_SIZE,             /* more than max_mbs macroblocks a picture (0.11: 3,600, 1280x720) */
    H264C_PROFILE,          /* a profile the core does not decode (SVC / MVC, ...) */
    H264C_RATE,             /* (0.11) more than mb_rate macroblocks a second (720p at 60 frames/s) */
};

struct h264check_state {
    /* the core's limits, set before the first h264check_au (h264ring_caps, interface 0.11; 0: the
     * 0.11 core's 3,600 / 108,000) and the stream's frame rate (the container's; 0 unknown: no
     * rate check -- a raw .264 has none) */
    unsigned max_mbs, mb_rate;
    double fps;
    int have_sps, have_pps;
    unsigned profile_idc, chroma_format_idc, bit_depth_luma, bit_depth_chroma;
    unsigned frame_mbs_only, mbaff, width_mbs, height_map_units, entropy;
};

/* feed one Annex-B access unit; returns the verdict once both an SPS and a PPS were seen
 * (H264C_UNKNOWN before that). Only the first SPS / PPS of each is used. */
enum h264check h264check_au(struct h264check_state *s, const uint8_t *au, size_t len);
const char *h264check_name(enum h264check c);

#endif
