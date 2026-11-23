import XCTest

/// A turn of the iPad shows whole pages only, from the moment it starts until the new layout is placed: the page
/// as it was, at its own proportions and all of it, then the new one faded in, as Apple Books does. Build 46 showed
/// the portrait page clipped in the landscape window with the unfold's leaf standing on edge over it (a grey strip)
/// a second into a cold turn on its side, and back upright the spread squeezed and cut off under the fold's leaf
/// (gatefold#537). Judged on every display frame by the app (`reader.turnFrames`): a frame is broken when a
/// picture over the page is cut off, short of the page or out of its own proportions, when a leaf is over it, or
/// when the page shows mid-layout with nothing whole over it. No book text is printed.
@MainActor
final class RotationFrameUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private var turnFrames: String { (el("reader.turnFrames").value as? String) ?? "" }

    /// Reads until `done`, never seconds; the hang guard only ends a wait whose reads stopped coming back.
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    /// The same words six reads running, once the page is shown.
    private func settle() {
        var last = "", same = 0
        _ = readsUntil(reads: 600) {
            let now = words
            let shown = (el("reader.pageReady").value as? String) == "1"
            if now.isEmpty || now != last || !shown { last = now; same = 0 } else { same += 1 }
            return same >= 6
        }
    }

    /// Turns the iPad and returns the app's verdict on every frame until the turn's reflow was shown.
    private func turn(to orientation: UIDeviceOrientation, _ what: String) -> String {
        let before = turnFrames
        XCUIDevice.shared.orientation = orientation
        let started = readsUntil(reads: 50) { turnFrames == "watching" || (turnFrames != before && turnFrames.contains("broken")) }
        XCTAssertTrue(started.ok, "\(what): the app watched the turn")
        let ended = readsUntil(reads: 400) { turnFrames.contains("broken") }
        XCTAssertTrue(ended.ok, "\(what): the turn's reflow was shown (not in \(ended.reads) reads)")
        let verdict = turnFrames
        print("TURNFRAMES \(what): \(verdict)")
        return verdict
    }

    /// A cold turn on its side (a fresh install, the book just opened), then back upright: every frame between the
    /// turn and the new layout being placed is a whole page.
    func testATurnOnItsSideAndBackShowsOnlyWholePages() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        settle()
        let side = turn(to: .landscapeLeft, "on its side")
        XCTAssertTrue(side.hasPrefix("0 broken of "), "on its side, frames that weren't a whole page: \(side)")
        XCTAssertFalse(side.contains("("), "on its side: \(side)")
        settle()
        let back = turn(to: .portrait, "back upright")
        XCTAssertTrue(back.hasPrefix("0 broken of "), "back upright, frames that weren't a whole page: \(back)")
        XCTAssertFalse(back.contains("("), "back upright: \(back)")
        XCTAssertFalse(words.isEmpty, "the page's words are readable")
    }
}
