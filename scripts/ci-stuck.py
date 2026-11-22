#!/usr/bin/env python3
"""Cancel a workflow run whose job has outlived its own timeout: GitHub lost the runner and never will.

Merge-group run 44213268613's "Unfold with a book open" sat in_progress for 78 min past its 75-min timeout; the runner
was gone, so GitHub never ended the job, a plain cancel did nothing, and the merge queue stalled for about 2 h until
`POST .../actions/runs/<id>/force-cancel`. This finds such runs, cancels them, and force-cancels any still running
after a wait.

    python3 -I scripts/ci-stuck.py check [--act]   # GITHUB_REPOSITORY, GITHUB_TOKEN; --act cancels, else it only says
    python3 -I scripts/ci-stuck.py --selftest

A job's limit is its workflow's: the largest `timeout-minutes:` (and matrix `timeout:`, for a reusable workflow's
callers) in that workflow file, or GitHub's default 360 min when a job there sets none. Never a guess: a job of
.github/workflows/real-unfold.yml is over at 75 min, one of app.yml at its slowest shard's 118. A job is stuck when
it has been in_progress for that limit plus GRACE minutes, counted from its own `started_at` (a job waiting in a
lane is queued, not in_progress, so its wait never counts). Merge-group runs go first, then pull requests, then the
rest. A run younger than its workflow's limit plus GRACE can't have a stuck job, so its jobs are never read: a
quiet tick reads one page of runs. HTTP 403 or 429 stops it at once, with a warning, and it acts no further.
"""
import datetime
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

GRACE = 5  # minutes past the limit before a job counts as stuck
DEFAULT = 360  # GitHub's job timeout when a job sets none
FORCE_AFTER = 120  # seconds between the cancel and the force-cancel
ORDER = {"merge_group": 0, "pull_request": 1}
WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"


class Stop(Exception):
    """GitHub said 403 or 429: stop calling it."""


def choice(value):
    """The largest minutes an expression of the form `${{ cond && 12 || 35 }}` can give, or None. Each `||` branch
    but the last must end `&& <literal>` and the last must be a literal; anything else (an input, fromJSON, a `||`
    inside a condition) can't be read here, so it is None."""
    m = re.fullmatch(r"\$\{\{(.*)\}\}", value.strip())
    if not m:
        return None
    *picks, last = m.group(1).split("||")
    got = [re.fullmatch(r".*&&\s*(\d+)\s*", p, re.S) for p in picks] + [re.fullmatch(r"\s*(\d+)\s*", last)]
    return max(int(g.group(1)) for g in got) if picks and all(got) else None


def limit(text):
    """A workflow file's longest job timeout in minutes: the largest literal `timeout-minutes:` or matrix `timeout:`
    (or the larger literal of a job's `cond && N || M`), or DEFAULT when a job that runs on a runner sets none (any
    other expression counts as none: it can't be read here)."""
    nums = [int(n) for n in re.findall(r"^\s*(?:-\s+)?timeout(?:-minutes)?:\s*(\d+)\s*(?:#.*)?$", text, re.M)]
    body = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:[ \t]*\n)", "\n" + body):
        if not re.search(r"^    runs-on:", block, re.M):
            continue
        own = re.search(r"^    timeout-minutes:[ \t]*(.*?)[ \t]*(?:#.*)?$", block, re.M)
        value = own.group(1) if own else ""
        if value.isdigit():
            continue
        picked = choice(value)
        if picked is None:
            return DEFAULT
        nums.append(picked)
    return max(nums) if nums else DEFAULT


def minutes(since, now):
    began = datetime.datetime.fromisoformat(since.replace("Z", "+00:00"))
    return (now - began).total_seconds() / 60


def stuck(runs, limits, jobs_of, now):
    """[(run, job, minutes in progress, limit)] for each in-progress run with a job past its limit + GRACE, merge
    groups first. `limits` maps a workflow path to its limit; `jobs_of(run id)` reads a run's jobs."""
    found = []
    for run in sorted(runs, key=lambda r: (ORDER.get(r.get("event"), 2), r["id"])):
        if run.get("status") != "in_progress":
            continue
        lim = limits.get(run.get("path", "").split("@")[0], DEFAULT)
        if minutes(run.get("run_started_at") or run["created_at"], now) < lim + GRACE:
            continue  # no job of it can be over yet: don't read its jobs
        late = [(j, minutes(j["started_at"], now)) for j in jobs_of(run["id"])
                if j.get("status") == "in_progress" and j.get("started_at")]
        late = [(j, m) for j, m in late if m >= lim + GRACE]
        if late:
            j, m = max(late, key=lambda x: x[1])
            found.append((run, j, m, lim))
    return found


def queue_pr(run):
    """The pull request a merge-group run tests, from its branch gh-readonly-queue/main/pr-<n>-<sha>, or None."""
    m = re.search(r"/pr-(\d+)-[0-9a-f]+$", run.get("head_branch") or "")
    return int(m.group(1)) if m else None


class Api:
    def __init__(self, repo, token):
        self.repo, self.token = repo, token

    def call(self, path, method="GET", body=None):
        req = urllib.request.Request(f"https://api.github.com/repos/{self.repo}/{path}", method=method,
                                     data=json.dumps(body).encode() if body is not None else None, headers={
                                         "Authorization": f"Bearer {self.token}",
                                         "Accept": "application/vnd.github+json",
                                         "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                raise Stop(f"HTTP {e.code} on {method} {path}")
            if e.code == 409 and method == "POST" and "cancel" in path:
                return {}  # the run is already ending (another tick, or GitHub): nothing to do
            raise

    def runs(self):
        return self.call("actions/runs?status=in_progress&per_page=100").get("workflow_runs", [])

    def run(self, run_id):
        return self.call(f"actions/runs/{run_id}")

    def jobs(self, run_id):
        out, page = [], 1
        while True:
            body = self.call(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
            out += body.get("jobs", [])
            if len(out) >= body.get("total_count", 0) or not body.get("jobs"):
                return out
            page += 1


def limits_here():
    return {f".github/workflows/{p.name}": limit(p.read_text()) for p in sorted(WORKFLOWS.glob("*.y*ml"))}


def summary(line):
    print(line, flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(line + "\n")


def check(api, act, now=None, wait=time.sleep):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    found = stuck(api.runs(), limits_here(), api.jobs, now)
    if not found:
        summary("No run has a job past its timeout.")
        return []
    summary("| Run | Event | Job | In progress | Its limit + grace | Action |\n|---|---|---|---|---|---|")
    for run, job, m, lim in found:
        what = "cancel" if act else "would cancel (dry run)"
        summary(f"| [{run['id']}]({run.get('html_url', '')}) {run.get('name', '')} | {run.get('event')} | "
                f"{job.get('name')} | {int(m)} min | {lim} + {GRACE} min | {what} |")
        if act:
            api.call(f"actions/runs/{run['id']}/cancel", "POST")
    if not act:
        return found
    wait(FORCE_AFTER)
    for run, job, m, lim in found:
        if api.run(run["id"]).get("status") != "completed":
            api.call(f"actions/runs/{run['id']}/force-cancel", "POST")
            summary(f"Run {run['id']} was still running {FORCE_AFTER} s after the cancel: force-cancelled.")
        pr = queue_pr(run) if run.get("event") == "merge_group" else None
        if pr:
            api.call(f"issues/{pr}/comments", "POST", {"body": (
                f"The merge queue's run [{run['id']}]({run.get('html_url', '')}) had a job, \"{job.get('name')}\", "
                f"in progress for {int(m)} min, past its workflow's {lim}-min timeout: its runner was lost and "
                f"GitHub never ended it. The stuck-run watchdog cancelled the run (scripts/ci-stuck.py). "
                "Requeue this pull request to test it again.")})
    return found


class Fake:
    def __init__(self, runs, jobs):
        self.runs_, self.jobs_, self.read = runs, jobs, []

    def jobs(self, run_id):
        self.read.append(run_id)
        return self.jobs_.get(run_id, [])


def selftest():
    now = datetime.datetime(2026, 11, 18, 12, 0, tzinfo=datetime.timezone.utc)
    ago = lambda m: (now - datetime.timedelta(minutes=m)).isoformat().replace("+00:00", "Z")
    RU, APP = ".github/workflows/real-unfold.yml", ".github/workflows/app.yml"
    limits = {RU: 75, APP: 118}

    def run(i, path=RU, event="merge_group", age=90, status="in_progress"):
        return {"id": i, "path": path, "event": event, "status": status, "run_started_at": ago(age),
                "head_branch": "gh-readonly-queue/main/pr-469-" + "a" * 40}

    def job(age, status="in_progress", name="Unfold with a book open"):
        return {"name": name, "status": status, "started_at": ago(age)}

    cases = [
        ("run 44213268613: a job 78 min into a 75-min limit is within the grace", [run(1)], {1: [job(78)]}, []),
        ("past the limit plus the grace, it is stuck", [run(2)], {2: [job(81)]}, [2]),
        ("a finished job is never stuck, however long ago it began", [run(3)], {3: [job(200, "completed")]}, []),
        ("a queued job (waiting in a lane) is never stuck", [run(4)], {4: [job(200, "queued")]}, []),
        ("an App shard at 100 min is within its workflow's 118", [run(5, APP, age=130)], {5: [job(100)]}, []),
        ("a run younger than its limit + grace: its jobs aren't read", [run(6, age=60)], {6: [job(81)]}, []),
        ("a completed run is left alone", [run(7, status="completed")], {7: [job(81)]}, []),
        ("an unknown workflow gets GitHub's 360-min default", [run(8, ".github/workflows/x.yml", age=400)],
         {8: [job(300)]}, []),
        ("merge groups first, then pull requests, then the rest",
         [run(9, event="push"), run(10, event="pull_request"), run(11)],
         {9: [job(90)], 10: [job(90)], 11: [job(90)]}, [11, 10, 9]),
    ]
    for name, runs, jobs, want in cases:
        api = Fake(runs, jobs)
        got = [r["id"] for r, *_ in stuck(runs, limits, api.jobs, now)]
        assert got == want, f"{name}: got {got}, want {want}"
        if "aren't read" in name:
            assert api.read == [], f"{name}: read jobs of {api.read}"
    assert queue_pr(run(1)) == 469 and queue_pr({"head_branch": "fix/x"}) is None
    wf = "on: push\njobs:\n  a:\n    runs-on: x\n    timeout-minutes: 75 # c\n    steps:\n      - run: y\n        timeout-minutes: 23\n"
    assert limit(wf) == 75, "the largest literal timeout"
    assert limit(wf + "  b:\n    runs-on: x\n    steps: []\n") == DEFAULT, "a job without one gets 360"
    assert limit(wf + "  c:\n    uses: ./w.yml\n    strategy:\n      matrix:\n        include:\n"
                      "          - timeout: 118 # 30 + 2 x 35.2\n") == 118, "a reusable caller's matrix timeout"
    assert limit(wf + "  d:\n    runs-on: x\n    timeout-minutes: ${{ inputs.t }}\n") == DEFAULT, "an expression"
    pick = "  e:\n    runs-on: x\n    timeout-minutes: ${{ needs.changes.outputs.native == 'false' && 12 || %s }}\n"
    assert limit(wf + pick % 35) == 75, "#580's build job: a choice between literals is its larger literal"
    assert limit(wf + pick % 90) == 90, "a choice's larger literal can be the workflow's limit"
    assert limit(wf + pick % "inputs.t") == DEFAULT, "a choice with a branch that isn't a literal"
    assert limit(wf + "  f:\n    runs-on: x\n    timeout-minutes: ${{ (a || b) && 12 || 35 }}\n") == DEFAULT, \
        "an expression it can't split safely"
    here = limits_here()
    # Read, not pinned: a pinned 75 failed every watchdog run once #463 set 77, and a floor of 118 for App failed
    # them again when a shard's limit fell to 107. Each must be a literal the parser found (30 or more), below the
    # 360-minute default it falls back to.
    assert 30 <= here[RU] < DEFAULT and 30 <= here[APP] < DEFAULT, f"this repository's limits: {here}"
    print(f"ci-stuck selftest: {len(cases) + 10} cases pass")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    if not argv or argv[0] != "check":
        print(__doc__, file=sys.stderr)
        return 2
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (repo and token):
        print("ci-stuck: needs GITHUB_REPOSITORY and GITHUB_TOKEN", file=sys.stderr)
        return 2
    try:
        check(Api(repo, token), "--act" in argv)
    except Stop as e:
        summary(f"::warning title=Stuck-run watchdog stopped::{e}; it acts no further this tick.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
