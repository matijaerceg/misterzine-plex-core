/* jf -- the Jellyfin server (jf.h; docs/jellyfin.md S4). */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <curl/curl.h>
#include "core.h"
#include "jf.h"

#define CLIENT_NAME    "MiSTer H264"
#define CLIENT_VERSION "0.1.0"
#define KEEPALIVE_MS   30000     /* the server drops a silent socket at 60 s (ForceKeepAlive at 45) */

struct buf { char *p; size_t n, cap; };

static size_t on_body(char *d, size_t sz, size_t nm, void *u)
{
    struct buf *b = u;
    size_t n = sz * nm;
    if (b->n + n + 1 > b->cap) {
        size_t cap = (b->n + n + 1) * 2;
        char *p = realloc(b->p, cap);
        if (!p) return 0;
        b->p = p; b->cap = cap;
    }
    memcpy(b->p + b->n, d, n);
    b->n += n;
    b->p[b->n] = 0;
    return n;
}

static void put_esc(char *dst, size_t len, const char *s)
{
    char *e = curl_easy_escape(NULL, s, 0);
    snprintf(dst, len, "%s", e ? e : "");
    curl_free(e);
}

static struct curl_slist *headers(struct jf *j, int json)
{
    char dev[128], name[128], h[512];
    put_esc(dev, sizeof dev, j->device_id);
    put_esc(name, sizeof name, j->device_name);
    int n = snprintf(h, sizeof h, "Authorization: MediaBrowser Client=\"MiSTer%%20H264\", Device=\"%s\", "
                     "DeviceId=\"%s\", Version=\"%s\"", name, dev, CLIENT_VERSION);
    if (j->token[0] && n > 0 && (size_t)n < sizeof h)
        snprintf(h + n, sizeof h - (size_t)n, ", Token=\"%s\"", j->token);
    struct curl_slist *l = curl_slist_append(NULL, h);
    if (json) {
        l = curl_slist_append(l, "Content-Type: application/json");
        l = curl_slist_append(l, "Accept: application/json");
    }
    return l;
}

static void common(struct jf *j, CURL *c)
{
    curl_easy_setopt(c, CURLOPT_CAINFO, j->cafile);
    curl_easy_setopt(c, CURLOPT_CONNECTTIMEOUT, 10L);
    curl_easy_setopt(c, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(c, CURLOPT_USERAGENT, CLIENT_NAME "/" CLIENT_VERSION);
}

int jf_init(struct jf *j, const char *server, const char *cafile, const char *device_id, const char *device_name)
{
    memset(j, 0, sizeof *j);
    curl_global_init(CURL_GLOBAL_DEFAULT);
    snprintf(j->server, sizeof j->server, "%s", server);
    size_t n = strlen(j->server);
    while (n && j->server[n - 1] == '/') j->server[--n] = 0;
    snprintf(j->cafile, sizeof j->cafile, "%s", cafile);
    snprintf(j->device_id, sizeof j->device_id, "%s", device_id);
    snprintf(j->device_name, sizeof j->device_name, "%s", device_name);
    j->http = curl_easy_init();
    return j->http ? 0 : -ENOMEM;
}

int jf_clone(struct jf *dst, const struct jf *src)
{
    *dst = *src;
    dst->ws = NULL;
    dst->ws_buf = NULL;
    dst->ws_len = dst->ws_cap = 0;
    dst->http = curl_easy_init();
    return dst->http ? 0 : -ENOMEM;
}

void jf_free(struct jf *j)
{
    jf_ws_close(j);
    if (j->http) curl_easy_cleanup(j->http);
    j->http = NULL;
}

int jf_request(struct jf *j, const char *method, const char *path, const char *body, cJSON **out)
{
    CURL *c = j->http;
    struct buf b = {0};
    char url[2560];
    snprintf(url, sizeof url, "%s%s", strncmp(path, "http", 4) ? j->server : "", path);
    curl_easy_reset(c);
    common(j, c);
    struct curl_slist *h = headers(j, 1);
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, h);
    curl_easy_setopt(c, CURLOPT_CUSTOMREQUEST, method);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 20L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &b);
    if (body) curl_easy_setopt(c, CURLOPT_POSTFIELDS, body);
    else if (!strcmp(method, "POST")) curl_easy_setopt(c, CURLOPT_POSTFIELDS, "");
    CURLcode rc = curl_easy_perform(c);
    long status = 0;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(h);
    if (rc != CURLE_OK) {
        fprintf(stderr, "jellyfin: %s %s: %s\n", method, path[0] == '/' ? path : "(a URL)", curl_easy_strerror(rc));
        free(b.p);
        return -EIO;
    }
    if (j->verbose) fprintf(stderr, "jellyfin: %s %.80s -> %ld\n", method, path, status);
    if (out) *out = b.n ? cJSON_Parse(b.p) : NULL;
    free(b.p);
    return (int)status;
}

static const char *str(const cJSON *o, const char *k)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsString(v) ? v->valuestring : NULL;
}

static double num(const cJSON *o, const char *k, double dflt)
{
    const cJSON *v = cJSON_GetObjectItemCaseSensitive(o, k);
    return cJSON_IsNumber(v) ? v->valuedouble : dflt;
}

int jf_public_info(struct jf *j, char *name, size_t nlen, char *version, size_t vlen)
{
    cJSON *r = NULL;
    int st = jf_request(j, "GET", "/System/Info/Public", NULL, &r);
    if (st != 200 || !r) { cJSON_Delete(r); return st < 0 ? st : -EPROTO; }
    snprintf(name, nlen, "%s", str(r, "ServerName") ? str(r, "ServerName") : "Jellyfin");
    snprintf(version, vlen, "%s", str(r, "Version") ? str(r, "Version") : "?");
    cJSON_Delete(r);
    return 0;
}

static int take_auth(struct jf *j, cJSON *r)
{
    const char *tok = str(r, "AccessToken");
    const cJSON *user = cJSON_GetObjectItemCaseSensitive(r, "User");
    const char *uid = user ? str(user, "Id") : NULL;
    if (!tok || !uid) return -EPROTO;
    snprintf(j->token, sizeof j->token, "%s", tok);
    snprintf(j->user_id, sizeof j->user_id, "%s", uid);
    return 0;
}

int jf_login_password(struct jf *j, const char *user, const char *pass)
{
    cJSON *b = cJSON_CreateObject(), *r = NULL;
    cJSON_AddStringToObject(b, "Username", user);
    cJSON_AddStringToObject(b, "Pw", pass);
    char *body = cJSON_PrintUnformatted(b);
    j->token[0] = 0;
    int st = jf_request(j, "POST", "/Users/AuthenticateByName", body, &r);
    int rc = st == 200 && r ? take_auth(j, r) : (st < 0 ? st : -EACCES);
    free(body); cJSON_Delete(b); cJSON_Delete(r);
    return rc;
}

int jf_qc_enabled(struct jf *j)
{
    cJSON *r = NULL;
    int st = jf_request(j, "GET", "/QuickConnect/Enabled", NULL, &r);
    int on = st == 200 && cJSON_IsTrue(r);
    cJSON_Delete(r);
    return st < 0 ? st : on;
}

int jf_qc_initiate(struct jf *j, char *secret, size_t slen, char *code, size_t clen)
{
    cJSON *r = NULL;
    j->token[0] = 0;
    int st = jf_request(j, "POST", "/QuickConnect/Initiate", NULL, &r);   /* POST: the GET is gone in 12.0 */
    int rc = -EPROTO;
    if (st == 200 && r && str(r, "Secret") && str(r, "Code")) {
        snprintf(secret, slen, "%s", str(r, "Secret"));
        snprintf(code, clen, "%s", str(r, "Code"));
        rc = 0;
    } else if (st < 0) rc = st;
    cJSON_Delete(r);
    return rc;
}

int jf_qc_poll(struct jf *j, const char *secret)
{
    char path[256];
    cJSON *r = NULL;
    snprintf(path, sizeof path, "/QuickConnect/Connect?secret=%s", secret);
    int st = jf_request(j, "GET", path, NULL, &r);
    int rc = st == 200 && r ? cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(r, "Authenticated")) : (st < 0 ? st : -ENOENT);
    cJSON_Delete(r);
    return rc;
}

int jf_qc_finish(struct jf *j, const char *secret)
{
    cJSON *b = cJSON_CreateObject(), *r = NULL;
    cJSON_AddStringToObject(b, "Secret", secret);
    char *body = cJSON_PrintUnformatted(b);
    int st = jf_request(j, "POST", "/Users/AuthenticateWithQuickConnect", body, &r);
    int rc = st == 200 && r ? take_auth(j, r) : (st < 0 ? st : -EACCES);
    free(body); cJSON_Delete(b); cJSON_Delete(r);
    return rc;
}

int jf_check_token(struct jf *j)
{
    if (!j->token[0]) return -EACCES;
    int st = jf_request(j, "GET", "/Users/Me", NULL, NULL);
    return st == 200 ? 0 : st == 401 || st == 403 ? -EACCES : (st < 0 ? st : -EPROTO);
}

int jf_capabilities(struct jf *j, const char *profile_json)
{
    cJSON *b = cJSON_CreateObject();
    cJSON *types = cJSON_AddArrayToObject(b, "PlayableMediaTypes");
    cJSON_AddItemToArray(types, cJSON_CreateString("Video"));
    static const char *const cmds[] = {
        "Play", "Playstate", "PlayNext", "PlayMediaSource", "SetVolume", "VolumeUp", "VolumeDown",
        "Mute", "Unmute", "ToggleMute", "SetAudioStreamIndex", "SetSubtitleStreamIndex", "DisplayMessage",
    };
    cJSON *sc = cJSON_AddArrayToObject(b, "SupportedCommands");
    for (unsigned i = 0; i < sizeof cmds / sizeof cmds[0]; i++) cJSON_AddItemToArray(sc, cJSON_CreateString(cmds[i]));
    cJSON_AddBoolToObject(b, "SupportsMediaControl", 1);
    cJSON_AddBoolToObject(b, "SupportsPersistentIdentifier", 1);
    cJSON *prof = cJSON_Parse(profile_json);
    if (prof) cJSON_AddItemToObject(b, "DeviceProfile", prof);
    char *body = cJSON_PrintUnformatted(b);
    int st = jf_request(j, "POST", "/Sessions/Capabilities/Full", body, NULL);
    free(body); cJSON_Delete(b);
    return st == 204 || st == 200 ? 0 : (st < 0 ? st : -EPROTO);
}

/* ---- the WebSocket ---- */

int jf_ws_open(struct jf *j)
{
    char url[600];
    jf_ws_close(j);
    const char *host = j->server + (strncmp(j->server, "https://", 8) == 0 ? 8 : strncmp(j->server, "http://", 7) == 0 ? 7 : 0);
    snprintf(url, sizeof url, "%s://%s/socket?ApiKey=%s&deviceId=%s",
             strncmp(j->server, "https://", 8) == 0 ? "wss" : "ws", host, j->token, j->device_id);
    CURL *c = curl_easy_init();
    if (!c) return -ENOMEM;
    common(j, c);
    struct curl_slist *h = headers(j, 0);
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, h);
    curl_easy_setopt(c, CURLOPT_CONNECT_ONLY, 2L);       /* the WebSocket upgrade, then ours */
    if (getenv("JELLYFIN_CURLV")) curl_easy_setopt(c, CURLOPT_VERBOSE, 1L);
    CURLcode rc = curl_easy_perform(c);
    curl_slist_free_all(h);
    if (rc != CURLE_OK) {
        fprintf(stderr, "jellyfin: the server's socket: %s\n", curl_easy_strerror(rc));
        curl_easy_cleanup(c);
        return -EIO;
    }
    j->ws = c;
    j->ws_len = 0;
    j->ws_tx_ms = now_ms();
    return 0;
}

void jf_ws_close(struct jf *j)
{
    if (j->ws) curl_easy_cleanup(j->ws);
    j->ws = NULL;
    free(j->ws_buf);
    j->ws_buf = NULL;
    j->ws_len = j->ws_cap = 0;
}

static int ws_send(struct jf *j, const char *text)
{
    size_t sent = 0;
    if (!j->ws) return -ENOTCONN;
    CURLcode rc = curl_ws_send(j->ws, text, strlen(text), &sent, 0, CURLWS_TEXT);
    j->ws_tx_ms = now_ms();
    return rc == CURLE_OK ? 0 : -EIO;
}

void jf_ws_keepalive(struct jf *j)
{
    if (j->ws && now_ms() - j->ws_tx_ms >= KEEPALIVE_MS) ws_send(j, "{\"MessageType\":\"KeepAlive\"}");
}

cJSON *jf_ws_poll(struct jf *j, int *closed)
{
    *closed = 0;
    if (!j->ws) { *closed = 1; return NULL; }
    for (;;) {
        char chunk[4096];
        size_t got = 0;
        const struct curl_ws_frame *meta = NULL;
        CURLcode rc = curl_ws_recv(j->ws, chunk, sizeof chunk, &got, &meta);
        if (rc == CURLE_AGAIN) return NULL;
        if (rc != CURLE_OK) { *closed = 1; jf_ws_close(j); return NULL; }
        if (meta && (meta->flags & CURLWS_CLOSE)) { *closed = 1; jf_ws_close(j); return NULL; }
        if (!meta || !(meta->flags & (CURLWS_TEXT | CURLWS_CONT | CURLWS_BINARY))) continue;   /* ping / pong */
        if (j->ws_len + got + 1 > j->ws_cap) {
            size_t cap = (j->ws_len + got + 1) * 2;
            char *p = realloc(j->ws_buf, cap);
            if (!p) { j->ws_len = 0; continue; }
            j->ws_buf = p; j->ws_cap = cap;
        }
        memcpy(j->ws_buf + j->ws_len, chunk, got);
        j->ws_len += got;
        j->ws_buf[j->ws_len] = 0;
        if (meta->bytesleft == 0 && !(meta->flags & CURLWS_CONT)) {   /* a whole message */
            cJSON *m = cJSON_Parse(j->ws_buf);
            j->ws_len = 0;
            if (m) return m;
        }
    }
}

/* ---- items, playback ---- */

int jf_item(struct jf *j, const char *id, struct jf_item *it)
{
    char path[256];
    cJSON *r = NULL;
    memset(it, 0, sizeof *it);
    snprintf(it->id, sizeof it->id, "%s", id);
    snprintf(path, sizeof path, "/Items/%s?userId=%s", id, j->user_id);
    int st = jf_request(j, "GET", path, NULL, &r);
    if (st != 200 || !r) {                              /* before 10.9: the per-user route */
        cJSON_Delete(r); r = NULL;
        snprintf(path, sizeof path, "/Users/%s/Items/%s", j->user_id, id);
        st = jf_request(j, "GET", path, NULL, &r);
    }
    if (st != 200 || !r) { cJSON_Delete(r); return st < 0 ? st : -ENOENT; }
    snprintf(it->name, sizeof it->name, "%s", str(r, "Name") ? str(r, "Name") : "");
    snprintf(it->series, sizeof it->series, "%s", str(r, "SeriesName") ? str(r, "SeriesName") : "");
    it->season = (int)num(r, "ParentIndexNumber", -1);
    it->episode = (int)num(r, "IndexNumber", -1);
    it->runtime_ticks = (int64_t)num(r, "RunTimeTicks", 0);
    cJSON_Delete(r);
    return 0;
}

/* an External subtitle's DeliveryUrl, .../Subtitles/{index}/{startTicks}/Stream.srt, carries the
 * StartTimeTicks the PlaybackInfo was asked with, and the server drops the cues before it and SHIFTS
 * the rest by it (SubtitleController -> SubtitleEncoder.FilterEvents, copyTimestamps false). The
 * client looks cues up at the item's time, so a track asked for at 297.9 s (a switch after a seek,
 * or a cast resumed mid-film) came back rebased to 0 and showed nothing (the maintainer's round,
 * 2026-10-01: English on, no subtitles). The start is set to 0: the whole track, its own times. */
static void whole_track(char *url)
{
    char *s = strstr(url, "/Subtitles/");
    char *ticks = s ? strchr(s + 11, '/') : NULL;     /* after the index */
    char *end = ticks ? strchr(ticks + 1, '/') : NULL;
    if (!end || end == ticks + 1) return;
    for (char *p = ticks + 1; p < end; p++) if (*p < '0' || *p > '9') return;
    ticks[1] = '0';
    memmove(ticks + 2, end, strlen(end) + 1);
}

/* (0.16, docs/colour.md R4) a transcode's colour code from its SOURCE's ColorSpace (ffmpeg's names, as
 * Jellyfin reports them), else the core's own size rule on the source's size (>= 1,280 wide or > 576
 * high: BT.709): limited range, as the transcode is */
unsigned jf_source_colour(const char *cs, double w, double h)
{
    if (cs && (!strcmp(cs, "bt709") || !strcmp(cs, "smpte240m"))) return H264RING_COLOUR_709;
    if (cs && (!strcmp(cs, "smpte170m") || !strcmp(cs, "bt470bg") || !strcmp(cs, "fcc"))) return H264RING_COLOUR_601;
    if (cs && !strcmp(cs, "bt2020nc")) return H264RING_COLOUR_2020;
    return (w >= 1280 || h > 576) ? H264RING_COLOUR_709 : H264RING_COLOUR_601;
}

int jf_playback_info(struct jf *j, const char *item, const char *profile_json, int64_t start_ticks,
                     int audio_index, int sub_index, int force_transcode, struct jf_stream *s)
{
    char path[256];
    memset(s, 0, sizeof *s);
    s->audio_index = s->sub_index = -1;
    cJSON *b = cJSON_CreateObject(), *r = NULL;
    cJSON_AddStringToObject(b, "UserId", j->user_id);
    cJSON *prof = cJSON_Parse(profile_json);
    if (prof) cJSON_AddItemToObject(b, "DeviceProfile", prof);
    cJSON_AddNumberToObject(b, "MaxStreamingBitrate", 10000000);
    cJSON_AddNumberToObject(b, "StartTimeTicks", (double)start_ticks);
    if (audio_index >= 0) cJSON_AddNumberToObject(b, "AudioStreamIndex", audio_index);
    if (sub_index >= -1) cJSON_AddNumberToObject(b, "SubtitleStreamIndex", sub_index);
    cJSON_AddBoolToObject(b, "EnableDirectPlay", !force_transcode);
    cJSON_AddBoolToObject(b, "EnableDirectStream", !force_transcode);
    cJSON_AddBoolToObject(b, "EnableTranscoding", 1);
    cJSON_AddBoolToObject(b, "AllowVideoStreamCopy", !force_transcode);
    cJSON_AddBoolToObject(b, "AllowAudioStreamCopy", 1);
    cJSON_AddBoolToObject(b, "AutoOpenLiveStream", 1);
    char *body = cJSON_PrintUnformatted(b);
    snprintf(path, sizeof path, "/Items/%s/PlaybackInfo", item);
    int st = jf_request(j, "POST", path, body, &r);
    free(body); cJSON_Delete(b);
    if (st != 200 || !r) { cJSON_Delete(r); return st < 0 ? st : -EPROTO; }
    int rc = -ENOENT;
    const cJSON *ms = cJSON_GetArrayItem(cJSON_GetObjectItemCaseSensitive(r, "MediaSources"), 0);
    snprintf(s->play_session_id, sizeof s->play_session_id, "%s", str(r, "PlaySessionId") ? str(r, "PlaySessionId") : "");
    if (ms) {
        const char *msid = str(ms, "Id") ? str(ms, "Id") : item;
        snprintf(s->media_source_id, sizeof s->media_source_id, "%s", msid);
        if (!force_transcode && cJSON_IsTrue(cJSON_GetObjectItemCaseSensitive(ms, "SupportsDirectPlay"))) {
            snprintf(s->url, sizeof s->url, "%s/Videos/%s/stream?static=true&mediaSourceId=%s&ApiKey=%s",
                     j->server, item, msid, j->token);
            rc = 0;
        } else if (str(ms, "TranscodingUrl")) {
            snprintf(s->url, sizeof s->url, "%s%s", j->server, str(ms, "TranscodingUrl"));
            s->transcode = 1;
            rc = 0;
        }
        s->audio_index = audio_index >= 0 ? audio_index : (int)num(ms, "DefaultAudioStreamIndex", -1);
        s->sub_index = sub_index >= -1 ? sub_index : (int)num(ms, "DefaultSubtitleStreamIndex", -1);
        const cJSON *st2;
        cJSON_ArrayForEach(st2, cJSON_GetObjectItemCaseSensitive(ms, "MediaStreams")) {
            const char *type = str(st2, "Type"), *title = str(st2, "DisplayTitle");
            int idx = (int)num(st2, "Index", -100);
            if (!type) continue;
            if (!strcmp(type, "Video") && s->video_dar == 0) {
                double aw = 0, ah = 0, w = num(st2, "Width", 0), h = num(st2, "Height", 0);
                if (s->transcode)               /* (0.16) the transcode keeps the source's pixels' matrix */
                    s->colour = jf_source_colour(str(st2, "ColorSpace"), w, h);
                const char *ar = str(st2, "AspectRatio");          /* "16:9", "2.40:1" */
                if (ar && sscanf(ar, "%lf:%lf", &aw, &ah) == 2 && aw > 0 && ah > 0) s->video_dar = aw / ah;
                else if (w > 0 && h > 0) s->video_dar = w / h;
            }
            if (!strcmp(type, "Audio")) {
                if (s->n_audio < 16) {
                    snprintf(s->audio_names[s->n_audio], sizeof s->audio_names[0], "%s", title ? title : "");
                    s->audio_list[s->n_audio++] = idx;
                }
                if (idx == s->audio_index) snprintf(s->audio_name, sizeof s->audio_name, "%s", title ? title : "");
            }
            if (strcmp(type, "Subtitle")) continue;
            if (s->n_sub < 32) {
                snprintf(s->sub_names[s->n_sub], sizeof s->sub_names[0], "%s", title ? title : "");
                s->sub_list[s->n_sub++] = idx;
            }
            if (idx != s->sub_index) continue;
            snprintf(s->sub_name, sizeof s->sub_name, "%s", title ? title : "");
            const char *how = str(st2, "DeliveryMethod"), *du = str(st2, "DeliveryUrl");
            if (how && !strcmp(how, "External") && du) {
                snprintf(s->sub_url, sizeof s->sub_url, "%s%s", strncmp(du, "http", 4) ? j->server : "", du);
                whole_track(s->sub_url);
            }
            else if (how && !strcmp(how, "Encode"))
                s->sub_burned = 1;
        }
    }
    cJSON_Delete(r);
    return rc;
}

int jf_report(struct jf *j, enum jf_report what, const char *item, const struct jf_stream *s,
              int64_t position_ticks, int paused, int volume)
{
    static const char *const path[] = {"/Sessions/Playing", "/Sessions/Playing/Progress", "/Sessions/Playing/Stopped"};
    cJSON *b = cJSON_CreateObject();
    cJSON_AddStringToObject(b, "ItemId", item);
    cJSON_AddStringToObject(b, "MediaSourceId", s->media_source_id);
    cJSON_AddStringToObject(b, "PlaySessionId", s->play_session_id);
    cJSON_AddNumberToObject(b, "PositionTicks", (double)position_ticks);
    cJSON_AddBoolToObject(b, "IsPaused", paused);
    cJSON_AddBoolToObject(b, "IsMuted", volume == 0);
    cJSON_AddNumberToObject(b, "VolumeLevel", volume);
    cJSON_AddBoolToObject(b, "CanSeek", 1);
    cJSON_AddStringToObject(b, "PlayMethod", s->transcode ? "Transcode" : "DirectPlay");
    if (s->audio_index >= 0) cJSON_AddNumberToObject(b, "AudioStreamIndex", s->audio_index);
    cJSON_AddNumberToObject(b, "SubtitleStreamIndex", s->sub_index);
    char *body = cJSON_PrintUnformatted(b);
    int st = jf_request(j, "POST", path[what], body, NULL);
    free(body); cJSON_Delete(b);
    return st == 204 || st == 200 ? 0 : (st < 0 ? st : -EPROTO);
}

char *jf_get_text(struct jf *j, const char *url, size_t *len)
{
    CURL *c = j->http;
    struct buf b = {0};
    curl_easy_reset(c);
    common(j, c);
    struct curl_slist *h = headers(j, 0);
    curl_easy_setopt(c, CURLOPT_URL, url);
    curl_easy_setopt(c, CURLOPT_HTTPHEADER, h);
    curl_easy_setopt(c, CURLOPT_TIMEOUT, 30L);
    curl_easy_setopt(c, CURLOPT_WRITEFUNCTION, on_body);
    curl_easy_setopt(c, CURLOPT_WRITEDATA, &b);
    CURLcode rc = curl_easy_perform(c);
    long status = 0;
    curl_easy_getinfo(c, CURLINFO_RESPONSE_CODE, &status);
    curl_slist_free_all(h);
    if (rc != CURLE_OK || status != 200) { free(b.p); return NULL; }
    if (len) *len = b.n;
    return b.p;
}
