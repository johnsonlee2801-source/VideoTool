#!/bin/zsh
# Builds a large synthetic library (N distinct short videos, default 1000) in the
# test runner's temp dir, runs StressTests against it, and prints the measurements.
# Each file is a copy of a few real clips with a unique tail, so every file has its
# own fingerprint and goes through the full fingerprint → probe → thumbnail → tag path.
set -e
cd "${0:A:h:h}"
N=${1:-1000}
BASE="${TMPDIR:-/tmp}/videotool-stress"     # the test host shares this temp dir
LIB="$BASE/library"
mkdir -p "$LIB"
SRC=(Tests/Fixtures/formats/h264_aac.mp4 Tests/Fixtures/formats/hevc_aac.mp4 Tests/Fixtures/formats/vp9_opus.webm Tests/Fixtures/formats/mpeg4_mp3.avi)
if [[ $(ls "$LIB" | wc -l) -lt $N ]]; then
  for i in $(seq 1 $N); do
    src=${SRC[$(( (i % ${#SRC[@]}) + 1 ))]}
    sub="$LIB/folder$(( i % 20 ))"; mkdir -p "$sub"
    out="$sub/clip $(printf %04d $i).${src##*.}"
    cp "$src" "$out"; printf 'videotool-stress-%08d' $i >> "$out"
  done
fi
echo "library: $(find "$LIB" -type f | wc -l | tr -d ' ') files in $(du -sh "$LIB" | cut -f1)"
touch "$BASE/RUN"          # enables StressTests for the next 10 minutes
VIDEOTOOL_CONFIGURATION=Debug scripts/xcb.sh test -only-testing:VideoToolTests/StressTests > "$BASE/stress.log" 2>&1 || true
grep -E "Test run with|✘" "$BASE/stress.log" | head -5
cat "$BASE/stress-results.json" 2>/dev/null || echo "no results (see $BASE/stress.log)"
