#!/usr/bin/env bash
# clients/uvc/tests/run_test.sh -- the camera viewer's host tests (docs/uvc.md U3, U6).
#   tests/run_test.sh          GREEN: test_asm (the payload assembler, 9 arms) and test_cam (the viewer
#                              against a fake core and a fake camera, a scripted pad: C1-C10, T1-T5)
#   tests/run_test.sh --red    ... and each mutation below fails its own arm / check
# Needs host gcc, pkg-config with FFmpeg (libavcodec, libavutil: the MJPEG encoder and decoder), the
# DejaVu typefaces (JF_FONT_DIR, default /usr/share/fonts/TTF), python3.
# A mutant is compiled from its own copy of src/ (never the tree's), and every binary is deleted
# before it is built (bench/h264/README.md: a failed build must not run the previous one).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
src=$here/../src
repo=$(cd "$here/../../.." && pwd)
common=$here/../../common
fonts=${JF_FONT_DIR:-/usr/share/fonts/TTF}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# apply one mutation: file, the exact text ("\n" a newline, "\&" an ampersand), its replacement
mutate() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2].replace('\\n', '\n').replace('\\&', '&'), sys.argv[3].replace('\\n', '\n').replace('\\&', '&')
s = open(p).read()
if s.count(a) != 1:
    sys.exit(f"mutation text found {s.count(a)} times: {a!r}")
open(p, 'w').write(s.replace(a, b))
PY
}

# ---- the assembler ----
build_asm() {  # dir -> dir/test_asm
    rm -f "$1/test_asm"
    cc -O1 -g -std=c11 -D_DEFAULT_SOURCE -DUVC_NO_LIBUSB -Wall -Wextra -Werror -I"$1" \
       -o "$1/test_asm" "$here/test_asm.c" "$1/uvc.c"
}

mkdir -p "$work/green"
cp "$src/uvc.c" "$src/uvc.h" "$work/green/"
build_asm "$work/green"
out=$("$work/green/test_asm") || { echo "$out"; echo "GREEN: FAIL"; exit 1; }
echo "$out"
n=$(grep -c '^ARM .* PASS' <<<"$out")
grep -qx 'ALL PASS' <<<"$out" && [ "$n" = 9 ] || { echo "GREEN: FAIL (arms passed: $n of 9)"; exit 1; }
echo "GREEN: PASS (the assembler: 9 arms)"

# ---- the viewer ----
make -s -C "$repo/hps" >/dev/null
cat > "$work/script" <<'SCRIPT'
mark start
sleep 1.5
mark raw
plug rawonly
sleep 2.5
mark rawgone
unplug
sleep 1.5
plug cam
wait_pics 1
mark live
wait_pics 40
press B
mark menu
press DOWN
press A
wait_size 320 240
mark small
wait_pics 20
press A
sleep 0.3
mark pause
sleep 1.5
mark resume
press A
wait_pics 10
mark unplug
unplug
sleep 2
mark replug
plug cam
wait_pics 20
mark quit
unplug
sleep 1.5
plug flaky
wait_size 320 240
mark flaky
wait_pics 10
mark flakyend
press BACK+START
end
SCRIPT

build_cam() {  # dir (holding cam.c, uvc.c, uvc.h) -> dir/test_cam
    rm -f "$1/test_cam"
    cc -O1 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE -DCLIENT_TEST -DUVC_NO_LIBUSB \
       -Wall -Wextra -Werror -Wno-error=deprecated-declarations \
       -I"$1" -I"$common" -I"$common/third_party/stb" -I"$repo/hps/include" $(pkg-config --cflags libavcodec libavutil) \
       -o "$1/test_cam" "$here/test_cam.c" "$1/cam.c" "$1/uvc.c" "$common/core.c" "$common/input.c" "$common/ui.c" \
       "$repo/hps/build/host/libh264ring.a" $(pkg-config --libs libavcodec libavutil) -lm -lpthread
}
run_cam() {  # dir -> dir/out (the test's stdout), dir/log (the viewer's stderr)
    timeout 120 "$1/test_cam" "$fonts" "$work/script" 90 >"$1/out" 2>"$1/log" || true
}

mkdir -p "$work/cam"
cp "$src/cam.c" "$src/uvc.c" "$src/uvc.h" "$work/cam/"
build_cam "$work/cam"
run_cam "$work/cam"
cat "$work/cam/out"
if grep -qx 'test_cam: ALL GREEN' "$work/cam/out"; then
  echo "GREEN: PASS (the viewer: $(grep -c '^  PASS' "$work/cam/out") checks)"
else
  echo "--- the viewer's log (tail):"; tail -30 "$work/cam/log"; echo "GREEN: FAIL (the viewer)"; exit 1
fi
[ "${1:-}" = --red ] || exit 0

# ---- --red ----
red_fail=0
# the assembler: name ~ arm that must fail ~ the exact text in uvc.c ~ its replacement ("~" separates:
# C has "|")
mutations=(
  "M1 no FID-toggle completion~A2~            done |= finish(a, s);\n        }\n        a->after_eof = 0;~        }\n        a->after_eof = 0;"
  "M2 a packet error keeps the frame~A3~        if (open \&\& !a->bad) { s->bad_packet++; a->bad = 1; }\n        return 0;\n    }\n    if (len == 0)~        return 0;\n    }\n    if (len == 0)"
  "M3 the error bit ignored~A4~    if (err \&\& !a->bad) { s->bad_err_bit++; a->bad = 1; }~    (void)err;"
  "M4 an overflow delivered truncated~A5~{ s->bad_overflow++; a->bad = 1; }~{ s->bad_overflow++; }"
  "M5 no shape check~A6~    if (!a->bad \&\& n \&\& !shape_ok(a, a->buf[f], n)) { a->bad = 1; s->bad_shape++; }~    (void)shape_ok;"
  "M6 no stray guard~A7~    if (a->after_eof \&\& fid == a->eof_fid) {~    if (0) {"
  "M7 replaced not counted~A8~        if (a->ready >= 0) s->frames_replaced++;~"
  "M8 the held buffer refilled~A9~if (i != a->ready \&\& i != a->held) { a->fill = i; break; }~if (i != a->ready \&\& i != a->fill) { a->fill = i; break; }"
)
for m in "${mutations[@]}"; do
  IFS='~' read -r name arm from to <<<"$m"
  d="$work/${name%% *}"
  mkdir -p "$d"
  cp "$src/uvc.c" "$src/uvc.h" "$d/"
  mutate "$d/uvc.c" "$from" "$to"
  if ! build_asm "$d" 2>"$d/build.log"; then
    echo "RED $name: did not build (a mutation must compile)"; cat "$d/build.log"; red_fail=1; continue
  fi
  out=$("$d/test_asm" || true)
  if grep -q "^ARM $arm FAIL" <<<"$out"; then
    echo "RED $name: caught by $arm"
  else
    echo "RED $name: NOT caught by $arm"; echo "$out" | sed 's/^/    /'; red_fail=1
  fi
done

# the viewer: name ~ the check that must fail ~ the exact text in cam.c ~ its replacement
cam_mutations=(
  "V1 the raw-rate filter dropped~C6a~        if (!iv || !uvc_mode_fits(m, iv)) continue;~        if (!iv) continue;"
  "V2 no flush on unplug~C5~    core_new_stream(\&c->core);                            /* the last picture goes~    (void)0;                            /* the last picture goes"
  "V3 the requested interval sent, not the committed~C4~    pic.rate_den = c->interval;~    pic.rate_den = c->cand[c->cur].interval;"
  "V4 pictures written while paused~C9~    if (c->paused) return;                                  /* held~    if (0) return;                                  /* held"
  "V5 no LOW_LATENCY~C2~    rc = h264ring_try_write_picture(c->core.r, k, \&pic, -1, H264RING_F_LOW_LATENCY);~    rc = h264ring_try_write_picture(c->core.r, k, \&pic, -1, 0);"
  "V6 the menu's choice ignored~C4~    int rc = start_mode(c, k);~    int rc = start_mode(c, was);"
  "V7 the smallest mode first~C2~                       : ba != aa ? ba > aa : b->interval < a->interval;~                       : ba != aa ? ba < aa : b->interval < a->interval;"
  "V8 MJPEG taken as limited range (colour auto, its full samples untagged)~C3~    case AV_PIX_FMT_YUVJ422P: return H264RING_PIX_YUVJ422P;~    case AV_PIX_FMT_YUVJ422P: return H264RING_PIX_YUV422P;"
  "V9 Back + Start ignored~T3~    if (a == ACT_STOP) { stop = 1; return; }~    if (a == ACT_STOP) { return; }"
  "V10 the refused device tried again~C6b~    if (c->state == C_REFUSED) {                          /* the refused one still there: keep the card */~    if (0) {                          /* the refused one still there: keep the card */"
  "V11 the first store reused for every picture (the library allows it: one acquire a stream)~C8~    rc = h264ring_picture_acquire(c->core.r, \&k);~    static unsigned k0 = 99; rc = k0 == 99 ? h264ring_picture_acquire(c->core.r, \&k0) : 0; k = k0;"
  "V13 the first mode that fails ends the search~C10~    for (unsigned k = 0; k < c->n_cand \&\& rc; k++)~    for (unsigned k = 0; k < c->n_cand \&\& rc == -ENODEV; k++)"
  "V12 no card while waiting~C1~    ui_card(c->ui, c->state == C_WAIT || c->state == C_REFUSED ? \&k : NULL);~    ui_card(c->ui, c->state == C_REFUSED ? \&k : NULL);"
)
for m in "${cam_mutations[@]}"; do
  IFS='~' read -r name arm from to <<<"$m"
  d="$work/${name%% *}"
  mkdir -p "$d"
  cp "$src/cam.c" "$src/uvc.c" "$src/uvc.h" "$d/"
  mutate "$d/cam.c" "$from" "$to"
  if ! build_cam "$d" 2>"$d/build.log"; then
    echo "RED $name: did not build (a mutation must compile)"; cat "$d/build.log"; red_fail=1; continue
  fi
  run_cam "$d"
  if grep -q "^  FAIL $arm " "$d/out"; then
    echo "RED $name: caught by $arm"
  else
    echo "RED $name: NOT caught by $arm"; grep -E '^  (PASS|FAIL)' "$d/out" | sed 's/^/    /'; red_fail=1
  fi
done
[ $red_fail = 0 ] && echo "RED: PASS (${#mutations[@]} assembler and ${#cam_mutations[@]} viewer mutations, each by its own arm)" ||
  { echo "RED: FAIL"; exit 1; }
