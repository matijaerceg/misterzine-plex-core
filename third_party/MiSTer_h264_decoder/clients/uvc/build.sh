#!/usr/bin/env bash
# clients/uvc/build.sh -- build h264cam for the MiSTer (docs/uvc.md): src/ + ../common/core.c, linked
# static against libh264ring (hps/), the image's libavcodec and libusb.
#   USE_DOCKER=1 clients/uvc/build.sh     in the pinned image (docker/, a layer on the file player's,
#                                         built on first use)
#   clients/uvc/build.sh                  inside that image already
# Output: build/arm/h264cam (ARM, static but for glibc) and build/dist/ laid out as the SD card
# (Scripts/h264cam.sh; h264cam/: the binary, the typefaces): copy it to /media/fat/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "${USE_DOCKER:-0}" = 1 ] && [ -z "${IN_CLIENTS_DOCKER:-}" ]; then
  clients=${CLIENTS_DOCKER_IMAGE:-mister-h264-clients:deps3}
  image=${UVC_DOCKER_IMAGE:-mister-h264-uvc:deps1}
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    docker image inspect "$clients" >/dev/null 2>&1 ||
      USE_DOCKER=1 "$repo/clients/player/build.sh" >/dev/null   # builds the image chain up to deps3
    docker build --build-arg BASE="$clients" -t "$image" "$here/docker"
  fi
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e IN_CLIENTS_DOCKER=1 \
       -v "$repo:$repo" -w "$here" "$image" ./build.sh "$@"
fi

make -C "$here" arm
dist=$here/build/dist/h264cam
rm -rf "$here/build/dist"
mkdir -p "$dist" "$here/build/dist/Scripts"
cp "$here/mister/h264cam.sh" "$here/build/dist/Scripts/"
cp "$here/build/arm/h264cam.stripped" "$dist/h264cam"
cp /opt/sysroot/share/clients/DejaVuSans.ttf /opt/sysroot/share/clients/DejaVuSans-Bold.ttf \
   /opt/sysroot/share/clients/DejaVu-LICENSE "$dist/"
ls -la "$dist"
