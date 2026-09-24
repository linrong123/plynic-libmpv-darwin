# Just enough of xcrun for mpv's meson build on macOS (swift-build): it asks
# `xcrun -find swiftc` / `xcrun -find swift`, and TOOLS/macos-sdk-version.py
# asks for the macOS SDK's path and version. The real xcrun is not reachable
# from the build (not on PATH, and outside the sandbox on CI).
{
  pkgs ? import ../default/pkgs.nix,
}:

let
  developer = "${pkgs.darwin.xcode}/Contents/Developer";
  toolchain = "${developer}/Toolchains/XcodeDefault.xctoolchain/usr/bin";
  sdk = "${developer}/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk";
in

pkgs.writeShellScriptBin "xcrun" ''
  set -eu
  sdk_version() {
    ${pkgs.python3}/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1] + "/SDKSettings.json"))["Version"])' "${sdk}"
  }
  case "$*" in
    "-find "*|"--find "*)
      tool=$2
      [ -x "${toolchain}/$tool" ] || { echo "xcrun: $tool not found" >&2; exit 1; }
      echo "${toolchain}/$tool" ;;
    "--sdk macosx --show-sdk-path"|"--show-sdk-path")
      echo "${sdk}" ;;
    "--sdk macosx --show-sdk-version"|"--show-sdk-version")
      sdk_version ;;
    *)
      echo "xcrun (plynic-libmpv-darwin stub): unsupported: $*" >&2
      exit 1 ;;
  esac
''
