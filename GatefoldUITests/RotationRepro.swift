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
///     is counted (`reader.pageCount` has a value; in the restore tests, after step 3), let the words settle.
///  2. Controls up, Contents, tap contents entry 11, by its identifier,
///     let the words settle.
///  3. Read two pages: two forward taps at the right edge, each waiting for the words to change and settle.
///  4. Turn the iPad to landscape (`.landscapeLeft`), wait for the words to change, then a long settle.
///     The words now on screen are "his page".
///  5. Three rounds: Home, wait for iOS to suspend Gatefold, terminate, relaunch without `-GatefoldReset`,
///     set `.landscapeLeft` again, a long settle. Compare with his page.
/// Every wait is counted in reads (a settle is the same words several reads running), never in seconds
/// (gatefold#266).
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

    /// Reads until `done` holds, a quarter second apart. Judged in reads; the hang guard only ends a wait
    /// whose reads stopped coming back (a starved runner takes seconds per query).
    private func readsUntil(reads: Int, hangGuard: TimeInterval, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(hangGuard)
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > hung { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return (false, reads, false)
    }
    /// Non-empty, then the same words `quiet` reads in a row. A short settle (3 reads) stands for the old
    /// 2.5 s of quiet. A long one (12 reads, about 9 s on the fastest runner's 0.5 s reads) stands for the
    /// old settle, 4 s and a second settle, so a late move after the first quiet is still seen. A settle the
    /// hang guard ended is logged: its words are the latest read, not a quiet page.
    private static let longQuiet = 12
    private func settle(quiet: Int = 3, hangGuard: TimeInterval = 60, _ when: String = "") -> String {
        let hung = Date().addingTimeInterval(hangGuard)
        var last = "", same = 0, reads = 0
        while Date() < hung {
            let now = vtext
            reads += 1
            if now.isEmpty || now != last { last = now; same = now.isEmpty ? 0 : 1 } else { same += 1 }
            if same >= quiet { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if !when.isEmpty || same < quiet {
            note("settle \(when.isEmpty ? "-" : when) \(same >= quiet ? "quiet" : "HANG GUARD") after \(reads) reads (\(same) of \(quiet) the same)")
        }
        return last
    }
    private func turnForward() {
        let old = vtext
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        _ = readsUntil(reads: 60, hangGuard: 15) { let now = vtext; return !now.isEmpty && now != old }
        _ = settle(hangGuard: 20)
    }
    /// He leaves: Home, then Gatefold is ended once iOS suspends it (its leaving work, the place sent and
    /// the reopen picture kept, has ended). The simulator under XCUITest never reports the suspension
    /// (gatefold#266's probe: 0 of 12 leaves), so the guard, the old 3 s, is what ends this wait there.
    private func leave(_ when: String) {
        XCUIDevice.shared.press(.home)
        let suspended = app.wait(for: .runningBackgroundSuspended, timeout: 3)
        note("left \(when) suspended=\(suspended)")
        app.quit()
    }
    /// Every move a settle made was behind a cover or a held picture: none on a page he could see.
    private func assertNoVisibleSettleMove(_ when: String) {
        let seen = el("reader.visibleSettleMove").exists
        note("visibleSettleMove \(when)=\(seen)")
        XCTAssertFalse(seen, "\(when): a settle moved the page with nothing over it")
    }
    private func waitCounted() -> Bool {
        let count = el("reader.pageCount")
        return readsUntil(reads: 1200, hangGuard: 300) {
            count.exists && !((count.value as? String) ?? "").isEmpty
        }.ok
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
    /// on the page he saw. The count is waited for just before the rotation, not before the jump: the
    /// jump and turns run while it counts (gatefold#266), and the restore still runs on a counted book.
    func testRotateThenLeaveWhileTheRestoreWaitsOnItsPage() throws {
        try rotateThenLeave(extra: Self.slowRestore, countBeforeJump: false)
    }

    /// The same, with the shown page noted only as Readium names it: on a device whose page scripts wait
    /// on the stalled install too, its words never come back before he leaves.
    func testRotateThenLeaveWhileTheRestoreWaitsOnItsPageWithoutItsWords() throws {
        try rotateThenLeave(extra: Self.slowRestore + ["-GatefoldShownPageWithoutWords", "YES"], countBeforeJump: false)
    }

    /// The same, with each reopen landing on the chapter's start (`-GatefoldReopenOnChapterStart`), as a
    /// reopen whose stalled restore settled there did on CI (gatefold#250, round 3 of run 43047479324): the
    /// saved place has no words, so only the open's own place can bring him back to his page.
    func testRotateThenLeaveWithoutItsWordsAndReopenOnTheChapterStart() throws {
        try rotateThenLeave(extra: Self.slowRestore + ["-GatefoldShownPageWithoutWords", "YES"],
                            reopenExtra: ["-GatefoldReopenOnChapterStart", "YES"])
    }

    private static let slowRestore = ["-GatefoldSlowRestorePage", "YES"]

    /// `countBeforeJump`: the book is counted before the Contents jump, as in the first repro; otherwise
    /// just before the rotation. Counted before the rotation either way.
    private func rotateThenLeave(extra: [String] = [], reopenExtra: [String] = [], countBeforeJump: Bool = true) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        // 1. Portrait, fresh install, open, wait for the count.
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = base + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        var counted = false
        if countBeforeJump {
            counted = waitCounted()
            XCTAssertTrue(counted, "the book was counted before the rotation")
        }
        _ = settle()

        // 2. A Contents jump.
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let contents = el("reader.contents")
        let controls = readsUntil(reads: 120, hangGuard: 30) { contents.exists && contents.isHittable }
        XCTAssertTrue(controls.ok, controls.hung ? "Contents is up (the hang guard ran out after \(controls.reads) reads)"
                                                 : "Contents is up (not in \(controls.reads) reads)")
        contents.tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 15), "the contents list is up")
        // The lazy list's rows, once it stops loading more: the same count two reads running.
        var loadedCount = -1
        _ = readsUntil(reads: 12, hangGuard: 10) { let n = rows.count; defer { loadedCount = n }; return n == loadedCount }
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
        for _ in 0..<10 where !(pick.exists && HitCheck.hittable(pick, in: app)) {
            // A short drag inside the list, never a swipe from its top: a pull-down there closes the sheet.
            let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.35 : 0.65))
            let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: above ? 0.65 : 0.35))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
        XCTAssertTrue(pick.isHittable, "contents entry 11 is on screen")
        pick.tap()
        // The old page stays put while the jump loads (over 10 s on a hosted runner), so wait for the
        // words to change before waiting for them to settle.
        let landed = readsUntil(reads: 240, hangGuard: 60) { let now = vtext; return !now.isEmpty && head(now) != head(beforeJump) }
        print("REPRO jump landed after \(landed.reads) reads\(landed.hung ? " (hang guard)" : "")")
        _ = settle()
        let jumped = !vtext.isEmpty && head(vtext) != head(beforeJump)
        XCTAssertTrue(jumped, "the Contents jump moved the page")

        // 3. Two pages read.
        turnForward()
        turnForward()
        if !countBeforeJump {
            counted = waitCounted()
            XCTAssertTrue(counted, "the book was counted before the rotation")
        }

        // 4. Turn the iPad. The words change once the spread is shown (settled, or shown as it is by the
        // watchdog), then a long settle: a restore started again can still move it.
        let beforeTurn = vtext
        XCUIDevice.shared.orientation = .landscapeLeft
        let reflowed = readsUntil(reads: 240, hangGuard: 60) { let now = vtext; return !now.isEmpty && now != beforeTurn }
        note("rotation shown after \(reflowed.reads) reads\(reflowed.hung ? " (hang guard)" : "")")
        let his = settle(quiet: Self.longQuiet, hangGuard: 120, "his page")
        XCTAssertFalse(his.isEmpty)
        note("setup counted=\(counted) contentsRows=\(rowCount) jumped=\(jumped) hisHead=\(hash(head(his)))")
        assertNoVisibleSettleMove("the rotation")

        // 5. Leave without turning, three times.
        var green = 0
        for round in 1...3 {
            leave("round \(round)")
            app.launchArguments = base + reopenExtra
            app.relaunch()
            XCUIDevice.shared.orientation = .landscapeLeft
            let back = settle(quiet: Self.longQuiet, hangGuard: 120, "round \(round)")
            let startsSame = head(back) == head(his)
            let middleSame = back.contains(middle(his))
            let at = back.range(of: head(his)).map { back.distance(from: back.startIndex, to: $0.lowerBound) } ?? -1
            if startsSame { green += 1 }
            note("round \(round) \(startsSame ? "GREEN" : "RED") startsSame=\(startsSame) middleSame=\(middleSame) hisStartAt=\(at) reopenedHead=\(hash(head(back)))")
            XCTAssertTrue(startsSame, "round \(round): reopened on his page")
            assertNoVisibleSettleMove("round \(round)")
        }
        note("SUMMARY green=\(green) of 3")

        // 6. Two turns on the spread the restore laid out (a column break at his words, when it put one in), then
        // leave: the reopen lands on the spread he turned to, not one the fresh layout's own columns make.
        turnForward()
        turnForward()
        let turned = settle(quiet: 4, hangGuard: 20)
        let savedAtTurn = (el("reader.savedWords").value as? String) ?? ""
        leave("after two turns")
        app.launchArguments = base
        app.relaunch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let afterTurns = settle(quiet: Self.longQuiet, hangGuard: 120, "after two turns")
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
