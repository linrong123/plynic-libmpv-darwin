#!/usr/bin/env python3
"""manifest.py <dist> --tag <tag> --xcode <Xcode.app>: write <dist>/manifest.json.

What a release is, in one file, like plynic-libmpv-android's manifest.json:

  tag, flavor                  the release
  mpv_commit, mpv_repo         the plynic-mpv commit (flake.lock), the same
  mpv_version                  one Android pins; mpv_version is the string
                               Mpv.framework reports at run time
  ffmpeg_version               the string Avutil reports at run time
  deps, dep_commits            every dependency's version, and the commit of
  dep_tarballs                 the ones pinned by git (or the release
                               tarball and its sha256)
  patches                      sha256 of every FFmpeg patch, keyed by its path
                               here; patches/ffmpeg/* are byte-identical with
                               plynic-libmpv-android's (same keys there)
  sources                      SOURCES.json: the corresponding source files
  static_system                what the frameworks link statically from the
                               Xcode toolchain as it is (no source archive
                               here); also added to SOURCES.json, see
                               static_system() below, after which
                               sources/SHA256SUMS gets SOURCES.json's new
                               digest
  archives, dsyms              sha256 and size of each release file
  frameworks                   per framework and slice: LC_UUID, minos, sdk,
                               install name, dependencies, run paths, count
                               of "dynamically looked up" imports (must be 0),
                               architectures, whether a dSYM with the same
                               UUID is inside the xcframework
  toolchain                    Xcode and SDK versions the release was built
                               with
  ffmpeg_licenses, mpv_gpl     the license string each FFmpeg library reports,
                               and the -Dgpl= value in Mpv's configuration
  checks                       the release gates (end of main()); a build that
                               fails one exits non-zero

Uses the host's otool, vtool, dwarfdump and nm (Xcode command line tools):
this only inspects what nix built.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import subprocess
import sys
import tarfile
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# What the app's media_kit_libs_{ios,macos}_video pods list (19 frameworks).
EXPECTED_FRAMEWORKS = [
    "Ass", "Avcodec", "Avfilter", "Avformat", "Avutil", "Dav1d", "Freetype", "Fribidi",
    "Harfbuzz", "Mbedcrypto", "Mbedtls", "Mbedx509", "Mpv", "Placebo", "Png16",
    "Swresample", "Swscale", "Uchardet", "Xml2",
]


def sh(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def file_entry(path):
    return {"file": os.path.basename(path), "sha256": sha256(path), "size": os.path.getsize(path)}


def macho_info(binary):
    loads = sh("otool", "-l", binary)
    info = {}
    # the LC_BUILD_VERSION load command, up to the next one; otool versions
    # differ in how they lay it out, so each field is looked up on its own
    block = re.search(r"cmd LC_BUILD_VERSION\n(.*?)(?:\nLoad command|\Z)", loads, re.S)
    for key in ("platform", "minos", "sdk"):
        m = re.search(r"^\s*%s\s+(\S+)" % key, block.group(1), re.M) if block else None
        info[key] = m.group(1) if m else None
    if not info["minos"]:
        print("manifest: no minos in otool -l of %s:\n%s" % (binary, block.group(0) if block else loads[:2000]),
              file=sys.stderr)
    info["uuid"] = re.search(r"uuid (\S+)", loads).group(1)
    info["install_name"] = re.search(r"cmd LC_ID_DYLIB\n.*?name (\S+)", loads, re.S).group(1)
    info["rpaths"] = re.findall(r"cmd LC_RPATH\n.*?path (\S+)", loads, re.S)
    deps = sh("otool", "-L", binary).splitlines()[2:]
    info["dependencies"] = [d.strip().split(" (")[0] for d in deps]
    info["archs"] = sh("lipo", "-archs", binary).split()
    nm = sh("nm", "-m", binary)
    info["dynamic_lookups"] = sum(1 for line in nm.splitlines() if "dynamically looked up" in line)
    info["size"] = os.path.getsize(binary)
    return info


def framework_binary(fw_dir):
    name = os.path.basename(fw_dir)[: -len(".framework")]
    path = os.path.join(fw_dir, name)
    return os.path.realpath(path), name


def dsym_uuids(dsym):
    out = sh("dwarfdump", "--uuid", dsym)
    return re.findall(r"UUID: (\S+)", out)


# The toolchain's static archives a framework slice may take code from, by
# the slice's platform: Swift's back-deployment libraries (the driver links
# libswiftCompatibility56.a into Swift code built for macOS < 12.3) and
# compiler-rt's builtins.
TOOLCHAIN_ARCHIVES = {
    "macos-arm64": ("swift/macosx/*.a", "clang/*/lib/darwin/libclang_rt.osx.a"),
    "ios-arm64": ("swift/iphoneos/*.a", "clang/*/lib/darwin/libclang_rt.ios.a"),
    "ios-arm64-simulator": ("swift/iphonesimulator/*.a", "clang/*/lib/darwin/libclang_rt.iossim.a"),
}


def defined_symbols(path, globals_only):
    """Names nm -U (-g: external only) lists for the arm64 slice of a Mach-O
    file or archive; empty if it has no arm64 slice."""
    args = ["nm", "-U", "-arch", "arm64"] + (["-g"] if globals_only else []) + [path]
    r = subprocess.run(args, capture_output=True, text=True)
    return {line.split()[-1] for line in r.stdout.splitlines() if len(line.split()) >= 3}


def archive_symbols(path):
    """The strong external definitions of an archive's arm64 members. Weak
    ones (___clang_call_terminate, inline C++, ___swift_reflection_version)
    are emitted by every object that needs them, so they prove nothing."""
    r = subprocess.run(["nm", "-m", "-U", "-g", "-arch", "arm64", path], capture_output=True, text=True)
    out = set()
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 3 and "weak" not in parts[:-1] and parts[-2] == "external":
            out.add(parts[-1])
    return out


# zlib's API, whatever build it comes from: a framework that defines any
# of these links zlib in statically (libpng's meson wrap falls back to a
# zlib subproject when it cannot find the system's, for one). Z_PREFIX
# builds name them z_<name>; Mach-O adds the leading underscore.
ZLIB_API = ("inflate", "deflate", "crc32", "adler32", "zlibVersion")
ZLIB_SYMBOLS = frozenset("_" + p + n for n in ZLIB_API for p in ("", "z_"))


def static_system(xcode, slices):
    """What the frameworks took from the Xcode toolchain's static archives.

    slices: [(framework, slice id, binary, dSYM DWARF file)]. A slice took
    code from an archive when its dSYM (the frameworks are stripped, the
    dSYM keeps every symbol) defines one of the archive's strong external
    definitions. One record per archive, in SOURCES.json's "static-system"
    shape: the fields plynic-libmpv-android's static_system entries have,
    with frameworks per slice instead of ABIs."""
    usr_lib = os.path.join(xcode, "Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib")
    bin_dir = os.path.join(os.path.dirname(usr_lib), "bin")
    provider = "Xcode " + " / ".join(sh(os.path.join(xcode, "Contents/Developer/usr/bin/xcodebuild"),
                                        "-version").split("\n")[:2]).strip().removeprefix("Xcode ")
    swift_version = sh(os.path.join(bin_dir, "swiftc"), "--version").splitlines()[0].strip()
    clang_version = sh(os.path.join(bin_dir, "clang"), "--version").splitlines()[0].strip()
    cache = {}
    records = {}
    for fw, sid, binary, dwarf in slices:
        defined = defined_symbols(dwarf, False)
        exported = defined_symbols(binary, True)
        for pattern in TOOLCHAIN_ARCHIVES[sid]:
            for archive in sorted(glob.glob(os.path.join(usr_lib, pattern))):
                if archive not in cache:
                    cache[archive] = archive_symbols(archive)
                taken = cache[archive] & defined
                if not taken:
                    continue
                rel = os.path.relpath(archive, usr_lib)
                name = os.path.basename(archive)[: -len(".a")]
                if name.startswith("libswift"):
                    rid = "swift-" + name[len("libswift"):].lower()
                    what = ("a back-deployment library: the Swift driver links it into Swift code whose "
                            "deployment target predates the OS runtime it stands in for"
                            if "Compatibility" in name else "a static library of the Swift toolchain")
                    rec = dict(version=swift_version, license="Apache-2.0 WITH Swift-exception",
                               upstream="https://github.com/swiftlang/swift",
                               note="%s.a, %s (stdlib/toolchain in the Swift repository)" % (name, what))
                else:
                    rid = "llvm-compiler-rt-builtins"
                    rec = dict(version=clang_version, license="Apache-2.0 WITH LLVM-exception",
                               upstream="https://github.com/swiftlang/llvm-project",
                               note="compiler-rt's builtins, which clang adds to every link")
                r = records.setdefault(rid, dict(id=rid, kind="static-system", provider=provider, exported=False,
                                                 archives={}, **rec))
                r["exported"] = r["exported"] or bool(taken & exported)
                arcs = r["archives"].setdefault(sid, [])
                a = next((a for a in arcs if a["path"] == rel), None)
                if a is None:
                    a = {"path": rel, "sha256": sha256(archive), "frameworks": []}
                    arcs.append(a)
                a["frameworks"].append(fw)
    return [records[k] for k in sorted(records)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dist")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--xcode", required=True)
    a = ap.parse_args()
    dist = a.dist

    lock = json.load(open(os.path.join(ROOT, "flake.lock")))
    mpv = lock["nodes"]["plynic-mpv"]["locked"]
    sources_path = os.path.join(dist, "sources", "SOURCES.json")
    # the archives; "static-system" entries (no file) are this script's own
    # and are rewritten below
    sources = [s for s in json.load(open(sources_path)) if s.get("kind") != "static-system"]

    manifest = {
        "tag": a.tag,
        "flavor": "plynic",
        "mpv_commit": mpv["rev"],
        "mpv_repo": "https://github.com/%s/%s.git" % (mpv["owner"], mpv["repo"]),
        "mpv_nar_hash": mpv["narHash"],
    }

    deps, dep_commits, dep_tarballs = {}, {}, {}
    for s in sources:
        if s["id"] in ("mpv", "patches", "plynic-libmpv-darwin", "libpngPatch"):
            continue
        deps[s["id"]] = s["version"]
        origin = s.get("origin", {})
        if "rev" in origin:
            dep_commits[s["id"]] = origin["rev"]
        elif "url" in origin:
            dep_tarballs[s["id"]] = {"url": origin["url"], "sha256": origin["sha256"]}
    manifest["deps"] = dict(sorted(deps.items()))
    manifest["dep_commits"] = dict(sorted(dep_commits.items()))
    manifest["dep_tarballs"] = dict(sorted(dep_tarballs.items()))

    patches = {}
    for p in sorted(glob.glob(os.path.join(ROOT, "patches", "*", "*.patch"))):
        patches[os.path.relpath(p, ROOT)] = sha256(p)
    manifest["patches"] = patches

    manifest["sources"] = [
        {k: s[k] for k in ("file", "id", "version", "license", "sha256", "size")} for s in sources
    ]

    archives = {}
    frameworks = {}
    linked = []  # (framework, slice, binary, dSYM DWARF file), for static_system()
    with tempfile.TemporaryDirectory() as tmp:
        for tgz in sorted(glob.glob(os.path.join(dist, "libmpv-xcframeworks_*.tar.gz"))):
            platform = "ios" if "_ios-" in os.path.basename(tgz) else "macos"
            archives[platform] = file_entry(tgz)
            with tarfile.open(tgz) as t:
                try:
                    t.extractall(os.path.join(tmp, platform), filter="tar")
                except TypeError:  # Python < 3.12
                    t.extractall(os.path.join(tmp, platform))
            for xcf in sorted(glob.glob(os.path.join(tmp, platform, "*", "*.xcframework"))):
                xname = os.path.basename(xcf)[: -len(".xcframework")]
                for slice_dir in sorted(glob.glob(os.path.join(xcf, "*-*"))):
                    slice_id = os.path.basename(slice_dir)
                    fw = glob.glob(os.path.join(slice_dir, "*.framework"))[0]
                    binary, _ = framework_binary(fw)
                    info = macho_info(binary)
                    dsym = os.path.join(slice_dir, "dSYMs", os.path.basename(fw) + ".dSYM")
                    info["dsym"] = os.path.isdir(dsym) and info["uuid"].upper() in [
                        u.upper() for u in dsym_uuids(dsym)
                    ]
                    info["privacy_manifest"] = bool(
                        glob.glob(os.path.join(fw, "**", "PrivacyInfo.xcprivacy"), recursive=True)
                    )
                    frameworks.setdefault(xname, {})[slice_id] = info
                    dwarf = os.path.join(dsym, "Contents", "Resources", "DWARF", os.path.basename(binary))
                    if slice_id in TOOLCHAIN_ARCHIVES and os.path.isfile(dwarf):
                        linked.append((xname, slice_id, binary, dwarf))
                    if xname == "Mpv" and "mpv_version" not in manifest:
                        m = re.search(rb"mpv (v0\.[0-9.]+-plynic-g[0-9a-f]{9}(?:-dirty)?)",
                                      open(binary, "rb").read())
                        manifest["mpv_version"] = m.group(1).decode() if m else None
                    if xname == "Avutil" and "ffmpeg_version" not in manifest:
                        m = re.search(rb"FFmpeg version (n?[0-9][0-9.]*)", open(binary, "rb").read())
                        manifest["ffmpeg_version"] = m.group(1).decode() if m else None
                    if xname == "Mpv":
                        data = open(binary, "rb").read()
                        gpl = sorted(set(re.findall(rb"-Dgpl=(\w+)", data)))
                        manifest.setdefault("mpv_gpl", {})[slice_id] = [g.decode() for g in gpl]
                    if re.match(r"(Av|Sw)", xname):
                        m = re.search(rb"lib\w+ license: ([^\0\n]+)", open(binary, "rb").read())
                        manifest.setdefault("ffmpeg_licenses", {}).setdefault(xname, {})[slice_id] = (
                            m.group(1).decode() if m else None
                        )
        statics = static_system(a.xcode, linked)
        # the dSYM keeps every symbol, local ones too; the binary its
        # exported ones (in case a slice had no dSYM, which fails anyway)
        zlib_static = sorted(
            "%s %s (%s)" % (fw, sid, ", ".join(sorted(found)))
            for fw, sid, binary, dwarf in linked
            for found in [ZLIB_SYMBOLS & (defined_symbols(dwarf, False) | defined_symbols(binary, False))]
            if found)
    manifest["archives"] = archives
    manifest["static_system"] = statics
    # SOURCES.json gets the same records (after the archives' entries, so a
    # reader that takes every entry with a "file" sees what it saw before),
    # and SHA256SUMS its digest: the nix build wrote SHA256SUMS for the
    # archives only, and SOURCES.json is only final now.
    with open(sources_path, "w") as f:
        json.dump(sources + statics, f, indent=2, sort_keys=True)
        f.write("\n")
    sums_path = os.path.join(dist, "sources", "SHA256SUMS")
    with open(sums_path) as f:
        sums = [line for line in f.read().splitlines() if not line.endswith("  SOURCES.json")]
    with open(sums_path, "w") as f:
        f.write("".join(line + "\n" for line in sums) + "%s  SOURCES.json\n" % sha256(sources_path))
    dsyms = os.path.join(dist, "dsyms-plynic.zip")
    manifest["dsyms"] = file_entry(dsyms) if os.path.exists(dsyms) else None
    manifest["frameworks"] = frameworks

    xcodebuild = os.path.join(a.xcode, "Contents/Developer/usr/bin/xcodebuild")
    toolchain = {"xcode": " / ".join(sh(xcodebuild, "-version").split("\n")[:2]).strip()}
    for sdk in ("iphoneos", "iphonesimulator", "macosx"):
        try:
            toolchain[sdk + "_sdk"] = sh(xcodebuild, "-version", "-sdk", sdk, "SDKVersion").strip()
        except subprocess.CalledProcessError:
            pass
    manifest["toolchain"] = toolchain

    # The gates every release must pass (plynic spec 0017 §6.2 4-1, §5.2 S4.3).
    problems = []
    # slice -> LC_BUILD_VERSION platform; otool prints the number or the name
    platforms = {
        "ios-arm64": ("2", "IOS"),
        "ios-arm64-simulator": ("7", "IOSSIMULATOR"),
        "macos-arm64": ("1", "MACOS"),
    }
    # the frameworks privacy/ has a manifest for; they must carry it on iOS
    privacy = sorted(
        os.path.basename(p)[: -len(".xcprivacy")] for p in glob.glob(os.path.join(ROOT, "privacy", "*.xcprivacy"))
    )
    for name in privacy:
        if name not in frameworks:
            problems.append("privacy/%s.xcprivacy: no such framework" % name)
    if sorted(frameworks) != sorted(EXPECTED_FRAMEWORKS):
        problems.append("frameworks %s, want %s" % (sorted(frameworks), sorted(EXPECTED_FRAMEWORKS)))
    for name, slices in frameworks.items():
        if sorted(slices) != sorted(platforms):
            problems.append("%s: slices %s, want %s" % (name, sorted(slices), sorted(platforms)))
        for sid, info in slices.items():
            want = "12.0" if sid.startswith("macos") else "15.0"
            if info.get("minos") != want:
                problems.append("%s %s: minos %s, want %s" % (name, sid, info.get("minos"), want))
            if sid in platforms and info.get("platform") not in platforms[sid]:
                problems.append("%s %s: platform %s, want %s" % (name, sid, info.get("platform"), platforms[sid][1]))
            if sid.startswith("ios") and name in privacy and not info["privacy_manifest"]:
                problems.append("%s %s: no PrivacyInfo.xcprivacy" % (name, sid))
            if info["dynamic_lookups"]:
                problems.append("%s %s: %d dynamically looked up imports" % (name, sid, info["dynamic_lookups"]))
            for d in info["dependencies"]:
                if not (d.startswith("@rpath/") or d.startswith("/System/") or d.startswith("/usr/lib/")):
                    problems.append("%s %s: depends on %s" % (name, sid, d))
            for r in info["rpaths"]:
                if not (r.startswith("@") or r == "/usr/lib/swift"):
                    problems.append("%s %s: run path %s" % (name, sid, r))
            if info["archs"] != ["arm64"]:
                problems.append("%s %s: architectures %s" % (name, sid, info["archs"]))
            if not info["dsym"]:
                problems.append("%s %s: no matching dSYM" % (name, sid))
    if not manifest.get("mpv_version") or not manifest["mpv_version"].endswith(
        "-plynic-g" + manifest["mpv_commit"][:9]
    ):
        problems.append("mpv_version %s does not name %s" % (manifest.get("mpv_version"), manifest["mpv_commit"]))
    want_ffmpeg = "n" + manifest["deps"].get("ffmpeg", "?")
    if manifest.get("ffmpeg_version") != want_ffmpeg:
        problems.append("ffmpeg_version %s, want %s" % (manifest.get("ffmpeg_version"), want_ffmpeg))
    for sid, gpl in manifest.get("mpv_gpl", {}).items():
        if gpl != ["false"]:
            problems.append("Mpv %s: configuration has -Dgpl=%s, want false" % (sid, "/".join(gpl) or "?"))
    for name, slices in manifest.get("ffmpeg_licenses", {}).items():
        for sid, lic in slices.items():
            if not lic or not lic.startswith("LGPL version"):
                problems.append("%s %s: license %s, want LGPL" % (name, sid, lic))
    for fs in zlib_static:
        problems.append("%s: zlib is linked in statically; the frameworks use the system's "
                        "/usr/lib/libz.1.dylib, and a static zlib would need its source under sources/" % fs)
    # every file under sources/ has its line in SHA256SUMS, SOURCES.json too
    with open(sums_path) as f:
        listed = {line.split("  ", 1)[1] for line in f.read().splitlines() if "  " in line}
    unlisted = sorted(set(os.listdir(os.path.join(dist, "sources"))) - listed - {"SHA256SUMS"})
    if unlisted:
        problems.append("sources/SHA256SUMS does not list %s" % ", ".join(unlisted))
    manifest["checks"] = {"passed": not problems, "problems": problems}

    with open(os.path.join(dist, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    for p in problems:
        print("manifest: " + p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
