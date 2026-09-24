{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "mbedtls";
  source = callPackage ../../utils/fetch-source/default.nix {
    inherit name;
    lock = (import ../../../packages.lock.nix).${name};
  };
  inherit (source) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };

  pname = import ../../utils/name/package.nix name;
  # The configuration is edited in include/mbedtls/mbedtls_config.h itself,
  # so the header FFmpeg compiles tls_mbedtls.c against (installed below) is
  # the one the library was built with. The same three settings as
  # plynic-libmpv-android (buildscripts/scripts/mbedtls.sh):
  #   MBEDTLS_THREADING_C + MBEDTLS_THREADING_PTHREAD: 3.6 turns TLS 1.3 on
  #     by default, which goes through PSA crypto, whose key store and global
  #     state are only thread-safe with these; mpv opens HTTPS connections
  #     from several threads at once.
  #   MBEDTLS_PLATFORM_DEV_RANDOM "/dev/urandom": the entropy file where no
  #     getrandom() exists (3.6.6 changed the default to /dev/random); on
  #     Darwin both are the same non-blocking generator, set for parity.
  patchedSource = pkgs.runCommand "${pname}-patched-source-${version}" { nativeBuildInputs = [ pkgs.python3 ]; } ''
    mkdir -p $out/subprojects/mbedtls
    cp -r ${source.tree}/* $out/subprojects/mbedtls/
    chmod -R u+w $out/subprojects/mbedtls
    (
      cd $out/subprojects/mbedtls
      python3 scripts/config.py set MBEDTLS_PLATFORM_DEV_RANDOM '"/dev/urandom"'
      python3 scripts/config.py set MBEDTLS_THREADING_C
      python3 scripts/config.py set MBEDTLS_THREADING_PTHREAD
    )
    cp ${./meson.build} $out/meson.build
  '';
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = patchedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.cmake
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
    mkDsyms
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    # create output layout
    mkdir -p $out/{include,lib}
    mkdir -p $out/include/{mbedtls,psa}
    mkdir -p $out/lib/pkgconfig

    # install headers
    cp $src/subprojects/mbedtls/include/mbedtls/*.h $out/include/mbedtls/
    cp $src/subprojects/mbedtls/include/psa/*.h $out/include/psa/

    # install libs (the versioned files; the unversioned names are symlinks)
    find build -type f -name '*.dylib' -exec sh -c 'cp {} $out/lib/' \;

    # install pkgconfig file
    cp ${./mbedtls.pc.in} $out/lib/pkgconfig/mbedtls.pc
    sed -i "s|\''${PREFIX}|$out|g" $out/lib/pkgconfig/mbedtls.pc
    sed -i "s|\''${VERSION}|${version}|g" $out/lib/pkgconfig/mbedtls.pc

    mk-dsyms $out
  '';
}
