#!/usr/bin/env bash
# hps/build_arm.sh -- build hps/ for the MiSTer (build/arm/h264play, h264stat, libh264ring.a).
#   hps/build_arm.sh               with arm-none-linux-gnueabihf-gcc on PATH
#   USE_DOCKER=1 hps/build_arm.sh  in the pinned image (hps/docker/Dockerfile, built on first use)
# The binaries are static: copy them to the rig (tools/mister.py deploy --bin) and run.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
if [ "${USE_DOCKER:-0}" = 1 ] && [ -z "${IN_HPS_DOCKER:-}" ]; then
  image=${HPS_DOCKER_IMAGE:-mister-h264-hps:gcc-arm-10.2}
  docker image inspect "$image" >/dev/null 2>&1 || docker build -t "$image" "$here/docker"
  exec docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -e IN_HPS_DOCKER=1 \
       -v "$here:$here" -w "$here" "$image" ./build_arm.sh "$@"
fi
make -C "$here" arm "$@"
file "$here"/build/arm/h264play "$here"/build/arm/h264stat 2>/dev/null || true
