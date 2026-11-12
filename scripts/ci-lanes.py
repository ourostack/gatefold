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
# Lanes in all: the 18 shard lanes, 3 each for Release build and Unit tests, 1 each for Duo tour, the cloud package
# and the two screenshot jobs. Builds for testing aren't laned (see EXEMPT), and one runs per pull request being
# pushed, about 8, so gatefold's pull requests hold about 36 macOS runners at most, within the 38 the enterprise's 50
# leave ourostack's pull requests (at least 12 stay for main, merge queues and spoonjoy).
BUDGET = 28
EXEMPT = {
    # The shards and Unit tests wait for this run's build inside their own jobs, so a laned build would spend their
    # setup budget. One runs per pull request being pushed.
    ("app.yml", "build"): "shards wait for its artifact",
    # Main and dispatch only; it never runs on a pull request.
    ("real-unfold.yml", "real-unfold"): "never runs on a pull request",
    # Publishing has its own group and runs from main.
    ("testflight.yml", "publish"): "runs from main, in its own group",
}
MACOS = re.compile(r"^\s{4}runs-on:.*\b(macos|xcode-)", re.I | re.M)
LANE = re.compile(r"gatefold-macos-pr-lane-([a-z0-9-]+?)-(?:\{0\}|0)'")


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
    """The job's `concurrency:` block (4-space key) as text, or None."""
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^    concurrency:", line):
            body = [line]
            for more in lines[i + 1:]:
                if re.match(r"^      ", more) or not more.strip():
                    body.append(more)
                else:
                    break
            return "\n".join(body)
    return None


def lanes_in(group):
    """How many lanes a group's expression names: 1, or 1 + each `&& 'k'` of a PR-number chain."""
    return 1 + len(re.findall(r"&& '\d'", group))


def check(files):
    """files: {filename: text}. Returns a list of errors."""
    errors, names, total = [], {}, 0
    for fname in sorted(files):
        text = files[fname]
        for job, block in jobs(text):
            if not MACOS.search(block):
                continue
            where = f"{fname}: {job}"
            if (fname, job) in EXEMPT:
                continue
            conc = concurrency(block)
            if conc is None:
                errors.append(f"{where} runs on macOS with no lane; give it one (see \"macOS lanes\" in app.yml)")
                continue
            if "cancel-in-progress" in conc:
                errors.append(f"{where}: a lane must never cancel-in-progress")
            if not re.search(r"^\s+queue:\s*max\s*$", conc, re.M):
                errors.append(f"{where}: a lane needs `queue: max`, or a third waiting job cancels the second")
            if "github.event_name == 'pull_request'" not in conc or "github.run_id" not in conc:
                errors.append(f"{where}: lanes are for pull requests only; push and dispatch need a group from github.run_id")
            m = LANE.search(conc)
            if not m:
                errors.append(f"{where}: its group names no gatefold-macos-pr-lane-<name>")
                continue
            lane = m.group(1)
            if lane in names:
                errors.append(f"{where}: lane {lane} is also {names[lane]}'s")
            names[lane] = where
            if lane == "shard":
                if "inputs.lane" not in conc:
                    errors.append(f"{where}: the shard lane comes from inputs.lane")
                total += SHARD_LANES
            else:
                total += lanes_in(conc)
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
        && format('gatefold-macos-pr-lane-unit-{0}', (endsWith(x, '1')) && '1' || '0')
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
                          "pull requests only"),
        "shared name": ({**good, "app.yml": GOOD_JOB + GOOD_JOB.replace("jobs:\n  unit:", "  release:") + GOOD_CALLER},
                        "also"),
        "caller drops lane": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("      lane: ${{ matrix.lane }}\n", "")},
                              "must pass"),
        "shard has no lane": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("            lane: 3\n", "")}, "needs `lane:`"),
        "lane out of range": ({**good, "app.yml": GOOD_JOB + GOOD_CALLER.replace("lane: 3", "lane: 19")}, "needs `lane:`"),
        "optional input": ({**good, "ui-tests.yml": GOOD_UI.replace("required: true", "required: false")}, "must be required"),
        "exempt build": ({**good, "app.yml": GOOD_JOB + "  build:\n    runs-on: xcode-27\n" + GOOD_CALLER}, None),
        "linux": ({**good, "app.yml": GOOD_JOB + "  core:\n    runs-on: ubuntu-latest\n" + GOOD_CALLER}, None),
    }
    failed = 0
    for name, (files, want) in cases.items():
        errs = check(files)
        ok = (not errs) if want is None else any(want in e for e in errs)
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {errs}"))
        failed += not ok
    over = check({"app.yml": GOOD_JOB.replace("&& '1' ||", "&& '1' || " + "(x) && '2' || " * BUDGET) + GOOD_CALLER,
                  "ui-tests.yml": GOOD_UI})
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
