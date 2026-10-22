#!/usr/bin/env bash
# make_clips.sh -- the Phase 3 hardware gate's clips (docs/roadmap.md P3k): synthetic x264
# Main streams -- the decoder is Main until Phase 5 -- generated here, never committed.
#
#   tools/p3/make_clips.sh OUTDIR
#     p60.264    720x480p59.94, 10 s, B frames, 2 slices, VUI timing (the display paces it)
#     film.264   720x480, 23.976 frames/s coded, 10 s, B frames (3:2 on the 59.94 raster)
#     sun.264    720x480p59.94, 10 s, P only, 1 slice, 1 reference (Sunshine's shape, Main)
#     switch.264 720x480p59.94, 5 s, another pattern: the --switch target
# Needs ffmpeg with libx264.
set -euo pipefail
OUT=$1; mkdir -p "$OUT"
enc() {   # src rate frames params out
  ffmpeg -v error -y -f lavfi -i "$1=size=720x480:rate=$2" -frames:v "$3" -pix_fmt yuv420p \
    -c:v libx264 -profile:v main -level 31 -x264-params "$4" "$OUT/$5"
  echo "  $5: $(stat -c%s "$OUT/$5") bytes"
}
enc testsrc2   60000/1001 600 "bframes=2:slices=2:keyint=120:bitrate=4000:vbv-maxrate=6000:vbv-bufsize=4000" p60.264
enc mandelbrot 24000/1001 240 "bframes=3:keyint=48:bitrate=2000:vbv-maxrate=4000:vbv-bufsize=4000" film.264
enc testsrc2   60000/1001 600 "bframes=0:ref=1:slices=1:keyint=600:bitrate=6000:vbv-maxrate=6000:vbv-bufsize=100" sun.264
enc smptehdbars 60000/1001 300 "bframes=2:keyint=60:bitrate=2000" switch.264
