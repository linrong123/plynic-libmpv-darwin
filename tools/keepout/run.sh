#!/bin/bash
# run.sh <dist> [sw|gl]: the --sub-keepout checks of kotest.c on the macOS
# frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz), through
# the render API's software renderer (default; what CI runs) or OpenGL.
#
# keepout.mkv: 60 s of black (320x180, FFmpeg's mpeg4 encoder), sid 1 the
# two text lines of keepout.ass (1-50 s), sid 2 the PGS stream mksup.py
# writes (two bars where a Blu-ray subtitle sits; FFmpeg starts each input at
# 0, so 0-49 s in the MKV). Made with FFmpeg 8 from those two:
#   ffmpeg -f lavfi -i color=black:s=320x180:r=2:d=60 -c:v mpeg4 -g 20 -q:v 31 \
#     -bitexact -map_metadata -1 -fflags +bitexact black.mkv
#   python3 mksup.py bottom.sup
#   ffmpeg -i black.mkv -i keepout.ass -i bottom.sup -map 0:v -map 1:s -map 2:s \
#     -c copy -bitexact -fflags +bitexact -map_metadata -1 keepout.mkv
set -euo pipefail
dist=$(cd "$1" && pwd)
mode=${2:-sw}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -F "$work/fw" -framework Mpv -framework OpenGL -Wl,-rpath,"$work/fw" \
  -mmacosx-version-min=12.0 -o "$work/kotest" "$here/kotest.c"

fail=0
for sid in 1 2; do
  echo "== sid=$sid ($([ $sid = 1 ] && echo ASS || echo PGS)), $mode"
  "$work/kotest" "$mode" "$here/keepout.mkv" $sid 10 || fail=1
done
echo "== paused track switches, $mode"
"$work/kotest" "$mode" "$here/keepout.mkv" 1 10 switch || fail=1
exit $fail
