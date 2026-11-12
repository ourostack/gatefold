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

    /// Reads `settle` waits while the opening cover is up (`reader.pageReady` 0): 1200, at least 0.3 s apart, as
    /// CountingPlaceholder's page-ready wait (#94). The app keeps that cover up while the chapter loads, so a reopen on a
    /// starved host can show no words for over a minute: 63 s in #238's round 2 (run 43214477644), still loading after
    /// 67 s in #195's round 4 (run 43238536988). The old 60 s settle returned an empty page then, hashed e3b0c44298fc
    /// (#214), though the screen still showed the cover.
    private static let settleReads = 1200
    /// Reads the words get once the reader reports its page ready: past that, an empty page is a blank page, an app
    /// defect, and fails at once instead of waiting out the cover's allowance.
    private static let readyReads = 200
    /// Reads (at least 0.1 s apart, `readsUntil`) a tap waits for a jump's veil to lift: 1200. #307's round 4 (run
    /// 43241520045) ran out of 600, about 90 s, with Catch up's jump still on its way to its chapter (#94, #214).
    private static let veilReads = 1200
    /// Reads that must repeat the words unchanged: 9, so 9 gaps of at least 0.3 s, no less than the old 2.5 s.
    private static let quietReads = 9

    /// The page's words once they have come and then repeated unchanged for `quietReads` reads, and the reads it took.
    /// Judged in reads and the reader's own ready report, never seconds (#94, #214). Empty words never count as
    /// settled. The hang guard (`HangGuard`) only catches a hang.
    private func settle(round: Int, _ what: String) -> (words: String, reads: Int) {
        let ready = el("reader.pageReady")
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: Self.settleReads))
        var last = "", same = 0, readyAt: Int?
        for read in 1...Self.settleReads {
            let now = words
            if now == last { same += 1 } else { last = now; same = 0 }
            if !now.isEmpty, same >= Self.quietReads { return (now, read) }
            if readyAt == nil, (ready.value as? String) == "1" { readyAt = read }
            if let readyAt, now.isEmpty, read - readyAt >= Self.readyReads {
                // "REOPEN round N:" so the iPad step's log filter keeps it.
                print("REOPEN round \(round): \(what) blank: the page was ready at read \(readyAt) and showed no words \(Self.readyReads) reads later")
                XCTFail("\(what): the page was ready and showed no words for \(Self.readyReads) reads")
                return (now, read)
            }
            if Date() > guardEnds {
                XCTFail("hang: \(what) ran \(read) reads without settled words")
                return (now, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("REOPEN round \(round): \(what) no settled words after \(Self.settleReads) reads (words \(!last.isEmpty), ready \(readyAt.map(String.init) ?? "never"))")
        XCTFail(last.isEmpty ? "\(what): the page never showed words in \(Self.settleReads) reads"
                             : "\(what): the words never held still in \(Self.settleReads) reads")
        return (last, Self.settleReads)
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
        // Read from one snapshot each and tapped at the point, never `isHittable`: asked of an offer mid-fold, it
        // fails the test (gatefold#236). After an offer tap the page gets 10 looks to answer before another, as
        // NavigationPlace's offer taps since #171. Taken only once the offer and its tab are both gone (taking it
        // hides the slip at once): an offer that folded just before its tap leaves the tab, and that tap may have
        // turned the page instead, which fails below rather than going on from the wrong page.
        let window = app.frame
        // Gone means gone on two looks in a row (one read can come back empty on a starved runner), and words seen
        // while a tap's quiet looks run don't end the look: the slip fades out over 0.35 s after a take.
        // The offer is tapped as soon as its frame is read, with no other query between, and a tab tap is followed
        // straight away by a look for the offer it opened (no quiet looks): opened, it folds again 10 s later, and on
        // a loaded runner two quiet looks outlasted that every time (#238's run 43030197427: 30 tab taps, the offer
        // seen between them and never tapped), where `element.tap()` on the next look took it (main, 4.7 s after).
        // That look skips even the words read: a tab just up means an offer to take. An offer still up once a tap's
        // quiet looks are spent is tapped again (the old loop stopped there and failed).
        var looks = 0, taps = 0, quiet = 0, gone = 0, taken = false, afterTab = false
        while looks < 200 {
            if Date() > hung { XCTFail("hang: looking for the Cloud's offer ran \(looks) looks over 2400 s"); return }
            looks += 1
            let wordsShown = afterTab ? false : !words.isEmpty
            afterTab = false
            if wordsShown, taps == 0 { break }
            let offerAt = HitCheck.frame(of: offer)
            if quiet == 0, let f = offerAt.flatMap({ HitCheck.usable($0, within: window) }) {
                HitCheck.tap(f, in: app); taps += 1; quiet = 10; gone = 0
                RunLoop.current.run(until: Date().addingTimeInterval(0.3))
                continue
            }
            let tabAt = HitCheck.frame(of: tab)
            gone = taps > 0 && offerAt == nil && tabAt == nil ? gone + 1 : 0
            if gone >= 2 { taken = true; break }
            if wordsShown, quiet == 0, gone == 0 { break }
            if quiet > 0 {
                quiet -= 1
            } else if let f = tabAt.flatMap({ HitCheck.usable($0, within: window) }) {
                HitCheck.tap(f, in: app); afterTab = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        if taps > 0, !taken {
            XCTFail("\(taps) taps meant for the Cloud's offer didn't take it in \(looks) looks (its tab is still up, words \(!words.isEmpty))")
            return
        }
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        // "REOPEN round N:" so the iPad step's log filter keeps it.
        guard taken else {
            print("REOPEN round \(round): no offer taken after \(looks) looks in \(secs) s; tab \(tab.exists) offer \(offer.exists) words \(!words.isEmpty)")
            return
        }
        print("REOPEN round \(round): offer taken after \(looks) looks (\(taps) taps) in \(secs) s")
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
    /// Reads of the app until `done`, never seconds (gatefold#94): each read waits at least 0.1 s, so `reads` is the
    /// floor a fast runner gets. The hang guard only catches a hang: `HangGuard` sizes it from `reads` and ends it
    /// before the step does.
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > guardEnds { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads, false)
    }

    /// The controls, judged in reads (gatefold#233). A tap under a jump's veil is swallowed, and the veil can stay
    /// up for a chapter that loads for minutes (#94: 135.7 s in run 43010124019), so each tap waits for the veil
    /// to lift first. Then up to 30 reads for the controls to come up, never a second tap while they fade in
    /// (it would put them down). If they never come up, the test says so, not a tap on a missing control, and
    /// returns false: the caller ends the test there, since every later step and round would wait on them too.
    private func numbersOn() -> Bool {
        let appearance = el("reader.appearance")
        let veil = el("reader.veil")
        for tap in 1...4 where !appearance.exists {
            let lifted = readsUntil(reads: Self.veilReads) { !veil.exists }
            guard lifted.ok else {
                print("REOPEN controls: the veil was still up after \(lifted.reads) reads\(lifted.hung ? " (hang guard)" : "")")
                break
            }
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            let up = readsUntil(reads: 30) { appearance.exists && appearance.isHittable }
            print("REOPEN controls: tap \(tap) up=\(up.ok) after \(up.reads) reads\(up.hung ? " (hang guard)" : "")")
            if up.hung { break }
        }
        guard appearance.exists else {
            XCTFail("the controls come up for Page Numbers (veil up: \(veil.exists))")
            return false
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
        return true
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
                                   "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                   // This host's looks take seconds; the offer mustn't fold between a look and the tap (#207, as
                                   // NavigationPlace's cover test). The fold isn't what this test checks.
                                   "-GatefoldOfferFoldSeconds", "600"]
            app.relaunch()
            open()
            takeTheOffer(round: round)
            let opened = settle(round: round, "open").words
            guard numbersOn() else { app.quit(); return }
            // The number takes the "Counting pages…" slot: the layout report this guards against.
            _ = el("reader.pageNumber").waitForExistence(timeout: 180)
            let left = settle(round: round, "leave").words
            print("REOPEN round \(round) leaves \(clock.string(from: Date()))")
            toShelf()
            print("REOPEN round \(round) reopens \(clock.string(from: Date()))")
            open()
            let (back, backReads) = settle(round: round, "reopen")
            let ok = !left.isEmpty && back == left
            if ok { same += 1 }
            print("REOPEN round \(round): opened \(Self.hash(opened)) left \(Self.hash(left)) back \(Self.hash(back)) after \(backReads) reads, ready \((el("reader.pageReady").value as? String) ?? "?"), \(clock.string(from: Date())) \(ok ? "SAME" : "MISS")")
            XCTAssertTrue(ok, "round \(round) returned other words (\(Self.hash(left)) then \(Self.hash(back)))")
            app.quit()
        }
        print("REOPEN SUMMARY method \(k): same=\(same) of \(mine.count) (rounds \(mine.map(String.init).joined(separator: ",")))")
    }
}
