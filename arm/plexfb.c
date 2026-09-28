/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 Matija Erceg
 *
 * plexfb - ARM-side writer for the PlexCRT core's DDR3 scan-out.
 *
 * Memory layout: see rtl/ddr_scanout.v. The ring lives in the Linux
 * framebuffer (/dev/fb0), which MiSTer main also maps; PHYS_BASE is a fallback.
 *
 *   plexfb card             draw a static test card into buffer 0 and exit
 *   plexfb anim [seconds]   moving bars, alternating buffers, paced on the
 *                           core's field counter (double-buffer / tear test)
 *   plexfb raw [fps] [yuv]  read 720x480 frames from stdin and show them:
 *                           BGRA (ffmpeg ... -f rawvideo -pix_fmt bgra -) or,
 *                           with "yuv", planar yuv420p converted in the core
 *   plexfb status           print the header and status words
 *
 * Build (WSL): arm-linux-gnueabihf-gcc -O2 -static -march=armv7-a -mfpu=neon
 *              -mfloat-abi=hard -o plexfb plexfb.c
 */
#define _GNU_SOURCE          /* F_SETPIPE_SZ */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <fcntl.h>
#include <math.h>
#include <sys/mman.h>
#include <time.h>
#include <pthread.h>
#include <signal.h>
#include <sys/types.h>
#if defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif

#define PHYS_BASE   0x30000000u
#define MAP_SIZE    (8u << 20)
#define NSLOT       4                                   /* frame ring, see ddr_scanout.v */
#define RING        4                                   /* slots the video cycles through */
#define BUF_OFF(i)  (0x100000u + (uint32_t)(i) * 0x160000u)
#define STAT_OFF    0x40u
#define MAGIC       0x504C4558u

#define W       720
#define H       480
#define STRIDE  (W * 4)

struct hdr {
	volatile uint32_t magic, seq, buf, width, height, stride, fmt, u_off, v_off, flags;
};

/* frame format: 0 = xRGB8888, 1 = planar yuv420p (ffmpeg -pix_fmt yuv420p) */
static int g_yuv = 0;
#define FRAME_BYTES   (g_yuv ? W * H * 3 / 2 : W * H * 4)
#define Y_STRIDE      W
#define U_OFF_WORDS   (W * H / 8)                 /* 43200 */
#define V_OFF_WORDS   (W * H / 8 + (W / 2) * (H / 2) / 8)   /* 54000 */
struct stat_w {
	volatile uint32_t field_cnt, seq_shown;
	volatile uint32_t joy;      /* build 15+: joystick_1[15:0] << 16 | joystick_0[15:0] */
	volatile uint32_t key;      /* build 15+: key_cnt << 16 | ps2_key[10:0] */
};

/* runtime control (AVI / raw modes):
 *   SIGUSR1  toggle pause (picture holds, audio stops with it)
 *   SIGTERM  leave cleanly: blank the screen, exit 0
 *   SIGUSR2  leave quietly: keep the last frame on screen (a seek: the next
 *            presenter takes over from it and starts its ring past that slot)
 * Progress goes to PLEXFB_STATUS (default /tmp/plexfb.stat) twice a second:
 *   pos=<s> shown=<n> filled=<n> eof=<0|1> paused=<0|1> starved=<n>
 */
static volatile sig_atomic_t g_pause = 0, g_quit = 0, g_hold = 0;
static void on_usr1(int s) { (void)s; g_pause = !g_pause; }
static void on_term(int s) { (void)s; g_quit = 1; }
static void on_usr2(int s) { (void)s; g_hold = 1; g_quit = 1; }

static uint8_t *map;
static struct hdr *hdr;
static struct stat_w *stat;

/*
 * MiSTer main sizes the Linux framebuffer for its own HDMI mode: at 720p, or
 * with direct video, /dev/fb0 maps less than the ring. Main writes that mode
 * again whenever it sets a video mode, from a worker thread, so the launcher's
 * 1920x1080 can be undone after it. Put it back before mapping. Writing the
 * mode clears this memory; the presenter publishes its own frames anyway.
 * Only for a running core: once main has loaded the menu, the mode is the
 * menu's, and the write also clears the top of its wallpaper.
 */
#define FB_MODE_FILE "/sys/module/MiSTer_fb/parameters/mode"

/* The core writes its field counter, then its status signature at +0x6c,
   every vsync (rtl/ddr_scanout.v). Running: the counter moves on to a
   nonzero value beside the signature within ms. A mode write zeroes both
   until the next vsync, and another core leaves them as they were. */
static int core_running(const volatile uint32_t *words, int ms)
{
	uint32_t start = words[STAT_OFF / 4];
	for (int waited = 0; ; waited += 2) {
		uint32_t f = words[STAT_OFF / 4];
		if (f != start && f != 0 && (words[0x6c / 4] & 0xfffffff0u) == 0x56500000u)
			return 1;
		if (waited >= ms) return 0;
		usleep(2000);
	}
}

/* through one page, which any mode maps */
static int core_running_fd(int fd, int ms)
{
	void *page = mmap(0, 4096, PROT_READ, MAP_SHARED, fd, 0);
	if (page == MAP_FAILED) return 0;
	int running = core_running(page, ms);
	munmap(page, 4096);
	return running;
}

/* 0 when the mode needed enlarging and the core is not running */
static int enlarge_fb(int fd, size_t len)
{
	char mode[64] = "";
	int fmt, rb, w, h, stride;
	FILE *f = fopen(FB_MODE_FILE, "r");
	if (!f) return 1;
	if (!fgets(mode, sizeof mode, f)) mode[0] = 0;
	fclose(f);
	if (sscanf(mode, "%d %d %d %d %d", &fmt, &rb, &w, &h, &stride) != 5) return 1;
	if (fmt == 8888 && (size_t)stride * (size_t)h >= len) return 1;
	if (!core_running_fd(fd, 100)) return 0;
	mode[strcspn(mode, "\n")] = 0;
	fprintf(stderr, "plexfb: framebuffer mode \"%s\" maps less than the ring; setting 1920x1080\n", mode);
	f = fopen(FB_MODE_FILE, "w");
	if (!f) { perror(FB_MODE_FILE); return 1; }
	fputs("8888 1 1920 1080 7680\n", f);
	if (fclose(f)) perror(FB_MODE_FILE);
	return 1;
}

/*
 * Two ways to reach the buffer:
 *   /dev/mem at PHYS_BASE  - strongly ordered mapping, every store waits
 *                            (measured 87 MB/s idle, 44 MB/s next to ffmpeg)
 *   /dev/fb0 at offset 0   - the fbdev driver maps its memory write-combined,
 *                            which is what we want for streaming frames.
 * PLEXFB_DEV=/dev/fb0 selects the second; the core must then read from the
 * framebuffer's physical address instead of PHYS_BASE.
 */
static void map_mem(void)
{
	const char *dev = getenv("PLEXFB_DEV");
	int fd;
	off_t off;
	if (dev && !strcmp(dev, "/dev/mem")) {          /* legacy, build 7 layout */
		fd = open(dev, O_RDWR | O_SYNC | O_CLOEXEC);
		off = PHYS_BASE;
	} else {
		if (!dev) dev = "/dev/fb0";                 /* default since build 8 */
		fd = open(dev, O_RDWR | O_CLOEXEC);
		off = 0;
	}
	if (fd < 0) { perror(dev); exit(1); }
	/* fb0 is 1920*1080*4 = 8,294,400 bytes; mmap refuses anything longer */
	size_t len = off ? MAP_SIZE : 0x7E0000u;   /* slot 4 ends at 0x7D1800 */
	for (int tries = 0; ; tries++) {
		if (!off && !enlarge_fb(fd, len)) {
			fprintf(stderr, "plexfb: MisterZine Plex Core is not running; framebuffer mode left alone\n");
			exit(1);
		}
		map = mmap(0, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, off);
		if (map != MAP_FAILED) break;
		/* main's own mode write can land between ours and the mapping */
		if (off || errno != EINVAL || tries == 20) {
			fprintf(stderr, "plexfb: cannot map %zu bytes of %s: %s\n", len, dev, strerror(errno));
			exit(1);
		}
		usleep(50000);
	}
	hdr  = (struct hdr *)(map);
	stat = (struct stat_w *)(map + STAT_OFF);
}

/* publish buffer `buf` as frame `seq`: header first, seq last */
static void publish(int buf, uint32_t seq)
{
	hdr->magic  = MAGIC;
	hdr->buf    = buf;
	hdr->width  = W;
	hdr->height = H;
	hdr->stride = g_yuv ? Y_STRIDE : STRIDE;
	hdr->fmt    = g_yuv;
	hdr->u_off  = U_OFF_WORDS;
	hdr->v_off  = V_OFF_WORDS;
	hdr->flags  = 0;
	__sync_synchronize();
	hdr->seq    = seq;
}

static void wait_field(uint32_t *last)
{
	for (;;) {
		uint32_t f = stat->field_cnt;
		if (f != *last) { *last = f; return; }
		usleep(300);
	}
}

static double now(void)
{
	struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec + ts.tv_nsec * 1e-9;
}

/* Block until field_cnt reaches target. The kernel's sleep granularity is
   coarse enough to overshoot a whole field, which turns a 3:2 cadence into
   4:1, so this sleeps only to a few ms before the field is due and spins the
   rest, watching the counter the core writes every vsync. */
static double g_fps, g_avi_fps;      /* set in avi mode; defined below */
#define FIELD_S (1.0 / 59.94)
static void wait_for_field(double target)
{
	static uint32_t last; static double last_t;
	for (;;) {
		uint32_t f = stat->field_cnt;
		double t = now();
		if (f != last) { last = f; last_t = t; }
		if ((double)f >= target || g_quit) return;
		double eta = last_t + (target - f) * FIELD_S - t;   /* seconds to go */
		/* A field at most, then look again: a framebuffer mode write clears
		   the counter for a moment, and a sleep worked out from that would
		   last as long as the core has been running. */
		if (eta > FIELD_S) eta = FIELD_S;
		if (eta > 0.0035) usleep((useconds_t)((eta - 0.0035) * 1e6));
		else if (eta > 0.0003) usleep(100);
		/* else spin */
	}
}

/* ---------- test card ---------- */
static const uint32_t bars[8] = {
	0xEBEBEB, 0xEBEB10, 0x10EBEB, 0x10EB10, 0xEB10EB, 0xEB1010, 0x1010EB, 0x101010
};

static void draw_card(uint32_t *f)
{
	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			uint32_t c;
			if (y < 120)       c = bars[x * 8 / W];
			else if (y < 240) {                     /* grid 16 px, one-pixel lines */
				c = ((x & 15) == 0 || (y & 15) == 0) ? 0xEBEBEB : 0x101010;
			}
			else if (y < 360) {                     /* ring + X, same as the FPGA card */
				int dx = x - 360, dy = y - 300;
				int d2 = dx * dx + dy * dy;
				c = 0x101010;
				if (d2 > 2966 && d2 < 3306) c = 0x10EBEB;
				if (abs(x - (y + 60)) <= 1 || abs(x - (660 - y)) <= 1) c = 0xEBEB10;
			}
			else {                                  /* grey ramp */
				uint32_t v = x * 255 / (W - 1);
				c = (v << 16) | (v << 8) | v;
			}
			/* 8-px border, blue, so the ARM frame is told apart from the FPGA card */
			if (x < 8 || x >= W - 8 || y < 4 || y >= H - 4) c = 0x2020FF;
			f[y * W + x] = c;
		}
	}
}

static void draw_anim(uint32_t *f, int t)
{
	int bx = (t * 6) % (W - 40);           /* a bar sweeping right, 6 px per field */
	int by = (t * 3) % (H - 40);           /* a bar sweeping down, 3 rows per field */
	for (int y = 0; y < H; y++) {
		for (int x = 0; x < W; x++) {
			uint32_t c = ((x >> 5) + (y >> 5)) & 1 ? 0x303030 : 0x181818;
			if (x >= bx && x < bx + 40) c = 0xEB4040;
			if (y >= by && y < by + 40) c = 0x40EB40;
			if (x < 8 || x >= W - 8 || y < 4 || y >= H - 4) c = 0x2020FF;
			f[y * W + x] = c;
		}
	}
}

static void copy_frame(int buf, const uint32_t *src)
{
	memcpy(map + BUF_OFF(buf), src, W * H * 4);
}

/* ---------- ring-buffered presenter ----------
 * The reader thread pulls frames from stdin straight into free ring slots and
 * can run up to NSLOT-2 frames ahead of the screen. The presenter publishes
 * one frame per `fields_per_frame` fields, never blocking on the decoder, so
 * decoder jitter is absorbed instead of turning into repeated frames. */
static volatile unsigned ring_filled = 0, ring_shown = 0;   /* frame counters */
/* the counters start at ring_base so the first slots written are not the
   one a previous presenter left on screen (its frame holds until ours) */
static unsigned ring_base = 0;
static volatile int ring_eof = 0;
static double stat_read_ms = 0, stat_scale_ms = 0;
/* every decoded frame is kept in RAM too, at the size it arrived (the ring is
   write-combined and must never be read): it is scaled from there into the
   ring, and an empty AVI chunk repeats it. The slack lets a scaler row read a
   few bytes past the last pixel it uses. */
#define MAX_SRC_W   1920
#define MAX_SRC_H   1088
#define RAM_BYTES   (MAX_SRC_W * MAX_SRC_H * 3 / 2 + 64)
static uint8_t *ram[RING];
static uint8_t *ram_slot(int i) { if (!ram[i]) ram[i] = malloc(RAM_BYTES); return ram[i]; }

/* ---------- picture geometry ----------
 * Plex sends square-pixel frames of whatever size fits the requested box:
 * 640x480 for 4:3, 720x404 for 16:9, 644x480 for a source a little wider
 * than 4:3. The raster is 720x480 on a 4:3 screen. Each frame is fitted into
 * it (letterbox or pillarbox) and resampled while it is copied into the ring:
 * two taps in each direction, NEON on the ARM, and a plain C version that
 * gives the same bytes. The source rectangle is separate from the frame, so a
 * crop or a zoom is only a different rectangle. */
struct plane_map {
	int sw, sh;                 /* source plane */
	int cx, cy, cw, ch;         /* source rectangle */
	int dx, dy, dw, dh;         /* where it lands in the output plane */
	int ow, oh;                 /* output plane: 720x480 or 360x240 */
	uint8_t black;
	int16_t hx[W]; uint8_t hw[W];   /* per output column: left tap, weight of the right one /128 */
	int16_t vy[H]; uint8_t vw[H];   /* per output row */
	int groups;                 /* NEON: whole groups of 8 output columns, 0 = C only */
	int16_t gbase[W / 8];
	uint8_t gia[W], gib[W], gwa[W], gwb[W];
};
struct geometry {
	int w, h;                   /* frame size */
	double aspect;              /* display aspect of the whole frame */
	struct plane_map p[3];      /* Y, U, V */
};
static struct geometry g_geo;
static int g_scale_c = 0;       /* force the C scaler (tests, PLEXFB_SCALE_C) */

/* output position k samples the input at (k + 0.5) * n_in / n_out - 0.5,
   in 1/128 pixel, clamped to the rectangle */
static void taps(int n_out, int n_in, int16_t *idx, uint8_t *wt)
{
	for (int k = 0; k < n_out; k++) {
		int64_t p = (int64_t)(2 * k + 1) * n_in * 64 / n_out - 64;
		if (p < 0) p = 0;
		int i = (int)(p >> 7), f = (int)(p & 127);
		if (i >= n_in - 1) { i = n_in - 1; f = 0; }
		idx[k] = (int16_t)i; wt[k] = (uint8_t)f;
	}
}

static void plane_setup(struct plane_map *m, int sw, int sh, int cx, int cy, int cw, int ch,
                        int dx, int dy, int dw, int dh, int ow, int oh, uint8_t black)
{
	*m = (struct plane_map){ .sw = sw, .sh = sh, .cx = cx, .cy = cy, .cw = cw, .ch = ch,
	                         .dx = dx, .dy = dy, .dw = dw, .dh = dh, .ow = ow, .oh = oh, .black = black };
	taps(dw, cw, m->hx, m->hw);
	taps(dh, ch, m->vy, m->vw);
	/* a group of 8 outputs gathers from one 16-byte window: fine up to about a
	   2:1 shrink, beyond that the plain loop does the row */
	m->groups = dw / 8;
	for (int g = 0; g < m->groups; g++) {
		int base = m->hx[8 * g];
		if (m->hx[8 * g + 7] + 1 - base > 15) { m->groups = 0; break; }
		m->gbase[g] = (int16_t)base;
		for (int k = 0; k < 8; k++) {
			int x = 8 * g + k;
			m->gia[x] = (uint8_t)(m->hx[x] - base);
			m->gib[x] = (uint8_t)(m->hx[x] - base + 1);
			m->gwb[x] = m->hw[x];
			m->gwa[x] = (uint8_t)(128 - m->hw[x]);
		}
	}
}

/* The picture area, from the app's geometry calibration: how far each edge
 * sits inside the raster's (even, so chroma stays aligned) and the picture's
 * width in thousandths of the nominal one, for a set that draws the picture
 * too wide or too narrow. The default is the whole raster at 4:3. */
struct screen { int l, t, r, b, width; };
#define SCREEN_MAX_X (W / 6)
#define SCREEN_MAX_Y (H / 6)
#define SCREEN_WIDTH_MIN 850
#define SCREEN_WIDTH_MAX 1150
static struct screen g_screen = { 0, 0, 0, 0, 1000 };

/* PLEXFB_GEOMETRY "left,top,right,bottom,width": 1 if valid */
static int parse_screen(const char *s, struct screen *out)
{
	struct screen v;
	char end;
	if (!s || sscanf(s, "%d,%d,%d,%d,%d%c", &v.l, &v.t, &v.r, &v.b, &v.width, &end) != 5) return 0;
	if ((v.l | v.t | v.r | v.b) & 1) return 0;
	if (v.l < 0 || v.r < 0 || v.l > SCREEN_MAX_X || v.r > SCREEN_MAX_X) return 0;
	if (v.t < 0 || v.b < 0 || v.t > SCREEN_MAX_Y || v.b > SCREEN_MAX_Y) return 0;
	if (v.width < SCREEN_WIDTH_MIN || v.width > SCREEN_WIDTH_MAX) return 0;
	*out = v;
	return 1;
}

/* where a frame of display aspect `aspect` and `sh` lines goes. Without
   calibration, exactly where it went before calibration existed; with it,
   the same shape, as large as fits the picture area at the calibrated width,
   centred. Keep in step with Geometry.Fit in app/internal/ui/geometry.go
   (tools/testdata/fit_cases.txt). */
static void fit(const struct screen *s, double aspect, int sh, int *dx, int *dy, int *dw, int *dh)
{
	/* on the whole 4:3 raster, as before calibration existed */
	int w = W, h = H;
	if (aspect > 4.0 / 3.0) h = 2 * (int)lround(H * (4.0 / 3.0) / aspect / 2);
	else                    w = 2 * (int)lround(W * aspect / (4.0 / 3.0) / 2);
	if (w < 16) w = 16;
	if (h < 16) h = 16;
	if (w >= W - W / 60) w = W;          /* near 4:3: no slivers of border */
	/* within 2% of the frame's own line count, keep its lines 1:1: a resample
	   that small would only soften the picture (644x480 fills the screen) */
	if (!(sh & 1) && sh <= H && abs(h - sh) <= H / 50) h = sh;
	/* calibrated: that shape, its width scaled by the correction, as large
	   as fits the picture area */
	int aw = W - s->l - s->r, ah = H - s->t - s->b;
	if (aw != W || ah != H || s->width != 1000) {
		double k = s->width / 1000.0;
		int nw = aw, nh = ah;
		if ((double)w * ah * k > (double)aw * h) nh = 2 * (int)lround((double)aw * h / (w * k) / 2);
		else                                     nw = 2 * (int)lround((double)w * ah * k / h / 2);
		w = aw - nw <= 2 ? aw : nw;      /* a rounding step short: fill */
		h = ah - nh <= 2 ? ah : nh;
		if (w < 16) w = 16;
		if (h < 16) h = 16;
	}
	*dw = w; *dh = h; *dx = s->l + ((aw - w) / 2 & ~1); *dy = s->t + ((ah - h) / 2 & ~1);
}

/* Crop, named by the file at PLEXFB_CROP_FILE: "off", "14:9" (the sides of
 * anything wider than 14:9 go) or "fill" (whatever overhangs the picture
 * area goes, so it has no borders: the sides of a wide picture on a 4:3
 * area, the top and bottom of a narrow one). The app writes the file before
 * playback and again when the viewer changes the crop; the presenter thread
 * reads it between fields (crop_follow). Keep the thresholds in step with Geometry.Cuts
 * in app/internal/ui/crop.go (tools/testdata/crop_cases.txt). */
enum { CROP_OFF, CROP_14_9, CROP_FILL };
static const char *const crop_names[] = { "off", "14:9", "fill" };
static int g_crop = CROP_OFF;
static const char *g_crop_file;

/* a crop's name, with nothing but white space around it: -1 if not one */
static int parse_crop(const char *s)
{
	char word[8], end;
	if (sscanf(s, " %7s %c", word, &end) != 1) return -1;
	for (int i = 0; i < 3; i++)
		if (!strcmp(word, crop_names[i])) return i;
	return -1;
}

/* the crop the file names: -1 if it is missing or names none */
static int read_crop(const char *path)
{
	char b[32];
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0) return -1;
	ssize_t n = read(fd, b, sizeof b - 1);
	close(fd);
	if (n <= 0) return -1;
	b[n] = 0;
	return parse_crop(b);
}

/* The part of a w x h frame of display aspect `aspect` that crop `mode`
   keeps, centred and even where chroma needs it; returns that part's
   display aspect. A picture within 1% of the target is left whole. */
static double crop_rect(int mode, const struct screen *s, int w, int h, double aspect,
                        int *cx, int *cy, int *cw, int *ch)
{
	*cx = 0; *cy = 0; *cw = w; *ch = h;
	if (mode == CROP_OFF) return aspect;
	double target = 14.0 / 9.0;
	if (mode == CROP_FILL)          /* the area's shape as the viewer sees it */
		target = (8.0 / 9.0) * (W - s->l - s->r) / ((H - s->t - s->b) * (s->width / 1000.0));
	if (aspect > target * 1.01) {
		*cw = 2 * (int)lround(w * target / aspect / 2);
		if (*cw < 16) *cw = 16;
		*cx = (w - *cw) / 2 & ~1;
	} else if (mode == CROP_FILL && aspect < target / 1.01) {
		*ch = 2 * (int)lround(h * aspect / target / 2);
		if (*ch < 16) *ch = 16;
		*cy = (h - *ch) / 2 & ~1;
	} else
		return aspect;
	return aspect * *cw * h / ((double)w * *ch);
}

/* the frame, less what the crop cuts, fitted to the picture area; frame
   planes are packed I420 */
static void geometry_setup(struct geometry *g, int w, int h, double aspect)
{
	int dx, dy, dw, dh, cx, cy, cw, ch;
	int w2 = (w + 1) / 2, h2 = (h + 1) / 2;
	if (!(aspect > 0.25 && aspect < 4.0)) aspect = (double)w / h;
	g->w = w; g->h = h; g->aspect = aspect;
	double shown = crop_rect(g_crop, &g_screen, w, h, aspect, &cx, &cy, &cw, &ch);
	if (g_crop == CROP_FILL && (cw < w || ch < h)) {
		/* cut to the area's shape: the whole area, whatever the rounding */
		dx = g_screen.l; dy = g_screen.t;
		dw = W - g_screen.l - g_screen.r; dh = H - g_screen.t - g_screen.b;
	} else
		fit(&g_screen, shown, ch, &dx, &dy, &dw, &dh);
	plane_setup(&g->p[0], w, h, cx, cy, cw, ch, dx, dy, dw, dh, W, H, 16);
	/* a side left whole keeps an odd last chroma sample; a cut one is even */
	for (int i = 1; i < 3; i++)
		plane_setup(&g->p[i], w2, h2, cx / 2, cy / 2, (cw + 1) / 2, (ch + 1) / 2,
		            dx / 2, dy / 2, dw / 2, dh / 2, W / 2, H / 2, 128);
}

static size_t geometry_frame_bytes(const struct geometry *g)
{
	return (size_t)g->w * g->h + 2 * (size_t)((g->w + 1) / 2) * ((g->h + 1) / 2);
}

/* one output row from a source row that already starts at the rectangle's left edge */
static void hscale_c(const struct plane_map *m, const uint8_t *row, uint8_t *d, int from)
{
	for (int k = from; k < m->dw; k++) {
		int i = m->hx[k], f = m->hw[k];
		d[k] = (uint8_t)((row[i] * (128 - f) + row[i + 1] * f + 64) >> 7);
	}
}

static void hscale(const struct plane_map *m, const uint8_t *row, uint8_t *d)
{
	int k = 0;
#ifdef HAVE_NEON
	if (!g_scale_c)
		for (int g = 0; g < m->groups; g++, k += 8) {
			const uint8_t *p = row + m->gbase[g];
			uint8x8x2_t win = { { vld1_u8(p), vld1_u8(p + 8) } };
			uint8x8_t a = vtbl2_u8(win, vld1_u8(m->gia + k));
			uint8x8_t b = vtbl2_u8(win, vld1_u8(m->gib + k));
			uint16x8_t acc = vmull_u8(a, vld1_u8(m->gwa + k));
			acc = vmlal_u8(acc, b, vld1_u8(m->gwb + k));
			vst1_u8(d + k, vrshrn_n_u16(acc, 7));
		}
#endif
	hscale_c(m, row, d, k);
}

/* rows r0 and r1 mixed by f/128 into out, n pixels */
static void vblend(const uint8_t *r0, const uint8_t *r1, int f, uint8_t *out, int n)
{
	int x = 0;
#ifdef HAVE_NEON
	if (!g_scale_c) {
		uint8x8_t wa = vdup_n_u8((uint8_t)(128 - f)), wb = vdup_n_u8((uint8_t)f);
		for (; x + 8 <= n; x += 8) {
			uint16x8_t acc = vmull_u8(vld1_u8(r0 + x), wa);
			acc = vmlal_u8(acc, vld1_u8(r1 + x), wb);
			vst1_u8(out + x, vrshrn_n_u16(acc, 7));
		}
	}
#endif
	for (; x < n; x++) out[x] = (uint8_t)((r0[x] * (128 - f) + r1[x] * f + 64) >> 7);
}

/* one plane of the frame into its output plane, borders included, every
   output byte written once and in order (the ring is write-combined) */
static void scale_plane(const struct plane_map *m, const uint8_t *src, uint8_t *dst)
{
	static uint8_t tmp[MAX_SRC_W + 32];
	int hcopy = m->cw == m->dw;          /* 1:1 columns: taps are k, weight 0 */
	for (int y = 0; y < m->oh; y++) {
		uint8_t *d = dst + (size_t)y * m->ow;
		if (y < m->dy || y >= m->dy + m->dh) { memset(d, m->black, m->ow); continue; }
		int k = y - m->dy, sy = m->cy + m->vy[k];
		const uint8_t *row = src + (size_t)sy * m->sw + m->cx;
		if (m->vw[k]) {
			const uint8_t *next = sy + 1 < m->sh ? row + m->sw : row;
			vblend(row, next, m->vw[k], tmp, m->cw);
			memset(tmp + m->cw, tmp[m->cw - 1], 16);
			row = tmp;
		}
		if (m->dx) memset(d, m->black, m->dx);
		if (hcopy) memcpy(d + m->dx, row, m->dw);
		else hscale(m, row, d + m->dx);
		if (m->dx + m->dw < m->ow) memset(d + m->dx + m->dw, m->black, m->ow - m->dx - m->dw);
	}
}

/* a packed I420 frame into a 720x480 yuv420p ring slot */
static void scale_frame(const struct geometry *g, const uint8_t *src, uint8_t *slot)
{
	size_t y = (size_t)g->w * g->h, c = (size_t)((g->w + 1) / 2) * ((g->h + 1) / 2);
	scale_plane(&g->p[0], src, slot);
	scale_plane(&g->p[1], src + y, slot + W * H);
	scale_plane(&g->p[2], src + y + c, slot + W * H + (W / 2) * (H / 2));
}

static void *reader_thread(void *arg)
{
	(void)arg;
	size_t need = FRAME_BYTES;
	for (;;) {
		/* slot (filled % NSLOT) is free once the frame that used it is no
		   longer on screen. After publish(shown) the core still shows frame
		   shown-1 until the next vsync, so frames shown-1 AND shown-2 must
		   stay untouched: never run more than NSLOT-2 frames ahead. */
		while (ring_filled - ring_shown >= RING - 2) usleep(500);
		uint8_t *dst = ram_slot(ring_filled % RING);
		size_t got = 0;
		double a = now();
		while (got < need) {
			ssize_t r = read(0, dst + got, need - got);
			if (r <= 0) { ring_eof = 1; return NULL; }
			got += r;
		}
		stat_read_ms += (now() - a) * 1e3;
		memcpy(map + BUF_OFF(ring_filled % RING), dst, need);
		__sync_synchronize();
		ring_filled++;
	}
}

/* progress for the launcher (timeline pings, resume point), written atomically */
static void write_status(double pos, int starved)
{
	static const char *path;
	static char tmp[256];
	if (!path) {
		path = getenv("PLEXFB_STATUS") ? getenv("PLEXFB_STATUS") : "/tmp/plexfb.stat";
		snprintf(tmp, sizeof tmp, "%s.tmp", path);
	}
	FILE *f = fopen(tmp, "w");
	if (!f) return;
	fprintf(f, "pos=%.2f shown=%u filled=%u eof=%d paused=%d starved=%d\n",
	        pos, ring_shown - ring_base, ring_filled - ring_base, ring_eof, (int)g_pause, starved);
	fclose(f);
	rename(tmp, path);
}

/* black frame into a slot the core is not showing, then publish it: leaves
   the CRT dark instead of holding the last picture after the stream ends */
static void blank_screen(uint32_t seq)
{
	int slot = (ring_shown + 1) % RING;
	uint8_t *dst = map + BUF_OFF(slot);
	if (g_yuv) {
		memset(dst, 16, W * H);
		memset(dst + W * H, 128, W * H / 2);
	} else
		memset(dst, 0, W * H * 4);
	__sync_synchronize();
	publish(slot, seq);
}

/* g_geo is the reader's once it has read the stream's header (g_geo_ready);
   after that the presenter thread may change the crop, so both hold this
   lock to change the geometry or to scale into the ring. Each change is a
   new generation; each ring slot notes the one it was scaled with. */
static pthread_mutex_t g_geo_lock = PTHREAD_MUTEX_INITIALIZER;
static volatile int g_geo_ready;
static unsigned g_geo_gen, slot_gen[RING];

static void log_picture(const char *what)
{
	const struct plane_map *y = &g_geo.p[0];
	fprintf(stderr, "plexfb: %s %dx%d, aspect %.3f, crop %s %dx%d at %d,%d -> %dx%d at %d,%d "
	        "(area %d,%d,%d,%d, width %d)%s\n",
	        what, g_geo.w, g_geo.h, g_geo.aspect, crop_names[g_crop], y->cw, y->ch, y->cx, y->cy,
	        y->dw, y->dh, y->dx, y->dy, g_screen.l, g_screen.t, g_screen.r, g_screen.b, g_screen.width,
	        y->groups || y->cw == y->dw ? "" : " (C scaler)");
}

/* presenter thread, every field: follow the crop file (read every 0.1 s),
   whatever the stream is doing. While frames flow, those already in the
   ring keep the crop they were scaled with, a frame or two. While the
   picture stands still (paused, or waiting for the decoder) the one on
   screen and any queued behind it that were scaled with an older crop are
   scaled again from the frames kept in RAM, so a change shows at once, also
   one made just before the picture stopped (a field may show it half
   drawn). Nothing is published meanwhile: this is the thread that publishes. */
static void crop_follow(void)
{
	static double next;
	if (!g_crop_file) return;
	if (now() >= next) {
		next = now() + 0.1;
		int c = read_crop(g_crop_file);
		if (c >= 0 && c != g_crop) {            /* only this thread changes g_crop */
			pthread_mutex_lock(&g_geo_lock);
			g_crop = c;
			if (g_geo_ready) {
				geometry_setup(&g_geo, g_geo.w, g_geo.h, g_geo.aspect);
				g_geo_gen++;
				log_picture("crop changed:");
			}
			pthread_mutex_unlock(&g_geo_lock);
		}
	}
	if (!g_geo_ready || !(g_pause || ring_filled == ring_shown)) return;
	pthread_mutex_lock(&g_geo_lock);
	for (unsigned i = ring_shown == ring_base ? ring_shown : ring_shown - 1; i != ring_filled; i++)
		if (slot_gen[i % RING] != g_geo_gen) {
			scale_frame(&g_geo, ram_slot(i % RING), map + BUF_OFF(i % RING));
			slot_gen[i % RING] = g_geo_gen;
		}
	__sync_synchronize();
	pthread_mutex_unlock(&g_geo_lock);
}

static void present_loop(double fps, uint32_t seq)
{
	/* let the reader get a head start so the first frames are not starved */
	while (ring_filled - ring_base < RING - 2 && !ring_eof && !g_quit) usleep(1000);
	if (g_avi_fps > 10 && g_avi_fps < 70 && fabs(g_avi_fps - fps) > 0.01) {
		fprintf(stderr, "plexfb: stream says %.3f fps, launcher said %.3f: following the stream\n", g_avi_fps, fps);
		fps = g_fps = g_avi_fps;
	}
	double fields_per_frame = 59.94 / fps;
	double target = stat->field_cnt + 1;
	int n = 0, starved = 0, max_ahead = 0;
	double t0 = now(), tstat = 0;
	/* the playback overlay is the core's own plane now (see ddr_scanout.v):
	   the presenter only publishes picture frames */
	int last_slot = -1;
	for (;;) {
		wait_for_field(target);
		if (g_quit) break;
		if (now() - tstat > 0.5) { tstat = now(); write_status((ring_shown - ring_base) / fps, starved); }
		crop_follow();
		if (g_pause) {                 /* hold: keep the clock pinned to now */
			target = stat->field_cnt + 1;
			continue;
		}
		if (ring_filled == ring_shown) {
			if (ring_eof) break;
			starved++;                 /* decoder behind: frame repeats */
			target += fields_per_frame;
			continue;
		}
		int ahead = ring_filled - ring_shown;
		if (ahead > max_ahead) max_ahead = ahead;
		last_slot = ring_shown % RING;
		publish(last_slot, ++seq);
		ring_shown++;
		n++;
		target += fields_per_frame;
		if ((double)stat->field_cnt > target + 1.0)   /* fell more than a frame behind */
			target = stat->field_cnt + 1;
	}
	double dt = now() - t0;
	ring_eof = 1;                      /* tells the audio thread to wind down */
	write_status((ring_shown - ring_base) / fps, starved);
	/* once main has loaded another core or the menu, this memory is its picture */
	if (!g_hold && core_running((const volatile uint32_t *)map, 100)) blank_screen(++seq);
	printf("%d frames in %.1fs (%.2f fps), avg read %.1f ms, scale %.1f ms, %d starved slots, max %d frames ahead%s\n",
	       n, dt, n / dt, n ? stat_read_ms / n : 0, n ? stat_scale_ms / n : 0, starved, max_ahead,
	       g_quit ? ", stopped" : "");
}

/* ---------- AVI mode: one interleaved stream, the presenter is the clock ----------
 * ffmpeg writes raw yuv420p video ('00dc' chunks) and S16LE stereo 48 kHz audio
 * ('01wb' chunks) into a single AVI on stdin. Video frames come at the size the
 * decoder made them and are fitted to the 4:3 raster on their way into the
 * frame ring (see picture geometry). Audio goes into a FIFO and is released to
 * aplay only when the picture has caught up to it, so the audio position
 * follows the field counter and does not depend on how far ahead the source
 * interleaved its audio (Plex sends it about a second early, which is what put
 * the sound ahead of the picture).
 * An empty video chunk (ffmpeg holding a frame over a timestamp gap) repeats
 * the previous frame, so every chunk is one frame of picture time.
 *
 *   PLEXFB_ALEAD  seconds of audio kept queued ahead of the picture (default 0.10,
 *                 roughly aplay's buffer so it never runs dry)
 *   PLEXFB_AOFF   extra audio delay in seconds, positive = later (default 0)
 *   PLEXFB_ACATCH how far the released audio may fall behind the picture before
 *                 the queued audio up to the picture is dropped (default 0.15)
 *   PLEXFB_SCALE_C scale with the plain C loops instead of NEON (same output)
 *   PLEXFB_GEOMETRY "left,top,right,bottom,width": the picture area from the
 *                 app's calibration, edges in pixels and lines inside the
 *                 raster's, width in thousandths (default "0,0,0,0,1000")
 *   PLEXFB_CROP_FILE a file naming the crop, "off", "14:9" or "fill" (see
 *                 crop_rect); read at the start and every 0.1 s after, so a
 *                 change shows within a few frames, and at once while the
 *                 picture stands still (see crop_follow)
 *
 * The gate alone only holds audio back. A stall that keeps the audio from
 * aplay for a while (a late wakeup, a blocked write) would leave every later
 * sample that much behind the picture until the next seek, so audio that has
 * fallen behind is dropped instead: one short skip, then in sync again.
 */
#define AFIFO_BYTES (48000 * 4 * 8)          /* 8 s of S16 stereo */
#define ABPS        (48000.0 * 4)
static uint8_t *afifo;
static volatile size_t a_w = 0, a_r = 0;     /* monotonic byte counters */
static double g_alead = 0.10, g_aoff = 0.0;    /* 0: a ball-and-wall clip on the CRT lands the beep on the hit
                                                  (the old 80 ms was measured before the ring_base fix) */
static double g_acatch = 0.15;
static FILE *aplay;

static uint32_t rd32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
static uint32_t rd16(const uint8_t *p) { return p[0] | p[1] << 8; }

/* a video stream's BITMAPINFOHEADER: the frame size, if it is planar yuv420p
   of a size the presenter takes */
static int parse_strf(const uint8_t *b, uint32_t sz, int *w, int *h)
{
	if (sz < 20) return 0;
	int64_t bw = (int32_t)rd32(b + 4), bh = (int32_t)rd32(b + 8);
	if (bh < 0) bh = -bh;                    /* top-down; 64 bits, so no overflow */
	if (bw < 16 || bw > MAX_SRC_W || bh < 16 || bh > MAX_SRC_H || rd16(b + 14) != 12
	    || (memcmp(b + 16, "I420", 4) && memcmp(b + 16, "IYUV", 4)))
		return 0;
	*w = (int)bw; *h = (int)bh;
	return 1;
}

/* ffmpeg's video properties chunk: the frame's display aspect, 0 if absent */
static double parse_vprp(const uint8_t *b, uint32_t sz)
{
	if (sz < 24) return 0;
	uint32_t ar = rd32(b + 20);               /* FrameAspectRatio, x << 16 | y */
	return (ar >> 16) && (ar & 0xffff) ? (double)(ar >> 16) / (ar & 0xffff) : 0;
}

static int read_full(void *dst, size_t n)
{
	size_t got = 0;
	while (got < n) {
		ssize_t r = read(0, (uint8_t *)dst + got, n - got);
		if (r <= 0) return 0;
		got += r;
	}
	return 1;
}

static int skip_bytes(size_t n)
{
	static uint8_t junk[65536];
	while (n) {
		size_t c = n > sizeof junk ? sizeof junk : n;
		if (!read_full(junk, c)) return 0;
		n -= c;
	}
	return 1;
}

static void *avi_reader(void *arg)
{
	(void)arg;
	uint8_t h[12];
	if (!read_full(h, 12) || memcmp(h, "RIFF", 4) || memcmp(h + 8, "AVI ", 4)) {
		fprintf(stderr, "plexfb: stdin is not an AVI stream\n");
		ring_eof = 1; return NULL;
	}
	/* stream 00's header says the frame size (strf, a BITMAPINFOHEADER) and,
	   when ffmpeg knows it, the display aspect (vprp). Without a size the
	   frames are the old 720x480 4:3 raster. */
	int vw = W, vh = H, sized = 0, streams = 0, vids = 0, ready = 0;
	double vaspect = 0;
	size_t vneed = 0;
	unsigned bad = 0;
	for (;;) {
		uint8_t ch[8];
		if (!read_full(ch, 8)) break;
		uint32_t sz = rd32(ch + 4);
		if (!memcmp(ch, "LIST", 4) || !memcmp(ch, "RIFF", 4)) {   /* descend into lists */
			uint8_t t[4];
			if (!read_full(t, 4)) break;
			continue;
		}
		size_t padded = sz + (sz & 1);
		if (!memcmp(ch, "strh", 4) && sz >= 32 && sz <= 256) {
			uint8_t b[256];
			if (!read_full(b, padded)) break;
			vids = streams++ == 0 && !memcmp(b, "vids", 4);   /* 00dc chunks are stream 00 */
			if (vids) {
				uint32_t scale = rd32(b + 20), rate = rd32(b + 24);
				if (scale && rate) g_avi_fps = (double)rate / scale;
			}
			continue;
		}
		if (vids && !ready && !memcmp(ch, "strf", 4) && sz >= 20 && sz <= 256) {
			uint8_t b[256];
			if (!read_full(b, padded)) break;
			if (parse_strf(b, sz, &vw, &vh)) sized = 1;
			else
				fprintf(stderr, "plexfb: video %dx%d, %u bits, %.4s: not yuv420p within %dx%d, taking 720x480\n",
				        (int)(int32_t)rd32(b + 4), (int)(int32_t)rd32(b + 8), rd16(b + 14), (const char *)b + 16,
				        MAX_SRC_W, MAX_SRC_H);
			continue;
		}
		if (vids && !ready && !memcmp(ch, "vprp", 4) && sz >= 24 && sz <= 256) {
			uint8_t b[256];
			if (!read_full(b, padded)) break;
			vaspect = parse_vprp(b, sz);
			continue;
		}
		if (!memcmp(ch, "00dc", 4)) {
			if (!ready) {
				if (!sized && !vaspect) vaspect = 4.0 / 3.0;
				pthread_mutex_lock(&g_geo_lock);
				geometry_setup(&g_geo, vw, vh, vaspect);
				g_geo_ready = 1;
				log_picture("picture");
				pthread_mutex_unlock(&g_geo_lock);
				vneed = geometry_frame_bytes(&g_geo);
				ready = 1;
			}
			if (sz && sz != vneed) {
				if (bad++ < 3) fprintf(stderr, "plexfb: video chunk %u bytes, expected %u\n", sz, (unsigned)vneed);
				if (!skip_bytes(padded)) break;
				continue;
			}
			while (ring_filled - ring_shown >= RING - 2) usleep(500);
			uint8_t *dst = ram_slot(ring_filled % RING);
			if (!sz) {
				/* an empty chunk is ffmpeg holding the frame over a gap in the
				   source's timestamps: show the last frame (black before the
				   first) for its slot, or the picture runs ahead of the sound */
				if (ring_filled != ring_base)
					memcpy(dst, ram_slot((ring_filled - 1) % RING), vneed);
				else {
					size_t luma = (size_t)vw * vh;
					memset(dst, 16, luma);
					memset(dst + luma, 128, vneed - luma);
				}
			} else {
				double a = now();
				if (!read_full(dst, sz)) break;
				if (sz & 1) skip_bytes(1);
				stat_read_ms += (now() - a) * 1e3;
			}
			double s = now();
			pthread_mutex_lock(&g_geo_lock);     /* the crop may change between frames */
			scale_frame(&g_geo, dst, map + BUF_OFF(ring_filled % RING));
			slot_gen[ring_filled % RING] = g_geo_gen;
			__sync_synchronize();
			ring_filled++;
			pthread_mutex_unlock(&g_geo_lock);
			stat_scale_ms += (now() - s) * 1e3;
		}
		else if (!memcmp(ch, "01wb", 4)) {
			size_t n = sz;
			while (n) {
				size_t off = a_w % AFIFO_BYTES;
				size_t c = n;
				if (c > AFIFO_BYTES - off) c = AFIFO_BYTES - off;
				if (c > 65536) c = 65536;
				while (AFIFO_BYTES - (a_w - a_r) < c) usleep(1000);
				if (!read_full(afifo + off, c)) goto done;
				__sync_synchronize();
				a_w += c;
				n -= c;
			}
			if (sz & 1) skip_bytes(1);
		}
		else if (!skip_bytes(padded)) break;      /* JUNK, ix00, idx1, ... */
	}
done:
	ring_eof = 1;
	return NULL;
}

static void *audio_thread(void *arg)
{
	(void)arg;
	int dbg = getenv("PLEXFB_DEBUG") != NULL;
	double tlast = now();
	for (;;) {
		double tv = (double)(ring_shown - ring_base) / g_fps;   /* picture time on screen */
		double ta = (double)a_r / ABPS;           /* audio time handed to aplay */
		if (dbg && now() - tlast > 1.0) {
			tlast = now();
			fprintf(stderr, "[a] tv=%.2f ta=%.2f queued=%.2fs filled=%u shown=%u eof=%d\n",
			        tv, ta, (a_w - a_r) / ABPS, ring_filled, ring_shown, ring_eof);
		}
		if (g_quit || (ring_eof && a_r >= a_w)) break;
		int drain = ring_eof && ring_filled == ring_shown;   /* picture over: let the tail out */
		if (!drain && a_w > a_r && ta < tv - g_aoff - g_acatch) {
			/* behind the picture: drop what is queued up to it, whole frames only */
			size_t to = (size_t)((tv - g_aoff) * ABPS) & ~(size_t)3;
			if (to > a_w) to = a_w;
			fprintf(stderr, "plexfb: audio %.2f s behind the picture at %.1f s, skipped ahead\n",
			        tv - g_aoff - ta, tv);
			__sync_synchronize();
			a_r = to;
			continue;
		}
		if (a_w == a_r || (!drain && ta > tv + g_alead - g_aoff)) { usleep(2000); continue; }
		size_t c = a_w - a_r;
		if (c > 3840) c = 3840;                   /* 20 ms slices */
		size_t off = a_r % AFIFO_BYTES;
		if (c > AFIFO_BYTES - off) c = AFIFO_BYTES - off;
		if (fwrite(afifo + off, 1, c, aplay) != c) break;
		fflush(aplay);
		a_r += c;
	}
	return NULL;
}

#ifndef PLEXFB_TEST          /* tools/plexfb_scale_test.c brings its own main */
int main(int argc, char **argv)
{
	const char *mode = argc > 1 ? argv[1] : "card";
	map_mem();

	if (!strcmp(mode, "status")) {
		for (int i = 0; i < 10; i++) {
			printf("magic=%08x seq=%u buf=%u %ux%u stride=%u | field_cnt=%u seq_shown=%u\n",
			       hdr->magic, hdr->seq, hdr->buf, hdr->width, hdr->height, hdr->stride,
			       stat->field_cnt, stat->seq_shown);
			usleep(200000);
		}
		return 0;
	}

	uint32_t *frame = malloc(W * H * 4);
	uint32_t seq = hdr->magic == MAGIC ? hdr->seq : 0;

	if (!strcmp(mode, "bench")) {       /* raw copy bandwidth into the mapping */
		draw_card(frame);
		double best = 1e9, tot = 0;
		for (int i = 0; i < 10; i++) {
			double a = now();
			copy_frame(i & 1, frame);
			double d = now() - a;
			tot += d; if (d < best) best = d;
		}
		printf("copy %u bytes: best %.1f ms (%.0f MB/s), avg %.1f ms (%.0f MB/s)\n",
		       W * H * 4, best * 1e3, W * H * 4 / best / 1e6, tot / 10 * 1e3, W * H * 4 / (tot / 10) / 1e6);
		return 0;
	}

	if (!strcmp(mode, "card")) {
		draw_card(frame);
		double t0 = now();
		copy_frame(0, frame);
		double t1 = now();
		publish(0, ++seq);
		printf("card published as seq %u (copy %.1f ms = %.0f MB/s)\n", seq,
		       (t1 - t0) * 1e3, W * H * 4 / (t1 - t0) / 1e6);
		return 0;
	}

	if (!strcmp(mode, "anim")) {
		double secs = argc > 2 ? atof(argv[2]) : 20;
		uint32_t last = stat->field_cnt;
		int buf = 0, t = 0, late = 0;
		double t0 = now(), tcopy = 0;
		while (now() - t0 < secs) {
			buf ^= 1;
			draw_anim(frame, t);
			double a = now();
			copy_frame(buf, frame);
			tcopy += now() - a;
			uint32_t before = stat->field_cnt;
			wait_field(&last);
			if (last - before > 1) late++;
			publish(buf, ++seq);
			t++;
		}
		printf("%d frames in %.1fs (%.1f/s), avg copy %.1f ms, %d late\n",
		       t, now() - t0, t / (now() - t0), tcopy / t * 1e3, late);
		return 0;
	}

	if (!strcmp(mode, "avi")) {
		g_fps = argc > 2 ? atof(argv[2]) : 23.976;
		g_yuv = 1;
		if (getenv("PLEXFB_ALEAD")) g_alead = atof(getenv("PLEXFB_ALEAD"));
		if (getenv("PLEXFB_AOFF"))  g_aoff  = atof(getenv("PLEXFB_AOFF"));
		if (getenv("PLEXFB_ACATCH")) g_acatch = atof(getenv("PLEXFB_ACATCH"));
		g_scale_c = getenv("PLEXFB_SCALE_C") != NULL;
		if (getenv("PLEXFB_GEOMETRY") && !parse_screen(getenv("PLEXFB_GEOMETRY"), &g_screen))
			fprintf(stderr, "plexfb: PLEXFB_GEOMETRY \"%s\" not understood, using the whole screen\n",
			        getenv("PLEXFB_GEOMETRY"));
		g_crop_file = getenv("PLEXFB_CROP_FILE");
		if (g_crop_file && *g_crop_file) {
			int c = read_crop(g_crop_file);
			if (c >= 0) g_crop = c;
			else fprintf(stderr, "plexfb: %s names no crop (off, 14:9 or fill), not cropping\n", g_crop_file);
		} else
			g_crop_file = NULL;
		if (fcntl(0, F_SETPIPE_SZ, 4 << 20) < 0) perror("F_SETPIPE_SZ (ignored)");
		signal(SIGUSR1, on_usr1);
		signal(SIGUSR2, on_usr2);
		signal(SIGTERM, on_term);
		signal(SIGINT, on_term);
		if (hdr->magic == MAGIC) ring_base = ring_filled = ring_shown = (hdr->buf + 1) % RING;
		afifo = malloc(AFIFO_BYTES);
		write_status(0, 0);            /* "starting": the UI stops drawing now */
		aplay = getenv("PLEXFB_MUTE") ? fopen("/dev/null", "w")
		      : popen("aplay -q -t raw -f S16_LE -c 2 -r 48000 --buffer-size=4800 -", "w");
		if (!aplay) { perror("aplay"); return 1; }
		pthread_t tr, ta;
		pthread_create(&tr, NULL, avi_reader, NULL);
		pthread_create(&ta, NULL, audio_thread, NULL);
		present_loop(g_fps, seq);
		pthread_join(ta, NULL);
		if (getenv("PLEXFB_MUTE")) fclose(aplay); else pclose(aplay);
		return 0;
	}

	if (!strcmp(mode, "raw")) {
		double fps = argc > 2 ? atof(argv[2]) : 29.97;
		g_yuv = argc > 3 && !strcmp(argv[3], "yuv");
		if (fcntl(0, F_SETPIPE_SZ, 4 << 20) < 0) perror("F_SETPIPE_SZ (ignored)");
		signal(SIGUSR1, on_usr1);
		signal(SIGTERM, on_term);
		signal(SIGINT, on_term);
		pthread_t th;
		pthread_create(&th, NULL, reader_thread, NULL);
		present_loop(fps, seq);
		return 0;
	}

	fprintf(stderr, "usage: plexfb card|anim [s]|raw [fps]|avi [fps]|status\n");
	return 2;
}
#endif
