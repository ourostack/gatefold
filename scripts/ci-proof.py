#!/usr/bin/env python3
"""Was this main commit's tree already proven before it reached main? Then main doesn't test it a second time.

A run proves a tree when its proof job, named "<prefix><tree sha>", passed and the whole run concluded success. App's
proof job runs only when the full lists ran and every gate passed; Real unfold's only when every unfold ran and passed.
The tree is `git rev-parse HEAD^{tree}` of what the run tested: the pull request's merge ref, or the merge queue's
commit. Equal trees are equal files, so the workflows, the test lists and the app are the ones that passed.

    python3 -I scripts/ci-proof.py --sha <main commit> --workflow app.yml --prefix "Full suite passed on tree "
    python3 -I scripts/ci-proof.py --tree <tree> --run <this run id> --workflow app.yml --prefix "Full suite passed on tree "
    python3 -I scripts/ci-proof.py --shards --tree <tree> --run <this run id> --workflow app.yml
    python3 -I scripts/ci-proof.py --selftest

Where it looks, for the workflow's runs of event pull_request or merge_group (never push, never dispatch), taking
only the newest such run on each commit:
  - the main commit itself (a merge queue fast-forwards main to the commit its group tested; a pull request's head
    pushed to main as it is has its own runs there), and
  - the head of each pull request GitHub says was merged as this commit (merge_commit_sha == the main commit).
In the merge queue (--tree), it looks instead at the workflow's other merge_group runs that concluded success, newest
first, whose own commit has this tree (a group's commit is what its run tested, so the run's head_commit.tree_id is
the tree it tested). A pull request re-enqueued after a runner fault is often tested again on the very same tree (#469:
four groups on tree 9c4ddc91, of which App passed in full in run 44223501154 and Real unfold in run 44252229893); the
second time its required checks pass by that proof. A run on another tree, a red or cancelled one, one whose proof job
skipped or names another tree, and this run itself never count. A proven run still ends with its proof job, so main's
push finds the proof on the commit the queue merged.

Per shard (--shards, the merge queue only): the UI shards that already passed on this very tree in another of the
workflow's merge_group runs, whatever that run's end (a run that lost one shard to its runner still passed the
others). It writes `shards=<names>` (space-separated, in a space on each side) to $GITHUB_OUTPUT, and each of those
shards reports "Passed on this tree" instead of running again (ui-tests.yml); the gates and the proof job then pass
only when every shard has passed on this tree, here or before. A shard counts only for its own job "<...> (<shard>) /
Tests" that ended success, in any attempt of a run whose own commit has this tree. Any trouble reading GitHub writes
an empty list, and every shard runs.

Exit 0 and `proven=true`, `proof=<run url>` in $GITHUB_OUTPUT when one run proves the main commit's tree; exit 1 and
`proven=false` otherwise: a push no such run passed, a tree that differs, a red or unfinished run, a proof job that skipped. Exit 2
and `proven=false` when GitHub can't be read. Anything but 0 runs the full suite: it fails closed.
"""
import json
import os
import re
import sys
import urllib.request

EVENTS = {"pull_request", "merge_group"}


class Api:
    def __init__(self, repo, token):
        self.repo, self.token = repo, token

    def get(self, path):
        req = urllib.request.Request(f"https://api.github.com/repos/{self.repo}/{path}", headers={
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        })
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.load(resp)

    def tree(self, sha):
        return self.get(f"commits/{sha}")["commit"]["tree"]["sha"]

    def merged_pr_heads(self, sha):
        pulls = self.get(f"commits/{sha}/pulls?per_page=100")
        return [p["head"]["sha"] for p in pulls if p.get("merged_at") and p.get("merge_commit_sha") == sha]

    def runs(self, workflow, head_sha):
        return self.get(f"actions/workflows/{workflow}/runs?head_sha={head_sha}&per_page=100")["workflow_runs"]

    def all_group_runs(self, workflow):
        return self.get(f"actions/workflows/{workflow}/runs?event=merge_group&per_page=100")["workflow_runs"]

    def all_jobs(self, run_id):
        out, page = [], 1
        while True:
            body = self.get(f"actions/runs/{run_id}/jobs?filter=all&per_page=100&page={page}")
            out += body.get("jobs", [])
            if len(out) >= body.get("total_count", 0) or not body.get("jobs"):
                return out
            page += 1

    def group_runs(self, workflow):
        return self.get(f"actions/workflows/{workflow}/runs?event=merge_group&status=success&per_page=100")["workflow_runs"]

    def jobs(self, run_id):
        out, page = [], 1
        while True:
            body = self.get(f"actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
            out += body.get("jobs", [])
            if len(out) >= body.get("total_count", 0) or not body.get("jobs"):
                return out
            page += 1


def prove(api, sha, workflow, prefix):
    """(run url or None, lines saying why). Raises on API trouble; the caller fails closed."""
    tree = api.tree(sha)
    want = prefix + tree
    lines = [f"main commit {sha[:7]}, tree {tree[:12]}; looking for a passed job named {want!r}"]
    heads = [sha] + [h for h in api.merged_pr_heads(sha) if h != sha]
    if len(heads) == 1:
        lines.append("no pull request was merged as this commit (a direct push?); only a merge queue run can prove it")
    for head in heads:
        # Only the newest run on a head counts, as in ci-green-gate.py: a rerun or a reopen that went red after a green
        # run takes the proof back.
        runs = sorted((r for r in api.runs(workflow, head) if r.get("event") in EVENTS), key=lambda r: r["id"])
        for run in runs[-1:]:
            where = f"run {run['id']} ({run.get('event')}, head {head[:7]}, the newest on it)"
            if run.get("status") != "completed" or run.get("conclusion") != "success":
                lines.append(f"{where}: {run.get('status')} {run.get('conclusion')}, not a proof")
                continue
            names = {j.get("name"): j for j in api.jobs(run["id"])}
            job = names.get(want)
            if job is None:
                others = sorted(n for n in names if n and n.startswith(prefix))
                lines.append(f"{where}: green, but proves {others or 'no tree'} (not this one)")
                continue
            if job.get("status") != "completed" or job.get("conclusion") != "success":
                lines.append(f"{where}: its proof job ended {job.get('conclusion')}, not a proof")
                continue
            url = run.get("html_url") or f"run {run['id']}"
            lines.append(f"{where}: proves tree {tree[:12]}: {url}")
            return url, lines
    lines.append("no run proves this tree: the full suite runs")
    return None, lines


LOOK = 5  # same-tree runs whose jobs it reads, newest first


def proven_by(api, run, want):
    """(url or None, line) for one run: it proves `want` when it concluded success and its job `want` passed."""
    where = f"run {run['id']} ({run.get('event')})"
    if run.get("status") != "completed" or run.get("conclusion") != "success":
        return None, f"{where}: {run.get('status')} {run.get('conclusion')}, not a proof"
    job = {j.get("name"): j for j in api.jobs(run["id"])}.get(want)
    if job is None or job.get("status") != "completed" or job.get("conclusion") != "success":
        return None, f"{where}: green, but its job {want!r} {'is missing' if job is None else 'ended ' + str(job.get('conclusion'))}"
    url = run.get("html_url") or f"run {run['id']}"
    return url, f"{where}: proves it: {url}"


def prove_tree(api, tree, run_id, workflow, prefix):
    """The merge queue's proof: another merge_group run of `workflow` that passed in full on this very tree.
    (run url or None, lines). Raises on API trouble; the caller fails closed."""
    want = prefix + tree
    lines = [f"merge group tree {tree[:12]}; looking for a passed job named {want!r} in another merge-queue run"]
    same = sorted((r for r in api.group_runs(workflow) if r.get("event") == "merge_group"
                   and (r.get("head_commit") or {}).get("tree_id") == tree and str(r["id"]) != str(run_id)),
                  key=lambda r: r["id"], reverse=True)
    if not same:
        lines.append("no other green merge-queue run tested this tree: the full suite runs")
        return None, lines
    for run in same[:LOOK]:
        url, line = proven_by(api, run, want)
        lines.append(line)
        if url:
            return url, lines
    lines.append("no run proves this tree: the full suite runs")
    return None, lines


SHARD_JOB = re.compile(r"\(([a-z0-9-]+)\) / Tests$")


def passed_shards(api, tree, run_id, workflow):
    """(sorted shard names that passed on this tree in another merge_group run, lines). Raises on API trouble."""
    same = [r for r in api.all_group_runs(workflow) if r.get("event") == "merge_group"
            and (r.get("head_commit") or {}).get("tree_id") == tree and str(r["id"]) != str(run_id)]
    lines = [f"merge group tree {tree[:12]}: {len(same)} other merge-queue run(s) tested it"]
    found = {}
    for run in sorted(same, key=lambda r: r["id"]):
        for job in api.all_jobs(run["id"]):
            m = SHARD_JOB.search(job.get("name") or "")
            if m and job.get("status") == "completed" and job.get("conclusion") == "success":
                found.setdefault(m.group(1), run["id"])
    for shard, rid in sorted(found.items()):
        lines.append(f"{shard}: passed on this tree in run {rid}")
    return sorted(found), lines


class Fake:
    """An API whose answers the selftest writes."""

    def __init__(self, trees, pulls, runs, jobs, broken=False):
        self.trees, self.pulls, self.runs_, self.jobs_, self.broken = trees, pulls, runs, jobs, broken

    def tree(self, sha):
        if self.broken:
            raise OSError("HTTP 502")
        return self.trees[sha]

    def merged_pr_heads(self, sha):
        return [p["head"]["sha"] for p in self.pulls.get(sha, [])
                if p.get("merged_at") and p.get("merge_commit_sha") == sha]

    def runs(self, workflow, head):
        return [r for r in self.runs_ if r["head"] == head and r["workflow"] == workflow]

    def all_group_runs(self, workflow):
        if self.broken:
            raise OSError("HTTP 502")
        return [dict(r, head_commit={"tree_id": r.get("tree")}) for r in self.runs_
                if r["workflow"] == workflow and r["event"] == "merge_group"]

    def all_jobs(self, run_id):
        return self.jobs_.get(run_id, [])

    def group_runs(self, workflow):
        if self.broken:
            raise OSError("HTTP 502")
        return [dict(r, head_commit={"tree_id": r.get("tree")}) for r in self.runs_
                if r["workflow"] == workflow and r["event"] == "merge_group" and r["conclusion"] == "success"]

    def jobs(self, run_id):
        return self.jobs_.get(run_id, [])


def selftest():
    P = "Full suite passed on tree "
    main, head, tree, other = "m" * 40, "h" * 40, "t" * 40, "o" * 40
    pr = {main: [{"head": {"sha": head}, "merged_at": "x", "merge_commit_sha": main}]}

    def run(i, event="pull_request", concl="success", h=head, wf="app.yml", status="completed"):
        return {"id": i, "event": event, "status": status, "conclusion": concl, "head": h, "workflow": wf,
                "html_url": f"https://example/runs/{i}"}

    def job(name, concl="success"):
        return {"name": name, "status": "completed", "conclusion": concl}

    proven, not_proven = True, False
    cases = {
        "a pull request's green full run on the same tree proves it":
            (Fake({main: tree}, pr, [run(1)], {1: [job(P + tree)]}), proven),
        "a merge queue run on the main commit itself proves it":
            (Fake({main: tree}, {}, [run(2, "merge_group", h=main)], {2: [job(P + tree)]}), proven),
        "a mismatched tree does not":
            (Fake({main: tree}, pr, [run(3)], {3: [job(P + other)]}), not_proven),
        "a red run does not, even with its proof job green":
            (Fake({main: tree}, pr, [run(4, concl="failure")], {4: [job(P + tree)]}), not_proven),
        "a cancelled run does not":
            (Fake({main: tree}, pr, [run(5, concl="cancelled")], {5: [job(P + tree)]}), not_proven),
        "an unfinished run does not":
            (Fake({main: tree}, pr, [run(6, concl=None, status="in_progress")], {6: [job(P + tree)]}), not_proven),
        "a proof job that skipped (the PR lists ran, not the full ones) does not":
            (Fake({main: tree}, pr, [run(7)], {7: [job(P + tree, "skipped")]}), not_proven),
        "a green PR run with no proof job does not":
            (Fake({main: tree}, pr, [run(8)], {8: [job("iPad (place)")]}), not_proven),
        "a direct push with no proving run on its own commit does not":
            (Fake({main: tree}, {}, [run(9)], {9: [job(P + tree)]}), not_proven),
        "a pull request not merged as this commit does not":
            (Fake({main: tree}, {main: [{"head": {"sha": head}, "merged_at": "x", "merge_commit_sha": other}]},
                  [run(10)], {10: [job(P + tree)]}), not_proven),
        "a push run never proves (only the PR or the merge queue's)":
            (Fake({main: tree}, {}, [run(11, "push", h=main)], {11: [job(P + tree)]}), not_proven),
        "another workflow's run does not":
            (Fake({main: tree}, pr, [run(12, wf="real-unfold.yml")], {12: [job(P + tree)]}), not_proven),
        "a red run before a green proving one: the newer green one proves it":
            (Fake({main: tree}, pr, [run(13, concl="failure"), run(14)], {13: [job(P + tree)], 14: [job(P + tree)]}),
             proven),
        "a green proving run then a newer red one on the same head does not":
            (Fake({main: tree}, pr, [run(15), run(16, concl="failure")], {15: [job(P + tree)], 16: [job(P + tree)]}),
             not_proven),
        "a direct push of a commit whose own pull_request run proved its tree does (equal trees, equal files)":
            (Fake({main: tree}, {}, [run(17, h=main)], {17: [job(P + tree)]}), proven),
    }
    for name, (api, want) in cases.items():
        url, lines = prove(api, main, "app.yml", P)
        assert (url is not None) == want, f"{name}: got {url}\n  " + "\n  ".join(lines)
    # GitHub unreadable: prove raises, and main() turns that into exit 2, proven=false.
    try:
        prove(Fake({}, {}, [], {}, broken=True), main, "app.yml", P)
        raise AssertionError("an unreadable API must raise")
    except OSError:
        pass
    # The merge queue: another group's run on the same tree (#469's groups, all on tree 9c4ddc91).
    def grun(i, t=tree, concl="success", wf="app.yml", event="merge_group"):
        return dict(run(i, event, concl, h=f"g{i}", wf=wf), tree=t)

    group = {
        "another group's green full run on the same tree proves it":
            (Fake({}, {}, [grun(21)], {21: [job(P + tree)]}), proven),
        "a green run on another tree does not, even with its proof job named for this tree":
            (Fake({}, {}, [grun(22, t=other)], {22: [job(P + tree)]}), not_proven),
        "a green run on this tree whose proof job names another tree does not":
            (Fake({}, {}, [grun(23)], {23: [job(P + other)]}), not_proven),
        "a red run on this tree does not":
            (Fake({}, {}, [grun(24, concl="failure")], {24: [job(P + tree)]}), not_proven),
        "a green run whose proof job skipped (some shards passed, not all) does not":
            (Fake({}, {}, [grun(25)], {25: [job(P + tree, "skipped")]}), not_proven),
        "a green run with no proof job (a partial record) does not":
            (Fake({}, {}, [grun(26)], {26: [job("iPad (place)")]}), not_proven),
        "this run itself does not":
            (Fake({}, {}, [grun(99)], {99: [job(P + tree)]}), not_proven),
        "another workflow's run does not":
            (Fake({}, {}, [grun(27, wf="real-unfold.yml")], {27: [job(P + tree)]}), not_proven),
        "a pull request's run on the same tree is not looked at here":
            (Fake({}, {}, [grun(28, event="pull_request")], {28: [job(P + tree)]}), not_proven),
        "an older proving run behind a newer one without proof still proves it":
            (Fake({}, {}, [grun(29), grun(30)], {29: [job(P + tree)], 30: [job("iPad (place)")]}), proven),
        "no run at all does not":
            (Fake({}, {}, [], {}), not_proven),
    }
    for name, (api, want) in group.items():
        url, lines = prove_tree(api, tree, 99, "app.yml", P)
        assert (url is not None) == want, f"{name}: got {url}\n  " + "\n  ".join(lines)
    try:
        prove_tree(Fake({}, {}, [], {}, broken=True), tree, 99, "app.yml", P)
        raise AssertionError("an unreadable API must raise")
    except OSError:
        pass
    # Per shard: #469's groups, each losing a different shard to its runner on the same tree.
    T = " / Tests"
    shards = {
        "a shard that passed on this tree in a red run counts":
            (Fake({}, {}, [grun(41, concl="failure")], {41: [job("iPad place shard (ipad-place-jumps)" + T),
                job("iPad undo shard (ipad-undo-rest)" + T, "failure")]}), ["ipad-place-jumps"]),
        "a shard that passed on a different tree does not count":
            (Fake({}, {}, [grun(42, t=other)], {42: [job("iPad place shard (ipad-place-jumps)" + T)]}), []),
        "a shard that failed, was cancelled or skipped does not count":
            (Fake({}, {}, [grun(43, concl="cancelled")], {43: [job("Duo shard (duo-scroll)" + T, "failure"),
                job("Duo shard (duo-position)" + T, "cancelled"), job("Duo shard (duo-turnback)" + T, "skipped")]}), []),
        "passes add up across runs and attempts on the same tree":
            (Fake({}, {}, [grun(44, concl="failure"), grun(45, concl="cancelled")],
                  {44: [job("Duo shard (duo-scroll)" + T), job("Duo shard (duo-position)" + T, "failure")],
                   45: [job("Duo shard (duo-position)" + T)]}), ["duo-position", "duo-scroll"]),
        "this run's own passes do not count":
            (Fake({}, {}, [grun(99)], {99: [job("Duo shard (duo-scroll)" + T)]}), []),
        "a gate, a Main only job or a shard reported by proof is not a shard pass":
            (Fake({}, {}, [grun(46)], {46: [job("iPad (place)"), job("iPad place shard (ipad-place-jumps) / Main only"),
                job("iPad place shard (ipad-place-shelf) / Passed on this tree")]}), []),
        "a pull request's run does not count":
            (Fake({}, {}, [grun(47, event="pull_request")], {47: [job("Duo shard (duo-scroll)" + T)]}), []),
        "another workflow's run does not count":
            (Fake({}, {}, [grun(48, wf="real-unfold.yml")], {48: [job("Duo shard (duo-scroll)" + T)]}), []),
    }
    for name, (api, want) in shards.items():
        got, lines = passed_shards(api, tree, 99, "app.yml")
        assert got == want, f"{name}: got {got}, want {want}\n  " + "\n  ".join(lines)
    try:
        passed_shards(Fake({}, {}, [], {}, broken=True), tree, 99, "app.yml")
        raise AssertionError("an unreadable API must raise")
    except OSError:
        pass
    print(f"ci-proof selftest: {len(cases) + 1 + len(group) + 1 + len(shards) + 1} cases pass")


def write(proven, proof=""):
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"proven={'true' if proven else 'false'}\nproof={proof}\n")


def write_shards(names):
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"shards= {' '.join(names)} \n")


def shards_main(tree, run_id, workflow):
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (tree and run_id and workflow and repo and token):
        print("ci-proof --shards: needs --tree, --run, --workflow, GITHUB_REPOSITORY and GITHUB_TOKEN", file=sys.stderr)
        write_shards([])
        return 2
    try:
        names, lines = passed_shards(Api(repo, token), tree, run_id, workflow)
    except Exception as exc:  # GitHub unreadable: every shard runs
        print(f"ci-proof --shards: could not read GitHub ({exc}); every shard runs", file=sys.stderr)
        write_shards([])
        return 2
    print("\n".join(lines) if names else "\n".join(lines + ["no shard passed on this tree before: every shard runs"]))
    write_shards(names)
    return 0


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    arg = lambda k: argv[argv.index(k) + 1] if k in argv else ""
    if "--shards" in argv:
        return shards_main(arg("--tree"), arg("--run"), arg("--workflow"))
    sha, workflow, prefix = arg("--sha"), arg("--workflow"), arg("--prefix")
    tree, run_id = arg("--tree"), arg("--run")
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not ((sha or (tree and run_id)) and workflow and prefix and repo and token):
        print("ci-proof: needs --sha (or --tree and --run), --workflow, --prefix, GITHUB_REPOSITORY and GITHUB_TOKEN",
              file=sys.stderr)
        write(False)
        return 2
    try:
        if tree:
            url, lines = prove_tree(Api(repo, token), tree, run_id, workflow, prefix)
        else:
            url, lines = prove(Api(repo, token), sha, workflow, prefix)
    except Exception as exc:  # GitHub unreadable: never guess proven
        print(f"ci-proof: could not read GitHub ({exc}); the full suite runs", file=sys.stderr)
        write(False)
        return 2
    print("\n".join(lines))
    write(url is not None, url or "")
    return 0 if url else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
