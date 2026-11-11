import CryptoKit
import UIKit
import XCTest

/// Build 19's reopen miss: a fresh open, a tap that only brings up the controls, Page Numbers turned on in
/// Fine-Tune (the number replacing "Counting pages…" shifts the layout and Readium reports another page
/// boundary), then back to the shelf and in again. The return must show the very words he left, every
/// time. About 1 in 11 missed before the fix. Pages are compared by hash; no book text is printed.
@MainActor
final class ReopenAfterControlsUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Rounds per run: 20 by default, `GATEFOLD_REOPEN_ROUNDS` to change it.
    private var rounds: Int { Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_ROUNDS"] ?? "") ?? 20 }

    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    /// Any type, never `app.buttons`: a control that is a menu can be typed PopUpButton, and a Button lookup then
    /// finds nothing (gatefold#165).
    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    /// The page's words once they have stopped changing for 2.5 s.
    private func settle(_ timeout: TimeInterval = 60) -> String {
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

    private func open() {
        let cover = el("book.gutenberg-pride-and-prejudice")
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 60), "the shelf")
        for _ in 0..<8 where !(cover.exists && cover.isHittable) { el("library.grid").swipeUp(); sleep(1) }
        cover.tap()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 60), "the book opened")
    }

    /// A fresh install offers the Cloud's place and never lands on it (#46): the book opens on its
    /// cover, which has no words. He takes the offer, as he would, so the round has words to keep.
    private func takeTheOffer(round: Int) {
        let offer = el("banner.jump"), tab = el("banner.tab")
        // Unanswered for 10 s the offer folds into its tab: the tab opens it again. It can fold between
        // two looks (gatefold#156's round 3 saw it, then lost it, and never opened the tab; #207, #211), so the
        // look goes on until the offer is there to tap. Judged in looks, not seconds (#94): 200 looks at least
        // 0.3 s apart (the old 60 s on a fast runner); the 2400 s guard only catches a hang: a look is up to five
        // queries of the app, and a starved runner has taken 1-2 s a query, so 200 looks can run to about 2000 s.
        let start = Date(), hung = start.addingTimeInterval(2400)
        var looks = 0, taken = false
        while looks < 200, words.isEmpty {
            if Date() > hung { XCTFail("hang: looking for the Cloud's offer ran \(looks) looks over 2400 s"); return }
            looks += 1
            if offer.exists, offer.isHittable { offer.tap(); taken = true; break }
            if tab.exists, tab.isHittable { tab.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        // "REOPEN round N:" so the iPad step's log filter keeps it.
        guard taken else {
            print("REOPEN round \(round): no offer taken after \(looks) looks in \(secs) s; tab \(tab.exists) offer \(offer.exists) words \(!words.isEmpty)")
            return
        }
        print("REOPEN round \(round): offer taken after \(looks) looks in \(secs) s")
        // Its own clock, so a slow look above doesn't spend this loop's guard.
        let shown = Date(), stuck = shown.addingTimeInterval(2400)
        var reads = 0
        while reads < 200, words.isEmpty {
            if Date() > stuck { XCTFail("hang: the offer's page ran \(reads) reads over 2400 s without words"); return }
            reads += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    private func toShelf() {
        let close = el("reader.close")
        for _ in 0..<4 where !(close.exists && close.isHittable) {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = close.waitForExistence(timeout: 3)
        }
        close.tap()
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 20), "back on the shelf")
        sleep(2)
    }

    /// One tap that only brings up the controls, then Page Numbers on in Fine-Tune.
    private func numbersOn() {
        let appearance = el("reader.appearance")
        for _ in 0..<4 where !appearance.exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appearance.waitForExistence(timeout: 3)
        }
        appearance.tap()
        let fine = el("appearance.customize")
        XCTAssertTrue(fine.waitForExistence(timeout: 10), "Fine-Tune is offered")
        if !fine.isHittable { el("appearance.panel").swipeUp() }
        fine.tap()
        let t = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(t.waitForExistence(timeout: 10), "the Page Numbers switch")
        for _ in 0..<4 where !t.isHittable { el("appearance.panel").swipeUp() }
        if (t.value as? String) != "1" { t.tap() }
        sleep(1)
        for id in ["appearance.close", "appearance.back", "appearance.close"] where el(id).exists { el(id).tap(); sleep(1) }
        if el("appearance.panel").exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        sleep(2)
    }

    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        var same = 0
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss.SSS"
        for round in 1...rounds {
            print("REOPEN round \(round) starts \(clock.string(from: Date()))")
            app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                   "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
                                   "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                   // This host's looks take seconds; the offer mustn't fold between a look and the tap (#207, as
                                   // NavigationPlace's cover test). The fold isn't what this test checks.
                                   "-GatefoldOfferFoldSeconds", "600"]
            app.relaunch()
            open()
            takeTheOffer(round: round)
            let opened = settle()
            numbersOn()
            // The number takes the "Counting pages…" slot: the layout report this guards against.
            _ = el("reader.pageNumber").waitForExistence(timeout: 180)
            let left = settle()
            print("REOPEN round \(round) leaves \(clock.string(from: Date()))")
            toShelf()
            print("REOPEN round \(round) reopens \(clock.string(from: Date()))")
            open()
            let back = settle()
            let ok = !left.isEmpty && back == left
            if ok { same += 1 }
            print("REOPEN round \(round): opened \(Self.hash(opened)) left \(Self.hash(left)) back \(Self.hash(back)) \(ok ? "SAME" : "MISS")")
            XCTAssertTrue(ok, "round \(round) returned other words (\(Self.hash(left)) then \(Self.hash(back)))")
            app.quit()
        }
        print("REOPEN SUMMARY same=\(same) of \(rounds)")
    }
}
