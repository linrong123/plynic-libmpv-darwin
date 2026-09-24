{
  pkgs ? import ../default/pkgs.nix,
}:

pkgs.runCommand "mk-xctoolchain-dsymutil" { } ''
  mkdir -p $out/bin
  ln -s ${pkgs.darwin.xcode}/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/dsymutil $out/bin/dsymutil
''
