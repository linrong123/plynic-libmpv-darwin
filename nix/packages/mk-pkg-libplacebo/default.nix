{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
}:

let
  name = "libplacebo";
  source = callPackage ../../utils/fetch-source/default.nix {
    inherit name;
    lock = (import ../../../packages.lock.nix).${name};
  };
  inherit (source) version;

  callPackage = pkgs.lib.callPackageWith { inherit pkgs os arch; };
  nativeFile = callPackage ../../utils/native-file/default.nix { };
  crossFile = callPackage ../../utils/cross-file/default.nix { };
  mkDsyms = callPackage ../../utils/dsym/default.nix { };
  nativeBuildInputs = [
    pkgs.meson
    pkgs.ninja
    pkgs.pkg-config
    pkgs.python3
    mkDsyms
  ];

  pname = import ../../utils/name/package.nix name;
  patchedSource = callPackage ../../utils/patch-shebangs/default.nix {
    name = "${pname}-patched-source-${version}";
    src = source.tree;
    inherit nativeBuildInputs;
  };
in

# mpv 0.41 requires libplacebo: vo=gpu (the renderer behind the render API
# the app uses) links its colour-space and shader helpers. LGPL-2.1-or-later,
# a dynamic library like the others (Placebo.framework).
#
# Only the OpenGL (ES) backend, as on Android: no Vulkan (not asked for, and
# it would need the loader and a SPIR-V compiler), no LittleCMS, no Dolby
# Vision reshaping, no demos or tests. Every optional dependency is named, so
# nothing on the build host can change what gets built. The OpenGL loader is
# generated from the glad submodule by python3 (jinja/markupsafe submodules);
# Vulkan-Headers (needed even without Vulkan) and fast_float are header-only.
# libplacebo has C++ parts (fast_float); as a dynamic library it links the
# system libc++.
pkgs.stdenvNoCC.mkDerivation {
  name = "${pname}-${os}-${arch}-${version}";
  pname = pname;
  inherit version;
  src = patchedSource;
  dontUnpack = true;
  enableParallelBuilding = true;
  inherit nativeBuildInputs;
  configurePhase = ''
    meson setup build $src \
      --native-file ${nativeFile} \
      --cross-file ${crossFile} \
      --prefix=$out \
      -Ddefault_library=shared \
      -Dvulkan=disabled -Dvk-proc-addr=disabled \
      -Dopengl=enabled -Dgl-proc-addr=enabled \
      -Dd3d11=disabled -Dglslang=disabled -Dshaderc=disabled \
      -Dlcms=disabled -Ddovi=disabled -Dlibdovi=disabled \
      -Dunwind=disabled -Dxxhash=disabled \
      -Ddemos=false -Dtests=false -Dbench=false -Dfuzz=false
  '';
  buildPhase = ''
    meson compile -vC build
  '';
  installPhase = ''
    meson install -C build
    mk-dsyms $out
  '';
}
