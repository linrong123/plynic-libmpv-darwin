{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libxml2";
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

# The same feature set as on Android (--with-minimum --with-threads
# --with-tree --without-lzma): FFmpeg's DASH demuxer only parses the MPD
# with the tree API. libxml2's own meson build (2.13+).
pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = source.tree;
  dontUnpack = true;
  enableParallelBuilding = true;
  # meson.build runs `git describe` (unchecked, but the program must exist)
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.git
    mkDsyms
  ];
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Ddefault_library=shared \
      -Dminimum=true \
      -Dthreads=enabled \
      -Dpython=disabled
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
    mk-dsyms $out
  '';
}
