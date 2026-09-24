# Only the xcframeworks archives: what plynic's media_kit_libs_{ios,macos}_video
# forks download.
let
  formats = import ../constants/formats.nix;
  xcframeworks = import ./xcframeworks.nix;
in

builtins.map (target: {
  format = formats.xcframeworks;
  inherit (target) os arch;
}) xcframeworks
