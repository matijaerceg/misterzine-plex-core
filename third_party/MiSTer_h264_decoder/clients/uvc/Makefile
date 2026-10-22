# clients/uvc/Makefile -- the USB camera / capture viewer, h264cam (docs/uvc.md).
#   make arm       the MiSTer build into build/arm (Cortex-A9) -- inside the build image:
#                  use ./build.sh (USE_DOCKER=1 runs it in docker/'s image, a layer on the file player's)
#   make host      the host build into build/host (system FFmpeg and libusb; root to open a device)
# Linked as the file player is (static but for glibc: docs/jellyfin.md F7), plus libusb, static; the
# image's libavcodec carries its audio decoders, so libswresample and libcrypto come with it.
REPO    := $(abspath ../..)
HPS     := $(REPO)/hps
COMMON  := ../common
SRC     := src/main.c src/cam.c src/uvc.c $(COMMON)/core.c $(COMMON)/input.c $(COMMON)/ui.c
WARN    := -Wall -Wextra -Werror -Wno-error=deprecated-declarations
CFLAGS_COMMON := -O2 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE $(WARN) -I$(HPS)/include -Isrc -I$(COMMON) \
                 -I$(COMMON)/third_party/stb

arm: CC := arm-none-linux-gnueabihf-gcc
arm:
	$(MAKE) -C $(HPS) arm >/dev/null
	@mkdir -p build/arm
	$(CC) $(CFLAGS_COMMON) -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -I/opt/sysroot/include \
	    -I/opt/sysroot/include/libusb-1.0 \
	    -o build/arm/h264cam $(SRC) $(HPS)/build/arm/libh264ring.a -L/opt/sysroot/lib \
	    -Wl,-Bstatic -lavcodec -lswresample -lavutil -lcrypto -lusb-1.0 \
	    -Wl,-Bdynamic -lm -lpthread -ldl
	arm-none-linux-gnueabihf-strip -o build/arm/h264cam.stripped build/arm/h264cam

host:
	$(MAKE) -C $(HPS) >/dev/null
	@mkdir -p build/host
	$(CC) $(CFLAGS_COMMON) $$(pkg-config --cflags libavcodec libavutil libusb-1.0) \
	    -o build/host/h264cam $(SRC) $(HPS)/build/host/libh264ring.a \
	    $$(pkg-config --libs libavcodec libavutil libusb-1.0) -lm -lpthread

clean:
	rm -rf build

.PHONY: arm host clean
