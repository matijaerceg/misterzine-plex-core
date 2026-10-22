#ifndef MISTERZINE_VIDEO_GEOMETRY_H
#define MISTERZINE_VIDEO_GEOMETRY_H

/* Pure geometry used to translate the saved CRT calibration into a video
 * rectangle and an independent raster clip window. Coordinates are pixels on
 * a 720-wide raster; y/height scale with raster_lines (480 or 576).
 */
#include <stdint.h>

enum video_analog_mode {
    VIDEO_MODE_AUTO = 0,
    VIDEO_MODE_FIT = 1,
    VIDEO_MODE_LETTERBOX = 2,
    VIDEO_MODE_CROP = 3,
    VIDEO_MODE_CROP_14_9 = 4
};

struct video_geometry_config {
    int left, top, right, bottom; /* calibrated edges, in 480-line units */
    int width;                    /* per-mille; zero means 1000 */
};

struct video_rect {
    int x, y, w, h;
};

struct video_geometry_result {
    struct video_rect image;
    struct video_rect clip;
    int override_required; /* false for factory/default geometry */
};

/* aspect_num/aspect_den is the resolved display aspect (DAR), including SAR.
 * source_lines is the coded/frame line count; raster_lines is 480 or 576.
 * Returns 0 on success, -1 for invalid input or an unrepresentable result.
 * Coordinates and extents are checked against the signed/unsigned 13-bit
 * core rectangle format: x/y [-4096,4095], w/h [1,8191].
 */
static inline long long vg_round(double x) { return (long long)(x + 0.5); }
static inline int vg_even_round(double x) { return (int)(2 * vg_round(x / 2.0)); }
static inline int vg_even_bounded(double x, int *out) {
    if (!(x >= 0.0) || x > 8191.0) return -1;
    *out = vg_even_round(x);
    return (*out >= 1 && *out <= 8191) ? 0 : -1;
}
static inline int vg_scaled_edge(int edge, unsigned raster_lines) {
    return vg_even_round((double)edge * raster_lines / 480.0);
}
static inline int vg_center_even(int delta) {
    int half = delta >= 0 ? delta / 2 : -((-delta + 1) / 2);
    return half >= 0 ? (half & ~1) : -(((-half + 1) / 2) * 2);
}
static inline int vg_valid_rect(struct video_rect r) {
    return r.x >= -4096 && r.x <= 4095 && r.y >= -4096 && r.y <= 4095 &&
           r.w >= 1 && r.w <= 8191 && r.h >= 1 && r.h <= 8191;
}
static inline int video_geometry_compute(const struct video_geometry_config *g,
        unsigned aspect_num, unsigned aspect_den, unsigned source_lines,
        unsigned raster_lines, enum video_analog_mode mode,
        struct video_geometry_result *out)
{
    struct video_geometry_config c;
    struct video_rect area;
    double a, bw, bh;
    int aw, ah, w, h, crop_14;
    if (!g || !out || !aspect_num || !aspect_den || !source_lines ||
        (raster_lines != 480 && raster_lines != 576) || mode < VIDEO_MODE_AUTO || mode > VIDEO_MODE_CROP_14_9)
        return -1;
    c = *g;
    if (c.width == 0) c.width = 1000;
    if (c.left < 0 || c.right < 0 || c.top < 0 || c.bottom < 0 ||
        c.left > 120 || c.right > 120 || c.top > 80 || c.bottom > 80 ||
        (c.left|c.right|c.top|c.bottom)&1 || c.width < 850 || c.width > 1150)
        return -1;
    if (c.left + c.right >= 720 || c.top + c.bottom >= 480) return -1;
    a = (double)aspect_num / aspect_den;
    if (!(a > 0.0) || a > 1000.0) return -1;
    crop_14 = mode == VIDEO_MODE_CROP_14_9 && a > 14.0 / 9.0;
    if (mode == VIDEO_MODE_CROP_14_9 && !crop_14) mode = VIDEO_MODE_LETTERBOX;

    /* Saved vertical edges use 480-line units; scale each edge to the active
     * 480/576-line raster and quantize both boundaries to even coordinates. */
    area.x = c.left;
    area.y = vg_scaled_edge(c.top, raster_lines);
    aw = 720 - c.left - c.right;
    ah = vg_scaled_edge(480 - c.bottom, raster_lines) - area.y;
    area.w = aw;
    area.h = ah;
    out->clip = area;
    out->override_required = !!(c.left || c.top || c.right || c.bottom || c.width != 1000);

    if (mode == VIDEO_MODE_AUTO) mode = VIDEO_MODE_LETTERBOX;
    if (mode == VIDEO_MODE_CROP || mode == VIDEO_MODE_CROP_14_9) {
        /* Cover the calibrated viewport; clipping is separately described. */
        double corrected_aspect = a * 540.0 / raster_lines * c.width / 1000.0;
        if ((double)aw / ah > corrected_aspect) {
            w = aw;
            if (vg_even_bounded(aw / corrected_aspect, &h)) return -1;
        } else {
            h = ah;
            if (vg_even_bounded(ah * corrected_aspect, &w)) return -1;
        }
        out->image.x = c.left + vg_center_even(aw - w);
        out->image.y = area.y + vg_center_even(area.h - h);
        out->image.w = w; out->image.h = h;
        if (crop_14) {
            /* 14:9 is the middle zoom between the 4:3 viewport and Fill.
             * Shrink Fill by the viewport-to-window ratio, preserving source
             * shape for every wide format (including cinemascope). */
            double scale = (4.0 / 3.0) / (14.0 / 9.0);
            out->image.w = vg_even_round(out->image.w * scale);
            out->image.h = vg_even_round(out->image.h * scale);
            out->image.x = c.left + vg_center_even(aw - out->image.w);
            out->image.y = area.y + vg_center_even(area.h - out->image.h);
        }
    } else if (mode == VIDEO_MODE_FIT) {
        /* Core Fit presents an anamorphic 16:9 window. */
        double nominal_w, nominal_h;
        double k = c.width / 1000.0;
        int fit_h = 480 - c.top - c.bottom;
        if (a > 16.0 / 9.0) {
            nominal_w = aw * k;
            nominal_h = (double)fit_h * (16.0 / 9.0) / a;
        } else {
            nominal_w = 405.0 * a * k;
            nominal_h = fit_h;
        }
        if (nominal_w > aw) {
            nominal_h *= aw / nominal_w;
            nominal_w = aw;
        }
        if (vg_even_bounded(nominal_w, &w) || vg_even_bounded(nominal_h, &h)) return -1;
        out->image.x = c.left + vg_center_even(aw - w);
        out->image.y = c.top + vg_center_even(fit_h - h);
        out->image.w = w; out->image.h = h;
        if (raster_lines == 576) {
            int y0 = vg_scaled_edge(out->image.y, 576);
            int y1 = vg_scaled_edge(out->image.y + out->image.h, 576);
            out->image.y = y0;
            out->image.h = y1 - y0;
        }
    } else {
        /* Match app Geometry.Fit on a 480-line coordinate plane, including
         * its near-4:3 and source-line snapping rules, then apply calibration. */
        bw = 720.0; bh = 480.0;
        if (a > 4.0/3.0) bh = vg_even_round(480.0 * (4.0/3.0) / a);
        else bw = vg_even_round(720.0 * a / (4.0/3.0));
        if (bw < 16) bw = 16;
        if (bh < 16) bh = 16;
        if (bw >= 708) bw = 720;
        if (!(source_lines & 1) && source_lines <= 480 &&
            (bh > (int)source_lines ? bh-(int)source_lines : (int)source_lines-bh) <= 9)
            bh = (int)source_lines;
        w = (int)bw; h = (int)bh;
        /* Calibration matching is defined on the app's 480-line preview. */
        ah = 480 - c.top - c.bottom;
        if (out->override_required) {
            double k = c.width / 1000.0;
            double nh = ah, nw = aw;
            if ((double)w * ah * k > (double)aw * h)
                nh = vg_even_round((double)aw * h / ((double)w * k));
            else
                nw = vg_even_round((double)w * ah * k / h);
            w = (int)nw; h = (int)nh;
            if (aw - w <= 2) w = aw;
            if (ah - h <= 2) h = ah;
            if (w < 16) w = 16;
            if (h < 16) h = 16;
        }
        out->image.x = c.left + vg_center_even(aw - w);
        out->image.y = c.top + vg_center_even(ah - h);
        out->image.w = w; out->image.h = h;
        /* PAL geometry is the app's 480 result scaled vertically. */
        if (raster_lines == 576) {
            int y0 = vg_scaled_edge(out->image.y, 576);
            int y1 = vg_scaled_edge(out->image.y + out->image.h, 576);
            out->image.y = y0;
            out->image.h = y1 - y0;
        }
    }
    return vg_valid_rect(out->image) && vg_valid_rect(out->clip) ? 0 : -1;
}

/* Map the physical display shape into the existing 4:3 calibration plane.
 * Width correction and safe edges keep their saved meanings on either display.
 * A 16:9 display stretches the same 720 raster 4/3 wider, so compensate by
 * reducing the content's raster aspect by 3/4 before fitting/cropping. */
static inline int video_geometry_compute_display(const struct video_geometry_config *g,
        unsigned aspect_num, unsigned aspect_den, unsigned source_lines,
        unsigned raster_lines, enum video_analog_mode mode, int widescreen,
        struct video_geometry_result *out)
{
    if (widescreen) {
        uint64_t n = (uint64_t)aspect_num * 3, d = (uint64_t)aspect_den * 4;
        uint64_t a = n, b = d;
        while (b) { uint64_t rem = a % b; a = b; b = rem; }
        if (!a) return -1;
        n /= a; d /= a;
        if (n > UINT32_MAX || d > UINT32_MAX) return -1;
        aspect_num = (unsigned)n; aspect_den = (unsigned)d;
        if (mode == VIDEO_MODE_FIT) mode = VIDEO_MODE_LETTERBOX;
    }
    return video_geometry_compute(g, aspect_num, aspect_den, source_lines,
                                  raster_lines, mode, out);
}

#endif
