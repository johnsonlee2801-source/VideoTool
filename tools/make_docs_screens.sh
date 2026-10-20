#!/bin/zsh
# Screenshots for the README (docs/images/<lang>/*.jpg), rendered by DocsScreenshotTests
# in Chinese, English and Japanese, then composes the README feature cards
# (tools/compose_readme_art.py). The film is Tears of Steel (CC BY 3.0, Blender
# Foundation), credited in every README; its subtitles in docs/demo were made by
# VideoTool itself. The library shots still use generated footage (ffmpeg lavfi).
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
# Real film for the README feature art: Tears of Steel (CC BY 3.0, Blender Foundation,
# mango.blender.org), downloaded once (372 MB, one request) into the user's cache.
FILM="$HOME/Library/Caches/VideoTool-docs/tears_of_steel_720p.mov"
if [ ! -s "$FILM" ]; then
  mkdir -p "${FILM:h}"
  echo "downloading Tears of Steel (once)…"
  curl -sS -L -C - --retry 5 --retry-delay 20 -o "$FILM" https://download.blender.org/demo/movies/ToS/tears_of_steel_720p.mov
fi
film_cut() { [ -s "$CLIPS/$1.mp4" ] || ffmpeg -hide_banner -loglevel error -y -ss "$2" -t "$3" -i "$FILM" -c:v copy -c:a aac "$CLIPS/$1.mp4"; }
film_cut tos-open 0 60          # the argument on the bridge (AI subtitles in docs/demo)
film_cut tos-celia 395 20       # close-up (clip art)
film_cut tos-robot 490 40       # the robot on the bridge (speed art)
cp docs/demo/tos-open.*.srt "$CLIPS/"
rm -rf "$BASE/frames"      # frames are cached per clip and time; start fresh

touch "$BASE/RUN"          # enables DocsScreenshotTests for the next 10 minutes
scripts/xcb.sh test -only-testing:VideoToolTests/DocsScreenshotTests > "$BASE/docs.log" 2>&1 || true
/opt/anaconda3/bin/python3 tools/compose_readme_art.py "$OUT" docs/images     # feature cards from the D2 shots
grep -E "Test run with|✘ Test" "$BASE/docs.log" | head -5
for lang in zh en ja; do
  mkdir -p docs/images/$lang
  for png in "$OUT/$lang"/*.png(N); do
    [[ ${png:t} == f-* ]] && continue          # raw shots for compose_readme_art.py only
    sips -s format jpeg -s formatOptions 82 -Z 1600 "$png" --out "docs/images/$lang/${${png:t}%.png}.jpg" >/dev/null
  done
  cp "$OUT/$lang"/*.gif(N) docs/images/$lang/
done
rm -f "$BASE/RUN"
# One GIF for every language (the subtitles in it are the same).
[ -f docs/images/en/clip.gif ] && mv docs/images/en/clip.gif docs/images/clip.gif
rm -f docs/images/zh/clip.gif docs/images/ja/clip.gif
# Keep only the pictures a README shows.
for f in docs/images/*/*(N); do
  grep -q "${f}" README.md README.zh-CN.md README.ja.md || rm "$f"
done
du -sh docs/images | cut -f1 | xargs echo "docs/images:"
