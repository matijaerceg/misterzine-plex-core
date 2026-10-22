#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# clients/jellyfin/tests/run_test.sh [--red] -- the Jellyfin client's host test (docs/jellyfin.md
# S6 "Gates"; tests/README.md): the client (src/, -DCLIENT_TEST) against a fake core (test_client.c)
# AND a scripted fake Jellyfin server (fake_server.py), scored by check_client.py with
# tools/ring_model.py's consumer and references ffmpeg makes from the fixtures.
#   --red   also prove each check can fail: every mutation of the client (applied to a COPY of
#           src/ and ../common/, compiled from the copy) must be caught by ITS OWN check (the label)
# Needs: host gcc, pkg-config with FFmpeg's libavformat / libavcodec / libswresample / libavutil
# and libcurl (with WebSockets), ffmpeg + ffprobe with libx264 (the fixtures), python3, and the
# DejaVu typefaces (JF_FONT_DIR, default /usr/share/fonts/TTF). Fixtures and runs live in
# .sim/jellyfin_test/ (gitignored; regenerated when this script's recipe changes).
set -u
here=$(cd "$(dirname "$0")" && pwd)
client=$(cd "$here/.." && pwd)
repo=$(cd "$client/../.." && pwd)
src=$client/src
common=$client/../common
work=$repo/.sim/jellyfin_test
media=$work/media
fonts=${JF_FONT_DIR:-/usr/share/fonts/TTF}
PKGS="libavformat libavcodec libswresample libavutil libcurl"

for t in gcc pkg-config ffmpeg ffprobe python3; do
  command -v "$t" >/dev/null || { echo "run_test: $t is needed"; exit 2; }
done
pkg-config --exists $PKGS || { echo "run_test: pkg-config cannot find $PKGS"; exit 2; }
for f in DejaVuSans.ttf DejaVuSans-Bold.ttf; do
  [ -f "$fonts/$f" ] || { echo "run_test: $fonts/$f missing (set JF_FONT_DIR)"; exit 2; }
done
make -C "$repo/hps" >/dev/null || { echo "run_test: hps/ host build failed"; exit 2; }
mkdir -p "$work"

# ---- the fixtures (generated, never committed) ----
RECIPE=7     # bump when a fixture's recipe below changes
fixtures() {
  # the stamp: the recipe AND the ffmpeg that made the references (the client links the same libraries)
  local stamp="$RECIPE $(ffmpeg -version | head -1)"
  [ -f "$media/recipe" ] && [ "$(cat "$media/recipe")" = "$stamp" ] && return 0
  rm -rf "$media"; mkdir -p "$media/hls"
  local pic="testsrc2=size=640x360:rate=25"
  # a chirp in each channel: no period, so the reference matches the client's PCM at one offset only
  local snd="aevalsrc=0.3*sin(2*PI*(200+60*t)*t)|0.25*sin(2*PI*(330+41*t)*t):s=48000:c=stereo"
  local x264="keyint=25:min-keyint=25:scenecut=0"
  local ff=(ffmpeg -nostdin -y -loglevel error)
  # A: direct play -- High, CABAC, 640x360, 25 frames/s, 12 s, an IDR every second, AAC stereo
  # (PNS off: the noise substitution's generator would differ in a decoder started mid-stream)
  "${ff[@]}" -f lavfi -i "$pic" -f lavfi -i "$snd" -t 12 -map 0:v -map 1:a -c:v libx264 -profile:v high \
      -preset veryfast -x264-params "$x264" -pix_fmt yuv420p -c:a aac -aac_pns 0 -b:a 128k "$media/A.mkv" || return 1
  # B: the same picture coded CAVLC (High) -- the server cannot see it; and its transcode as HLS
  "${ff[@]}" -f lavfi -i "$pic" -f lavfi -i "$snd" -t 8 -map 0:v -map 1:a -c:v libx264 -profile:v high \
      -preset veryfast -x264-params "$x264:cabac=0" -pix_fmt yuv420p -c:a aac -aac_pns 0 -b:a 128k "$media/B.mkv" || return 1
  "${ff[@]}" -f lavfi -i "$pic" -f lavfi -i "$snd" -t 8 -map 0:v -map 1:a -c:v libx264 -profile:v high \
      -preset veryfast -x264-params "$x264" -pix_fmt yuv420p -c:a aac -aac_pns 0 -b:a 128k \
      -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_filename "$media/hls/seg%d.ts" "$media/hls/main.m3u8" || return 1
  # C: the pad's item -- 300 s of one colour (seeks of +90 s and +180 s fit; a few hundred KB), High
  # CABAC, an IDR every second, no audio
  "${ff[@]}" -f lavfi -i "color=c=0x336699:size=320x180:rate=25" -t 300 -c:v libx264 -profile:v high \
      -preset veryfast -x264-params "$x264" -pix_fmt yuv420p "$media/C.mkv" || return 1
  # D: the transcode of 2026-10-09 (docs/jellyfin.md S12) -- its audio first after 3 s of video (past
  # the probe's reach: no sample rate), then up to 6.5 s AHEAD of its video in the stream (the server's
  # muxer; the core keeps only 5.12 s it has not played). One 10 s segment; tools/ts_skew.py moves the
  # audio's PES units, every timestamp as encoded
  mkdir -p "$media/hlsD"
  "${ff[@]}" -f lavfi -i "$pic" -f lavfi -i "$snd" -t 10 -map 0:v -map 1:a -c:v libx264 -profile:v high \
      -preset veryfast -x264-params "$x264" -pix_fmt yuv420p -c:a aac -aac_pns 0 -b:a 128k -f mpegts "$media/D_src.ts" || return 1
  python3 "$repo/tools/ts_skew.py" "$media/D_src.ts" "$media/hlsD/dseg0.ts" --lead 6.5 --audio-from 3 > "$media/D.skew" || return 1
  printf '#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:10.000000,\ndseg0.ts\n#EXT-X-ENDLIST\n' > "$media/hlsD/main.m3u8"
  "${ff[@]}" -copyts -i "$media/hlsD/dseg0.ts" -map 0:v -c copy -f h264 "$media/D.h264" || return 1
  "${ff[@]}" -copyts -i "$media/hlsD/dseg0.ts" -map 0:v -c copy -f framemd5 "$media/D.framemd5" || return 1
  "${ff[@]}" -i "$media/D_src.ts" -map 0:a -f s16le -ac 2 -ar 48000 "$media/D.pcm" || return 1
  # the file's order (pos) and times of every packet: check_client.py proves the skew is there
  ffprobe -v error -show_entries packet=stream_index,pts,pos -of csv=p=0 "$media/hlsD/dseg0.ts" > "$media/D.packets" || return 1
  printf '1\n00:00:00,500 --> 00:00:02,500\nThe first cue\n\n2\n00:00:03,000 --> 00:00:05,500\n<i>The second</i> cue\n\n3\n00:00:06,500 --> 00:00:09,000\nThe third cue\non two lines\n\n4\n00:00:09,500 --> 00:00:11,500\nThe last cue\n' > "$media/A.srt"
  # the references (-copyts: the CLI would otherwise rebase every timestamp to start at 0)
  "${ff[@]}" -copyts -i "$media/A.mkv" -map 0:v -c copy -bsf:v h264_mp4toannexb -f h264 "$media/A.h264" || return 1
  "${ff[@]}" -copyts -i "$media/A.mkv" -map 0:v -c copy -bsf:v h264_mp4toannexb -f framemd5 "$media/A.framemd5" || return 1
  "${ff[@]}" -i "$media/A.mkv" -map 0:a -f s16le -ac 2 -ar 48000 "$media/A.pcm" || return 1
  "${ff[@]}" -copyts -i "$media/C.mkv" -map 0:v -c copy -bsf:v h264_mp4toannexb -f framemd5 "$media/C.framemd5" || return 1
  "${ff[@]}" -copyts -i "$media/B.mkv" -map 0:v -c copy -bsf:v h264_mp4toannexb -f framemd5 "$media/B.framemd5" || return 1
  "${ff[@]}" -copyts -i "$media/hls/main.m3u8" -map 0:v -c copy -f h264 "$media/hls.h264" || return 1
  "${ff[@]}" -copyts -i "$media/hls/main.m3u8" -map 0:v -c copy -f framemd5 "$media/hls.framemd5" || return 1
  local a b c h t0 d d0
  a=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$media/A.mkv")
  b=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$media/B.mkv")
  c=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$media/C.mkv")
  h=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$media/hls/main.m3u8")
  t0=$(ffprobe -v error -select_streams a -show_entries frame=pts_time -read_intervals "%+1" -of csv=p=0 "$media/A.mkv" | head -1)
  d=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$media/hlsD/main.m3u8")
  d0=$(ffprobe -v error -select_streams a -show_entries frame=pts_time -read_intervals "%+1" -of csv=p=0 "$media/D_src.ts" | head -1)
  printf '{"A_start": %s, "B_start": %s, "C_start": %s, "hls_start": %s, "A_audio_t0": %s, "D_start": %s, "D_audio_t0": %s}\n' \
      "$a" "$b" "$c" "$h" "$t0" "$d" "$d0" > "$media/fixtures.json"
  echo "$stamp" > "$media/recipe"
}
fixtures || { echo "run_test: the fixtures failed"; rm -rf "$media"; exit 2; }

build() {   # $1 = the root to compile (src/ and common/ in it), $2 = the binary
  rm -f "$2"   # a failed build must not leave the previous binary to run
  gcc -O2 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE -DCLIENT_TEST -Wall -Wextra -Wno-deprecated-declarations \
      -I"$repo/hps/include" -I"$1/src" -I"$1/common" -I"$client/third_party/cjson" -I"$1/common/third_party/stb" \
      $(pkg-config --cflags $PKGS) "$here/test_client.c" "$1"/src/*.c "$1"/common/*.c "$client/third_party/cjson/cJSON.c" \
      "$repo/hps/build/host/libh264ring.a" $(pkg-config --libs $PKGS) -lm -lpthread -o "$2" 2> "$2.build.log"
}

run() {     # $1 = binary, $2 = the run's directory; returns 0 when both halves are GREEN
  local d=$2 port spid
  rm -rf "$d"; mkdir -p "$d/dir" "$d/out"
  cp "$fonts/DejaVuSans.ttf" "$fonts/DejaVuSans-Bold.ttf" "$d/dir/"
  python3 "$here/fake_server.py" --dir "$d/dir" --media "$media" --log "$d/server.json" --portfile "$d/port" \
      --runtime-a 12 --runtime-b 8 --runtime-c 300 --runtime-d 10 > "$d/server.log" 2>&1 &
  spid=$!
  for _ in $(seq 100); do [ -f "$d/port" ] && break; sleep 0.05; done
  [ -f "$d/port" ] || { echo "fake_server did not start" > "$d/log"; kill $spid 2>/dev/null; return 1; }
  port=$(cat "$d/port")
  printf 'server=http://127.0.0.1:%s\nname=MiSTer test\n' "$port" > "$d/dir/jellyfin.ini"
  timeout 200 "$1" "$d/dir" "$d/out" 150 > "$d/log" 2>&1
  touch "$d/dir/client_done"
  wait $spid
  cat "$d/server.log" >> "$d/log"
  python3 "$here/check_client.py" "$d/out" "$d/server.json" "$media" >> "$d/log" 2>&1
  grep -q "^test_client: ALL GREEN" "$d/log" && grep -q "^check_client: ALL GREEN" "$d/log"
}

bin=$client/build/test/test_client
mkdir -p "$client/build/test"
# the GREEN build from a staging root that only links the two trees (the mutants' roots are copies)
stage=$client/build/test/root
rm -rf "$stage"; mkdir -p "$stage"; ln -s "$src" "$stage/src"; ln -s "$(cd "$common" && pwd)" "$stage/common"
build "$stage" "$bin" || { cat "$bin.build.log"; echo "run_test: build failed"; exit 1; }
[ -x "$bin" ] || { echo "run_test: build failed"; exit 1; }
if run "$bin" "$work/green"; then
  grep -E "^  (PASS|FAIL) |^fake_server:" "$work/green/log"
  echo "GREEN"
else
  grep -vE "^jellyfin: |^ui: |^player: |^core: " "$work/green/log" | tail -60
  echo "run_test: FAILURES (the whole log: .sim/jellyfin_test/green/log)"
  exit 1
fi
[ "${1:-}" = "--red" ] || { echo "run_test: ALL GREEN"; exit 0; }

# ---- --red: each mutation (mutations.py), on a COPY of src/, and the check that must catch it ----
red_fail=0
summary=()
for name in $(python3 "$here/mutations.py" list); do
  [ -n "${JF_RED_ONLY:-}" ] && [ "$name" != "$JF_RED_ONLY" ] && continue   # JF_RED_ONLY=NAME: that mutation alone
  label=$(python3 "$here/mutations.py" label "$name")
  m=$work/red_$name
  rm -rf "$m"; mkdir -p "$m"; cp -r "$src" "$m/src"; cp -r "$common" "$m/common"
  if ! python3 "$here/mutations.py" apply "$name" "$m"; then
    echo "  RED $name: the mutation did not apply"; red_fail=1; summary+=("$name|did not apply|$label"); continue
  fi
  if diff -rq "$src" "$m/src" >/dev/null && diff -rq "$common" "$m/common" >/dev/null; then
    echo "  RED $name: the copy is unchanged"; red_fail=1; summary+=("$name|did not apply|$label"); continue
  fi
  if ! build "$m" "$m/test_client" || [ ! -x "$m/test_client" ]; then
    echo "  RED $name: the mutant did not build"; red_fail=1; summary+=("$name|did not build|$label"); continue
  fi
  run "$m/test_client" "$m/run"
  if grep -F "  FAIL $label" "$m/run/log" >/dev/null; then
    echo "  RED $name: caught by its own check"
    summary+=("$name|caught|$label")
  else
    echo "  RED $name: NOT caught by \"$label\""; red_fail=1; summary+=("$name|NOT caught|$label")
  fi
done

echo
printf '  %-16s %-12s %s\n' "mutation" "result" "its own check"
for row in "${summary[@]}"; do
  IFS='|' read -r n r l <<< "$row"
  printf '  %-16s %-12s %s\n' "$n" "$r" "$l"
done
[ $red_fail = 0 ] && echo "run_test: ALL GREEN (and RED)" || { echo "run_test: RED FAILURES"; exit 1; }
