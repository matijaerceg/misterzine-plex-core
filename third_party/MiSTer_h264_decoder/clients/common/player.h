/* player -- one stream from a URL into the core (docs/jellyfin.md S2, S3): libavformat demuxes
 * on a reader thread into a bounded packet queue; player_step(), called from the client's one
 * loop, moves packets into the ring without blocking -- the video as Annex-B access units with
 * their PTS (90 kHz), the audio decoded, resampled to 48 kHz s16 stereo and written with its PTS.
 * The ring is touched only from the loop's thread (the library is not thread-safe). */
#ifndef CLIENT_PLAYER_H
#define CLIENT_PLAYER_H

#include <stdint.h>
#include "h264check.h"
#include "h264ring.h"
#include "subs.h"

struct player;

struct player_cfg {
    const char *url;          /* anything avformat_open_input takes: https://.../master.m3u8, a file */
    const char *headers;      /* extra HTTP headers ("Authorization: ...\r\n"), or NULL */
    const char *cafile;       /* the CA bundle for HTTPS (every request, the HLS segments' too) */
    double start_s;           /* where in the item this stream starts (the transcode's StartTimeTicks) */
    int seek;                 /* 1: seek the opened stream to start_s (direct play); 0: it starts there */
    int audio_stream;         /* the container's audio stream index, -1: the demuxer's best */
    int hls_trim;             /* 1: url is a Jellyfin transcode's master.m3u8 -- start at the segment
                                 holding start_s (a trimmed playlist: the server's transcoder starts
                                 once, there) instead of opening at the film's start and seeking */
    int hold;                 /* 1: write nothing until player_release() -- stop at PL_READY with the
                                 first IDR checked and held (a seek keeps the old picture frozen meanwhile) */
    int text_subs;            /* 1: decode every text subtitle track into cues (player_subs: the file
                                 player, docs/player.md); 0: subtitle tracks discarded */
    int cavlc_ok;             /* 1: a CAVLC stream is written, the library's write call rewriting it
                                 into CABAC (interface 0.10; the file player, docs/player.md P6);
                                 one it cannot rewrite (FMO, ASO, ...) is PL_UNDECODABLE with
                                 player_error() saying why. 0: CAVLC is PL_UNDECODABLE (Jellyfin:
                                 the server transcodes instead) */
    unsigned max_mbs, mb_rate; /* (0.11) the core's largest picture and macroblock rate (h264ring_caps;
                                 0: the 0.11 core's 3,600 / 108,000): a stream past either is
                                 PL_UNDECODABLE (H264C_SIZE / H264C_RATE) before the ring */
    int arm_video;            /* (0.15) 1: video the core does not decode is decoded on the ARM (vdec.h:
                                 MPEG-1/2, MPEG-4 Part 2, DivX 3, WMV7/8, Theora, MJPEG, H.263 at SD) and
                                 sent as pictures (the ring opened with H264RING_OPEN_PICTURES; the file
                                 player, docs/player.md "Other codecs"); another codec, or one past SD,
                                 is PL_FAILED with player_error() naming why. 0: only H.264 (Jellyfin:
                                 the server transcodes) */
    unsigned colour;          /* (0.16, docs/colour.md) the colour code the stream's access units carry
                                 (h264ring_set_colour): 0 auto -- the stream's own tags, else by size.
                                 Jellyfin: the SOURCE's on a transcode (the server labels every transcode
                                 BT.709, an SD source's 601 pixels included: colour.md R4) */
};

/* what the stream holds, once it opened (the file player's tracks, refresh rate and refusals) */
struct player_track {
    int index;                /* the container's stream index */
    int playable;             /* a decoder for it was built in */
    int def;                  /* the file marks it default or forced */
    char name[96];            /* "eng  Commentary  AC-3 5.1": language, title, format */
};
struct player_info {
    double duration;          /* seconds, 0 unknown */
    double fps;               /* the container's frame rate, 0 unknown */
    int width, height;        /* the coded picture's */
    double dar;               /* its display aspect (the sample aspect applied), 0 unknown */
    int raw;                  /* a raw .264 / .h264 stream: no timestamps (written without a PTS: the
                                 core paces it from the VUI), no seeking, no audio */
    int cavlc;                /* (cavlc_ok) the stream is CAVLC: rewritten into CABAC as it is written
                                 (set once its first access unit was checked) */
    char video[32];           /* the video's format ("h264", "hevc", ...; "" none) */
    int sw;                   /* (arm_video) decoded on the ARM, shown as pictures */
    struct player_track *audio;
    unsigned n_audio;
    int audio_cur;            /* the stream played (-1 none) */
    struct player_track *subs;   /* the text tracks (text_subs), in player_subs()' order */
    unsigned n_subs;
};

enum player_state {
    PL_OPENING,               /* the reader thread is opening the URL */
    PL_READY,                 /* (hold) the first IDR is checked and held: release it to start writing */
    PL_RUNNING,               /* packets flowing into the ring */
    PL_DRAINED,               /* the last access unit written with END_OF_STREAM */
    PL_UNDECODABLE,           /* h264check said no: player_check() says why */
    PL_FAILED,                /* the URL did not open / the demuxer failed */
};

int  player_open(struct player **pp, const struct player_cfg *cfg);
/* move what can be moved now; never blocks on the ring or the network */
enum player_state player_step(struct player *p, h264ring *r);
/* the item's time (seconds) of a 90 kHz presentation time (the STC): the start the stream was
 * asked for, plus the clock's distance from the stream's first picture. stc_running 0 (the
 * clock not anchored yet: the first picture not shown): the start. */
double player_position(const struct player *p, uint64_t stc, int stc_running);
void player_release(struct player *p);   /* after PL_READY: write from the held IDR on */
/* the stream's tracks and shape once it opened (state past PL_OPENING, or PL_FAILED after the open:
 * a file whose video is not H.264); NULL before */
const struct player_info *player_info(const struct player *p);
/* text subtitle track k's cues so far (text_subs; k < n_subs), times in the item's seconds as
 * player_position() gives them; NULL none. Grows as the demuxer reaches them (seconds ahead of
 * the picture); the player owns it. */
struct subs *player_subs(const struct player *p, unsigned k);
enum h264check player_check(const struct player *p);
const char *player_error(const struct player *p);
void player_close(struct player *p);

/* counters, for the log and the host test */
struct player_counts {
    uint64_t video_aus, audio_records, audio_bytes, dropped_before_idr, queue_full_waits;
    uint64_t rewrite_skipped;          /* (cavlc_ok) units the CAVLC rewrite could not parse, dropped */
    uint64_t pictures, pics_late, pics_nonref;   /* (arm_video) pictures sent; dropped late; seconds
                                                    decoded reference pictures only (behind) */
    int64_t audio_lead_max;            /* 90 kHz: the most the stream's audio came ahead of its video */
    uint64_t audio_held;               /* video packets taken while the audio waited (AUD_LEAD) */
    uint64_t audio_forced;             /* audio packets let through early: nothing else could come */
};
void player_counts(const struct player *p, struct player_counts *c);

#endif
