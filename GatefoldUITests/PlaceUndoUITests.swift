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
        XCTAssertTrue(el("reader.veil").waitForNonExistence(timeout: 60), "the veil lifts")
        // Already up (a jump made from them leaves them up), or still fading in: a tap now would put
        // them down.
        let contents = app.buttons["reader.contents"]
        if contents.exists {
            let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: contents)
            if XCTWaiter.wait(for: [hittable], timeout: 2) == .completed { return }
        }
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 5))
    }

    private func contentsJump(to chapter: String) {
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", chapter)).firstMatch
        // The list opens centred on the current chapter, so the first rows are not built yet.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH[c] %@", "Chapter")).firstMatch.waitForExistence(timeout: 10),
                      "the contents list opens")
        for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(row.exists && row.isHittable, "the contents list \(chapter)")
        row.tap()
    }

    /// A Contents jump, then the controls gone: "Back" is on the page, and one tap on it is his page again.
    func testAJumpIsOneTapToUndoWithTheControlsHidden() {
        let first = openFresh()
        contentsJump(to: "Chapter XL")
        let jumped = waitForWords(changingFrom: first, timeout: 30)
        XCTAssertNotEqual(opening(jumped), opening(first), "the jump moved the page")
        if app.buttons["reader.contents"].exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["reader.contents"].waitForNonExistence(timeout: 5), "the controls are hidden")
        let back = app.buttons["reader.back"]
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no way back on the page without opening the controls")
        // Still there a while later: he may notice the jump late.
        RunLoop.current.run(until: Date().addingTimeInterval(10))
        XCTAssertTrue(back.exists, "the way back went away by itself")
        back.tap()
        let returned = waitForWords(changingFrom: jumped, timeout: 30)
        XCTAssertEqual(opening(returned), opening(first), "Back did not return to his page")
        // And Back itself is one tap to undo.
        XCTAssertTrue(app.buttons["reader.back"].waitForExistence(timeout: 5), "going back can't be undone")
        // And the page still answers: a tap in its middle brings the controls up.
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 5), "after Back a tap no longer shows the controls")
    }

    /// Back to a chapter still loading takes him back once it has loaded: on CI's iPad (job 129949744000,
    /// gatefold#170) Back gave up and he stayed where he had jumped to. Every jump's load is held open
    /// (`-GatefoldHoldChapterLoad`; each look of the veil spends two, so 1600 is 800 looks, past Back's
    /// 150 plain reads). The veil may let go at its limit meanwhile (the chapter shows its own loading);
    /// the trip goes on. Judged in samples of the held load.
    func testBackToAChapterStillLoadingWaitsForItAndTakesHimBack() {
        let first = openFresh(["-GatefoldHoldChapterLoad", "1600"])
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
        var samples = 0, bare = 0
        while held.exists, samples < 1200 {
            samples += 1
            if !veil.exists, held.exists { bare += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("BACKHELD samples=\(samples) veilGoneWhileLoading=\(bare) heldAtEnd=\(held.exists)")
        XCTAssertFalse(held.exists, "the held load never ended")
        XCTAssertTrue(veil.waitForNonExistence(timeout: 30), "Back's veil lifted once the chapter had loaded")
        let returned = waitForWords(changingFrom: jumped, timeout: 30)
        XCTAssertEqual(opening(returned), opening(first), "Back did not return to his page")
        XCTAssertNotEqual(back.label, "Couldn't go back. Try again")
    }

    /// A Contents jump whose chapter load never ends: the veil lets go at its limit (about 30 s), his
    /// page stays on screen and answers his taps; the screen is never frozen behind it (gatefold#173).
    func testAContentsJumpThatNeverLoadsLetsTheVeilGo() {
        let first = openFresh(["-GatefoldHangLinkJumps", "1"])
        let veil = el("reader.veil")
        contentsJump(to: "Chapter XL")
        XCTAssertTrue(veil.waitForExistence(timeout: 10), "the jump put up no veil")
        // The veil's limit is 150 beats of 200 ms; well past it, it must have let go.
        XCTAssertTrue(veil.waitForNonExistence(timeout: 90), "the veil froze the screen past its limit")
        let shown = waitForWords()
        XCTAssertEqual(opening(shown), opening(first), "the jump that never came back moved the page")
        // His taps reach the page again: one brings the controls up.
        if !app.buttons["reader.contents"].exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 10), "a tap on the page after the veil let go brought no controls")
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
    func testATapWhileAJumpIsUnderWayLandsWhereHeChose() {
        let first = openFresh(["-GatefoldHoldChapterLoad", "60"])
        contentsJump(to: "Chapter XL")
        let veil = el("reader.veil")
        XCTAssertTrue(veil.waitForExistence(timeout: 10), "the jump's veil is up")
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(veil.waitForNonExistence(timeout: 60))
        let landed = settledWords()
        XCTAssertNotEqual(opening(landed), opening(first))
        // The same jump again, untouched, from his first page: the page it lands on is where he chose.
        app.buttons["reader.back"].tap()
        _ = waitForWords(changingFrom: landed, timeout: 30)
        contentsJump(to: "Chapter XL")
        XCTAssertTrue(veil.waitForExistence(timeout: 10))
        XCTAssertTrue(veil.waitForNonExistence(timeout: 60))
        XCTAssertEqual(opening(settledWords()), opening(landed), "a tap during the jump moved the page off where he chose")
    }
}
