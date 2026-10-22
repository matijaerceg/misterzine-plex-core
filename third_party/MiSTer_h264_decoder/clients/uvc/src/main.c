/* h264cam -- a USB camera or HDMI capture dongle shown through the H264 core (docs/uvc.md).
 *   h264cam [--dir DIR]          the viewer (cam.c, U6): what the Scripts menu's h264cam.sh runs
 *   h264cam --list | --stage ... the measuring tool below (step 1, U2)
 * Step 1 (U2): the measuring tool. Each stage adds one cost to the one before, so a run per stage
 * separates them:
 *   idle      nothing: the baseline (Main, the kernel, the USB host's own interrupts)
 *   capture   frames read from the device and assembled, then discarded (usbfs, libusb, DWC2)
 *   decode    ... and decoded on the ARM (MJPEG by libavcodec; YUY2 repacked to planar 4:2:2)
 *   show      ... and copied into the core's stores and shown (interface 0.15's PICTURE record)
 * The CPU a process's rusage reports is not the whole cost: this kernel does not account interrupt
 * time (/proc/stat's irq column stays 0) and DWC2's interrupt lands on CPU0. So --spin runs one
 * SCHED_IDLE spinner pinned to each core, which counts what is left over: a run's rate against the
 * idle stage's is the share of each core everything else took, interrupts included. */
#include <errno.h>
#include <getopt.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>
#include <libavcodec/avcodec.h>
#include <libavutil/log.h>
#include <libavutil/pixdesc.h>
#include "core.h"
#include "uvc.h"

static volatile sig_atomic_t quit;
static void on_sig(int s) { (void)s; quit = 1; }

static double mono(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

static double thread_cpu(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* ---- the instruments ---- */

#define NCPU 2
struct spinner { int cpu; volatile int stop; volatile uint64_t n; pthread_t t; };

static void *spin(void *arg)
{
    struct spinner *s = arg;
    cpu_set_t set;
    struct sched_param sp = { 0 };
    CPU_ZERO(&set);
    CPU_SET(s->cpu, &set);
    pthread_setaffinity_np(pthread_self(), sizeof set, &set);
    pthread_setschedparam(pthread_self(), SCHED_IDLE, &sp);
    while (!s->stop) {
        for (volatile int i = 0; i < 1000; i++) {}
        s->n++;
    }
    return NULL;
}

/* the DWC2 host's interrupts, all CPUs (/proc/interrupts' "dwc2" line) */
static uint64_t dwc2_irqs(void)
{
    FILE *f = fopen("/proc/interrupts", "r");
    char line[512];
    uint64_t n = 0;
    if (!f) return 0;
    while (fgets(line, sizeof line, f)) {
        if (!strstr(line, "dwc2")) continue;
        char *p = strchr(line, ':');
        for (int c = 0; p && c < NCPU; c++) {
            char *e;
            unsigned long long v = strtoull(p + 1, &e, 10);
            if (e == p + 1) break;
            n += v;
            p = e - 1;
        }
    }
    fclose(f);
    return n;
}

/* /proc/stat's first line: busy and total jiffies, both cores (interrupt time not accounted) */
static void cpu_jiffies(uint64_t *busy, uint64_t *total)
{
    unsigned long long v[10] = { 0 };
    FILE *f = fopen("/proc/stat", "r");
    *busy = *total = 0;
    if (!f) return;
    if (fscanf(f, "cpu %llu %llu %llu %llu %llu %llu %llu %llu", &v[0], &v[1], &v[2], &v[3], &v[4], &v[5],
               &v[6], &v[7]) == 8) {
        *total = v[0] + v[1] + v[2] + v[3] + v[4] + v[5] + v[6] + v[7];
        *busy = *total - v[3] - v[4];
    }
    fclose(f);
}

/* ---- decode ---- */

enum stage { ST_IDLE, ST_CAPTURE, ST_DECODE, ST_SHOW };

struct pic {                        /* a decoded picture's planes, as h264ring_picture_copy takes them */
    const uint8_t *planes[3];
    int strides[3];
    unsigned fmt;
};

/* YUY2 (Y0 U Y1 V) to planar 4:2:2, limited range (UVC's uncompressed video is BT.601 limited) */
static void yuy2_planar(const uint8_t *s, unsigned w, unsigned h, uint8_t *y, uint8_t *u, uint8_t *v)
{
    for (unsigned r = 0; r < h; r++)
        for (unsigned x = 0; x < w; x += 2, s += 4) {
            *y++ = s[0]; *u++ = s[1]; *y++ = s[2]; *v++ = s[3];
        }
}

static int av_fmt(const AVFrame *f, unsigned *fmt)
{
    int full = f->color_range == AVCOL_RANGE_JPEG;
    switch (f->format) {
    case AV_PIX_FMT_YUVJ420P: *fmt = H264RING_PIX_YUVJ420P; return 0;
    case AV_PIX_FMT_YUVJ422P: *fmt = H264RING_PIX_YUVJ422P; return 0;
    case AV_PIX_FMT_YUV420P: *fmt = full ? H264RING_PIX_YUVJ420P : H264RING_PIX_YUV420P; return 0;
    case AV_PIX_FMT_YUV422P: *fmt = full ? H264RING_PIX_YUVJ422P : H264RING_PIX_YUV422P; return 0;
    default: return -1;
    }
}

static void usage(void)
{
    fprintf(stderr,
        "usage: h264cam [--list] [--dev VID:PID] [--format mjpeg|yuyv] [--size WxH] [--fps N]\n"
        "               [--stage idle|capture|decode|show] [--seconds N] [--spin] [--spin-base A,B]\n"
        "               [--save FILE --save-frames N] [--alt N]\n"
        "  --list         the devices' formats, sizes and rates\n"
        "  --stage        what each frame costs, one stage at a time (default show; docs/uvc.md U2)\n"
        "  --spin         a SCHED_IDLE spinner on each core: what is left of each\n"
        "  --spin-base    the idle stage's spinner rates, to print each core's share taken\n"
        "  --alt          stream on this alternate setting, whatever the payload (U2b's sweep)\n"
        "  --save         write the first N complete frames (each: u32 length, the bytes) for a replay\n");
}

int cam_main(int argc, char **argv);

static int measure_main(int argc, char **argv)
{
    int list = 0, vid = -1, pid = -1, do_spin = 0, save_n = 0, force_alt = 0;
    unsigned want_w = 640, want_h = 480;
    double fps = 30, seconds = 0, base[NCPU] = { 0 };
    uint32_t fourcc = UVC_MJPG;
    enum stage stage = ST_SHOW;
    const char *save = NULL;
    static const struct option lo[] = {
        { "list", no_argument, 0, 'l' }, { "dev", required_argument, 0, 'd' },
        { "format", required_argument, 0, 'f' }, { "size", required_argument, 0, 's' },
        { "fps", required_argument, 0, 'r' }, { "stage", required_argument, 0, 'S' },
        { "seconds", required_argument, 0, 't' }, { "spin", no_argument, 0, 'p' },
        { "spin-base", required_argument, 0, 'b' }, { "save", required_argument, 0, 'w' },
        { "save-frames", required_argument, 0, 'n' }, { "alt", required_argument, 0, 'a' }, { "help", no_argument, 0, 'h' }, { 0, 0, 0, 0 } };
    for (int c; (c = getopt_long(argc, argv, "", lo, NULL)) != -1;) {
        switch (c) {
        case 'l': list = 1; break;
        case 'd': if (sscanf(optarg, "%x:%x", &vid, &pid) != 2) { usage(); return 2; } break;
        case 'f':
            if (!strcmp(optarg, "mjpeg")) fourcc = UVC_MJPG;
            else if (!strcmp(optarg, "yuyv")) fourcc = UVC_YUY2;
            else { usage(); return 2; }
            break;
        case 's': if (sscanf(optarg, "%ux%u", &want_w, &want_h) != 2) { usage(); return 2; } break;
        case 'r': fps = atof(optarg); break;
        case 'S':
            if (!strcmp(optarg, "idle")) stage = ST_IDLE;
            else if (!strcmp(optarg, "capture")) stage = ST_CAPTURE;
            else if (!strcmp(optarg, "decode")) stage = ST_DECODE;
            else if (!strcmp(optarg, "show")) stage = ST_SHOW;
            else { usage(); return 2; }
            break;
        case 't': seconds = atof(optarg); break;
        case 'p': do_spin = 1; break;
        case 'b': if (sscanf(optarg, "%lf,%lf", &base[0], &base[1]) != 2) { usage(); return 2; } do_spin = 1; break;
        case 'w': save = optarg; break;
        case 'n': save_n = atoi(optarg); break;
        case 'a': force_alt = atoi(optarg); break;
        default: usage(); return 2;
        }
    }
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    struct uvc_dev *d = NULL;
    const struct uvc_mode *m = NULL;
    uint32_t interval = 0;
    char info[256] = "";
    int rc;
    if (stage != ST_IDLE || list) {
        if ((rc = uvc_open(&d, vid, pid))) {
            fprintf(stderr, "h264cam: no USB video device%s (%s)\n", rc == -EACCES ? " we may open" : "", strerror(-rc));
            return 1;
        }
        unsigned n;
        const struct uvc_mode *ms = uvc_modes(d, &n);
        if (list) {
            printf("%s\n", uvc_name(d));
            for (unsigned i = 0; i < n; i++) {
                const struct uvc_mode *x = &ms[i];
                printf("  if %u fmt %u frame %u  %.4s %4ux%-4u  max %7u B  rates", x->vs_if, x->fmt_idx, x->frame_idx,
                       (const char *)&x->fourcc, x->width, x->height, x->max_frame);
                for (unsigned j = 0; j < x->n_int; j++) printf(" %.2f", 1e7 / x->intervals[j]);
                if (!x->n_int) printf(" %.2f-%.2f", 1e7 / x->int_max, 1e7 / x->int_min);
                printf("\n");
            }
            uvc_close(d);
            return 0;
        }
        if (!(m = uvc_pick(d, fourcc, want_w, want_h))) {
            fprintf(stderr, "h264cam: %s offers no %s\n", uvc_name(d), fourcc == UVC_MJPG ? "MJPEG" : "YUY2");
            uvc_close(d);
            return 1;
        }
        interval = uvc_pick_interval(m, fps > 0 ? (uint32_t)(1e7 / fps + 0.5) : 0);
    }

    /* the core first: loading it takes seconds, and the stream should start with the clock */
    struct core core;
    int have_core = 0;
    if (stage == ST_SHOW) {
        if ((rc = core_open2(&core, NULL, H264RING_OPEN_PICTURES))) { uvc_close(d); return 1; }
        have_core = 1;
    }

    const AVCodec *codec = NULL;
    AVCodecContext *av = NULL;
    AVFrame *fr = av_frame_alloc();
    AVPacket *pkt = av_packet_alloc();
    uint8_t *planar = NULL;
    if (stage >= ST_DECODE && m->fourcc == UVC_MJPG) {
        av_log_set_level(AV_LOG_FATAL);   /* Logitech's APP fields draw an error line every frame (harmless); decode errors are counted */
        codec = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
        av = codec ? avcodec_alloc_context3(codec) : NULL;
        if (!av) { fprintf(stderr, "h264cam: no MJPEG decoder\n"); return 1; }
        av->thread_count = 1;
        if (avcodec_open2(av, codec, NULL) < 0) { fprintf(stderr, "h264cam: the MJPEG decoder did not open\n"); return 1; }
    } else if (stage >= ST_DECODE) {
        planar = malloc((size_t)m->width * m->height * 2u);
    }
    FILE *sf = save && save_n > 0 ? fopen(save, "wb") : NULL;

    struct spinner sp[NCPU];
    uint64_t sp0[NCPU] = { 0 };
    if (do_spin)
        for (int i = 0; i < NCPU; i++) {
            sp[i] = (struct spinner){ .cpu = i };
            pthread_create(&sp[i].t, NULL, spin, &sp[i]);
        }
    if (stage != ST_IDLE) {
        uvc_force_alt(d, force_alt);
        int fr_rc = uvc_fixed_rate(d);
        printf("h264cam: constant frame rate (AE priority off): %s\n", fr_rc ? strerror(-fr_rc) : "set");
        if ((rc = uvc_start(d, m, interval, &interval, info, sizeof info))) {   /* the record carries the committed rate */
            fprintf(stderr, "h264cam: %s did not start streaming (%s)\n", uvc_name(d), strerror(-rc));
            quit = 1;
        } else {
            printf("h264cam: %s: %s\n", uvc_name(d), info);
        }
    }
    sleep(1);                                    /* settle: the spinners scheduled, the stream started */
    for (int i = 0; do_spin && i < NCPU; i++) sp0[i] = sp[i].n;
    uint64_t irq0 = dwc2_irqs(), jb0, jt0;
    cpu_jiffies(&jb0, &jt0);
    struct rusage ru0;
    getrusage(RUSAGE_SELF, &ru0);
    double t0 = mono(), tick = t0, dec_cpu = 0, copy_cpu = 0;
    uint64_t n_dec = 0, n_shown = 0, no_store = 0, ring_full = 0, dec_err = 0, wr_err = 0;
    struct uvc_stats us0;
    memset(&us0, 0, sizeof us0);
    if (d && !quit) uvc_get_stats(d, &us0);

    while (!quit && (seconds <= 0 || mono() - t0 < seconds)) {
        if (have_core && core_poll(&core) == -ENODEV) break;
        if (stage == ST_IDLE) { usleep(100000); continue; }
        const uint8_t *data;
        size_t len;
        rc = uvc_take(d, &data, &len, 200);
        if (rc == -EIO) { fprintf(stderr, "h264cam: the stream stopped (the device was unplugged?)\n"); break; }
        if (rc) continue;
        if (sf && save_n > 0) {
            uint32_t l = (uint32_t)len;
            fwrite(&l, 4, 1, sf);
            fwrite(data, 1, len, sf);
            if (--save_n == 0) { fclose(sf); sf = NULL; }
        }
        if (stage < ST_DECODE) continue;
        struct pic p;
        double c0 = thread_cpu();
        if (av) {
            pkt->data = (uint8_t *)data;         /* the assembler pads past the end (uvc.c PAD) */
            pkt->size = (int)len;
            if (avcodec_send_packet(av, pkt) < 0 || avcodec_receive_frame(av, fr) < 0 || av_fmt(fr, &p.fmt)) {
                dec_err++;
                continue;
            }
            for (int i = 0; i < 3; i++) { p.planes[i] = fr->data[i]; p.strides[i] = fr->linesize[i]; }
        } else {
            uint8_t *y = planar, *u = y + (size_t)m->width * m->height, *v = u + (size_t)m->width * m->height / 2u;
            yuy2_planar(data, m->width, m->height, y, u, v);
            p.planes[0] = y; p.planes[1] = u; p.planes[2] = v;
            p.strides[0] = (int)m->width; p.strides[1] = p.strides[2] = (int)m->width / 2;
            p.fmt = H264RING_PIX_YUV422P;
        }
        double c1 = thread_cpu();
        dec_cpu += c1 - c0;
        n_dec++;
        if (stage == ST_SHOW) {
            struct h264ring_picture pic;
            unsigned k;
            memset(&pic, 0, sizeof pic);
            pic.width = av ? (unsigned)fr->width : m->width;
            pic.height = av ? (unsigned)fr->height : m->height;
            pic.structure = H264RING_PIC_STRUCT_FRAME;
            pic.pic_struct = -1;
            pic.rate_num = 10000000u;            /* the committed interval, 100 ns units */
            pic.rate_den = interval;
            pic.colour = (p.fmt == H264RING_PIX_YUVJ420P || p.fmt == H264RING_PIX_YUVJ422P) ?   /* (0.16) D-C8 */
                         H264RING_COLOUR_601_FULL : H264RING_COLOUR_AUTO;
            rc = h264ring_picture_acquire(core.r, &k);
            if (rc == -EAGAIN) { no_store++; continue; }       /* every store still shown: this frame is dropped */
            if (rc) { wr_err++; continue; }
            if (h264ring_picture_copy(h264ring_picture_store(core.r, k), &pic, p.planes, p.strides, p.fmt)) {
                fprintf(stderr, "h264cam: a %ux%u picture the core cannot show\n", pic.width, pic.height);
                break;
            }
            /* LOW_LATENCY: shown as soon as it arrives; no PTS (the camera's clock is not ours) */
            rc = h264ring_try_write_picture(core.r, k, &pic, -1, H264RING_F_LOW_LATENCY);
            if (rc == -EAGAIN) ring_full++;      /* the store stays ours; the next frame takes another */
            else if (rc) wr_err++;
            else n_shown++;
            copy_cpu += thread_cpu() - c1;
        }
        if (mono() - tick >= 5) {
            struct uvc_stats s;
            uvc_get_stats(d, &s);
            tick = mono();
            printf("  %5.1f s: frames %llu bad %llu replaced %llu, decoded %llu, shown %llu\n", tick - t0,
                   (unsigned long long)(s.frames - us0.frames), (unsigned long long)(s.frames_bad - us0.frames_bad),
                   (unsigned long long)(s.frames_replaced - us0.frames_replaced),
                   (unsigned long long)n_dec, (unsigned long long)n_shown);
            fflush(stdout);
        }
    }

    double wall = mono() - t0;
    struct rusage ru1;
    getrusage(RUSAGE_SELF, &ru1);
    uint64_t irq1 = dwc2_irqs(), jb1, jt1;
    cpu_jiffies(&jb1, &jt1);
    double sprate[NCPU] = { 0 };
    for (int i = 0; do_spin && i < NCPU; i++) {
        sprate[i] = (sp[i].n - sp0[i]) / wall;
        sp[i].stop = 1;
        pthread_join(sp[i].t, NULL);
    }
    struct uvc_stats s;
    memset(&s, 0, sizeof s);
    if (d) { uvc_get_stats(d, &s); uvc_stop(d); }
    if (sf) fclose(sf);

#define D(f) (unsigned long long)(s.f - us0.f)
    static const char *names[] = { "idle", "capture", "decode", "show" };
    printf("h264cam: stage %s, %.1f s%s%s\n", names[stage], wall, info[0] ? ": " : "", info);
    if (d) {
        printf("  frames %llu (%.2f/s), taken %llu, replaced %llu, bad %llu [err bit %llu, packet %llu, overflow %llu, shape %llu]\n",
               D(frames), D(frames) / wall, D(frames_taken), D(frames_replaced), D(frames_bad), D(bad_err_bit),
               D(bad_packet), D(bad_overflow), D(bad_shape));
        printf("  fid_no_eof %llu, stray %llu, bad headers %llu, resubmit errors %llu\n", D(fid_no_eof),
               D(stray_payloads), D(bad_headers), D(resubmit_errors));
        printf("  transfers %llu, packets %llu (empty %llu, errors %llu), payload %.2f MB/s\n", D(transfers), D(packets),
               D(packets_empty), D(packet_errors), D(bytes) / wall / 1e6);
    }
    if (n_dec)
        printf("  decoded %llu (errors %llu): %.2f ms CPU each%s%s\n", (unsigned long long)n_dec,
               (unsigned long long)dec_err, dec_cpu / n_dec * 1e3, av ? ", as " : "",
               av ? av_get_pix_fmt_name((enum AVPixelFormat)fr->format) : "");
    if (stage == ST_SHOW)
        printf("  shown %llu, no store free %llu, ring full %llu, write errors %llu: copy + write %.2f ms CPU each\n",
               (unsigned long long)n_shown, (unsigned long long)no_store, (unsigned long long)ring_full,
               (unsigned long long)wr_err, n_shown ? copy_cpu / n_shown * 1e3 : 0.0);
    double ut = (ru1.ru_utime.tv_sec - ru0.ru_utime.tv_sec) + (ru1.ru_utime.tv_usec - ru0.ru_utime.tv_usec) / 1e6;
    double stt = (ru1.ru_stime.tv_sec - ru0.ru_stime.tv_sec) + (ru1.ru_stime.tv_usec - ru0.ru_stime.tv_usec) / 1e6;
    /* the spinners are this process's too: their time is not the pipeline's */
    printf("  share of one core: decode %.3f, copy %.3f, USB thread %.3f (whole run), process %.3f (user %.3f, sys %.3f)%s\n",
           dec_cpu / wall, copy_cpu / wall, d ? uvc_thread_cpu(d) / wall : 0.0, (ut + stt) / wall, ut / wall,
           stt / wall, do_spin ? " -- includes the spinners: read the spin line" : "");
    printf("  dwc2 interrupts %.0f/s; /proc/stat busy %.3f of 2 cores (interrupt time not accounted)\n",
           (irq1 - irq0) / wall, jt1 > jt0 ? 2.0 * (jb1 - jb0) / (jt1 - jt0) : 0.0);
    if (do_spin) {
        printf("  spin (left over, iterations/s): cpu0 %.0f, cpu1 %.0f", sprate[0], sprate[1]);
        /* a core the idle run left (almost) nothing of is Main's (pinned to CPU1, polling): no share */
        for (int i = 0; i < NCPU; i++)
            if (base[i] > 0 && base[i] >= 0.01 * (base[0] > base[1] ? base[0] : base[1]))
                printf("%s cpu%d %.3f", i == 0 || !(base[0] >= 0.01 * base[1]) ? " -> taken beyond idle:" : ",", i,
                       1 - sprate[i] / base[i]);
            else if (base[i] > 0)
                printf(" (cpu%d: nothing left at idle -- Main's)", i);
        printf("\n");
    }
    if (av) avcodec_free_context(&av);
    av_frame_free(&fr);
    av_packet_free(&pkt);
    free(planar);
    if (have_core) core_close(&core);
    uvc_close(d);
    return 0;
}

#ifndef CLIENT_TEST
int main(int argc, char **argv)
{
    for (int i = 1; i < argc; i++)                   /* any option but --dir: the measuring tool */
        if (!strcmp(argv[i], "--dir")) i++;
        else return measure_main(argc, argv);
    return cam_main(argc, argv);
}
#endif
