/* SPDX-License-Identifier: MIT (hps/LICENSE) */
/* cavlc2cabac -- the library's CAVLC -> CABAC rewriter (h264ring_cavlc.h) on a file: the
 * host-side check (bench/h264/run_cavlc.sh decodes both with ffmpeg and compares) and the
 * rig's CPU measurement (--bench: the rewrite alone, from memory, timed).
 *
 *   cavlc2cabac in.264 out.264          rewrite; exit 0, 2 refused, 3 error (the reason on stderr)
 *   cavlc2cabac --bench N in.264        rewrite N times, report the time per access unit and
 *                                       the macroblocks / s, bins / s it sustains
 *   --fps F                             with --bench: the share of one core at F access units / s
 */
#define _POSIX_C_SOURCE 200809L
#include "h264ring.h"
#include "h264ring_cavlc.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec * 1e-9;
}

static uint8_t *slurp(const char *path, size_t *n)
{
    FILE *f = fopen(path, "rb");
    uint8_t *b = NULL;
    size_t cap = 0;
    *n = 0;
    if (!f)
        return NULL;
    for (;;) {
        size_t got;
        if (*n == cap) {
            uint8_t *q;
            cap = cap ? cap * 2 : 1 << 20;
            q = realloc(b, cap);
            if (!q) {
                free(b);
                fclose(f);
                return NULL;
            }
            b = q;
        }
        got = fread(b + *n, 1, cap - *n, f);
        if (!got)
            break;
        *n += got;
    }
    fclose(f);
    return b;
}

int main(int argc, char **argv)
{
    const char *in = NULL, *outp = NULL;
    int bench = 0, i, quiet = 0;
    double fps = 0;
    size_t n, n_aus, k;
    uint8_t *buf;
    struct h264ring_au *aus;
    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--bench") && i + 1 < argc)
            bench = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc)
            fps = atof(argv[++i]);
        else if (!strcmp(argv[i], "-q"))
            quiet = 1;
        else if (!in)
            in = argv[i];
        else if (!outp)
            outp = argv[i];
        else {
            fprintf(stderr, "usage: cavlc2cabac [--bench N [--fps F]] [-q] in.264 [out.264]\n");
            return 1;
        }
    }
    if (!in || (!bench && !outp)) {
        fprintf(stderr, "usage: cavlc2cabac [--bench N [--fps F]] [-q] in.264 [out.264]\n");
        return 1;
    }
    buf = slurp(in, &n);
    if (!buf) {
        perror(in);
        return 1;
    }
    n_aus = h264ring_split_annexb(buf, n, NULL, 0);
    aus = calloc(n_aus ? n_aus : 1, sizeof *aus);
    if (!aus)
        return 1;
    h264ring_split_annexb(buf, n, aus, n_aus);
    if (bench) {
        struct h264ring_cavlc_stats st;
        double t0, t, best = 1e30, sum = 0;
        int r;
        h264ring_cavlc *cv = NULL;
        for (r = 0; r < bench; r++) {
            if (cv)
                h264ring_cavlc_free(cv);
            cv = h264ring_cavlc_new();
            t0 = now();
            for (k = 0; k < n_aus; k++) {
                const uint8_t *o;
                size_t ol;
                int rc = h264ring_cavlc_au(cv, buf + aus[k].off, aus[k].len, &o, &ol);
                if (rc >= H264RING_CAVLC_REFUSED) {
                    fprintf(stderr, "cavlc2cabac: unit %zu: %s: %s\n", k,
                            rc == H264RING_CAVLC_REFUSED ? "refused" : "error", h264ring_cavlc_why(cv));
                    return rc == H264RING_CAVLC_REFUSED ? 2 : 3;
                }
            }
            t = now() - t0;
            sum += t;
            if (t < best)
                best = t;
        }
        h264ring_cavlc_get_stats(cv, &st);
        printf("%s: %zu units, %llu macroblocks, %llu bins, %llu -> %llu bytes\n", in, n_aus,
               (unsigned long long)st.mbs, (unsigned long long)st.bins,
               (unsigned long long)st.bytes_in, (unsigned long long)st.bytes_out);
        printf("best of %d: %.3f s = %.3f ms a unit, %.0f macroblocks/s, %.2f Mbins/s, %.1f ns a bin\n",
               bench, best, 1e3 * best / n_aus, st.mbs / best, st.bins / best / 1e6, 1e9 * best / st.bins);
        printf("mean: %.3f s\n", sum / bench);
        if (fps > 0)
            printf("at %.2f units/s: %.1f %% of one core\n", fps, 100.0 * best / n_aus * fps);
        h264ring_cavlc_free(cv);
    } else {
        FILE *f = fopen(outp, "wb");
        h264ring_cavlc *cv = h264ring_cavlc_new();
        struct h264ring_cavlc_stats st;
        if (!f || !cv) {
            perror(outp);
            return 1;
        }
        for (k = 0; k < n_aus; k++) {
            const uint8_t *o;
            size_t ol;
            int rc = h264ring_cavlc_au(cv, buf + aus[k].off, aus[k].len, &o, &ol);
            if (rc >= H264RING_CAVLC_REFUSED) {
                fprintf(stderr, "cavlc2cabac: unit %zu: %s: %s\n", k,
                        rc == H264RING_CAVLC_REFUSED ? "refused" : "error", h264ring_cavlc_why(cv));
                fclose(f);
                return rc == H264RING_CAVLC_REFUSED ? 2 : 3;
            }
            if (fwrite(o, 1, ol, f) != ol) {
                perror(outp);
                return 1;
            }
        }
        fclose(f);
        h264ring_cavlc_get_stats(cv, &st);
        if (!quiet)
            printf("%s: %zu units (%llu rewritten), %llu slices rewritten, %llu passed, %llu macroblocks, "
                   "%llu bins, %llu -> %llu bytes, %llu cabac_zero_words, %llu all-zero 8x8 blocks, "
                   "%llu I_PCM, %llu P_8x8ref0\n",
                   in, n_aus, (unsigned long long)st.units_rewritten, (unsigned long long)st.slices_rewritten,
                   (unsigned long long)st.slices_passed, (unsigned long long)st.mbs,
                   (unsigned long long)st.bins, (unsigned long long)st.bytes_in,
                   (unsigned long long)st.bytes_out, (unsigned long long)st.zero_words,
                   (unsigned long long)st.t8_zero_blocks, (unsigned long long)st.pcm_mbs,
                   (unsigned long long)st.p8x8ref0_mbs);
        h264ring_cavlc_free(cv);
    }
    free(aus);
    free(buf);
    return 0;
}
