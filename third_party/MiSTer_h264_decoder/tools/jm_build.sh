#!/usr/bin/env bash
# Build the JM 18.4 reference decoder with syntax-element tracing (TRACE 1), as the
# CABAC golden for Phase 3 (docs/roadmap.md, docs/references.md).
#
# JM's TRACE is a compile-time constant in ldecod/inc/defines.h (it #undefs any -D), so
# the source is copied to $H264_REFS_DIR/JM/build_trace/ and patched there; the pristine
# tree is never touched. The tree also calls MSVC-only functions unguarded
# (_aligned_malloc, _fseeki64, __int64): tools/jm_posix_compat.h stands them in.
#
#   tools/jm_build.sh            -> $H264_REFS_DIR/JM/build_trace/bin/ldecod.exe
#   tools/jm_build.sh --clean    rebuild from scratch
#   tools/jm_build.sh --lencod   -> $H264_REFS_DIR/JM/build_enc/bin/lencod.exe: the JM 18.4
#                                encoder, untouched, for the P4 control-path fixtures
#                                (field MMCOs, long-term references, the B-list swap, list
#                                modification: tools/jm_fixtures.py)
#
# The traced decoder writes trace_dec.txt in its working directory; tools/h264_trace_ref.py
# runs it and normalises that file.
set -eu
cd "$(dirname "$0")/.."
REFS="${H264_REFS_DIR:-$HOME/h264-refs}"
JM="${H264_JM_DIR:-$REFS/JM}"
B="$JM/build_trace"
[ -d "$JM/ldecod/src" ] || { echo "jm_build: no JM source at $JM (set H264_REFS_DIR / H264_JM_DIR)"; exit 2; }
if [ "${1:-}" = "--lencod" ]; then
    E="$JM/build_enc"
    if [ ! -d "$E/lencod" ]; then
        mkdir -p "$E"
        cp -r "$JM/lencod" "$JM/lcommon" "$E/"
        rm -rf "$E/lencod/obj" "$E/bin"
    fi
    mkdir -p "$E/bin"
    make -C "$E/lencod" \
        CFLAGS="-w -fcommon -include $(pwd)/tools/jm_posix_compat.h" 2>&1 | grep -v '^compiling object' || true
    [ -x "$E/bin/lencod.exe" ] || { echo "jm_build: no lencod binary produced"; exit 1; }
    echo "jm_build: $E/bin/lencod.exe"
    exit 0
fi
[ "${1:-}" = "--clean" ] && rm -rf "$B"
if [ ! -f "$B/ldecod/inc/defines.h" ]; then
    mkdir -p "$B"
    cp -r "$JM/ldecod" "$JM/lcommon" "$B/"
    rm -rf "$B/ldecod/obj" "$B/bin"
    sed -i 's/^\(# *define TRACE  *\)0 /\11 /' "$B/ldecod/inc/defines.h"
fi
grep -q 'define TRACE  *1' "$B/ldecod/inc/defines.h" || { echo "jm_build: TRACE patch failed"; exit 2; }
mkdir -p "$B/bin"
make -C "$B/ldecod" \
    CFLAGS="-w -fcommon -include $(pwd)/tools/jm_posix_compat.h" 2>&1 | grep -v '^compiling object' || true
[ -x "$B/bin/ldecod.exe" ] || { echo "jm_build: no binary produced"; exit 1; }
echo "jm_build: $B/bin/ldecod.exe"
