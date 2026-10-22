/* h264player -- the MiSTer H264 core's file player (docs/player.md).
 *   h264player [--dir DIR] [--root FOLDER]...
 *       browse the video folders on the overlay with the pad and play a file through the core
 *       (P2): the roots are /media/fat/video, /media/usb0-7 (when mounted) and /media/fat/cifs,
 *       or DIR/h264player.ini's root= lines, or the --root options; DIR keeps state.txt (the last
 *       folder and file). Ends on Back + Start in the browser, when another core is loaded, or on
 *       SIGTERM. DIR: the binary's own directory (/media/fat/h264player: the typefaces too).
 *   h264player [--dir DIR] play FILE
 *       one file through the same player, no browser; ends with it (bring-up and the rig's tests)
 * What plays is the core's: H.264 Main / High, CABAC, 8-bit 4:2:0, at most 3,600 macroblocks a
 * picture (1280x720) and 108,000 a second (720p30, 480p60: h264ring_caps). Anything else is refused before a byte of it reaches the core, the reason on screen
 * (docs/player.md "The envelope"). */
#include <dirent.h>
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavutil/log.h>
#include "browse.h"
#include "core.h"
#include "input.h"
#include "player.h"
#include "subs.h"
#include "ui.h"

#define PANEL_MS        5000
#define SEEK_SETTLE_MS  600         /* seek steps add up; the stream restarts once, this long after the last */
#define TRACK_SETTLE_MS 800         /* audio presses add up likewise (an audio change restarts the stream) */
#define SETTINGS_MS     500         /* the core's answer to a settings request */
#define MAX_ROOTS       16

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static char dir[512];

static const char *in_dir(const char *name)
{
    static char p[2][700];
    static int k;
    k ^= 1;
    snprintf(p[k], sizeof p[k], "%s/%s", dir, name);
    return p[k];
}

struct app {
    struct core core;
    struct ui *ui;
    struct cl_input in;
    /* the browser */
    char *roots[MAX_ROOTS];
    unsigned n_roots;
    struct listing ls;               /* the folder shown (or the roots: ls.path "") */
    unsigned sel;
    char note[160];                  /* the list's title line when the folder did not open */
    int quit_after;                  /* `play FILE`: end with the file */
    /* what plays */
    int playing;
    int file;                        /* its entry in ls */
    char path[PATH_MAX], title[256], subline[300];
    struct player *pl;
    int paused, loading, held, started;
    int audio;                       /* the stream asked for (-1 the best) */
    int track_pending, track_target;
    uint64_t track_due;
    int seek_pending;
    double seek_target;
    uint64_t seek_due;
    double pos;
    int sub;                         /* -1 off; 0 .. n-1 the file's text tracks; n the .srt beside it */
    struct subs *ext;                /* the .srt beside the file */
    char sub_name[96];
    int refresh_ours;                /* the Refresh Rate on screen is the player's 50 Hz, not the user's */
    double saver_dim, saver_black;   /* the screensaver's times, minutes (P5) */
};

/* ---- the refresh rate (docs/player.md P4) ----
 * Refresh Rate on Auto takes the rate from the stream's VUI; a 25 / 50 frames/s file without VUI
 * timing would play on the 59.94 Hz raster and judder (analog first: PAL files on a 576i CRT). So
 * while the user's choice is Auto, a file of the 25 / 50 family asks for 50 Hz itself, and the
 * player gives Auto back for the next file of another rate and when it ends. A rate the user set
 * in the OSD is never touched. */
static int settings(struct app *a, unsigned refresh)
{
    unsigned v[H264RING_OPT_COUNT] = {0};
    v[H264RING_OPT_REFRESH_RATE] = refresh;
    int seq = h264ring_request_settings(a->core.r, 1u << H264RING_OPT_REFRESH_RATE, v);
    if (seq < 0) { fprintf(stderr, "h264player: settings request: %s\n", strerror(-seq)); return seq; }
    for (uint64_t t0 = now_ms(); now_ms() - t0 < SETTINGS_MS; usleep(2000)) {
        if (core_poll(&a->core)) return -ENODEV;
        if ((int)H264RING_ST(&a->core.st, SET_SEQ) == seq) break;
    }
    /* consumed: stop asserting it (the core would apply it again at every new session, over a
     * choice the user makes in the OSD meanwhile) */
    h264ring_clear_settings(a->core.r);
    fprintf(stderr, "h264player: Refresh Rate -> %s (result %u)\n", refresh == 3 ? "50 Hz" : "Auto",
            (unsigned)H264RING_ST(&a->core.st, SET_ERR));
    return 0;
}

static unsigned refresh_for(double fps)
{
    return (fps > 24.5 && fps < 25.5) || (fps > 49.5 && fps < 50.5) ? 3u : 0u;
}

static void apply_refresh(struct app *a, double fps)
{
    unsigned cur = (unsigned)H264RING_ST(&a->core.st, OSD_REFRESH);
    if (cur != 0 && !(a->refresh_ours && cur == 3)) {
        a->refresh_ours = 0;                       /* the user's own choice */
        return;
    }
    unsigned want = refresh_for(fps);
    if (want != cur && settings(a, want) == 0) a->refresh_ours = want == 3;
}

static void restore_refresh(struct app *a)
{
    if (a->refresh_ours && H264RING_ST(&a->core.st, OSD_REFRESH) == 3) settings(a, 0);
    a->refresh_ours = 0;
}

/* ---- the screen ---- */

/* the raster's width (0.10: 720 fitted; the picture's own on "Native (HDMI)") -- the canvas spans it */
static unsigned raster_width(const struct app *a)
{
    if (!a->core.have_st) return 720u;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    return rs.w ? rs.w : 720u;
}

/* the raster's lines (0.10, h264ring_raster: word 80's size) */
static unsigned raster_lines(const struct app *a)
{
    if (!a->core.have_st) return 480u;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    if (rs.h) return rs.h;
    return H264RING_ST(&a->core.st, RASTER_STD) == 2 ? 576u : 480u;
}

/* the shape the whole raster is shown at (word 47: 4:3 on the analog raster; under A' the
 * display's shape, the picture letterboxed inside -- docs/hdmi_raster.md), as the Jellyfin client */
static double raster_aspect(const struct app *a)
{
    if (!a->core.have_st) return 4.0 / 3.0;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    return rs.aspect;
}

static int is_root(const struct app *a, const char *path)
{
    for (unsigned i = 0; i < a->n_roots; i++) if (!strcmp(a->roots[i], path)) return 1;
    return 0;
}

static const char *lpath(const struct app *a) { return a->ls.path ? a->ls.path : ""; }

static const char *list_title(const struct app *a)
{
    return a->note[0] ? a->note : lpath(a)[0] ? lpath(a) : "Videos";
}

static void show_list(struct app *a)
{
    struct ui_list l = {
        .title = list_title(a),
        .hint = a->n_roots > 1 || (lpath(a)[0] && !is_root(a, lpath(a)))
              ? "A  open      B  back      LB / RB  page      Back + Start  quit"
              : "A  open      LB / RB  page      Back + Start  quit",
        .rows = (const char *const *)a->ls.rows, .n = a->ls.n, .sel = a->sel,
        .empty = lpath(a)[0] ? "No folders or videos here" : "No video folders: see the manual (Video player)",
    };
    ui_list(a->ui, &l);
}

static void show_now(struct app *a)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    const char *audio = "";
    if (in) for (unsigned i = 0; i < in->n_audio; i++) if (in->audio[i].index == in->audio_cur) audio = in->audio[i].name;
    struct ui_now n = {
        .title = a->title, .subtitle = a->subline,
        .position = a->seek_pending ? a->seek_target : a->pos,
        .duration = in ? in->duration : 0, .paused = a->paused,
        .loading = a->loading, .seeking = a->seek_pending,
        .audio = audio, .subs = a->sub >= 0 ? a->sub_name : "",
    };
    ui_playing(a->ui, &n);
}

/* ---- the browser ---- */

static void state_save(const struct app *a)
{
    FILE *f = fopen(in_dir("state.txt"), "w");
    if (!f) return;
    fprintf(f, "folder=%s\n", lpath(a));
    if (a->sel < a->ls.n) fprintf(f, "file=%s\n", a->ls.names[a->sel]);
    fclose(f);
}

/* show a folder ("" the roots; with one root, that root is the top) with `select` selected */
static void open_folder(struct app *a, const char *path, const char *select)
{
    struct listing l;
    int rc = path[0] ? browse_read(&l, path) : browse_roots(&l, (const char *const *)a->roots, a->n_roots);
    a->note[0] = 0;
    if (rc) {
        fprintf(stderr, "h264player: %s: %s\n", path, strerror(-rc));
        snprintf(a->note, sizeof a->note, "%s: %s", path, strerror(-rc));
        if (!a->ls.path) browse_roots(&a->ls, (const char *const *)a->roots, a->n_roots);
        show_list(a);
        return;
    }
    if (!path[0] && l.n == 1) {                      /* one root: it is the top */
        char only[PATH_MAX];
        snprintf(only, sizeof only, "%s", l.names[0]);
        browse_free(&l);
        open_folder(a, only, select);
        return;
    }
    browse_free(&a->ls);
    a->ls = l;
    int k = select ? browse_find(&a->ls, select) : -1;
    a->sel = k >= 0 ? (unsigned)k : 0;
    show_list(a);
}

static void folder_up(struct app *a)
{
    if (!lpath(a)[0]) return;                         /* the roots: the top */
    if (is_root(a, a->ls.path)) {
        unsigned shown = 0;
        struct listing r;
        if (!browse_roots(&r, (const char *const *)a->roots, a->n_roots)) { shown = r.n; browse_free(&r); }
        if (shown > 1) { char was[PATH_MAX]; snprintf(was, sizeof was, "%s", a->ls.path); open_folder(a, "", was); }
        return;
    }
    char parent[PATH_MAX], base[PATH_MAX];
    browse_split(a->ls.path, parent, base, sizeof parent);
    open_folder(a, parent, base);
}

/* ---- playing ---- */

static void close_player(struct app *a)
{
    if (a->pl) player_close(a->pl);
    a->pl = NULL;
}

/* the .srt beside the file ("name.srt", else "name.<anything>.srt": a language tag) */
static void load_ext_subs(struct app *a)
{
    subs_free(a->ext);
    a->ext = NULL;
    char folder[PATH_MAX], base[PATH_MAX];
    browse_split(a->path, folder, base, sizeof folder);
    char *dot = strrchr(base, '.');
    if (dot) *dot = 0;
    char srt[2 * PATH_MAX + 8] = "";
    snprintf(srt, sizeof srt, "%s/%s.srt", folder, base);
    if (access(srt, R_OK)) {
        srt[0] = 0;
        DIR *d = opendir(folder);
        size_t bl = strlen(base);
        for (struct dirent *de; d && (de = readdir(d));) {
            size_t n = strlen(de->d_name);
            if (n > bl + 5 && !strncmp(de->d_name, base, bl) && de->d_name[bl] == '.' &&
                !strcasecmp(de->d_name + n - 4, ".srt")) {
                snprintf(srt, sizeof srt, "%s/%.255s", folder, de->d_name);
                break;
            }
        }
        if (d) closedir(d);
    }
    if (!srt[0]) return;
    FILE *f = fopen(srt, "rb");
    if (!f) return;
    fseek(f, 0, SEEK_END);
    long n = ftell(f);
    fseek(f, 0, SEEK_SET);
    char *t = n > 0 && n < (64l << 20) ? malloc((size_t)n) : NULL;
    if (t && fread(t, 1, (size_t)n, f) == (size_t)n) a->ext = subs_parse(t, (size_t)n);
    free(t);
    fclose(f);
    if (a->ext && !subs_count(a->ext)) { subs_free(a->ext); a->ext = NULL; }
    if (a->ext) fprintf(stderr, "h264player: subtitles beside the file: %s (%u cues)\n", srt, subs_count(a->ext));
}

static unsigned n_subs(const struct app *a)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    return (in ? in->n_subs : 0) + (a->ext ? 1u : 0u);
}

static void set_sub(struct app *a, int k)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    unsigned emb = in ? in->n_subs : 0;
    a->sub = k;
    if (k < 0) snprintf(a->sub_name, sizeof a->sub_name, "Off");
    else if ((unsigned)k < emb) snprintf(a->sub_name, sizeof a->sub_name, "%s", in->subs[k].name);
    else snprintf(a->sub_name, sizeof a->sub_name, "SRT beside the file");
    ui_subtitle(a->ui, NULL);
}

/* the track a file starts with: the .srt beside it (someone put it there), else the file's
 * default / forced text track, else none */
static void default_sub(struct app *a)
{
    const struct player_info *in = player_info(a->pl);
    unsigned emb = in ? in->n_subs : 0;
    int k = -1;
    if (a->ext) k = (int)emb;
    else for (unsigned i = 0; in && i < emb && k < 0; i++) if (in->subs[i].def) k = (int)i;
    set_sub(a, k);
}

static struct subs *cur_subs(const struct app *a)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    unsigned emb = in ? in->n_subs : 0;
    if (a->sub < 0) return NULL;
    return (unsigned)a->sub < emb ? player_subs(a->pl, (unsigned)a->sub) : a->ext;
}

/* open the file at `start`. keep: the same file is on screen (a seek, an audio track) -- PAUSE the
 * core (the picture holds) and open HELD; the flush comes once the new stream's IDR is checked
 * (tend_playing, PL_READY). A new file is held too: the refresh rate is set between its check and
 * its first byte. */
static int open_stream(struct app *a, double start, int keep)
{
    close_player(a);
    if (keep) h264ring_set_pause(a->core.r, 1);
    a->held = 1;
    struct player_cfg cfg = {
        .url = a->path, .start_s = start, .seek = 1, .audio_stream = a->audio, .hold = 1, .text_subs = 1, .cavlc_ok = 1,
        .arm_video = 1,                              /* (0.15) other codecs decoded here at SD (docs/player.md) */
    };
    struct h264ring_caps caps;                       /* (0.11) the core's largest picture and rate */
    h264ring_caps(&a->core.st, &caps);
    cfg.max_mbs = caps.max_mbs;
    cfg.mb_rate = caps.mb_rate;
    a->pos = start;
    a->loading = 1;
    return player_open(&a->pl, &cfg);
}

static void stop_playing(struct app *a)
{
    if (!a->playing) return;
    close_player(a);
    core_new_stream(&a->core);                       /* black under the list */
    h264ring_set_pause(a->core.r, 0);
    subs_free(a->ext);
    a->ext = NULL;
    a->playing = 0;
    a->in.nav = 1;
    ui_subtitle(a->ui, NULL);
    ui_playing(a->ui, NULL);
    ui_panel_hide(a->ui);
    if (a->quit_after) { stop = 1; return; }
    show_list(a);
}

static void start_file(struct app *a, unsigned k)
{
    if (k < a->ls.n_dirs || k >= a->ls.n) return;
    close_player(a);
    a->file = (int)k;
    a->sel = k;
    state_save(a);
    snprintf(a->path, sizeof a->path, "%s/%s", a->ls.path, a->ls.names[k]);
    snprintf(a->title, sizeof a->title, "%s", a->ls.names[k]);
    char *dot = strrchr(a->title, '.');
    if (dot && dot != a->title) *dot = 0;
    char folder[PATH_MAX], base[PATH_MAX];
    browse_split(a->ls.path, folder, base, sizeof folder);
    snprintf(a->subline, sizeof a->subline, "%.200s    %u of %u", base, k - a->ls.n_dirs + 1, a->ls.n - a->ls.n_dirs);
    fprintf(stderr, "h264player: play %s\n", a->path);
    a->playing = 1;
    a->started = 0;
    a->paused = 0;
    a->audio = -1;
    a->sub = -1;
    a->sub_name[0] = 0;
    a->seek_pending = a->track_pending = 0;
    a->in.nav = 0;
    load_ext_subs(a);
    open_stream(a, 0, 0);
    show_now(a);
    ui_panel(a->ui, PANEL_MS);
}

/* the next / previous file in the folder (step +1 / -1); past either end: the list */
static void step_file(struct app *a, int step)
{
    int k = a->file + step;
    if (k < (int)a->ls.n_dirs || k >= (int)a->ls.n) { stop_playing(a); return; }
    start_file(a, (unsigned)k);
}

static const char *why_refused(const struct app *a, enum h264check c, char *b, size_t n)
{
    const struct player_info *in = player_info(a->pl);
    switch (c) {
    /* short: the message's header is one line of the safe area (the log has the path) */
    case H264C_CAVLC: return "CAVLC H.264 (Baseline profile)";
    case H264C_MBAFF: return "MBAFF interlaced H.264";
    case H264C_CHROMA: return "4:2:2, 4:4:4 or monochrome H.264";
    case H264C_BITDEPTH: return "10-bit H.264";
    case H264C_PROFILE: return "an H.264 profile the core does not decode";
    case H264C_SIZE:
        if (in && in->width > 0) { snprintf(b, n, "%dx%d is larger than 720p", in->width, in->height); return b; }
        return "larger than 720p";
    case H264C_RATE:                                 /* (0.11) 720p60: the core would play it at half speed */
        if (in && in->width > 0 && in->fps > 0) {
            snprintf(b, n, "%dx%d at %.0f frames/s is too fast", in->width, in->height, in->fps);
            return b;
        }
        return "too many frames a second";
    default: return h264check_name(c);
    }
}

/* the file cannot play: back to the list, the reason on screen (and the log) */
static void refuse(struct app *a, const char *why)
{
    fprintf(stderr, "h264player: cannot play %s: %s\n", a->path, why);
    char head[200];
    snprintf(head, sizeof head, "Cannot play: %s", why);
    a->playing = 1;                                  /* (stop_playing's precondition) */
    stop_playing(a);
    ui_message(a->ui, head, "Convert it on a computer: the manual's Compatibility page", 8000);
}

static double clamp_pos(const struct app *a, double t)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    double dur = in ? in->duration : 0;
    if (dur > 10 && t > dur - 5) t = dur - 5;
    return t < 0 ? 0 : t;
}

static void seek_step(struct app *a, double d)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    if (in && in->raw) { ui_message(a->ui, "This file cannot seek", "a raw H.264 stream has no index", 3000); return; }
    if (!a->seek_pending) a->seek_target = a->pos;
    a->seek_target = clamp_pos(a, a->seek_target + d);
    a->seek_pending = 1;
    a->seek_due = now_ms() + SEEK_SETTLE_MS;
    show_now(a);
    ui_panel(a->ui, PANEL_MS);
}

static void seek_to(struct app *a, double t)
{
    a->seek_pending = 0;
    fprintf(stderr, "h264player: seek to %.1f s (from %.1f s)\n", clamp_pos(a, t), a->pos);
    open_stream(a, clamp_pos(a, t), a->pl != NULL);
    show_now(a);
    ui_panel(a->ui, PANEL_MS);
}

static void set_pause(struct app *a, int p)
{
    if (!a->playing || p == a->paused) return;
    a->paused = p;
    if (!a->held) h264ring_set_pause(a->core.r, p);   /* held: applied at the flush */
    show_now(a);
    if (p) ui_panel(a->ui, 0); else ui_panel(a->ui, PANEL_MS);
}

static void cycle_audio(struct app *a)
{
    const struct player_info *in = a->pl ? player_info(a->pl) : NULL;
    if (!in || in->n_audio < 2) { ui_message(a->ui, "Audio", in && in->n_audio ? "This file has one audio track" : "This file has no audio", 2000); return; }
    int cur = a->track_pending ? a->track_target : in->audio_cur;
    unsigned k = 0;
    for (unsigned i = 0; i < in->n_audio; i++) if (in->audio[i].index == cur) k = (i + 1) % in->n_audio;
    a->track_pending = 1;
    a->track_target = in->audio[k].index;
    a->track_due = now_ms() + TRACK_SETTLE_MS;
    char t[128];
    snprintf(t, sizeof t, "%s%s", in->audio[k].name, in->audio[k].playable ? "" : "  (not playable: silent)");
    ui_message(a->ui, "Audio", t, 2000);
}

/* subtitles: Off -> each text track -> the .srt beside the file -> Off; at once (no restart: the
 * cues of every track are kept as the demuxer passes them) */
static void cycle_subs(struct app *a)
{
    unsigned n = n_subs(a);
    if (!n) { ui_message(a->ui, "Subtitles", "This file has none the player can show", 2000); return; }
    int k = a->sub + 1;
    if (k >= (int)n) k = -1;
    set_sub(a, k);
    ui_message(a->ui, "Subtitles", a->sub_name, 2000);
    show_now(a);
}

static void act_play(struct app *a, enum cl_action x)
{
    switch (x) {
    case ACT_PAUSE: set_pause(a, !a->paused); break;
    case ACT_BACK: seek_step(a, -10); break;
    case ACT_FWD: seek_step(a, 30); break;
    case ACT_BACK_BIG: seek_step(a, -300); break;
    case ACT_FWD_BIG: seek_step(a, 300); break;
    case ACT_STOP: stop_playing(a); break;
    case ACT_SUBS: cycle_subs(a); break;
    case ACT_AUDIO: cycle_audio(a); break;
    case ACT_INFO: ui_panel(a->ui, PANEL_MS); break;
    case ACT_NEXT: step_file(a, 1); break;
    case ACT_PREV: if (a->pos > 10) seek_to(a, 0); else step_file(a, -1); break;
    default: break;
    }
}

static void act_browse(struct app *a, enum cl_action x)
{
    unsigned page = ui_list_rows(a->ui), n = a->ls.n;
    switch (x) {
    case ACT_UP: if (n) a->sel = a->sel ? a->sel - 1 : n - 1; break;
    case ACT_DOWN: if (n) a->sel = a->sel + 1 < n ? a->sel + 1 : 0; break;
    case ACT_PAGE_UP: a->sel = a->sel > page ? a->sel - page : 0; break;
    case ACT_PAGE_DOWN: if (n) a->sel = a->sel + page < n ? a->sel + page : n - 1; break;
    case ACT_OK:
        if (a->sel < a->ls.n_dirs) {
            char next[PATH_MAX];
            if (a->ls.path[0]) snprintf(next, sizeof next, "%s/%s", a->ls.path, a->ls.names[a->sel]);
            else snprintf(next, sizeof next, "%s", a->ls.names[a->sel]);
            open_folder(a, next, NULL);
            state_save(a);
            return;
        }
        if (a->sel < n) start_file(a, a->sel);
        return;
    case ACT_CANCEL: folder_up(a); state_save(a); return;
    case ACT_STOP:
        fprintf(stderr, "h264player: quit from the list\n");
        stop = 1;
        return;
    default: return;
    }
    show_list(a);
}

static void act(struct app *a, enum cl_action x)
{
    fprintf(stderr, "h264player: input: %s\n", input_action_name(x));
    if (a->playing) act_play(a, x); else act_browse(a, x);
}

/* one loop's worth of the stream */
static void tend_playing(struct app *a)
{
    if (!a->playing || !a->pl) return;
    if (a->seek_pending && now_ms() >= a->seek_due) seek_to(a, a->seek_target);
    if (a->track_pending && now_ms() >= a->track_due) {
        a->track_pending = 0;
        const struct player_info *in = player_info(a->pl);
        if (in && a->track_target != in->audio_cur) {
            fprintf(stderr, "h264player: audio track %d\n", a->track_target);
            a->audio = a->track_target;
            open_stream(a, a->pos, 1);
        }
    }
    enum player_state s = player_step(a->pl, a->core.r);
    if (s == PL_READY) {                              /* the IDR is checked and held: now the flush */
        if (!a->started) {                            /* a new file: its rate, its subtitles */
            const struct player_info *in = player_info(a->pl);
            apply_refresh(a, in ? in->fps : 0);
            default_sub(a);
            a->started = 1;
            fprintf(stderr, "h264player: %dx%d, %.3f frames/s, %.1f s, %u audio, %u text subtitle tracks%s\n",
                    in ? in->width : 0, in ? in->height : 0, in ? in->fps : 0, in ? in->duration : 0,
                    in ? in->n_audio : 0, in ? in->n_subs : 0, in && in->raw ? " (raw: no timestamps)" : "");
            if (in && in->cavlc) fprintf(stderr, "h264player: CAVLC: rewritten into CABAC as it is written (P6)\n");
            if (in && in->sw) fprintf(stderr, "h264player: %s: decoded on the ARM, shown as pictures (0.15)\n", in->video);
        }
        core_new_stream(&a->core);
        h264ring_set_pause(a->core.r, a->paused);
        player_release(a->pl);
        a->held = 0;
        s = player_step(a->pl, a->core.r);
    }
    const char *why = NULL;
    char b[160];
    if (s == PL_UNDECODABLE) {                        /* the check, or the CAVLC rewrite (its reason) */
        const char *e = player_error(a->pl);
        refuse(a, e && e[0] ? e : why_refused(a, player_check(a->pl), b, sizeof b));
        return;
    }
    if (core_refused(&a->core, &why)) { refuse(a, why); return; }
    if (s == PL_FAILED) {
        const struct player_info *in = player_info(a->pl);
        if (in && in->video[0] && strcmp(in->video, "h264")) { refuse(a, player_error(a->pl)); return; }
        fprintf(stderr, "h264player: %s: %s\n", a->path, player_error(a->pl));
        ui_message(a->ui, "Playback failed", player_error(a->pl), 8000);
        stop_playing(a);
        return;
    }
    const struct player_info *in = player_info(a->pl);
    int running = !a->held && core_flag(&a->core, H264RING_L_STC_RUN);
    if (!a->held) a->pos = player_position(a->pl, core_stc(&a->core), running);
    if (a->loading && (running || (in && in->raw && !a->held))) { a->loading = 0; show_now(a); }
    if (s == PL_DRAINED && core_flag(&a->core, H264RING_L_ENDED)) {
        fprintf(stderr, "h264player: played %s\n", a->path);
        if (a->quit_after) stop_playing(a);
        else step_file(a, 1);                         /* the folder plays on */
        return;
    }
    struct subs *cues = cur_subs(a);
    const char *line = running && cues ? subs_at(cues, a->pos) : NULL;
#ifdef CLIENT_TEST
    static char said[512];                            /* the host test scores the cues shown (log) */
    static char was[512];
    if (strcmp(was, line ? line : "")) {
        snprintf(was, sizeof was, "%s", line ? line : "");
        snprintf(said, sizeof said, "%s", was);
        for (char *c = said; *c; c++) if (*c == '\n') *c = '|';
        if (line) fprintf(stderr, "h264player: subtitle at %.2f: %s\n", a->pos, said);
    }
#endif
    ui_subtitle(a->ui, line);
    show_now(a);
}

/* ---- the roots: --root, else h264player.ini's root= lines, else the defaults ---- */

static void add_root(struct app *a, const char *p)
{
    size_t n = strlen(p);
    while (n > 1 && p[n - 1] == '/') n--;            /* "/media/usb0/" -> "/media/usb0" */
    if (a->n_roots < MAX_ROOTS && n) a->roots[a->n_roots++] = strndup(p, n);
}

/* key = value; the value, or NULL when the line is not that key's */
static const char *ini_value(char *line, const char *key)
{
    char *v = line + strspn(line, " \t");
    size_t n = strlen(key);
    if (strncmp(v, key, n)) return NULL;
    v += n;
    v += strspn(v, " \t");
    if (*v++ != '=') return NULL;
    return v + strspn(v, " \t");
}

/* the screensaver's times: minutes (decimals allowed), 0 off; a nonsense value keeps the default */
static void ini_minutes(const char *v, double *m)
{
    char *end;
    double x = strtod(v, &end);
    if (end != v && x >= 0 && x <= 24 * 60) *m = x;
}

/* h264player.ini: root= lines (only when no --root was given), the screensaver's times */
static void read_ini(struct app *a, int roots)
{
    FILE *f = fopen(in_dir("h264player.ini"), "r");
    if (!f) return;
    char line[600];
    const char *v;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if ((v = ini_value(line, "root"))) { if (roots && *v) add_root(a, v); }
        else if ((v = ini_value(line, "screensaver_dim"))) ini_minutes(v, &a->saver_dim);
        else if ((v = ini_value(line, "screensaver_black"))) ini_minutes(v, &a->saver_black);
    }
    fclose(f);
}

static void default_roots(struct app *a)
{
    add_root(a, "/media/fat/video");
    char p[32];
    for (int i = 0; i < 8; i++) { snprintf(p, sizeof p, "/media/usb%d", i); add_root(a, p); }
    add_root(a, "/media/fat/cifs");
}

/* where the list starts: the folder and file of the last run, when they still exist under a root */
static void open_start(struct app *a)
{
    FILE *f = fopen(in_dir("state.txt"), "r");
    char folder[PATH_MAX] = "", file[PATH_MAX] = "", line[PATH_MAX];
    while (f && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        if (!strncmp(line, "folder=", 7)) snprintf(folder, sizeof folder, "%s", line + 7);
        else if (!strncmp(line, "file=", 5)) snprintf(file, sizeof file, "%s", line + 5);
    }
    if (f) fclose(f);
    int under = 0;
    for (unsigned i = 0; i < a->n_roots && folder[0]; i++) {
        size_t n = strlen(a->roots[i]);
        under |= !strncmp(folder, a->roots[i], n) && (folder[n] == 0 || folder[n] == '/');
    }
    struct stat st;
    if (under && stat(folder, &st) == 0 && S_ISDIR(st.st_mode)) open_folder(a, folder, file[0] ? file : NULL);
    else open_folder(a, "", NULL);
}

static int run(struct app *a, const char *play_file)
{
    if (core_open2(&a->core, getenv("H264PLAYER_RBF"), H264RING_OPEN_PICTURES)) return 1;   /* (0.15) the stores too */
    if (ui_open(&a->ui, a->core.r, dir)) { core_close(&a->core); return 1; }
    ui_saver_times(a->ui, (unsigned)(a->saver_dim * 60000.0), (unsigned)(a->saver_black * 60000.0));
    a->in.nav = 1;
    if (play_file) {                                  /* one file: its folder, the file selected, played */
        char folder[PATH_MAX], base[PATH_MAX];
        browse_split(play_file, folder, base, sizeof folder);
        a->quit_after = 1;
        add_root(a, folder);
        open_folder(a, folder, base);
        int k = browse_find(&a->ls, base);
        if (k < (int)a->ls.n_dirs) { fprintf(stderr, "h264player: %s is not a video file here\n", play_file); stop = 1; }
        else start_file(a, (unsigned)k);
    } else {
        open_start(a);
    }
    while (!stop) {
        if (core_poll(&a->core)) break;
        enum cl_action acts[16];
        unsigned na = input_poll(&a->in, a->core.r, acts, 16);
        for (unsigned i = 0; i < na && !stop; i++) {
            if (ui_wake(a->ui)) {                     /* the press only wakes the screensaver (P5) */
                fprintf(stderr, "h264player: input: %s (woke the screensaver)\n", input_action_name(acts[i]));
                continue;
            }
            act(a, acts[i]);
        }
        tend_playing(a);
        ui_busy(a->ui, a->playing && !a->paused);     /* video playing: no screensaver */
        ui_draw(a->ui, raster_width(a), raster_lines(a), raster_aspect(a));
#ifdef CLIENT_TEST
        static int saver_was;                         /* the host test times the stages (log) */
        if (ui_saver_level(a->ui) != saver_was) {
            saver_was = ui_saver_level(a->ui);
            fprintf(stderr, "h264player: screensaver %s\n", saver_was == 2 ? "black" : saver_was ? "dim" : "off");
        }
#endif
        usleep(2000);
    }
    if (!a->core.gone) {
        close_player(a);
        restore_refresh(a);
    }
    close_player(a);
    subs_free(a->ext);
    browse_free(&a->ls);
    ui_close(a->ui);
    core_close(&a->core);
    for (unsigned i = 0; i < a->n_roots; i++) free(a->roots[i]);
    return 0;
}

#ifdef CLIENT_TEST
/* the host test (tests/test_player.c) runs the player on a thread beside its fake core */
void player_test_stop(void) { stop = 1; }
int player_main(int argc, char **argv);
int player_main(int argc, char **argv)
#else
int main(int argc, char **argv)
#endif
{
    av_log_set_level(getenv("H264PLAYER_AVLOG") ? AV_LOG_INFO : AV_LOG_WARNING);
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    ssize_t n = readlink("/proc/self/exe", dir, sizeof dir - 1);
    dir[n > 0 ? n : 0] = 0;
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0; else snprintf(dir, sizeof dir, ".");
    static struct app a;
    memset(&a, 0, sizeof a);
    a.file = -1;
    a.sub = -1;
    a.saver_dim = 5;                                  /* P5's defaults */
    a.saver_black = 30;
    const char *play = NULL;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--dir") && i + 1 < argc) snprintf(dir, sizeof dir, "%s", argv[++i]);
        else if (!strcmp(argv[i], "--root") && i + 1 < argc) add_root(&a, argv[++i]);
        else if (!strcmp(argv[i], "play") && i + 1 < argc) play = argv[++i];
        else {
            fprintf(stderr, "usage: h264player [--dir DIR] [--root FOLDER]...   the browser\n"
                            "       h264player [--dir DIR] play FILE              one file\n");
            return 2;
        }
    }
    read_ini(&a, !play && !a.n_roots);
    if (!play && !a.n_roots) default_roots(&a);
    return run(&a, play);
}
