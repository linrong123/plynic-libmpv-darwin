{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
  flavor ? import ../../utils/default/flavor.nix,
}:

let
  name = "ffmpeg";
  source = callPackage ../../utils/fetch-source/default.nix {
    inherit name;
    lock = (import ../../../packages.lock.nix).${name};
  };
  inherit (source) version;

  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      flavor
      ;
  };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };
  mbedtls = callPackage ../mk-pkg-mbedtls/default.nix { };
  dav1d = callPackage ../mk-pkg-dav1d/default.nix { };
  libxml2 = callPackage ../mk-pkg-libxml2/default.nix { };

  pname = import ../../utils/name/package.nix name;
  # patches/ffmpeg: byte-identical with plynic-libmpv-android's
  # buildscripts/patches/ffmpeg, applied the same way (git apply, file name
  # order); both repositories' manifests list their sha256.
  # patches/ffmpeg-darwin: Darwin only, applied after them.
  sharedPatches = builtins.sort builtins.lessThan (
    builtins.attrNames (builtins.readDir ../../../patches/ffmpeg)
  );
  darwinPatches = builtins.sort builtins.lessThan (
    builtins.attrNames (builtins.readDir ../../../patches/ffmpeg-darwin)
  );
  patchedSource =
    pkgs.runCommand "${pname}-patched-source-${version}"
      {
        nativeBuildInputs = [ pkgs.git ];
      }
      ''
        cp -r ${source.tree} src
        export src=$PWD/src
        chmod -R u+w $src

        cd $src
        ${pkgs.lib.concatMapStrings (p: ''
          echo "Applying patches/ffmpeg/${p}"
          git apply --verbose ${../../../patches/ffmpeg + "/${p}"}
        '') sharedPatches}
        ${pkgs.lib.concatMapStrings (p: ''
          echo "Applying patches/ffmpeg-darwin/${p}"
          git apply --verbose ${../../../patches/ffmpeg-darwin + "/${p}"}
        '') darwinPatches}
        # No .git here, so ffbuild/version.sh would fall back to RELEASE
        # ("8.1.3"); Android builds from a git checkout of the tag and reports
        # "n8.1.3". Same string on both: ffmpeg-version is compared at run time.
        echo "n${version}" > VERSION
        cd -

        cp ${./meson.build} $src/meson.build
        cp ${./meson.options} $src/meson.options

        cp -r $src $out
      '';
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${variant}-${flavor}-${version}";
  pname = pname;
  inherit version;
  src = patchedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    mkDsyms
  ];
  buildInputs = [
    mbedtls
    dav1d
    libxml2
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Dvariant=${variant} \
      -Dflavor=${flavor} |
      tee configure.log
  '';
  buildPhase = ''
    meson compile -vC build $(basename $src)
  '';
  installPhase = ''
    # manual install to preserve symlinks (meson install -C build)
    cp -r build/dist$out $out

    # copy configure.log
    cp configure.log $out/share/ffmpeg/

    mk-dsyms $out
  '';
}
