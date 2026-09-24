{
  pkgs ? import ../../utils/default/pkgs.nix,
  format ? import ../../utils/default/format.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
  flavor ? import ../../utils/default/flavor.nix,
}:

let
  name = "archive";
  version = import ../../utils/version/default.nix { inherit pkgs; };

  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      flavor
      ;
  };

  pname = import ../../utils/name/output.nix name;
  formats = import ../../utils/constants/formats.nix;
  # The name plynic's media_kit_libs_{ios,macos}_video forks download:
  # libmpv-xcframeworks_<tag>_<ios|macos>-universal-video-plynic.tar.gz, one
  # top-level directory holding the *.xcframework (each slice with its dSYM).
  archiveBaseName = "libmpv-${format}_${version}_${os}-${arch}-${variant}-${flavor}";
  src =
    if format == formats.xcframeworks then
      callPackage ../mk-out-xcframeworks/default.nix { }
    else
      abort "Format ${format} is not supported";
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${format}-${os}-${arch}-${variant}-${flavor}-${version}";
  inherit pname;
  inherit version;
  dontUnpack = true;
  enableParallelBuilding = true;
  nativeBuildInputs = [
    pkgs.gnutar
    pkgs.gzip
  ];
  inherit src;
  # Deterministic: sorted members, fixed owner and mtime, no gzip timestamp.
  buildPhase = ''
    build=$PWD/build
    mkdir -p $build

    cp --no-preserve=mode -r $src ${archiveBaseName}
    tar --sort=name --format=gnu --mtime=@1 --owner=0 --group=0 --numeric-owner \
      -cf - ${archiveBaseName} | gzip -n -9 > $build/${archiveBaseName}.tar.gz
  '';
  installPhase = ''
    cp -r $build $out
  '';
}
