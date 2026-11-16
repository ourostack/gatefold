#!/usr/bin/env python3
"""CI only: did a UI test run fail before any test started, for a reason in the machine, not the app?

    python3 -I scripts/ci-bootstrap.py why <ui.log>   # prints the reason and exits 0 if so; exits 1 if not
    python3 -I scripts/ci-bootstrap.py --selftest

The hosted simulators often fail to start XCTest's runner: "Failed to install or launch the test runner" (Mach error
-308, "server died", or SpringBoard refusing the launch), the runner crashing or stalling "while preparing to run
tests", or the device gone from xcodebuild's list ("Unable to find a device matching the provided destination").
gatefold#135 has a dozen of them since 2026-11-09, and main's App run at 15fe8ab lost 3 of its 7 red shards this way
(run 43799490331). None of them runs a line of the app. Erasing the device or booting another on the same host did not
help (#429's first run: the boot hung or the erase ran out of time), so the shard's step fails with a line that
scripts/ci-rerun-runner.py reads, and the shard runs again on a fresh runner. A run in which any test started is never
retried: its failure is the test's.
"""
import re
import sys

STARTED = re.compile(r"^Test Case '-\[\S+ \S+\]' started\.", re.M)

# What xcodebuild says when the runner never got going. Each seen on this repository's CI (run and job in gatefold#135).
REASONS = [
    ("the test runner could not be installed or launched", re.compile(r"Failed to install or launch the test runner")),
    ("the test runner never finished starting", re.compile(r"never finished bootstrapping")),
    ("the test runner timed out while starting", re.compile(r"timed out while preparing to run tests")),
    ("the simulator was gone from xcodebuild's devices", re.compile(r"Unable to find a device matching the provided destination")),
]


def why(log):
    """The reason, when the run failed before any test started for one of REASONS; else None."""
    if STARTED.search(log):
        return None
    for reason, pattern in REASONS:
        if pattern.search(log):
            return reason
    return None


def selftest():
    launch = ("xcodebuild: error: Failed to install or launch the test runner. (Underlying Error: The operation "
              "couldn't be completed. (Mach error -308 - (ipc/mig) server died))\n** TEST EXECUTE FAILED **\n")
    boot = ("Early unexpected exit, operation never finished bootstrapping - no restart will be attempted. (Underlying "
            "Error: The test runner crashed while preparing to run tests: GatefoldUITests-Runner)\n")
    gone = ("xcodebuild: error: Unable to find a device matching the provided destination specifier:\n"
            "\t\t{ platform:iOS Simulator, arch:arm64, id:36DBF76A-7131-4B1E-8224-FEDB053EEAFA }\n")
    stalled = "The test runner timed out while preparing to run tests\n"
    started = "Test Case '-[GatefoldUITests.FineTuneTapUITests testATapOnTheRowsNameChangesItsSwitch]' started.\n"
    failed = ("/x/ReviewerChecksUITests.swift:355: error: -[GatefoldUITests.ReviewerChecksUITests "
              "testPageNumbersAreOnOrOffInEveryBook] : XCTAssertTrue failed\n")
    cases = [
        (launch, "the test runner could not be installed or launched"),
        (boot, "the test runner never finished starting"),
        (stalled, "the test runner timed out while starting"),
        (gone, "the simulator was gone from xcodebuild's devices"),
        # Once a test has started, a failure is the test's, whatever follows it.
        (started + launch, None),
        (started + boot, None),
        (started + failed, None),
        ("", None),
        ("** TEST EXECUTE FAILED **\n", None),
    ]
    bad = 0
    for log, want in cases:
        got = why(log)
        if got != want:
            bad += 1
            print(f"FAIL: {log[:70]!r}: got {got!r}, want {want!r}")
    print(f"{len(cases) - bad} of {len(cases)} passed")
    return 1 if bad else 0


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) == 2 and argv[0] == "why":
        try:
            with open(argv[1], errors="replace") as f:
                reason = why(f.read())
        except OSError as e:
            print(f"no log to read ({e})", file=sys.stderr)
            return 1
        if reason:
            print(reason)
            return 0
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
