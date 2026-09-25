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

**arm64 only means the app has to be arm64 only too.** media-kit's releases
had x86_64 slices; a universal (arm64 + x86_64) app build against these
either fails to link its x86_64 slice or, where the pods are weakly linked,
produces an app that starts without Mpv on an Intel Mac. So:

- macOS: `ARCHS = arm64` (or `EXCLUDED_ARCHS = x86_64`) for the Runner and
  every pod target, and a check in the release script that `lipo -archs` of
  the app binary and of `Mpv.framework` both say `arm64`;
- iOS simulator: `EXCLUDED_ARCHS[sdk=iphonesimulator*]` must include
  `x86_64` (not just `i386`);
- updates: an Intel Mac must not be offered the build. Sparkle 2.8.1 (the
  version plynic 1.0.19 ships) knows no hardware requirement in the appcast
  (its keys: `minimumSystemVersion`, `maximumSystemVersion`, `channel`,
  `minimumAutoupdateVersion`, ...), so the appcast alone cannot hold the
  update back from Intel clients that are already installed.

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
- macOS: `coreaudio`, `avfoundation`, `cocoa`, `gl-cocoa`, `videotoolbox-gl`,
  and `swift-build` targeting macOS 12 (0.41's cocoa code needs Swift).
  `ao_avfoundation` comes after `ao_coreaudio` in the autoprobe order, so a
  device coreaudio cannot open still plays (upstream's macOS builds have both;
  on macOS 27, 0.41's coreaudio failed for every mono file until plynic-mpv
  `70b11aa32f`).
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

What the frameworks link statically from the Xcode toolchain as it is has
no archive here (it is Apple's and the Swift project's code, published by
them); `tools/manifest.py` finds it after the build and records it in
`manifest.json` (`static_system`) and at the end of `SOURCES.json`, one
entry per archive with `"kind": "static-system"` and no `"file"`: version
(`swiftc`/`clang --version`), licence, provider (the Xcode), upstream,
whether it is exported, and per slice the archive's path in the toolchain,
its sha256 and the frameworks that took code from it (a slice took code from
an archive when its dSYM defines one of the archive's strong external
symbols). Since rc4 that is one entry: `libswiftCompatibility56.a` (Swift's
back-deployment library for Swift code built for macOS < 12.3) in the macOS
Mpv, not exported. Nothing takes code from compiler-rt, and zlib, iconv and
libc++ are the systems' own dylibs (`/usr/lib/libz.1.dylib`, ...); the
release gates fail if a framework ever links zlib statically (any slice
whose dSYM or binary defines `inflate`, `deflate`, `crc32`, `adler32` or
`zlibVersion`, also `z_`-prefixed). `SHA256SUMS` lists every file under
`sources/`, `SOURCES.json` included (since rc5: `manifest.py` adds its line
after writing the static-system entries), and a gate fails a release where
it does not.

Kept for at least three years after the last distribution of the app
version that shipped the release.

## Build

Needs [Nix](https://nixos.org/download) with flakes and Xcode.

```shell
$ nix develop -c make XCODE_PATH=/Applications/Xcode.app VERSION=v0.41.0-plynic.1
$ ls dist
```

`dist/` gets the release files and `manifest.json`; the build fails if the
19 frameworks and three slices are not all there, or a framework has the
wrong minimum OS or LC_BUILD_VERSION platform, a non-system dependency or
run path, "dynamically looked up" imports, no matching dSYM, an architecture
other than arm64, or (iOS) lacks its privacy manifest; if FFmpeg's libraries
report another license than LGPL or another version than the pinned one;
if Mpv's configuration is not `-Dgpl=false`; if a framework links zlib
statically; if `sources/SHA256SUMS` misses a file; or if `mpv-version` does
not name the pinned commit.

Checks on the built frameworks (CI runs both, after the build):

```shell
$ tools/probe/run.sh dist --check      # versions, decoders, demuxers
$ tools/probe/run.sh dist <file|url> [seconds] [opt=val ...]   # play, vo/ao null
$ tools/keepout/run.sh dist [sw|gl]    # --sub-keepout, paused track switches
$ tools/shot/run.sh dist [gl|glsw|sw] [strict]  # screenshot-raw of VideoToolbox / software frames
$ tools/rotate/run.sh dist [gl|glsw|sw]         # rotation through the render API
```

`tools/shot` plays two testsrc2 clips (H.264 → nv12, HEVC 10-bit → p010)
through the OpenGL render API with `hwdec=videotoolbox` and `hwdec=no` and
takes `screenshot-raw video` in bgr0 and rgba64 while rendering; `strict`
fails a VideoToolbox run that decoded in software (and a run that found no
such OpenGL context). `gl` is a hardware-accelerated CGL context, what the
app gets on a Mac. `glsw` is CGL's software renderer ("Apple Software
Renderer"), which does mpv's VideoToolbox interop (IOSurface textures) too,
so the frames reach `screenshot-raw` as VideoToolbox images and have to be
downloaded exactly as on a Mac: CI's runner has no hardware-accelerated
OpenGL, and runs `glsw strict` (rc3's frameworks fail it, rc4's pass; on
the macos-15 and macos-26 images, macos-14's VM has no H.264 VideoToolbox
decoder) and `sw` (the render API's software renderer, software decoding
only). `gl strict` is the pre-release step on a Mac, below.

`tools/rotate` plays a clip of four coloured quadrants through the render
API with `video-rotate` 0/90/180/270 and one whose file says it is rotated
(a display matrix), and reads each frame back from the render target: the
OpenGL renderer has to show every orientation (`gl`, and `glsw` in
`gpu-dumb-mode`, since CGL's software renderer returns black frames through
mpv's floating-point intermediate textures), the software renderer (`sw`)
the picture unrotated, and none of them may ask for a rotation filter.
Rotation is the VO's job: mpv asks lavfi for its `rotate` filter only when
the VO cannot rotate, and this FFmpeg has no such filter (overlay and
equalizer are the only ones); the `null` case plays the rotated file with
`vo=null` and expects mpv's fatal "filter 'rotate' not found or failed to
allocate", which is what an app's log shows while its player has no video
output yet. CI runs `glsw` and `sw`; rc5's frameworks fail `sw` (the
process aborts on the first rotated frame).

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
builds every push to a `plynic/*` branch and runs the checks above
(`tools/shot` as `glsw strict` and `sw`, `tools/rotate` as `glsw` and
`sw`). For a tag `v*-plynic.*` it
creates the release **as a draft**, with a body that lists what CI checked
(`tools/release/notes.py`); tags containing `rc` are prereleases. The build
job only reads the repository; a separate job, for tags only, uploads the
release. Third-party actions are pinned by commit.

**Publishing a release is a step on a Mac** (Apple silicon, a GPU, `gh`
with write access): `tools/release/publish.sh <tag>` downloads the draft's
macOS archive and `manifest.json`, checks the archive against the manifest
(sha256, tag, release gates), runs `tools/shot/run.sh <dist> gl strict`
(tools/shot from the tagged commit) on it, and only if all four cases pass
in a hardware-accelerated context attaches the output as
`screenshot-check-macos.txt` (archive sha256, machine, macOS, GL renderer,
every case), writes the result into the release body and publishes the
draft. That is the one check CI cannot run: VideoToolbox frames in the
accelerated OpenGL context an app uses, then `screenshot-raw` (rc3 shipped
with every such screenshot failing). A release without that section and
file in its body and assets has not been through it.

## Releases

A pushed tag is never moved or deleted, even when its CI run fails before
publishing anything: the fix goes out under the next number. The app's lock
refers to a tag and can go back to any earlier one.

Tags are shared with plynic-libmpv-android: the same `v0.41.0-plynic.<n>` on
both is built from the same plynic-mpv commit (their `manifest.json`s say
which).

- **v0.41.0-plynic.rc2** — plynic-mpv `f226dd6356`: the first release of
  this repository. Known problems, fixed in rc3: on macOS 27 no audio for
  mono files (coreaudio, no other AO built); a subtitle track selected
  while paused often showing nothing until unpause.
- **v0.41.0-plynic.rc3** — plynic-mpv `c5438ee6c4`: coreaudio without the
  channel map, ao_avfoundation as fallback, the paused-switch redraw;
  `tools/keepout` in CI; stricter release gates; BinaryPath of the macOS
  slices as xcodebuild writes it (`Mpv.framework/Versions/A/Mpv`). Known
  problem, fixed in rc4: `screenshot-raw` of a VideoToolbox frame fails.
- **v0.41.0-plynic.rc4** — plynic-mpv `d75b92b584`: `screenshot: correctly
  detect hardware frame` (upstream `c66204b69b`, cherry-picked). Since
  mpv 0.41 (`9b1d47ece1`) a hardware image carries its software
  sub-format's descriptor, so the screenshot path handed VideoToolbox frames
  to libswscale ("Input image format videotoolbox not supported by
  libswscale") instead of downloading them: no screenshot of any
  hardware-decoded frame through the render API on iOS or macOS (an app's
  "resume" thumbnail, for one). On rc4's macOS frameworks H.264, HEVC
  8/10-bit and VP9 decoded with VideoToolbox return the picture in bgr0
  and rgba64, as software-decoded files do (`tools/shot`, new; CI runs its
  software-renderer half, its runner has no OpenGL).
  `static_system` in `SOURCES.json` and `manifest.json`, and the zlib gate
  (see [Source](#source)). Checked on macOS 27 (Xcode 27.0): the release
  gates, `tools/probe --check`, `tools/keepout` sw and gl, `tools/shot gl
  strict`, the 15-case TLS matrix (verdicts and TLS log lines identical to
  rc3), coreaudio on four outputs x five files; the iOS simulator slice:
  the probe's checks, playback, audiounit.
- **v0.41.0-plynic.rc5** — plynic-mpv `d75b92b584`, as rc4, and the same
  inputs otherwise: a local build of rc5 gives frameworks byte-identical to
  a local build of rc4 (every file of both archives; same LC_UUIDs). What
  changed is how a release is checked and published:
  - `tools/shot glsw strict` in CI: the VideoToolbox half of the screenshot
    check through CGL's software renderer, which the runner has (rc4's CI
    skipped it for want of an OpenGL context); rc3's frameworks fail it,
    rc4's pass.
  - releases are drafts until `tools/release/publish.sh` has run
    `tools/shot gl strict` on a Mac against the published archive and
    written the result into the release (see [Build](#build)); rc5 is the
    first published that way.
  - the zlib gate looks for zlib's whole API (`inflate`, `deflate`, `crc32`,
    `adler32`, `zlibVersion`, plain or `z_`-prefixed; before: only
    `_zlibVersion`); `sources/SHA256SUMS` lists `SOURCES.json` (it never
    did) and a gate checks that it lists every file.
  Checked on macOS 27 (Xcode 27.0), local build: the release gates,
  `tools/probe --check`, `tools/keepout` sw and gl, `tools/shot` gl strict,
  glsw strict and sw, the 15-case TLS matrix (identical to rc4). coreaudio
  and the iOS simulator slice were not run again: their frameworks are
  byte-identical to rc4's.
- **v0.41.0-plynic.rc6** — plynic-mpv `4c4e802343`: `vo_libmpv: use the
  VO_CAP of the renderer backend instead of the VO` (upstream `7a94ec5719`,
  cherry-picked). vo_libmpv announced `VO_CAP_ROTATE90` for every render API
  backend and computed a rotated source rectangle for the software backend
  too, which cannot rotate: on rc5 the first frame rotated by 90 or 270
  degrees - a portrait phone video's display matrix, or `video-rotate=90` -
  aborted the process (`mp_image_crop()` assertion). media_kit_video uses
  that backend in the iOS simulator and wherever its OpenGL texture cannot
  be created. Now such frames are drawn unrotated there; OpenGL rotates as
  before. A local build of rc6 differs from a local build of rc5 in
  `Mpv.framework` (and its dSYM) only.
  - `tools/rotate` (new, in CI as glsw and sw): every quarter turn and a
    file's own rotation read back from the render target, the software
    renderer's unrotated picture, and `vo=null`'s "filter 'rotate' not found"
    (see [Build](#build)). Rotation is the VO's; FFmpeg keeps its two filters
    (the same decision as plynic-libmpv-android's rc6: the only VO in an
    app's paths that makes mpv ask for lavfi's `rotate` is `vo=null`, whose
    frames are thrown away). rc5's frameworks fail `sw` (both rotated cases
    abort); rc6's pass all three modes.
  Checked on macOS 27 (Xcode 27.0, Apple M4 Pro), local build: the release
  gates, `tools/probe --check`, `tools/keepout` sw and gl, `tools/shot` gl
  strict, glsw strict and sw, `tools/rotate` gl, glsw and sw, the app's
  23-case TLS testbed (`tool/tls-testbed`: 23 of 23, the same verdicts as
  rc5's release).

## What changed from media-kit

- One flavor, `plynic`, one variant, `video`; the audio variant, the
  `default`/`full`/`encodersgpl` flavors and the packages only
  `encodersgpl` used (x264, libvpx, libvorbis, libogg, fftools-ffi; GPL) are
  removed, as are the "libs" archives and the per-framework SwiftPM zips.
- arm64 only; iOS 15.0 / macOS 12.0.
- mpv from the plynic-mpv flake input instead of a tarball plus patches
  (its Darwin changes are commits there: objc meson fix, audiounit session
  option, no fstatfs on iOS, coreaudio without the channel map).
- FFmpeg n8.1.3 and dependencies at the Android versions; libplacebo added
  (Placebo.framework: 19 frameworks instead of 18); libass and libxml2 with
  their own meson builds; mbedtls 3.6.
- The xcodebuild helper understands `-debug-symbols` and LC_BUILD_VERSION
  platforms and writes the resolved `BinaryPath`; dSYMs, privacy manifests,
  Info.plist keys, deterministic archives, `manifest.json`, `sources/`.
- macOS builds `ao_avfoundation` as well.
- CI records the Xcode it used instead of naming one.

## License

The build scripts: MIT (birros, and the plynic changes), see
[LICENSE.txt](LICENSE.txt). The frameworks: LGPL (mpv `-Dgpl=false`, FFmpeg
`--enable-version3`) and the licenses of the other libraries, listed in each
release's `sources/SOURCES.json`.
