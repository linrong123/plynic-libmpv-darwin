{
  pkgs ? import ../../utils/default/pkgs.nix,
  os ? import ../../utils/default/os.nix,
  arch ? pkgs.callPackage ../../utils/default/arch.nix { },
  variant ? import ../../utils/default/variant.nix,
  flavor ? import ../../utils/default/flavor.nix,
}:

let
  name = "libs";
  version = import ../../utils/version/default.nix { inherit pkgs; };

  archs = import ../../utils/constants/archs.nix;
  callPackage = pkgs.lib.callPackageWith {
    inherit
      pkgs
      os
      arch
      variant
      flavor
      ;
  };
  pname = import ../../utils/name/output.nix name;
in

let
  name = "${pname}-${os}-${arch}-${variant}-${flavor}-${version}";
in

if arch != archs.universal then
  let
    xctoolchainOtool = callPackage ../../utils/xctoolchain/otool.nix { };
    xctoolchainInstallNameTool = callPackage ../../utils/xctoolchain/install-name-tool.nix { };
    xctoolchainStrip = callPackage ../../utils/xctoolchain/strip.nix { };

    deps = [
      (callPackage ../mk-pkg-mpv/default.nix { })
      (callPackage ../mk-pkg-ffmpeg/default.nix { })
      (callPackage ../mk-pkg-mbedtls/default.nix { })
      (callPackage ../mk-pkg-libplacebo/default.nix { })
      (callPackage ../mk-pkg-dav1d/default.nix { })
      (callPackage ../mk-pkg-libxml2/default.nix { })
      (callPackage ../mk-pkg-uchardet/default.nix { })
      (callPackage ../mk-pkg-libass/default.nix { })
      (callPackage ../mk-pkg-harfbuzz/default.nix { })
      (callPackage ../mk-pkg-fribidi/default.nix { })
      (callPackage ../mk-pkg-freetype/default.nix { })
      (callPackage ../mk-pkg-libpng/default.nix { })
    ];
  in
  pkgs.stdenvNoCC.mkDerivation {
    inherit name;
    pname = pname;
    inherit version;
    dontUnpack = true;
    enableParallelBuilding = true;
    nativeBuildInputs = [
      xctoolchainInstallNameTool
      xctoolchainOtool
      xctoolchainStrip
    ];
    buildPhase = ''
      mkdir -p build/dSYM

      # Copy dylibs except '*-subset.*.dylib', and their dSYMs
      for dep in ${pkgs.lib.concatStringsSep " " deps}; do
        find $dep/lib \
          -type f -name '*.dylib' \
          ! -name '*-subset.*.dylib' \
          -exec \
          cp {} ./build/ \
          \;
        if [ -d $dep/dSYM ]; then
          for dsym in $dep/dSYM/*.dSYM; do
            case "$(basename $dsym)" in *-subset.*) continue ;; esac
            cp -R $dsym ./build/dSYM/
          done
        fi
      done
      chmod -R u+w ./build

      # Rename dylib libfoo.100.99.88.dylib -> libfoo.dylib (and its dSYM)
      for file in ./build/lib*.dylib; do
        new_path=$(echo $file | sed -E 's/^(.*\/lib[^.]*).*$/\1.dylib/')
        if [ $file != $new_path ]; then
          mv $file $new_path
          if [ -d ./build/dSYM/$(basename $file).dSYM ]; then
            mv ./build/dSYM/$(basename $file).dSYM ./build/dSYM/$(basename $new_path).dSYM
          fi
        fi
      done

      # Change dylib's id libfoo.dylib -> @rpath/libfoo.dylib
      for file in ./build/lib*.dylib; do
        name=$(basename $file)
        install_name_tool -id @rpath/$name $file
      done

      # Change dylib's dep path /nix/store/**/libfoo.99.dylib -> @rpath/libfoo.99.dylib
      for file in ./build/lib*.dylib; do
        deps=$(otool -L $file | tail -n +3 | sed -n 's|.*\(/nix/store/[^ ]*\).*|\1|p')
        for dep in $deps; do
          name=$(basename $dep)
          install_name_tool -change $dep @rpath/$name $file
        done
      done

      # Change dylib's dep path @rpath/libfoo.99.dylib -> @rpath/libfoo.dylib
      for file in ./build/lib*.dylib; do
        deps=$(otool -L $file | tail -n +3 | sed -n 's|.*\(@rpath/[^ ]*\).*|\1|p')
        for dep in $deps; do
          name=$(echo $dep | sed -n 's|@rpath/\(lib[^.]*\).*|\1.dylib|p')
          install_name_tool -change $dep @rpath/$name $file
        done
      done

      # Drop run paths into the build machine: mpv's swift build adds the
      # Xcode toolchain's swift library directory (the Swift runtime the app
      # uses is the system's, /usr/lib/swift, which stays).
      for file in ./build/lib*.dylib; do
        otool -l $file | awk '/cmd LC_RPATH/ {r=1} r && /path / {print $2; r=0}' |
          while read -r rpath; do
            case "$rpath" in
              @*|/usr/lib/swift) ;;
              *) echo "$file: dropping LC_RPATH $rpath"
                 install_name_tool -delete_rpath "$rpath" $file ;;
            esac
          done
      done

      # Strip local symbols now that the dSYMs hold them (the exported
      # symbols stay, and so does the LC_UUID the dSYMs are matched by).
      for file in ./build/lib*.dylib; do
        strip -x $file
      done
    '';
    installPhase = ''
      cp -r build $out
    '';
  }
else
  let
    targets = import ./targets.nix;
    xctoolchainLipo = callPackage ../../utils/xctoolchain/lipo.nix { };

    depArchs = builtins.concatMap (
      target: if target.os == os && target.arch != archs.universal then [ target.arch ] else [ ]
    ) targets;
    deps = builtins.map (
      arch:
      import ./default.nix {
        inherit
          pkgs
          os
          arch
          variant
          flavor
          ;
      }
    ) depArchs;
  in
  pkgs.stdenvNoCC.mkDerivation {
    inherit name;
    pname = pname;
    inherit version;
    dontUnpack = true;
    enableParallelBuilding = true;
    nativeBuildInputs = [
      xctoolchainLipo
    ];
    buildPhase = ''
      mkdir -p build/dSYM

      # Concatenate source directories and convert string to array
      deps="${pkgs.lib.concatStringsSep " " deps}"
      read -a deps <<< "$deps"

      # Loop through all .dylib files in the first source directory
      for lib in ''${deps[0]}/*.dylib; do
        lib_name=$(basename $lib)

        # Initialize lipo command
        lipo_cmd="lipo -create"

        # Add each corresponding .dylib file from all source directories
        for dir in ''${deps[@]}; do
          if [ -f $dir/$lib_name ]; then
            lipo_cmd+=" $dir/$lib_name"
          else
            echo "Error: $lib_name not found in $dir" 2> /dev/stderr
            exit 1
          fi
        done

        # Set output to build directory and execute lipo command
        lipo_cmd+=" -output ./build/$lib_name"
        eval "$lipo_cmd"
      done

      # One architecture per OS (arm64): the dSYMs carry over as they are.
      # With several, each dSYM's DWARF would have to be lipo'ed the same way.
      if [ ''${#deps[@]} -ne 1 ]; then
        echo "Error: more than one architecture, dSYMs are not merged" >&2
        exit 1
      fi
      cp -R ''${deps[0]}/dSYM/. ./build/dSYM/
    '';
    installPhase = ''
      cp -r build $out
    '';
  }
