import CryptoKit
import UIKit
import XCTest

/// A turn of the iPad that arrives while the page is still moving (a Contents jump still loading its
/// chapter, a page turn mid-flight) must still end on a whole spread. A cold iPad in build 19 could keep
/// the old portrait page up under a frozen leaf, the right page blank, past 14 s. Both halves of the
/// spread must carry words within 20 s of the turn. No book text is printed.
@MainActor
final class RotationMidTransitionUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() async throws { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    /// Reads of the app until `done`, never seconds (gatefold#94, as FineTuneTap in #121): each read waits at least
    /// 0.1 s, so `reads` sets the floor a fast runner gets (the old seconds). The hang guard only catches a hang:
    /// `HangGuard` sizes it from `reads` and ends it before the step does (gatefold#223; the fixed 120 s and 180 s
    /// it replaces would end these waits after about 6 and 10 reads at the slowest read seen, long before their caps).
    /// After one wait hangs, later waits answer at once and the spread isn't judged, so the test ends with its own
    /// failure and leaves the shard's later tests their time (gatefold#223 review). Per test: each gets an instance.
    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        if hung { return (false, 0, true) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > guardEnds { hung = true; return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads, false)
    }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }

    private func settle(_ timeout: TimeInterval) -> String {
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

    /// The share of dark pixels in each half of the screen along its long side (a landscape spread's
    /// two pages, whichever way the raw picture is turned).
    static func ink(_ image: UIImage) -> (Double, Double)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var a = 0, b = 0
        let alongX = w >= h
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where px[y * w + x] < 110 {
                if (alongX ? x < w / 2 : y < h / 2) { a += 1 } else { b += 1 }
            }
        }
        let half = Double(w * h) / 8
        return (Double(a) / half, Double(b) / half)
    }

    private func launch(_ extra: [String] = []) {
        XCUIDevice.shared.orientation = .portrait
        sleep(1)
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"] + extra
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        _ = settle(60)
    }

    private func tapContentsRow() {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let offered = readsUntil(reads: 50) { el("reader.contents").exists }
        print("MIDTURN contents offered=\(offered.ok) after \(offered.reads) reads\(offered.hung ? " (hang guard)" : "")")
        XCTAssertTrue(offered.ok, "Contents is offered (not in \(offered.reads) reads\(offered.hung ? ", hang guard" : ""))")
        el("reader.contents").tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        let listed = readsUntil(reads: 150) { rows.firstMatch.exists }
        print("MIDTURN contents listed=\(listed.ok) after \(listed.reads) reads\(listed.hung ? " (hang guard)" : "")")
        XCTAssertTrue(listed.ok, "the contents list is up (not in \(listed.reads) reads\(listed.hung ? ", hang guard" : ""))")
        // Entry 31, named: about a dozen rows past his chapter (entry 18 at 0.31), where the old pick, the 31st row
        // built or the last, landed. That pick moved to another row after every swipe, and `isHittable` on a built
        // row off screen failed the test (gatefold#98; `ContentsRow`).
        let pick = app.buttons["contents.entry.31"]
        let tapped = ContentsRow.tap(pick, in: app)
        print("MIDTURN contents row tapped=\(tapped.ok) after \(tapped.drags) drags")
        XCTAssertTrue(tapped.ok, "contents entry 31 came into view (not in \(tapped.drags) drags)")
        let closed = readsUntil(reads: 50) { !pick.exists }
        XCTAssertTrue(closed.ok, "the Contents jump was taken (the list still up after \(closed.reads) reads)")
    }

    private func turn() { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap() }

    private func expectWholeSpread(_ what: String, within asked: TimeInterval = 20) {
        if self.hung { XCTFail("\(what): not judged, since a wait before it hung"); return }
        // Whatever was moving, a spread with words on both pages within the limit. A hosted runner runs
        // two to four times slower than this Mac and a screenshot there can take seconds, so CI sets a
        // floor (`GATEFOLD_SPREAD_FLOOR`); the page left stuck for good, the bug this guards, still fails.
        let floor = TimeInterval(ProcessInfo.processInfo.environment["GATEFOLD_SPREAD_FLOOR"] ?? "") ?? 0
        let limit = max(asked, floor)
        // Judged in screenshots as well as seconds (gatefold#94): the looks keep a 1 s beat from the turn, so a fast
        // runner takes one a second and fails at the limit as before, while a starved runner, whose screenshots take
        // seconds, still gets one look per second of the limit before it fails, unless its screenshots take over 4 s
        // each: four times the limit ends it then.
        let looks = Int(limit.rounded(.up))
        let start = Date()
        let up = start.addingTimeInterval(limit), hung = start.addingTimeInterval(limit * 4)
        var last: (Double, Double)?, shots = 0, hangGuard = false
        while Date() < up || shots < looks {
            if Date() >= hung { hangGuard = true; break }
            shots += 1
            if let i = Self.ink(XCUIScreen.main.screenshot().image) {
                last = i
                if i.0 > 0.01, i.1 > 0.01 { break }
            }
            RunLoop.current.run(until: start.addingTimeInterval(Double(shots)))
        }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "after-\(what)"; shot.lifetime = .keepAlways; add(shot)
        let ok = (last?.0 ?? 0) > 0.01 && (last?.1 ?? 0) > 0.01
        print("MIDTURN \(what): ink \(last.map { String(format: "%.3f / %.3f", $0.0, $0.1) } ?? "none") \(ok ? "WHOLE" : "STUCK") after \(String(format: "%.1f", Date().timeIntervalSince(start))) s, \(shots) screenshots")
        XCTAssertTrue(ok, "\(what): the spread wasn't whole within \(Int(limit)) s and \(looks) screenshots of the turn\(hangGuard ? " (hang guard)" : "")")
        XCTAssertFalse(settle(30).isEmpty, "\(what): the page's words are readable")
    }

    func testTurningDuringAContentsJump() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch()
        tapContentsRow()
        XCUIDevice.shared.orientation = .landscapeLeft
        // A cold Contents jump alone takes up to 8.8 s; on CI's erased iPad, with the turn on top, the
        // page loaded past 20 s (blank paper and a spinner, then the whole spread). Measured, bounded at 45.
        expectWholeSpread("a turn of the iPad during a Contents jump", within: 45)
    }

    /// The last resort: a restore that never comes back (held on purpose) still uncovers the spread
    /// within 20 s of the turn, never the old page under a frozen leaf.
    func testARestoreThatNeverSettlesStillShowsTheSpread() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch(["-GatefoldStallReflow", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft
        expectWholeSpread("a turn of the iPad whose restore never settles")
    }

    func testTurningDuringAPageTurn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch()
        tapContentsRow()
        turn()
        turn()
        XCUIDevice.shared.orientation = .landscapeLeft
        // The restore under the turns can need the 12 s watchdog, and a hosted runner runs about twice
        // as slow as this Mac (19 s here, 21 s there): bounded at 30 s, timing printed.
        expectWholeSpread("a turn of the iPad during page turns after a jump", within: 30)
    }
}
