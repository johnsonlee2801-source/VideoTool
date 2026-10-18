#!/bin/zsh
# Build the library and run its Swift Testing suite with plain swiftc.
# Exists because SwiftPM cannot run inside the agent's sandbox (its nested
# sandbox-exec and build service are blocked). In a normal terminal,
# `swift test` in this directory does the same thing.
set -e
cd "${0:A:h:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
TC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain"
FW="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
OUT="$PWD/.build-direct"; mkdir -p "$OUT"
MC="${SWIFT_MODULE_CACHE:-$OUT/modcache}"
quiet() { grep -vE "xcrun_db|DVTFilePathFSEvents" || true; }

echo "== compiling VideoToolCore"
swiftc -module-cache-path "$MC" -swift-version 6 -enable-testing -parse-as-library \
  -emit-module -emit-module-path "$OUT/VideoToolCore.swiftmodule" \
  -emit-library -module-name VideoToolCore Sources/VideoToolCore/*.swift \
  -o "$OUT/libVideoToolCore.dylib" 2> >(quiet >&2)

cat > "$OUT/main.swift" <<'SWIFT'
import Testing
@main struct Runner {
    static func main() async { await Testing.__swiftPMEntryPoint() as Never }
}
SWIFT

echo "== compiling tests"
swiftc -module-cache-path "$MC" -swift-version 6 -parse-as-library \
  -I "$OUT" -L "$OUT" -lVideoToolCore -F "$FW" \
  -plugin-path "$TC/usr/lib/swift/host/plugins/testing" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$OUT" \
  Tests/VideoToolCoreTests/*.swift "$OUT/main.swift" -o "$OUT/runner" 2> >(quiet >&2)

echo "== running"
"$OUT/runner" "$@"
