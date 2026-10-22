#!/usr/bin/env bash
# clients/player/build.sh -- build the file player for the MiSTer (docs/player.md): src/ +
# ../common/, linked static against libh264ring (hps/) and the image's FFmpeg (and the OpenSSL
# its shared build carries).
#   USE_DOCKER=1 clients/player/build.sh     in the pinned image (../common/docker/, built on first use)
#   clients/player/build.sh                  inside that image already
# Output: build/arm/h264player (ARM, static but for glibc, stripped) and build/dist/ laid out as the
# SD card (Scripts/h264player.sh; h264player/: the binary, the typefaces): copy it to /media/fat/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "${USE_DOCKER:-0}" = 1 ] && [ -z "${IN_CLIENTS_DOCKER:-}" ]; then
  base=${HPS_DOCKER_IMAGE:-mister-h264-hps:gcc-arm-10.2}
  ml=${ML_DOCKER_IMAGE:-mister-h264-moonlight:deps1}
  image=${CLIENTS_DOCKER_IMAGE:-mister-h264-clients:deps3}   # (0.15) the other codecs' decoders
  docker image inspect "$base" >/dev/null 2>&1 || docker build -t "$base" "$repo/hps/docker"
  docker image inspect "$ml" >/dev/null 2>&1 ||
    docker build --build-arg BASE="$base" -t "$ml" "$repo/clients/moonlight/docker"
  docker image inspect "$image" >/dev/null 2>&1 ||
    docker build --build-arg BASE="$ml" -t "$image" "$repo/clients/common/docker"
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e IN_CLIENTS_DOCKER=1 \
       -v "$repo:$repo" -w "$here" "$image" ./build.sh "$@"
fi

make -C "$here" arm
dist=$here/build/dist/h264player
rm -rf "$here/build/dist"
mkdir -p "$dist" "$here/build/dist/Scripts"
cp "$here/mister/h264player.sh" "$here/build/dist/Scripts/"
cp "$here/build/arm/h264player.stripped" "$dist/h264player"
cp /opt/sysroot/share/clients/DejaVuSans.ttf /opt/sysroot/share/clients/DejaVuSans-Bold.ttf \
   /opt/sysroot/share/clients/DejaVu-LICENSE "$dist/"
ls -la "$dist"
