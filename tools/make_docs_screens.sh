#!/bin/zsh
# Screenshots for the README (docs/images/<lang>/*.jpg), rendered by DocsScreenshotTests
# in Chinese, English and Japanese. The demo footage is generated here (ffmpeg lavfi:
# fractals and gradients), so the images carry no third-party content.
# Usage: tools/make_docs_screens.sh      Needs ffmpeg; run outside the sandbox.
set -e
cd "${0:A:h:h}"
BASE="${TMPDIR:-/tmp}/videotool-docs"     # the test host shares this temp dir
CLIPS="$BASE/clips"; OUT="$BASE/out"
mkdir -p "$CLIPS"; rm -rf "$OUT"; mkdir -p "$OUT"
make() { [ -s "$CLIPS/$1" ] || { echo "making $1…"; local n=$1; shift; ffmpeg -hide_banner -loglevel error -y "$@" "$CLIPS/$n"; } }
make neon.mp4   -f lavfi -i "mandelbrot=s=1920x1080:rate=24:start_scale=3:end_scale=0.0004:outer=normalized_iteration_count" \
                -t 20 -vf "hue=h=300:s=1.6,eq=contrast=1.15:saturation=1.4" -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p
make aurora.mp4 -f lavfi -i "gradients=s=1920x1080:c0=0x0A0A0F:c1=0xFF2E63:c2=0x7B61FF:c3=0x08D9D6:nb_colors=4:speed=0.02:type=radial" \
                -t 20 -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p
make cells.mp4  -f lavfi -i "cellauto=s=480x270:rule=110:rate=24,scale=1920:1080:flags=neighbor,format=yuv420p,lutyuv=u=128+(val-128)*0:v=128" \
                -t 20 -vf "colorchannelmixer=rr=0.1:gg=0.85:bb=0.84" -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p
make life.mp4   -f lavfi -i "life=s=480x270:mold=10:r=24:ratio=0.1:death_color=#1D1D27:life_color=#FFD60A:mold_color=#FF2E63" \
                -t 20 -vf "scale=1920:1080:flags=neighbor" -c:v libx264 -preset veryfast -crf 22 -pix_fmt yuv420p
touch "$BASE/RUN"          # enables DocsScreenshotTests for the next 10 minutes
scripts/xcb.sh test -only-testing:VideoToolTests/DocsScreenshotTests > "$BASE/docs.log" 2>&1 || true
grep -E "Test run with|✘ Test" "$BASE/docs.log" | head -5
for lang in zh en ja; do
  mkdir -p docs/images/$lang
  for png in "$OUT/$lang"/*.png(N); do
    sips -s format jpeg -s formatOptions 82 -Z 1600 "$png" --out "docs/images/$lang/${${png:t}%.png}.jpg" >/dev/null
  done
  cp "$OUT/$lang"/*.gif(N) docs/images/$lang/
done
rm -f "$BASE/RUN"
du -sh docs/images | cut -f1 | xargs echo "docs/images:"
