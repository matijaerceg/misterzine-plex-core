#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# clients/player/tests/run_test.sh [--red] -- the file player's host test (docs/player.md "Gates";
# tests/README.md): the player (src/ + ../common/, -DCLIENT_TEST) against a fake core driven by a
# scripted pad (test_player.c), scored by check_player.py with tools/ring_model.py's consumer and
# references ffmpeg makes from the fixtures.
#   --red   also prove each check can fail: every mutation (applied to a COPY of src/ and
#           ../common/, compiled from the copy) must be caught by ITS OWN check (the label beside it)
# Needs: host gcc, pkg-config with FFmpeg's libavformat / libavcodec / libswresample / libavutil,
# ffmpeg + ffprobe with libx264 (the fixtures), python3, and the DejaVu typefaces (JF_FONT_DIR,
# default /usr/share/fonts/TTF). Fixtures and runs live in .sim/player_test/ (gitignored;
# regenerated when this script's recipe changes).
set -u
here=$(cd "$(dirname "$0")" && pwd)
client=$(cd "$here/.." && pwd)
repo=$(cd "$client/../.." && pwd)
src=$client/src
common=$(cd "$client/../common" && pwd)
work=$repo/.sim/player_test
media=$work/media
fonts=${JF_FONT_DIR:-/usr/share/fonts/TTF}
PKGS="libavformat libavcodec libswresample libavutil"

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
# The folder the player browses (sorted as the player sorts: folders first, then files):
#   a_dir/inner.mkv  120 s of one colour, 25 frames/s (50 Hz), an IDR a second, no audio: the seek
#   b_pal.mp4        3 s, 352x288 at 25 frames/s (50 Hz), MP4 (avcC), AAC
#   c_ok.mkv         8 s, 640x360 at 30 frames/s, AAC, an SRT track (default) and an ASS track
#   d_big.mkv        1344x720 (3,780 macroblocks: over 0.11's 3,600) at 24 frames/s (under the rate:
#                    only the size can refuse it), CAVLC: refused for its size
#                    (CAVLC alone would now play: the size must be found first -- h264check's order)
#   e_cavlc.mkv      1 s Baseline (CAVLC) 320x240: plays, the library's write call rewriting it (P6)
#   f_mpeg4.mkv      (0.15) MPEG-4 Part 2, 320x240 at 30: decoded on the ARM, sent as pictures (frames);
#                    a DTS 5.1 track, a tone in the CENTER only (2026-10-06: dca reports stereo at open
#                    under `downmix` and decodes 5.1 -- the player's stereo-built swr dropped the center)
#   g_fast.mkv       (0.11) 1280x720 at 60 frames/s: 3,600 macroblocks, but 216,000 a second -- refused
#                    by its rate (the core's 108,000) before the ring, not played at half speed
#   h_mpeg2i.mpg     (0.15) MPEG-2 352x240 interlaced (top field first) at 29.97, an MPEG program stream:
#                    decoded on the ARM, sent as woven field pairs
#   i_mjpeg.avi      (0.15) MJPEG 320x240 at 30, 4:2:2 full range (yuvj422p): converted to 4:2:0 limited
#   j_ffv1.mkv       (0.15) FFV1: refused (not a codec the MiSTer decodes)
#   k_hd.mkv         (0.15) MPEG-4 Part 2 1280x720: refused (larger than SD: the ARM's budget)
#   l_ahead.ts       8 s, 320x240 at 25, AAC, its audio up to 6.5 s AHEAD of its video in the file
#                    (tools/ts_skew.py; docs/jellyfin.md S12): the player holds it to ~1 s ahead
#   m_late.ts        6 s, the same, no audio in the file's first 3 s of video: past the probe (no
#                    sample rate), played all the same
#   .hidden.mkv      a hidden file: never listed (it would sort first and shift every press)
#   aa_notes.txt     not a video: never listed (likewise)
RECIPE=9     # bump when a fixture's recipe below changes
fixtures() {
  local stamp="$RECIPE $(ffmpeg -version | head -1)"
  [ -f "$media/recipe" ] && [ "$(cat "$media/recipe")" = "$stamp" ] && return 0
  rm -rf "$media"; mkdir -p "$media/root/a_dir"
  local R=$media/root
  local snd="aevalsrc=0.3*sin(2*PI*(200+60*t)*t)|0.25*sin(2*PI*(330+41*t)*t):s=48000:c=stereo"
  local ff=(ffmpeg -nostdin -y -loglevel error)
  local x264=(-c:v libx264 -profile:v high -preset veryfast -pix_fmt yuv420p)
  "${ff[@]}" -f lavfi -i "color=c=0x663399:size=320x180:rate=25" -t 120 "${x264[@]}" \
      -x264-params keyint=25:min-keyint=25:scenecut=0 "$R/a_dir/inner.mkv" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=352x288:rate=25" -f lavfi -i "$snd" -t 3 -map 0:v -map 1:a "${x264[@]}" \
      -x264-params keyint=25:min-keyint=25:scenecut=0 -c:a aac -b:a 128k "$R/b_pal.mp4" || return 1
  printf '1\n00:00:00,500 --> 00:00:02,500\nThe first cue\n\n2\n00:00:06,000 --> 00:00:07,500\n<i>The last</i> cue\n' > "$media/c.srt"
  cat > "$media/c.ass" <<'EOF'
[Script Info]
ScriptType: v4.00+
PlayResX: 640
PlayResY: 360

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,Arial,20,&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,1,0,2,10,10,10,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
Dialogue: 0,0:00:03.00,0:00:05.50,Default,,0,0,0,,{\p1}m 0 0 l 100 0 100 100{\p0}
Dialogue: 0,0:00:03.00,0:00:05.50,Default,,0,0,0,,{\i1}An ASS line{\i0}\Non two
EOF
  "${ff[@]}" -f lavfi -i "testsrc2=size=640x360:rate=30" -f lavfi -i "$snd" -i "$media/c.srt" -i "$media/c.ass" \
      -t 8 -map 0:v -map 1:a -map 2:s -map 3:s "${x264[@]}" -x264-params keyint=30:min-keyint=30:scenecut=0 \
      -c:a aac -b:a 128k -c:s:0 srt -c:s:1 ass -disposition:s:0 default -disposition:s:1 0 "$R/c_ok.mkv" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=1344x720:rate=24" -t 1 "${x264[@]}" -x264-params cabac=0 "$R/d_big.mkv" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=320x240:rate=30" -t 1 -c:v libx264 -profile:v baseline -preset veryfast \
      -pix_fmt yuv420p "$R/e_cavlc.mkv" || return 1
  # its pictures, decoded: what the rewritten stream must decode to as well (lossless)
  "${ff[@]}" -i "$R/e_cavlc.mkv" -map 0:v -f framemd5 "$media/e_cavlc.decoded.framemd5" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=320x240:rate=30" -f lavfi -i "sine=f=440:r=48000" -t 1 -map 0:v -map 1:a \
      -c:v mpeg4 -af "pan=5.1(side)|FC=c0" -c:a dca -strict -2 -b:a 1509k "$R/f_mpeg4.mkv" || return 1
  # its audio as ffmpeg downmixes it (swr's default 5.1 -> stereo matrix: the player's)
  "${ff[@]}" -i "$R/f_mpeg4.mkv" -map 0:a -ac 2 -ar 48000 -f s16le "$media/f_mpeg4.pcm" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=60" -t 1 "${x264[@]}" "$R/g_fast.mkv" || return 1
  # (0.15) decoded on the ARM: MPEG-2 interlaced (B-pictures: reordered), MJPEG 4:2:2 full range; refused:
  # FFV1, an HD MPEG-4
  "${ff[@]}" -f lavfi -i "testsrc2=size=352x240:rate=60000/1001" -t 1.05 \
      -vf "tinterlace=interleave_top,setfield=tff" -c:v mpeg2video -flags +ildct+ilme -bf 2 -g 12 -b:v 2M \
      -f mpeg "$R/h_mpeg2i.mpg" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=320x240:rate=30" -t 1 -c:v mjpeg -pix_fmt yuvj422p -q:v 3 "$R/i_mjpeg.avi" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=320x240:rate=30" -t 1 -c:v ffv1 "$R/j_ffv1.mkv" || return 1
  "${ff[@]}" -f lavfi -i "testsrc2=size=1280x720:rate=30" -t 1 -c:v mpeg4 "$R/k_hd.mkv" || return 1
  # their decoded pictures (the references): each frame's PTS and the MD5 of its planes as yuv420p (the
  # store's own format, so the frames compare as they are), and MJPEG's source planes as decoded
  for n in f_mpeg4 h_mpeg2i; do
    "${ff[@]}" -copyts -i "$(ls "$R/$n".*)" -map 0:v -pix_fmt yuv420p -f framemd5 "$media/$n.decoded.framemd5" || return 1
    # each picture's time as the decoder gives it (best_effort_timestamp, the stream's time base): the
    # framemd5's are the output's, rescaled to an ideal rate
    { ffprobe -v error -select_streams v:0 -show_entries stream=time_base -of csv=p=0 "$(ls "$R/$n".*)"
      ffprobe -v error -select_streams v:0 -show_entries frame=best_effort_timestamp -of csv=p=0 "$(ls "$R/$n".*)"
    } > "$media/$n.times" || return 1
  done
  "${ff[@]}" -copyts -i "$R/i_mjpeg.avi" -map 0:v -pix_fmt yuvj422p -f framemd5 "$media/i_mjpeg.decoded.framemd5" || return 1
  "${ff[@]}" -i "$R/i_mjpeg.avi" -map 0:v -pix_fmt yuvj422p -f rawvideo "$media/i_mjpeg.yuvj422p" || return 1
  # (S12) the interleaves of 2026-10-09's transcode, in a file: audio far ahead; audio past the probe
  # (different pictures: the scorer tells the two sessions apart by their first access unit)
  local ts=(-f lavfi -i "$snd" -map 0:v -map 1:a "${x264[@]}" -x264-params keyint=25:min-keyint=25:scenecut=0
            -c:a aac -aac_pns 0 -b:a 128k -f mpegts)
  "${ff[@]}" -f lavfi -i "testsrc2=size=320x240:rate=25" "${ts[@]}" -t 8 "$media/l_src.ts" || return 1
  "${ff[@]}" -f lavfi -i "testsrc=size=320x240:rate=25" "${ts[@]}" -t 6 "$media/m_src.ts" || return 1
  python3 "$repo/tools/ts_skew.py" "$media/l_src.ts" "$R/l_ahead.ts" --lead 6.5 > "$media/l_ahead.skew" || return 1
  python3 "$repo/tools/ts_skew.py" "$media/m_src.ts" "$R/m_late.ts" --lead 0 --audio-from 3 > "$media/m_late.skew" || return 1
  for n in l_ahead m_late; do
    ffprobe -v error -show_entries packet=stream_index,pts,pos -of csv=p=0 "$R/$n.ts" > "$media/$n.packets" || return 1
    "${ff[@]}" -i "$R/$n.ts" -map 0:a -f s16le -ac 2 -ar 48000 "$media/$n.pcm" || return 1
  done
  cp "$R/e_cavlc.mkv" "$R/.hidden.mkv"
  echo "not a video" > "$R/aa_notes.txt"
  # the references (-copyts: the CLI would otherwise rebase every timestamp to start at 0)
  local n
  for n in a_dir/inner b_pal c_ok d_big e_cavlc f_mpeg4 g_fast j_ffv1 k_hd l_ahead m_late; do
    local f; f=$(ls "$R/$n".*)
    local b; b=$(basename "$n")
    "${ff[@]}" -copyts -i "$f" -map 0:v -c copy -bsf:v h264_mp4toannexb -f framemd5 "$media/$b.framemd5" 2>/dev/null ||
      "${ff[@]}" -copyts -i "$f" -map 0:v -c copy -f framemd5 "$media/$b.framemd5" || return 1
  done
  for n in a_dir/inner b_pal c_ok l_ahead m_late; do
    local b; b=$(basename "$n")
    "${ff[@]}" -copyts -i "$(ls "$R/$n".*)" -map 0:v -c copy -bsf:v h264_mp4toannexb -f h264 "$media/$b.h264" || return 1
  done
  local si sb sc l0 m0
  si=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$R/a_dir/inner.mkv")
  sb=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$R/b_pal.mp4")
  sc=$(ffprobe -v error -show_entries format=start_time -of csv=p=0 "$R/c_ok.mkv")
  l0=$(ffprobe -v error -select_streams a -show_entries frame=pts_time -read_intervals "%+1" -of csv=p=0 "$R/l_ahead.ts" | head -1)
  m0=$(ffprobe -v error -select_streams a -show_entries frame=pts_time -read_intervals "%+1" -of csv=p=0 "$R/m_late.ts" | head -1)
  printf '{"inner_start": %s, "b_pal_start": %s, "c_ok_start": %s, "l_ahead_audio_t0": %s, "m_late_audio_t0": %s}\n' \
      "$si" "$sb" "$sc" "$l0" "$m0" > "$media/fixtures.json"
  echo "$stamp" > "$media/recipe"
}
fixtures || { echo "run_test: the fixtures failed"; rm -rf "$media"; exit 2; }

# the pad's script (test_player.c runs it; check_player.py reads its log)
script() {
  cat <<'EOF'
sleep 1.5
press DOWN          # a_dir -> b_pal
press A             # play it (25 frames/s: 50 Hz asked for)
wait_played 1
wait_ended          # 3 s at the fake core's half speed; the folder plays on
wait_played 2       # c_ok (30 frames/s: Auto again), its SRT track on (default)
wait_stc 2.75       # the SRT's first cue has been on screen
press X             # the next subtitle track: the ASS one
wait_ended          # c_ok ends; the next file, d_big, is refused: the list
sleep 2
press DOWN          # e_cavlc
press A             # plays: CAVLC, rewritten into CABAC by the library's write call
wait_played 3
wait_ended          # its end plays f_mpeg4 on: MPEG-4, decoded on the ARM (0.15)
wait_played 4
wait_ended          # its end tries g_fast: 1280x720 at 60 frames/s, refused (too fast), the list
sleep 2
press DOWN          # h_mpeg2i
press A             # MPEG-2 interlaced, decoded on the ARM: field pairs
wait_played 5
wait_ended          # its end plays i_mjpeg on (MJPEG 4:2:2 full range)
wait_played 6
wait_ended          # its end tries j_ffv1: refused (FFV1), the list
sleep 2
press DOWN          # k_hd
press A             # MPEG-4 1280x720: refused (larger than SD), the list
sleep 2
press DOWN          # l_ahead
press A             # its audio 6.5 s ahead of its video in the file: held to ~1 s ahead
wait_played 7
wait_ended          # its end plays m_late on: its audio past the probe, played
wait_played 8
wait_ended          # the folder's end: the list
sleep 2
press LB            # a page up (twice: the list is longer than a page now): the top, a_dir
press LB
press A             # into a_dir
sleep 0.5
press A             # inner.mkv (25 frames/s: 50 Hz)
wait_played 9
wait_stc 1
press RIGHT         # +30 s: one seek, after the settle
wait_played 10
sleep 1.5
press BACK+START    # the list
sleep 0.5
press B             # up: the root, a_dir selected
sleep 9             # left alone: the screensaver dims at 3.6 s, goes black at 7.2 s (h264player.ini)
press DOWN          # wakes it -- and does nothing else
sleep 0.5
press A             # so this opens a_dir (a DOWN that moved would make it play b_pal)
sleep 0.5
press BACK+START    # quit: the player gives Auto back and ends
end
EOF
}

build() {   # $1 = the root to compile (src/ and common/ in it), $2 = the binary
  rm -f "$2"   # a failed build must not leave the previous binary to run
  gcc -O2 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE -DCLIENT_TEST -Wall -Wextra -Wno-deprecated-declarations \
      -I"$repo/hps/include" -I"$1/src" -I"$1/common" -I"$1/common/third_party/stb" \
      $(pkg-config --cflags $PKGS) "$here/test_player.c" "$1"/src/*.c "$1"/common/*.c \
      "$repo/hps/build/host/libh264ring.a" $(pkg-config --libs $PKGS) -lm -lpthread -o "$2" 2> "$2.build.log"
}

# /dev/fb0 is Main's HDMI mode's size (ui.c, docs/hd_raster.md S13): the main arm (and every mutant)
# on a 1280x720 mode's 3,686,400 bytes -- both rasters fit whole; the second on a 720x480 mode's
# 1,382,400 -- both drawn shorter (T8 / T9)
FB_720P=3686400
FB_480P=1382400
run() {     # $1 = binary, $2 = the run's directory, $3 = /dev/fb0's size; 0 when both halves are GREEN
  local d=$2
  rm -rf "$d"; mkdir -p "$d/dir" "$d/out"
  cp "$fonts/DejaVuSans.ttf" "$fonts/DejaVuSans-Bold.ttf" "$d/dir/"
  script > "$d/dir/script"
  # the screensaver's stages in seconds, not minutes (P5); the scenario's other idle stretches
  # in the list are at most ~2 s
  printf 'screensaver_dim=0.06\nscreensaver_black=0.12\n' > "$d/dir/h264player.ini"
  CLIENT_TEST_FB_LEN=${3:-$FB_720P} timeout 240 "$1" "$d/dir" "$media/root" "$d/out" 180 > "$d/log" 2>&1
  python3 "$here/check_player.py" "$d/out" "$d/log" "$media" >> "$d/log" 2>&1
  grep -q "^test_player: ALL GREEN" "$d/log" && grep -q "^check_player: ALL GREEN" "$d/log"
}

bin=$client/build/test/test_player
mkdir -p "$client/build/test"
stage=$client/build/test/root
rm -rf "$stage"; mkdir -p "$stage"; ln -s "$src" "$stage/src"; ln -s "$common" "$stage/common"
build "$stage" "$bin" || { cat "$bin.build.log"; echo "run_test: build failed"; exit 1; }
[ -x "$bin" ] || { echo "run_test: build failed"; exit 1; }
for arm in green:$FB_720P green_fb480:$FB_480P; do
  dir=${arm%%:*} fb=${arm#*:}
  if run "$bin" "$work/$dir" "$fb"; then
    grep -E "^  (PASS|FAIL) |^test_player: framebuffer" "$work/$dir/log"
    echo "GREEN ($dir: /dev/fb0 $fb bytes)"
  else
    grep -vE "^h264player: |^ui: |^player: |^core: " "$work/$dir/log" | tail -60
    echo "run_test: FAILURES (the whole log: .sim/player_test/$dir/log)"
    exit 1
  fi
done
[ "${1:-}" = "--red" ] || { echo "run_test: ALL GREEN"; exit 0; }

# ---- --red: each mutation (mutations.py), on a COPY of src/ and common/, and its own check ----
red_fail=0
summary=()
for name in $(python3 "$here/mutations.py" list); do
  # PL_RED_ONLY="NAME ..." : those mutations alone
  [ -n "${PL_RED_ONLY:-}" ] && [[ " $PL_RED_ONLY " != *" $name "* ]] && continue
  label=$(python3 "$here/mutations.py" label "$name")
  m=$work/red_$name
  rm -rf "$m"; mkdir -p "$m"; cp -r "$src" "$m/src"; cp -r "$common" "$m/common"
  if ! python3 "$here/mutations.py" apply "$name" "$m"; then
    echo "  RED $name: the mutation did not apply"; red_fail=1; summary+=("$name|did not apply|$label"); continue
  fi
  if diff -rq "$src" "$m/src" >/dev/null && diff -rq "$common" "$m/common" >/dev/null; then
    echo "  RED $name: the copy is unchanged"; red_fail=1; summary+=("$name|did not apply|$label"); continue
  fi
  if ! build "$m" "$m/test_player" || [ ! -x "$m/test_player" ]; then
    echo "  RED $name: the mutant did not build"; red_fail=1; summary+=("$name|did not build|$label"); continue
  fi
  run "$m/test_player" "$m/run" "$FB_720P"
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
