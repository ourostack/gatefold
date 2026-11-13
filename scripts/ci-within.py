#!/usr/bin/env python3
"""CI only: run a test command so that a hang ends it gently before its step's limit (gatefold#126).

    python3 -I scripts/ci-within.py --until <epoch seconds> -- xcodebuild test-without-building ...
    python3 -I scripts/ci-within.py left <job start> <limit> <boot> <setup> <reserve> <cap>   # the time-left action
    python3 -I scripts/ci-within.py --selftest

A step cut off at its `timeout-minutes` has its xcodebuild killed while it writes the result bundle, which then
can't be read (run 42538700258: "duo.xcresult/Info.plist does not exist"). This sends the command SIGINT 2 min
before the step's end (`until`, from the time-left action, so time the step spent before this started counts),
so xcodebuild ends the test run and closes the bundle, then kills its process group if it has not ended 90 s
later. It exits 124 when the time ran out, else with the command's own status. The step's own limit stays as the
backstop.

`left` is the time-left action's sum (gatefold#198): the step's `until` is the end of the tests' whole budget plus
GRACE, so the stop comes when the budget ends, not GRACE before it. It came out of the budget before, and a minute
was rounded off, so a 6 min budget stopped its tests at 3 min 59 s (gatefold#353). That was hidden while setup ended
before `setup` minutes, which leaves spare minutes, and showed when a slow boot used them up. A setup that ran past
`boot` minutes, so the tests could no longer get their whole budget, fails as infrastructure before any test runs.
"""
import os
import signal
import subprocess
import sys
import tempfile
import time

GRACE = 120  # seconds before the step's end: the 90 s for the command to end, and a margin
SETTLE = 90


def run(seconds, argv, settle=SETTLE):
    seconds = max(1, int(seconds))
    # Its own process group, so the kill below also ends whatever it started that still holds the pipe open.
    child = subprocess.Popen(argv, start_new_session=True)
    forward = lambda sig, _: child.send_signal(sig)  # the runner's own cancel reaches the command
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    try:
        return child.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        pass
    print(f"::error::Still running {seconds // 60} min {seconds % 60} s in: stopping it so its results can be written and uploaded (gatefold#126)", flush=True)
    child.send_signal(signal.SIGINT)
    try:
        child.wait(timeout=settle)
    except subprocess.TimeoutExpired:
        print(f"ci-within: no end {settle} s after SIGINT; killing it", flush=True)
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()
    return 124


def left(job_start, limit, boot, setup, reserve, cap, now):
    """(minutes, until, line) for the test step, all whole numbers; or (None, None, error) when setup ran too long.

    The tests get `limit - boot - reserve` minutes from the later of now and `setup` minutes into the job, and ci-within
    stops them GRACE before `until`, so `until` is their end plus GRACE: the GRACE comes out of the reserve, not the
    tests (gatefold#353). `minutes`, the step's timeout-minutes, is rounded up, so the step's own limit never comes
    before `until`."""
    budget = limit - boot - reserve
    if budget < 1:
        return None, None, f"A limit of {limit} min leaves no tests' budget after {boot} for setup and {reserve} for logs"
    took = now - job_start
    if took > boot * 60:
        return None, None, (f"Setup took {took // 60} min {took % 60} s, past the {boot} min this job holds for it, so "
                            f"its tests can't have their whole {budget} min. Infrastructure, not the app: no test ran. "
                            f"Rerun the failed job for a fresh runner (gatefold#353)")
    tests_end = max(now, job_start + setup * 60) + budget * 60
    until = min(tests_end + GRACE, now + cap * 60)
    minutes = max(1, -(-(until - now) // 60))
    line = (f"{minutes} min for this step: {(tests_end - now) // 60} min {(tests_end - now) % 60} s of tests "
            f"({budget} min of budget) then {GRACE} s to stop them, after {took // 60} min of setup; "
            f"the job's limit is {limit} min, {reserve} kept for its logs")
    return minutes, until, line


def gone(pid):
    """True when pid has exited (a zombie counts: it holds no pipe)."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return stat == "" or stat.startswith("Z")


def selftest():
    start = time.monotonic()
    assert run(30, [sys.executable, "-c", "pass"]) == 0
    assert run(30, [sys.executable, "-c", "raise SystemExit(3)"]) == 3
    # Ends on SIGINT, as xcodebuild does.
    assert run(1, [sys.executable, "-c", "import time; time.sleep(60)"], settle=10) == 124
    # Ignores SIGINT, and has started a child of its own: both killed after the settle time.
    ignore = ("import signal, subprocess, sys, time; signal.signal(signal.SIGINT, signal.SIG_IGN); "
              "p = subprocess.Popen(['sleep', '60']); open(sys.argv[1], 'w').write(str(p.pid)); time.sleep(60)")
    with tempfile.TemporaryDirectory() as scratch:
        pidfile = os.path.join(scratch, "pid")
        status = run(1, [sys.executable, "-c", ignore, pidfile], settle=2)
        grandchild = int(open(pidfile).read())
    assert status == 124
    deadline = time.monotonic() + 3
    while not gone(grandchild) and time.monotonic() < deadline:
        time.sleep(0.1)
    assert gone(grandchild), "the command's own child outlived the kill"
    # A deadline already past still gives the command a moment, then stops it.
    assert main(["--until", str(int(time.time())), "--", sys.executable, "-c", "pass"]) == 0
    assert time.monotonic() - start < 20, "a stop waited out the command"
    # left: job_start 0; a 48 min limit, 30 for setup, 12 for logs: 6 min of tests.
    m, u, _ = left(0, 48, 30, 12, 12, 600, now=11 * 60)  # gatefold#353's ipad-place-counting: setup 11 min
    assert u - GRACE == 18 * 60, "the tests end their whole budget after the 12 min setup allowance"
    assert m * 60 >= u - 11 * 60 and (m - 1) * 60 < u - 11 * 60, "the step's limit is `until`, rounded up"
    m, u, _ = left(0, 51, 30, 12, 12, 600, now=10 * 60 + 9)  # its ipad-taps-rest: 9 min of tests, setup 10 min 9 s
    assert u - GRACE - (10 * 60 + 9) >= 9 * 60, "the stop never comes before the budget's end"
    m, u, _ = left(0, 48, 30, 12, 12, 600, now=20 * 60)  # setup past the 12 min: the whole budget from now
    assert u == 20 * 60 + 6 * 60 + GRACE and m == 8
    m, u, _ = left(0, 48, 30, 12, 12, 600, now=30 * 60)  # setup at its allowance exactly: still the whole budget
    assert u - GRACE == 36 * 60 and u <= (48 - 12) * 60 + GRACE, "the GRACE comes out of the reserve, no more"
    m, u, why = left(0, 48, 30, 12, 12, 600, now=30 * 60 + 1)
    assert m is None and "Infrastructure" in why, "a setup past its allowance fails, never a short test step"
    m, u, why = left(0, 42, 30, 12, 12, 600, now=60)
    assert m is None and "no tests' budget" in why
    m, u, _ = left(0, 48, 30, 12, 12, 3, now=60)
    assert u == 60 + 3 * 60 and m == 3, "the cap bounds the step"
    assert main(["left", "0", "48", "30", "12", "12", "600"]) == 1, "a job that began at the epoch overran"
    print("ci-within: selftest passed")
    return 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) == 7 and argv[0] == "left" and all(a.isdigit() for a in argv[1:]):
        minutes, until, line = left(*map(int, argv[1:]), now=int(time.time()))
        if minutes is None:
            print(f"::error title=Setup overran::{line}", flush=True)
            return 1
        print(line, flush=True)
        out = os.environ.get("GITHUB_OUTPUT")
        if out:
            with open(out, "a") as f:
                f.write(f"minutes={minutes}\nuntil={until}\n")
        return 0
    if len(argv) < 4 or argv[0] != "--until" or argv[2] != "--" or not argv[1].isdigit():
        print(__doc__, file=sys.stderr)
        return 2
    return run(int(argv[1]) - time.time() - GRACE, argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
