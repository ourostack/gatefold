import CryptoKit
import UIKit
import XCTest

/// Kept as CI's guard on the rotation path (red on build 17, 3 of 12 rounds green; green on PR #23).
/// Reviewer 2's rotation repro for build 17 (review-aris-words-lens.md, "The regression").
///
/// Device: iPad Pro 13-inch (M4) simulator (`com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB`),
/// iOS 27.0 runtime, freshly created. Book: the bundled Project Gutenberg Pride and Prejudice.
///
/// Path (an ordinary reader's, no jump hook after the first open):
///  1. Portrait. Fresh install (`-GatefoldReset`), open Pride and Prejudice at 0.31, wait until the book
///     is counted (`reader.pageCount` has a value; up to 300 s), let the words settle.
///  2. Controls up, Contents, tap the last contents entry (index min(30, rows - 1); 13 rows on this book),
///     let the words settle.
///  3. Read two pages: two forward taps at the right edge, each waiting for the words to change and settle.
///  4. Turn the iPad to landscape (`.landscapeLeft`), let the reflow settle (30 s cap, then 6 s more).
///     The words now on screen are "his page".
///  5. Three rounds: Home, 3 s, terminate, relaunch without `-GatefoldReset`, set `.landscapeLeft` again,
///     let the words settle. Compare with his page.
///
/// Judging, with no book text printed: the visible-text probe (`reader.visibleText`) is whitespace-collapsed.
///  - `startsSame`: SHA-256 of the first 30 characters of his page equals that of the reopened page.
///  - `middleSame`: a 40-character stretch from the middle of his page is on the reopened page.
///  - `hisStartAt`: where his first 30 characters begin in the reopened page's text (character index), or
///    -1. A positive number means the reopened screen starts before his page: it reopened early, and his
///    first line sits that many characters in (on a spread, typically at the top of the right page).
/// A round is red unless `startsSame` is true. Build 17 (f20a87b) in my review: 3 of 3 red, every round
/// `startsSame=false middleSame=true`, about one page early. Build 16 (23006346): 3 of 3 green.
@MainActor
final class RotationRepro: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let base = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var vtext: String { (el("reader.visibleText").value as? String) ?? "" }
    private func note(_ s: String) { print("REPRO " + s) }
    private func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private func head(_ t: String) -> String { String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }
    private func middle(_ t: String) -> String {
        let c = Array(t); guard c.count > 60 else { return t }
        let s = c.count / 2 - 20; return String(c[s..<(s + 40)])
    }

    /// Non-empty, then unchanged for 2.5 s.
    private func settle(_ timeout: TimeInterval = 60) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, vtext.isEmpty { usleep(200_000) }
        var last = vtext, since = Date()
        while Date() < deadline, Date().timeIntervalSince(since) < 2.5 {
            usleep(250_000)
            let now = vtext
            if now != last { last = now; since = Date() }
        }
        return last
    }
    private func turnForward() {
        let old = vtext
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, vtext == old || vtext.isEmpty { usleep(200_000) }
        _ = settle(20)
    }
    private func waitCounted(_ timeout: TimeInterval = 300) -> Bool {
        let count = el("reader.pageCount")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if count.exists, let v = count.value as? String, !v.isEmpty { return true }
            usleep(500_000)
        }
        return false
    }

    func testRotateThenLeaveWithoutTurning() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        // 1. Portrait, fresh install, open, wait for the count.
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        let counted = waitCounted()
        XCTAssertTrue(counted, "the book was counted before the rotation")
        _ = settle(60)
        sleep(3)

        // 2. A Contents jump.
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        sleep(2)
        XCTAssertTrue(el("reader.contents").waitForExistence(timeout: 5))
        el("reader.contents").tap()
        sleep(2)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the contents list is up")
        sleep(1)
        let beforeJump = vtext
        let rowCount = rows.count
        let pick = rows.element(boundBy: min(30, max(0, rows.count - 1)))
        for _ in 0..<6 where !pick.isHittable { app.swipeUp() }
        pick.tap()
        // The old page stays put while the jump loads (over 10 s on a hosted runner), so wait for the
        // words to change before waiting for them to settle.
        let jumpStart = Date()
        while Date().timeIntervalSince(jumpStart) < 60, vtext.isEmpty || head(vtext) == head(beforeJump) { usleep(250_000) }
        print("REPRO jump landed after \(String(format: "%.1f", Date().timeIntervalSince(jumpStart))) s")
        _ = settle(60)
        sleep(4)
        let jumped = !vtext.isEmpty && head(vtext) != head(beforeJump)
        XCTAssertTrue(jumped, "the Contents jump moved the page")

        // 3. Two pages read.
        turnForward()
        turnForward()
        sleep(3)

        // 4. Turn the iPad.
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = settle(30)
        sleep(6)
        _ = settle(60)
        sleep(3)
        let his = vtext
        XCTAssertFalse(his.isEmpty)
        note("setup counted=\(counted) contentsRows=\(rowCount) jumped=\(jumped) hisHead=\(hash(head(his)))")

        // 5. Leave without turning, three times.
        var green = 0
        for round in 1...3 {
            XCUIDevice.shared.press(.home)
            sleep(3)
            app.quit()
            app.launchArguments = base
            app.relaunch()
            XCUIDevice.shared.orientation = .landscapeLeft
            sleep(2)
            _ = settle(60)
            sleep(4)
            let back = settle(10)
            let startsSame = head(back) == head(his)
            let middleSame = back.contains(middle(his))
            let at = back.range(of: head(his)).map { back.distance(from: back.startIndex, to: $0.lowerBound) } ?? -1
            if startsSame { green += 1 }
            note("round \(round) \(startsSame ? "GREEN" : "RED") startsSame=\(startsSame) middleSame=\(middleSame) hisStartAt=\(at) reopenedHead=\(hash(head(back)))")
            XCTAssertTrue(startsSame, "round \(round): reopened on his page")
        }
        note("SUMMARY green=\(green) of 3")
        // Ended here, not by XCTest at teardown, where #44 recorded "Failed to terminate" (gatefold#76).
        app.quit()
    }
}
