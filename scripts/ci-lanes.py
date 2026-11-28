"""Checks that macOS jobs wait in the shared lanes: every pull request's, and main pushes' in App and Real unfold (gatefold#286).

    python3 -I scripts/ci-lanes.py check
    python3 -I scripts/ci-lanes.py --selftest

The Ouro Labs enterprise has 50 macOS slots, and every org in it draws on them, spoonjoy included. Gatefold's pull
requests cap themselves with job-level lanes (`concurrency` with `queue: max`): a lane runs one job at a time, across
every open pull request, first come first served. See "macOS lanes" at the top of app.yml. This fails when
  - a job that runs on macOS (`runs-on` names macos or xcode-) has no lane and isn't exempt below,
  - a lane can cancel a job (`cancel-in-progress`), or doesn't queue (`queue: max`),
  - a lane applies to dispatch or any other event: those runs need a group of their own, from `github.run_id`,
  - one of App's or Real unfold's laned jobs lets main pushes skip the lanes, or a main push waits anywhere but this
    job's own main lane (`gatefold-macos-main-lane-<name>`, one per shard or place): each main commit has a run of
    its own (MAIN_LANED), so overlapping runs would hold a full set of Macs each (gatefold#246),
  - App's or Real unfold's run-level group lets a later push to main replace a waiting one (it must be per commit),
  - two jobs share a lane name, so one would wait on the other's lanes,
  - a shard caller doesn't pass `lane: ${{ matrix.lane }}`, or a shard has no `lane` between 1 and SHARD_LANES,
  - one shard lane's `timeout`s add up to more than LANE_SHARE times the mean lane's,
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
# Odd and even pull requests each get their own set of the shard lanes (the last-digit parity in ui-tests.yml's group).
SHARD_SETS = 2
# A full-list run takes as long as its busiest shard lane, so no lane's shard timeouts may add up to more than this
# times the mean lane's (the timeouts are 2x measured time plus a fixed margin). On 2026-11-27 lane 2 summed 475 min
# of timeouts against a mean of 227 (2.1x), and 113 min of main's measured shard time against 53; after moving six
# shards the busiest is 285 (1.26x), 60 min measured.
LANE_SHARE = 1.4
# Real unfold's places: the lanes 1 to 5 its caller's matrix gives them (real-unfold.yml; real-unfold-place.yml waits in them).
PLACE_LANES = 5
# Lanes in all, a hard cap on laned jobs: the 36 shard lanes (18 for each parity), 3 each for Release build and Unit
# tests, 1 each for Duo tour, the cloud package and the two screenshot jobs. Builds for testing aren't laned (see
# EXEMPT): one runs per pull request being pushed. Raised from 28 on 2026-11-13 while spoonjoy is outside the
# enterprise, so ourostack has all 50 of its macOS slots; if spoonjoy rejoins, set SHARD_SETS back to 1 and BUDGET to 28.
# Plus 5 for Real unfold's places on pull requests that touch the reader (2026-11-17). From 2026-11-15 to 11-17 the
# organization's macOS jobs peaked at 82 at once (gatefold, ouro-ui-apple, ouro-md, ouro-ui-core), so 50 is not a hard
# ceiling, but main's unlaned shards waited 5 to 34 min whenever about 50 to 65 ran: the pool is busy, not idle.
BUDGET = 51
EXEMPT = {
    # The shards and Unit tests wait for this run's build inside their own jobs, so a laned build would spend their
    # setup budget. One runs per pull request being pushed.
    ("app.yml", "build"): None,
    # Pushes to main and dispatch only (its `on` and `if`): it saves the warm devices the UI shards boot from
    # (gatefold#533).
    ("warm-sim.yml", "warm-sim"): "github.event_name != 'pull_request'",
    # Real unfold's one build, for the same reason as App's: its five places wait for it inside their own jobs. One runs
    # per pull request being pushed that touches the reader.
    ("real-unfold.yml", "build"): None,
    # The cloud canary signs in to the live cloud, so it runs from schedule and dispatch only, one at a time in its
    # own group; never on a pull request.
    ("cloud-canary.yml", "canary"): "github.event_name != 'pull_request'",
    # The live gate on a cloud fix: a dispatched run (its `if`), in the canary's own group; never a pull_request run.
    ("cloud-fix-gate.yml", "live"): "github.event_name != 'pull_request'",
    # The review panel's screenshots: dispatch only (its `on` and `if`), at most two legs at once; never a pull request.
    ("panel.yml", "capture"): "github.event_name != 'pull_request'",
    # The App Intents X-ray for the adoption ledger: pushes to main and dispatch only (its `if`); never a pull request.
    ("actions.yml", "app-intents-xray"): "github.event_name != 'pull_request'",
    # Publishing has its own group and runs from main; the check holds testflight.yml to having no pull_request trigger.
    ("testflight.yml", "publish"): None,
}
MACOS = re.compile(r"^\s{4}runs-on:.*\b(macos|xcode-)", re.I | re.M)
MATRIX_RUNS_ON = re.compile(r"^\s{4}runs-on:.*\bmatrix\.", re.M)
PR_NUMBER = r"endsWith\(format\('\{0\}', github\.event\.pull_request\.number\), '(\d)'\)"
# One link of the last-digit chain: (endsWith(..., 'd') || endsWith(..., 'd')) && 'k' ||
LINK = re.compile(r"\(" + PR_NUMBER + r"(?: \|\| " + PR_NUMBER.replace("(\\d)", "\\d") + r")*\) && '(\d)' \|\| ")
GROUP = re.compile(r"^\$\{\{ github\.event_name == 'pull_request' && (?P<pr>.+) \|\| (?P<off>format\('[^']*', .+\)) \}\}$")
PUSH = " || github.event_name == 'push' && "
# Workflows whose laned jobs must lane main pushes too: each main commit has an App and a Real unfold run of its own
# (their run-level group is per commit), so without lanes a burst of merges would start a full set of Macs per commit.
MAIN_LANED = {"app.yml", "ui-tests.yml", "real-unfold-place.yml"}
# The run-level groups that must be per commit on main pushes, never shared ('main'), or a later merge replaces a
# waiting run and its commit gets no verdict (fast-honest-ci 2.7; 10 of 18 main runs on 2026-11-22).
PER_COMMIT = {"app.yml": "app-", "real-unfold.yml": "real-unfold-"}
# A main push's lane: this job's own name, alone or one per shard, place or matrix leg; never a pull request's lane.
# Main's lanes are outside BUDGET: together they hold one main run's worth of Macs, as one batched run did.
MAIN_LANE = re.compile(r"'gatefold-macos-main-lane-(?P<a>[a-z0-9-]+)'"
                       r"|format\('gatefold-macos-main-lane-(?P<b>[a-z0-9-]+)-\{0\}', (?:inputs\.shard|inputs\.lane|matrix\.lane)\)")


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
    """The job's `concurrency:` block (4-space key), without its 6-space comment lines, or None. Lines inside the
    `group: >-` block scalar are kept as they are: there a `#` or a blank line is part of the value."""
    lines = block.splitlines()
    for i, line in enumerate(lines):
        if re.match(r"^    concurrency:", line):
            body = [line]
            for more in lines[i + 1:]:
                if re.match(r"^      ", more) or not more.strip():
                    if not re.match(r"^ {4,6}#", more):
                        body.append(more)
                else:
                    break
            return "\n".join(body).rstrip("\n")
    return None


def group_of(conc):
    """The `group: >-` expression, folded onto one line as YAML folds it; None unless every line of the block is plain
    text at 8 spaces (a blank, deeper or `#` line would put text into the name that a check here can't see)."""
    lines = conc.splitlines()
    for i, line in enumerate(lines):
        if line == "      group: >-":
            block = []
            for more in lines[i + 1:]:
                if more.strip() and not re.match(r"^ {7}", more):
                    break
                block.append(more)
            while block and not block[-1].strip():
                block.pop()
            if not block or any(not re.match(r"^ {8}[^ #]", l) for l in block):
                return None
            return " ".join(l.strip() for l in block)
    return None


def lane(pr, block=None):
    """(name, lanes) for a pull-request branch, or (None, why) when it isn't a bounded lane."""
    m = re.fullmatch(r"'gatefold-macos-pr-lane-([a-z0-9-]+)-0'", pr)
    if m:
        return m.group(1), 1
    m = re.fullmatch(r"format\('gatefold-macos-pr-lane-shard-\{0\}-\{1\}', inputs\.lane, (.+)\)", pr)
    if m:
        rest, picked = m.group(1), {"0"}
        while True:
            link = LINK.match(rest)
            if not link:
                break
            picked.add(link.groups()[-1])
            rest = rest[link.end():]
        if rest != "'0'" or len(picked) != SHARD_SETS:
            return None, f"the shard lane's {{1}} must be the last-digit chain picking {SHARD_SETS} sets, ending || '0'"
        return "shard", SHARD_LANES * SHARD_SETS
    # Real unfold's place workflow: one lane per place, 1 to PLACE_LANES (the caller's matrix names them).
    m = re.fullmatch(r"'gatefold-macos-pr-lane-unfold-\{0\}', inputs\.lane", pr.removeprefix("format(").removesuffix(")"))
    if m:
        return "unfold", PLACE_LANES
    # A matrix whose legs each wait in their own lane, shared by every pull request: one lane per distinct `lane:`.
    m = re.fullmatch(r"format\('gatefold-macos-pr-lane-([a-z0-9-]+)-\{0\}', matrix\.lane\)", pr)
    if m:
        entries = re.split(r"^          - ", block or "", flags=re.M)[1:]
        legs = [re.search(r"^(?:            )?lane: (\d+)\s*$", e, re.M) for e in entries]
        if not entries or not all(legs):
            return None, "a lane by matrix.lane needs a literal `lane:` in each matrix entry"
        return m.group(1), len({l.group(1) for l in legs})
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
        on = re.search(r"^on:(.*?)(?=^\S)", text + "\nend:", re.M | re.S)
        if fname == "testflight.yml" and on and re.search(r"\bpull_request(_target)?\b", on.group(1)):
            errors.append("testflight.yml runs on pull requests, so its exempt publish job needs a lane")
        for job, block in jobs(text):
            if not (MACOS.search(block) or (MATRIX_RUNS_ON.search(block) and re.search(r"\b(macos|xcode)-", block))):
                continue
            where = f"{fname}: {job}"
            if (fname, job) in EXEMPT:
                need = EXEMPT[(fname, job)]
                job_if = re.search(r"^    if: (.*)$", block, re.M)
                if need and not (job_if and need in job_if.group(1)):
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
            off, pr = g.group("off"), g.group("pr")
            push = None
            if PUSH in pr:
                pr, push = pr.split(PUSH, 1)
            elif fname in MAIN_LANED:
                errors.append(f"{where}: main pushes must wait in a main lane too (`|| github.event_name == 'push' && "
                              "'gatefold-macos-main-lane-<name>'`): each main commit has its own run")
            per_leg = ("strategy:" in block or job == "run" and fname == "ui-tests.yml"
                       or job == "place" and fname == "real-unfold-place.yml")
            if ("github.run_id, github.run_attempt" not in off or "gatefold-macos-pr-lane" in off
                    or not re.match(r"format\('[^']*\{0\}[^']*\{1\}", off) or (per_leg and not re.search(
                    r"github\.run_attempt, (strategy\.job-index|inputs\.shard|inputs\.place, inputs\.try)\)$", off))):
                errors.append(f"{where}: push and dispatch need a group of their own: format(..., github.run_id, "
                              "github.run_attempt" + (", strategy.job-index, inputs.shard or inputs.place, inputs.try" if per_leg else "") + ")")
            name, lanes = lane(pr, block)
            if name is None:
                errors.append(f"{where}: {lanes}")
                continue
            if push is not None:
                m = MAIN_LANE.fullmatch(push)
                if name == "shard" and push != "format('gatefold-macos-main-lane-shard-{0}', inputs.shard)":
                    errors.append(f"{where}: on main pushes a shard waits in a lane of its own, one per shard "
                                  "(inputs.shard), not one of the 18 numbered lanes, which would hold a lone run to its "
                                  "busiest lane")
                elif not m or (m.group("a") or m.group("b")) != name:
                    errors.append(f"{where}: a main push must wait in this job's own main lane, "
                                  f"'gatefold-macos-main-lane-{name}' (or a format of it by shard, place or leg), not {push}")
            if name in names:
                errors.append(f"{where}: lane {name} is also {names[name]}'s")
            names[name] = where
            total += lanes
    for fname, prefix in PER_COMMIT.items():
        text = files.get(fname)
        if text is None:
            continue
        top = re.search(r"^concurrency:\n  group: >-\n((?:    .*\n)+)", text, re.M)
        group = " ".join(l.strip() for l in top.group(1).splitlines()) if top else ""
        if f"{prefix}${{{{ github.event_name == 'pull_request' && github.ref || github.event_name == 'push' && format('main-{{0}}', github.sha) ||" not in group:
            errors.append(f"{fname}: the run's group must give each push to main its own, "
                          "format('main-{0}', github.sha), so a later merge never replaces it")
    errors += check_shards(files.get("app.yml", ""), files.get("ui-tests.yml", ""))
    errors += check_places(files.get("real-unfold.yml", ""), files.get("real-unfold-place.yml", ""))
    for fname in ("real-unfold.yml", "real-unfold-place.yml"):
        for job, block in jobs(files.get(fname, "")):
            limit = re.search(r"^      LIMIT: (\"?[^\s\"#]+\"?)", block, re.M)
            timeout = re.search(r"^    timeout-minutes: (\S+)", block, re.M)
            if limit and (not timeout or timeout.group(1) != limit.group(1).strip('"')):
                errors.append(f"{fname}: {job}: env LIMIT must equal timeout-minutes, or the unfolds stop by the wrong clock")
    if total > BUDGET:
        errors.append(f"the lanes add up to {total}, over the budget of {BUDGET} (see BUDGET in scripts/ci-lanes.py)")
    return errors


def check_shards(app, ui):
    errors, lanes = [], {}
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
                continue
            timeout = re.search(r"^            timeout: (\d+)", entry, re.M)
            if not timeout:
                errors.append(f"app.yml: {job} shard {shard.group(1)} needs a literal `timeout:`, which weighs its lane")
                continue
            lanes.setdefault(int(lane.group(1)), []).append((int(timeout.group(1)), shard.group(1)))
    # Fewer shards than lanes can't be balanced; the real matrix has three per lane.
    if sum(len(v) for v in lanes.values()) >= SHARD_LANES:
        mean = sum(t for v in lanes.values() for t, _ in v) / SHARD_LANES
        for n, v in sorted(lanes.items()):
            if sum(t for t, _ in v) > LANE_SHARE * mean:
                errors.append(f"app.yml: shard lane {n}'s timeouts add up to {sum(t for t, _ in v)} min, over "
                              f"{LANE_SHARE} x the mean lane's {mean:.0f} ({', '.join(s for _, s in v)}): a full-list run "
                              "waits on its busiest lane, so move a shard to the lightest one")
    return errors


def check_places(real, place):
    """Real unfold's `unfold` and `retry` callers pass every input the place workflow needs, and its `lane` is required."""
    if not place:
        return []
    errors = []
    if not re.search(r"^      lane:\n(?:        .*\n)*?        required: true", place, re.M):
        errors.append("real-unfold-place.yml: the `lane` input must be required, so a caller can't drop it")
    for job, block in jobs(real):
        if "uses: ./.github/workflows/real-unfold-place.yml" not in block:
            continue
        if not re.search(r"^      lane: \$\{\{ matrix\.lane \}\}\s*$", block, re.M):
            errors.append(f"real-unfold.yml: {job} must pass `lane: ${{{{ matrix.lane }}}}` to real-unfold-place.yml")
        if job == "unfold":
            lanes = re.findall(r"^            lane: (\d+)\s*$", block, re.M)
            if sorted(lanes) != sorted(str(i) for i in range(1, PLACE_LANES + 1)):
                errors.append(f"real-unfold.yml: unfold's places need `lane:` 1 to {PLACE_LANES}, one each: {lanes}")
    return errors


def read():
    return {n: open(os.path.join(WORKFLOWS, n), encoding="utf-8").read()
            for n in os.listdir(WORKFLOWS) if n.endswith((".yml", ".yaml"))}


def top(prefix):
    """A run-level group that gives each main push its own."""
    return (f"concurrency:\n  group: >-\n    {prefix}${{{{ github.event_name == 'pull_request' && github.ref\n"
            "    || github.event_name == 'push' && format('main-{0}', github.sha) || github.sha }}\n")


GOOD_JOB = """jobs:
  unit:
    runs-on: xcode-27
    concurrency:
      group: >-
        ${{ github.event_name == 'pull_request'
        && format('gatefold-macos-pr-lane-unit-{0}', (endsWith(format('{0}', github.event.pull_request.number), '1') || endsWith(format('{0}', github.event.pull_request.number), '4')) && '1' || '0')
        || github.event_name == 'push' && 'gatefold-macos-main-lane-unit'
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
        && format('gatefold-macos-pr-lane-shard-{0}-{1}', inputs.lane, (endsWith(format('{0}', github.event.pull_request.number), '1') || endsWith(format('{0}', github.event.pull_request.number), '3') || endsWith(format('{0}', github.event.pull_request.number), '5') || endsWith(format('{0}', github.event.pull_request.number), '7') || endsWith(format('{0}', github.event.pull_request.number), '9')) && '1' || '0')
        || github.event_name == 'push' && format('gatefold-macos-main-lane-shard-{0}', inputs.shard)
        || format('ui-tests-{0}-{1}-{2}', github.run_id, github.run_attempt, inputs.shard) }}
      queue: max
"""
GOOD_LEGS = """jobs:
  unfold:
    strategy:
      matrix:
        include:
          - place: "a"
            lane: 1
          - place: "b"
            lane: 2
    runs-on: xcode-27
    concurrency:
      group: >-
        ${{ github.event_name == 'pull_request'
        && format('gatefold-macos-pr-lane-unfold-{0}', matrix.lane)
        || format('real-unfold-{0}-{1}-{2}', github.run_id, github.run_attempt, strategy.job-index) }}
      queue: max
"""
GOOD_PLACE = """on:
  workflow_call:
    inputs:
      lane:
        description: x
        type: number
        required: true
jobs:
  place:
    runs-on: xcode-27
    concurrency:
      group: >-
        ${{ github.event_name == 'pull_request'
        && format('gatefold-macos-pr-lane-unfold-{0}', inputs.lane)
        || github.event_name == 'push' && format('gatefold-macos-main-lane-unfold-{0}', inputs.lane)
        || format('real-unfold-{0}-{1}-{2}{3}', github.run_id, github.run_attempt, inputs.place, inputs.try) }}
      queue: max
    timeout-minutes: ${{ inputs.timeout }}
    env:
      LIMIT: ${{ inputs.timeout }} # the timeout
"""
GOOD_PLACES = "jobs:\n  unfold:\n    strategy:\n      matrix:\n        include:\n" + "".join(
    f'          - place: "p{i}"\n            lane: {i}\n' for i in range(1, 6)) + (
    "    uses: ./.github/workflows/real-unfold-place.yml\n    with:\n      lane: ${{ matrix.lane }}\n")
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


def spread():
    """A shard caller with one 30-minute shard in each of the 18 lanes."""
    return GOOD_CALLER.replace("          - shard: duo-a\n            timeout: 30\n            lane: 3\n", "".join(
        f"          - shard: duo-{i}\n            timeout: 30\n            lane: {i}\n" for i in range(1, SHARD_LANES + 1)))


def selftest():
    app = top("app-")
    good = {"app.yml": app + GOOD_JOB + GOOD_CALLER, "ui-tests.yml": GOOD_UI}
    unit_push = "        || github.event_name == 'push' && 'gatefold-macos-main-lane-unit'\n"
    cases = {
        "good": (good, None),
        "no lane": ({**good, "app.yml": app + GOOD_JOB.replace("    concurrency:", "    x:") + GOOD_CALLER}, "no lane"),
        "cancels": ({**good, "app.yml": app + GOOD_JOB.replace("queue: max", "queue: max\n      cancel-in-progress: true") + GOOD_CALLER},
                    "cancel-in-progress"),
        "no queue": ({**good, "app.yml": app + GOOD_JOB.replace("queue: max", "queue: single") + GOOD_CALLER}, "queue: max"),
        "laned off PRs": ({**good, "app.yml": app + GOOD_JOB.replace("github.run_id", "github.sha") + GOOD_CALLER},
                          "group of their own"),
        "shared name": ({**good, "app.yml": app + GOOD_JOB + GOOD_JOB.replace("jobs:\n  unit:", "  release:") + GOOD_CALLER},
                        "also"),
        "caller drops lane": ({**good, "app.yml": app + GOOD_JOB + GOOD_CALLER.replace("      lane: ${{ matrix.lane }}\n", "")},
                              "must pass"),
        "shard has no lane": ({**good, "app.yml": app + GOOD_JOB + GOOD_CALLER.replace("            lane: 3\n", "")}, "needs `lane:`"),
        "balanced lanes": ({**good, "app.yml": app + GOOD_JOB + spread()}, None),
        "a lane carries double": ({**good, "app.yml": app + GOOD_JOB + spread().replace("lane: 2\n", "lane: 1\n")}, "shard lane 1's timeouts"),
        "shard has no timeout": ({**good, "app.yml": app + GOOD_JOB + GOOD_CALLER.replace("            timeout: 30\n", "")}, "literal `timeout:`"),
        "lane out of range": ({**good, "app.yml": app + GOOD_JOB + GOOD_CALLER.replace("lane: 3", "lane: 19")}, "needs `lane:`"),
        "optional input": ({**good, "ui-tests.yml": GOOD_UI.replace("required: true", "required: false")}, "must be required"),
        "unbounded lane": ({**good, "app.yml": app + GOOD_JOB.replace("(endsWith(format('{0}', github.event.pull_request.number), '1') || endsWith(format('{0}', github.event.pull_request.number), '4')) && '1' || '0'", "github.event.pull_request.number") + GOOD_CALLER}, "last-digit chain"),
        "swapped": ({**good, "app.yml": app + GOOD_JOB.replace("github.event_name == 'pull_request'", "github.event_name != 'pull_request'") + GOOD_CALLER}, "the group must read"),
        "comment only": ({**good, "app.yml": app + GOOD_JOB.replace("      queue: max", "      # queue: max") + GOOD_CALLER}, "queue: max"),
        "unlaned unfold": ({**good, "real-unfold.yml": "jobs:\n  unfold:\n    if: always()\n    runs-on: xcode-27\n"}, "no lane"),
        "matrix lanes": ({**good, "real-unfold.yml": top("real-unfold-") + GOOD_LEGS}, None),
        "matrix lanes without a lane": ({**good, "real-unfold.yml": GOOD_LEGS.replace("            lane: 2\n", "")}, "literal `lane:`"),
        "unfold limit drifts": ({**good, "real-unfold.yml": GOOD_LEGS + "    timeout-minutes: 70\n    env:\n      LIMIT: \"60\"\n"}, "must equal"),
        "testflight on PRs": ({**good, "testflight.yml": "on:\n  pull_request:\njobs:\n  publish:\n    runs-on: xcode-27\n"}, "testflight.yml runs on pull requests"),
        "matrix os": ({**good, "app.yml": app + GOOD_JOB + "  m:\n    runs-on: ${{ matrix.os }}\n    strategy:\n      matrix:\n        os: [macos-26]\n" + GOOD_CALLER}, "no lane"),
        "leg group": ({**good, "app.yml": app + GOOD_JOB.replace("    runs-on: xcode-27\n", "    runs-on: xcode-27\n    strategy:\n      matrix: {}\n") + GOOD_CALLER}, "group of their own"),
        "hash in group": ({**good, "app.yml": app + GOOD_JOB.replace("        || format('app-unit", "        #${{ github.event.pull_request.number }}\n        || format('app-unit") + GOOD_CALLER}, "the group must read"),
        "blank in group": ({**good, "app.yml": app + GOOD_JOB.replace("        || format('app-unit", "\n        || format('app-unit") + GOOD_CALLER}, "the group must read"),
        "off-PR joins a lane": ({**good, "app.yml": app + GOOD_JOB.replace("format('app-unit-{0}-{1}'", "format('gatefold-macos-pr-lane-unit-0'") + GOOD_CALLER}, "group of their own"),
        "condition in a step": ({**good, "cloud-canary.yml": "jobs:\n  canary:\n    if: always()\n    runs-on: xcode-27\n    steps:\n      - if: github.event_name != 'pull_request'\n"}, "exempt only while"),
        "testflight inline on": ({**good, "testflight.yml": "on: [workflow_run, pull_request]\njobs:\n  publish:\n    runs-on: xcode-27\n"}, "testflight.yml runs on pull requests"),
        "exempt build": ({**good, "app.yml": app + GOOD_JOB + "  build:\n    runs-on: xcode-27\n" + GOOD_CALLER}, None),
        "one shard set": ({**good, "ui-tests.yml": re.sub(r"format\('gatefold-macos-pr-lane-shard-\{0\}-\{1\}', inputs\.lane, .*\)\n", "format('gatefold-macos-pr-lane-shard-{0}-{1}', inputs.lane, '0')\n", GOOD_UI)}, "shard lane's {1}"),
        "place workflow": ({**good, "real-unfold.yml": top("real-unfold-") + GOOD_PLACES, "real-unfold-place.yml": GOOD_PLACE}, None),
        "main shares a run group": ({**good, "app.yml": good["app.yml"].replace("format('main-{0}', github.sha)", "github.run_attempt == 1 && 'main'")}, "its own, format('main-{0}'"),
        "unfold shares a run group": ({**good, "real-unfold.yml": GOOD_PLACES, "real-unfold-place.yml": GOOD_PLACE}, "real-unfold.yml: the run's group"),
        "main skips the lanes": ({**good, "app.yml": good["app.yml"].replace(unit_push, "")}, "must wait in a main lane too"),
        "main shard skips the lanes": ({**good, "ui-tests.yml": GOOD_UI.replace("        || github.event_name == 'push' && format('gatefold-macos-main-lane-shard-{0}', inputs.shard)\n", "")}, "must wait in a main lane too"),
        "main in a pull request's lane": ({**good, "app.yml": good["app.yml"].replace("'gatefold-macos-main-lane-unit'\n", "'gatefold-macos-pr-lane-unit-0'\n")}, "own main lane"),
        "main in another job's lane": ({**good, "app.yml": good["app.yml"].replace("'gatefold-macos-main-lane-unit'\n", "'gatefold-macos-main-lane-release'\n")}, "own main lane"),
        "main shards share numbered lanes": ({**good, "ui-tests.yml": GOOD_UI.replace("format('gatefold-macos-main-lane-shard-{0}', inputs.shard)", "format('gatefold-macos-main-lane-shard-{0}', inputs.lane)")}, "one per shard"),
        "main lane per run is no lane": ({**good, "app.yml": good["app.yml"].replace("'gatefold-macos-main-lane-unit'\n", "format('gatefold-macos-main-lane-unit-{0}', github.sha)\n")}, "own main lane"),
        "other workflows need no main lane": ({**good, "duo-tour.yml": "jobs:\n  tour:\n    runs-on: xcode-27\n    concurrency:\n      group: >-\n        ${{ github.event_name == 'pull_request'\n        && 'gatefold-macos-pr-lane-duo-tour-0'\n        || format('duo-tour-{0}-{1}', github.run_id, github.run_attempt) }}\n      queue: max\n"}, None),
        "place drops lane": ({**good, "real-unfold.yml": GOOD_PLACES.replace("      lane: ${{ matrix.lane }}\n", ""), "real-unfold-place.yml": GOOD_PLACE}, "must pass"),
        "place lane missing": ({**good, "real-unfold.yml": GOOD_PLACES.replace("lane: 5", "lane: 4"), "real-unfold-place.yml": GOOD_PLACE}, "1 to 5"),
        "place retries share a group": ({**good, "real-unfold.yml": GOOD_PLACES, "real-unfold-place.yml": GOOD_PLACE.replace("{2}{3}', github.run_id, github.run_attempt, inputs.place, inputs.try", "{2}', github.run_id, github.run_attempt, inputs.place")}, "group of their own"),
        "place limit drifts": ({**good, "real-unfold.yml": GOOD_PLACES, "real-unfold-place.yml": GOOD_PLACE.replace("LIMIT: ${{ inputs.timeout }}", "LIMIT: 60")}, "must equal"),
        "linux": ({**good, "app.yml": app + GOOD_JOB + "  core:\n    runs-on: ubuntu-latest\n" + GOOD_CALLER}, None),
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
    over = check({"app.yml": app + GOOD_JOB + many + GOOD_CALLER, "ui-tests.yml": GOOD_UI})
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
            print("Every pull-request macOS job waits in a lane, App's and Real unfold's wait in a main lane each on main pushes, each main push has a run of its own, and the pull-request lanes fit the budget")
        return 1 if errors else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
