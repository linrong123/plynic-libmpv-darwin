#!/bin/bash
# run.sh <dist> [gl|glsw|sw] [strict]: screenshot-raw checks of shot.c on
# the macOS frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz).
#
# gl (default): OpenGL render API in a hardware-accelerated context, each
# clip decoded with VideoToolbox and in software - what the app does on a
# Mac. glsw: the same through CGL's software renderer, for machines without
# a GPU context (GitHub's macOS runners): VideoToolbox frames still reach
# the render API through the OpenGL interop, so the screenshot has to
# download them exactly as on a Mac. sw: the render API's software
# renderer, software decoding only (VideoToolbox frames need the OpenGL
# interop). strict: a VideoToolbox run that ends up decoding in software
# fails instead of passing on the software path; CI runs `glsw strict`, a
# release is published after `gl strict` on a Mac
# (tools/release/publish.sh). Without the requested OpenGL context the gl /
# glsw runs are skipped and say so; strict turns a skip into a failure.
#
# The last line is a summary: "SUMMARY <mode> [strict]: <n> passed, <n>
# failed, <n> skipped; GL <renderer>".
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
case "$mode" in gl|glsw|sw) ;; *) echo "run.sh: mode is gl, glsw or sw, not $mode" >&2; exit 2 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -Wno-deprecated-declarations -F "$work/fw" -framework Mpv -framework OpenGL \
  -Wl,-rpath,"$work/fw" -mmacosx-version-min=12.0 -o "$work/shot" "$here/shot.c"

hwdecs=(videotoolbox no)
[ "$mode" = sw ] && hwdecs=(no)
pass=0 fail=0 skip=0 renderer=-
for clip in shot_h264.mp4 shot_hevc10.mp4; do
  for hwdec in "${hwdecs[@]}"; do
    echo "== $clip, $mode, hwdec=$hwdec"
    req=
    [ "$hwdec" != no ] && [ "$strict" = strict ] && req=require-hwdec
    rc=0
    "$work/shot" "$mode" "$here/$clip" "$hwdec" $req > "$work/out" 2>&1 || rc=$?
    cat "$work/out"
    r=$(sed -n 's/^GL \(.*\) | .*/\1/p' "$work/out" | head -1)
    [ -n "$r" ] && renderer=$r
    if [ $rc -eq 77 ] && [ "$strict" != strict ]; then
      skip=$((skip + 1))
    elif [ $rc -eq 0 ]; then
      pass=$((pass + 1))
    else
      fail=$((fail + 1))
    fi
  done
done
echo "SUMMARY $mode${strict:+ $strict}: $pass passed, $fail failed, $skip skipped; GL $renderer"
[ $fail -eq 0 ]
