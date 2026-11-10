#!/usr/bin/env python3
"""CI only: a simulator that boots while the job does other work.

    python3 -I scripts/ci-simulator.py start <name> "<device name prefix>"   # e.g. "iPad Pro 13-inch", "iPhone Duo"
    python3 -I scripts/ci-simulator.py wait <name> "<device name prefix>" [s] # wait for it (default 1200 s)
    python3 -I scripts/ci-simulator.py --selftest

`start` picks the newest iOS runtime the image already has that offers that device and is no newer than the selected
Xcode's simulator SDK (an iPhone on iOS 27.2 beside Xcode 27.1 hung booting twice, spoonjoy-apple#218), then runs
.github/scripts/boot-sim.sh, the one place the boot and its escalating retries live (#57), in a detached process. It
returns at once, so the job downloads the build while the simulator boots.

`wait` waits for boot-sim.sh with its own limit, writes UDID and DESTINATION to $GITHUB_ENV, and fails with
boot-sim.sh's log, as "Simulator did not boot", when it failed or did not finish. The limit counts from `start`, so
the time spent downloading meanwhile counts toward it; a boot that has finished is read even when the wait starts after
the limit (the unit job's Release build can outlast it, #78). A boot has taken 10 min on a hosted runner, and boot-sim.sh
bounds each bootstatus at 7 min so a hang falls through to its next attempt; the wait step's own timeout is longer.

Before it passes, `wait` checks that the device is still Booted and its runtime is still listed as available: a
runtime that fails to mount ("Malformed bundle") can vanish after the boot, and the test launch then fails with
"runtime path not found" (gatefold#71). If not, it runs boot-sim.sh once more for a fresh device, on the time left.
`erase <name> <udid>` was the cold step's erase, unused by the workflow since gatefold#150 (kept for a quick way back;
follow-up to remove it): shutdown, erase, boot and bootstatus, each bounded, then the same
check; if the runtime went, one fresh device erased the same way. It prints the UDID to test on.
Offline test: bash scripts/test-ci-simulator.sh (a fake xcrun and boot-sim.sh; no simulator).

A prefix that is a whole device name ("iPhone Duo") picks that device only, never a sibling such as "iPhone Duo Pro".
"""
import json
import os
import platform
import signal
import subprocess
import sys
import tempfile
import time
from contextlib import redirect_stdout
from pathlib import Path

BOOT_SIM = Path(os.environ.get("CI_SIMULATOR_BOOT_SIM")
                or Path(__file__).resolve().parent.parent / ".github" / "scripts" / "boot-sim.sh")


def state_dir():
    d = Path(os.environ.get("RUNNER_TEMP") or tempfile.gettempdir()) / "ci-simulator"
    d.mkdir(parents=True, exist_ok=True)
    return d


def version(v):
    return [int(p) for p in v.split(".")]


def pick(runtimes, prefix, sdk):
    """(runtime identifier, device type identifier): the newest runtime at or below the SDK that offers the device."""
    top = version(sdk)[:2]
    fits = [r for r in runtimes
            if r.get("platform") == "iOS" and r.get("isAvailable") and version(r["version"])[:2] <= top
            and any(d["name"].startswith(prefix) for d in r.get("supportedDeviceTypes", []))]
    if not fits:
        raise SystemExit(f"ci-simulator: no available iOS runtime at or below the iOS {sdk} SDK offers {prefix!r}")
    r = max(fits, key=lambda r: version(r["version"]))
    kinds = [d for d in r["supportedDeviceTypes"] if d["name"].startswith(prefix)]
    exact = [d for d in kinds if d["name"] == prefix]
    return r["identifier"], sorted(d["identifier"] for d in (exact or kinds))[-1]


def start(name, prefix):
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], capture_output=True, text=True,
                         check=True, timeout=60).stdout.strip()
    listing = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True,
                             check=True, timeout=120).stdout
    runtime, kind = pick(json.loads(listing)["runtimes"], prefix, sdk)
    print(f"Booting {kind} on {runtime} (simulator SDK {sdk})")
    d = state_dir()
    (d / f"{name}.started").write_text(f"{time.time()}\n")
    (d / f"{name}.plan").write_text(json.dumps({"kind": kind, "runtime": runtime, "prefix": prefix, "sdk": sdk}))
    # Detached, so it outlives this step: the UDID goes to <name>.udid, boot-sim.sh's exit code to <name>.status.
    subprocess.Popen(
        ["sh", "-c", '"$1" "$2" "$3" "$4" > "$5.udid"; echo $? > "$5.status"', "boot",
         str(BOOT_SIM), name, kind, runtime, str(d / name)],
        stdout=open(d / f"{name}.log", "ab"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        start_new_session=True)


def wait_boot(name, limit, clock=time.time, nap=time.sleep):
    """boot-sim.sh's exit code, or None if it has not finished within the limit, counted from `start`."""
    status = state_dir() / f"{name}.status"
    started = state_dir() / f"{name}.started"
    end = (float(started.read_text()) if started.exists() else clock()) + limit
    while True:
        # Read before the deadline check: a job that builds past the limit while the boot finishes must
        # still see it (#78: 8 of 9 "did not finish" reports came from a boot that had already finished).
        if status.exists() and status.read_text().strip():
            return int(status.read_text().strip())
        if clock() >= end:
            return None
        nap(2)


def outcome(code, udid, limit):
    if code is None:
        return f"boot-sim.sh did not finish within {limit} s"
    if code != 0:
        return f"boot-sim.sh exited {code}"
    return "booted" if udid else "boot-sim.sh printed no UDID"


def unready(udid, runtimes, devices):
    """Why a booted device can't take the tests yet, or None. The runtime can vanish after the boot ("Malformed
    bundle" while it mounts; the test launch then says "runtime path not found", gatefold#71)."""
    runtime = next((rt for rt, ds in devices.items() for d in ds if d.get("udid") == udid), None)
    if runtime is None:
        return f"{udid} is no longer listed"
    device = next(d for d in devices[runtime] if d.get("udid") == udid)
    state = device.get("state")
    if device.get("isAvailable") is False:
        return f"{udid} is unavailable ({device.get('availabilityError', 'no reason given')})"
    if state != "Booted":
        return f"{udid} is {state}, not Booted"
    if not any(r.get("identifier") == runtime and r.get("isAvailable") for r in runtimes):
        return f"its runtime {runtime} is no longer available"
    return None


def setting(name, default):
    """A number from the environment; unset or empty means the default."""
    return float(os.environ.get(name) or default)


BEGAN = time.time()
# The seconds this run may take: the step's own limit less a margin, from the workflow. Past it the step would be
# killed with no clear error, so what is left is checked before each bounded call (gatefold#74).
BUDGET = setting("CI_SIMULATOR_BUDGET", "inf")
MARGIN = 30  # kept to print the outcome and exit


class OutOfTime(Exception):
    pass


def left():
    return BEGAN + BUDGET - MARGIN - time.time()


def bounded(seconds):
    """A call's timeout, cut to what is left of the budget; OutOfTime when nothing is."""
    remaining = left()
    if remaining < 1:
        raise OutOfTime()
    return min(seconds, remaining)


def out_of_time(udid, doing):
    """The step's time ran out before the device was seen ready: it fails, with its own warning, never a kill.
    (A device is passed only on a check that answered Booted with its runtime available; no path runs out of
    time after such an answer, so out of time is always a failure, gatefold#74 review.)"""
    print(f"::warning title=Simulator check out of time::The step's time ran out {doing}; "
          f"{udid or 'the device'} was not seen Booted with its runtime available.")
    return f"the step's time ran out {doing}"


LIST_TRIES = 2  # a list that has not answered in this many tries says nothing about the device
LIST_TIMEOUT = setting("CI_SIMULATOR_LIST_TIMEOUT", "120")  # the offline test shortens it


def listing(what):
    """`simctl list <what> -j`, parsed, or None when it never answered in LIST_TRIES tries."""
    for n in range(1, LIST_TRIES + 1):
        try:
            out = subprocess.run(["xcrun", "simctl", "list", what, "-j"], capture_output=True, text=True,
                                 timeout=bounded(LIST_TIMEOUT))
            return json.loads(out.stdout)[what]
        except (OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
            print(f"simctl list {what}, try {n} of {LIST_TRIES}: no answer ({e!r})")
    return None


def check(udid):
    """None when the device is ready, else why not. Only an answer can say a device is not ready: a list that
    times out after a clean boot is the machine being slow (run 42502520118 replaced a healthy iPad over one), so
    the device is kept, with a warning. When the step's time runs out it raises OutOfTime."""
    runtimes, devices = listing("runtimes"), listing("devices")
    if runtimes is None or devices is None:
        print(f"::warning title=Simulator check unanswered::simctl list did not answer in {LIST_TRIES} tries; "
              f"keeping {udid}, whose boot finished.")
        return None
    return unready(udid, runtimes, devices)


def export(udid):
    env = os.environ.get("GITHUB_ENV")
    if env:
        with open(env, "a") as f:
            f.write(f"UDID={udid}\nDESTINATION=platform=iOS Simulator,arch={platform.machine()},id={udid}\n")


# One full boot-sim.sh attempt, the slowest that passes: bootstatus 420 s + its kill grace 5 + the listing 60 + its
# second ask 60 + the second bootstatus 90 + its grace 5 = 640 s, rounded up to 660. A fresh device never starts
# with less (it would be killed mid-attempt). What must be left to try one at all: that, plus the two `quietly` calls
# (60 s each) and the runtime listing (120 s): 660 + 240 = 900 s. The offline test shortens both.
# They fit the workflow's budgets less the 30 s margin. The wait step (1740 s, so 1710): the boot is read at up to
# 1200 s and the check takes up to 2 listings x 2 tries x 120 s = 480 s, so a fresh device fits when the first boot
# and its check took up to 1710 - 900 = 810 s, as a typical 3 to 10 min boot does; past that it fails, out of time,
# with its own message. The erase (1800 s, so 1770): a typical erase and check (about 130 s), a fresh device (900 s)
# and its own erase and check (about 130 s) take about 1160 s; the worst case (1140 s of erase calls) fails the same way.
BOOT_ATTEMPT = setting("CI_SIMULATOR_BOOT_ATTEMPT", "660")
RETRY_RESERVE = setting("CI_SIMULATOR_RETRY_RESERVE", "900")


def quietly(*args):
    try:
        subprocess.run(["xcrun", "simctl", *args], capture_output=True, timeout=60)
    except (OSError, subprocess.SubprocessError):
        pass


def again(name, limit):
    """Run boot-sim.sh once more, in the foreground, for a fresh device. (udid, outcome)

    It picks the runtime afresh, so a runtime that has gone is passed over for the newest one still available. Its
    stderr goes to the log file, not a pipe: boot-sim.sh's watchdog `sleep` can outlive it holding stderr open, and
    reading a pipe would wait for that sleep."""
    d = state_dir()
    plan_file = d / f"{name}.plan"
    if not plan_file.exists():
        return "", "no record of what `start` booted"
    plan = json.loads(plan_file.read_text())
    kind, runtime = plan["kind"], plan["runtime"]
    try:
        listing = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True,
                                 timeout=bounded(120)).stdout
        runtime, kind = pick(json.loads(listing)["runtimes"], plan["prefix"], plan["sdk"])
    except (SystemExit, OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
        print(f"Could not pick a runtime afresh ({e}); trying {runtime} again.")
    timeout = bounded(limit)
    if timeout < BOOT_ATTEMPT:
        return "", f"only {int(timeout)} s left, less than one boot attempt ({int(BOOT_ATTEMPT)} s), so no fresh device"
    print(f"Booting a fresh {kind} on {runtime}, within {int(timeout)} s")
    log = d / f"{name}-2.log"
    with open(log, "ab") as err:
        # Its own process group, so a timeout ends its bootstatus and watchdog too, not only its bash.
        proc = subprocess.Popen([str(BOOT_SIM), f"{name}-2", kind, runtime], stdout=subprocess.PIPE, stderr=err,
                                stdin=subprocess.DEVNULL, start_new_session=True)
        try:
            stdout, _ = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(proc.pid, sig)
                except ProcessLookupError:
                    break
                try:
                    proc.wait(timeout=5)
                    break
                except subprocess.TimeoutExpired:
                    pass
            print(log.read_text(errors="replace")[-4000:] if log.exists() else "")
            return "", f"the fresh device did not boot within {int(timeout)} s"
    print(log.read_text(errors="replace")[-4000:] if log.exists() else "")
    udid = stdout.decode(errors="replace").strip()
    return udid, outcome(proc.returncode, udid, int(timeout))


# Shutdown's bound is a setting so the offline test can make it hang. On a healthy runner an idle device shuts down in
# seconds; the one that hung past 120 s (job 129031300623) did so while `simctl list` hung too, so CoreSimulatorService
# was not answering: a longer bound or a second shutdown would only spend more of the step on the same stall.
ERASE_STEPS = [(("shutdown",), setting("CI_SIMULATOR_SHUTDOWN_TIMEOUT", "120")), (("erase",), 300), (("boot",), 300),
               (("bootstatus", "-b"), 420)]


def erase(udid, steps=ERASE_STEPS):
    """Shut down, erase, boot and wait for the device, each call bounded (a runtime that won't mount hangs bootstatus,
    #57), then check it. "ready", or why not. Any call that does not finish or fails fails the erase, with its reason:
    the cold test is only worth running on an erased device, and a shutdown that hung leaves the device Booted, so the
    erase after it fails (405) and the device was never erased (gatefold#137, job 129031300623)."""
    for args, limit in steps:
        cmd = (args[0], udid, *args[1:])
        timeout = bounded(limit)
        try:
            out = subprocess.run(["xcrun", "simctl", *cmd], capture_output=True, text=True, timeout=timeout)
        except subprocess.TimeoutExpired:
            print(f"simctl {' '.join(cmd)} hung past {int(timeout)} s")
            return f"simctl {args[0]} hung past {int(timeout)} s"
        except OSError as e:
            return f"simctl could not run ({e!r})"
        said = (out.stdout + out.stderr).strip()
        print(f"simctl {' '.join(cmd)}: exit {out.returncode} {out.stderr.strip()[-300:]}")
        # A device that is already shut down is what the shutdown is for.
        if args[0] == "shutdown" and out.returncode != 0 and "current state: Shutdown" in said:
            continue
        if out.returncode != 0:
            return f"simctl {args[0]} exited {out.returncode}" + (" and said Failed" if "Failed" in said else "")
        # As boot-sim.sh: a boot whose bootstatus failed is a failed boot, even if the device is listed Booted.
        if args[0] == "bootstatus" and "Failed" in said:
            return "bootstatus said Failed"
    problem = check(udid)
    return "ready" if problem is None else problem


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) >= 3 and argv[0] == "start":
        try:
            start(argv[1], argv[2])
        except (SystemExit, OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
            # The wait step reports it, with the log; the job goes on downloading meanwhile.
            d = state_dir()
            (d / f"{argv[1]}.log").open("a").write(f"ci-simulator start failed: {e!r}\n")
            (d / f"{argv[1]}.status").write_text("97\n")
        return 0
    if len(argv) == 3 and argv[0] == "erase":
        # The cold step: erase the booted device and boot it again, each simctl call bounded, then the same check.
        # If its runtime went (gatefold#71), one fresh device, erased the same way. Prints the UDID; fails otherwise.
        # Unused by the workflow since gatefold#150: a just-created simulator is at least as cold (build 19: RotationRepro
        # green in 0 of 3 rounds on one, 6 of 9 after an erase), so the cold step tests on the job's own new iPad.
        name, udid = argv[1], argv[2]
        with redirect_stdout(sys.stderr):
            try:
                said = erase(udid)
                if said != "ready" and left() < RETRY_RESERVE:
                    said = out_of_time(udid, f"for a fresh device (after the erase, {said})")
                elif said != "ready":
                    print(f"::warning title=Infrastructure retry::After the erase, {said}. Erasing a fresh device.")
                    quietly("shutdown", udid)
                    quietly("delete", udid)
                    udid, said = again(name, BOOT_ATTEMPT)
                    if said == "booted":
                        said = erase(udid)
            except OutOfTime:
                said = out_of_time(udid, "during the erase")
        if said == "ready":
            export(udid)
            print(udid)
            return 0
        print(f"::error title=Simulator did not boot::{said}. No app code ran.", file=sys.stderr)
        return 1
    if len(argv) >= 3 and argv[0] == "wait":
        name, limit = argv[1], int(argv[3]) if len(argv) > 3 else 1200
        code = wait_boot(name, limit)
        udid_file = state_dir() / f"{name}.udid"
        udid = udid_file.read_text().strip() if udid_file.exists() else ""
        said = outcome(code, udid, limit)
        log = state_dir() / f"{name}.log"
        print(log.read_text(errors="replace")[-4000:] if log.exists() else "(no boot-sim.sh log)")
        try:
            problem = check(udid) if said == "booted" else None
        except OutOfTime:
            said = out_of_time(udid, "while checking it")
        if said == "booted":
            if problem is None:
                export(udid)
                print(f"{udid} booted, and its runtime is available")
                return 0
            if left() < RETRY_RESERVE:
                print(f"::error title=Simulator did not boot::"
                      f"{out_of_time(udid, f'for a fresh device (booted, but {problem})')}. No app code ran.")
                return 1
            # The machine, not the app: one fresh device, on whatever time is left (gatefold#71).
            print(f"::warning title=Infrastructure retry::Booted, but {problem}. Booting a fresh device.")
            quietly("shutdown", udid)
            quietly("delete", udid)
            started = state_dir() / f"{name}.started"
            boot_left = (float(started.read_text()) if started.exists() else time.time()) + limit - time.time()
            try:
                udid, said = again(name, max(boot_left, RETRY_RESERVE))
            except OutOfTime:
                udid, said = "", "the step's time ran out booting a fresh device"
            if said == "booted":
                try:
                    problem = check(udid)
                except OutOfTime:
                    problem = out_of_time(udid, "while checking the fresh device")
                if problem is None:
                    export(udid)
                    print(f"{udid} booted on the second try, and its runtime is available")
                    return 0
                said = f"booted again, but {problem}"
        print(f"::error title=Simulator did not boot::{said}. No app code ran.")
        return 1
    print(__doc__, file=sys.stderr)
    return 2


def selftest():
    ipad = {"name": "iPad Pro 13-inch (M5)", "identifier": "iPad-Pro-13-M5"}
    duo = {"name": "iPhone Duo", "identifier": "iPhone-Duo"}
    runtimes = [
        {"platform": "iOS", "isAvailable": True, "version": "27.0", "identifier": "iOS-27-0", "supportedDeviceTypes": [ipad]},
        {"platform": "iOS", "isAvailable": True, "version": "27.1", "identifier": "iOS-27-1", "supportedDeviceTypes": [ipad, duo]},
        {"platform": "iOS", "isAvailable": True, "version": "27.2", "identifier": "iOS-27-2", "supportedDeviceTypes": [ipad, duo]},
        {"platform": "iOS", "isAvailable": False, "version": "27.3", "identifier": "iOS-27-3", "supportedDeviceTypes": [duo]},
    ]
    assert pick(runtimes, "iPhone Duo", "27.1") == ("iOS-27-1", "iPhone-Duo"), "never newer than the SDK"
    assert pick(runtimes, "iPad Pro 13-inch", "27.2.1") == ("iOS-27-2", "iPad-Pro-13-M5")
    assert pick(runtimes, "iPhone Duo", "27.4") == ("iOS-27-2", "iPhone-Duo"), "only available runtimes"
    pro = {"name": "iPhone Duo Pro", "identifier": "iPhone-Duo-Pro"}
    sib = [dict(runtimes[1], supportedDeviceTypes=[duo, pro])]
    assert pick(sib, "iPhone Duo", "27.1") == ("iOS-27-1", "iPhone-Duo"), "a whole name never picks a sibling"
    try:
        pick(runtimes, "iPhone Duo", "27.0")
        raise AssertionError("no runtime offering the device must fail")
    except SystemExit:
        pass
    os.environ["RUNNER_TEMP"] = tempfile.mkdtemp()
    now = [0.0]
    clock, nap = (lambda: now[0]), (lambda s: now.__setitem__(0, now[0] + s))
    assert wait_boot("hung", 10, clock, nap) is None, "a hang times out"
    (state_dir() / "ok.status").write_text("0\n")
    assert wait_boot("ok", 10, clock, nap) == 0
    (state_dir() / "late.started").write_text("-100\n")
    now[0] = 0.0
    assert wait_boot("late", 50, clock, nap) is None, "the limit counts from start"
    assert now[0] == 0.0, "no waiting once the limit has passed"
    # #78: the unit job's Release build ran past the limit while the boot had long finished; a
    # finished boot is read even when the wait step starts after the limit.
    (state_dir() / "done-late.started").write_text("-2000\n")
    (state_dir() / "done-late.status").write_text("0\n")
    assert wait_boot("done-late", 1200, clock, nap) == 0, "a boot that finished is read after the limit"
    assert outcome(0, "ABC", 600) == "booted"
    assert outcome(0, "", 600) == "boot-sim.sh printed no UDID"
    assert outcome(1, "", 600) == "boot-sim.sh exited 1"
    assert outcome(None, "", 600) == "boot-sim.sh did not finish within 600 s"
    assert BOOT_SIM.exists(), "boot-sim.sh is where start runs it from"
    devs = {"iOS-27-2": [{"udid": "a", "state": "Booted"}, {"udid": "b", "state": "Shutdown"}]}
    rts = [{"identifier": "iOS-27-2", "isAvailable": True}]
    assert unready("a", rts, devs) is None
    assert unready("b", rts, devs) == "b is Shutdown, not Booted"
    assert unready("c", rts, devs) == "c is no longer listed"
    assert unready("a", [{"identifier": "iOS-27-2", "isAvailable": False}], devs) == \
        "its runtime iOS-27-2 is no longer available", "gatefold#71: booted, then the runtime went"
    assert unready("a", [], devs) == "its runtime iOS-27-2 is no longer available"
    gone = {"iOS-27-2": [{"udid": "a", "state": "Booted", "isAvailable": False, "availabilityError": "runtime profile not found"}]}
    assert unready("a", rts, gone) == "a is unavailable (runtime profile not found)"
    print("ci-simulator: selftest passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
