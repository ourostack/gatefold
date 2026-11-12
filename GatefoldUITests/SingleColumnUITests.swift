import UIKit
import XCTest

/// A one-page screen is always one column (gatefold#303). Build 25's review saw the folded Duo's cover screen and
/// a portrait iPad laid out as two cramped columns mid-reading. Every one of those spreads followed a tap in the
/// page's top margin, at its centre, where the UI tests' hidden posture switch for a spread sat; the forced spread
/// then held through folds, scrubs, Contents and turns until the book was closed. This walks the review's steps
/// (turns, a turn then a top-centre tap, a scrub, a Contents round trip, a reopen) and, on every page shown,
/// reads the web view's own count of the text columns on screen (`reader.columns`). Judged in reads, never seconds.
@MainActor
final class SingleColumnUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldColumnsProbe", "YES",
        "-GatefoldTheme", "vellum",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var page: XCUIElement { el("reader.page") }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private var columns: String { (el("reader.columns").value as? String) ?? "" }

    /// Reads of the app until `done`, each at least 0.2 s apart; the hang guard only catches a hang.
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > guardEnds { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (false, reads, false)
    }

    /// Once the page's words and its column count have read the same five times running, the page shown is one
    /// column: the web view's lines (`columns 1`) and the layout the reader asked Readium for (`layout 1`).
    private func expectOneColumn(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        var last = "", same = 0
        let still = readsUntil(reads: 300) {
            let now = words + "|" + columns
            same = now == last && !words.isEmpty && !columns.isEmpty ? same + 1 : 0
            last = now
            return same >= 4
        }
        let measure = columns
        print("COLUMNS \(step): \(measure) (still \(still.ok) after \(still.reads) reads\(still.hung ? ", hang guard" : ""))")
        XCTAssertTrue(still.ok, "\(step): the page settled within \(still.reads) reads (columns \(measure))", file: file, line: line)
        XCTAssertTrue(measure.hasPrefix("columns 1 "), "\(step): the web view shows one column of text: \(measure)", file: file, line: line)
        XCTAssertFalse(measure.contains(" css 2 "), "\(step): Readium was asked for two columns: \(measure)", file: file, line: line)
        XCTAssertTrue(measure.hasSuffix(" layout 1"), "\(step): the reader's layout is two columns: \(measure)", file: file, line: line)
        XCTAssertEqual(el("reader.posture").label, "single", "\(step): the posture on a one-page screen", file: file, line: line)
    }

    private func turn(forward: Bool = true) {
        let before = words
        page.coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.93 : 0.07, dy: 0.5)).tap()
        _ = readsUntil(reads: 100) { words != before && !words.isEmpty }
    }

    private func hideControls() {
        let contents = app.buttons["reader.contents"]
        for _ in 0..<3 where contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { !contents.exists }
        }
    }

    private func showControls() {
        let contents = app.buttons["reader.contents"]
        for _ in 0..<3 where !contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { contents.exists && contents.isHittable }
        }
        XCTAssertTrue(contents.exists, "the controls come up")
    }

    /// The review's "turn-then-top-tap": a tap in the page's top margin at its centre, where the running head is.
    private func topCentreTap() {
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 26)).tap()
        _ = readsUntil(reads: 10) { false }
        hideControls()
    }

    func testAOnePageScreenStaysOneColumnThroughTheReviewSteps() throws {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book opened")
        let size = app.windows.firstMatch.frame.size
        try XCTSkipIf(size.width > size.height, "a \(Int(size.width)) x \(Int(size.height)) screen is not a one-page screen")
        XCTAssertTrue(readsUntil(reads: 450) { el("reader.anchorCheck").label.hasPrefix("ready") }.ok, "the first page is ready")
        expectOneColumn("opened")

        turn()
        expectOneColumn("a turn")

        for k in 1...3 {
            turn()
            topCentreTap()
            expectOneColumn("turn then top-centre tap #\(k)")
        }

        showControls()
        let scrubber = el("reader.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "the scrubber")
        let before = words
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        _ = readsUntil(reads: 150) { words != before && !words.isEmpty }
        hideControls()
        expectOneColumn("after a scrub")
        topCentreTap()
        expectOneColumn("after a scrub, a top-centre tap")

        showControls()
        app.buttons["reader.contents"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10),
                      "the contents opened")
        app.swipeDown(velocity: .fast)
        _ = readsUntil(reads: 50) { !app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.exists }
        hideControls()
        expectOneColumn("Contents opened and closed")
        turn()
        topCentreTap()
        expectOneColumn("after Contents, a turn then a top-centre tap")

        // Leave and come back: the reopen lays the page out again, on the same screen.
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        app.quit()
        app.launchArguments = common
        app.relaunch()
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book reopened")
        expectOneColumn("reopened")
        turn()
        topCentreTap()
        expectOneColumn("reopened, a turn then a top-centre tap")
        turn(forward: false)
        expectOneColumn("reopened, a turn back")
    }
}
