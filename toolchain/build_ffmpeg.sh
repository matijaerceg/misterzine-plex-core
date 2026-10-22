#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BUILD="$ROOT/build"
OUT="$BUILD/arm"
PREFIX="$OUT/ffmpeg-prefix"
SRC="$BUILD/sources"
JOBS=${JOBS:-$(nproc)}

FFMPEG_VERSION=7.1.1
OPENSSL_VERSION=3.0.15
FFMPEG_TARBALL="ffmpeg-${FFMPEG_VERSION}.tar.xz"
OPENSSL_TARBALL="openssl-${OPENSSL_VERSION}.tar.gz"
FFMPEG_URL="https://ffmpeg.org/releases/${FFMPEG_TARBALL}"
OPENSSL_URL="https://www.openssl.org/source/${OPENSSL_TARBALL}"
# FFmpeg's matches its release signature; OpenSSL's is the published one.
FFMPEG_SHA256=733984395e0dbbe5c046abda2dc49a5544e7e0e1e2366bba849222ae9e3a03b1
OPENSSL_SHA256=23c666d0edf20f14249b3d8f0368acaee9ab585b09e1de82107c66e1f3ec9533

for tool in make perl wget tar pkg-config sha256sum arm-linux-gnueabihf-gcc; do
  command -v "$tool" >/dev/null || { echo "missing prerequisite: $tool" >&2; exit 1; }
done

mkdir -p "$SRC" "$OUT" "$PREFIX"
cd "$SRC"

# A tarball already in build/sources is used as is, so a release's archived
# copy can stand in when the site is down. Either way it must match the hash.
download() {
  local url=$1 file=$2 sha=$3
  if [[ ! -f "$file" ]]; then
    wget --progress=dot:giga -O "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  if ! echo "$sha  $file" | sha256sum -c --quiet -; then
    echo "$file does not match its pinned SHA-256; delete it and retry" >&2
    exit 1
  fi
}

download "$OPENSSL_URL" "$OPENSSL_TARBALL" "$OPENSSL_SHA256"
download "$FFMPEG_URL" "$FFMPEG_TARBALL" "$FFMPEG_SHA256"

if [[ ! -f "$PREFIX/lib/libssl.a" || ! -f "$PREFIX/lib/libcrypto.a" ]]; then
  rm -rf "openssl-${OPENSSL_VERSION}"
  tar -xzf "$OPENSSL_TARBALL"
  cd "openssl-${OPENSSL_VERSION}"
  ./Configure linux-armv4 \
    --prefix="$PREFIX" --libdir=lib \
    no-shared no-tests no-module no-dso no-engine no-async \
    -static -march=armv7-a -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard \
    --cross-compile-prefix=arm-linux-gnueabihf-
  make -j"$JOBS"
  make install_sw
  cd "$SRC"
fi

rm -rf "ffmpeg-${FFMPEG_VERSION}"
tar -xJf "$FFMPEG_TARBALL"
cd "ffmpeg-${FFMPEG_VERSION}"

export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"

./configure \
  --prefix="$PREFIX" \
  --arch=arm --target-os=linux \
  --cross-prefix=arm-linux-gnueabihf- \
  --pkg-config=pkg-config \
  --cc=arm-linux-gnueabihf-gcc \
  --enable-cross-compile \
  --enable-static --disable-shared \
  --extra-cflags='-O2 -march=armv7-a -mfpu=neon -mfloat-abi=hard' \
  --extra-libs='-ldl -lpthread -latomic' \
  --extra-ldflags='-static' \
  --enable-neon --enable-armv6 --enable-armv6t2 --enable-vfp \
  --disable-autodetect --disable-everything \
  --enable-avformat --enable-avcodec --enable-avutil --enable-swresample \
  --enable-avfilter --disable-avdevice --disable-swscale --disable-postproc \
  --enable-ffmpeg --enable-ffprobe --disable-ffplay \
  --disable-doc --disable-debug \
  --enable-network --enable-openssl --pkg-config-flags=--static \
  --enable-protocol=file,http,https,tcp,tls,crypto,pipe \
  --enable-demuxer=mov,matroska,mpegts,hls,h264,aac,ac3,eac3,mp3,flac,ogg,wav \
  --enable-decoder=aac,ac3,eac3,dca,mp3,mp3float,flac,opus,vorbis,h264,pcm_s8,pcm_u8,pcm_s16le,pcm_s16be,pcm_u16le,pcm_u16be,pcm_s24le,pcm_s24be,pcm_u24le,pcm_u24be,pcm_s32le,pcm_s32be,pcm_u32le,pcm_u32be,pcm_f32le,pcm_f32be,pcm_f64le,pcm_f64be \
  --enable-parser=aac,aac_latm,ac3,dca,flac,h264,hevc,mpegaudio,opus,vorbis \
  --enable-bsf=h264_mp4toannexb,h264_metadata,aac_adtstoasc \
  --enable-encoder=rawvideo,pcm_s16le \
  --enable-muxer=rawvideo,pcm_s16le,null,h264,matroska \
  --enable-filter=aresample,aformat,anull,atrim \
  --enable-pthreads

make -j"$JOBS"
make install
cp -f ffmpeg ffprobe "$OUT/"

file "$OUT/ffmpeg" "$OUT/ffprobe"
echo "FFmpeg $FFMPEG_VERSION installed under $PREFIX"
