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
        app.launchArguments = base
        app.relaunch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book reopened")
        XCTAssertFalse(settle(120).isEmpty, "the reopened page never came up")
        // A starved host can show the page before his place is set on it (the cover's bound forces it up):
        // then his saved place is offered, not moved to under his eyes (build 21), and he takes it.
        let offer = app.buttons["banner.jump"]
        var offered = false
        var landed = reads(75) {
            if shown == last { return true }
            offered = offer.exists
            return offered
        } && shown == last
        if !landed, offered {
            print("QUICKLEAVE reopened \(shown), his saved place offered; taking it")
            offer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            landed = reads(75) { shown == last }
        }
        print("QUICKLEAVE reopened \(shown)")
        XCTAssertTrue(landed, "the reopen is on \(shown), not the page of his last turn (\(last)); opened at \(opened)")
    }
}
