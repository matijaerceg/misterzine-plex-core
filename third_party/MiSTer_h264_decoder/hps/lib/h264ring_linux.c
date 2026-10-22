/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* hps/lib/h264ring_linux.c -- the MiSTer backend: /dev/mem, the lock, launching the core.
 * docs/architecture.md "The HPS interface, v0.1" ("The ARM side", "Launch, and two programs").
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <linux/fb.h>
#include <sys/file.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include "h264ring.h"
#include "h264ring_priv.h"

#define REGION_BYTE H264RING_CTRL_BYTE
#define REGION_LEN  (H264RING_RING_BYTE + H264RING_RING_SIZE - H264RING_CTRL_BYTE)
#define LOCK_PATH   "/tmp/h264ring.lock"

#define STORES_LEN  ((size_t)H264RING_DPB_STORES * H264RING_DPB_STORE)   /* (0.15) the DPB's stores */

/* never map a range Linux uses: /proc/iomem's "System RAM" lines (dvd-core's rule) */
static int range_is_free(unsigned long base, unsigned long len)
{
    FILE *f = fopen("/proc/iomem", "r");
    char line[256];
    int ok = 1;
    if (!f)
        return 1;                         /* no iomem (not Linux?): nothing to check against */
    while (fgets(line, sizeof line, f)) {
        unsigned long a, b;
        if (line[0] == ' ' || !strstr(line, "System RAM"))
            continue;
        if (sscanf(line, "%lx-%lx", &a, &b) == 2 &&
            !(b < base || a >= base + len))
            ok = 0;
    }
    fclose(f);
    return ok;
}
static int region_is_free(void) { return range_is_free(REGION_BYTE, REGION_LEN); }

static void devmem_release(h264ring *r)
{
    if (r->map)
        munmap(r->map, r->map_len);
    if (r->smap)
        munmap(r->smap, r->smap_len);
    if (r->mem_fd >= 0)
        close(r->mem_fd);
    if (r->lock_fd >= 0)
        close(r->lock_fd);                /* releases the flock */
}

int h264ring_open_devmem(h264ring **out, unsigned flags)
{
    struct h264ring_backend be;
    int fd, lfd = -1, rc;
    void *map, *smap = NULL;
    *out = NULL;
    if (!region_is_free() || ((flags & H264RING_OPEN_PICTURES) && !range_is_free(H264RING_DPB_BYTE, STORES_LEN)))
        return -EFAULT;
    if (!(flags & H264RING_OPEN_NOLOCK)) {
        lfd = open(LOCK_PATH, O_RDWR | O_CREAT | O_CLOEXEC, 0666);
        if (lfd < 0)
            return -errno;
        if (flock(lfd, LOCK_EX | LOCK_NB) < 0) {
            close(lfd);
            return -EBUSY;                /* another program feeds the core */
        }
    }
    fd = open("/dev/mem", O_RDWR | O_SYNC | O_CLOEXEC);   /* O_SYNC: an uncached mapping */
    if (fd < 0) {
        rc = -errno;
        if (lfd >= 0) close(lfd);
        return rc;
    }
    map = mmap(NULL, REGION_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, REGION_BYTE);
    if (map == MAP_FAILED) {
        rc = -errno;
        close(fd);
        if (lfd >= 0) close(lfd);
        return rc;
    }
    if (flags & H264RING_OPEN_PICTURES) {  /* (0.15) the stores: strongly ordered too (not System RAM) */
        smap = mmap(NULL, STORES_LEN, PROT_READ | PROT_WRITE, MAP_SHARED, fd, H264RING_DPB_BYTE);
        if (smap == MAP_FAILED) {
            rc = -errno;
            munmap(map, REGION_LEN);
            close(fd);
            if (lfd >= 0) close(lfd);
            return rc;
        }
    }
    memset(&be, 0, sizeof be);
    be.stores = (volatile uint64_t *)smap;
    be.ctrl = (volatile uint64_t *)map;
    be.ring = (volatile uint64_t *)((char *)map + (H264RING_RING_BYTE - H264RING_CTRL_BYTE));
    be.ring_size = H264RING_RING_SIZE;
    rc = h264ring_attach(out, &be);
    if (rc) {
        if (smap)
            munmap(smap, STORES_LEN);
        munmap(map, REGION_LEN);
        close(fd);
        if (lfd >= 0) close(lfd);
        return rc;
    }
    (*out)->mem_fd = fd;
    (*out)->lock_fd = lfd;
    (*out)->map = map;
    (*out)->map_len = REGION_LEN;
    (*out)->smap = smap;
    (*out)->smap_len = smap ? STORES_LEN : 0;
    (*out)->release = devmem_release;
    return 0;
}

static int corename_is(const char *want)
{
    char buf[64] = {0};
    FILE *f = fopen("/tmp/CORENAME", "r");
    if (!f)
        return 0;
    if (!fgets(buf, sizeof buf, f))
        buf[0] = 0;
    fclose(f);
    buf[strcspn(buf, "\r\n")] = 0;
    return strcmp(buf, want) == 0;
}

/* the core is loaded: CORENAME is the name an app's build gives it, or, without one,
 * the core's own name */
static int core_loaded(const char *core_name)
{
    if (core_name && *core_name)
        return corename_is(core_name);
    return corename_is("H264");
}

int h264ring_launch_core(const char *rbf, unsigned timeout_ms)
{
    return h264ring_launch_core_as(rbf, NULL, timeout_ms);
}

int h264ring_launch_core_as(const char *rbf, const char *core_name, unsigned timeout_ms)
{
    const char *mgl = "/tmp/h264ring.mgl";
    FILE *f;
    int fd;
    char cmd[128];
    struct timespec ts;
    if (core_loaded(core_name))
        return 0;
    f = fopen(mgl, "w");
    if (!f)
        return -errno;
    fprintf(f, "<mistergamedescription>\n  <rbf>%s</rbf>\n</mistergamedescription>\n",
            rbf ? rbf : "_Other/H264");
    fclose(f);
    /* one command per write (Main reads the FIFO a write at a time: docs/mgl_launch.md) */
    fd = open("/dev/MiSTer_cmd", O_WRONLY | O_NONBLOCK | O_CLOEXEC);
    if (fd < 0)
        return -errno;
    snprintf(cmd, sizeof cmd, "load_core %s\n", mgl);
    if (write(fd, cmd, strlen(cmd)) < 0) {
        int e = -errno;
        close(fd);
        return e;
    }
    close(fd);
    for (unsigned t = 0; t < timeout_ms; t += 100) {
        ts.tv_sec = 0;
        ts.tv_nsec = 100 * 1000000L;
        nanosleep(&ts, NULL);
        if (core_loaded(core_name))
            return 0;                     /* the caller opens and checks the heartbeat */
    }
    return -ETIMEDOUT;
}

/* ---- (0.9) the Linux framebuffer, the overlay's pages ---- */
/* fbcon draws its cursor (a blinking text cell on tty1's login prompt) into the framebuffer
 * on its own -- measured on the MiSTer, 2026-09-30: 16 lines changed within 2 s under the
 * core, none once the blink was off and the cursor hidden. The console stays bound (Main's F9
 * terminal uses it); only its cursor is quieted, and restored at the unmap. */
#define FBCON_BLINK "/sys/class/graphics/fbcon/cursor_blink"
static void fbcon_cursor(int show, int blink)
{
    int fd = open("/dev/tty1", O_WRONLY | O_NOCTTY | O_CLOEXEC);
    FILE *f;
    if (fd >= 0) {
        const char *seq = show ? "\033[?25h" : "\033[?25l";
        ssize_t n = write(fd, seq, strlen(seq));
        (void)n;
        close(fd);
    }
    if (blink >= 0 && (f = fopen(FBCON_BLINK, "w"))) {
        fprintf(f, "%d\n", blink);
        fclose(f);
    }
}

int h264ring_fb_map(struct h264ring_fb *fb)
{
    struct fb_fix_screeninfo fix;
    void *map;
    int fd;
    if (!fb)
        return -EINVAL;
    memset(fb, 0, sizeof *fb);
    fb->fd = -1;
    fd = open("/dev/fb0", O_RDWR | O_CLOEXEC);
    if (fd < 0)
        return -ENODEV;
    if (ioctl(fd, FBIOGET_FSCREENINFO, &fix) < 0 || fix.smem_len == 0 ||
        fix.smem_start < H264RING_FB_BYTE ||
        fix.smem_start + fix.smem_len > (unsigned long)H264RING_FB_BYTE + H264RING_FB_SIZE) {
        close(fd);                        /* not the region the core reads: nothing it could show */
        return -ENODEV;
    }
    map = mmap(NULL, fix.smem_len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (map == MAP_FAILED) {
        close(fd);
        return -errno;
    }
    fb->virt = map;
    fb->phys = (uint32_t)fix.smem_start;
    fb->len = fix.smem_len;
    fb->fd = fd;
    fb->blink = -1;
    {
        FILE *f = fopen(FBCON_BLINK, "r");
        if (f) {
            if (fscanf(f, "%d", &fb->blink) != 1)
                fb->blink = -1;
            fclose(f);
        }
    }
    fbcon_cursor(0, fb->blink >= 0 ? 0 : -1);
    return 0;
}

void h264ring_fb_unmap(struct h264ring_fb *fb)
{
    if (!fb || !fb->virt)
        return;
    munmap(fb->virt, fb->len);
    close(fb->fd);
    fbcon_cursor(1, fb->blink);
    fb->virt = NULL;
    fb->fd = -1;
}
