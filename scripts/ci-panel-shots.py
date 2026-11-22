"""Names the screenshots `xcrun xcresulttool export attachments` wrote, for the review panel (.github/workflows/panel.yml).

    python3 -I scripts/ci-panel-shots.py <exported dir> <out dir> <prefix> [<expected screenshots>]
    python3 -I scripts/ci-panel-shots.py --selftest

The export writes each attachment under a generated file name and lists it in manifest.json with the name the test
gave it, plus "_<n>_<UUID>" before the extension. This copies each to <out dir>/<prefix>-<its name><extension>, so
PanelCaptureUITests' "light-01-library" lands as duo-light-01-library.png. A name seen twice gets -2, -3 and so on.
Fails when the manifest is missing or lists nothing, or, given <expected screenshots>, when it holds fewer PNGs than
that (a failure's own attachments and screen recordings aside): a walk that stopped early, or whose shots never reached
the result bundle, never uploads as if it were the panel (the Duo's set in run 45062075206 held its first shot only).
"""
import json
import os
import re
import shutil
import sys
import tempfile

SUFFIX = re.compile(r"_\d+_[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")


def attachments(node):
    """Every {exportedFileName, suggestedHumanReadableName} in the manifest, in order."""
    if isinstance(node, dict):
        if "exportedFileName" in node:
            yield node
        for value in node.values():
            yield from attachments(value)
    elif isinstance(node, list):
        for value in node:
            yield from attachments(value)


def clean(name):
    stem, ext = os.path.splitext(name)
    stem = SUFFIX.sub("", stem)
    stem = re.sub(r"[^A-Za-z0-9._-]+", "-", stem).strip("-") or "shot"
    return stem, ext or ".png"


def shots(names):
    """The walk's own screenshots among the written names."""
    return [n for n in names if n.endswith(".png") and "-failure-" not in n]


def name_all(src, out, prefix):
    with open(os.path.join(src, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    os.makedirs(out, exist_ok=True)
    seen, written = {}, []
    for a in attachments(manifest):
        stem, ext = clean(a.get("suggestedHumanReadableName") or a["exportedFileName"])
        if a.get("isAssociatedWithFailure"):
            stem = f"failure-{stem}"
        key = f"{prefix}-{stem}"
        seen[key] = seen.get(key, 0) + 1
        target = f"{key}{'' if seen[key] == 1 else f'-{seen[key]}'}{ext}"
        shutil.copyfile(os.path.join(src, os.path.basename(a["exportedFileName"])), os.path.join(out, target))
        written.append(target)
    if not written:
        raise SystemExit(f"::error::{src}/manifest.json lists no attachments")
    return written


def selftest():
    with tempfile.TemporaryDirectory() as tmp:
        src, out = os.path.join(tmp, "src"), os.path.join(tmp, "out")
        os.makedirs(src)
        uuid = "0A1B2C3D-0000-4000-8000-0123456789AB"
        manifest = [{"testIdentifier": "PanelCaptureUITests/testCapture()", "attachments": [
            {"exportedFileName": "a.png", "suggestedHumanReadableName": f"light-01-library_0_{uuid}.png"},
            {"exportedFileName": "b.png", "suggestedHumanReadableName": f"light-01-library_1_{uuid}.png"},
            {"exportedFileName": "c.png", "suggestedHumanReadableName": "odd name/here.png",
             "isAssociatedWithFailure": True},
        ]}]
        for n in ("a.png", "b.png", "c.png"):
            with open(os.path.join(src, n), "w") as f:
                f.write(n)
        with open(os.path.join(src, "manifest.json"), "w") as f:
            json.dump(manifest, f)
        got = name_all(src, out, "duo")
        assert got == ["duo-light-01-library.png", "duo-light-01-library-2.png", "duo-failure-odd-name-here.png"], got
        assert shots(got + ["duo-Screen-Recording.mp4"]) == got[:2], shots(got)
        assert main(["x", src, out, "duo", "2"]) == 0
        assert main(["x", src, out, "duo", "3"]) == 1
        with open(os.path.join(out, "duo-light-01-library-2.png")) as f:
            assert f.read() == "b.png"
        with open(os.path.join(src, "manifest.json"), "w") as f:
            json.dump([], f)
        try:
            name_all(src, out, "duo")
            raise AssertionError("an empty manifest passed")
        except SystemExit:
            pass
    print("ci-panel-shots selftest passed")


def main(argv):
    if argv[1:] == ["--selftest"]:
        selftest()
        return 0
    if len(argv) not in (4, 5):
        print(__doc__, file=sys.stderr)
        return 2
    names = name_all(argv[1], argv[2], argv[3])
    for name in names:
        print(name)
    if len(argv) == 5 and len(shots(names)) < int(argv[4]):
        print(f"::error::{argv[1]} holds {len(shots(names))} screenshots, not the walk's {argv[4]}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
