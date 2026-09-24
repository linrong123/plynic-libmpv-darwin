# `universal` is the per-OS aggregate the xcframeworks are made from; with
# arm64 as the only architecture it holds just that slice.
let
  oses = import ../constants/oses.nix;
  archs = import ../constants/archs.nix;
in
(import ./pkgs.nix)
++ [
  {
    os = oses.iossimulator;
    arch = archs.universal;
  }
  {
    os = oses.macos;
    arch = archs.universal;
  }
]
