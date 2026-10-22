/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring_cavlc.c -- the CAVLC -> CABAC rewriter (fj#20; docs/cavlc.md, the manual's
 * integrating/ pages). Written from ITU-T H.264 (06/2026): 7.3 syntax, 9.2 CAVLC parsing,
 * 9.3 CABAC (9.3.2 binarisations, 9.3.3.1 ctxIdx derivations, 9.3.4 the encoding engine).
 * The CABAC derivations mirror tools/h264_fe_ref.py, the project's executable spec of the
 * decoding side, function for function (its names are given beside each one); the tables
 * come from h264ring_cavlc_tab.h, generated from the spec transcriptions in tools/.
 *
 * Shape: per access unit, each NAL unit is either copied (byte for byte, nothing copied at
 * all when the unit needs no change) or rewritten: SPS (profile / constraint flags), PPS
 * (entropy_coding_mode_flag), and a slice of a CAVLC PPS, whose CAVLC slice data is parsed
 * macroblock by macroblock and re-coded with CABAC in the same pass. The syntax order of a
 * macroblock is the same in both (7.3.5), so most syntax elements are coded as they are
 * parsed; from coded_block_pattern on, a macroblock's residual is parsed first, because an
 * 8x8 block CAVLC codes as all zero cannot be expressed in CABAC (no coded_block_flag for
 * ctxBlockCat 5 in 4:2:0) and changes what is coded before it (docs/cavlc.md S3).
 *
 * Neighbour state lives in a ring of PicWidthInMbs + 1 macroblocks (A is the previous slot,
 * B the next one), tagged with the macroblock address and a slice number, so availability
 * (6.4.x: the same slice) is a tag compare. Not MBAFF (refused).
 */
#include "h264ring_cavlc.h"
#include "h264ring_cavlc_tab.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CV_MAX_UNIT   (64u << 20)    /* the largest rewritten access unit: an error past it */
#define CV_MAX_MBS    139264u        /* Level 6.2 MaxFS (Table A-1): the largest picture */
#define CV_MAX_REFS   32u            /* num_ref_idx_lX_active_minus1 <= 31 (7.4.3) */

enum { ST_P = 0, ST_B = 1, ST_I = 2 };

/* ------------------------------------------------------------------ buffers */

struct buf { uint8_t *p; size_t n, cap; };

static int buf_grow(struct buf *b, size_t extra)
{
    size_t want;
    uint8_t *q;
    if (b->n + extra <= b->cap)
        return 0;
    if (b->n + extra > CV_MAX_UNIT + 64)
        return -1;
    want = b->cap ? b->cap : 65536;
    while (want < b->n + extra)
        want *= 2;
    q = (uint8_t *)realloc(b->p, want);
    if (!q)
        return -1;
    b->p = q;
    b->cap = want;
    return 0;
}

static int buf_put(struct buf *b, const uint8_t *p, size_t n)
{
    if (buf_grow(b, n))
        return -1;
    memcpy(b->p + b->n, p, n);
    b->n += n;
    return 0;
}

/* 7.4.1: emulation prevention removed; CV_PAD zero bytes after the RBSP (the reader's padding:
 * cavlc_block checks its position once per syntax element, at most ~60 bits apart) */
#define CV_PAD 64
static int unescape(struct buf *o, const uint8_t *p, size_t n)
{
    size_t i;
    unsigned zeros = 0;
    uint8_t *d;
    o->n = 0;
    if (buf_grow(o, n + CV_PAD))
        return -1;
    d = o->p;
    for (i = 0; i < n; i++) {
        uint8_t c = p[i];
        if (zeros >= 2 && c == 3) {
            zeros = 0;
            continue;
        }
        *d++ = c;
        zeros = c ? 0 : zeros + 1;
    }
    o->n = (size_t)(d - o->p);
    memset(d, 0, CV_PAD);
    return 0;
}

/* 7.4.1: an emulation_prevention_three_byte after two zeros before a byte <= 3, and after a
 * final zero byte (only cabac_zero_words end an RBSP with one) */
static int escape(struct buf *o, const uint8_t *p, size_t n)
{
    size_t i;
    unsigned zeros = 0;
    uint8_t *d;
    if (buf_grow(o, n + n / 2 + 4))
        return -1;
    d = o->p + o->n;
    for (i = 0; i < n; i++) {
        uint8_t c = p[i];
        if (zeros >= 2 && c <= 3) {
            *d++ = 3;
            zeros = 0;
        }
        *d++ = c;
        zeros = c ? 0 : zeros + 1;
    }
    if (n && p[n - 1] == 0)
        *d++ = 3;
    o->n = (size_t)(d - o->p);
    return 0;
}

/* ------------------------------------------------------------------ bit reader */

struct br { const uint8_t *p; uint32_t nbits, pos; int err; };

static inline uint32_t br_peek(const struct br *b)     /* 25 valid bits at least */
{
    const uint8_t *q = b->p + (b->pos >> 3);
    uint32_t v = (uint32_t)q[0] << 24 | (uint32_t)q[1] << 16 | (uint32_t)q[2] << 8 | q[3];
    return v << (b->pos & 7);
}

static inline void br_skip(struct br *b, unsigned n)
{
    b->pos += n;
    if (b->pos > b->nbits) {
        b->pos = b->nbits;
        b->err = 1;
    }
}

static inline uint32_t br_u(struct br *b, unsigned n)   /* n <= 25 */
{
    uint32_t v;
    if (!n)
        return 0;
    v = br_peek(b) >> (32 - n);
    br_skip(b, n);
    return v;
}

static uint32_t br_u32(struct br *b, unsigned n)        /* n <= 32 */
{
    if (n > 16) {
        uint32_t hi = br_u(b, n - 16);           /* sequenced: operand order is unspecified */
        return hi << 16 | br_u(b, 16);
    }
    return br_u(b, n);
}

static uint32_t br_ue(struct br *b)
{
    uint32_t v = br_peek(b);
    unsigned lz;
    if (v >= 0x00080000u) {                             /* at most 12 leading zeros */
        lz = (unsigned)__builtin_clz(v);
        br_skip(b, 2 * lz + 1);
        return (v >> (31 - 2 * lz)) - 1;
    }
    lz = 0;
    while (!br_u(b, 1)) {
        if (++lz > 31 || b->err) {
            b->err = 1;
            return 0;
        }
    }
    return ((1u << lz) - 1) + br_u32(b, lz);
}

static int32_t br_se(struct br *b)
{
    uint32_t k = br_ue(b);
    return (k & 1) ? (int32_t)((k + 1) >> 1) : -(int32_t)(k >> 1);
}

/* the position of the rbsp_stop_one_bit: more_rbsp_data() (7.2) is pos < it */
static uint32_t rbsp_stop(const uint8_t *p, size_t n)
{
    while (n && p[n - 1] == 0)
        n--;
    if (!n)
        return 0;
    return (uint32_t)(n * 8 - 1 - (unsigned)__builtin_ctz(p[n - 1]));
}

/* ------------------------------------------------------------------ bit writer */

struct bw { struct buf *b; uint32_t acc; unsigned nacc; int err; };

static inline void bw_byte(struct bw *w, uint8_t c)
{
    struct buf *b = w->b;
    if (b->n >= b->cap && buf_grow(b, 1)) {
        w->err = 1;
        return;
    }
    b->p[b->n++] = c;
}

static inline void bw_put(struct bw *w, uint32_t v, unsigned n)   /* n <= 24 */
{
    if (!n)
        return;
    w->acc = (w->acc << n) | (v & ((1u << n) - 1));
    w->nacc += n;
    while (w->nacc >= 8) {
        w->nacc -= 8;
        bw_byte(w, (uint8_t)(w->acc >> w->nacc));
    }
}

static void bw_ue(struct bw *w, uint32_t v)
{
    uint64_t x = (uint64_t)v + 1;
    unsigned nb = 64 - (unsigned)__builtin_clzll(x);
    unsigned z = nb - 1;
    while (z > 16) {
        bw_put(w, 0, 16);
        z -= 16;
    }
    bw_put(w, 0, z);
    if (nb > 24) {
        bw_put(w, (uint32_t)(x >> 16), nb - 16);
        bw_put(w, (uint32_t)x & 0xFFFF, 16);
    } else {
        bw_put(w, (uint32_t)x, nb);
    }
}

static void bw_copy(struct bw *w, struct br *r, uint32_t from, uint32_t to)
{
    unsigned n;
    r->pos = from;
    while (r->pos + 24 <= to)
        bw_put(w, br_u(r, 24), 24);
    /* the length first: argument evaluation order is unspecified, and ARM's gcc read r->pos
     * after br_u() had advanced it (the header's tail written as 0 bits; found on the rig) */
    n = to - r->pos;
    bw_put(w, br_u(r, n), n);
}

/* ------------------------------------------------------------------ VLC tables */

/* two levels of 8 bits: an entry is value << 5 | length (0: no code), or a subtable
 * (index << 5 | 31) for the codes longer than 8 bits */
struct vlc { uint16_t t1[256]; uint16_t *t2; unsigned n2; };

static int vlc_build(struct vlc *v, const struct cv_code *c)
{
    memset(v->t1, 0, sizeof v->t1);
    v->t2 = NULL;
    v->n2 = 0;
    for (; c->len; c++) {
        unsigned len = c->len, code = c->code, k;
        if (len <= 8) {
            unsigned base = code << (8 - len);
            for (k = 0; k < (1u << (8 - len)); k++)
                v->t1[base + k] = (uint16_t)(c->value << 5 | len);
        } else {
            unsigned pre = code >> (len - 8), base;
            uint16_t e = v->t1[pre];
            if ((e & 31) != 31) {
                uint16_t *t = (uint16_t *)realloc(v->t2, (v->n2 + 1) * 256 * sizeof *t);
                if (!t)
                    return -1;
                v->t2 = t;
                memset(t + v->n2 * 256, 0, 256 * sizeof *t);
                e = (uint16_t)(v->n2 << 5 | 31);
                v->t1[pre] = e;
                v->n2++;
            }
            base = (e >> 5) * 256 + ((code & ((1u << (len - 8)) - 1)) << (16 - len));
            for (k = 0; k < (1u << (16 - len)); k++)
                v->t2[base + k] = (uint16_t)(c->value << 5 | len);
        }
    }
    return 0;
}

static inline int vlc_read(struct br *b, const struct vlc *v)
{
    uint32_t x = br_peek(b);
    unsigned e = v->t1[x >> 24];
    if ((e & 31) == 31)
        e = v->t2[(e >> 5) * 256 + ((x >> 16) & 255)];
    if (!(e & 31))
        return -1;                              /* no such code (the reader's err means: past the end) */
    br_skip(b, e & 31);
    return (int)(e >> 5);
}

/* ------------------------------------------------------------------ CABAC encoder (9.3.4) */

/* Two engines that write the same bytes. The default holds codILow with the output bits not
 * yet written above its 10-bit window and writes whole bytes: renormalisation is one count
 * of leading zeros, and a carry out of the window is resolved a byte at a time (a byte 0xFF
 * is held back until the next byte shows whether a carry turns it, and the bytes after it,
 * over). CV_SPEC_ENGINE builds the spec's own procedure (Figures 9-7 to 9-12, a bit at a
 * time with bitsOutstanding), the reference bench/h264/run_cavlc.sh compares it with. The
 * first bit the spec's PutBit drops (firstBitFlag) is the default engine's carry position
 * above the first byte: always 0, as the coded interval stays inside [0, 510). */

struct cab {
    struct bw *w;
    uint32_t low, range, outstanding;
#ifdef CV_SPEC_ENGINE
    int first;
#else
    int queue;                         /* output bits held above the window, minus 8 */
    size_t start;                      /* the buffer's length when the engine started */
#endif
    uint32_t bins;
    uint8_t st[CV_NUM_CTX];            /* pStateIdx << 1 | valMPS */
};

/* 9.3.1.1; set 0 = I, 1..3 = cabac_init_idc 0..2 */
static void cab_init_ctx(struct cab *c, int qp, unsigned set)
{
    unsigned i;
    if (qp < 0) qp = 0;
    if (qp > 51) qp = 51;
    for (i = 0; i < CV_NUM_CTX; i++) {
        int m = cv_ctx_init[(set * CV_NUM_CTX + i) * 2], n = cv_ctx_init[(set * CV_NUM_CTX + i) * 2 + 1];
        int pre = ((m * qp) >> 4) + n;          /* arithmetic shift: the spec's >> (5.7) */
        if (pre < 1) pre = 1;
        if (pre > 126) pre = 126;
        c->st[i] = pre <= 63 ? (uint8_t)((63 - pre) << 1) : (uint8_t)((pre - 64) << 1 | 1);
    }
}

#ifdef CV_SPEC_ENGINE

/* 9.3.4.1 */
static void cab_start(struct cab *c)
{
    c->low = 0;
    c->range = 510;
    c->first = 1;
    c->outstanding = 0;
}

/* Figure 9-9 */
static inline void cab_putbit(struct cab *c, unsigned b)
{
    if (c->first)
        c->first = 0;
    else
        bw_put(c->w, b, 1);
    while (c->outstanding) {
        unsigned k = c->outstanding > 24 ? 24 : c->outstanding;
        bw_put(c->w, b ? 0 : 0xFFFFFF, k);
        c->outstanding -= k;
    }
}

/* Figure 9-8 */
static inline void cab_renorm(struct cab *c)
{
    while (c->range < 256) {
        if (c->low < 256) {
            cab_putbit(c, 0);
        } else if (c->low >= 512) {
            c->low -= 512;
            cab_putbit(c, 1);
        } else {
            c->low -= 256;
            c->outstanding++;
        }
        c->range <<= 1;
        c->low <<= 1;
    }
}

/* 9.3.4.4 */
static inline void cab_bypass(struct cab *c, unsigned bin)
{
    c->low <<= 1;
    if (bin)
        c->low += c->range;
    if (c->low >= 1024) {
        cab_putbit(c, 1);
        c->low -= 1024;
    } else if (c->low < 512) {
        cab_putbit(c, 0);
    } else {
        c->low -= 512;
        c->outstanding++;
    }
    c->bins++;
}

/* EncodeFlush (Figure 9-12) */
static void cab_flush(struct cab *c)
{
    c->range = 2;
    cab_renorm(c);
    cab_putbit(c, (c->low >> 9) & 1);
    bw_put(c->w, ((c->low >> 7) & 3) | 1, 2);
}

#else

static void cab_start(struct cab *c)
{
    c->low = 0;
    c->range = 510;
    c->queue = -9;
    c->outstanding = 0;
    c->start = c->w->b->n;
}

static inline void cab_putbyte(struct cab *c)
{
    if (c->queue >= 0) {
        uint32_t out = c->low >> (c->queue + 10);
        c->low &= (0x400u << c->queue) - 1;
        c->queue -= 8;
        if ((out & 0xFF) == 0xFF) {
            c->outstanding++;
        } else {
            struct buf *b = c->w->b;
            unsigned carry = out >> 8;
            if (carry && b->n > c->start)
                b->p[b->n - 1]++;               /* never 0xFF: those are held back */
            for (; c->outstanding; c->outstanding--)
                bw_byte(c->w, carry ? 0x00 : 0xFF);
            bw_byte(c->w, (uint8_t)out);
        }
    }
}

static inline void cab_renorm(struct cab *c)
{
    unsigned sh = (unsigned)__builtin_clz(c->range) - 23;   /* range 2..510: up to 7 shifts */
    c->range <<= sh;
    c->low <<= sh;
    c->queue += (int)sh;
    cab_putbyte(c);
}

static inline void cab_bypass(struct cab *c, unsigned bin)
{
    c->low <<= 1;
    if (bin)
        c->low += c->range;
    c->queue++;
    cab_putbyte(c);
    c->bins++;
}

/* EncodeFlush: range 2 renormalised (7 bits), the window's bits 9, 8 and 7 | 1 written (the
 * last one the rbsp_stop_one_bit, or the bit before an I_PCM's pcm_alignment_zero_bits),
 * nothing after them: the last byte is completed with zero bits */
static void cab_flush(struct cab *c)
{
    c->low <<= 7;
    c->queue += 7;
    cab_putbyte(c);
    c->low |= 0x80;
    c->low <<= 3;
    c->queue += 3;
    cab_putbyte(c);
    c->low &= ~0x3FFu;
    if (c->queue > -8) {
        c->low <<= -c->queue;
        c->queue = 0;
        cab_putbyte(c);
    }
    for (; c->outstanding; c->outstanding--)
        bw_byte(c->w, 0xFF);
}

#endif

/* 9.3.4.2 */
static inline void cab_bin(struct cab *c, unsigned ctx, unsigned bin)
{
    unsigned s = c->st[ctx];
    unsigned lps = cv_range_lps[(s >> 1) * 4 + ((c->range >> 6) & 3)];
    c->range -= lps;
    if (bin != (s & 1)) {
        c->low += c->range;
        c->range = lps;
    }
    c->st[ctx] = cv_trans[s << 1 | bin];
    cab_renorm(c);
    c->bins++;
}

/* 9.3.4.5: binVal 1 ends the slice or precedes an I_PCM macroblock's samples */
static void cab_terminate(struct cab *c, unsigned bin)
{
    c->range -= 2;
    if (bin) {
        c->low += c->range;
        cab_flush(c);
    } else {
        cab_renorm(c);
    }
    c->bins++;
}

/* UEGk (9.3.2.3) of v >= 0: TU prefix to uCoff under contexts ctx_first / ctx_rest[...],
 * Exp-Golomb suffix in bypass. ctx_of(bin) is given as a small table. */
static inline void cab_ueg_suffix(struct cab *c, uint32_t suf, unsigned k)
{
    while (suf >= (1u << k)) {
        cab_bypass(c, 1);
        suf -= 1u << k;
        k++;
    }
    cab_bypass(c, 0);
    while (k--)
        cab_bypass(c, (suf >> k) & 1);
}

/* The engine in LOCAL variables for a whole loop (E_*): through the struct, every bin loaded and
 * stored low / range / queue / bins, and the byte writes (uint8_t, aliasing everything) forced
 * them back to memory -- ~30 cycles a bin of the A9's ~100 (docs/cavlc.md S8a). E_DECL copies the
 * registers in, E_SAVE writes them back; the byte output stays out of line (one bin in ~8). The
 * spec's engine (CV_SPEC_ENGINE) maps them to its functions: the same bytes either way. */
#ifndef CV_SPEC_ENGINE
static void cab_putbyte_slow(struct cab *c) { cab_putbyte(c); }
#define E_DECL(c) uint32_t e_low = (c)->low, e_range = (c)->range, e_bins = (c)->bins; \
                  int e_q = (c)->queue; uint8_t *const e_st = (c)->st
#define E_SAVE(c) ((c)->low = e_low, (c)->range = e_range, (c)->queue = e_q, (c)->bins = e_bins)
#define E_OUT(c) do { if (e_q >= 0) { E_SAVE(c); cab_putbyte_slow(c); e_low = (c)->low; e_q = (c)->queue; } } while (0)
#define E_BIN(c, ctx, bin) do { \
        unsigned s_ = e_st[ctx], b_ = (bin); \
        unsigned l_ = cv_range_lps[(s_ >> 1) * 4 + ((e_range >> 6) & 3)]; \
        e_range -= l_; \
        if (b_ != (s_ & 1)) { e_low += e_range; e_range = l_; } \
        e_st[ctx] = cv_trans[s_ << 1 | b_]; \
        { unsigned sh_ = (unsigned)__builtin_clz(e_range) - 23; e_range <<= sh_; e_low <<= sh_; e_q += (int)sh_; } \
        E_OUT(c); e_bins++; } while (0)
#define E_BYPASS(c, bin) do { e_low <<= 1; if (bin) e_low += e_range; e_q++; E_OUT(c); e_bins++; } while (0)
#else
#define E_DECL(c) do { } while (0)
#define E_SAVE(c) ((void)0)
#define E_BIN(c, ctx, bin) cab_bin(c, ctx, bin)
#define E_BYPASS(c, bin) cab_bypass(c, bin)
#endif

/* ------------------------------------------------------------------ parameter sets */

struct sps {
    int valid;
    const char *refuse;                /* why a CAVLC slice on it is refused */
    unsigned profile_idc, log2_max_frame_num, poc_type, log2_max_poc_lsb, delta_pic_order_always_zero;
    unsigned frame_mbs_only, mbaff, width_mbs, height_map_units, direct_8x8_inference;
};

struct pps {
    int valid;
    const char *refuse;
    unsigned sps_id, cabac, bottom_field_pic_order_in_frame_present, num_ref_idx_default[2];
    unsigned weighted_pred, weighted_bipred_idc, deblocking_filter_control_present;
    unsigned redundant_pic_cnt_present, transform_8x8_mode;
    int pic_init_qp;
};

/* ------------------------------------------------------------------ macroblock state */

struct mbi {
    uint32_t addr, slice;
    uint8_t skip, intra, inxn, i16, pcm, direct16, t8, cbp, cpm_nz, qpd_nz, sub_direct;
    uint8_t cbf_dc, cbf_cdc, cbf_cac;  /* Intra16x16 DC; Cb / Cr DC (bits 0, 1); AC (4 * iCbCr + blk) */
    uint16_t cbf_luma;                 /* per 4x4 (all four 1 for a coded 8x8 block) */
    uint16_t pred[2], refgt0[2];       /* predFlagLX (0 for direct) / ref_idx > 0, per 4x4 */
    uint8_t amvd[2][2][16];            /* |mvd| saturated at 127: [list][comp][4x4] */
    uint8_t tc[24];                    /* CAVLC TotalCoeff: luma 0-15, Cb 16-19, Cr 20-23 */
};

/* a neighbouring block: 0 the current macroblock, 1 A, 2 B; the block index in it */
struct nb { uint8_t who, idx; };

/* a residual block in forward scan order */
struct blk { unsigned n; uint8_t pos[16]; int32_t lev[16]; };

struct h264ring_cavlc {
    struct sps sps[32];
    struct pps pps[256];
    struct vlc ct[6], tz[15], tzc[3], rb[7];
    struct nb l4left[16], l4up[16], b8left[4], b8up[4], c4left[4], c4up[4];
    struct buf rbsp, nal, out;
    struct mbi *ring;
    unsigned ring_n;
    uint32_t slice_id;
    /* the picture in progress (7.4.1.2.4), for ASO and 9.3.4.6 */
    int have_pic, opener;
    struct { unsigned pps_id, frame_num, field_pic, bottom_field, ref0, idr, idr_pic_id, poc_lsb;
             int32_t dpb, dp0, dp1; } pic;
    uint32_t pic_next_mb;              /* the address after the picture's last rewritten slice */
    uint64_t pic_bins, pic_bytes;
    int vt_ok;
    struct h264ring_cavlc_stats stats;
    char why[200];
};

struct sh {
    unsigned nal_ref_idc, nal_type, first_mb, slice_type, pps_id, frame_num, field_pic, bottom_field;
    unsigned idr_pic_id, poc_lsb, num_ref[2];
    int32_t dpb, dp0, dp1;
    int qp;
    uint32_t pos_qp, pos_end;
};

/* the slice being rewritten */
struct sl {
    h264ring_cavlc *cv;
    struct br *r;
    struct cab *c;
    const struct sps *sps;
    const struct pps *pps;
    unsigned st, field, w, n_mbs, num_ref[2];
    uint32_t slice, addr, x, ri, stop;
    struct mbi *cur, *A, *B;
    const struct mbi *prev;
    const char *err;
    int refuse;                        /* err names something CABAC cannot express, not malformed */
};

#define FAIL(s, msg) do { (s)->err = (msg); return -1; } while (0)

/* ------------------------------------------------------------------ neighbours (6.4.11, non-MBAFF) */

static void nb_tables(h264ring_cavlc *cv)
{
    unsigned i;
    for (i = 0; i < 16; i++) {
        unsigned x = (i >> 2 & 1) * 8 + (i & 1) * 4, y = (i >> 3) * 8 + (i >> 1 & 1) * 4;
        unsigned lx = (x + 15) & 15, uy = (y + 15) & 15;
        cv->l4left[i].who = x ? 0 : 1;
        cv->l4left[i].idx = (uint8_t)(8 * (y >> 3) + 4 * (lx >> 3) + 2 * ((y & 7) >> 2) + ((lx & 7) >> 2));
        cv->l4up[i].who = y ? 0 : 2;
        cv->l4up[i].idx = (uint8_t)(8 * (uy >> 3) + 4 * (x >> 3) + 2 * ((uy & 7) >> 2) + ((x & 7) >> 2));
    }
    for (i = 0; i < 4; i++) {
        unsigned x = i & 1, y = i >> 1;
        cv->b8left[i].who = x ? 0 : 1;
        cv->b8left[i].idx = (uint8_t)(2 * y + (x ^ 1));
        cv->b8up[i].who = y ? 0 : 2;
        cv->b8up[i].idx = (uint8_t)(2 * (y ^ 1) + x);
        cv->c4left[i] = cv->b8left[i];  /* 4:2:0 chroma 4x4 blocks are laid out as 8x8 luma ones */
        cv->c4up[i] = cv->b8up[i];
    }
}

static inline const struct mbi *who(const struct sl *s, unsigned w)
{
    return w == 0 ? s->cur : w == 1 ? s->A : s->B;
}

/* ------------------------------------------------------------------ CAVLC residual (9.2) */

static int nc_of(int a, int b)
{
    if (a >= 0 && b >= 0)
        return (a + b + 1) >> 1;
    return a >= 0 ? a : b >= 0 ? b : 0;
}

/* nC for luma 4x4 block idx (9.2.1: Intra16x16DCLevel uses idx 0) */
static int nc_luma(const struct sl *s, unsigned idx)
{
    const h264ring_cavlc *cv = s->cv;
    const struct mbi *a = who(s, cv->l4left[idx].who), *b = who(s, cv->l4up[idx].who);
    return nc_of(a ? a->tc[cv->l4left[idx].idx] : -1, b ? b->tc[cv->l4up[idx].idx] : -1);
}

static int nc_chroma(const struct sl *s, unsigned icc, unsigned idx)
{
    const h264ring_cavlc *cv = s->cv;
    const struct mbi *a = who(s, cv->c4left[idx].who), *b = who(s, cv->c4up[idx].who);
    unsigned o = 16 + 4 * icc;
    return nc_of(a ? a->tc[o + cv->c4left[idx].idx] : -1, b ? b->tc[o + cv->c4up[idx].idx] : -1);
}

/* residual_block_cavlc (7.3.5.3.2, 9.2): maxNumCoeff 4 (chroma DC 4:2:0), 15 or 16 */
/* The reader's position in a LOCAL for the whole block (written back once): through the struct,
 * every peek and skip loaded and stored it, and its end check ran per skip. Here the position may
 * run past the RBSP's end between checks (once per syntax element, under CV_PAD bytes of zeros),
 * and the write-back clamps it and sets err exactly as br_skip would. */
static inline uint32_t peek_at(const uint8_t *p, uint32_t pos)     /* 25 valid bits at least */
{
    uint32_t v;
    memcpy(&v, p + (pos >> 3), 4);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    v = __builtin_bswap32(v);
#endif
    return v << (pos & 7);
}

static inline int vlc_at(const struct vlc *v, const uint8_t *p, uint32_t *pos)
{
    uint32_t x = peek_at(p, *pos);
    unsigned e = v->t1[x >> 24];
    if ((e & 31) == 31)
        e = v->t2[(e >> 5) * 256 + ((x >> 16) & 255)];
    if (!(e & 31))
        return -1;
    *pos += e & 31;
    return (int)(e >> 5);
}

static int cavlc_block(struct sl *s, int nc, unsigned maxn, struct blk *o)
{
    struct br *r = s->r;
    const h264ring_cavlc *cv = s->cv;
    const uint8_t *rp = r->p;
    uint32_t pos = r->pos, nb = r->nbits;
    int32_t lv[16];
    unsigned run[16];
    unsigned tc, t1, i, sl, tz, zl;
    int v, num;
#define R_BACK() do { if (pos > nb) { pos = nb; r->err = 1; } r->pos = pos; } while (0)
#define R_FAIL(msg) do { R_BACK(); FAIL(s, msg); } while (0)
#define R_CUT() do { if (pos > nb) R_FAIL("the slice data ends inside a block"); } while (0)
    v = vlc_at(&cv->ct[nc < 0 ? 4 : nc < 2 ? 0 : nc < 4 ? 1 : nc < 8 ? 2 : 3], rp, &pos);
    if (v < 0)
        R_FAIL("coeff_token: no such code");
    R_CUT();
    tc = (unsigned)v >> 2;
    t1 = (unsigned)v & 3;
    if (tc > maxn)
        R_FAIL("TotalCoeff above maxNumCoeff");
    o->n = tc;
    if (!tc) {
        R_BACK();
        return 0;
    }
    {                                           /* the trailing ones' signs: t1 bits at once */
        uint32_t x = peek_at(rp, pos);
        for (i = 0; i < t1; i++)
            lv[i] = (x >> (31 - i)) & 1 ? -1 : 1;
        pos += t1;
    }
    sl = (tc > 10 && t1 < 3) ? 1 : 0;
    for (; i < tc; i++) {
        uint32_t x = peek_at(rp, pos);
        unsigned prefix, lss;
        int32_t code;
        if (x >= 0x80u) {                       /* within the 25 bits peeked */
            prefix = (unsigned)__builtin_clz(x);
            pos += prefix + 1;
        } else {
            prefix = 0;
            while (!((peek_at(rp, pos) >> 31) & 1)) {
                pos++;
                if (++prefix > 28)
                    R_FAIL("level_prefix too long");
                R_CUT();
            }
            pos++;
        }
        lss = (prefix == 14 && sl == 0) ? 4 : prefix >= 15 ? prefix - 3 : sl;
        code = (int32_t)((prefix < 15 ? prefix : 15) << sl);
        if (lss) {
            code += (int32_t)(peek_at(rp, pos) >> (32 - lss));
            pos += lss;
        }
        R_CUT();
        if (prefix >= 15 && sl == 0)
            code += 15;
        if (prefix >= 16)
            code += (1 << (prefix - 3)) - 4096;
        if (i == t1 && t1 < 3)
            code += 2;
        lv[i] = (code & 1) ? (-code - 1) >> 1 : (code + 2) >> 1;
        if (sl == 0)
            sl = 1;
        if ((lv[i] < 0 ? -lv[i] : lv[i]) > (3 << (sl - 1)) && sl < 6)
            sl++;
    }
    tz = 0;
    if (tc < maxn) {
        v = vlc_at(maxn == 4 ? &cv->tzc[tc - 1] : &cv->tz[tc - 1], rp, &pos);
        if (v < 0)
            R_FAIL("total_zeros: no such code");
        tz = (unsigned)v;
        if (tz > maxn - tc)
            R_FAIL("total_zeros too large");
    }
    zl = tz;
    for (i = 0; i + 1 < tc; i++) {
        run[i] = 0;
        if (zl > 0) {
            v = vlc_at(&cv->rb[(zl < 7 ? zl : 7) - 1], rp, &pos);
            if (v < 0)
                R_FAIL("run_before: no such code");
            run[i] = (unsigned)v;
            if (run[i] > zl)
                R_FAIL("run_before above zerosLeft");
            zl -= run[i];
        }
    }
    R_BACK();
#undef R_BACK
#undef R_FAIL
#undef R_CUT
    run[tc - 1] = zl;
    num = -1;
    for (i = tc; i-- > 0;) {
        num += (int)run[i] + 1;
        o->pos[tc - 1 - i] = (uint8_t)num;
        o->lev[tc - 1 - i] = lv[i];
    }
    return 0;
}

/* ------------------------------------------------------------------ CABAC residual (7.3.5.3.3, 9.3.3.1.3) */

static const uint8_t CAT_OFF_CBF[5] = {0, 4, 8, 12, 16};
static const uint8_t CAT_OFF_SIG[5] = {0, 15, 29, 44, 47};
static const uint8_t CAT_OFF_ABS[5] = {0, 10, 20, 30, 39};

/* h264_fe_ref.cbf_term: condTermFlagN given the neighbour's transBlock flag (-1: n/a) */
static inline unsigned cbf_term(const struct sl *s, const struct mbi *m, int tb)
{
    if (!m)
        return s->cur->intra;
    if (m->pcm)
        return 1;
    return tb < 0 ? 0 : (unsigned)tb;
}

static unsigned inc_cbf_dc(const struct sl *s)
{
    const struct mbi *a = s->A, *b = s->B;
    return cbf_term(s, a, a && a->i16 ? a->cbf_dc : -1) +
           2 * cbf_term(s, b, b && b->i16 ? b->cbf_dc : -1);
}

static int luma_tb(const struct mbi *m, unsigned nb)
{
    if (!m || m->skip || m->pcm || !((m->cbp >> (nb >> 2)) & 1))
        return -1;
    return (m->cbf_luma >> nb) & 1;
}

static unsigned inc_cbf_luma(const struct sl *s, unsigned idx)
{
    const h264ring_cavlc *cv = s->cv;
    const struct mbi *a = who(s, cv->l4left[idx].who), *b = who(s, cv->l4up[idx].who);
    return cbf_term(s, a, luma_tb(a, cv->l4left[idx].idx)) +
           2 * cbf_term(s, b, luma_tb(b, cv->l4up[idx].idx));
}

static unsigned inc_cbf_cdc(const struct sl *s, unsigned icc)
{
    const struct mbi *a = s->A, *b = s->B;
    int ta = a && !a->skip && !a->pcm && (a->cbp >> 4) ? (a->cbf_cdc >> icc) & 1 : -1;
    int tb = b && !b->skip && !b->pcm && (b->cbp >> 4) ? (b->cbf_cdc >> icc) & 1 : -1;
    return cbf_term(s, a, ta) + 2 * cbf_term(s, b, tb);
}

static unsigned inc_cbf_cac(const struct sl *s, unsigned icc, unsigned idx)
{
    const h264ring_cavlc *cv = s->cv;
    const struct mbi *a = who(s, cv->c4left[idx].who), *b = who(s, cv->c4up[idx].who);
    unsigned ia = 4 * icc + cv->c4left[idx].idx, ib = 4 * icc + cv->c4up[idx].idx;
    int ta = a && !a->skip && !a->pcm && (a->cbp >> 4) == 2 ? (a->cbf_cac >> ia) & 1 : -1;
    int tb = b && !b->skip && !b->pcm && (b->cbp >> 4) == 2 ? (b->cbf_cac >> ib) & 1 : -1;
    return cbf_term(s, a, ta) + 2 * cbf_term(s, b, tb);
}

/* the levels of a block, last significant first (h264_fe_ref.residual_block's second loop) */
static void enc_levels(struct cab *c, unsigned cat, const int32_t *lev, unsigned n)
{
    unsigned abs_off = cat == 5 ? 426 : 227 + CAT_OFF_ABS[cat];
    unsigned eq1 = 0, gt1 = 0, k;
    unsigned capn = cat == 3 ? 3 : 4;
    E_DECL(c);
    for (k = n; k-- > 0;) {
        int32_t l = lev[k];
        uint32_t a = (uint32_t)(l < 0 ? -l : l) - 1;
        unsigned inc0 = gt1 ? 0 : (1 + eq1 < 4 ? 1 + eq1 : 4);
        unsigned incn = 5 + (gt1 < capn ? gt1 : capn);
        unsigned b, pre = a < 14 ? a : 14;
        /* coeff_abs_level_minus1: UEG0, uCoff 14 */
        E_BIN(c, abs_off + inc0, pre > 0);
        for (b = 1; b < pre; b++)
            E_BIN(c, abs_off + incn, 1);
        if (pre > 0 && pre < 14)
            E_BIN(c, abs_off + incn, 0);
        if (a >= 14) {                           /* the Exp-Golomb suffix (k = 0) in bypass */
            uint32_t suf = a - 14;
            unsigned kk = 0;
            while (suf >= (1u << kk)) {
                E_BYPASS(c, 1);
                suf -= 1u << kk;
                kk++;
            }
            E_BYPASS(c, 0);
            while (kk--)
                E_BYPASS(c, (suf >> kk) & 1);
        }
        E_BYPASS(c, l < 0);
        if (a == 0)
            eq1++;
        else
            gt1++;
    }
    E_SAVE(c);
}

/* a 4x4-class block (ctxBlockCat 0-4): coded_block_flag, significance map, levels */
static unsigned enc_block(struct sl *s, unsigned cat, unsigned maxn, unsigned inc_cbf, const struct blk *b)
{
    struct cab *c = s->c;
    unsigned sig_off = (s->field ? 277 : 105) + CAT_OFF_SIG[cat];
    unsigned last_off = (s->field ? 338 : 166) + CAT_OFF_SIG[cat];
    unsigned i, j, last;
    E_DECL(c);
    E_BIN(c, 85 + CAT_OFF_CBF[cat] + inc_cbf, b->n > 0);
    if (!b->n) {
        E_SAVE(c);
        return 0;
    }
    last = b->pos[b->n - 1];
    for (i = 0, j = 0; i < maxn - 1 && i <= last; i++) {
        unsigned inc = cat == 3 ? (i < 2 ? i : 2) : i;
        unsigned sig = b->pos[j] == i;
        E_BIN(c, sig_off + inc, sig);
        if (sig) {
            E_BIN(c, last_off + inc, i == last);
            j++;
        }
    }
    E_SAVE(c);
    enc_levels(c, cat, b->lev, b->n);
    return 1;
}

/* an 8x8 block (ctxBlockCat 5, no coded_block_flag in 4:2:0): 64 levels in scan order */
static void enc_block8(struct sl *s, const int32_t *c64)
{
    struct cab *c = s->c;
    const uint8_t *sigmap = s->field ? cv_sig8_field : cv_sig8_frame;
    unsigned sig_off = s->field ? 436 : 402, last_off = s->field ? 451 : 417;
    int32_t lev[64];
    unsigned i, n = 0, last = 0;
    for (i = 0; i < 64; i++)
        if (c64[i])
            last = i;
    {
        E_DECL(c);
        for (i = 0; i < 63 && i <= last; i++) {
            unsigned sig = c64[i] != 0;
            E_BIN(c, sig_off + sigmap[i], sig);
            if (sig)
                E_BIN(c, last_off + cv_last8[i], i == last);
        }
        E_SAVE(c);
    }
    for (i = 0; i <= last; i++)
        if (c64[i])
            lev[n++] = c64[i];
    enc_levels(c, 5, lev, n);
}

/* ------------------------------------------------------------------ macroblock layer (7.3.5) */

/* h264_fe_ref.decode_mb_type_i in reverse: it = the I-slice mb_type 0..25 */
static void enc_mb_type_i(struct cab *c, unsigned off, unsigned inc0, unsigned it)
{
    static const uint8_t C3[5] = {3, 4, 5, 6, 7}, CS[5] = {1, 2, 2, 3, 3};
    const uint8_t *ci = off == 3 ? C3 : CS;
    unsigned t, pred, chroma, ac;
    if (it == 0) {
        cab_bin(c, off + inc0, 0);
        return;
    }
    cab_bin(c, off + inc0, 1);
    if (it == 25) {
        cab_terminate(c, 1);
        return;
    }
    cab_terminate(c, 0);
    t = it - 1;
    pred = t & 3;
    chroma = (t >> 2) % 3;
    ac = t >= 12;
    cab_bin(c, off + ci[0], ac);
    cab_bin(c, off + ci[1], chroma != 0);
    if (chroma)
        cab_bin(c, off + ci[2], chroma == 2);
    cab_bin(c, off + ci[3], pred >> 1);
    cab_bin(c, off + ci[4], pred & 1);
}

static void enc_mb_type_p(struct cab *c, unsigned mt)
{
    switch (mt) {
    case 0: cab_bin(c, 14, 0); cab_bin(c, 15, 0); cab_bin(c, 16, 0); break;
    case 1: cab_bin(c, 14, 0); cab_bin(c, 15, 1); cab_bin(c, 17, 1); break;
    case 2: cab_bin(c, 14, 0); cab_bin(c, 15, 1); cab_bin(c, 17, 0); break;
    case 3: cab_bin(c, 14, 0); cab_bin(c, 15, 0); cab_bin(c, 16, 1); break;
    default: cab_bin(c, 14, 1); enc_mb_type_i(c, 17, 0, mt - 5); break;
    }
}

static void enc_mb_type_b(struct cab *c, unsigned inc, unsigned mt)
{
    unsigned bits;
    int extra = -1;
    if (mt == 0) {
        cab_bin(c, 27 + inc, 0);
        return;
    }
    cab_bin(c, 27 + inc, 1);
    if (mt <= 2) {
        cab_bin(c, 30, 0);
        cab_bin(c, 32, mt - 1);
        return;
    }
    cab_bin(c, 30, 1);
    if (mt <= 10)
        bits = mt - 3;
    else if (mt == 11)
        bits = 14;
    else if (mt == 22)
        bits = 15;
    else if (mt <= 21) {
        bits = (mt + 4) >> 1;
        extra = (int)((mt + 4) & 1);
    } else
        bits = 13;                              /* intra: the I suffix follows */
    cab_bin(c, 31, bits >> 3);
    cab_bin(c, 32, (bits >> 2) & 1);
    cab_bin(c, 32, (bits >> 1) & 1);
    cab_bin(c, 32, bits & 1);
    if (extra >= 0)
        cab_bin(c, 32, (unsigned)extra);
    if (mt >= 23)
        enc_mb_type_i(c, 32, 0, mt - 23);
}

static void enc_sub_p(struct cab *c, unsigned t)
{
    if (t == 0) { cab_bin(c, 21, 1); return; }
    cab_bin(c, 21, 0);
    if (t == 1) { cab_bin(c, 22, 0); return; }
    cab_bin(c, 22, 1);
    cab_bin(c, 23, t == 2);
}

static void enc_sub_b(struct cab *c, unsigned t)
{
    if (t == 0) { cab_bin(c, 36, 0); return; }
    cab_bin(c, 36, 1);
    if (t <= 2) { cab_bin(c, 37, 0); cab_bin(c, 39, t - 1); return; }
    cab_bin(c, 37, 1);
    if (t <= 6) {
        cab_bin(c, 38, 0);
        cab_bin(c, 39, (t - 3) >> 1);
        cab_bin(c, 39, (t - 3) & 1);
        return;
    }
    cab_bin(c, 38, 1);
    if (t <= 10) {
        cab_bin(c, 39, 0);
        cab_bin(c, 39, (t - 7) >> 1);
        cab_bin(c, 39, (t - 7) & 1);
        return;
    }
    cab_bin(c, 39, 1);
    cab_bin(c, 39, t - 11);
}

/* the neighbour partitions' exclusions of 9.3.3.1.1.6 / 9.3.3.1.1.7 */
static inline int mv_usable(const struct mbi *m, unsigned lx, unsigned nb)
{
    return m && !m->skip && !m->intra && !m->direct16 && !((m->sub_direct >> (nb >> 2)) & 1) &&
           ((m->pred[lx] >> nb) & 1);
}

/* h264_fe_ref.decode_ref_idx in reverse (U binarisation; bins: inc, 4, 5, 5...) */
static void enc_ref(struct sl *s, unsigned lx, unsigned blk, unsigned r)
{
    const h264ring_cavlc *cv = s->cv;
    const struct mbi *a = who(s, cv->l4left[blk].who), *b = who(s, cv->l4up[blk].who);
    unsigned na = cv->l4left[blk].idx, nbb = cv->l4up[blk].idx, inc = 0, k;
    if (mv_usable(a, lx, na) && ((a->refgt0[lx] >> na) & 1))
        inc += 1;
    if (mv_usable(b, lx, nbb) && ((b->refgt0[lx] >> nbb) & 1))
        inc += 2;
    for (k = 0; k <= r; k++)
        cab_bin(s->c, k == 0 ? 54 + inc : k == 1 ? 58 : 59, k < r);
}

/* h264_fe_ref.decode_mvd_pair in reverse: UEG3, uCoff 9, signed; bins inc, 3, 4, 5, 6, 6... */
static void enc_mvd(struct sl *s, unsigned lx, uint16_t mask, int32_t mvx, int32_t mvy)
{
    const h264ring_cavlc *cv = s->cv;
    unsigned first = (unsigned)__builtin_ctz(mask), comp, k;
    const struct mbi *a = who(s, cv->l4left[first].who), *b = who(s, cv->l4up[first].who);
    unsigned na = cv->l4left[first].idx, nbb = cv->l4up[first].idx;
    int32_t v[2] = {mvx, mvy};
    uint8_t sat[2];
    struct cab *c = s->c;
    E_DECL(c);
    for (comp = 0; comp < 2; comp++) {
        unsigned sum = 0, inc, off = comp ? 47 : 40, pre;
        uint32_t av = (uint32_t)(v[comp] < 0 ? -v[comp] : v[comp]);
        if (mv_usable(a, lx, na))
            sum += a->amvd[lx][comp][na];
        if (mv_usable(b, lx, nbb))
            sum += b->amvd[lx][comp][nbb];
        inc = sum > 32 ? 2 : sum > 2 ? 1 : 0;
        pre = av < 9 ? av : 9;
        for (k = 0; k < pre; k++)
            E_BIN(c, k == 0 ? off + inc : off + (k + 2 < 6 ? k + 2 : 6), 1);
        if (pre < 9) {
            E_BIN(c, pre == 0 ? off + inc : off + (pre + 2 < 6 ? pre + 2 : 6), 0);
        } else {                                 /* the Exp-Golomb suffix (k = 3) in bypass */
            uint32_t suf = av - 9;
            unsigned kk = 3;
            while (suf >= (1u << kk)) {
                E_BYPASS(c, 1);
                suf -= 1u << kk;
                kk++;
            }
            E_BYPASS(c, 0);
            while (kk--)
                E_BYPASS(c, (suf >> kk) & 1);
        }
        if (av)
            E_BYPASS(c, v[comp] < 0);
        sat[comp] = (uint8_t)(av < 127 ? av : 127);
    }
    E_SAVE(c);
    for (k = 0; k < 16; k++) {
        if ((mask >> k) & 1) {
            s->cur->amvd[lx][0][k] = sat[0];
            s->cur->amvd[lx][1][k] = sat[1];
        }
    }
}

/* te(v) of ref_idx_lX (7.4.5.1: range num_ref_idx_lX_active_minus1, non-MBAFF) */
static int read_ref(struct sl *s, unsigned lx, unsigned *r)
{
    unsigned range = s->num_ref[lx] - 1;
    *r = range == 1 ? !br_u(s->r, 1) : br_ue(s->r);
    if (*r > range)
        FAIL(s, "ref_idx out of range");
    return 0;
}

static int read_mvd(struct sl *s, int32_t *v)
{
    *v = br_se(s->r);
    if (*v < -32768 || *v > 32767)
        FAIL(s, "mvd out of range");
    return 0;
}

static const uint16_t PART_16x8[2] = {0x00FF, 0xFF00};
static const uint16_t PART_8x16[2] = {0x0F0F, 0xF0F0};
/* B mb_type 4..21 (Table 7-14): (pred0, pred1); bit 0 L0, bit 1 L1 */
static const uint8_t B_PAIR[9][2] = {{1, 1}, {2, 2}, {1, 2}, {2, 1}, {1, 3}, {2, 3}, {3, 1}, {3, 2}, {3, 3}};
/* sub_mb_type: pred (0 direct), parts, shape (0 8x8, 1 8x4, 2 4x8, 3 4x4) */
static const uint8_t P_SUB[4][3] = {{1, 1, 0}, {1, 2, 1}, {1, 2, 2}, {1, 4, 3}};
static const uint8_t B_SUB[13][3] = {{0, 4, 3}, {1, 1, 0}, {2, 1, 0}, {3, 1, 0}, {1, 2, 1}, {1, 2, 2},
                                     {2, 2, 1}, {2, 2, 2}, {3, 2, 1}, {3, 2, 2}, {1, 4, 3}, {2, 4, 3},
                                     {3, 4, 3}};
static const uint8_t SUB_MASK[4][4] = {{0xF, 0, 0, 0}, {0x3, 0xC, 0, 0}, {0x5, 0xA, 0, 0}, {1, 2, 4, 8}};

/* mb_pred for an inter partitioning (7.3.5.1) */
static int mb_pred_inter(struct sl *s, unsigned mt)
{
    struct mbi *cur = s->cur;
    uint16_t mask[2];
    uint8_t pred[2];
    unsigned np, lx, p;
    if (s->st == ST_P) {
        pred[0] = pred[1] = 1;
        if (mt == 0) { np = 1; mask[0] = 0xFFFF; }
        else if (mt == 1) { np = 2; mask[0] = PART_16x8[0]; mask[1] = PART_16x8[1]; }
        else { np = 2; mask[0] = PART_8x16[0]; mask[1] = PART_8x16[1]; }
    } else if (mt <= 3) {
        np = 1;
        mask[0] = 0xFFFF;
        pred[0] = (uint8_t)mt;
    } else {
        unsigned k = mt - 4;
        np = 2;
        if (k % 2 == 0) { mask[0] = PART_16x8[0]; mask[1] = PART_16x8[1]; }
        else { mask[0] = PART_8x16[0]; mask[1] = PART_8x16[1]; }
        pred[0] = B_PAIR[k / 2][0];
        pred[1] = B_PAIR[k / 2][1];
    }
    for (p = 0; p < np; p++)
        for (lx = 0; lx < 2; lx++)
            if (pred[p] >> lx & 1)
                cur->pred[lx] |= mask[p];
    for (lx = 0; lx < 2; lx++)
        for (p = 0; p < np; p++)
            if ((pred[p] >> lx & 1) && s->num_ref[lx] > 1) {
                unsigned r;
                if (read_ref(s, lx, &r))
                    return -1;
                enc_ref(s, lx, (unsigned)__builtin_ctz(mask[p]), r);
                if (r)
                    cur->refgt0[lx] |= mask[p];
            }
    for (lx = 0; lx < 2; lx++)
        for (p = 0; p < np; p++)
            if (pred[p] >> lx & 1) {
                int32_t x, y;
                if (read_mvd(s, &x) || read_mvd(s, &y))
                    return -1;
                enc_mvd(s, lx, mask[p], x, y);
            }
    return 0;
}

/* sub_mb_pred (7.3.5.2); returns noSubMbPartSizeLessThan8x8Flag or -1 */
static int sub_mb_pred(struct sl *s, int p8ref0)
{
    struct mbi *cur = s->cur;
    unsigned t[4], b8, lx, k;
    int no_lt8 = 1;
    for (b8 = 0; b8 < 4; b8++) {
        const uint8_t *d;
        t[b8] = br_ue(s->r);
        if (t[b8] > (s->st == ST_P ? 3u : 12u))
            FAIL(s, "sub_mb_type out of range");
        if (s->st == ST_P)
            enc_sub_p(s->c, t[b8]);
        else
            enc_sub_b(s->c, t[b8]);
        d = s->st == ST_P ? P_SUB[t[b8]] : B_SUB[t[b8]];
        if (d[0] == 0) {
            cur->sub_direct |= (uint8_t)(1u << b8);
            if (!s->sps->direct_8x8_inference)
                no_lt8 = 0;
        } else if (d[1] > 1) {
            no_lt8 = 0;
        }
        for (lx = 0; lx < 2; lx++)
            if (d[0] >> lx & 1)
                cur->pred[lx] |= (uint16_t)(0xFu << (4 * b8));
    }
    for (lx = 0; lx < 2; lx++)
        for (b8 = 0; b8 < 4; b8++) {
            const uint8_t *d = s->st == ST_P ? P_SUB[t[b8]] : B_SUB[t[b8]];
            if (d[0] && (d[0] >> lx & 1) && s->num_ref[lx] > 1) {
                unsigned r = 0;                  /* P_8x8ref0: not coded in CAVLC, 0 (7.4.5) */
                if (!p8ref0 && read_ref(s, lx, &r))
                    return -1;
                enc_ref(s, lx, 4 * b8, r);
                if (r)
                    cur->refgt0[lx] |= (uint16_t)(0xFu << (4 * b8));
            }
        }
    for (lx = 0; lx < 2; lx++)
        for (b8 = 0; b8 < 4; b8++) {
            const uint8_t *d = s->st == ST_P ? P_SUB[t[b8]] : B_SUB[t[b8]];
            if (d[0] && (d[0] >> lx & 1))
                for (k = 0; k < d[1]; k++) {
                    int32_t x, y;
                    if (read_mvd(s, &x) || read_mvd(s, &y))
                        return -1;
                    enc_mvd(s, lx, (uint16_t)(SUB_MASK[d[2]][k] << (4 * b8)), x, y);
                }
        }
    return no_lt8;
}

static unsigned inc_t8(const struct sl *s)
{
    return (s->A && s->A->t8) + (s->B && s->B->t8);
}

/* the residual of one macroblock as parsed (7.3.5.3, CAVLC) */
struct mbres {
    struct blk dc, l4[16], cdc[2], cac[2][4];
    int32_t l8[4][64];
};

static int parse_residual(struct sl *s, struct mbres *res, unsigned cbp, unsigned t8, unsigned i16)
{
    struct mbi *cur = s->cur;
    unsigned b8, b, icc;
    if (i16 && cavlc_block(s, nc_luma(s, 0), 16, &res->dc))
        return -1;
    for (b8 = 0; b8 < 4; b8++) {
        if (t8)
            memset(res->l8[b8], 0, sizeof res->l8[b8]);
        for (b = 0; b < 4; b++) {
            unsigned idx = 4 * b8 + b;
            struct blk *k = &res->l4[idx];
            k->n = 0;
            if (!((cbp >> b8) & 1))
                continue;
            if (cavlc_block(s, nc_luma(s, idx), i16 ? 15 : 16, k))
                return -1;
            cur->tc[idx] = (uint8_t)k->n;
            if (t8) {                            /* 7.3.5.3.2: level8x8[4 * i + i4x4] */
                unsigned j;
                for (j = 0; j < k->n; j++)
                    res->l8[b8][4 * k->pos[j] + b] = k->lev[j];
            }
        }
    }
    for (icc = 0; icc < 2; icc++) {
        res->cdc[icc].n = 0;
        if ((cbp >> 4) && cavlc_block(s, -1, 4, &res->cdc[icc]))
            return -1;
    }
    for (icc = 0; icc < 2; icc++)
        for (b = 0; b < 4; b++) {
            struct blk *k = &res->cac[icc][b];
            k->n = 0;
            if ((cbp >> 4) == 2) {
                if (cavlc_block(s, nc_chroma(s, icc, b), 15, k))
                    return -1;
                cur->tc[16 + 4 * icc + b] = (uint8_t)k->n;
            }
        }
    return 0;
}

/* h264_fe_ref.residual in reverse, from the output cbp / transform_size_8x8_flag */
static void enc_residual(struct sl *s, const struct mbres *res, int t8_as_4x4)
{
    struct mbi *cur = s->cur;
    unsigned b8, b, icc;
    if (cur->i16)
        cur->cbf_dc = (uint8_t)enc_block(s, 0, 16, inc_cbf_dc(s), &res->dc);
    for (b8 = 0; b8 < 4; b8++) {
        if (!((cur->cbp >> b8) & 1))
            continue;
        if (cur->t8) {
            enc_block8(s, res->l8[b8]);
            cur->cbf_luma |= (uint16_t)(0xFu << (4 * b8));
            continue;
        }
        for (b = 0; b < 4; b++) {
            unsigned idx = 4 * b8 + b;
            static const struct blk none = {0, {0}, {0}};
            const struct blk *k = t8_as_4x4 ? &none : &res->l4[idx];
            unsigned cat = cur->i16 ? 1 : 2;
            if (enc_block(s, cat, cur->i16 ? 15 : 16, inc_cbf_luma(s, idx), k))
                cur->cbf_luma |= (uint16_t)(1u << idx);
        }
    }
    if (cur->cbp >> 4)
        for (icc = 0; icc < 2; icc++)
            if (enc_block(s, 3, 4, inc_cbf_cdc(s, icc), &res->cdc[icc]))
                cur->cbf_cdc |= (uint8_t)(1u << icc);
    if ((cur->cbp >> 4) == 2)
        for (icc = 0; icc < 2; icc++)
            for (b = 0; b < 4; b++)
                if (enc_block(s, 4, 15, inc_cbf_cac(s, icc, b), &res->cac[icc][b]))
                    cur->cbf_cac |= (uint8_t)(1u << (4 * icc + b));
}

/* h264_fe_ref.decode_cbp in reverse */
static void enc_cbp(struct sl *s, unsigned cbp)
{
    const h264ring_cavlc *cv = s->cv;
    struct cab *c = s->c;
    const struct mbi *a = s->A, *b = s->B;
    unsigned b8, ta0, tb0;
    for (b8 = 0; b8 < 4; b8++) {
        unsigned inc = 0, side;
        for (side = 0; side < 2; side++) {
            struct nb n = side ? cv->b8up[b8] : cv->b8left[b8];
            const struct mbi *m = who(s, n.who);
            unsigned cond;
            if (!m || m->pcm)
                cond = 0;
            else if (n.who == 0)
                cond = !((cbp >> n.idx) & 1);
            else
                cond = m->skip || !((m->cbp >> n.idx) & 1);
            inc += cond << side;
        }
        cab_bin(c, 73 + inc, (cbp >> b8) & 1);
    }
#define CTERM(m, bin) (!(m) ? 0u : (m)->pcm ? 1u : (m)->skip ? 0u : \
                       (bin) == 0 ? (unsigned)(((m)->cbp >> 4) != 0) : (unsigned)(((m)->cbp >> 4) == 2))
    ta0 = CTERM(a, 0);
    tb0 = CTERM(b, 0);
    cab_bin(c, 77 + ta0 + 2 * tb0, (cbp >> 4) != 0);
    if (cbp >> 4)
        cab_bin(c, 77 + 4 + CTERM(a, 1) + 2 * CTERM(b, 1), (cbp >> 4) == 2);
#undef CTERM
}

/* h264_fe_ref.decode_qp_delta in reverse */
static void enc_qp_delta(struct sl *s, int32_t d)
{
    const struct mbi *p = s->prev;
    unsigned inc = p && !p->skip && !p->pcm && (p->i16 || p->cbp) && p->qpd_nz;
    uint32_t k = d > 0 ? (uint32_t)(2 * d - 1) : (uint32_t)(-2 * d), i;
    for (i = 0; i <= k; i++)
        cab_bin(s->c, i == 0 ? 60 + inc : i == 1 ? 62 : 63, i < k);
}

static void enc_chroma_pred(struct sl *s, unsigned v)
{
    unsigned inc = 0, k;
    if (s->A && s->A->intra && !s->A->pcm && s->A->cpm_nz) inc++;
    if (s->B && s->B->intra && !s->B->pcm && s->B->cpm_nz) inc++;
    for (k = 0; k < 3 && k <= v; k++)
        cab_bin(s->c, k == 0 ? 64 + inc : 67, k < v);
}

static int pcm_mb(struct sl *s)
{
    struct br *r = s->r;
    struct bw *w = s->c->w;
    unsigned i;
    while (r->pos & 7)
        if (br_u(r, 1))
            FAIL(s, "pcm_alignment_zero_bit is 1");
    if (r->pos + 384 * 8 > r->nbits)
        FAIL(s, "I_PCM samples cut");
    /* the terminate bin (coded by the caller) flushed the engine; pcm_alignment_zero_bits */
    if (w->nacc)
        bw_put(w, 0, 8 - w->nacc);
    for (i = 0; i < 384; i++)
        bw_byte(w, (uint8_t)br_u(r, 8));
    cab_start(s->c);                             /* 9.3.1.2 after the samples */
    s->cv->stats.pcm_mbs++;
    s->cur->pcm = 1;
    memset(s->cur->tc, 16, sizeof s->cur->tc);
    return 0;
}

static int macroblock(struct sl *s)
{
    h264ring_cavlc *cv = s->cv;
    struct br *r = s->r;
    struct cab *c = s->c;
    struct mbi *cur = s->cur;
    unsigned base = s->st == ST_I ? 0 : s->st == ST_P ? 5 : 23;
    unsigned mt = br_ue(r), cbp, t8_in = 0;
    int it, p8ref0 = 0, no_lt8 = 1, t8_as_4x4 = 0;
    int32_t qpd = 0;
    struct mbres res;
    if (r->err || mt > base + 25)
        FAIL(s, "mb_type out of range");
    if (s->st == ST_P && mt == 4) {              /* P_8x8ref0: CABAC has only P_8x8 */
        p8ref0 = 1;
        mt = 3;
        cv->stats.p8x8ref0_mbs++;
    }
    if (s->st == ST_I)
        enc_mb_type_i(c, 3, (s->A && !s->A->inxn) + (s->B && !s->B->inxn), mt);
    else if (s->st == ST_P)
        enc_mb_type_p(c, mt);
    else
        enc_mb_type_b(c, (s->A && !s->A->skip && !s->A->direct16) + (s->B && !s->B->skip && !s->B->direct16), mt);
    it = (int)mt - (int)base;
    if (it >= 0) {
        cur->intra = 1;
        if (it == 25)
            return pcm_mb(s);
        if (it == 0) {
            unsigned n, k;
            cur->inxn = 1;
            if (s->pps->transform_8x8_mode) {
                t8_in = br_u(r, 1);
                cab_bin(c, 399 + inc_t8(s), t8_in);
                cur->t8 = (uint8_t)t8_in;
            }
            n = t8_in ? 4 : 16;
            {
                E_DECL(c);
                for (k = 0; k < n; k++) {
                    unsigned prev = br_u(r, 1);
                    E_BIN(c, 68, prev);
                    if (!prev) {
                        unsigned rem = br_u(r, 3);
                        E_BIN(c, 69, rem & 1);
                        E_BIN(c, 69, (rem >> 1) & 1);
                        E_BIN(c, 69, (rem >> 2) & 1);
                    }
                }
                E_SAVE(c);
            }
        } else {
            unsigned t = (unsigned)it - 1;
            cur->i16 = 1;
            cur->cbp = (uint8_t)((t >= 12 ? 15 : 0) | (((t % 12) / 4) << 4));
        }
        {
            unsigned cpm = br_ue(r);
            if (cpm > 3)
                FAIL(s, "intra_chroma_pred_mode out of range");
            enc_chroma_pred(s, cpm);
            cur->cpm_nz = cpm != 0;
        }
    } else if (s->st == ST_B && mt == 0) {
        cur->direct16 = 1;
    }
    if ((s->st == ST_P && mt == 3) || (s->st == ST_B && mt == 22)) {
        no_lt8 = sub_mb_pred(s, p8ref0);
        if (no_lt8 < 0)
            return -1;
    } else if (!cur->intra && !cur->direct16) {
        if (mb_pred_inter(s, mt))
            return -1;
    }
    /* from here the residual is parsed before anything is coded (the 8x8 rule) */
    cbp = cur->cbp;
    if (!cur->i16) {
        unsigned k = br_ue(r);
        if (k > 47)
            FAIL(s, "coded_block_pattern out of range");
        cbp = cur->inxn ? cv_cbp_intra[k] : cv_cbp_inter[k];
        if ((cbp & 15) && s->pps->transform_8x8_mode && !cur->intra && no_lt8 &&
            (!cur->direct16 || s->sps->direct_8x8_inference))
            t8_in = br_u(r, 1);
    }
    if (cbp || cur->i16) {
        qpd = br_se(r);
        if (qpd < -26 || qpd > 25)
            FAIL(s, "mb_qp_delta out of range");
        if (parse_residual(s, &res, cbp, t8_in, cur->i16))
            return -1;
    }
    if (r->err)
        FAIL(s, "macroblock cut by the slice's end");
    /* docs/cavlc.md S3: an 8x8 block CAVLC codes with its cbp bit set and all 64 levels 0 */
    if (t8_in) {
        unsigned b8, zero = 0, coded = cbp & 15;
        for (b8 = 0; b8 < 4; b8++)
            if ((coded >> b8) & 1) {
                unsigned b, n = 0;
                for (b = 0; b < 4; b++)
                    n += res.l4[4 * b8 + b].n;
                if (!n)
                    zero |= 1u << b8;
            }
        if (zero) {
            cv->stats.t8_zero_blocks++;
            if (!cur->intra && zero == coded)
                t8_as_4x4 = 1;                   /* inter: the 4x4 transform, every block cbf 0 */
            else {
                cbp &= ~zero;                    /* the block not coded: same levels, same QP */
                if (!cbp && qpd) {
                    s->refuse = 1;
                    FAIL(s, "an Intra_8x8 macroblock whose only coded 8x8 blocks are all zero, with "
                            "mb_qp_delta not 0 (not expressible in CABAC)");
                }
            }
        }
    }
    if (!cur->i16) {
        enc_cbp(s, cbp);
        cur->cbp = (uint8_t)cbp;
        if ((cbp & 15) && s->pps->transform_8x8_mode && !cur->intra && no_lt8 &&
            (!cur->direct16 || s->sps->direct_8x8_inference)) {
            cur->t8 = (uint8_t)(t8_in && !t8_as_4x4);
            cab_bin(c, 399 + inc_t8(s), cur->t8);
        }
    }
    if (cbp || cur->i16) {
        enc_qp_delta(s, qpd);
        cur->qpd_nz = qpd != 0;
        enc_residual(s, &res, t8_as_4x4);
    }
    return 0;
}

/* ------------------------------------------------------------------ slice data (7.3.4) */

static void mb_begin(struct sl *s)
{
    h264ring_cavlc *cv = s->cv;
    struct mbi *m = &cv->ring[s->ri], *a, *b;
    memset(m, 0, sizeof *m);
    m->addr = s->addr;
    m->slice = s->slice;
    s->cur = m;
    a = &cv->ring[s->ri ? s->ri - 1 : cv->ring_n - 1];
    b = &cv->ring[s->ri + 1 < cv->ring_n ? s->ri + 1 : 0];
    s->A = s->x && a->addr == s->addr - 1 && a->slice == s->slice ? a : NULL;
    s->B = s->addr >= s->w && b->addr == s->addr - s->w && b->slice == s->slice ? b : NULL;
}

static void mb_end(struct sl *s)
{
    h264ring_cavlc *cv = s->cv;
    s->prev = s->cur;
    s->addr++;
    if (++s->x == s->w)
        s->x = 0;
    if (++s->ri == cv->ring_n)
        s->ri = 0;
    cv->stats.mbs++;
}

static int slice_data(struct sl *s)
{
    struct br *r = s->r;
    struct cab *c = s->c;
    int more = 1;
    for (;;) {
        if (s->st != ST_I) {
            uint32_t run = br_ue(r), k;
            if (r->err || run > s->n_mbs - s->addr)
                FAIL(s, "mb_skip_run past the picture");
            if (run)
                more = r->pos < s->stop;
            for (k = 0; k < run; k++) {
                mb_begin(s);
                s->cur->skip = 1;
                cab_bin(c, (s->st == ST_P ? 11 : 24) + (s->A && !s->A->skip) + (s->B && !s->B->skip), 1);
                cab_terminate(c, k + 1 == run && !more);
                mb_end(s);
            }
            if (!more)
                return 0;
        }
        if (s->addr >= s->n_mbs)
            FAIL(s, "slice data past the picture");
        mb_begin(s);
        if (s->st != ST_I)
            cab_bin(c, (s->st == ST_P ? 11 : 24) + (s->A && !s->A->skip) + (s->B && !s->B->skip), 0);
        if (macroblock(s))
            return -1;
        more = r->pos < s->stop;
        cab_terminate(c, !more);
        mb_end(s);
        if (!more)
            return 0;
    }
}

/* ------------------------------------------------------------------ parameter sets (7.3.2) */

static void skip_scaling_list(struct br *b, unsigned n)
{
    unsigned j, last = 8, next = 8;
    for (j = 0; j < n && !b->err; j++) {
        if (next) {
            int32_t d = br_se(b);
            next = (unsigned)((int)last + d + 256) % 256;
        }
        last = next ? next : last;
    }
}

static int is_high(unsigned p)
{
    return p == 100 || p == 110 || p == 122 || p == 244 || p == 44 || p == 83 || p == 86 ||
           p == 118 || p == 128 || p == 138 || p == 139 || p == 134 || p == 135;
}

static int parse_sps(h264ring_cavlc *cv, const uint8_t *p, size_t n)
{
    struct br b = {p, (uint32_t)(n * 8), 0, 0};
    struct sps s;
    unsigned id, cfi = 1;
    memset(&s, 0, sizeof s);
    s.profile_idc = br_u(&b, 8);
    br_u(&b, 16);                                /* constraint flags, reserved, level_idc */
    id = br_ue(&b);
    if (id > 31) {
        snprintf(cv->why, sizeof cv->why, "seq_parameter_set_id %u (0..31)", id);
        return -1;
    }
    cv->sps[id].valid = 0;                       /* replaced: valid again only if this one parses */
    if (is_high(s.profile_idc)) {
        unsigned i, nl;
        cfi = br_ue(&b);
        if (cfi == 3)
            br_u(&b, 1);                         /* separate_colour_plane_flag */
        if (cfi != 1)
            s.refuse = "chroma_format_idc other than 4:2:0";
        {
            unsigned dl = br_ue(&b), dc = br_ue(&b);  /* both read: || would skip the second */
            if (dl || dc)
                s.refuse = "bit depth above 8";
        }
        if (br_u(&b, 1))
            s.refuse = "qpprime_y_zero_transform_bypass_flag";
        if (br_u(&b, 1)) {                       /* seq_scaling_matrix_present_flag */
            nl = cfi != 3 ? 8 : 12;
            for (i = 0; i < nl; i++)
                if (br_u(&b, 1))
                    skip_scaling_list(&b, i < 6 ? 16 : 64);
        }
    }
    s.log2_max_frame_num = br_ue(&b) + 4;
    s.poc_type = br_ue(&b);
    if (s.poc_type == 0) {
        s.log2_max_poc_lsb = br_ue(&b) + 4;
    } else if (s.poc_type == 1) {
        unsigned k, cnt;
        s.delta_pic_order_always_zero = br_u(&b, 1);
        br_se(&b);
        br_se(&b);
        cnt = br_ue(&b);
        if (cnt > 255) {
            snprintf(cv->why, sizeof cv->why, "num_ref_frames_in_pic_order_cnt_cycle %u (0..255)", cnt);
            return -1;
        }
        for (k = 0; k < cnt; k++)
            br_se(&b);
    } else if (s.poc_type > 2) {
        snprintf(cv->why, sizeof cv->why, "pic_order_cnt_type %u", s.poc_type);
        return -1;
    }
    br_ue(&b);                                   /* max_num_ref_frames */
    br_u(&b, 1);                                 /* gaps_in_frame_num_value_allowed_flag */
    s.width_mbs = br_ue(&b) + 1;
    s.height_map_units = br_ue(&b) + 1;
    s.frame_mbs_only = br_u(&b, 1);
    if (!s.frame_mbs_only)
        s.mbaff = br_u(&b, 1);
    s.direct_8x8_inference = br_u(&b, 1);
    if (b.err || s.log2_max_frame_num > 16 || s.log2_max_poc_lsb > 16) {
        snprintf(cv->why, sizeof cv->why, "SPS %u malformed", id);
        return -1;
    }
    if ((uint64_t)s.width_mbs * s.height_map_units * (2 - s.frame_mbs_only) > CV_MAX_MBS) {
        snprintf(cv->why, sizeof cv->why, "SPS %u: a picture beyond Level 6.2's %u macroblocks", id, CV_MAX_MBS);
        return -1;
    }
    s.valid = 1;
    cv->sps[id] = s;
    return 0;
}

static int parse_pps(h264ring_cavlc *cv, const uint8_t *p, size_t n, uint32_t *entropy_pos)
{
    struct br b = {p, (uint32_t)(n * 8), 0, 0};
    struct pps q;
    unsigned id;
    memset(&q, 0, sizeof q);
    id = br_ue(&b);
    if (id <= 255)
        cv->pps[id].valid = 0;                   /* replaced: valid again only if this one parses */
    q.sps_id = br_ue(&b);
    if (id > 255 || q.sps_id > 31) {
        snprintf(cv->why, sizeof cv->why, "PPS id %u / SPS id %u out of range", id, q.sps_id);
        return -1;
    }
    *entropy_pos = b.pos;
    q.cabac = br_u(&b, 1);
    q.bottom_field_pic_order_in_frame_present = br_u(&b, 1);
    if (br_ue(&b)) {
        q.refuse = "slice groups (FMO, num_slice_groups_minus1 > 0)";
        q.valid = 1;
        cv->pps[id] = q;
        return 0;
    }
    q.num_ref_idx_default[0] = br_ue(&b) + 1;
    q.num_ref_idx_default[1] = br_ue(&b) + 1;
    q.weighted_pred = br_u(&b, 1);
    q.weighted_bipred_idc = br_u(&b, 2);
    q.pic_init_qp = 26 + br_se(&b);
    br_se(&b);                                   /* pic_init_qs_minus26 */
    br_se(&b);                                   /* chroma_qp_index_offset */
    q.deblocking_filter_control_present = br_u(&b, 1);
    br_u(&b, 1);                                 /* constrained_intra_pred_flag */
    q.redundant_pic_cnt_present = br_u(&b, 1);
    if (q.redundant_pic_cnt_present)
        q.refuse = "redundant pictures (redundant_pic_cnt_present_flag)";
    if (b.pos < rbsp_stop(p, n)) {               /* more_rbsp_data() */
        q.transform_8x8_mode = br_u(&b, 1);
        /* pic_scaling_matrix_present_flag and its lists, second_chroma_qp_index_offset: not
         * needed (the rewriter never re-serialises the PPS, only flips one bit) */
    }
    if (b.err || q.num_ref_idx_default[0] > CV_MAX_REFS || q.num_ref_idx_default[1] > CV_MAX_REFS ||
        q.weighted_bipred_idc > 2 || q.pic_init_qp < 0 || q.pic_init_qp > 51) {
        snprintf(cv->why, sizeof cv->why, "PPS %u malformed", id);
        return -1;
    }
    q.valid = 1;
    cv->pps[id] = q;
    return 0;
}

/* ------------------------------------------------------------------ slice header (7.3.3) */

/* returns 0 ok, -1 error (why set), 1 refused (why set) */
static int parse_sh(h264ring_cavlc *cv, struct br *b, unsigned hdr, struct sh *h)
{
    const struct pps *q;
    const struct sps *s;
    unsigned st, n_mbs;
    memset(h, 0, sizeof *h);
    h->nal_ref_idc = (hdr >> 5) & 3;
    h->nal_type = hdr & 31;
    h->first_mb = br_ue(b);
    st = br_ue(b);
    h->pps_id = br_ue(b);
    if (b->err || st > 9 || h->pps_id > 255 || !cv->pps[h->pps_id].valid) {
        snprintf(cv->why, sizeof cv->why, "slice: slice_type %u / PPS %u not sent", st, h->pps_id);
        return -1;
    }
    q = &cv->pps[h->pps_id];
    if (q->cabac)
        return 0;                                /* the caller passes it through */
    s = &cv->sps[q->sps_id];
    if (!s->valid) {
        snprintf(cv->why, sizeof cv->why, "PPS %u refers to SPS %u, not sent", h->pps_id, q->sps_id);
        return -1;
    }
    if (q->refuse || s->refuse) {
        snprintf(cv->why, sizeof cv->why, "%s", q->refuse ? q->refuse : s->refuse);
        return 1;
    }
    st %= 5;
    if (st == 3 || st == 4) {
        snprintf(cv->why, sizeof cv->why, "SP / SI slices");
        return 1;
    }
    h->slice_type = st == 0 ? ST_P : st == 1 ? ST_B : ST_I;
    h->frame_num = br_u(b, s->log2_max_frame_num);
    if (!s->frame_mbs_only) {
        h->field_pic = br_u(b, 1);
        if (h->field_pic)
            h->bottom_field = br_u(b, 1);
    }
    if (s->mbaff && !h->field_pic) {
        snprintf(cv->why, sizeof cv->why, "MBAFF (mb_adaptive_frame_field_flag)");
        return 1;
    }
    n_mbs = s->width_mbs * s->height_map_units * (2 - s->frame_mbs_only) / (h->field_pic ? 2 : 1);
    if (h->first_mb >= n_mbs) {
        snprintf(cv->why, sizeof cv->why, "first_mb_in_slice %u of %u", h->first_mb, n_mbs);
        return -1;
    }
    if (h->nal_type == 5)
        h->idr_pic_id = br_ue(b);
    if (s->poc_type == 0) {
        h->poc_lsb = br_u(b, s->log2_max_poc_lsb);
        if (q->bottom_field_pic_order_in_frame_present && !h->field_pic)
            h->dpb = br_se(b);
    }
    if (s->poc_type == 1 && !s->delta_pic_order_always_zero) {
        h->dp0 = br_se(b);
        if (q->bottom_field_pic_order_in_frame_present && !h->field_pic)
            h->dp1 = br_se(b);
    }
    /* redundant_pic_cnt: refused at its PPS */
    if (h->slice_type == ST_B)
        br_u(b, 1);                              /* direct_spatial_mv_pred_flag */
    h->num_ref[0] = q->num_ref_idx_default[0];
    h->num_ref[1] = q->num_ref_idx_default[1];
    if (h->slice_type != ST_I) {
        unsigned lx;
        if (br_u(b, 1)) {
            h->num_ref[0] = br_ue(b) + 1;
            if (h->slice_type == ST_B)
                h->num_ref[1] = br_ue(b) + 1;
        }
        if (h->num_ref[0] > CV_MAX_REFS || h->num_ref[1] > CV_MAX_REFS) {
            snprintf(cv->why, sizeof cv->why, "num_ref_idx_active above 32");
            return -1;
        }
        for (lx = 0; lx < (h->slice_type == ST_B ? 2u : 1u); lx++)
            if (br_u(b, 1)) {                    /* ref_pic_list_modification_flag_lX */
                unsigned k;
                for (k = 0;; k++) {
                    unsigned idc = br_ue(b);
                    if (idc == 3)
                        break;
                    if (idc > 5 || k > CV_MAX_REFS || b->err) {
                        snprintf(cv->why, sizeof cv->why, "ref_pic_list_modification malformed");
                        return -1;
                    }
                    br_ue(b);
                }
            }
    }
    if ((q->weighted_pred && h->slice_type == ST_P) || (q->weighted_bipred_idc == 1 && h->slice_type == ST_B)) {
        unsigned lx, i;
        br_ue(b);                                /* luma_log2_weight_denom */
        br_ue(b);                                /* chroma_log2_weight_denom (4:2:0) */
        for (lx = 0; lx < (h->slice_type == ST_B ? 2u : 1u); lx++)
            for (i = 0; i < h->num_ref[lx]; i++) {
                if (br_u(b, 1)) {
                    br_se(b);
                    br_se(b);
                }
                if (br_u(b, 1)) {
                    br_se(b); br_se(b); br_se(b); br_se(b);
                }
            }
    }
    if (h->nal_ref_idc) {
        if (h->nal_type == 5) {
            br_u(b, 2);
        } else if (br_u(b, 1)) {                 /* adaptive_ref_pic_marking_mode_flag */
            unsigned k;
            for (k = 0;; k++) {
                unsigned op = br_ue(b);
                if (op == 0)
                    break;
                if (op > 6 || k > 100 || b->err) {
                    snprintf(cv->why, sizeof cv->why, "dec_ref_pic_marking malformed");
                    return -1;
                }
                if (op == 1 || op == 3)
                    br_ue(b);
                if (op == 2)
                    br_ue(b);
                if (op == 3 || op == 6)
                    br_ue(b);
                if (op == 4)
                    br_ue(b);
            }
        }
    }
    h->pos_qp = b->pos;                          /* cabac_init_idc goes here (P / B) */
    h->qp = q->pic_init_qp + br_se(b);
    if (q->deblocking_filter_control_present) {
        unsigned idc = br_ue(b);
        if (idc > 2) {
            snprintf(cv->why, sizeof cv->why, "disable_deblocking_filter_idc %u", idc);
            return -1;
        }
        if (idc != 1) {
            br_se(b);
            br_se(b);
        }
    }
    h->pos_end = b->pos;
    if (b->err || h->qp < 0 || h->qp > 51) {
        snprintf(cv->why, sizeof cv->why, "slice header malformed");
        return -1;
    }
    return 0;
}

/* 7.4.1.2.4: the first VCL NAL unit of a new primary picture */
static int new_picture(h264ring_cavlc *cv, const struct sh *h, const struct sps *s)
{
    if (!cv->have_pic || cv->opener)
        return 1;
    if (h->pps_id != cv->pic.pps_id || h->frame_num != cv->pic.frame_num ||
        h->field_pic != cv->pic.field_pic || h->bottom_field != cv->pic.bottom_field ||
        (h->nal_ref_idc == 0) != cv->pic.ref0 || (h->nal_type == 5) != cv->pic.idr)
        return 1;
    if (h->nal_type == 5 && h->idr_pic_id != cv->pic.idr_pic_id)
        return 1;
    if (s->poc_type == 0 && (h->poc_lsb != cv->pic.poc_lsb || h->dpb != cv->pic.dpb))
        return 1;
    if (s->poc_type == 1 && (h->dp0 != cv->pic.dp0 || h->dp1 != cv->pic.dp1))
        return 1;
    return 0;
}

static int ring_size(h264ring_cavlc *cv, unsigned w)
{
    if (cv->ring_n != w + 1) {
        struct mbi *m = (struct mbi *)realloc(cv->ring, (w + 1) * sizeof *m);
        if (!m)
            return -1;
        cv->ring = m;
        cv->ring_n = w + 1;
        memset(m, 0xFF, (w + 1) * sizeof *m); /* addr / slice never match */
    }
    return 0;
}

/* one CAVLC slice NAL unit (payload p, n bytes, header byte first) -> cv->nal (escaped) */
static int rewrite_slice(h264ring_cavlc *cv, const uint8_t *p, size_t n)
{
    struct br b;
    struct sh h;
    struct bw w;
    struct cab c;
    struct sl s;
    const struct pps *q;
    const struct sps *sp;
    int rc;
    uint64_t k;
    uint32_t pic_mbs;
    if (unescape(&cv->rbsp, p + 1, n - 1)) {
        snprintf(cv->why, sizeof cv->why, "out of memory");
        return -1;
    }
    b.p = cv->rbsp.p;
    b.nbits = (uint32_t)(cv->rbsp.n * 8);
    b.pos = 0;
    b.err = 0;
    rc = parse_sh(cv, &b, p[0], &h);
    if (rc)
        return rc;
    q = &cv->pps[h.pps_id];
    sp = &cv->sps[q->sps_id];
    if (new_picture(cv, &h, sp)) {
        cv->have_pic = 1;
        cv->opener = 0;
        cv->pic.pps_id = h.pps_id;
        cv->pic.frame_num = h.frame_num;
        cv->pic.field_pic = h.field_pic;
        cv->pic.bottom_field = h.bottom_field;
        cv->pic.ref0 = h.nal_ref_idc == 0;
        cv->pic.idr = h.nal_type == 5;
        cv->pic.idr_pic_id = h.idr_pic_id;
        cv->pic.poc_lsb = h.poc_lsb;
        cv->pic.dpb = h.dpb;
        cv->pic.dp0 = h.dp0;
        cv->pic.dp1 = h.dp1;
        cv->pic_next_mb = 0;
        cv->pic_bins = 0;
        cv->pic_bytes = 0;
    } else if (h.first_mb < cv->pic_next_mb) {
        snprintf(cv->why, sizeof cv->why, "arbitrary slice order (ASO): first_mb_in_slice %u after %u",
                 h.first_mb, cv->pic_next_mb);
        return 1;
    }
    if (ring_size(cv, sp->width_mbs)) {
        snprintf(cv->why, sizeof cv->why, "out of memory");
        return -1;
    }
    /* the new RBSP: the header with cabac_init_idc and the alignment, then the slice data */
    w.acc = 0;
    w.nacc = 0;
    w.err = 0;
    w.b = &cv->nal;
    cv->nal.n = 0;
    bw_put(&w, p[0], 8);                         /* nal_unit_header (not escaped: first byte) */
    bw_copy(&w, &b, 0, h.pos_qp);
    if (h.slice_type != ST_I)
        bw_ue(&w, 0);                            /* cabac_init_idc */
    bw_copy(&w, &b, h.pos_qp, h.pos_end);
    while (w.nacc)
        bw_put(&w, 1, 1);                        /* cabac_alignment_one_bit */
    memset(&s, 0, sizeof s);
    s.cv = cv;
    s.r = &b;
    s.c = &c;
    s.sps = sp;
    s.pps = q;
    s.st = h.slice_type;
    s.field = h.field_pic;
    s.w = sp->width_mbs;
    s.n_mbs = sp->width_mbs * sp->height_map_units * (2 - sp->frame_mbs_only) / (h.field_pic ? 2 : 1);
    s.num_ref[0] = h.num_ref[0];
    s.num_ref[1] = h.num_ref[1];
    s.slice = ++cv->slice_id;
    if (cv->slice_id == 0xFFFFFFFFu)
        cv->slice_id = 0;                       /* 0xFFFFFFFF marks an empty ring slot */
    s.addr = h.first_mb;
    s.x = h.first_mb % s.w;
    s.ri = h.first_mb % cv->ring_n;
    s.stop = rbsp_stop(cv->rbsp.p, cv->rbsp.n);
    b.pos = h.pos_end;
    c.w = &w;
    c.bins = 0;
    cab_init_ctx(&c, h.qp, h.slice_type == ST_I ? 0 : 1);
    cab_start(&c);
    if (slice_data(&s)) {
        if (b.err)                               /* whatever the parse tripped on first */
            snprintf(cv->why, sizeof cv->why, "CAVLC slice (first_mb_in_slice %u): cut short in mb %u",
                     h.first_mb, s.addr);
        else
            snprintf(cv->why, sizeof cv->why, "CAVLC slice (first_mb_in_slice %u, mb %u): %s", h.first_mb,
                     s.addr, s.err ? s.err : "malformed");
        return s.refuse ? 1 : -1;
    }
    if (b.err) {
        snprintf(cv->why, sizeof cv->why, "CAVLC slice (first_mb_in_slice %u): cut short", h.first_mb);
        return -1;
    }
    while (w.nacc)
        bw_put(&w, 0, 1);                        /* rbsp_alignment_zero_bit */
    if (w.err) {
        snprintf(cv->why, sizeof cv->why, "out of memory");
        return -1;
    }
    cv->pic_next_mb = s.addr;
    /* escape into cv->rbsp's place: cv->nal holds the RBSP with its header byte */
    {
        struct buf tmp = cv->rbsp;
        tmp.n = 0;
        if (buf_put(&tmp, cv->nal.p, 1) || escape(&tmp, cv->nal.p + 1, cv->nal.n - 1)) {
            cv->rbsp = tmp;
            snprintf(cv->why, sizeof cv->why, "out of memory");
            return -1;
        }
        cv->rbsp = tmp;
    }
    /* 9.3.4.6: cabac_zero_words for the picture so far (RawMbBits 3072 at 8-bit 4:2:0) */
    cv->pic_bins += c.bins;
    cv->pic_bytes += cv->rbsp.n;
    pic_mbs = s.n_mbs;
    k = 0;
    if (32 * cv->pic_bins > 3072ull * pic_mbs) {
        uint64_t need = (3 * (32 * cv->pic_bins - 3072ull * pic_mbs) + 1023) / 1024;
        if (need > cv->pic_bytes)
            k = (need - cv->pic_bytes + 2) / 3;
    }
    if (k) {
        static const uint8_t zw[3] = {0, 0, 3};
        uint64_t i;
        for (i = 0; i < k; i++)
            if (buf_put(&cv->rbsp, zw, 3)) {
                snprintf(cv->why, sizeof cv->why, "out of memory");
                return -1;
            }
        cv->pic_bytes += 3 * k;
        cv->stats.zero_words += k;
    }
    cv->stats.bins += c.bins;
    cv->stats.slices_rewritten++;
    cv->stats.bytes_in += n;
    cv->stats.bytes_out += cv->rbsp.n;
    return 0;
}

/* ------------------------------------------------------------------ the access unit */

static int emit(h264ring_cavlc *cv, const uint8_t *in, size_t *src, size_t upto, const uint8_t *p, size_t n)
{
    if (buf_put(&cv->out, in + *src, upto - *src) || buf_put(&cv->out, p, n)) {
        snprintf(cv->why, sizeof cv->why, "a rewritten access unit above %u MB", CV_MAX_UNIT >> 20);
        return -1;
    }
    return 0;
}

int h264ring_cavlc_au(h264ring_cavlc *cv, const uint8_t *in, size_t len, const uint8_t **out, size_t *out_len)
{
    size_t i = 0, src = 0;
    int changed = 0;
    cv->why[0] = 0;
    cv->out.n = 0;
    cv->stats.units++;
    *out = in;
    *out_len = len;
    if (!cv->vt_ok) {
        snprintf(cv->why, sizeof cv->why, "out of memory (tables)");
        return H264RING_CAVLC_ERROR;
    }
    while (i + 3 <= len) {
        size_t s, e, j;
        unsigned t;
        if (!(in[i] == 0 && in[i + 1] == 0 && in[i + 2] == 1)) {
            i++;
            continue;
        }
        s = i + 3;
        for (j = s; j + 3 <= len && !(in[j] == 0 && in[j + 1] == 0 && in[j + 2] == 1); j++)
            ;
        if (j + 3 > len)
            j = len;
        e = j;
        while (e > s && in[e - 1] == 0)
            e--;
        i = j;
        if (e <= s)
            continue;
        if (in[s] & 0x80)
            continue;                            /* not a NAL unit this can read: passed, the core judges it */
        t = in[s] & 31;
        if (t == 6 || t == 7 || t == 8 || t == 9 || (t >= 14 && t <= 18))
            cv->opener = 1;
        if (t == 7) {
            if (unescape(&cv->rbsp, in + s + 1, e - s - 1)) {
                snprintf(cv->why, sizeof cv->why, "out of memory");
                return H264RING_CAVLC_ERROR;
            }
            /* an SPS this parser cannot read is passed as it is and forgotten: the rewrite never
             * stops a stream it does not need to touch (a CAVLC slice on it is an error later) */
            int sps_ok = parse_sps(cv, cv->rbsp.p, cv->rbsp.n) == 0;
            cv->why[0] = 0;                      /* not this call's verdict */
            if (sps_ok && cv->rbsp.n >= 2) {
                /* Main for a former Baseline / Extended stream; CABAC is not Baseline or Extended */
                uint8_t prof = cv->rbsp.p[0], cs = cv->rbsp.p[1];
                if (prof == 66 || prof == 88) {
                    prof = 77;
                    cs |= 0x40;
                }
                cs &= (uint8_t)~0xA0;
                if (prof != cv->rbsp.p[0] || cs != cv->rbsp.p[1]) {
                    cv->rbsp.p[0] = prof;
                    cv->rbsp.p[1] = cs;
                    cv->nal.n = 0;
                    if (buf_put(&cv->nal, in + s, 1) || escape(&cv->nal, cv->rbsp.p, cv->rbsp.n) ||
                        emit(cv, in, &src, s, cv->nal.p, cv->nal.n))
                        return H264RING_CAVLC_ERROR;
                    src = e;
                    changed = 1;
                }
            }
        } else if (t == 8) {
            uint32_t epos;
            unsigned id;
            if (unescape(&cv->rbsp, in + s + 1, e - s - 1)) {
                snprintf(cv->why, sizeof cv->why, "out of memory");
                return H264RING_CAVLC_ERROR;
            }
            if (parse_pps(cv, cv->rbsp.p, cv->rbsp.n, &epos)) {
                cv->why[0] = 0;
                continue;                        /* as an unreadable SPS: passed, forgotten */
            }
            {
                struct br b = {cv->rbsp.p, (uint32_t)(cv->rbsp.n * 8), 0, 0};
                id = br_ue(&b);
            }
            if (!cv->pps[id].cabac && !cv->pps[id].refuse) {
                cv->rbsp.p[epos >> 3] |= (uint8_t)(0x80u >> (epos & 7));    /* entropy_coding_mode_flag */
                cv->nal.n = 0;
                if (buf_put(&cv->nal, in + s, 1) || escape(&cv->nal, cv->rbsp.p, cv->rbsp.n) ||
                    emit(cv, in, &src, s, cv->nal.p, cv->nal.n))
                    return H264RING_CAVLC_ERROR;
                src = e;
                changed = 1;
            }
        } else if (t == 1 || t == 5) {
            int rc;
            /* a CABAC slice: three ue(v) of its header decide, nothing is copied */
            {
                uint8_t hb[16];
                struct br b;
                size_t m = e - s - 1 < 12 ? e - s - 1 : 12, k, z = 0, o = 0;
                unsigned pid;
                for (k = 0; k < m; k++) {        /* unescape the first bytes */
                    uint8_t c = in[s + 1 + k];
                    if (z >= 2 && c == 3) { z = 0; continue; }
                    hb[o++] = c;
                    z = c ? 0 : z + 1;
                }
                memset(hb + o, 0, sizeof hb - o);
                b.p = hb;
                b.nbits = (uint32_t)(o * 8);
                b.pos = 0;
                b.err = 0;
                br_ue(&b);
                br_ue(&b);
                pid = br_ue(&b);
                /* CABAC, or a parameter set never received (a stream joined mid-way) or not
                 * readable: passed as it is -- the core judges it, as without the rewrite */
                if (b.err || pid > 255 || !cv->pps[pid].valid || cv->pps[pid].cabac) {
                    cv->stats.slices_passed++;
                    cv->opener = 0;
                    cv->have_pic = 0;                /* not a picture of ours */
                    continue;
                }
            }
            rc = rewrite_slice(cv, in + s, e - s);
            if (rc < 0)
                return H264RING_CAVLC_ERROR;
            if (rc > 0)
                return H264RING_CAVLC_REFUSED;
            if (emit(cv, in, &src, s, cv->rbsp.p, cv->rbsp.n))
                return H264RING_CAVLC_ERROR;
            src = e;
            changed = 1;
        } else if (t >= 2 && t <= 4) {
            snprintf(cv->why, sizeof cv->why, "data partitioning (nal_unit_type %u)", t);
            return H264RING_CAVLC_REFUSED;
        }
    }
    if (!changed)
        return H264RING_CAVLC_PASS;
    if (buf_put(&cv->out, in + src, len - src)) {
        snprintf(cv->why, sizeof cv->why, "a rewritten access unit above %u MB", CV_MAX_UNIT >> 20);
        return H264RING_CAVLC_ERROR;
    }
    cv->stats.units_rewritten++;
    *out = cv->out.p;
    *out_len = cv->out.n;
    return H264RING_CAVLC_REWRITTEN;
}

/* ------------------------------------------------------------------ the context */

h264ring_cavlc *h264ring_cavlc_new(void)
{
    h264ring_cavlc *cv = (h264ring_cavlc *)calloc(1, sizeof *cv);
    unsigned i;
    int bad = 0;
    if (!cv)
        return NULL;
    for (i = 0; i < 6; i++)
        bad |= vlc_build(&cv->ct[i], cv_coeff_token_rows[i]);
    for (i = 0; i < 15; i++)
        bad |= vlc_build(&cv->tz[i], cv_total_zeros_rows[i]);
    for (i = 0; i < 3; i++)
        bad |= vlc_build(&cv->tzc[i], cv_total_zeros_cdc_rows[i]);
    for (i = 0; i < 7; i++)
        bad |= vlc_build(&cv->rb[i], cv_run_before_rows[i]);
    cv->vt_ok = !bad;
    nb_tables(cv);
    return cv;
}

void h264ring_cavlc_reset(h264ring_cavlc *cv)
{
    memset(cv->sps, 0, sizeof cv->sps);
    memset(cv->pps, 0, sizeof cv->pps);
    cv->have_pic = 0;
    cv->opener = 0;
}

void h264ring_cavlc_free(h264ring_cavlc *cv)
{
    unsigned i;
    if (!cv)
        return;
    for (i = 0; i < 6; i++) free(cv->ct[i].t2);
    for (i = 0; i < 15; i++) free(cv->tz[i].t2);
    for (i = 0; i < 3; i++) free(cv->tzc[i].t2);
    for (i = 0; i < 7; i++) free(cv->rb[i].t2);
    free(cv->rbsp.p);
    free(cv->nal.p);
    free(cv->out.p);
    free(cv->ring);
    free(cv);
}

const char *h264ring_cavlc_why(const h264ring_cavlc *cv)
{
    return cv->why;
}

void h264ring_cavlc_get_stats(const h264ring_cavlc *cv, struct h264ring_cavlc_stats *st)
{
    *st = cv->stats;
}
