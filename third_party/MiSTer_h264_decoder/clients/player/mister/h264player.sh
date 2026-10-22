#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/h264player.sh -- play video files from the SD card, a USB drive or a network share on
# the MiSTer H264 core. Run it from MiSTer's Scripts menu: it loads the core and shows your video
# folders; pick a file with the pad (A open, B back).
# Folders: /media/fat/video (made on the first run), /media/usb0-7, /media/fat/cifs -- or root=
# lines in /media/fat/h264player/h264player.ini.
# What plays: standard-definition H.264 (High or Main, CABAC, 8-bit) -- the manual's
# Compatibility page says how to convert anything else.
# Quit: Back + Start on a pad (or Q) in the list, or load another core from the menu.
# Design: docs/player.md in the MiSTer H264 core's repository.
DIR=${H264PLAYER_DIR:-/media/fat/h264player}   # (the override: tests)
LOG=$DIR/h264player.log
BIN=$DIR/h264player

[ -x "$BIN" ] || { echo "The video player is not installed: $BIN is missing."; exit 1; }
mkdir -p /media/fat/video

if pidof h264player >/dev/null; then
  echo "The video player is already running."
  exit 1
fi

echo "Starting the video player."
echo "Put videos in /media/fat/video, or on a USB drive."
# Detached: the player outlives this script's console and the core load it makes. When it
# exits, for any reason, go back to the menu -- but only from this core, never another.
setsid nohup bash -c '
  bin=$1; log=$2
  "$bin" > "$log" 2>&1
  echo "h264player exited: $?" >> "$log"
  [ "$(cat /tmp/CORENAME 2>/dev/null)" = H264 ] && echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
' h264player "$BIN" "$LOG" > /dev/null 2>&1 < /dev/null &
exit 0
