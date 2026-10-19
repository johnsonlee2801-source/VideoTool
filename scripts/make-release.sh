#!/bin/zsh
# Build a universal (Apple silicon + Intel) Release VideoTool and package it as a DMG.
#
#   scripts/make-release.sh            # ad-hoc signed: users open it once with "Open Anyway"
#
# Later, with a paid Apple Developer account, the same script signs with a
# Developer ID and notarizes, so it opens without any warning:
#
#   DEVELOPER_ID="Developer ID Application: Name (TEAMID)" \
#   NOTARY_PROFILE=videotool-notary scripts/make-release.sh
#
# (create the profile once with: xcrun notarytool store-credentials videotool-notary)
# Nothing secret lives in this repository: identities and credentials come from
# the environment and the login keychain.
set -e
cd "${0:A:h:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DD="${VIDEOTOOL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex}"
OUT="$DD/release"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" App/Info.plist)
LOG="${TMPDIR:-/tmp}/videotool-release-$VERSION.log"
mkdir -p "$OUT"

echo "building VideoTool $VERSION (universal)…"
[ -d VideoTool.xcodeproj ] || scripts/regen.sh
xcodebuild -project VideoTool.xcodeproj -scheme VideoTool -configuration Release \
  -destination "generic/platform=macOS" -derivedDataPath "$DD" \
  -clonedSourcePackagesDirPath "$DD/SourcePackages" -packageCachePath "$DD/PackageCache" \
  -skipPackagePluginValidation -skipMacroValidation \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO DEVELOPMENT_TEAM="" CODE_SIGN_STYLE=Manual \
  build > "$LOG" 2>&1 || { tail -30 "$LOG"; exit 1; }

APP="$OUT/VideoTool.app"
rm -rf "$APP"
ditto "$DD/Build/Products/Release/VideoTool.app" "$APP"
xattr -cr "$APP"
lipo -archs "$APP/Contents/MacOS/VideoTool"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --force --deep --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

DMG="$OUT/VideoTool-$VERSION.dmg"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/VideoTool.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "VideoTool $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" > /dev/null
rm -rf "$STAGE"

if [ -n "$DEVELOPER_ID" ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  if [ -n "$NOTARY_PROFILE" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "$DMG"
shasum -a 256 "$DMG"
