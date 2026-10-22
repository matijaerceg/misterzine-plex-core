#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VENDOR="$ROOT/third_party/MiSTer_h264_decoder/hps"
# the host test reads ../h264/dec/h264_pkg.sv (the decoder's refusal codes), so the
# copy keeps hps/ and h264/dec/ as siblings
WORK_ROOT="$ROOT/build/hps-src"
WORK="$WORK_ROOT/hps"
OUT="$ROOT/build/arm"
HOST_OUT="$ROOT/build/hps-host"
LOG="$ROOT/build/hps-host-test.log"

command -v make >/dev/null
command -v gcc >/dev/null
command -v arm-linux-gnueabihf-gcc >/dev/null

mkdir -p "$ROOT/build" "$OUT"
rm -rf "$WORK_ROOT" "$HOST_OUT"
mkdir -p "$WORK_ROOT/h264/dec"
cp -a "$VENDOR" "$WORK"
cp "$ROOT/third_party/MiSTer_h264_decoder/h264/dec/h264_pkg.sv" "$WORK_ROOT/h264/dec/"

echo "Running native x86 host tests..."
make -C "$WORK" BUILD="$HOST_OUT" test 2>&1 | tee "$LOG"

echo "Building static ARMv7 HPS library and tools..."
make -C "$WORK" \
  BUILD="$OUT" \
  CROSS_COMPILE=arm-linux-gnueabihf- \
  OPT='-O2 -g' \
  EXTRA_CFLAGS='-march=armv7-a -mfpu=neon -mfloat-abi=hard' \
  CAVLC_OPT='-O3 -marm' \
  LDFLAGS='-static' \
  all

file "$OUT/libh264ring.a" "$OUT/h264play" "$OUT/h264stat" "$OUT/cavlc2cabac"
echo "Host test log: $LOG"

