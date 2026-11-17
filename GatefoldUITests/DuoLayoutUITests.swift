import XCTest

/// The reader's layout holds still on the Duo, judged by frames (Ari, build 39, 2026-11-15).
///
/// - The open Duo held upright reports a status column at its top trailing corner only while the status bar is up.
///   The reader hid the status bar wherever such a column sat under its Close button, so the column went, so the
///   status bar came back, and so on several times a second: Close and the side controls jumped about 150 pt, the
///   clock showed through, and every flip moved the page and reflowed it. `-GatefoldStatusColumn` reports such a
///   column (top trailing, 144 x 82 pt) while the status bar is up, on any screen, so this runs without a hinge.
/// - Scrolling on the closed Duo, the chapter's running head sat over the first line of text, and the text stopped
///   38 pt below the top. In scroll mode the text runs to the screen's top and no running head is drawn over it.
///
/// Waits are judged in reads of the app (each at least 0.1 s), never seconds; `HangGuard` only catches a hang.
@MainActor
final class DuoLayoutUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { app.terminate() }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { hung = true; return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    private func open(_ extra: [String]) {
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                               "-GatefoldGoTo", "0.31", "-GatefoldTheme", "daylight"] + extra
        app.launch()
        let ready = readsUntil(reads: 1200) { el("reader.pageReady").exists && (el("reader.pageReady").value as? String) == "1" }
        XCTAssertTrue(ready.ok, "the book opened (\(ready.reads) reads)")
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    /// One look at the top chrome: Close's frame, the status bar's state and the reflows so far.
    private struct Look: Equatable, CustomStringConvertible {
        var close: CGRect?
        var statusBar: String
        var reflow: String
        var description: String { "close \(close.map { "\($0)" } ?? "gone") status bar \(statusBar) reflow \(reflow)" }
    }

    private func look() -> Look {
        let close = el("reader.close")
        let status = el("reader.statusBar")
        let reflow = el("reader.reflow")
        return Look(close: close.exists ? close.frame : nil,
                    statusBar: status.exists ? status.label : "gone",
                    reflow: reflow.exists ? (reflow.value as? String) ?? "" : "gone")
    }

    /// With the controls up and nothing touched, Close, the status bar and the page hold still: 30 looks in a row
    /// (about 3 s or more) the same, once they have settled. Before the fix they changed several times a second.
    private func checkTheChromeHoldsStill(_ extra: [String], file: StaticString = #filePath, line: UInt = #line) {
        open(["-GatefoldStatusColumn", "YES", "-GatefoldShowChrome", "YES"] + extra)
        let up = readsUntil(reads: 100) { el("reader.close").exists }
        XCTAssertTrue(up.ok, "the controls came up", file: file, line: line)
        // Let the controls' arrival and any first settle pass: up to 30 reads for 5 equal looks running.
        var last = look(), same = 0
        _ = readsUntil(reads: 30) {
            let now = look()
            same = now == last ? same + 1 : 0
            last = now
            return same >= 5
        }
        let settled = look()
        var changes: [String] = []
        for i in 1...30 {
            let now = look()
            if now != settled, changes.count < 6 { changes.append("look \(i): \(now)") }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        shot("chrome-held")
        XCTAssertTrue(changes.isEmpty, "the controls held still for 30 looks from \(settled); they changed: \(changes.joined(separator: "; "))",
                      file: file, line: line)
        // Close sits inside the window and clear of the status bar's column whenever the status bar is up.
        if let close = settled.close {
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(close), "Close \(close) inside the window \(window)", file: file, line: line)
            if settled.statusBar == "shown" {
                let column = CGRect(x: window.maxX - 144, y: window.minY, width: 144, height: 82)
                XCTAssertFalse(close.intersects(column), "Close \(close) clear of the status column \(column)", file: file, line: line)
            }
        }
    }

    func testTheChromeHoldsStillBesideAStatusColumnScrolling() { checkTheChromeHoldsStill(["-GatefoldPageTurn", "scroll"]) }

    func testTheChromeHoldsStillBesideAStatusColumnTurningPages() { checkTheChromeHoldsStill(["-GatefoldPageTurn", "slide"]) }

    /// Scrolling, the text runs to the top of the screen, and no running head is drawn over it. The folded Duo had
    /// its head over a line at (24, 33.8), and the page 46 pt down (Ari, build 39; Ouro Feel on gatefold#413).
    func testScrollingTextRunsToTheTopWithNoHeadOverIt() { checkScrollingTop([]) }

    /// The same on two facing pages with a status column at the top (the open Duo): Ouro Feel on gatefold#413 found
    /// both heads at y = -9 over the text there, and the page pushed down out of the window.
    func testScrollingSpreadRunsToTheTopWithNoHeadOverIt() {
        checkScrollingTop(["-GatefoldForcePosture", "spread", "-GatefoldStatusColumn", "YES"])
    }

    /// On the folded Duo, the cover screen's status column reaches down to 174 pt while Contents is up and back to
    /// 82 pt once it closes. The page settles its top once and holds it through that: before the fix it moved with
    /// the column, reflowed twice, and the second reflow never settled, so the next turn never landed
    /// (SingleColumnUITests on gatefold#415's CI). On a screen with no status column it holds still all the same.
    func testContentsOpenedAndClosedLeavesThePageWhereItWas() {
        open([])
        let page = el("reader.page")
        let reflow = el("reader.reflow")
        let contents = app.buttons["reader.contents"]
        func still() -> (frame: CGRect, reflows: String) {
            var last = (frame: CGRect.null, reflows: ""), same = 0
            _ = readsUntil(reads: 100) {
                let now = (frame: page.exists ? page.frame : .null, reflows: (reflow.value as? String) ?? "")
                same = now.frame == last.frame && now.reflows == last.reflows && !now.reflows.hasSuffix("reflowing") ? same + 1 : 0
                last = now
                return same >= 5
            }
            return last
        }
        func tapMiddle(until done: () -> Bool) {
            for _ in 0..<3 where !done() {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                _ = readsUntil(reads: 25, done)
            }
        }
        let before = still()
        tapMiddle { contents.exists && contents.isHittable }
        XCTAssertTrue(contents.exists, "the controls came up")
        contents.tap()
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "contents.current", "contents.entry."))
        XCTAssertTrue(readsUntil(reads: 100) { rows.firstMatch.exists }.ok, "Contents opened")
        // Closed by its Done button: a swipe down starts on a row (a slow simulator takes it for a tap and jumps
        // there) or on the tabs (it changes tab and leaves the sheet up).
        let done = app.buttons["Done"].firstMatch
        XCTAssertTrue(done.exists, "Contents has its Done button")
        done.tap()
        XCTAssertTrue(readsUntil(reads: 100) { !done.exists && !rows.firstMatch.exists }.ok, "Contents closed")
        tapMiddle { !contents.exists }
        XCTAssertFalse(contents.exists, "the controls went down")
        let after = still()
        shot("after-contents")
        XCTAssertEqual(after.frame, before.frame, "the page holds its place through Contents")
        XCTAssertEqual(after.reflows.split(separator: " ").first, before.reflows.split(separator: " ").first,
                       "no reflow for opening and closing Contents (\(before.reflows) then \(after.reflows))")
    }

    private func checkScrollingTop(_ extra: [String], file: StaticString = #filePath, line: UInt = #line) {
        open(["-GatefoldPageTurn", "scroll"] + extra)
        let page = el("reader.page")
        XCTAssertTrue(readsUntil(reads: 100) { page.exists }.ok, "the page is up", file: file, line: line)
        // Let a late camera report settle the page (`PageTop`): 5 equal looks running, within 60 reads.
        var last = CGRect.null, same = 0
        _ = readsUntil(reads: 60) {
            let now = page.exists ? page.frame : .null
            same = now == last ? same + 1 : 0
            last = now
            return same >= 5
        }
        shot("scroll-top")
        let window = app.windows.firstMatch.frame
        let frame = page.exists ? page.frame : .null
        XCTAssertEqual(frame.minY, window.minY, accuracy: 0.5, "the scrolling page starts at the screen's top (\(frame), window \(window))",
                       file: file, line: line)
        XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(frame), "the scrolling page \(frame) lies inside the window \(window)",
                      file: file, line: line)
        // Scrolling text runs up through the top band, so no running head is drawn at all, on one page or two.
        for id in ["reader.runningHead", "reader.runningHead.book"] {
            let head = el(id)
            XCTAssertFalse(head.exists, "no \(id) while scrolling (one at \(head.exists ? "\(head.frame)" : "-"), page \(frame))",
                           file: file, line: line)
        }
    }
}
