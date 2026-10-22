/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/feeder/h264play.c -- the reference feeder: plays an Annex-B H.264 file through the
 * core's HPS interface (the client library, hps/include/h264ring.h). The developer input
 * path (roadmap D3) and the example every integration starts from.
 *
 *   h264play [options] FILE.264
 *     --fps N         the access-unit rate for --pts and --realtime (default 59.94)
 *     --pts           stamp access unit i with i * 90000 / fps (only for streams without
 *                     reordering: a PTS is a PRESENTATION time). Default: no PTS -- the core
 *                     paces pictures by the stream's VUI timing
 *     --realtime      write access units at the fps rate (a live source), not as fast as
 *                     the ring takes them
 *     --ll            LOW_LATENCY on every access unit (present as soon as decoded)
 *     --graphics      GRAPHICS on every access unit (interface 0.4: the stream is rendered
 *                     graphics -- the core's Anti-Twitter Auto filters it at 480i)
 *     --osd LIST      change the core's menu settings when the session starts (interface
 *                     0.4, h264ring_request_settings), LIST = name=value[,name=value]:
 *                     aspect deinterlace video_output hdmi_deinterlace analog_aspect
 *                     refresh_rate anti_twitter, values their menu positions (0 = the first);
 *                     withdrawn at exit (the settings stay as set; a later session does not
 *                     re-apply them)
 *     --loop N        play the file N times (END_OF_STREAM, then a new stream each time)
 *     --switch F      after --at access units, switch to file F (DISCONTINUITY)
 *     --at N          (default: half the first file)
 *     --flush         switch by h264ring_flush() instead: drop what the core has not read
 *                     yet (a seek that does not wait for the queue). Either way the feeder
 *                     prints how long the core took to start the new stream
 *     --pcm FILE      (interface 0.5) play FILE with the video: raw PCM, 48 kHz 16-bit signed
 *                     little-endian stereo (ffmpeg -i IN -f s16le -ar 48000 -ac 2 OUT.pcm), as
 *                     AUDIO records stamped on the video's timeline: frame k at the first
 *                     access unit's PTS + --pcm-offset + k / 48000 s (the first access unit's
 *                     PTS is 0 without --pts: the core's clock then starts at 0 with it)
 *     --pcm-offset MS the audio's first frame relative to the first access unit (default 0)
 *     --pcm-chunk MS  the audio records' length (default 20)
 *     --pcm-lead MS   write the audio this far ahead of the video, by PTS (default 300): the
 *                     order a demuxer would interleave them in
 *     --audio-only    the PCM alone, no FILE.264: the core starts its clock from the audio
 *     --atten N       the audio's attenuation, 0.5 dB steps (0 full volume, 255 mute)
 *     --pause A,B     pause the core A seconds after the start for B ms (word 34, out of band)
 *     --overlay [FMT] (interface 0.9) a progress bar over the video: drawn into the Linux
 *                     framebuffer (/dev/fb0) and composited by the core on its own raster (HDMI
 *                     and analog), FMT 1555 (default), 4444 or 8888; two pages flipped, a
 *                     24-line band (the core reads those lines alone); hidden at exit
 *     --overlay-band A,B  declare lines A..B as the band instead (the bar still drawn in its
 *                     own lines): the core fetches them all -- 0,479 is a full canvas's load
 *     --overlay-size W,H  a W x H canvas (centred by the core) instead of 720 x 480, the whole
 *                     canvas the band, its line 0 an opaque white rule: at 480i with the
 *                     anti-twitter the raster line above the canvas shows a quarter of it;
 *                     up to OVL_MAX_W x OVL_MAX_H (0.12: 2,048 x 2,048) while two pages fit
 *                     /dev/fb0, whose size is Main's HDMI mode's (8888 1280 x 720: 3.5 MiB a
 *                     page, two only on a 1920x1080 mode)
 *     --rumble P,L,S  (interface 0.13) rumble pad P (0-5) with the large motor at L and the small
 *                     at S (0-255) for the whole playback, kept going past Main's 32.767 s
 *                     (h264ring_rumble_keepalive between access units); repeatable; stopped at
 *                     exit (h264ring_close). Main plays it on the user's pad with that player
 *                     number; h264stat shows what the core passes on (rum_p0..rum_p5)
 *     --no-cavlc      write a CAVLC stream as it is (h264ring_set_rewrite(r, 0): the core
 *                     refuses it, REF_CAVLC). By default the library's write call rewrites CAVLC
 *                     into CABAC (h264ring_cavlc.h, fj#20) -- a CABAC stream passes untouched --;
 *                     the feeder calls h264ring_prepare_au() for each unit BEFORE its --realtime
 *                     due time and prints the share of one core the rewrite took. A stream the
 *                     rewrite refuses (FMO, ASO, ...) stops the feeder
 *     --no-launch     do not load the core (it must already run)
 *     --rbf PATH      the MGL's <rbf> (default _Other/H264)
 *     --quiet
 *     --list          print each access unit's offset and length, and exit (no core: the
 *                     splitter's test, tools/tests/test_hps_lib.py, against ffprobe)
 *
 * Access units are split by the library (h264ring_split_annexb: H.264 7.4.1.2.3 as the core's
 * streams need it); each record carries exactly one, start codes included (the interface's
 * rule).
 */
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include "h264ring.h"
#include "h264ring_cavlc.h"

struct au { uint32_t off, len; };     /* the library's struct h264ring_au */

/* --pcm: the audio file and where it has been written up to */
static struct { uint8_t *buf; size_t n, pos; int64_t pts0; uint32_t chunk; } pcm;

/* write the PCM up to (not including) presentation time `until` (90 kHz); -1: to the end */
static int write_pcm(h264ring *r, int64_t until)
{
    while (pcm.buf && pcm.pos < pcm.n) {
        int64_t pts = pcm.pts0 + (int64_t)(pcm.pos / 4) * 90000 / 48000;   /* this record's first frame */
        uint32_t len = pcm.n - pcm.pos < pcm.chunk ? (uint32_t)(pcm.n - pcm.pos) : pcm.chunk;
        int rc;
        if (until >= 0 && pts >= until) break;
        len &= ~3u;
        if (len == 0) { pcm.pos = pcm.n; break; }
        if ((rc = h264ring_write_audio(r, pcm.buf + pcm.pos, len, pts < 0 ? 0 : pts, 5000)))
            return rc;
        pcm.pos += len;
    }
    return 0;
}
struct stream { uint8_t *buf; size_t n; struct au *aus; size_t n_aus; };

static int load(const char *path, struct stream *s)
{
    FILE *f = fopen(path, "rb");
    long n;
    if (!f) { perror(path); return -1; }
    fseek(f, 0, SEEK_END); n = ftell(f); fseek(f, 0, SEEK_SET);
    s->buf = (uint8_t *)malloc((size_t)n + 4);
    if (!s->buf || fread(s->buf, 1, (size_t)n, f) != (size_t)n) { fclose(f); fprintf(stderr, "%s: read failed\n", path); return -1; }
    fclose(f);
    s->n = (size_t)n;
    return 0;
}

static void split(struct stream *s)
{
    size_t n = h264ring_split_annexb(s->buf, s->n, NULL, 0);
    s->aus = (struct au *)malloc((n ? n : 1) * sizeof *s->aus);
    s->n_aus = h264ring_split_annexb(s->buf, s->n, (struct h264ring_au *)s->aus, n);
}

static uint64_t cpu_us(void)            /* this thread's CPU time: the rewrite's cost */
{
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

static uint64_t mono_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000u + (uint64_t)ts.tv_nsec / 1000u;
}

/* --overlay: a progress bar (interface 0.9). A 720 x 480 canvas -- one canvas pixel is one raster
 * pixel, centred -- of which only the bar's band is drawn and declared, in two pages of the
 * framebuffer: draw into the page not shown, show it, and wait for the core to have read the
 * new descriptor before the old page is drawn into again. */
/* the canvas (720 x 480, or --overlay-size) and the bar in it: 24 lines from 60 above its
 * bottom, a twelfth of its width in from each side */
#define OV_W  ov.w
#define OV_H  ov.h
#define OV_Y0 (ov.h - 60u)            /* the band: the bar's lines */
#define OV_Y1 (ov.h - 37u)
#define OV_X0 (ov.w / 12u)
#define OV_X1 (ov.w - ov.w / 12u - 1u)
static struct {
    int on, page, last_pct, band_a, band_b, sized;
    unsigned w, h;
    unsigned fmt, bpp;
    struct h264ring_fb fb;
    struct h264ring_overlay o;
    uint32_t page_bytes;
    uint64_t last_us;
} ov;

static uint32_t ov_px(unsigned r8, unsigned g8, unsigned b8, unsigned a8)   /* straight alpha */
{
    if (ov.fmt == H264RING_OVL_FMT_1555)
        return (a8 >= 128 ? 0x8000u : 0u) | ((r8 >> 3) << 10) | ((g8 >> 3) << 5) | (b8 >> 3);
    if (ov.fmt == H264RING_OVL_FMT_4444)
        return ((a8 >> 4) << 12) | ((r8 >> 4) << 8) | ((g8 >> 4) << 4) | (b8 >> 4);
    return (a8 << 24) | (r8 << 16) | (g8 << 8) | b8;           /* 8888: bytes B, G, R, A */
}

static int ov_open(const char *fmt)
{
    int rc;
    ov.fmt = !strcmp(fmt, "4444") ? H264RING_OVL_FMT_4444 : !strcmp(fmt, "8888") ? H264RING_OVL_FMT_8888 :
             H264RING_OVL_FMT_1555;
    ov.bpp = ov.fmt == H264RING_OVL_FMT_8888 ? 4u : 2u;
    if ((rc = h264ring_fb_map(&ov.fb)))
        return rc;
    ov.page_bytes = (((OV_W * ov.bpp + 7u) & ~7u) * OV_H + 4095u) & ~4095u;
    if (2u * ov.page_bytes > ov.fb.len) {          /* /dev/fb0 is Main's HDMI mode's size, not the region */
        fprintf(stderr, "h264play: --overlay: two %ux%u pages need %u bytes; /dev/fb0 holds %u (Main's HDMI "
                "mode: a larger video_mode makes it larger)\n", OV_W, OV_H, 2u * ov.page_bytes, (unsigned)ov.fb.len);
        h264ring_fb_unmap(&ov.fb);
        return -ENOSPC;
    }
    memset(ov.fb.virt, 0, 2u * ov.page_bytes);          /* transparent: both pages */
    if (ov.sized)                                       /* the canvas's line 0: an opaque white rule */
        for (unsigned pg = 0; pg < 2; pg++)
            for (unsigned x = 0; x < OV_W; x++) {
                uint8_t *line = (uint8_t *)ov.fb.virt + pg * ov.page_bytes;
                if (ov.bpp == 4) ((uint32_t *)line)[x] = ov_px(255, 255, 255, 255);
                else ((uint16_t *)line)[x] = (uint16_t)ov_px(255, 255, 255, 255);
            }
    ov.o.width = OV_W; ov.o.height = OV_H; ov.o.stride = (uint16_t)((OV_W * ov.bpp + 7u) & ~7u);   /* a multiple of 8 */
    ov.o.format = (uint8_t)ov.fmt;
    ov.o.band_first = (uint16_t)(ov.sized ? 0u : ov.band_b ? (unsigned)ov.band_a : OV_Y0);
    ov.o.band_last = (uint16_t)(ov.sized ? OV_H - 1u : ov.band_b ? (unsigned)ov.band_b : OV_Y1);
    ov.page = 1; ov.last_pct = -1; ov.on = 1;
    return 0;
}

static void ov_draw(h264ring *r, int pct, int quiet)
{
    int back = ov.page ^ 1, gen, rc;
    uint8_t *page = (uint8_t *)ov.fb.virt + (size_t)back * ov.page_bytes;
    unsigned fill = OV_X0 + 2u + (unsigned)pct * (OV_X1 - OV_X0 - 3u) / 100u;
    if (!ov.on || pct == ov.last_pct)
        return;
    for (unsigned y = OV_Y0; y <= OV_Y1; y++) {
        uint8_t *line = page + (size_t)y * ov.o.stride;
        for (unsigned x = 0; x < OV_W; x++) {
            uint32_t v = 0;                                          /* outside the bar: transparent */
            if (x >= OV_X0 && x <= OV_X1) {
                if (y < OV_Y0 + 2 || y > OV_Y1 - 2 || x < OV_X0 + 2 || x > OV_X1 - 2)
                    v = ov_px(240, 240, 240, 255);                   /* the frame */
                else if (x < fill)
                    v = ov_px(40, 160, 240, 255);                    /* done */
                else
                    v = ov_px(16, 16, 24, 160);                      /* to go: translucent (1555: opaque) */
            }
            if (ov.bpp == 4) ((uint32_t *)line)[x] = v;
            else ((uint16_t *)line)[x] = (uint16_t)v;
        }
    }
    ov.o.base = ov.fb.phys + (uint32_t)back * ov.page_bytes;
    gen = h264ring_overlay_show(r, &ov.o);
    rc = gen > 0 ? h264ring_overlay_wait(r, gen, 500) : gen;       /* the old page is free after this */
    if (rc) {
        if (!quiet) fprintf(stderr, "h264play: --overlay: %s (ovl_err in the status block)\n", strerror(-rc));
        ov.on = 0;
        return;
    }
    ov.page = back;
    ov.last_pct = pct;
}

/* --osd name=value[,...]: one settings request (interface 0.4) */
static int request_osd(h264ring *r, const char *list)
{
    static const char *const names[H264RING_OPT_COUNT] = {"aspect", "deinterlace", "video_output",
        "hdmi_deinterlace", "analog_aspect", "refresh_rate", "anti_twitter"};
    unsigned values[H264RING_OPT_COUNT] = {0}, mask = 0;
    char buf[256], *save = NULL;
    int seq;
    snprintf(buf, sizeof buf, "%s", list);
    for (char *t = strtok_r(buf, ",", &save); t; t = strtok_r(NULL, ",", &save)) {
        char *eq = strchr(t, '=');
        unsigned i;
        if (!eq) return -EINVAL;
        *eq = 0;
        for (i = 0; i < H264RING_OPT_COUNT && strcmp(t, names[i]); i++) ;
        if (i == H264RING_OPT_COUNT) return -EINVAL;
        values[i] = (unsigned)atoi(eq + 1);
        mask |= 1u << i;
    }
    seq = h264ring_request_settings(r, mask, values);
    if (seq > 0) fprintf(stderr, "h264play: settings request %d sent (%s)\n", seq, list);
    return seq < 0 ? seq : 0;
}

static void usage(void)
{
    fprintf(stderr, "usage: h264play [--fps N] [--pts] [--realtime] [--ll] [--graphics] [--loop N] "
                    "[--switch FILE [--at N] [--flush]] [--osd name=v,...] [--overlay [1555|4444|8888] [--overlay-band A,B] [--overlay-size W,H]] [--pcm FILE [--pcm-offset MS] "
                    "[--pcm-chunk MS] [--pcm-lead MS] [--audio-only]] [--atten N] [--pause A,B] [--rumble P,L,S] "
                    "[--colour N] [--no-cavlc] [--no-launch] [--rbf PATH] [--quiet] FILE.264\n");
    exit(2);
}

int main(int argc, char **argv)
{
    double fps = 60000.0 / 1001.0;
    int use_pts = 0, realtime = 0, ll = 0, gfx = 0, loops = 1, launch = 1, quiet = 0, list = 0, flush = 0, rc;
    int colour = 0;                       /* (0.16) --colour N: the stream's colour code (h264ring_set_colour) */
    uint64_t t_switch = 0;
    uint32_t streams0 = 0;
    long at = -1;
    const char *file = NULL, *sw = NULL, *rbf = NULL, *osd = NULL, *pcm_file = NULL, *ovl = NULL;
    double pcm_off_ms = 0, pcm_chunk_ms = 20, pcm_lead_ms = 300, pause_at = -1, pause_ms = 0;
    int audio_only = 0, atten = -1, paused = 0, cavlc = 1;
    unsigned rum[6][2] = {{0}}, n_rum = 0;          /* (0.13) --rumble P,L,S */
    uint64_t cv_us = 0, cv_max_us = 0;
    struct stream a, b;
    h264ring *r = NULL;
    struct h264ring_status st;
    uint64_t t0, n_written = 0;
    int64_t pts0 = 0;

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = atof(argv[++i]);
        else if (!strcmp(argv[i], "--pts")) use_pts = 1;
        else if (!strcmp(argv[i], "--realtime")) realtime = 1;
        else if (!strcmp(argv[i], "--ll")) ll = 1;
        else if (!strcmp(argv[i], "--graphics")) gfx = 1;
        else if (!strcmp(argv[i], "--colour") && i + 1 < argc) {
            colour = atoi(argv[++i]);
            if (colour < 0 || colour > 6) usage();
        }
        else if (!strcmp(argv[i], "--loop") && i + 1 < argc) loops = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--switch") && i + 1 < argc) sw = argv[++i];
        else if (!strcmp(argv[i], "--at") && i + 1 < argc) at = atol(argv[++i]);
        else if (!strcmp(argv[i], "--no-launch")) launch = 0;
        else if (!strcmp(argv[i], "--no-cavlc")) cavlc = 0;
        else if (!strcmp(argv[i], "--rbf") && i + 1 < argc) rbf = argv[++i];
        else if (!strcmp(argv[i], "--quiet")) quiet = 1;
        else if (!strcmp(argv[i], "--list")) list = 1;
        else if (!strcmp(argv[i], "--flush")) flush = 1;
        else if (!strcmp(argv[i], "--osd") && i + 1 < argc) osd = argv[++i];
        else if (!strcmp(argv[i], "--overlay-band") && i + 1 < argc) {
            if (sscanf(argv[++i], "%d,%d", &ov.band_a, &ov.band_b) != 2) usage();
        }
        else if (!strcmp(argv[i], "--overlay-size") && i + 1 < argc) {
            if (sscanf(argv[++i], "%u,%u", &ov.w, &ov.h) != 2 || ov.w < 48 || ov.w > H264RING_OVL_MAX_W || ov.h < 64 ||
                ov.h > H264RING_OVL_MAX_H)
                usage();
            ov.sized = 1;
        }
        else if (!strcmp(argv[i], "--overlay")) {
            ovl = "1555";
            if (i + 1 < argc && (!strcmp(argv[i + 1], "1555") || !strcmp(argv[i + 1], "4444") || !strcmp(argv[i + 1], "8888")))
                ovl = argv[++i];
        }
        else if (!strcmp(argv[i], "--pcm") && i + 1 < argc) pcm_file = argv[++i];
        else if (!strcmp(argv[i], "--pcm-offset") && i + 1 < argc) pcm_off_ms = atof(argv[++i]);
        else if (!strcmp(argv[i], "--pcm-chunk") && i + 1 < argc) pcm_chunk_ms = atof(argv[++i]);
        else if (!strcmp(argv[i], "--pcm-lead") && i + 1 < argc) pcm_lead_ms = atof(argv[++i]);
        else if (!strcmp(argv[i], "--audio-only")) audio_only = 1;
        else if (!strcmp(argv[i], "--atten") && i + 1 < argc) atten = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--rumble") && i + 1 < argc) {
            unsigned p_, l_, s_;
            if (sscanf(argv[++i], "%u,%u,%u", &p_, &l_, &s_) != 3 || p_ > 5 || l_ > 255 || s_ > 255) usage();
            rum[p_][0] = l_; rum[p_][1] = s_; n_rum++;
        }
        else if (!strcmp(argv[i], "--pause") && i + 1 < argc) { if (sscanf(argv[++i], "%lf,%lf", &pause_at, &pause_ms) != 2) usage(); }
        else if (argv[i][0] == '-') usage();
        else file = argv[i];
    }
    if ((!file && !audio_only) || fps <= 0 || loops < 1 || (audio_only && !pcm_file) || pcm_chunk_ms < 1 ||
        atten > 255) usage();
    if (pcm_file) {
        struct stream p;
        if (load(pcm_file, &p)) return 1;
        pcm.buf = p.buf; pcm.n = p.n & ~(size_t)3; pcm.pos = 0;
        pcm.pts0 = (int64_t)(pcm_off_ms * 90.0);
        pcm.chunk = (uint32_t)(pcm_chunk_ms * 48.0) * 4u;
    }
    if (audio_only) { a.buf = NULL; a.n = 0; a.aus = NULL; a.n_aus = 0; }
    else { if (load(file, &a)) return 1; split(&a); }
    if (sw) { if (load(sw, &b)) return 1; split(&b); }
    if (list) {
        for (size_t i = 0; i < a.n_aus; i++) printf("%u %u\n", a.aus[i].off, a.aus[i].len);
        return 0;
    }
    if (at < 0) at = (long)a.n_aus / 2;
    if (!quiet && file) fprintf(stderr, "h264play: %s: %zu access units\n", file, a.n_aus);
    if (!quiet && pcm.buf) fprintf(stderr, "h264play: %s: %.2f s of audio from %+.1f ms, %u-byte records\n",
                                   pcm_file, (double)pcm.n / 192000.0, pcm_off_ms, pcm.chunk);

    if (launch && (rc = h264ring_launch_core(rbf, 10000))) {
        fprintf(stderr, "h264play: loading the core: %s\n", strerror(-rc)); return 1;
    }
    for (int tries = 0; ; tries++) {             /* a freshly loaded core needs a moment */
        rc = h264ring_open_devmem(&r, 0);
        if (rc != -ENODEV || tries > 50) break;
        usleep(100000);
    }
    if (rc) { fprintf(stderr, "h264play: open: %s\n", strerror(-rc)); return 1; }
    if ((rc = h264ring_start_session(r, 3000))) {
        fprintf(stderr, "h264play: session: %s\n", strerror(-rc)); h264ring_close(r); return 1;
    }
    if (osd && (rc = request_osd(r, osd)) < 0) {
        fprintf(stderr, "h264play: --osd %s: %s\n", osd, strerror(-rc)); h264ring_close(r); return 1;
    }
    if (atten >= 0) h264ring_set_atten(r, (unsigned)atten);
    h264ring_set_colour(r, (unsigned)colour);     /* (0.16) 0 auto: the stream's own tags, else by size */
    for (unsigned p_ = 0; n_rum && p_ < 6; p_++)            /* (0.13) after the session: the core passes it on */
        h264ring_rumble(r, p_, rum[p_][0], rum[p_][1]);
    if (!ov.sized) { ov.w = 720; ov.h = 480; }
    if (ov.band_b && (ov.band_a < 0 || ov.band_a > ov.band_b || (unsigned)ov.band_b >= OV_H ||
                      (unsigned)ov.band_a > OV_Y0 || (unsigned)ov.band_b < OV_Y1)) usage();
    if (ovl) {
        if ((rc = ov_open(ovl))) fprintf(stderr, "h264play: --overlay: the framebuffer: %s\n", strerror(-rc));
        else ov_draw(r, 0, quiet);
    }

    h264ring_set_rewrite(r, cavlc);

    /* the playlist: A (or A's first --at access units, then all of B, the first with
     * DISCONTINUITY), the last with END_OF_STREAM; --loop repeats it (the library puts
     * DISCONTINUITY on the access unit after each END_OF_STREAM) */
    t0 = mono_us();
    for (int loop = 0; loop < loops; loop++) {
        size_t na = sw ? (size_t)at : a.n_aus, nb = sw ? b.n_aus : 0;
        if (na > a.n_aus) na = a.n_aus;
        for (size_t i = 0; i < na + nb; i++) {
            const struct stream *s = i < na ? &a : &b;
            const struct au *u = &s->aus[i < na ? i : i - na];
            unsigned flags = (ll ? H264RING_F_LOW_LATENCY : 0) | (gfx ? H264RING_F_GRAPHICS : 0);
            const uint8_t *au = s->buf + u->off;
            size_t au_len = u->len;
            if (sw && i == na) {                   /* the switch: in order, or dropping the queue */
                if (h264ring_status(r, &st) == 0) streams0 = (uint32_t)H264RING_ST(&st, N_STREAMS);
                t_switch = mono_us();
                if (flush) {
                    if ((rc = h264ring_flush(r, 1000))) {
                        fprintf(stderr, "h264play: flush: %s\n", strerror(-rc)); h264ring_close(r); return 1;
                    }
                    if (!quiet) fprintf(stderr, "h264play: flushed (the queue dropped) in %.1f ms\n",
                                        (double)(mono_us() - t_switch) / 1e3);
                } else flags |= H264RING_F_DISCONTINUITY;
            }
            if (t_switch && streams0 != ~0u && h264ring_status(r, &st) == 0 &&
                (uint32_t)H264RING_ST(&st, N_STREAMS) != streams0) {
                if (!quiet) fprintf(stderr, "h264play: the core started the new stream %.1f ms after the switch\n",
                                    (double)(mono_us() - t_switch) / 1e3);
                streams0 = ~0u;
            }
            if (i + 1 == na + nb) flags |= H264RING_F_END_OF_STREAM;
            /* the audio up to this access unit's time plus the lead (the first loop only) */
            if (pcm.buf && loop == 0) {
                int64_t upto = (int64_t)((double)n_written * 90000.0 / fps) + (int64_t)(pcm_lead_ms * 90.0);
                if ((rc = write_pcm(r, upto))) {
                    fprintf(stderr, "h264play: audio: %s\n", strerror(-rc)); h264ring_close(r); return 1;
                }
            }
            if (pause_at >= 0 && !paused && mono_us() - t0 >= (uint64_t)(pause_at * 1e6)) {
                h264ring_set_pause(r, 1); paused = 1;
                if (!quiet) fprintf(stderr, "h264play: paused\n");
            }
            if (paused == 1 && mono_us() - t0 >= (uint64_t)((pause_at + pause_ms / 1e3) * 1e6)) {
                h264ring_set_pause(r, 0); paused = 2;
                if (!quiet) fprintf(stderr, "h264play: resumed\n");
            }
            /* the rewrite BEFORE the unit's due time (h264ring_prepare_au; the write is then free):
             * rewritten inside a write made at the due time, a unit would reach the core late by
             * its own rewrite time (an IDR's is several frame periods) */
            if (cavlc) {
                uint64_t c0 = cpu_us(), dt;
                rc = h264ring_prepare_au(r, au, (uint32_t)au_len, flags);
                dt = cpu_us() - c0;
                cv_us += dt;
                if (dt > cv_max_us)
                    cv_max_us = dt;
                if (rc) {
                    fprintf(stderr, "h264play: access unit %zu: the CAVLC rewrite %s: %s\n", i,
                            rc == -EOPNOTSUPP ? "refused it" : "failed", h264ring_rewrite_why(r));
                    h264ring_close(r);
                    return 1;
                }
            }
            if (realtime) {
                uint64_t due = t0 + (uint64_t)((double)n_written * 1e6 / fps);
                uint64_t now = mono_us();
                if (due > now) usleep((useconds_t)(due - now));
            }
            if (n_rum)
                h264ring_rumble_keepalive(r);                   /* (0.13) cheap: steps a pad every 10 s */
            rc = h264ring_write_au(r, au, (uint32_t)au_len,
                                   use_pts ? pts0 + (int64_t)((double)n_written * 90000.0 / fps) : -1,
                                   flags, 5000);
            if (rc) {
                fprintf(stderr, "h264play: access unit %zu: %s%s%s\n", i, strerror(-rc),
                        rc == -EOPNOTSUPP || rc == -EBADMSG ? " -- " : "",
                        rc == -EOPNOTSUPP || rc == -EBADMSG ? h264ring_rewrite_why(r) : "");
                if (h264ring_status(r, &st) == 0) h264ring_dump(stderr, &st, 0);
                h264ring_close(r);
                return 1;
            }
            n_written++;
            if (ov.on && mono_us() - ov.last_us > 250000u) {        /* the bar, 4 times a second */
                ov.last_us = mono_us();
                ov_draw(r, (int)(n_written * 100u / ((uint64_t)(na + nb) * (uint64_t)loops)), quiet);
            }
        }
    }
    if (ov.on) ov_draw(r, 100, quiet);
    if (pcm.buf && (rc = write_pcm(r, -1))) {                   /* the audio's tail (and --audio-only) */
        fprintf(stderr, "h264play: audio: %s\n", strerror(-rc)); h264ring_close(r); return 1;
    }
    if (!quiet) fprintf(stderr, "h264play: %llu access units written in %.2f s; waiting for the end\n",
                        (unsigned long long)n_written, (double)(mono_us() - t0) / 1e6);
    if (cavlc) {
        struct h264ring_cavlc_stats cs;
        h264ring_rewrite_stats(r, &cs);
        if (!quiet && cs.units_rewritten)
            fprintf(stderr, "h264play: CAVLC rewritten: %llu of %llu access units, %llu bins, %.2f s of CPU = "
                            "%.1f %% of one core at %.2f access units/s; the longest unit %.1f ms\n",
                    (unsigned long long)cs.units_rewritten, (unsigned long long)cs.units,
                    (unsigned long long)cs.bins, cv_us / 1e6, 100.0 * cv_us / 1e6 / ((double)cs.units / fps),
                    fps, cv_max_us / 1e3);
    }
    /* wait for the display to take the last END (or an error); audio-only: the audio played */
    for (int i = 0; i < 600; i++) {
        if (pause_at >= 0 && !paused && mono_us() - t0 >= (uint64_t)(pause_at * 1e6)) {
            h264ring_set_pause(r, 1); paused = 1;
            if (!quiet) fprintf(stderr, "h264play: paused\n");
        }
        if (paused == 1 && mono_us() - t0 >= (uint64_t)((pause_at + pause_ms / 1e3) * 1e6)) {
            h264ring_set_pause(r, 0); paused = 2;
            if (!quiet) fprintf(stderr, "h264play: resumed\n");
        }
        if (h264ring_status(r, &st) == 0) {
            unsigned s = (unsigned)H264RING_ST(&st, STATE);
            if (audio_only && H264RING_ST(&st, AUD_STATE) == 0 && H264RING_ST(&st, AUD_Q_REC) == 0 && i > 2) break;
            if (t_switch && streams0 != ~0u && (uint32_t)H264RING_ST(&st, N_STREAMS) != streams0) {
                if (!quiet) fprintf(stderr, "h264play: the core started the new stream %.1f ms after the switch\n",
                                    (double)(mono_us() - t_switch) / 1e3);
                streams0 = ~0u;
            }
            if (s == H264RING_S_ENDED || s == H264RING_S_ERROR) break;
        }
        usleep(100000);
    }
    if (paused == 1) h264ring_set_pause(r, 0);    /* never leave the core paused */
    if (h264ring_status(r, &st) == 0)
        h264ring_dump(stdout, &st, 1);
    rc = audio_only ? ((unsigned)H264RING_ST(&st, STATE) == H264RING_S_ERROR)
                    : ((unsigned)H264RING_ST(&st, STATE) == H264RING_S_ENDED ? 0 : 1);
    if (osd)
        h264ring_clear_settings(r);    /* withdraw --osd: never re-applied over a later session */
    if (ovl) {
        if (ov.on) h264ring_overlay_hide(r);
        h264ring_fb_unmap(&ov.fb);
    }
    h264ring_close(r);
    return rc;
}
