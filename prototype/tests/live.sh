#!/bin/zsh
# Integration lane: real mpv, no window, no audio. Drives the gesture through
# mpv's input pipeline via tests/live/driver.lua and checks speed/pause.
set -e
cd "${0:A:h}"
ROOT="${PWD:h}"
command -v mpv >/dev/null || { echo "mpv not found (brew install mpv)" >&2; exit 2; }
LOG="${TMPDIR:-/tmp}/hold-drag-speed-live.log"
rm -f "$LOG"
set +e
mpv --config-dir="$ROOT/mpv-config" --script="$PWD/live/driver.lua" \
    --vo=null --ao=null --no-terminal --log-file="$LOG" --msg-level=all=info \
    --idle=yes --keep-open=yes \
    "av://lavfi:testsrc=duration=600:size=320x240:rate=30" 2>/dev/null
rc=$?
set -e
grep -E "\[live\]" "$LOG" | sed -E 's/^\[[^]]*\]\[[^]]*\]\[[^]]*\] //'
if grep -qiE "\[(hold_drag_speed|driver)\].*(error|traceback)" "$LOG"; then
  echo "Lua errors in log:"; grep -iE "\[(hold_drag_speed|driver)\].*(error|traceback)" "$LOG"; rc=1
fi
echo "exit=$rc (log: $LOG)"
exit $rc
