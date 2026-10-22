#!/usr/bin/env bash
# capture_sunshine.sh -- record what a Sunshine host actually sends a Moonlight client
# (docs/p1_measurements.md §2b). A stock moonlight-embedded client with one addition
# (tools/p1/moonlight_dump.patch: "-platform fake" writes the video to a file) streams the
# host's "Desktop" app at 720x480@60, H.264 only, view-only, one session per bitrate, while
# mpv plays CLIP fullscreen on the host's display (so the stream carries known, moving
# content and nothing personal).
#
#   tools/p1/capture_sunshine.sh MOONLIGHT_BIN CLIP OUTDIR [BITRATE_KBPS...]   (default 3000 10000 16000)
#
# (Since the Moonlight client work: clients/moonlight/build.sh builds this client for the
#  MiSTer with the dump in its patch series -- docs/moonlight.md. The recipe below is the
#  workstation build Phase 1 used.)
# Build the client once:
#   git clone --depth 1 --recurse-submodules --shallow-submodules \
#       https://github.com/moonlight-stream/moonlight-embedded.git
#   git -C moonlight-embedded apply tools/p1/moonlight_dump.patch
#   cmake -S moonlight-embedded -B moonlight-embedded/build && make -C moonlight-embedded/build
#   moonlight-embedded/build/moonlight pair localhost      # enter the PIN in Sunshine's web UI
# The client asks for 1 slice and declares no reference frame invalidation (the simplest
# stream shape); the bitrate is the CLIENT request (Sunshine encodes ~0.73x of it).
set -u
ML=$1; CLIP=$2; OUT=$3; shift 3
rates=("$@"); [ ${#rates[@]} -gt 0 ] || rates=(3000 10000 16000)
mkdir -p "$OUT"
mpv --fs --loop-file=inf --no-audio --osd-level=0 --no-osc --really-quiet "$CLIP" > "$OUT/mpv.log" 2>&1 &
MPV=$!
sleep 4
for b in "${rates[@]}"; do
  echo "== session $b kbit/s $(date +%T)"
  MOONLIGHT_DUMP=$OUT/cap_${b}.h264 "$ML" stream localhost -app Desktop -width 720 -height 480 -fps 60 \
    -bitrate "$b" -codec h264 -platform fake -viewonly -nosops -quitappafter > "$OUT/cap_${b}.log" 2>&1 &
  M=$!
  sleep 22
  kill -INT $M 2>/dev/null; sleep 3; kill -0 $M 2>/dev/null && kill $M
  wait $M 2>/dev/null
  echo "   $(stat -c%s "$OUT/cap_${b}.h264" 2>/dev/null || echo 0) bytes"
  sleep 3
done
kill $MPV 2>/dev/null
