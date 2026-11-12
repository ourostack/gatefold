#!/usr/bin/env python3
"""The host's side of the App Store screenshots (screenshots/spec.json, GatefoldListingShots).

    python3 -I scripts/screenshots/capture.py watch --udid U --device ipad --dir D [--spec S]
        Until D/finished exists: for each D/<scene>.ready, stage the status bar, shoot until three frames in a row
        are the same, keep that frame as D/<scene>.png and write D/<scene>.done (or D/<scene>.fail with the reason).
    python3 -I scripts/screenshots/capture.py stage --udid U [--spec S]
        Light appearance, default text size, staged status bar.
    python3 -I scripts/screenshots/capture.py recover --udid U [--spec S]
        Reboot a simulator that stopped answering (shut down, boot and bootstatus the same UDID, each bounded), then
        stage it again. The watcher asks for this by writing D/<scene>.<try>.stuck (gatefold#150).
    python3 -I scripts/screenshots/capture.py device --device iphone [--spec S]    # the simulator name to boot
    python3 -I scripts/screenshots/capture.py check --device ipad --dir D [--spec S]
        Every scene of that device has a shot of the device's screen size.
    python3 -I scripts/screenshots/capture.py compare A B
        The same commit gives the same pixels: every PNG in A has a byte-identical twin in B. Writes nothing.
    python3 -I scripts/screenshots/capture.py fingerprint [--spec S]
        One hash of everything that can change what a shot shows; a release renders only when it changed.
    python3 -I scripts/screenshots/capture.py --selftest
Logs carry scene ids and hashes only.
"""
import hashlib
import json
import os
import pathlib
import struct
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = ROOT / "screenshots" / "spec.json"
# What can change a shot: the app, its packages' code, the project, the scenes, the spec and the composer.
# Also what renders it: the dependencies, the pinned Xcode and simulator, and the workflow's appearance settings.
ON_SCREEN = ["Gatefold", "Packages/GatefoldCore/Sources", "Packages/GatefoldCloud/Sources",
             "Packages/GatefoldCore/Package.swift", "Packages/GatefoldCloud/Package.swift",
             "Packages/GatefoldCloud/Package.resolved", "project.yml", "GatefoldListingShots", "screenshots",
             "scripts/screenshots", ".github/actions/select-xcode", ".github/workflows/screenshots.yml"]
# The watcher gives up after SHOOT_LIMIT seconds of shooting; the scene test waits longer (ListingShotsUITests: 360 s).
STABLE_FRAMES, SHOOT_LIMIT, FRAME_GAP = 3, 80, 0.8
# One screenshot call. It is a hang guard, not a judgment: answered calls' times are logged per scene and kind
# ("slowest"), and one that has not answered in 15 s is asked again, so a hung screenshot costs 15 s, never a scene.
SIMCTL_LIMIT = 15
# The status bar is staged once a hand-off, before its first frame, and waited for until it answers: on a busy runner
# `simctl status_bar override` is slow, not dead. PR #292's job 131093420221 and probe run 43184304862 left it
# unanswered at 15 s in most hand-offs while every screenshot answered, and one answered on its third ask (under 45 s).
# Asking again only queues another request behind the slow one, and a reboot did not help (4 reboots, each followed
# by a status bar that again did not answer in 15 s). So one ask, bounded at 120 s as a hang guard; unanswered by then,
# the device is stuck.
STATUS_BAR_LIMIT = 120
UI_LIMIT = 60  # `simctl ui` appearance and text size, when staging; slow on a busy runner like the status bar
# A hand-off may lose ASKS - 1 screenshots to no answer, each asked again; the ASKS-th means the device stopped
# answering (gatefold#150): the scene fails with D/<handoff>.stuck and the workflow reboots the device for a new try.
# The frames either side of an unanswered call are not "in a row", so the stable run starts again after one.
ASKS = 3
LIST_LIMIT = 30  # the one device listing a stuck hand-off makes, to tell the device from CoreSimulatorService
# Worst case for one hand-off: the status bar (120), SHOOT_LIMIT of shooting (80), its last screenshot (15), ASKS
# unanswered screenshots (3 x 15) and the listing (30): 290 s. The scene test waits 360 s.
WATCH_WORST = STATUS_BAR_LIMIT + SHOOT_LIMIT + SIMCTL_LIMIT + ASKS * SIMCTL_LIMIT + LIST_LIMIT
# The reboot (recover): an idle device shuts down in seconds, and one that does not in 120 s is a service that is not
# answering (ci-simulator.py's ERASE_STEPS, job 129031300623). First boots on these runners took 86-555 s
# (gatefold#150, run 42768198374); a reboot is no first boot, so 600 s for its bootstatus is past the slowest seen.
REBOOT_STEPS = [(("shutdown",), 120), (("boot",), 300), (("bootstatus", "-b"), 600)]
# After those (1020 s), the staging (2 x 60 + 120 s) and ci-simulator.py's quiet (QUIET_LIMIT, 120 s): 23 min a reboot.


def requiet(udid):
    """The first-boot jobs ci-simulator.py removed (gatefold#209) come back with a reboot; remove them again."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("ci_simulator", ROOT / "scripts" / "ci-simulator.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    mod.quiet(udid)
# Books in the public domain everywhere; the shelf launch argument may name only these.
PUBLIC_DOMAIN = {"moby-dick", "pride-and-prejudice", "frankenstein", "dracula", "alice-in-wonderland",
                 "sherlock-holmes", "emma"}


def load(spec):
    return json.loads(pathlib.Path(spec).read_text())


def scenes_for(spec, device):
    return [s for s in spec["scenes"] if device in s["devices"]]


def status_bar_cmd(udid, spec):
    sb = spec["status_bar"]
    return ["xcrun", "simctl", "status_bar", udid, "override", "--time", sb["time"], *sb["args"]]


def status_bar(udid, spec):
    subprocess.run(status_bar_cmd(udid, spec), check=True, capture_output=True, timeout=STATUS_BAR_LIMIT)


def stage(udid, spec, run=subprocess.run, log=print):
    """Light appearance, default text size and the staged status bar: what every shot is taken under."""
    for cmd, limit in ((["xcrun", "simctl", "ui", udid, "appearance", "light"], UI_LIMIT),
                       (["xcrun", "simctl", "ui", udid, "content_size", "large"], UI_LIMIT),
                       (status_bar_cmd(udid, spec), STATUS_BAR_LIMIT)):
        t = time.monotonic()
        run(cmd, check=True, capture_output=True, timeout=limit)
        log(f"stage: simctl {cmd[2]} {cmd[4] if cmd[2] == 'ui' else 'override'} answered in {time.monotonic() - t:.1f} s",
            flush=True)


class Stuck(Exception):
    """The device stopped answering: a status bar unanswered in STATUS_BAR_LIMIT, or ASKS screenshots in a hand-off."""


class Device:
    """The simulator the watcher shoots, through bounded simctl calls that are asked again when they don't answer.

    CAPTURE_FORCE_HANG=N (the workflow's dispatch input force_hang) runs the first N screenshot calls of this watcher
    as a command that never answers in time, so a probe run can prove the recovery path on a healthy runner."""

    def __init__(self, udid, run=subprocess.run, log=print, force=0):
        self.udid, self.run, self.log, self.force = udid, run, log, force
        self.begin()

    def begin(self):
        self.unanswered, self.lost, self.slowest = 0, 0.0, {}

    def took(self):
        return ", ".join(f"slowest {k} {v:.1f} s" for k, v in sorted(self.slowest.items()))

    def call(self, cmd, what, handoff, limit=SIMCTL_LIMIT, again=True):
        while True:
            asked = cmd
            if self.force > 0 and what == "io screenshot":
                self.force -= 1
                asked = ["sleep", str(SIMCTL_LIMIT * 4)]
            t = time.monotonic()
            try:
                out = self.run(asked, check=True, capture_output=True, timeout=limit)
                self.slowest[what] = max(self.slowest.get(what, 0.0), time.monotonic() - t)
                return out
            except subprocess.TimeoutExpired:
                self.lost += time.monotonic() - t
                self.unanswered += 1
                if not again:
                    raise Stuck(f"simctl {what} did not answer in {limit} s")
                if self.unanswered >= ASKS:
                    raise Stuck(f"simctl {what} did not answer in {SIMCTL_LIMIT} s, "
                                f"{self.unanswered} calls unanswered in this hand-off")
                self.log(f"{handoff}: simctl {what} did not answer in {SIMCTL_LIMIT} s "
                         f"({self.unanswered} of {ASKS}); asking again", flush=True)

    def listing_answers(self):
        """Whether CoreSimulatorService answers a device listing: if not, the hang is the service's, not the device's."""
        try:
            self.run(["xcrun", "simctl", "list", "devices", "-j"], check=True, capture_output=True, timeout=LIST_LIMIT)
            return True
        except (OSError, subprocess.SubprocessError):
            return False


def recover(udid, spec, run=subprocess.run, log=print, quiet=requiet):
    """Reboot the same UDID and stage it again. None when it answers again, else why not."""
    for args, limit in REBOOT_STEPS:
        cmd = ["xcrun", "simctl", args[0], udid, *args[1:]]
        t = time.monotonic()
        try:
            out = run(cmd, capture_output=True, text=True, timeout=limit)
        except subprocess.TimeoutExpired:
            if args[0] == "shutdown":
                # The device can't be reached through the service; a fresh device would be booted by the same one.
                return (f"simctl shutdown hung past {limit} s: CoreSimulatorService is not answering, so neither a "
                        f"reboot nor a fresh simulator can help")
            return f"simctl {' '.join(args)} hung past {limit} s"
        said = ((out.stdout or "") + (out.stderr or "")).strip()
        log(f"recover: simctl {' '.join(args)} {udid}: exit {out.returncode} in {time.monotonic() - t:.0f} s", flush=True)
        if args[0] == "shutdown" and out.returncode != 0 and "current state: Shutdown" in said:
            continue
        if out.returncode != 0 or (args[0] == "bootstatus" and "Failed" in said):
            return f"simctl {args[0]} exited {out.returncode}"
    try:
        stage(udid, spec, run, log)
    except subprocess.TimeoutExpired as exc:
        return f"the rebooted device did not answer staging in {exc.timeout:.0f} s"
    except subprocess.CalledProcessError as exc:
        return f"staging the rebooted device failed (exit {exc.returncode})"
    quiet(udid)
    log(f"recover: {udid} rebooted, staged and quieted", flush=True)
    return None


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    return struct.unpack(">II", head[16:24])


def settled(hashes, n=STABLE_FRAMES):
    """True when the last n frame hashes are the same."""
    return len(hashes) >= n and len(set(hashes[-n:])) == 1


def shoot(dev, display, out, spec, handoff=None):
    """Shoots until the screen holds still. Returns (ok, why); raises Stuck when the device stopped answering."""
    hashes = []
    with tempfile.TemporaryDirectory(prefix="shot-") as t:
        return shoot_into(pathlib.Path(t), dev, display, out, spec, hashes, handoff or out.stem)


def shoot_into(tmp, dev, display, out, spec, hashes, handoff, nap=time.sleep):
    dev.begin()
    # Again for each hand-off: after a launch the iPad's bar works out its weekday anew. Before the first frame, and
    # outside SHOOT_LIMIT, so a slow answer costs no frame time.
    dev.call(status_bar_cmd(dev.udid, spec), "status_bar", handoff, limit=STATUS_BAR_LIMIT, again=False)
    dev.lost = 0.0
    started = time.monotonic()
    i = 0
    # SHOOT_LIMIT counts the time spent shooting; a call that never answered is bounded by count (ASKS), not by it.
    while time.monotonic() - started - dev.lost < SHOOT_LIMIT:
        before = dev.unanswered
        frame = tmp / f"{i}.png"
        cmd = ["xcrun", "simctl", "io", dev.udid, "screenshot", "--type=png"]
        if display:
            cmd.append(f"--display={display}")
        dev.call(cmd + [str(frame)], "io screenshot", handoff)
        if dev.unanswered != before:
            hashes.clear()  # what the screen did while a call hung is unknown, so the run of equal frames starts again
        hashes.append(hashlib.sha256(frame.read_bytes()).hexdigest())
        if settled(hashes):
            frame.replace(out)
            lost = f", {dev.unanswered} calls asked again" if dev.unanswered else ""
            return True, f"settled after {i + 1} frames ({dev.took()}{lost})"
        i += 1
        nap(FRAME_GAP)
    # Keep the last two frames in unsettled/, out of the shots' own glob, so the artifact shows what kept moving.
    keep = out.parent / "unsettled"
    keep.mkdir(exist_ok=True)
    for n, j in enumerate((i - 2, i - 1), 1):
        if j >= 0 and (tmp / f"{j}.png").exists():
            shutil.copyfile(tmp / f"{j}.png", keep / f"{handoff}-{n}.png")
    return False, f"the screen never held still for {STABLE_FRAMES} frames in {SHOOT_LIMIT} s"


def watch(udid, device, d, spec, dev=None):
    d = pathlib.Path(d)
    display = spec["devices"][device].get("display")
    force = os.environ.get("CAPTURE_FORCE_HANG") or "0"
    dev = dev or Device(udid, force=int(force) if force.isdigit() else 0)
    print(f"watching {d} for {device} scenes" + (f", the first {dev.force} screenshot calls forced to hang"
                                                 if dev.force else ""), flush=True)
    while not (d / "finished").exists():
        sweep(d, dev, display, spec)
        time.sleep(0.3)


def sweep(d, dev, display, spec, log=print):
    """Shoot every scene that is ready and not yet answered."""
    # <scene>.<try>.ready: each try has its own hand-off files, so a late answer to one never passes the next.
    for ready in sorted(d.glob("*.ready")):
        handoff = ready.stem
        scene = handoff.split(".", 1)[0]
        if (d / f"{handoff}.done").exists() or (d / f"{handoff}.fail").exists():
            continue
        try:
            ok, why = shoot(dev, display, d / f"{scene}.png", spec, handoff)
        except Stuck as exc:
            where = ("the device listing answered, so the device is stuck, not the service"
                     if dev.listing_answers() else "the device listing did not answer either")
            ok, why = False, f"the simulator stopped answering: {exc}; {where}"
            (d / f"{handoff}.stuck").write_text(why)  # before .fail: the workflow reads it once the try ends
        except subprocess.CalledProcessError as exc:
            ok, why = False, f"simctl failed: {exc.stderr.decode(errors='replace').strip()[:200]}"
        except Exception as exc:  # never leave the scene waiting: say why
            ok, why = False, f"the watcher failed: {type(exc).__name__}: {exc}"[:300]
        if ok:
            log(f"{handoff}: {why}, sha256 {sha(d / f'{scene}.png')[:16]}", flush=True)
            (d / f"{handoff}.done").write_text(why)
        else:
            log(f"{handoff}: {why}", flush=True)
            (d / f"{handoff}.fail").write_text(why)


def sha(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def check(device, d, spec):
    want = spec["devices"][device]["screen"]
    problems = []
    for s in scenes_for(spec, device):
        p = pathlib.Path(d) / f"{s['id']}.png"
        if not p.exists():
            problems.append(f"{device} {s['id']}: no shot")
            continue
        w, h = png_size(p)
        if sorted((w, h)) != sorted(want):
            problems.append(f"{device} {s['id']}: {w}x{h}, but the {device}'s screen is {want[0]}x{want[1]}")
    return problems


def compare(a, b):
    a, b = pathlib.Path(a), pathlib.Path(b)
    names = sorted(p.name for p in a.glob("*.png"))
    problems = [] if names else [f"{a} has no shots"]
    for n in names:
        if not (b / n).exists():
            problems.append(f"{n}: only in the first pass")
        elif sha(a / n) != sha(b / n):
            problems.append(f"{n}: the two passes differ ({sha(a / n)[:12]} and {sha(b / n)[:12]})")
        else:
            print(f"{n}: {sha(a / n)[:16]} both passes")
    for p in sorted(b.glob("*.png")):
        if not (a / p.name).exists():
            problems.append(f"{p.name}: only in the second pass")
    return problems


def fingerprint(root=ROOT):
    listing = subprocess.run(["git", "ls-tree", "-r", "HEAD", "--", *ON_SCREEN], cwd=root, check=True,
                             capture_output=True, text=True).stdout
    return hashlib.sha256(listing.encode()).hexdigest()


def device_name(device, spec):
    """The first of the device's names this Mac's simulators offer, as a prefix: "iPad Pro 13-inch" is offered as
    "iPad Pro 13-inch (M5)". ci-simulator.py matches the same way (a whole name never picks a sibling)."""
    d = spec["devices"][device]
    names = [d["name"], *d.get("fallbacks", [])]
    listing = json.loads(subprocess.run(["xcrun", "simctl", "list", "devicetypes", "-j"], check=True,
                                        capture_output=True, text=True).stdout)
    return pick_name(names, [t["name"] for t in listing["devicetypes"]])


def pick_name(names, offered):
    for n in names:
        if any(o == n or o.startswith(n + " (") for o in offered):
            return n
    raise SystemExit(f"capture: this Mac offers none of {names} (it offers {sorted(offered)})")


class FakeSimctl:
    """Answers like simctl, except the calls listed in `hang` (1-based, counted over screenshot calls) time out."""

    def __init__(self, hang=(), frames=None, listing=True, steps=None):
        self.hang, self.frames, self.listing, self.steps = set(hang), frames, listing, steps or {}
        self.shots, self.calls = 0, []

    def __call__(self, cmd, check=False, capture_output=False, timeout=None, text=False):
        self.calls.append(cmd[2] if cmd[0] == "xcrun" else cmd[0])
        if cmd[0] == "sleep":  # CAPTURE_FORCE_HANG's stand-in: never answers within the limit
            raise subprocess.TimeoutExpired(cmd, timeout)
        if cmd[2] == "io":
            self.shots += 1
            if self.shots in self.hang:
                raise subprocess.TimeoutExpired(cmd, timeout)
            frame = self.frames[self.shots - 1] if self.frames else b"still"
            pathlib.Path(cmd[-1]).write_bytes(frame)
        if cmd[2] == "list" and not self.listing:
            raise subprocess.TimeoutExpired(cmd, timeout)
        said = self.steps.get(cmd[2], (0, ""))
        if said == "hang":
            raise subprocess.TimeoutExpired(cmd, timeout)
        if check and said[0]:
            raise subprocess.CalledProcessError(said[0], cmd, said[1], "")
        return subprocess.CompletedProcess(cmd, said[0], said[1], "")


def selftest_recovery():
    spec = {"status_bar": {"time": "2026-01-01T17:41:00Z", "args": []}}
    quiet = lambda *a, **k: None
    with tempfile.TemporaryDirectory() as t:
        t = pathlib.Path(t)
        # One unanswered screenshot: asked again, and the scene still needs three equal frames after it.
        sim = FakeSimctl(hang=[2])
        dev = Device("U", run=sim, log=quiet)
        ok, why = shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
        assert ok and dev.unanswered == 1 and sim.shots == 5, (ok, why, sim.shots)
        assert "1 calls asked again" in why, why
        # The run of equal frames starts again after a hang: a, a, <hang>, a, b, b, b settles on the last b only.
        sim = FakeSimctl(hang=[3], frames=[b"a", b"a", b"", b"a", b"b", b"b", b"b"])
        dev = Device("U", run=sim, log=quiet)
        ok, why = shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
        assert ok and sim.shots == 7 and (t / "s.png").read_bytes() == b"b", (why, sim.shots)
        # A device that stops answering: ASKS unanswered calls end the hand-off with Stuck, bounded by count.
        sim = FakeSimctl(hang=range(1, 100))
        dev = Device("U", run=sim, log=quiet)
        try:
            shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
            raise AssertionError("a device that never answers must be stuck")
        except Stuck as exc:
            assert sim.shots == ASKS and f"{ASKS} calls unanswered" in str(exc), (sim.shots, exc)
        # Unanswered calls count over the hand-off, not only in a row.
        sim = FakeSimctl(hang=[1, 3, 5], frames=[b"", b"a", b"", b"a", b"", b"a", b"a", b"a"])
        dev = Device("U", run=sim, log=quiet)
        try:
            shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
            raise AssertionError("three unanswered calls in one hand-off are stuck")
        except Stuck:
            assert sim.shots == 5
        # The status bar is asked once a hand-off, before any frame, and not again: unanswered, the device is stuck.
        sim = FakeSimctl(steps={"status_bar": "hang"})
        dev = Device("U", run=sim, log=quiet)
        try:
            shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
            raise AssertionError("an unanswered status bar is stuck")
        except Stuck as exc:
            assert sim.calls == ["status_bar"] and f"in {STATUS_BAR_LIMIT} s" in str(exc), (sim.calls, exc)
        sim = FakeSimctl()
        shoot_into(t, Device("U", run=sim, log=quiet), None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
        assert sim.calls == ["status_bar", "io", "io", "io"], sim.calls
        # The forced hang (the probe's CAPTURE_FORCE_HANG) runs through the same path: N forced, then real calls.
        sim = FakeSimctl()
        dev = Device("U", run=sim, log=quiet, force=2)
        ok, why = shoot_into(t, dev, None, t / "s.png", spec, [], "s.1", nap=lambda s: None)
        assert ok and dev.unanswered == 2 and dev.force == 0 and sim.calls.count("sleep") == 2, why
        # The watcher: stuck, then (after the workflow's reboot) the next try is a new hand-off that succeeds.
        d = t / "w"
        d.mkdir()
        dev = Device("U", run=FakeSimctl(), log=quiet, force=ASKS + 1)
        dev.listing_answers = lambda: False
        (d / "midnight.1.ready").write_text("midnight")
        sweep(d, dev, None, spec, log=quiet)
        assert (d / "midnight.1.stuck").exists() and (d / "midnight.1.fail").exists(), sorted(os.listdir(d))
        assert "listing did not answer either" in (d / "midnight.1.stuck").read_text()
        (d / "midnight.1r.ready").write_text("midnight")
        sweep(d, dev, None, spec, log=quiet)
        assert (d / "midnight.1r.done").exists() and "1 calls asked again" in (d / "midnight.1r.done").read_text()
        assert not (d / "midnight.1r.stuck").exists()
    # The reboot: shutdown, boot and bootstatus of the same UDID, then the staging again.
    sim = FakeSimctl()
    assert recover("U", spec, quiet=quiet, run=sim, log=quiet) is None
    assert sim.calls == ["shutdown", "boot", "bootstatus", "ui", "ui", "status_bar"], sim.calls
    assert recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"shutdown": (149, "current state: Shutdown")}), log=quiet) is None
    assert "neither a reboot nor a fresh" in recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"shutdown": "hang"}), log=quiet)
    assert "hung past 600" in recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"bootstatus": "hang"}), log=quiet)
    assert "exited 1" in recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"bootstatus": (1, "Failed")}), log=quiet)
    assert "staging" in recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"status_bar": "hang"}), log=quiet)
    assert "exit 2" in recover("U", spec, quiet=quiet, run=FakeSimctl(steps={"ui": (2, "")}), log=quiet)
    quieted = []
    assert recover("U", spec, quiet=quieted.append, run=FakeSimctl(), log=quiet) is None and quieted == ["U"]
    assert WATCH_WORST + 30 <= 360, "ListingShotsUITests waits 360 s for the host"


def selftest():
    assert not settled(["a", "b", "a"]) and settled(["x", "a", "a", "a"]) and not settled(["a", "a"])
    selftest_recovery()
    with tempfile.TemporaryDirectory() as t:
        a, b = pathlib.Path(t, "a"), pathlib.Path(t, "b")
        a.mkdir(); b.mkdir()
        png = b"\x89PNG\r\n\x1a\n" + struct.pack(">I", 13) + b"IHDR" + struct.pack(">II", 1206, 2622) + b"\x08\x06\x00\x00\x00"
        (a / "shelf.png").write_bytes(png); (b / "shelf.png").write_bytes(png)
        assert compare(a, b) == []
        (b / "shelf.png").write_bytes(png + b"x")
        assert "differ" in compare(a, b)[0]
        (a / "midnight.png").write_bytes(png)
        assert any("only in the first" in p for p in compare(a, b))
        spec = {"devices": {"iphone": {"screen": [1206, 2622]}},
                "scenes": [{"id": "shelf", "devices": ["iphone"]}, {"id": "papers", "devices": ["iphone"]}]}
        assert check("iphone", a, spec) == ["iphone papers: no shot"], check("iphone", a, spec)
        assert png_size(a / "shelf.png") == (1206, 2622)
    assert pick_name(["iPad Pro 13-inch"], ["iPad Pro 11-inch (M5)", "iPad Pro 13-inch (M5)"]) == "iPad Pro 13-inch"
    assert pick_name(["iPhone Duo"], ["iPhone Duo Pro", "iPhone Duo"]) == "iPhone Duo"
    assert pick_name(["iPhone 17 Pro", "iPhone 16 Pro"], ["iPhone 17 Pro Max", "iPhone 16 Pro"]) == "iPhone 16 Pro"
    spec = load(SPEC)
    for s in spec["scenes"]:
        assert set(s["devices"]) <= set(spec["devices"]), s["id"]
        assert len(s["headline"]) == 2 and s["subline"] and s["bg"] in ("paper", "ink"), s["id"]
        caption = (" ".join(s["headline"]) + " " + s["subline"]).lower()
        assert not any(m in caption for m in ("pocketbook", "inkpad")), f"{s['id']}: no trademarks (2.3.7)"
    kinds = {k: d["kind"] for k, d in spec["devices"].items()}
    for s in spec["scenes"]:
        assert set(s.get("whole", [])) <= {kinds[k] for k in s["devices"]}, f"{s['id']}: whole names device kinds it runs on"
    for s in spec["scenes"]:
        assert s["ready"].get("type") in ("staticText", "other", "button", "any"), f"{s['id']}: ready needs its element type"
    shelf = spec["launch"][spec["launch"].index("-GatefoldFakeShelf") + 1].split(",")
    assert set(shelf) <= PUBLIC_DOMAIN and len(shelf) == len(set(shelf)), f"public-domain books, once each: {shelf}"
    seeds = (ROOT / "Gatefold" / "Sync" / "FakeSyncService.swift").read_text()
    for name in shelf:
        assert f'resource: "{name}"' in seeds, f"-GatefoldFakeShelf names {name}, which the fake Cloud does not have"
    opened = [a.split("gutenberg-", 1)[1] for s in spec["scenes"] for a in s["args"] if a.startswith("gutenberg-")]
    # A scene opens its book past the fake Cloud's place for it, so no "read on without you" offer can turn up
    # mid-capture (it did, once, over the spread: two passes, two pictures).
    for s in spec["scenes"]:
        if "-GatefoldRemoteAheadAfter" in s["args"]:
            # The catch-up offer stays open while the host shoots (it folds into its tab after 10 s by default).
            assert "-GatefoldOfferFoldSeconds" in s["args"], f"{s['id']}: hold the offer open with -GatefoldOfferFoldSeconds"
        if "-GatefoldOpenBook" not in s["args"]:
            continue
        book = s["args"][s["args"].index("-GatefoldOpenBook") + 1].split("gutenberg-", 1)[1]
        at = float(s["args"][s["args"].index("-GatefoldGoTo") + 1])
        m = re.search(rf'resource: "{re.escape(book)}".*?remoteProgression: (nil|[0-9.]+)', seeds)
        assert m, f"{s['id']}: no seed for {book}"
        assert m.group(1) == "nil" or at > float(m.group(1)) + 0.02, \
            f"{s['id']}: opens {book} at {at}, not past the fake Cloud's {m.group(1)}"
    assert set(opened) <= set(shelf), f"a scene opens a book that is not on the shelf: {opened}"
    assert len(fingerprint()) == 64
    print(f"capture selftest: ok ({len(spec['scenes'])} scenes)")


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    cmd = argv[0] if argv else ""
    spec = load(arg(argv, "--spec", SPEC))
    if cmd == "watch":
        watch(arg(argv, "--udid"), arg(argv, "--device"), arg(argv, "--dir"), spec)
        return 0
    if cmd == "status-bar":
        status_bar(arg(argv, "--udid"), spec)
        return 0
    if cmd == "stage":
        stage(arg(argv, "--udid"), spec)
        return 0
    if cmd == "recover":
        why = recover(arg(argv, "--udid"), spec)
        if why:
            print(f"::warning title=Simulator recovery failed::{why}")  # the scene's own tries say if it failed
        return 1 if why else 0
    if cmd == "device":
        print(device_name(arg(argv, "--device"), spec))
        return 0
    if cmd == "scenes":
        print(" ".join(s["id"] for s in scenes_for(spec, arg(argv, "--device"))))
        return 0
    if cmd in ("check", "compare"):
        problems = check(arg(argv, "--device"), arg(argv, "--dir"), spec) if cmd == "check" else compare(argv[1], argv[2])
        for p in problems:
            print(f"::error::{p}")
        return 1 if problems else 0
    if cmd == "fingerprint":
        print(fingerprint())
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
