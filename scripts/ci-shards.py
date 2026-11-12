"""Checks the UI test shards' lists in app.yml against the tests in GatefoldUITests (gatefold#39).

    python3 -I scripts/ci-shards.py check [--list] [--expect FILE]
    python3 -I scripts/ci-shards.py write
    python3 -I scripts/ci-shards.py smoke DEVICE [CLASS ...]
    python3 -I scripts/ci-shards.py --selftest

Each shard job in app.yml (one that calls ui-tests.yml) lists `tests`, `skip` and `pr_tests` per matrix entry, under
GatefoldUITests: a class, or a class and a test. For each tier (`pr`: a pull request that runs the PR lists; `main`:
main and full-list pull requests) this fails when
  - an entry names no test in the sources (a renamed test would otherwise drop out of CI quietly),
  - a skipped test is not in its shard's `tests`, or runs in no other shard on that device on main,
  - a shard has no `tests` list (an empty list would run the whole suite), or a PR list with no `pr_when`,
  - one test runs in two shards on the same device in the same tier,
  - a shard's `timeout` is under `<setup> + 2 x <slowest> + 5 + 12` rounded up, or its comment doesn't show that sum:
    <setup> is the `boot` ui-tests.yml gives the time-left action (gatefold#198), <slowest> the minutes its tests'
    slowest passes add up to in scripts/ci-shards.times, for whichever of its two lists (main or PR) runs longer, and
    5 the test step's minutes no test gets (LAUNCH below; gatefold#260),
  - a test that a shard runs has no slowest pass in scripts/ci-shards.times, or a line there names no test CI runs.
--list prints every "tier|device|test" with its shard. --expect FILE fails unless that set equals the file's (the first
word of each line; blank lines and lines starting with # ignored). CI checks against scripts/ci-shards.expect, so a
test leaves CI only by a visible edit there: after adding or removing a test, `write` rewrites the file from the shards
(keeping its comment header), and the diff shows what changed.
`smoke` prints the job limit for DEVICE's smoke shard when a pull request also runs the UI test classes it edits there:
the same formula over the smoke PR list and those classes (the changes job passes it on; gatefold#260).
Reads only; no dependencies beyond python3. It runs in the job `CI scripts, offline`, which `GatefoldCore tests` (a
required check) stands for (gatefold#241).
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "app.yml")
SHARD = os.path.join(ROOT, ".github", "workflows", "ui-tests.yml")
RESERVE = 12  # the time-left action's default, kept for the logs after the tests
# Minutes of the test step that no test gets (gatefold#260): ci-within.py stops the run 2 min before the step's end
# (its GRACE), and xcodebuild takes up to 3 min more to start the first test and end the run (159 s at the 99th
# percentile of 4008 green test steps, 2026-11-08 to 11-12).
LAUNCH = 5
TIMES_NAME = "scripts/ci-shards.times"
TIMES = os.path.join(ROOT, TIMES_NAME)
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
                note = re.search(r"\s#\s*(.*)$", value)
                if note:
                    entry["#" + m.group(1)] = note.group(1).strip()
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


def plan(text, tests, lists=None):
    """(problems, {(tier, device, test): [shard, ...]}). Given a list, `lists` also gets each shard's
    (job, device, entry, {tier: tests})."""
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
        if lists is not None:
            lists.append((job, device, s, {"pr": on_pr, "main": full}))
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


def boot_of(shard_text):
    """The `boot` minutes ui-tests.yml gives the time-left action, or None."""
    m = re.search(r"^\s+boot:\s*\"?(\d+)\"?", shard_text, re.M)
    return int(m.group(1)) if m else None


def read_times(path):
    with open(path, encoding="utf-8") as f:
        return read_times_text(f.read())


def read_times_text(text):
    """({"device|Class/test": seconds}, problems) from the times file: `device|Class/test<TAB>seconds`, then notes."""
    times, problems = {}, []
    for n, line in enumerate(text.splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) < 2 or not re.fullmatch(r"\d+", cols[1].strip()) or "|" not in cols[0]:
            problems.append(f"line {n} should read `device|Class/test<TAB>seconds`: {line.strip()}")
            continue
        if cols[0].strip() in times:
            problems.append(f"line {n}: {cols[0].strip()} is listed twice")
        times[cols[0].strip()] = int(cols[1])
    return times, problems


def tenths_up(seconds):
    """Seconds as minutes, rounded up to a tenth."""
    return -(-seconds // 6) / 10


def minutes_for(seconds, boot):
    """(job limit, its formula) for tests whose slowest passes add up to `seconds`."""
    slowest = tenths_up(seconds)
    return boot + -(-int(round(2 * slowest * 10)) // 10) + LAUNCH + RESERVE, f"{boot} + 2 x {slowest:.1f} + {LAUNCH} + {RESERVE}"


def limit_problems(lists, boot, times):
    """Each shard's `timeout` against `boot + 2 x <slowest> + LAUNCH + 12`, its comment showing the sum, with <slowest> the
    sum of its tests' slowest passes in the times file for the tier that runs longer (gatefold#198, gatefold#260). A
    limit may sit a minute over its need, no more: a hang should fail as soon as a green run can't still be running."""
    if boot is None:
        return ["ui-tests.yml gives the time-left action no `boot`, so no shard's tests' budget can be checked"]
    out, missing, used = [], set(), set()
    for job, device, s, tiers in lists:
        where = f"{job} shard {s.get('shard', '?')}"
        sums, unknown = {}, set()
        for tier, chosen in tiers.items():
            keys = {f"{device}|{t}" for t in chosen}
            used |= keys
            unknown |= keys - set(times)
            sums[tier] = sum(times.get(k, 0) for k in keys)
        missing |= unknown
        if unknown:
            continue  # its sum isn't known yet; the missing lines below say what to add, then rerun for this shard
        tier = max(sums, key=lambda k: (sums[k], k == "main"))
        need, want = minutes_for(sums[tier], boot)
        note = s.get("#timeout", "")
        timeout = int(s["timeout"]) if s.get("timeout", "").isdigit() else None
        if re.sub(r"\s+", " ", note.strip()) != want or timeout is None or not need <= timeout <= need + 1:
            out.append(f"{where}: its timeout should read `{need} # {want}`: {boot} for setup, twice its {tier} list's "
                       f"slowest passes ({sums[tier]} s in {TIMES_NAME}), {LAUNCH} for the test run's start and its stop's "
                       f"grace, {RESERVE} for the logs; it reads {s.get('timeout', '?')} # {note or '(no formula)'}")
    for k in sorted(missing):
        out.append(f"{k} has no slowest pass in {TIMES_NAME}, so its shard's limit can't be checked: add a line "
                   f"`{k}<TAB><seconds>`, its slowest passing time in CI (an estimate until CI has run it), then rerun "
                   "this check for its shard's timeout line")
    for k in sorted(set(times) - used):
        out.append(f"{k} is in {TIMES_NAME}, but no shard runs it: remove its line")
    return out


# A test the times file doesn't have on this device (a new class, or one main runs only on the other device): the
# other device's time, else this.
UNKNOWN_SECONDS = 600


def smoke_limit(text, tests, times, boot, device, classes):
    """The job limit for `device`'s smoke shard when it also runs `classes` (a pull request that edits them)."""
    lists = []
    plan(text, tests, lists)
    chosen = set()
    for _, d, s, tiers in lists:
        if d == device and s.get("pr_when") == "smoke":
            chosen |= tiers["pr"]
    for c in classes:
        chosen |= {f"{c}/{t}" for t in tests.get(c, [])}

    def seconds(t):
        if f"{device}|{t}" in times:
            return times[f"{device}|{t}"]
        return max((v for k, v in times.items() if k.split("|", 1)[1] == t), default=UNKNOWN_SECONDS)
    return minutes_for(sum(seconds(t) for t in chosen), boot)


def smoke(args):
    """`smoke DEVICE [CLASS ...]`: print the smoke shard's job limit in minutes, then its formula."""
    with open(WORKFLOW, encoding="utf-8") as f:
        text = f.read()
    with open(SHARD, encoding="utf-8") as f:
        boot = boot_of(f.read())
    need, want = smoke_limit(text, read_tests(SOURCES), read_times(TIMES)[0], boot, args[0], args[1:])
    print(need)
    print(f"{need} # {want}", file=sys.stderr)
    return 0


def check(args):
    with open(WORKFLOW, encoding="utf-8") as f:
        text = f.read()
    lists = []
    problems, runs = plan(text, read_tests(SOURCES), lists)
    times, bad = read_times(TIMES)
    problems += [f"{TIMES_NAME} {p}" for p in bad]
    with open(SHARD, encoding="utf-8") as f:
        problems += limit_problems(lists, boot_of(f.read()), times)
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
        problems, runs = plan(f.read(), read_tests(sources))
    if problems:
        # A broken entry drops its tests from the set, so writing now would quietly drop them from the file too.
        for p in problems:
            print(f"::error title=UI test shards (.github/workflows/app.yml)::{p}")
        print("Fix the shards first; scripts/ci-shards.expect is unchanged.")
        return 1
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
    # The limit: the boot's minutes, twice the slowest passes rounded up, the run's start and stop, and the reserve
    # (gatefold#198), the slowest summed from the times file over the tier that runs longer (gatefold#260).
    assert boot_of('      - uses: ./.github/actions/time-left\n        with:\n          boot: "30" # x\n') == 30
    assert boot_of("no boot here") is None
    ipad = "iPad Pro 13-inch|"
    times = {ipad + "AUITests/testOne": 120, ipad + "AUITests/testTwo": 228, ipad + "BUITests/testThree": 300}

    def limits(timeout, entry="            tests: AUITests\n", known=times):
        lists = []
        problems = plan(wf(f"""          - shard: s1
{entry}            timeout: {timeout}
            cold: false
          - shard: s2
            tests: BUITests
            timeout: {need(5.0)} # 30 + 2 x 5.0 + {LAUNCH} + 12
            cold: false"""), tests, lists)[0]
        assert problems == [], problems
        return limit_problems(lists, 30, known)

    def need(slowest):
        return 30 + -(-int(round(2 * slowest * 10)) // 10) + LAUNCH + 12

    # 120 + 228 s is 5.8 min, twice that 11.6, rounded up to 12.
    ok = f"{need(5.8)} # 30 + 2 x 5.8 + {LAUNCH} + 12"
    assert need(5.8) == 54 + LAUNCH and limits(ok) == [], limits(ok)
    assert limits(f"{need(5.8) + 1} # 30 + 2 x 5.8 + {LAUNCH} + 12") == []  # a minute over, as some shards kept
    short = limits(f"{need(5.8) - 1} # 30 + 2 x 5.8 + {LAUNCH} + 12")
    assert any(f"should read `{need(5.8)} #" in p for p in short), short
    # A sum that isn't the times file's, an old formula, or none: each names the line to write.
    for wrong in (f"{need(5.8)} # 30 + 2 x 4.8 + {LAUNCH} + 12", "54 # 30 + 2 x 5.8 + 12", "54"):
        got = limits(wrong)
        assert any(f"should read `{need(5.8)} # 30 + 2 x 5.8 + {LAUNCH} + 12`" in p for p in got), (wrong, got)
    # A PR list that runs longer than the full list sizes the limit (gatefold#260: ipad-undo-edge's 4.8 min of main
    # tests, but 339 s of PR tests): here testTwo's 228 s, 3.8 min, against testOne's 2.0.
    heavy = ("            tests: AUITests/testOne\n            pr_tests: AUITests/testTwo\n            pr_when: g\n")
    got = limits(f"{need(2.0)} # 30 + 2 x 2.0 + {LAUNCH} + 12", heavy)
    assert any("twice its pr list's slowest passes (228 s" in p for p in got), got
    assert limits(f"{need(3.8)} # 30 + 2 x 3.8 + {LAUNCH} + 12", heavy) == []
    # A catch-all grows with its class: a test the times file doesn't know, or one it knows that no shard runs, fails.
    unknown = limits(ok, known={k: v for k, v in times.items() if not k.endswith("testTwo")})
    assert any("AUITests/testTwo has no slowest pass" in p for p in unknown), unknown
    stale = limits(ok, known=dict(times, **{ipad + "AUITests/testGone": 60}))
    assert any("AUITests/testGone is in scripts/ci-shards.times, but no shard runs it" in p for p in stale), stale
    assert read_times_text("iPad|A/t\t60\tnote\n# c\n\nbad line\n") == ({"iPad|A/t": 60}, ["line 4 should read "
                                                                                     "`device|Class/test<TAB>seconds`: bad line"])
    over = limits(f"{need(5.8) + 2} # 30 + 2 x 5.8 + {LAUNCH} + 12")  # more than a minute over: a hang waits longer
    assert any(f"should read `{need(5.8)} #" in p for p in over), over
    # Rounding up to a tenth: 120 + 229 s is 5.817 min, so 5.9.
    assert limits(f"{need(5.9)} # 30 + 2 x 5.9 + {LAUNCH} + 12", known=dict(times, **{ipad + "AUITests/testTwo": 229})) == []
    # A skipped test is out of its shard's sum: the sums are over plan()'s lists, its `tests` less its `skip`.
    lists = []
    plan(wf("""          - shard: s1
            tests: AUITests
            skip: AUITests/testTwo
          - shard: s2
            tests: AUITests/testTwo BUITests"""), tests, lists)
    assert lists[0][3]["main"] == {"AUITests/testOne"}, lists
    # A tie between the lists names the main list.
    tie = "            tests: AUITests/testOne\n            pr_tests: AUITests/testOne\n            pr_when: g\n"
    got = limits("1 # x", tie)
    assert any("twice its main list's slowest passes (120 s" in p for p in got), got
    # A shard with a test the times file lacks isn't sized until it has the line, so the fix takes one round.
    assert not any("s1: its timeout" in p for p in unknown), unknown
    assert any("listed twice" in p for p in read_times_text("d|A/t\t1\nd|A/t\t2\n")[1])
    # The smoke shard with edited classes: its PR list plus every test of each class, a time from the other device
    # when this one has none, else UNKNOWN_SECONDS.
    smokewf = wf(f"""          - shard: s1
            tests: AUITests/testOne
            pr_tests: BUITests/testThree
            pr_when: smoke
            timeout: 1
            cold: false""")
    duo = dict(times, **{"iPhone Duo|AUITests/testTwo": 60})
    assert smoke_limit(smokewf, tests, times, 30, "iPad Pro 13-inch", [])[0] == need(5.0)
    assert smoke_limit(smokewf, tests, times, 30, "iPad Pro 13-inch", ["AUITests"])[0] == need(10.8)  # 300+120+228
    unseen = dict(tests, CUITests=["testNew"])
    assert smoke_limit(smokewf, unseen, duo, 30, "iPad Pro 13-inch", ["CUITests"])[0] == need(15.0)  # 300 + 600
    assert limit_problems([], None, {}) != []
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
    if args[:1] == ["smoke"] and len(args) >= 2:
        sys.exit(smoke(args[1:]))
    print(__doc__, file=sys.stderr)
    sys.exit(2)
