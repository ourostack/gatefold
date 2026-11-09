#!/usr/bin/env python3
"""CI only: run a test command so that a hang ends it gently before its step's limit (gatefold#126).

    python3 -I scripts/ci-within.py --until <epoch seconds> -- xcodebuild test-without-building ...
    python3 -I scripts/ci-within.py --selftest

A step cut off at its `timeout-minutes` has its xcodebuild killed while it writes the result bundle, which then
can't be read (run 42538700258: "duo.xcresult/Info.plist does not exist"). This sends the command SIGINT 2 min
before the step's end (`until`, from the time-left action, so time the step spent before this started counts),
so xcodebuild ends the test run and closes the bundle, then kills its process group if it has not ended 90 s
later. It exits 124 when the time ran out, else with the command's own status. The step's own limit stays as the
backstop.
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
    print("ci-within: selftest passed")
    return 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) < 4 or argv[0] != "--until" or argv[2] != "--" or not argv[1].isdigit():
        print(__doc__, file=sys.stderr)
        return 2
    return run(int(argv[1]) - time.time() - GRACE, argv[3:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
