#!/bin/zsh
# Builds Tests/Fixtures/speech-en.mkv: a black 320x180 H.264 video with an English
# voice from macOS `say` (AAC). Used by the AI subtitle tests: the words are known,
# so recognition and timing can be checked. Needs ffmpeg (Homebrew).
set -e
cd "${0:A:h:h}"
tmp=$(mktemp -d)
say -v Samantha -o "$tmp/speech.aiff" \
  "Hello everyone. Today we will learn how to watch videos faster. Press and hold the picture to speed up. Release the mouse to return to normal speed."
ffmpeg -hide_banner -loglevel error -y -f lavfi -i "color=c=black:s=320x180:r=10" -i "$tmp/speech.aiff" \
  -shortest -c:v libx264 -preset veryfast -tune stillimage -c:a aac -b:a 48k Tests/Fixtures/speech-en.mkv
rm -r "$tmp"
ls -la Tests/Fixtures/speech-en.mkv
