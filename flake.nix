{
  description = "plynic-libmpv-darwin: libmpv for iOS and macOS, built for plynic";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs?ref=nixpkgs-unstable";
    flakelight = {
      url = "github:nix-community/flakelight";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # The plynic-mpv fork, at the same commit plynic-libmpv-android pins
    # (buildscripts/include/depinfo.sh, v_mpv). flake.lock records its NAR
    # hash. Bump with
    #   nix flake lock --override-input plynic-mpv github:linrong123/plynic-mpv/<sha>
    # and try local work with
    #   nix build --override-input plynic-mpv git+file:///path/to/plynic-mpv?rev=<sha> ...
    plynic-mpv = {
      url = "github:linrong123/plynic-mpv/4c4e802343438d79561abbd15d9bc453473860af";
      flake = false;
    };
  };

  outputs =
    { flakelight, plynic-mpv, ... }:
    flakelight ./. {
      flakelight.builtinFormatters = false;
      withOverlays = [
        (final: prev: {
          plynicMpv = {
            src = plynic-mpv;
            rev = plynic-mpv.rev or "0000000000000000000000000000000000000000";
            dirty = !(plynic-mpv ? rev);
          };
        })
      ]
      ++ import ./nix/utils/default/overlays.nix;
      nixpkgs.config = {
        allowUnfree = true;
      };
      systems = [
        "aarch64-darwin"
      ];
      devShell = pkgs: {
        stdenv = pkgs.stdenvNoCC;
        packages = with pkgs; [
          tree
          gnumake
        ];
      };
      perSystem =
        { pkgs, ... }:
        {
          packages = import ./nix/utils/flake/create-cross-packages.nix {
            inherit pkgs;
            path = ./nix/packages;
          };
        };
    };
}
