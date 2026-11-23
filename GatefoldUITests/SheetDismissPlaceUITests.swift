import UIKit
import XCTest

/// Closing a sheet without choosing is not a move (gatefold#535). Build 46's review on the folded Duo's cover screen
/// opened Contents, scrolled it, pulled it away and found his place two chapters off; closing Fine-Tune after
/// Justify moved it too. Contents closed without a row chosen leaves the very page he was on; Justify reflows the
/// page, which may break it elsewhere, but his first whole words stay on screen, as a rotation keeps them.
/// Pages are compared by a hash of their words, never the words (no book text in a log). Judged in reads.
@MainActor
final class SheetDismissPlaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// The Contents list's chapter rows, his current one included.
    private var contentsRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "contents.current", "contents.entry."))
    }

    private func words(_ text: String) -> [Substring] { text.split(whereSeparator: \.isWhitespace) }
    /// The words that open the page.
    private func opening(_ text: String) -> String { words(text).prefix(12).joined(separator: " ") }
    /// A page's words as a hash, for logs and messages: FNV-1a over the opening.
    private func hash(_ text: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for b in opening(text).utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
        return String(format: "%08x", h)
    }

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

    /// Opens the book fresh at `at` of the way through and returns its settled page.
    private func open(at: String) -> String {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", at]
        app.launch()
        let page = ReaderReads.settle(app, "the opened page") { print("SHEETPLACE \($0)") }.words
        let window = app.windows.firstMatch.frame
        print("SHEETPLACE opened \(hash(page)) in a \(Int(window.width))x\(Int(window.height)) window")
        return page
    }

    /// Taps the page's middle until the controls show `button`: a tap, then up to 10 reads for them, 4 times.
    private func showChrome(_ button: String) {
        var shown = (ok: false, reads: 0, hung: false)
        for _ in 0..<4 where !app.buttons[button].exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            shown = readsUntil(reads: 10) { app.buttons[button].exists }
            if shown.hung { break }
        }
        XCTAssertTrue(app.buttons[button].exists, "the controls came up with \(button)\(shown.hung ? " (hang guard)" : "")")
    }

    private func openContents() {
        showChrome("reader.contents")
        app.buttons["reader.contents"].tap()
        let up = readsUntil(reads: 60) { contentsRows.firstMatch.exists }
        XCTAssertTrue(up.ok, "Contents opened within \(up.reads) reads\(up.hung ? " (hang guard)" : "")")
    }

    /// Scrolls the list a long way, as his flick did, and waits for it to stop coasting.
    private func scrollContents() {
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.exists, "the Contents list")
        list.swipeUp(velocity: .fast)
        list.swipeUp(velocity: .fast)
        var last = "", same = 0
        let still = readsUntil(reads: 60) {
            let now = contentsRows.allElementsBoundByIndex.prefix(3).map(\.identifier).joined(separator: ",")
            same = now == last ? same + 1 : 0
            last = now
            return same >= 3
        }
        XCTAssertTrue(still.ok, "the list stopped within \(still.reads) reads\(still.hung ? " (hang guard)" : "")")
    }

    /// Waits for Contents to be gone: no row and no list left.
    private func expectContentsClosed(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = readsUntil(reads: 60) { !contentsRows.firstMatch.exists && !app.collectionViews.firstMatch.exists }
        XCTAssertTrue(gone.ok, "\(how) closed Contents within \(gone.reads) reads\(gone.hung ? " (hang guard)" : "")", file: file, line: line)
    }

    private func expectSamePage(as before: String, _ how: String, file: StaticString = #filePath, line: UInt = #line) {
        let after = ReaderReads.settle(app, "the page after \(how)") { print("SHEETPLACE \($0)") }.words
        print("SHEETPLACE \(how): \(hash(before)) -> \(hash(after)); back up \(el("reader.back").exists)")
        XCTAssertEqual(hash(after), hash(before), "\(how) moved the page (\(hash(before)) to \(hash(after)))", file: file, line: line)
        XCTAssertFalse(el("reader.back").exists, "\(how) left a Back to return from", file: file, line: line)
    }

    /// Contents opened, flicked well away from his chapter and pulled down by its top: the same page.
    func testPullingContentsAwayAfterScrollingKeepsThePage() {
        let before = open(at: "0.52")
        openContents()
        scrollContents()
        // His pull starts at the sheet's top, above the list, and goes to the screen's foot. Before gatefold#535 the
        // top was a navigation bar the list scrolled under: the same pull from that bar scrolled the list back and
        // left Contents up (this test, pulling from `app.navigationBars`, failed there on main at 361cb372).
        let header = el("contents.header")
        XCTAssertTrue(header.exists, "Contents' header")
        let from = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.98))
        from.press(forDuration: 0.05, thenDragTo: to)
        expectContentsClosed("a pull down")
        expectSamePage(as: before, "Contents scrolled and pulled away")
    }

    /// Contents opened, flicked and closed with its close button: the same page.
    func testClosingContentsAfterScrollingKeepsThePage() {
        let before = open(at: "0.52")
        openContents()
        scrollContents()
        let close = app.buttons["contents.close"].firstMatch
        XCTAssertTrue(close.exists, "Contents' close button")
        close.tap()
        expectContentsClosed("the close button")
        expectSamePage(as: before, "Contents scrolled and closed")
    }

    /// Fine-Tune's Justify flipped, then the panel closed by a tap off it: the page reflows, and the first whole
    /// words he had at the top of the page are still on it.
    func testClosingFineTuneAfterJustifyKeepsHisWords() {
        let before = open(at: "0.6")
        // The first word can be the end of one begun on the page before: his first whole words follow it.
        let his = words(before).dropFirst().prefix(6).joined(separator: " ")
        XCTAssertFalse(his.isEmpty, "the page had words")
        showChrome("reader.appearance")
        app.buttons["reader.appearance"].tap()
        let fineTune = app.buttons["appearance.customize"]
        let offered = readsUntil(reads: 40) { fineTune.exists }
        XCTAssertTrue(offered.ok, "Your Page's Fine-Tune within \(offered.reads) reads\(offered.hung ? " (hang guard)" : "")")
        if !fineTune.isHittable { el("appearance.panel").swipeUp() }
        fineTune.tap()
        let justify = app.switches["appearance.justify"].firstMatch
        let listed = readsUntil(reads: 40) { justify.exists }
        XCTAssertTrue(listed.ok, "Justify within \(listed.reads) reads\(listed.hung ? " (hang guard)" : "")")
        let panel = el("appearance.panel")
        for _ in 0..<4 where !justify.isHittable { panel.swipeUp() }
        let was = (justify.value as? String) ?? "?"
        let reflowBefore = ReaderReads.reflowNumber(app)
        justify.press(forDuration: 0)
        let flipped = readsUntil(reads: 40) { ((justify.value as? String) ?? "?") != was }
        XCTAssertTrue(flipped.ok, "Justify changed within \(flipped.reads) reads\(flipped.hung ? " (hang guard)" : "")")
        XCTAssertNotNil(ReaderReads.reflowSettled(app, since: reflowBefore, "Justify") { print("SHEETPLACE \($0)") },
                        "Justify's reflow settled")
        // Closed by a tap off the panel: above it, or beside it where the panel leaves room.
        let frame = panel.frame, window = app.windows.firstMatch.frame
        let off = frame.minY > 60 ? CGVector(dx: window.midX, dy: frame.minY / 2)
            : CGVector(dx: (frame.maxX + window.maxX) / 2, dy: window.midY)
        app.coordinate(withNormalizedOffset: .zero).withOffset(off).tap()
        let closed = readsUntil(reads: 40) { !panel.exists }
        XCTAssertTrue(closed.ok, "a tap off the panel closed it within \(closed.reads) reads\(closed.hung ? " (hang guard)" : "")")
        let after = ReaderReads.settle(app, "the page after Justify") { print("SHEETPLACE \($0)") }.words
        let kept = words(after).joined(separator: " ").contains(his)
        print("SHEETPLACE Justify: \(hash(before)) -> \(hash(after)); his first words still on screen \(kept)")
        XCTAssertTrue(kept, "after Justify and a close, his first whole words left the page (\(hash(before)) to \(hash(after)))")
    }
}
