#!/usr/bin/env python3
"""Checks that what Gatefold tells Apple and its readers about privacy matches what the app does.

    python3 -I scripts/store-readiness.py check      # this checkout
    python3 -I scripts/store-readiness.py --selftest

App Review rejects an app whose privacy manifest misses a required-reason API (ITMS-91053), and a privacy label or
policy that says less than the app does breaks Guideline 5.1.1 and 5.1.2. Each rule below reads the source, so a
change to what the app touches fails here, on Linux, before it reaches a build:

  - Gatefold/Support/PrivacyInfo.xcprivacy exists, says no tracking, and is copied into the app: project.yml's app
    target takes all of Gatefold/ and excludes no .xcprivacy (xcodegen puts it in Resources; checked with 2.46.0), and
    a generated project.pbxproj, where there is one, has it in Resources.
  - Every required-reason API the app's own code calls, and those its linked packages call without shipping their
    own manifest (UNMANIFESTED_PACKAGES), is declared with a reason Apple accepts for that category.
  - When the app sends telemetry (TELEMETRY_MARKERS in its code), the manifest declares the data it sends, none of it
    linked to the person or used for tracking, the privacy page says so and no longer says it collects nothing, and
    distribution/apple-distribution.json says data is collected and points at that page.
"""

from __future__ import annotations

import json
import plistlib
import re
import sys
import tempfile
from pathlib import Path

MANIFEST = "Gatefold/Support/PrivacyInfo.xcprivacy"
PBXPROJ = "Gatefold.xcodeproj/project.pbxproj"
PROJECT_YML = "project.yml"
PRIVACY_PAGE = "docs/privacy/index.html"
DISTRIBUTION = "distribution/apple-distribution.json"
PRIVACY_URL = "https://ourostack.github.io/gatefold/privacy/"
SOURCE_GLOBS = ["Gatefold/**/*.swift", "Packages/*/Sources/**/*.swift"]

# Apple's required-reason API categories: what in Swift reaches each, and the reasons that fit an app like this one.
# https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api
REQUIRED_REASON = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {
        "pattern": r"\bUserDefaults\b|@AppStorage\b",
        "reasons": {"CA92.1", "1C8F.1", "C56D.1", "AC6B.1"},
    },
    "NSPrivacyAccessedAPICategoryFileTimestamp": {
        "pattern": r"\b(creationDate|modificationDate|contentModificationDate\w*|creationDateKey|fileModificationDate|"
                   r"attributesOfItem|getattrlist\w*|fstatat|lstat|fstat)\b|[^\w.]stat\(",
        "reasons": {"C617.1", "3B52.1", "0A2A.1", "DDA9.1"},
    },
    "NSPrivacyAccessedAPICategorySystemBootTime": {
        "pattern": r"\b(systemUptime|mach_absolute_time)\b",
        "reasons": {"35F9.1", "8FFB.1", "3D61.1"},
    },
    "NSPrivacyAccessedAPICategoryDiskSpace": {
        "pattern": r"\b(volumeAvailableCapacity\w*|volumeTotalCapacity\w*|systemFreeSize|systemSize|statv?fs)\b",
        "reasons": {"85F4.1", "E174.1", "7D9E.1", "B728.1"},
    },
    "NSPrivacyAccessedAPICategoryActiveKeyboards": {
        "pattern": r"\bactiveInputModes\b",
        "reasons": {"3EC4.1", "54BD.1"},
    },
}

# Packages linked into the app that ship no PrivacyInfo.xcprivacy of their own, and the required-reason APIs their
# code calls, read from each one's source at the revision Package.resolved pins. Their calls are the app's to declare.
# (CryptoSwift, ZIPFoundation and SQLite.swift ship manifests; SwiftSoup, Fuzi and DifferenceKit call none of these.)
UNMANIFESTED_PACKAGES = {
    "NSPrivacyAccessedAPICategoryUserDefaults": "Readium Navigator (EPUBPreferences+Legacy.swift reads UserDefaults.standard)",
    "NSPrivacyAccessedAPICategoryFileTimestamp": "Zip, which Readium links (Zip.swift reads FileAttributeKey.modificationDate)",
}

# Code that sends anything off the device to us rather than to the reader's own PocketBook Cloud.
TELEMETRY_MARKERS = [r"posthog\.com"]

# Every event the app sends (`capture("gatefold_…"` in its code, plus the place events GatefoldTelemetry names) and
# the App Privacy data types it is. Every event also carries a random install ID (Apple's nearest kind is Device ID)
# and the app and iOS versions. None is linked to a person or used for tracking. A new event fails the check until it
# is listed here, in the manifest and on the privacy page.
TELEMETRY_EVENTS = {
    "gatefold_download": {"NSPrivacyCollectedDataTypeOtherDiagnosticData"},
    "gatefold_place_push": {"NSPrivacyCollectedDataTypeOtherDiagnosticData"},
    "gatefold_place_pull": {"NSPrivacyCollectedDataTypeOtherDiagnosticData"},
    "gatefold_download_tap": {"NSPrivacyCollectedDataTypeProductInteraction"},
    "gatefold_open": {"NSPrivacyCollectedDataTypePerformanceData"},
    "gatefold_jump": {"NSPrivacyCollectedDataTypePerformanceData"},
}
EVERY_EVENT = {"NSPrivacyCollectedDataTypeDeviceID"}
TELEMETRY_DATA = set().union(EVERY_EVENT, *TELEMETRY_EVENTS.values())
EVENT_NAME = r'"(gatefold_[a-z_]+)"'

# Sentences the privacy page may not carry while telemetry ships.
NOTHING_COLLECTED = [r"collects nothing", r"No analytics", r"We never see .*anything you do"]

# The signed-in session keeps the password in the Keychain to sign in again (GatefoldCloud's StoredSession), so the
# page may not say it is never stored.
KEPT_PASSWORD = r"\bvar password: String\?"
PASSWORD_NEVER_KEPT = r"password is never (stored|kept|saved)|never (store|keep|save)s? your password"


def sources(root: Path) -> list[Path]:
    out: list[Path] = []
    for glob in SOURCE_GLOBS:
        out += [p for p in root.glob(glob) if "/.build/" not in p.as_posix() and "Tests" not in p.parts[-2]]
    return sorted(set(out))


def read_sources(root: Path) -> str:
    return "\n".join(p.read_text(errors="replace") for p in sources(root))


def check(root: Path) -> list[str]:
    problems: list[str] = []
    manifest_path = root / MANIFEST
    if not manifest_path.is_file():
        return [f"{MANIFEST} is missing: App Store Connect refuses a build without a privacy manifest (ITMS-91053)."]
    try:
        manifest = plistlib.loads(manifest_path.read_bytes())
    except Exception as e:  # noqa: BLE001 - any parse failure is the finding
        return [f"{MANIFEST} is not a property list: {e}"]

    spec = (root / PROJECT_YML).read_text(errors="replace") if (root / PROJECT_YML).is_file() else ""
    app = spec.split("\n  Gatefold:\n", 1)[1].split("\n  Gatefold", 1)[0] if "\n  Gatefold:\n" in spec else ""
    excluded = re.findall(r"^ +excludes:\n((?:          - .*\n?)+)", app, re.M)
    if not re.search(r"- path: Gatefold\n", app) or any(re.search(r"xcprivacy|Support", e) for e in excluded):
        problems.append(f"{PROJECT_YML}: the Gatefold target must take Gatefold/ whole, so {MANIFEST} is a resource.")
    pbx = root / PBXPROJ
    if pbx.is_file() and "PrivacyInfo.xcprivacy in Resources" not in pbx.read_text(errors="replace"):
        problems.append(f"{MANIFEST} is not in the app's Resources build phase ({PBXPROJ}); run xcodegen generate.")

    if manifest.get("NSPrivacyTracking") is not False:
        problems.append("NSPrivacyTracking must be false: Gatefold tracks no one.")
    if manifest.get("NSPrivacyTrackingDomains"):
        problems.append("NSPrivacyTrackingDomains must be empty.")

    declared: dict[str, set[str]] = {}
    for entry in manifest.get("NSPrivacyAccessedAPITypes", []):
        declared[entry.get("NSPrivacyAccessedAPIType", "")] = set(entry.get("NSPrivacyAccessedAPITypeReasons", []))
    code = read_sources(root)
    for category, rule in REQUIRED_REASON.items():
        needed_by = []
        m = re.search(rule["pattern"], code)
        if m:
            needed_by.append(f"the app's code ({m.group(0).strip()})")
        if category in UNMANIFESTED_PACKAGES:
            needed_by.append(UNMANIFESTED_PACKAGES[category])
        if not needed_by:
            continue
        reasons = declared.get(category)
        if reasons is None:
            problems.append(f"{category} is used by {' and '.join(needed_by)} but not declared in {MANIFEST}.")
        elif not reasons & rule["reasons"]:
            problems.append(f"{category} needs one of {sorted(rule['reasons'])}; {MANIFEST} gives {sorted(reasons)}.")

    collected = {e.get("NSPrivacyCollectedDataType"): e for e in manifest.get("NSPrivacyCollectedDataTypes", [])}
    for kind, e in collected.items():
        if e.get("NSPrivacyCollectedDataTypeTracking") is not False:
            problems.append(f"{kind} must say NSPrivacyCollectedDataTypeTracking false.")
        if not e.get("NSPrivacyCollectedDataTypePurposes"):
            problems.append(f"{kind} needs at least one NSPrivacyCollectedDataTypePurposes entry.")

    sends = any(re.search(m, code) for m in TELEMETRY_MARKERS)
    for event in sorted(set(re.findall(EVENT_NAME, code)) - TELEMETRY_EVENTS.keys()):
        problems.append(f"The app sends the event {event}, which TELEMETRY_EVENTS doesn't list: add its App Privacy "
                        f"data types there, to {MANIFEST} and to {PRIVACY_PAGE}.")
    page = (root / PRIVACY_PAGE).read_text(errors="replace") if (root / PRIVACY_PAGE).is_file() else ""
    dist = json.loads((root / DISTRIBUTION).read_text()) if (root / DISTRIBUTION).is_file() else {}
    privacy = [c.get("store", {}).get("privacy", {}) for c in dist.get("channels", [])]
    if sends:
        for kind in sorted(TELEMETRY_DATA - collected.keys()):
            problems.append(f"The app sends telemetry, so {MANIFEST} must declare {kind}.")
        for kind in sorted(TELEMETRY_DATA & collected.keys()):
            if collected[kind].get("NSPrivacyCollectedDataTypeLinked") is not False:
                problems.append(f"{kind} is sent with a random install ID only, so it must say Linked false.")
        for phrase in NOTHING_COLLECTED:
            if re.search(phrase, page):
                problems.append(f"{PRIVACY_PAGE} says \"{phrase}\", but release builds send telemetry.")
        if not re.search(r"diagnostic", page, re.I):
            problems.append(f"{PRIVACY_PAGE} must say what the diagnostic telemetry sends.")
        for p in privacy:
            if p.get("collectsData") is not True:
                problems.append(f"{DISTRIBUTION}: privacy.collectsData must be true while telemetry ships.")
    if re.search(KEPT_PASSWORD, code) and re.search(PASSWORD_NEVER_KEPT, page, re.I):
        problems.append(f"{PRIVACY_PAGE} says the password is never stored, but the Keychain keeps it to sign in again.")
    for p in privacy:
        if p.get("policyUrl") != PRIVACY_URL:
            problems.append(f"{DISTRIBUTION}: privacy.policyUrl must be {PRIVACY_URL}, the page the listing names.")
    return problems


# --- selftest -------------------------------------------------------------------------------------------------------

def _manifest(api_types=None, collected=None, tracking=False) -> bytes:
    return plistlib.dumps({
        "NSPrivacyTracking": tracking,
        "NSPrivacyTrackingDomains": [],
        "NSPrivacyAccessedAPITypes": api_types if api_types is not None else [
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
             "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]},
            {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
             "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
        ],
        "NSPrivacyCollectedDataTypes": collected if collected is not None else [
            {"NSPrivacyCollectedDataType": k, "NSPrivacyCollectedDataTypeLinked": False,
             "NSPrivacyCollectedDataTypeTracking": False,
             "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}
            for k in sorted(TELEMETRY_DATA)
        ],
    })


def _tree(tmp: Path, *, manifest: bytes | None = None, code: str = "let d = UserDefaults.standard\n",
          page: str = "<p>Diagnostic counts only.</p>", collects=True, url=PRIVACY_URL, in_resources=True,
          excludes: str = '"**/.DS_Store"') -> Path:
    (tmp / "Gatefold/Support").mkdir(parents=True)
    (tmp / "Gatefold/App").mkdir(parents=True)
    (tmp / "Gatefold.xcodeproj").mkdir()
    (tmp / "docs/privacy").mkdir(parents=True)
    (tmp / "distribution").mkdir()
    if manifest is not None:
        (tmp / MANIFEST).write_bytes(manifest)
    (tmp / "Gatefold/App/App.swift").write_text(code)
    (tmp / PBXPROJ).write_text("PrivacyInfo.xcprivacy in Resources" if in_resources else "")
    (tmp / PROJECT_YML).write_text("targets:\n  Gatefold:\n    type: application\n    sources:\n      - path: Gatefold\n"
                                   f"        excludes:\n          - {excludes}\n  GatefoldTests:\n    type: bundle\n")
    (tmp / PRIVACY_PAGE).write_text(page)
    (tmp / DISTRIBUTION).write_text(json.dumps(
        {"channels": [{"store": {"privacy": {"policyUrl": url, "collectsData": collects}}}]}))
    return tmp


def selftest() -> int:
    telemetry = 'let u = URL(string: "https://us.i.posthog.com/i/v0/e/")\nlet d = UserDefaults.standard\n'
    cases = [
        ("a missing manifest fails", dict(manifest=None), ["is missing"]),
        ("a good manifest, no telemetry, passes", dict(manifest=_manifest(collected=[]), collects=False), []),
        ("a good manifest with telemetry passes", dict(manifest=_manifest(), code=telemetry), []),
        ("a manifest outside the build fails", dict(manifest=_manifest(), in_resources=False), ["Resources build phase"]),
        ("a project.yml that excludes the manifest fails",
         dict(manifest=_manifest(), excludes='"**/*.xcprivacy"'), ["must take Gatefold/ whole"]),
        ("tracking fails", dict(manifest=_manifest(tracking=True)), ["NSPrivacyTracking must be false"]),
        ("an event nobody listed fails",
         dict(manifest=_manifest(), code=telemetry + 'capture("gatefold_secret_sauce", properties: [:])\n'),
         ["sends the event gatefold_secret_sauce"]),
        ("a listed event passes",
         dict(manifest=_manifest(), code=telemetry + 'capture("gatefold_jump", properties: [:])\n'), []),
        ("a later source path naming Support is no exclude",
         dict(manifest=_manifest(), excludes='"**/.DS_Store"\n      - path: Support/Generated.swift'), []),
        ("an undeclared UserDefaults use fails",
         dict(manifest=_manifest(api_types=[{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
                                             "NSPrivacyAccessedAPITypeReasons": ["C617.1"]}])),
         ["NSPrivacyAccessedAPICategoryUserDefaults is used by"]),
        ("a package's file timestamps count even when the app's code has none",
         dict(manifest=_manifest(api_types=[{"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
                                             "NSPrivacyAccessedAPITypeReasons": ["CA92.1"]}])),
         ["NSPrivacyAccessedAPICategoryFileTimestamp is used by Zip"]),
        ("a reason from another category fails",
         dict(manifest=_manifest(api_types=[
             {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryUserDefaults",
              "NSPrivacyAccessedAPITypeReasons": ["C617.1"]},
             {"NSPrivacyAccessedAPIType": "NSPrivacyAccessedAPICategoryFileTimestamp",
              "NSPrivacyAccessedAPITypeReasons": ["C617.1"]}])),
         ["NSPrivacyAccessedAPICategoryUserDefaults needs one of"]),
        ("boot time in the app's code must be declared",
         dict(manifest=_manifest(), code="let t = ProcessInfo.processInfo.systemUptime\n"),
         ["NSPrivacyAccessedAPICategorySystemBootTime is used by the app's code (systemUptime)"]),
        ("telemetry without its data types fails",
         dict(manifest=_manifest(collected=[]), code=telemetry),
         ["must declare NSPrivacyCollectedDataTypeDeviceID", "must declare NSPrivacyCollectedDataTypePerformanceData"]),
        ("telemetry with a page that says nothing is collected fails",
         dict(manifest=_manifest(), code=telemetry, page="<p>Gatefold collects nothing. No analytics.</p>"),
         ['says "collects nothing"', 'says "No analytics"', "must say what the diagnostic telemetry sends"]),
        ("a page that says the password is never stored fails while the session keeps it",
         dict(manifest=_manifest(), code="struct StoredSession { public var password: String? }\n",
              page="<p>No tracking. Diagnostic counts only. Your password is never stored.</p>"),
         ["says the password is never stored"]),
        ("telemetry with collectsData false fails",
         dict(manifest=_manifest(), code=telemetry, collects=False), ["collectsData must be true"]),
        ("another privacy URL fails", dict(manifest=_manifest(), url="https://ouroboros.bot/privacy"),
         ["policyUrl must be"]),
        ("linked telemetry fails",
         dict(manifest=_manifest(collected=[
             {"NSPrivacyCollectedDataType": k, "NSPrivacyCollectedDataTypeLinked": True,
              "NSPrivacyCollectedDataTypeTracking": False,
              "NSPrivacyCollectedDataTypePurposes": ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]}
             for k in sorted(TELEMETRY_DATA)]), code=telemetry),
         ["must say Linked false"]),
    ]
    failed = 0
    for name, kwargs, expected in cases:
        with tempfile.TemporaryDirectory() as tmp:
            got = check(_tree(Path(tmp), **kwargs))
        ok = all(any(e in g for g in got) for e in expected) and (bool(expected) == bool(got))
        print(f"{'ok  ' if ok else 'FAIL'} {name}")
        if not ok:
            failed += 1
            print("     expected:", expected)
            print("     got:     ", got)
    print(f"{len(cases) - failed}/{len(cases)} passed")
    return 1 if failed else 0


def main(argv: list[str]) -> int:
    if argv[1:] == ["--selftest"]:
        return selftest()
    if argv[1:2] == ["check"]:
        root = Path(argv[2]) if len(argv) > 2 else Path(__file__).resolve().parent.parent
        problems = check(root)
        for p in problems:
            print(f"::error::{p}")
        print("Store readiness: " + ("ok" if not problems else f"{len(problems)} problem(s)"))
        return 1 if problems else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
