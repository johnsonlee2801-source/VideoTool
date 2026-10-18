#!/bin/zsh
# Launch mpv with the prototype config only. Usage: ./run.sh /path/to/video.mp4
set -e
DIR="${0:A:h}"
if ! command -v mpv >/dev/null; then
  echo "mpv not found. Install with: brew install mpv" >&2
  exit 1
fi
# Every run leaves a log next to the prototype so a misbehaving gesture can be
# diagnosed afterwards (script events are logged at info level).
exec mpv --config-dir="$DIR/mpv-config" --log-file="$DIR/last-run.log" --msg-level=hold_drag_speed=info "$@"
