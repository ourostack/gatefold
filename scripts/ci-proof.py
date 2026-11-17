#!/usr/bin/env python3
"""Was this main commit's tree already proven before it reached main? Then main doesn't test it a second time.

A run proves a tree when its proof job, named "<prefix><tree sha>", passed and the whole run concluded success. App's
proof job runs only when the full lists ran and every gate passed; Real unfold's only when every unfold ran and passed.
The tree is `git rev-parse HEAD^{tree}` of what the run tested: the pull request's merge ref, or the merge queue's
commit. Equal trees are equal files, so the workflows, the test lists and the app are the ones that passed.

    python3 -I scripts/ci-proof.py --sha <main commit> --workflow app.yml --prefix "Full suite passed on tree "
    python3 -I scripts/ci-proof.py --selftest

Where it looks, for the workflow's runs of event pull_request or merge_group (never push, never dispatch), taking
only the newest such run on each commit:
  - the main commit itself (a merge queue fast-forwards main to the commit its group tested; a pull request's head
    pushed to main as it is has its own runs there), and
  - the head of each pull request GitHub says was merged as this commit (merge_commit_sha == the main commit).
Exit 0 and `proven=true`, `proof=<run url>` in $GITHUB_OUTPUT when one run proves the main commit's tree; exit 1 and
`proven=false` otherwise: a push no such run passed, a tree that differs, a red or unfinished run, a proof job that skipped. Exit 2
and `proven=false` when GitHub can't be read. Anything but 0 runs the full suite: it fails closed.
"""
import json
import os
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
    print(f"ci-proof selftest: {len(cases) + 1} cases pass")


def write(proven, proof=""):
    out = os.environ.get("GITHUB_OUTPUT")
    if out:
        with open(out, "a") as fh:
            fh.write(f"proven={'true' if proven else 'false'}\nproof={proof}\n")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    arg = lambda k: argv[argv.index(k) + 1] if k in argv else ""
    sha, workflow, prefix = arg("--sha"), arg("--workflow"), arg("--prefix")
    repo, token = os.environ.get("GITHUB_REPOSITORY", ""), os.environ.get("GITHUB_TOKEN", "")
    if not (sha and workflow and prefix and repo and token):
        print("ci-proof: needs --sha, --workflow, --prefix, GITHUB_REPOSITORY and GITHUB_TOKEN", file=sys.stderr)
        write(False)
        return 2
    try:
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
