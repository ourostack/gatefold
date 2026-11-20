import UIKit
import XCTest

/// Contents closes the way a reader's sheet does: a swipe down from its header, a swipe down in the list once it is at
/// its top, or a pull that takes the list past its top. Flicking through the list never closes it. Build 47's review
/// swiped down fast and pulled down from inside the list, on iPad and on the folded Duo, and Contents stayed up every
/// time: both began in a list scrolled away from its top, so they scrolled it back and stretched it past the top, and
/// the sheet never took them over. The swipes from the header and from the list's top passed before the change too;
/// the pull past the top failed on both devices. Closed without a row chosen, Contents leaves the very page he was on.
/// Pages are compared by a hash of their words, never the words (no book text in a log). Judged in reads.
@MainActor
final class ContentsCloseUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// The Contents list's chapter rows, his current one included.
    private var contentsRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "contents.current", "contents.entry."))
    }
    private var list: XCUIElement { app.collectionViews.firstMatch }
    /// The book's first chapter row: on screen only when the list is at (or near) its top.
    private var firstRow: XCUIElement { el("contents.entry.0") }

    private func hash(_ text: String) -> String {
        var h: UInt32 = 0x811C_9DC5
        for b in text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ").utf8 { h = (h ^ UInt32(b)) &* 0x0100_0193 }
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

    /// Opens the book fresh half way through, its Contents list opening on a chapter far from the top, and returns the
    /// settled page.
    private func open() -> String {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.52"]
        app.launch()
        let page = ReaderReads.settle(app, "the opened page") { print("CONTENTSCLOSE \($0)") }.words
        let window = app.windows.firstMatch.frame
        print("CONTENTSCLOSE opened \(hash(page)) in a \(Int(window.width))x\(Int(window.height)) window")
        return page
    }

    private func openContents() {
        var shown = (ok: false, reads: 0, hung: false)
        for _ in 0..<4 where !app.buttons["reader.contents"].exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            shown = readsUntil(reads: 10) { app.buttons["reader.contents"].exists }
            if shown.hung { break }
        }
        XCTAssertTrue(app.buttons["reader.contents"].exists, "the controls came up\(shown.hung ? " (hang guard)" : "")")
        app.buttons["reader.contents"].tap()
        let up = readsUntil(reads: 60) { contentsRows.firstMatch.exists }
        XCTAssertTrue(up.ok, "Contents opened within \(up.reads) reads\(up.hung ? " (hang guard)" : "")")
        XCTAssertTrue(list.exists, "the Contents list")
        XCTAssertFalse(firstRow.exists, "Contents opened on his chapter, away from the list's top")
    }

    /// Waits until the list has stopped coasting: the same rows at the same heights for three reads.
    private func waitForStill(file: StaticString = #filePath, line: UInt = #line) {
        var last = "", same = 0
        let still = readsUntil(reads: 60) {
            let now = contentsRows.allElementsBoundByIndex.prefix(3).map { "\($0.identifier)@\(Int($0.frame.minY))" }.joined(separator: ",")
            same = now == last ? same + 1 : 0
            last = now
            return same >= 3
        }
        XCTAssertTrue(still.ok, "the list stopped within \(still.reads) reads\(still.hung ? " (hang guard)" : "")", file: file, line: line)
    }

    /// Contents is still up after the list has settled: a gesture that must not close it didn't.
    private func expectStillUp(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
        waitForStill(file: file, line: line)
        let up = contentsRows.firstMatch.exists && list.exists
        print("CONTENTSCLOSE \(how): still up \(up)")
        XCTAssertTrue(up, "\(how) closed Contents", file: file, line: line)
    }

    /// A swipe, in pixels a second. `XCUIGestureVelocity.fast` and `.slow` are markers that only `swipeDown(velocity:)`
    /// and its kin understand (they read -30 and -20); handed to a drag, they jump the finger to its end with no
    /// speed, and no sheet or list takes that for a swipe.
    private let swipe = XCUIGestureVelocity(2000)
    /// A pull, slow enough that the finger, not a flick, carries it.
    private let pull = XCUIGestureVelocity(400)

    /// A finger on the list, `dy` points down (negative: up), released while still moving: a flick.
    private func flick(dy: CGFloat) {
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy > 0 ? 0.25 : 0.75))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: dy)), withVelocity: swipe, thenHoldForDuration: 0)
    }

    /// Flicks the list down until its first chapter shows, each a short flick from a list not yet at its top, so the
    /// list's own coasting carries it there, not his finger; then waits for it to rest.
    private func flickToTop() {
        for _ in 0..<30 where !firstRow.exists {
            flick(dy: 120)
            RunLoop.current.run(until: Date().addingTimeInterval(1))
            XCTAssertTrue(contentsRows.firstMatch.exists, "a flick toward the list's top closed Contents")
        }
        waitForStill()
        XCTAssertTrue(firstRow.exists, "the list reached its top")
        print("CONTENTSCLOSE at the top: first row at \(Int(firstRow.frame.minY)), list at \(Int(list.frame.minY))")
    }

    /// Waits for Contents to be gone: no row and no list left.
    private func expectContentsClosed(_ how: String, file: StaticString = #filePath, line: UInt = #line) {
        let gone = readsUntil(reads: 30) { !contentsRows.firstMatch.exists && !list.exists }
        print("CONTENTSCLOSE \(how): closed \(gone.ok) in \(gone.reads) reads")
        XCTAssertTrue(gone.ok, "\(how) closed Contents within \(gone.reads) reads\(gone.hung ? " (hang guard)" : "")", file: file, line: line)
    }

    private func expectSamePage(as before: String, _ how: String, file: StaticString = #filePath, line: UInt = #line) {
        let after = ReaderReads.settle(app, "the page after \(how)") { print("CONTENTSCLOSE \($0)") }.words
        print("CONTENTSCLOSE \(how): \(hash(before)) -> \(hash(after)); back up \(el("reader.back").exists)")
        XCTAssertEqual(hash(after), hash(before), "\(how) moved the page (\(hash(before)) to \(hash(after)))", file: file, line: line)
        XCTAssertFalse(el("reader.back").exists, "\(how) left a Back to return from", file: file, line: line)
    }

    /// A fast swipe down that starts on the header, the list still on his chapter part way down: Contents goes.
    func testAFastSwipeDownFromTheHeaderClosesContents() {
        let before = open()
        openContents()
        let header = el("contents.header")
        XCTAssertTrue(header.exists, "Contents' header")
        let from = header.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: 220)), withVelocity: swipe, thenHoldForDuration: 0)
        expectContentsClosed("a fast swipe down from the header")
        expectSamePage(as: before, "a fast swipe down from the header")
    }

    /// The list flicked up to its top, then a fast swipe down on the list: Contents goes.
    func testAFastSwipeDownInTheListAtItsTopClosesContents() {
        let before = open()
        openContents()
        flickToTop()
        flick(dy: 220)
        expectContentsClosed("a fast swipe down in the list at its top")
        expectSamePage(as: before, "a fast swipe down in the list at its top")
    }

    /// The list a little way from its top, then one slow pull from inside it to the screen's foot: the pull scrolls the
    /// list back to its top and carries on past it, and Contents goes.
    func testAPullPastTheTopOfTheListClosesContents() {
        let before = open()
        openContents()
        flickToTop()
        // Up 80 points and held, so the list is just off its top and doesn't coast. On the folded Duo a slow drag up
        // from the list's very top now and then left it where it was (2 of 17 drags in local runs), so the drag is made
        // again until the list has moved, at most three times.
        func offTop() -> Bool { !firstRow.exists || firstRow.frame.minY < list.frame.minY - 20 }
        var drags = 0
        for _ in 0..<3 where !offTop() {
            let low = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
            low.press(forDuration: 0.05, thenDragTo: low.withOffset(CGVector(dx: 0, dy: -80)), withVelocity: pull, thenHoldForDuration: 0.5)
            drags += 1
            waitForStill()
            XCTAssertTrue(contentsRows.firstMatch.exists, "a short scroll up closed Contents")
        }
        print("CONTENTSCLOSE off the top after \(drags) drags up: \(offTop())")
        XCTAssertTrue(offTop(), "the list scrolled off its top")
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: pull, thenHoldForDuration: 0.2)
        expectContentsClosed("a pull past the top of the list")
        expectSamePage(as: before, "a pull past the top of the list")
    }

    /// Flicks up and down through the middle of the list, the way he looks for a chapter: Contents stays up, and the
    /// close button then leaves the same page.
    func testFlickingThroughTheListKeepsContentsUp() {
        let before = open()
        openContents()
        for k in 0..<3 {
            flick(dy: -260)
            expectStillUp("flick up \(k)")
            XCTAssertFalse(firstRow.exists, "the list is still away from its top before flick down \(k)")
            flick(dy: 260)
            expectStillUp("flick down \(k)")
        }
        let close = app.buttons["contents.close"].firstMatch
        XCTAssertTrue(close.exists, "Contents' close button")
        close.tap()
        expectContentsClosed("the close button")
        expectSamePage(as: before, "flicking through Contents and closing it")
    }
}
