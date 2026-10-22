#!/usr/bin/env bash
# clients/common/docker/deps.sh -- cross-build the FFmpeg clients' dependencies (the Jellyfin
# client, the file player), static, into /opt/sysroot beside Moonlight's (run inside the image,
# docker/Dockerfile). Pinned by
# sha256: FFmpeg's tarball and DejaVu's release recorded from HTTPS downloads (2026-10-01; they
# publish GPG signatures only); the CA bundle's is curl.se's own published sum. (cJSON and
# stb_truetype are vendored in ../../jellyfin/third_party/ and ../third_party/: the host tests
# compile the same sources.)
set -euo pipefail
PREFIX=/opt/sysroot
HOST=arm-none-linux-gnueabihf
ARCH="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"
export CC=$HOST-gcc AR=$HOST-ar RANLIB=$HOST-ranlib
export PKG_CONFIG_LIBDIR=$PREFIX/lib/pkgconfig
J=$(( $(nproc) > 8 ? 8 : $(nproc) ))   # capped: a Quartus fit may share the workstation's memory
cd /tmp

fetch() {  # url sha256 [file]
    local f=${3:-${1##*/}}
    wget -q "$1" -O "$f"
    echo "$2  $f" | sha256sum -c -
}

# FFmpeg 8.0.3: the demuxers a Jellyfin stream arrives in (HLS-TS transcodes; MKV / MP4 / TS
# direct play) and a file on the card (those, raw .264 / .h264, external .srt: docs/player.md),
# the H.264 parser and the avcC -> Annex B filter, the audio decoders the ARM plays
# (docs/jellyfin.md S3, R2: TrueHD left to the server), the text subtitle decoders (the file
# player's embedded tracks: SRT, ASS / SSA, mov_text, WebVTT, plain text), libswresample; TLS by
# OpenSSL.
# (0.15, deps3) The file player's other codecs, decoded on the ARM (docs/player.md P7): the video
# decoders MPEG-1/2, MPEG-4 Part 2, MS-MPEG4 v1-3, WMV7/8, Theora, MJPEG, H.263; their parsers; the
# containers AVI, ASF, MPEG-PS / elementary, Ogg, raw MPEG-4; and the audio they carry (MP2, LPCM,
# WMA v1 / v2, ADPCM). Still LGPL (none needs --enable-gpl); swscale still off (the library's copy
# converts the 4:2:2 / full-range formats it takes).
# udp stays enabled: 8.0's OpenSSL link needs it (fixed upstream in 9.0.2).
# configure without CC / AR / RANLIB in the environment: it takes them as the HOST tools.
fetch https://ffmpeg.org/releases/ffmpeg-8.0.3.tar.xz \
      6136812ea6d4e68bdba27e33c2a94382711cdf4f8602ffef056ff792bd6f9818
tar xf ffmpeg-8.0.3.tar.xz
(cd ffmpeg-8.0.3 && env -u CC -u AR -u RANLIB ./configure \
     --enable-cross-compile --cross-prefix=$HOST- --pkg-config=pkg-config \
     --arch=arm --cpu=cortex-a9 --target-os=linux --enable-neon --enable-vfpv3 \
     --prefix=$PREFIX --enable-static --disable-shared \
     --disable-programs --disable-doc --disable-autodetect --disable-debug \
     --disable-everything --disable-avdevice --disable-swscale --disable-avfilter \
     --enable-avformat --enable-avcodec --enable-swresample --enable-network \
     --enable-protocol=file,http,https,tcp,tls,crypto,udp \
     --enable-demuxer=hls,mpegts,matroska,mov,aac,ac3,eac3,mp3,flac,dts,h264,avi,asf,mpegps,mpegvideo,ogg,m4v \
     --enable-parser=h264,aac,aac_latm,ac3,dca,mpegaudio,opus,flac,vorbis,mpegvideo,mpeg4video,h263,mjpeg \
     --enable-bsf=h264_mp4toannexb,extract_extradata \
     --enable-decoder=aac,aac_latm,ac3,eac3,dca,mp3float,opus,flac,vorbis,subrip,srt,ass,ssa,movtext,webvtt,text \
     --enable-decoder=mpeg1video,mpeg2video,mpeg4,msmpeg4v1,msmpeg4v2,msmpeg4v3,wmv1,wmv2,theora,mjpeg,h263,h263p \
     --enable-decoder=mp2float,pcm_s16le,pcm_u8,pcm_dvd,wmav1,wmav2,adpcm_ima_wav,adpcm_ms \
     --enable-openssl --pkg-config-flags=--static \
     --extra-cflags="-I$PREFIX/include" --extra-ldflags="-L$PREFIX/lib" \
 && make -j$J && make install)

# Mozilla's CA bundle as curl publishes it (MiSTer Linux's own is from 2021): shipped beside
# the clients, the system's /etc/ssl/cert.pem the fallback
install -d $PREFIX/share/clients
fetch https://curl.se/ca/cacert-2026-09-25.pem \
      a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505
install -m 644 cacert-2026-09-25.pem $PREFIX/share/clients/cacert.pem

# the overlay's typeface (titles, the progress, subtitles): DejaVu Sans and Sans Bold, shipped as
# files beside the client with their licence (Bitstream Vera's terms + public-domain changes)
fetch https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-2.37.tar.bz2 \
      fa9ca4d13871dd122f61258a80d01751d603b4d3ee14095d65453b4e846e17d7
tar xf dejavu-fonts-ttf-2.37.tar.bz2
install -m 644 dejavu-fonts-ttf-2.37/ttf/DejaVuSans.ttf dejavu-fonts-ttf-2.37/ttf/DejaVuSans-Bold.ttf \
    $PREFIX/share/clients/
install -m 644 dejavu-fonts-ttf-2.37/LICENSE $PREFIX/share/clients/DejaVu-LICENSE

rm -rf /tmp/*
ls $PREFIX/lib/libav*.a $PREFIX/lib/libswresample.a $PREFIX/share/clients/
