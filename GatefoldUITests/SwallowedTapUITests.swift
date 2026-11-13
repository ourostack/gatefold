import XCTest

/// Every tap on the page gets an answer: a turn at its edge, the controls in its middle. Build 25's spazz runs
/// swiped a freshly opened book a few pages on and back, and then no tap on the page did anything at all, with no
/// tap in the reader's log, until a rotation laid the page out again (gatefold#321). Judged in answered taps and
/// reads, never in seconds.
@MainActor
final class SwallowedTapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTapsAfterSwipesOnAFreshBookAreAnswered() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldAllowReopen", "YES", "-GatefoldDownloadAll", "YES",
        ]
        app.launch()
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        // As the spazz run: opened from the shelf, its page warmed behind it.
        let cover = el("book.gutenberg-pride-and-prejudice")
        XCTAssertTrue(readsUntil(reads: Self.reads, "the shelf shows the book") { cover.exists }.ok, "the shelf shows the book")
        for _ in 0..<8 where !cover.isHittable { el("library.grid").swipeUp() }
        cover.tap()
        let page = el("reader.page")
        XCTAssertTrue(readsUntil(reads: Self.reads, "the reader opens") { page.exists }.ok, "the reader opens")
        // Opened at its start, the book has no words to anchor yet (`reader.anchorCheck` stays pending): its page is ready.
        let probe = el("reader.pageReady")
        XCTAssertTrue(readsUntil(reads: Self.reads, "the page is ready") { (probe.value as? String) == "1" }.ok, "the page is ready")
        let close = app.buttons["reader.close"].firstMatch
        func screen(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        // The spazz run's look round Your Page: the controls, Your Page, Fine-Tune, and a tap above the panel to put it away.
        screen(0.5, 0.5).tap()
        XCTAssertTrue(readsUntil(reads: Self.reads, "the controls come up") { close.exists }.ok, "the controls come up")
        let appearance = app.buttons["reader.appearance"].firstMatch
        if appearance.exists {
            appearance.tap()
            let panel = el("appearance.panel")
            _ = readsUntil(reads: Self.reads, "Your Page opens") { panel.exists }
            let fine = app.buttons["appearance.customize"].exists ? app.buttons["appearance.customize"] : app.buttons["Fine-Tune"].firstMatch
            if fine.exists { fine.tap() }
            screen(0.5, 0.1).tap()
            let gone = readsUntil(reads: Self.reads, "Your Page goes") { !panel.exists }
            print("SWALLOWED panel gone after a tap above it: \(gone.ok) after \(gone.reads) reads")
        }
        if close.exists { screen(0.5, 0.5).tap(); _ = readsUntil(reads: Self.reads, "the controls go") { !close.exists } }

        let report = el("reader.turnPlacement")
        func landed() -> Int {
            let words = report.label.split(separator: " ")
            return words.first == "landed" && words.count > 1 ? Int(words[1]) ?? 0 : 0
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { screen(x, y) }

        // The spazz run's first round: four quick swipes on, one back, each waited for in counted turns.
        for (i, forward) in [true, true, true, true, false].enumerated() {
            let before = landed()
            if forward { at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: at(0.25, 0.5)) } else { at(0.25, 0.5).press(forDuration: 0.05, thenDragTo: at(0.75, 0.5)) }
            let turned = readsUntil(reads: Self.reads, "swipe \(i + 1) turns") { landed() > before }
            print("SWALLOWED swipe \(i + 1) turned=\(turned.ok) after \(turned.reads) reads (landed \(landed()))")
        }

        // Then taps on the middle of the page: each must bring the controls up, and a second tap take them down.
        let taps: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.3, 0.5), (0.7, 0.5), (0.5, 0.25), (0.5, 0.75)]
        var answered = 0
        for (i, (x, y)) in taps.enumerated() {
            at(x, y).tap()
            let up = readsUntil(reads: Self.answerReads, "tap \(i + 1) brings the controls") { close.exists }
            print("SWALLOWED tap \(i + 1) at \(x),\(y): controls=\(up.ok) after \(up.reads) reads")
            guard up.ok else { continue }
            answered += 1
            at(0.5, 0.5).tap()
            XCTAssertTrue(readsUntil(reads: Self.reads, "the controls go after tap \(i + 1)") { !close.exists }.ok, "the controls go after tap \(i + 1)")
        }
        // An edge tap turns: on the page's own edge (the portrait iPad's page is narrower than the window).
        let before = landed()
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let turned = readsUntil(reads: Self.answerReads, "the edge tap turns") { landed() > before || close.exists }
        let edgeTurned = landed() > before
        print("SWALLOWED edge tap turned=\(edgeTurned) after \(turned.reads) reads")
        print("SWALLOWED answered \(answered + (edgeTurned ? 1 : 0)) of \(taps.count + 1) taps")
        XCTAssertEqual(answered + (edgeTurned ? 1 : 0), taps.count + 1, "every tap after the swipes is answered")
    }

    /// The reads a wait may take. Each read waits at least 0.1 s.
    private static let reads = 300
    /// The reads a tap's answer may take: a tap the page heard answers within a few reads (#304's probes: 1 to 3).
    private static let answerReads = 50

    /// As SpreadTurnSettleUITests: the hang guard (`HangGuard`) ends only a hang, and fails naming the wait.
    private func readsUntil(reads: Int, _ what: String, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds {
                XCTFail("hang: \(what): \(read) of its \(reads) reads ran past the hang guard")
                return (false, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }
}
