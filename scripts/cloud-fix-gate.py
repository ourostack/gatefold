#!/usr/bin/env python3
"""CI only: the live gate on a cloud fix (gatefold#372).

    python3 -I scripts/cloud-fix-gate.py verdict --exit <swift test status> --log <canary log>
    python3 -I scripts/cloud-fix-gate.py --selftest

A pull request labelled `cloud-drift-fix` (one a coding agent opened for a cloud-drift issue) must
pass the live canary on its own code, not only the fake-cloud CI, before it merges. cloud-fix-gate.yml
runs LiveCanaryTests on the pull request's head and this turns the result into the commit status
`Live cloud canary`:

- success: the test passed (a known issue that still happens is a pass). The gate labels the pull
  request `live-canary-passed`; the agent that opened it turns on auto-merge only then.
- failure: a step failed, so the fix doesn't work against the real cloud.
- error: the cloud's login limit (429) stopped sign-in, or the test never ran. Nothing was learned;
  the gate can be run again later. Never a pass.

Prints `<state>\t<description>` (a status description, at most 140 characters).
"""
import sys


def verdict(status, log):
    lines = [l for l in log.splitlines() if "CANARY " in l]
    if any("INCONCLUSIVE" in l for l in lines):
        return "error", "Inconclusive: the cloud's login limit stopped sign-in; run the gate again later"
    if not lines:
        return "error", "The canary never ran (build or runner failure)"
    failed = [l.split("CANARY ", 1)[1] for l in lines if "FAILED" in l]
    if status == 0:
        return "success", f"Live canary passed on this code ({len(lines)} steps)"
    first = failed[0] if failed else "the test failed"
    return "failure", ("Live canary failed: " + first)[:140]


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def selftest():
    ok = "LIVE CANARY sign-in: store lookup ok\nLIVE CANARY library ok\n"
    assert verdict(0, ok)[0] == "success"
    # A known issue still happening passes (the test passes); its line says KNOWN, or FAILED before #377.
    assert verdict(0, ok + "LIVE CANARY position write: lands KNOWN: refused\n")[0] == "success"
    assert verdict(0, ok + "LIVE CANARY position write: lands FAILED: refused\n")[0] == "success"
    state, text = verdict(1, ok + "LIVE CANARY download: size matches the listing FAILED: listed 10 bytes, got 9\n")
    assert state == "failure" and "size matches" in text and len(text) <= 140, text
    assert verdict(0, "LIVE CANARY INCONCLUSIVE sign-in rate-limited retry-after=unknown\n")[0] == "error"
    assert verdict(1, "error: build failed\n")[0] == "error"
    assert verdict(1, ok)[0] == "failure"
    print("cloud-fix-gate selftest ok")
    return 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        return selftest()
    if argv[:1] == ["verdict"]:
        log_path = arg(argv, "--log")
        try:
            log = open(log_path, encoding="utf-8", errors="replace").read()
        except OSError:
            log = ""
        state, text = verdict(int(arg(argv, "--exit", "1")), log)
        print(f"{state}\t{text}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
