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

    private func openFresh(_ extra: [String] = []) -> String {
        app.launchArguments = common + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                                "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
            // GATEFOLD_POSTURE=spread runs the same checks on the unfolded Duo.
            + (ProcessInfo.processInfo.environment["GATEFOLD_POSTURE"].map { ["-GatefoldForcePosture", $0] } ?? [])
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 90))
        return settledWords()
    }

    private func showChrome() {
        // A tap under a jump's veil is swallowed (the veil is the page changing), so wait it out.
        XCTAssertTrue(el("reader.veil").waitForNonExistence(timeout: 60), "the veil lifts")
        // Already up (a jump made from them leaves them up): a tap now would put them down.
        if app.buttons["reader.contents"].exists { return }
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
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.07, dy: 0.5)).tap()
        let back = waitForWords(changingFrom: ahead, timeout: 15)
        XCTAssertEqual(opening(back), opening(first), "a tap at x 0.07 on the spread didn't turn back")
        XCTAssertFalse(app.buttons["reader.contents"].exists, "the tap showed the controls instead of turning")
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
