# clients/moonlight/docker/Dockerfile -- the Moonlight client's ARM build image: the hps/ image
# (the pinned gcc-arm 10.2 toolchain, glibc 2.31 = MiSTer Linux's) plus cmake / pkgconf, and the
# client's dependencies cross-built STATIC into /opt/sysroot (docs/moonlight.md M4: one file to
# copy; OpenSSL 3 because moonlight-embedded is GPL-3.0 with no OpenSSL exception).
#   clients/moonlight/build.sh builds it on first use (after hps/docker's image).
ARG BASE=mister-h264-hps:gcc-arm-10.2
FROM ${BASE}

RUN apt-get update && apt-get install -y --no-install-recommends \
        cmake pkgconf perl patch \
    && rm -rf /var/lib/apt/lists/*

COPY deps.sh toolchain.cmake /opt/
RUN /opt/deps.sh

ENV PKG_CONFIG_LIBDIR=/opt/sysroot/lib/pkgconfig
