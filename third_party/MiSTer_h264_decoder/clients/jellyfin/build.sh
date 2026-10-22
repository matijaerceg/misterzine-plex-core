#!/usr/bin/env bash
# clients/jellyfin/build.sh -- build the Jellyfin client for the MiSTer (docs/jellyfin.md):
# src/ + ../common/ + third_party/, linked static against libh264ring (hps/) and the image's FFmpeg / curl /
# OpenSSL.
#   USE_DOCKER=1 clients/jellyfin/build.sh     in the pinned image (../common/docker/, built on first use)
#   clients/jellyfin/build.sh                  inside that image already
# Output: build/arm/jellyfin (ARM, static but for glibc, stripped) and build/dist/ laid out as the SD card
# (Scripts/jellyfin.sh; jellyfin/: the binary, the CA bundle, the typeface): copy it to /media/fat/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

if [ "${USE_DOCKER:-0}" = 1 ] && [ -z "${IN_JF_DOCKER:-}" ]; then
  base=${HPS_DOCKER_IMAGE:-mister-h264-hps:gcc-arm-10.2}
  ml=${ML_DOCKER_IMAGE:-mister-h264-moonlight:deps1}
  image=${CLIENTS_DOCKER_IMAGE:-mister-h264-clients:deps3}   # the image clients/common/docker builds today (as the player's)
  docker image inspect "$base" >/dev/null 2>&1 || docker build -t "$base" "$repo/hps/docker"
  docker image inspect "$ml" >/dev/null 2>&1 ||
    docker build --build-arg BASE="$base" -t "$ml" "$repo/clients/moonlight/docker"
  docker image inspect "$image" >/dev/null 2>&1 ||
    docker build --build-arg BASE="$ml" -t "$image" "$repo/clients/common/docker"
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e IN_JF_DOCKER=1 \
       -v "$repo:$repo" -w "$here" "$image" ./build.sh "$@"
fi

make -C "$here" arm
dist=$here/build/dist/jellyfin
rm -rf "$here/build/dist"
mkdir -p "$dist" "$here/build/dist/Scripts"
cp "$here/mister/jellyfin.sh" "$here/build/dist/Scripts/"
cp "$here/build/arm/jellyfin.stripped" "$dist/jellyfin"
cp /opt/sysroot/share/clients/cacert.pem /opt/sysroot/share/clients/DejaVuSans.ttf \
   /opt/sysroot/share/clients/DejaVuSans-Bold.ttf /opt/sysroot/share/clients/DejaVu-LICENSE "$dist/"
ls -la "$dist"
