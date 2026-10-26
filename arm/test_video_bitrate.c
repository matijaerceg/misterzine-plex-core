#include "video_bitrate.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
 struct video_bitrate s = {0};
 video_bitrate_add(&s, 1000, 0);
 video_bitrate_add(&s, 1000, -1);
 assert(s.bytes == 0);
 for (int i=0;i<48;i++) video_bitrate_add(&s, 12500, 3750);
 assert(s.recent_bps == 2400000 && video_bitrate_average(&s) == 2400000);
 /* Another two media seconds at twice the rate: recent and average differ. */
 for (int i=0;i<48;i++) video_bitrate_add(&s, 25000, 3750);
 assert(s.recent_bps == 4800000 && video_bitrate_average(&s) == 3600000);
 /* Pausing contributes no samples; seeking resets the measurement. */
 assert(video_bitrate_average(&s) == 3600000);
 s = (struct video_bitrate){0};
 assert(!s.recent_bps && !video_bitrate_average(&s));
 puts("video bitrate: PASS");
}
