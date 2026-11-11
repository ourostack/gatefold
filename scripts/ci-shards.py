"""Checks the UI test shards' lists in app.yml against the tests in GatefoldUITests (gatefold#39).

    python3 -I scripts/ci-shards.py check [--list] [--expect FILE]
    python3 -I scripts/ci-shards.py write
    python3 -I scripts/ci-shards.py --selftest

Each shard job in app.yml (one that calls ui-tests.yml) lists `tests`, `skip` and `pr_tests` per matrix entry, under
GatefoldUITests: a class, or a class and a test. For each tier (`pr`: a pull request that runs the PR lists; `main`:
main and full-list pull requests) this fails when
  - an entry names no test in the sources (a renamed test would otherwise drop out of CI quietly),
  - a skipped test is not in its shard's `tests`, or runs in no other shard on that device on main,
  - a shard has no `tests` list (an empty list would run the whole suite), or a PR list with no `pr_when`,
  - one test runs in two shards on the same device in the same tier.
--list prints every "tier|device|test" with its shard. --expect FILE fails unless that set equals the file's (the first
word of each line; blank lines and lines starting with # ignored). CI checks against scripts/ci-shards.expect, so a
test leaves CI only by a visible edit there: after adding or removing a test, `write` rewrites the file from the shards
(keeping its comment header), and the diff shows what changed.
Reads only; no dependencies, so it runs in the Swift container of `GatefoldCore tests`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "app.yml")
SOURCES = os.path.join(ROOT, "GatefoldUITests")
TIERS = ("pr", "main")
EXPECT = os.path.join(ROOT, "scripts", "ci-shards.expect")
WRITE = "python3 -I scripts/ci-shards.py write"


def read_tests(sources_dir):
    """{class: [test, ...]} from the UI test sources: test methods of each XCTestCase subclass."""
    tests = {}
    for name in sorted(os.listdir(sources_dir)):
        if name.endswith(".swift"):
            with open(os.path.join(sources_dir, name), encoding="utf-8") as f:
                tests_in(f.read(), tests)
    return tests


def tests_in(text, tests):
    cls = None
    for line in text.splitlines():
        # A top-level type: an XCTestCase subclass starts a class; any other type or extension ends it.
        m = re.match(r"(?:(?:final|private|fileprivate|public|internal|open)\s+)*"
                     r"(class|struct|enum|extension|actor|protocol)\s+(\w+)\s*(:\s*XCTestCase\b)?", line)
        if m:
            cls = m.group(2) if m.group(1) == "class" and m.group(3) else None
            if cls:
                tests.setdefault(cls, [])
            continue
        m = re.match(r"\s*func\s+(test\w*)\s*\(", line)
        if m and cls:
            tests[cls].append(m.group(1))
    return tests


def jobs(text):
    """{job id: [lines]} for the top-level jobs."""
    out, job, inside = {}, None, False
    for line in text.splitlines():
        if line.startswith("jobs:"):
            inside = True
            continue
        if not inside:
            continue
        m = re.match(r"  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            job = m.group(1)
            out[job] = []
        elif job and (line.startswith("   ") or not line.strip()):
            out[job].append(line)
        elif line.strip() and not line.startswith(" "):
            break
    return out


def scalar(value):
    value = re.sub(r"\s+#.*$", "", value.strip())
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        value = value[1:-1]
    return value


def shards(text):
    """[(job, device, entry)] for every matrix entry of a job that calls ui-tests.yml."""
    found = []
    for job, lines in jobs(text).items():
        body = "\n".join(lines)
        if "uses: ./.github/workflows/ui-tests.yml" in body:
            device = re.search(r"^\s+device:\s*(.+)$", body, re.M)
            device = scalar(device.group(1)) if device else "?"
            for entry in matrix_entries(lines):
                found.append((job, device, entry))
    return found


def matrix_entries(lines):
    entries, entry, key, key_indent = [], None, None, 0
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        m = re.match(r"\s*- shard:\s*(.+)$", line)
        if m:
            entry = {"shard": scalar(m.group(1))}
            entries.append(entry)
            key, key_indent = None, indent + 2
            continue
        if entry is None:
            continue
        if indent < key_indent:
            entry, key = None, None
            continue
        if key is not None and indent > key_indent:
            entry[key] = (entry[key] + " " + stripped).strip()
            continue
        m = re.match(r"\s*([A-Za-z_]+):\s*(.*)$", line)
        if m and indent == key_indent:
            value = m.group(2)
            if value.strip() in (">-", ">", "|", "|-"):
                key = m.group(1)
                entry[key] = ""
            else:
                key = None
                entry[m.group(1)] = scalar(value)
    return entries


def expand(entries, tests, problems, where):
    names = set()
    for e in entries.split():
        cls, _, method = e.partition("/")
        if cls not in tests or (method and method not in tests[cls]) or (not method and not tests[cls]):
            problems.append(f"{where}: {e} names no test in GatefoldUITests")
            continue
        names |= {f"{cls}/{method}"} if method else {f"{cls}/{t}" for t in tests[cls]}
    return names


def plan(text, tests):
    """(problems, {(tier, device, test): [shard, ...]})"""
    problems, runs, seen, skips = [], {}, set(), []
    for job, device, s in shards(text):
        name = s.get("shard", "?")
        where = f"{job} shard {name}"
        if name in seen:
            problems.append(f"{where}: two shards have this name (their artifacts would collide)")
        seen.add(name)
        listed = expand(s.get("tests", ""), tests, problems, where + " tests")
        skipped = expand(s.get("skip", ""), tests, problems, where + " skip")
        for t in sorted(skipped - listed):
            problems.append(f"{where}: skips {t}, which it does not list")
        full = listed - skipped
        skips += [(where, device, t) for t in sorted(skipped & listed)]
        pr = s.get("pr_tests", "")
        if not s.get("tests", "").strip():
            problems.append(f"{where}: no tests listed (an empty list runs the whole suite)")
        if not pr:
            on_pr = full
        elif pr.strip() == "none":
            on_pr = set()
        else:
            on_pr = expand(pr, tests, problems, where + " pr_tests")
            if not s.get("pr_when", "").strip():
                problems.append(f"{where}: has pr_tests but no pr_when, so it never runs on a pull request")
        for tier, chosen in (("pr", on_pr), ("main", full)):
            for t in chosen:
                runs.setdefault((tier, device, t), []).append(name)
    # A catch-all's skip hands a test to another shard; it must run there, or it runs nowhere.
    for where, device, t in skips:
        if ("main", device, t) not in runs:
            problems.append(f"{where}: skips {t}, which no other shard runs on the {device} on main")
    for (tier, device, t), names in sorted(runs.items()):
        if len(names) > 1:
            problems.append(f"{tier}: {t} runs on the {device} in {len(names)} shards: {', '.join(names)}")
    return problems, runs


def check(args):
    with open(WORKFLOW, encoding="utf-8") as f:
        text = f.read()
    problems, runs = plan(text, read_tests(SOURCES))
    listed = []
    if "--list" in args:
        for (tier, device, t), names in sorted(runs.items()):
            print(f"{tier}|{device}|{t}\t{','.join(names)}")
    if "--expect" in args:
        with open(args[args.index("--expect") + 1], encoding="utf-8") as f:
            want = {l.split("\t")[0].strip() for l in f if l.strip() and not l.lstrip().startswith("#")}
        have = {f"{tier}|{device}|{t}" for tier, device, t in runs}
        listed += expect_problems(want, have)
    for tier in TIERS:
        devices = sorted({d for (ti, d, _) in runs if ti == tier})
        print(f"{tier}: " + "; ".join(
            f"{d} {sum(1 for (ti, dd, _) in runs if ti == tier and dd == d)} tests" for d in devices))
    for p in problems:
        print(f"::error title=UI test shards (.github/workflows/app.yml)::{p}")
    for p in listed:
        print(f"::error title=UI test list (scripts/ci-shards.expect)::{p}")
    if not problems and not listed:
        print("Every listed test exists, and each runs in exactly one shard per device and tier.")
    return 1 if problems or listed else 0


def expect_problems(want, have):
    """What differs between the expect file's set and the shards', each with the fix."""
    out = []
    for line in sorted(have - want):
        out.append(f"UI test {line} runs in CI but isn't in scripts/ci-shards.expect. If you added it, run `{WRITE}` "
                   "and commit the file.")
    for line in sorted(want - have):
        out.append(f"UI test {line} is in scripts/ci-shards.expect, but no shard runs it: was it renamed, removed or "
                   f"dropped from a shard's list in app.yml? If that's intended, run `{WRITE}` and commit the file.")
    return out


def write(path=EXPECT, workflow=WORKFLOW, sources=SOURCES):
    """Rewrite the expect file from the shards, keeping its leading comment lines."""
    with open(workflow, encoding="utf-8") as f:
        _, runs = plan(f.read(), read_tests(sources))
    header = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for l in f:
                if not l.lstrip().startswith("#"):
                    break
                header.append(l)
    lines = sorted(f"{tier}|{device}|{t}" for tier, device, t in runs)
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(header)
        f.write("".join(l + "\n" for l in lines))
    print(f"wrote {len(lines)} tests to {os.path.relpath(path, ROOT)}")
    return 0


def selftest():
    tests = tests_in("""
final class AUITests: XCTestCase {
    func testOne() {}
    func testTwo() throws {}
    private func helper() {}
}
final class BUITests: XCTestCase {
    func testThree() { checkTurns() }
}
enum Density {
    static func testLooksLikeATest() {}
}
extension XCUIApplication {
    func testNotATestEither() {}
}
""", {})
    assert tests == {"AUITests": ["testOne", "testTwo"], "BUITests": ["testThree"]}, tests

    def wf(entries, app=""):
        return f"""name: App
jobs:
  changes:
    runs-on: ubuntu-latest
  one:
    name: One (${{{{ matrix.shard }}}})
    strategy:
      matrix:
        include:
{entries}
    uses: ./.github/workflows/ui-tests.yml
    with:
      device: "iPad Pro 13-inch"
      shard: ${{{{ matrix.shard }}}}
{app}
  gate:
    runs-on: ubuntu-latest
"""

    ok = wf("""          # A comment between entries
          - shard: s1
            tests: >-
              AUITests/testOne
            timeout: 30 # with a comment
            skip: ""
            pr_tests: ""
            cold: false
          - shard: s2
            tests: >-
              AUITests
            skip: >-
              AUITests/testOne
            pr_tests: >-
              none
            timeout: 30
            cold: false
          - shard: s3
            tests: >-
              BUITests
            skip: ""
            pr_tests: ""
            timeout: 30
            cold: false""")
    found = shards(ok)
    assert [(j, d, s["shard"]) for j, d, s in found] == [
        ("one", "iPad Pro 13-inch", "s1"), ("one", "iPad Pro 13-inch", "s2"), ("one", "iPad Pro 13-inch", "s3")], found
    assert found[0][2]["tests"] == "AUITests/testOne" and found[0][2]["timeout"] == "30", found[0]
    problems, runs = plan(ok, tests)
    assert problems == [], problems
    assert runs[("main", "iPad Pro 13-inch", "AUITests/testTwo")] == ["s2"]
    assert ("pr", "iPad Pro 13-inch", "AUITests/testTwo") not in runs  # pr_tests: none
    assert runs[("pr", "iPad Pro 13-inch", "BUITests/testThree")] == ["s3"]
    # The catch-all skips AUITests/testOne; with s1 gone it runs nowhere.
    orphan = plan(ok.replace("""          - shard: s1
            tests: >-
              AUITests/testOne
""", """          - shard: s1
            tests: >-
              BUITests/testThree
"""), tests)[0]
    assert any("skips AUITests/testOne, which no other shard runs" in p for p in orphan), orphan

    def problems_of(entries):
        return plan(wf(entries), tests)[0]

    base = "            timeout: 30\n            cold: {cold}"
    dup = problems_of("""          - shard: s1
            tests: >-
              AUITests
""" + base.format(cold="false") + """
          - shard: s2
            tests: >-
              AUITests/testTwo
""" + base.format(cold="false"))
    assert any("AUITests/testTwo runs on the iPad Pro 13-inch in 2 shards: s1, s2" in p for p in dup), dup
    missing = problems_of("""          - shard: s1
            tests: >-
              AUITests/testGone CUITests
""" + base.format(cold="false"))
    assert sum("names no test" in p for p in missing) == 2, missing
    outside = problems_of("""          - shard: s1
            tests: >-
              AUITests/testOne
            skip: >-
              AUITests/testTwo
""" + base.format(cold="false"))
    assert any("skips AUITests/testTwo, which it does not list" in p for p in outside), outside
    # A cold (rotation) shard follows the tiers like any other: main only with pr_tests: none.
    cold = plan(wf("""          - shard: s1
            tests: >-
              AUITests
            pr_tests: >-
              none
""" + base.format(cold="true") + """
          - shard: s2
            tests: ""
""" + base.format(cold="false")), tests)
    assert ("pr", "iPad Pro 13-inch", "AUITests/testOne") not in cold[1], cold[1]
    assert cold[1][("main", "iPad Pro 13-inch", "AUITests/testOne")] == ["s1"], cold[1]
    assert any("s2" in p and "no tests listed" in p for p in cold[0]), cold[0]
    same_name = problems_of("""          - shard: s1
            tests: AUITests
""" + base.format(cold="false") + """
          - shard: s1
            tests: BUITests
""" + base.format(cold="false"))
    assert any("two shards have this name" in p for p in same_name), same_name
    # A new test, and one that went: each message names the test and the command that fixes the file (#195 read a
    # missing line as a unit-test failure).
    new, gone = expect_problems({"main|d|A/t1", "main|d|A/gone"}, {"main|d|A/t1", "main|d|A/added"})
    assert "main|d|A/added runs in CI but isn't in scripts/ci-shards.expect" in new and WRITE in new, new
    assert "main|d|A/gone is in scripts/ci-shards.expect, but no shard runs it" in gone and WRITE in gone, gone
    assert expect_problems({"x"}, {"x"}) == []
    print("ci-shards selftest: ok")
    return 0


if __name__ == "__main__":
    args = sys.argv[1:]
    if args[:1] == ["--selftest"]:
        sys.exit(selftest())
    if args[:1] == ["check"]:
        sys.exit(check(args[1:]))
    if args[:1] == ["write"]:
        sys.exit(write())
    print(__doc__, file=sys.stderr)
    sys.exit(2)
