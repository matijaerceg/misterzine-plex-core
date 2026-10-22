#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/jellyfin.sh -- play your Jellyfin server's films and shows on the MiSTer H264 core.
# Run it from MiSTer's Scripts menu. The first run writes the settings file (set your server's
# address in it); the next loads the core: sign in with the code it shows (in any Jellyfin app:
# Settings > Quick Connect), then pick something in a Jellyfin app and play it on this MiSTer.
# Files: /media/fat/jellyfin/ (the client, jellyfin.ini, state.json, jellyfin.log).
# Quit: Back + Start on a pad (or Esc) while nothing plays, or load another core from the menu.
# Design: docs/jellyfin.md in the MiSTer H264 core's repository.
DIR=${JELLYFIN_DIR:-/media/fat/jellyfin}   # (the override: tests)
INI=$DIR/jellyfin.ini
LOG=$DIR/jellyfin.log
BIN=$DIR/jellyfin

[ -x "$BIN" ] || { echo "Jellyfin is not installed: $BIN is missing."; exit 1; }

if [ ! -f "$INI" ]; then
  cat > "$INI" <<'EOF'
; Jellyfin for the MiSTer H264 core. Set server, then run Jellyfin from Scripts again.
; server: your Jellyfin server's address, as a browser opens it
server=https://
; name: how this MiSTer appears in Jellyfin's "Play on" list
name=MiSTer
; Only for a server with Quick Connect turned off: a user and password to sign in with
; (kept here in clear -- prefer Quick Connect)
user=
password=
; The screensaver, against burn-in: minutes with nothing playing (a paused film, the ready
; screen) before the screen dims, then before it goes black; 0 turns that step off
;screensaver_dim=5
;screensaver_black=30
EOF
  echo "Created $INI."
  echo "Edit it (set server=...), then run Jellyfin again."
  exit 0
fi

server=$(grep -v '^[[:space:]]*[;#]' "$INI" | sed -n 's/^[[:space:]]*server[[:space:]]*=[[:space:]]*//p' | tr -d '\r' | tail -n 1)
case $server in
  http://?*|https://?*) ;;
  *) echo "Set server= in $INI first (https://your-server or http://address:8096)."; exit 1 ;;
esac

if pidof jellyfin >/dev/null; then
  echo "Jellyfin is already running."
  exit 1
fi

echo "Starting Jellyfin for $server."
echo "The first time, sign in with the code shown on the screen."
echo "Then play something from a Jellyfin app to \"this MiSTer\"."
# Detached: the client outlives this script's console and the core load it makes. When it
# exits, for any reason, go back to the menu -- but only from this core, never another.
setsid nohup bash -c '
  bin=$1; log=$2
  "$bin" > "$log" 2>&1
  echo "jellyfin exited: $?" >> "$log"
  [ "$(cat /tmp/CORENAME 2>/dev/null)" = H264 ] && echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
' jellyfin "$BIN" "$LOG" > /dev/null 2>&1 < /dev/null &
exit 0
