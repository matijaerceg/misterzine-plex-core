/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Checks the presenter's picture geometry and scaler (arm/plexfb.c) without
 * MiSTer hardware: where each frame shape lands on the 4:3 raster, that the
 * scaler keeps flat colour flat, ramps monotonic and borders black, that a
 * 720x480 frame passes through untouched, and (built for the ARM) that the
 * NEON path gives exactly the bytes of the plain C one.
 *
 *   cc -O2 -Wall -Wno-unused-function -pthread -o plexfb_scale_test tools/plexfb_scale_test.c -lm
 *   ./plexfb_scale_test [time]
 */
#define PLEXFB_TEST
#include "../arm/plexfb.c"

static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("FAIL line %d: ", __LINE__); \
	printf(__VA_ARGS__); printf("\n"); } } while (0)

#define SLOT_BYTES (W * H * 3 / 2)

static void fits(int w, int h, double aspect, int ex, int ey, int ew, int eh)
{
	static struct geometry g;
	geometry_setup(&g, w, h, aspect);
	const struct plane_map *p = &g.p[0];
	CHECK(p->dx == ex && p->dy == ey && p->dw == ew && p->dh == eh,
	      "%dx%d aspect %.4f in %d,%d,%d,%d width %d -> %dx%d at %d,%d, expected %dx%d at %d,%d",
	      w, h, aspect, g_screen.l, g_screen.t, g_screen.r, g_screen.b, g_screen.width,
	      p->dw, p->dh, p->dx, p->dy, ew, eh, ex, ey);
	const struct plane_map *u = &g.p[1];
	CHECK(u->dx == ex / 2 && u->dy == ey / 2 && u->dw == ew / 2 && u->dh == eh / 2,
	      "%dx%d chroma rectangle %dx%d at %d,%d", w, h, u->dw, u->dh, u->dx, u->dy);
}

/* tools/testdata/fit_cases.txt, which the app's Go tests read too (found
   beside this source, or at PLEXFB_FIT_CASES when the test runs elsewhere) */
static void fit_cases(void)
{
	char path[1024];
	const char *slash = strrchr(__FILE__, '/');
	snprintf(path, sizeof path, "%.*stestdata/fit_cases.txt", slash ? (int)(slash - __FILE__ + 1) : 0, __FILE__);
	if (getenv("PLEXFB_FIT_CASES")) snprintf(path, sizeof path, "%s", getenv("PLEXFB_FIT_CASES"));
	FILE *f = fopen(path, "r");
	CHECK(f != NULL, "cannot open %s", path);
	if (!f) return;
	char line[256];
	int n = 0;
	while (fgets(line, sizeof line, f)) {
		struct screen s;
		double num, den;
		int lines, x, y, w, h;
		if (sscanf(line, "%d %d %d %d %d %lf/%lf %d %d %d %d %d", &s.l, &s.t, &s.r, &s.b, &s.width,
		           &num, &den, &lines, &x, &y, &w, &h) != 12) continue;
		char text[64];
		snprintf(text, sizeof text, "%d,%d,%d,%d,%d", s.l, s.t, s.r, s.b, s.width);
		CHECK(parse_screen(text, &g_screen), "%s: not accepted", text);
		/* a frame of that many lines; its width does not move it */
		int fw = 2 * (int)lround(lines * num / den / 2);
		fits(fw < 16 ? 16 : fw > MAX_SRC_W ? MAX_SRC_W : fw, lines, num / den, x, y, w, h);
		n++;
	}
	fclose(f);
	CHECK(n >= 30, "only %d fit cases read from %s", n, path);
	g_screen = (struct screen){ 0, 0, 0, 0, 1000 };
}

/* fit() as it was before calibration (commit 71cfd60^) */
static void old_fit(double aspect, int sh, int *dx, int *dy, int *dw, int *dh)
{
	int w = W, h = H;
	if (aspect > 4.0 / 3.0) h = 2 * (int)lround(H * (4.0 / 3.0) / aspect / 2);
	else                    w = 2 * (int)lround(W * aspect / (4.0 / 3.0) / 2);
	if (w < 16) w = 16;
	if (h < 16) h = 16;
	if (w >= W - W / 60) w = W;
	if (!(sh & 1) && sh <= H && abs(h - sh) <= H / 50) h = sh;
	*dw = w; *dh = h; *dx = (W - w) / 2 & ~1; *dy = (H - h) / 2 & ~1;
}

/* Without calibration every frame the presenter accepts (even sizes up to
   1920x1088, square pixels, plus the common anamorphic aspects) lands
   exactly where it did before calibration existed. */
static void default_unchanged(void)
{
	g_screen = (struct screen){ 0, 0, 0, 0, 1000 };
	static const double aspects[] = { 0, 4.0 / 3.0, 16.0 / 9.0, 1.85, 2.39 };   /* 0: square pixels */
	int same = 0, other = 0;
	for (int sh = 16; sh <= MAX_SRC_H; sh += 2)
		for (int sw = 16; sw <= MAX_SRC_W; sw += 2)
			for (unsigned i = 0; i < sizeof aspects / sizeof *aspects; i++) {
				if (i && sw != 720) continue;       /* anamorphic: DVD width, any height */
				double a = i ? aspects[i] : (double)sw / sh;
				int ox, oy, ow, oh, x, y, w, h;
				old_fit(a, sh, &ox, &oy, &ow, &oh);
				fit(&g_screen, a, sh, &x, &y, &w, &h);
				if (ox == x && oy == y && ow == w && oh == h) { same++; continue; }
				if (other++ < 5) printf("  %dx%d aspect %.4f: was %dx%d at %d,%d, now %dx%d at %d,%d\n",
				                        sw, sh, a, ow, oh, ox, oy, w, h, x, y);
			}
	CHECK(!other && same > 500000, "default placement changed for %d frame shapes (%d unchanged)", other, same);
}

/* tools/testdata/crop_cases.txt, which the app's Go tests read too (beside
   this source, or at PLEXFB_CROP_CASES) */
static void crop_cases(void)
{
	char path[1024];
	const char *slash = strrchr(__FILE__, '/');
	snprintf(path, sizeof path, "%.*stestdata/crop_cases.txt", slash ? (int)(slash - __FILE__ + 1) : 0, __FILE__);
	if (getenv("PLEXFB_CROP_CASES")) snprintf(path, sizeof path, "%s", getenv("PLEXFB_CROP_CASES"));
	FILE *f = fopen(path, "r");
	CHECK(f != NULL, "cannot open %s", path);
	if (!f) return;
	char line[256];
	int n = 0;
	while (fgets(line, sizeof line, f)) {
		struct screen s;
		char name[8];
		double num, den;
		int fw, fh, x, y, w, h, cx, cy, cw, ch;
		if (sscanf(line, "%d %d %d %d %d %7s %d %d %lf/%lf %d %d %d %d", &s.l, &s.t, &s.r, &s.b, &s.width,
		           name, &fw, &fh, &num, &den, &x, &y, &w, &h) != 14) continue;
		char text[64];
		snprintf(text, sizeof text, "%d,%d,%d,%d,%d", s.l, s.t, s.r, s.b, s.width);
		CHECK(parse_screen(text, &g_screen), "%s: not accepted", text);
		int mode = parse_crop(name);
		CHECK(mode >= 0, "crop \"%s\" not understood", name);
		if (mode < 0) continue;
		crop_rect(mode, &g_screen, fw, fh, num / den, &cx, &cy, &cw, &ch);
		CHECK(cx == x && cy == y && cw == w && ch == h, "%s %s %dx%d aspect %.4f: kept %dx%d at %d,%d, expected %dx%d at %d,%d",
		      text, name, fw, fh, num / den, cw, ch, cx, cy, w, h, x, y);
		/* what fill cuts, it fits to the whole area: no border at all */
		static struct geometry g;
		g_crop = mode;
		geometry_setup(&g, fw, fh, num / den);
		g_crop = CROP_OFF;
		const struct plane_map *p = &g.p[0];
		if (mode == CROP_FILL && (w < fw || h < fh))
			CHECK(p->dx == s.l && p->dy == s.t && p->dw == W - s.l - s.r && p->dh == H - s.t - s.b,
			      "%s fill %dx%d: %dx%d at %d,%d, not the area", text, fw, fh, p->dw, p->dh, p->dx, p->dy);
		CHECK(p->cx == cx && p->cy == cy && p->cw == cw && p->ch == ch && g.p[1].cx == cx / 2 && g.p[1].cy == cy / 2,
		      "%s %s %dx%d: planes not set to the kept part", text, name, fw, fh);
		n++;
	}
	fclose(f);
	CHECK(n >= 20, "only %d crop cases read from %s", n, path);
	g_screen = (struct screen){ 0, 0, 0, 0, 1000 };
}

static void crop_words(void)
{
	CHECK(parse_crop("off") == CROP_OFF && parse_crop("14:9\n") == CROP_14_9 && parse_crop("  fill \n") == CROP_FILL,
	      "a crop name not understood");
	const char *bad[] = { "", "\n", "Fill", "fill x", "14:9x", "4:3", "fillfillfill" };
	for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++)
		CHECK(parse_crop(bad[i]) == -1, "crop \"%s\" understood", bad[i]);
	char path[] = "/tmp/plexfb_crop_XXXXXX";
	int fd = mkstemp(path);
	CHECK(fd >= 0 && write(fd, "fill\n", 5) == 5, "cannot write %s", path);
	if (fd >= 0) close(fd);
	CHECK(read_crop(path) == CROP_FILL, "crop file not read");
	unlink(path);
	CHECK(read_crop(path) == -1, "a missing crop file read");
}

static void fill_random(uint8_t *f, int w, int h, unsigned seed);

static void set_crop_file(const char *path, const char *text)
{
	FILE *f = fopen(path, "w");
	if (f) { fputs(text, f); fclose(f); }
}

/* which ring slots differ from `before`, as a bit mask */
static unsigned slots_changed(const uint8_t *before)
{
	unsigned mask = 0;
	for (unsigned i = 0; i < RING; i++)
		if (memcmp(before + i * SLOT_BYTES, map + BUF_OFF(i), SLOT_BYTES)) mask |= 1u << i;
	return mask;
}

/* each ring slot from `from` up to ring_filled holds its RAM frame at the current geometry */
static int slots_scaled(unsigned from, uint8_t *want)
{
	int stale = 0;
	for (unsigned i = from; i != ring_filled; i++) {
		scale_frame(&g_geo, ram_slot(i % RING), want);
		stale += memcmp(want, map + BUF_OFF(i % RING), SLOT_BYTES) != 0;
	}
	return stale;
}

static void ring_copy(uint8_t *before)
{
	for (unsigned i = 0; i < RING; i++) memcpy(before + i * SLOT_BYTES, map + BUF_OFF(i), SLOT_BYTES);
}

/* A crop change while the picture stands still (paused, or waiting for the
   decoder) scales the frames in the ring again from the ones kept in RAM,
   the one on screen included, never the slot a previous presenter left up;
   while frames flow only the geometry changes, and the frames queued with
   the old crop are brought up to date if the picture stops before they
   show. It needs nothing from the reader: the presenter thread follows. */
static void crop_follow_ring(void)
{
	static uint8_t mem[0x7E0000];
	uint8_t *want = malloc(SLOT_BYTES), *before = malloc(SLOT_BYTES * RING);
	int w = 720, h = 404;
	map = mem;
	g_screen = (struct screen){ 0, 0, 0, 0, 1000 };
	g_crop = CROP_OFF;
	geometry_setup(&g_geo, w, h, 720.0 / 404);
	g_geo_ready = 1;
	memset(map + BUF_OFF(0), 0x5A, SLOT_BYTES);          /* the previous presenter's frame */
	ring_base = 1; ring_shown = 2; ring_filled = 4;       /* slot 1 on screen, 2 and 3 ahead */
	for (unsigned i = 1; i < 4; i++) {
		fill_random(ram_slot(i), w, h, i);
		scale_frame(&g_geo, ram_slot(i), map + BUF_OFF(i));
		slot_gen[i] = g_geo_gen;
	}
	char path[] = "/tmp/plexfb_crop_XXXXXX";
	int fd = mkstemp(path);
	if (fd >= 0) close(fd);
	g_crop_file = path;

	/* paused */
	set_crop_file(path, "fill\n");
	g_pause = 1;
	crop_follow();
	int touched = 0;
	for (size_t i = 0; i < SLOT_BYTES; i++) touched += map[BUF_OFF(0) + i] != 0x5A;
	CHECK(g_crop == CROP_FILL && g_geo.p[0].cw == 538 && g_geo.p[0].dw == W && g_geo.p[0].dh == H,
	      "paused: crop %d, %d wide -> %dx%d", g_crop, g_geo.p[0].cw, g_geo.p[0].dw, g_geo.p[0].dh);
	int stale = slots_scaled(1, want);
	CHECK(!stale && !touched, "paused: %d ring frames not scaled again, %d bytes of the old frame touched", stale, touched);

	/* playing, frames ahead: they keep the crop they have */
	ring_copy(before);
	set_crop_file(path, "14:9\n");
	g_pause = 0;
	usleep(120000);                                       /* it looks every 0.1 s */
	crop_follow();
	unsigned moved = slots_changed(before);
	CHECK(g_crop == CROP_14_9 && g_geo.p[0].cw == 628 && !moved, "playing: crop %d, %d wide, ring slots %x rewritten",
	      g_crop, g_geo.p[0].cw, moved);

	/* those frames show and the decoder stalls, the file unchanged: the last
	   one, on screen with the old crop, is brought up to date */
	ring_shown = 4;
	ring_copy(before);
	crop_follow();
	moved = slots_changed(before);
	stale = slots_scaled(3, want);
	CHECK(moved == 1u << 3 && !stale, "drained, then stalled: slots %x rewritten, %d stale", moved, stale);

	/* a change with frames queued, then a pause before they show, the file
	   unchanged since: all of them, and the one on screen, catch up */
	ring_shown = 2;
	set_crop_file(path, "off\n");
	usleep(120000);
	crop_follow();                                        /* noted while playing */
	ring_copy(before);
	g_pause = 1;
	crop_follow();
	moved = slots_changed(before);
	stale = slots_scaled(1, want);
	touched = 0;
	for (size_t i = 0; i < SLOT_BYTES; i++) touched += map[BUF_OFF(0) + i] != 0x5A;
	CHECK(g_crop == CROP_OFF && moved == 0xE && !stale && !touched,
	      "queued, then paused: slots %x rewritten, %d stale, %d bytes of the old frame touched", moved, stale, touched);

	/* standing still with nothing out of date: nothing is written */
	ring_copy(before);
	crop_follow();
	CHECK(!slots_changed(before), "standing still: slots %x rewritten", slots_changed(before));

	/* before the reader has read the stream's header the crop is only noted */
	g_geo_ready = 0;
	ring_copy(before);
	set_crop_file(path, "fill\n");
	usleep(120000);
	crop_follow();
	CHECK(g_crop == CROP_FILL && g_geo.p[0].cw == 720 && !slots_changed(before),
	      "before the header: crop %d, geometry or ring changed", g_crop);

	unlink(path);
	g_crop_file = NULL; g_crop = CROP_OFF; g_pause = 0; g_geo_ready = 0;
	ring_base = ring_shown = ring_filled = 0;
	map = NULL;
	free(want); free(before);
}

static void screen_settings(void)
{
	struct screen s = { 0, 0, 0, 0, 1000 };
	const char *bad[] = { "", "1,0,0,0,1000", "0,0,0,0,849", "0,0,0,0,1151", "122,0,0,0,1000",
	                      "0,82,0,0,1000", "-2,0,0,0,1000", "0,0,0,0", "0,0,0,0,1000x", "0,0,0,0,1000,4" };
	for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++)
		CHECK(!parse_screen(bad[i], &s) && s.width == 1000, "PLEXFB_GEOMETRY \"%s\" accepted", bad[i]);
	CHECK(parse_screen("120,80,120,80,1150", &s) && s.l == 120 && s.b == 80 && s.width == 1150, "the limits refused");
	CHECK(parse_screen("0,0,0,0,850", &s) && s.width == 850, "the narrowest width refused");
}

static uint8_t *frame_new(int w, int h)
{
	uint8_t *f = malloc(RAM_BYTES);
	memset(f, 0xAA, RAM_BYTES);      /* slack past the frame is garbage on purpose */
	(void)w; (void)h;
	return f;
}

static size_t chroma_bytes(int w, int h) { return (size_t)((w + 1) / 2) * ((h + 1) / 2); }

static void fill_random(uint8_t *f, int w, int h, unsigned seed)
{
	size_t n = (size_t)w * h + 2 * chroma_bytes(w, h);
	for (size_t i = 0; i < n; i++) { seed = seed * 1103515245u + 12345u; f[i] = (uint8_t)(seed >> 16); }
}

/* output plane pointers in a slot */
static uint8_t *out_y(uint8_t *s) { return s; }
static uint8_t *out_u(uint8_t *s) { return s + W * H; }
static uint8_t *out_v(uint8_t *s) { return s + W * H + (W / 2) * (H / 2); }

static void flat_and_borders(int w, int h, double aspect)
{
	static struct geometry g;
	geometry_setup(&g, w, h, aspect);
	uint8_t *f = frame_new(w, h), *slot = malloc(SLOT_BYTES);
	size_t y = (size_t)w * h, c = chroma_bytes(w, h);
	memset(f, 100, y); memset(f + y, 90, c); memset(f + y + c, 160, c);
	scale_frame(&g, f, slot);
	const struct plane_map *p = &g.p[0], *q = &g.p[1];
	int bad_pic = 0, bad_border = 0;
	for (int r = 0; r < H; r++)
		for (int x = 0; x < W; x++) {
			int in = r >= p->dy && r < p->dy + p->dh && x >= p->dx && x < p->dx + p->dw;
			uint8_t v = out_y(slot)[r * W + x];
			if (in ? v != 100 : v != 16) { if (in) bad_pic++; else bad_border++; }
		}
	for (int r = 0; r < H / 2; r++)
		for (int x = 0; x < W / 2; x++) {
			int in = r >= q->dy && r < q->dy + q->dh && x >= q->dx && x < q->dx + q->dw;
			uint8_t u = out_u(slot)[r * (W / 2) + x], v = out_v(slot)[r * (W / 2) + x];
			if (in ? (u != 90 || v != 160) : (u != 128 || v != 128)) { if (in) bad_pic++; else bad_border++; }
		}
	CHECK(!bad_pic && !bad_border, "%dx%d flat frame (crop %s): %d picture and %d border samples off",
	      w, h, crop_names[g_crop], bad_pic, bad_border);
	free(f); free(slot);
}

static void ramps(int w, int h, double aspect)
{
	static struct geometry g;
	geometry_setup(&g, w, h, aspect);
	uint8_t *f = frame_new(w, h), *slot = malloc(SLOT_BYTES);
	size_t y = (size_t)w * h, c = chroma_bytes(w, h);
	for (int r = 0; r < h; r++)                 /* luma ramps left to right, chroma top to bottom */
		for (int x = 0; x < w; x++) f[(size_t)r * w + x] = (uint8_t)(16 + x * 219 / (w - 1));
	int cw = (w + 1) / 2, ch = (h + 1) / 2;
	for (int r = 0; r < ch; r++)
		for (int x = 0; x < cw; x++) f[y + (size_t)r * cw + x] = f[y + c + (size_t)r * cw + x] = (uint8_t)(16 + r * 224 / (ch - 1));
	scale_frame(&g, f, slot);
	const struct plane_map *p = &g.p[0], *q = &g.p[1];
	int back = 0;
	for (int r = p->dy; r < p->dy + p->dh; r++)
		for (int x = p->dx + 1; x < p->dx + p->dw; x++)
			if (out_y(slot)[r * W + x] < out_y(slot)[r * W + x - 1]) back++;
	for (int x = q->dx; x < q->dx + q->dw; x++)
		for (int r = q->dy + 1; r < q->dy + q->dh; r++)
			if (out_u(slot)[r * (W / 2) + x] < out_u(slot)[(r - 1) * (W / 2) + x]) back++;
	uint8_t first = out_y(slot)[p->dy * W + p->dx], last = out_y(slot)[p->dy * W + p->dx + p->dw - 1];
	/* the picture's ends are the kept part's (16..235 for the whole frame):
	   exactly, or within a step where a shrink blends in the neighbour */
	int lo = f[p->cx], hi = f[p->cx + p->cw - 1];
	int ends = p->cw <= p->dw ? first == lo && last == hi : abs(first - lo) <= 1 && abs(last - hi) <= 1;
	if (p->cw == w) ends = ends && lo == 16 && hi == 235;
	CHECK(!back && ends, "%dx%d ramps (crop %s): %d steps backwards, ends %u..%u of %d..%d",
	      w, h, crop_names[g_crop], back, first, last, lo, hi);
	free(f); free(slot);
}

static void passthrough(void)
{
	static struct geometry g;
	geometry_setup(&g, W, H, 4.0 / 3.0);
	uint8_t *f = frame_new(W, H), *slot = malloc(SLOT_BYTES);
	fill_random(f, W, H, 7);
	scale_frame(&g, f, slot);
	CHECK(!memcmp(f, slot, SLOT_BYTES), "720x480 4:3 frame is not passed through unchanged");
	free(f); free(slot);
}

static void neon_matches_c(int w, int h, double aspect)
{
	static struct geometry g;
	geometry_setup(&g, w, h, aspect);
	uint8_t *f = frame_new(w, h), *a = malloc(SLOT_BYTES), *b = malloc(SLOT_BYTES);
	fill_random(f, w, h, (unsigned)(w * 31 + h));
	g_scale_c = 0; scale_frame(&g, f, a);
	g_scale_c = 1; scale_frame(&g, f, b);
	g_scale_c = 0;
	size_t diff = 0;
	for (size_t i = 0; i < SLOT_BYTES; i++) diff += a[i] != b[i];
	CHECK(!diff, "%dx%d: NEON and C differ in %zu bytes", w, h, diff);
	free(f); free(a); free(b);
}

static void wr32(uint8_t *p, uint32_t v) { p[0] = v; p[1] = v >> 8; p[2] = v >> 16; p[3] = v >> 24; }

static int strf(int32_t w, int32_t h, int bits, const char *fourcc, uint32_t sz, int *ow, int *oh)
{
	uint8_t b[40] = { 0 };
	wr32(b, 40); wr32(b + 4, (uint32_t)w); wr32(b + 8, (uint32_t)h);
	b[12] = 1; b[14] = (uint8_t)bits; memcpy(b + 16, fourcc, 4);
	*ow = *oh = -1;
	return parse_strf(b, sz, ow, oh);
}

static void headers(void)
{
	int w, h;
	CHECK(strf(644, 480, 12, "I420", 40, &w, &h) && w == 644 && h == 480, "I420 644x480 not taken: %dx%d", w, h);
	CHECK(strf(640, -480, 12, "IYUV", 40, &w, &h) && w == 640 && h == 480, "top-down IYUV not taken: %dx%d", w, h);
	CHECK(!strf(640, INT32_MIN, 12, "I420", 40, &w, &h), "height -2^31 taken");
	CHECK(!strf(640, 480, 12, "YV12", 40, &w, &h), "YV12 (swapped planes) taken");
	CHECK(!strf(640, 480, 24, "I420", 40, &w, &h), "24 bits taken");
	CHECK(!strf(4096, 2160, 12, "I420", 40, &w, &h), "4096x2160 taken");
	CHECK(!strf(8, 8, 12, "I420", 40, &w, &h), "8x8 taken");
	CHECK(!strf(640, 480, 12, "I420", 16, &w, &h), "short strf taken");
	uint8_t v[36] = { 0 };
	wr32(v + 20, 16u << 16 | 9);
	CHECK(fabs(parse_vprp(v, 36) - 16.0 / 9.0) < 1e-9, "vprp 16:9 read as %f", parse_vprp(v, 36));
	CHECK(parse_vprp(v, 20) == 0, "short vprp read");
	wr32(v + 20, 0);
	CHECK(parse_vprp(v, 36) == 0, "vprp without an aspect read");
}

/* a crop rectangle (a zoom, later): only the rectangle's pixels reach the screen */
static void crop(void)
{
	static struct plane_map m;
	int w = 640, h = 360;
	uint8_t *f = frame_new(w, h), *out = malloc(W * H);
	for (int r = 0; r < h; r++)
		for (int x = 0; x < w; x++) f[(size_t)r * w + x] = (uint8_t)(x * 255 / (w - 1));
	/* the middle 480x360 of a 16:9 frame, filling the 4:3 screen */
	plane_setup(&m, w, h, 80, 0, 480, 360, 0, 0, W, H, W, H, 16);
	scale_plane(&m, f, out);
	uint8_t lo = f[80], hi = f[80 + 479];
	int outside = 0, back = 0;
	for (int r = 0; r < H; r++)
		for (int x = 0; x < W; x++) {
			uint8_t v = out[r * W + x];
			if (v < lo || v > hi) outside++;
			if (x && v < out[r * W + x - 1]) back++;
		}
	CHECK(!outside && !back && out[0] == lo && out[W - 1] == hi, "crop: %d samples outside %u..%u, %d backwards, ends %u..%u",
	      outside, lo, hi, back, out[0], out[W - 1]);
	free(f); free(out);
}

static void timing(int w, int h, double aspect)
{
	static struct geometry g;
	geometry_setup(&g, w, h, aspect);
	uint8_t *f = frame_new(w, h), *slot = malloc(SLOT_BYTES);
	fill_random(f, w, h, 3);
	for (int c = 0; c < 2; c++) {
		g_scale_c = c;
		double t = now();
		for (int i = 0; i < 50; i++) scale_frame(&g, f, slot);
		printf("  %dx%d crop %s -> %dx%d: %s %.2f ms/frame\n", w, h, crop_names[g_crop], g.p[0].dw, g.p[0].dh,
		       c ? "C   " : "fast", (now() - t) * 1e3 / 50);
	}
	g_scale_c = 0;
	free(f); free(slot);
}

/* the core's vsync write, 10 ms from now: field counter, then status word */
static volatile uint32_t core_page[1024];
static uint32_t core_status_next;
static void *core_writes(void *arg)
{
	(void)arg;
	usleep(10000);
	core_page[STAT_OFF / 4] = 1236;
	core_page[0x6c / 4] = core_status_next;
	return NULL;
}

static int core_after_write(uint32_t status)
{
	pthread_t t;
	core_status_next = status;
	pthread_create(&t, NULL, core_writes, NULL);
	int running = core_running(core_page, 100);
	pthread_join(t, NULL);
	return running;
}

/* the presenter enlarges the mode and blanks on exit only for a running core */
static void core_detection(void)
{
	CHECK(!core_running(core_page, 20), "an empty page read as a running core");
	core_page[STAT_OFF / 4] = 1234;
	core_page[0x6c / 4] = 0x56500001;
	CHECK(!core_running(core_page, 20), "a counter left behind by a core that has gone read as running");
	core_page[STAT_OFF / 4] = core_page[0x6c / 4] = 0;   /* a mode write */
	CHECK(core_after_write(0x56500001), "a core writing again after a mode write was not seen");
	core_page[STAT_OFF / 4] = core_page[0x6c / 4] = 0;
	CHECK(!core_after_write(0), "a counter without the status signature read as running");
}

int main(int argc, char **argv)
{
	core_detection();

	/* frame shapes Plex sends and a few it could, on the whole raster and in
	   calibrated picture areas */
	fit_cases();
	default_unchanged();
	fits(640, 480, 0, 0, 0, 720, 480);                  /* no aspect in the header: square pixels */
	fits(720, 480, 4.0 / 3.0, 0, 0, 720, 480);          /* 4:3 DVD, aspect from the header */
	fits(720, 480, 16.0 / 9.0, 0, 60, 720, 360);        /* anamorphic 16:9 DVD */
	screen_settings();

	crop_cases();
	crop_words();
	crop_follow_ring();

	headers();
	crop();
	passthrough();
	int shapes[][2] = { {640, 480}, {644, 480}, {720, 404}, {720, 306}, {480, 360}, {576, 480}, {270, 480},
	                    {642, 482}, {641, 481}, {1280, 720}, {352, 240} };
	/* the whole raster, then calibrated areas: edges in, both axes resampled;
	   a narrow one, where fill cuts the sides of 4:3 too; each crop in each */
	struct screen areas[] = { { 0, 0, 0, 0, 1000 }, { 16, 12, 18, 10, 985 }, { 120, 0, 120, 0, 1000 } };
	for (unsigned a = 0; a < sizeof areas / sizeof *areas; a++) {
		g_screen = areas[a];
		for (g_crop = CROP_OFF; g_crop <= CROP_FILL; g_crop++) {
			for (unsigned i = 0; i < sizeof shapes / sizeof *shapes; i++) {
				int w = shapes[i][0], h = shapes[i][1];
				flat_and_borders(w, h, (double)w / h);
				ramps(w, h, (double)w / h);
				neon_matches_c(w, h, (double)w / h);
			}
			neon_matches_c(720, 480, 16.0 / 9.0);
		}
		g_crop = CROP_OFF;
	}
	g_screen = areas[0];
#ifdef HAVE_NEON
	printf("NEON build\n");
#endif
	if (argc > 1 && !strcmp(argv[1], "time")) {
		timing(640, 480, 4.0 / 3.0);
		timing(644, 480, 644.0 / 480);
		timing(720, 404, 720.0 / 404);
		timing(640, 360, 16.0 / 9.0);
		g_crop = CROP_FILL;
		timing(720, 404, 720.0 / 404);
		timing(720, 300, 720.0 / 300);
		g_crop = CROP_OFF;
	}
	printf("%d checks, %d failed\n", checks, fails);
	return fails != 0;
}
