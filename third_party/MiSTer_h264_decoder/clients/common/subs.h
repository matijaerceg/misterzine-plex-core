/* subs -- a text subtitle track (SRT, as the server converts any text format to: docs/jellyfin.md
 * J6; or a file's own text track, cue by cue as the demuxer meets them: docs/player.md), its cues
 * at a time. The tags (<i>, {\an8}, ...) are dropped: the overlay draws plain text. */
#ifndef CLIENT_SUBS_H
#define CLIENT_SUBS_H

#include <stddef.h>

struct subs;

struct subs *subs_parse(const char *srt, size_t len);
struct subs *subs_new(void);
/* one cue, from a to b seconds of the item, kept in start order. ass: text is an ASS event as
 * FFmpeg's text decoders give it (ReadOrder, Layer, Style, Name, MarginL, MarginR, MarginV,
 * Effect, Text: the Text taken, \N a line break, a vector drawing dropped); else plain / SRT
 * text. 0, or -1 (nothing to show, or no memory). */
int subs_add(struct subs *s, double a, double b, const char *text, int ass);
/* the text at t seconds of the item (cues that overlap there joined, a line each), or NULL;
 * valid until the next call */
const char *subs_at(struct subs *s, double t);
unsigned subs_count(const struct subs *s);
void subs_free(struct subs *s);

#endif
