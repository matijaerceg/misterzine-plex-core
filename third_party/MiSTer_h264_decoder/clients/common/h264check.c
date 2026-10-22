/* h264check -- the SPS / PPS fields that decide whether the core decodes a stream (h264check.h).
 * The parse follows H.264 7.3.2.1.1 / 7.3.2.2 up to the fields it needs. */
#include <string.h>
#include "h264check.h"

#define MAX_MBS 3600u   /* the 0.11 core's picture bound (Level 3.1's MaxFS), when the caller sets none */
#define MB_RATE 108000u /* ... and its macroblock rate (Level 3.1's MaxMBPS) */

struct bits {
    uint8_t buf[256];   /* the RBSP (emulation prevention removed), the first bytes are enough */
    size_t n, pos;      /* bytes, bit position */
    int bad;
};

static void rbsp(struct bits *b, const uint8_t *p, size_t len)
{
    unsigned zeros = 0;
    b->n = b->pos = 0;
    b->bad = 0;
    for (size_t i = 0; i < len && b->n < sizeof b->buf; i++) {
        if (zeros >= 2 && p[i] == 3) { zeros = 0; continue; }   /* emulation_prevention_three_byte */
        zeros = p[i] == 0 ? zeros + 1 : 0;
        b->buf[b->n++] = p[i];
    }
}

static unsigned u1(struct bits *b)
{
    if (b->pos >= b->n * 8) { b->bad = 1; return 0; }
    unsigned v = (b->buf[b->pos >> 3] >> (7 - (b->pos & 7))) & 1u;
    b->pos++;
    return v;
}

static unsigned un(struct bits *b, unsigned n)
{
    unsigned v = 0;
    while (n--) v = v << 1 | u1(b);
    return v;
}

static unsigned ue(struct bits *b)
{
    unsigned lz = 0;
    while (!u1(b) && !b->bad) if (++lz > 31) { b->bad = 1; return 0; }
    return lz ? ((1u << lz) - 1 + un(b, lz)) : 0;
}

static int se(struct bits *b)
{
    unsigned k = ue(b);
    return (k & 1) ? (int)((k + 1) / 2) : -(int)(k / 2);
}

static void scaling_list(struct bits *b, unsigned size)
{
    int last = 8, next = 8;
    for (unsigned j = 0; j < size; j++) {
        if (next) next = (last + se(b) + 256) % 256;
        last = next ? next : last;
    }
}

static void parse_sps(struct h264check_state *s, struct bits *b)
{
    s->profile_idc = un(b, 8);
    un(b, 16);                              /* constraint flags, reserved, level_idc */
    ue(b);                                  /* seq_parameter_set_id */
    s->chroma_format_idc = 1;
    s->bit_depth_luma = s->bit_depth_chroma = 8;
    switch (s->profile_idc) {
    case 100: case 110: case 122: case 244: case 44: case 83: case 86: case 118: case 128:
    case 138: case 139: case 134: case 135:
        s->chroma_format_idc = ue(b);
        if (s->chroma_format_idc == 3) u1(b);              /* separate_colour_plane_flag */
        s->bit_depth_luma = ue(b) + 8;
        s->bit_depth_chroma = ue(b) + 8;
        u1(b);                                             /* qpprime_y_zero_transform_bypass_flag */
        if (u1(b))                                         /* seq_scaling_matrix_present_flag */
            for (unsigned i = 0; i < (s->chroma_format_idc != 3 ? 8u : 12u); i++)
                if (u1(b)) scaling_list(b, i < 6 ? 16 : 64);
        break;
    }
    ue(b);                                  /* log2_max_frame_num_minus4 */
    unsigned poc_type = ue(b);
    if (poc_type == 0) {
        ue(b);
    } else if (poc_type == 1) {
        u1(b); se(b); se(b);
        unsigned n = ue(b);
        for (unsigned i = 0; i < n && i < 256 && !b->bad; i++) se(b);
    }
    ue(b);                                  /* max_num_ref_frames */
    u1(b);                                  /* gaps_in_frame_num_value_allowed_flag */
    s->width_mbs = ue(b) + 1;
    s->height_map_units = ue(b) + 1;
    s->frame_mbs_only = u1(b);
    s->mbaff = s->frame_mbs_only ? 0 : u1(b);
    s->have_sps = !b->bad;
}

static void parse_pps(struct h264check_state *s, struct bits *b)
{
    ue(b);                                  /* pic_parameter_set_id */
    ue(b);                                  /* seq_parameter_set_id */
    s->entropy = u1(b);
    s->have_pps = !b->bad;
}

static enum h264check verdict(const struct h264check_state *s)
{
    if (!s->have_sps || !s->have_pps) return H264C_UNKNOWN;
    if (s->profile_idc != 66 && s->profile_idc != 77 && s->profile_idc != 88 &&
        s->profile_idc != 100 && s->profile_idc != 110 && s->profile_idc != 122 && s->profile_idc != 244)
        return H264C_PROFILE;
    if (s->chroma_format_idc != 1) return H264C_CHROMA;
    if (s->bit_depth_luma != 8 || s->bit_depth_chroma != 8) return H264C_BITDEPTH;
    if (s->mbaff) return H264C_MBAFF;
    unsigned frame_h = s->height_map_units * (s->frame_mbs_only ? 1u : 2u);
    unsigned long mbs = (unsigned long)s->width_mbs * frame_h;
    if (mbs > (s->max_mbs ? s->max_mbs : MAX_MBS)) return H264C_SIZE;
    /* the rate, from the container's frame rate (1 % over is rounding: 30 frames/s exactly is
     * Level 3.1's 108,000 at 720p): 720p60 decodes at half speed -- refused, not played so */
    if (s->fps > 0 && (double)mbs * s->fps > 1.01 * (s->mb_rate ? s->mb_rate : MB_RATE)) return H264C_RATE;
    /* last: since interface 0.10 the library's write call rewrites CAVLC into CABAC, so a program
     * that lets it through (the file player) must still see every reason the rewrite cannot cure */
    if (!s->entropy) return H264C_CAVLC;
    return H264C_OK;
}

enum h264check h264check_au(struct h264check_state *s, const uint8_t *au, size_t len)
{
    size_t i = 0;
    while (i + 3 < len) {
        /* the next start code */
        if (!(au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1)) { i++; continue; }
        size_t start = i + 3, end = start;
        while (end + 2 < len && !(au[end] == 0 && au[end + 1] == 0 && (au[end + 2] == 1 || au[end + 2] == 0)))
            end++;
        if (end + 2 >= len) end = len;
        if (start < end) {
            unsigned type = au[start] & 0x1F;
            struct bits b;
            if (type == 7 && !s->have_sps) { rbsp(&b, au + start + 1, end - start - 1); parse_sps(s, &b); }
            if (type == 8 && !s->have_pps) { rbsp(&b, au + start + 1, end - start - 1); parse_pps(s, &b); }
        }
        i = end;
    }
    return verdict(s);
}

const char *h264check_name(enum h264check c)
{
    switch (c) {
    case H264C_OK: return "decodable";
    case H264C_CAVLC: return "CAVLC (not CABAC)";
    case H264C_MBAFF: return "MBAFF";
    case H264C_CHROMA: return "chroma format (not 4:2:0)";
    case H264C_BITDEPTH: return "bit depth (not 8)";
    case H264C_SIZE: return "picture size (larger than 1280x720)";
    case H264C_PROFILE: return "profile";
    case H264C_RATE: return "frame rate (more than 1280x720 at 30 or 854x480 at 60 frames/s)";
    default: return "unknown";
    }
}
