#!/usr/bin/env python3
"""The one list of what a runner fault looks like in this repository's CI: a job that failed for a reason in the
machine, not in the app. Read by scripts/ci-bootstrap.py (a UI test log), scripts/ci-rerun-runner.py (a failed App
run's jobs) and scripts/ci-requeue.py (a failed merge-queue entry). Each keeps its own policy; only the words live here.

    python3 -I scripts/ci-runner-faults.py --selftest

The other scripts load this file by its path (load() below), because `python3 -I` keeps the script's folder off the
import path. Add a signature here, with the run it was seen on, and every reader picks it up.
"""
import importlib.util
import os
import re
import sys

# What xcodebuild says when XCTest's runner never got going (ci-bootstrap.py reads them only from a log in which no
# test started). Each seen on this repository's CI (run and job in gatefold#135).
XCODEBUILD = [
    ("the test runner could not be installed or launched", re.compile(r"Failed to install or launch the test runner")),
    ("the test runner never finished starting", re.compile(r"never finished bootstrapping")),
    ("the test runner timed out while starting", re.compile(r"timed out while preparing to run tests")),
    ("the simulator was gone from xcodebuild's devices", re.compile(r"Unable to find a device matching the provided destination")),
]

# The lines our own steps write when they find a runner fault, and GitHub's own for a lost runner (ci-rerun-runner.py
# reads them from a failed job's error lines and annotations).
MARKS = [
    ("no app code ran", re.compile(r"No app code ran")),
    ("the hosted runner lost contact with GitHub", re.compile(r"The hosted runner lost communication with the server")),
    ("the runner's disk failed", re.compile(r"The runner's disk failed")),
    ("the simulator's runtime disk disappeared", re.compile(r"The simulator's runtime disk disappeared")),
    ("the iOS simulator runtime was missing", re.compile(r"simulator runtime is not available\. runtime path not found")),
]

# Further words a whole job log can show (ci-requeue.py), each seen on a merge-queue run that a person re-enqueued.
MORE = [
    # Run 44241083397 (#476), "Unfold with a book open": DeviceHub's press Open got no answer twice.
    ("a DeviceHub press stalled", re.compile(r"press \w+ stalled twice|a DeviceHub press stalled")),
    # gatefold#135: "(Mach error -308 - (ipc/mig) server died)" as the test runner launched.
    ("Mach error -308 (the simulator's server died)", re.compile(r"Mach error -308")),
    ("no test started", re.compile(r"No test started")),
]

FAULTS = XCODEBUILD + MARKS + MORE

# A test of the app that ran and failed: XCTest's case line or an assertion's error line.
TEST_FAILED = re.compile(r"Test Case '-\[\S+ \S+\]' failed|: error: -\[\S+ \S+\] : (XCT\w+|failed)")

# Jobs that only gather others (app.yml's gates, real-unfold.yml's summary and both proofs): they fail only because a job
# they wait for did, so their failure says nothing of its own.
SUMMARIES = {"iPad (place)", "iPad (reviewer)", "iPad (taps)", "iPad (undo)", "Duo (the reviewers' checks)",
             "Build and unit-test the app", "Real unfold"}
SUMMARY_PREFIXES = ("Full suite passed on tree ", "Real unfold passed on tree ")


def summary(name):
    return name in SUMMARIES or name.startswith(SUMMARY_PREFIXES)


def fault(text, signatures=FAULTS):
    """The first signature's name that `text` shows, or None."""
    for name, pattern in signatures:
        if pattern.search(text):
            return name
    return None


def load(name):
    """Another script in this folder, as a module (its dashes kept), for `python3 -I` callers."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), name)
    spec = importlib.util.spec_from_file_location(name.replace("-", "_").removesuffix(".py"), path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def selftest():
    cases = [
        ("xcodebuild: error: Failed to install or launch the test runner. (Underlying Error: The operation couldn't be "
         "completed. (Mach error -308 - (ipc/mig) server died))", "the test runner could not be installed or launched"),
        ("2026-11-18T06:26:15.2674890Z ##[error]press Open stalled twice", "a DeviceHub press stalled"),
        ("xcodebuild: error: Unable to find a device matching the provided destination specifier:",
         "the simulator was gone from xcodebuild's devices"),
        ("##[error]boot-sim.sh did not finish within 1200 s. No app code ran.", "no app code ran"),
        ("##[error]Process completed with exit code 65.", None),
        ("", None),
    ]
    bad = 0
    for text, want in cases:
        if fault(text) != want:
            bad += 1
            print(f"FAIL: {text[:70]!r}: got {fault(text)!r}, want {want!r}")
    tests = [
        ("Test Case '-[GatefoldUITests.PlaceUndoUITests testATapAboveYourPageClosesItAndKeepsThePage]' failed "
         "(196.687 seconds).", True),
        ("/x/PlaceUndoUITests.swift:265: error: -[GatefoldUITests.PlaceUndoUITests testATap] : XCTAssertEqual failed "
         "(text withheld)", True),
        ("  XCTESTRUN: /Users/runner/work/_temp/dd/Build/Products/Gatefold_iphonesimulator27.2-arm64.xctestrun", False),
        ("Test Case '-[GatefoldUITests.PlaceUndoUITests testATap]' passed (12.0 seconds).", False),
    ]
    for text, want in tests:
        if bool(TEST_FAILED.search(text)) != want:
            bad += 1
            print(f"FAIL: test failed in {text[:70]!r} is not {want}")
    names = [("iPad (undo)", True), ("Full suite passed on tree abc", True), ("Real unfold", True),
             ("Unfold with a book open", False), ("iPad undo shard (ipad-undo-rest) / Tests", False)]
    for name, want in names:
        if summary(name) != want:
            bad += 1
            print(f"FAIL: summary({name!r}) is not {want}")
    total = len(cases) + len(tests) + len(names)
    print(f"{total - bad} of {total} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(selftest() if sys.argv[1:] == ["--selftest"] else __doc__)
