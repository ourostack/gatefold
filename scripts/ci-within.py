#!/usr/bin/env python3
"""CI only: run a test command so that a hang ends it gently before its step's limit (gatefold#126).

    python3 -I scripts/ci-within.py <step minutes> -- xcodebuild test-without-building ...
    python3 -I scripts/ci-within.py --selftest

A step cut off at its `timeout-minutes` has its xcodebuild killed while it writes the result bundle, which then
can't be read (run 42538700258: "duo.xcresult/Info.plist does not exist"). This sends the command SIGINT 2 min
before the step's limit, so xcodebuild ends the test run and closes the bundle, then kills it if it has not
ended 90 s later. It exits 124 when the time ran out, else with the command's own status. The step's own limit
stays as the backstop.
"""
import signal
import subprocess
import sys
import time

GRACE = 120  # seconds before the step's limit: the 90 s for the command to end, and a margin
SETTLE = 90


def run(seconds, argv, settle=SETTLE):
    child = subprocess.Popen(argv)
    forward = lambda sig, _: child.send_signal(sig)  # the runner's own cancel reaches the command
    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    try:
        return child.wait(timeout=max(1, seconds))
    except subprocess.TimeoutExpired:
        pass
    print(f"::error::Still running {max(1, seconds) // 60} min in: stopping it so its results can be written and uploaded (gatefold#126)", flush=True)
    child.send_signal(signal.SIGINT)
    try:
        child.wait(timeout=settle)
    except subprocess.TimeoutExpired:
        print(f"ci-within: no end {settle} s after SIGINT; killing it", flush=True)
        child.kill()
        child.wait()
    return 124


def selftest():
    start = time.monotonic()
    assert run(30, [sys.executable, "-c", "pass"]) == 0
    assert run(30, [sys.executable, "-c", "raise SystemExit(3)"]) == 3
    # Ends on SIGINT, as xcodebuild does.
    assert run(1, [sys.executable, "-c", "import time; time.sleep(60)"], settle=10) == 124
    # Ignores SIGINT: killed after the settle time.
    ignore = "import signal, time; signal.signal(signal.SIGINT, signal.SIG_IGN); time.sleep(60)"
    assert run(1, [sys.executable, "-c", ignore], settle=2) == 124
    assert time.monotonic() - start < 20, "a stop waited out the command"
    print("ci-within: selftest passed")
    return 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) < 3 or argv[1] != "--":
        print(__doc__, file=sys.stderr)
        return 2
    return run(int(argv[0]) * 60 - GRACE, argv[2:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
