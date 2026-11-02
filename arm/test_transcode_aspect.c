#include <stdio.h>
#include "transcode_aspect.h"
#include "video_geometry.h"

int main(void)
{
    struct test {
        const char *name;
        struct transcode_source source;
        int w, h, sn, sd, repair;
    } cases[] = {
        {"NTSC stale SAR", {720,480,1.33}, 640,480,8,9,1},
        {"correct NTSC", {720,480,1.33}, 640,480,1,1,0},
        {"smaller 4:3 transcode", {720,480,1.33}, 480,360,8,9,1},
        {"704-wide DVD", {704,480,1.33}, 640,480,10,11,1},
        {"PAL stale SAR", {720,576,1.33}, 640,480,16,15,1},
        {"anamorphic widescreen", {720,480,1.78}, 854,480,32,27,1},
        {"legitimate anamorphic output", {720,480,1.33}, 360,240,8,9,0},
        {"unchanged original", {720,480,1.33}, 720,480,8,9,0},
        {"square original", {640,480,1.33}, 480,360,8,9,0},
        {"intentionally narrow picture", {640,480,32.0/27}, 640,480,8,9,0},
        {"different output shape", {720,480,1.33}, 640,360,8,9,0},
        {"unrelated wrong tag", {720,480,1.33}, 640,480,2,1,0},
        {"missing metadata", {0,0,0}, 640,480,8,9,0},
        {"missing source width", {0,480,1.33}, 640,480,8,9,0},
        {"missing SAR", {720,480,1.33}, 640,480,0,0,0},
        {"missing output dimensions", {720,480,1.33}, 0,480,8,9,0},
        {"NaN aspect", {720,480,NAN}, 640,480,8,9,0},
        {"infinite aspect", {720,480,INFINITY}, 640,480,8,9,0},
    };
    unsigned failures = 0;
    for (unsigned i=0; i<sizeof cases/sizeof *cases; ++i) {
        struct test t=cases[i];
        int got=transcode_aspect_stale(t.source,t.w,t.h,t.sn,t.sd);
        if (got!=t.repair) { fprintf(stderr,"FAIL %s: repair=%d\n",t.name,got); ++failures; }
    }
    /* The corrected SAR must feed calibrated geometry too, not only the SPS. */
    struct video_geometry_config g={12,0,8,0,1000};
    struct video_geometry_result original,corrected,narrow;
    if (video_geometry_compute(&g,4,3,480,480,VIDEO_MODE_AUTO,&original) ||
        video_geometry_compute(&g,640,480,480,480,VIDEO_MODE_AUTO,&corrected) ||
        video_geometry_compute(&g,640*8,480*9,480,480,VIDEO_MODE_AUTO,&narrow) ||
        corrected.image.x!=original.image.x || corrected.image.w!=original.image.w ||
        narrow.image.w>=corrected.image.w) ++failures;
    if (failures) return 1;
    puts("transcode aspect: 18 policy cases and calibrated geometry passed");
    return 0;
}
