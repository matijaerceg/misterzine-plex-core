# hps/docker/Dockerfile -- the pinned ARM cross toolchain for hps/ (gcc-arm 10.2-2020.11,
# arm-none-linux-gnueabihf): the same recipe as MiSTer_DVD's and MiSTer_UMD_Video's
# main/docker/Dockerfile, so Docker reuses their cached layers. Bookworm, not bullseye: the
# latter's security repository expired (MiSTer_DVD, 2026-09-10); the base only supplies
# make / wget -- the toolchain is the pinned tarball, which is what fixes the codegen.
#   docker build -t mister-h264-hps:gcc-arm-10.2 hps/docker   (hps/build_arm.sh does it)
FROM debian:bookworm-slim

ARG TC=gcc-arm-10.2-2020.11-x86_64-arm-none-linux-gnueabihf
ARG TC_URL=https://developer.arm.com/-/media/Files/downloads/gnu-a/10.2-2020.11/binrel/${TC}.tar.xz

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates wget xz-utils git make python3 \
    && rm -rf /var/lib/apt/lists/*

RUN wget -q "${TC_URL}" -O /tmp/tc.tar.xz \
    && mkdir -p /opt/toolchain \
    && tar -xJf /tmp/tc.tar.xz -C /opt/toolchain --strip-components=1 \
    && rm /tmp/tc.tar.xz

ENV PATH="/opt/toolchain/bin:${PATH}"
