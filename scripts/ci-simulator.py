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
the time spent downloading meanwhile counts toward it. A boot has taken 10 min on a hosted runner, and boot-sim.sh
bounds each bootstatus at 7 min so a hang falls through to its next attempt; the wait step's own timeout is longer.

Before it passes, `wait` checks that the device is still Booted and its runtime is still listed as available: a
runtime that fails to mount ("Malformed bundle") can vanish after the boot, and the test launch then fails with
"runtime path not found" (gatefold#71). If not, it runs boot-sim.sh once more for a fresh device, on the time left.
`ready <name> <udid>` runs the same check after a step re-boots the device itself (the cold step's erase), and
prints the UDID to test on: that one, or one fresh device.
Offline test: bash scripts/test-ci-simulator.sh (a fake xcrun and boot-sim.sh; no simulator).

A prefix that is a whole device name ("iPhone Duo") picks that device only, never a sibling such as "iPhone Duo Pro".
"""
import json
import os
import platform
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
    while clock() < end:
        if status.exists() and status.read_text().strip():
            return int(status.read_text().strip())
        nap(2)
    return None


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


def check(udid):
    try:
        runtimes = json.loads(subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True,
                                             text=True, timeout=120).stdout)["runtimes"]
        devices = json.loads(subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True,
                                            text=True, timeout=120).stdout)["devices"]
    except (OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
        return f"simctl could not list the simulators ({e!r})"
    return unready(udid, runtimes, devices)


def export(udid):
    env = os.environ.get("GITHUB_ENV")
    if env:
        with open(env, "a") as f:
            f.write(f"UDID={udid}\nDESTINATION=platform=iOS Simulator,arch={platform.machine()},id={udid}\n")


RETRY_RESERVE = 300  # the least a fresh device gets, past the limit if need be; the wait step allows for it


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
                                 timeout=120).stdout
        runtime, kind = pick(json.loads(listing)["runtimes"], plan["prefix"], plan["sdk"])
    except (SystemExit, OSError, subprocess.SubprocessError, ValueError, KeyError) as e:
        print(f"Could not pick a runtime afresh ({e}); trying {runtime} again.")
    print(f"Booting a fresh {kind} on {runtime}")
    log = d / f"{name}-2.log"
    try:
        with open(log, "ab") as err:
            out = subprocess.run([str(BOOT_SIM), f"{name}-2", kind, runtime], stdout=subprocess.PIPE, stderr=err,
                                 stdin=subprocess.DEVNULL, timeout=limit)
    except subprocess.TimeoutExpired:
        print(log.read_text(errors="replace")[-4000:] if log.exists() else "")
        return "", f"the fresh device did not boot within {int(limit)} s"
    print(log.read_text(errors="replace")[-4000:] if log.exists() else "")
    udid = out.stdout.decode(errors="replace").strip()
    return udid, outcome(out.returncode, udid, limit)


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
    if len(argv) == 3 and argv[0] == "ready":
        # After a step re-boots the device itself (the cold step's erase), the same check: print the UDID to test on,
        # this one or one fresh device (also written to $GITHUB_ENV for later steps), or fail (gatefold#71).
        name, udid = argv[1], argv[2]
        problem = check(udid)
        if problem is None:
            print(udid)
            return 0
        print(f"::warning title=Infrastructure retry::After its re-boot, {problem}. Booting a fresh device.",
              file=sys.stderr)
        quietly("shutdown", udid)
        quietly("delete", udid)
        with redirect_stdout(sys.stderr):
            udid, said = again(name, 600)
            if said == "booted":
                problem = check(udid)
                said = "booted" if problem is None else f"booted again, but {problem}"
        if said == "booted":
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
        if said == "booted":
            problem = check(udid)
            if problem is None:
                export(udid)
                print(f"{udid} booted, and its runtime is available")
                return 0
            # The machine, not the app: one fresh device, on whatever time is left (gatefold#71).
            print(f"::warning title=Infrastructure retry::Booted, but {problem}. Booting a fresh device.")
            quietly("shutdown", udid)
            quietly("delete", udid)
            started = state_dir() / f"{name}.started"
            left = (float(started.read_text()) if started.exists() else time.time()) + limit - time.time()
            udid, said = again(name, max(left, RETRY_RESERVE))
            if said == "booted":
                problem = check(udid)
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
