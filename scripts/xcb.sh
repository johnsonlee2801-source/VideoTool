#!/bin/zsh
# xcodebuild wrapper. Usage: scripts/xcb.sh build | test | clean
# Build state lives OUTSIDE the repo: the repo sits on the iCloud-synced Desktop,
# where Xcode's package resolver silently resolves nothing (seen 2026-10-17)
# and codesign rejects FinderInfo xattrs.
set -e
cd "${0:A:h:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DD="${VIDEOTOOL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex}"
action=${1:-build}
(( $# > 0 )) && shift
[ -d VideoTool.xcodeproj ] || scripts/regen.sh
mkdir -p "$DD/Results"
stamp=$(date +%Y%m%d-%H%M%S)-$$          # pid suffix: unique even within one second
arch=${VIDEOTOOL_ARCH:-$(uname -m)}
config=${VIDEOTOOL_CONFIGURATION:-Debug}
set +e
xcodebuild \
  -project VideoTool.xcodeproj -scheme VideoTool -configuration "$config" -destination "platform=macOS,arch=$arch" \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$DD/SourcePackages" \
  -packageCachePath "$DD/PackageCache" \
  -resultBundlePath "$DD/Results/$action-$stamp.xcresult" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual \
  "$action" "$@"
rc=$?
# Build products are not installs: keep them out of Launchpad / "Open With".
# Only /Applications/VideoTool.app should be registered (scripts/install.sh).
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
for app in "$DD"/Build/Products/*/VideoTool.app; do [ -d "$app" ] && "$LSR" -u "$app" 2>/dev/null; done
exit $rc
