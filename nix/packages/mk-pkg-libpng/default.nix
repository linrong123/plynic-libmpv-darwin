{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libpng";
  locks = import ../../../packages.lock.nix;
  source = callPackage ../../utils/fetch-source/default.nix {
    inherit name;
    lock = locks.${name};
  };
  inherit (source) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };

  pname = import ../../utils/name/package.nix name;
  libpngPatch = builtins.fetchurl {
    inherit (locks.libpngPatch) url sha256;
  };
  patchedSource =
    pkgs.runCommand "${pname}-patched-source-${version}"
      {
        nativeBuildInputs = [
          pkgs.unzip
          pkgs.rsync
        ];
      }
      ''
        cp -r ${source.tree} src
        export src=$PWD/src
        chmod -R 777 $src

        # meson build files from the WrapDB
        unzip ${libpngPatch} -d libpng-patch
        rsync -a libpng-patch/libpng-*/ $src/

        cp -r $src $out
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
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
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
    meson install -C build
    mk-dsyms $out
  '';
}
