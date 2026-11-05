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

    private func toShelf() {
        let close = app.buttons["reader.close"].firstMatch
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
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appearance.waitForExistence(timeout: 3)
        }
        appearance.tap()
        let fine = app.buttons["appearance.customize"]
        XCTAssertTrue(fine.waitForExistence(timeout: 10), "Fine-Tune is offered")
        if !fine.isHittable { el("appearance.panel").swipeUp() }
        fine.tap()
        let t = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(t.waitForExistence(timeout: 10), "the Page Numbers switch")
        for _ in 0..<4 where !t.isHittable { el("appearance.panel").swipeUp() }
        if (t.value as? String) != "1" { t.tap() }
        sleep(1)
        for id in ["appearance.close", "appearance.back", "appearance.close"] where app.buttons[id].exists { app.buttons[id].tap(); sleep(1) }
        if el("appearance.panel").exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        sleep(2)
    }

    func testAReturnAfterTheControlsAndNumbersShowsTheSameWords() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        var same = 0
        for round in 1...rounds {
            app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                   "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
                                   "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"]
            app.launch()
            open()
            _ = settle()
            numbersOn()
            // The number takes the "Counting pages…" slot: the layout report this guards against.
            _ = el("reader.pageNumber").waitForExistence(timeout: 180)
            let left = settle()
            toShelf()
            open()
            let back = settle()
            let ok = !left.isEmpty && back == left
            if ok { same += 1 }
            print("REOPEN round \(round): left \(Self.hash(left)) back \(Self.hash(back)) \(ok ? "SAME" : "MISS")")
            XCTAssertTrue(ok, "round \(round) returned other words (\(Self.hash(left)) then \(Self.hash(back)))")
            app.terminate()
        }
        print("REOPEN SUMMARY same=\(same) of \(rounds)")
    }
}
