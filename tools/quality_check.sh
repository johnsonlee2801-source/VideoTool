#!/bin/zsh
# Picture and performance check (review study 2026-10-19: fans and CPU on 4K,
# laggy seeking, dropped frames, HDR looking wrong). Generates large test clips
# (kept out of the repo, ~150 MB, cached), plays them in a real player window
# with QualityTests, and prints the measurements.
# Usage: tools/quality_check.sh       Needs ffmpeg (Homebrew); run outside the sandbox.
# Run it with the screen on and unlocked: with the display asleep, frame and seek
# numbers cannot be measured (the results say "screenLive": false). macOS does not
# let the test window come to the front by itself: click it once when it appears
# (the test waits 30 s), otherwise frames/seeks are reported as not measured.
set -e
cd "${0:A:h:h}"
BASE="${TMPDIR:-/tmp}/videotool-quality"   # the test host shares this temp dir
CLIPS="$BASE/clips"
mkdir -p "$CLIPS"
make() { [ -s "$CLIPS/$1" ] || { echo "making $1…"; shift; ffmpeg -hide_banner -loglevel error -y "$@"; } }
# 4K HEVC 10-bit HDR10 (PQ, BT.2020) with sound
make hdr10_4k_hevc10.mkv -f lavfi -i "testsrc2=s=3840x2160:r=24" -f lavfi -i "sine=f=440:r=48000" -t 12 \
  -c:v libx265 -preset ultrafast -crf 20 -pix_fmt yuv420p10le \
  -x265-params "hdr10=1:repeat-headers=1:colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc:master-display=G(13250,34500)B(7500,3000)R(34000,16000)WP(15635,16450)L(10000000,1):max-cll=1000,400" \
  -c:a aac -b:a 128k "$CLIPS/hdr10_4k_hevc10.mkv"
# 4K 60 fps H.264 at ~60 Mbit/s
make h264_4k60_high.mp4 -f lavfi -i "testsrc2=s=3840x2160:r=60" -f lavfi -i "sine=f=330:r=48000" -t 12 \
  -c:v libx264 -preset veryfast -b:v 60M -maxrate 60M -bufsize 120M -pix_fmt yuv420p -g 120 \
  -c:a aac -b:a 128k "$CLIPS/h264_4k60_high.mp4"
# 1080p HEVC 8-bit, long GOP (seeking has to decode from far keyframes)
make hevc_1080_longgop.mp4 -f lavfi -i "testsrc2=s=1920x1080:r=30" -f lavfi -i "sine=f=550:r=48000" -t 60 \
  -c:v libx265 -preset ultrafast -crf 24 -x265-params "keyint=300:min-keyint=300" -tag:v hvc1 \
  -c:a aac -b:a 96k "$CLIPS/hevc_1080_longgop.mp4"
du -sh "$CLIPS" | cut -f1 | xargs echo "clips:"
touch "$BASE/RUN"          # enables QualityTests for the next 10 minutes
rm -f "$BASE/quality-results.json"
scripts/xcb.sh test -only-testing:VideoToolTests/QualityTests > "$BASE/quality.log" 2>&1 || true
grep -E "Test run with|✘ Test|↳ [a-z]" "$BASE/quality.log" | grep -v "^.*Connection" | head -20
cat "$BASE/quality-results.json" 2>/dev/null || echo "no results (see $BASE/quality.log)"
