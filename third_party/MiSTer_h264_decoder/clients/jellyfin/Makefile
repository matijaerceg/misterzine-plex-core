# clients/jellyfin/Makefile -- the Jellyfin client (docs/jellyfin.md).
#   make arm       the MiSTer build into build/arm (Cortex-A9) -- inside the build image:
#                  use ./build.sh (USE_DOCKER=1 runs it in clients/jellyfin/docker's image)
#   make host      the host build into build/host (system FFmpeg / curl)
#   make test      the host test: tests/run_test.sh (a fake core and a fake server; tests/README.md)
# The ARM binary is static EXCEPT glibc (docs/jellyfin.md J2): a static glibc loads the system's
# NSS modules (libnss_files / libnss_dns) for every host-name lookup, and that second libc is not
# set up for threads the static one created -- curl's resolver thread crashed in libnss_files on
# the rig (2026-10-01). glibc 2.31 is MiSTer Linux's, and a binary linked against it runs on any
# later one: still one file to copy.
REPO    := $(abspath ../..)
HPS     := $(REPO)/hps
COMMON  := ../common
# core / player / h264check / input / ui / subs / vdec: clients/common/, shared with the file player
# (vdec, the ARM's decode of other codecs, is linked but off here: the server transcodes them)
SRC     := src/main.c src/jf.c src/profile.c $(COMMON)/core.c $(COMMON)/player.c $(COMMON)/h264check.c \
           $(COMMON)/input.c $(COMMON)/ui.c $(COMMON)/subs.c $(COMMON)/vdec.c third_party/cjson/cJSON.c
WARN    := -Wall -Wextra -Werror -Wno-error=deprecated-declarations
CFLAGS_COMMON := -O2 -g -std=c11 -D_DEFAULT_SOURCE -D_GNU_SOURCE $(WARN) -I$(HPS)/include \
                 -Isrc -I$(COMMON) -Ithird_party/cjson -I$(COMMON)/third_party/stb

arm: BUILD := build/arm
arm: CC := arm-none-linux-gnueabihf-gcc
arm:
	$(MAKE) -C $(HPS) arm >/dev/null
	@mkdir -p build/arm
	$(CC) $(CFLAGS_COMMON) -mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard -I/opt/sysroot/include \
	    -o build/arm/jellyfin $(SRC) $(HPS)/build/arm/libh264ring.a -L/opt/sysroot/lib \
	    -Wl,-Bstatic -lavformat -lavcodec -lswresample -lavutil -lcurl -lssl -lcrypto \
	    -Wl,-Bdynamic -lm -lpthread -ldl
	arm-none-linux-gnueabihf-strip -o build/arm/jellyfin.stripped build/arm/jellyfin

host:
	$(MAKE) -C $(HPS) >/dev/null
	@mkdir -p build/host
	$(CC) $(CFLAGS_COMMON) $$(pkg-config --cflags libavformat libavcodec libswresample libavutil libcurl) \
	    -o build/host/jellyfin $(SRC) $(HPS)/build/host/libh264ring.a \
	    $$(pkg-config --libs libavformat libavcodec libswresample libavutil libcurl) -lm -lpthread

test:
	tests/run_test.sh

clean:
	rm -rf build

.PHONY: arm host test clean
