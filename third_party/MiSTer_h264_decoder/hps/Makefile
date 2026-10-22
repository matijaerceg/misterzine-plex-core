# hps/Makefile -- the client library, the reference feeder and h264stat.
#   make            host build into build/host (the tests; a Linux PC has no /dev/mem region)
#   make test       host build + the unit tests (hps/tests/run_tests.sh runs them with --red)
#   make arm        the MiSTer build into build/arm (static, Cortex-A9): needs
#                   arm-none-linux-gnueabihf-gcc -- or run ./build_arm.sh (USE_DOCKER=1: the
#                   pinned gcc-arm 10.2 image, hps/docker/Dockerfile)
CROSS_COMPILE ?=
CC      := $(CROSS_COMPILE)gcc
AR      := $(CROSS_COMPILE)ar
BUILD   ?= build/host
OPT     ?= -O2 -g
CFLAGS  := $(OPT) -std=c99 -D_DEFAULT_SOURCE -Wall -Wextra -Werror -Iinclude -Ilib $(EXTRA_CFLAGS)
LDFLAGS ?=
LIBSRC  := lib/h264ring.c lib/h264ring_linux.c lib/h264ring_dump.c lib/h264ring_au.c lib/h264ring_cavlc.c
LIBOBJ  := $(LIBSRC:%.c=$(BUILD)/obj/%.o)
HDRS    := include/h264ring.h include/h264ring_layout.h include/h264ring_cavlc.h lib/h264ring_priv.h \
           lib/h264ring_cavlc_tab.h

all: $(BUILD)/libh264ring.a $(BUILD)/h264play $(BUILD)/h264stat $(BUILD)/cavlc2cabac

# the CAVLC rewrite's hot loops (docs/cavlc.md S8a): the arm build compiles this one object with
# CAVLC_OPT (-O3, ARM rather than Thumb-2 code: ~4 % on the rig); every other object keeps OPT
$(BUILD)/obj/lib/h264ring_cavlc.o: CFLAGS += $(CAVLC_OPT)

$(BUILD)/obj/%.o: %.c $(HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD)/libh264ring.a: $(LIBOBJ)
	$(AR) rcs $@ $^

$(BUILD)/h264play: $(BUILD)/obj/feeder/h264play.o $(BUILD)/libh264ring.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/h264stat: $(BUILD)/obj/h264stat/h264stat.o $(BUILD)/libh264ring.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/cavlc2cabac: $(BUILD)/obj/cavlc2cabac/cavlc2cabac.o $(BUILD)/libh264ring.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

$(BUILD)/test_ring: $(BUILD)/obj/tests/test_ring.o $(BUILD)/libh264ring.a
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

test: $(BUILD)/test_ring $(BUILD)/h264play
	$(BUILD)/test_ring

# the MiSTer: ARMv7-A Cortex-A9 with NEON, hard float, static (no library to install on the rig)
arm:
	$(MAKE) BUILD=build/arm CROSS_COMPILE=arm-none-linux-gnueabihf- \
	        EXTRA_CFLAGS="-mcpu=cortex-a9 -mfpu=neon -mfloat-abi=hard" CAVLC_OPT="-O3 -marm" \
	        LDFLAGS=-static all

clean:
	rm -rf build

.PHONY: all test arm clean
