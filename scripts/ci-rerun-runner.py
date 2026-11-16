#!/usr/bin/env python3
"""CI only: rerun an App run's failed jobs once when every failure was the runner, not the app (gatefold#135, #404).

    python3 -I scripts/ci-rerun-runner.py <run id>     # GH_TOKEN and GH_REPO set; called by rerun-runner.yml
    python3 -I scripts/ci-rerun-runner.py --selftest

Main's App runs at 3e20f75, 921576f and 15fe8ab lost 8 shards before any test began (the test runner could not
launch, or the simulator was gone), and more to hosts that lost contact with GitHub or jobs stopped from outside. Each
waited for a person to rerun it, and TestFlight publishes only from a green main. A fresh runner is what helps, so this
reruns the failed jobs, once (the run's first attempt only), when every failed or cancelled job either:

- says no app code ran (ui-tests.yml's "rerun it on a fresh runner" line, or ci-simulator.py's "No app code ran"),
- lost its runner ("The hosted runner lost communication with the server"),
- was cancelled (none of our workflows cancels a job of a run that goes on, so it was stopped from outside), or
- is a summary check that fails only because a shard did (SUMMARIES).

A test that failed next to them leaves the run as it is, for a person. Adapted from ouro-ui-apple's
scripts/ci-rerun-broken-runner.py (#196, #202): annotations are read before logs, which GitHub stores late.
"""
import json
import re
import subprocess
import sys

MARK = re.compile(r"No app code ran|The hosted runner lost communication with the server")
# Jobs that fail only because a job they wait for failed (app.yml's summary checks).
SUMMARIES = {"iPad (place)", "iPad (reviewer)", "iPad (taps)", "iPad (undo)", "Duo (the reviewers' checks)"}


def decide(failed):
    """`failed`: [(job name, conclusion, evidence text)]. Returns (rerun?, reason)."""
    runner = [n for n, c, text in failed if n not in SUMMARIES and (c == "cancelled" or MARK.search(text))]
    other = [n for n, c, text in failed if n not in SUMMARIES and n not in runner]
    if not runner:
        return False, "no job failed on the runner"
    if other:
        return False, "other jobs failed too, so the run is left for a person: " + "; ".join(other)
    return True, "the runner stopped: " + "; ".join(runner)


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def errors(log):
    """A job log's error lines only: the log also echoes each step's script, and ui-tests.yml's holds the mark's words."""
    return "\n".join(line for line in log.splitlines() if "##[error]" in line)


def evidence(repo, job_id):
    text = []
    for path in (f"{repo}/check-runs/{job_id}/annotations", f"{repo}/actions/jobs/{job_id}/logs"):
        try:
            got = gh("api", path, *(["--jq", ".[].message"] if path.endswith("annotations") else []))
        except subprocess.CalledProcessError:
            continue
        text.append(got if path.endswith("annotations") else errors(got))
        if MARK.search(text[-1]):
            break
    return "\n".join(text)


def main(run_id):
    repo = "repos/{owner}/{repo}"
    jobs = json.loads(gh("api", "--paginate", f"{repo}/actions/runs/{run_id}/attempts/1/jobs",
                         "--jq", "[.jobs[]|{id, name, conclusion}]"))
    failed = [(j["name"], j["conclusion"], evidence(repo, j["id"]) if j["conclusion"] == "failure" else "")
              for j in jobs if j["conclusion"] in ("failure", "cancelled", "timed_out")]
    rerun, why = decide(failed)
    print(("Rerunning the failed jobs on fresh runners: " if rerun else "Not rerunning: ") + why)
    if rerun:
        gh("api", "-X", "POST", f"{repo}/actions/runs/{run_id}/rerun-failed-jobs")


def selftest():
    launch = ("##[error]No test started: the test runner could not be installed or launched. No app code ran; "
              "rerun it on a fresh runner (gatefold#135).")
    boot = "##[error]boot-sim.sh did not finish within 1200 s. No app code ran."
    lost = "The hosted runner lost communication with the server. Anything in your workflow that terminates..."
    test = "ReviewerChecksUITests.swift:355: error: -[GatefoldUITests.ReviewerChecksUITests testX] : XCTAssertTrue failed"
    jumps = "iPad place shard (ipad-place-jumps) / Tests"
    portrait = "iPad place shard (ipad-place-portrait) / Tests"
    cases = [
        ([(jumps, "failure", launch), ("iPad (place)", "failure", "")], True),
        ([(jumps, "failure", boot), (portrait, "failure", lost), ("iPad (place)", "failure", "")], True),
        ([(jumps, "cancelled", ""), ("iPad (place)", "failure", "")], True),
        # A test that failed beside them is left for a person.
        ([(jumps, "failure", launch), (portrait, "failure", test), ("iPad (place)", "failure", "")], False),
        ([(portrait, "failure", test)], False),
        # A test runner that died mid-test (gatefold#424) is not marked: left for a person.
        ([("Duo shard (duo-turnback) / Tests", "failure", "Test crashed with signal term.")], False),
        ([("iPad (place)", "failure", "")], False),
        ([], False),
    ]
    bad = 0
    echoed = ('2026-11-16T07:00:00Z \x1b[36;1m  echo "::error title=The runner, not the app::No test started: $why. No app '
              'code ran; rerun it on a fresh runner (gatefold#135)."\x1b[0m\n2026-11-16T07:22:10Z ##[error]XCTAssertTrue failed')
    if MARK.search(errors(echoed)):
        bad += 1
        print("FAIL: the step's echoed script read as the mark")
    for failed, want in cases:
        got, why = decide(failed)
        if got != want:
            bad += 1
            print(f"FAIL: {[f[0] for f in failed]}: got {got} ({why}), want {want}")
    print(f"{len(cases) - bad} of {len(cases)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    elif len(sys.argv) == 2:
        main(sys.argv[1])
    else:
        sys.exit(__doc__)
