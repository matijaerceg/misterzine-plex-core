# clients/player/Makefile -- the file player (docs/player.md).
#   make arm       the MiSTer build into build/arm (Cortex-A9) -- inside the build image:
#                  use ./build.sh (USE_DOCKER=1 runs it in clients/common/docker's image)
#   make host      the host build into build/host (system FFmpeg)
#   make test      the host test: tests/run_test.sh (a fake core, scripted presses; tests/README.md)
# The ARM binary is static except glibc, as the Jellyfin client's (docs/jellyfin.md F7): the image's
# libavformat is built with its network protocols (the shared build), whose name lookups would load
# NSS modules into a static glibc. A file player never looks a name up, but one link rule for both
# clients is one less thing to get wrong; glibc 2.31 is MiSTer Linux's.
REPO    := $(abspath ../..)
HPS     := $(REPO)/hps
COMMON  := ../common
SRC     := src/main.c src/browse.c $(COMMON)/core.c $(COMMON)/player.c $(COMMON)/h264check.c \
           $(COMMON)/input.c $(COMMON)/ui.c $(COMMON)/subs.c $(COMMON)/vdec.c
WARN    := -Wall -Wextra -Werror -Wno-error=deprecated-declarations
CFLAGS_COMMON := -O2 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE $(WARN) -I$(HPS)/include \
                 -Isrc -I$(COMMON) -I$(COMMON)/third_party/stb

arm: CC := arm-none-linux-gnueabihf-gcc
arm:
	$(MAKE) -C $(HPS) arm >/dev/null
	@mkdir -p build/arm
	$(CC) $(CFLAGS_COMMON) -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -I/opt/sysroot/include \
	    -o build/arm/h264player $(SRC) $(HPS)/build/arm/libh264ring.a -L/opt/sysroot/lib \
	    -Wl,-Bstatic -lavformat -lavcodec -lswresample -lavutil -lssl -lcrypto \
	    -Wl,-Bdynamic -lm -lpthread -ldl
	arm-none-linux-gnueabihf-strip -o build/arm/h264player.stripped build/arm/h264player

host:
	$(MAKE) -C $(HPS) >/dev/null
	@mkdir -p build/host
	$(CC) $(CFLAGS_COMMON) $$(pkg-config --cflags libavformat libavcodec libswresample libavutil) \
	    -o build/host/h264player $(SRC) $(HPS)/build/host/libh264ring.a \
	    $$(pkg-config --libs libavformat libavcodec libswresample libavutil) -lm -lpthread

test:
	tests/run_test.sh

clean:
	rm -rf build

.PHONY: arm host test clean
