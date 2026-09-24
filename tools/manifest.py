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
  archives, dsyms              sha256 and size of each release file
  frameworks                   per framework and slice: LC_UUID, minos, sdk,
                               install name, dependencies, run paths, count
                               of "dynamically looked up" imports (must be 0),
                               architectures, whether a dSYM with the same
                               UUID is inside the xcframework
  toolchain                    Xcode and SDK versions the release was built
                               with

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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dist")
    ap.add_argument("--tag", required=True)
    ap.add_argument("--xcode", required=True)
    a = ap.parse_args()
    dist = a.dist

    lock = json.load(open(os.path.join(ROOT, "flake.lock")))
    mpv = lock["nodes"]["plynic-mpv"]["locked"]
    sources = json.load(open(os.path.join(dist, "sources", "SOURCES.json")))

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
                    if xname == "Mpv" and "mpv_version" not in manifest:
                        m = re.search(rb"mpv (v0\.[0-9.]+-plynic-g[0-9a-f]{9}(?:-dirty)?)",
                                      open(binary, "rb").read())
                        manifest["mpv_version"] = m.group(1).decode() if m else None
                    if xname == "Avutil" and "ffmpeg_version" not in manifest:
                        m = re.search(rb"FFmpeg version (n?[0-9][0-9.]*)", open(binary, "rb").read())
                        manifest["ffmpeg_version"] = m.group(1).decode() if m else None
    manifest["archives"] = archives
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

    # The gates every release must pass (plynic spec 0017 §6.2 4-1).
    problems = []
    for name, slices in frameworks.items():
        for sid, info in slices.items():
            want = "12.0" if sid.startswith("macos") else "15.0"
            if info.get("minos") != want:
                problems.append("%s %s: minos %s, want %s" % (name, sid, info.get("minos"), want))
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
    manifest["checks"] = {"passed": not problems, "problems": problems}

    with open(os.path.join(dist, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    for p in problems:
        print("manifest: " + p, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
