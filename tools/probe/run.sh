#!/bin/bash
# run.sh <dist> [probe args...]: build tools/probe/probe.c against the macOS
# frameworks of a build (dist/libmpv-xcframeworks_*_macos-*.tar.gz) and run it.
# Without probe args: --check.
set -euo pipefail
dist=$(cd "$1" && pwd); shift
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
tar -xzf "$dist"/libmpv-xcframeworks_*_macos-universal-video-plynic.tar.gz -C "$work"
mkdir -p "$work/fw"
for fw in "$work"/*/*.xcframework/macos-arm64/*.framework; do
  ln -s "$fw" "$work/fw/"
done
clang -O1 -Wall -F "$work/fw" -framework Mpv -Wl,-rpath,"$work/fw" \
  -mmacosx-version-min=12.0 -o "$work/probe" "$here/probe.c"
"$work/probe" "${@:---check}"
