{
  pkgs ? import ../../utils/default/pkgs.nix,
}:

# The complete corresponding source of a release (plynic spec 0017 K-F), so
# that every LGPL library in the frameworks comes with its source from the
# same place:
#
#   src-<dep>-<version>.tar.xz   a dependency pinned by git commit: the tree,
#                                deterministic tar (sorted, owner 0, mtime 1)
#   <upstream tarball>           a dependency pinned as a release tarball
#                                (mbedtls, uchardet, libpng, libpng's WrapDB
#                                meson files): the very file, same sha256
#   src-mpv-<sha9>.tar.xz        the plynic-mpv fork at the pinned commit (its
#                                plynic changes are commits there)
#   patches-<tag>.tar.xz         patches/: applied to FFmpeg by mk-pkg-ffmpeg
#   plynic-libmpv-darwin-<tag>.tar.xz
#                                this repository as built (nix expressions,
#                                cross files, packages.lock.nix, flake.lock)
#   SOURCES.json                 one entry per file: what it is, version,
#                                licence, upstream location and commit or
#                                digest, sha256, size, patches applied
#   SHA256SUMS                   `shasum -a 256 -c` format
let
  version = import ../../utils/version/default.nix { inherit pkgs; };
  locks = import ../../../packages.lock.nix;
  licenses = {
    dav1d = "BSD-2-Clause";
    ffmpeg = "LGPL-3.0-or-later";
    freetype = "FTL OR GPL-2.0-or-later";
    fribidi = "LGPL-2.1-or-later";
    harfbuzz = "MIT-Modern-Variant";
    libass = "ISC";
    libplacebo = "LGPL-2.1-or-later";
    libpng = "libpng-2.0";
    libpngPatch = "MIT";
    libxml2 = "MIT";
    mbedtls = "Apache-2.0 OR GPL-2.0-or-later";
    uchardet = "MPL-1.1 OR GPL-2.0-or-later OR LGPL-2.1-or-later";
  };
  patchesFor = {
    ffmpeg = builtins.map (p: "patches/ffmpeg/${p}") (
      builtins.sort builtins.lessThan (builtins.attrNames (builtins.readDir ../../../patches/ffmpeg))
    )
    ++ builtins.map (p: "patches/ffmpeg-darwin/${p}") (
      builtins.sort builtins.lessThan (
        builtins.attrNames (builtins.readDir ../../../patches/ffmpeg-darwin)
      )
    );
  };
  deps = builtins.map (
    name:
    let
      lock = locks.${name};
      fetched = pkgs.callPackage ../../utils/fetch-source/default.nix { inherit name lock; };
    in
    {
      id = name;
      inherit (fetched) version archive archiveName origin;
      license = licenses.${name};
      patches = patchesFor.${name} or [ ];
    }
  ) (builtins.attrNames locks);
  inherit (pkgs.plynicMpv) rev;
  sha9 = builtins.substring 0 9 rev;
  treeTar =
    name: prefix: tree:
    pkgs.runCommand name
      {
        nativeBuildInputs = [
          pkgs.gnutar
          pkgs.xz
        ];
      }
      ''
        tar --sort=name --format=pax --pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
          --mtime=@1 --owner=0 --group=0 --numeric-owner \
          --transform 's|^\.|${prefix}|' \
          -C ${tree} -cf - . | xz -T1 -c > $out
      '';
  mpvArchive = treeTar "src-mpv-${sha9}.tar.xz" "mpv-${sha9}" pkgs.plynicMpv.src;
  patchesArchive = treeTar "patches-${version}.tar.xz" "patches" ../../../patches;
  repoArchive = treeTar "plynic-libmpv-darwin-${version}.tar.xz" "plynic-libmpv-darwin-${version}" ../../..;
  extra = [
    {
      id = "mpv";
      version = sha9;
      archive = mpvArchive;
      archiveName = "src-mpv-${sha9}.tar.xz";
      origin = {
        git = "https://github.com/linrong123/plynic-mpv.git";
        inherit rev;
      };
      license = "LGPL-2.1-or-later";
      patches = [ ];
    }
    {
      id = "patches";
      inherit version;
      archive = patchesArchive;
      archiveName = "patches-${version}.tar.xz";
      origin = { };
      license = "LGPL-2.1-or-later AND LGPL-3.0-or-later";
      patches = [ ];
    }
    {
      id = "plynic-libmpv-darwin";
      inherit version;
      archive = repoArchive;
      archiveName = "plynic-libmpv-darwin-${version}.tar.xz";
      origin = {
        git = "https://github.com/linrong123/plynic-libmpv-darwin.git";
        tag = version;
      };
      license = "MIT";
      patches = [ ];
    }
  ];
  entries = deps ++ extra;
  index = pkgs.writeText "sources-index.json" (
    builtins.toJSON (
      builtins.map (e: {
        file = e.archiveName;
        inherit (e)
          id
          version
          license
          origin
          patches
          ;
      }) entries
    )
  );
in

pkgs.stdenvNoCC.mkDerivation {
  name = "mk-out-sources-${version}";
  inherit version;
  dontUnpack = true;
  nativeBuildInputs = [ pkgs.python3 ];
  buildPhase = ''
    mkdir build
    ${pkgs.lib.concatMapStrings (e: ''
      cp ${e.archive} build/${e.archiveName}
    '') entries}
    chmod 644 build/*
    python3 - ${index} build <<'PY'
    import hashlib, json, os, sys
    index, out = sys.argv[1], sys.argv[2]
    entries = json.load(open(index))
    for e in entries:
        data = open(os.path.join(out, e["file"]), "rb").read()
        e["sha256"] = hashlib.sha256(data).hexdigest()
        e["size"] = len(data)
    entries.sort(key=lambda e: e["file"])
    with open(os.path.join(out, "SOURCES.json"), "w") as f:
        json.dump(entries, f, indent=2, sort_keys=True)
        f.write("\n")
    with open(os.path.join(out, "SHA256SUMS"), "w") as f:
        for e in entries:
            f.write("%s  %s\n" % (e["sha256"], e["file"]))
    PY
  '';
  installPhase = ''
    cp -r build $out
  '';
}
