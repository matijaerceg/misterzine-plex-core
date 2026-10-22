/* profile -- the device profile sent with every PlaybackInfo and the capabilities
 * (docs/jellyfin.md S2 "The device profile", which is its rationale; R1 measured the server's
 * answers to it). In short:
 *  - direct play: H.264 High / Main, 8-bit SDR, progressive, <= 10 Mbit/s, <= 60 frames/s, inside
 *    the core's picture bound and rate (interface 0.11: 3,600 macroblocks, 108,000 a second) by
 *    bands KEYED ON THE WIDTH: width <= 720: height <= 576; width 721-864: height <= 480; wider,
 *    up to 1280x720 at <= 30 frames/s (720p24 / 720p30); wider above 30 frames/s: <= 864x480.
 *    A band's conditions become the transcode's limits whenever the source matches it (the
 *    height-keyed form capped every 1080p transcode at 720 wide; a frame-rate condition in a band
 *    would cap a 60 frames/s source's transcode at 30 -- so the rate keys the band instead);
 *    audio the ARM decodes (TrueHD left to the server: a third of a core, R2);
 *  - otherwise an HLS transcode in MPEG-TS, H.264, capped by ONE box: 854x480 (every aspect fits
 *    1,620 macroblocks; never 854 wide and 576 high together: a 4:3 source would be 768x576), or
 *    1280x720 when the output shows it at that size (jf_profile_json(1): Video Output Native
 *    (HDMI) on a core whose native raster reaches 720 lines -- none yet, docs/jellyfin.md S2);
 *    a source above 30 frames/s stays inside 864x480 either way (its band);
 *  - subtitles: text External (drawn on the overlay), bitmaps Encode (burned in).
 * Generated from the R1 profile; edit the JSON here and the note together. */
#include "profile.h"

/* W, H: the transcode's box (string literals) */
#define JF_PROFILE(W, H) \
    "{\"Name\":\"MiSTer-H264\",\"MaxStreamingBitrate\":10000000,\"MaxStaticBitrate\":10000000,\"DirectPlayProf" \
    "iles\":[{\"Type\":\"Video\",\"Container\":\"mkv,mp4,m4v,mov,ts,m2ts\",\"VideoCodec\":\"h264\",\"AudioCodec\":\"a" \
    "ac,ac3,eac3,dts,mp3,opus,flac,vorbis\"}],\"TranscodingProfiles\":[{\"Type\":\"Video\",\"Context\":\"Stream" \
    "ing\",\"Protocol\":\"hls\",\"Container\":\"ts\",\"VideoCodec\":\"h264\",\"AudioCodec\":\"aac,ac3\",\"MaxAudioChann" \
    "els\":\"2\",\"MinSegments\":1,\"BreakOnNonKeyFrames\":false,\"Conditions\":[{\"Condition\":\"LessThanEqual\"," \
    "\"Property\":\"Width\",\"Value\":\"" W "\"},{\"Condition\":\"LessThanEqual\",\"Property\":\"Height\",\"Value\":\"" H "\"" \
    "}]}],\"CodecProfiles\":[{\"Type\":\"Video\",\"Codec\":\"h264\",\"Conditions\":[{\"Condition\":\"EqualsAny\",\"Pro" \
    "perty\":\"VideoProfile\",\"Value\":\"high|main\",\"IsRequired\":true},{\"Condition\":\"LessThanEqual\",\"Prope" \
    "rty\":\"VideoBitDepth\",\"Value\":\"8\"},{\"Condition\":\"EqualsAny\",\"Property\":\"VideoRangeType\",\"Value\":\"" \
    "SDR\"},{\"Condition\":\"NotEquals\",\"Property\":\"IsInterlaced\",\"Value\":\"true\"},{\"Condition\":\"LessThanE" \
    "qual\",\"Property\":\"Width\",\"Value\":\"1280\",\"IsRequired\":true},{\"Condition\":\"LessThanEqual\",\"Property" \
    "\":\"Height\",\"Value\":\"720\",\"IsRequired\":true},{\"Condition\":\"LessThanEqual\",\"Property\":\"VideoFramer" \
    "ate\",\"Value\":\"60\"},{\"Condition\":\"LessThanEqual\",\"Property\":\"VideoBitrate\",\"Value\":\"10000000\"}]}," \
    "{\"Type\":\"Video\",\"Codec\":\"h264\",\"ApplyConditions\":[{\"Condition\":\"LessThanEqual\",\"Property\":\"Wi" \
    "dth\",\"Value\":\"720\"}],\"Conditions\":[{\"Condition\":\"LessThanEqual\",\"Property\":\"Height\",\"Value\":\"576" \
    "\"}]},{\"Type\":\"Video\",\"Codec\":\"h264\",\"ApplyConditions\":[{\"Condition\":\"GreaterThanEqual\",\"Property\":\"Wi" \
    "dth\",\"Value\":\"721\"},{\"Condition\":\"LessThanEqual\",\"Property\":\"Width\",\"Value\":\"864\"}],\"Conditions\"" \
    ":[{\"Condition\":\"LessThanEqual\",\"Property\":\"Height\",\"Value\":\"480\"}]},{\"Type\":\"Video\",\"Codec\":\"h2" \
    "64\",\"ApplyConditions\":[{\"Condition\":\"GreaterThanEqual\",\"Property\":\"Width\",\"Value\":\"865\"},{\"Condit" \
    "ion\":\"GreaterThanEqual\",\"Property\":\"VideoFramerate\",\"Value\":\"30.5\"}],\"Conditions\":[{\"Condition\":" \
    "\"LessThanEqual\",\"Property\":\"Width\",\"Value\":\"864\"},{\"Condition\":\"LessThanEqual\",\"Property\":\"Heigh" \
    "t\",\"Value\":\"480\"}]}],\"SubtitleProfiles\":[{\"Format\":\"srt\",\"Method\":\"External\"},{\"Format\":\"subrip\"" \
    ",\"Method\":\"External\"},{\"Format\":\"ass\",\"Method\":\"External\"},{\"Format\":\"ssa\",\"Method\":\"External\"" \
    "},{\"Format\":\"vtt\",\"Method\":\"External\"},{\"Format\":\"pgssub\",\"Method\":\"Encode\"},{\"Format\":\"dvdsub" \
    "\",\"Method\":\"Encode\"},{\"Format\":\"dvbsub\",\"Method\":\"Encode\"}]}"

static const char *const profile_sd = JF_PROFILE("854", "480");
static const char *const profile_hd = JF_PROFILE("1280", "720");

const char *jf_profile_json(int hd)
{
    return hd ? profile_hd : profile_sd;
}
