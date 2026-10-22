# clients/uvc/docker/Dockerfile -- the USB camera / capture viewer's ARM build image (docs/uvc.md):
# the file player's image (mister-h264-clients:deps3: the hps/ toolchain, FFmpeg with the MJPEG
# decoder, static, in /opt/sysroot) plus libusb, static and without udev (MiSTer Linux has no
# libudev: libusb scans /dev/bus/usb itself). A layer, not a rebuild of deps3: FFmpeg is not
# touched. Tagged mister-h264-uvc:deps1 by clients/uvc/build.sh on first use.
ARG BASE=mister-h264-clients:deps3
FROM ${BASE}

COPY deps.sh /opt/uvc-deps.sh
RUN /opt/uvc-deps.sh
