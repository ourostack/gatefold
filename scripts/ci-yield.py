#!/usr/bin/env python3
"""Hold a pull request's macOS jobs while the merge queue's own macOS jobs wait for a runner.

On 2026-11-18 the merge queue's front group (#469, run 44273931050) had 39 xcode-27 jobs queued for 76 min while pull
request runs started at 10:28Z got runners. Main can't move until its group runs, so a pull request's macOS jobs wait
for it: the workflow's `yield` job (.github/workflows/yield.yml, on ubuntu) runs this before any of them starts.

    python3 -I scripts/ci-yield.py wait     # GITHUB_REPOSITORY, GITHUB_TOKEN
    python3 -I scripts/ci-yield.py --selftest

Every POLL seconds it reads main's merge-group runs that haven't completed, keeps the newest of each workflow (an
older one belongs to a group the queue replaced or will drop; scripts/ci-stuck.py cancels those), and reads their
jobs, newest first, stopping at the first macOS job (a `macos-*` or `xcode-*` label) still queued. While there is one,
it waits. A poll costs 1 call plus one per workflow read until the first hit: at most 1 plus the number of workflows
with a merge-group run (about 4 today).
It stops waiting, and the pull request's jobs start, when
  - no merge-group macOS job is queued,
  - it has waited CAP minutes (it never makes a job wait longer than that),
  - any read fails, HTTP 403 and 429 included: an error never holds a job back,
  - the token has fewer than FLOOR API calls left this hour: the budget is shared with every workflow's token, and
    scripts/ci-proof.py fails closed (running main's whole suite on Macs) when it can't read.
It always exits 0, and yield.yml's job has continue-on-error: yielding may delay a job, never skip or fail one.
"""
import contextlib
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

POLL = 120  # seconds between reads: under one a minute, so several waiting pull requests stay within the API budget
CAP = 30 * 60  # seconds: never hold a job longer
FLOOR = 300  # API calls left this hour below which it stops reading and lets the jobs start
MACOS = re.compile(r"^(macos|xcode)-", re.I)


def waiting(runs, jobs_of):
    """(run, count) for the newest unfinished merge-group run with a macOS job queued for a runner, or None."""
    newest = {}
    for r in runs:
        if (r.get("event") == "merge_group" and r.get("status") != "completed"
                and (r.get("head_branch") or "").startswith("gh-readonly-queue/main/")):
            w = r.get("workflow_id")
            if w not in newest or r["id"] > newest[w]["id"]:
                newest[w] = r
    for run in sorted(newest.values(), key=lambda r: r["id"], reverse=True):
        queued = [j for j in jobs_of(run["id"])
                  if j.get("status") == "queued" and any(MACOS.match(l or "") for l in j.get("labels") or [])]
        if queued:
            return run, len(queued)
    return None


class Low(Exception):
    """The token's API budget is nearly spent."""


class Api:
    def __init__(self, repo, token):
        self.repo, self.token = repo, token

    def get(self, path):
        req = urllib.request.Request(f"https://api.github.com/repos/{self.repo}/{path}", headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            left = resp.headers.get("X-RateLimit-Remaining")
            if left is not None and int(left) < FLOOR:
                raise Low(f"{left} API calls left this hour, under {FLOOR}")
            return json.loads(resp.read())

    def runs(self):
        return self.get("actions/runs?event=merge_group&per_page=50").get("workflow_runs", [])

    def jobs(self, run_id):
        out, page = [], 1
        while True:
            body = self.get(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
            out += body.get("jobs", [])
            if len(out) >= body.get("total_count", 0) or not body.get("jobs"):
                return out
            page += 1


def say(line):
    print(line, flush=True)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a") as f:
            f.write(line + "\n")


def wait(api, clock=time.monotonic, sleep=time.sleep):
    """Wait while the merge queue has a macOS job queued, up to CAP. Returns why it stopped: 'clear', 'cap' or 'error'."""
    start = clock()
    while True:
        try:
            found = waiting(api.runs(), api.jobs)
        except Exception as e:  # any failure lets the jobs run
            say(f"::notice title=Not yielding::Could not read the merge queue's runs ({type(e).__name__}: {e}); "
                "this pull request's macOS jobs start now.")
            return "error"
        held = int(clock() - start)
        if not found:
            say(f"No merge-group macOS job is waiting for a runner; this pull request's macOS jobs start "
                f"(held {held // 60} min {held % 60} s).")
            return "clear"
        run, n = found
        if held + POLL > CAP:
            say(f"::notice title=Yield cap reached::Merge-group run {run['id']} still has {n} macOS job(s) queued, "
                f"but this pull request has waited {held // 60} min, its cap; its macOS jobs start now.")
            return "cap"
        say(f"Merge-group run {run['id']} ({run.get('name', '')}) has {n} macOS job(s) queued for a runner; "
            f"waiting {POLL} s ({held // 60} min held so far, cap {CAP // 60}).")
        sleep(POLL)


class Fake:
    """A scripted API: each poll reads the next (runs, {run id: jobs}) state, or raises it if it is an exception."""

    def __init__(self, states):
        self.states, self.calls = list(states), 0

    def runs(self):
        self.calls += 1
        state = self.states.pop(0) if len(self.states) > 1 else self.states[0]
        if isinstance(state, Exception):
            raise state
        self.now = state
        return state[0]

    def jobs(self, run_id):
        self.calls += 1
        return self.now[1].get(run_id, [])


def selftest():
    def run(i, status="in_progress", event="merge_group", workflow=1, branch="gh-readonly-queue/main/pr-469-" + "c" * 40):
        return {"id": i, "status": status, "event": event, "name": "App", "workflow_id": workflow, "head_branch": branch}

    def job(status="queued", label="xcode-27"):
        return {"status": status, "labels": [label]}

    front = ([run(44273931050, "queued")], {44273931050: [job("completed", "ubuntu-latest")] + [job()] * 39})
    clear = ([run(44273931050)], {44273931050: [job("in_progress")] * 39})
    cases = [
        ("2026-11-18: the front group's 39 queued xcode-27 jobs hold a pull request", front, True),
        ("their jobs running, not queued: go", clear, False),
        ("a queued Linux job doesn't hold a Mac", ([run(1)], {1: [job(label="ubuntu-latest")]}), False),
        ("a macos-* label counts too", ([run(1)], {1: [job(label="macos-26")]}), True),
        ("a completed merge-group run doesn't hold", ([run(1, "completed")], {1: [job()]}), False),
        ("a pull request's queued Mac job doesn't hold another", ([run(1, event="pull_request")], {1: [job()]}), False),
        ("no merge-group run at all: go", ([], {}), False),
        ("an older group's run of the same workflow (an orphan) doesn't hold",
         ([run(44261384475), run(44273931050)], {44261384475: [job()], 44273931050: [job("in_progress")]}), False),
        ("another branch's queue doesn't hold", ([run(1, branch="gh-readonly-queue/release/pr-1-" + "c" * 40)], {1: [job()]}), False),
    ]
    for name, (runs, jobs), want in cases:
        got = waiting(runs, lambda i: jobs.get(i, []))
        assert bool(got) == want, f"{name}: got {got}"
    got = waiting([run(1, workflow=1), run(2, workflow=2)], lambda i: [job()])
    assert got[0]["id"] == 2, "newest run first"
    reads = []
    waiting([run(1, workflow=1), run(2, workflow=2), run(3, workflow=3)],
            lambda i: reads.append(i) or ([job()] if i == 3 else []))
    assert reads == [3], f"it stops at the first run with a queued Mac job: read {reads}"

    out, os.environ["GITHUB_STEP_SUMMARY"] = os.environ.pop("GITHUB_STEP_SUMMARY", None), ""
    try:
        loops = run_loops(front, clear)
    finally:
        if out is None:
            os.environ.pop("GITHUB_STEP_SUMMARY")
        else:
            os.environ["GITHUB_STEP_SUMMARY"] = out
    n = len(cases) + 2 + loops + budget()
    print(f"ci-yield selftest: {n} cases pass")


def budget():
    """Api.get raises Low under FLOOR calls left, and wait() then lets the jobs start."""
    class Resp(io.BytesIO):
        def __init__(self, left):
            super().__init__(b'{"workflow_runs": []}')
            self.headers = {"X-RateLimit-Remaining": str(left)}

        def __enter__(self):
            return self

        def __exit__(self, *a):
            return False

    real, api = urllib.request.urlopen, Api("ourostack/gatefold", "t")
    try:
        urllib.request.urlopen = lambda *a, **k: Resp(FLOOR - 1)
        try:
            api.runs()
            raise AssertionError("under the floor must stop reading")
        except Low:
            pass
        with contextlib.redirect_stdout(io.StringIO()):
            assert wait(api, sleep=lambda s: None) == "error", "under the floor: the jobs start"
        urllib.request.urlopen = lambda *a, **k: Resp(FLOOR)
        assert api.runs() == [], "at the floor it still reads"
    finally:
        urllib.request.urlopen = real
    return 3


def run_loops(front, clear):
    def loop(states):
        t = [0.0]
        sleeps = []
        api = Fake(states)
        with contextlib.redirect_stdout(io.StringIO()):
            why = wait(api, clock=lambda: t[0], sleep=lambda s: (sleeps.append(s), t.__setitem__(0, t[0] + s)))
        return why, sleeps, api

    why, sleeps, _ = loop([clear])
    assert (why, sleeps) == ("clear", []), "nothing queued: no wait at all"
    why, sleeps, _ = loop([front, front, front, clear])
    assert (why, sleeps) == ("clear", [POLL] * 3), f"waits a minute a poll until the queue's Macs start: {why} {sleeps}"
    why, sleeps, api = loop([front])
    assert why == "cap" and sum(sleeps) <= CAP and sum(sleeps) + POLL > CAP, f"stops at the cap: {sum(sleeps)} s"
    assert all(s >= 60 for s in sleeps), "polls at most once a minute"
    assert api.calls <= 2 * (CAP // POLL + 1), f"two reads a waiting poll: {api.calls}"
    why, sleeps, _ = loop([urllib.error.HTTPError("u", 429, "rate limited", {}, None)])
    assert (why, sleeps) == ("error", []), "HTTP 429: go at once"
    why, sleeps, _ = loop([front, OSError("network")])
    assert (why, sleeps) == ("error", [POLL]), "an error after a wait: go at once"
    return 5


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    if not argv or argv[0] != "wait":
        print(__doc__, file=sys.stderr)
        return 2
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (repo and token):
        say("::notice title=Not yielding::No GITHUB_REPOSITORY or GITHUB_TOKEN; the macOS jobs start now.")
        return 0
    wait(Api(repo, token))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
