# clients/common/docker/Dockerfile -- the FFmpeg clients' ARM build image (the Jellyfin client,
# the file player): Moonlight's image
# (the hps/ toolchain, gcc-arm 10.2 / glibc 2.31 = MiSTer Linux's; OpenSSL 3, curl, expat, opus
# static in /opt/sysroot) plus FFmpeg's demuxers and audio decoders, static, the CA bundle and
# the overlay's typeface
# (docs/jellyfin.md J2: one file to copy; FFmpeg's libraries LGPL-2.1+, no --enable-gpl).
#   clients/jellyfin/build.sh and clients/player/build.sh build it on first use (after Moonlight's
#   image), tagged mister-h264-clients:deps3 (0.15: the file player's other codecs, docs/player.md P7;
#   deps2 without them is what the Jellyfin client still builds in; deps1 was the Jellyfin client's alone).
ARG BASE=mister-h264-moonlight:deps1
FROM ${BASE}

# a host gcc: FFmpeg's configure builds and runs host tools
RUN apt-get update && apt-get install -y --no-install-recommends gcc libc6-dev xz-utils bzip2 \
    && rm -rf /var/lib/apt/lists/*

COPY deps.sh /opt/clients-deps.sh
RUN /opt/clients-deps.sh
