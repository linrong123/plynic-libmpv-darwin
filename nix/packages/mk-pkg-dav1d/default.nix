{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "dav1d";
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
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = source.tree;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.nasm
    mkDsyms
  ];
  # The aarch64 assembly (NEON) is assembled by clang; only x86 would need
  # nasm, which is listed so that meson's probe never fails on the host.
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Dbitdepths="['8', '16']" \
      -Denable_asm=true \
      -Denable_tools=false \
      -Denable_examples=false \
      -Denable_tests=false \
      -Denable_docs=false \
      -Dlogging=true \
      -Dtestdata_tests=false \
      -Dfuzzing_engine=none \
      -Dfuzzer_ldflags= \
      -Dxxhash_muxer=disabled \
      -Dtrim_dsp=if-release
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
    mk-dsyms $out
  '';
}
