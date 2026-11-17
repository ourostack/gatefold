#!/usr/bin/env python3
"""CI only: did a UI test run fail before any test started, for a reason in the machine, not the app?

    python3 -I scripts/ci-bootstrap.py why <ui.log>   # prints the reason and exits 0 if so; exits 1 if not
    python3 -I scripts/ci-bootstrap.py crash <.ips>   # exits 0 if the crash is the runner's disk (below); 1 if not
    python3 -I scripts/ci-bootstrap.py lost <simdiskimaged.log> <.ips>   # exits 0 if the iOS runtime's disk went
                                                                         # away as the app crashed (below); 1 if not
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
import datetime
import json
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


def disk_fault(report):
    """The reason, when a crash report is the runner failing to read a file it had mapped: SIGBUS with
    KERN_MEMORY_ERROR (the kernel could not page the memory in) at an address in a "mapped file" region. Seen on the
    xcode-27 image (macOS 27.2 26B123) in the app and in the UI-test runner alike, inside dyld or code pages, on
    #429, #435 and main's run at 3e20f75. Any other crash, a KERN_MEMORY_ERROR outside a mapped file included, is
    None: it stays the app's."""
    try:
        d = json.loads(report.split("\n", 1)[1])
    except (IndexError, ValueError):
        return None
    exc = d.get("exception") or {}
    if exc.get("signal") != "SIGBUS" or "KERN_MEMORY_ERROR" not in (exc.get("subtype") or ""):
        return None
    region = next((l for l in (d.get("vmRegionInfo") or "").splitlines() if l.lstrip().startswith("--->")), "")
    if not re.match(r"\s*--->\s+mapped file\s", region):
        return None
    return f"{exc['subtype']} in a mapped file: the runner could not read it back"


# simdiskimaged's line when a mounted runtime image goes away without being asked to (an unmount it was asked for
# logs "Disk unmount requested" first, and only "Volume at ... is gone"). Only an iOS runtime counts: the runner image
# unmounts watchOS and tvOS runtimes on its own while the tests run.
DISAPPEARED = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d(?:\.\d+)?)Z\s.*Disk disappeared at (\S*(?:iPhoneOS\.SimulatorRuntime|/iOS_)\S*?),?\s", re.M)
# gatefold#440: the disk was logged gone 2.6 s and 8.1 s after Gatefold crashed (the processes that read it fail
# first), so the window reaches both ways.
WINDOW = 30


def runtime_lost(diskimaged, report):
    """The reason, when simdiskimaged.log (from the result bundle's diagnostics) shows an iOS simulator runtime's disk
    disappearing within WINDOW seconds of the report's crash. With it gone, the app dies however its next read of the
    runtime fails: a SIGABRT when libobjc cannot dlopen its trampolines, a SIGSEGV with no app frame (gatefold#440, run
    43870503829), or a SIGBUS. Any crash without that line nearby is None: it stays the app's."""
    try:
        d = json.loads(report.split("\n", 1)[1])
        crashed = datetime.datetime.strptime(d["captureTime"][:19], "%Y-%m-%d %H:%M:%S")
    except (IndexError, ValueError, KeyError, TypeError):
        return None
    for when, path in DISAPPEARED.findall(diskimaged):
        gone = datetime.datetime.strptime(when[:19], "%Y-%m-%d %H:%M:%S")
        if abs((gone - crashed).total_seconds()) <= WINDOW:
            return f"the simulator's iOS runtime disk disappeared at {when}Z ({path.rsplit('/', 1)[-1]})"
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
    def ips(exception, arrow):
        body = {"exception": exception, "vmRegionInfo": "0x105430000 is in 0x105430000-0x105440000;\n"
                "      REGION TYPE   START - END\n      __LINKEDIT   105420000-105430000 [ 64K] r--/rwx\n" + arrow}
        return '{"app_name":"Gatefold"}\n' + json.dumps(body)
    bus = {"type": "EXC_BAD_ACCESS", "signal": "SIGBUS", "subtype": "KERN_MEMORY_ERROR at 0x0000000105430000"}
    mapped = "--->  mapped file                 105430000-105440000    [   64K] r-x/rwx SM=COW  Object_id=dc641189"
    heap = "--->  MALLOC_SMALL                105430000-105440000    [   64K] rw-/rwx SM=PRV"
    crashes = [
        (ips(bus, mapped), True),  # GatefoldUITests-Runner-2026-11-16-085254.ips, #429
        (ips(bus, heap), False),  # the same fault in the app's own memory is the app's
        (ips({"type": "EXC_BAD_ACCESS", "signal": "SIGBUS", "subtype": "KERN_PROTECTION_FAILURE at 0x1"}, mapped), False),
        (ips({"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"}, mapped), False),  # a Swift trap, as #436
        ("not a report", False),
    ]
    for report, want in crashes:
        if bool(disk_fault(report)) != want:
            bad += 1
            print(f"FAIL: crash {report[-90:]!r}: want {want}")
    # gatefold#440, run 43870503829: simdiskimaged.log from each shard's result bundle and the Gatefold report's
    # timing and exception, trimmed.
    taps_log = (
        "2026-11-16 13:21:42.851Z   Info     Volume at /Library/Developer/CoreSimulator/Volumes/watchOS_24R362 is gone, "
        "cancelling any dyld cache updates under it\n"
        "2026-11-16 13:23:36.623Z   Info     Skipping Mobile Asset purge for /System/Library/AssetsV2/com_apple_MobileAsset_"
        "appleTVOSSimulatorRuntime/f6a3a9321156c52c0d245f50953d9867b2b139ab.asset/AssetData; another runtime registration "
        "still references this asset\n"
        "2026-11-16 13:23:53.304Z   Info     Disk disappeared at /private/var/run/com.apple.security.cryptexd/mnt/com.apple."
        "iPhoneOS.SimulatorRuntime-v24.1.434.0.a8xtfK, cancelling any dyld cache updates\n"
        "2026-11-16 13:23:53.362Z   Info     Volume at /private/var/run/com.apple.security.cryptexd/mnt/com.apple.iPhoneOS."
        "SimulatorRuntime-v24.1.434.0.a8xtfK is gone, cancelling any dyld cache updates under it\n")
    shelf_log = (
        "2026-11-16 13:46:16.473Z   Info     Disk disappeared at /private/var/run/com.apple.security.cryptexd/mnt/com.apple."
        "iPhoneOS.SimulatorRuntime-v24.1.434.0.17Td8m, cancelling any dyld cache updates\n"
        "2026-11-16 13:46:18.606Z   Info     Disk disappeared at /private/var/run/com.apple.security.cryptexd/mnt/com.apple."
        "XROS.SimulatorRuntime-v24.13.362.0.hvn3UY, cancelling any dyld cache updates\n")
    watch_log = (  # an unmount of another platform's runtime, as the runner image does mid-run
        "2026-11-16 13:23:50.000Z   Info     Disk disappeared at /private/var/run/com.apple.security.cryptexd/mnt/com.apple."
        "watchOS.SimulatorRuntime-v24.13.362.0.Ab12Cd, cancelling any dyld cache updates\n")
    def at(when, exception, termination):
        return ('{"app_name":"Gatefold","timestamp":"' + when[:19] + '.00 +0000","bug_type":"309"}\n'
                + json.dumps({"captureTime": when, "exception": exception, "termination": termination}))
    abort = {"codes": "0x0000000000000000, 0x0000000000000000", "type": "EXC_CRASH", "signal": "SIGABRT"}
    objc = {"namespace": "OBJC", "flags": 646, "code": 1}
    taps = at("2026-11-16 13:23:45.1886 +0000", abort, objc)  # Gatefold-2026-11-16-132347.ips
    shelf = at("2026-11-16 13:46:13.8986 +0000",  # Gatefold-2026-11-16-134615.0004.ips
               {"type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "subtype": "KERN_INVALID_ADDRESS at 0x0000000000000008"},
               {"namespace": "SIGNAL", "code": 11, "indicator": "Segmentation fault: 11"})
    losses = [
        (taps_log, taps, True),  # 8.1 s before the disk was logged gone
        (shelf_log, shelf, True),  # 2.6 s before
        (taps_log, shelf, False),  # the same disk loss 22 minutes earlier
        (watch_log, taps, False),  # another platform's runtime going
        (taps_log.split("2026-11-16 13:23:53.304Z")[0], taps, False),  # a SIGABRT with no disk loss stays the app's
        ("", taps, False),
        (taps_log, "not a report", False),
    ]
    for log, report, want in losses:
        if bool(runtime_lost(log, report)) != want:
            bad += 1
            print(f"FAIL: lost {report[-60:]!r} with {log[-90:]!r}: want {want}")
    total = len(cases) + len(crashes) + len(losses)
    print(f"{total - bad} of {total} passed")
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
    if len(argv) == 2 and argv[0] == "crash":
        try:
            with open(argv[1], errors="replace") as f:
                reason = disk_fault(f.read())
        except OSError:
            return 1
        if reason:
            print(reason)
            return 0
        return 1
    if len(argv) == 3 and argv[0] == "lost":
        try:
            with open(argv[1], errors="replace") as f, open(argv[2], errors="replace") as g:
                reason = runtime_lost(f.read(), g.read())
        except OSError:
            return 1
        if reason:
            print(reason)
            return 0
        return 1
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
