"""Prints why each failed test failed, from the result bundles, so a red job names its cause in its log.

The jobs' live logs keep only some lines, so a failure could be visible only in the .xcresult (gatefold#85).
An assertion's own text can quote the book, so it is withheld after "XCTAssert... failed", as in the live log.

    python3 -I scripts/ci-failures.py <bundle.xcresult>...   (bundles that do not exist are skipped)
"""
import json
import os
import re
import subprocess
import sys

ASSERT = re.compile(r"XCTAssert[A-Za-z]* failed")


def withhold(message):
    m = ASSERT.search(message)
    if m:
        return message[: m.end()] + " (text withheld)"
    return message[:300]


def failures(node, path=()):
    """Yields (test, message) for every failure message under a failed test case."""
    here = path + (node.get("name", ""),)
    if node.get("nodeType") == "Test Case" and node.get("result") == "Failed":
        messages = [c.get("name", "") for c in walk(node) if c.get("nodeType") == "Failure Message"]
        test = "/".join(here[-2:])
        for message in messages or ["(no failure message recorded)"]:
            yield test, message
        return
    for child in node.get("children", []):
        yield from failures(child, here)


def walk(node):
    for child in node.get("children", []):
        yield child
        yield from walk(child)


def main(paths):
    for path in paths:
        if not os.path.exists(path):
            continue
        out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", path],
                             capture_output=True, text=True)
        if out.returncode != 0:
            print(f"{os.path.basename(path)}: could not read the bundle ({out.stderr.strip()[:200]})")
            continue
        found = [f for n in json.loads(out.stdout).get("testNodes", []) for f in failures(n)]
        print(f"{os.path.basename(path)}: {len(found)} failure(s)")
        for test, message in found:
            print(f"::error title={test}::{withhold(message)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
