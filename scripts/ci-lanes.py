"""Checks that pull-request macOS jobs wait in the shared lanes (gatefold#286).

    python3 -I scripts/ci-lanes.py check
    python3 -I scripts/ci-lanes.py --selftest

The Ouro Labs enterprise has 50 macOS slots, and every org in it draws on them, spoonjoy included. Gatefold's pull
requests cap themselves with job-level lanes (`concurrency` with `queue: max`): a lane runs one job at a time, across
every open pull request, first come first served. See "macOS lanes" at the top of app.yml. This fails when
  - a job that runs on macOS (`runs-on` names macos or xcode-) has no lane and isn't exempt below,
  - a lane can cancel a job (`cancel-in-progress`), or doesn't queue (`queue: max`),
  - a lane applies outside pull requests: push and dispatch runs need a group of their own, from `github.run_id`,
  - two jobs share a lane name, so one would wait on the other's lanes,
  - a shard caller doesn't pass `lane: ${{ matrix.lane }}`, or a shard has no `lane` between 1 and SHARD_LANES,
  - the lanes add up to more than BUDGET.
Reads only; no dependencies beyond python3. It runs in the job `CI scripts, offline`, which `GatefoldCore tests` (a
required check) stands for.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
SHARD_LANES = 18
# Lanes in all, a hard cap on laned jobs: the 18 shard lanes, 3 each for Release build and Unit tests, 1 each for Duo
# tour, the cloud package and the two screenshot jobs. Builds for testing aren't laned (see EXEMPT): one runs per pull
# request being pushed, so with about 8 pushed at once gatefold's pull requests hold about 36 macOS runners, a soft
# figure, within the 38 of the enterprise's 50 that ourostack's pull requests may use (12 stay for main, merge queues
# and spoonjoy).
BUDGET = 28
EXEMPT = {
    # The shards and Unit tests wait for this run's build inside their own jobs, so a laned build would spend their
    # setup budget. One runs per pull request being pushed.
    ("app.yml", "build"): None,
    # Main and dispatch only: its `if` keeps it off pull requests, and the check holds it to that.
    ("real-unfold.yml", "real-unfold"): "github.event_name != 'pull_request'",
    # Publishing has its own group and runs from main; the check holds testflight.yml to having no pull_request trigger.
    ("testflight.yml", "publish"): None,
}
MACOS = re.compile(r"^\s{4}runs-on:.*\b(macos|xcode-)", re.I | re.M)
MATRIX_RUNS_ON = re.compile(r"^\s{4}runs-on:.*\bmatrix\.", re.M)
PR_NUMBER = r"endsWith\(format\('\{0\}', github\.event\.pull_request\.number\), '(\d)'\)"
# One link of the last-digit chain: (endsWith(..., 'd') || endsWith(..., 'd')) && 'k' ||
LINK = re.compile(r"\(" + PR_NUMBER + r"(?: \|\| " + PR_NUMBER.replace("(\\d)", "\\d") + r")*\) && '(\d)' \|\| ")
GROUP = re.compile(r"^\$\{\{ github\.event_name == 'pull_request' && (?P<pr>.+) \|\| (?P<off>format\('[^']*', .+\)) \}\}$")


def jobs(text):
    """[(name, block)] for each job under `jobs:`."""
    out, name, block, inside = [], None, [], False
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line):
            inside = False
        if not inside:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            if name:
                out.append((name, "\n".join(block)))
            name, block = m.group(1), []
        elif name:
            block.append(line)
    if name:
        out.append((name, "\n".join(block)))
    return out


def concurrency(block):
    """The job's `concurrency:` block (4-space key) without comment lines, or None."""
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^    concurrency:", line):
            body = [line]
            for more in lines[i + 1:]:
                if re.match(r"^      ", more) or not more.strip():
                    if not more.strip().startswith("#"):
                        body.append(more)
                else:
                    break
            return "\n".join(body)
    return None


def group_of(conc):
    """The `group: >-` expression, folded onto one line as YAML folds it."""
    m = re.search(r"^      group: >-\n((?:        .*\n?)+)", conc, re.M)
    return " ".join(l.strip() for l in m.group(1).splitlines()) if m else None


def lane(pr):
    """(name, lanes) for a pull-request branch, or (None, why) when it isn't a bounded lane."""
    m = re.fullmatch(r"'gatefold-macos-pr-lane-([a-z0-9-]+)-0'", pr)
    if m:
        return m.group(1), 1
    m = re.fullmatch(r"format\('gatefold-macos-pr-lane-shard-\{0\}', inputs\.lane\)", pr)
    if m:
        return "shard", SHARD_LANES
    m = re.fullmatch(r"format\('gatefold-macos-pr-lane-([a-z0-9-]+)-\{0\}', (.+)\)", pr)
    if not m:
        return None, "the pull-request branch must be a lane name: 'gatefold-macos-pr-lane-<name>-0', or a format of one"
    rest, picked = m.group(2), {"0"}
    while True:
        link = LINK.match(rest)
        if not link:
            break
        picked.add(link.groups()[-1])
        rest = rest[link.end():]
    if rest != "'0'" or len(picked) < 2:
        return None, ("a lane's {0} must be the last-digit chain of endsWith(...pull_request.number...) && 'k', ending "
                      "|| '0'; anything else (the number itself, a matrix value, a run id) is a lane per pull request")
    return m.group(1), len(picked)


def check(files):
    """files: {filename: text}. Returns a list of errors."""
    errors, names, total = [], {}, 0
    for fname in sorted(files):
        text = files[fname]
        if fname == "testflight.yml" and re.search(r"^  pull_request:", text, re.M):
            errors.append("testflight.yml runs on pull requests, so its exempt publish job needs a lane")
        for job, block in jobs(text):
            if not (MACOS.search(block) or (MATRIX_RUNS_ON.search(block) and re.search(r"\b(macos|xcode)-", block))):
                continue
            where = f"{fname}: {job}"
            if (fname, job) in EXEMPT:
                need = EXEMPT[(fname, job)]
                if need and need not in block:
                    errors.append(f"{where} is exempt only while its `if` holds `{need}`; give it a lane")
                continue
            conc = concurrency(block)
            if conc is None:
                errors.append(f"{where} runs on macOS with no lane; give it one (see \"macOS lanes\" in app.yml)")
                continue
            if "cancel-in-progress" in conc:
                errors.append(f"{where}: a lane must never cancel-in-progress")
            if not re.search(r"^\s+queue:\s*max\s*$", conc, re.M):
                errors.append(f"{where}: a lane needs `queue: max`, or a third waiting job cancels the second")
            g = GROUP.match(group_of(conc) or "")
            if not g:
                errors.append(f"{where}: the group must read ${{{{ github.event_name == 'pull_request' && <lane> || "
                              "format(<own group>) }}, so only pull requests share a lane")
                continue
            off = g.group("off")
            per_leg = "strategy:" in block or job == "run" and fname == "ui-tests.yml"
            if "github.run_id, github.run_attempt" not in off or (per_leg and not re.search(
                    r"github\.run_attempt, (strategy\.job-index|inputs\.shard)\)$", off)):
                errors.append(f"{where}: push and dispatch need a group of their own: format(..., github.run_id, "
                              "github.run_attempt" + (", strategy.job-index or inputs.shard" if per_leg else "") + ")")
            name, lanes = lane(g.group("pr"))
            if name is None:
                errors.append(f"{where}: {lanes}")
                continue
            if name in names:
                errors.append(f"{where}: lane {name} is also {names[name]}'s")
            names[name] = where
            total += lanes
    errors += check_shards(files.get("app.yml", ""), files.get("ui-tests.yml", ""))
    if total > BUDGET:
        errors.append(f"the lanes add up to {total}, over the budget of {BUDGET} (see BUDGET in scripts/ci-lanes.py)")
    return errors


def check_shards(app, ui):
    errors = []
    if not re.search(r"^      lane:\n(?:        .*\n)*?        required: true", ui, re.M):
        errors.append("ui-tests.yml: the `lane` input must be required, so a caller can't drop it")
    for job, block in jobs(app):
        if "uses: ./.github/workflows/ui-tests.yml" not in block:
            continue
        if not re.search(r"^      lane: \$\{\{ matrix\.lane \}\}\s*$", block, re.M):
            errors.append(f"app.yml: {job} must pass `lane: ${{{{ matrix.lane }}}}` to ui-tests.yml")
        for entry in re.split(r"^          - ", block, flags=re.M)[1:]:
            shard = re.match(r"shard: (\S+)", entry)
            if not shard:
                continue
            lane = re.search(r"^            lane: (\d+)\s*$", entry, re.M)
            if not lane or not 1 <= int(lane.group(1)) <= SHARD_LANES:
                errors.append(f"app.yml: {job} shard {shard.group(1)} needs `lane:` from 1 to {SHARD_LANES}")
    return errors


def read():
    return {n: open(os.path.join(WORKFLOWS, n), encoding="utf-8").read()
            for n in os.listdir(WORKFLOWS) if n.endswith((".yml", ".yaml"))}


GOOD_JOB = """jobs:
  unit:
    runs-on: xcode-27
    concurrency:
      group: >-
        ${{ github.event_name == 'pull_request'
        && format('gatefold-macos-pr-lane-unit-{0}', (endsWith(format('{0}', github.event.pull_request.number), '1') || endsWith(format('{0}', github.event.pull_request.number), '4')) && '1' || '0')
        || format('app-unit-{0}-{1}', github.run_id, github.run_attempt) }}
      queue: max
    steps: []
"""
GOOD_UI = """on:
  workflow_call:
    inputs:
      lane:
        description: x
        type: number
        required: true
jobs:
  run:
    runs-on: xcode-27
    concurrency:
      group: >-
        ${{ github.event_name == 'pull_request'
        && format('gatefold-macos-pr-lane-shard-{0}', inputs.lane)
        || format('ui-tests-{0}-{1}-{2}', github.run_id, github.run_attempt, inputs.shard) }}
      queue: max
"""
GOOD_CALLER = """
  duo:
    strategy:
      matrix:
        include:
          - shard: duo-a
            timeout: 30
            lane: 3
    uses: ./.github/workflows/ui-tests.yml
    with:
      shard: ${{ matrix.shard }}
      lane: ${{ matrix.lane }}
"""


def selftest():
    good = {"app.yml": GOOD_JOB + GOOD_CALLER, "ui-tests.yml": GOOD_UI}
    cases = {
        "good": (good, None),
        "no lane": ({**good, "app.yml": GOOD_JOB.replace("    concurrency:", "    x:") + GOOD_CALLER}, "no lane"),
        "cancels": ({**good, "app.yml": GOOD_JOB.replace("queue: max", "queue: max\n      cancel-in-progress: true") + GOOD_CALLER},
                    "cancel-in-progress"),
        "no queue": ({**good, "app.yml": GOOD_JOB.replace("queue: max", "queue: single") + GOOD_CALLER}, "queue: max"),
        "laned off PRs": ({**good, "app.yml": GOOD_JOB.replace("github.run_id", "github.sha") + GOOD_CALLER},
                          "group of their own"),
        "shared name": ({**good, "app.yml": GOOD_JOB + GOOD_JOB.replace("jobs:\n  unit:", "  release:") + GOOD_CALLER},
                        "also"),
        "caller drops lane": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("      lane: ${{ matrix.lane }}\n", "")},
                              "must pass"),
        "shard has no lane": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("            lane: 3\n", "")}, "needs `lane:`"),
        "lane out of range": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("lane: 3", "lane: 19")}, "needs `lane:`"),
        "optional input": ({**good, "ui-tests.yml": GOOD_UI.replace("required: true", "required: false")}, "must be required"),
        "unbounded lane": ({**good, "app.yml": GOOD_JOB.replace("(endsWith(format('{0}', github.event.pull_request.number), '1') || endsWith(format('{0}', github.event.pull_request.number), '4')) && '1' || '0'", "github.event.pull_request.number") + GOOD_CALLER}, "last-digit chain"),
        "swapped": ({**good, "app.yml": GOOD_JOB.replace("github.event_name == 'pull_request'", "github.event_name != 'pull_request'") + GOOD_CALLER}, "the group must read"),
        "comment only": ({**good, "app.yml": GOOD_JOB.replace("      queue: max", "      # queue: max") + GOOD_CALLER}, "queue: max"),
        "real-unfold on PRs": ({**good, "real-unfold.yml": "jobs:\n  real-unfold:\n    if: always()\n    runs-on: xcode-27\n"}, "exempt only while"),
        "testflight on PRs": ({**good, "testflight.yml": "on:\n  pull_request:\njobs:\n  publish:\n    runs-on: xcode-27\n"}, "testflight.yml runs on pull requests"),
        "matrix os": ({**good, "app.yml": GOOD_JOB + "  m:\n    runs-on: ${{ matrix.os }}\n    strategy:\n      matrix:\n        os: [macos-26]\n" + GOOD_CALLER}, "no lane"),
        "leg group": ({**good, "app.yml": GOOD_JOB.replace("    runs-on: xcode-27\n", "    runs-on: xcode-27\n    strategy:\n      matrix: {}\n") + GOOD_CALLER}, "group of their own"),
        "exempt build": ({**good, "app.yml": GOOD_JOB + "  build:\n    runs-on: xcode-27\n" + GOOD_CALLER}, None),
        "linux": ({**good, "app.yml": GOOD_JOB + "  core:\n    runs-on: ubuntu-latest\n" + GOOD_CALLER}, None),
    }
    failed = 0
    for name, (files, want) in cases.items():
        errs = check(files)
        ok = (not errs) if want is None else any(want in e for e in errs)
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {errs}"))
        failed += not ok
    many = "".join(
        f"  r{i}:\n    runs-on: xcode-27\n    concurrency:\n      group: >-\n"
        f"        ${{{{ github.event_name == 'pull_request'\n        && 'gatefold-macos-pr-lane-r{i}-0'\n"
        f"        || format('r-{{0}}-{{1}}', github.run_id, github.run_attempt) }}}}\n      queue: max\n"
        for i in range(BUDGET))
    over = check({"app.yml": GOOD_JOB + many + GOOD_CALLER, "ui-tests.yml": GOOD_UI})
    ok = any("over the budget" in e for e in over)
    print(("ok   " if ok else "FAIL ") + "over budget")
    failed += not ok
    print(f"{failed} failed")
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:] == ["check"]:
        errors = check(read())
        for e in errors:
            print(f"::error::{e}")
        if not errors:
            print("Every pull-request macOS job waits in a lane, and the lanes fit the budget")
        return 1 if errors else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
