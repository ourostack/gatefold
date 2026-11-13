#!/usr/bin/env python3
"""Hand each cloud-drift issue to Copilot's coding agent and see its fix through (gatefold#372).

    python3 -I scripts/cloud-drift-dispatch.py tick [--dry-run]   # one pass; run every 10 minutes
    python3 -I scripts/cloud-drift-dispatch.py --selftest

The last link of the cloud's self-repair loop. The canary (cloud-canary.yml) opens a `cloud-drift`
issue when PocketBook Cloud changes under us. Each pass of this:

1. Assigns an open `cloud-drift` issue to Copilot's coding agent, with the instructions below, and
   labels it `agent-fixing`. Never twice.
2. Sees Copilot's pull request for it through:
   - when Copilot has finished (its title loses "[WIP]"), approves its workflow runs that wait for
     approval (runs a bot's pushes start wait for a person), labels it `cloud-drift-fix`, which starts
     the live gate (cloud-fix-gate.yml), and marks it ready for review;
   - when the gate passes (`live-canary-passed`), turns on auto-merge. Normal CI and the gate merge
     it, and main's green gate ships it to TestFlight;
   - when CI or the gate fails, tells Copilot what failed (a comment that mentions @copilot), at
     most MAX_TRIES times, then labels the pull request `needs-human`;
   - when the gate was inconclusive (the cloud's login limit), runs it again once per head.

It runs as a person (`gh` signed in as the repository's owner), not as GITHUB_TOKEN: only a person
can assign Copilot, and a merge made with GITHUB_TOKEN would not start main's workflows, so TestFlight
would never publish the fix. Every action is idempotent, so a pass can run any time.
"""
import json
import os
import subprocess
import sys

REPO = os.environ.get("GATEFOLD_REPO", "ourostack/gatefold")
DRIFT, FIXING, FIX, PASSED, HUMAN = "cloud-drift", "agent-fixing", "cloud-drift-fix", "live-canary-passed", "needs-human"
GATE = "Live cloud canary"
COPILOT = {"Copilot", "copilot-swe-agent", "app/copilot-swe-agent", "copilot-swe-agent[bot]"}
MAX_TRIES = 3
MARK = "<!-- cloud-drift-dispatch:"

INSTRUCTIONS = """\
PocketBook Cloud changed under Gatefold: the live cloud canary went red. The issue has the failed steps
and, when the run captured them, the redacted requests and responses diffed against our fixtures.

Fix the client in `Packages/GatefoldCloud` so the basics work again: sign-in, the library, a download
and the e-reader's place. Prefer tolerating the change (accept the old and the new shape) over
replacing the old shape, and note anything the app now does without through `CloudDrift.shared.note`.

- Add or update a fixture under `Packages/GatefoldCloud/Tests/GatefoldCloudTests/Fixtures` with the
  new shape, and a test that fails without your fix (see `ToleranceTests.swift`).
- Add a changelog fragment in `changelog.d/` (see `changelog.d/README.md`).
- Say `Fixes #{issue}` in the pull request body.
- The package needs Swift on macOS; if you can't build it here, CI builds it on macOS. Read its
  failures in the pull request's checks.

When you finish, the pull request is run against the real cloud (`cloud-fix-gate.yml`). It merges
on its own once CI and that live run pass.
"""


def gh(*args, input=None, check=True):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:3])}: {r.stderr.strip()[:300]}")
    return r.stdout


def ghj(*args):
    out = gh(*args)
    return json.loads(out) if out.strip() else None


def names(items):
    return {i["name"] for i in items or []}


def plan(issues, prs, facts):
    """The actions for one pass, as (verb, number, detail) tuples. Pure, for the selftest.

    issues: open cloud-drift issues (number, labels, assignees). prs: open pull requests by Copilot
    (number, title, isDraft, headRefOid, labels, body, closingIssuesReferences, autoMergeRequest).
    facts[pr number]: {"waiting": [run ids awaiting approval], "gate": (state, description) or None,
    "failed": [names of failed checks other than the gate], "marks": [markers already posted]}.
    """
    acts = []
    drift = {i["number"] for i in issues}
    linked = set()
    for pr in prs:
        refs = {r["number"] for r in pr.get("closingIssuesReferences") or []}
        refs |= {n for n in drift if f"#{n}" in (pr.get("body") or "")}
        mine = refs & drift
        if not mine:
            continue
        linked |= mine
        n, sha, labels = pr["number"], pr["headRefOid"], names(pr.get("labels"))
        f = facts.get(n, {})
        marks = f.get("marks", [])
        if HUMAN in labels or pr["title"].startswith("[WIP]"):
            continue  # while Copilot works, its pushes' runs wait: no macOS runners for half-done code
        for run in f.get("waiting", []):
            acts.append(("approve-run", n, run))
        if FIX not in labels:
            acts.append(("label", n, FIX))
        if pr.get("isDraft"):
            acts.append(("ready", n, None))
        state, text = f.get("gate") or (None, "")
        tries = sum(1 for m in marks if m.startswith("retry "))
        failed = f.get("failed") or []
        if failed or state == "failure":
            if f"retry {sha}" in marks:
                continue
            if tries >= MAX_TRIES:
                if "gave-up" not in marks:
                    acts.append(("give-up", n, None))
                continue
            what = []
            if failed:
                what.append("CI failed: " + ", ".join(failed) + ". Read those checks' logs.")
            if state == "failure":
                what.append(f"The live cloud canary failed on this code: {text}")
            acts.append(("retry", n, (sha, " ".join(what))))
        elif state == "error" and f"rerun {sha}" not in marks:
            acts.append(("rerun-gate", n, sha))
        elif state == "success" and PASSED in labels and not pr.get("autoMergeRequest"):
            acts.append(("auto-merge", n, None))
    for i in issues:
        n = i["number"]
        if n in linked or HUMAN in names(i.get("labels")) or FIXING in names(i.get("labels")):
            continue
        if any(a.get("login") in COPILOT for a in i.get("assignees") or []):
            continue
        acts.append(("assign", n, None))
    return acts


def gather():
    issues = ghj("issue", "list", "-R", REPO, "--label", DRIFT, "--state", "open",
                 "--json", "number,labels,assignees") or []
    fields = "number,title,isDraft,headRefOid,labels,body,closingIssuesReferences,autoMergeRequest,author"
    prs = [p for p in ghj("pr", "list", "-R", REPO, "--state", "open", "--json", fields) or []
           if (p.get("author") or {}).get("login") in COPILOT]
    facts = {}
    for p in prs:
        sha = p["headRefOid"]
        waiting = ghj("api", f"repos/{REPO}/actions/runs?head_sha={sha}&status=action_required",
                      "-q", "[.workflow_runs[].id]") or []
        status = ghj("api", f"repos/{REPO}/commits/{sha}/status") or {}
        gate = next(((s["state"], s.get("description") or "") for s in status.get("statuses", [])
                     if s.get("context") == GATE), None)
        runs = ghj("api", f"repos/{REPO}/commits/{sha}/check-runs?per_page=100",
                   "-q", "[.check_runs[] | {name, conclusion}]") or []
        failed = sorted({r["name"] for r in runs if r["conclusion"] in ("failure", "timed_out")})
        comments = ghj("pr", "view", str(p["number"]), "-R", REPO, "--json", "comments", "-q", "[.comments[].body]") or []
        marks = [c.split(MARK, 1)[1].split("-->", 1)[0].strip() for c in comments if MARK in c]
        facts[p["number"]] = {"waiting": waiting, "gate": gate, "failed": failed, "marks": marks}
    return issues, prs, facts


LABELS = {FIXING: ("1D76DB", "Copilot's coding agent is fixing this cloud-drift issue (cloud-drift-dispatch.py)"),
          FIX: ("0E8A16", "A fix for a cloud-drift issue; gated on the live canary (cloud-fix-gate.yml)"),
          HUMAN: ("B60205", "The cloud-drift agent gave up; a person needs to look (cloud-drift-dispatch.py)")}


def label(kind, n, name):
    color, about = LABELS[name]
    gh("label", "create", name, "-R", REPO, "--color", color, "--description", about, check=False)
    gh(kind, "edit", str(n), "-R", REPO, "--add-label", name)


def do(act):
    verb, n, detail = act
    if verb == "assign":
        body = {"assignees": ["copilot-swe-agent[bot]"],
                "agent_assignment": {"target_repo": REPO, "base_branch": "main",
                                     "custom_instructions": INSTRUCTIONS.replace("{issue}", str(n))}}
        gh("api", "-X", "POST", f"repos/{REPO}/issues/{n}/assignees", "--input", "-", input=json.dumps(body))
        label("issue", n, FIXING)
        gh("issue", "comment", str(n), "-R", REPO, "--body",
           "Handed to Copilot's coding agent (`scripts/cloud-drift-dispatch.py`). Its pull request runs "
           "against the real cloud before it merges.")
    elif verb == "approve-run":
        gh("api", "-X", "POST", f"repos/{REPO}/actions/runs/{detail}/approve", check=False)
    elif verb == "label":
        label("pr", n, detail)
    elif verb == "ready":
        gh("pr", "ready", str(n), "-R", REPO)
    elif verb == "auto-merge":
        gh("pr", "merge", str(n), "-R", REPO, "--auto", "--squash")
    elif verb == "retry":
        sha, what = detail
        gh("pr", "comment", str(n), "-R", REPO, "--body", f"@copilot {what} Please fix it and push.\n\n{MARK} retry {sha} -->")
    elif verb == "rerun-gate":
        gh("workflow", "run", "cloud-fix-gate.yml", "-R", REPO, "--ref", "main", "-f", f"pr={n}")
        gh("pr", "comment", str(n), "-R", REPO, "--body",
           f"The live canary was inconclusive (the cloud's login limit); running it again.\n\n{MARK} rerun {detail} -->")
    elif verb == "give-up":
        label("pr", n, HUMAN)
        gh("pr", "comment", str(n), "-R", REPO, "--body",
           f"Copilot tried {MAX_TRIES} times and CI or the live canary still fails, so this needs a person.\n\n{MARK} gave-up -->")


def tick(argv):
    issues, prs, facts = gather()
    acts = plan(issues, prs, facts)
    for a in acts:
        print("would" if "--dry-run" in argv else "doing", *a[:2], a[2] if a[0] != "retry" else a[2][1][:120])
        if "--dry-run" not in argv:
            try:
                do(a)
            except RuntimeError as e:
                print(f"failed: {e}", file=sys.stderr)
    if not acts:
        print(f"nothing to do ({len(issues)} drift issues, {len(prs)} Copilot pull requests)")
    return 0


def selftest():
    L = lambda *ns: [{"name": x} for x in ns]
    issue = {"number": 50, "labels": L(DRIFT), "assignees": []}
    assert plan([issue], [], {}) == [("assign", 50, None)]
    assert plan([dict(issue, labels=L(DRIFT, FIXING))], [], {}) == []
    assert plan([dict(issue, assignees=[{"login": "Copilot"}])], [], {}) == []
    wip = {"number": 60, "title": "[WIP] Tolerate the new shape", "isDraft": True, "headRefOid": "a1",
           "labels": [], "body": "Fixes #50", "closingIssuesReferences": [], "autoMergeRequest": None}
    # Still working: nothing, not even its waiting runs; the issue is not handed out again.
    assert plan([issue], [wip], {60: {"waiting": [7]}}) == []
    done = dict(wip, title="Tolerate the new shape")
    assert plan([issue], [done], {}) == [("label", 60, FIX), ("ready", 60, None)]
    gated = dict(done, isDraft=False, labels=L(FIX))
    assert plan([issue], [gated], {60: {"gate": ("pending", "")}}) == []
    assert plan([issue], [dict(gated, labels=L(FIX, PASSED))], {60: {"gate": ("success", "ok")}}) == [("auto-merge", 60, None)]
    assert plan([issue], [dict(gated, labels=L(FIX, PASSED), autoMergeRequest={"x": 1})], {60: {"gate": ("success", "ok")}}) == []
    # A failure goes back to Copilot once per head, then to a person after MAX_TRIES.
    acts = plan([issue], [gated], {60: {"gate": ("failure", "Live canary failed: download"), "failed": ["Package tests"]}})
    assert acts[0][0] == "retry" and acts[0][2][0] == "a1" and "Package tests" in acts[0][2][1] and "download" in acts[0][2][1], acts
    assert plan([issue], [gated], {60: {"gate": ("failure", "x"), "marks": ["retry a1"]}}) == []
    tried = ["retry a", "retry b", "retry c"]
    assert plan([issue], [gated], {60: {"gate": ("failure", "x"), "marks": tried}}) == [("give-up", 60, None)]
    assert plan([issue], [gated], {60: {"gate": ("failure", "x"), "marks": tried + ["gave-up"]}}) == []
    assert plan([issue], [dict(gated, labels=L(FIX, HUMAN))], {60: {"gate": ("failure", "x")}}) == []
    # Inconclusive (429): run the gate again, once per head.
    assert plan([issue], [gated], {60: {"gate": ("error", "Inconclusive")}}) == [("rerun-gate", 60, "a1")]
    assert plan([issue], [gated], {60: {"gate": ("error", "x"), "marks": ["rerun a1"]}}) == []
    # A Copilot pull request for something else is left alone; the link can be GitHub's closing reference.
    assert plan([], [dict(done, body="Fixes #9")], {}) == []
    assert plan([issue], [dict(done, body="", closingIssuesReferences=[{"number": 50}])], {})[0] == ("label", 60, FIX)
    assert "Fixes #50" in INSTRUCTIONS.replace("{issue}", "50")
    print("cloud-drift-dispatch selftest ok")
    return 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        return selftest()
    if argv[:1] == ["tick"]:
        return tick(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
