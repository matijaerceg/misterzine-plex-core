#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Scripts/moonlight.sh -- stream a PC's desktop or games to the MiSTer H264 core with Moonlight.
# Run it from MiSTer's Scripts menu. The first run writes the settings file; the next pairs
# with the PC (a PIN to type into Sunshine's web page); after that each run starts a stream.
# Files: /media/fat/moonlight/ (the client, moonlight.ini, keys/, moonlight.log).
# The keyboard, mouse and pads reach the PC through the core (Main holds every input device
# while a core runs; the core hands this program what Main sends it). Quit: Ctrl+Alt+Shift+Q,
# or Start+Back+LB+RB on a pad. Design: docs/moonlight.md in the MiSTer H264 core's repository.
DIR=${MOONLIGHT_DIR:-/media/fat/moonlight}   # (the override: tests)
INI=$DIR/moonlight.ini
LOG=$DIR/moonlight.log
BIN=$DIR/moonlight

[ -x "$BIN" ] || { echo "Moonlight is not installed: $BIN is missing."; exit 1; }

if [ ! -f "$INI" ]; then
  cat > "$INI" <<'EOF'
; Moonlight for the MiSTer H264 core. Set host, then run Moonlight from Scripts again.
; host: the PC running Sunshine -- its IP address, or a name your network resolves
host=
; app: as the PC lists it (Desktop, Steam Big Picture, ...)
app=Desktop
; the picture the PC encodes. Empty (the default): the MiSTer screen's shape --
; 640x480 on a 4:3 screen (an analog TV, or Aspect Ratio 4:3), else 848x480 (16:9).
; Or set both (640x480, 848x480, ...): the core decodes up to 1,620 macroblocks
; (854x480) at 60 frames/s in real time.
width=
height=
fps=60
; the bitrate asked for, kbit/s
bitrate=10000
; 1: quit the app on the PC when the stream ends
quitappafter=0
EOF
  echo "Created $INI."
  echo "Edit it (set host=...), then run Moonlight again."
  exit 0
fi

host= app=Desktop width= height= fps=60 bitrate=10000 quitappafter=0
while IFS='=' read -r k v; do
  k=${k//[[:space:]]/}
  v=${v%$'\r'}
  v=${v#"${v%%[![:space:]]*}"}
  v=${v%"${v##*[![:space:]]}"}
  case $k in
    host|app|width|height|fps|bitrate|quitappafter) printf -v "$k" '%s' "$v" ;;
  esac
done < <(grep -v '^[[:space:]]*[;#]' "$INI")

[ -n "$host" ] || { echo "Set host= in $INI first."; exit 1; }
for n in fps bitrate quitappafter; do
  [[ ${!n} =~ ^[0-9]+$ ]] || { echo "$n=${!n} in $INI is not a number."; exit 1; }
done
if [ -z "$width$height" ]; then
  width=0 height=0      # the client asks for the screen's shape
elif ! [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]]; then
  echo "Set both width= and height= in $INI (numbers), or leave both empty."
  exit 1
fi

if pidof moonlight >/dev/null; then
  echo "Moonlight is already streaming."
  exit 1
fi

mkdir -p "$DIR/keys"
cd "$DIR" || exit 1

# paired? (the client makes its keys on first use)
out=$("$BIN" list "$host" -keydir "$DIR/keys" 2>&1)
if grep -q "must pair" <<<"$out"; then
  echo "Pairing with $host."
  echo "On the PC, open Sunshine's web page (PIN tab) and type the PIN below."
  "$BIN" pair "$host" -keydir "$DIR/keys" 2>&1
  echo "Then run Moonlight again to stream."
  exit 0
fi
if ! grep -q '^1\. ' <<<"$out"; then
  tail -n 5 <<<"$out"
  echo "Could not reach $host."
  exit 1
fi
if ! sed -n 's/^[0-9]*\. //p' <<<"$out" | grep -qxF -- "$app"; then
  echo "$host has no app called \"$app\". It has:"
  grep '^[0-9]*\. ' <<<"$out"
  exit 1
fi

args=(stream "$host" -keydir "$DIR/keys" -app "$app" -width "$width" -height "$height"
      -fps "$fps" -bitrate "$bitrate" -codec h264 -platform mister -nosops)
[ "$quitappafter" = 1 ] && args+=(-quitappafter)

echo "Streaming $app from $host."
echo "To stop: Ctrl+Alt+Shift+Q, or Start+Back+LB+RB on a pad (or load another core from the MiSTer menu)."
# Detached: the client outlives this script's console and the core load it makes. When it
# exits, for any reason, go back to the menu -- but only from this core, never another.
setsid nohup bash -c '
  bin=$1; log=$2; shift 2
  "$bin" "$@" > "$log" 2>&1
  echo "moonlight exited: $?" >> "$log"
  [ "$(cat /tmp/CORENAME 2>/dev/null)" = H264 ] && echo "load_core /media/fat/menu.rbf" > /dev/MiSTer_cmd
' moonlight "$BIN" "$LOG" "${args[@]}" > /dev/null 2>&1 < /dev/null &
exit 0
