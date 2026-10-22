#!/usr/bin/env bash
# mb_census.sh -- which macroblock types (and how much of the High-profile 8x8 tools) a
# stream uses: the first N pictures traced by JM (tools/jm_build.sh's TRACE decoder, UMD's)
# through a FIFO into tools/p1/jm_mbcensus.awk (no trace file on disk). The awk assumes ONE
# IDR then P pictures only at 720x480 -- check with hdr_summary.py first (Sunshine streams are).
#
#   tools/p1/mb_census.sh STREAM.h264 [N_PICTURES (120)]
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
JM=${H264_JM_DIR:-${H264_REFS_DIR:-$HOME/h264-refs}/JM}/build_trace/bin/ldecod.exe
[ -x "$JM" ] || { echo "no traced JM at $JM (UMD's tools/jm_build.sh builds it)"; exit 2; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
ffmpeg -v error -y -i "$1" -c copy -frames:v "${2:-120}" "$W/w.264"
cd "$W" && mkfifo trace_dec.txt
awk -f "$HERE/jm_mbcensus.awk" trace_dec.txt & A=$!
"$JM" -p InputFile=w.264 -p OutputFile=/dev/null -p VQdim=0 -p ResidualsOutput=0 > jm.log 2>&1
wait $A
