#ifndef JFPLAY_TRANSCODE_ASPECT_H
#define JFPLAY_TRANSCODE_ASPECT_H
#include <math.h>

/* Plex's original, selected media version. A video transcode may resize an
 * anamorphic source to square pixels while retaining its old SAR (issue #19).
 * Never infer the intended display shape from output dimensions alone. */
struct transcode_source {
    int width, height;
    double dar;
};

static inline int transcode_source_valid(struct transcode_source s)
{
    return s.width > 0 && s.width <= 65535 && s.height > 0 && s.height <= 65535 &&
           isfinite(s.dar) && s.dar >= 0.05 && s.dar <= 20.0;
}

static inline int ta_near(double a, double b)
{
    /* Plex rounds display aspect to two decimal places (1.33, 1.78).
     * Half a percent also allows even-pixel rounding of transcode sizes. */
    return fabs(a - b) <= b * 0.005;
}

static inline int transcode_aspect_stale(struct transcode_source source,
        int width, int height, int sar_num, int sar_den)
{
    if (!transcode_source_valid(source) || width <= 0 || height <= 0 ||
        sar_num <= 0 || sar_den <= 0 ||
        (width == source.width && height == source.height)) return 0;
    double original_sar = source.dar * source.height / source.width;
    double sar = (double)sar_num / sar_den;
    return !ta_near(original_sar, 1.0) && !ta_near(sar, 1.0) &&
           ta_near((double)width / height, source.dar) && ta_near(sar, original_sar);
}
#endif
