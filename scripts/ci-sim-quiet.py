#!/usr/bin/env python3
"""Stop a booted simulator's wallpaper and poster rendering (gatefold#39 experiment).

On the hosted runner a just-booted iOS 27 simulator keeps a 1-min load of 300-790 on 10 CPUs for the whole job,
its busiest processes the wallpaper posters (Unity2025Poster, KaleidoscopePoster, EmojiPosterExtension...) and
MTLCompilerService. This prints the simulator's launchd jobs that match, boots each out, and prints what is left,
every call bounded. It never fails the job: it only reports.

Usage: ci-sim-quiet.py <udid>
"""
import re
import subprocess
import sys

MATCH = re.compile(r"poster|wallpaper|PosterBoard|MTLCompiler", re.I)


def run(args, limit=30):
    try:
        p = subprocess.run(args, capture_output=True, text=True, timeout=limit)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return None, f"hung past {limit} s"


def labels(udid):
    code, out = run(["xcrun", "simctl", "spawn", udid, "launchctl", "list"])
    if code != 0:
        print(f"launchctl list: exit {code}: {out.strip()[:300]}")
        return []
    return [line.split()[-1] for line in out.splitlines()[1:] if line.split() and MATCH.search(line.split()[-1])]


def main(argv):
    if len(argv) != 1:
        print(__doc__)
        return 2
    udid = argv[0]
    found = labels(udid)
    print(f"{len(found)} matching launchd jobs: {' '.join(found)}")
    for label in found:
        for target in (f"system/{label}", f"user/501/{label}", f"gui/501/{label}"):
            code, out = run(["xcrun", "simctl", "spawn", udid, "launchctl", "bootout", target], 20)
            print(f"bootout {target}: exit {code} {out.strip()[:160]}")
            if code == 0:
                break
    left = labels(udid)
    print(f"{len(left)} still listed: {' '.join(left)}")
    code, out = run(["ps", "-Aceo", "pcpu=,comm="])
    hits = [line.strip() for line in out.splitlines() if MATCH.search(line)]
    print(f"host processes matching now: {len(hits)}: {'; '.join(hits[:12])}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
