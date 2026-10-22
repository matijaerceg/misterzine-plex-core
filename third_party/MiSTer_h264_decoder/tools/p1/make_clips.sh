#!/usr/bin/env bash
# make_clips.sh -- Phase 1's proxy streams (docs/p1_measurements.md "Streams").
#
#   tools/p1/make_clips.sh SOURCE_VIDEO START_SECONDS OUTDIR
#
# A 5 s segment of SOURCE, cropped to 3:2, scaled to 720x480 and motion-interpolated to
# 59.94 frames/s (distinct frames: duplicated ones would compress to skips and understate
# the decoder's load), then encoded as:
#   x264_main_12M.264     libx264 Main, zerolatency (7 slices), 12 Mbit/s
#   nvenc_main_12M.264    NVENC Main, low latency, CBR, 3 refs (driver default), 12 Mbit/s
#   nvenc_high_12M.264    the same at High (header analysis only: 8x8 transform)
#   sun_main_{2,4,8,12}M.264  NVENC Main (2M = 1988 kbit/s: moonlight-qt's default
#                         3,000 kbit/s request after Sunshine's FEC / audio / overhead cuts), shaped like a stock Sunshine session with a Moonlight
#                         client that leaves RFI off: 1 slice, refs 1, no B, CBR, VBV of one
#                         frame, infinite GOP (Sunshine sends High; Main is what this decoder
#                         can play -- the profile is the one difference)
#   sun_high_8M.264       the Sunshine shape at High, as a stock host sends it
# Needs ffmpeg with libx264 and h264_nvenc. Media never goes into the repository.
set -euo pipefail
SRC=$1; T=$2; OUT=$3
mkdir -p "$OUT"
ffmpeg -v error -y -ss "$T" -t 5.3 -i "$SRC" \
  -vf "crop=ih*3/2:ih,scale=720:480:flags=lanczos,minterpolate=fps=60000/1001:mi_mode=mci:mc_mode=aobmc:me_mode=bidir:vsbmc=1,format=yuv420p" \
  -frames:v 300 -an "$OUT/src60.y4m"
Y=$OUT/src60.y4m
ffmpeg -v error -y -i "$Y" -c:v libx264 -profile:v main -level 31 -preset veryfast -tune zerolatency \
  -b:v 12M -maxrate 12M -bufsize 400k -x264-params pic-struct=1:keyint=600 "$OUT/x264_main_12M.264"
for p in main high; do
  ffmpeg -v error -y -i "$Y" -c:v h264_nvenc -profile:v $p -preset p1 -tune ull -rc cbr -b:v 12M \
    -bufsize 200k -bf 0 -g 600 "$OUT/nvenc_${p}_12M.264"
done
for b in 1988 4000 8000 12000; do
  n=$(( (b + 500) / 1000 ))
  ffmpeg -v error -y -i "$Y" -c:v h264_nvenc -profile:v main -preset p1 -tune ull -rc cbr -b:v ${b}k \
    -bufsize $((b / 60))k -bf 0 -refs 1 -g 100000 -slices 1 "$OUT/sun_main_${n}M.264"
done
ffmpeg -v error -y -i "$Y" -c:v h264_nvenc -profile:v high -preset p1 -tune ull -rc cbr -b:v 8M \
  -bufsize 133k -bf 0 -refs 1 -g 100000 -slices 1 "$OUT/sun_high_8M.264"
ls -la "$OUT"/*.264
