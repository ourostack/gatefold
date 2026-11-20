import XCTest

/// No control stands on a line of text with nothing behind it (gatefold#538). Build 46's review saw the folded Duo's
/// cover screen with the controls up: the trailing column (Contents, Share, Your Page, Search) stood on the page's
/// lines, words running under it, because the paper beneath the controls only reached the height of the bottom bar.
/// On the iPad the column stands in the margin beside a page inset to a book's measure. With the controls up, this
/// reads `reader.chromeOverText`: for every floating control, the lines of text the web view has under it, and those
/// of them no paper covers. Judged in reads, never seconds.
@MainActor
final class ChromeBackingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var page: XCUIElement { el("reader.page") }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private var overText: String { (el("reader.chromeOverText").value as? String) ?? "" }

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

    private func showControls() {
        let contents = app.buttons["reader.contents"]
        for _ in 0..<3 where !contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { contents.exists && contents.isHittable }
        }
        XCTAssertTrue(contents.exists, "the controls come up")
    }

    private func hideControls() {
        let contents = app.buttons["reader.contents"]
        for _ in 0..<3 where contents.exists {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = readsUntil(reads: 25) { !contents.exists }
        }
    }

    /// The most lines the column has stood over in any step, paper or not: above zero shows the page ran under it,
    /// so `bare 0` means the paper covered them, not that no line was there to cover.
    private var mostUnderTheColumn = 0

    /// `reader.chromeOverText` is `pass N: name under/bare, ...`, cleared whenever the paper is measured afresh.
    /// Once the last pass (3) has read the same five times running, the column is among the pieces and no piece
    /// has a line showing under it.
    private func expectBacked(_ step: String, file: StaticString = #filePath, line: UInt = #line) {
        var last = "", same = 0
        let still = readsUntil(reads: 150) {
            let now = overText
            same = now == last && now.hasPrefix("pass 3: ") && !words.isEmpty ? same + 1 : 0
            last = now
            return same >= 4
        }
        let measure = overText
        print("CHROME \(step): \(measure) (still \(still.ok) after \(still.reads) reads\(still.hung ? ", hang guard" : ""))")
        XCTAssertTrue(still.ok, "\(step): the measure settled within \(still.reads) reads (\(measure))", file: file, line: line)
        var pieces: [String: (under: Int, bare: Int)] = [:]
        for piece in measure.dropFirst("pass 3: ".count).split(separator: ",") {
            let parts = piece.trimmingCharacters(in: .whitespaces).split(separator: " ")
            let counts = parts.last?.split(separator: "/").compactMap { Int($0) } ?? []
            guard parts.count == 2, counts.count == 2 else { continue }
            pieces[String(parts[0])] = (counts[0], counts[1])
        }
        guard let column = pieces["column"] else {
            return XCTFail("\(step): the column's place was read: \(measure)", file: file, line: line)
        }
        mostUnderTheColumn = max(mostUnderTheColumn, column.under)
        let bare = pieces.filter { $0.value.bare > 0 }.map(\.key).sorted()
        XCTAssertTrue(bare.isEmpty, "\(step): \(bare.joined(separator: ", ")) stand on lines with nothing behind them: \(measure)",
                      file: file, line: line)
    }

    func testTheControlsNeverStandOnBareText() throws {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldChromeBackingProbe", "YES", "-GatefoldTheme", "vellum",
            "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
        ]
        app.launch()
        XCTAssertTrue(page.waitForExistence(timeout: 60), "the book opened")
        let size = app.windows.firstMatch.frame.size
        try XCTSkipIf(size.width > size.height, "a \(Int(size.width)) x \(Int(size.height)) screen is not a one-page screen")
        XCTAssertTrue(readsUntil(reads: 450) { el("reader.anchorCheck").label.hasPrefix("ready") }.ok, "the first page is ready")

        showControls()
        expectBacked("opened")

        // Another page lays its lines out elsewhere under the column.
        hideControls()
        let before = words
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        XCTAssertTrue(readsUntil(reads: 100) { words != before && !words.isEmpty }.ok, "the turn landed")
        showControls()
        expectBacked("after a turn")

        // A scrub brings the Back pill up above the scrubber, which raises the paper at the foot.
        let scrubber = el("reader.scrubber")
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5), "the scrubber")
        let beforeScrub = words
        scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: 0.5)))
        XCTAssertTrue(readsUntil(reads: 150) { words != beforeScrub && !words.isEmpty }.ok, "the scrub moved the page")
        showControls()
        XCTAssertTrue(app.buttons["reader.back"].waitForExistence(timeout: 10), "the Back pill")
        expectBacked("after a scrub, with Back up")
        XCTAssertGreaterThan(mostUnderTheColumn, 0, "the page ran under the column in some step, so the paper had lines to cover")
    }
}
