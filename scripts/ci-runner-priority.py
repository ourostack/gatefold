#!/usr/bin/env python3
"""Keeps the runner's agent running while the simulator boots (gatefold#404).

    python3 -I scripts/ci-runner-priority.py [seconds]   # in the background of a shard, from before the boot
    python3 -I scripts/ci-runner-priority.py --selftest

A first boot of a simulator holds a 3-CPU runner's load at 500 to 760 with hundreds of runnable threads, and the
machine freezes: the load sampler on a shard that GitHub then cancelled from outside logged nothing for 10 min, and its
job ended within a minute of the load falling. The runner's agent (Runner.Listener and Runner.Worker) is starved too, so
GitHub loses it and cancels the job. This raises the agent's priority and lowers the simulator's own processes' for
`seconds` (default 1500, past the boot's budget), once each, as the boot starts them. A renice that fails (no sudo, a
process that just ended) is skipped; this never fails the job.
"""
import subprocess
import sys
import time

AGENT_NICE = -10
SIM_NICE = 10
POLL = 1.0


def parse(ps_output):
    """(pid, nice, command) for each line of `ps -axo pid=,nice=,command=`."""
    rows = []
    for line in ps_output.splitlines():
        parts = line.split(None, 2)
        if len(parts) == 3 and parts[0].isdigit() and parts[1].lstrip("-").isdigit():
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
    return rows


def is_agent(command):
    return "/Runner.Listener" in command or "/Runner.Worker" in command


def is_simulator(command):
    return "/RuntimeRoot/" in command or "/CoreSimulator/Devices/" in command


def plan(rows, done):
    """(agent pids to raise, simulator pids to lower) that aren't done yet and aren't at the wanted priority."""
    up = [p for p, n, c in rows if is_agent(c) and n > AGENT_NICE and p not in done]
    down = [p for p, n, c in rows if is_simulator(c) and n < SIM_NICE and p not in done]
    return up, down


def renice(nice, pids):
    if pids:
        subprocess.run(["sudo", "-n", "renice", "-n", str(nice), "-p", *map(str, pids)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)


def main(seconds):
    done, end = set(), time.time() + seconds
    while time.time() < end:
        out = subprocess.run(["ps", "-axo", "pid=,nice=,command="], capture_output=True, text=True, check=False).stdout
        up, down = plan(parse(out), done)
        renice(AGENT_NICE, up)
        renice(SIM_NICE, down)
        done.update(up, down)
        time.sleep(POLL)


def selftest():
    ps = "\n".join([
        "  101   0 /Users/runner/runners/2.330.0/bin/Runner.Listener run --startuptype service",
        "  102   0 /Users/runner/runners/2.330.0/bin/Runner.Worker spawnclient 123 456",
        "  103   0 /Library/Developer/CoreSimulator/Volumes/iOS_23A/RuntimeRoot/usr/libexec/assistantd",
        "  104   0 /Users/runner/Library/Developer/CoreSimulator/Devices/ABC/data/Containers/Bundle/App/Gatefold",
        "  105  10 /Library/Developer/CoreSimulator/Volumes/iOS_23A/RuntimeRoot/usr/libexec/searchd",
        "  106   0 /usr/bin/xcodebuild test-without-building",
        "  107 -10 /Users/runner/runners/2.330.0/bin/Runner.Listener run",
        "garbage line",
    ])
    rows = parse(ps)
    assert len(rows) == 7, rows
    up, down = plan(rows, set())
    assert up == [101, 102], f"the agent not yet raised: {up}"
    assert down == [103, 104], f"the simulator's processes not yet lowered, never xcodebuild: {down}"
    assert plan(rows, {101, 103}) == ([102], [104]), "a pid done once is left alone"
    print("ci-runner-priority selftest: ok")


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        selftest()
    else:
        main(float(sys.argv[1]) if len(sys.argv) > 1 else 1500)
