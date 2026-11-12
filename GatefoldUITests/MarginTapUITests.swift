import XCTest

/// On a freshly opened landscape spread, a tap in a page's outer margin turns it, every time, and a tap on the
/// middle of a page shows the controls. Build 25's reviewers tapped the iPad spread at 7% and 93% of its width and
/// got the controls 9 times out of 9: the turn zone stopped 88 pt in, inside the 69 pt margin and 19 pt of text
/// (gatefold#304). Judged in counted turns (`reader.turnPlacement`'s `landed N`) and reads, never in seconds.
@MainActor
final class MarginTapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    func testEveryMarginTapOnAFreshSpreadTurns() throws {
        // The Duo's spread needs a hinge the UI test can't move (real-unfold.yml); its 951 pt spread's zone is in
        // GatefoldCore's TapZonesTests.
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The landscape spread runs on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "curl",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(readsUntil(reads: Self.reads, "the reader opens") { page.exists }.ok, "the reader opens")
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        let ready = readsUntil(reads: Self.reads, "the reader is ready") { probe.exists && probe.label.hasPrefix("ready") }
        XCTAssertTrue(ready.ok, "the reader is ready within \(Self.reads) reads: \(probe.label)")
        let posture = app.descendants(matching: .any)["reader.posture"]
        XCTAssertEqual(posture.label, "spread", "the iPad on its side lays out a spread")

        let report = app.descendants(matching: .any)["reader.turnPlacement"]
        let close = app.buttons["reader.close"].firstMatch
        func landed() -> Int {
            let words = report.label.split(separator: " ")
            return words.first == "landed" && words.count > 1 ? Int(words[1]) ?? 0 : 0
        }
        func hideControls(_ what: String) {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(readsUntil(reads: Self.reads, "the controls go after \(what)") { !close.exists }.ok, "the controls go after \(what)")
        }

        // The reviewers' margin taps (7%, 93%, and the spazz runs' 3%, 90% and 97%), forward then back, from the
        // first tap after the page is ready.
        let taps: [CGFloat] = [0.93, 0.90, 0.97, 0.93, 0.07, 0.03, 0.07]
        var turned = 0
        for (i, x) in taps.enumerated() {
            let before = landed()
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            // A verdict either way: the turn lands, or the controls come up in its place.
            let verdict = readsUntil(reads: Self.reads, "margin tap \(i + 1) at \(x)") { landed() > before || close.exists }
            let didTurn = landed() == before + 1
            if didTurn { turned += 1 }
            print("MARGINTAP \(i + 1) at \(x): turned=\(didTurn) controls=\(close.exists) after \(verdict.reads) reads (\(report.label))")
            // No verdict at all: the tap never reached the page. Counted as a miss, and the rest would only wait as long.
            if !verdict.ok { break }
            if close.exists { hideControls("margin tap \(i + 1)") }
        }
        print("MARGINTAPS turned \(turned) of \(taps.count)")

        // The middle of either page still shows the controls, and turns nothing.
        for x in [0.5, 0.3, 0.7] as [CGFloat] {
            let before = landed()
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let up = readsUntil(reads: Self.reads, "the controls come up at \(x)") { close.exists || landed() > before }
            print("MIDDLETAP at \(x): controls=\(close.exists) landed \(before)->\(landed()) after \(up.reads) reads")
            XCTAssertTrue(close.exists, "a tap at \(x) of the width shows the controls")
            XCTAssertEqual(landed(), before, "a tap at \(x) of the width turns nothing")
            hideControls("the tap at \(x)")
        }

        XCTAssertEqual(turned, taps.count, "every margin tap on a fresh spread turns: \(turned) of \(taps.count) did")
    }

    /// The reads a wait may take. Each read waits at least 0.1 s, so a fast runner gets at least 30 s; a slow one
    /// gets as many reads, however long each takes.
    private static let reads = 300

    /// As SpreadTurnSettleUITests: the hang guard (`HangGuard`, sized from `reads`) ends only a hang, and fails naming
    /// the wait (`what`).
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
