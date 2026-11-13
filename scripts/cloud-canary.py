#!/usr/bin/env python3
"""CI only: judge a cloud canary run and report it (gatefold#372).

    python3 -I scripts/cloud-canary.py report --log <canary log> --outcome <success|failure> \
        --state-in <previous state.json or missing> --state-out <state.json>
    python3 -I scripts/cloud-canary.py --selftest

The canary test (LiveCanaryTests) logs one `CANARY <step> ok|FAILED|INCONCLUSIVE` line per step. Verdicts:

- green: every step ran and passed. Comments once on an open `cloud-drift` issue that it is green again,
  and closes an open `canary-lockout` issue.
- drift: a step failed. Opens, or comments on, the one open `cloud-drift` issue with the redacted steps.
  A coding agent acts on every cloud-drift issue, so nothing but a real failed step lands there.
- inconclusive: the cloud's login limit (429) stopped sign-in, so the run couldn't check anything. No
  cloud-drift issue; the job summary says so with the retry time. Only when sign-in has been refused this
  way for more than 24 hours does it open one `canary-lockout` issue.
- broken: no step lines at all (the build or the runner failed before the canary ran). The run is red;
  no issue, since nothing about the cloud is known.

The state carried between runs (an artifact) is `{"locked_since": <ISO time or null>}`.
"""
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timedelta, timezone

LOCKOUT_LIMIT = timedelta(hours=24)
SCHEDULE_MINUTE, SCHEDULE_HOURS = 17, 6  # cloud-canary.yml's cron: "17 */6 * * *"
DRIFT, LOCKOUT = "cloud-drift", "canary-lockout"
GREEN_AGAIN = "The cloud canary is green again"

REDACTIONS = [
    (re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]+"), "<email>"),
    (re.compile(r"\b(signature|payload|token|access_token|refresh_token|client_secret|client_id|password)=[^&\"\s]+"), r"\1=<redacted>"),
    (re.compile(r"Bearer [A-Za-z0-9._-]+"), "Bearer <redacted>"),
]


def redact(line):
    for pattern, replacement in REDACTIONS:
        line = pattern.sub(replacement, line)
    return line


def steps(log):
    """The canary's own step lines, redacted, plus Swift Testing's issue lines."""
    keep = [l.strip() for l in log.splitlines() if "CANARY " in l or "recorded an issue" in l or "Known issue" in l]
    return [redact(l) for l in keep][:60]


def next_run(now):
    slot = now.replace(minute=SCHEDULE_MINUTE, second=0, microsecond=0)
    slot = slot.replace(hour=slot.hour - slot.hour % SCHEDULE_HOURS)
    while slot <= now:
        slot += timedelta(hours=SCHEDULE_HOURS)
    return slot


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def judge(log, outcome, state, now):
    """Pure: the verdict, the summary, the new state, and what to do with issues."""
    lines = steps(log)
    locked = next((l for l in lines if "CANARY INCONCLUSIVE" in l), None)
    failed = [l for l in lines if "FAILED" in l or "recorded an issue" in l]
    if locked:
        m = re.search(r"retry-after=(\d+)", locked)
        retry = now + timedelta(seconds=int(m.group(1))) if m else None
        since = parse_iso(state["locked_since"]) if state.get("locked_since") else now
        hours = (now - since).total_seconds() / 3600
        retry_text = (f"the cloud says retry after {iso(retry)}" if retry
                      else f"the cloud gave no time; the next scheduled run is {iso(next_run(now))}")
        summary = (f"### Inconclusive: sign-in was rate-limited\n\nPocketBook Cloud refused the test account's sign-in "
                   f"with its login limit (429), so this run checked nothing. This is not cloud drift; no cloud-drift "
                   f"issue is opened. Retry: {retry_text}. Refused since {iso(since)} ({hours:.1f} h).")
        lockout = None
        if now - since > LOCKOUT_LIMIT:
            lockout = (f"The cloud canary's test account has been refused sign-in by PocketBook Cloud's login limit "
                       f"(429) since {iso(since)}, more than 24 hours, so the canary has checked nothing since. "
                       f"Something may be signing in to test account 1 too often, or the cloud's limit changed. "
                       f"Latest: {retry_text}.")
        return {"verdict": "inconclusive", "summary": summary, "state": {"locked_since": iso(since)},
                "drift": None, "lockout": lockout, "green": False}
    state = {"locked_since": None}
    if failed or outcome != "success":
        if not lines:
            return {"verdict": "broken", "state": state, "drift": None, "lockout": None, "green": False,
                    "summary": "### Broken: the canary never ran\n\nNo step lines in the log: the build or the runner "
                               "failed first. Nothing is known about the cloud, so no issue is opened."}
        body = "\n".join(lines)
        return {"verdict": "drift", "state": state, "lockout": None, "green": False, "drift": body,
                "summary": f"### Red: PocketBook Cloud drifted\n\n```\n{body}\n```"}
    return {"verdict": "green", "state": state, "drift": None, "lockout": None, "green": True,
            "summary": "### Green: the cloud's basics work\n\n```\n" + "\n".join(lines) + "\n```"}


def gh(*args):
    return subprocess.run(["gh", *args, "-R", os.environ["GITHUB_REPOSITORY"]], check=True,
                          capture_output=True, text=True).stdout.strip()


def open_issue(label):
    return gh("issue", "list", "--label", label, "--state", "open", "--json", "number", "-q", ".[0].number // empty")


def act(result, run_url):
    for label, color, about in ((DRIFT, "B60205", "PocketBook Cloud changed under us (the cloud canary went red)"),
                                (LOCKOUT, "FBCA04", "The cloud canary's test account is locked out of sign-in")):
        subprocess.run(["gh", "label", "create", label, "--color", color, "--description", about,
                        "-R", os.environ["GITHUB_REPOSITORY"]], capture_output=True)
    if result["drift"]:
        body = f"The cloud canary went red: {run_url}\n\nSteps:\n```\n{result['drift']}\n```\n"
        issue = open_issue(DRIFT)
        if issue:
            gh("issue", "comment", issue, "--body", body)
        else:
            gh("issue", "create", "--label", DRIFT, "--title", "Cloud drift: the PocketBook Cloud canary is red", "--body",
               body + "\nThe canary (`.github/workflows/cloud-canary.yml`, gatefold#372) checks sign-in, the library, a "
               "download, the e-reader's place and a position write against test account 1. Fix the client in "
               "`Packages/GatefoldCloud`; the canary comments here when it is green again.")
    if result["lockout"] and not open_issue(LOCKOUT):
        gh("issue", "create", "--label", LOCKOUT, "--title", "Cloud canary: test account locked out of sign-in for over 24 h",
           "--body", f"{result['lockout']}\n\nLatest run: {run_url}")
    if result["green"]:
        issue = open_issue(DRIFT)
        if issue:
            last = gh("issue", "view", issue, "--json", "comments", "-q", '.comments[-1].body // ""')
            if not last.startswith(GREEN_AGAIN):
                gh("issue", "comment", issue, "--body", f"{GREEN_AGAIN}: {run_url}")
    if result["verdict"] in ("green", "drift"):
        issue = open_issue(LOCKOUT)
        if issue:
            gh("issue", "close", issue, "--comment", f"The canary signed in again: {run_url}")


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def report(argv, now=None):
    now = now or datetime.now(timezone.utc).replace(microsecond=0)
    log_path, state_in = arg(argv, "--log"), arg(argv, "--state-in")
    log = open(log_path, encoding="utf-8", errors="replace").read() if log_path and os.path.exists(log_path) else ""
    state = json.load(open(state_in)) if state_in and os.path.exists(state_in) else {}
    result = judge(log, arg(argv, "--outcome", "failure"), state, now)
    with open(arg(argv, "--state-out"), "w") as f:
        json.dump(result["state"], f)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as f:
            f.write(result["summary"] + "\n")
    print(result["summary"])
    if "--dry-run" not in argv:
        run_url = f"{os.environ.get('GITHUB_SERVER_URL')}/{os.environ.get('GITHUB_REPOSITORY')}/actions/runs/{os.environ.get('GITHUB_RUN_ID')}"
        act(result, run_url)
    if result["verdict"] == "inconclusive":
        print("::warning title=Cloud canary inconclusive::Sign-in was rate-limited (429); this run checked nothing.")
        return 0
    return 0 if result["verdict"] == "green" else 1


def selftest():
    now = datetime(2026, 11, 13, 16, 30, tzinfo=timezone.utc)
    ok = "LIVE CANARY sign-in: store lookup ok\nLIVE CANARY library ok\nLIVE CANARY download ok\n"
    limited = "LIVE CANARY INCONCLUSIVE sign-in rate-limited retry-after=unknown\n"

    r = judge(ok, "success", {}, now)
    assert r["verdict"] == "green" and r["green"] and not r["drift"] and r["state"] == {"locked_since": None}

    r = judge(ok + "LIVE CANARY download: size matches the listing FAILED: listed 10 bytes, got 9 for a@b.com "
              "https://x/y?signature=abc&payload=def Bearer abc.def\n", "failure", {}, now)
    assert r["verdict"] == "drift" and r["drift"] and not r["lockout"]
    assert "a@b.com" not in r["drift"] and "abc" not in r["drift"] and "def" not in r["drift"], r["drift"]

    # A 429 at sign-in: inconclusive, no drift issue, a summary with the retry time, the lockout clock starts.
    r = judge(limited, "success", {}, now)
    assert r["verdict"] == "inconclusive" and r["drift"] is None and r["lockout"] is None and not r["green"]
    assert r["state"] == {"locked_since": "2026-11-13T16:30:00Z"}
    assert "not cloud drift" in r["summary"] and "2026-11-13T18:17:00Z" in r["summary"], r["summary"]
    # Even when the test step failed as well, the 429 decides: still no drift issue.
    assert judge(limited, "failure", {}, now)["drift"] is None
    # The cloud's Retry-After is the retry time when it gives one.
    r = judge("LIVE CANARY INCONCLUSIVE sign-in rate-limited retry-after=600\n", "success", {}, now)
    assert "retry after 2026-11-13T16:40:00Z" in r["summary"], r["summary"]
    # Still refused 23 h later: the clock keeps its start, and there is still no issue.
    r = judge(limited, "success", {"locked_since": "2026-11-12T17:30:00Z"}, now)
    assert r["lockout"] is None and r["state"]["locked_since"] == "2026-11-12T17:30:00Z"
    # More than 24 h: a canary-lockout issue, never a cloud-drift one.
    r = judge(limited, "success", {"locked_since": "2026-11-12T16:00:00Z"}, now)
    assert r["lockout"] and r["drift"] is None and "since 2026-11-12T16:00:00Z" in r["lockout"]
    # Signing in again clears the clock.
    assert judge(ok, "success", {"locked_since": "2026-11-12T16:00:00Z"}, now)["state"] == {"locked_since": None}

    # No step lines: broken, no issue, red.
    r = judge("error: build failed\n", "failure", {}, now)
    assert r["verdict"] == "broken" and r["drift"] is None and r["lockout"] is None

    assert next_run(datetime(2026, 11, 13, 18, 17, tzinfo=timezone.utc)) == datetime(2026, 11, 14, 0, 17, tzinfo=timezone.utc)
    assert next_run(datetime(2026, 11, 13, 23, 59, tzinfo=timezone.utc)) == datetime(2026, 11, 14, 0, 17, tzinfo=timezone.utc)
    print("cloud-canary selftest ok")
    return 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        return selftest()
    if argv[:1] == ["report"]:
        return report(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
