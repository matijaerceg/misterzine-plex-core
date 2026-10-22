#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/h264cam.sh -- show a USB camera or video capture device on the MiSTer H264 core. Run it
# from MiSTer's Scripts menu: it loads the core and waits for a camera; plug one in (or have it
# plugged in already). Cameras that send MJPEG work best (most webcams).
# Controls: A pause, B the mode list, Back + Start quit (or load another core from the menu).
# Design: docs/uvc.md in the MiSTer H264 core's repository.
DIR=${H264CAM_DIR:-/media/fat/h264cam}   # (the override: tests)
LOG=$DIR/h264cam.log
BIN=$DIR/h264cam

[ -x "$BIN" ] || { echo "The camera viewer is not installed: $BIN is missing."; exit 1; }

if pidof h264cam >/dev/null; then
  echo "The camera viewer is already running."
  exit 1
fi
for p in h264player moonlight jellyfin; do
  if pidof "$p" >/dev/null; then
    echo "Another H264 program ($p) is running: quit it first."
    exit 1
  fi
done

echo "Starting the camera viewer."
echo "Plug in a USB camera if it is not plugged in yet."
# Detached: the viewer outlives this script's console and the core load it makes. Pinned to CPU0:
# Main holds CPU1 (docs/uvc.md U2). When it exits, for any reason, go back to the menu -- but only
# from this core, never another.
setsid nohup bash -c '
  bin=$1; log=$2
  taskset -c 0 "$bin" > "$log" 2>&1
  echo "h264cam exited: $?" >> "$log"
  [ "$(cat /tmp/CORENAME 2>/dev/null)" = H264 ] && echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
' h264cam "$BIN" "$LOG" > /dev/null 2>&1 < /dev/null &
exit 0
