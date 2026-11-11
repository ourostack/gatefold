#!/usr/bin/env python3
"""Is this main commit green? TestFlight publishes only a commit whose required checks all passed.

Reads the commit's check runs from the GitHub API and judges the required ones, listed in
.github/required-checks.txt (the branch protection's names, which never change). For each name the newest
run counts, so a rerun that turned green counts as green.

    python3 -I scripts/ci-green-gate.py --sha <sha>      # prints the state, writes state= to $GITHUB_OUTPUT
    python3 -I scripts/ci-green-gate.py --selftest

States:
  green       every required check concluded success, skipped or neutral
  pending     a required check has not reported or has not finished; a later completion asks again
  superseded  none failed, but one was cancelled (main's newest push replaced this run, gatefold#246): the newer
              commit's run covers it
  red         a required check failed, timed out or could not start
It exits 0 for every state; the workflow decides what each one means. It exits 2 when it cannot ask GitHub.
"""
import json
import os
import pathlib
import sys
import urllib.request

PASS = {"success", "skipped", "neutral"}
CANCELLED = {"cancelled"}
REQUIRED_FILE = pathlib.Path(__file__).resolve().parent.parent / ".github" / "required-checks.txt"


def required_names(path=REQUIRED_FILE):
    names = [ln.strip() for ln in pathlib.Path(path).read_text().splitlines()]
    return [n for n in names if n and not n.startswith("#")]


def judge(required, runs):
    """required: names; runs: check-run dicts (name, status, conclusion, id). Returns (state, lines)."""
    newest = {}
    for run in runs:
        name = run.get("name")
        if name in required and (name not in newest or run.get("id", 0) > newest[name].get("id", 0)):
            newest[name] = run
    lines, states = [], []
    for name in required:
        run = newest.get(name)
        if run is None:
            states.append("pending")
            lines.append(f"{name}: not reported yet")
        elif run.get("status") != "completed":
            states.append("pending")
            lines.append(f"{name}: {run.get('status')}")
        elif run.get("conclusion") in PASS:
            states.append("green")
            lines.append(f"{name}: {run.get('conclusion')}")
        elif run.get("conclusion") in CANCELLED:
            states.append("superseded")
            lines.append(f"{name}: cancelled")
        else:
            states.append("red")
            lines.append(f"{name}: {run.get('conclusion')}")
    for state in ("red", "pending", "superseded"):
        if state in states:
            return state, lines
    return "green", lines


def fetch_runs(repo, sha, token):
    runs, page = [], 1
    while True:
        url = f"https://api.github.com/repos/{repo}/commits/{sha}/check-runs?per_page=100&page={page}"
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = json.load(resp)
        batch = body.get("check_runs", [])
        runs.extend(batch)
        if len(runs) >= body.get("total_count", 0) or not batch:
            return runs
        page += 1


def selftest():
    req = ["A", "B"]
    ok = lambda n, i=1: {"name": n, "status": "completed", "conclusion": "success", "id": i}
    cases = [
        ([ok("A"), ok("B")], "green"),
        ([ok("A")], "pending"),
        ([ok("A"), {"name": "B", "status": "in_progress", "conclusion": None, "id": 2}], "pending"),
        ([ok("A"), {"name": "B", "status": "completed", "conclusion": "failure", "id": 2}], "red"),
        ([ok("A"), {"name": "B", "status": "completed", "conclusion": "cancelled", "id": 2}], "superseded"),
        # A rerun that went green counts; an older failed run of the same name does not.
        ([ok("A"), {"name": "B", "status": "completed", "conclusion": "failure", "id": 2}, ok("B", 3)], "green"),
        # A rerun that went red after a green one counts as red.
        ([ok("A"), ok("B", 2), {"name": "B", "status": "completed", "conclusion": "failure", "id": 3}], "red"),
        # Red outranks pending, pending outranks superseded.
        ([{"name": "A", "status": "completed", "conclusion": "timed_out", "id": 1}], "red"),
        ([{"name": "A", "status": "completed", "conclusion": "cancelled", "id": 1}], "pending"),
        ([ok("A"), {"name": "B", "status": "completed", "conclusion": "skipped", "id": 2}], "green"),
        # Checks outside the list don't matter.
        ([ok("A"), ok("B"), {"name": "Duo tour", "status": "completed", "conclusion": "failure", "id": 9}], "green"),
    ]
    for i, (runs, want) in enumerate(cases):
        got, _ = judge(req, runs)
        assert got == want, f"case {i}: got {got}, want {want}"
    names = required_names()
    assert "Build and unit-test the app" in names and "Real unfold" in names, names
    print(f"ci-green-gate selftest: {len(cases)} cases pass; {len(names)} required checks listed")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    sha = argv[argv.index("--sha") + 1] if "--sha" in argv else os.environ.get("GATE_SHA", "")
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (sha and repo and token):
        print("ci-green-gate: needs --sha, GITHUB_REPOSITORY and GITHUB_TOKEN", file=sys.stderr)
        return 2
    try:
        runs = fetch_runs(repo, sha, token)
    except Exception as exc:  # network or API trouble: say so, never guess green
        print(f"ci-green-gate: could not read check runs for {sha}: {exc}", file=sys.stderr)
        return 2
    state, lines = judge(required_names(), runs)
    print(f"{sha[:7]} is {state}")
    for line in lines:
        print(f"  {line}")
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"state={state}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
