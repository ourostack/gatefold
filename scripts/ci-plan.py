#!/usr/bin/env python3
"""What a pull request's run tests: the plan the `changes` job in app.yml writes to its outputs.

    python3 -I scripts/ci-plan.py --base SHA --head SHA --expect N   # a pull request; N is the PR's changed_files
    python3 -I scripts/ci-plan.py --event merge_group                 # anything else: everything
    python3 -I scripts/ci-plan.py --selftest

Test once, fail closed. The merge queue, main and dispatch always run everything; they are the gate and the safety net.
A pull request runs only what its files can affect, by the table below, file by file:

  - Markdown, changelog fragments, docs and other tools ("not affected"): nothing of the app runs. Each required check
    still reports, passing as "not affected", which only this plan can say.
  - The CI that builds, boots or runs the app's tests (app.yml, ui-tests.yml, .github/actions, .github/scripts, this
    plan, and every file they name outside the job "CI scripts, offline", such as scripts/ci-shards.expect):
    everything.
  - A file only "CI scripts, offline" names (its scripts and what they name in turn, such as scripts/ci-lanes.py or
    testflight.yml): that job and GatefoldCore tests, on Linux; no macOS job. A file both name runs everything.
  - Any other script under scripts/: the offline job too, on Linux, since a script can reach another in ways no scan
    sees; screenshots, cloud and changelog scripts are "not affected" (their own workflows test them).
  - What everything builds on (project.yml, the Xcode project, Package.*, Gatefold/Resources, Gatefold/Support):
    everything.
  - App sources: the build, Release build, unit tests and the iPad and Duo smoke, plus the guards their paths fire
    (`place-undo`, `place-jumps`, `taps`; the lists are the Gatefold agent's).
  - Unit tests only: the build, Release build and unit tests, no UI shard.
  - A UI test class: it runs in the smoke shard of each device main runs it on (the iPad when main runs it nowhere
    yet). A UI test file with no test class (a helper every test uses): everything.
  - Anything the table doesn't name: everything.

A change the plan can't see fails the run instead of passing: when the diff can't be read, is empty, or lists another
number of files than the pull request has, this exits 1 with an error, and every required check in app.yml fails on a
`changes` that didn't succeed. Nothing is skipped as a pass on a guess.
"""
import argparse
import json
import os
import re
import subprocess
import sys

NOT_AFFECTED = re.compile(r"(\.md$|^changelog\.d/|^docs/|^distribution/|^tools/|^screenshots/|^scripts/screenshots/"
                          r"|^\.gitignore$|^\.github/(workflows/(?!(app|ui-tests)\.yml$)[^/]+|required-checks\.txt"
                          r"|CODEOWNERS)$|^actions/(?!generated/)"
                          r"|^scripts/(cloud-[^/]+|ouro-actions\.sh|changelog\.py|(package|release)-testflight[^/]*)$)")
CI = re.compile(r"^(\.github/(scripts|actions)/|\.github/workflows/(app|ui-tests)\.yml$|scripts/ci-plan\.py$)")
SCRIPTS = re.compile(r"^scripts/")  # one no macOS job names can't change what they run; the offline job still runs
SHARED = re.compile(r"^(project\.yml|Gatefold\.xcodeproj/|Package\.(swift|resolved)$|Gatefold/(Resources|Support)/)")
APP = re.compile(r"^(Gatefold/(App|Design|Duo|Library|Reader|Sync|Welcome)/|Packages/(GatefoldCore|GatefoldCloud)/"
                 r"|actions/generated/|GatefoldListingShots/)")
UNIT = re.compile(r"^GatefoldTests/")
UI_TEST = re.compile(r"^GatefoldUITests/[^/]+\.swift$")
PLACE = re.compile(r"^(Gatefold/Reader/(ReaderModel|ReaderHostController|ReaderScreen|LandingPlace|BookPositions"
                   r"|ReopenSnapshot|BookOpener|ReaderPage|ReaderJS|Highlights)\.swift$|Packages/GatefoldCore/)")
TAPS = re.compile(r"^(Gatefold/Reader/(ReaderChrome|CurlOverlay|ReaderMoments|ReaderSheets|SettingsPanel|ReaderScreen)"
                  r"\.swift$|Gatefold/Reader/PageCurl\.metal$|Gatefold/Design/)")
GUARDS = ["smoke", "place-undo", "place-jumps", "taps"]
IPAD, DUO = "iPad Pro 13-inch", "iPhone Duo"
FALLBACK_SMOKE = 180  # minutes, when the shards' formula can't say (as before)


class Hidden(Exception):
    """The plan can't see the whole change: the run must fail, not pass."""


def everything(reason):
    return {"app": "true", "full": "true", "offline": "true", "fired": "", "edited-ipad": "", "edited-duo": "",
            "smoke-ipad": "0", "smoke-duo": "0", "reason": reason}


def plan(files, expect, ci_named, classes_of, on_main, smoke, offline_named=frozenset()):
    """The outputs for a pull request with `files` changed (both paths of a rename), `expect` files by GitHub's count.

    ci_named: paths the CI that builds, boots or runs the app's tests names (a change to one runs everything).
    offline_named: paths only the job "CI scripts, offline" names (a change to one runs that job, on Linux).
    classes_of(path): the XCTestCase classes a UI test file declares, or None when it is gone.
    on_main: {(device, class)} main runs. smoke(device, classes) -> minutes, or None.
    """
    if not files:
        raise Hidden("the diff lists no files")
    if expect is not None and len(files) < expect:
        raise Hidden(f"the diff lists {len(files)} files but the pull request changes {expect}")
    full, app, offline, fired, ipad, duo, why = False, False, False, set(), [], [], []
    for f in files:
        if CI.match(f) or f in ci_named:
            full = True
            why.append(f"{f} is the CI that runs the app's tests")
        elif f in offline_named or SCRIPTS.match(f) and not NOT_AFFECTED.search(f):
            offline = True
        elif NOT_AFFECTED.search(f):
            continue
        elif SHARED.match(f):
            full = True
            why.append(f"everything builds on {f}")
        elif UNIT.match(f):
            app = True
        elif UI_TEST.match(f):
            app = True
            fired.add("smoke")
            classes = classes_of(f)
            if classes is None:
                continue  # deleted: shards-check fails on a listed test that no longer exists
            if not classes:
                full = True
                why.append(f"{f} has no test class, so every test uses it")
            for c in classes:
                on_ipad, on_duo = (IPAD, c) in on_main, (DUO, c) in on_main
                if on_ipad or not on_duo:
                    ipad.append(c)
                if on_duo:
                    duo.append(c)
        elif APP.match(f):
            app = True
            fired.add("smoke")
            if PLACE.match(f) or f.startswith("Gatefold/App/"):
                fired.add("place-undo")
            if PLACE.match(f):
                fired.add("place-jumps")
            if TAPS.match(f):
                fired.add("taps")
        else:
            full = True
            why.append(f"the plan doesn't map {f}")
    if full:
        return everything("; ".join(why))
    if not app:
        return {**everything("only the CI scripts' offline tests can see this change" if offline else
                             "no file this change touches builds into the app or runs its tests"),
                "app": "false", "full": "false", "offline": str(offline).lower()}
    ipad, duo = sorted(set(ipad)), sorted(set(duo))
    s_ipad, s_duo = smoke(IPAD, ipad), smoke(DUO, duo)
    return {"app": "true", "full": "false", "offline": "true", "fired": " ".join(g for g in GUARDS if g in fired),
            "edited-ipad": " ".join(ipad), "edited-duo": " ".join(duo),
            "smoke-ipad": str(FALLBACK_SMOKE if s_ipad is None else s_ipad),
            "smoke-duo": str(FALLBACK_SMOKE if s_duo is None else s_duo),
            "reason": "guards for this change: " + (" ".join(g for g in GUARDS if g in fired) or "none")}


# The repository, for the real run.

def changed(base, head):
    out = subprocess.run(["git", "diff", "--name-status", "-M", f"{base}...{head}"], capture_output=True, text=True)
    if out.returncode:
        raise Hidden(f"git diff failed: {out.stderr.strip()}")
    files, entries = [], 0
    for line in out.stdout.splitlines():
        parts = line.split("\t")
        entries += 1
        files.extend(parts[1:])  # a rename names both paths; both count for the plan
    return files, entries


NAME = re.compile(r"(?<![\w./-])((?:scripts|\.github)/[\w./-]*\w)")


def code(text):
    """The text without comment lines and Python docstrings: a file a comment mentions isn't one the code uses."""
    text = re.sub(r'(?s)"""(?:.*?)"""', "", text)
    return "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))


def closure(texts, read=()):
    """Every file the texts' code names, and every file those name in turn; `read` are the files the texts are."""
    todo, seen = [n for t in texts for n in names(code(t))], set(read)
    while todo:
        f = todo.pop()
        if f in seen or not os.path.isfile(f):
            continue
        seen.add(f)
        text = open(f, errors="replace").read()
        if f == "scripts/ci-plan.py":  # its selftest names paths only as examples
            text = text[:text.index("\ndef selftest():")] + text[text.index("\ndef main(argv):"):]
        todo += names(code(text))
    return seen


def names(text):
    """The paths a text names: whole paths, and bare file names from scripts/ and .github/scripts/ (a script calls
    its neighbour as "$here/name")."""
    found = NAME.findall(text)
    for d in ("scripts", ".github/scripts"):
        if os.path.isdir(d):
            found += [f"{d}/{n}" for n in os.listdir(d) if n in text and os.path.isfile(f"{d}/{n}")]
    return found


def ci_named():
    """(files the CI that builds, boots or runs the tests names, files only "CI scripts, offline" names)."""
    app = open(".github/workflows/app.yml").read()
    start = app.index("\n  ci-scripts:\n")
    end = re.compile(r"\n  [a-z0-9-]+:\n").search(app, start + 1)
    offline_job = app[start:end.start()] if end else app[start:]
    texts = [app.replace(offline_job, ""), open(".github/workflows/ui-tests.yml").read()]
    texts += [open(f".github/actions/{d}/action.yml").read() for d in sorted(os.listdir(".github/actions"))
              if os.path.isfile(f".github/actions/{d}/action.yml")]
    whole = {".github/workflows/app.yml", ".github/workflows/ui-tests.yml"}
    runs = closure(texts + ["scripts/ci-plan.py"], whole) | whole
    return runs, closure([offline_job], whole) - runs


def classes_of(path):
    if not os.path.exists(path):
        return None
    return re.findall(r"class (\w+)\s*:\s*XCTestCase", open(path).read())


def on_main():
    run = subprocess.run([sys.executable, "-I", "scripts/ci-shards.py", "check", "--list"], capture_output=True,
                         text=True)
    if run.returncode:
        raise Hidden(f"scripts/ci-shards.py check --list failed: {run.stderr.strip()[-300:]}")
    out = run.stdout
    pairs = set()
    for line in out.splitlines():
        parts = line.split("\t")[0].split("|")
        if len(parts) != 3:
            continue  # the check's summary lines
        tier, device, test = parts
        if tier == "main":
            pairs.add((device, test.split("/")[0]))
    return pairs


def smoke(device, classes):
    out = subprocess.run([sys.executable, "-I", "scripts/ci-shards.py", "smoke", device, *classes],
                         capture_output=True, text=True)
    return int(out.stdout.strip()) if out.returncode == 0 and out.stdout.strip().isdigit() else None


def selftest():
    named = {"scripts/ci-crashes.sh", "scripts/ci-proof.py", "scripts/test-ci-simulator.sh",
             "scripts/ci-shards.expect"}
    on = {(IPAD, "NavigationPlaceUITests"), (DUO, "DuoTourUITests"), (IPAD, "BothUITests"), (DUO, "BothUITests")}
    sources = {"GatefoldUITests/NavigationPlaceUITests.swift": ["NavigationPlaceUITests"],
               "GatefoldUITests/DuoTourUITests.swift": ["DuoTourUITests"],
               "GatefoldUITests/BothUITests.swift": ["BothUITests"],
               "GatefoldUITests/NewUITests.swift": ["NewUITests"],
               "GatefoldUITests/UITestHelpers.swift": []}

    def run(files, expect=None):
        return plan(files, len(files) if expect is None else expect, named, sources.get, on,
                    lambda d, cs: 20 + 10 * len(cs), {"scripts/ci-lanes.py", ".github/workflows/testflight.yml"})

    def check(name, files, **want):
        got = run(files)
        bad = {k: (got[k], v) for k, v in want.items() if got[k] != v}
        assert not bad, f"{name}: {bad} (got {got})"

    def hidden(name, files, expect):
        try:
            run(files, expect)
        except Hidden:
            return
        raise AssertionError(f"{name}: the plan passed a change it can't see")

    cases = [
        ("Markdown and a changelog fragment: not affected, nothing of the app runs",
         ["README.md", "changelog.d/x.md"], dict(app="false", full="false", fired="")),
        ("another workflow and docs: not affected", [".github/workflows/stuck-runs.yml", "docs/shots/a.png"],
         dict(app="false", full="false")),
        ("app.yml: everything", [".github/workflows/app.yml"], dict(app="true", full="true")),
        ("a CI script: everything", ["scripts/ci-proof.py"], dict(full="true")),
        ("a CI test script: everything", ["scripts/test-ci-simulator.sh"], dict(full="true")),
        ("a composite action: everything", [".github/actions/await-build/action.yml"], dict(full="true")),
        ("a file app.yml names: everything", ["scripts/ci-crashes.sh"], dict(full="true")),
        ("the shard lists: everything", ["scripts/ci-shards.expect"], dict(full="true")),
        ("this plan: everything", ["scripts/ci-plan.py"], dict(full="true")),
        ("a CI script no macOS job names: the offline job only", ["scripts/ci-stuck.py"],
         dict(app="false", full="false", offline="true")),
        ("a cloud script: not affected", ["scripts/cloud-canary.py"], dict(app="false", offline="false")),
        ("a script only the offline job tests: that job, no macOS job", ["scripts/ci-lanes.py"],
         dict(app="false", full="false", offline="true")),
        ("a workflow only the offline job reads: that job", [".github/workflows/testflight.yml"],
         dict(app="false", offline="true")),
        ("an offline script beside an app file: the app's plan, offline included", ["scripts/ci-lanes.py",
         "Gatefold/Library/Shelf.swift"], dict(app="true", full="false", offline="true", fired="smoke")),
        ("Markdown only: nothing, not even the offline job", ["README.md"], dict(offline="false")),
        ("the actions' source (its own workflow checks it): not affected", ["actions/gatefold.actions.mts"],
         dict(app="false")),
        ("the actions' generated Swift builds into the app", ["actions/generated/OuroActions.swift"],
         dict(app="true", fired="smoke")),
        ("project.yml: everything", ["project.yml"], dict(full="true")),
        ("a resource: everything", ["Gatefold/Resources/Base.lproj/Main.strings"], dict(full="true")),
        ("an unmapped file: everything", ["Gatefold/NewArea/Thing.swift"], dict(full="true")),
        ("an unmapped top-level file: everything", ["Makefile"], dict(full="true")),
        ("a Markdown file beside a CI change still runs everything", ["a.md", ".github/workflows/ui-tests.yml"],
         dict(full="true")),
        ("a library file: the smoke only", ["Gatefold/Library/Shelf.swift"],
         dict(app="true", full="false", fired="smoke")),
        ("the reader model: the place guards", ["Gatefold/Reader/ReaderModel.swift"],
         dict(full="false", fired="smoke place-undo place-jumps")),
        ("the reader screen: place and taps", ["Gatefold/Reader/ReaderScreen.swift"],
         dict(fired="smoke place-undo place-jumps taps")),
        ("GatefoldCore: the place guards", ["Packages/GatefoldCore/Sources/X.swift"],
         dict(fired="smoke place-undo place-jumps")),
        ("the app shell: undo", ["Gatefold/App/GatefoldApp.swift"], dict(fired="smoke place-undo")),
        ("the design system: taps", ["Gatefold/Design/Tokens.swift"], dict(fired="smoke taps")),
        ("unit tests only: the app checks, no UI guard", ["GatefoldTests/ReaderModelTests.swift"],
         dict(app="true", full="false", fired="")),
        ("an iPad test class: in the iPad smoke", ["GatefoldUITests/NavigationPlaceUITests.swift"],
         dict(full="false", fired="smoke", **{"edited-ipad": "NavigationPlaceUITests", "edited-duo": "",
                                              "smoke-ipad": "30", "smoke-duo": "20"})),
        ("a Duo test class: in the Duo smoke", ["GatefoldUITests/DuoTourUITests.swift"],
         dict(**{"edited-ipad": "", "edited-duo": "DuoTourUITests"})),
        ("a class on both: both smokes", ["GatefoldUITests/BothUITests.swift"],
         dict(**{"edited-ipad": "BothUITests", "edited-duo": "BothUITests"})),
        ("a new class main runs nowhere: the iPad smoke", ["GatefoldUITests/NewUITests.swift"],
         dict(**{"edited-ipad": "NewUITests", "edited-duo": ""})),
        ("a UI test helper: everything", ["GatefoldUITests/UITestHelpers.swift"], dict(full="true")),
        ("a UI test resource: everything (unmapped)", ["GatefoldUITests/Fixtures/book.epub"], dict(full="true")),
    ]
    for name, files, want in cases:
        check(name, files, **want)
    hiddens = [
        ("an empty diff fails the run, never passes as not affected", [], 3),
        ("a diff with fewer files than the pull request fails the run", ["README.md"], 4),
        ("a diff that sees only the harmless half of a change fails the run", ["docs/a.md"], 2),
    ]
    for name, files, expect in hiddens:
        hidden(name, files, expect)
    print(f"ci-plan selftest: {len(cases) + len(hiddens)} cases pass")


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("--selftest", action="store_true")
    p.add_argument("--event", default="pull_request")
    p.add_argument("--base")
    p.add_argument("--head")
    p.add_argument("--expect", type=int)
    a = p.parse_args(argv)
    if a.selftest:
        selftest()
        return 0
    try:
        if a.event != "pull_request":
            out = everything(f"a {a.event} run tests everything")
        else:
            files, entries = changed(a.base, a.head)
            print("\n".join(files))
            if a.expect is not None and entries != a.expect:
                raise Hidden(f"the diff lists {entries} files but the pull request changes {a.expect}")
            runs, offline = ci_named()
            out = plan(files, None, runs, classes_of, on_main(), smoke, offline)
    except Hidden as e:
        print(f"::error title=The plan can't see this change::{e}, so nothing is skipped as a pass: every required "
              "check fails. Rerun once the pull request's diff is readable (scripts/ci-plan.py).")
        return 1
    print(f"::notice title=Plan::{out['reason']}")
    with open(os.environ.get("GITHUB_OUTPUT", os.devnull), "a") as gh:
        for k, v in out.items():
            gh.write(f"{k}={v}\n")
    print(json.dumps(out, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
