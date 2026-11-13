import XCTest

/// He turns a few pages and leaves at once, and iOS ends Gatefold before the write of his last turn has
/// landed (gatefold#301: build 25's review reopened pages before where he left). The reopen chains linger
/// before leaving, so their writes always land first. Here the write under way is held for good
/// (`-GatefoldHoldTurnWrites`), so the reopen shows only what leaving itself kept. Judged by the place
/// Readium names (file and progression in it), in reads, never in seconds.
@MainActor
final class QuickLeaveUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private let base = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES"]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    /// The page Readium last reported, as "file@progression": set as the report arrives, before any write.
    private var shown: String { (el("reader.shownPlace").value as? String) ?? "" }

    /// Reads of the app until `done`, each at least 0.2 s apart (a starved runner makes reads slower, not
    /// fewer). The hang guard ends it only on a runner that has stopped answering.
    private func reads(_ limit: Int, hangGuard: TimeInterval = 900, until done: () -> Bool) -> Bool {
        let hung = Date().addingTimeInterval(hangGuard)
        for _ in 0..<limit {
            if done() { return true }
            if Date() > hung { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return done()
    }

    /// The page's words once they have stopped changing for 2.5 s. (Not after a held turn: the words probe
    /// follows each write; the turns are read by the place Readium names.)
    private func settle(_ timeout: TimeInterval = 90) -> String {
        let up = Date().addingTimeInterval(timeout)
        var last = "", since = Date()
        while Date() < up {
            let now = words
            if now != last { last = now; since = Date() }
            if !now.isEmpty, Date().timeIntervalSince(since) > 2.5 { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return words
    }

    /// Three turns, Home as soon as the last one has reached its page, and iOS ends Gatefold: the reopen is
    /// on the page of his last turn. On iPad and Duo alike.
    func testTurnsThenAQuickLeaveReopenOnTheLastTurnsPage() {
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldHoldTurnWrites", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        XCTAssertFalse(settle(120).isEmpty, "the page never came up")
        XCTAssertTrue(reads(300) { (el("reader.pageReady").value as? String) == "1" }, "the page never became ready for a turn")
        let opened = shown
        var last = opened
        for turn in 1...3 {
            let before = shown
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            XCTAssertTrue(reads(75) { let now = shown; return !now.isEmpty && now != before },
                          "turn \(turn) never reached its page (still \(before))")
            last = shown
        }
        XCTAssertNotEqual(last, opened, "the turns never moved the page")
        print("QUICKLEAVE opened \(opened) last turn \(last)")
        // He leaves at once: no wait for his words or for the write.
        XCUIDevice.shared.press(.home)
        // A Duo simulator up for a day can miss the Home press (ReopenLandingUITests).
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        app.quit()
        // The reopen meets CI's starved iPad (gatefold#310): the page answers no script for 400 looks (at least 20 s),
        // past the cover's own 11.5 s, and a place with no words opens on its file's first page.
        app.launchArguments = base + ["-GatefoldReopenOnChapterStart", "YES", "-GatefoldStallOpenScripts", "400"]
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book reopened")
        XCTAssertFalse(settle(120).isEmpty, "the reopened page never came up")
        // Judged as the cover lifts: the page itself is on his last turn's page. His saved place offered and taken,
        // or put right after the page showed, is not a landing (gatefold#310).
        XCTAssertTrue(reads(1200) { (el("reader.pageReady").value as? String) == "1" }, "the reopened page never showed")
        let landed = reads(4) { shown == last }
        if app.buttons["banner.jump"].exists { print("QUICKLEAVE reopened \(shown) with his saved place offered") }
        print("QUICKLEAVE reopened \(shown)")
        XCTAssertTrue(landed, "the reopen is on \(shown), not the page of his last turn (\(last)); opened at \(opened)")
    }

    /// He leaves while a reopen's cover is still held for his place (gatefold#310), after the 12 s reflow watchdog
    /// has shown the page beneath it as it is: he never saw that page, so the reopen after keeps his saved place
    /// (gatefold#366). On the iPad's side the reopen begins a rotation's reflow, whose restore waits on the page's
    /// scripts, held here for 800 looks (at least 40 s): the watchdog fires at 12 s, inside the cover's 900-look hold.
    func testALeaveUnderTheReopensCoverAfterTheWatchdogKeepsHisPlace() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the reopen's rotation reflow is the iPad's")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        // His place, saved bare as a quick leave keeps it: a place with no words, so the stalled reopen opens on its
        // file's first page, a page he never chose.
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldHoldTurnWrites", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        XCTAssertTrue(reads(1200) { (el("reader.pageReady").value as? String) == "1" }, "the page never became ready for a turn")
        for turn in 1...3 {
            let before = shown
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            XCTAssertTrue(reads(75) { let now = shown; return !now.isEmpty && now != before },
                          "turn \(turn) never reached its page (still \(before))")
        }
        leave()
        app.launchArguments = base + ["-GatefoldReopenOnChapterStart", "YES", "-GatefoldStallOpenScripts", "800"]
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book reopened")
        let saved = (el("reader.savedPlace").value as? String) ?? ""
        XCTAssertFalse(saved.isEmpty, "the reopen had a saved place")
        let watchdog = el("reader.shownUnsettled")
        XCTAssertTrue(reads(600) { ((watchdog.value as? String).flatMap(Int.init) ?? 0) > 0 },
                      "the watchdog never showed the page under the reopen's cover")
        // The case itself: the cover still up as the watchdog fires. A cover already lifted is another case.
        XCTAssertEqual(el("reader.pageReady").value as? String, "0", "the cover lifted before the watchdog fired")
        leave()
        app.launchArguments = base
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book reopened again")
        let kept = (el("reader.savedPlace").value as? String) ?? ""
        print("QUICKLEAVE under the cover: saved \(saved) kept \(kept)")
        XCTAssertEqual(kept, saved, "a leave under the reopen's cover kept a page he never saw")
    }

    /// Home, then iOS ends Gatefold: no wait for any write.
    private func leave() {
        XCUIDevice.shared.press(.home)
        // A Duo simulator up for a day can miss the Home press (ReopenLandingUITests).
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        app.quit()
    }
}
