#!/bin/zsh
# Runs every app test with code coverage on and prints line coverage per file of
# VideoTool.app, weakest first. Fails if total line coverage drops below the floor.
# Usage: scripts/coverage.sh [floor-percent]   (default 85; 2026-10-18 baseline: 87.3)
# Run outside the agent sandbox (xcodebuild writes to ~/Library).
set -e
cd "${0:A:h:h}"
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
DD="${VIDEOTOOL_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData/VideoTool-cli.noindex}"
floor=${1:-85}
set +e
scripts/xcb.sh test -enableCodeCoverage YES > "$DD/coverage-last.log" 2>&1
rc=$?
set -e
grep -E "Test run with" "$DD/coverage-last.log" | tail -1
if [ $rc -ne 0 ]; then echo "tests failed (exit $rc); see $DD/coverage-last.log"; exit 1; fi
result=$(ls -td "$DD"/Results/test-*.xcresult | head -1)
xcrun xccov view --report --json "$result" | /opt/anaconda3/bin/python3 -c '
import json, sys
floor = float(sys.argv[1])
app = next(t for t in json.load(sys.stdin)["targets"] if t["name"] == "VideoTool.app")
for f in sorted(app["files"], key=lambda f: f["lineCoverage"]):
    print("  %5.1f%%  %4d  %s" % (f["lineCoverage"] * 100, f["executableLines"], f["name"]))
total = app["lineCoverage"] * 100
print("VideoTool.app line coverage: %.1f%% (%d/%d), floor %.0f%%" % (total, app["coveredLines"], app["executableLines"], floor))
sys.exit(0 if total >= floor else 1)
' "$floor"
