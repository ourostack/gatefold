import XCTest

/// The scrubber says where the page is. The review panel of 2026-11-22 found them apart on the iPad: after a scrubber
/// jump the thumb stood at the jump's target over the page he had left (ipad-dark-09/10), and after a search jump the
/// thumb fell to the book's start over the match's page (ipad-dark-12, ipad-light-12). Each place is a fraction of the
/// book: the thumb's, and the page's from the navigator's report (`reader.scrubberThumb`). Judged in reads.
@MainActor
final class ScrubberPlaceUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { app.terminate() }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func readsUntil(reads: Int, _ done: () -> Bool) -> Bool {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for _ in 1...reads {
            if done() { return true }
            if Date() > guardEnds { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return false
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func controlsUp() {
        for _ in 0..<4 where !el("reader.scrubber").exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 10) { el("reader.scrubber").exists }
        }
        XCTAssertTrue(el("reader.scrubber").exists, "the controls came up")
    }

    /// The thumb's place and the page's, once they have held for 2 s (or the reads ran out).
    private func places() -> (thumb: Double, page: Double)? {
        func read() -> (Double, Double)? {
            let parts = (el("reader.scrubberThumb").value as? String ?? "").split(separator: " ")
            guard parts.count == 4, let t = Double(parts[1]), let p = Double(parts[3]) else { return nil }
            return (t, p)
        }
        var last: (Double, Double)?, since = Date()
        _ = readsUntil(reads: 150) {
            let now = read()
            if now.map({ "\($0)" }) != last.map({ "\($0)" }) { last = now; since = Date() }
            return now != nil && Date().timeIntervalSince(since) > 2
        }
        return last
    }

    private func expectTogether(_ what: String) {
        controlsUp()
        guard let at = places() else { return XCTFail("\(what): no reading of the scrubber") }
        print("SCRUBBERPLACE \(what): thumb \(at.thumb) page \(at.page)")
        shot(what)
        XCTAssertGreaterThanOrEqual(at.page, 0, "\(what): the page is placed in the book")
        XCTAssertEqual(at.thumb, at.page, accuracy: 0.02, "\(what): the thumb stands where the page is")
    }

    func testTheScrubberStandsWhereThePageIsAfterEachJump() {
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                               "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(readsUntil(reads: 1500) { (el("reader.pageReady").value as? String) == "1" }, "the book opened")
        controlsUp()
        let scrubber = el("reader.scrubber")
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)))
        expectTogether("after-scrubber-jump")

        controlsUp()
        app.buttons["reader.search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(readsUntil(reads: 100) { field.exists }, "Search opened")
        field.tap()
        field.typeText("Darcy")
        let result = app.buttons["search.result"].firstMatch
        XCTAssertTrue(readsUntil(reads: 150) { result.exists }, "a result")
        result.tap()
        XCTAssertTrue(readsUntil(reads: 100) { !field.exists }, "Search closed on the jump")
        expectTogether("after-search-jump")
    }
}
