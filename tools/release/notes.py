#!/usr/bin/env python3
"""notes.py <dist> <checks dir> [--mac <evidence file>] [--body <file>]: a release body.

CI (without --mac) writes the body a tag's draft release is created with:
what was built, and the checks CI ran on these very frameworks (each
checks/<name>.txt summed up in one line). The section between the
MAC_BEGIN and MAC_END markers says that the Mac check is pending.

tools/release/publish.sh (with --mac and --body, the draft's current body)
replaces that section with the Mac check's evidence: the archive it tested
(sha256), the machine, the GL renderer and each case's result, from the
evidence file it also attaches to the release.
"""
import argparse
import json
import os
import re
import sys

MAC_BEGIN = "<!-- mac-check -->"
MAC_END = "<!-- /mac-check -->"

CHECKS = [
    ("probe", "tools/probe/run.sh dist --check", "versions, decoders, demuxers"),
    ("keepout-sw", "tools/keepout/run.sh dist sw", "--sub-keepout, paused track switches"),
    ("shot-glsw", "tools/shot/run.sh dist glsw strict",
     "screenshot-raw of VideoToolbox frames (nv12, p010) and software frames in bgr0 and rgba64, through "
     "CGL's software renderer: the OpenGL interop and the frame download a Mac does"),
    ("shot-sw", "tools/shot/run.sh dist sw", "screenshot-raw through the render API's software renderer"),
    ("rotate-glsw", "tools/rotate/run.sh dist glsw strict",
     "video-rotate 0/90/180/270 and a file's own rotation, VideoToolbox and software frames, read back "
     "from the OpenGL render target (CGL's software renderer); vo=null reports the missing lavfi rotate "
     "filter; strict: no case skipped, the VideoToolbox cases decode with VideoToolbox"),
    ("rotate-sw", "tools/rotate/run.sh dist sw",
     "the render API's software renderer draws rotated frames unrotated instead of aborting"),
    ("fallback", "tools/fallback/run.sh dist",
     "a video stream no decoder can open (HEVC with a broken hvcC) after VideoToolbox failed: one software "
     "attempt, the decoder wrapper's verdict, the core answering, the audio to its end"),
]


def summary(path):
    """A check's output in one line: its SUMMARY line if it prints one,
    otherwise how many of its RESULT lines say PASS."""
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError:
        return None
    s = [l.strip() for l in lines if l.startswith("SUMMARY ")]
    if s:
        return s[-1][len("SUMMARY "):]
    results = [l.strip() for l in lines if l.startswith("RESULT ")]
    if not results:
        return None
    passed = sum(1 for r in results if r.startswith("RESULT PASS"))
    return "%d of %d runs pass%s" % (passed, len(results), " (%s)" % results[0] if len(results) == 1 else "")


def mac_section(evidence):
    if not evidence:
        return (f"{MAC_BEGIN}\n### Mac check before publishing\n\n"
                "**Pending.** This release stays a draft until `tools/release/publish.sh <tag>` has run "
                "`tools/shot/run.sh <dist> gl strict` on a Mac (hardware-accelerated OpenGL, VideoToolbox) "
                "against the macOS archive attached here, attached its output as "
                f"`screenshot-check-macos.txt` and written the result into this section.\n{MAC_END}")
    text = open(evidence, encoding="utf-8").read()
    field = lambda k: (re.search(r"^%s: (.*)$" % re.escape(k), text, re.M) or [None, "?"])[1]
    # one line per case: "== <clip>, gl, hwdec=<asked>", "HWDEC <got>", "RESULT ..."
    cases, case = [], None
    for l in text.splitlines():
        if l.startswith("== "):
            case = [l[3:].strip(), "-", "?"]
            cases.append(case)
        elif case and l.startswith("HWDEC "):
            case[1] = l[6:].strip()
        elif case and l.startswith("RESULT "):
            case[2] = re.sub(r"\(gl, [^:]*: ", "(", l[7:].strip())
    result = summary(evidence)
    return "\n".join([
        MAC_BEGIN,
        "### Mac check before publishing",
        "",
        f"`tools/shot/run.sh <dist> gl strict` (tools/shot at `{field('tools')[:10]}`), on the macOS archive "
        f"attached here (sha256 `{field('archive_sha256')}`):",
        "",
        f"- **{result}**",
        f"- machine: {field('machine')}, macOS {field('macos')}; OpenGL renderer: {field('renderer')}",
        f"- run {field('date')}; full output: `screenshot-check-macos.txt`",
        "",
        "```",
        *["%s -> hwdec-current %s: %s" % tuple(c) for c in cases],
        "```",
        MAC_END,
    ])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dist")
    ap.add_argument("checks")
    ap.add_argument("--mac", help="evidence file written by publish.sh")
    ap.add_argument("--body", help="the current release body, whose Mac section is replaced")
    a = ap.parse_args()

    if a.body:
        body = open(a.body, encoding="utf-8").read()
        if MAC_BEGIN not in body or MAC_END not in body:
            sys.exit("notes.py: the release body has no Mac check section to fill in")
        head, rest = body.split(MAC_BEGIN, 1)
        tail = rest.split(MAC_END, 1)[1]
        sys.stdout.write(head + mac_section(a.mac) + tail)
        return

    m = json.load(open(os.path.join(a.dist, "manifest.json")))
    run_url = os.environ.get("RUN_URL", "")
    image = " ".join(x for x in (os.environ.get("ImageOS"), os.environ.get("ImageVersion")) if x) or "?"
    lines = [
        f"plynic-mpv `{m['mpv_commit'][:10]}` (`mpv-version` {m.get('mpv_version')}), FFmpeg "
        f"{m.get('ffmpeg_version')}; built with {m['toolchain'].get('xcode', '?')}"
        + (f" by [this CI run]({run_url})" if run_url else "") + ". "
        "What changed: README.md of this tag, section Releases. The macOS and iOS frameworks, their dSYMs, "
        "`manifest.json` and the corresponding source (`SOURCES.json`, `SHA256SUMS` and the archives) are "
        "attached.",
        "",
        f"### Checks CI ran on these frameworks (macOS slice, runner {image})",
        "",
        f"- release gates (`tools/manifest.py`): {'passed' if m['checks']['passed'] else 'FAILED'}",
    ]
    for name, cmd, what in CHECKS:
        lines.append(f"- `{cmd}` ({what}): {summary(os.path.join(a.checks, name + '.txt')) or 'not run'}")
    lines += ["", mac_section(None), ""]
    sys.stdout.write("\n".join(lines))


if __name__ == "__main__":
    main()
