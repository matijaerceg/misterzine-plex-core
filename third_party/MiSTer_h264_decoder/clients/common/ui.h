/* ui -- a client's screens on the core's overlay plane (interface 0.9; docs/jellyfin.md J1, J5,
 * J6; docs/player.md P2): a card (Jellyfin's ready screen, over the idle screen: a session with no
 * video, R3), a list (the file player's browser), the now-playing panel, messages, subtitles. Drawn into /dev/fb0 in 4444 (antialiased text, translucent panels at 16
 * bits a pixel), two pages flipped by the overlay's generation, only the lines drawn declared as
 * the band. One canvas pixel is one raster pixel: the text is drawn for the raster's pixel aspect
 * (720 wide is 4:3 on the analog raster) and inside a CRT's safe area. */
#ifndef CLIENT_UI_H
#define CLIENT_UI_H

#include <stdint.h>
#include "h264ring.h"

struct ui;

struct ui_now {
    const char *title, *subtitle;    /* the item's name; the series / episode line ("" none) */
    double position, duration;       /* seconds */
    int paused;
    int loading;                     /* a start or a seek: no picture yet */
    int seeking;                     /* steps being added up: position is the target */
    const char *audio, *subs;        /* the tracks' names ("" none) */
};

int  ui_open(struct ui **u, h264ring *r, const char *fontdir);
void ui_close(struct ui *u);

/* a card, centred: a title; a line; a big code (or "": the card is shorter); a foot; a note in
 * the accent colour ("" each: none). Shown while nothing plays and no list is up. */
struct ui_card { const char *title, *line, *big, *foot, *note; };

/* a list (the file player's browser), the whole safe area: a title, the rows from a scroll that
 * keeps `sel` in view, `sel` highlighted, a hint at the bottom. The rows are NOT copied: the
 * caller keeps them unchanged until the next ui_list() (call it again after any change). Shown
 * while nothing plays; over a card. */
struct ui_list {
    const char *title, *hint;
    const char *const *rows;
    unsigned n, sel;
    const char *empty;               /* shown when n is 0 */
};

/* what to show; each takes effect at the next ui_draw() */
void ui_card(struct ui *u, const struct ui_card *c);           /* NULL: none */
void ui_list(struct ui *u, const struct ui_list *l);           /* NULL: none */
unsigned ui_list_rows(const struct ui *u);                     /* the rows a page shows (at the last draw's raster) */
void ui_playing(struct ui *u, const struct ui_now *now);       /* NULL: not playing */
void ui_panel(struct ui *u, unsigned show_ms);                 /* show the now-playing panel for a while (0: until hidden) */
void ui_panel_hide(struct ui *u);
void ui_message(struct ui *u, const char *header, const char *text, unsigned ms);
void ui_subtitle(struct ui *u, const char *text);              /* NULL / "": none */

/* the screensaver (docs/player.md P5): after dim_ms with no activity and no video playing, a 75 %
 * black veil over the whole raster and one line (what is up: paused title and position, the
 * card, the folder) fading in and out at random places; after black_ms, fully black with the
 * same line. 0 turns a stage off. */
void ui_saver_times(struct ui *u, unsigned dim_ms, unsigned black_ms);
void ui_activity(struct ui *u);               /* a server command, a new screen: idle starts again */
void ui_busy(struct ui *u, int busy);         /* video playing (not paused): never idle */
int  ui_wake(struct ui *u);                   /* a button: activity; 1 when it only woke the saver
                                                 (the caller then ignores the press) */
int  ui_saver_level(const struct ui *u);      /* 0 off, 1 dimmed, 2 black (as last drawn) */

/* redraw when something changed (at most ~8 times a second); call every loop. w x lines: the raster
 * the canvas is drawn for (h264ring_raster's w x h, interface 0.10: 720 x 480 / 576 fitted, the
 * picture's own size up to 2,048 x 2,048 (0.12) on Video Output "Native (HDMI)"); aspect: the shape the
 * whole raster is SHOWN at (rs.aspect: 4/3 on the analog raster, HDMI's ar_x : ar_y otherwise) --
 * the text is drawn for the pixel aspect aspect * lines / w, so it is not squeezed when HDMI shows
 * the raster at a scope film's 2.39:1 or a native raster at its own shape. Every screen, the
 * screensaver's veil included, spans the whole raster. */
void ui_draw(struct ui *u, unsigned w, unsigned lines, double aspect);

#endif
