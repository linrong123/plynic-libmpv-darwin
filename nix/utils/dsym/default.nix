# `mk-dsyms <prefix>`: a dSYM bundle for every dynamic library installed under
# <prefix>/lib, written to <prefix>/dSYM/<file>.dSYM.
#
# Has to run in the install phase of the package that linked the library: on
# Darwin the DWARF stays in the object files, and the linked library only
# points at them (its debug map), so the build directory must still exist. The
# library keeps its symbols until mk-out-libs strips it; the dSYM and the
# stripped library share the LC_UUID, which is what crash reporting and App
# Store Connect match on.
{
  pkgs ? import ../default/pkgs.nix,
}:

let
  dsymutil = pkgs.callPackage ../xctoolchain/dsymutil.nix { };
in

pkgs.writeShellScriptBin "mk-dsyms" ''
  set -euo pipefail
  prefix=$1
  mkdir -p "$prefix/dSYM"
  find "$prefix/lib" -name '*.dylib' -type f | sort | while read -r lib; do
    ${dsymutil}/bin/dsymutil "$lib" -o "$prefix/dSYM/$(basename "$lib").dSYM"
  done
''
