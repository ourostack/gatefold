#!/usr/bin/env python3
"""Merge queue only: when an entry failed only because of its runners, put the pull request back in the queue, once.

    python3 -I scripts/ci-requeue.py <run id>   # GH_TOKEN, GH_REPO set; QUEUE_TOKEN to enqueue; by requeue.yml
    python3 -I scripts/ci-requeue.py --verdict <run id>   # what it would decide of that commit's jobs; changes nothing
    python3 -I scripts/ci-requeue.py --selftest

The queue tests one entry at a time, and on 11-17 and 11-18 most entries it dropped had failed on the machine, not the
app: shards cancelled from outside, "No test started", Mach error -308, the simulator gone from xcodebuild's devices
(run 44241084984, #475) or a DeviceHub press that stalled twice (run 44241083397, #476). Each time a person put the
pull request back by hand. This does it instead, once, when every merge-group run on the entry's commit has finished:

- a job that failed (gates and summaries aside) must show a signature from scripts/ci-runner-faults.py near one of
  its error lines, and no job, failed or cancelled, may show a test that failed (XCTest's "Test Case ... failed" or an
  XCTAssert line);
- a run with no failed job but cancelled ones was stopped from outside, which counts as the runner too;
- the queue itself must have dropped the entry (a person's removal is theirs), on this commit, and the pull request
  must be open and out of the queue;
- the pull request's last time in the queue must not have been a re-enqueue of ours (a marker comment, then the queue
  entry within MINE seconds): a runner fault twice in a row is left for a person.

Anything else (a failed test, a failure it doesn't recognise) leaves the pull request out, and it says why in a comment.

The enqueue needs QUEUE_TOKEN, a token of a person or a GitHub App. A workflow's GITHUB_TOKEN can call
enqueuePullRequest, but the queue then starts no merge_group run (GitHub starts no workflow for an event that
GITHUB_TOKEN caused), so the entry would sit until the queue's 120 min check timeout and hold up the whole queue
(probe: ourostack/queue-probe, run 44252809097 queued it as github-actions and no merge_group run came in four
minutes; queued by a person, its run 44253349327 started in 6 s). Without QUEUE_TOKEN it comments what it would have
done, and leaves the enqueue to a person.
"""
import json
import os
import re
import subprocess
import sys
import time


def _faults():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ci-runner-faults.py")
    spec = importlib.util.spec_from_file_location("ci_runner_faults", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


F = _faults()
MARKER = "<!-- ci-requeue sha={sha} verdict={verdict} -->"
MARKED = re.compile(r"<!-- ci-requeue sha=(\w+) verdict=(\w+) -->")
MINE = 300           # seconds between our marker comment and the queue entry it announced
CONTEXT = 40         # log lines before an error line that may hold its cause (xcodebuild prints it above)
QUEUE_BOT = "github-merge-queue"
WATCHED = ("App", "Real unfold")  # requeue.yml's workflow_run list: the last of them to end decides
PR_OF_BRANCH = re.compile(r"^gh-readonly-queue/.+/pr-(\d+)-[0-9a-f]+$")


def plain(log):
    """A job log without the scripts GitHub echoes before each step (they hold the very words we look for)."""
    return [l for l in log.splitlines() if "\x1b[36;1m" not in l and "##[group]Run " not in l]


def near_errors(lines):
    """The error lines and the CONTEXT lines above each."""
    keep = set()
    for i, line in enumerate(lines):
        if "##[error]" in line:
            keep.update(range(max(0, i - CONTEXT), i + 1))
    return "\n".join(lines[i] for i in sorted(keep))


def classify(jobs):
    """`jobs`: [(name, conclusion, log)] over every run on the entry's commit. Returns (verdict, why): verdict is
    "requeue" (the runner only), "test" (a test failed), "unknown" (a failure with no runner signature) or "green"."""
    for name, conclusion, log in jobs:
        if conclusion in ("failure", "timed_out", "cancelled"):
            hit = next((l for l in plain(log) if F.TEST_FAILED.search(l)), None)
            if hit:
                return "test", f"a test failed in {name}: {hit.split('Z ', 1)[-1].strip()[:200]}"
    failed = [(n, l) for n, c, l in jobs if c in ("failure", "timed_out") and not F.summary(n)]
    cancelled = [n for n, c, _ in jobs if c == "cancelled" and not F.summary(n)]
    found = []
    for name, log in failed:
        sig = F.fault(near_errors(plain(log)))
        if not sig:
            return "unknown", f"{name} failed, and its log shows no runner fault this knows"
        found.append(f"{name}: {sig}")
    if found:
        return "requeue", "; ".join(found)
    if cancelled:
        return "requeue", f"{len(cancelled)} jobs cancelled from outside, none failed (first: {cancelled[0]})"
    if any(c in ("failure", "timed_out") for _, c, _ in jobs):
        return "unknown", "only gate jobs failed, and nothing they wait for did"
    return "green", "nothing failed"


def removal(timeline, sha):
    """The queue's own removal of this entry, from the pull request's timeline, or a reason it isn't one."""
    removed = [e for e in timeline if e["__typename"] == "RemovedFromMergeQueueEvent"]
    if not removed:
        return None, "the queue hasn't removed it yet"
    last = removed[-1]
    if (last.get("beforeCommit") or {}).get("oid") != sha:
        return None, "its last removal from the queue was of another commit"
    actor = (last.get("actor") or {}).get("login", "")
    if not actor.startswith(QUEUE_BOT) or last.get("reason") in ("merged", "manual"):
        return None, f"{actor or 'someone'} took it out of the queue ({last.get('reason')}), not the failed checks"
    return last, None


def stamp(t):
    return time.mktime(time.strptime(t[:19], "%Y-%m-%dT%H:%M:%S"))


def ours(timeline):
    """Whether its last time in the queue was our re-enqueue: our requeue marker, then an add within MINE seconds."""
    added = [e for e in timeline if e["__typename"] == "AddedToMergeQueueEvent"]
    marks = [e for e in timeline if e["__typename"] == "IssueComment"
             and (m := MARKED.search(e.get("body") or "")) and m.group(2) == "requeue"]
    if not added or not marks:
        return False
    add = stamp(added[-1]["createdAt"])
    return any(0 <= add - stamp(m["createdAt"]) <= MINE for m in marks)


def told(timeline, sha):
    """Whether we already commented on this commit (the other run's completion got here first)."""
    return any((m := MARKED.search(e.get("body") or "")) and m.group(1) == sha
               for e in timeline if e["__typename"] == "IssueComment")


# ---- GitHub


def gh(*args, token=None):
    env = dict(os.environ, **({"GH_TOKEN": token} if token else {}))
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True, env=env).stdout


def api(path, *args):
    return json.loads(gh("api", f"repos/{{owner}}/{{repo}}/{path}", *args))


TIMELINE = """query($owner:String!,$name:String!,$n:Int!){repository(owner:$owner,name:$name){pullRequest(number:$n){
  id state isInMergeQueue
  timelineItems(last:60,itemTypes:[ADDED_TO_MERGE_QUEUE_EVENT,REMOVED_FROM_MERGE_QUEUE_EVENT,ISSUE_COMMENT]){nodes{
    __typename
    ... on AddedToMergeQueueEvent{createdAt}
    ... on RemovedFromMergeQueueEvent{createdAt reason actor{login} beforeCommit{oid}}
    ... on IssueComment{createdAt body}}}}}}"""


def pull(number):
    owner, name = os.environ["GH_REPO"].split("/")
    d = json.loads(gh("api", "graphql", "-f", f"query={TIMELINE}", "-f", f"owner={owner}", "-f", f"name={name}",
                      "-F", f"n={number}"))["data"]["repository"]["pullRequest"]
    return d, d["timelineItems"]["nodes"]


def comment(number, body):
    gh("pr", "comment", str(number), "--body", body)


def gather(runs):
    """[(job name, conclusion, log)] for the failed and cancelled jobs of each run's latest attempt."""
    jobs = []
    for r in runs:
        for j in api(f"actions/runs/{r['id']}/attempts/{r['run_attempt']}/jobs?per_page=100")["jobs"]:
            if j["conclusion"] in ("failure", "timed_out", "cancelled"):
                try:
                    log = gh("api", f"repos/{{owner}}/{{repo}}/actions/jobs/{j['id']}/logs")
                except subprocess.CalledProcessError:
                    log = ""
                jobs.append((j["name"], j["conclusion"], log))
    return jobs


def verdict_only(run_id):
    """What it would decide of the jobs on a merge-group run's commit, touching nothing (no timeline, no comment)."""
    run = api(f"actions/runs/{run_id}")
    runs = api(f"actions/runs?head_sha={run['head_sha']}&event=merge_group&per_page=50")["workflow_runs"]
    print(*classify(gather(runs)), sep=": ")
    return 0


def main(run_id):
    run = api(f"actions/runs/{run_id}")
    m = PR_OF_BRANCH.match(run.get("head_branch") or "")
    if run.get("event") != "merge_group" or not m:
        print(f"Not a merge-queue run ({run.get('event')}, {run.get('head_branch')})")
        return 0
    number, sha = int(m.group(1)), run["head_sha"]
    runs = api(f"actions/runs?head_sha={sha}&event=merge_group&per_page=50")["workflow_runs"]
    going = [r for r in runs if r["status"] != "completed" and r["name"] in WATCHED]
    if going:
        print(f"Waiting: {going[0]['name']} ({going[0]['id']}) is still {going[0]['status']}; its end decides")
        return 0
    if all(r["conclusion"] in ("success", "skipped", "neutral") for r in runs):
        print("Every merge-group run on this commit passed")
        return 0
    links = ", ".join(f"[{r['name']} {r['id']}]({r['html_url']})" for r in runs
                      if r["conclusion"] not in ("success", "skipped", "neutral"))
    # The queue drops the entry when a required check fails; give that removal a moment to reach the timeline.
    for _ in range(12):
        pr, timeline = pull(number)
        if pr["state"] != "OPEN" or pr["isInMergeQueue"]:
            print(f"#{number} is {pr['state'].lower()}{' and back in the queue' if pr['isInMergeQueue'] else ''}")
            return 0
        if told(timeline, sha):
            print(f"#{number} already has our comment for {sha[:8]}")
            return 0
        removed, why_not = removal(timeline, sha)
        if removed or "yet" not in why_not:
            break
        time.sleep(10)
    if not removed:
        print(f"Leaving #{number}: {why_not}")
        return 0
    verdict, why = classify(gather(runs))
    verdict, why = classify(jobs)
    print(f"#{number} at {sha[:8]}: {verdict}: {why}")
    head = f"The merge queue dropped this pull request: merge-group runs {links} on {sha[:8]}."
    if verdict != "requeue":
        comment(number, f"{MARKER.format(sha=sha, verdict=verdict)}\n{head}\n\nNot re-enqueued: {why}. "
                        "It stays out of the queue for a person (scripts/ci-requeue.py).")
        return 0
    if ours(timeline):
        comment(number, f"{MARKER.format(sha=sha, verdict='again')}\n{head}\n\nThe runner again ({why}), but its last "
                        "time in the queue was already an automatic re-enqueue, so it stays out for a person.")
        return 0
    token = os.environ.get("QUEUE_TOKEN")
    if not token:
        comment(number, f"{MARKER.format(sha=sha, verdict='notoken')}\n{head}\n\nOnly the runner failed ({why}), so "
                        "this would go back in the queue, but the workflow has no QUEUE_TOKEN to enqueue with "
                        "(scripts/ci-requeue.py says why GITHUB_TOKEN can't). Re-enqueue it by hand.")
        return 0
    comment(number, f"{MARKER.format(sha=sha, verdict='requeue')}\n{head}\n\nOnly the runner failed ({why}), so it "
                    "goes back in the queue, once. If it fails on the runner again it stays out for a person.")
    try:
        gh("api", "graphql", "-f", "query=mutation($id:ID!){enqueuePullRequest(input:{pullRequestId:$id})"
           "{mergeQueueEntry{position}}}", "-f", f"id={pr['id']}", token=token)
    except subprocess.CalledProcessError as e:
        comment(number, f"Re-enqueueing failed: {(e.stderr or '').strip()[:300]}")
        return 1
    print(f"Re-enqueued #{number}")
    return 0


# ---- Offline


def selftest():
    def log(*lines):
        return "\n".join(f"2026-11-18T05:43:02.0000000Z {l}" for l in lines)
    echo = "\x1b[36;1m  echo \"::error::No test started: $why. No app code ran; rerun it on a fresh runner\"\x1b[0m"
    # Run 44241083397 (#476), "Unfold with a book open", job 134588947975.
    press = log("press Open gave no answer in 120 s (try 2); the app's latest main-thread note: 05:56:21.347 Df "
                "Gatefold[23652:14cb5] [bot.ouro.gatefold:reader] main: still held after 1010 ms",
                "##[error]press Open stalled twice",
                "##[error]a DeviceHub press stalled twice, so the unfolds after it never ran (4 of 28 begun)",
                "##[error]Process completed with exit code 1.")
    # Run 44241084984 (#475), "Unfold with a book open", job 134588955516.
    gone = log("xcodebuild: error: Unable to find a device matching the provided destination specifier:",
               "\t\t{ platform:macOS, arch:arm64e, id:e58556942a13e66de7365a8c60afcdb9084ee225, name:My Mac }",
               "##[error]Process completed with exit code 70.")
    # gatefold#135: the test runner failed to launch (Mach error -308), and ui-tests.yml's mark for it.
    mach = log("xcodebuild: error: Failed to install or launch the test runner. (Underlying Error: The operation "
               "couldn't be completed. (Mach error -308 - (ipc/mig) server died))", "** TEST EXECUTE FAILED **",
               "##[error]No test started: the test runner could not be installed or launched. No app code ran; rerun "
               "it on a fresh runner (gatefold#135).")
    # Run 44237422258 (#469), "iPad undo shard (ipad-undo-underway) / Tests", job 134576859511: a real failure.
    test = log("  XCTESTRUN: /Users/runner/work/_temp/dd/Build/Products/Gatefold_iphonesimulator27.2-arm64.xctestrun",
               "/Users/runner/work/gatefold/gatefold/GatefoldUITests/PlaceUndoUITests.swift:265: error: "
               "-[GatefoldUITests.PlaceUndoUITests testATapAboveYourPageClosesItAndKeepsThePage] : XCTAssertEqual "
               "failed (text withheld)",
               "Test Case '-[GatefoldUITests.PlaceUndoUITests testATapAboveYourPageClosesItAndKeepsThePage]' failed "
               "(196.687 seconds).", "##[error]Process completed with exit code 65.")
    # The same shard's gate (job 134585846169): fails only because its shards did.
    gate = log("Shards: cancelled", "##[error]Process completed with exit code 1.")
    odd = log("##[error]Process completed with exit code 2.")
    # A fault far above the failure is an earlier, recovered step's, not this failure's cause.
    far = log("xcodebuild: error: Unable to find a device matching the provided destination specifier:",
              *["ok"] * (CONTEXT + 5), "##[error]Process completed with exit code 2.")
    unfold, undo = "Unfold with a book open", "iPad undo shard (ipad-undo-underway) / Tests"
    cases = [
        ([(unfold, "failure", press), ("Real unfold", "failure", gate)], "requeue"),
        ([(unfold, "failure", gone), ("Real unfold", "failure", gate)], "requeue"),
        ([(undo, "failure", mach), ("iPad (undo)", "failure", gate)], "requeue"),
        # Run 44241083478 (#476): App's shards all cancelled from outside, its gates red.
        ([("iPad undo shard (ipad-undo-rest) / Tests", "cancelled", ""), ("iPad (undo)", "failure", gate),
          ("Full suite passed on tree abc", "cancelled", "")], "requeue"),
        # Run 44237422258 (#469): a test failed, the rest cancelled; and a test that failed in a cancelled job.
        ([(undo, "failure", test), ("iPad reviewer shard (ipad-reviewer-rest) / Tests", "cancelled", ""),
          ("iPad (undo)", "failure", gate)], "test"),
        ([(unfold, "failure", press), (undo, "cancelled", test)], "test"),
        # A runner fault beside a test failure is the test's.
        ([(unfold, "failure", gone), (undo, "failure", test)], "test"),
        # A failure it doesn't know, alone or beside a runner fault, stays out.
        ([(unfold, "failure", odd)], "unknown"),
        ([(unfold, "failure", press), ("Release build for devices", "failure", odd)], "unknown"),
        ([(unfold, "failure", far)], "unknown"),
        # The script's own echoed words are not a fault.
        ([(undo, "failure", log(echo, "##[error]Process completed with exit code 65."))], "unknown"),
        ([("iPad (undo)", "failure", gate)], "unknown"),
        ([("Build for testing", "success", "")], "green"),
    ]
    bad = 0
    for jobs, want in cases:
        got, why = classify(jobs)
        if got != want:
            bad += 1
            print(f"FAIL: {[j[0] for j in jobs]}: got {got} ({why}), want {want}")
    sha = "86cf4ae1e1b740fc45c15c7083a659237df17485"

    def added(t):
        return {"__typename": "AddedToMergeQueueEvent", "createdAt": t}

    def removed(t, actor, reason, oid=sha):
        return {"__typename": "RemovedFromMergeQueueEvent", "createdAt": t, "actor": {"login": actor},
                "reason": reason, "beforeCommit": {"oid": oid}}

    def said(t, verdict, oid="0" * 40):
        return {"__typename": "IssueComment", "createdAt": t, "body": MARKER.format(sha=oid, verdict=verdict) + "\nx"}

    person = [added("2026-11-18T04:26:58Z"), removed("2026-11-18T05:47:24Z", "arimendelow", "manual")]
    queue = [added("2026-11-18T04:26:58Z"), removed("2026-11-18T05:47:24Z", QUEUE_BOT, "failed_checks")]
    retried = [said("2026-11-18T04:26:50Z", "requeue")] + queue
    human_after = [said("2026-11-18T03:00:00Z", "requeue"), added("2026-11-18T03:00:20Z"),
                   removed("2026-11-18T04:00:00Z", QUEUE_BOT, "failed_checks", "1" * 40)] + queue
    checks = [
        (removal(person, sha)[0] is None, True),        # #475 at 05:47: a person took it out
        (removal(queue, sha)[0] is not None, True),
        (removal(queue, "f" * 40)[0] is None, True),     # another commit's removal
        (removal([added("2026-11-18T04:26:58Z")], sha)[1] == "the queue hasn't removed it yet", True),
        (ours(queue), False),
        (ours(retried), True),                           # our re-enqueue failed again: not twice in a row
        (ours(human_after), False),                      # a person queued it since our last re-enqueue
        (told([said("2026-11-18T05:50:00Z", "test", sha)], sha), True),
        (told([said("2026-11-18T05:50:00Z", "test")], sha), False),
        (bool(PR_OF_BRANCH.match("gh-readonly-queue/main/pr-475-49fdd977a12bce40e54d5257af563e779a35cf06")), True),
        (bool(PR_OF_BRANCH.match("main")), False),
    ]
    for i, (got, want) in enumerate(checks):
        if got != want:
            bad += 1
            print(f"FAIL: timeline check {i}: got {got}, want {want}")
    total = len(cases) + len(checks)
    print(f"{total - bad} of {total} passed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    elif len(sys.argv) == 3 and sys.argv[1] == "--verdict":
        sys.exit(verdict_only(sys.argv[2]))
    elif len(sys.argv) == 2:
        sys.exit(main(sys.argv[1]))
    else:
        sys.exit(__doc__)
