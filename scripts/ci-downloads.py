"""Checks that every job that unpacks the downloaded build checks it whole first and can download it again.

    python3 -I scripts/ci-downloads.py check
    python3 -I scripts/ci-downloads.py --selftest

A download can report success and still end truncated: "truncated gzip input" at the unpack (gatefold#89; again
on gatefold#639, Screenshots' Shots (ipad), job 140775676796). So before a job unpacks products.tgz it must
  - test the archive with `gzip -t` in a step with `id: whole` and `continue-on-error: true`, and
  - download it again in a later step whose `if:` reads `steps.whole.outcome != 'success'`,
both before the unpack. A bad transfer then costs one more download, not the job.
Reads only; no dependencies beyond python3. It runs in the job `CI scripts, offline`.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORKFLOWS = os.path.join(ROOT, ".github", "workflows")
UNPACK = re.compile(r"tar -x[a-z]*f \"\$RUNNER_TEMP/products\.tgz\"")
TEST = re.compile(r"gzip -t \"\$RUNNER_TEMP/products\.tgz\"")


def jobs(text):
    """[(name, block)] for each job under `jobs:`."""
    out, name, block, inside = [], None, [], False
    for line in text.splitlines():
        if re.match(r"^jobs:\s*$", line):
            inside = True
            continue
        if inside and re.match(r"^\S", line):
            inside = False
        if not inside:
            continue
        m = re.match(r"^  ([A-Za-z0-9_-]+):\s*$", line)
        if m:
            if name:
                out.append((name, "\n".join(block)))
            name, block = m.group(1), []
        elif name:
            block.append(line)
    if name:
        out.append((name, "\n".join(block)))
    return out


def steps(block):
    """Each step's text, in order, with comment lines dropped."""
    lines = [l for l in block.splitlines() if not re.match(r"^\s*#", l)]
    out, cur = [], None
    for line in lines:
        if re.match(r"^      - ", line):
            if cur is not None:
                out.append("\n".join(cur))
            cur = [line]
        elif cur is not None:
            if re.match(r"^ {0,5}\S", line):
                out.append("\n".join(cur))
                cur = None
            else:
                cur.append(line)
    if cur is not None:
        out.append("\n".join(cur))
    return out


def check(files):
    """files: {filename: text}. Returns a list of errors."""
    errors = []
    for fname in sorted(files):
        for job, block in jobs(files[fname]):
            whole = again = False
            for step in steps(block):
                if UNPACK.search(step):
                    if not whole:
                        errors.append(f"{fname}: {job}: unpacks products.tgz without first testing it "
                                      "(`gzip -t` in a step with `id: whole` and `continue-on-error: true`)")
                    elif not again:
                        errors.append(f"{fname}: {job}: unpacks products.tgz with no download again for a "
                                      "truncated one (`if: ... steps.whole.outcome != 'success'`)")
                    whole = again = False
                    continue
                if (TEST.search(step) and re.search(r"^        id: whole\s*$|^      - id: whole\s*$", step, re.M)
                        and re.search(r"^        continue-on-error: true\s*$", step, re.M)):
                    whole, again = True, False
                elif (whole and "uses: actions/download-artifact@" in step
                      and re.search(r"^        if: .*steps\.whole\.outcome != 'success'", step, re.M)):
                    again = True
    return errors


def read():
    return {n: open(os.path.join(WORKFLOWS, n), encoding="utf-8").read()
            for n in os.listdir(WORKFLOWS) if n.endswith((".yml", ".yaml"))}


GOOD = """jobs:
  shots:
    runs-on: xcode-27
    steps:
      - id: fetch
        uses: actions/download-artifact@v4
        continue-on-error: true
        with:
          name: build
      - id: whole
        # A download can end truncated.
        name: The download is whole (gzip -t)
        if: steps.fetch.outcome == 'success'
        continue-on-error: true
        run: gzip -t "$RUNNER_TEMP/products.tgz"
      - name: Download the build again
        if: steps.fetch.outcome != 'success' || steps.whole.outcome != 'success'
        uses: actions/download-artifact@v4
        with:
          name: build
      - name: Unpack
        run: |
          set -eu
          tar -xzf "$RUNNER_TEMP/products.tgz" -C "$RUNNER_TEMP/dd/Build"
"""
NO_CHECK = """jobs:
  shots:
    runs-on: xcode-27
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: build
      - name: Unpack
        run: |
          tar -xzf "$RUNNER_TEMP/products.tgz" -C "$RUNNER_TEMP/dd/Build"
"""


def selftest():
    retry = GOOD.split("      - name: Download the build again\n")[1].split("      - name: Unpack\n")[0]
    cases = {
        "good": ({"a.yml": GOOD}, None),
        "no check": ({"a.yml": NO_CHECK}, "without first testing it"),
        "no download again": ({"a.yml": GOOD.replace("      - name: Download the build again\n" + retry, "")},
                              "no download again"),
        "check can fail the job": ({"a.yml": GOOD.replace("        continue-on-error: true\n        run: gzip", "        run: gzip")},
                                   "without first testing it"),
        "check without its id": ({"a.yml": GOOD.replace("      - id: whole\n", "      - id: test\n")},
                                 "without first testing it"),
        "download again ignores the check": ({"a.yml": GOOD.replace(" || steps.whole.outcome != 'success'", "")},
                                             "no download again"),
        "check after the unpack": ({"a.yml": GOOD.replace("      - id: whole\n", "      - name: Early\n        run: tar -xzf \"$RUNNER_TEMP/products.tgz\"\n      - id: whole\n")},
                                   "without first testing it"),
        "commented check": ({"a.yml": GOOD.replace("        run: gzip -t", "        # run: gzip -t")}, "without first testing it"),
        "each job checks its own": ({"a.yml": GOOD + NO_CHECK.replace("jobs:\n  shots:", "  other:")}, "a.yml: other:"),
        "packing is fine": ({"a.yml": "jobs:\n  build:\n    steps:\n      - run: tar -czf \"$RUNNER_TEMP/products.tgz\" Products\n"}, None),
        "no products": ({"a.yml": "jobs:\n  x:\n    steps:\n      - run: tar -xzf other.tgz\n"}, None),
    }
    failed = 0
    for name, (files, want) in cases.items():
        errs = check(files)
        ok = (not errs) if want is None else any(want in e for e in errs)
        print(("ok   " if ok else "FAIL ") + name + ("" if ok else f": {errs}"))
        failed += not ok
    print(f"{failed} failed")
    return 1 if failed else 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:] == ["check"]:
        errors = check(read())
        for e in errors:
            print(f"::error::{e}")
        if not errors:
            print("Every job that unpacks the downloaded build tests it whole first and downloads it again if not")
        return 1 if errors else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
