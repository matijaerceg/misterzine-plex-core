#!/usr/bin/env bash
# make_clips.sh -- Phase 4's hardware clips (docs/architecture.md "Audio (Phase 4)", its
# gates): synthetic, generated here, never committed.
#
#   tools/p4/make_clips.sh OUTDIR
#     avsync.264 / avsync.pcm   720x480p59.94, black; frame 60k (every second) white. The
#               audio: 48 kHz s16le stereo, silent but for a 30 ms 1 kHz beep starting at
#               exactly each flash's time (1 s, 2 s, ...). Played with
#                 h264play --pts --pcm avsync.pcm avsync.264
#               both are stamped from 0; captured through the HDMI card (picture and sound),
#               the delay from a flash's first frame to its beep's onset IS the A/V offset
#     tone.pcm  20 s of a 440 Hz tone at -12 dBFS: --atten and --pause by ear / on the capture
#               (h264play --audio-only --pcm tone.pcm: the audio anchor, no picture)
# Needs ffmpeg with libx264. No B-frames (h264play --pts stamps access units in order).
set -euo pipefail
OUT=$1; mkdir -p "$OUT"
DUR=${DUR:-30}
ffmpeg -v error -y -f lavfi -i "color=c=black:s=720x480:r=60000/1001:d=$DUR" \
  -vf "drawbox=x=0:y=0:w=720:h=480:c=white:t=fill:enable='eq(mod(n\,60)\,59)'" \
  -pix_fmt yuv420p -c:v libx264 -profile:v high -level 31 \
  -x264-params "bframes=0:keyint=60:bitrate=3000" "$OUT/avsync.264"
# the flash is frame 60k-1 (0-based), shown at (60k-1) x 1001/60000 s: the beep starts there
ffmpeg -v error -y -f lavfi \
  -i "aevalsrc='if(lt(mod(t+1001/60000\,60*1001/60000)\,0.03)*gt(t\,0.5)\,0.5*sin(2*PI*1000*t)\,0)|if(lt(mod(t+1001/60000\,60*1001/60000)\,0.03)*gt(t\,0.5)\,0.5*sin(2*PI*1000*t)\,0)':s=48000:d=$DUR" \
  -f s16le -ar 48000 -ac 2 "$OUT/avsync.pcm"
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=20" \
  -af "volume=-12dB" -f s16le -ar 48000 -ac 2 "$OUT/tone.pcm"
for f in avsync.264 avsync.pcm tone.pcm; do echo "  $f: $(stat -c%s "$OUT/$f") bytes"; done
