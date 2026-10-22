#!/usr/bin/env bash
# clients/uvc/docker/deps.sh -- cross-build libusb for the USB camera viewer (docs/uvc.md), static,
# into /opt/sysroot beside the clients' FFmpeg (run inside the image, docker/Dockerfile). Pinned by
# sha256, recorded from the HTTPS download (2026-10-06). libusb is LGPL-2.1+.
set -euo pipefail
PREFIX=/opt/sysroot
HOST=arm-none-linux-gnueabihf
ARCH="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard"
J=$(( $(nproc) > 8 ? 8 : $(nproc) ))   # capped: a Quartus fit may share the workstation's memory
cd /tmp

fetch() {  # url sha256 [file]
    local f=${3:-${1##*/}}
    wget -q "$1" -O "$f"
    echo "$2  $f" | sha256sum -c -
}

# libusb 1.0.29: usbfs (/dev/bus/usb) for the UVC streaming interface -- the MiSTer kernel has no
# V4L2 / uvcvideo (docs/uvc.md U1). --disable-udev: device discovery by scanning /dev/bus/usb.
fetch https://github.com/libusb/libusb/releases/download/v1.0.29/libusb-1.0.29.tar.bz2 \
      5977fc950f8d1395ccea9bd48c06b3f808fd3c2c961b44b0c2e6e29fc3a70a85
tar xf libusb-1.0.29.tar.bz2
(cd libusb-1.0.29 && CC=$HOST-gcc AR=$HOST-ar RANLIB=$HOST-ranlib CFLAGS="-O2 $ARCH" \
     ./configure --host=$HOST --prefix=$PREFIX --enable-static --disable-shared --disable-udev \
     && make -j"$J" && make install)
rm -rf /tmp/libusb-1.0.29*
