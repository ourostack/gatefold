#!/usr/bin/env python3
"""Merge queue only: when a job fails, cancel every other run testing the same merge-group commit, so the queue drops
the entry and re-forms at once instead of waiting for the slowest run (Real unfold, 60+ min) to finish.

    python3 -I scripts/ci-fail-fast.py              # in the failed job: GITHUB_EVENT_NAME, GITHUB_SHA, GITHUB_RUN_ID, ...
    python3 -I scripts/ci-fail-fast.py own <run id> # in .github/workflows/fail-fast.yml
    python3 -I scripts/ci-fail-fast.py --selftest

Called by .github/actions/fail-fast as the last step of each merge-group job, under `if: failure()`, after every log
upload. It reads the runs on the commit (one call), cancels each that is a merge_group run, isn't finished and isn't
this one, then dispatches .github/workflows/fail-fast.yml for this run. A job can't cancel its own run: the cancel
reaches the failed job too and turns its "failure" into "cancelled" (seen on a probe, run 44237674247). So the
dispatched workflow waits until a failed job in this run has finished as "failure", then cancels the run, which stops
its other jobs and the gate that waits on them.

On any other event it does nothing: a push to main, a pull request or a dispatch never fails fast. A run that is
already ending (HTTP 409) is fine; HTTP 403 or 429 stops it with a warning. It never fails a job: the job has failed
already, and this only saves the queue's time.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request


class Stop(Exception):
    pass


WAIT = 300   # seconds the dispatched workflow waits for the failed job to finish
NAP = 5


def targets(runs, sha, mine, event):
    """Other run ids to cancel: merge_group runs on this commit that aren't finished. Empty off the queue."""
    if event != "merge_group":
        return []
    return sorted(r["id"] for r in runs if r.get("event") == "merge_group" and r.get("head_sha") == sha
                  and r.get("status") != "completed" and r["id"] != mine)


def ready(run, jobs):
    """Whether the dispatched workflow may cancel `run` now: a merge_group run, not finished, with a job finished as
    "failure", so cancelling can't take that conclusion away."""
    return (run.get("event") == "merge_group" and run.get("status") != "completed"
            and any(j.get("status") == "completed" and j.get("conclusion") == "failure" for j in jobs))


class Api:
    def __init__(self, repo, token):
        self.repo, self.token = repo, token

    def call(self, path, method="GET", body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(f"https://api.github.com/repos/{self.repo}/{path}", data=data, method=method,
                                     headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"})
        try:
            with urllib.request.urlopen(req, timeout=30) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            if e.code in (403, 429):
                raise Stop(f"HTTP {e.code} on {method} {path}")
            if e.code == 409 and method == "POST":
                return {}  # already ending
            raise


def selftest():
    sha, other = "a" * 40, "b" * 40

    def run(i, event="merge_group", status="in_progress", h=sha):
        return {"id": i, "event": event, "status": status, "head_sha": h}

    runs = [run(1), run(2), run(3, status="queued"), run(4, status="completed"), run(5, "push"),
            run(6, "pull_request"), run(7, h=other)]
    cases = [
        ("the queue's other runs on this commit, never this one", runs, 2, "merge_group", [1, 3]),
        ("a finished run is left as it is", [run(4, status="completed")], 9, "merge_group", []),
        ("a push to main never fails fast", runs, 2, "push", []),
        ("a pull request never fails fast", runs, 2, "pull_request", []),
        ("a dispatch never fails fast", runs, 2, "workflow_dispatch", []),
        ("another commit's group is never touched", [run(7, h=other), run(2)], 2, "merge_group", []),
        ("push and pull-request runs on the same commit are never touched", [run(5, "push"), run(6, "pull_request")],
         2, "merge_group", []),
    ]
    for name, rs, mine, event, want in cases:
        got = targets(rs, sha, mine, event)
        assert got == want, f"{name}: got {got}, want {want}"
    done, going = {"status": "completed", "conclusion": "failure"}, {"status": "in_progress", "conclusion": None}
    gates = [
        ("the failed job has finished: cancel the run", run(2), [done, going], True),
        ("the failed job is still in its last step: wait", run(2), [going, going], False),
        ("a job finished cancelled isn't a failure: wait", run(2), [{"status": "completed", "conclusion": "cancelled"}],
         False),
        ("the run already finished: nothing to do", run(2, status="completed"), [done], False),
        ("a push run is never cancelled", run(5, "push"), [done, going], False),
    ]
    for name, r, jobs, want in gates:
        assert ready(r, jobs) == want, f"{name}: got {not want}"
    class Fake:  # answers each poll with the next (run, jobs) state, the last one repeating
        def __init__(self, states):
            self.states, self.posts, self.state = states, [], states[0]

        def call(self, path, method="GET", body=None):
            if method == "POST":
                self.posts.append(path)
                return {}
            if path.endswith("/jobs?filter=latest&per_page=100"):
                return {"jobs": self.state[1]}
            self.state = self.states.pop(0) if len(self.states) > 1 else self.states[0]
            return self.state[0]

    global NAP, WAIT
    NAP, WAIT = 0, 10
    fake = Fake([(run(2), [going]), (run(2), [done, going])])
    own(fake, 2)
    assert fake.posts == ["actions/runs/2/cancel"], f"own cancels once its failed job has finished: {fake.posts}"
    fake, WAIT = Fake([(run(2), [going])]), 0
    own(fake, 2)
    assert fake.posts == [], f"own gives up at its limit without cancelling: {fake.posts}"
    print(f"ci-fail-fast selftest: {len(cases) + len(gates) + 2} cases pass")


def own(api, run_id):
    """In the dispatched workflow: wait until a job in `run_id` has finished as "failure", then cancel the run."""
    waited = 0
    while True:
        run = api.call(f"actions/runs/{run_id}")
        jobs = api.call(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs", [])
        if ready(run, jobs):
            print(f"::notice title=Merge queue fails fast::{run.get('name')} run {run_id} has a failed job, so the "
                  "rest of it is cancelled: the queue drops this entry now.", flush=True)
            api.call(f"actions/runs/{run_id}/cancel", "POST")
            return
        if run.get("status") == "completed" or run.get("event") != "merge_group" or waited >= WAIT:
            print(f"ci-fail-fast: run {run_id} is {run.get('status')} ({run.get('event')}); nothing to cancel")
            return
        time.sleep(NAP)
        waited += NAP


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    env = os.environ.get
    if argv[:1] == ["own"]:
        try:
            own(Api(env("GITHUB_REPOSITORY", ""), env("GITHUB_TOKEN", "")), int(argv[1]))
        except Stop as e:
            print(f"::warning title=Fail-fast stopped::{e}; the run finishes on its own.")
        return 0
    event, sha, mine = env("GITHUB_EVENT_NAME", ""), env("GITHUB_SHA", ""), int(env("GITHUB_RUN_ID") or 0)
    if event != "merge_group":
        print(f"ci-fail-fast: {event or 'no'} event, not the merge queue: nothing to cancel")
        return 0
    api = Api(env("GITHUB_REPOSITORY", ""), env("GITHUB_TOKEN", ""))
    try:
        runs = api.call(f"actions/runs?head_sha={sha}&event=merge_group&per_page=100").get("workflow_runs", [])
        ids = targets(runs, sha, mine, event)
        names = {r["id"]: r.get("name", "") for r in runs}
        for i in ids:
            print(f"::notice title=Merge queue fails fast::A job failed, so run {i} ({names.get(i)}) on {sha[:7]} "
                  "is cancelled: the queue drops this entry now (scripts/ci-fail-fast.py).", flush=True)
            api.call(f"actions/runs/{i}/cancel", "POST")
        # This run's own other jobs: a cancel from here would turn this job's failure into "cancelled".
        api.call("actions/workflows/fail-fast.yml/dispatches", "POST",
                 {"ref": env("FAIL_FAST_REF", "main"), "inputs": {"run": str(mine)}})
        print(f"ci-fail-fast: asked fail-fast.yml to cancel the rest of run {mine} once this job has finished")
    except Stop as e:
        print(f"::warning title=Fail-fast stopped::{e}; the other runs finish on their own.")
    except Exception as e:  # never turn a failed job's cleanup into a second failure
        print(f"::warning title=Fail-fast could not cancel::{e!r}; the other runs finish on their own.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
