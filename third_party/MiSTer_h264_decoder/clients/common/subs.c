/* subs -- SRT cues (subs.h). */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "subs.h"

struct cue { double a, b; char *text; };
struct subs { struct cue *c; unsigned n, cap, last; char *join; size_t join_cap; };

static int stamp(const char *p, double *t)
{
    unsigned h, m, s, ms;
    if (sscanf(p, "%u:%u:%u%*[,.]%u", &h, &m, &s, &ms) != 4) return 0;
    *t = h * 3600.0 + m * 60.0 + s + ms / 1000.0;
    return 1;
}

/* the cue's lines without markup: <...> tags and {...} overrides dropped */
static char *clean(const char *a, const char *b)
{
    char *o = malloc((size_t)(b - a) + 1), *q = o;
    if (!o) return NULL;
    int in_tag = 0, in_ovr = 0;
    for (const char *p = a; p < b; p++) {
        if (*p == '<') { in_tag = 1; continue; }
        if (*p == '>' && in_tag) { in_tag = 0; continue; }
        if (*p == '{') { in_ovr = 1; continue; }
        if (*p == '}' && in_ovr) { in_ovr = 0; continue; }
        if (in_tag || in_ovr || *p == '\r') continue;
        *q++ = *p;
    }
    while (q > o && (q[-1] == '\n' || q[-1] == ' ')) q--;
    *q = 0;
    return o;
}

struct subs *subs_new(void) { return calloc(1, sizeof(struct subs)); }

/* room for one more cue */
static int grow(struct subs *s)
{
    if (s->n < s->cap) return 0;
    unsigned cap = s->cap ? s->cap * 2 : 256;
    struct cue *c = realloc(s->c, cap * sizeof *c);
    if (!c) return -1;
    s->c = c; s->cap = cap;
    return 0;
}

/* an ASS event's Text field as plain text: after the 8th comma; \N / \n a line break, \h a space;
 * NULL for a vector drawing ({\p1} ...: shapes, not words) */
static char *ass_text(const char *ev)
{
    const char *t = ev;
    for (int k = 0; k < 8 && t; k++) { t = strchr(t, ','); if (t) t++; }
    if (!t) t = ev;                                  /* not an event: the whole string */
    for (const char *q = t; (q = strstr(q, "\\p")) != NULL; q += 2)
        if (q[2] >= '1' && q[2] <= '9') return NULL;
    char *o = malloc(strlen(t) + 1), *w = o;
    if (!o) return NULL;
    for (const char *p = t; *p; p++) {
        if (p[0] == '\\' && (p[1] == 'N' || p[1] == 'n')) { *w++ = '\n'; p++; }
        else if (p[0] == '\\' && p[1] == 'h') { *w++ = ' '; p++; }
        else *w++ = *p;
    }
    *w = 0;
    return o;
}

int subs_add(struct subs *s, double a, double b, const char *text, int ass)
{
    if (!s || !text) return -1;
    char *raw = ass ? ass_text(text) : strdup(text);
    if (!raw) return -1;
    char *txt = clean(raw, raw + strlen(raw));
    free(raw);
    if (!txt || !*txt || grow(s)) { free(txt); return -1; }
    if (b <= a) b = a + 4;                           /* no duration: a few seconds */
    unsigned i = s->n;                               /* in start order (the demuxer's is, nearly always) */
    while (i > 0 && s->c[i - 1].a > a) i--;
    memmove(&s->c[i + 1], &s->c[i], (s->n - i) * sizeof *s->c);
    s->c[i] = (struct cue){a, b, txt};
    s->n++;
    if (s->last > i) s->last = i;
    return 0;
}

struct subs *subs_parse(const char *srt, size_t len)
{
    struct subs *s = subs_new();
    if (!s) return NULL;
    const char *p = srt, *end = srt + len;
    if (len >= 3 && (unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) p += 3;
    while (p < end) {
        const char *arrow = strstr(p, "-->");
        if (!arrow || arrow >= end) break;
        const char *ls = arrow;                       /* the timing line's start */
        while (ls > p && ls[-1] != '\n') ls--;
        double a, b;
        const char *nl = memchr(arrow, '\n', (size_t)(end - arrow));
        if (!nl) break;
        if (!stamp(ls, &a) || !stamp(arrow + 3 + strspn(arrow + 3, " "), &b)) { p = nl + 1; continue; }
        const char *t = nl + 1, *te = t;               /* the text: up to a blank line */
        while (te < end) {
            const char *n2 = memchr(te, '\n', (size_t)(end - te));
            const char *line_end = n2 ? n2 : end;
            size_t k = (size_t)(line_end - te);
            if (k == 0 || (k == 1 && te[0] == '\r')) break;
            te = n2 ? n2 + 1 : end;
        }
        if (grow(s)) break;
        char *txt = clean(t, te);
        if (txt && *txt) s->c[s->n++] = (struct cue){a, b, txt};
        else free(txt);
        p = te;
    }
    return s;
}

const char *subs_at(struct subs *s, double t)
{
    if (!s || !s->n) return NULL;
    unsigned i = s->last < s->n ? s->last : 0;
    if (s->c[i].a > t) i = 0;                          /* a seek back: from the start */
    for (; i < s->n && s->c[i].b <= t; i++) {}
    s->last = i;
    /* overlapping cues (two speakers, a sign over dialogue): every one that covers t, a line each */
    const char *one = NULL;
    size_t len = 0;
    unsigned covering = 0;
    for (unsigned k = i; k < s->n && s->c[k].a <= t; k++)
        if (s->c[k].b > t) { if (!one) one = s->c[k].text; covering++; len += strlen(s->c[k].text) + 1; }
    if (covering < 2) return one;
    if (len > s->join_cap) {
        char *j = realloc(s->join, len);
        if (!j) return one;
        s->join = j; s->join_cap = len;
    }
    char *w = s->join;
    for (unsigned k = i; k < s->n && s->c[k].a <= t; k++)
        if (s->c[k].b > t) {
            if (w != s->join) *w++ = '\n';
            size_t n = strlen(s->c[k].text);
            memcpy(w, s->c[k].text, n);
            w += n;
        }
    *w = 0;
    return s->join;
}

unsigned subs_count(const struct subs *s) { return s ? s->n : 0; }

void subs_free(struct subs *s)
{
    if (!s) return;
    for (unsigned i = 0; i < s->n; i++) free(s->c[i].text);
    free(s->c);
    free(s->join);
    free(s);
}
