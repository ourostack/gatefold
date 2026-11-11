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
    /// Rounds per run, over all five methods: 20 by default, `GATEFOLD_REOPEN_ROUNDS` to change it.
    private var rounds: Int { Int(ProcessInfo.processInfo.environment["GATEFOLD_REOPEN_ROUNDS"] ?? "") ?? 20 }
    /// The rounds are split over this many methods, so each fits one CI shard: method k takes rounds k, k + 5,
    /// k + 10, and so on, and together they take rounds 1 to `rounds` once each. Every round is its own fresh
    /// install (`-GatefoldReset` wipes the library, its places and the reopen book; the fake Cloud starts from
    /// its seed on every launch), so no round reads what another saved and the split changes nothing they judge.
    /// The reopen pictures in Caches survive a reset, but are read only for a launch reopen, which the reset clears.
    private static let methods = 5

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
    private func takeTheOffer() {
        let offer = el("banner.jump"), tab = el("banner.tab")
        let up0 = Date().addingTimeInterval(60)
        // Unanswered for 10 s the offer folds into its tab: the tab opens it again.
        while words.isEmpty, !offer.exists, Date() < up0 {
            if tab.exists, tab.isHittable { tab.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        guard offer.exists, words.isEmpty else { return }
        offer.tap()
        let up = Date().addingTimeInterval(60)
        while words.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.3)) }
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

    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords1() throws { try returns(1) }
    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords2() throws { try returns(2) }
    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords3() throws { try returns(3) }
    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords4() throws { try returns(4) }
    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords5() throws { try returns(5) }

    /// Method `k`'s rounds: k, k + 5, ... up to `rounds`.
    private func returns(_ k: Int) throws {
        let mine = Array(stride(from: k, through: rounds, by: Self.methods))
        try XCTSkipIf(mine.isEmpty, "\(rounds) rounds leave none for method \(k)")
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        var same = 0
        let clock = DateFormatter(); clock.dateFormat = "HH:mm:ss.SSS"
        for round in mine {
            print("REOPEN round \(round) starts \(clock.string(from: Date()))")
            app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                   "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
                                   "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"]
            app.relaunch()
            open()
            takeTheOffer()
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
        print("REOPEN SUMMARY method \(k): same=\(same) of \(mine.count) (rounds \(mine.map(String.init).joined(separator: ",")))")
    }
}
