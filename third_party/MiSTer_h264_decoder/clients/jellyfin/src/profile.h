/* profile -- the device profile (profile.c; docs/jellyfin.md S2) */
#ifndef JF_PROFILE_H
#define JF_PROFILE_H
/* hd 0: transcodes capped by the 854x480 box; 1: by 1280x720 (the output shows a 720-line picture
 * at its own size: Native (HDMI) and h264ring_caps' native_h >= 720). Direct play is the same. */
const char *jf_profile_json(int hd);
#endif
