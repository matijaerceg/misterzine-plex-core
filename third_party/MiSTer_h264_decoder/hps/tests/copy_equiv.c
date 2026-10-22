/* copy_equiv -- h264ring_picture_copy over a battery of pictures, one line per case: the case and an
 * FNV-1a hash of the store it wrote. run_copy_arm.sh builds it against the library twice for the
 * MiSTer -- NEON, and H264RING_NO_NEON (the scalar path the host tests score against a model) -- runs
 * both on the rig and diffs the lines: the NEON interior (put_row) is never run by a host test. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "h264ring.h"

static uint32_t seed = 12345u;
static uint8_t rnd(void) { seed = seed * 1103515245u + 12345u; return (uint8_t)(seed >> 16); }

int main(void)
{
    static const unsigned ws[] = { 1, 7, 8, 9, 15, 16, 17, 33, 63, 64, 65, 127, 640, 720 };
    static const unsigned hs[] = { 1, 2, 15, 16, 17, 31, 33, 480 };
    const unsigned maxw = 736, maxh = 512;
    uint8_t *pl[3];
    volatile uint64_t *st = aligned_alloc(64, H264RING_DPB_STORE);
    unsigned n = 0;
    for (int i = 0; i < 3; i++) pl[i] = malloc((size_t)maxw * maxh);
    if (!st || !pl[0] || !pl[1] || !pl[2]) return 1;
    for (unsigned fmt = 0; fmt < 4; fmt++)
        for (unsigned wi = 0; wi < sizeof ws / sizeof ws[0]; wi++)
            for (unsigned hi = 0; hi < sizeof hs / sizeof hs[0]; hi++)
                for (unsigned pair = 0; pair < 2; pair++) {
                    struct h264ring_picture p = { ws[wi], hs[hi],
                        pair ? H264RING_PIC_STRUCT_PAIR_BOT : H264RING_PIC_STRUCT_FRAME, -1, 0, 0, 0, 0, 0 };
                    struct h264ring_pic_layout l;
                    if (h264ring_picture_layout(&p, &l)) continue;
                    for (int i = 0; i < 3; i++)                 /* every byte value, at random */
                        for (size_t j = 0; j < (size_t)maxw * maxh; j++) pl[i][j] = rnd();
                    for (uint32_t j = 0; j < l.bytes / 8u; j++) st[j] = 0xA5A5A5A5A5A5A5A5ull;
                    const uint8_t *planes[3] = { pl[0] + 3, pl[1] + 1, pl[2] + 5 };   /* unaligned rows too */
                    int strides[3] = { (int)maxw - 3, (int)maxw / 2 + 7, (int)maxw / 2 + 9 };
                    if (h264ring_picture_copy(st, &p, planes, strides, fmt)) { printf("copy failed\n"); return 1; }
                    uint64_t h = 1469598103934665603ull;
                    for (uint32_t j = 0; j < l.bytes / 8u; j++) {
                        uint64_t v = st[j];
                        for (int b = 0; b < 8; b++) { h ^= (v >> (8 * b)) & 0xFF; h *= 1099511628211ull; }
                    }
                    printf("fmt %u %ux%u %s %016llx\n", fmt, p.width, p.height, pair ? "pair" : "frame",
                           (unsigned long long)h);
                    n++;
                }
    printf("cases %u\n", n);
    return 0;
}
