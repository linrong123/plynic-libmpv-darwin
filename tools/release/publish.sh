#!/bin/bash
# publish.sh <tag>: the last step of every release, on a Mac (Apple silicon,
# a GPU, `gh` logged in with write access to this repository).
#
# CI creates a tag's release as a draft (.github/workflows/ci.yaml): its
# runner has no hardware-accelerated OpenGL, so the one check it cannot run
# is what an app does on a Mac - VideoToolbox frames through an accelerated
# CGL context, then screenshot-raw (rc3 shipped with every such screenshot
# failing; CI's glsw run covers the same code through the software
# renderer, this covers the hardware path). This script:
#
#   1. downloads the draft's manifest.json and macOS archive, and checks the
#      archive's sha256 against the manifest and the manifest's tag and
#      release gates;
#   2. runs tools/shot/run.sh <dist> gl strict from the tagged commit (not
#      this working tree) on that archive;
#   3. attaches the output, with the archive's sha256, the machine, macOS
#      and the OpenGL renderer, as screenshot-check-macos.txt, and writes
#      the result into the release body's Mac section
#      (tools/release/notes.py);
#   4. publishes the draft (a prerelease stays a prerelease).
#
# A failing check leaves the release a draft, and nothing is attached. Run
# it again after fixing whatever made it fail (a new tag if the frameworks
# were at fault: tags never move).
set -euo pipefail
tag=${1:?usage: publish.sh <tag>}
repo=${PLYNIC_DARWIN_REPO:-linrong123/plynic-libmpv-darwin}
root=$(cd "$(dirname "$0")/../.." && pwd)
die() { echo "publish.sh: $*" >&2; exit 1; }

[ "$(uname -s)/$(uname -m)" = Darwin/arm64 ] || die "run this on an Apple silicon Mac"
draft=$(gh release view "$tag" -R "$repo" --json isDraft -q .isDraft) || die "no release $tag in $repo"
[ "$draft" = true ] || die "$tag is already published"
git -C "$root" fetch -q --tags origin 2>/dev/null || true
commit=$(git -C "$root" rev-parse --verify -q "$tag^{commit}") || die "no tag $tag in $root (git fetch --tags)"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/dist" "$work/src"
gh release download "$tag" -R "$repo" -D "$work/dist" \
  -p manifest.json -p "libmpv-xcframeworks_${tag}_macos-universal-video-plynic.tar.gz"
archive="$work/dist/libmpv-xcframeworks_${tag}_macos-universal-video-plynic.tar.gz"
sha=$(shasum -a 256 "$archive" | cut -d' ' -f1)
python3 - "$work/dist/manifest.json" "$tag" "$sha" <<'PY' || die "the draft's files do not match its manifest"
import json, sys
m, tag, sha = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3]
problems = []
if m.get("tag") != tag:
    problems.append("manifest.json is for %s" % m.get("tag"))
if not m.get("checks", {}).get("passed"):
    problems.append("the release gates failed: %s" % m.get("checks"))
if m.get("archives", {}).get("macos", {}).get("sha256") != sha:
    problems.append("the macOS archive's sha256 is %s, the manifest says %s"
                    % (sha, m.get("archives", {}).get("macos", {}).get("sha256")))
for p in problems:
    print(p, file=sys.stderr)
sys.exit(1 if problems else 0)
PY

# The check as of the tag.
git -C "$root" archive "$commit" tools/shot tools/release | tar -x -C "$work/src"
evidence="$work/screenshot-check-macos.txt"
rc=0
"$work/src/tools/shot/run.sh" "$work/dist" gl strict > "$work/shot.txt" 2>&1 || rc=$?
{
  echo "tag: $tag"
  echo "archive: $(basename "$archive")"
  echo "archive_sha256: $sha"
  echo "tools: $commit"
  echo "date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "machine: $(sysctl -n hw.model) ($(sysctl -n machdep.cpu.brand_string))"
  echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
  echo "renderer: $(sed -n 's/^GL //p' "$work/shot.txt" | sort -u | paste -sd ';' -)"
  echo "exit: $rc"
  echo
  cat "$work/shot.txt"
} > "$evidence"
cat "$evidence"
[ $rc -eq 0 ] || die "tools/shot gl strict failed; $tag stays a draft"
grep -q '^SUMMARY gl strict: 4 passed, 0 failed, 0 skipped' "$evidence" \
  || die "tools/shot gl strict did not run all four cases; $tag stays a draft"
grep -q '^renderer: Apple Software Renderer' "$evidence" \
  && die "the OpenGL context is the software renderer; run this on a Mac with a GPU"

gh release view "$tag" -R "$repo" --json body -q .body > "$work/body.md"
python3 "$work/src/tools/release/notes.py" "$work/dist" "$work" --mac "$evidence" --body "$work/body.md" \
  > "$work/body.new.md"
gh release upload "$tag" -R "$repo" --clobber "$evidence"
gh release edit "$tag" -R "$repo" --notes-file "$work/body.new.md" --draft=false
echo "publish.sh: $tag published: $(gh release view "$tag" -R "$repo" --json url -q .url)"
