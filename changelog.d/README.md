# Changelog fragments: every change, told as a harrowing tale

Every pull request that changes the app adds one file here, `changelog.d/<slug>.md`. When a build goes to
TestFlight, CI strings together every fragment added since the last build, in merge order, and that becomes What to
Test (`scripts/changelog.py assemble`; no model writes anything at release time). The same commits always give the
same text.

"Changes the app" means it touches `Gatefold/`, a package's `Sources/` or manifest, `project.yml` or `distribution/`.
Tests, CI, scripts and docs need no fragment. The `Changelog fragment` check fails an app pull request without one.
When a tester would notice nothing at all (a rename, a refactor with no visible change), label the pull request
`no-changelog` instead.

## The format

```
---
title: The Veil That Would Not Lift
try: Open a long chapter, tap Back before it loads, and count to two.
---
For eleven builds, a reader who tapped Back while a chapter was still loading was left
staring into a pale veil that refused to rise. Some waited. Some force-quit. One wrote to us.
The veil now knows its limit: two seconds, then it lets go, and the page comes home.
```

- `title:` (required, at most 70 characters): the name of the tale.
- `try:` (optional, at most 240): one line telling a tester where to go to see it. It is printed as "Try it: ...".
- The tale (required, at most 700 characters): plain text, because What to Test shows no Markdown. No links, headings
  or HTML. Paragraphs are fine.
- File name: lowercase letters, digits and dashes, like `the-veil-that-would-not-lift.md`. It is never shown.

The whole of What to Test is at most 4,000 characters. When a build carries more than fits, the later tales shrink to
their titles.

## The voice

Each fragment is a short adventure in which the reader, the book or the tester barely survives, and the fix arrives
like the cavalry. Melodrama is the point. Have fun.

1. **It must be true.** Every peril and every rescue is something that really changed in this pull request. No
   invented features, no promises, nothing the build doesn't do (App Review Guideline 2.3, and testers' trust). Big
   words for small fixes are welcome; false ones are not.
2. **Say what changed in plain words somewhere in the tale,** so a tester who skims still knows what to look at.
   The `try:` line says where.
3. **Short.** Three to five sentences. Testers read it on a phone, standing up.
4. **Our books, not theirs.** Never quote a book's text, not even a public-domain one, and never a real reader's
   library. Name a public-domain book if it helps ("halfway through Moby-Dick").
5. **No blame and no jargon.** The villain is the bug, never a person or a team. "A race between the reflow and the
   reopen picture" becomes "the page and its own memory raced each other to the screen".
6. **Vary the opening.** The assembler adds its own opening and closing line, so start your tale in the middle of the
   action.

## Seed tales, to steal from

Invented examples of the voice. They describe no real change; don't copy them into a fragment.

```
---
title: The Hinge and the Lost Line
try: Open any book on the Duo folded, then unfold it mid-page.
---
Halfway through Moby-Dick, a reader opened their Duo like a book, and the line they were on
fled to the far page and hid. They searched both screens. They found the whale before they
found their place. Now the line stays put when the hinge moves, on whichever screen you left it.
```

```
---
title: Midnight, and the Page That Glowed White
try: Choose the Midnight paper, close the app, then come back to it.
---
It was well past midnight when the reader returned, eyes adjusted to the dark, and Gatefold
greeted them with a flash of pure white, like a lighthouse at arm's length. Survivors report
seeing spots until morning. Coming back to a dark page now stays dark, from the first frame.
```

```
---
title: The Cloud Kept Its Secret
try: Sign out, sign in again, and pull down on the shelf.
---
The shelf said the library was empty. The Cloud said the library was full. Neither would
back down, and the reader stood between them holding nothing. After a sign-in, the shelf now
asks the Cloud again instead of trusting its own old answer.
```

```
---
title: A Tap Swallowed Whole
try: Tap the middle of the page while a jump is still settling.
---
Something in the dark between pages was eating taps. A reader would tap once, twice,
three times, and the controls never came. We went in after it. A tap during a jump now
reaches the page, and the controls come up the first time.
```

## Seeing the result

```
python3 -I scripts/changelog.py assemble --head HEAD            # since the last testflight/build-* tag
python3 -I scripts/changelog.py assemble --head HEAD --since <sha>
python3 -I scripts/changelog.py lint                            # every fragment here
```
