{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
}:

let
  name = "mpv";
  # The plynic-mpv fork (flake input, see flake.nix): the same commit as the
  # Android build. Darwin-specific changes are commits there, not patches here.
  inherit (pkgs.plynicMpv) rev dirty;
  sha9 = builtins.substring 0 9 rev;
  upstreamVersion = pkgs.lib.trim (builtins.readFile "${pkgs.plynicMpv.src}/MPV_VERSION");
  # mpv-version reads "mpv v0.41.0-plynic-g<first 9 hex digits of the
  # commit>", exactly what plynic-libmpv-android stamps (scripts/mpv.sh), so
  # the app can check at run time that both platforms run the same fork
  # commit. Without a .git, common/meson.build falls back to
  # "v" + MPV_VERSION.
  version = "${upstreamVersion}-plynic-g${sha9}${if dirty then "-dirty" else ""}";

  oses = import ../../utils/constants/oses.nix;
  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      ;
  };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };
  xctoolchainLipo = callPackage ../../utils/xctoolchain/lipo.nix { };
  xctoolchainXcrun = callPackage ../../utils/xctoolchain/xcrun.nix { };
  ffmpeg = callPackage ../mk-pkg-ffmpeg/default.nix { };
  uchardet = callPackage ../mk-pkg-uchardet/default.nix { };
  libass = callPackage ../mk-pkg-libass/default.nix { };
  libplacebo = callPackage ../mk-pkg-libplacebo/default.nix { };

  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
    xctoolchainLipo
    mkDsyms
  ]
  ++ pkgs.lib.optionals (os == oses.macos) [
    xctoolchainXcrun
  ];

  pname = import ../../utils/name/package.nix name;
  patchedSource = pkgs.runCommand "${pname}-patched-source-${version}" { } ''
    cp -r ${pkgs.plynicMpv.src} src
    export src=$PWD/src
    chmod -R u+w $src
    echo "${version}" > $src/MPV_VERSION
    cp -r $src $out
  '';
  fixedSource = callPackage ../../utils/patch-shebangs/default.nix {
    name = "${pname}-fixed-source-${version}";
    src = patchedSource;
    inherit nativeBuildInputs;
  };

  # Frameworks the Objective-C/C parts use without meson declaring them
  # (ao_audiounit: AVAudioSession; hwdec_ios_gl: CVOpenGLESTextureCache,
  # EAGLContext; hwdec_mac_gl: IOSurface; objc_msgSend everywhere). They are
  # linked explicitly and b_lundef is on, so a symbol nothing provides fails
  # the link instead of becoming a "dynamically looked up" import that only
  # works while the host app happens to have loaded the library (media-kit's
  # v0.7.3 iOS libmpv had 15 of those). A second machine file, because a
  # c_link_args on the command line would replace the cross file's.
  linkFrameworks =
    if os == oses.macos then
      [
        "IOSurface"
        "CoreVideo"
        "OpenGL"
      ]
    else if os == oses.ios then
      [
        "AVFoundation"
        "CoreVideo"
        "OpenGLES"
      ]
    else
      [
        "AVFoundation"
      ];
  linkArgs = builtins.concatStringsSep ", " (
    builtins.concatMap (f: [
      "'-framework'"
      "'${f}'"
    ]) linkFrameworks
    ++ [ "'-lobjc'" ]
  );
  linkFile = pkgs.writeText "mk-mpv-link-${os}-${arch}.ini" ''
    [built-in options]
    c_link_args    = common_args + [${linkArgs}]
    objc_link_args = common_args + [${linkArgs}]
  '';
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${variant}-${version}";
  pname = pname;
  inherit version;
  src = fixedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  inherit nativeBuildInputs;
  buildInputs = [
    ffmpeg
    uchardet
    libass
    libplacebo
  ];
  configurePhase = ''
    # swiftc (macOS) keeps its clang module cache under $HOME, which the nix
    # sandbox has no writable one of (/homeless-shelter)
    export HOME=$TMPDIR

    # Every option of mpv 0.41's meson.options, off; what the platform needs
    # is switched on below.
    DISABLE_ALL_OPTIONS=(
      `# booleans`
      -Dgpl=false `# GPL (version 2 or later) build`
      -Dcplayer=false `# mpv CLI player`
      -Dlibmpv=false `# libmpv library`
      -Dbuild-date=false `# include compile timestamp in binary`
      -Dtests=false `# meson unit tests`
      -Dfuzzers=false `# fuzzer binaries`
      -Ddisable-packet-pool=false `# disable packet pool (development only)`

      `# misc features`
      -Dcdda=disabled `# cdda support (libcdio)`
      -Dcplugins=disabled `# C plugins`
      -Ddvbin=disabled `# DVB input module`
      -Ddvdnav=disabled `# dvdnav support`
      -Diconv=disabled `# iconv`
      -Djavascript=disabled `# Javascript (MuJS backend)`
      -Djpeg=disabled `# libjpeg image writer`
      -Dlcms2=disabled `# LCMS2 support`
      -Dlibarchive=disabled `# libarchive wrapper for reading zip files and more`
      -Dlibavdevice=disabled `# libavdevice`
      -Dlibbluray=disabled `# Bluray support`
      -Dlua=disabled `# Lua`
      -Dpthread-debug=disabled `# pthread runtime debugging wrappers`
      -Drubberband=disabled `# librubberband support`
      -Dsdl2-gamepad=disabled `# SDL2 gamepad input`
      -Duchardet=disabled `# uchardet support`
      -Duwp=disabled `# Universal Windows Platform`
      -Dvapoursynth=disabled `# VapourSynth filter bridge`
      -Dvector=disabled `# GCC vector instructions`
      -Dwin32-threads=disabled `# win32 native threading`
      -Dx11-clipboard=disabled `# X11 clipboard backend`
      -Dzimg=disabled `# libzimg support (high quality software scaler)`
      -Dzlib=disabled `# zlib`

      `# audio output features`
      -Dalsa=disabled `# ALSA audio output`
      -Daudiounit=disabled `# AudioUnit output (iOS)`
      -Dcoreaudio=disabled `# CoreAudio audio output`
      -Davfoundation=disabled `# AVFoundation audio output`
      -Djack=disabled `# JACK audio output`
      -Dopenal=disabled `# OpenAL audio output`
      -Daudiotrack=disabled `# Android AudioTrack audio output`
      -Daaudio=disabled `# Android AAudio audio output`
      -Dopensles=disabled `# OpenSL ES audio output`
      -Doss-audio=disabled `# OSSv4 audio output`
      -Dpipewire=disabled `# PipeWire audio output`
      -Dpulse=disabled `# PulseAudio audio output`
      -Dsdl2-audio=disabled `# SDL2 audio output`
      -Dsndio=disabled `# sndio audio output`
      -Dwasapi=disabled `# WASAPI audio output`

      `# video output features`
      -Dcaca=disabled `# CACA`
      -Dcocoa=disabled `# Cocoa`
      -Dd3d11=disabled `# Direct3D 11 video output`
      -Ddirect3d=disabled `# Direct3D support`
      -Ddmabuf-wayland=disabled `# dmabuf-wayland video output`
      -Ddrm=disabled `# Direct Rendering Manager (DRM)`
      -Degl=disabled `# EGL 1.4`
      -Degl-android=disabled `# Android EGL support`
      -Degl-angle=disabled `# OpenGL ANGLE headers`
      -Degl-angle-lib=disabled `# OpenGL Win32 ANGLE library`
      -Degl-angle-win32=disabled `# OpenGL Win32 ANGLE backend`
      -Degl-drm=disabled `# OpenGL DRM EGL backend`
      -Degl-wayland=disabled `# OpenGL Wayland backend`
      -Degl-x11=disabled `# OpenGL X11 EGL backend`
      -Dgbm=disabled `# Generic Buffer Manager (GBM)`
      -Dgl=disabled `# OpenGL context support`
      -Dgl-cocoa=disabled `# OpenGL Cocoa backend`
      -Dgl-dxinterop=disabled `# OpenGL/DirectX Interop backend`
      -Dgl-win32=disabled `# OpenGL Win32 backend`
      -Dgl-x11=disabled `# OpenGL X11/GLX (deprecated/legacy)`
      -Dsdl2-video=disabled `# SDL2 video output`
      -Dshaderc=disabled `# libshaderc SPIR-V compiler`
      -Dsixel=disabled `# Sixel video output`
      -Dspirv-cross=disabled `# SPIRV-Cross SPIR-V shader converter`
      -Dplain-gl=disabled `# OpenGL without platform-specific code (e.g. for libmpv)`
      -Dvdpau=disabled `# VDPAU acceleration`
      -Dvdpau-gl-x11=disabled `# VDPAU with OpenGL/X11`
      -Dvaapi=disabled `# VAAPI acceleration`
      -Dvaapi-drm=disabled `# VAAPI (DRM support)`
      -Dvaapi-wayland=disabled `# VAAPI (Wayland support)`
      -Dvaapi-win32=disabled `# VAAPI (Windows support)`
      -Dvaapi-x11=disabled `# VAAPI (X11 support)`
      -Dvulkan=disabled `# Vulkan context support`
      -Dwayland=disabled `# Wayland`
      -Dx11=disabled `# X11`
      -Dxv=disabled `# Xv video output`

      `# hwaccel features`
      -Dandroid-media-ndk=disabled `# Android Media APIs`
      -Dcuda-hwaccel=disabled `# CUDA acceleration`
      -Dcuda-interop=disabled `# CUDA with graphics interop`
      -Dd3d-hwaccel=disabled `# D3D11VA hwaccel`
      -Dd3d9-hwaccel=disabled `# DXVA2 hwaccel`
      -Dgl-dxinterop-d3d9=disabled `# OpenGL/DirectX DXVA2 hwaccel`
      -Dios-gl=disabled `# iOS OpenGL ES interop support`
      -Dvideotoolbox-gl=disabled `# Videotoolbox with OpenGL`
      -Dvideotoolbox-pl=disabled `# Videotoolbox with libplacebo`

      `# macOS features`
      -Dmacos-10-15-4-features=disabled `# macOS 10.15.4 SDK Features`
      -Dmacos-11-features=disabled `# macOS 11 SDK Features`
      -Dmacos-11-3-features=disabled `# macOS 11.3 SDK Features`
      -Dmacos-12-features=disabled `# macOS 12 SDK Features`
      -Dmacos-cocoa-cb=disabled `# macOS libmpv backend`
      -Dmacos-media-player=disabled `# macOS Media Player support`
      -Dmacos-touchbar=disabled `# macOS Touch Bar support`
      -Dswift-build=disabled `# macOS Swift build tools`
      -Dswift-flags= `# Optional Swift compiler flags`

      `# Windows features`
      -Dwin32-smtc=disabled `# Enable Media Control support`

      `# manpages`
      -Dhtml-build=disabled `# HTML manual generation`
      -Dmanpage-build=disabled `# manpage generation`
      -Dpdf-build=disabled `# PDF manual generation`
    )

    COMMON_OPTIONS=(
      -Dlibmpv=true
      `# The debugoptimized of mpv's own default_options, like Android.`
      --buildtype=debugoptimized
      `# See linkFile above.`
      -Db_lundef=true
      -Diconv=enabled
      -Duchardet=enabled
      -Dzlib=enabled
      -Dgl=enabled
      -Dplain-gl=enabled
      `# No scripting: nothing downloaded may be run (App Store 2.5.2).`
      -Dlua=disabled
      -Djavascript=disabled
      -Dcplugins=disabled
    )

    # Cocoa is needed on macOS: videotoolbox-gl (hardware decoding into
    # OpenGL textures) requires gl-cocoa, which requires cocoa. With cocoa but
    # without swift, 0.41 compiles call sites whose implementations are
    # Swift-only, and mpv_create() jumps to a null pointer; so swift-build
    # is on, targeting the same macOS as everything else.
    MACOS_OPTIONS=(
      -Dcoreaudio=enabled
      -Dcocoa=enabled
      -Dgl-cocoa=enabled
      -Dvideotoolbox-gl=enabled
      -Dswift-build=enabled
      -Dswift-flags="-target arm64-apple-macos12.0"
      -Dmacos-10-15-4-features=enabled
      -Dmacos-11-features=enabled
      -Dmacos-11-3-features=enabled
      -Dmacos-12-features=enabled
    )

    # The simulator has the AudioUnit output too (media-kit's builds left the
    # simulator silent), but no hardware decoding to share with OpenGL ES.
    IOS_OPTIONS=(
      -Daudiounit=enabled
    )
    IOS_DEVICE_OPTIONS=(
      -Dios-gl=enabled
    )

    OPTIONS=("''${DISABLE_ALL_OPTIONS[@]}" "''${COMMON_OPTIONS[@]}")
    if [ "${os}" == "${oses.macos}" ]; then
      OPTIONS+=("''${MACOS_OPTIONS[@]}")
      export MACOS_SDK=$(xcrun --sdk macosx --show-sdk-path)
      export MACOS_SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
    else
      OPTIONS+=("''${IOS_OPTIONS[@]}")
      if [ "${os}" == "${oses.ios}" ]; then
        OPTIONS+=("''${IOS_DEVICE_OPTIONS[@]}")
      fi
    fi

    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --cross-file ${linkFile} \
      --prefix=$out \
      "''${OPTIONS[@]}" |
      tee configure.log
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build

    mk-dsyms $out

    # copy configure.log
    mkdir -p $out/share/mpv
    cp configure.log $out/share/mpv/
  '';
}
