#!/bin/bash
# run.sh <dist> [gl|sw] [strict]: screenshot-raw checks of shot.c on the
# macOS frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz).
#
# gl (default): OpenGL render API, each clip decoded with VideoToolbox and in
# software. sw: the software renderer, software decoding only (VideoToolbox
# frames need the OpenGL interop). strict: a VideoToolbox run that ends up
# decoding in software fails instead of passing on the software path; use it
# on a Mac, not in a VM. Without an OpenGL context (some CI machines) the gl
# runs are skipped and say so.
#
# The clips are 3 s of FFmpeg's testsrc2 at 320x180:
#   ffmpeg -f lavfi -i testsrc2=size=320x180:rate=10 -t 3 -c:v h264_videotoolbox \
#     -b:v 100k -g 10 -an -map_metadata -1 -fflags +bitexact shot_h264.mp4
#   ffmpeg -f lavfi -i testsrc2=size=320x180:rate=10 -t 3 -c:v libx265 \
#     -pix_fmt yuv420p10le -tag:v hvc1 -x265-params keyint=10 -b:v 60k -an \
#     -map_metadata -1 -fflags +bitexact shot_hevc10.mp4
# (VideoToolbox hands out nv12 for the first and p010 for the second.)
set -euo pipefail
dist=$(cd "$1" && pwd)
mode=${2:-gl}
strict=${3:-}
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -F "$work/fw" -framework Mpv -framework OpenGL -Wl,-rpath,"$work/fw" \
  -mmacosx-version-min=12.0 -o "$work/shot" "$here/shot.c"

hwdecs=(videotoolbox no)
[ "$mode" = sw ] && hwdecs=(no)
fail=0
for clip in shot_h264.mp4 shot_hevc10.mp4; do
  for hwdec in "${hwdecs[@]}"; do
    echo "== $clip, $mode, hwdec=$hwdec"
    req=
    [ "$hwdec" != no ] && [ "$strict" = strict ] && req=require-hwdec
    rc=0
    "$work/shot" "$mode" "$here/$clip" "$hwdec" $req || rc=$?
    [ $rc -eq 77 ] && continue
    [ $rc -ne 0 ] && fail=1
  done
done
exit $fail
