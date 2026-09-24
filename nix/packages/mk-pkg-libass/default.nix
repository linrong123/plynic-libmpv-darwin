{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libass";
  source = callPackage ../../utils/fetch-source/default.nix {
    inherit name;
    lock = (import ../../../packages.lock.nix).${name};
  };
  inherit (source) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };
  xctoolchainLipo = callPackage ../../utils/xctoolchain/lipo.nix { };
  fribidi = callPackage ../mk-pkg-fribidi/default.nix { };
  harfbuzz = callPackage ../mk-pkg-harfbuzz/default.nix { };
  freetype = callPackage ../mk-pkg-freetype/default.nix { };

  pname = import ../../utils/name/package.nix name;
in

# libass's own meson build (0.17.2+). CoreText is the font provider (the
# system fonts, PingFang for CJK), and the aarch64 NEON assembly is on, as
# on Android arm64 (blur, rasterizer and blending in plain C otherwise).
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
    xctoolchainLipo
    mkDsyms
  ];
  buildInputs = [
    fribidi
    harfbuzz
    freetype
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Ddefault_library=shared \
      -Dfontconfig=disabled \
      -Ddirectwrite=disabled \
      -Dcoretext=enabled \
      -Dlibunibreak=disabled \
      -Dasm=enabled \
      -Drequire-system-font-provider=false \
      -Dtest=disabled \
      -Dcompare=disabled \
      -Dprofile=disabled \
      -Dfuzz=disabled \
      -Dcheckasm=disabled
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
    mk-dsyms $out
  '';
}
