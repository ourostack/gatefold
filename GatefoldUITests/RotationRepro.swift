import CryptoKit
import UIKit
import XCTest
import GatefoldCore

/// Kept as CI's guard on the rotation path (red on build 17, 3 of 12 rounds green; green on PR #23).
/// Reviewer 2's rotation repro for build 17 (review-aris-words-lens.md, "The regression").
///
/// Device: iPad Pro 13-inch (M4) simulator (`com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M4-8GB`),
/// iOS 27.0 runtime, freshly created. Book: the bundled Project Gutenberg Pride and Prejudice.
///
/// Path (an ordinary reader's, no jump hook after the first open):
///  1. Portrait. Fresh install (`-GatefoldReset`), open Pride and Prejudice at 0.31, wait until the book
///     is counted (`reader.pageCount` has a value; up to 300 s), let the words settle.
///  2. Controls up, Contents, tap contents entry 11, by its identifier,
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
    /// Every move a settle made was behind a cover or a held picture: none on a page he could see.
    private func assertNoVisibleSettleMove(_ when: String) {
        let seen = el("reader.visibleSettleMove").exists
        note("visibleSettleMove \(when)=\(seen)")
        XCTAssertFalse(seen, "\(when): a settle moved the page with nothing over it")
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
        try rotateThenLeave()
    }

    /// The same path with the rotation's reflows stalled behind their cover (`-GatefoldStallReflow`, first
    /// launch only), so the 12 s watchdog shows the page as it is and the restore runs again with no cover
    /// up, while the reopens take the quick, covered path: gatefold#108's pair, forced. The two paginated
    /// his place differently (the column break at his words went in only while covered).
    func testRotateThenLeaveWithoutTurningAfterStalledReflows() throws {
        try rotateThenLeave(extra: ["-GatefoldStallReflow", "YES"])
    }

    /// The same path with the rotation's page slow to answer (`-GatefoldSlowRestorePage`, first launch only):
    /// the restore waits on its first script past the 12 s watchdog, which shows the page as it is, and he
    /// leaves on that page before the restore settles, as on CI's iPad (gatefold#133). The reopen must start
    /// on the page he saw.
    func testRotateThenLeaveWhileTheRestoreWaitsOnItsPage() throws {
        try rotateThenLeave(extra: ["-GatefoldSlowRestorePage", "YES"])
    }

    /// The same, with the shown page noted only as Readium names it: on a device whose page scripts wait
    /// on the stalled install too, its words never come back before he leaves. Noted at the place his turn
    /// kept, as when Readium reports nothing new under the stall (CI 43075159905), the leave keeps his words.
    func testRotateThenLeaveWhileTheRestoreWaitsOnItsPageWithoutItsWords() throws {
        try rotateThenLeave(extra: ["-GatefoldSlowRestorePage", "YES", "-GatefoldShownPageWithoutWords", "YES",
                                    "-GatefoldShownPageAtHisPlace", "YES"])
    }

    private func rotateThenLeave(extra: [String] = []) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        // 1. Portrait, fresh install, open, wait for the count.
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = base + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
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
        // One entry, named, every run: the last row the lazy list had loaded was 12 rows on some runs and
        // 14 on others, so the jump went to a different chapter from run to run (gatefold#133, #193).
        let pick = app.descendants(matching: .any)["contents.entry.11"]
        // The list opens scrolled to his chapter, so entry 11 may sit above or below what is on screen.
        // Short drags inside the list itself, a few at a time: a swipe at the list's top would close the sheet.
        let list = app.collectionViews.firstMatch
        let loaded = rows.allElementsBoundByIndex.map { $0.identifier.replacingOccurrences(of: "contents.entry.", with: "") }
        print("REPRO jump rows loaded \(loaded.joined(separator: ","))")
        let current = app.descendants(matching: .any)["contents.current"].exists
        print("REPRO jump current row \(current ? "up" : "not loaded")")
        // Toward entry 11 only: a pull-down at the list's top can close the sheet. Entry 11 in the top half
        // of the loaded rows (or above them) is reached by pulling down; one loaded at the top edge isn't
        // hittable, and a push up would take it away.
        let ids = loaded.compactMap { Int($0) }
        let above = ids.isEmpty ? false : 11 < (ids.min()! + ids.max()!) / 2
        for _ in 0..<10 where !(pick.exists && pick.isHittable) {
            // A short drag inside the list, never a swipe from its top: a pull-down there closes the sheet.
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.35 : 0.65))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.65 : 0.35))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
        XCTAssertTrue(pick.isHittable, "contents entry 11 is on screen")
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
        // The page his second turn kept, and the words it saved: the place a leave on it keeps (gatefold#133).
        // Compared only, never printed.
        let turnedBeforeRotation = vtext
        let savedBeforeRotation = (el("reader.savedWords").value as? String) ?? ""

        // 4. Turn the iPad.
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = settle(30)
        sleep(6)
        _ = settle(60)
        sleep(3)
        let his = vtext
        XCTAssertFalse(his.isEmpty)
        note("setup counted=\(counted) contentsRows=\(rowCount) jumped=\(jumped) hisHead=\(hash(head(his)))")
        assertNoVisibleSettleMove("the rotation")

        // 5. Leave without turning, three times.
        var green = 0
        // The stalled-leave tests hold the restore past the leave (the slow-restore hook): only they test the
        // shown page's write and the words it keeps. The others settle, and leave by other paths.
        let stalledLeave = extra.contains("-GatefoldSlowRestorePage")
        // Left with no words on the page his turn kept: the place keeps his words (gatefold#133, CI 43075159905).
        let keepsHisWords = extra.contains("-GatefoldShownPageAtHisPlace")
        for round in 1...3 {
            // Round 1 is the stalled leave (the slow-restore hook holds the restore past it); a restore that
            // settled first leaves nothing to test, and a green would be luck. Its value names no book text.
            if round == 1, stalledLeave {
                let stalled = ((el("reader.reflow").value as? String) ?? "").hasSuffix("reflowing")
                note("round 1 leaves under a stalled restore: \(stalled)")
                XCTAssertTrue(stalled, "the restore was still stalled when he left")
            }
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
            // Noted at the place his turn kept (the hook), the leave keeps that place and its words: the reopen
            // puts them at the top of the left page, as a restore does. Otherwise it is the page he saw.
            let startsSame = keepsHisWords
                ? ReopenMatch.compare(left: turnedBeforeRotation, reopened: back, saved: savedBeforeRotation) != .different
                : head(back) == head(his)
            let middleSame = back.contains(middle(his))
            let at = back.range(of: head(his)).map { back.distance(from: back.startIndex, to: $0.lowerBound) } ?? -1
            // His turn kept his words; leaving on that same page, with or without words from it, keeps them
            // (gatefold#133: a bare progression reopened one page boundary early). Never printed, only tested.
            let keptWords = !keepsHisWords || !((el("reader.savedWords").value as? String) ?? "").isEmpty
            if startsSame && keptWords { green += 1 }
            note("round \(round) \(startsSame && keptWords ? "GREEN" : "RED") startsSame=\(startsSame) keptWords=\(keptWords) middleSame=\(middleSame) hisStartAt=\(at) reopenedHead=\(hash(head(back)))")
            XCTAssertTrue(keptWords, "round \(round): the place reopened carries his words")
            XCTAssertTrue(startsSame, "round \(round): reopened on his page")
            assertNoVisibleSettleMove("round \(round)")
        }
        note("SUMMARY green=\(green) of 3")

        // 6. Two turns on the spread the restore laid out (a column break at his words, when it put one in), then
        // leave: the reopen lands on the spread he turned to, not one the fresh layout's own columns make.
        turnForward()
        turnForward()
        sleep(3)
        let turned = settle(20)
        let savedAtTurn = (el("reader.savedWords").value as? String) ?? ""
        XCUIDevice.shared.press(.home)
        sleep(3)
        app.quit()
        app.launchArguments = base
        app.relaunch()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        _ = settle(60)
        sleep(4)
        let afterTurns = settle(10)
        // His place is the page's first whole word (`ReaderJS.anchor`): a spread that opens on the end of a
        // word hyphenated across the turn reopens on the word after it. That counts only when the place the
        // app saved proves the dropped token was a word's tail (`ReopenMatch`); otherwise exact or red.
        let match = ReopenMatch.compare(left: turned, reopened: afterTurns, saved: savedAtTurn)
        let turnedSame = !turned.isEmpty && match != .different
        let turnedAt = afterTurns.range(of: head(turned)).map { afterTurns.distance(from: afterTurns.startIndex, to: $0.lowerBound) } ?? -1
        note("round turned \(turnedSame ? "GREEN" : "RED") startsSame=\(turnedSame) match=\(match.rawValue) hisStartAt=\(turnedAt) turnedHead=\(hash(head(turned))) savedHead=\(hash(head(savedAtTurn))) reopenedHead=\(hash(head(afterTurns)))")
        XCTAssertTrue(turnedSame, "after two turns: reopened on the spread he turned to")
        assertNoVisibleSettleMove("after two turns")
        // Ended here, not by XCTest at teardown, where #44 recorded "Failed to terminate" (gatefold#76).
        app.quit()
    }
}
