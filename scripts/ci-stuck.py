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

It also cancels merge-group runs nobody will read (`orphans`). When the merge queue rebuilds a group, the old group's
runs keep going: on 2026-11-18 runs 44273299109 and 44273299138 (head f3f2821d, a #471 group built at 09:09Z) and
44261384475 (head ed5f14c2, an earlier #469 group) held 4 + 1 + 7 macOS runners while the queue's front group, #469's
run 44273931050, had 39 jobs queued for 76 min. Each pass reads the queue's entries over GraphQL and cancels every
queued or in-progress merge_group run whose head commit is neither an entry's head commit nor one of main's last
MAIN_DEPTH commits (a group that just merged: its run may still be writing the proof a main push reads). A run younger
than MIN_AGE is left alone, in case the queue hasn't shown its entry yet. It fails closed: a queue read that errors,
returns GraphQL errors, has no merge queue, or doesn't list every entry, cancels nothing.

    python3 -I scripts/ci-stuck.py orphans [--act]   # only the orphan sweep: the merge_group trigger runs this
"""
import contextlib
import datetime
import io
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
MIN_AGE = 2  # minutes: a merge-group run younger than this is never an orphan (its entry may not show yet)
MAIN_DEPTH = 50  # main's newest commits: a merge-group run on one of them belongs to a group that merged
LIVE = ("queued", "in_progress", "waiting", "pending", "requested")  # a run in any of these can still take a runner
QUEUE_QUERY = """query($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) {
    mergeQueue(branch: "main") { entries(first: 100) { totalCount nodes { headCommit { oid } } } }
    ref(qualifiedName: "refs/heads/main") { target { ... on Commit { history(first: %d) { nodes { oid } } } } }
  }
}""" % MAIN_DEPTH
WORKFLOWS = Path(__file__).resolve().parent.parent / ".github" / "workflows"


class Stop(Exception):
    """GitHub said 403 or 429: stop calling it."""


def limit(text):
    """A workflow file's longest job timeout in minutes: the largest literal `timeout-minutes:` or matrix `timeout:`,
    or DEFAULT when a job that runs on a runner sets none (an expression counts as none: it can't be read here)."""
    nums = [int(n) for n in re.findall(r"^\s*(?:-\s+)?timeout(?:-minutes)?:\s*(\d+)\s*(?:#.*)?$", text, re.M)]
    body = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    for block in re.split(r"\n(?=  [A-Za-z0-9_-]+:[ \t]*\n)", "\n" + body):
        if re.search(r"^    runs-on:", block, re.M) and not re.search(r"^    timeout-minutes:\s*\d+", block, re.M):
            return DEFAULT
    return max(nums) if nums else DEFAULT


def minutes(since, now):
    began = datetime.datetime.fromisoformat(since.replace("Z", "+00:00"))
    return (now - began).total_seconds() / 60


def stuck(runs, limits, jobs_of, now):
    """[(run, job, minutes in progress, limit)] for each in-progress run with a job past its limit + GRACE, merge
    groups first. `limits` maps a workflow path to its limit; `jobs_of(run id)` reads a run's jobs."""
    found = []
    for run in sorted(runs, key=lambda r: (ORDER.get(r.get("event"), 2), r["id"])):
        if run.get("status") not in ("in_progress", "queued"):
            continue  # a merge-group run can say `queued` while some of its jobs are in progress
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


def keep(reply):
    """The head commits a merge-group run may be on and still be read: every queue entry's, and main's newest
    MAIN_DEPTH. None (cancel nothing) unless the reply is whole: no errors, a merge queue, every entry listed, main read."""
    try:
        if not isinstance(reply, dict) or reply.get("errors"):
            return None
        repo = reply["data"]["repository"]
        entries = repo["mergeQueue"]["entries"]
        nodes = entries["nodes"]
        if len(nodes) != entries["totalCount"]:
            return None
        shas = {n["headCommit"]["oid"] for n in nodes if n.get("headCommit")}
        shas |= {n["oid"] for n in repo["ref"]["target"]["history"]["nodes"]}
        return shas
    except (KeyError, TypeError):
        return None


def orphans(runs, kept, now):
    """The merge-group runs nobody will read: queued or in progress, at least MIN_AGE old, and on a head commit not
    in `kept`. An unread queue (`kept` None) gives none."""
    if kept is None:
        return []
    return [r for r in runs if r.get("event") == "merge_group" and r.get("status") in LIVE
            and (r.get("head_branch") or "").startswith("gh-readonly-queue/main/")
            and r.get("head_sha") not in kept and minutes(r["created_at"], now) >= MIN_AGE]


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
        # A run whose jobs have only partly started reports `queued` (merge-group run 44273931050 did, with 3 jobs
        # in progress), so both lists are read.
        return [r for status in ("in_progress", "queued")
                for r in self.call(f"actions/runs?status={status}&per_page=100").get("workflow_runs", [])]

    def group_runs(self):
        return self.call("actions/runs?event=merge_group&per_page=100").get("workflow_runs", [])

    def queue(self):
        """The merge queue's entries and main's newest commits, or None when the read fails."""
        owner, name = self.repo.split("/", 1)
        req = urllib.request.Request("https://api.github.com/graphql", method="POST", data=json.dumps({
            "query": QUEUE_QUERY, "variables": {"owner": owner, "name": name}}).encode(), headers={
                "Authorization": f"Bearer {self.token}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                raise Stop(f"HTTP {e.code} on the merge queue's GraphQL read")
            summary(f"::warning title=Merge queue unread::HTTP {e.code}; no orphaned run is cancelled this tick.")
            return None
        except (urllib.error.URLError, OSError, ValueError) as e:
            summary(f"::warning title=Merge queue unread::{e}; no orphaned run is cancelled this tick.")
            return None

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


def sweep(api, act, now, cancelled):
    """Cancel the merge-group runs nobody will read, appending each to `cancelled` as it goes (so an error part way
    still leaves the ones cancelled to be force-cancelled). Returns them."""
    reply = api.queue()
    kept = keep(reply)
    if kept is None:
        if reply is not None:
            summary("::warning title=Merge queue unread::The queue's reply was not whole "
                    f"({json.dumps(reply)[:300]}); no orphaned run is cancelled this tick.")
        return []
    found = orphans(api.group_runs(), kept, now)
    if not found:
        summary("No merge-group run is orphaned: each is on a commit the queue or main still has.")
        return []
    summary("| Orphaned merge-group run | Head | Status | Action |\n|---|---|---|---|")
    for run in found:
        what = "cancel" if act else "would cancel (dry run)"
        summary(f"| [{run['id']}]({run.get('html_url', '')}) {run.get('name', '')} | {run.get('head_sha', '')[:8]} "
                f"({run.get('head_branch', '')}) | {run.get('status')} | {what} |")
        if act:
            api.call(f"actions/runs/{run['id']}/cancel", "POST")
            cancelled.append(run)
    return found


def force(api, ids):
    """Force-cancel each run still not completed FORCE_AFTER seconds after its cancel."""
    for rid in ids:
        if api.run(rid).get("status") != "completed":
            api.call(f"actions/runs/{rid}/force-cancel", "POST")
            summary(f"Run {rid} was still running {FORCE_AFTER} s after the cancel: force-cancelled.")


def check(api, act, now=None, wait=time.sleep, stuck_too=True):
    now = now or datetime.datetime.now(datetime.timezone.utc)
    found = stuck(api.runs(), limits_here(), api.jobs, now) if stuck_too else []
    cancelled = []
    try:
        lost = sweep(api, act, now, cancelled)
    except (Stop, urllib.error.URLError, OSError, ValueError) as e:  # HTTPError is a URLError
        summary(f"::warning title=Orphan sweep stopped::{e}; it cancels no more orphaned runs this tick.")
        lost = cancelled
    found = [f for f in found if f[0]["id"] not in {r["id"] for r in lost}]
    if stuck_too and not found:
        summary("No run has a job past its timeout.")
    if found:
        summary("| Run | Event | Job | In progress | Its limit + grace | Action |\n|---|---|---|---|---|---|")
    for run, job, m, lim in found:
        what = "cancel" if act else "would cancel (dry run)"
        summary(f"| [{run['id']}]({run.get('html_url', '')}) {run.get('name', '')} | {run.get('event')} | "
                f"{job.get('name')} | {int(m)} min | {lim} + {GRACE} min | {what} |")
        if act:
            api.call(f"actions/runs/{run['id']}/cancel", "POST")
    if not act or not (found or lost):
        return lost, found
    wait(FORCE_AFTER)
    force(api, [r["id"] for r in lost] + [run["id"] for run, *_ in found])
    for run, job, m, lim in found:
        pr = queue_pr(run) if run.get("event") == "merge_group" else None
        if pr:
            api.call(f"issues/{pr}/comments", "POST", {"body": (
                f"The merge queue's run [{run['id']}]({run.get('html_url', '')}) had a job, \"{job.get('name')}\", "
                f"in progress for {int(m)} min, past its workflow's {lim}-min timeout: its runner was lost and "
                f"GitHub never ended it. The stuck-run watchdog cancelled the run (scripts/ci-stuck.py). "
                "Requeue this pull request to test it again.")})
    return lost, found


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
        ("a merge-group run that says `queued` with a job in progress is still read",
         [run(12, status="queued")], {12: [job(81)]}, [12]),
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
    here = limits_here()
    assert here[RU] == 75 and here[APP] >= 118, f"this repository's limits: {here}"
    print(f"ci-stuck selftest: {len(cases) + 6} cases pass")
    return len(cases) + 6 + selftest_orphans(now, ago)


def queue_errors():
    """Api.queue: HTTP 403 or 429 stops the tick (Stop); any other failure is an unread queue (None)."""
    real = urllib.request.urlopen

    def raising(err):
        def urlopen(*a, **k):
            raise err
        return urlopen
    api = Api("ourostack/gatefold", "t")
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            for code in (403, 429):
                urllib.request.urlopen = raising(urllib.error.HTTPError("u", code, "x", {}, None))
                try:
                    api.queue()
                    raise AssertionError(f"HTTP {code} must stop the tick")
                except Stop:
                    pass
            for err in (urllib.error.HTTPError("u", 502, "x", {}, None), urllib.error.URLError("dns"), OSError("reset")):
                urllib.request.urlopen = raising(err)
                assert api.queue() is None, f"{err}: an unread queue"
    finally:
        urllib.request.urlopen = real
    return 2


FRONT, OLD_471, OLD_469, MAIN = "f2dcc8c1" + "0" * 32, "f3f2821d" + "0" * 32, "ed5f14c2" + "0" * 32, "cef8d590" + "0" * 32


def reply(entries=(FRONT, None, None), main=(MAIN,), total=None):
    """A GraphQL reply shaped like the live one: entries with a head commit or (QUEUED, not built yet) none."""
    nodes = [{"headCommit": {"oid": e} if e else None} for e in entries]
    return {"data": {"repository": {
        "mergeQueue": {"entries": {"totalCount": len(nodes) if total is None else total, "nodes": nodes}},
        "ref": {"target": {"history": {"nodes": [{"oid": m} for m in main]}}}}}}


class FakeApi:
    """Records every write; `ends` lists the runs that complete after a plain cancel."""

    def __init__(self, queue, groups, ends=()):
        self.queue_, self.groups, self.ends, self.posts = queue, groups, set(ends), []

    def queue(self):
        return self.queue_

    def group_runs(self):
        return self.groups

    def runs(self):
        return []

    def jobs(self, run_id):
        return []

    def run(self, run_id):
        return {"status": "completed" if run_id in self.ends else "in_progress"}

    def call(self, path, method="GET", body=None):
        self.posts.append(path)
        return {}


def selftest_orphans(now, ago):
    def grun(i, sha, status="in_progress", age=60, event="merge_group"):
        return {"id": i, "event": event, "status": status, "head_sha": sha, "created_at": ago(age),
                "name": "App", "head_branch": "gh-readonly-queue/main/pr-1-" + "b" * 40}

    incident = [grun(44273931050, FRONT, "queued", 77), grun(44273299109, OLD_471, age=81),
                grun(44273299138, OLD_471, age=81), grun(44261384475, OLD_469, "queued", 165)]
    kept = keep(reply())
    cases = [
        ("2026-11-18: the front group's run stays; the rebuilt #471 group's and the old #469 group's go",
         incident, kept, [44273299109, 44273299138, 44261384475]),
        ("a run on one of main's newest commits (a group that just merged) stays", [grun(1, MAIN)], kept, []),
        ("a run younger than MIN_AGE stays, in case its entry isn't listed yet", [grun(2, OLD_471, age=1)], kept, []),
        ("a completed run is left alone", [grun(3, OLD_471, "completed")], kept, []),
        ("a pull-request run is never an orphan", [grun(4, OLD_471, event="pull_request")], kept, []),
        ("an unread queue cancels nothing", incident, None, []),
        ("a run of another branch's queue is left alone",
         [{**grun(5, OLD_471), "head_branch": "gh-readonly-queue/release/pr-1-" + "b" * 40}], kept, []),
    ]
    for name, runs, k, want in cases:
        got = [r["id"] for r in orphans(runs, k, now)]
        assert got == want, f"{name}: got {got}, want {want}"
    assert kept == {FRONT, MAIN}, f"a QUEUED entry has no head commit yet: {kept}"
    fail_closed = [
        ("GraphQL errors, even beside data", {**reply(), "errors": [{"message": "Something went wrong"}]}),
        ("no merge queue on main", {"data": {"repository": {"mergeQueue": None, "ref": reply()["data"]["repository"]["ref"]}}}),
        ("more entries than listed", reply(total=101)),
        ("main unread", {"data": {"repository": {**reply()["data"]["repository"], "ref": None}}}),
        ("no reply", None),
    ]
    for name, r in fail_closed:
        assert keep(r) is None, f"{name}: must cancel nothing, kept {keep(r)}"

    # End to end, with a fake API: what gets cancelled, force-cancelled, or left. Its summary lines go nowhere, so a
    # CI step summary never shows the fake runs.
    out, os.environ["GITHUB_STEP_SUMMARY"] = os.environ.pop("GITHUB_STEP_SUMMARY", None), ""
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            end_to_end(now, incident)
        queue_checked = queue_errors()
    finally:
        if out is None:
            os.environ.pop("GITHUB_STEP_SUMMARY")
        else:
            os.environ["GITHUB_STEP_SUMMARY"] = out
    n = len(cases) + len(fail_closed) + 5 + queue_checked
    print(f"ci-stuck selftest: {n} orphan cases pass")
    return n


def end_to_end(now, incident):
    waits = []
    api = FakeApi(reply(), incident, ends={44273299138})
    lost, _ = check(api, True, now=now, wait=waits.append, stuck_too=False)
    base = "actions/runs/{}/"
    assert [r["id"] for r in lost] == [44273299109, 44273299138, 44261384475]
    assert api.posts == [base.format(44273299109) + "cancel", base.format(44273299138) + "cancel",
                         base.format(44261384475) + "cancel", base.format(44273299109) + "force-cancel",
                         base.format(44261384475) + "force-cancel"], f"cancel, wait, force what still runs: {api.posts}"
    assert waits == [FORCE_AFTER], "one wait before the force-cancels"
    api = FakeApi({"errors": [{"message": "Something went wrong"}]}, incident)
    check(api, True, now=now, wait=waits.append)
    assert api.posts == [], f"fail closed: an errored queue read cancels nothing, posted {api.posts}"
    api = FakeApi(reply(), incident)

    def stop():
        raise Stop("HTTP 403 on the merge queue's GraphQL read")
    api.queue, ran = stop, []
    api.runs = lambda: ran.append(1) or []
    check(api, True, now=now, wait=waits.append)
    assert ran == [1] and api.posts == [], "a sweep that stops still lets the stuck check run, and cancels nothing"
    api = FakeApi(reply(), incident)
    check(api, False, now=now, wait=waits.append)
    assert api.posts == [], f"a dry run posts nothing: {api.posts}"
    api = FakeApi(reply(), [incident[0]])
    check(api, True, now=now, wait=waits.append)
    assert api.posts == [] and waits == [FORCE_AFTER], "nothing orphaned: no cancel and no wait"


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    if not argv or argv[0] not in ("check", "orphans"):
        print(__doc__, file=sys.stderr)
        return 2
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (repo and token):
        print("ci-stuck: needs GITHUB_REPOSITORY and GITHUB_TOKEN", file=sys.stderr)
        return 2
    try:
        check(Api(repo, token), "--act" in argv, stuck_too=argv[0] == "check")
    except Stop as e:
        summary(f"::warning title=Stuck-run watchdog stopped::{e}; it acts no further this tick.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
