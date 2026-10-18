#!/bin/zsh
# xcodebuild wrapper. Usage: scripts/xcb.sh build | test | clean
# Build state lives OUTSIDE the repo: the repo sits on the iCloud-synced Desktop,
# where Xcode's package resolver silently resolves nothing (seen 2026-10-17)
# and codesign rejects FinderInfo xattrs.
set -e
cd "${0:A:h:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DD="${VIDEOTOOL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/VideoTool-cli}"
action=${1:-build}
(( $# > 0 )) && shift
[ -d VideoTool.xcodeproj ] || scripts/regen.sh
mkdir -p "$DD/Results"
stamp=$(date +%Y%m%d-%H%M%S)-$$          # pid suffix: unique even within one second
arch=${VIDEOTOOL_ARCH:-$(uname -m)}
exec xcodebuild \
  -project VideoTool.xcodeproj -scheme VideoTool -destination "platform=macOS,arch=$arch" \
  -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$DD/SourcePackages" \
  -packageCachePath "$DD/PackageCache" \
  -resultBundlePath "$DD/Results/$action-$stamp.xcresult" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual \
  "$action" "$@"
