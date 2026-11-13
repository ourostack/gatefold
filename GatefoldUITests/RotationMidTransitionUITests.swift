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

    /// Returns the row tapped, which is gone once the jump has closed the list.
    private func tapContentsRow() -> XCUIElement {
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
        return pick
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
        let row = tapContentsRow()
        XCUIDevice.shared.orientation = .landscapeLeft
        // A cold Contents jump alone takes up to 8.8 s; on CI's erased iPad, with the turn on top, the
        // page loaded past 20 s (blank paper and a spinner, then the whole spread). Measured, bounded at 45.
        expectWholeSpread("a turn of the iPad during a Contents jump", within: 45)
        // Asked after the turn, so the turn still comes straight after the tap, while the jump is moving.
        XCTAssertFalse(row.exists, "the Contents jump was taken (the list is still up)")
    }

    /// The last resort: a restore that never comes back (held on purpose) still uncovers the spread
    /// within 20 s of the turn, never the old page under a frozen leaf.
    func testARestoreThatNeverSettlesStillShowsTheSpread() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch(["-GatefoldStallReflow", "YES"])
        XCUIDevice.shared.orientation = .landscapeLeft
        expectWholeSpread("a turn of the iPad whose restore never settles")
    }

    // MARK: A cold turn on its side, and back (gatefold#302)

    /// One look at a landscape spread: the share of dark pixels on each page, and whether a grey band stands
    /// across the page from top to bottom (a leaf on edge, risen and not laid flat; build 25's frames had one
    /// about 300 px wide over the left page for 6 s and more). Whole is words on both pages and no band.
    struct SpreadLook {
        let ink: (Double, Double)
        let band: Bool
        var whole: Bool { ink.0 > 0.01 && ink.1 > 0.01 && !band }
        var text: String { String(format: "%.3f/%.3f%@", ink.0, ink.1, band ? " band" : "") }
    }

    static func look(_ image: UIImage) -> SpreadLook? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        // The spread runs along the picture's long side, whichever way the raw picture is turned.
        let alongX = w >= h
        let long = alongX ? w : h, short = alongX ? h : w
        var a = 0, b = 0, run = 0, longest = 0
        for p in stride(from: 0, to: long, by: 2) {
            var grey = 0, samples = 0
            for q in stride(from: 0, to: short, by: 2) {
                let v = alongX ? px[q * w + p] : px[p * w + q]
                if v < 110 { if p < long / 2 { a += 1 } else { b += 1 } }
                // Paper is white, words near black; a leaf's shade is the grey between, from top to bottom.
                if v >= 120, v < 230 { grey += 1 }
                samples += 1
            }
            if samples > 0, Double(grey) / Double(samples) >= 0.6 { run += 2; longest = max(longest, run) } else { run = 0 }
        }
        let half = Double(w * h) / 8
        return SpreadLook(ink: (Double(a) / half, Double(b) / half), band: longest >= long / 100)
    }

    private func count(_ id: String) -> Int { Int((el(id).value as? String) ?? "") ?? 0 }
    /// The latest reflow's number, and whether it has settled ("3 settled").
    private var reflow: (number: Int, settled: Bool) {
        let v = (el("reader.reflow").value as? String) ?? ""
        return (Int(v.split(separator: " ").first ?? "") ?? 0, v.hasSuffix("settled"))
    }
    /// Settled: a reflow newer than `before` has settled, never the one from before the turn.
    private func settledSince(_ before: Int) -> Bool { let r = reflow; return r.number > before && r.settled }
    private func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private func head(_ t: String) -> String { String(t.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) }

    /// The build 25 review's path: a fresh open in portrait at 0.31, counted, a Contents jump (entry 31), two pages
    /// read. Returns his page's words (compared, never printed).
    private func readTwoPagesAfterAJump() -> String {
        launch()
        let pageCount = el("reader.pageCount")
        let counted = readsUntil(reads: 3000) { pageCount.exists && !((pageCount.value as? String) ?? "").isEmpty }
        XCTAssertTrue(counted.ok, "the book was counted before the turn (not in \(counted.reads) reads)")
        _ = settle(30)
        let row = tapContentsRow()
        _ = readsUntil(reads: 300) { !row.exists }
        _ = settle(40)
        for _ in 0..<2 {
            let before = words
            turn()
            _ = readsUntil(reads: 150) { let now = words; return !now.isEmpty && now != before }
            _ = settle(20)
        }
        return words
    }

    /// Turned on its side, cold: the spread opens whole and stays whole, and the leaf rising from the spine never
    /// stands waiting on it for more than a moment. Build 25 kept the old portrait page up with the right page blank and the risen leaf
    /// standing over it for 6 s and more; its check took a look from before the turn as the whole spread
    /// (`wholeAt=0.0 s`). Judged in frames: the app's display frames with the leaf standing, and looks at the
    /// screen from the first one the reader lays out as a spread.
    func testAColdTurnOnItsSideOpensAWholeSpreadWithNoStandingLeaf() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        _ = readTwoPagesAfterAJump()
        let stoodBefore = count("reader.leafStoodFrames"), reflowBefore = reflow.number
        XCUIDevice.shared.orientation = .landscapeLeft
        let spread = readsUntil(reads: 100) { el("reader.posture").label == "spread" }
        XCTAssertTrue(spread.ok, "the reader laid out a spread (not in \(spread.reads) reads)")
        // The first looks can still be the picture from before the turn, and the unfold itself (the leaf rising,
        // then swinging open) covers part of the spread for a moment: those are not counted against it. A look
        // that isn't whole counts once the leaf has stood waiting, or once the reflow has settled.
        var looks: [SpreadLook] = [], standingLooks = 0, afterSettled = 0, quiet = 0
        for n in 0..<60 {
            // Asked before the picture is taken, so a look counted as after the settle is one.
            let settled = settledSince(reflowBefore)
            let shot = XCUIScreen.main.screenshot()
            guard let look = Self.look(shot.image) else { continue }
            looks.append(look)
            if !look.whole {
                if count("reader.leafStoodFrames") > stoodBefore { standingLooks += 1 }
                if settled { afterSettled += 1 }
                if looks.filter({ !$0.whole }).count <= 6 {
                    let a = XCTAttachment(screenshot: shot); a.name = "turn-look-\(n)-\(look.text)"; add(a)
                }
            }
            // Done once the reflow has settled and the spread has held whole for eight looks running.
            quiet = look.whole && settled ? quiet + 1 : 0
            if quiet >= 8 { break }
        }
        let stood = count("reader.leafStoodFrames") - stoodBefore
        let nonWhole = looks.filter { !$0.whole }
        print("COLDTURN looks=\(looks.count) nonWhole=\(nonWhole.count) blankHalf=\(nonWhole.filter { $0.ink.0 <= 0.01 || $0.ink.1 <= 0.01 }.count) band=\(nonWhole.filter(\.band).count) standingLooks=\(standingLooks) afterSettled=\(afterSettled) leafStoodFrames=\(stood) [\(looks.map(\.text).joined(separator: ", "))]")
        // A leaf that pauses at the top of its rise for a moment is a beat of the unfold; one that stands there
        // waiting on a reloaded chapter is the stuck curl. Hosted runners lay the spread out 2 to 4 times slower
        // than a Mac, so the bar leaves the fix's slowest hosted run room: build 25's main stood 226 display frames
        // and 7 looks on a hosted runner (probe 43288332572), the fix 22 and 34 frames and 1 look (43288337838).
        XCTAssertLessThanOrEqual(stood, 90, "the leaf stood risen over the old page for \(stood) frames, waiting on its spread")
        XCTAssertLessThanOrEqual(standingLooks, 2, "\(standingLooks) looks showed a blank page or a standing leaf while the leaf stood")
        XCTAssertEqual(afterSettled, 0, "\(afterSettled) looks showed a blank page or a leaf after the reflow settled")
        XCTAssertGreaterThanOrEqual(quiet, 8, "the spread didn't settle whole in \(looks.count) looks")
    }

    /// Turned on its side and back upright without a turn of the page, he is on his page: the chapter's page is kept
    /// through both turns (build 25 loaded it again, which opens at the chapter's first page: a title page for
    /// about 1.4 s), and its margins are the ones the page was read in (build 25's open kept a phone's margins in
    /// portrait until the first turn on its side set the iPad's, so back upright his words fell a third of a page
    /// down another page: 16 became 17). Judged in reads: the page's loads, and his first words, by hash.
    func testTurnedOnItsSideAndBackHeIsOnHisPage() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        let his = readTwoPagesAfterAJump()
        XCTAssertFalse(his.isEmpty, "his page's words are readable")
        let freshBefore = count("reader.reflowFreshPages"), beforeTurn = reflow.number
        XCUIDevice.shared.orientation = .landscapeLeft
        _ = readsUntil(reads: 100) { el("reader.posture").label == "spread" }
        _ = readsUntil(reads: 300) { settledSince(beforeTurn) }
        let spread = settle(30), beforeBack = reflow.number
        XCUIDevice.shared.orientation = .portrait
        _ = readsUntil(reads: 100) { el("reader.posture").label == "single" }
        _ = readsUntil(reads: 300) { settledSince(beforeBack) }
        let back = settle(30)
        let fresh = count("reader.reflowFreshPages") - freshBefore
        let at = back.range(of: head(his)).map { back.distance(from: back.startIndex, to: $0.lowerBound) } ?? -1
        print("TURNBACK hisHead=\(hash(head(his))) spreadHasHis=\(spread.contains(head(his))) backHead=\(hash(head(back))) hisStartAt=\(at) freshPages=\(fresh)")
        XCTAssertEqual(fresh, 0, "the chapter's page was loaded again \(fresh) times across the two turns (a reload opens on its first page)")
        XCTAssertTrue(spread.contains(head(his)), "on its side, the spread holds his page's first words")
        // By hash: book text never goes into a log.
        XCTAssertEqual(hash(head(back)), hash(head(his)), "back upright, his page opens on his first words (they start \(at) characters in)")
    }

    func testTurningDuringAPageTurn() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        launch()
        let row = tapContentsRow()
        turn()
        turn()
        XCUIDevice.shared.orientation = .landscapeLeft
        // The restore under the turns can need the 12 s watchdog, and a hosted runner runs about twice
        // as slow as this Mac (19 s here, 21 s there): bounded at 30 s, timing printed.
        expectWholeSpread("a turn of the iPad during page turns after a jump", within: 30)
        XCTAssertFalse(row.exists, "the Contents jump was taken (the list is still up)")
    }
}
