/* jf -- the Jellyfin server as the client talks to it (docs/jellyfin.md S4): the MediaBrowser
 * header only (legacy authentication is off by default from 12.0), sign-in by Quick Connect,
 * the capabilities that make the MiSTer a cast target, the WebSocket its commands arrive on,
 * PlaybackInfo with the device profile, and the playback reports. libcurl + cJSON. */
#ifndef JF_JF_H
#define JF_JF_H

#include <stdint.h>
#include "cJSON.h"

struct jf {
    char server[256];          /* https://host[:port][/base], no trailing slash */
    char cafile[512];
    char device_id[40];        /* generated once, kept (a new sign-in revokes the device's old tokens) */
    char device_name[64];
    char token[80], user_id[40];
    void *http;                /* CURL * */
    void *ws;                  /* CURL * (CONNECT_ONLY = 2), NULL while closed */
    uint64_t ws_tx_ms;         /* the last frame sent (the keep-alive) */
    char *ws_buf;              /* a message being reassembled */
    size_t ws_len, ws_cap;
    int verbose;
};

int  jf_init(struct jf *j, const char *server, const char *cafile, const char *device_id,
             const char *device_name);
void jf_free(struct jf *j);
/* a second handle on the same server and sign-in (its own HTTP connection, no socket): for another
 * thread -- one jf is never used by two threads at once */
int  jf_clone(struct jf *dst, const struct jf *src);

/* an HTTP request; body (JSON text) may be NULL; *out the parsed JSON reply when there is one.
 * Returns the HTTP status, or a negative errno-style value when no reply came. */
int  jf_request(struct jf *j, const char *method, const char *path, const char *body, cJSON **out);

/* the server's name and version (no sign-in needed); 0 or < 0 */
int  jf_public_info(struct jf *j, char *name, size_t nlen, char *version, size_t vlen);

/* ---- signing in ---- */
int  jf_login_password(struct jf *j, const char *user, const char *pass);  /* the ini's fallback */
int  jf_qc_enabled(struct jf *j);                                            /* 1, 0, < 0 */
int  jf_qc_initiate(struct jf *j, char *secret, size_t slen, char *code, size_t clen);
int  jf_qc_poll(struct jf *j, const char *secret);                           /* 1 approved, 0 not yet, < 0 */
int  jf_qc_finish(struct jf *j, const char *secret);                         /* token + user id */
int  jf_check_token(struct jf *j);                                           /* 0 still valid */

/* ---- the cast target ---- */
int  jf_capabilities(struct jf *j, const char *profile_json);
int  jf_ws_open(struct jf *j);
/* a whole message, or NULL (nothing now); *closed set when the socket died (re-open it) */
cJSON *jf_ws_poll(struct jf *j, int *closed);
void jf_ws_keepalive(struct jf *j);   /* call every loop: sends one every 30 s */
void jf_ws_close(struct jf *j);

/* ---- playing ---- */
struct jf_item {
    char id[40], name[160], series[120];
    int season, episode;
    int64_t runtime_ticks;     /* 100 ns */
};
int  jf_item(struct jf *j, const char *id, struct jf_item *it);

struct jf_stream {
    char url[2048];            /* absolute: the direct-play file, or the transcode's playlist */
    char media_source_id[40], play_session_id[40];
    int transcode;             /* 0 DirectPlay, 1 Transcode */
    int audio_index;           /* the item's audio stream (Jellyfin's index), -1 none */
    int sub_index;             /* the subtitle stream shown, -1 none */
    char sub_url[1024];        /* an External text subtitle as SRT (absolute), "" when none / burned in */
    int sub_burned;
    /* the item's tracks, for the overlay and for cycling through them */
    int audio_list[16], n_audio, sub_list[32], n_sub;
    char audio_names[16][64], sub_names[32][64];    /* the lists' DisplayTitles */
    double video_dar;          /* the picture's display aspect (the server's AspectRatio, else width / height; 0 unknown) */
    unsigned colour;           /* (0.16, docs/colour.md R4) the colour code to send: 0 (auto) on direct play; on a
                                  transcode the SOURCE's matrix -- the server labels every transcode BT.709
                                  and converts nothing -- BT.709 / 601 / 2020 from its ColorSpace, else by its size */
    char audio_name[96], sub_name[96];
};
/* PlaybackInfo with the profile: start (100 ns ticks); audio_index the audio stream wanted (-1:
 * the server's default); sub_index the subtitle stream (-1: none, -2: the server's default);
 * force_transcode: the client's own check refused the file (no direct play, no stream copy) */
unsigned jf_source_colour(const char *colour_space, double width, double height);   /* (0.16) */
int  jf_playback_info(struct jf *j, const char *item, const char *profile_json, int64_t start_ticks,
                      int audio_index, int sub_index, int force_transcode, struct jf_stream *s);

enum jf_report { JF_REPORT_START, JF_REPORT_PROGRESS, JF_REPORT_STOPPED };
int  jf_report(struct jf *j, enum jf_report what, const char *item, const struct jf_stream *s,
               int64_t position_ticks, int paused, int volume);

/* GET a text body (the subtitle's SRT); malloc'd, NULL on failure */
char *jf_get_text(struct jf *j, const char *url, size_t *len);

#endif
