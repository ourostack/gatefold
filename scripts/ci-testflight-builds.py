#!/usr/bin/env python3
"""Which commit each TestFlight build came from, kept as GitHub deployments, never as tags GitHub must create.

    python3 -I scripts/ci-testflight-builds.py record   # BUILD, SHA, GH_TOKEN, GITHUB_REPOSITORY set; by testflight.yml
    python3 -I scripts/ci-testflight-builds.py tags     # GH_TOKEN, GITHUB_REPOSITORY set; in a full clone
    python3 -I scripts/ci-testflight-builds.py list     # build, commit and date of each recorded build
    python3 -I scripts/ci-testflight-builds.py --selftest

TestFlight used to tag each published commit testflight/build-N with the workflow's token. GitHub refuses a token
without the `workflows` permission any new ref, tag or branch, at a commit whose .github/workflows differ from what
it compares them with, and GITHUB_TOKEN can never have that permission. A publish takes about ten minutes and judges
a commit that is often already behind main, and most pull requests change app.yml (a shard's timeout), so the tag
was refused for builds 65 and 66 (runs 45110123133, 45126244670: "Resource not accessible by integration (HTTP 403)").
`git push` gives the reason the API hides: "refusing to allow a GitHub App to create or update workflow
`.github/workflows/app.yml` without `workflows` permission". The Ouro Current app has no `workflows` permission
either, and an annotated tag, GraphQL createRef and a release were refused the same way (probe branch ci/tag-probe,
2026-11-23). A deployment names a commit without creating a ref, so GITHUB_TOKEN with `deployments: write` may make one.

`record` adds one deployment in the testflight-builds environment for the published commit, payload {"build": N}.
`tags` reads them back and makes a local testflight/build-N tag for each in this clone, so `git tag --contains`,
`git describe` and scripts/changelog.py read published builds as before. A tag on GitHub (builds up to 64, 66 and
67, and any added by hand) wins over a deployment with the same number at another commit; it is never moved.
"""
import json
import os
import re
import subprocess
import sys

ENVIRONMENT = "testflight-builds"
TASK = "testflight:build"
TAG = "testflight/build-{}"
RECORD_JOB = "Record the published build testflight/build-N"
# The steps that read published builds from tags; a job running one must run `tags` first.
READERS = ("'testflight/build-*'", "changelog.py assemble")


def builds(deployments):
    """[(build, sha)] of the recorded deployments, newest first, skipping any that isn't a TestFlight build."""
    out = []
    for d in deployments:
        payload = d.get("payload")
        if isinstance(payload, str):
            try:
                payload = json.loads(payload) if payload else {}
            except ValueError:
                payload = {}
        build = (payload or {}).get("build") if isinstance(payload, dict) else None
        sha = d.get("sha", "")
        if d.get("task") != TASK or not isinstance(build, int) or build < 1 or not re.fullmatch(r"[0-9a-f]{40}", sha):
            continue
        out.append((build, sha))
    return out


def plan(recorded, existing):
    """(tags to make [(tag, sha)], warnings) given recorded builds and the clone's tags {tag: sha}."""
    make, warn, seen = [], [], {}
    for build, sha in recorded:
        tag = TAG.format(build)
        if tag in seen:
            if seen[tag] != sha:
                warn.append(f"{tag} is recorded at both {seen[tag][:7]} and {sha[:7]}; the newest record, {seen[tag][:7]}, is used.")
            continue
        seen[tag] = sha
        have = existing.get(tag)
        if have is None:
            make.append((tag, sha))
        elif have != sha:
            warn.append(f"{tag} is tagged at {have[:7]} but recorded at {sha[:7]}; the tag is kept.")
    return make, warn


def deployment_body(build, sha):
    if not re.fullmatch(r"[1-9][0-9]*", str(build)):
        raise ValueError(f"build number {build!r}")
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError(f"commit {sha!r} (a full SHA is needed)")
    return {"ref": sha, "environment": ENVIRONMENT, "task": TASK, "payload": {"build": int(build)},
            "description": f"TestFlight build {build}", "auto_merge": False, "required_contexts": [],
            "transient_environment": False, "production_environment": False}


def gh(*args, body=None):
    out = subprocess.run(["gh", "api", *args] + (["--input", "-"] if body is not None else []), check=True,
                         capture_output=True, text=True, input=json.dumps(body) if body is not None else None).stdout
    return out


def fetch_deployments(repo):
    out = gh("--paginate", f"repos/{repo}/deployments?environment={ENVIRONMENT}&task={TASK}&per_page=100",
             "--jq", ".[]|tojson")
    return [json.loads(line) for line in out.splitlines() if line.strip()]


def local_tags():
    out = subprocess.run(["git", "for-each-ref", "--format=%(refname:strip=2) %(*objectname) %(objectname)",
                          "refs/tags/testflight/"], check=True, capture_output=True, text=True).stdout
    tags = {}
    for line in out.splitlines():
        parts = line.split()
        if parts:
            tags[parts[0]] = parts[1] if len(parts) == 3 else parts[-1]
    return tags


def record():
    repo, build, sha = os.environ["GITHUB_REPOSITORY"], os.environ.get("BUILD", ""), os.environ.get("SHA", "")
    body = deployment_body(build, sha)
    dep = json.loads(gh(f"repos/{repo}/deployments", body=body))
    gh(f"repos/{repo}/deployments/{dep['id']}/statuses", "-f", "state=success",
       "-f", f"description=On TestFlight as build {build}")
    print(f"Recorded {sha[:7]} as TestFlight build {build} (deployment {dep['id']}, environment {ENVIRONMENT})")


def tags():
    make, warn = plan(builds(fetch_deployments(os.environ["GITHUB_REPOSITORY"])), local_tags())
    for w in warn:
        print(f"::warning::{w}")
    for tag, sha in make:
        subprocess.run(["git", "tag", tag, sha], check=True)
    print(f"{len(make)} recorded build(s) tagged in this clone" + (f": {', '.join(t for t, _ in make)}" if make else ""))


def jobs(text):
    """{job id: block} of a workflow, as written (two-space job ids under `jobs:`)."""
    body = text.split("\njobs:\n", 1)[1] if "\njobs:\n" in text else ""
    out, job = {}, None
    for line in body.splitlines(keepends=True):
        m = re.match(r"  ([\w-]+):\s*$", line)
        if m:
            job = m.group(1)
            out[job] = ""
        elif job and not re.match(r"\S", line):
            out[job] += line
        else:
            job = None
    return out


def permissions(block):
    m = re.search(r"^    permissions:\n((?:      .*\n)+)", block, re.M)
    return dict(re.findall(r"^      ([\w-]+): (\w+)", m.group(1), re.M)) if m else {}


def check_workflows(testflight, screenshots, others=()):
    """Problems with how the workflows record and read published builds; empty when right.

    others: (name, text) of any other workflow that may read them (changelog.yml's What to Test preview)."""
    bad = []
    if "git/refs" in testflight or "git push" in testflight:
        bad.append("testflight.yml writes a ref; GitHub refuses GITHUB_TOKEN a tag at a commit whose workflows differ")
    tf = jobs(testflight)
    rec = [j for j, b in tf.items() if "ci-testflight-builds.py record" in b]
    if len(rec) != 1:
        bad.append(f"testflight.yml records the published build in {len(rec)} jobs, not 1")
    else:
        b = tf[rec[0]]
        if f"name: {RECORD_JOB}\n" not in b:
            bad.append(f"the recording job is not named {RECORD_JOB!r}")
        if permissions(b) != {"contents": "read", "deployments": "write"}:
            bad.append(f"the recording job's permissions are {permissions(b)}, not exactly contents: read, deployments: write")
    if f'startswith("{RECORD_JOB}")' not in screenshots:
        bad.append("screenshots.yml does not find a published build by the recording job's name")
    for name, text in (("testflight.yml", testflight), ("screenshots.yml", screenshots), *others):
        for job, b in jobs(text).items():
            uses = [b.find(r) for r in READERS if r in b]
            if not uses:
                continue
            at = b.find("ci-testflight-builds.py") if "ci-testflight-builds.py tags" in b else -1
            if at < 0 or at > min(uses):
                bad.append(f"{name} job {job} reads testflight/build-N tags without first running ci-testflight-builds.py tags")
            if permissions(b).get("deployments") not in ("read", "write"):
                bad.append(f"{name} job {job} reads recorded builds without deployments: read")
    return bad


def selftest():
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append(f"{name}: got {got!r}, want {want!r}")

    a, b, c = "a" * 40, "b" * 40, "c" * 40
    dep = lambda build, sha, task=TASK: {"task": task, "sha": sha, "payload": {"build": build}}
    check("builds: payload object", builds([dep(68, a)]), [(68, a)])
    check("builds: payload string", builds([{"task": TASK, "sha": a, "payload": '{"build": 68}'}]), [(68, a)])
    check("builds: other task skipped", builds([dep(68, a, "deploy")]), [])
    check("builds: no number skipped", builds([{"task": TASK, "sha": a, "payload": {}}, dep("68", a), dep(0, a)]), [])
    check("builds: short sha skipped", builds([dep(68, "abc1234")]), [])
    check("builds: bad payload string skipped", builds([{"task": TASK, "sha": a, "payload": "{"}]), [])
    check("plan: new build tagged", plan([(68, a)], {}), ([("testflight/build-68", a)], []))
    check("plan: already tagged here", plan([(68, a)], {"testflight/build-68": a}), ([], []))
    mk, w = plan([(66, b)], {"testflight/build-66": a})
    check("plan: a tag on GitHub wins", mk, [])
    check("plan: and says so", len(w), 1)
    mk, w = plan([(68, b), (68, a)], {})
    check("plan: the newest record of a number wins", mk, [("testflight/build-68", b)])
    check("plan: and says so twice-recorded", len(w), 1)
    check("plan: same record twice is quiet", plan([(68, a), (68, a)], {}), ([("testflight/build-68", a)], []))
    check("plan: several", plan([(69, c), (68, b)], {"testflight/build-67": a})[0],
          [("testflight/build-69", c), ("testflight/build-68", b)])
    body = deployment_body("68", a)
    check("body: names the commit, no ref", (body["ref"], body["environment"], body["task"], body["payload"]),
          (a, ENVIRONMENT, TASK, {"build": 68}))
    check("body: no merge, no required checks", (body["auto_merge"], body["required_contexts"]), (False, []))
    for build, sha in (("", a), ("6x", a), ("0", a), ("68", "abc1234"), ("68", "")):
        try:
            deployment_body(build, sha)
            fails.append(f"body: accepted build {build!r} at {sha!r}")
        except ValueError:
            pass

    good_tf = f"""name: T
jobs:
  gate:
    permissions:
      contents: read
      deployments: read
    steps:
      - run: python3 -I scripts/ci-testflight-builds.py tags
      - run: git tag --list 'testflight/build-*' --contains x
  publish:
    permissions:
      deployments: read
    steps:
      - run: python3 -I "$RUNNER_TEMP"/ci-testflight-builds.py tags
      - run: python3 -I scripts/changelog.py assemble --head x
  record:
    name: {RECORD_JOB}
    permissions:
      contents: read
      deployments: write
    steps:
      - run: python3 -I scripts/ci-testflight-builds.py record
"""
    good_ss = f"""name: S
jobs:
  shots:
    permissions:
      deployments: read
    steps:
      - run: x=startswith("{RECORD_JOB}"); python3 -I scripts/ci-testflight-builds.py tags; git tag --list 'testflight/build-*'
"""
    check("workflows: right", check_workflows(good_tf, good_ss), [])
    check("workflows: a tag write is caught", len(check_workflows(good_tf + "      - run: gh api repos/r/git/refs\n", good_ss)), 1)
    check("workflows: contents write on the recorder is caught",
          len(check_workflows(good_tf.replace("      contents: read\n      deployments: write\n", "      contents: write\n      deployments: write\n"), good_ss)), 1)
    check("workflows: a reader without tags first is caught",
          len(check_workflows(good_tf.replace("      - run: python3 -I scripts/ci-testflight-builds.py tags\n", ""), good_ss)), 1)
    check("workflows: tags after the read is caught",
          len(check_workflows(good_tf, good_ss.replace("python3 -I scripts/ci-testflight-builds.py tags; git tag --list 'testflight/build-*'",
                                                       "git tag --list 'testflight/build-*'; python3 -I scripts/ci-testflight-builds.py tags"))), 1)
    check("workflows: a reader without deployments: read is caught",
          len(check_workflows(good_tf.replace("    permissions:\n      deployments: read\n", "    permissions:\n      contents: read\n"), good_ss)), 1)
    check("workflows: screenshots on the old job name is caught",
          len(check_workflows(good_tf, good_ss.replace(RECORD_JOB, "Tag the published commit"))), 1)
    other = ("other.yml", "name: O\njobs:\n  preview:\n    steps:\n      - run: python3 -I scripts/changelog.py assemble --head x\n")
    check("workflows: another workflow's reader is caught", len(check_workflows(good_tf, good_ss, [other])), 2)
    check("workflows: renamed recorder is caught", len(check_workflows(good_tf.replace(f"name: {RECORD_JOB}", "name: X"), good_ss)), 1)

    here = os.path.dirname(os.path.abspath(__file__))
    wf = os.path.join(here, "..", ".github", "workflows")
    texts = {}
    for f in sorted(os.listdir(wf)):
        if f.endswith((".yml", ".yaml")):
            with open(os.path.join(wf, f)) as fh:
                texts[f] = fh.read()
    others = [(f, t) for f, t in texts.items() if f not in ("testflight.yml", "screenshots.yml")]
    for problem in check_workflows(texts["testflight.yml"], texts["screenshots.yml"], others):
        fails.append(f"workflows as written: {problem}")

    for f in fails:
        print(f"FAIL {f}")
    print(f"ci-testflight-builds selftest: {'FAILED' if fails else 'ok'}")
    return 1 if fails else 0


if __name__ == "__main__":
    mode = sys.argv[1:]
    if mode == ["--selftest"]:
        sys.exit(selftest())
    if mode == ["record"]:
        record()
    elif mode == ["tags"]:
        tags()
    elif mode == ["list"]:
        for build, sha in builds(fetch_deployments(os.environ.get("GITHUB_REPOSITORY", "ourostack/gatefold"))):
            print(f"{TAG.format(build)} {sha}")
    else:
        sys.exit(__doc__)
