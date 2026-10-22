CC := arm-linux-gnueabihf-gcc
HOSTCC ?= cc
ROOT := ..
PREFIX := $(ROOT)/build/arm/ffmpeg-prefix
H264 := $(ROOT)/third_party/MiSTer_h264_decoder/hps
# the decoder project's SPS / PPS check (h264check.c), shared with its clients
H264CHECK := $(ROOT)/third_party/MiSTer_h264_decoder/clients/common

CFLAGS := -std=gnu11 -O2 -static -march=armv7-a -mfpu=neon -mfloat-abi=hard \
	-Wall -Wextra -Wpedantic -pthread -I$(PREFIX)/include -I$(H264)/include -I$(H264CHECK)
LIBS := $(ROOT)/build/arm/libh264ring.a \
	$(PREFIX)/lib/libavformat.a $(PREFIX)/lib/libavcodec.a \
	$(PREFIX)/lib/libswresample.a $(PREFIX)/lib/libavutil.a \
	$(PREFIX)/lib/libssl.a $(PREFIX)/lib/libcrypto.a \
	-lm -ldl -lpthread -latomic

.PHONY: all clean contract-test core-owner-test audio-boost-test seek-cache-test seek-protocol-test h264-idr-test film-speed-test direct-check-test
all: jfplay

jfplay: jfplay.c audio_boost.h film_speed.h h264_idr.h seek_cache.h seek_protocol.h video_geometry.h core_owner.h \
		direct_check.h lag_watch.h $(H264CHECK)/h264check.c $(H264CHECK)/h264check.h $(ROOT)/build/arm/libh264ring.a
	$(CC) $(CFLAGS) -o $@ $< $(H264CHECK)/h264check.c $(LIBS)

direct-check-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -I$(H264CHECK) -o /tmp/jfplay-direct-check-test \
		test_direct_check.c $(H264CHECK)/h264check.c
	/tmp/jfplay-direct-check-test

contract-test:
	python3 test_jfplay_contract.py

core-owner-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/jfplay-core-owner-test test_core_owner.c
	/tmp/jfplay-core-owner-test

audio-boost-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -o /tmp/jfplay-audio-boost-test test_audio_boost.c
	/tmp/jfplay-audio-boost-test

seek-cache-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/jfplay-seek-cache-test test_seek_cache.c
	/tmp/jfplay-seek-cache-test

seek-protocol-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/jfplay-seek-protocol-test test_seek_protocol.c
	/tmp/jfplay-seek-protocol-test

h264-idr-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/jfplay-h264-idr-test test_h264_idr.c
	/tmp/jfplay-h264-idr-test

film-speed-test:
	$(HOSTCC) -std=c11 -Wall -Wextra -Werror -O2 -o /tmp/jfplay-film-speed-test test_film_speed.c
	/tmp/jfplay-film-speed-test

clean:
	$(RM) jfplay
