/* ui -- the client's screens on the overlay plane (ui.h). */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
#include "core.h"
#include "ui.h"

#ifdef CLIENT_TEST
void *client_test_fb;                  /* the host test reads the pages drawn (tests/) */
double client_test_par;                /* (0.10) the pixel aspect and the lines the last draw used: T8 */
unsigned client_test_lines;
#endif

/* one canvas pixel is one raster pixel (the identity mapping, interface 0.9), and since 0.10 the
 * raster is not always 720 wide: Video Output "Native (HDMI)" makes it the picture's own size, up to
 * OVL_MAX_W x OVL_MAX_H (2,048 x 2,048 since interface 0.12, docs/hd_raster.md; 1,024 x 2,047 at 0.10).
 * The canvas is drawn for the raster the caller passes (h264ring_raster: w x h), its rows the raster's
 * width apart (rounded to 8 bytes), two pages of it in the framebuffer. /dev/fb0 is NOT MiSTer_fb's
 * whole 8 MB region: Main sizes it to its HDMI mode (width x height x 4: 1,382,400 bytes at 720x480,
 * 3,686,400 at 1280x720, 8,294,400 at 1920x1080 -- measured, docs/hd_raster.md S13). So the pages are
 * laid out again whenever the raster changes, and a raster taller than two pages of it fit is drawn
 * to the lines that fit (the core centres the canvas: the UI shorter, clipped by nothing; logged).
 * A fixed 2,048-pixel row (0.12's first try) left a 1280x720 mode 450 lines: no UI at all. */
#define MIN_FB     (2u * 720u * 2u * 480u)            /* two pages of the smallest raster: 720x480's fb */
/* the safe area (2026-10-06: text cut off on a CRT): on an SD raster (at most 576 lines -- the analog
 * rasters, Interlaced or Progressive, and an SD picture's native one, which a TV overscans too) every
 * screen keeps inside TITLE-safe, 10 % of the width and of the lines in from each edge (SMPTE RP 27.3;
 * 72 px x 48 / 57 lines at 720 x 480 / 576) -- 40 px and 28 lines (~5.5 %, about action-safe) were cut
 * by a CRT's overscan. A larger (native HD) raster keeps 40 px x 28 lines. Panels may reach 10 px
 * outside it (their background only). */
#define SAFE_X_HD  40
#define SAFE_Y_HD  28
#define FRAME_MS   125             /* redraws at most 8 times a second */
#define GLYPHS     512
#define SAVER_IN_MS    2000        /* the saver's line: fades in, */
#define SAVER_HOLD_MS  6000        /* holds, */
#define SAVER_OUT_MS   2000        /* fades out, */
#define SAVER_GAP_MS   1000        /* and comes back elsewhere */

/* 4444: A [15:12], R [11:8], G [7:4], B [3:0], straight alpha */
#define C_WHITE   0xFFFFu
#define C_GREY    0xFBBBu
#define C_ACCENT  0xF4AEu          /* Jellyfin's purple-blue, roughly */
#define C_PANEL   0xD111u          /* dark, translucent */
#define C_TRACK   0xF444u

struct glyph { int font, px, cp; unsigned char *bm; int w, h, xo, yo; float adv; };

struct ui {
    h264ring *r;
    struct h264ring_fb fb;
    int mapped;
    stbtt_fontinfo font[2];          /* 0 regular, 1 bold */
    unsigned char *ttf[2];
    struct glyph cache[GLYPHS];
    float par;                       /* the raster's pixel aspect (width / height of a pixel) */
    unsigned w, lines;               /* the canvas: the raster's width and lines (clamped to what fits) */
    unsigned stride;                 /* pixels a row: the raster's width, a multiple of 4 (8 bytes) */
    size_t page_bytes;               /* two pages of stride x lines from the framebuffer's start */
    int cur;                         /* the page shown (-1 none) */
    int pending_gen;                 /* a flip the core has not read yet */
    int shown;                       /* the overlay is on */
    int dirty;
    uint64_t last_ms, panel_until, msg_until;
    int panel_on;
    /* what to show */
    int card;
    char c_title[96], c_line[160], c_big[32], c_foot[160], c_note[160];
    struct ui_list list;
    int listed;
    int playing;
    char title[160], sub[160], audio[96], subs[96];
    double pos, dur;
    int paused, loading, seeking;
    char msg_h[96], msg_t[200];
    char subtitle[512];
    int last_sec;
    /* the screensaver */
    unsigned dim_ms, black_ms;
    uint64_t act_ms;                 /* the last activity */
    int busy, saver;                 /* video playing; the stage drawn (0 / 1 / 2) */
    uint64_t cyc_ms;                 /* the line's cycle started */
    int sx, sy, s_alpha;             /* its place (left, baseline) and the alpha last drawn */
    int mx, my;                      /* the safe area's margins (left / right, top / bottom) at u->w x u->lines */
};

/* ---- pixels ---- */

static uint16_t *page(struct ui *u, int n) { return (uint16_t *)((uint8_t *)u->fb.virt + (size_t)n * u->page_bytes); }

/* src (4444 colour, coverage 0..255) over dst, straight alpha */
static inline uint16_t over(uint16_t d, uint16_t c, unsigned cov)
{
    unsigned sa = ((c >> 12) * 17u * cov + 127u) / 255u;          /* 0..255 */
    if (!sa) return d;
    unsigned da = (d >> 12) * 17u;
    unsigned oa = sa + da * (255u - sa) / 255u;
    unsigned out = (oa * 15u + 127u) / 255u << 12;
    for (int sh = 8; sh >= 0; sh -= 4) {
        unsigned s = ((c >> sh) & 15u) * 17u, t = ((d >> sh) & 15u) * 17u;
        unsigned v = oa ? (s * sa + t * da * (255u - sa) / 255u) / oa : 0;
        out |= ((v * 15u + 127u) / 255u) << sh;
    }
    return (uint16_t)out;
}

static void fill(const struct ui *u, uint16_t *pg, int x, int y, int w, int h, uint16_t c)
{
    for (int j = y < 0 ? 0 : y; j < y + h && j < (int)u->lines; j++)
        for (int i = x < 0 ? 0 : x; i < x + w && i < (int)u->w; i++)
            pg[(size_t)j * u->stride + (size_t)i] = c;
}

/* ---- text ---- */

static unsigned utf8(const char **s)
{
    const unsigned char *p = (const unsigned char *)*s;
    unsigned c = *p++;
    int n = c < 0x80 ? 0 : c < 0xE0 ? 1 : c < 0xF0 ? 2 : 3;
    if (n) c &= 0x3Fu >> n;
    while (n-- && (*p & 0xC0) == 0x80) c = c << 6 | (*p++ & 0x3Fu);
    *s = (const char *)p;
    return c;
}

static struct glyph *glyph(struct ui *u, int f, int px, unsigned cp)
{
    unsigned h = (cp * 2654435761u ^ (unsigned)px * 40503u ^ (unsigned)f) % GLYPHS;
    struct glyph *g = &u->cache[h];
    if (g->bm && g->font == f && g->px == px && g->cp == (int)cp) return g;
    if (g->bm) stbtt_FreeBitmap(g->bm, NULL);
    /* par is a raster pixel's width / height (0.889 on the 4:3 raster: narrow pixels), so a glyph
     * takes 1 / par as many pixels across to look right (it was * par: text ~21 % too narrow) */
    float sy = stbtt_ScaleForPixelHeight(&u->font[f], (float)px), sx = sy / u->par;
    int adv, lsb;
    stbtt_GetCodepointHMetrics(&u->font[f], (int)cp, &adv, &lsb);
    g->font = f; g->px = px; g->cp = (int)cp;
    g->adv = (float)adv * sx;
    g->bm = stbtt_GetCodepointBitmap(&u->font[f], sx, sy, (int)cp, &g->w, &g->h, &g->xo, &g->yo);
    if (!g->bm) { g->bm = (unsigned char *)calloc(1, 1); g->w = g->h = 0; }
    return g;
}

static float text_w(struct ui *u, int f, int px, const char *s)
{
    float w = 0;
    while (*s) w += glyph(u, f, px, utf8(&s))->adv;
    return w;
}

/* draw at (x, baseline); outline: a black edge of `outline` pixels first (subtitles over video) */
static float text(struct ui *u, uint16_t *pg, float x, int base, int f, int px, uint16_t c, const char *s,
                  float max_w, int outline)
{
    float x0 = x;
    while (*s) {
        unsigned cp = utf8(&s);
        struct glyph *g = glyph(u, f, px, cp);
        if (max_w > 0 && x + g->adv - x0 > max_w) break;
        int gx = (int)(x + 0.5f) + g->xo, gy = base + g->yo;
        for (int pass = outline ? 0 : 1; pass < 2; pass++) {
            int r = pass ? 0 : outline;
            uint16_t col = pass ? c : 0xF000u;
            for (int j = -r; j < g->h + r; j++)
                for (int i = -r; i < g->w + r; i++) {
                    unsigned cov = 0;
                    if (r) {                                   /* the coverage dilated by r */
                        for (int dj = -r; dj <= r && cov < 255; dj++)
                            for (int di = -r; di <= r; di++) {
                                int jj = j + dj, ii = i + di;
                                if (jj >= 0 && jj < g->h && ii >= 0 && ii < g->w && g->bm[jj * g->w + ii] > cov)
                                    cov = g->bm[jj * g->w + ii];
                            }
                    } else if (j >= 0 && j < g->h && i >= 0 && i < g->w) {
                        cov = g->bm[j * g->w + i];
                    }
                    int X = gx + i, Y = gy + j;
                    if (cov && X >= 0 && X < (int)u->w && Y >= 0 && Y < (int)u->lines)
                        pg[(size_t)Y * u->stride + (size_t)X] = over(pg[(size_t)Y * u->stride + (size_t)X], col, cov);
                }
        }
        x += g->adv;
    }
    return x - x0;
}

static void text_c(struct ui *u, uint16_t *pg, int base, int f, int px, uint16_t c, const char *s, int outline)
{
    float maxw = (float)(u->w - 2 * u->mx), w = text_w(u, f, px, s);
    text(u, pg, (float)u->w / 2 - (w < maxw ? w : maxw) / 2, base, f, px, c, s, maxw, outline);
}

/* the next line of `s` that fits maxw (word-wrapped); returns its length, *next the rest */
static size_t wrap(struct ui *u, int f, int px, const char *s, float maxw, const char **next)
{
    size_t best = 0;
    float w = 0;
    const char *p = s;
    while (*p && *p != '\n') {
        const char *q = p;
        unsigned cp = utf8(&q);
        w += glyph(u, f, px, cp)->adv;
        if (w > maxw && best) break;
        if (cp == ' ') best = (size_t)(p - s);
        p = q;
        if (!*p || *p == '\n') best = (size_t)(p - s);
    }
    if (!best) best = (size_t)(p - s);
    const char *n = s + best;
    while (*n == ' ' || *n == '\n') n++;
    *next = n;
    return best;
}

static void fmt_time(char *b, size_t n, double s)
{
    if (s < 0) s = 0;
    unsigned t = (unsigned)s;
    if (t >= 3600) snprintf(b, n, "%u:%02u:%02u", t / 3600, t / 60 % 60, t % 60);
    else snprintf(b, n, "%u:%02u", t / 60, t % 60);
}

/* ---- the screens ---- */

static int wrap_at(struct ui *u, int f, int px, const char *s, float w, const char **st, size_t *len, int n)
{
    int k = 0;
    while (*s && k < n) {
        const char *nx;
        len[k] = wrap(u, f, px, s, w, &nx);
        st[k++] = s;
        s = nx;
    }
    return *s ? n + 1 : k;              /* n + 1: more than n lines at this width */
}

/* the lines `s` word-wraps to within maxw, at most n (the rest dropped): their starts and lengths -- BALANCED:
 * as many lines as maxw needs, at the narrowest width that still needs no more (no lone last word) */
static int wrap_lines(struct ui *u, int f, int px, const char *s, float maxw, const char **st, size_t *len, int n)
{
    int k = wrap_at(u, f, px, s, maxw, st, len, n);
    if (k > n) return wrap_at(u, f, px, s, maxw, st, len, n), n;
    if (k > 1) {
        float lo = maxw / (float)k, hi = maxw;
        for (int i = 0; i < 12; i++) {                 /* the narrowest width keeping k lines */
            float mid = (lo + hi) / 2;
            if (wrap_at(u, f, px, s, mid, st, len, n) == k) hi = mid; else lo = mid;
        }
        wrap_at(u, f, px, s, hi, st, len, n);
    }
    return k;
}

/* a wrapped block, each line centred, `pitch` apart from baseline `y` */
static void text_c_lines(struct ui *u, uint16_t *pg, int y, int f, int px, uint16_t c, const char *const *st,
                         const size_t *len, int n, int pitch)
{
    char b[192];
    for (int i = 0; i < n; i++) {
        size_t l = len[i] < sizeof b - 1 ? len[i] : sizeof b - 1;
        memcpy(b, st[i], l);
        b[l] = 0;
        text_c(u, pg, y + i * pitch, f, px, c, b, 0);
    }
}

#define CARD_PAD   16              /* the text's margin inside the card, each side */
#define CARD_PITCH 26              /* a wrapped line's pitch */

static void draw_card(struct ui *u, uint16_t *pg, int *y0, int *y1)
{
    int big = u->c_big[0] != 0, lpx = big ? 20 : 21;
    /* the line and the note wrap to the card's width (the card is the title-safe width on an SD raster:
     * "...play it on this MiSTer" ran past it at 720 wide), up to three lines each; the card grows */
    float maxw = (float)((int)u->w - 2 * u->mx - 2 * CARD_PAD);
    const char *ls[3], *ns[3];
    size_t ll[3], nl_[3];
    int nl = u->c_line[0] ? wrap_lines(u, 0, lpx, u->c_line, maxw, ls, ll, 3) : 0;
    int nn = u->c_note[0] ? wrap_lines(u, 0, 18, u->c_note, maxw, ns, nl_, 3) : 0;
    int extra = (nl > 1 ? (nl - 1) * CARD_PITCH : 0) + (nn > 1 ? (nn - 1) * CARD_PITCH : 0);
    int top = (int)u->lines / 2 - (big ? 120 : 80) - extra / 2, h = (big ? 240 : 160) + extra;
    fill(u, pg, u->mx, top, (int)u->w - 2 * u->mx, h, C_PANEL);
    int y = top + 46;
    text_c(u, pg, y, 1, 34, C_WHITE, u->c_title, 0);
    y += 38;
    text_c_lines(u, pg, y, 0, lpx, C_GREY, ls, ll, nl, CARD_PITCH);
    y += nl > 1 ? (nl - 1) * CARD_PITCH : 0;
    if (big) {
        y += 70;
        text_c(u, pg, y, 1, 60, C_ACCENT, u->c_big, 0);
        y += 44;
    } else {
        y += 34;
    }
    if (u->c_foot[0]) text_c(u, pg, y, 0, 18, C_GREY, u->c_foot, 0);
    y += 28;
    text_c_lines(u, pg, y, 0, 18, C_ACCENT, ns, nl_, nn, CARD_PITCH);
    *y0 = top; *y1 = top + h - 1;
}

#define LIST_ROW   30              /* a row's pitch */
#define LIST_HEAD  52              /* the title's band */
#define LIST_HINT  36              /* the hint's band, at the safe area's foot */

unsigned ui_list_rows(const struct ui *u)
{
    unsigned lines = u->lines ? u->lines : 480u, my = u->lines ? (unsigned)u->my : 48u;
    return (lines - 2u * my - LIST_HEAD - LIST_HINT) / LIST_ROW;
}

/* the list: the safe area's panel, the title, a page of rows around sel, the hint */
static void draw_list(struct ui *u, uint16_t *pg, int *y0, int *y1)
{
    const struct ui_list *l = &u->list;
    int top = u->my, bottom = (int)u->lines - u->my;
    fill(u, pg, u->mx - 10, top, (int)u->w - 2 * u->mx + 20, bottom - top, C_PANEL);
    float maxw = (float)(u->w - 2 * u->mx);
    text(u, pg, u->mx, top + 34, 1, 24, C_WHITE, l->title ? l->title : "", maxw, 0);
    unsigned page = ui_list_rows(u), first = 0;
    if (l->n > page && l->sel >= page / 2) first = l->sel - page / 2;
    if (l->n > page && first > l->n - page) first = l->n - page;
    int y = top + LIST_HEAD;
    if (!l->n && l->empty) text(u, pg, u->mx, y + 22, 0, 20, C_GREY, l->empty, maxw, 0);
    for (unsigned i = first; i < l->n && i < first + page; i++, y += LIST_ROW) {
        int on = i == l->sel;
        if (on) fill(u, pg, u->mx - 6, y, (int)u->w - 2 * u->mx + 12, LIST_ROW - 2, C_ACCENT);
        text(u, pg, u->mx, y + 21, on, 20, on ? C_WHITE : C_GREY, l->rows[i] ? l->rows[i] : "", maxw, 0);
    }
    if (l->n > page) {                               /* where the page is: a thin bar at the right */
        int track = (int)(page * LIST_ROW), th = track * (int)page / (int)l->n;
        if (th < 8) th = 8;
        int ty = top + LIST_HEAD + (track - th) * (int)first / (int)(l->n - page);
        fill(u, pg, (int)u->w - u->mx + 4, ty, 3, th, C_GREY);
    }
    if (l->hint) text_c(u, pg, bottom - 14, 0, 17, C_GREY, l->hint, 0);
    *y0 = top; *y1 = bottom - 1;
}

static void draw_panel(struct ui *u, uint16_t *pg, int *y0, int *y1)
{
    int h = 104, top = (int)u->lines - h - u->my;
    fill(u, pg, u->mx - 10, top, (int)u->w - 2 * u->mx + 20, h, C_PANEL);
    float maxw = (float)(u->w - 2 * u->mx);
    text(u, pg, u->mx, top + 30, 1, 24, C_WHITE, u->title, maxw - 90, 0);
    const char *label = u->seeking ? "Seek" : u->loading ? "Loading" : u->paused ? "Paused" : NULL;
    if (label) {
        float w = text_w(u, 1, 20, label);
        text(u, pg, (float)(u->w - u->mx) - w, top + 30, 1, 20, C_ACCENT, label, 0, 0);
    }
    if (u->sub[0]) text(u, pg, u->mx, top + 54, 0, 18, C_GREY, u->sub, maxw, 0);
    /* the progress */
    int bx = u->mx, bw = (int)u->w - 2 * u->mx, by = top + 66;
    fill(u, pg, bx, by, bw, 6, C_TRACK);
    if (u->dur > 0) {
        double f = u->pos / u->dur;
        fill(u, pg, bx, by, (int)(bw * (f < 0 ? 0 : f > 1 ? 1 : f)), 6, C_ACCENT);
    }
    char a[24], b[24], t[64];
    fmt_time(a, sizeof a, u->pos);
    fmt_time(b, sizeof b, u->dur);
    snprintf(t, sizeof t, "%s / %s", a, b);
    text(u, pg, u->mx, top + 94, 0, 18, C_GREY, t, 0, 0);
    char tracks[200];
    snprintf(tracks, sizeof tracks, "%s%s%s", u->audio, u->subs[0] ? "  |  " : "", u->subs);
    float tw = text_w(u, 0, 16, tracks);
    if (tw > maxw / 2) tw = maxw / 2;
    text(u, pg, (float)(u->w - u->mx) - tw, top + 94, 0, 16, C_GREY, tracks, maxw / 2, 0);
    *y0 = top; *y1 = top + h - 1;
}

static void draw_message(struct ui *u, uint16_t *pg, int *y0, int *y1)
{
    /* at the top; over a list, at its foot instead (above the hint), clear of its title and rows */
    int h = u->msg_t[0] ? 74 : 46;
    int top = u->listed && !u->playing ? (int)u->lines - u->my - LIST_HINT - 8 - h : u->my;
    fill(u, pg, u->mx, top, (int)u->w - 2 * u->mx, h, C_PANEL);
    text_c(u, pg, top + 32, 1, 22, C_WHITE, u->msg_h, 0);
    if (u->msg_t[0]) text_c(u, pg, top + 60, 0, 18, C_GREY, u->msg_t, 0);
    *y0 = top; *y1 = top + h - 1;
}

/* the subtitle, bottom-up, above the panel when it is shown */
static void draw_subtitle(struct ui *u, uint16_t *pg, int bottom, int *y0, int *y1)
{
    const char *lines[4];
    size_t lens[4];
    int n = 0, px = 30, step = 36;
    const char *s = u->subtitle;
    float maxw = (float)(u->w - 2 * u->mx);
    while (*s && n < 4) {
        const char *next;
        lens[n] = wrap(u, 1, px, s, maxw, &next);
        lines[n++] = s;
        s = next;
    }
    int base = bottom;
    *y1 = base + 10;
    for (int i = n - 1; i >= 0; i--) {
        char l[512];
        size_t k = lens[i] < sizeof l - 1 ? lens[i] : sizeof l - 1;
        memcpy(l, lines[i], k);
        l[k] = 0;
        text_c(u, pg, base, 1, px, C_WHITE, l, 2);
        base -= step;
    }
    *y0 = base + step - px - 4;
}

/* the line the saver shows: what is up */
static void saver_text(const struct ui *u, char *b, size_t n)
{
    char t[24];
    if (u->playing) {
        fmt_time(t, sizeof t, u->pos);
        snprintf(b, n, "%s  \u00b7  %s  \u00b7  %s", u->paused ? "Paused" : "Stopped", u->title, t);
    } else if (u->listed) {
        snprintf(b, n, "%s", u->list.title ? u->list.title : "");
    } else if (u->card) {
        snprintf(b, n, "%s%s%s", u->c_title, u->c_big[0] ? ":  " : "", u->c_big);
    } else {
        b[0] = 0;
    }
}

/* the stage due now (0 / 1 / 2) */
static int saver_stage(const struct ui *u, uint64_t now)
{
    if (u->busy) return 0;
    uint64_t idle = now - u->act_ms;
    if (u->black_ms && idle >= u->black_ms) return 2;
    if (u->dim_ms && idle >= u->dim_ms) return 1;
    return 0;
}

/* the line's alpha (0..15) in its cycle, and a new place at each cycle's start */
static int saver_alpha(struct ui *u, uint64_t now, float tw)
{
    uint64_t cyc = SAVER_IN_MS + SAVER_HOLD_MS + SAVER_OUT_MS + SAVER_GAP_MS;
    if (!u->cyc_ms || now - u->cyc_ms >= cyc) {
        u->cyc_ms = now;
        int span_x = (int)u->w - 2 * u->mx - (int)tw, span_y = (int)u->lines - 2 * u->my;
        u->sx = u->mx + (span_x > 0 ? rand() % span_x : 0);
        u->sy = u->my + 24 + (span_y > 24 ? rand() % (span_y - 24) : 0);
    }
    uint64_t k = now - u->cyc_ms;
    float a = k < SAVER_IN_MS ? (float)k / SAVER_IN_MS
            : k < SAVER_IN_MS + SAVER_HOLD_MS ? 1.0f
            : k < SAVER_IN_MS + SAVER_HOLD_MS + SAVER_OUT_MS ? 1.0f - (float)(k - SAVER_IN_MS - SAVER_HOLD_MS) / SAVER_OUT_MS
            : 0.0f;
    return (int)(a * 11.0f + 0.5f);              /* at most 11 / 15: a dim grey line, never full white */
}

void ui_draw(struct ui *u, unsigned w, unsigned lines, double aspect)
{
    uint64_t now = now_ms();
    if (!(aspect > 0.2 && aspect < 5.0)) aspect = 4.0 / 3.0;
    if (!w) w = 720u;
    if (!lines) lines = 480u;
    /* the pixel aspect of the raster as a whole (shown at `aspect`), before the canvas is clamped */
    float par = (float)(aspect * (double)lines / (double)w);
    if (w > H264RING_OVL_MAX_W) w = H264RING_OVL_MAX_W;
    unsigned stride = (w + 3u) & ~3u;                /* 4444: a row a multiple of 8 bytes */
    size_t fit = u->fb.len / ((size_t)2u * stride * 2u);
    if (fit > H264RING_OVL_MAX_H) fit = H264RING_OVL_MAX_H;
    if (lines > fit) {                               /* taller than two pages fit: shorter, centred by the core */
        if (stride != u->stride || (unsigned)fit != u->lines)
            fprintf(stderr, "ui: the framebuffer (%u bytes, Main's HDMI mode) holds two pages of %u x %u: "
                    "the raster's %u lines drawn to %u\n", (unsigned)u->fb.len, w, (unsigned)fit, lines, (unsigned)fit);
        lines = (unsigned)fit;
    }
    if (stride != u->stride || lines != u->lines) {
        /* the pages move: hide first, and draw into neither until the core has taken that (the
         * pending generation, below) -- the page shown may overlap either new one */
        if (u->shown) { int g = h264ring_overlay_hide(u->r); if (g > 0) u->pending_gen = g; u->shown = 0; }
        u->stride = stride;
        u->page_bytes = (size_t)stride * 2u * lines;
        u->cur = -1;
    }
    if (w != u->w || lines != u->lines || par < u->par * 0.995f || par > u->par * 1.005f) {
        u->w = w; u->lines = lines; u->par = par; u->dirty = 1;
        u->mx = lines <= 576u ? (int)(w / 10u) : SAFE_X_HD;
        u->my = lines <= 576u ? (int)(lines / 10u) : SAFE_Y_HD;
#ifdef CLIENT_TEST
        client_test_par = par; client_test_lines = lines;
#endif
        for (unsigned i = 0; i < GLYPHS; i++) if (u->cache[i].bm) { stbtt_FreeBitmap(u->cache[i].bm, NULL); u->cache[i].bm = NULL; } }
    if (u->panel_on && u->panel_until && now >= u->panel_until) { u->panel_on = 0; u->dirty = 1; }
    if (u->msg_h[0] && now >= u->msg_until) { u->msg_h[0] = u->msg_t[0] = 0; u->dirty = 1; }
    if (u->playing && u->panel_on && (int)u->pos != u->last_sec) { u->last_sec = (int)u->pos; u->dirty = 1; }
    if (u->busy) u->act_ms = now;
    int stage = saver_stage(u, now);
    char stext[300] = "";
    float stw = 0;
    int salpha = 0;
    if (stage != u->saver) { u->saver = stage; u->cyc_ms = 0; u->dirty = 1; }
    if (stage && u->lines) {
        saver_text(u, stext, sizeof stext);
        stw = text_w(u, 0, 22, stext);
        salpha = saver_alpha(u, now, stw);
        if (salpha != u->s_alpha) { u->s_alpha = salpha; u->dirty = 1; }
    }
    if (!u->dirty || now - u->last_ms < FRAME_MS) return;
    if (u->pending_gen > 0) {
        /* the page we are about to draw into may still be read: wait until the core has taken the
         * flip's descriptor -- or a LATER one: every session start (each new stream's flush)
         * re-writes this program's descriptor with a newer generation, so "equal" may never come */
        struct h264ring_status st;
        if (h264ring_status(u->r, &st)) return;
        if ((int32_t)((uint32_t)H264RING_ST(&st, OVL_GEN) - (uint32_t)u->pending_gen) < 0) return;
        if (H264RING_ST(&st, OVL_STATE) == H264RING_OVL_S_REFUSED)
            fprintf(stderr, "ui: the core refused the overlay (ovl_err %u)\n", (unsigned)H264RING_ST(&st, OVL_ERR));
        u->pending_gen = 0;
    }
    int n = u->cur == 0 ? 1 : 0;
    uint16_t *pg = page(u, n);
    memset(pg, 0, u->page_bytes);
    int lo = (int)u->lines, hi = -1, a, b;
#define SPAN(fn, ...) do { fn(u, pg, __VA_ARGS__ &a, &b); if (a < lo) lo = a; if (b > hi) hi = b; } while (0)
    if (u->saver) {                                  /* the veil over everything, the line, nothing else */
        fill(u, pg, 0, 0, (int)u->w, (int)u->lines, u->saver == 2 ? 0xF000u : 0xB000u);
        if (salpha && stext[0])
            text(u, pg, (float)u->sx, u->sy, 0, 22, (uint16_t)(0x0BBBu | (unsigned)salpha << 12), stext, 0, 0);
        lo = 0; hi = (int)u->lines - 1;
    } else {
    if (u->card && !u->playing && !u->listed) SPAN(draw_card, );
    if (u->listed && !u->playing) SPAN(draw_list, );
    if (u->playing && (u->panel_on || u->paused || u->loading || u->seeking)) SPAN(draw_panel, );
    if (u->msg_h[0]) SPAN(draw_message, );
    if (u->playing && u->subtitle[0]) {
        int bottom = (int)u->lines - u->my - 12 - ((u->panel_on || u->paused || u->loading || u->seeking) ? 104 + 16 : 0);
        SPAN(draw_subtitle, bottom, );
    }
    }
#undef SPAN
    u->dirty = 0;
    u->last_ms = now;
    if (hi < 0) {                                   /* nothing to show */
        /* (a re-layout may follow: the core must have let go of the page before either is drawn) */
        if (u->shown) { int g = h264ring_overlay_hide(u->r); if (g > 0) u->pending_gen = g; u->shown = 0; }
        return;
    }
    if (lo < 0) lo = 0;
    if (hi >= (int)u->lines) hi = (int)u->lines - 1;
    struct h264ring_overlay o = {
        .base = u->fb.phys + (uint32_t)(n * u->page_bytes), .width = (uint16_t)u->w, .height = (uint16_t)u->lines,
        .stride = (uint16_t)(u->stride * 2u), .format = H264RING_OVL_FMT_4444,
        .band_first = (uint16_t)lo, .band_last = (uint16_t)hi,
    };
    int gen = h264ring_overlay_show(u->r, &o);
    if (gen > 0) { u->pending_gen = gen; u->cur = n; u->shown = 1; }
    else fprintf(stderr, "ui: overlay: %s\n", strerror(-gen));
}

/* ---- state ---- */

void ui_saver_times(struct ui *u, unsigned dim_ms, unsigned black_ms)
{
    u->dim_ms = dim_ms;
    u->black_ms = black_ms;
}

void ui_activity(struct ui *u) { u->act_ms = now_ms(); }

void ui_busy(struct ui *u, int busy) { u->busy = busy; }

int ui_wake(struct ui *u)
{
    int was = u->saver || saver_stage(u, now_ms());
    u->act_ms = now_ms();
    return was;
}

int ui_saver_level(const struct ui *u) { return u->saver; }

void ui_card(struct ui *u, const struct ui_card *c)
{
    u->card = c != NULL;
    if (c) {
        snprintf(u->c_title, sizeof u->c_title, "%s", c->title ? c->title : "");
        snprintf(u->c_line, sizeof u->c_line, "%s", c->line ? c->line : "");
        snprintf(u->c_big, sizeof u->c_big, "%s", c->big ? c->big : "");
        snprintf(u->c_foot, sizeof u->c_foot, "%s", c->foot ? c->foot : "");
        snprintf(u->c_note, sizeof u->c_note, "%s", c->note ? c->note : "");
    }
    u->dirty = 1;
}

void ui_list(struct ui *u, const struct ui_list *l)
{
    u->listed = l != NULL;
    if (l) u->list = *l;
    u->dirty = 1;
}

void ui_playing(struct ui *u, const struct ui_now *now)
{
    if (!now) { if (u->playing) u->dirty = 1; u->playing = 0; u->subtitle[0] = 0; return; }
    if (!u->playing || strcmp(u->title, now->title) || u->paused != now->paused ||
        u->loading != now->loading || u->seeking != now->seeking || (now->seeking && u->pos != now->position) ||
        strcmp(u->audio, now->audio ? now->audio : "") || strcmp(u->subs, now->subs ? now->subs : ""))
        u->dirty = 1;
    u->playing = 1;
    snprintf(u->title, sizeof u->title, "%s", now->title ? now->title : "");
    snprintf(u->sub, sizeof u->sub, "%s", now->subtitle ? now->subtitle : "");
    snprintf(u->audio, sizeof u->audio, "%s", now->audio ? now->audio : "");
    snprintf(u->subs, sizeof u->subs, "%s", now->subs ? now->subs : "");
    u->pos = now->position;
    u->dur = now->duration;
    u->paused = now->paused;
    u->loading = now->loading;
    u->seeking = now->seeking;
}

void ui_panel(struct ui *u, unsigned show_ms)
{
    u->panel_on = 1;
    u->panel_until = show_ms ? now_ms() + show_ms : 0;
    u->dirty = 1;
}

void ui_panel_hide(struct ui *u) { if (u->panel_on) u->dirty = 1; u->panel_on = 0; }

void ui_message(struct ui *u, const char *header, const char *text, unsigned ms)
{
    snprintf(u->msg_h, sizeof u->msg_h, "%s", header ? header : "");
    snprintf(u->msg_t, sizeof u->msg_t, "%s", text ? text : "");
    u->msg_until = now_ms() + ms;
    u->dirty = 1;
}

void ui_subtitle(struct ui *u, const char *t)
{
    if (!t) t = "";
    if (strcmp(u->subtitle, t)) { snprintf(u->subtitle, sizeof u->subtitle, "%s", t); u->dirty = 1; }
}

static unsigned char *slurp(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *p = n > 0 ? malloc((size_t)n) : NULL;
    if (p && fread(p, 1, (size_t)n, f) != (size_t)n) { free(p); p = NULL; }
    fclose(f);
    return p;
}

int ui_open(struct ui **pu, h264ring *r, const char *fontdir)
{
    struct ui *u = calloc(1, sizeof *u);
    if (!u) return -ENOMEM;
    u->r = r;
    u->cur = -1;
    static const char *const names[2] = {"DejaVuSans.ttf", "DejaVuSans-Bold.ttf"};
    for (int i = 0; i < 2; i++) {
        char path[600];
        snprintf(path, sizeof path, "%s/%s", fontdir, names[i]);
        u->ttf[i] = slurp(path);
        if (!u->ttf[i] || !stbtt_InitFont(&u->font[i], u->ttf[i], stbtt_GetFontOffsetForIndex(u->ttf[i], 0))) {
            fprintf(stderr, "ui: the typeface %s did not load\n", path);
            ui_close(u);
            return -ENOENT;
        }
    }
#ifdef CLIENT_TEST
    /* the host test: the pages in memory, at the address the real framebuffer would have */
    extern void *client_test_fb;
    /* the framebuffer's size follows Main's HDMI mode: CLIENT_TEST_FB_LEN models one (default the
     * whole region less the page the device skips) */
    const char *fbl = getenv("CLIENT_TEST_FB_LEN");
    u->fb.len = fbl ? (uint32_t)strtoul(fbl, NULL, 0) : H264RING_FB_SIZE - 0x1000u;
    /* the memory behind it the core's whole region, so a page laid out past fb.len is scored by the
     * fake core (test_player T9) instead of crashing the test */
    u->fb.virt = client_test_fb = calloc(1, H264RING_FB_SIZE - 0x1000u);
    u->fb.phys = H264RING_FB_BYTE + 0x1000u;
    int rc = u->fb.virt ? 0 : -ENOMEM;
#else
    int rc = h264ring_fb_map(&u->fb);
#endif
    /* the pages are laid out for each raster (ui_draw); here only: two of the smallest raster fit */
    if (rc || u->fb.len < MIN_FB) {
        if (rc) fprintf(stderr, "ui: the framebuffer: %s\n", strerror(-rc));
        else fprintf(stderr, "ui: the framebuffer: too small (%u bytes, Main's HDMI mode; %u needed)\n",
                     (unsigned)u->fb.len, MIN_FB);
        ui_close(u);
        return rc ? rc : -ENOSPC;
    }
    u->mapped = 1;
    u->lines = 0;
    u->act_ms = now_ms();
    u->dim_ms = 5u * 60u * 1000u;                    /* P5's defaults; the program's ini may change them */
    u->black_ms = 30u * 60u * 1000u;
    srand((unsigned)u->act_ms);
    *pu = u;
    return 0;
}

void ui_close(struct ui *u)
{
    if (!u) return;
    if (u->shown) h264ring_overlay_hide(u->r);
#ifdef CLIENT_TEST
    if (u->mapped) free(u->fb.virt);
#else
    if (u->mapped) h264ring_fb_unmap(&u->fb);
#endif
    for (unsigned i = 0; i < GLYPHS; i++) if (u->cache[i].bm) stbtt_FreeBitmap(u->cache[i].bm, NULL);
    free(u->ttf[0]); free(u->ttf[1]);
    free(u);
}
