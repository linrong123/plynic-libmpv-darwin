# plynic-libmpv-darwin

libmpv for iOS and macOS, as dynamic xcframeworks, built for
[plynic](https://github.com/linrong123/plynic)'s `media_kit_libs_ios_video`
and `media_kit_libs_macos_video` forks. The Darwin counterpart of
[plynic-libmpv-android](https://github.com/linrong123/plynic-libmpv-android):
both build the same [plynic-mpv](https://github.com/linrong123/plynic-mpv)
commit with the same FFmpeg and the same FFmpeg patches, and tag their
releases alike (`v0.41.0-plynic.<n>`).

This repository is a fork of media-kit's
[libmpv-darwin-build](https://github.com/media-kit/libmpv-darwin-build)
(v0.7.3, `aadae8c`; history kept), which is heavily inspired by Homebrew and
IINA. The nix build, the framework layout and the xcodebuild/plutil helpers
are theirs; see [What changed from media-kit](#what-changed-from-media-kit).

## What a release contains

| File | What |
|---|---|
| `libmpv-xcframeworks_<tag>_ios-universal-video-plynic.tar.gz` | one directory of 19 `*.xcframework`, slices `ios-arm64` and `ios-arm64-simulator`, each with its dSYM (`DebugSymbolsPath`) |
| `libmpv-xcframeworks_<tag>_macos-universal-video-plynic.tar.gz` | the same for `macos-arm64` |
| `dsyms-plynic.zip` | every slice's `<Name>.framework.dSYM`, for symbolicating crash reports |
| `manifest.json` | commits, versions, patch digests, per framework and slice: LC_UUID, minos, SDK, install name, dependencies, run paths, "dynamically looked up" imports; the checks every release passes |
| `sources/*` | the complete corresponding source, see [Source](#source) |

"universal" is the xcframework bundling every slice of a platform; the only
architecture is arm64 (Apple silicon Macs, iOS devices, the simulator on
Apple silicon). The archive names and the directory inside are what media-kit
publishes, so the app's packages only need a different URL and digest.

The 19 frameworks: Mpv, Avcodec, Avfilter, Avformat, Avutil, Swresample,
Swscale, Placebo, Ass, Freetype, Fribidi, Harfbuzz, Png16, Uchardet, Xml2,
Dav1d, Mbedtls, Mbedx509, Mbedcrypto. Each is a dynamic framework with
install name `@rpath/<Name>.framework/<Name>` (macOS:
`.../Versions/A/<Name>`), which keeps every LGPL library replaceable.

## Versions

Everything is pinned in `flake.lock` (plynic-mpv, nixpkgs) and
`packages.lock.nix` (the rest), at the versions and commits
plynic-libmpv-android pins:

| | |
|---|---|
| mpv | plynic-mpv, branch `plynic/v0.41.0` (flake input `plynic-mpv`); `mpv-version` reads `mpv v0.41.0-plynic-g<first 9 hex digits of the commit>`, the same string as on Android |
| FFmpeg | n8.1.3 (`1041abdc96`); `ffmpeg-version` reads `n8.1.3`, as on Android |
| libplacebo | 7.360.1, OpenGL only (mpv 0.41 needs it for `vo=gpu`/the render API) |
| mbedtls | 3.6.7 (TLS 1.3; `MBEDTLS_THREADING_C`) |
| libass, FreeType, HarfBuzz, FriBidi | 0.17.5 (NEON assembly on), 2.13.3, 11.5.1, 1.0.17 |
| dav1d, libxml2, uchardet, libpng | 1.5.4, 2.14.6, 0.0.8, 1.6.58 |
| minimum OS | iOS 15.0, macOS 12.0 (the app's) |

The git-pinned sources are fetched from GitHub mirrors, by commit and NAR
hash; they are the same trees plynic-libmpv-android builds (checked file by
file when this repository was set up).

### FFmpeg patches

- `patches/ffmpeg/`: **byte-identical** with plynic-libmpv-android's
  `buildscripts/patches/ffmpeg/`, applied the same way (`git apply`, file name
  order). Both repositories' `manifest.json` list them under the same keys
  with their sha256, so the app can check that both platforms run the same
  TLS code:
  - `tls_mbedtls_ca_partial`: a CA file with some unparsable certificates is
    still used
  - `tls_mbedtls_no_ip_sni`: no IP address in SNI unless verifying
  - `tls_mbedtls_verify_flags`: a line with mbedtls' verify flags when a
    certificate is rejected
  - `upstream_http_soft_seek_fallback`, `upstream_http_willclose_from_request`:
    backports from FFmpeg master (HTTP resume after a closed keep-alive
    connection)
- `patches/ffmpeg-darwin/`: Darwin only.
  - `videotoolbox_ios_bgra`: on iOS, VideoToolbox hands out BGRA for 10-bit
    4:2:0, because iOS's OpenGL ES has no 16-bit textures (media-kit's
    `ffmpeg-fix-ios-hdr-texture`, rebased onto n8.1.3). To be replaced by the
    app setting `hwdec-image-format=nv12` once an iPhone A/B confirms it.

media-kit's `vp9-hwaccel` (does not build on FFmpeg 8.1; Intel only),
`hls-mp4-seek` and `dash-base-url-escape` (upstream since) are gone.

### mpv build

- Everything off, then: libmpv, iconv, uchardet, zlib, OpenGL (`plain-gl`).
  No Lua, JavaScript or C plugins (App Store guideline 2.5.2).
- iOS device: `audiounit`, `ios-gl` (hardware decoding into GL ES
  textures). iOS simulator: `audiounit` too (media-kit's simulator builds
  had no audio output); no `ios-gl`.
- macOS: `coreaudio`, `cocoa`, `gl-cocoa`, `videotoolbox-gl`, and
  `swift-build` targeting macOS 12 (0.41's cocoa code needs Swift).
- `b_lundef` on and the frameworks the Objective-C parts use linked
  explicitly (AVFoundation, CoreVideo, OpenGLES / IOSurface, OpenGL; objc):
  no framework has "dynamically looked up" imports (media-kit's v0.7.3 iOS
  Mpv had 15, working only while the app happened to have loaded them).
- `--audiounit-skip-session-management` (plynic-mpv) lets the app own the
  iOS audio session.

FFmpeg is media-kit's `full` flavor (every decoder, demuxer, parser,
protocol, bsf; overlay and equalizer filters) plus the spdif muxer, as on
Android, and still `--enable-small` like Android until the -Os/-O3
comparison (plynic spec 0017 TD7) decides for both.

### Debug symbols, privacy manifests, bundle ids

Everything is compiled with `-g`; `dsymutil` runs in each package while its
objects still exist, then the libraries are stripped of local symbols
(`strip -x`). dSYM and framework share the LC_UUID.

The iOS frameworks that call "required reason" APIs carry a
`PrivacyInfo.xcprivacy` (Mpv, Avformat, Avutil, Harfbuzz, Mbedx509, Xml2);
see [privacy/README.md](privacy/README.md).

Bundle identifiers are `com.github.linrong123.plynic-libmpv.<Name>`; every
Info.plist has `CFBundlePackageType` `FMWK` and `CFBundleSupportedPlatforms`.

## Source

Each release attaches, under `sources/`, what the frameworks are built from
(plynic spec 0017 K-F):

- `src-<dep>-<version>.tar.xz`: a git-pinned dependency's tree
  (deterministic tar: sorted, owner 0, mtime 1), submodules included
  (libplacebo)
- the upstream release tarballs of mbedtls, uchardet, libpng and libpng's
  WrapDB meson files, byte for byte
- `src-mpv-<sha9>.tar.xz`: the plynic-mpv commit
- `patches-<tag>.tar.xz`, `plynic-libmpv-darwin-<tag>.tar.xz`: the patches,
  and this repository as built
- `SOURCES.json` (id, version, licence, origin, patches, sha256, size) and
  `SHA256SUMS`

Kept for at least three years after the last distribution of the app
version that shipped the release.

## Build

Needs [Nix](https://nixos.org/download) with flakes and Xcode.

```shell
$ nix develop -c make XCODE_PATH=/Applications/Xcode.app VERSION=v0.41.0-plynic.1
$ ls dist
```

`dist/` gets the release files and `manifest.json`; the build fails if a
framework has the wrong minimum OS, a non-system dependency or run path,
"dynamically looked up" imports, no matching dSYM, or an `mpv-version` that
does not name the pinned commit.

One package: `make TARGET=mk-pkg-mpv-macos-arm64-video`.

Local mpv work, without pushing:

```shell
$ make XCODE_PATH=/Applications/Xcode.app \
    NIX_ARGS='--override-input plynic-mpv git+file:///path/to/plynic-mpv?ref=refs/heads/plynic/v0.41.0&rev=<sha>'
```

(`manifest.json`'s check then reports that `mpv-version` does not match
`flake.lock`, as it should.)

Bump the mpv commit:

```shell
$ nix flake lock --override-input plynic-mpv github:linrong123/plynic-mpv/<sha>
```

CI (`.github/workflows/ci.yaml`, `macos-15`, the image's default Xcode)
builds every push to a `plynic/*` branch, and publishes a release for every
tag `v*-plynic.*`; tags containing `rc` are prereleases.

## What changed from media-kit

- One flavor, `plynic`, one variant, `video`; the audio variant, the
  `default`/`full`/`encodersgpl` flavors and the packages only
  `encodersgpl` used (x264, libvpx, libvorbis, libogg, fftools-ffi; GPL) are
  removed, as are the "libs" archives and the per-framework SwiftPM zips.
- arm64 only; iOS 15.0 / macOS 12.0.
- mpv from the plynic-mpv flake input instead of a tarball plus patches
  (its Darwin changes are commits there: objc meson fix, audiounit session
  option, no fstatfs on iOS).
- FFmpeg n8.1.3 and dependencies at the Android versions; libplacebo added
  (Placebo.framework: 19 frameworks instead of 18); libass and libxml2 with
  their own meson builds; mbedtls 3.6.
- The xcodebuild helper understands `-debug-symbols` and LC_BUILD_VERSION
  platforms; dSYMs, privacy manifests, Info.plist keys, deterministic
  archives, `manifest.json`, `sources/`.
- CI records the Xcode it used instead of naming one.

## License

The build scripts: MIT (birros, and the plynic changes), see
[LICENSE.txt](LICENSE.txt). The frameworks: LGPL (mpv `-Dgpl=false`, FFmpeg
`--enable-version3`) and the licenses of the other libraries, listed in each
release's `sources/SOURCES.json`.
