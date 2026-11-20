#!/usr/bin/env python3
"""CI only: retry a shard that GitHub cancelled, in the same App run (gatefold#404).

    python3 -I scripts/ci-retry.py plan      # GH_TOKEN, GH_REPO, RUN_ID set; writes matrix= and count= to $GITHUB_OUTPUT
    python3 -I scripts/ci-retry.py verdict   # writes <job id>=ok|bad for each UI shard job to $GITHUB_OUTPUT
    python3 -I scripts/ci-retry.py --selftest

A hosted macOS runner whose simulator is booting is cancelled from outside about 1 shard in 12 ("The operation was
canceled", no test ran). A run with a cancelled job ends "cancelled" however the rest goes, and rerun-runner.yml can
only rerun it after the whole run has ended, so each cancel cost an hour. This runs only the cancelled shards again as
soon as every shard has ended, still in the same run, on fresh runners (app.yml's `retry` job); `verdict` then
reports each shard job's group as ok when every shard passed, or was cancelled and passed on its retry. Only a cancelled
shard is retried: a failed one, a test failure above all, stays failed and keeps its gate red. Nothing is retried in a
run someone cancelled (the jobs say `!cancelled()`), and a retry that is cancelled too is left to rerun-runner.yml.

The retry's inputs come from app.yml's own matrix (scripts/ci-shards.py reads it), so a shard has one definition.
"""
import importlib.util
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", ".github", "workflows", "app.yml")
FIRST = re.compile(r"^(?P<prefix>.+) shard \((?P<shard>[^)]+)\) / (?P<inner>.+)$")
RETRY = re.compile(r"^Retry \((?P<shard>[^)]+)\) / (?P<inner>.+)$")
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


def classify(jobs, prefixes):
    """`jobs`: [{name, conclusion}] of one run. Returns ({job id: "ok" | "bad"}, [shards to retry])."""
    first, retried = {}, {}
    for j in jobs:
        m = FIRST.match(j["name"])
        if m and m["inner"] == "Tests":
            first[m["shard"]] = (m["prefix"], j["conclusion"])
            continue
        m = RETRY.match(j["name"])
        if m and m["inner"] == "Tests":
            retried[m["shard"]] = j["conclusion"]
    out = {job: "ok" for job in prefixes}
    byprefix = {prefix: job for job, prefix in prefixes.items()}
    for shard, (prefix, conclusion) in first.items():
        if conclusion in PASSED or (conclusion == "cancelled" and retried.get(shard) == "success"):
            continue
        if prefix in byprefix:
            out[byprefix[prefix]] = "bad"
    return out, sorted(s for s, (_, c) in first.items() if c == "cancelled")


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
    entries, prefixes = app_shards(open(APP).read())
    jobs = gh_jobs(os.environ["RUN_ID"])
    verdict, cancelled = classify(jobs, prefixes)
    if mode == "plan":
        todo = [e for e in entries if e["shard"] in cancelled]
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
    print("checks passed" if not bad else f"{bad} failed")
    return 1 if bad else 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--selftest"]:
        sys.exit(selftest())
    elif sys.argv[1:] in (["plan"], ["verdict"]):
        main(sys.argv[1])
    else:
        sys.exit(__doc__)
