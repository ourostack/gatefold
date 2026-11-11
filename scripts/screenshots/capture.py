#!/usr/bin/env python3
"""The host's side of the App Store screenshots (screenshots/spec.json, GatefoldListingShots).

    python3 -I scripts/screenshots/capture.py watch --udid U --device ipad --dir D [--spec S]
        Until D/finished exists: for each D/<scene>.ready, stage the status bar, shoot until three frames in a row
        are the same, keep that frame as D/<scene>.png and write D/<scene>.done (or D/<scene>.fail with the reason).
    python3 -I scripts/screenshots/capture.py status-bar --udid U [--spec S]
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
# The watcher gives up after SHOOT_LIMIT seconds; the scene test waits longer (ListingShotsUITests: 120 s).
STABLE_FRAMES, SHOOT_LIMIT, FRAME_GAP = 3, 80, 0.8
# Elements whose text names the e-reader ("In step with your InkPad", the catch-up offer and its tab).
NAMES_THE_DEVICE = {"library.syncHealth", "banner", "banner.jump", "banner.tab"}
# Books in the public domain everywhere; the shelf launch argument may name only these.
PUBLIC_DOMAIN = {"moby-dick", "pride-and-prejudice", "frankenstein", "dracula", "alice-in-wonderland",
                 "sherlock-holmes", "emma"}


def load(spec):
    return json.loads(pathlib.Path(spec).read_text())


def scenes_for(spec, device):
    return [s for s in spec["scenes"] if device in s["devices"]]


def status_bar(udid, spec):
    sb = spec["status_bar"]
    subprocess.run(["xcrun", "simctl", "status_bar", udid, "override", "--time", sb["time"], *sb["args"]],
                   check=True, capture_output=True)


def png_size(path):
    with open(path, "rb") as f:
        head = f.read(24)
    if head[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"{path} is not a PNG")
    return struct.unpack(">II", head[16:24])


def settled(hashes, n=STABLE_FRAMES):
    """True when the last n frame hashes are the same."""
    return len(hashes) >= n and len(set(hashes[-n:])) == 1


def shoot(udid, display, out, spec):
    """Shoots until the screen holds still. Returns (ok, why)."""
    hashes = []
    with tempfile.TemporaryDirectory(prefix="shot-") as t:
        return shoot_into(pathlib.Path(t), udid, display, out, spec, hashes)


def shoot_into(tmp, udid, display, out, spec, hashes):
    started = time.monotonic()
    i = 0
    while time.monotonic() - started < SHOOT_LIMIT:
        if i % 5 == 0:
            status_bar(udid, spec)  # again: after a launch the iPad's bar works out its weekday anew
        frame = tmp / f"{i}.png"
        cmd = ["xcrun", "simctl", "io", udid, "screenshot", "--type=png"]
        if display:
            cmd.append(f"--display={display}")
        subprocess.run(cmd + [str(frame)], check=True, capture_output=True)
        hashes.append(hashlib.sha256(frame.read_bytes()).hexdigest())
        if settled(hashes):
            frame.replace(out)
            return True, f"settled after {i + 1} frames"
        i += 1
        time.sleep(FRAME_GAP)
    # Keep the last two frames in unsettled/, out of the shots' own glob, so the artifact shows what kept moving.
    keep = out.parent / "unsettled"
    keep.mkdir(exist_ok=True)
    for n, j in enumerate((i - 2, i - 1), 1):
        if j >= 0 and (tmp / f"{j}.png").exists():
            shutil.copyfile(tmp / f"{j}.png", keep / f"{out.stem}-{int(time.time())}-{n}.png")
    return False, f"the screen never held still for {STABLE_FRAMES} frames in {SHOOT_LIMIT} s"


def watch(udid, device, d, spec):
    d = pathlib.Path(d)
    display = spec["devices"][device].get("display")
    print(f"watching {d} for {device} scenes", flush=True)
    while not (d / "finished").exists():
        for ready in sorted(d.glob("*.ready")):
            scene = ready.stem
            if (d / f"{scene}.done").exists() or (d / f"{scene}.fail").exists():
                continue
            try:
                ok, why = shoot(udid, display, d / f"{scene}.png", spec)
            except subprocess.CalledProcessError as exc:
                ok, why = False, f"simctl failed: {exc.stderr.decode(errors='replace').strip()[:200]}"
            except Exception as exc:  # never leave the scene waiting: say why
                ok, why = False, f"the watcher failed: {type(exc).__name__}: {exc}"[:300]
            if ok:
                print(f"{scene}: {why}, sha256 {sha(d / f'{scene}.png')[:16]}", flush=True)
                (d / f"{scene}.done").write_text(why)
            else:
                print(f"{scene}: {why}", flush=True)
                (d / f"{scene}.fail").write_text(why)
        time.sleep(0.3)


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


def selftest():
    assert not settled(["a", "b", "a"]) and settled(["x", "a", "a", "a"]) and not settled(["a", "a"])
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
        assert "PocketBook" not in " ".join(s["headline"]) + s["subline"], f"{s['id']}: no trademarks (2.3.7)"
    for s in spec["scenes"]:
        assert s["ready"].get("type") in ("staticText", "other", "button"), f"{s['id']}: ready needs its element type"
    # The surfaces where the app names the reader's e-reader by its trademark stay out of the listing.
    for s in spec["scenes"]:
        assert s["ready"]["id"] not in NAMES_THE_DEVICE and "-GatefoldRemoteAheadAfter" not in s["args"], \
            f"{s['id']}: shows the app's InkPad wording (see the spec's parked scenes)"
    shelf = spec["launch"][spec["launch"].index("-GatefoldFakeShelf") + 1].split(",")
    assert set(shelf) <= PUBLIC_DOMAIN and len(shelf) == len(set(shelf)), f"public-domain books, once each: {shelf}"
    seeds = (ROOT / "Gatefold" / "Sync" / "FakeSyncService.swift").read_text()
    for name in shelf:
        assert f'resource: "{name}"' in seeds, f"-GatefoldFakeShelf names {name}, which the fake Cloud does not have"
    opened = [a.split("gutenberg-", 1)[1] for s in spec["scenes"] for a in s["args"] if a.startswith("gutenberg-")]
    # A scene opens its book past the fake Cloud's place for it, so no "read on without you" offer can turn up
    # mid-capture (it did, once, over the spread: two passes, two pictures).
    for s in spec["scenes"]:
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
