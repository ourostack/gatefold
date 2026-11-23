#!/usr/bin/env python3
"""CI only: retry a shard (or Real unfold place) that GitHub cancelled, in the same run (gatefold#404).

    python3 -I scripts/ci-retry.py plan      # GH_TOKEN, GH_REPO, RUN_ID set; writes matrix= and count= to $GITHUB_OUTPUT
    python3 -I scripts/ci-retry.py verdict   # writes <job id>=ok|bad for each UI shard job to $GITHUB_OUTPUT
    python3 -I scripts/ci-retry.py proof     # RESULTS = toJSON(needs) of App's proof job; fails unless each passed

WORKFLOW names the workflow whose run is judged: app.yml (the default; its UI shards) or real-unfold.yml (its places,
which real-unfold-place.yml runs; the one job `unfold` is judged as a group).
    python3 -I scripts/ci-retry.py --selftest

A hosted macOS runner whose simulator is booting is cancelled from outside about 1 shard in 12 ("The operation was
canceled", no test ran). A run with a cancelled job ends "cancelled" however the rest goes, and rerun-runner.yml can
only rerun it after the whole run has ended, so each cancel cost an hour. This runs only the cancelled shards again as
soon as every shard has ended, still in the same run, on fresh runners (app.yml's `retry` job); `verdict` then
reports each shard job's group as ok when every shard passed, or was cancelled and passed on its retry. Only a cancelled
shard is retried: a failed one, a test failure above all, stays failed and keeps its gate red. Nothing is retried in a
run someone cancelled (the jobs say `!cancelled()`), and a retry that is cancelled too is left to rerun-runner.yml.

The retry's inputs come from the workflow's own matrix (scripts/ci-shards.py reads App's), so a shard or place has one
definition.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", ".github", "workflows", "app.yml")
REAL = os.path.join(HERE, "..", ".github", "workflows", "real-unfold.yml")
FIRST = re.compile(r"^(?P<prefix>.+) shard \((?P<shard>[^)]+)\) / (?P<inner>.+)$")
RETRY = re.compile(r"^Retry \((?P<shard>[^)]+)\) / (?P<inner>.+)$")
# Real unfold's job `unfold` calls real-unfold-place.yml once per place: "Unfold at 0.12 / Place", retried as
# "Retry (0.12) / Place". Its one group is judged as a whole.
FIRST_PLACE = re.compile(r"^(?P<prefix>Unfold) at (?P<shard>[^/]+?) / (?P<inner>Place)$")
PASSED = {"success", "skipped"}


def _shards():
    spec = importlib.util.spec_from_file_location("ci_shards", os.path.join(HERE, "ci-shards.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def app_shards(text):
    """([{shard, device, sim, tests, skip, cold, timeout, lane}], {job id: its name's prefix, "iPad place"})."""
    ci = _shards()
    entries, prefixes = [], {}
    for job, lines in ci.jobs(text).items():
        body = "\n".join(lines)
        if "uses: ./.github/workflows/ui-tests.yml" not in body or job == "retry":
            continue
        name = re.search(r"^\s+name:\s*(.+?) shard \(\$\{\{ matrix\.shard \}\}\)\s*$", body, re.M)
        sim = re.search(r"^\s+sim:\s*(.+)$", body, re.M)
        device = re.search(r"^\s+device:\s*(.+)$", body, re.M)
        prefixes[job] = name.group(1)
        for e in ci.matrix_entries(lines):
            entries.append({
                "shard": e["shard"], "device": ci.scalar(device.group(1)), "sim": ci.scalar(sim.group(1)),
                "tests": e.get("tests", "").strip(), "skip": e.get("skip", "").strip(),
                "cold": e.get("cold") == "true", "timeout": int(e["timeout"]), "lane": int(e["lane"]),
            })
    return entries, prefixes


def real_places(text):
    """([{place, early, timeout, lane}], {"unfold": "Unfold"}) for Real unfold's `unfold` matrix."""
    block = "\n".join(_shards().jobs(text)["unfold"])
    block = block.split("\n    permissions:")[0]
    entries = []
    for part in re.split(r"^ {10}- ", block, flags=re.M)[1:]:
        e = dict(re.findall(r"^\s*(place|early|timeout|lane):\s*\"?([^\"\n#]+?)\"?\s*(?:#.*)?$", part, re.M))
        entries.append({"place": e["place"], "early": e["early"], "timeout": int(e["timeout"]), "lane": int(e["lane"])})
    return entries, {"unfold": "Unfold"}


def classify(jobs, prefixes):
    """`jobs`: [{name, conclusion}] of one run. Returns ({job id: "ok" | "bad"}, [shards to retry])."""
    first, retried = {}, {}
    for j in jobs:
        m = FIRST.match(j["name"]) or FIRST_PLACE.match(j["name"])
        if m and m["inner"] in ("Tests", "Place"):
            first[m["shard"]] = (m["prefix"], j["conclusion"])
            continue
        m = RETRY.match(j["name"])
        if m and m["inner"] in ("Tests", "Place"):
            retried[m["shard"]] = j["conclusion"]
    out = {job: "ok" for job in prefixes}
    byprefix = {prefix: job for job, prefix in prefixes.items()}
    for shard, (prefix, conclusion) in first.items():
        if conclusion in PASSED or (conclusion == "cancelled" and retried.get(shard) == "success"):
            continue
        if prefix in byprefix:
            out[byprefix[prefix]] = "bad"
    return out, sorted(s for s, (_, c) in first.items() if c == "cancelled")


# App's proof job ("Full suite passed on tree <tree>") needs exactly the required checks, which judge the shards after
# their retries; it runs on always() and passes only when each of those passed (see `proof_ok`).
PROOF_NEEDS = ["changes", "core", "app", "ipad-place-gate", "ipad-undo-gate", "ipad-taps-gate", "ipad-reviewer-gate", "duo-gate"]


def proof_ok(results):
    """results: {need: result} from toJSON(needs). (ok, lines): ok only when every one of PROOF_NEEDS is there and
    passed. A failed, cancelled, skipped or missing check is red: the job fails, never skips."""
    lines = [f"{n}: {results.get(n) or 'missing'}" for n in PROOF_NEEDS]
    return all(results.get(n) == "success" for n in PROOF_NEEDS), lines


def proof_job(text):
    """(if, needs, run) of app.yml's `proof` job, as written."""
    m = re.search(r"^  proof:\n((?:(?:    .*|\s*)\n)+?)(?=^  \S|\Z)", text, re.M)
    block = m.group(1) if m else ""
    cond = re.search(r"^    if: (.*)$", block, re.M)
    needs = re.search(r"^    needs: \[(.*)\]$", block, re.M)
    return (cond.group(1) if cond else "", [n.strip() for n in needs.group(1).split(",")] if needs else [],
            "python3 -I scripts/ci-retry.py proof" in block)


def gh_jobs(run_id):
    out = subprocess.run(["gh", "api", "--paginate", f"repos/{{owner}}/{{repo}}/actions/runs/{run_id}/jobs?filter=latest",
                          "--jq", ".jobs[]|{name, conclusion}|tojson"], check=True, capture_output=True, text=True).stdout
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def emit(**kv):
    lines = "".join(f"{k}={v}\n" for k, v in kv.items())
    path = os.environ.get("GITHUB_OUTPUT")
    if path:
        with open(path, "a") as f:
            f.write(lines)
    print(lines, end="")


def main(mode):
    if mode == "proof":
        results = {k: (v or {}).get("result") for k, v in json.loads(os.environ.get("RESULTS") or "{}").items()}
        ok, lines = proof_ok(results)
        print("\n".join(lines))
        if not ok:
            print("::error::Not every required check passed, so this run proves nothing about its tree.")
        sys.exit(0 if ok else 1)
    real = os.environ.get("WORKFLOW") == "real-unfold.yml"
    entries, prefixes = (real_places if real else app_shards)(open(REAL if real else APP).read())
    key = "place" if real else "shard"
    jobs = gh_jobs(os.environ["RUN_ID"])
    verdict, cancelled = classify(jobs, prefixes)
    if mode == "plan":
        todo = [e for e in entries if e[key] in cancelled]
        print(f"Cancelled shards to retry: {', '.join(cancelled) or 'none'}")
        emit(matrix=json.dumps({"include": todo}, separators=(",", ":")), count=len(todo))
    else:
        print("\n".join(f"{job}: {v}" for job, v in verdict.items()))
        emit(**verdict)


def selftest():
    text = open(APP).read()
    entries, prefixes = app_shards(text)
    bad = 0

    def check(ok, what):
        nonlocal bad
        if not ok:
            bad += 1
            print("FAIL:", what)

    check(len(entries) > 20 and len({e["shard"] for e in entries}) == len(entries), "every shard is read once")
    check(set(prefixes.values()) >= {"iPad place", "iPad taps", "Duo"}, f"job names: {prefixes}")
    check(all(e["device"] and e["sim"] and e["tests"] or e["skip"] for e in entries), "each shard has its inputs")
    check(any(e["cold"] for e in entries) and any(not e["cold"] for e in entries), "cold is read as a boolean")
    places, groups = real_places(open(REAL).read())
    check([p["place"] for p in places] == ["0.12", "0.31", "0.47", "0.66", "0.83"] and groups == {"unfold": "Unfold"}, f"places: {places}")
    check(all(p["early"] and p["timeout"] == 77 and 1 <= p["lane"] <= 5 for p in places), f"each place has its inputs: {places}")
    j = lambda name, c: {"name": name, "conclusion": c}
    t = lambda p, s, c: j(f"{p} shard ({s}) / Tests", c)
    check(classify([t("iPad place", "a", "success"), j("iPad (place)", "success")], prefixes)[0]["ipad-place"] == "ok", "a passed shard")
    r = classify([t("iPad place", "a", "cancelled"), j("Retry (a) / Tests", "success")], prefixes)
    check(r == ({k: "ok" for k in prefixes}, ["a"]), f"a cancelled shard that passed its retry: {r}")
    r = classify([t("iPad place", "a", "cancelled"), t("iPad place", "b", "success")], prefixes)
    check(r[0]["ipad-place"] == "bad" and r[1] == ["a"], "a cancelled shard with no retry is bad")
    r = classify([t("iPad place", "a", "cancelled"), j("Retry (a) / Tests", "failure")], prefixes)
    check(r[0]["ipad-place"] == "bad", "a retry that failed is bad")
    r = classify([t("iPad place", "a", "cancelled"), j("Retry (a) / Tests", "cancelled")], prefixes)
    check(r[0]["ipad-place"] == "bad", "a retry that was cancelled too is bad")
    r = classify([t("iPad taps", "a", "failure"), j("Retry (a) / Tests", "success")], prefixes)
    check(r[0]["ipad-taps"] == "bad" and r[1] == [], "a failed shard is never retried or excused")
    r = classify([t("Duo", "d", "success"), t("iPad taps", "a", "cancelled"), j("Retry (a) / Tests", "success")], prefixes)
    check(r[0]["duo"] == "ok" and r[0]["ipad-taps"] == "ok", "groups are judged apart")
    r = classify([j("iPad place shard (a) / Main only", "success"), j("Build for testing", "success")], prefixes)
    check(set(r[0].values()) == {"ok"}, "a shard with nothing to run is ok")
    u = lambda p, c: j(f"Unfold at {p} / Place", c)
    r = classify([u("0.12", "cancelled"), u("0.31", "success"), j("Retry (0.12) / Place", "success")], groups)
    check(r == ({"unfold": "ok"}, ["0.12"]), f"a cancelled place that passed its retry: {r}")
    r = classify([u("0.12", "cancelled"), u("0.31", "success")], groups)
    check(r == ({"unfold": "bad"}, ["0.12"]), "a cancelled place with no retry is bad")
    r = classify([u("0.12", "failure"), j("Retry (0.12) / Place", "success")], groups)
    check(r == ({"unfold": "bad"}, []), "a failed place is never retried or excused")
    r = classify([u("0.12", "cancelled"), j("Retry (0.12) / Place", "cancelled")], groups)
    check(r[0] == {"unfold": "bad"}, "a retry that was cancelled too is bad")
    r = classify([u("0.12", "success"), u("0.31", "success")], groups)
    check(r == ({"unfold": "ok"}, []), "every place passed")
    # App's proof job: judged by its needs, the required checks, never by the shard jobs under them.
    green = {n: "success" for n in PROOF_NEEDS}
    r = classify([t("iPad place", "a", "cancelled"), j("Retry (a) / Tests", "success")], prefixes)[0]
    gate = "success" if r["ipad-place"] == "ok" else "failure"  # each gate: shards success, or cancelled and retried ok
    check(proof_ok({**green, "ipad-place-gate": gate})[0], "a cancelled shard that passed its retry: the proof is green")
    check(not proof_ok({**green, "duo-gate": "failure"})[0], "a failed gate: the proof is red")
    check(not proof_ok({**green, "ipad-taps-gate": "skipped"})[0], "a skipped gate: the proof is red")
    check(not proof_ok({**green, "app": "cancelled"})[0], "a cancelled check: the proof is red")
    check(not proof_ok({k: v for k, v in green.items() if k != "core"})[0], "a missing check: the proof is red")
    cond, needs, runs = proof_job(text)
    check(cond.startswith("${{ always() && ") and "success()" not in cond and "cancelled()" not in cond,
          f"the proof job runs on always(), so a cancelled job under a gate can't skip it: {cond}")
    check(needs == PROOF_NEEDS, f"the proof job needs exactly the required checks, no shard job: {needs}")
    check(runs, "the proof job judges with `ci-retry.py proof`")
    print("checks passed" if not bad else f"{bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    elif sys.argv[1:] in (["plan"], ["verdict"], ["proof"]):
        main(sys.argv[1])
    else:
        sys.exit(__doc__)
