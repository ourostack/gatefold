import XCTest

/// Scroll mode keeps his place (Ari, build 39 on the Duo, 2026-11-15). A sideways swipe moved him to the next
/// chapter and a swipe back put him at its start or end, and a tap on the status bar scrolled the chapter to its
/// top. In scroll a sideways swipe never changes chapter, a tap at the top never moves the page, and a chapter
/// changes only by scrolling on past its end or back past its start, which lands where that scroll left off.
/// Every wait is judged in reads, never seconds (`readsUntil`, `HangGuard`).
@MainActor
final class ScrollModeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    /// Opens Pride and Prejudice in scroll at `goTo` of the book: 0.31 is a seventh of the way into its sixth file,
    /// 0.338 most of the way through it.
    private func launch(goTo: String = "0.31") {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", goTo,
            "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "scroll",
        ]
        app.launch()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    /// The place on screen, as "file@progression" (`reader.shownPlace`), or nil before there is one. Read only once
    /// the probe exists: `value` on an element not there yet fails the test on the spot (gatefold#407).
    private func shown() -> (file: String, progression: Double)? {
        let probe = el("reader.shownPlace")
        guard probe.exists else { return nil }
        let parts = ((probe.value as? String) ?? "").split(separator: "@")
        guard parts.count == 2, let p = Double(parts[1]) else { return nil }
        return (String(parts[0]), p)
    }

    /// Judged in reads, one every 0.25 s; a hang guard sized from the reads stops a stuck query.
    private func readsUntil(_ reads: Int, file: StaticString = #filePath, line: UInt = #line, _ done: () -> Bool) -> Bool {
        let hung = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 0..<reads {
            if done() { return true }
            if Date() > hung { XCTFail("hang guard: stuck at read \(read) of \(reads)", file: file, line: line); return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return done()
    }

    /// The place once it has held still for `quiet` reads in a row.
    private func settledPlace(_ what: String, quiet: Int = 8, file: StaticString = #filePath, line: UInt = #line) -> (file: String, progression: Double) {
        var last = "", same = 0
        let ok = readsUntil(ReaderReads.coverReads, file: file, line: line) {
            let now = shown().map { "\($0.file)@\($0.progression)" } ?? ""
            if now == last { same += 1 } else { last = now; same = 0 }
            return !now.isEmpty && same >= quiet
        }
        XCTAssertTrue(ok, "\(what): the place never held still", file: file, line: line)
        let place = shown() ?? ("", -1)
        print("SCROLLMODE \(what): \(place.file)@\(place.progression)")
        return place
    }

    /// Opened in scroll, its words up, and moved down the chapter a little so the top of the chapter is somewhere else.
    private func openedPartWayIn(goTo: String = "0.31") -> (file: String, progression: Double) {
        launch(goTo: goTo)
        let ready = el("reader.pageReady")
        XCTAssertTrue(readsUntil(ReaderReads.coverReads) { ready.exists && (ready.value as? String) == "1" }, "the page showed")
        _ = ReaderReads.settle(app, "the opening page") { print("SCROLLMODE \($0)") }
        let start = settledPlace("opened")
        scroll(up: true, by: 0.35)
        let place = settledPlace("scrolled part way")
        XCTAssertEqual(place.file, start.file, "a short scroll stays in the chapter")
        XCTAssertGreaterThan(place.progression, 0.02, "the scroll moved down the chapter")
        return place
    }

    /// A slow vertical drag on the page, a fraction of its height: up moves on through the text.
    private func scroll(up: Bool, by fraction: Double) {
        let page = el("reader.page")
        let from = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.5 + fraction / 2 : 0.5 - fraction / 2))
        let to = page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 0.5 - fraction / 2 : 0.5 + fraction / 2))
        from.press(forDuration: 0.05, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.1)
    }

    /// A quick flick across the page, as a thumb does.
    private func sideSwipe(left: Bool) {
        let page = el("reader.page")
        if left { page.swipeLeft(velocity: .fast) } else { page.swipeRight(velocity: .fast) }
    }

    /// The place stays `place` for `reads` reads: same chapter, and within `slack` of where he was.
    private func stays(at place: (file: String, progression: Double), for reads: Int = 24, slack: Double = 0.01,
                       _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        var moved: (file: String, progression: Double)?
        _ = readsUntil(reads, file: file, line: line) {
            if let now = shown(), now.file != place.file || abs(now.progression - place.progression) > slack { moved = now; return true }
            return false
        }
        if let moved { print("SCROLLMODE \(what): moved to \(moved.file)@\(moved.progression)") }
        XCTAssertNil(moved, "\(what): the place moved from \(place.file)@\(place.progression) to \(moved.map { "\($0.file)@\($0.progression)" } ?? "")",
                     file: file, line: line)
    }

    /// A sideways swipe either way, in scroll, never changes the chapter or moves the place (Ari's first report).
    func testASidewaysSwipeInScrollKeepsThePlace() {
        let place = openedPartWayIn()
        sideSwipe(left: true)
        stays(at: place, "a swipe to the left")
        sideSwipe(left: false)
        stays(at: place, "a swipe to the right")
    }

    /// A tap on the status bar never scrolls the chapter to its top (Ari's second report: iOS's tap-to-top on the
    /// page's scroll view). Tapped at the top centre of the screen, where the status bar is.
    func testATapOnTheStatusBarKeepsThePlace() {
        let place = openedPartWayIn()
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(CGVector(dx: 0, dy: 8)).tap()
        stays(at: place, "a tap on the status bar")
    }

    /// Scrolled to the end of a chapter, a scroll on opens the next at its start; scrolled back past that start, the
    /// chapter he left is open again at its end, where he was, never its start.
    func testScrollingPastAChaptersEndAndBackLandsWhereHeWas() {
        let place = openedPartWayIn(goTo: "0.338")
        // Down to the chapter's end and on past it, one flick at a time, each settled before the next: a flick that
        // starts mid-chapter can only reach the end, so the one that opens the next chapter is the one that started
        // there, and the place before it is the chapter's end.
        var end = place
        var crossed = false
        for _ in 0..<40 {
            el("reader.page").swipeUp(velocity: .fast)
            var now = settledPlace("flicked on", quiet: 4)
            // A flick that left the place where it was began at the chapter's end, so it is the pull that opens the
            // next chapter. On a busy runner that chapter takes several seconds to open, and the place holds still
            // at the old end meanwhile. Another flick then would land on the new chapter and scroll it on past its
            // start (gatefold#425). So wait for the chapter, judged in reads, and flick again only if it never comes.
            if now.file == place.file, now.progression == end.progression {
                if readsUntil(ReaderReads.coverReads, { shown()?.file != place.file }) {
                    now = settledPlace("the pull opened the next chapter", quiet: 4)
                }
            }
            if now.file != place.file { crossed = true; break }
            end = now
        }
        XCTAssertTrue(crossed, "scrolling on past the chapter's end opened the next")
        XCTAssertGreaterThan(end.progression, 0.9, "the chapter's end was reached before the next opened")
        let opened = settledPlace("the next chapter")
        XCTAssertNotEqual(opened.file, place.file, "the next chapter is open")
        XCTAssertLessThan(opened.progression, 0.02, "the next chapter opened at its start")
        // Back past its start: the chapter he left, at its end.
        scroll(up: false, by: 0.4)
        XCTAssertTrue(readsUntil(ReaderReads.coverReads) { shown()?.file == place.file }, "a scroll back past the start returned")
        let back = settledPlace("back in the chapter")
        XCTAssertEqual(back.file, end.file)
        XCTAssertEqual(back.progression, end.progression, accuracy: 0.02, "back at the chapter's end, where he left it")
    }
}
