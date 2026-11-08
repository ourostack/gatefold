"""Prints why each failed test failed, from the result bundles, so a red job names its cause in its log.

The jobs' live logs keep only some lines, so a failure could be visible only in the .xcresult (gatefold#85).
A message can quote the book (an assertion's values, an element's label), so everything from "XCTAssert... failed",
or from the first quote, arrow or element attribute, is withheld. A test's own XCTFail text must never hold page words.

    python3 -I scripts/ci-failures.py <bundle.xcresult>...   (bundles that do not exist are skipped)
"""
import json
import os
import re
import subprocess
import sys

ASSERT = re.compile(r"XCTAssert[A-Za-z]* failed")


# Where an element's words or a compared value can begin: a quote, Swift Testing's arrow, or an element attribute.
VALUE = re.compile(r'["\u201c\u2192\n]|\b(label|value|title|placeholderValue|identifier)\b', re.I)


def withhold(message):
    m = ASSERT.search(message)
    if m:
        return message[: m.end()] + " (text withheld)"
    m = VALUE.search(message)
    if m:
        return message[: m.start()].rstrip() + " (text withheld)"
    return message[:300]


def escape(text, title=False):
    text = text.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    return text.replace(":", "%3A").replace(",", "%2C") if title else text


def failures(node, path=()):
    """Yields (test, message) for every failure message under a failed test case, and for every one outside any
    test case (a runner that crashed or lost its connection records its failure on the bundle or the plan)."""
    here = path + (node.get("name", ""),)
    if node.get("nodeType") == "Test Case":
        if node.get("result") == "Failed":
            messages = [c.get("name", "") for c in walk(node) if c.get("nodeType") == "Failure Message"]
            for message in messages or ["(no failure message recorded)"]:
                yield "/".join(here[-2:]), message
        return
    if node.get("nodeType") == "Failure Message":
        yield path[-1] if path else "(test run)", node.get("name", "")
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
        try:
            nodes = json.loads(out.stdout).get("testNodes", [])
        except ValueError:
            print(f"{os.path.basename(path)}: the bundle's results are not readable (cut short?)")
            continue
        found = [f for n in nodes for f in failures(n)]
        print(f"{os.path.basename(path)}: {len(found)} failure(s)")
        for test, message in found:
            print(f"::error title={escape(test, title=True)}::{escape(withhold(message))}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
