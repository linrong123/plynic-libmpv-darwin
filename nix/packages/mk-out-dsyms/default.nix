{
  pkgs ? import ../../utils/default/pkgs.nix,
}:

# dsyms-plynic.zip: <slice>/<Name>.framework.dSYM for every framework of every
# slice, the same bundles the xcframeworks carry (for symbolicating crash
# reports without unpacking an archive). Matched by LC_UUID.
let
  version = import ../../utils/version/default.nix { inherit pkgs; };
  oses = import ../../utils/constants/oses.nix;
  archs = import ../../utils/constants/archs.nix;
  frameworks = os: import ../mk-out-frameworks/default.nix {
    inherit pkgs os;
    arch = archs.universal;
  };
  slices = {
    "ios-arm64" = frameworks oses.ios;
    "ios-arm64-simulator" = frameworks oses.iossimulator;
    "macos-arm64" = frameworks oses.macos;
  };
in

pkgs.stdenvNoCC.mkDerivation {
  name = "mk-out-dsyms-${version}";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.zip ];
  buildPhase = ''
    mkdir -p dsyms build
    ${pkgs.lib.concatStrings (
      pkgs.lib.mapAttrsToList (slice: fw: ''
        mkdir -p dsyms/${slice}
        cp -R --no-preserve=mode ${fw}/dSYMs/. dsyms/${slice}/
      '') slices
    )}
    find dsyms -exec touch -h -d @1 {} +
    (cd dsyms && find . -mindepth 1 | LC_ALL=C sort | zip -X -9 -@ ../build/dsyms-plynic.zip > /dev/null)
  '';
  installPhase = ''
    cp -r build $out
  '';
}
