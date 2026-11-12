import XCTest

/// Losing his place is the worst a reader can do to him (build 20: "fucked my location with accidental
/// navigation"). Only a deliberate turn or a jump he chose moves the page, and every jump that is not a
/// turn is one tap to undo, with the controls hidden. Words are compared, never printed.
@MainActor
final class PlaceUndoUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
    private var visibleText: String { (el("reader.visibleText").value as? String) ?? "" }
    /// The words that open the page, as a number: enough to tell two pages apart, nothing to quote.
    private func opening(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ").hashValue
    }

    private func waitForWords(changingFrom old: String? = nil, timeout: TimeInterval = 60) -> String {
        let up = Date().addingTimeInterval(timeout)
        while Date() < up {
            let now = visibleText
            if !now.isEmpty, now != old { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return visibleText
    }

    /// Reads of the page's words, `interval` apart, until they differ from `old` (`atMost` + 1
    /// if they never do).
    private func readsUntilWords(changeFrom old: String, atMost: Int, every interval: TimeInterval = 0.25) -> Int {
        for read in 1...atMost {
            RunLoop.current.run(until: Date().addingTimeInterval(interval))
            let now = visibleText
            if !now.isEmpty, now != old { return read }
        }
        return atMost + 1
    }

    /// Waits judged in reads of the app, never seconds (gatefold#196, as #177 and #121): each read is a
    /// round trip to the app, so a starved runner makes reads slower instead of failing what landed late.
    /// Each read waits at least 0.1 s, so `reads` is the floor a fast runner gets. The hang guard ends only a
    /// hang: `HangGuard` sizes it from `reads` and ends it before the step does (gatefold#223). The fixed guards
    /// it replaces (30 s to 240 s) would end a wait after 2 to 13 reads at the slowest read seen, before its cap.
    /// After one wait hangs, every later wait in the test answers at once, not done, so the test runs to its end
    /// with its own failures and leaves the shard's later tests their time, instead of each wait in turn running
    /// on toward the step's end (gatefold#223 review). A test method gets a fresh instance, so this is per test.
    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds {
                hung = true
                XCTFail("hang: a wait ran \(read) of its \(reads) reads past its hang guard")
                return (false, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    /// A jump has landed: its veil is gone and the page shows other words than `old`. The words change
    /// beneath the veil, which swallows a tap (`handleTap`), so a tap waits for this, not for the words.
    private func landed(from old: String, reads: Int = 300) -> (words: String, reads: Int, ok: Bool) {
        let veil = el("reader.veil")
        var words = ""
        let wait = readsUntil(reads: reads) {
            words = visibleText
            return !words.isEmpty && words != old && !veil.exists
        }
        return (words, wait.reads, wait.ok)
    }

    /// Settled: the same words in two reads a second apart.
    private func settledWords() -> String {
        var last = waitForWords()
        for _ in 0..<20 {
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            let now = visibleText
            if now == last, !now.isEmpty { return now }
            last = now
        }
        return last
    }

    private func openFresh(_ extra: [String] = [], goTo: String = "0.31") -> String {
        app.launchArguments = common + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                                "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", goTo]
            // GATEFOLD_POSTURE=spread runs the same checks on the unfolded Duo.
            + (ProcessInfo.processInfo.environment["GATEFOLD_POSTURE"].map { ["-GatefoldForcePosture", $0] } ?? [])
            // GATEFOLD_COUNTERS=0 opens the same page with no counting behind it, for an A/B of what it costs.
            + (ProcessInfo.processInfo.environment["GATEFOLD_COUNTERS"].map { ["-GatefoldCounters", $0] } ?? [])
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 90))
        return settledWords()
    }

    private func showChrome() {
        // A tap under a jump's veil is swallowed (the veil is the page changing), so wait it out.
        // Judged in reads (gatefold#166), as every wait here: a starved runner's queries take seconds.
        let veil = el("reader.veil")
        XCTAssertTrue(readsUntil(reads: 600) { !veil.exists }.ok, "the veil lifts")
        // Already up (a jump made from them leaves them up), or fading in or out: wait for one or the
        // other and never tap them down. 2 s of wall time ran out on a starved runner while they were
        // up, and the tap that followed put them down.
        let contents = app.buttons["reader.contents"]
        if contents.exists {
            _ = readsUntil(reads: 30) { !contents.exists || contents.isHittable }
            if contents.exists {
                XCTAssertTrue(contents.isHittable, "the controls that are up become hittable")
                return
            }
        }
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(readsUntil(reads: 50) { contents.exists && contents.isHittable }.ok,
                      "a tap in the middle brings up the controls")
    }

    private func contentsJump(to chapter: String) {
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", chapter)).firstMatch
        // The list opens centred on the current chapter, so the first rows are not built yet.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Chapter")).firstMatch.waitForExistence(timeout: 10),
                      "the contents list opens")
        // Asking a row whether it is hittable fails the test outright when the list has built it off screen
        // ("activation point invalid": main 42855033645, gatefold#196, #98), so `ContentsRow` reads its frame.
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list \(chapter)")
    }

    /// A Contents jump, then the controls gone: "Back" is on the page, and one tap on it is his page again.
    func testAJumpIsOneTapToUndoWithTheControlsHidden() {
        let first = openFresh()
        contentsJump(to: "Chapter XL")
        let jump = landed(from: first)
        print("UNDO jump landed after \(jump.reads) reads")
        XCTAssertNotEqual(opening(jump.words), opening(first), "the jump moved the page")
        XCTAssertTrue(jump.ok, "the jump's veil lifts")
        let jumped = jump.words
        XCTAssertTrue(keptAtChapterXL(), "the jump didn't keep the chapter he chose")
        // A jump made from the controls leaves them up, perhaps still fading in: once they are, a tap in
        // the middle puts them down.
        let contents = app.buttons["reader.contents"]
        let up = readsUntil(reads: 20) { contents.exists && contents.isHittable }
        if up.ok { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let hidden = readsUntil(reads: 50) { !contents.exists }
        print("UNDO controls up=\(up.ok) after \(up.reads) reads; hidden after \(hidden.reads) reads")
        XCTAssertTrue(hidden.ok, "the controls are hidden")
        let back = app.buttons["reader.back"]
        let shown = readsUntil(reads: 50) { back.exists }
        print("UNDO back shown after \(shown.reads) reads")
        XCTAssertTrue(shown.ok, "no way back on the page without opening the controls")
        // Still there a while later: he may notice the jump late.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        XCTAssertTrue(back.exists, "the way back went away by itself")
        XCTAssertFalse(contents.exists, "the controls stayed hidden")
        back.tap()
        let returned = landed(from: jumped)
        print("UNDO back landed after \(returned.reads) reads")
        XCTAssertEqual(opening(returned.words), opening(first), "Back did not return to his page")
        XCTAssertTrue(returned.ok, "Back's veil lifts")
        // And Back itself is one tap to undo.
        let again = readsUntil(reads: 50) { app.buttons["reader.back"].exists }
        XCTAssertTrue(again.ok, "going back can't be undone")
        // And the page still answers: a tap in its middle brings the controls up.
        XCTAssertFalse(contents.exists, "the controls stayed down through Back")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let answers = readsUntil(reads: 50) { contents.exists }
        print("UNDO back again after \(again.reads) reads; controls after \(answers.reads) reads")
        XCTAssertTrue(answers.ok, "after Back a tap no longer shows the controls")
    }

    /// Back to a chapter still loading takes him back once it has loaded: on CI's iPad (job 129949744000,
    /// gatefold#170) Back gave up and he stayed where he had jumped to. Back's first 25 sends are each
    /// taken at its chapter's start, the chapter still loading meanwhile (`-GatefoldHoldBackSends`), as a
    /// web view still loading takes a jump: past the 15 a trip of 150 plain reads makes (one each 10).
    /// The veil may let go at its limit meanwhile (the chapter shows its own loading); the trip goes on.
    /// Judged in samples of the held load.
    func testBackToAChapterStillLoadingWaitsForItAndTakesHimBack() {
        // Opened inside a chapter (0.31), not at one's start: a Back to a chapter's start sends once, and
        // the hold would never run out.
        let first = openFresh(["-GatefoldHoldBackSends", "25"])
        let held = el("reader.loadingHeld"), veil = el("reader.veil")
        contentsJump(to: "Chapter XL")
        XCTAssertTrue(veil.waitForExistence(timeout: 10) && veil.waitForNonExistence(timeout: 240), "the jump's veil lifts")
        let jumped = waitForWords(changingFrom: first, timeout: 30)
        XCTAssertNotEqual(opening(jumped), opening(first), "the jump moved the page")
        if app.buttons["reader.contents"].exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        let back = app.buttons["reader.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 10), "a way back")
        back.tap()
        XCTAssertTrue(held.waitForExistence(timeout: 30), "Back's chapter load is held open")
        // Sampled until the held load ends: how long the veil stayed, for the log (it may let go at its limit).
        // A trip that stops sending leaves it held: 400 samples, past the 25 sends' 50 s of reads.
        var samples = 0, bare = 0
        // Read from a snapshot: the held load can end between `exists` and a plain `value`, which then fails (#213).
        func sendsLeftNow() -> String? { (try? held.snapshot())?.value as? String }
        print("BACKHELD sendsLeftAtStart=\(sendsLeftNow() ?? "?")")
        var sendsLeft = "?"
        while held.exists, samples < 400 {
            sendsLeft = sendsLeftNow() ?? sendsLeft
            samples += 1
            if !veil.exists, held.exists { bare += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("BACKHELD sendsLeft=\(sendsLeft) samples=\(samples) veilGoneWhileLoading=\(bare) heldAtEnd=\(held.exists)")
        XCTAssertFalse(held.exists, "Back stopped sending while the chapter was still loading")
        XCTAssertTrue(veil.waitForNonExistence(timeout: 30), "Back's veil lifted once the chapter had loaded")
        let returned = waitForWords(changingFrom: jumped, timeout: 30)
        XCTAssertEqual(opening(returned), opening(first), "Back did not return to his page")
        // The button may have gone by now (#213): a gone button shows no failure either.
        XCTAssertNotEqual((try? back.snapshot())?.label, "Couldn't go back. Try again")
    }

    /// A touch resting on the scrubber, and a short wobble on it, never move the page.
    func testATouchOnTheScrubberNeverJumps() {
        let first = openFresh()
        showChrome()
        let scrubber = el("reader.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)).tap()
        let at = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        at.press(forDuration: 0.1, thenDragTo: at.withOffset(CGVector(dx: 6, dy: 0)))
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        XCTAssertEqual(opening(settledWords()), opening(first), "a touch on the scrubber moved the page")
    }

    /// Your Page open: a tap above it, in the page's margin, closes the panel and turns nothing.
    func testATapAboveYourPageClosesItAndKeepsThePage() {
        let first = openFresh()
        showChrome()
        app.buttons["reader.appearance"].tap()
        let panel = el("appearance.panel")
        XCTAssertTrue(panel.waitForExistence(timeout: 10))
        // In the page's right margin, below the top bar: the turn zone, where a tap that got through would turn.
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.25)).tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "a tap above Your Page didn't close it")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        XCTAssertEqual(opening(settledWords()), opening(first), "closing Your Page moved the page")
    }

    /// On a spread, a tap near the window's left edge at mid-height turns back. The UI tests' posture
    /// switches once sat in that strip and swallowed it (the iPad spread's x 0.07 did nothing).
    func testATapNearTheLeftEdgeOfASpreadTurnsBack() throws {
        let first = openFresh()
        try XCTSkipUnless(el("reader.posture").label == "spread", "a spread only (the iPad, or the unfolded Duo)")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let ahead = waitForWords(changingFrom: first, timeout: 15)
        XCTAssertNotEqual(opening(ahead), opening(first), "the forward turn didn't happen")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        let back = waitForWords(changingFrom: ahead, timeout: 15)
        XCTAssertEqual(opening(back), opening(first), "a tap at x 0.03 on the spread didn't turn back")
        XCTAssertFalse(app.buttons["reader.contents"].exists, "the tap showed the controls instead of turning")
        // Again a little higher, where the old switches sat on a tall iPad (0.45 of the page down): the
        // strip is gone at every height, not only at mid-height on a short one.
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let ahead2 = waitForWords(changingFrom: back, timeout: 15)
        XCTAssertNotEqual(opening(ahead2), opening(back), "the second forward turn didn't happen")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.47)).tap()
        let back2 = waitForWords(changingFrom: ahead2, timeout: 15)
        XCTAssertEqual(opening(back2), opening(first), "a tap at x 0.03, 0.47 down, on the spread didn't turn back")
        XCTAssertFalse(app.buttons["reader.contents"].exists, "the higher tap showed the controls instead of turning")
    }

    /// A tap at the left edge turns back as promptly as one at the right edge turns forward: the
    /// page has moved within 12 reads (feel-ci's folded Duo saw it move only after 43), and neither
    /// turn waited more than 24 looks for the page beneath to paint.
    func testATapAtTheLeftEdgeTurnsBackPromptly() {
        leftEdgeTurnsBack(reading: 0.25)
    }

    /// The same, read as feel-ci's turn check does (curl turns, a read every tenth of a second), opened
    /// at 0.31 so both taps stay within one chapter. A turn into another chapter waits for that chapter
    /// to load (#61); its check comes with the fix that preloads the neighbours.
    func testATapAtTheLeftEdgeTurnsBackPromptlyWithinAChapter() {
        leftEdgeTurnsBack(reading: 0.1, extra: ["-GatefoldPageTurn", "curl"], goTo: "0.31", label: "curl at 0.31")
    }

    /// The newest turn's count and the looks it waited for the page beneath, from the app itself:
    /// counted from the tap, where reads after XCUITest's tap start only once the app has gone idle.
    private func turnWait() -> (turn: Int, looks: Int, crossed: Bool) {
        let parts = ((el("reader.turnWait").value as? String) ?? "").split(separator: " ").compactMap { Int($0) }
        return parts.count == 3 ? (parts[0], parts[1], parts[2] == 1) : (0, -1, false)
    }

    private func looks(ofTurnAfter turn: Int) -> (looks: Int, crossed: Bool) {
        for _ in 0..<100 {
            let now = turnWait()
            if now.turn > turn { return (now.looks, now.crossed) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (-1, false)
    }

    private func leftEdgeTurnsBack(reading interval: TimeInterval, extra: [String] = [], goTo: String = "0.31",
                                   label: String = "default at 0.31", reads limit: Int = 12, looks lookLimit: Int = 24) {
        let first = openFresh(extra, goTo: goTo)
        let page = el("reader.page")
        let before = turnWait().turn
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let forward = readsUntilWords(changeFrom: first, atMost: 200, every: interval)
        let forwardLooks = looks(ofTurnAfter: before)
        let ahead = settledWords()
        XCTAssertNotEqual(opening(ahead), opening(first), "the forward turn didn't happen")
        let middle = turnWait().turn
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        let reads = readsUntilWords(changeFrom: ahead, atMost: 200, every: interval)
        let back = looks(ofTurnAfter: middle)
        // One line for CI's log (counts only, never words): which turns crossed a chapter, and what each cost.
        let line = "TURNWAIT \(label): reads forward \(forward), back \(reads); looks forward \(forwardLooks.looks)\(forwardLooks.crossed ? " (crossed a chapter)" : ""), back \(back.looks)\(back.crossed ? " (crossed a chapter)" : "")"
        print(line)
        XCTContext.runActivity(named: line) { _ in }
        XCTAssertLessThanOrEqual(reads, limit, "a tap at the left edge turned back only after \(reads) reads (forward took \(forward))")
        XCTAssertLessThanOrEqual(forward, limit, "a tap at the right edge turned forward only after \(forward) reads")
        XCTAssertTrue((0...lookLimit).contains(forwardLooks.looks), "the forward turn waited \(forwardLooks.looks) looks for the page beneath")
        XCTAssertTrue((0...lookLimit).contains(back.looks), "the back turn waited \(back.looks) looks for the page beneath")
        XCTAssertEqual(opening(settledWords()), opening(first), "the tap at the left edge didn't turn back to the page before")
    }

    /// On a chapter's first page (where a Contents jump lands), a tap at the left edge and a swipe
    /// right each turn back into the chapter before, in every posture (feel-ci's folded Duo saw
    /// neither move the page).
    func testAChaptersFirstPageTurnsBackByTapAndBySwipe() {
        let first = openFresh()
        contentsJump(to: "Chapter XL")
        _ = waitForWords(changingFrom: first, timeout: 30)
        XCTAssertTrue(el("reader.veil").waitForNonExistence(timeout: 60), "the veil lifts")
        XCTAssertTrue(keptAtChapterXL(), "the jump didn't keep the chapter he chose")
        if app.buttons["reader.contents"].exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["reader.contents"].waitForNonExistence(timeout: 5), "the controls are hidden")
        let start = settledWords()
        let page = el("reader.page")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.5)).tap()
        let before = waitForWords(changingFrom: start, timeout: 15)
        XCTAssertNotEqual(opening(before), opening(start), "a tap at the left edge of a chapter's first page didn't turn back")
        XCTAssertFalse(app.buttons["reader.contents"].exists, "the tap showed the controls instead of turning")
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let again = waitForWords(changingFrom: before, timeout: 15)
        XCTAssertEqual(opening(again), opening(start), "the forward turn didn't come back to the chapter's first page")
        page.swipeRight()
        let swiped = waitForWords(changingFrom: again, timeout: 15)
        XCTAssertNotEqual(opening(swiped), opening(start), "a swipe right on a chapter's first page didn't turn back")
    }

    /// A tap on the turn zone while a jump's veil is up is not a turn: the page lands where he chose.
    /// A Contents jump leaves the controls up, and a tap that got past the veil would put them down
    /// (`handleTap`), so the controls still up after it prove the tap was swallowed, not just harmless.
    /// Each wait is judged in reads (gatefold#166): a starved runner's queries take seconds each, and
    /// 10 s for the veil ran out on #182. The chapter's load is held for 800 looks (about 20 s), so the
    /// veil outlasts the slow reads and the tap.
    func testATapWhileAJumpIsUnderWayLandsWhereHeChose() {
        let first = openFresh(["-GatefoldHoldChapterLoad", "800"])
        contentsJump(to: "Chapter XL")
        let veil = el("reader.veil")
        let contents = app.buttons["reader.contents"]
        let up = readsUntil(reads: 100) { veil.exists }
        print("UNDO tapped jump: veil up after \(up.reads) reads")
        XCTAssertTrue(up.ok, "the jump's veil is up")
        XCTAssertTrue(contents.exists, "the controls are up under the veil")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        // One veil a jump: still up after the tap means it was up when the tap landed.
        XCTAssertTrue(veil.exists, "the tap landed under the jump's veil")
        let jump = landed(from: first, reads: 1200)
        print("UNDO tapped jump landed after \(jump.reads) reads")
        XCTAssertTrue(jump.ok, "the jump's veil lifts")
        XCTAssertTrue(contents.exists, "the tap under the veil was swallowed (the controls it would have put down are up)")
        let chosen = settledWords()
        XCTAssertNotEqual(opening(chosen), opening(first))
        // Judged against the entry he chose: Chapter XL starts 0.80 into its file, and a landing on the
        // file's first page (an earlier chapter) was kept as his place (gatefold#166, #254).
        XCTAssertTrue(keptAtChapterXL(), "the tapped jump didn't keep the chapter he chose")
        // The same jump again, untouched, from his first page: the page it lands on is where he chose.
        app.buttons["reader.back"].tap()
        let back = landed(from: chosen, reads: 1200)
        print("UNDO back landed after \(back.reads) reads")
        XCTAssertTrue(back.ok, "Back's veil lifts")
        contentsJump(to: "Chapter XL")
        let again = readsUntil(reads: 100) { veil.exists }
        XCTAssertTrue(again.ok, "the untouched jump's veil is up")
        let untouched = landed(from: back.words, reads: 1200)
        print("UNDO untouched jump: veil up after \(again.reads) reads, landed after \(untouched.reads) reads")
        XCTAssertTrue(untouched.ok, "the untouched jump's veil lifts")
        // The untouched jump is judged first on its own: on #254 it, not the tapped one, stopped on its
        // file's first page.
        XCTAssertTrue(keptAtChapterXL(), "the untouched jump didn't keep the chapter he chose")
        XCTAssertEqual(opening(settledWords()), opening(chosen), "the tapped and the untouched jump to the same chapter landed on different pages")
    }

    /// The place a move of his last kept is Chapter XL's page, in reads: in file h-9, whose anchor for it
    /// is 0.80 of the way into the file's text (the file's start is an earlier chapter), on the page holding
    /// it, which starts within a page before. The app's probe gives a file name and a number, never words.
    private func keptAtChapterXL(reads: Int = 40) -> Bool {
        let probe = el("reader.savedPlace")
        for _ in 0..<reads {
            let parts = ((probe.value as? String) ?? "").split(separator: "@")
            if parts.count == 2, parts[0].contains("-h-9."), let p = Double(parts[1]), abs(p - 0.79) < 0.08 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }
}
