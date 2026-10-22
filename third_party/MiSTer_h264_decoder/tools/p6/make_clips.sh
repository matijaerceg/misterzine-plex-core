#!/usr/bin/env bash
# make_clips.sh -- P6 part 2's hardware clips (docs/analog.md §8-§10): synthetic x264 High
# streams generated here, never committed.
#
#   tools/p6/make_clips.sh OUTDIR
#     p60x.264    720x480p at EXACTLY 60.000 frames/s (VUI 1000 / 120000, a Sunshine
#                 stream's tick): Refresh Rate Auto -> 60.00 Hz
#     pal50.264   720x576p at 50 frames/s, SAR 12:11 (BT.601 PAL): Auto -> 50 Hz, snapped 1:1
#     pal25.264   720x576 at 25 frames/s coded: Auto -> 50 Hz, two refreshes a frame
#     twitter.264 720x480p59.94, one-line horizontal grid lines (every 8th row) over a
#                 moving test pattern: the anti-twitter A/B on a 15 kHz display
#     mark480.264 / mark576.264  black, one-line white markers at frame lines 100, 201, 300
#                 (720x480 at 59.94 / 720x576 at 50): field order on a real scaler -- with
#                 Analog Aspect = Fit (1:1) the markers are 101 then 99 lines apart; with the
#                 fields swapped, 99 then 101 (history.md §7's method)
#     still.264   720x480p59.94, a STILL picture: one-line white grid lines every 8 rows on
#                 black -- on the analog capture any frame-to-frame change is flicker
#                 (twitter), not motion: the anti-twitter measurement
# Needs ffmpeg with libx264.
set -euo pipefail
OUT=$1; mkdir -p "$OUT"
enc() {   # lavfi-source rate frames vf x264-params out [extra ffmpeg args]
  ffmpeg -v error -y -f lavfi -i "$1" -r "$2" -frames:v "$3" -vf "$4" -pix_fmt yuv420p \
    -c:v libx264 -profile:v high -level 31 -x264-params "$5" "${@:7}" "$OUT/$6"
  echo "  $6: $(stat -c%s "$OUT/$6") bytes, $(ffprobe -v error -select_streams v -show_entries stream=width,height,r_frame_rate,sample_aspect_ratio -of csv=p=0 "$OUT/$6")"
}
enc "testsrc2=size=720x480:rate=60" 60 600 "null" "bframes=0:keyint=120:bitrate=6000:vbv-maxrate=8000:vbv-bufsize=4000" p60x.264
enc "testsrc2=size=720x576:rate=50" 50 500 "setsar=12/11" "bframes=2:keyint=100:bitrate=5000:vbv-maxrate=8000:vbv-bufsize=4000" pal50.264
enc "mandelbrot=size=720x576:rate=25" 25 250 "setsar=12/11" "bframes=3:keyint=50:bitrate=3000:vbv-maxrate=6000:vbv-bufsize=4000" pal25.264
enc "testsrc2=size=720x480:rate=60000/1001" 60000/1001 600 "drawgrid=w=720:h=8:t=1:c=white" "bframes=2:keyint=120:bitrate=6000" twitter.264
M="drawbox=y=100:w=720:h=1:t=fill:c=white,drawbox=y=201:w=720:h=1:t=fill:c=white,drawbox=y=300:w=720:h=1:t=fill:c=white"
enc "color=black:size=720x480:rate=60000/1001" 60000/1001 300 "$M" "bframes=0:keyint=60:crf=8" mark480.264
enc "color=black:size=720x576:rate=50" 50 250 "$M" "bframes=0:keyint=50:crf=8" mark576.264
enc "color=black:size=720x480:rate=60000/1001" 60000/1001 300 "drawgrid=w=90:h=8:t=1:c=white" "bframes=0:keyint=60:crf=8" still.264
# the VUI ticks the Auto rule reads (num_units_in_tick / time_scale)
for c in p60x pal50 pal25 twitter mark480 mark576; do
  printf '  %-8s VUI tick: %s\n' "$c" "$(ffmpeg -hide_banner -i "$OUT/$c.264" -c copy -bsf:v trace_headers -frames:v 1 -f null - 2>&1 \
    | grep -m2 -E 'num_units_in_tick|time_scale' | awk '{print $NF}' | paste -sd/)"
done
