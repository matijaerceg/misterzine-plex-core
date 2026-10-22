#!/usr/bin/env bash
# clients/moonlight/tests/run_test.sh [--red] -- the Moonlight client's mister backend on the
# host, against a fake core (test_mister.c), scored by the independent consumer
# (check_mister.py); and (interface 0.6) its input, src/mister/mister_input.c, against a control
# block written as the core writes its input region, every LiSend* call recorded
# (test_input.c: the host's Windows key codes, the design's events). docs/moonlight.md §4, §7.
#   --red   also prove each check can fail: every mutation of src/mister/mister.c must be
#           caught by ITS OWN check (the label listed beside it)
# Needs: the upstream checkout (clients/moonlight/build.sh, for Limelight.h), host gcc and
# libopus (pkg-config opus), python3. The stream: .sim/sunshine/cap_10000.h264 (a real
# Sunshine capture; gitignored) when present, else a High-profile clip made with ffmpeg.
set -u
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
hdr=$here/../build/src/third_party/moonlight-common-c/src
src=$here/../src/mister
out=$here/../build/test
mkdir -p "$out"

[ -f "$hdr/Limelight.h" ] || { echo "run clients/moonlight/build.sh first (the upstream checkout)"; exit 2; }
pkg-config --exists opus || { echo "libopus (pkg-config opus) is needed"; exit 2; }
make -C "$repo/hps" >/dev/null || { echo "hps/ host build failed"; exit 2; }

stream=$repo/.sim/sunshine/cap_10000.h264
if [ ! -f "$stream" ]; then
  stream=$out/x264_high.h264
  [ -f "$stream" ] || ffmpeg -loglevel error -f lavfi -i testsrc2=size=720x480:rate=60 -t 5 \
      -c:v libx264 -profile:v high -preset veryfast -g 600 -bf 0 -pix_fmt yuv420p "$stream" ||
      { echo "no stream: neither the capture nor ffmpeg"; exit 2; }
fi

# (fj#20) a CAVLC stream (x264 ultrafast) and its CABAC rewrite by hps' cavlc2cabac (S7); a stream
# the rewrite refuses (redundant pictures, tools/cavlc_synth.py) for S8
cavlc=$out/cavlc_uf.h264
[ -f "$cavlc" ] || ffmpeg -loglevel error -f lavfi -i testsrc2=size=720x480:rate=60 -t 1 \
    -c:v libx264 -profile:v high -preset ultrafast -g 600 -bf 0 -pix_fmt yuv420p "$cavlc" ||
    { echo "no CAVLC stream: ffmpeg with libx264 is needed"; exit 2; }
"$repo/hps/build/host/cavlc2cabac" -q "$cavlc" "$out/cavlc_uf.cabac.h264" || { echo "cavlc2cabac failed"; exit 2; }
python3 "$repo/tools/cavlc_synth.py" redundant "$out/cavlc_refused.h264" || { echo "cavlc_synth failed"; exit 2; }

build() {   # $1 = mister.c to compile, $2 = binary
  rm -f "$2"   # a failed build must not leave the previous binary to run
  gcc -O2 -g -std=gnu99 -Wall -Wextra -Wno-unused-parameter -I"$hdr" -I"$repo/hps/include" -I"$src" \
      $(pkg-config --cflags opus) "$here/test_mister.c" "$1" "$repo/hps/build/host/libh264ring.a" \
      $(pkg-config --libs opus) -lpthread -lm -o "$2"
}

run() {     # $1 = binary, $2 = log; returns 0 when both halves are GREEN
  rm -f "$out"/t.*
  timeout 120 "$1" "$stream" "$out/t" "$cavlc" "$out/cavlc_refused.h264" > "$2" 2>&1
  python3 "$here/check_mister.py" "$out/t" "$stream" "$out/cavlc_uf.cabac.h264" >> "$2" 2>&1
  grep -q "test_mister: ALL GREEN" "$2" && grep -q "check_mister: ALL GREEN" "$2"
}

build "$src/mister.c" "$out/test_mister" || { echo "build failed"; exit 1; }
[ -x "$out/test_mister" ] || { echo "build failed"; exit 1; }
if run "$out/test_mister" "$out/green.log"; then
  grep -E "PASS|FAIL" "$out/green.log"
  echo "GREEN ($(basename "$stream"))"
else
  cat "$out/green.log"
  echo "run_test: FAILURES"
  exit 1
fi
# ---- 0.6: the input ----
# mister_input.c includes upstream's "../input/keyboard.h" and "../loop.h": found through the
# checkout's src/input (its ..)
build_in() {   # $1 = mister_input.c to compile, $2 = binary
  rm -f "$2"
  gcc -O2 -g -std=gnu99 -Wall -Wextra -Wno-unused-parameter -I"$hdr" -I"$repo/hps/include" -I"$src" \
      -I"$here/../build/src/src/input" "$here/test_input.c" "$1" "$repo/hps/build/host/libh264ring.a" -o "$2"
}
build_in "$src/mister_input.c" "$out/test_input" || { echo "input build failed"; exit 1; }
if [ -x "$out/test_input" ] && timeout 60 "$out/test_input" > "$out/input.log" 2>&1 && grep -q "test_input: ALL GREEN" "$out/input.log"; then
  grep -E "PASS|FAIL" "$out/input.log"
  echo "GREEN (input)"
else
  cat "$out/input.log"
  echo "run_test: FAILURES (input)"
  exit 1
fi
[ "${1:-}" = "--red" ] || { echo "run_test: ALL GREEN"; exit 0; }

# ---- --red: each mutation, and the check that must catch it ----
red_fail=0
mutate() {  # name, sed expression, the check's label (a fixed string)
  local name=$1 expr=$2 label=$3 m=$out/red_$1.c
  sed -e "$expr" "$src/mister.c" > "$m"
  if cmp -s "$m" "$src/mister.c"; then
    echo "  RED $name: the mutation did not apply"; red_fail=1; return
  fi
  if ! build "$m" "$out/red_$name" || [ ! -x "$out/red_$name" ]; then
    echo "  RED $name: the mutant did not build"; red_fail=1; return
  fi
  run "$out/red_$name" "$out/red_$name.log"
  if grep -F "FAIL $label" "$out/red_$name.log" >/dev/null; then
    echo "  RED $name: caught by \"$label\""
  else
    echo "  RED $name: NOT caught by \"$label\""; red_fail=1
  fi
}
mutate graphics 's/(H264RING_F_LOW_LATENCY | H264RING_F_GRAPHICS)/(H264RING_F_LOW_LATENCY)/' \
       "S1: LOW_LATENCY and GRAPHICS on every access unit"
mutate concat 's/e != NULL; e = e->next) {/e != NULL \&\& e->next != NULL; e = e->next) {/' \
       "S1: every access unit's bytes, in order"
mutate mutex 's/pthread_mutex_lock(&ring_mx);/;/; s/pthread_mutex_unlock(&ring_mx);/;/' \
       "S1: the consumer finds no error in what the backend wrote"
mutate early 's/} else if (audio \&\& !video_started) {/} else if (0) {/' \
       "S1: no audio before the session's first access unit"
mutate idr_request 's/            LiRequestIdrFrame();/            ;/' \
       "S2: an error in the status block -> one IDR request (not one per error)"
mutate idr_grace 's/if (e != err_base \&\& idr_written_ms \&\&/if (0 \&\&/' \
       "S2: the IDR is written and the stream resumes"
mutate idr_wait 's/if (!ok || (wait_idr \&\& !idr)) {/if (!ok) {/' \
       "S2: P frames while the IDR is awaited are not written (DR_NEED_IDR)"
mutate restart 's/if (ring \&\& !session_ok \&\& !n.core_gone \&\& now_ms() - restart_ms >= RESTART_MS)/if (0)/' \
       "S3: a new session, and a P frame is not its first record"
mutate refusal 's/kill(getpid(), SIGTERM);/;/' \
       "S4: a refusal ends the stream (SIGTERM), once, and asks for no IDR"
mutate osd 's/osd_open = (H264RING_ST(&st, LIVE) \& H264RING_L_OSD_OPEN) != 0;/osd_open = 0;/' \
       "S5: OSD_OPEN read from the status block, and its clearing"
mutate plc 's/int frames = opus_multistream_decode(opus, (const unsigned char \*)data, length,/int frames = !data ? 0 : opus_multistream_decode(opus, (const unsigned char *)data, length,/' \
       "S1: lost packets concealed"
mutate size 's/\*width = four3 ? 640 : 848;/*width = 848;/' \
       "S5: the size asked for follows the screen (480i 640x480, 4:3 640x480, 16:9 848x480)"
mutate cavlc_off 's/^    ring = r;$/    ring = r; h264ring_set_rewrite(r, 0);/' \
       "S7: the CAVLC stream's units written as their CABAC rewrite, in order"
mutate cavlc_refuse 's|kill(getpid(), SIGTERM);    /\* as a core refusal|;    /* as a core refusal|' \
       "S8: a stream the CAVLC rewrite refuses ends (SIGTERM) once, nothing written, no IDR asked"
mutate core_gone 's/} else if (now_ms() - beat_ms >= ALIVE_MS) {/} else if (0) {/' \
       "S6: the core unloaded ends the stream (SIGTERM), not a restart forever"
mutate caps_size 's/if (mbs > (long)caps.max_mbs) {/if (0) {/' \
       "setup refuses a picture over the core's 3,600 macroblocks (1920x1080 at 10: under the rate)"
mutate caps_rate 's|if (mbs \* redrawRate > (long)caps.mb_rate \* 101 / 100) {|if (0) {|' \
       "setup refuses 1280x720 at 60 frames/s (over the core's 108,000 macroblocks a second)"
mutate caps_fixed 's/    h264ring_caps(&st, &caps);/    h264ring_caps(\&st, \&caps); caps.max_mbs = 1620;/' \
       "setup accepts 1280x720 at 30 frames/s (0.11: 3,600 macroblocks, 108,000 a second)"
# the input: each mutation of mister_input.c caught by its own check
mutate_in() {  # name, sed expression, the check's label (a fixed string)
  local name=$1 expr=$2 label=$3 m=$out/red_in_$1.c
  sed -e "$expr" "$src/mister_input.c" > "$m"
  if cmp -s "$m" "$src/mister_input.c"; then
    echo "  RED in_$name: the mutation did not apply"; red_fail=1; return
  fi
  # the mutant sits in build/test: its "mister.h" / "ps2_keys.h" come through -I"$src"
  if ! build_in "$m" "$out/red_in_$name" || [ ! -x "$out/red_in_$name" ]; then
    echo "  RED in_$name: the mutant did not build"; red_fail=1; return
  fi
  timeout 60 "$out/red_in_$name" > "$out/red_in_$name.log" 2>&1
  if grep -F "FAIL $label" "$out/red_in_$name.log" >/dev/null; then
    echo "  RED in_$name: caught by \"$label\""
  else
    echo "  RED in_$name: NOT caught by \"$label\""; red_fail=1
  fi
}
mutate_in baseline 's/ev_count = (uint32_t)H264RING_IN(&in, EV_COUNT);/ev_count = 0;/' \
       "T1 what happened before the program is not forwarded"
mutate_in modifier 's/if (pressed) modifiers |= mod; else modifiers \&= ~mod;/;/' \
       "T2 Shift+A: the modifier on the A (VK_LSHIFT 0xA0)"
mutate_in stray 's/if (!pressed \&\& !held\[ext\]\[code\]) {/if (0) {/' \
       "T2 a release of a key not held is dropped"
mutate_in pause 's/if (lk == KEY_PAUSE) {/if (0) {/' \
       "T2 Pause: down and up at once (0x13)"
mutate_in mouse_y 's/int32_t dy = -(int32_t)/int32_t dy = (int32_t)/' \
       "T3 movement: the sums' difference, Y negated (PS/2 counts up)"
mutate_in wheel 's/int32_t dw = -(int32_t)/int32_t dw = (int32_t)/' \
       "T3 the wheel, negated (PS/2 counts towards the user)"
mutate_in arrival 's/LiSendControllerArrivalEvent((uint8_t)n, pad_mask, LI_CTYPE_XBOX, PAD_BUTTONS, LI_CCAP_RUMBLE);/;/' \
       "T4 pad 1: arrival (Xbox), then its state"
mutate_in stick_y 's/(short)(-ly \* STICK_SCALE)/(short)(ly * STICK_SCALE)/' \
       "T4 A, Up and LT (255); the stick: X right, Y up-positive"
mutate_in osd_release 's/                    release_all();\n                    osd = true;/X/; /if (H264RING_EV_OPEN(ev\[i\]) \&\& !osd) {/{n;s/release_all();/;/}' \
       "T5 OSD opened: the key up, the button up, the pad zeroed"
mutate_in osd_gate 's/} else if (osd) {/} else if (0) {/' \
       "T5 while it is open: nothing forwarded"
mutate_in lost 's/lost_total += lost;/lost_total += lost; lost = 0; continue;/' \
       "T6 8 events lost: counted, the held A released first"
mutate_in quit_key 's/return quit_armed \&\& modifiers == 0;/return false;/' \
       "T7 ... the modifiers up: the stream ends"
mutate_in quit_pad 's/if ((b \& QUIT_PAD) == QUIT_PAD) {/if (0) {/' \
       "T8 Start+Back+LB+RB: the stream ends, the pad zeroed"
mutate_in guide_declared 's/RS_CLK_FLAG | SPECIAL_FLAG)/RS_CLK_FLAG)/' \
       "T4 the arrival declares the Guide (SPECIAL) among its buttons"
mutate_in action_taken 's/actions |= 1u << (H264RING_EV_CODE(ev\[i\]) \& 31);/;/' \
       "T10 the OSD closed: the Guide pressed on pad 0"
mutate_in action_open 's/if (actions \&\& !osd) {/if (actions) {/' \
       "T10 the OSD closed: the Guide pressed on pad 0"
mutate_in action_order 's/} else if (t == H264RING_EV_ACTION) {/} else if (t == H264RING_EV_ACTION \&\& !osd) {/' \
       "T10 the OSD closed: the Guide pressed on pad 0"
mutate_in tap 's/guide_ms = GUIDE_TAP_MS;/guide_ms = 1;/' \
       "T10 the Guide held 100 ms, then released"
mutate_in chord_time 's/chord_ms\[n\] += ms;/chord_ms[n] += 2 * ms;/' \
       "T11 held a second: the Guide on pad 2, Back and Start released"
mutate_in chord_hide 's/w = raw \& ~(uint64_t)chord_hide\[n\];/w = raw;/' \
       "T11 held a second: the Guide on pad 2, Back and Start released"
mutate_in chord_release 's/chord_hide\[n\] \&= b;/;/' \
       "T11 Back and Start kept from the host until released, then the game's again"
mutate_in chord_lb 's/ \&\& !(b \& (H264RING_PAD_LB | H264RING_PAD_RB)) \&\& !chord_hide\[n\]/ \&\& !chord_hide[n]/' \
       "T11 not with LB held (the quit combo on its way)"
# (0.13) the rumble
mutate_in rumble_motors 's/(uint16_t)((low \& 0xFF00u) | (high >> 8))/(uint16_t)((high \& 0xFF00u) | (low >> 8))/' \
       "T12 rumble: pad 0 {0x80, 0x40}, pad 3 {0xFF, 0x01} -- the large motor is the host's low frequency"
mutate_in rumble_callback_writes 's/__atomic_store_n(\&rum_want\[n\], (uint16_t)((low \& 0xFF00u) | (high >> 8)), __ATOMIC_RELAXED);/{ uint16_t v_ = (uint16_t)((low \& 0xFF00u) | (high >> 8)); __atomic_store_n(\&rum_want[n], v_, __ATOMIC_RELAXED); if (mister_ring()) h264ring_rumble(mister_ring(), n, v_ >> 8, v_ \& 0xFFu); }/' \
       "T12 nothing written before the timer (the callback's thread never writes the core)"
mutate_in rumble_dropped 's/__atomic_add_fetch(\&rum_dropped, 1, __ATOMIC_RELAXED);/;/' \
       "T12 a controller past six dropped and counted; trigger rumble ignored"
mutate_in rumble_osd 's/        rumble_tick(r, ms);             \/\* (0.13)/        if (!osd) rumble_tick(r, ms);             \/* (0.13)/' \
       "T12 written while Main's menu is open (Main plays it on every core)"
mutate_in rumble_keepalive 's/int k = h264ring_rumble_keepalive(r);/int k = 0;/' \
       "T12 a held rumble kept going past Main's 32.767 s (stepped by the keepalive), an off one not"
mutate_in rumble_stop 's/if (rum_sent\[n\] \&\& r \&\& h264ring_rumble(r, (unsigned)n, 0, 0) == 0)/if (0)/' \
       "T12 every pad stopped when the input stops"
mutate_in rumble_cap 's/PAD_BUTTONS, LI_CCAP_RUMBLE);/PAD_BUTTONS, 0);/' \
       "T4 the arrival declares rumble (0.13)"
[ $red_fail = 0 ] && echo "run_test: ALL GREEN (and RED)" || { echo "run_test: RED FAILURES"; exit 1; }
