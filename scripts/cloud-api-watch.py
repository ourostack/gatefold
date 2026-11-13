#!/usr/bin/env python3
"""CI only: watch PocketBook's own web app for API changes, daily (gatefold#372).

    python3 -I scripts/cloud-api-watch.py check [--snapshot scripts/cloud-web-api.json] [--report out.md]
    python3 -I scripts/cloud-api-watch.py write [--snapshot scripts/cloud-web-api.json]
    python3 -I scripts/cloud-api-watch.py --selftest

PocketBook changes its cloud without notice, and its own web app (cloud.pocketbook.com, a Nuxt app)
changes with it. This downloads the app's JavaScript (the page's /_nuxt/ scripts and every chunk they
import), pulls out the API calls it makes (path literals under the API roots, `${...}` shown as {}) and
the snake_case names it uses (fields such as fast_hash, pointer_pb, read_position; error codes), and
compares them with the committed snapshot. Chunk names change on every deploy, so only what is in them
is compared. The canary (cloud-canary.yml) sees a change once it breaks; this sees it when PocketBook's
own client starts using it, often first.

`check` exits 0 when nothing changed, 1 when something did (the report says what), and 3 when the web
app couldn't be read (blocked, down or reshaped): that is inconclusive, never a change. `write`
refreshes the snapshot; a pull request that adapts Gatefold to a change commits it.
"""
import hashlib
import json
import os
import re
import sys
import urllib.request
from collections import deque

SITE = "https://cloud.pocketbook.com/"
SNAPSHOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cloud-web-api.json")
MAX_CHUNKS = 600
UA = ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
      "Version/18.0 Safari/605.1.15")
# First path segments that are API calls rather than pages of the site.
API_ROOTS = {"api", "front-api", "ssr-api", "auth", "user", "users", "books", "fileops", "files", "file", "notes",
             "collections", "stats", "authors", "reader", "positions", "bookmarks", "read-position", "search",
             "recommendations", "mercure", "mercure-hub", "media", "shops", "widgets", "library", "sync", "devices"}
PATH = re.compile(r"""["'`](/[a-z][a-z0-9-]*(?:/[A-Za-z0-9_.${}-]*)*)["'`]""")
SNAKE = re.compile(r"\b([a-z][a-z0-9]*(?:_[a-z0-9]+)+)\b")
SCRIPT = re.compile(r"""(?:/_nuxt/|["']\./)([A-Za-z0-9_-]+\.js)""")


def fetch(url, accept="*/*"):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": accept})
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.read().decode("utf-8", errors="replace")


def crawl(get=fetch, site=SITE):
    """{chunk name: text} for every script the page loads, followed through their imports."""
    html = get(site, accept="text/html")
    queue, seen, texts = deque(SCRIPT.findall(html)), set(), {}
    while queue and len(seen) < MAX_CHUNKS:
        name = queue.popleft()
        if name in seen:
            continue
        seen.add(name)
        try:
            texts[name] = get(site.rstrip("/") + "/_nuxt/" + name)
        except Exception:
            continue
        queue.extend(n for n in SCRIPT.findall(texts[name]) if n not in seen)
    return texts


def extract(texts):
    paths, names = set(), set()
    for text in texts.values():
        for p in PATH.findall(text):
            p = re.sub(r"\$\{[^}]*\}", "{}", p)
            if p.split("/")[1] in API_ROOTS:
                paths.add(p)
        names.update(SNAKE.findall(text))
    return {"paths": sorted(paths), "names": sorted(names)}


def diff(old, new):
    lines = []
    for key, what in (("paths", "API paths"), ("names", "snake_case names")):
        gone = sorted(set(old.get(key, [])) - set(new[key]))
        added = sorted(set(new[key]) - set(old.get(key, [])))
        if gone or added:
            lines.append(f"**{what}**")
            lines += [f"- gone: `{x}`" for x in gone] + [f"- new: `{x}`" for x in added]
    return lines


def fingerprint(lines):
    return hashlib.sha256("\n".join(lines).encode()).hexdigest()[:12]


def arg(argv, name, default=None):
    return argv[argv.index(name) + 1] if name in argv else default


def check(argv, get=fetch):
    snapshot = arg(argv, "--snapshot", SNAPSHOT)
    try:
        texts = crawl(get)
    except Exception as e:  # blocked, down: we learned nothing about the API
        print(f"::warning title=Cloud API watch inconclusive::{SITE} could not be read ({type(e).__name__})")
        return 3
    if len(texts) < 5:
        print(f"::warning title=Cloud API watch inconclusive::only {len(texts)} scripts found on {SITE}; the page changed shape")
        return 3
    new = extract(texts)
    old = json.load(open(snapshot))
    lines = diff(old, new)
    report = arg(argv, "--report")
    if not lines:
        print(f"No change: {len(new['paths'])} API paths and {len(new['names'])} names, from {len(texts)} scripts.")
        return 0
    body = (f"PocketBook's web app ({SITE}) changed the API calls it makes, compared with "
            f"`scripts/cloud-web-api.json` ({len(texts)} scripts read):\n\n" + "\n".join(lines) +
            f"\n\nfingerprint: {fingerprint(lines)}\n")
    print(body)
    if report:
        open(report, "w").write(body)
    return 1


def write(argv, get=fetch):
    texts = crawl(get)
    new = extract(texts)
    with open(arg(argv, "--snapshot", SNAPSHOT), "w") as f:
        json.dump(new, f, indent=1)
        f.write("\n")
    print(f"Wrote {len(new['paths'])} API paths and {len(new['names'])} names from {len(texts)} scripts.")
    return 0


def selftest():
    import tempfile
    page = '<html><script type="module" src="/_nuxt/Entry1.js"></script><link rel="modulepreload" href="/_nuxt/Lib2.js"></html>'
    chunks = {
        "Entry1.js": 'import("./Books3.js");const a=`/books/status/${i}/${r}`,b="/account/settings",c="/fileops/info";',
        "Lib2.js": 'x.get("/user");y={fast_hash:h,read_position:p};z["pointer_pb"];',
        "Books3.js": 'fetch(`/notes/${u}`);q.include_metadata=!0;import("./Missing4.js");',
    }
    for n in ("A", "B", "C"):
        chunks[f"Pad{n}.js"] = "void 0;"
    page = page.replace("</html>", "".join(f'<script src="/_nuxt/Pad{n}.js"></script>' for n in "ABC") + "</html>")

    def get(url, accept="*/*"):
        if url == SITE:
            return page
        name = url.rsplit("/", 1)[1]
        if name not in chunks:
            raise OSError("404")
        return chunks[name]

    texts = crawl(get)
    assert set(texts) == {"Entry1.js", "Lib2.js", "Books3.js", "PadA.js", "PadB.js", "PadC.js"}, sorted(texts)
    got = extract(texts)
    assert got["paths"] == ["/books/status/{}/{}", "/fileops/info", "/notes/{}", "/user"], got["paths"]
    assert {"fast_hash", "read_position", "pointer_pb", "include_metadata"} <= set(got["names"]), got["names"]
    with tempfile.TemporaryDirectory() as root:
        snap, report = os.path.join(root, "snap.json"), os.path.join(root, "report.md")
        assert write(["--snapshot", snap], get) == 0
        assert check(["--snapshot", snap, "--report", report], get) == 0, "unchanged"
        # November 2026 in miniature: the web app starts asking for include_metadata on a new path.
        chunks["Books3.js"] += 'fetch("/fileops/info/v2");w.md5_digest=1;'
        assert check(["--snapshot", snap, "--report", report], get) == 1
        text = open(report).read()
        assert "- new: `/fileops/info/v2`" in text and "- new: `md5_digest`" in text and "fingerprint:" in text, text
        chunks.pop("Lib2.js")
        text_gone = diff(json.load(open(snap)), extract(crawl(get)))
        assert "- gone: `/user`" in text_gone, text_gone

        def down(url, accept="*/*"):
            raise OSError("blocked")
        assert check(["--snapshot", snap], down) == 3, "a blocked site is inconclusive"
        assert check(["--snapshot", snap], lambda url, accept="*/*": "<html></html>") == 3, "no scripts is inconclusive"
    print("cloud-api-watch selftest ok")
    return 0


def main(argv):
    if argv[:1] == ["--selftest"]:
        return selftest()
    if argv[:1] == ["check"]:
        return check(argv[1:])
    if argv[:1] == ["write"]:
        return write(argv[1:])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
