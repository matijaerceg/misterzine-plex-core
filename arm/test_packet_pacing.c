#include "packet_pacing.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    struct packet_pacing s = {.has_audio=1,.pcm_frames=640,
        .video_written=90000,.audio_written=90000,.video_pts=180000,.audio_pts=INT64_MIN};
    /* The original dropout: partial PCM and no queued audio must not let
       a burst of video run seconds ahead while the next audio is fetched. */
    assert(!packet_video_ready(s,960,9000));
    s.audio_written=INT64_MIN;
    assert(!packet_video_ready(s,960,9000));
    s.video_written=INT64_MIN;
    assert(packet_video_ready(s,960,9000)); /* establish the first video clock */
    s.video_written=90000;s.audio_written=90000;s.video_pts=99000;
    assert(packet_video_ready(s,960,9000));
    s.video_pts=180000;s.reader_done=1;
    assert(packet_video_ready(s,960,9000)); /* EOF with a partial audio record */
    s.reader_done=0;s.reader_blocked=1;
    assert(packet_video_ready(s,960,9000)); /* bounded queue cannot deadlock */
    s.pcm_frames=960;
    assert(!packet_video_ready(s,960,9000)); /* write a complete record first */
    s.reader_blocked=0;s.pcm_frames=640;s.audio_queued=1;s.audio_pts=270000;
    assert(packet_video_ready(s,960,9000)); /* known silence between timestamps */
    s.audio_pts=90000;
    assert(!packet_video_ready(s,960,9000)); /* audio is still due */
    s.has_audio=0;
    assert(packet_video_ready(s,960,9000));
    puts("packet pacing checks passed");
}
