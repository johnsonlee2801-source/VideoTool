#!/bin/zsh
# Run the prototype's unit tests with luajit (Lua 5.1 compatible, like mpv's Lua).
set -e
cd "${0:A:h}"
export VT_SCRIPT_DIR="${PWD:h}/mpv-config/scripts/hold-drag-speed"
LUA=${LUA:-$(command -v luajit || command -v lua5.1 || command -v lua)}
[ -n "$LUA" ] || { echo "no Lua interpreter found (brew install luajit)" >&2; exit 2; }
rc=0
for t in test_*.lua; do
  echo "== $t"
  "$LUA" "$t" || rc=1
done
exit $rc
