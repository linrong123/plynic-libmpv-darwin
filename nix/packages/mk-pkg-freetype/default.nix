{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "freetype";
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
  harfbuzz = callPackage ../mk-pkg-harfbuzz/default.nix { };
  libpng = callPackage ../mk-pkg-libpng/default.nix { };

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
    pkgs.python3
    xctoolchainLipo
    mkDsyms
  ];
  buildInputs = [
    harfbuzz
    libpng
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Dbrotli=disabled \
      -Dbzip2=disabled \
      -Dharfbuzz=enabled \
      -Dmmap=disabled \
      -Dpng=enabled \
      -Dtests=disabled \
      -Dzlib=system
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
    mk-dsyms $out
  '';
}
