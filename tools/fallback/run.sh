#!/bin/bash
# run.sh <dist>: what mpv does with a video stream no decoder can open, on
# the macOS frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz).
#
# hevc_bad_hvcc.mkv is hevc_good.mkv with its hvcC broken (mkbad.py): every
# libavcodec HEVC decoder, VideoToolbox's hwaccel included, refuses to open
# it ("Invalid NAL unit size in extradata."). Up to plynic-mpv f7a734caa2
# (rc7), and in upstream mpv, a hardware decoder that fails to open made
# vd_lavc fall back until a decoder opened, and when software decoding could
# not open either it tried software decoding again, forever: on the core
# thread, under the core lock, so every client call waited and mpv never
# said "Failed to initialize a decoder for codec 'hevc'". rc8 tries software
# decoding once. Cases (fallprobe.c: vo=null, ao=null, the core asked for
# time-pos once a second without blocking):
#   vt-copy   hwdec=videotoolbox-copy (a hwdec that opens a device without a
#             VO, so the hardware attempt really happens): a handful of
#             "Could not open codec." at most (8: one per decoding method for
#             each decoder the wrapper tries; rc7 logged 100 000 in 4 s), the
#             wrapper's verdict once, the core answering throughout, the
#             audio playing to its end
#   sw        hwdec=no: the same without the hardware attempt (this case
#             never looped)
#   good      hevc_good.mkv with hwdec=videotoolbox-copy: no failure at all
#             (the fixture itself decodes)
# The last line is a summary: "SUMMARY fallback: <n> passed, <n> failed".
#
# The clips (4 s, 160x90 HEVC + AAC):
#   ffmpeg -f lavfi -i testsrc2=size=160x90:rate=10 -f lavfi -i sine=frequency=440:sample_rate=48000 \
#     -t 4 -c:v libx265 -x265-params log-level=error:info=0 -pix_fmt yuv420p -c:a aac -b:a 32k \
#     -map_metadata -1 -fflags +bitexact -flags +bitexact hevc_good.mkv
#   ./mkbad.py hevc_good.mkv hevc_bad_hvcc.mkv
set -uo pipefail
dist=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -F "$work/fw" -framework Mpv -Wl,-rpath,"$work/fw" -mmacosx-version-min=12.0 \
  -o "$work/fallprobe" "$here/fallprobe.c" || exit 2

pass=0 fail=0
check() {  # check <label> <max open failures> <verdicts> <file> <options...>
  local label=$1 maxfail=$2 verdicts=$3 file=$4; shift 4
  echo "== $label"
  "$work/fallprobe" 8 "$here/$file" vo=null "$@" > "$work/out" 2>&1
  local rc=$?
  cat "$work/out"
  local opened verdict
  opened=$(sed -n 's/^COUNT *\([0-9]*\)  Could not open codec\..*/\1/p' "$work/out")
  verdict=$(sed -n 's/^COUNT *\([0-9]*\)  Failed to initialize a decoder.*/\1/p' "$work/out")
  if [ $rc -eq 0 ] && grep -q '^RESULT responsive' "$work/out" \
     && grep -q 'END_FILE reason=0' "$work/out" \
     && [ "${opened:-x}" -le "$maxfail" ] 2>/dev/null && [ "${verdict:-x}" = "$verdicts" ]; then
    echo "PASS $label"; pass=$((pass + 1))
  else
    echo "FAIL $label (rc $rc, $opened open failures, $verdict verdicts)"; fail=$((fail + 1))
  fi
}
check vt-copy 8 1 hevc_bad_hvcc.mkv hwdec=videotoolbox-copy
check sw 8 1 hevc_bad_hvcc.mkv hwdec=no
check good 0 0 hevc_good.mkv hwdec=videotoolbox-copy
echo "SUMMARY fallback: $pass passed, $fail failed"
[ $fail -eq 0 ]
