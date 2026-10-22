#include "video_geometry.h"
#include <stdio.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

static int failures;
#define CHECK(c, msg) do { if (!(c)) { fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); failures++; } } while (0)

static void fixture_tests(void)
{
    FILE *f = fopen("tools/testdata/fit_cases.txt", "r");
    char line[512];
    int n = 0;
    CHECK(f != NULL, "open shared fit fixtures");
    if (!f) return;
    while (fgets(line, sizeof line, f)) {
        int l,t,r,b,width,lines,x,y,w,h;
        unsigned an,ad;
        char *hash = strchr(line, '#');
        if (hash) *hash = 0;
        if (sscanf(line, "%d%d%d%d%d %u/%u %d%d%d%d%d", &l,&t,&r,&b,&width,&an,&ad,&lines,&x,&y,&w,&h) != 12) continue;
        struct video_geometry_config g = {l,t,r,b,width};
        struct video_geometry_result out;
        int rc = video_geometry_compute(&g,an,ad,(unsigned)lines,480,VIDEO_MODE_LETTERBOX,&out);
        if (rc || out.image.x != x || out.image.y != y || out.image.w != w || out.image.h != h) {
            fprintf(stderr, "fixture %d: got rc=%d {%d,%d,%d,%d}, expected {%d,%d,%d,%d}\n",
                n,rc,out.image.x,out.image.y,out.image.w,out.image.h,x,y,w,h);
            failures++;
        }
        n++;
    }
    fclose(f);
    CHECK(n >= 20, "all fit fixtures parsed");
}

int main(void)
{
    fixture_tests();
    {
        struct video_geometry_config g = {0,0,0,0,0};
        struct video_geometry_result o;
        CHECK(video_geometry_compute(&g,16,9,1080,480,VIDEO_MODE_AUTO,&o)==0, "default geometry accepted");
        CHECK(!o.override_required, "factory geometry does not override core default");
        CHECK(o.image.x==0 && o.image.y==60 && o.image.w==720 && o.image.h==360, "auto uses app letterbox preview");
        CHECK(video_geometry_compute(&g,16,9,1080,576,VIDEO_MODE_LETTERBOX,&o)==0, "PAL accepted");
        CHECK(o.clip.y==0 && o.clip.h==576 && o.image.y==72 && o.image.h==432, "PAL vertically scales preview");
        g.top=6; g.bottom=2;
        CHECK(video_geometry_compute(&g,16,9,1080,576,VIDEO_MODE_CROP,&o)==0, "PAL crop accepted");
        CHECK(o.clip.y==8 && o.clip.h==566 && o.clip.y%2==0 && o.clip.h%2==0, "PAL edges round to even positions independently");
        CHECK(o.image.x%2==0 && o.image.y%2==0 && o.image.w%2==0 && o.image.h%2==0, "PAL image rectangle stays even");
    }
    {
        struct video_geometry_config g = {0,0,0,0,1000};
        struct video_geometry_result o;
        CHECK(video_geometry_compute(&g,16,9,1080,480,VIDEO_MODE_CROP,&o)==0, "crop accepted");
        CHECK(o.image.x==-120 && o.image.w==960 && o.image.y==0 && o.image.h==480, "NTSC crop accounts for raster pixel aspect");
        CHECK(o.clip.x==0 && o.clip.w==720 && o.clip.h==480, "crop has independent clip viewport");
        CHECK(video_geometry_compute(&g,16,9,1080,480,VIDEO_MODE_CROP_14_9,&o)==0, "14:9 crop accepted");
        CHECK(o.image.x==-52 && o.image.w==822 && o.image.y==34 && o.image.h==412, "14:9 keeps more source with small bars");
        CHECK(video_geometry_compute(&g,235,100,1080,480,VIDEO_MODE_CROP_14_9,&o)==0, "cinemascope 14:9 crop accepted");
        CHECK(o.image.x==-184 && o.image.w==1088 && o.image.y==34 && o.image.h==412, "14:9 crop scales wide formats consistently");
        CHECK(video_geometry_compute(&g,16,9,1080,576,VIDEO_MODE_CROP_14_9,&o)==0, "PAL 14:9 crop accepted");
        CHECK(o.image.x==-52 && o.image.w==822 && o.image.y==40 && o.image.h==494, "PAL 14:9 crop keeps aspect and centers");
        CHECK(video_geometry_compute(&g,14,9,1080,480,VIDEO_MODE_CROP_14_9,&o)==0, "14:9 input accepted");
        CHECK(o.image.x==0 && o.image.y==34 && o.image.w==720 && o.image.h==412, "14:9 input stays whole");
        g.width=980;
        CHECK(video_geometry_compute(&g,16,9,1080,480,VIDEO_MODE_CROP,&o)==0, "width-corrected crop accepted");
        CHECK(o.image.w<960 && o.image.w>=720, "crop applies calibrated width correction while covering viewport");
        g.width=1000;
        CHECK(video_geometry_compute(&g,4,3,480,480,VIDEO_MODE_FIT,&o)==0, "fit accepted");
        CHECK(o.image.w==540 && o.image.h==480 && o.image.x==90, "fit is anamorphic 16:9");
        g.width=850;
        CHECK(video_geometry_compute(&g,4,3,480,480,VIDEO_MODE_FIT,&o)==0, "width-corrected fit accepted");
        CHECK(o.image.w==460 && o.image.h==480, "fit applies calibrated width correction");
    }
    {
        struct video_geometry_config bad = {-2,0,0,0,1000};
        struct video_geometry_result o;
        CHECK(video_geometry_compute(&bad,4,3,480,480,VIDEO_MODE_AUTO,&o)<0, "negative calibration rejected");
        bad.left=0; bad.width=1200;
        CHECK(video_geometry_compute(&bad,4,3,480,480,VIDEO_MODE_AUTO,&o)<0, "out-of-range width rejected");
        bad.width=1000;
        CHECK(video_geometry_compute(&bad,0,3,480,480,VIDEO_MODE_AUTO,&o)<0, "zero aspect rejected");
        CHECK(video_geometry_compute(&bad,1,UINT_MAX,480,480,VIDEO_MODE_CROP,&o)<0, "unrepresentable tiny aspect rejected before narrowing");
        CHECK(video_geometry_compute(&bad,4,3,480,576,VIDEO_MODE_AUTO,&o)==0, "576-line raster accepted");
        CHECK(video_geometry_compute(&bad,4,3,480,525,VIDEO_MODE_AUTO,&o)<0, "unsupported raster rejected");
    }
    {
        struct video_geometry_config g = {0,0,0,0,1000};
        struct video_geometry_result o;
        CHECK(video_geometry_compute_display(&g,16,9,720,480,VIDEO_MODE_LETTERBOX,1,&o)==0,
              "widescreen display accepted");
        CHECK(o.image.x==0 && o.image.y==0 && o.image.w==720 && o.image.h==480,
              "16:9 video fills 16:9 display");
        CHECK(video_geometry_compute_display(&g,4,3,480,576,VIDEO_MODE_LETTERBOX,1,&o)==0,
              "4:3 video on widescreen PAL accepted");
        CHECK(o.image.x==90 && o.image.y==0 && o.image.w==540 && o.image.h==576,
              "4:3 video pillarboxed on widescreen");
        CHECK(video_geometry_compute_display(&g,4,3,480,480,VIDEO_MODE_CROP,1,&o)==0,
              "widescreen crop accepted");
        CHECK(o.image.x==0 && o.image.y==-80 && o.image.w==720 && o.image.h==640,
              "crop removes side bars by cropping top and bottom");
        CHECK(video_geometry_compute_display(&g,16,9,720,480,VIDEO_MODE_LETTERBOX,0,&o)==0,
              "4:3 display unchanged");
        CHECK(o.image.y==60 && o.image.h==360, "4:3 display keeps letterbox");
    }
    if (failures) return 1;
    puts("video geometry tests passed");
    return 0;
}
