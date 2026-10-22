#!/usr/bin/env bash
# clients/moonlight/docker/deps.sh -- cross-build the Moonlight client's dependencies, static,
# into /opt/sysroot (run inside the image, docker/Dockerfile). Every tarball is pinned by its
# sha256: OpenSSL's and opus's are the publishers' own; curl, expat and libevdev publish GPG
# signatures only, so theirs were recorded from an HTTPS download (2026-09-29).
set -euo pipefail
PREFIX=/opt/sysroot
HOST=arm-none-linux-gnueabihf
ARCH="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"
export CC=$HOST-gcc AR=$HOST-ar RANLIB=$HOST-ranlib CFLAGS="-O2 $ARCH"
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
J=$(nproc)
cd /tmp

fetch() {  # url sha256
    local f=${1##*/}
    wget -q "$1" -O "$f"
    echo "$2  $f" | sha256sum -c -
    tar xf "$f"
}

fetch https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz \
      603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
(cd openssl-3.5.9 && ./Configure linux-armv4 \
     no-shared no-tests no-docs no-apps no-module --prefix=$PREFIX --libdir=lib \
 && make -j$J build_sw && make install_sw)

fetch https://curl.se/download/curl-8.22.0.tar.xz \
      f7ef3ae8a22e521f289803fe93543eb64c329b58aa73a9e224dfd915a2a5f4f7
(cd curl-8.22.0 && ./configure --host=$HOST --prefix=$PREFIX --disable-shared --enable-static \
     --with-openssl=$PREFIX --without-zlib --without-brotli --without-zstd --without-libpsl \
     --without-nghttp2 --without-libidn2 --without-libssh2 --without-ca-bundle --without-ca-path \
     --disable-ldap --disable-ldaps --disable-rtsp --disable-dict --disable-telnet --disable-tftp \
     --disable-pop3 --disable-imap --disable-smtp --disable-gopher --disable-mqtt --disable-smb \
     --disable-ftp --disable-file --disable-manual --disable-docs \
 && make -j$J && make install)

fetch https://github.com/libexpat/libexpat/releases/download/R_2_8_5/expat-2.8.5.tar.xz \
      1e727b8933ec51a77a9a9d9afcf8e688bce45d907c13e36ab7393fe36e703182
(cd expat-2.8.5 && ./configure --host=$HOST --prefix=$PREFIX --disable-shared --enable-static \
     --without-docbook --without-examples --without-tests \
 && make -j$J && make install)

fetch https://downloads.xiph.org/releases/opus/opus-1.5.2.tar.gz \
      65c1d2f78b9f2fb20082c38cbe47c951ad5839345876e46941612ee87f9a7ce1
(cd opus-1.5.2 && ./configure --host=$HOST --prefix=$PREFIX --disable-shared --enable-static \
     --disable-extra-programs --disable-doc \
 && make -j$J && make install)

fetch https://www.freedesktop.org/software/libevdev/libevdev-1.13.7.tar.xz \
      0caf824971108f15bb2ad356433bae198d7d3bf1e82d43f63626e069e060bfa6
(cd libevdev-1.13.7 && ./configure --host=$HOST --prefix=$PREFIX --disable-shared --enable-static \
     --disable-gcov \
 && make -j$J && make install)

rm -rf /tmp/*
ls $PREFIX/lib/*.a
