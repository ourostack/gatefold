#!/usr/bin/env python3
"""Gatefold's changelog: one fragment per app change, told as a harrowing tale, assembled without judgment.

Every pull request that changes the app adds a fragment, changelog.d/<slug>.md (the voice and the format are in
changelog.d/README.md). At publish, CI strings the fragments added since the last published build into TestFlight's
What to Test, in the order they merged. Nothing here writes prose: the same commits always give the same text.

    python3 -I scripts/changelog.py check --base <sha> --head <sha> [--labels a,b]   # a pull request's fragment
    python3 -I scripts/changelog.py lint                                             # every fragment on disk
    python3 -I scripts/changelog.py assemble --head <sha> [--since <ref>] [--out f]  # What to Test
    python3 -I scripts/changelog.py --selftest

`--since` defaults to the newest testflight/build-* tag behind --head; with none, every fragment counts.
"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

DIR = "changelog.d"
SKIP_LABEL = "no-changelog"
LIMIT = 4000  # App Store Connect's What to Test
TITLE_MAX, TRY_MAX, BODY_MAX = 70, 240, 700
SLUG = re.compile(r"^[a-z0-9][a-z0-9-]{2,79}\.md$")
# What builds into the app a tester holds. Tests, CI, scripts, docs and the website are not in it.
APP = re.compile(r"^(Gatefold/|Packages/[^/]+/(Sources/|Package\.(swift|resolved)$)|project\.yml$|distribution/)")

OPENERS = [
    "Gather close, testers. What follows is true, and some of it still keeps us up at night.",
    "Light a candle. These are the dispatches from the latest crossing.",
    "Not every page that went into the dark came back. These ones did.",
    "The ledger is opened, the ink is wet, and the reader survived. Mostly.",
    "We set out with a book and a hinge. Here is what happened next.",
]
CLOSERS = [
    "So ends this account. Read on, and tell us what you find out there.",
    "If you meet anything stranger than this, send word by way of feedback.",
    "The shelf holds for now. Report any creaks.",
    "Mark your place. There will be another chapter.",
]
NUMERALS = ["I", "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X", "XI", "XII", "XIII", "XIV", "XV",
            "XVI", "XVII", "XVIII", "XIX", "XX"]


def git(*args, cwd=None):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


def is_fragment(path):
    p = pathlib.PurePosixPath(path)
    return len(p.parts) == 2 and p.parts[0] == DIR and p.suffix == ".md" and not p.name.startswith(("_", "README"))


def parse(text, name="fragment"):
    """Returns (fields, errors). fields: title, try (optional), body."""
    errors = []
    lines = text.replace("\r\n", "\n").split("\n")
    if not lines or lines[0].strip() != "---":
        return {}, [f"{name}: starts with a '---' line, then 'title:' (see {DIR}/README.md)"]
    end = next((i for i, ln in enumerate(lines[1:], 1) if ln.strip() == "---"), None)
    if end is None:
        return {}, [f"{name}: the front matter needs a closing '---' line"]
    fields = {}
    for ln in lines[1:end]:
        if not ln.strip():
            continue
        key, sep, value = ln.partition(":")
        key = key.strip().lower()
        if not sep or key not in ("title", "try"):
            errors.append(f"{name}: unknown front-matter line {ln.strip()!r} (only title: and try:)")
            continue
        fields[key] = value.strip().strip('"')
    body = "\n".join(lines[end + 1:]).strip()
    body = re.sub(r"\n{3,}", "\n\n", body)
    fields["body"] = body
    title = fields.get("title", "")
    if not title:
        errors.append(f"{name}: needs a title: line")
    elif len(title) > TITLE_MAX:
        errors.append(f"{name}: the title is {len(title)} characters; keep it to {TITLE_MAX}")
    if len(fields.get("try", "")) > TRY_MAX:
        errors.append(f"{name}: try: is {len(fields['try'])} characters; keep it to {TRY_MAX}")
    if not body:
        errors.append(f"{name}: tell the tale below the front matter")
    elif len(body) > BODY_MAX:
        errors.append(f"{name}: the tale is {len(body)} characters; keep it to {BODY_MAX} (testers read it on a phone)")
    # What to Test is plain text: links and markup show as their raw characters.
    markup = re.compile(r"\]\(|<[a-zA-Z/][^>]*>|^#", re.M)
    if any(markup.search(fields.get(k, "")) for k in ("title", "try", "body")):
        errors.append(f"{name}: What to Test is plain text; drop Markdown links, headings and HTML")
    return fields, errors


def check(base, head, labels, cwd=None):
    """A pull request: returns (ok, messages)."""
    fields = git("diff", "-z", "--name-status", "--no-renames", f"{base}...{head}", cwd=cwd).split("\0")
    changed = list(zip(fields[0::2], fields[1::2]))
    app = [p for s, p in changed if APP.match(p)]
    # A tale counts only when it is new: assemble takes fragments added since the last build, so editing an old
    # one tells testers nothing. Edited ones are still checked.
    added = [p for s, p in changed if s == "A" and is_fragment(p)]
    frags = [p for s, p in changed if s[:1] in ("A", "M") and is_fragment(p)]
    msgs, ok = [], True
    for p in frags:
        if not SLUG.match(pathlib.PurePosixPath(p).name):
            ok = False
            msgs.append(f"{p}: name it with lowercase letters, digits and dashes, like {DIR}/the-veil-that-lingered.md")
        _, errs = parse(git("show", f"{head}:{p}", cwd=cwd), p)
        if errs:
            ok = False
            msgs.extend(errs)
    if app and not added:
        if SKIP_LABEL in labels:
            msgs.append(f"No fragment, and the '{SKIP_LABEL}' label says none is needed.")
        else:
            ok = False
            msgs.append(
                f"This pull request changes the app ({len(app)} files, e.g. {app[0]}) but adds no fragment. "
                f"Add {DIR}/<slug>.md telling what changed as a harrowing tale ({DIR}/README.md has the voice), "
                f"or label the pull request '{SKIP_LABEL}' when a tester would notice nothing."
            )
    elif not app:
        msgs.append("No app change, so no fragment is needed.")
    if ok and frags:
        msgs.append("Fragment ok: " + ", ".join(frags))
    return ok, msgs


def lint(root="."):
    errs = []
    for f in sorted(pathlib.Path(root, DIR).glob("*.md")):
        rel = f"{DIR}/{f.name}"
        if not is_fragment(rel):
            continue
        if not SLUG.match(f.name):
            errs.append(f"{rel}: lowercase letters, digits and dashes only")
        errs.extend(parse(f.read_text(), rel)[1])
    return errs


def last_tag(head, cwd=None):
    try:
        return git("describe", "--tags", "--match", "testflight/build-*", "--abbrev=0", head, cwd=cwd).strip()
    except subprocess.CalledProcessError:
        return ""


def added_since(since, head, cwd=None):
    """Fragment paths added in (since, head], oldest merge first, that still exist at head."""
    rng = f"{since}..{head}" if since else head
    # Renames are detected (and so not "added"): a fragment moved to a new name is not a new tale.
    out = git("log", "--reverse", "--first-parent", "--diff-filter=A", "--find-renames", "--name-only", "-z",
              "--format=", rng, "--", DIR, cwd=cwd).replace("\n", "\0")
    present = set(git("ls-tree", "--name-only", f"{head}:{DIR}", cwd=cwd).split()) if has_dir(head, cwd) else set()
    seen, order = set(), []
    for p in (x for x in out.split("\0") if x):
        if is_fragment(p) and p not in seen and pathlib.PurePosixPath(p).name in present:
            seen.add(p)
            order.append(p)
    return order


def has_dir(head, cwd=None):
    return subprocess.run(["git", "cat-file", "-e", f"{head}:{DIR}"], cwd=cwd, capture_output=True).returncode == 0


def pick(options, key):
    return options[int(key[:8], 16) % len(options)]


def render(tales, head, subjects=()):
    """tales: list of field dicts. Fits LIMIT by trimming later tales to their titles, never mid-sentence."""
    opener, closer = pick(OPENERS, head), pick(CLOSERS, head[::-1])
    if not tales:
        lines = ["No tale was written for this build. The ship's log records only:"]
        lines += [f"- {s}" for s in subjects[:12]] or ["- small repairs below deck"]
        return fit("\n".join(lines + ["", closer]))

    def tale(i, t, full):
        num = NUMERALS[i] if i < len(NUMERALS) else str(i + 1)
        head_line = f"{num}. {t['title']}"
        if not full:
            return head_line
        parts = [head_line, t["body"]]
        if t.get("try"):
            parts.append(f"Try it: {t['try']}")
        return "\n".join(parts)

    for full_count in range(len(tales), -1, -1):
        blocks = [tale(i, t, i < full_count) for i, t in enumerate(tales)]
        text = "\n\n".join([opener, *blocks, closer])
        if len(text) <= LIMIT:
            return text
    return fit("\n\n".join([opener, *(tale(i, t, False) for i, t in enumerate(tales))]))


REST = "\n\n(The rest is in changelog.d on GitHub.)"


def fit(text):
    if len(text) <= LIMIT:
        return text
    cut = text[:LIMIT - len(REST)]
    cut = cut.rsplit("\n", 1)[0] if "\n" in cut else cut
    return cut + REST


def assemble(head, since=None, cwd=None):
    # A shallow clone has neither the history nor the tags: it would quietly find only the tip's tales.
    if git("rev-parse", "--is-shallow-repository", cwd=cwd).strip() == "true":
        raise SystemExit("changelog: this clone is shallow; check out with fetch-depth: 0 (and its tags)")
    head = git("rev-parse", head, cwd=cwd).strip()
    if since is None:
        since = last_tag(head, cwd)
    paths = added_since(since, head, cwd)
    tales = []
    for p in paths:
        fields, errs = parse(git("show", f"{head}:{p}", cwd=cwd), p)
        if not errs:
            tales.append(fields)
        else:
            print("skipping " + "; ".join(errs), file=sys.stderr)
    subjects = []
    if not tales:
        rng = f"{since}..{head}" if since else head
        subjects = [s for s in git("log", "--first-parent", "--format=%s", "-n", "12", rng, cwd=cwd).splitlines() if s]
    return render(tales, head, subjects)


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def selftest():
    with tempfile.TemporaryDirectory() as d:
        def run(*a):
            return git(*a, cwd=d)
        run("init", "-q", "-b", "main")
        run("config", "user.email", "t@example.com")
        run("config", "user.name", "t")
        run("config", "commit.gpgsign", "false")

        def commit(files, msg):
            for path, text in files.items():
                f = pathlib.Path(d, path)
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text(text)
            run("add", "-A")
            run("commit", "-q", "-m", msg)
            return run("rev-parse", "HEAD").strip()

        frag = lambda t, b, tr="": f"---\ntitle: {t}\n" + (f"try: {tr}\n" if tr else "") + f"---\n{b}\n"
        c0 = commit({"README.md": "x", f"{DIR}/README.md": "guide"}, "start")
        c1 = commit({"Gatefold/A.swift": "1", f"{DIR}/the-first-crossing.md": frag("The First Crossing", "It held.", "Open a book.")}, "one")
        c2 = commit({"Gatefold/B.swift": "2"}, "two, no tale")
        c3 = commit({"scripts/x.py": "3"}, "ci only")
        c4 = commit({"Gatefold/C.swift": "4", f"{DIR}/the-second-night.md": frag("The Second Night", "It held again.")}, "four")

        ok, _ = check(c0, c1, [], cwd=d); assert ok, "app change with a fragment passes"
        ok, m = check(c1, c2, [], cwd=d); assert not ok and "adds no fragment" in m[0], m
        ok, _ = check(c1, c2, [SKIP_LABEL], cwd=d); assert ok, "the label lets it through"
        ok, m = check(c2, c3, [], cwd=d); assert ok and "No app change" in m[0], m
        bad = commit({"Gatefold/D.swift": "5", f"{DIR}/Bad_Name.md": "no front matter"}, "bad")
        ok, m = check(c4, bad, [], cwd=d); assert not ok and any("lowercase" in x for x in m) and any("'---'" in x for x in m), m
        long_one = commit({f"{DIR}/too-long.md": frag("T" * 80, "x" * 800)}, "long")
        ok, m = check(bad, long_one, [], cwd=d); assert not ok and len([x for x in m if 'keep it' in x]) == 2, m
        md = commit({f"{DIR}/linky.md": frag("Linky", "See [here](https://x).")}, "link")
        ok, m = check(long_one, md, [], cwd=d); assert not ok and "plain text" in m[0], m

        edit = commit({"Gatefold/F.swift": "7", f"{DIR}/the-first-crossing.md": frag("The First Crossing", "It held, barely.")}, "edit")
        ok, m = check(md, edit, [], cwd=d); assert not ok and "adds no fragment" in " ".join(m), m
        run("mv", f"{DIR}/the-second-night.md", f"{DIR}/the-second-night-renamed.md"); run("commit", "-q", "-m", "rename")
        renamed = run("rev-parse", "HEAD").strip()
        assert added_since(edit, renamed, cwd=d) == [], "a rename is no new tale"
        assert len(fit("x" * 5000)) <= LIMIT and len(fit(("y" * 50 + "\n") * 100)) <= LIMIT
        text = assemble(c4, since=None, cwd=d)
        assert text.index("I. The First Crossing") < text.index("II. The Second Night"), text
        assert "Try it: Open a book." in text and text == assemble(c4, since=None, cwd=d), "deterministic"
        run("tag", "testflight/build-21", c1)
        text = assemble(c4, cwd=d)  # since the tag: only the second tale
        assert "The Second Night" in text and "The First Crossing" not in text, text
        run("tag", "testflight/build-22", c4)
        quiet = commit({"Gatefold/E.swift": "6"}, "a quiet fix")
        text = assemble(quiet, cwd=d)
        assert "No tale was written" in text and "- a quiet fix" in text, text

        many = [{"title": f"Tale {i}", "body": "w" * 690, "try": "t" * 200} for i in range(12)]
        text = render(many, "a" * 40)
        assert len(text) <= LIMIT and "XII. Tale 11" in text and "I. Tale 0\n" + "w" * 690 in text, len(text)
        errs = lint(d)
        assert any("Bad_Name" in e for e in errs) and any("too-long" in e for e in errs), errs
    print("changelog selftest: ok")


def main(argv):
    if "--selftest" in argv:
        selftest()
        return 0
    cmd = argv[0] if argv else ""
    if cmd == "check":
        if not arg(argv, "--base"):
            print(__doc__, file=sys.stderr)
            return 2
        labels = [x.strip() for x in arg(argv, "--labels", "").split(",") if x.strip()]
        ok, msgs = check(arg(argv, "--base"), arg(argv, "--head", "HEAD"), labels)
        for m in msgs:
            info = m.startswith(("No app change", "No fragment, and", "Fragment ok"))
            print(m if info else "::error::" + m)
        return 0 if ok else 1
    if cmd == "lint":
        errs = lint()
        for e in errs:
            print("::error::" + e)
        return 1 if errs else 0
    if cmd == "assemble":
        text = assemble(arg(argv, "--head", "HEAD"), arg(argv, "--since"))
        out = arg(argv, "--out")
        if out:
            pathlib.Path(out).write_text(text)
        else:
            print(text)
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
