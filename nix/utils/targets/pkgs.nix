# arm64 only: iPhones and iPads, the simulator on Apple silicon, and Apple
# silicon Macs (no Intel Mac to test on; plynic spec 0017 §8.0 Q11).
let
  oses = import ../constants/oses.nix;
  archs = import ../constants/archs.nix;
in
[
  {
    os = oses.ios;
    arch = archs.arm64;
  }
  {
    os = oses.iossimulator;
    arch = archs.arm64;
  }
  {
    os = oses.macos;
    arch = archs.arm64;
  }
]
