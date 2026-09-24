# The source tree of a dependency, as pinned in packages.lock.nix.
#
# Two kinds of pins:
#   { version; url; sha256; file ? <last URL component>; }
#     a release tarball; sha256 is that of the file itself (as upstream
#     publishes it), the tree is the tarball with its top directory stripped
#   { version; github = "owner/repo"; rev; hash; submodules ? false; }
#     a git commit (the same one plynic-libmpv-android pins); hash is the NAR
#     hash of the tree, so it does not depend on how GitHub happens to
#     compress its archives today
#
# `archive` is what the release publishes as the corresponding source (see
# mk-out-sources): the upstream tarball byte for byte, or for a git pin a
# deterministic tar.xz of the tree.
{
  pkgs ? import ../default/pkgs.nix,
  name,
  lock,
}:

let
  isGit = lock ? github;
  pname = import ../name/package.nix name;
  owner = builtins.head (builtins.split "/" lock.github);
  repo = builtins.elemAt (builtins.split "/" lock.github) 2;
  tarball = builtins.fetchurl { inherit (lock) url sha256; };
  tree =
    if isGit then
      pkgs.fetchFromGitHub {
        name = "${pname}-source-${lock.version}";
        inherit owner repo;
        inherit (lock) rev hash;
        fetchSubmodules = lock.submodules or false;
      }
    else
      pkgs.runCommand "${pname}-source-${lock.version}" { } ''
        mkdir $out
        tar -xf ${tarball} --strip-components=1 -C $out
      '';
  archiveName =
    if isGit then
      "src-${name}-${lock.version}.tar.xz"
    else
      lock.file or (builtins.baseNameOf lock.url);
  archive =
    if isGit then
      pkgs.runCommand archiveName
        {
          nativeBuildInputs = [
            pkgs.gnutar
            pkgs.xz
          ];
        }
        ''
          tar --sort=name --format=pax --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
            --mtime=@1 --owner=0 --group=0 --numeric-owner \
            --transform 's|^\.|${name}-${lock.version}|' \
            -C ${tree} -cf - . | xz -T1 -c > $out
        ''
    else
      tarball;
in
{
  inherit tree archive archiveName;
  inherit (lock) version;
  origin =
    if isGit then
      {
        git = "https://github.com/${lock.github}.git";
        inherit (lock) rev;
        submodules = lock.submodules or false;
      }
    else
      {
        inherit (lock) url sha256;
      };
}
