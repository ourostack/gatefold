import CryptoKit
import UIKit
import XCTest

/// The taste reviewers' recurring checks, run by CI on every build instead of in a driver written again
/// for each review (Ari, 2026-11-04: "confirm you're doing what can be done with deterministic tooling
/// with deterministic tooling"). Pages are compared by hash; no book text is printed or kept.
///
/// Covered elsewhere and run beside these: consecutive numbers and +1/+2 a turn
/// (`PageNumberUITests`), landing at rest (`SpreadTurnSettleUITests`), the tap rate
/// (`FineTuneTapUITests`).
@MainActor
final class ReviewerChecksUITests: XCTestCase {
    private var app: XCUIApplication!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private let base = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES"]

    // MARK: Helpers

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
    }
    private func note(_ s: String) { print("REVIEWER \(s)") }

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

    /// Waits are judged in reads of the app, never seconds (gatefold#105, as #94 and #121): each read is a round trip
    /// to the app, so a starved runner (a cold simulator's first reads take up to 10 s) makes reads slower instead of
    /// failing what landed late. Each read waits at least 0.2 s, so `reads` sets the floor a fast runner gets (the old
    /// seconds); `hangGuard` ends it on a runner so slow that the reads would run on.
    private func readsUntil(reads: Int, hangGuard: TimeInterval, _ done: () -> Bool) -> (ok: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(hangGuard)
        for read in 1...reads {
            if done() { return (true, read, false) }
            if Date() > hung { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return (false, reads, false)
    }

    /// A turn is his tap and then different words on the page, within 75 reads (the old 15 s at 0.2 s a read). The
    /// hang guard is well past the cap even at a cold read's 10 s (75 x 10 s is 750 s), so only a runner that has
    /// stopped answering reaches it, and it fails as a hang, not as a page that didn't turn.
    @discardableResult
    private func turnForward(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let before = words
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        let start = Date()
        let turned = readsUntil(reads: 75, hangGuard: 900) { let now = words; return now != before && !now.isEmpty }
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        note("TURNREADS turned=\(turned.ok) after \(turned.reads) reads in \(secs) s\(turned.hung ? " (hang guard)" : "")")
        if turned.hung { XCTFail("hang: the turn's reads ran on for \(secs) s (\(turned.reads) reads) without a verdict", file: file, line: line) }
        if turned.ok { _ = settle(15) }
        return turned.ok
    }

    /// The book's count, judged in reads and the reader's ready report (`ReaderReads.counted`, gatefold#122): the
    /// cover's reads while the page isn't ready, then 600 once it is. Never a fixed 300 s, which read a slow open as a
    /// book never counted.
    private func counted(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> Int? {
        ReaderReads.counted(app, what, say: note, file: file, line: line)
    }

    /// The reader's page is up, in reads (`ReaderReads.opened`, gatefold#122), never a fixed 60 to 120 s: a starved
    /// runner's fresh launch with every book downloading had not opened its book after 120 s (run 43301488929).
    private func opened(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        ReaderReads.opened(app, what, say: note, file: file, line: line) != nil
    }

    /// The page's words once they have come and held, judged in reads and the reader's ready report
    /// (`ReaderReads.settle`, #214, #122): an empty page never counts as settled.
    private func settled(_ what: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        ReaderReads.settle(app, what, say: note, file: file, line: line).words
    }

    /// `element` exists within `reads` reads at least 0.2 s apart (the old seconds on a fast runner, five reads a
    /// second); `HangGuard` only catches a hang.
    private func appears(_ element: XCUIElement, reads: Int) -> Bool {
        readsUntil(reads: reads, hangGuard: HangGuard.seconds(reads: reads)) { element.exists }.ok
    }

    private var numbers: [Int] {
        app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }
            // The label is formatted for reading ("1,023"); keep the digits.
            .compactMap { Int($0.label.filter(\.isNumber)) }
    }

    private func leaveAndRelaunch() -> String {
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) { XCUIApplication(bundleIdentifier: "com.apple.springboard").activate() }
        sleep(3)
        app.quit()
        app.launchArguments = base
        app.relaunch()
        XCTAssertTrue(opened("the reopen"), "the book reopened")
        _ = settled("the reopen")
        sleep(3)
        return settled("the reopen, again")
    }

    private func openFineTune() {
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appears(appearance, reads: 15)
        }
        appearance.tap()
        let fine = app.buttons["appearance.customize"]
        XCTAssertTrue(appears(fine, reads: 50), "Fine-Tune is offered")
        if !fine.isHittable { el("appearance.panel").swipeUp() }
        fine.tap()
    }

    private func pageNumbersSwitch() -> XCUIElement {
        let t = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(appears(t, reads: 50), "the Page Numbers switch")
        for _ in 0..<4 where !t.isHittable { el("appearance.panel").swipeUp() }
        return t
    }

    /// Sets Page Numbers through his Fine-Tune switch; the switch's own state is the answer.
    private func setPageNumbers(_ on: Bool) {
        openFineTune()
        let t = pageNumbersSwitch()
        if ((t.value as? String) == "1") != on {
            t.tap()
            // Judged in reads of the switch, not seconds (#219, #94): 25 reads at least 0.2 s apart (about the old 5 s on a
            // fast runner). One look at the app has taken up to 18.6 s here (#207), so 25 reads can run to about 450 s and
            // the guard is 600 s, not FineTuneTap's 180 s (#119); it only catches a hang. Then 5 reads that it stays turned.
            let want = on ? "1" : "0", start = Date(), hung = start.addingTimeInterval(600)
            var reads = 0, turned = false, hang = false
            while reads < 25 {
                if Date() > hung { hang = true; break }
                reads += 1
                if (t.value as? String) == want { turned = true; break }
                if reads < 25 { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
            }
            var held = 0
            while turned, held < 5, !hang {
                RunLoop.current.run(until: Date().addingTimeInterval(0.2))
                guard (t.value as? String) == want else { break }
                held += 1
            }
            let secs = String(format: "%.1f", Date().timeIntervalSince(start))
            note("switch \(on ? "on" : "off") turned=\(turned) after \(reads) reads in \(secs) s, held \(held) of 5\(hang ? " (hang guard)" : "")")
            if hang { XCTFail("hang: reading the Page Numbers switch ran \(reads) reads over 600 s") }
            else {
                XCTAssertTrue(turned, "the switch turned \(on ? "on" : "off") (not in \(reads) reads)")
                if turned { XCTAssertEqual(held, 5, "the switch stayed \(on ? "on" : "off") (\(held) of 5 reads)") }
            }
        }
        closePanel()
    }

    private func closePanel() {
        for id in ["appearance.close", "appearance.back", "appearance.close"] where app.buttons[id].exists { app.buttons[id].tap(); sleep(1) }
        if el("appearance.panel").exists { el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap() }
        sleep(2)
    }

    private func backToShelf() {
        let close = app.buttons["reader.close"].firstMatch
        for _ in 0..<4 where !(close.exists && close.isHittable) {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appears(close, reads: 15)
        }
        close.tap()
        XCTAssertTrue(appears(el("library.grid"), reads: 100), "back on the shelf")
        sleep(2)
    }

    private func openFromShelf(_ id: String) {
        let cover = el("book.\(id)")
        XCTAssertTrue(appears(el("library.grid"), reads: 100), "the shelf")
        for _ in 0..<8 where !(cover.exists && cover.isHittable) { el("library.grid").swipeUp(); sleep(1) }
        XCTAssertTrue(cover.exists, "\(id) is on the shelf")
        cover.tap()
        XCTAssertTrue(opened(id), "\(id) opened")
        // A first open here shows its start, a cover with no words, until the Cloud's offer is taken: no settle yet.
        sleep(2)
    }

    /// The Cloud's place offered on a first open here: take it (the tab brings back an offer that folded).
    /// The offer can fold into its tab between a look and the tap (#207), so it is tapped where its frame was just read (#236).
    /// Any type, never `app.buttons` (#165). Judged in looks, not seconds (#94): 200 at least 0.3 s apart (the old
    /// 60 s on a fast runner); the 2400 s guard only catches a hang: a look is up to five queries of the app, and a
    /// starved runner has taken 1-2 s a query, so 200 looks can run to about 2000 s. No 600 s hold here, unlike
    /// ReopenAfterControls: the offers of the books this test opens and leaves untaken must still fold off the page.
    private func takeTheOffer() {
        let offer = el("banner.jump"), tab = el("banner.tab")
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
        guard taken else {
            if words.isEmpty { note("no Cloud offer on a page with no words after \(looks) looks in \(secs) s") }
            return
        }
        note("offer taken after \(looks) looks (\(taps) taps) in \(secs) s")
        // Its own clock, so a slow look above doesn't spend this loop's guard.
        let shown = Date(), stuck = shown.addingTimeInterval(2400)
        var reads = 0
        while reads < 200, words.isEmpty {
            if Date() > stuck { XCTFail("hang: the offer's page ran \(reads) reads over 2400 s without words"); return }
            reads += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
    }

    /// A number is up within 600 reads (the old 120 s on a fast runner). Asked once the book is counted, so the
    /// number has nothing left to wait on.
    private func numbersShown() -> Bool { appears(el("reader.pageNumber"), reads: 600) }

    // MARK: Reopen returns the same words

    /// From three places, two turns on, then leave and come back three times with turns between: every
    /// reopen shows exactly the page he left (by hash). On the iPad it runs on a spread.
    func testEveryReopenReturnsTheSameWords() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        var same = 0, total = 0
        for spot in ["0.31", "0.12", "0.47"] {
            app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                          "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", spot]
            app.relaunch()
            XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened at \(spot)")
            _ = settle(120)
            turnForward(); turnForward()
            for round in 0..<3 {
                if round == 1 { turnForward() }
                if round == 2 { turnForward(); turnForward() }
                let left = settle(60)
                let back = leaveAndRelaunch()
                total += 1
                let ok = !left.isEmpty && back == left
                if ok { same += 1 }
                note("reopen at \(spot) round \(round + 1): left \(Self.hash(left)) back \(Self.hash(back)) \(ok ? "SAME" : "MISS")")
                XCTAssertTrue(ok, "reopen at \(spot), round \(round + 1), returned other words (\(Self.hash(left)) then \(Self.hash(back)))")
            }
            app.quit()
        }
        note("REOPEN SUMMARY same=\(same) of \(total)")
    }

    // MARK: True numbers

    /// The book's last page carries the book's count: an exact count ends where the book does.
    func testTheLastPagesNumberIsTheCount() {
        if pad { XCUIDevice.shared.orientation = .landscapeLeft; sleep(1) }
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldPageFurniture", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.993"]
        app.launch()
        XCTAssertTrue(opened("pride"), "the book opened")
        guard let count = counted("pride") else { return XCTFail("the book was never counted") }
        _ = settled("pride")
        XCTAssertTrue(numbersShown(), "a number is up")
        var last = numbers, turns = 0
        note("start numbers=\(last) labels=\(app.descendants(matching: .any).matching(identifier: "reader.pageNumber").allElementsBoundByIndex.map(\.label))")
        while turns < 40, !el("endLeaf").exists, turnForward() {
            turns += 1
            sleep(1)
            note("turn \(turns): numbers=\(numbers) endLeaf=\(el("endLeaf").exists)")
            if !el("endLeaf").exists, !numbers.isEmpty { last = numbers }
        }
        note("last page numbers=\(last) count=\(count) turns=\(turns) endLeaf=\(el("endLeaf").exists)")
        XCTAssertTrue(el("endLeaf").exists, "turning on reached the end of the book")
        XCTAssertEqual(last.last, count, "the last page's number is the book's count")
        if last.count == 2 { XCTAssertEqual(last[1], last[0] + 1, "the last spread's numbers are consecutive") }
    }

    // MARK: Reader-wide toggles

    /// Page Numbers is his setting, not a book's: off by default, on in one book is on in the next (a
    /// book with its own look included), off in one is off in all, kept across a relaunch, and the
    /// words never move.
    func testPageNumbersAreOnOrOffInEveryBook() {
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-emma", "-GatefoldGoTo", "0.2"]
        app.launch()
        XCTAssertTrue(opened("emma"), "the first book opened")
        XCTAssertNotNil(counted("emma"), "the book was counted")
        _ = settled("emma")
        // Emma gets a look of its own: one size larger.
        openFineTuneLarger()
        XCTAssertNotNil(counted("emma, larger"), "counted again at the larger size")
        XCTAssertTrue(numbersOff(), "off by default")
        backToShelf()

        openFromShelf("gutenberg-pride-and-prejudice")
        XCTAssertNotNil(counted("pride"), "the second book was counted")
        // Opened here for the first time, it shows its start (a cover, no words) and offers the Cloud's place.
        takeTheOffer()
        let before = settled("pride")
        XCTAssertGreaterThan(before.count, 0, "the page has words")
        XCTAssertTrue(numbersOff(), "off by default in a second book")
        setPageNumbers(true)
        XCTAssertTrue(numbersShown(), "on where he turned it on")
        let after = settled("pride, numbers on")
        note("words with numbers on: \(Self.hash(before)) then \(Self.hash(after)) numbers=\(numbers) chars=\(before.count)")
        XCTAssertGreaterThan(after.count, 0, "the page has words with numbers on")
        XCTAssertEqual(Self.hash(after), Self.hash(before), "turning numbers on moved no words")
        backToShelf()

        openFromShelf("gutenberg-emma")
        XCTAssertNotNil(counted("emma, again"), "the first book was counted again")
        XCTAssertTrue(numbersShown(), "on in a book with its own look")
        setPageNumbers(false)
        let number = el("reader.pageNumber")
        XCTAssertTrue(readsUntil(reads: 50, hangGuard: HangGuard.seconds(reads: 50)) { !number.exists }.ok, "off where he turned it off")
        backToShelf()

        openFromShelf("gutenberg-alice-in-wonderland")
        XCTAssertNotNil(counted("alice"), "the third book was counted")
        XCTAssertTrue(numbersOff(), "off in a book never opened")
        backToShelf()

        openFromShelf("gutenberg-pride-and-prejudice")
        XCTAssertNotNil(counted("pride, again"), "the first book was counted on return")
        XCTAssertTrue(numbersOff(), "off in the book where he had turned it on")
        let again = settled("pride, again")
        note("words back in the first book: \(Self.hash(before)) then \(Self.hash(again))")
        XCTAssertGreaterThan(again.count, 0, "the page has words on return")
        XCTAssertEqual(Self.hash(again), Self.hash(before), "and its words are where they were")
        let back = leaveAndRelaunch()
        note("words after a relaunch: \(Self.hash(back))")
        XCTAssertGreaterThan(back.count, 0, "the page has words after a relaunch")
        XCTAssertNotNil(counted("pride, relaunched"), "counted after a relaunch")
        XCTAssertTrue(numbersOff(), "still off after a relaunch")
        XCTAssertEqual(Self.hash(back), Self.hash(before), "on his page after a relaunch")
        if Self.hash(back) != Self.hash(before) {
            // Where he is now, by number, for the report.
            setPageNumbers(true)
            _ = numbersShown()
            note("after a relaunch numbers=\(numbers) chars=\(back.count)")
        }
    }

    /// Neither a number nor the "Counting pages…" slot: asked only once the book is counted, when a
    /// number would be up if the setting were on.
    /// Judged over 5 reads at least 0.2 s apart (the old single look after 1 s), every one with neither up.
    private func numbersOff() -> Bool {
        let number = el("reader.pageNumber"), counting = el("reader.pageCounting")
        for read in 1...5 {
            if number.exists || counting.exists { note("numbers up at read \(read) of 5"); return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return true
    }

    private func openFineTuneLarger() {
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.isHittable {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appears(appearance, reads: 15)
        }
        appearance.tap()
        let larger = app.buttons["appearance.larger"].firstMatch
        XCTAssertTrue(appears(larger, reads: 50), "the size control")
        larger.tap()
        sleep(2)
        closePanel()
        _ = settled("emma, larger")
    }

    // MARK: Density

    /// The iPad's default spread fills the page as Apple Books' does. Ari's own Apple Books spread
    /// (delight-build14 `aris-device/4-apple-books-spread.jpg`, measured by the reviewers): 18 lines,
    /// the first at 11.3% of the height, the last ending at 82.3%, line pitch ÷ text width 0.071.
    /// Gatefold measured 19, 12.4%, 84.6% and 0.072 when the reviewers called it right. A page can end
    /// early (a chapter opening, a paragraph kept whole), so the fullest of six pages is the one judged.
    func testTheDefaultSpreadIsAsFullAsAppleBooks() throws {
        guard pad else { throw XCTSkip("Apple Books' spread was recorded on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        app.launchArguments = base + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                      "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120))
        // His page, shown: words under the opening cover aren't reported (gatefold#374), so a tap never lands on the
        // cover, which answers with the controls instead of a turn. In reads, never a fixed 120 s.
        XCTAssertFalse(settled("the default spread").isEmpty, "the spread shows words")
        var pages: [Density.Measure] = []
        for spread in 0..<3 {
            if spread > 0 { XCTAssertTrue(turnForward(), "turned to spread \(spread + 1)"); _ = settle() }
            sleep(3)
            let shot = XCUIScreen.main.screenshot()
            let window = app.windows.firstMatch.frame
            for band in [(0.0, 0.5), (0.5, 1.0)] {
                guard let m = Density.measure(shot.image, landscape: window.width > window.height, from: band.0, to: band.1) else { continue }
                note(String(format: "density spread %d lines=%d first=%.1f%% last=%.1f%% pitch/textw=%.3f textw/pagew=%.2f",
                            spread + 1, m.lines, m.first * 100, m.last * 100, m.pitchPerWidth, m.widthPerPage))
                pages.append(m)
            }
        }
        guard let m = pages.max(by: { ($0.lines, $0.last) < ($1.lines, $1.last) }) else { return XCTFail("no lines found") }
        note(String(format: "density fullest lines=%d first=%.1f%% last=%.1f%% pitch/textw=%.3f", m.lines, m.first * 100, m.last * 100, m.pitchPerWidth))
        XCTAssertTrue((16...21).contains(m.lines), "lines on a full page: \(m.lines) (Apple Books 18)")
        XCTAssertEqual(m.first, 0.113, accuracy: 0.025, "where the first line starts (Apple Books 11.3%)")
        XCTAssertEqual(m.last, 0.823, accuracy: 0.035, "where the last line ends (Apple Books 82.3%)")
        XCTAssertEqual(m.pitchPerWidth, 0.071, accuracy: 0.008, "line pitch against text width (Apple Books 0.071)")
        XCTAssertEqual(m.widthPerPage, 0.80, accuracy: 0.05, "text width against page width (Apple Books 0.80)")
    }
}

/// The reviewers' line-density measure (`density.py`): dark rows in a column band, grouped into lines.
enum Density {
    struct Measure { let lines: Int; let first: Double; let last: Double; let pitchPerWidth: Double; let widthPerPage: Double }

    /// `landscape`: the screen's way up. XCUIScreen hands back the panel's pixels, which stay portrait
    /// on an iPad turned landscape-left; those are turned a quarter counter-clockwise to read as seen.
    static func measure(_ image: UIImage, landscape: Bool, from x0f: Double, to x1f: Double) -> Measure? {
        guard let raw = image.cgImage else { return nil }
        let turn = landscape && raw.width < raw.height
        let size = turn ? CGSize(width: raw.height, height: raw.width) : CGSize(width: raw.width, height: raw.height)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let upright = UIGraphicsImageRenderer(size: size, format: format).image { r in
            let c = r.cgContext
            if turn {
                // CoreGraphics draws bottom-up: flip, then turn so the panel's right edge becomes the top.
                c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                c.translateBy(x: size.width / 2, y: size.height / 2)
                c.rotate(by: .pi / 2)
                c.draw(raw, in: CGRect(x: -size.height / 2, y: -size.width / 2, width: size.height, height: size.width))
            } else {
                c.translateBy(x: 0, y: size.height); c.scaleBy(x: 1, y: -1)
                c.draw(raw, in: CGRect(origin: .zero, size: size))
            }
        }
        guard let cg = upright.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        let x0 = Int(Double(w) * x0f), x1 = Int(Double(w) * x1f)
        func dark(_ x: Int, _ y: Int) -> Bool { px[y * w + x] < 110 }
        let rows = (0..<h).map { y in stride(from: x0, to: x1, by: 2).reduce(0) { $0 + (dark($1, y) ? 1 : 0) } }
        let threshold = max(3, Int(Double(x1 - x0) / 2 * 0.01))
        var runs: [(Int, Int)] = []
        var y = 0
        while y < h {
            if rows[y] > threshold {
                let s = y
                while y < h, rows[y] > threshold { y += 1 }
                if y - s >= max(4, h / 400) { runs.append((s, y)) }
            }
            y += 1
        }
        let body = runs.filter { Double($0.0) > Double(h) * 0.06 && Double($0.0) < Double(h) * 0.94 }
        // A quotation mark or a dash on its own row is a sliver, not a line.
        let heights = body.map { $0.1 - $0.0 }.sorted()
        guard !heights.isEmpty else { return nil }
        let typical = heights[heights.count / 2]
        let lines = body.filter { $0.1 - $0.0 >= typical / 2 }
        guard lines.count > 1 else { return nil }
        let inkColumns = (x0..<x1).filter { x in stride(from: Int(Double(h) * 0.15), to: Int(Double(h) * 0.85), by: 3).contains { dark(x, $0) } }
        guard let lo = inkColumns.min(), let hi = inkColumns.max(), hi > lo else { return nil }
        let textWidth = Double(hi - lo)
        let gaps = zip(lines.dropFirst(), lines).map { Double($0.0 - $1.0) }.sorted()
        let pitch = gaps[gaps.count / 2]
        return Measure(lines: lines.count, first: Double(lines.first!.0) / Double(h), last: Double(lines.last!.1) / Double(h),
                       pitchPerWidth: pitch / textWidth, widthPerPage: textWidth / Double(x1 - x0))
    }
}
