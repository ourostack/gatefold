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

A run with a cancelled job ends "cancelled", not "failure" (main's App run 44021756211 at 4688f6d: five iPad shards
stopped from outside, and the rerun workflow skipped it twice), so both conclusions come here. A pull request's run
cancelled because a newer push replaced it (app.yml's cancel-in-progress) is left alone: its newer run is the one.

A test that failed next to them leaves the run as it is, for a person. Adapted from ouro-ui-apple's
scripts/ci-rerun-broken-runner.py (#196, #202): annotations are read before logs, which GitHub stores late.
"""
import json
import re
import subprocess
import sys

MARK = re.compile(r"No app code ran|The hosted runner lost communication with the server|The runner's disk failed"
                  r"|The simulator's runtime disk disappeared|simulator runtime is not available\. runtime path not found")
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


def superseded(run, newest_id):
    """`run`: the App run ({id, conclusion, event}); `newest_id`: the newest App run of its branch and event. True when a
    newer push cancelled it (only pull requests cancel in progress), so there is nothing to rerun."""
    return run["conclusion"] == "cancelled" and run["event"] == "pull_request" and newest_id not in (None, run["id"])


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
    run = json.loads(gh("api", f"{repo}/actions/runs/{run_id}",
                        "--jq", "{id, conclusion, event, head_branch, workflow_id}"))
    if run["conclusion"] == "cancelled" and run["event"] == "pull_request":
        newest = json.loads(gh("api", f"{repo}/actions/workflows/{run['workflow_id']}/runs", "-X", "GET",
                               "-f", f"branch={run['head_branch']}", "-f", "event=pull_request", "-f", "per_page=1",
                               "--jq", "[.workflow_runs[].id]"))
        if superseded(run, newest[0] if newest else None):
            print(f"Not rerunning: a newer push replaced it (run {newest[0]})")
            return
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
    disk = ("##[error]Gatefold-2026-11-16-084152.0003.ips: KERN_MEMORY_ERROR at 0x000000010085b6d0 in a mapped file: the "
            "runner could not read it back. The runner's disk failed; rerun it on a fresh runner (gatefold#135).")
    app = '##[error]The app crashed during the tests: Gatefold-2026-11-16-070650.ips "exception" : {"type":"EXC_BREAKPOINT"}'
    jumps = "iPad place shard (ipad-place-jumps) / Tests"
    portrait = "iPad place shard (ipad-place-portrait) / Tests"
    cases = [
        ([(jumps, "failure", launch), ("iPad (place)", "failure", "")], True),
        ([(jumps, "failure", boot), (portrait, "failure", lost), ("iPad (place)", "failure", "")], True),
        ([(jumps, "cancelled", ""), ("iPad (place)", "failure", "")], True),
        # SIGBUS reading a mapped file back (#429, #435): the runner's disk, rerun; any other crash is the app's.
        ([("iPad reviewer shard (ipad-reviewer-controls) / Tests", "failure", disk + "\n" + test)], True),
        ([(jumps, "failure", app)], False),
        # The iOS runtime's disk disappearing as the app crashed (gatefold#440): the runner's, rerun.
        ([("iPad taps shard (ipad-taps-rest) / Tests", "failure", "##[error]Gatefold-2026-11-16-132347.ips: the "
          "simulator's iOS runtime disk disappeared at 2026-11-16 13:23:53.304Z (com.apple.iPhoneOS.SimulatorRuntime-"
          "v24.1.434.0.a8xtfK). The simulator's runtime disk disappeared; rerun it on a fresh runner (gatefold#440).\n"
          "Test crashed with signal bus.")], True),
        # The simulator runtime's disk image gone mid-run (main at de443f4): the same runner fault as the SIGBUS above.
        ([(jumps, "failure", "Failed to prepare device 'gatefold-ipad' for impending launch. (Underlying Error: The iOS "
          "27.0 simulator runtime is not available. runtime path not found. Download the iOS 27.0 simulator runtime")], True),
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
    runs = [
        # Main's run 44021756211: shards cancelled from outside end the run "cancelled"; main never cancels in progress.
        (({"id": 1, "conclusion": "cancelled", "event": "push"}, 2), False),
        # A pull request's run replaced by a newer push: that newer run is the one.
        (({"id": 1, "conclusion": "cancelled", "event": "pull_request"}, 2), True),
        (({"id": 2, "conclusion": "cancelled", "event": "pull_request"}, 2), False),
        (({"id": 1, "conclusion": "failure", "event": "pull_request"}, 2), False),
    ]
    for (run, newest), want in runs:
        if superseded(run, newest) != want:
            bad += 1
            print(f"FAIL: superseded({run}, {newest}) is not {want}")
    cases += runs
    print(f"{len(cases) - bad} of {len(cases)} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    elif len(sys.argv) == 2:
        main(sys.argv[1])
    else:
        sys.exit(__doc__)
