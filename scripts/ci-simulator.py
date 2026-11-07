#!/usr/bin/env python3
"""CI only: a simulator that boots while the job does other work.

    python3 -I scripts/ci-simulator.py start <name> "<device name prefix>"   # e.g. "iPad Pro 13-inch", "iPhone Duo"
    python3 -I scripts/ci-simulator.py wait <name> "<device name prefix>" [s] # wait for it (default 600 s)
    python3 -I scripts/ci-simulator.py --selftest

`start` picks the newest iOS runtime the image already has that offers that device and is no newer than the selected
Xcode's simulator SDK (an iPhone on iOS 27.2 beside Xcode 27.1 hung booting twice, spoonjoy-apple#218), then runs
.github/scripts/boot-sim.sh, the one place the boot and its escalating retries live (#57), in a detached process. It
returns at once, so the job downloads the build while the simulator boots.

`wait` waits for boot-sim.sh with its own limit, writes UDID and DESTINATION to $GITHUB_ENV, and fails with
boot-sim.sh's log, as "Simulator did not boot", when it failed or did not finish. boot-sim.sh's three attempts with
their service restarts fit in 600 s; the wait step's own timeout is a little longer.
"""
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from pathlib import Path

BOOT_SIM = Path(__file__).resolve().parent.parent / ".github" / "scripts" / "boot-sim.sh"


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
    return r["identifier"], sorted(d["identifier"] for d in r["supportedDeviceTypes"] if d["name"].startswith(prefix))[-1]


def start(name, prefix):
    sdk = subprocess.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], capture_output=True, text=True,
                         check=True, timeout=60).stdout.strip()
    listing = subprocess.run(["xcrun", "simctl", "list", "runtimes", "-j"], capture_output=True, text=True,
                             check=True, timeout=120).stdout
    runtime, kind = pick(json.loads(listing)["runtimes"], prefix, sdk)
    print(f"Booting {kind} on {runtime} (simulator SDK {sdk})")
    d = state_dir()
    # Detached, so it outlives this step: the UDID goes to <name>.udid, boot-sim.sh's exit code to <name>.status.
    subprocess.Popen(
        ["sh", "-c", '"$1" "$2" "$3" "$4" > "$5.udid"; echo $? > "$5.status"', "boot",
         str(BOOT_SIM), name, kind, runtime, str(d / name)],
        stdout=open(d / f"{name}.log", "ab"), stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        start_new_session=True)


def wait_boot(name, limit, clock=time.monotonic, nap=time.sleep):
    """boot-sim.sh's exit code, or None if it has not finished within the limit."""
    status = state_dir() / f"{name}.status"
    end = clock() + limit
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


def export(udid):
    env = os.environ.get("GITHUB_ENV")
    if env:
        with open(env, "a") as f:
            f.write(f"UDID={udid}\nDESTINATION=platform=iOS Simulator,arch={platform.machine()},id={udid}\n")


def main(argv):
    if argv == ["--selftest"]:
        return selftest()
    if len(argv) >= 3 and argv[0] == "start":
        start(argv[1], argv[2])
        return 0
    if len(argv) >= 3 and argv[0] == "wait":
        name, limit = argv[1], int(argv[3]) if len(argv) > 3 else 600
        code = wait_boot(name, limit)
        udid_file = state_dir() / f"{name}.udid"
        udid = udid_file.read_text().strip() if udid_file.exists() else ""
        said = outcome(code, udid, limit)
        log = state_dir() / f"{name}.log"
        print(log.read_text(errors="replace")[-4000:] if log.exists() else "(no boot-sim.sh log)")
        if said == "booted":
            export(udid)
            print(f"{udid} booted")
            return 0
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
    assert outcome(0, "ABC", 600) == "booted"
    assert outcome(0, "", 600) == "boot-sim.sh printed no UDID"
    assert outcome(1, "", 600) == "boot-sim.sh exited 1"
    assert outcome(None, "", 600) == "boot-sim.sh did not finish within 600 s"
    assert BOOT_SIM.exists(), "boot-sim.sh is where start runs it from"
    print("ci-simulator: selftest passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
