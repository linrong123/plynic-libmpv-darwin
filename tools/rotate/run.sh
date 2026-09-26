#!/bin/bash
# run.sh <dist> [gl|glsw|sw] [strict]: the rotation checks of rot.c on the
# macOS frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz).
#
# mpv rotates in the VO when the VO says it can (VO_CAP_ROTATE90: the render
# API's vo=libmpv) and otherwise inserts lavfi's `rotate` filter, which
# these frameworks do not have (FFmpeg with the overlay and equalizer
# filters only). Cases, per hwdec (videotoolbox and no; sw: no):
#   video-rotate  rot.mp4, video-rotate 0/90/180/270/0, each frame read back
#                 from the render target: no rotation filter asked for
#   file          rot_meta90.mp4 (the rotation in the file: a display matrix
#                 of 90 degrees counter-clockwise, which FFmpeg shows as
#                 GWRB), then video-rotate=90 on top of it
# and once, without a render context:
#   null          vo=null on rot_meta90.mp4: the chain asks for the filter and
#                 mpv logs "filter 'rotate' not found or failed to allocate"
#                 (what an app sees while its player has no video output yet)
# gl, glsw, sw as tools/shot, with two differences:
# - sw: the render API's software renderer cannot rotate. It draws every
#   frame unrotated (plynic-mpv 7a94ec5719, upstream's fix: vo_libmpv takes
#   the backend's capabilities); rc5 and earlier aborted on the first frame
#   rotated by 90 or 270 degrees (an assertion in mp_image_crop()), which is
#   what media_kit_video's software texture - the iOS simulator, a device
#   without the OpenGL texture - did with every portrait phone video. So sw
#   expects RGBW throughout, and a crash fails.
# - glsw renders with gpu-dumb-mode=yes: through mpv's full pipeline (its
#   floating-point intermediate textures) CGL's software renderer returns
#   black frames. The rotation is the same final pass in both.
# strict, as tools/shot: a skipped case (no such OpenGL context here) fails,
# and a VideoToolbox case has to decode with VideoToolbox at every mark
# (hwdec-current; without it a fallback to software decoding passed on the
# software path). CI runs `glsw strict` (its VM decodes H.264 with
# VideoToolbox, see tools/shot) and `sw` (software decoding only).
# The last line is a summary: "SUMMARY rotate <mode> [strict]: <n> passed,
# <n> failed, <n> skipped".
#
# The clips: four 160x90 quadrants, red green / blue white, 10 fps, 20 s
# (plynic-libmpv-android's tools/rotate-check has the same two):
#   q="color=0xff0000:s=160x90:r=10:d=20[a];color=0x00ff00:s=160x90:r=10:d=20[b];"
#   q="$q color=0x0000ff:s=160x90:r=10:d=20[c];color=0xffffff:s=160x90:r=10:d=20[d];"
#   q="$q [a][b][c][d]xstack=inputs=4:layout=0_0|w0_0|0_h0|w0_h0"
#   ffmpeg -f lavfi -i "$q" -c:v libx264 -preset veryslow -bf 0 -crf 30 -pix_fmt yuv420p \
#     -g 10 -an -map_metadata -1 -fflags +bitexact -flags +bitexact rot.mp4
#   ffmpeg -display_rotation 90 -i rot.mp4 -c copy -map_metadata -1 \
#     -fflags +bitexact rot_meta90.mp4
set -euo pipefail
dist=$(cd "$1" && pwd)
mode=${2:-gl}
strict=${3:-}
case "$mode" in gl|glsw|sw) ;; *) echo "run.sh: mode is gl, glsw or sw, not $mode" >&2; exit 2 ;; esac
case "$strict" in ""|strict) ;; *) echo "run.sh: the third argument is strict or nothing, not $strict" >&2; exit 2 ;; esac
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -Wno-deprecated-declarations -F "$work/fw" -framework Mpv -framework OpenGL \
  -Wl,-rpath,"$work/fw" -mmacosx-version-min=12.0 -o "$work/rot" "$here/rot.c"

hwdecs=(videotoolbox no)
[ "$mode" = sw ] && hwdecs=(no)
# the layouts at video-rotate 0, 90, 180, 270, and of rot_meta90.mp4 (270)
r0=RGBW r90=BRWG r180=WBGR r270=GWRB
[ "$mode" = sw ] && r90=RGBW r180=RGBW r270=RGBW
opts=()
[ "$mode" = glsw ] && opts=(gpu-dumb-mode=yes)
pass=0 fail=0 skip=0
check() {  # check <label> <rot args...>
  echo "== $1"; shift
  local rc=0
  "$work/rot" "$@" || rc=$?
  if [ $rc -eq 77 ] && [ "$strict" != strict ]; then
    skip=$((skip + 1))
  elif [ $rc -eq 0 ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
  fi
}
for hwdec in "${hwdecs[@]}"; do
  req=()
  [ "$hwdec" != no ] && [ "$strict" = strict ] && req=(require-hwdec)
  check "video-rotate, $mode, hwdec=$hwdec" "$mode" "$here/rot.mp4" "$hwdec" ${req[@]+"${req[@]}"} \
    ${opts[@]+"${opts[@]}"} \
    +wait=1 +mark=$r0 +set=video-rotate=90 +wait=0.8 +mark=$r90 +set=video-rotate=180 +wait=0.8 +mark=$r180 \
    +set=video-rotate=270 +wait=0.8 +mark=$r270 +set=video-rotate=0 +wait=0.8 +mark=$r0
  check "file, $mode, hwdec=$hwdec" "$mode" "$here/rot_meta90.mp4" "$hwdec" ${req[@]+"${req[@]}"} \
    ${opts[@]+"${opts[@]}"} +wait=1 +mark=$r270 +set=video-rotate=90 +wait=0.8 +mark=$r0
done
check "null, vo=null, hwdec=no" null "$here/rot_meta90.mp4" no +wait=1
echo "SUMMARY rotate $mode${strict:+ $strict}: $pass passed, $fail failed, $skip skipped"
[ $fail -eq 0 ]
