#!/usr/bin/env python3
"""Merge queue only: when a job fails, cancel every other run testing the same merge-group commit, so the queue drops
the entry and re-forms at once instead of waiting for the slowest run (Real unfold, 60+ min) to finish.

    python3 -I scripts/ci-fail-fast.py           # GITHUB_EVENT_NAME, GITHUB_SHA, GITHUB_RUN_ID, GITHUB_REPOSITORY, GITHUB_TOKEN
    python3 -I scripts/ci-fail-fast.py --selftest

Called by .github/actions/fail-fast as the last step of each merge-group job, under `if: failure()`, so the failed
job keeps its "failure" conclusion and every log it uploaded first. It reads the runs on the commit (one call) and
cancels each that is a merge_group run, isn't finished, and isn't this one; then this run, last, so its own other jobs
stop too. On any other event it does nothing: a push to main, a pull request or a dispatch never fails fast. A run
that is already ending (HTTP 409) is fine; HTTP 403 or 429 stops it with a warning. It never fails the job: the job
has failed already, and this only saves the queue's time.
"""
import json
import os
import sys
import urllib.error
import urllib.request


class Stop(Exception):
    pass


def targets(runs, sha, own, event):
    """Run ids to cancel, own run last: merge_group runs on this commit that aren't finished. Empty off the queue."""
    if event != "merge_group":
        return []
    others = sorted(r["id"] for r in runs if r.get("event") == "merge_group" and r.get("head_sha") == sha
                    and r.get("status") != "completed" and r["id"] != own)
    mine = [r["id"] for r in runs if r["id"] == own and r.get("status") != "completed"]
    return others + mine


class Api:
    def __init__(self, repo, token):
        self.repo, self.token = repo, token

    def call(self, path, method="GET"):
        req = urllib.request.Request(f"https://api.github.com/repos/{self.repo}/{path}", method=method, headers={
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
        ("the queue's other runs on this commit, then this one", runs, 2, "merge_group", [1, 3, 2]),
        ("a finished run is left as it is", [run(4, status="completed")], 9, "merge_group", []),
        ("a push to main never fails fast", runs, 2, "push", []),
        ("a pull request never fails fast", runs, 2, "pull_request", []),
        ("a dispatch never fails fast", runs, 2, "workflow_dispatch", []),
        ("another commit's group is never touched", [run(7, h=other), run(2)], 2, "merge_group", [2]),
        ("push and pull-request runs on the same commit are never touched", [run(5, "push"), run(6, "pull_request")],
         2, "merge_group", []),
    ]
    for name, rs, own, event, want in cases:
        got = targets(rs, sha, own, event)
        assert got == want, f"{name}: got {got}, want {want}"
    print(f"ci-fail-fast selftest: {len(cases)} cases pass")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    env = os.environ.get
    event, sha, own = env("GITHUB_EVENT_NAME", ""), env("GITHUB_SHA", ""), int(env("GITHUB_RUN_ID") or 0)
    if event != "merge_group":
        print(f"ci-fail-fast: {event or 'no'} event, not the merge queue: nothing to cancel")
        return 0
    api = Api(env("GITHUB_REPOSITORY", ""), env("GITHUB_TOKEN", ""))
    try:
        runs = api.call(f"actions/runs?head_sha={sha}&event=merge_group&per_page=100").get("workflow_runs", [])
        ids = targets(runs, sha, own, event)
        names = {r["id"]: r.get("name", "") for r in runs}
        for i in ids:
            print(f"::notice title=Merge queue fails fast::A job failed, so run {i} ({names.get(i)}) on {sha[:7]} "
                  "is cancelled: the queue drops this entry now (scripts/ci-fail-fast.py).", flush=True)
            api.call(f"actions/runs/{i}/cancel", "POST")
    except Stop as e:
        print(f"::warning title=Fail-fast stopped::{e}; the other runs finish on their own.")
    except Exception as e:  # never turn a failed job's cleanup into a second failure
        print(f"::warning title=Fail-fast could not cancel::{e!r}; the other runs finish on their own.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
