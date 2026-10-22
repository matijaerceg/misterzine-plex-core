# hps/ -- the HPS-side client of the MiSTer H264 core

MIT licensed (`LICENSE`): link it from a program of any license. The rest of the repository
is GPL-3.0-or-later.

| | |
|---|---|
| `include/h264ring.h` | the library's API |
| `include/h264ring_layout.h` | the interface's layout -- **generated** by `tools/ring_layout.py`; never edit it |
| `lib/` | the protocol (`h264ring.c`), the MiSTer backend (`/dev/mem`, the lock, launching the core), the status dump, the Annex-B access-unit splitter |
| `feeder/h264play.c` | the reference feeder: plays an Annex-B file |
| `h264stat/h264stat.c` | prints the core's status block |
| `include/h264ring_cavlc.h`, `lib/h264ring_cavlc.c` | the CAVLC -> CABAC rewriter (fj#20): CAVLC streams for a core that decodes CABAC, bit-exact; its tables (`lib/h264ring_cavlc_tab.h`) **generated** by `tools/gen_hps_tables.py` |
| `cavlc2cabac/cavlc2cabac.c` | the rewriter on a file (`bench/h264/run_cavlc.sh`), and `--bench` for its CPU cost on the rig |
| `tests/test_ring.c` | the library against a fake core (`make test`; `tools/tests/test_hps_lib.py` adds the independent consumer and ffprobe) |
| `docker/`, `build_arm.sh` | the MiSTer build (pinned gcc-arm 10.2, static) |

```bash
make && make test                  # host
USE_DOCKER=1 ./build_arm.sh        # build/arm/{h264play,h264stat,cavlc2cabac,libh264ring.a}
```

The user-facing documentation is the manual's "Integrating a program" pages
(`site/content/integrating/`); the design is `docs/architecture.md` "The HPS interface".
