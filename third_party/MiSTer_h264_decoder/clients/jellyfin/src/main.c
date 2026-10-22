/* jellyfin -- the MiSTer H264 core's Jellyfin client (docs/jellyfin.md).
 *   jellyfin [--dir DIR]
 *       the cast target (J1): reads DIR/jellyfin.ini (server=, and user= / password= only for a
 *       server with Quick Connect off), signs in by Quick Connect (J4: the code on the overlay),
 *       keeps DIR/state.json (the device id, the token), loads the core and waits on the overlay
 *       for an item a Jellyfin app plays on it; ends when another core is loaded or on SIGTERM.
 *       DIR: the binary's own directory (/media/fat/jellyfin).
 *   jellyfin [--dir DIR] play URL [--start S] [--audio N] [--header "Name: value"]
 *       one stream straight into the core, no server (bring-up and the rig's tests)
 */
#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <libavutil/log.h>
#include "core.h"
#include "input.h"
#include "jf.h"
#include "player.h"
#include "profile.h"
#include "subs.h"
#include "ui.h"

#define TICKS          10000000.0   /* Jellyfin's 100 ns ticks a second */
#define PROGRESS_MS    10000        /* a Progress report (and on every event) */
#define QC_POLL_MS     5000         /* Quick Connect: as jellyfin-web polls */
#define WS_RETRY_MS    5000
#define PANEL_MS       5000
#define TRACK_SETTLE_MS 800         /* audio / subtitle presses add up likewise: one change, this long after the last */
#define SEEK_SETTLE_MS 600          /* the pad's / keyboard's seek steps add up; the stream restarts once, this long after the last */
#define QUEUE_MAX      1000         /* a Play's items kept (a series' "play all"); past it: said, not dropped silently */

static volatile sig_atomic_t stop;
static void on_signal(int s) { (void)s; stop = 1; }

static char dir[512];

static const char *in_dir(const char *name)
{
    static char p[4][700];
    static int k;
    k = (k + 1) & 3;
    snprintf(p[k], sizeof p[k], "%s/%s", dir, name);
    return p[k];
}

static const char *cafile_default(void)
{
    const char *env = getenv("JELLYFIN_CAFILE");
    if (env) return env;
    if (access(in_dir("cacert.pem"), R_OK) == 0) return in_dir("cacert.pem");
    return "/etc/ssl/cert.pem";
}

/* ---- jellyfin.ini (parsed, never sourced: keys whitelisted, spaces and CRs trimmed) ---- */

struct ini { char server[256], user[96], password[128], name[64]; double saver_dim, saver_black; };

/* the screensaver's times: minutes (decimals allowed), 0 off, a nonsense value the default */
static double minutes(const char *v, double dflt)
{
    char *end;
    double m = strtod(v, &end);
    return end != v && m >= 0 && m <= 24 * 60 ? m : dflt;
}

static void trim(char *s)
{
    size_t n = strlen(s);
    while (n && (s[n - 1] == ' ' || s[n - 1] == '\r' || s[n - 1] == '\n' || s[n - 1] == '\t')) s[--n] = 0;
    size_t k = strspn(s, " \t");
    memmove(s, s + k, strlen(s + k) + 1);
}

static int ini_read(struct ini *c)
{
    memset(c, 0, sizeof *c);
    snprintf(c->name, sizeof c->name, "MiSTer");
    c->saver_dim = 5;                             /* docs/player.md P5 */
    c->saver_black = 30;
    FILE *f = fopen(in_dir("jellyfin.ini"), "r");
    if (!f) return -ENOENT;
    char line[512];
    while (fgets(line, sizeof line, f)) {
        char *eq = strchr(line, '=');
        if (line[0] == '#' || line[0] == ';' || !eq) continue;
        *eq = 0;
        char *k = line, *v = eq + 1;
        trim(k); trim(v);
        if (!strcmp(k, "server")) snprintf(c->server, sizeof c->server, "%s", v);
        else if (!strcmp(k, "user")) snprintf(c->user, sizeof c->user, "%s", v);
        else if (!strcmp(k, "password")) snprintf(c->password, sizeof c->password, "%s", v);
        else if (!strcmp(k, "name") && *v) snprintf(c->name, sizeof c->name, "%s", v);
        else if (!strcmp(k, "screensaver_dim")) c->saver_dim = minutes(v, 5);
        else if (!strcmp(k, "screensaver_black")) c->saver_black = minutes(v, 30);
        else fprintf(stderr, "jellyfin: jellyfin.ini: unknown key %s (ignored)\n", k);
    }
    fclose(f);
    return c->server[0] ? 0 : -EINVAL;
}

/* ---- state.json: the device id, and the token for the server it came from ---- */

struct state { char device_id[40], server[256], token[80], user_id[40]; };

static void state_read(struct state *s)
{
    memset(s, 0, sizeof *s);
    FILE *f = fopen(in_dir("state.json"), "r");
    if (f) {
        char b[2048];
        size_t n = fread(b, 1, sizeof b - 1, f);
        b[n] = 0;
        fclose(f);
        cJSON *j = cJSON_Parse(b);
        const cJSON *v;
#define GET(k, dst) if ((v = cJSON_GetObjectItemCaseSensitive(j, k)) && cJSON_IsString(v)) snprintf(dst, sizeof dst, "%s", v->valuestring)
        GET("DeviceId", s->device_id); GET("Server", s->server); GET("Token", s->token); GET("UserId", s->user_id);
#undef GET
        cJSON_Delete(j);
    }
    if (!s->device_id[0]) {                       /* once, kept: a new sign-in revokes the device's old tokens */
        FILE *u = fopen("/proc/sys/kernel/random/uuid", "r");
        char id[64] = "";
        if (u) { if (!fgets(id, sizeof id, u)) id[0] = 0; fclose(u); }
        size_t k = 0;
        for (char *p = id; *p && k < sizeof s->device_id - 1; p++) if (*p != '-' && *p != '\n') s->device_id[k++] = *p;
        s->device_id[k] = 0;
    }
}

static void state_write(const struct state *s)
{
    cJSON *j = cJSON_CreateObject();
    cJSON_AddStringToObject(j, "DeviceId", s->device_id);
    cJSON_AddStringToObject(j, "Server", s->server);
    cJSON_AddStringToObject(j, "Token", s->token);
    cJSON_AddStringToObject(j, "UserId", s->user_id);
    char *t = cJSON_Print(j);
    char tmp[700];
    snprintf(tmp, sizeof tmp, "%s.tmp", in_dir("state.json"));
    mode_t old = umask(077);                      /* the token is a credential */
    FILE *f = fopen(tmp, "w");
    umask(old);
    if (f && t) { fputs(t, f); fclose(f); rename(tmp, in_dir("state.json")); }
    else if (f) fclose(f);
    free(t);
    cJSON_Delete(j);
}

/* ---- the reports, on their own thread (and their own HTTP connection): a report never stalls
 * the loop that reads the pad and feeds the core -- a 10 s Progress over TLS to a distant server
 * took a few hundred ms, and a tap pressed and released inside that was lost (the rig, 2026-10-01) */

struct report_job { enum jf_report what; char item[40]; struct jf_stream st; int64_t ticks; int paused, volume; };

struct reporter {
    pthread_t thread;
    pthread_mutex_t mx;
    pthread_cond_t cv;
    struct report_job q[16];
    unsigned head, tail;
    int quit, up;
    struct jf jf;
};

static void *reporter_main(void *arg)
{
    struct reporter *r = arg;
    pthread_mutex_lock(&r->mx);
    for (;;) {
        while (r->head == r->tail && !r->quit) pthread_cond_wait(&r->cv, &r->mx);
        if (r->head == r->tail) break;                 /* quit, and drained: the last Stopped went out */
        struct report_job j = r->q[r->head++ % 16];
        pthread_mutex_unlock(&r->mx);
        jf_report(&r->jf, j.what, j.item, &j.st, j.ticks, j.paused, j.volume);
        pthread_mutex_lock(&r->mx);
    }
    pthread_mutex_unlock(&r->mx);
    return NULL;
}

static int reporter_start(struct reporter *r, const struct jf *j)
{
    memset(r, 0, sizeof *r);
    pthread_mutex_init(&r->mx, NULL);
    pthread_cond_init(&r->cv, NULL);
    if (jf_clone(&r->jf, j) || pthread_create(&r->thread, NULL, reporter_main, r)) return -ENOMEM;
    r->up = 1;
    return 0;
}

static void reporter_post(struct reporter *r, const struct report_job *j)
{
    pthread_mutex_lock(&r->mx);
    if (r->tail - r->head == 16) {                     /* the server is slow: the oldest goes */
        fprintf(stderr, "jellyfin: reports queued faster than the server answers: one dropped\n");
        r->head++;
    }
    r->q[r->tail++ % 16] = *j;
    pthread_cond_signal(&r->cv);
    pthread_mutex_unlock(&r->mx);
}

static void reporter_stop(struct reporter *r)
{
    if (!r->up) return;
    pthread_mutex_lock(&r->mx);
    r->quit = 1;
    pthread_cond_signal(&r->cv);
    pthread_mutex_unlock(&r->mx);
    pthread_join(r->thread, NULL);
    jf_free(&r->jf);
    r->up = 0;
}

/* ---- the subtitle fetcher, on its own thread (and its own HTTP connection): a subtitle's
 * PlaybackInfo and its .srt can take seconds -- Jellyfin extracts a file's embedded text tracks on
 * the first request (an MKV with 27 tracks, the maintainer's round, 2026-10-01) -- and on the
 * loop's thread they froze the picture (the ring not fed) and the overlay until the server
 * answered. One job at a time: a newer one replaces a waiting one; a result is applied only if
 * its generation is still the app's (a stop, a new item or a newer switch drop it). */

struct sub_job {
    unsigned gen;
    int need_info;                    /* 1: a switch -- PlaybackInfo for `idx` first; 0: fetch `url` */
    char item[40];
    int64_t ticks;
    int audio, idx, forced;
    int hd;                           /* the item's profile (jf_profile_json): the same stream offered again */
    char url[1024];
};

struct sub_res {
    unsigned gen;
    int need_info, ok, burned, idx;
    char url[1024], name[96];
    char *text;
    size_t len;
};

struct fetcher {
    pthread_t thread;
    pthread_mutex_t mx;
    pthread_cond_t cv;
    struct sub_job job;
    struct sub_res res;
    int have_job, have_res, quit, up;
    struct jf jf;
};

static void sub_run(struct jf *jf, const struct sub_job *j, struct sub_res *r)
{
    memset(r, 0, sizeof *r);
    r->gen = j->gen;
    r->need_info = j->need_info;
    r->idx = j->idx;
    snprintf(r->url, sizeof r->url, "%s", j->url);
    if (j->need_info) {
        struct jf_stream t;
        if (jf_playback_info(jf, j->item, jf_profile_json(j->hd), j->ticks, j->audio, j->idx, j->forced, &t)) return;
        r->burned = t.sub_burned || !t.sub_url[0];
        snprintf(r->url, sizeof r->url, "%s", t.sub_url);
        snprintf(r->name, sizeof r->name, "%s", t.sub_name);
        if (r->burned) { r->ok = 1; return; }
    }
    r->text = jf_get_text(jf, r->url, &r->len);
    r->ok = r->text != NULL;
}

static void *fetcher_main(void *arg)
{
    struct fetcher *f = arg;
    pthread_mutex_lock(&f->mx);
    for (;;) {
        while (!f->have_job && !f->quit) pthread_cond_wait(&f->cv, &f->mx);
        if (f->quit) break;
        struct sub_job j = f->job;
        f->have_job = 0;
        pthread_mutex_unlock(&f->mx);
        struct sub_res r;
        sub_run(&f->jf, &j, &r);
        pthread_mutex_lock(&f->mx);
        if (f->have_res) free(f->res.text);       /* never taken: superseded */
        f->res = r;
        f->have_res = 1;
    }
    pthread_mutex_unlock(&f->mx);
    return NULL;
}

static int fetcher_start(struct fetcher *f, const struct jf *j)
{
    memset(f, 0, sizeof *f);
    pthread_mutex_init(&f->mx, NULL);
    pthread_cond_init(&f->cv, NULL);
    if (jf_clone(&f->jf, j) || pthread_create(&f->thread, NULL, fetcher_main, f)) return -ENOMEM;
    f->up = 1;
    return 0;
}

/* not up (no thread): the job runs here, on the caller's thread, as before the fetcher */
static void fetcher_post(struct fetcher *f, struct jf *jf, const struct sub_job *j)
{
    if (!f->up) {
        struct sub_res r;
        sub_run(jf, j, &r);
        if (f->have_res) free(f->res.text);
        f->res = r;
        f->have_res = 1;
        return;
    }
    pthread_mutex_lock(&f->mx);
    f->job = *j;
    f->have_job = 1;
    pthread_cond_signal(&f->cv);
    pthread_mutex_unlock(&f->mx);
}

static int fetcher_take(struct fetcher *f, struct sub_res *r)
{
    if (f->up) pthread_mutex_lock(&f->mx);
    int got = f->have_res;
    if (got) { *r = f->res; f->have_res = 0; }
    if (f->up) pthread_mutex_unlock(&f->mx);
    return got;
}

static void fetcher_stop(struct fetcher *f)
{
    if (f->up) {
        pthread_mutex_lock(&f->mx);
        f->quit = 1;
        pthread_cond_signal(&f->cv);
        pthread_mutex_unlock(&f->mx);
        pthread_join(f->thread, NULL);
        jf_free(&f->jf);
        f->up = 0;
    }
    if (f->have_res) free(f->res.text);
    f->have_res = 0;
}

/* ---- the client ---- */

struct app {
    struct core core;
    struct ui *ui;
    struct jf jf;
    struct cl_input in;
    struct reporter rep;
    struct fetcher fx;                /* the subtitles' server requests, off the loop's thread */
    unsigned sub_gen;                 /* the fetch whose result is still wanted */
    char server_name[96];
    uint64_t ws_retry_ms;
    /* what plays */
    int playing;
    struct jf_item info;
    struct jf_stream st;
    struct player *pl;
    int forced, paused, reported;
    int hd;                           /* (0.11) this item's PlaybackInfo asked for the 1280x720 box (hd_box) */
    int loading;                      /* a start or a seek, no picture yet */
    int held;                         /* the old picture frozen (the core paused) until the new stream's IDR is ready */
    int report_at_release;
    int track_pending;                /* 0 none, 1 audio, 2 subtitles: presses being added up ... */
    int track_target;                 /* ... to this stream index (-1: subtitles off) */
    uint64_t track_due;            /* a seek's Progress: sent when the new stream starts, not while the old picture is up */
    int seek_pending;                 /* the pad's seek steps being added up ... */
    double seek_target;               /* ... to here */
    uint64_t seek_due;                /* ... and done then */
    int volume;                       /* 0..100 */
    double pos;
    uint64_t progress_ms;
    struct subs *subs;
    char subline[200];
    /* the queue (a Play's ItemIds) */
    char (*queue)[40];
    int qn, qi;
};

/* the ready screen: the sign-in code (Quick Connect's), or ready to play */
static void ready(struct ui *u, const char *server, const char *code, const char *note)
{
    struct ui_card c = {
        .title = code ? "Sign in to Jellyfin" : "Ready to play",
        .line = code ? "In a Jellyfin app: Settings > Quick Connect, enter"
                     : "In a Jellyfin app, choose an item and play it on this MiSTer",
        .big = code, .foot = server, .note = note,
    };
    ui_card(u, &c);
}

/* the raster the overlay is drawn for (interface 0.10, h264ring_raster: word 80's size, word 47's
 * shape). Under A' (docs/hdmi_raster.md: Progressive, Analog Aspect Auto, a picture wider than
 * the HDMI display) the core letterboxes the picture INSIDE the raster and HDMI shows the whole
 * raster at the display's shape, so the bottom lines -- where the subtitles go -- are the bars
 * below a scope film. Word 47 is trusted (F8 did not reproduce: hdmi_raster.md §7); the client
 * no longer second-guesses the core's rule. */
/* the raster's width (0.10: 720 fitted; the picture's own on "Native (HDMI)") -- the canvas spans it */
static unsigned raster_width(const struct app *a)
{
    if (!a->core.have_st) return 720u;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    return rs.w ? rs.w : 720u;
}

/* (0.11) the transcode's box: 1280x720 only where the output shows a 720-line picture at its own
 * size -- Video Output Native (HDMI), as the core resolved it (0.14: Auto is Native on an HDMI-only
 * MiSTer), on a core whose native raster reaches 720 lines (word 81's
 * native_h; 480 on every core so far: the HD raster is a later branch, docs/roadmap.md). On the
 * fitted 720-wide rasters (480i / 480p / 576, HDMI's fitted) a 720p transcode adds nothing but
 * work: 854x480 (docs/jellyfin.md S2). */
static int hd_box(const struct app *a)
{
    if (!a->core.have_st) return 0;
    struct h264ring_caps caps;
    h264ring_caps(&a->core.st, &caps);
    return h264ring_video_out(&a->core.st) == H264RING_VOUT_NATIVE && caps.native_h >= 720;   /* (0.14) as resolved: Auto can be Native */
}

static unsigned raster_lines(const struct app *a)
{
    if (!a->core.have_st) return 480u;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    if (rs.h) return rs.h;
    return H264RING_ST(&a->core.st, RASTER_STD) == 2 ? 576u : 480u;
}

/* the shape the whole raster is shown at: 4:3 on the analog (interlaced) raster, else the aspect
 * the core gives HDMI's scaler (word 47) -- 4:3 until the core has reported one */
static double raster_aspect(const struct app *a)
{
    if (!a->core.have_st) return 4.0 / 3.0;
    struct h264ring_raster rs;
    h264ring_raster(&a->core.st, &rs);
    return rs.aspect;
}

static void show_now(struct app *a)
{
    struct ui_now n = {
        .title = a->info.name, .subtitle = a->subline,
        .position = a->seek_pending ? a->seek_target : a->pos,
        .duration = (double)a->info.runtime_ticks / TICKS, .paused = a->paused,
        .loading = a->loading, .seeking = a->seek_pending,
        .audio = a->st.audio_name, .subs = a->st.sub_index >= 0 ? a->st.sub_name : "",
    };
    ui_playing(a->ui, &n);
}

static void report(struct app *a, enum jf_report what)
{
    if (!a->playing) return;
    struct report_job j = { .what = what, .st = a->st, .ticks = (int64_t)(a->pos * TICKS),
                            .paused = a->paused, .volume = a->volume };
    snprintf(j.item, sizeof j.item, "%s", a->info.id);
    if (a->rep.up) reporter_post(&a->rep, &j);
    else jf_report(&a->jf, what, j.item, &a->st, j.ticks, j.paused, j.volume);
    a->progress_ms = now_ms();
}

static void close_player(struct app *a)
{
    if (a->pl) player_close(a->pl);
    a->pl = NULL;
}

/* open the stream at `start` seconds (the same PlaybackInfo: a seek re-opens the same URL --
 * direct play seeks in the file, HLS seeks inside the server's playlist, which restarts its
 * transcode there; both carry the item's time in their timestamps, offset by the stream's
 * start_time: docs/jellyfin.md S2 "Delivery").
 * keep: a stream is on screen (a seek, a track change) -- PAUSE the core (the picture holds, the
 * sound stops) and open the new stream HELD; the flush that blacks the screen comes only once its
 * first IDR is checked and ready (tend_playing, PL_READY): the black shrinks from the whole open
 * (a transcode's restart: seconds) to the IDR's decode. Otherwise (a first start) flush now. */
static int open_stream(struct app *a, double start, int keep)
{
    close_player(a);
    if (keep) {
        h264ring_set_pause(a->core.r, 1);
        a->held = 1;
    } else {
        core_new_stream(&a->core);
        h264ring_set_pause(a->core.r, 0);
        a->held = 0;
    }
    a->paused = 0;
    struct player_cfg cfg = {
        .url = a->st.url, .cafile = a->jf.cafile, .start_s = start, .seek = 1,
        .audio_stream = a->st.transcode ? -1 : a->st.audio_index, .hold = keep,
        .hls_trim = a->st.transcode,
        .colour = a->st.colour,                   /* (0.16) a transcode: its source's (colour.md R4) */
    };
    struct h264ring_caps caps;                    /* (0.11) the core's largest picture and rate */
    h264ring_caps(&a->core.st, &caps);
    cfg.max_mbs = caps.max_mbs;
    cfg.mb_rate = caps.mb_rate;
    a->pos = start;
    a->loading = 1;
    return player_open(&a->pl, &cfg);
}

static void stop_playing(struct app *a, int report_it)
{
    if (!a->playing) return;
    if (report_it && a->reported) report(a, JF_REPORT_STOPPED);
    close_player(a);
    core_new_stream(&a->core);           /* black under the ready screen, the queue dropped */
    subs_free(a->subs);
    a->subs = NULL;
    a->sub_gen++;                        /* a fetch still running is dropped when it answers */
    a->playing = 0;
    ui_subtitle(a->ui, NULL);
    ui_playing(a->ui, NULL);
    ready(a->ui, a->server_name, NULL, NULL);
}

static void load_subs(struct app *a);

/* PlaybackInfo, then the stream. audio / sub: Jellyfin's stream indexes (-1 / -2: the defaults) */
static int start_item(struct app *a, const char *item, double start, int audio, int sub, int force)
{
    int same = a->playing && !strcmp(a->info.id, item);
    int keep = same && a->pl && !force;  /* the picture stays up while the new stream opens (not for
                                            the CAVLC retry: what is on screen is nothing) */
    if (a->playing && !same) stop_playing(a, 1);
    else if (same) {                     /* the same item again (a track change, the CAVLC retry):
                                            Stopped only for a play the server saw start */
        if (a->reported) report(a, JF_REPORT_STOPPED);
        if (!keep) close_player(a);
    }
    if (!same && jf_item(&a->jf, item, &a->info)) {
        ui_message(a->ui, "Could not open the item", NULL, 5000);
        return -ENOENT;
    }
    a->subline[0] = 0;
    if (a->info.series[0])
        snprintf(a->subline, sizeof a->subline, "%s  S%d E%d", a->info.series, a->info.season, a->info.episode);
    a->hd = hd_box(a);
    int rc = jf_playback_info(&a->jf, item, jf_profile_json(a->hd), (int64_t)(start * TICKS), audio, sub, force, &a->st);
    if (rc) {
        ui_message(a->ui, "The server offered no stream for this item", NULL, 6000);
        a->playing = 1;
        stop_playing(a, 0);
        return rc;
    }
    a->forced = force;
    load_subs(a);
    fprintf(stderr, "jellyfin: play %s at %.1f s: %s%s\n", a->info.name, start,
            a->st.transcode ? "transcode" : "direct play", a->st.sub_burned ? ", subtitles burned in" : "");
    a->playing = 1;
    a->reported = 0;
    rc = open_stream(a, start, keep);
    show_now(a);
    ui_panel(a->ui, PANEL_MS);
    return rc;
}

static double clamp_pos(const struct app *a, double t)
{
    double dur = (double)a->info.runtime_ticks / TICKS;
    if (dur > 10 && t > dur - 5) t = dur - 5;
    return t < 0 ? 0 : t;
}

static void seek_to(struct app *a, double t)
{
    a->seek_pending = 0;
    fprintf(stderr, "jellyfin: seek to %.1f s (from %.1f s)\n", clamp_pos(a, t), a->pos);
    int keep = a->pl != NULL;
    open_stream(a, clamp_pos(a, t), keep);
    show_now(a);
    ui_panel(a->ui, PANEL_MS);
    if (keep) a->report_at_release = 1;          /* the position is the new stream's once it starts */
    else report(a, JF_REPORT_PROGRESS);
}

/* a seek step from the pad or the keyboard: steps add up while they keep coming (taps, or a button
 * held: input.c repeats it), the panel shows the target, and the stream restarts ONCE, SEEK_SETTLE_MS
 * after the last -- a transcode's restart takes seconds, one per tap made the controls feel lost */
static void seek_step(struct app *a, double d)
{
    if (!a->seek_pending) a->seek_target = a->pos;
    a->seek_target = clamp_pos(a, a->seek_target + d);
    a->seek_pending = 1;
    a->seek_due = now_ms() + SEEK_SETTLE_MS;
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
    report(a, JF_REPORT_PROGRESS);
}

static void set_volume(struct app *a, int v)
{
    a->volume = v < 0 ? 0 : v > 100 ? 100 : v;
    /* 0.5 dB steps: 100 % is 0, 50 % is 12 (6 dB), 0 is 255 (mute) */
    unsigned att = a->volume == 0 ? 255u : (unsigned)lround(-40.0 * log10(a->volume / 100.0));
    h264ring_set_atten(a->core.r, a->volume == 0 ? 255u : att > 254 ? 254 : att);
    char t[16];
    snprintf(t, sizeof t, "%d %%", a->volume);
    ui_message(a->ui, "Volume", a->volume ? t : "Muted", 1500);
    report(a, JF_REPORT_PROGRESS);
}

static void next_item(struct app *a, int step)
{
    int i = a->qi + step;
    if (i < 0 || i >= a->qn) { stop_playing(a, 1); return; }
    a->qi = i;
    start_item(a, a->queue[i], 0, -1, -2, 0);
}

/* the audio / subtitle buttons: each press steps a pending choice (shown at once), applied
 * TRACK_SETTLE_MS after the last -- an audio change on a transcode restarts it (seconds), so three
 * quick presses must not be three restarts */
static void cycle_audio(struct app *a)
{
    if (!a->playing) return;
    if (a->st.n_audio < 2) { ui_message(a->ui, "Audio", "This item has one audio track", 2000); return; }
    int cur = a->track_pending == 1 ? a->track_target : a->st.audio_index, k = 0;
    for (int i = 0; i < a->st.n_audio; i++) if (a->st.audio_list[i] == cur) k = (i + 1) % a->st.n_audio;
    a->track_pending = 1;
    a->track_target = a->st.audio_list[k];
    a->track_due = now_ms() + TRACK_SETTLE_MS;
    ui_message(a->ui, "Audio", a->st.audio_names[k], 2000);
}

/* the current track's cues: fetched by the fetcher (sub_apply takes them); the old ones go now */
static void load_subs(struct app *a)
{
    subs_free(a->subs);
    a->subs = NULL;
    ui_subtitle(a->ui, NULL);
    a->sub_gen++;                                     /* whatever was being fetched is stale */
    if (!a->st.sub_url[0]) return;
    struct sub_job j = { .gen = a->sub_gen, .need_info = 0 };
    snprintf(j.url, sizeof j.url, "%s", a->st.sub_url);
    fetcher_post(&a->fx, &a->jf, &j);
}

/* another subtitle track (-1: none). A text track is the overlay's -- drawn by the client, the
 * stream untouched; only a track the server must burn in (or one burned in now) restarts the stream
 * (on the rig a transcode's restart left the picture black for ~7 s at every press). The server is
 * asked off the loop's thread (the fetcher): the picture and the overlay go on meanwhile. */
static void set_subs(struct app *a, int idx)
{
    if (!a->playing) return;
    if (!a->st.sub_burned) {
        if (idx < 0) {                                /* off: nothing to ask */
            a->st.sub_index = -1;
            a->st.sub_url[0] = a->st.sub_name[0] = 0;
            load_subs(a);
            ui_message(a->ui, "Subtitles", "Off", 2000);
            show_now(a);
            report(a, JF_REPORT_PROGRESS);
            return;
        }
        struct sub_job j = { .gen = ++a->sub_gen, .need_info = 1, .ticks = (int64_t)(a->pos * TICKS),
                             .audio = a->st.audio_index, .idx = idx, .forced = a->forced, .hd = a->hd };
        snprintf(j.item, sizeof j.item, "%s", a->info.id);
        ui_message(a->ui, "Subtitles", "Loading...", 30000);
        fetcher_post(&a->fx, &a->jf, &j);
        return;
    }
    ui_message(a->ui, "Subtitles", "The server burns these in: restarting the picture", 4000);
    start_item(a, a->info.id, a->pos, a->st.audio_index, idx, a->forced);
}

/* a fetch's result, on the loop's thread: a switch's track (or the restart a burned-in one needs),
 * then the cues */
static void sub_apply(struct app *a)
{
    struct sub_res r;
    if (!fetcher_take(&a->fx, &r)) return;
    if (r.gen != a->sub_gen || !a->playing) { free(r.text); return; }
    if (r.need_info) {
        if (!r.ok) { ui_message(a->ui, "Subtitles", "The server did not answer", 4000); return; }
        if (r.burned) {
            free(r.text);
            ui_message(a->ui, "Subtitles", "The server burns these in: restarting the picture", 4000);
            start_item(a, a->info.id, a->pos, a->st.audio_index, r.idx, a->forced);
            return;
        }
        a->st.sub_index = r.idx;
        snprintf(a->st.sub_url, sizeof a->st.sub_url, "%s", r.url);
        snprintf(a->st.sub_name, sizeof a->st.sub_name, "%s", r.name);
    }
    subs_free(a->subs);
    a->subs = r.text ? subs_parse(r.text, r.len) : NULL;
    free(r.text);
    if (!a->subs) { ui_message(a->ui, "The subtitles did not load", NULL, 4000); return; }
    fprintf(stderr, "jellyfin: subtitles %s: %u cues\n", a->st.sub_name, subs_count(a->subs));
    if (r.need_info) {
        ui_message(a->ui, "Subtitles", a->st.sub_name, 2000);
        show_now(a);
        report(a, JF_REPORT_PROGRESS);
    }
}

static void cycle_subs(struct app *a)
{
    if (!a->playing) return;
    if (!a->st.n_sub) { ui_message(a->ui, "Subtitles", "This item has none", 2000); return; }
    int cur = a->track_pending == 2 ? a->track_target : a->st.sub_index, next = -1, k = -1;
    if (cur < 0) { next = a->st.sub_list[0]; k = 0; }
    else for (int i = 0; i < a->st.n_sub; i++)
        if (a->st.sub_list[i] == cur && i + 1 < a->st.n_sub) { next = a->st.sub_list[i + 1]; k = i + 1; }
    a->track_pending = 2;
    a->track_target = next;
    a->track_due = now_ms() + TRACK_SETTLE_MS;
    ui_message(a->ui, "Subtitles", k < 0 ? "Off" : a->st.sub_names[k], 2000);
}

static void act(struct app *a, enum cl_action x)
{
    fprintf(stderr, "jellyfin: input: %s%s\n", input_action_name(x), a->playing ? "" : " (nothing plays)");
    if (!a->playing) return;
    switch (x) {
    case ACT_PAUSE: set_pause(a, !a->paused); break;
    case ACT_BACK: seek_step(a, -10); break;
    case ACT_FWD: seek_step(a, 30); break;
    case ACT_BACK_BIG: seek_step(a, -300); break;
    case ACT_FWD_BIG: seek_step(a, 300); break;
    case ACT_STOP: stop_playing(a, 1); break;
    case ACT_SUBS: cycle_subs(a); break;
    case ACT_AUDIO: cycle_audio(a); break;
    case ACT_INFO: ui_panel(a->ui, PANEL_MS); break;
    default: break;
    }
}

static int arg_int(const cJSON *o, const char *k, int dflt)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    if (cJSON_IsNumber(v)) return v->valueint;
    if (cJSON_IsString(v) && v->valuestring[0]) return atoi(v->valuestring);
    return dflt;
}

static double arg_ticks(const cJSON *o, const char *k)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? v->valuedouble / TICKS : 0;
}

/* a message from the server's socket (docs/jellyfin.md S4 "Being a cast target") */
static void on_message(struct app *a, cJSON *m)
{
    const cJSON *t = cJSON_GetObjectItemCaseSensitive(m, "MessageType");
    const cJSON *d = cJSON_GetObjectItemCaseSensitive(m, "Data");
    if (!cJSON_IsString(t)) return;
    const char *type = t->valuestring;
    if (!strcmp(type, "ForceKeepAlive")) { a->jf.ws_tx_ms = 0; jf_ws_keepalive(&a->jf); return; }
    /* a command for this player is activity (it wakes the screensaver, P5); the server's other
     * broadcasts (library and task updates, keep-alives) are not */
    if (!strcmp(type, "Play") || !strcmp(type, "Playstate") || !strcmp(type, "GeneralCommand"))
        ui_activity(a->ui);
    if (strcmp(type, "KeepAlive")) {
        const cJSON *c = d ? cJSON_GetObjectItemCaseSensitive(d, "Command") : NULL;
        const cJSON *nm = d ? cJSON_GetObjectItemCaseSensitive(d, "Name") : NULL;
        fprintf(stderr, "jellyfin: server: %s%s%s\n", type,
                cJSON_IsString(c) ? " " : cJSON_IsString(nm) ? " " : "",
                cJSON_IsString(c) ? c->valuestring : cJSON_IsString(nm) ? nm->valuestring : "");
    }
    if (!strcmp(type, "Play") && d) {
        const cJSON *ids = cJSON_GetObjectItemCaseSensitive(d, "ItemIds");
        const cJSON *cmd = cJSON_GetObjectItemCaseSensitive(d, "PlayCommand");
        int n = cJSON_GetArraySize(ids);
        if (n <= 0) return;
        const char *how = cJSON_IsString(cmd) ? cmd->valuestring : "PlayNow";
        if (!strcmp(how, "PlayNext") || !strcmp(how, "PlayLast")) {
            int at = !strcmp(how, "PlayNext") && a->playing ? a->qi + 1 : a->qn;
            for (int i = 0; i < n && a->qn < QUEUE_MAX; i++, at++) {
                const cJSON *id = cJSON_GetArrayItem(ids, i);
                if (!cJSON_IsString(id)) continue;
                memmove(a->queue[at + 1], a->queue[at], (size_t)(a->qn - at) * sizeof a->queue[0]);
                snprintf(a->queue[at], sizeof a->queue[0], "%s", id->valuestring);
                a->qn++;
            }
            if (n > 0 && a->qn >= QUEUE_MAX) {
                fprintf(stderr, "jellyfin: the queue is full (%d items): the rest were not added\n", QUEUE_MAX);
                ui_message(a->ui, "The queue is full", "Only the first items were added", 5000);
            }
            if (!a->playing) { a->qi = 0; start_item(a, a->queue[0], 0, -1, -2, 0); }
            return;
        }
        a->qn = 0;
        for (int i = 0; i < n && i < QUEUE_MAX; i++) {
            const cJSON *id = cJSON_GetArrayItem(ids, i);
            if (cJSON_IsString(id)) snprintf(a->queue[a->qn++], sizeof a->queue[0], "%s", id->valuestring);
        }
        if (!a->qn) return;
        if (n > QUEUE_MAX) {
            fprintf(stderr, "jellyfin: %d items played; the first %d kept\n", n, QUEUE_MAX);
            ui_message(a->ui, "A long list", "Only the first items will play", 5000);
        }
        a->qi = arg_int(d, "StartIndex", 0);
        if (a->qi < 0 || a->qi >= a->qn) a->qi = 0;
        start_item(a, a->queue[a->qi], arg_ticks(d, "StartPositionTicks"),
                   arg_int(d, "AudioStreamIndex", -1), arg_int(d, "SubtitleStreamIndex", -2), 0);
        return;
    }
    if (!strcmp(type, "Playstate") && d) {
        const cJSON *c = cJSON_GetObjectItemCaseSensitive(d, "Command");
        const char *cmd = cJSON_IsString(c) ? c->valuestring : "";
        if (!strcmp(cmd, "Stop")) stop_playing(a, 1);
        else if (!strcmp(cmd, "Pause")) set_pause(a, 1);
        else if (!strcmp(cmd, "Unpause")) set_pause(a, 0);
        else if (!strcmp(cmd, "PlayPause")) set_pause(a, !a->paused);
        else if (!strcmp(cmd, "Seek") && a->playing) seek_to(a, arg_ticks(d, "SeekPositionTicks"));
        else if (!strcmp(cmd, "NextTrack") && a->playing) next_item(a, 1);
        else if (!strcmp(cmd, "PreviousTrack") && a->playing) { if (a->pos > 10) seek_to(a, 0); else next_item(a, -1); }
        else if (!strcmp(cmd, "Rewind") && a->playing) seek_to(a, a->pos - 10);
        else if (!strcmp(cmd, "FastForward") && a->playing) seek_to(a, a->pos + 30);
        return;
    }
    if (!strcmp(type, "GeneralCommand") && d) {
        const cJSON *n = cJSON_GetObjectItemCaseSensitive(d, "Name");
        const cJSON *args = cJSON_GetObjectItemCaseSensitive(d, "Arguments");
        const char *name = cJSON_IsString(n) ? n->valuestring : "";
        if (!strcmp(name, "SetVolume")) set_volume(a, arg_int(args, "Volume", a->volume));
        else if (!strcmp(name, "VolumeUp")) set_volume(a, a->volume + 5);
        else if (!strcmp(name, "VolumeDown")) set_volume(a, a->volume - 5);
        else if (!strcmp(name, "Mute")) set_volume(a, 0);
        else if (!strcmp(name, "Unmute") || (!strcmp(name, "ToggleMute") && a->volume == 0)) set_volume(a, 100);
        else if (!strcmp(name, "ToggleMute")) set_volume(a, 0);
        else if (!strcmp(name, "SetAudioStreamIndex") && a->playing)
            start_item(a, a->info.id, a->pos, arg_int(args, "Index", -1), a->st.sub_index, a->forced);
        else if (!strcmp(name, "SetSubtitleStreamIndex") && a->playing)
            set_subs(a, arg_int(args, "Index", -1));
        else if (!strcmp(name, "DisplayMessage")) {
            const cJSON *h = cJSON_GetObjectItemCaseSensitive(args, "Header"), *x = cJSON_GetObjectItemCaseSensitive(args, "Text");
            int ms = arg_int(args, "TimeoutMs", 5000);
            ui_message(a->ui, cJSON_IsString(h) ? h->valuestring : "", cJSON_IsString(x) ? x->valuestring : "",
                       (unsigned)(ms > 0 ? ms : 5000));
        }
    }
}

/* one loop's worth of the stream: the player, its end, the reports, the subtitles */
static void tend_playing(struct app *a)
{
    sub_apply(a);
    if (!a->playing || !a->pl) return;
    if (a->seek_pending && now_ms() >= a->seek_due) seek_to(a, a->seek_target);
    if (a->track_pending && now_ms() >= a->track_due) {
        int kind = a->track_pending, t = a->track_target;
        a->track_pending = 0;
        if (kind == 1 && t != a->st.audio_index) {
            fprintf(stderr, "jellyfin: audio track %d\n", t);
            start_item(a, a->info.id, a->pos, t, a->st.sub_index, a->forced);
        } else if (kind == 2 && t != a->st.sub_index) {
            fprintf(stderr, "jellyfin: subtitle track %d\n", t);
            set_subs(a, t);
        }
        if (!a->playing || !a->pl) return;
    }
    enum player_state s = player_step(a->pl, a->core.r);
    if (s == PL_READY) {                        /* the new stream's IDR is ready: now the flush */
        core_new_stream(&a->core);
        h264ring_set_pause(a->core.r, a->paused);
        player_release(a->pl);
        a->held = 0;
        s = player_step(a->pl, a->core.r);
        if (a->report_at_release && a->reported) report(a, JF_REPORT_PROGRESS);
        a->report_at_release = 0;
    }
    const char *why = NULL;
    if (s == PL_UNDECODABLE || core_refused(&a->core, &why)) {
        const char *what = why ? why : h264check_name(player_check(a->pl));
        if (!a->forced) {                       /* what the server could not see: ask it for a transcode */
            fprintf(stderr, "jellyfin: the stream uses %s -- asking the server to transcode it\n", what);
            ui_message(a->ui, "Transcoding", what, 4000);
            start_item(a, a->info.id, a->pos, a->st.audio_index, a->st.sub_index, 1);
        } else {
            fprintf(stderr, "jellyfin: the server's transcode is not decodable either (%s)\n", what);
            ui_message(a->ui, "This item cannot play", what, 8000);
            stop_playing(a, 1);
        }
        return;
    }
    if (s == PL_FAILED) {
        fprintf(stderr, "jellyfin: the stream failed: %s\n", player_error(a->pl));
        ui_message(a->ui, "Playback failed", player_error(a->pl), 8000);
        stop_playing(a, 1);
        return;
    }
    /* held: the clock is the OLD picture's (paused, still "running") -- the position stays the target
     * and the panel says Loading until the new stream's first picture */
    int running = !a->held && core_flag(&a->core, H264RING_L_STC_RUN);
    if (!a->held) a->pos = player_position(a->pl, core_stc(&a->core), running);
    if (running && a->loading) { a->loading = 0; show_now(a); }
    if (running && !a->reported) { report(a, JF_REPORT_START); a->reported = 1; }
    if (s == PL_DRAINED && core_flag(&a->core, H264RING_L_ENDED)) {
        a->pos = (double)a->info.runtime_ticks / TICKS;
        if (a->qi + 1 < a->qn) next_item(a, 1);  /* reports this one Stopped at its end */
        else stop_playing(a, 1);
        return;
    }
    if (a->reported && now_ms() - a->progress_ms >= PROGRESS_MS) report(a, JF_REPORT_PROGRESS);
    if (a->subs) ui_subtitle(a->ui, running ? subs_at(a->subs, a->pos) : NULL);
    show_now(a);
}

/* idle a while with the screen and the core tended (sign-in waits); 0, or -ENODEV: the core went */
static int idle_ms(struct app *a, unsigned ms)
{
    for (uint64_t t0 = now_ms(); !stop && now_ms() - t0 < ms; usleep(20000)) {
        if (core_poll(&a->core)) return -ENODEV;
        /* the sign-in takes no buttons, but a press wakes the screensaver over the code (P5) */
        enum cl_action acts[16];
        for (unsigned i = 0, n = input_poll(&a->in, a->core.r, acts, 16); i < n; i++) ui_wake(a->ui);
        ui_draw(a->ui, raster_width(a), raster_lines(a), raster_aspect(a));
    }
    return 0;
}

static int sign_in(struct app *a, const struct ini *c, struct state *s)
{
    if (s->token[0] && !strcmp(s->server, c->server)) {
        snprintf(a->jf.token, sizeof a->jf.token, "%s", s->token);
        snprintf(a->jf.user_id, sizeof a->jf.user_id, "%s", s->user_id);
        int rc = jf_check_token(&a->jf);
        if (rc == 0) return 0;
        if (rc != -EACCES) return rc;           /* the server unreachable: not a reason to sign in again */
        a->jf.token[0] = 0;
    }
    int rc;
    if (c->user[0]) {
        rc = jf_login_password(&a->jf, c->user, c->password);
    } else {
        rc = jf_qc_enabled(&a->jf);
        if (rc <= 0) {
            ready(a->ui, a->server_name, NULL,
                     rc == 0 ? "Quick Connect is off on this server: add user= and password= to jellyfin.ini"
                             : "The server does not answer");
            return idle_ms(a, 10000) ? -ENODEV : -EACCES;
        }
        char secret[128], code[16];
        rc = -ETIMEDOUT;
        while (!stop && rc) {
            if (jf_qc_initiate(&a->jf, secret, sizeof secret, code, sizeof code)) return -EIO;
            fprintf(stderr, "jellyfin: Quick Connect code %s\n", code);
            ready(a->ui, a->server_name, code, NULL);
            for (uint64_t t0 = now_ms(); !stop && rc && now_ms() - t0 < 9 * 60 * 1000;) {   /* expires at 10 min */
                if (idle_ms(a, QC_POLL_MS)) return -ENODEV;
                if (jf_qc_poll(&a->jf, secret) == 1) rc = jf_qc_finish(&a->jf, secret);
            }
        }
    }
    if (rc) return rc;
    snprintf(s->server, sizeof s->server, "%s", c->server);
    snprintf(s->token, sizeof s->token, "%s", a->jf.token);
    snprintf(s->user_id, sizeof s->user_id, "%s", a->jf.user_id);
    state_write(s);
    return 0;
}

static int cmd_cast(void)
{
    struct ini c;
    struct state s;
    struct app a;
    memset(&a, 0, sizeof a);
    a.volume = 100;
    a.queue = calloc(QUEUE_MAX + 1, sizeof *a.queue);
    if (!a.queue) return 1;
    if (ini_read(&c)) {
        fprintf(stderr, "jellyfin: %s needs server=https://your-server:8096\n", in_dir("jellyfin.ini"));
        return 2;
    }
    state_read(&s);
    state_write(&s);                            /* the device id is kept from the first run */
    if (jf_init(&a.jf, c.server, cafile_default(), s.device_id, c.name)) return 1;
    a.jf.verbose = getenv("JELLYFIN_VERBOSE") != NULL;
    if (core_open(&a.core, getenv("JELLYFIN_RBF"))) return 1;
    if (ui_open(&a.ui, a.core.r, dir)) return 1;
    ui_saver_times(a.ui, (unsigned)(c.saver_dim * 60000.0), (unsigned)(c.saver_black * 60000.0));
    char ver[32];
    if (jf_public_info(&a.jf, a.server_name, sizeof a.server_name, ver, sizeof ver)) {
        snprintf(a.server_name, sizeof a.server_name, "%.95s", c.server);
        ready(a.ui, a.server_name, NULL, "The server does not answer -- retrying");
    } else {
        fprintf(stderr, "jellyfin: %s, Jellyfin %s\n", a.server_name, ver);
        ready(a.ui, a.server_name, NULL, NULL);
    }
    int rc;
    while (!stop && (rc = sign_in(&a, &c, &s))) {
        if (rc == -ENODEV) goto out;
        fprintf(stderr, "jellyfin: not signed in (%s) -- retrying\n", strerror(-rc));
        ready(a.ui, a.server_name, NULL, "Could not sign in -- retrying");
        if (idle_ms(&a, 5000)) goto out;
    }
    ready(a.ui, a.server_name, NULL, NULL);
    if (reporter_start(&a.rep, &a.jf)) fprintf(stderr, "jellyfin: the reports go out on the loop's thread\n");
    if (fetcher_start(&a.fx, &a.jf)) fprintf(stderr, "jellyfin: the subtitles are fetched on the loop's thread\n");
    while (!stop) {
        if (core_poll(&a.core)) break;
        if (!a.jf.ws && now_ms() - a.ws_retry_ms >= WS_RETRY_MS) {
            a.ws_retry_ms = now_ms();
            if (jf_capabilities(&a.jf, jf_profile_json(hd_box(&a))) == 0 && jf_ws_open(&a.jf) == 0)
                fprintf(stderr, "jellyfin: ready: play to \"%s\" from a Jellyfin app\n", c.name);
        }
        int closed = 0;
        for (cJSON *m; (m = jf_ws_poll(&a.jf, &closed)); cJSON_Delete(m)) on_message(&a, m);
        jf_ws_keepalive(&a.jf);
        enum cl_action acts[16];
        unsigned na = input_poll(&a.in, a.core.r, acts, 16);
        for (unsigned i = 0; i < na; i++) {
            if (ui_wake(a.ui)) {                       /* the press only wakes the screensaver (P5) */
                fprintf(stderr, "jellyfin: input: %s (woke the screensaver)\n", input_action_name(acts[i]));
                continue;
            }
            if (acts[i] == ACT_STOP && !a.playing) {   /* on the ready screen: quit (the launcher loads the menu) */
                fprintf(stderr, "jellyfin: quit from the ready screen\n");
                stop = 1;
            }
            act(&a, acts[i]);
        }
        tend_playing(&a);
        ui_busy(a.ui, a.playing && !a.paused);     /* video playing: no screensaver */
        ui_draw(a.ui, raster_width(&a), raster_lines(&a), raster_aspect(&a));
        usleep(2000);
    }
out:
    stop_playing(&a, 1);
    reporter_stop(&a.rep);                      /* drains: the Stopped goes out before the exit */
    fetcher_stop(&a.fx);
    ui_close(a.ui);
    jf_free(&a.jf);
    core_close(&a.core);
    free(a.queue);
    return 0;
}

static int cmd_play(int argc, char **argv)
{
    struct player_cfg cfg = { .audio_stream = -1, .cafile = cafile_default() };
    char headers[1024] = "";
    for (int i = 0; i < argc; i++) {
        if (!strcmp(argv[i], "--start") && i + 1 < argc) { cfg.start_s = atof(argv[++i]); cfg.seek = 1; }
        else if (!strcmp(argv[i], "--audio") && i + 1 < argc) cfg.audio_stream = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--header") && i + 1 < argc) {
            strncat(headers, argv[++i], sizeof headers - strlen(headers) - 3);
            strcat(headers, "\r\n");
        } else if (!cfg.url) cfg.url = argv[i];
        else { fprintf(stderr, "play: what is %s?\n", argv[i]); return 2; }
    }
    if (!cfg.url) { fprintf(stderr, "play: a URL\n"); return 2; }
    cfg.headers = headers[0] ? headers : NULL;

    struct core core;
    if (core_open(&core, getenv("JELLYFIN_RBF"))) return 1;
    struct h264ring_caps caps;                    /* (0.11) the core's largest picture and rate */
    h264ring_caps(&core.st, &caps);
    cfg.max_mbs = caps.max_mbs;
    cfg.mb_rate = caps.mb_rate;
    struct player *pl;
    if (player_open(&pl, &cfg)) return 1;
    uint64_t last = 0, t0 = now_ms();
    enum player_state st = PL_OPENING;
    int rc = 0;
    while (!stop) {
        if (core_poll(&core)) { rc = 1; break; }
        st = player_step(pl, core.r);
        const char *why;
        if (st == PL_FAILED) { fprintf(stderr, "play: %s\n", player_error(pl)); rc = 1; break; }
        if (st == PL_UNDECODABLE) {
            fprintf(stderr, "play: the core cannot decode this stream: %s\n", h264check_name(player_check(pl)));
            rc = 1; break;
        }
        if (core_refused(&core, &why)) { fprintf(stderr, "play: the core refused the stream: %s\n", why); rc = 1; break; }
        if (st == PL_DRAINED && core_flag(&core, H264RING_L_ENDED)) break;
        if (now_ms() - last >= 1000) {
            last = now_ms();
            struct player_counts n;
            player_counts(pl, &n);
            printf("%7.1f s  position %8.2f  au %llu  audio %llu  errors %u  late %u  skipped %u\n",
                   (double)(last - t0) / 1000.0, player_position(pl, core_stc(&core), core_flag(&core, H264RING_L_STC_RUN)),
                   (unsigned long long)n.video_aus, (unsigned long long)n.audio_records, core_errors(&core),
                   (unsigned)H264RING_ST(&core.st, DISP_LATE), (unsigned)H264RING_ST(&core.st, DISP_SKIP));
            fflush(stdout);
        }
        usleep(2000);
    }
    struct player_counts n;
    player_counts(pl, &n);
    printf("end: %s  au %llu  audio records %llu  dropped before the IDR %llu  errors %u\n",
           st == PL_DRAINED ? "played" : stop ? "stopped" : "failed",
           (unsigned long long)n.video_aus, (unsigned long long)n.audio_records,
           (unsigned long long)n.dropped_before_idr, core_errors(&core));
    player_close(pl);
    core_close(&core);
    return rc;
}

#ifdef CLIENT_TEST
/* the host test (tests/test_client.c) runs the client on a thread beside its fake core */
void jf_test_stop(void) { stop = 1; }
int jf_main(int argc, char **argv);
int jf_main(int argc, char **argv)
#else
int main(int argc, char **argv)
#endif
{
    /* FFmpeg's info level logs every URL it opens, and a transcode's URLs carry the access token
     * (ApiKey=...): the log is a file on the SD card, so warnings and errors only */
    av_log_set_level(AV_LOG_WARNING);
    if (getenv("JELLYFIN_AVLOG")) {        /* diagnostics only: "debug" shows the token too */
        av_log_set_level(!strcmp(getenv("JELLYFIN_AVLOG"), "debug") ? AV_LOG_DEBUG : AV_LOG_INFO);
        av_log_set_flags(AV_LOG_PRINT_TIME);
    }
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGPIPE, SIG_IGN);
    /* DIR: --dir, else the binary's own directory */
    ssize_t n = readlink("/proc/self/exe", dir, sizeof dir - 1);
    dir[n > 0 ? n : 0] = 0;
    char *slash = strrchr(dir, '/');
    if (slash) *slash = 0; else snprintf(dir, sizeof dir, ".");
    if (argc >= 3 && !strcmp(argv[1], "--dir")) { snprintf(dir, sizeof dir, "%s", argv[2]); argc -= 2; argv += 2; }
    if (argc >= 2 && !strcmp(argv[1], "play")) return cmd_play(argc - 2, argv + 2);
    if (argc == 1) return cmd_cast();
    fprintf(stderr, "usage: jellyfin [--dir DIR]                 the cast target (DIR/jellyfin.ini)\n"
                    "       jellyfin [--dir DIR] play URL [--start S] [--audio N] [--header \"Name: value\"]\n");
    return 2;
}
