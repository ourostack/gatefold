#!/usr/bin/env python3
"""CI only: does a change edit what orchestrates App's macOS jobs? (gatefold#630)

    python3 -I scripts/ci-orchestration.py <file with changed paths, one per line>   # prints "yes" or "no"
    python3 -I scripts/ci-orchestration.py --selftest

A pull request runs no macOS shard (app.yml's `native`), so a change to the workflow or the scripts that plan, retry,
shard and judge those jobs would first run on main, where a mistake turns main red. Such a change runs them on its
own pull request (fast-honest-ci 2.5: shared files run everything). An empty or unreadable list fails closed: "yes".
"""
import re
import sys

ORCHESTRATION = re.compile(
    r"^(\.github/(workflows/(app|ui-tests)\.yml|actions/.+|scripts/.+)|scripts/ci-[^/]+)$"
)


def touches(paths):
    paths = [p.strip() for p in paths if p.strip()]
    return not paths or any(ORCHESTRATION.match(p) for p in paths)


def selftest():
    bad = 0

    def check(ok, what):
        nonlocal bad
        if not ok:
            bad += 1
            print("FAIL:", what)

    check(touches([".github/workflows/app.yml"]), "app.yml")
    check(touches([".github/workflows/ui-tests.yml"]), "ui-tests.yml")
    check(touches(["README.md", "scripts/ci-retry.py"]), "a CI script among others")
    check(touches([".github/actions/await-build/action.yml"]), "a composite action")
    check(touches(["scripts/ci-shards.expect"]), "the shard lists")
    check(touches([]), "an empty list fails closed")
    check(not touches(["README.md", "docs/a.md", "Gatefold/Reader/ReaderPage.swift"]), "app code and docs")
    check(not touches([".github/workflows/panel.yml", "scripts/changelog.py"]), "other workflows and scripts")
    print("checks passed" if not bad else f"{bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    try:
        lines = open(sys.argv[1]).read().splitlines()
    except (IndexError, OSError):
        lines = []
    print("yes" if touches(lines) else "no")
