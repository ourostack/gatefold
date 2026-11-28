#!/usr/bin/env python3
"""CI only: does a change edit what orchestrates App's macOS jobs? (gatefold#630)

    python3 -I scripts/ci-orchestration.py <file with changed paths, one per line>   # prints "yes" or "no"
    python3 -I scripts/ci-orchestration.py --selftest

A pull request runs no macOS shard (app.yml's `native`), so a change to the workflow or the scripts that plan, retry,
shard and judge those jobs would first run on main, where a mistake turns main red. Such a change runs them on its
own pull request (fast-honest-ci 2.5: shared files run everything). An empty or unreadable list fails closed: "yes".

    python3 -I scripts/ci-orchestration.py <changed paths file> --base <rev> --head <rev>

With the pull request's base and head, a change to the UI shard lists alone is a test change, not orchestration
(gatefold#639): adding a test class to a shard's `tests`, `skip` or `pr_tests` in app.yml, its `pr_when` (one of the
changes job's groups), its `timeout`, the comments
among the matrix entries, and the data files scripts/ci-shards.expect, .times and .unrun. Such a pull
request runs no macOS shard, like any app change: `CI scripts, offline` runs scripts/ci-shards.py check on it (every
listed test exists, each runs in one shard per device, every UI test runs on main or is in scripts/ci-shards.unrun,
and the timeouts follow the times file), and the class runs in its shard on main. Anything else in app.yml is
orchestration: a step, a job, a shard added, removed or renamed, a lane, `cold`, the caller's inputs, a list, group or
timeout that isn't plain names, a known group or digits. app.yml is read at the merge base of base and head (the diff's own
range) and at head; a side git can't read fails closed.
"""
import re
import subprocess
import sys

ORCHESTRATION = re.compile(
    r"^(\.github/(workflows/(app|ui-tests)\.yml|actions/.+|scripts/.+)|scripts/ci-[^/]+)$"
)


APP = ".github/workflows/app.yml"
# Data, not orchestration: scripts/ci-shards.py check judges both on the pull request.
DATA = {"scripts/ci-shards.expect", "scripts/ci-shards.times", "scripts/ci-shards.unrun"}
LISTS = {"tests", "skip", "pr_tests"}
# The groups the changes job writes to `fired`; a shard's `pr_when` names one. A new group is a step change, so
# orchestration.
GROUPS = {"smoke", "place-undo", "place-jumps", "taps"}
NAMES = re.compile(r"^[A-Za-z0-9_/ ]*$")  # class or Class/test names, "none", or nothing


class NotLists(Exception):
    pass


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def normalized(text):
    """app.yml without each UI shard's lists (`tests`, `skip`, `pr_tests`), `pr_when`, `timeout` and the comments
    among the matrix entries, so two versions that differ in those alone compare equal; scripts/ci-shards.py check
    judges what they hold. A list that isn't plain names, a `pr_when` that isn't one of GROUPS or a timeout that isn't
    digits raises NotLists."""
    out, chunk = [], []

    def flush():
        body = "\n".join(chunk)
        out.extend(entries(chunk) if "uses: ./.github/workflows/ui-tests.yml" in body else chunk)
        chunk.clear()

    inside = False
    for line in text.splitlines():
        if line.startswith("jobs:"):
            flush()
            inside = True
            out.append(line)
            continue
        if inside and re.match(r"  [A-Za-z0-9_-]+:\s*$", line):
            flush()
        chunk.append(line)
    flush()
    return "\n".join(out)


def entries(lines):
    """A shard job's lines with its matrix `include:` entries normalized (see normalized)."""
    out, region, key_indent, folding = [], None, None, None
    for line in lines:
        stripped, indent = line.strip(), len(line) - len(line.lstrip())
        if folding is not None:
            key, words, at = folding
            if not stripped or indent > at:
                words.append(stripped)
                continue
            names(" ".join(words))
            folding = None
        if region is None:
            out.append(line)
            if re.match(r"\s*include:\s*$", line):
                region = indent
            continue
        if not stripped or stripped.startswith("#"):
            continue  # a blank line or a comment among the entries
        if indent <= region:
            region = None
            out.append(line)
            continue
        m = re.match(r"(\s*)- shard:\s*(.+)$", line)
        if m:
            key_indent = indent + 2
            shard = unquote(re.sub(r"\s+#.*$", "", m.group(2)))
            out.append(f"{m.group(1)}- shard: {shard}")
            continue
        m = re.match(r"\s*([A-Za-z_]+):\s*(.*)$", line)
        if m and indent == key_indent and m.group(1) in LISTS:
            value = m.group(2).strip()
            if value in (">-", ">", "|", "|-"):
                folding = (m.group(1), [], indent)
            else:
                names(unquote(value))
            continue
        if m and indent == key_indent and m.group(1) == "pr_when":
            if unquote(re.sub(r"\s+#.*$", "", m.group(2))) not in GROUPS:
                raise NotLists(f"pr_when {m.group(2).strip()}")
            continue
        if m and indent == key_indent and m.group(1) == "timeout":
            if not re.fullmatch(r"\d+(\s+#.*)?", m.group(2).strip()):
                raise NotLists(f"timeout {m.group(2).strip()}")
            continue
        out.append(line)
    if folding is not None:  # a folded list that ends the job
        names(" ".join(folding[1]))
    return out


def names(value):
    if not NAMES.match(value):
        raise NotLists(value)


def lists_only(base, head):
    """Do these two versions of app.yml differ only in the UI shard lists (see normalized)?"""
    if base is None or head is None:
        return False
    try:
        return normalized(base) == normalized(head)
    except NotLists:
        return False


def touches(paths, read=None):
    """Does this change edit what orchestrates the macOS jobs? `read(path, side)` gives a file's text at "base" or
    "head" (None when it can't); without it, app.yml and the data files count, as before."""
    paths = [p.strip() for p in paths if p.strip()]
    if not paths:
        return True
    for p in paths:
        if not ORCHESTRATION.match(p):
            continue
        if read is not None and p in DATA:
            continue
        if read is not None and p == APP and lists_only(read(p, "base"), read(p, "head")):
            continue
        return True
    return False


def git_reader(base, head):
    """read(path, side) from git: base is the merge base of base and head, as the pull request's diff is."""
    def git(*args):
        return subprocess.run(["git", *args], capture_output=True, text=True, check=True).stdout

    try:
        revs = {"base": git("merge-base", base, head).strip(), "head": head}
    except (OSError, subprocess.CalledProcessError):
        return lambda path, side: None

    def read(path, side):
        try:
            return git("show", f"{revs[side]}:{path}")
        except Exception:  # noqa: BLE001 - anything unreadable (not UTF-8 too) fails closed
            return None
    return read


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

    # Only the shard lists (gatefold#639: a new UI test class in a shard's `tests`, its timeout and the two data files
    # ran every macOS shard on the pull request, 17 full runs and 9,928 macOS min in one day). With both sides of
    # app.yml readable, a change to the lists alone is a test change, not orchestration.
    base = """name: App
jobs:
  changes:
    runs-on: ubuntu-latest
    steps:
      - run: |
          # a shell comment
          echo plan
  one:
    name: One (${{ matrix.shard }})
    needs: changes
    strategy:
      matrix:
        include:
          # Slowest first
          - shard: s1
            # 120 + 60
            tests: >-
              AUITests/testOne
              BUITests
            skip: ""
            pr_tests: none
            pr_when: smoke
            cold: false
            timeout: 54 # 30 + 2 x 3.0 + 5 + 12
            lane: 3
          - shard: s2
            tests: CUITests
            pr_tests: >-
              CUITests/testOne
            timeout: 50 # 30 + 2 x 1.0 + 5 + 12
            lane: 4
    uses: ./.github/workflows/ui-tests.yml
    with:
      device: "iPad Pro 13-inch"
      tests: ${{ matrix.tests }}
      timeout: ${{ matrix.timeout }}
"""
    app = ".github/workflows/app.yml"
    data = ["scripts/ci-shards.expect", "scripts/ci-shards.times"]

    def sides(head, before=base):
        return lambda path, side: {"base": before, "head": head}[side] if path == app else ""

    added = base.replace("              BUITests\n", "              BUITests NewUITests\n").replace(
        "# 120 + 60", "# 120 + 60, and about 90 for the new class").replace(
        "timeout: 54 # 30 + 2 x 3.0 + 5 + 12", "timeout: 57 # 30 + 2 x 4.5 + 5 + 12").replace(
        "          # Slowest first\n", "")
    check(lists_only(base, added), "a class added to a list, its timeout and comments: lists only")
    check(not touches([app] + data + ["GatefoldUITests/NewUITests.swift"], sides(added)),
          "a new class in a shard's list with the two data files runs no macOS shard")
    check(not touches(data, sides(base)), "the expect and times files alone are data")
    check(not touches(["scripts/ci-shards.unrun"], sides(base)), "the tests CI doesn't run, and why, are data")
    moved = base.replace("              BUITests\n", "").replace("tests: CUITests", "tests: CUITests BUITests")
    check(lists_only(base, moved), "a class moved between shards: lists only (ci-shards.py check judges it)")
    pr = base.replace("pr_tests: none", "pr_tests: AUITests/testOne")
    check(lists_only(base, pr), "a PR list: lists only")
    # gatefold#661: a PR list and its group added to a shard that had neither.
    grouped = base.replace("            timeout: 50 #", "            pr_when: place-jumps\n            timeout: 50 #")
    check(lists_only(base, grouped), "a shard's pr_when, one of the changes job's groups: lists only")
    check(lists_only(base, base.replace("pr_when: smoke", "pr_when: taps")), "a pr_when moved to another group")
    check(lists_only(base, base.replace("            skip: \"\"\n", "")), "an empty skip dropped")
    for what, edit in (
            ("a lane", ("lane: 3", "lane: 5")),
            ("a pr_when no group fires", ("pr_when: smoke", "pr_when: bogus")),
            ("a pr_when expression", ("pr_when: smoke", "pr_when: ${{ inputs.g }}")),
            ("cold", ("cold: false", "cold: true")),
            ("a new shard", ("          - shard: s2\n", "          - shard: s3\n            tests: DUITests\n"
                                                     "            timeout: 50\n            lane: 9\n"
                                                     "          - shard: s2\n")),
            ("a renamed shard", ("shard: s2", "shard: s2b")),
            ("a list's key", ("            skip: \"\"\n", "            skips: \"\"\n")),
            ("a list made an expression", ("tests: CUITests", "tests: ${{ needs.changes.outputs.x }}")),
            ("a timeout made an expression", ("timeout: 54 #", "timeout: ${{ 54 }} #")),
            ("a step", ("echo plan", "echo plan2")),
            ("a shell comment", ("# a shell comment", "# another")),
            ("the caller's inputs", ("device: \"iPad Pro 13-inch\"", "device: \"iPhone Duo\"")),
            ("the called workflow", ("ui-tests.yml\n", "ui-tests2.yml\n")),
            ("a needs", ("    needs: changes\n    strategy", "    needs: [changes, core]\n    strategy")),
    ):
        changed = base.replace(*edit)
        check(changed != base, f"the fixture has {what}")
        check(not lists_only(base, changed), f"{what} is orchestration")
        check(touches([app], sides(changed)), f"{what} runs the macOS jobs")
    check(touches([app] + data, sides(added, None)), "an unreadable base fails closed")
    check(touches([app], lambda path, side: None), "an unreadable app.yml fails closed")
    check(touches(["scripts/ci-shards.times", "scripts/ci-shards.py"], sides(base)), "the shard script is orchestration")
    check(touches([app, ".github/workflows/ui-tests.yml"], sides(added)), "the shard workflow beside a list change")
    check(touches([], sides(base)), "an empty list still fails closed")
    # Trailing spaces outside the lists are behaviour: after a `\` in a run block, the space ends the line continuation.
    check(not lists_only(base, base.replace("echo plan", "echo plan \\ ")),
          "a trailing space in a run block is orchestration")
    check(not lists_only(base, base.replace("          # a shell comment", "          # a shell comment ")),
          "any trailing space outside the matrix entries is orchestration")
    # A folded list that ends its job is judged too.
    tail = base.replace("    uses: ./.github/workflows/ui-tests.yml\n    with:\n      device: \"iPad Pro 13-inch\"\n"
                        "      tests: ${{ matrix.tests }}\n      timeout: ${{ matrix.timeout }}\n", "")
    last = tail.replace("    strategy:", "    uses: ./.github/workflows/ui-tests.yml\n    strategy:").replace(
        "            pr_tests: >-\n              CUITests/testOne\n            timeout: 50 # 30 + 2 x 1.0 + 5 + 12\n            lane: 4\n",
        "            timeout: 50 # 30 + 2 x 1.0 + 5 + 12\n            lane: 4\n            pr_tests: >-\n              CUITests/testOne\n")
    check(last.rstrip().endswith("CUITests/testOne"), "the fixture ends its job with a folded list")
    check(last != tail and lists_only(last, last.replace("CUITests/testOne", "CUITests/testTwo")),
          "a folded list at the end of a job: lists only")
    check(not lists_only(last, last.replace("              CUITests/testOne", "              ${{ github.event.pull_request.title }}")),
          "an expression in a folded list at the end of a job is orchestration")
    print("checks passed" if not bad else f"{bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    args = sys.argv[1:]
    read = None
    if "--base" in args and "--head" in args:
        try:
            read = git_reader(args[args.index("--base") + 1], args[args.index("--head") + 1])
        except IndexError:
            read = lambda path, side: None  # noqa: E731
    try:
        lines = open(args[0]).read().splitlines()
    except (IndexError, OSError):
        lines = []
    print("yes" if touches(lines, read) else "no")
