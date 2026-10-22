#!/usr/bin/env bash
# clients/moonlight/build.sh -- build the Moonlight client for the MiSTer (docs/moonlight.md):
# moonlight-embedded at a pinned commit + patches/ + src/mister/ (the "mister" platform),
# linked static against libh264ring (hps/) and the dependencies in the build image.
#   USE_DOCKER=1 clients/moonlight/build.sh     in the pinned image (docker/, built on first use)
#   clients/moonlight/build.sh                  inside that image already
# Output: build/moonlight (static ARM), build/gamecontrollerdb.txt (the input mappings), and
# build/dist/ laid out as the SD card (Scripts/moonlight.sh, moonlight/): copy it to /media/fat/.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

UPSTREAM=https://github.com/moonlight-stream/moonlight-embedded.git
PIN=f32e415aea6797d261d6b470dcf8bf18727341c2          # moonlight-embedded (2.7.1)
COMMON_PIN=b126e481a195fdc7152d211def17190e3434bcce   # its moonlight-common-c at PIN

if [ "${USE_DOCKER:-0}" = 1 ] && [ -z "${IN_ML_DOCKER:-}" ]; then
  base=${HPS_DOCKER_IMAGE:-mister-h264-hps:gcc-arm-10.2}
  image=${ML_DOCKER_IMAGE:-mister-h264-moonlight:deps1}
  docker image inspect "$base" >/dev/null 2>&1 || docker build -t "$base" "$repo/hps/docker"
  docker image inspect "$image" >/dev/null 2>&1 ||
    docker build --build-arg BASE="$base" -t "$image" "$here/docker"
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e IN_ML_DOCKER=1 \
       -v "$repo:$repo" -w "$here" "$image" ./build.sh "$@"
fi

out=$here/build
src=$out/src
mkdir -p "$out"

# libh264ring for the target (the library as an integrator links it)
make -C "$repo/hps" arm >/dev/null

# upstream at the pin, clean, with the patch series and the backend
if [ ! -d "$src/.git" ]; then
  git init -q "$src"
  git -C "$src" remote add origin "$UPSTREAM"
fi
git -C "$src" fetch -q --depth 1 origin "$PIN"
git -C "$src" checkout -q -f "$PIN"
git -C "$src" clean -q -fdx
git -C "$src" submodule -q update --init --depth 1 --recursive
[ "$(git -C "$src/third_party/moonlight-common-c" rev-parse HEAD)" = "$COMMON_PIN" ] ||
  { echo "moonlight-common-c is not at $COMMON_PIN" >&2; exit 1; }
for p in "$here"/patches/*.patch; do
  git -C "$src" apply --whitespace=nowarn "$p"
done
cp -r "$here/src/mister" "$src/src/"

rm -rf "$out/cmake" "$out/moonlight"
cmake -S "$src" -B "$out/cmake" -DCMAKE_TOOLCHAIN_FILE="$here/docker/toolchain.cmake" \
      -DCMAKE_BUILD_TYPE=Release -DENABLE_SDL=OFF -DENABLE_FFMPEG=OFF -DENABLE_X11=OFF \
      -DENABLE_CEC=OFF -DENABLE_PULSE=OFF -DENABLE_MISTER=ON \
      -DH264RING_DIR="$repo/hps" -DH264RING_LIBRARY="$repo/hps/build/arm/libh264ring.a" >/dev/null
make -C "$out/cmake" -j"$(nproc)" moonlight
cp "$out/cmake/moonlight" "$out/moonlight"
arm-none-linux-gnueabihf-strip "$out/moonlight"
cp "$src/third_party/SDL_GameControllerDB/gamecontrollerdb.txt" "$out/"
# the SD card's layout: copy build/dist/* to /media/fat/
rm -rf "$out/dist"
mkdir -p "$out/dist/Scripts" "$out/dist/moonlight"
cp "$here/mister/moonlight.sh" "$out/dist/Scripts/"
cp "$out/moonlight" "$out/dist/moonlight/"
file "$out/moonlight" 2>/dev/null || ls -l "$out/moonlight"
