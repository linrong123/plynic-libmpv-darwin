{
  pkgs ? import ../../utils/default/pkgs.nix,
}:

# Everything a release publishes: the two xcframeworks archives, the dSYMs
# of every slice, and the corresponding source (sources/).
let
  name = "all";
  version = import ../../utils/version/default.nix { inherit pkgs; };

  pname = import ../../utils/name/output.nix name;
  flavors = import ../../utils/default/flavors.nix;
  variants = import ../../utils/default/variants.nix;
  targets = import ../mk-out-archive/targets.nix;
  archives = builtins.concatMap (
    target:
    builtins.concatMap (
      variant:
      builtins.map (
        flavor:
        import ../mk-out-archive/default.nix {
          inherit
            pkgs
            variant
            flavor
            ;
          inherit (target) format os arch;
        }
      ) flavors
    ) variants
  ) targets;
  dsyms = import ../mk-out-dsyms/default.nix { inherit pkgs; };
  sources = import ../mk-out-sources/default.nix { inherit pkgs; };
in

pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}";
  pname = pname;
  inherit version;
  dontUnpack = true;
  enableParallelBuilding = true;
  buildPhase = ''
    mkdir build

    for ARCHIVE in ${pkgs.lib.concatStringsSep " " archives}; do
      echo $ARCHIVE
      cp --no-preserve=mode $ARCHIVE/*.tar.gz build/
    done
    cp --no-preserve=mode ${dsyms}/*.zip build/
    cp -r --no-preserve=mode ${sources} build/sources
  '';
  installPhase = ''
    cp -r build $out
  '';
}
