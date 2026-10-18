#!/bin/zsh
# Build a Release VideoTool, install it to /Applications, and
# explain how to make it the default video player (macOS requires your confirmation).
# An existing /Applications/VideoTool.app is moved to the Trash first, never deleted.
set -e
cd "${0:A:h:h}"
VIDEOTOOL_CONFIGURATION=Release scripts/xcb.sh build > "${TMPDIR:-/tmp}/videotool-release-build.log" 2>&1 \
  || { tail -20 "${TMPDIR:-/tmp}/videotool-release-build.log"; exit 1; }
DD="${VIDEOTOOL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/VideoTool-cli}"
BUILT="$DD/Build/Products/Release/VideoTool.app"
DEST=/Applications/VideoTool.app
if [ -d "$DEST" ]; then
  # Into the Trash (recoverable), without scripting Finder (that would need an automation prompt).
  mv "$DEST" "$HOME/.Trash/VideoTool-$(date +%Y%m%d-%H%M%S).app"
fi
ditto "$BUILT" "$DEST"
xattr -cr "$DEST" 2>/dev/null || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
echo "installed: $DEST ($(defaults read "$DEST/Contents/Info" CFBundleShortVersionString))"
cat <<'MSG'
To make VideoTool the default video player, open it and choose
  文件 › 设为默认视频播放器…
macOS asks to confirm each format (one dialog at a time). Apps cannot switch
defaults silently on current macOS.
MSG
