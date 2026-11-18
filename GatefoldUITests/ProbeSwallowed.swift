import XCTest

/// Every tap on the page gets an answer: a turn at its edge, the controls in its middle. Build 25's spazz runs
/// swiped a freshly opened book a few pages on and back, and then no tap on the page did anything at all, with no
/// tap in the reader's log, until a rotation laid the page out again (gatefold#321). The folded Duo's taps died the
/// same way after a jump. Judged in answered taps and reads, never in seconds.
extension FineTuneTapUITests {

    func probeSwallowed() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldAllowReopen", "YES", "-GatefoldDownloadAll", "YES",
            // The round with the Cloud's offer up needs it up: unanswered, it folds 10 s after the page shows, and on
            // CI's iPad this test's first look for it came 15 and 17 s after (d502a1f, a8061a1). A swipe still folds it.
            "-GatefoldOfferFoldSeconds", "600", "-GatefoldProbeSlowBeneath", "65",
        ]
        app.launch()
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
        // As the spazz run: opened from the shelf, its page warmed behind it.
        let cover = el("book.gutenberg-pride-and-prejudice")
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the shelf shows the book") { cover.exists }.ok, "the shelf shows the book")
        for _ in 0..<8 where !cover.isHittable { el("library.grid").swipeUp() }
        cover.tap()
        let page = el("reader.page")
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the reader opens") { page.exists }.ok, "the reader opens")
        // Opened at its start, the book has no words to anchor yet (`reader.anchorCheck` stays pending): its page is ready.
        let probe = el("reader.pageReady")
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the page is ready") { (probe.value as? String) == "1" }.ok, "the page is ready")
        let close = app.buttons["reader.close"].firstMatch
        func screen(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        let report = el("reader.turnPlacement")
        func landed() -> Int {
            let words = report.label.split(separator: " ")
            return words.first == "landed" && words.count > 1 ? Int(words[1]) ?? 0 : 0
        }
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { screen(x, y) }
        // The app's own report that a turn is under way (`reader.turning`), from its start until it lands.
        let turning = el("reader.turning")
        func isTurning() -> Bool { (turning.value as? String) == "1" }
        /// A swipe's turn, waited for as the app reports it: heard (under way or landed) within the reads, then
        /// followed to its end while its page beneath loads. Swipe 1 leaves the cover for chapter 1,
        /// whose file loads first: on CI's iPad that took 938 looks, about 58 s, past a 300-read wait (gatefold#492).
        /// The app bounds that load itself (`ReaderHostController.loadingLooks`), and `turnReads` follows its bound.
        func swipeLands(after before: Int) -> (ok: Bool, reads: Int, ended: Bool) {
            let heard = swReadsUntil(reads: Self.swReads, "a swipe's turn starts") { landed() > before || isTurning() }
            guard heard.ok else { return (false, heard.reads, true) }
            // A turn whose finger was never heard lifting (#321) stays under way: it fails here, in the app's own bound.
            let ended = swReadsUntil(reads: Self.swTurnReads, "the swipe's turn ends") { !isTurning() }
            guard ended.ok else { return (false, heard.reads + ended.reads, false) }
            // The landing is reported once the turn has ended and the page is snapshotted, within the reads a swipe always had.
            let landedNow = swReadsUntil(reads: Self.swReads, "the swipe's turn lands") { landed() > before }
            return (landedNow.ok, heard.reads + ended.reads + landedNow.reads, true)
        }

        let slip = el("banner"), tab = el("banner.tab")
        var answered = 0, asked = 0
        func round(_ name: String, edge: Bool = true) {
            print("SWALLOWED \(name): Cloud slip \(slip.exists ? "up" : "down"), tab \(tab.exists ? "up" : "down")")
            // Taps on the middle of the page: each must bring the controls up, and a second tap take them down.
            let taps: [(CGFloat, CGFloat)] = [(0.5, 0.5), (0.3, 0.5), (0.7, 0.5), (0.5, 0.25), (0.5, 0.75)]
            for (i, (x, y)) in taps.enumerated() {
                asked += 1
                at(x, y).tap()
                let up = swReadsUntil(reads: Self.swAnswerReads, "\(name): tap \(i + 1) brings the controls") { close.exists }
                print("SWALLOWED \(name): tap \(i + 1) at \(x),\(y): controls=\(up.ok) after \(up.reads) reads")
                guard up.ok else { continue }
                answered += 1
                at(0.5, 0.5).tap()
                XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the controls go") { !close.exists }.ok, "\(name): the controls go after tap \(i + 1)")
            }
            // An edge tap turns: on the page's own edge (the portrait iPad's page is narrower than the window).
            guard edge else { return }
            asked += 1
            let before = landed()
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
            let turned = swReadsUntil(reads: Self.swAnswerReads, "\(name): the edge tap turns") { landed() > before || close.exists }
            if landed() > before { answered += 1 }
            if close.exists { at(0.5, 0.5).tap(); _ = swReadsUntil(reads: Self.swReads, "the controls go") { !close.exists } }
            print("SWALLOWED \(name): edge tap turned=\(landed() > before) after \(turned.reads) reads")
        }
        // The Cloud's offer slides out over the cover a few seconds after it opens: taps with it up (#304's third
        // bullet). Middle taps only, so the swipes below still leave the cover.
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the Cloud's offer is up") { slip.exists }.ok, "the Cloud's offer is up")
        round("with the Cloud slip up", edge: false)

        // The spazz run's look round Your Page: the controls, Your Page, Fine-Tune, and a tap above the panel to put it away.
        screen(0.5, 0.5).tap()
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the controls come up") { close.exists }.ok, "the controls come up")
        let appearance = app.buttons["reader.appearance"].firstMatch
        if appearance.exists {
            appearance.tap()
            let panel = el("appearance.panel")
            _ = swReadsUntil(reads: Self.swReads, "Your Page opens") { panel.exists }
            let fine = app.buttons["appearance.customize"].exists ? app.buttons["appearance.customize"] : app.buttons["Fine-Tune"].firstMatch
            if fine.exists { fine.tap() }
            screen(0.5, 0.1).tap()
            let gone = swReadsUntil(reads: Self.swReads, "Your Page goes") { !panel.exists }
            print("SWALLOWED panel gone after a tap above it: \(gone.ok) after \(gone.reads) reads")
        }
        if close.exists { screen(0.5, 0.5).tap(); _ = swReadsUntil(reads: Self.swReads, "the controls go") { !close.exists } }

        // The spazz run's first round: four quick swipes on, one back, each waited for in counted turns.
        for (i, forward) in [true, true, true, true, false].enumerated() {
            let before = landed()
            if forward { at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: at(0.25, 0.5)) } else { at(0.25, 0.5).press(forDuration: 0.05, thenDragTo: at(0.75, 0.5)) }
            let turned = swipeLands(after: before)
            print("SWALLOWED swipe \(i + 1) turned=\(turned.ok) after \(turned.reads) reads (landed \(landed()))")
            // The first swipe leaves the cover for the first chapter: that is the swipe whose finger was never heard lifting.
            if i == 0 { XCTAssertTrue(turned.ok, "swipe 1 turns into the first chapter") }
            // A turn still under way past the app's own bound is #321's: the later swipes would only wait it out again.
            guard turned.ended else { XCTFail("swipe \(i + 1)'s turn ends"); break }
        }
        round("after the swipes")

        // A jump: Contents, a chapter further on, and taps once its veil is gone (the Duo's round after jump 7).
        at(0.5, 0.5).tap()
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the controls come up for Contents") { close.exists }.ok, "the controls come up for Contents")
        app.buttons["reader.contents"].firstMatch.tap()
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'contents.entry.'"))
        XCTAssertTrue(swReadsUntil(reads: Self.swReads, "the contents list is up") { rows.firstMatch.exists }.ok, "the contents list is up")
        let shown = el("reader.shownPlace")
        let placeBefore = shown.value as? String
        let row = ContentsRow.tap(app.buttons["contents.entry.11"], in: app)
        XCTAssertTrue(row.ok, "contents entry 11 came into view (not in \(row.drags) drags)")
        let veil = el("reader.veil")
        let landedJump = swReadsUntil(reads: Self.swReads, "the jump lands") {
            // The place shown has moved (the veil may not be up yet when the list goes), and the veil is gone.
            !rows.firstMatch.exists && (shown.value as? String) != placeBefore && !veil.exists && (probe.value as? String) == "1"
        }
        print("SWALLOWED jump landed=\(landedJump.ok) after \(landedJump.reads) reads")
        XCTAssertTrue(landedJump.ok, "the jump lands")
        if close.exists { at(0.5, 0.5).tap(); _ = swReadsUntil(reads: Self.swReads, "the controls go") { !close.exists } }
        round("after a jump")

        print("SWALLOWED answered \(answered) of \(asked) taps")
        XCTAssertEqual(answered, asked, "every tap after the swipes and after the jump is answered")
    }

    /// The reads a wait may take. Each read waits at least 0.1 s.
    static let swReads = 300
    /// The reads a turn under way may take: the app's own bound on its wait for the page beneath, 1200 looks of at
    /// least 50 ms (`ReaderHostController.loadingLooks`). It holds while a look takes no more than half as long as a
    /// read: on CI's iPad a look took about 62 ms (938 in 58 s, gatefold#492) and a read about 0.18 s, so 600 reads are
    /// about 108 s against the app's 75 s.
    static let swTurnReads = 600
    /// The reads a tap's answer may take: a tap the page heard answers within a few reads (#304's probes: 1 to 3).
    static let swAnswerReads = 50

    /// As SpreadTurnSettleUITests: the hang guard (`HangGuard`) ends only a hang, and fails naming the wait.
    func swReadsUntil(reads: Int, _ what: String, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds {
                XCTFail("hang: \(what): \(read) of its \(reads) reads ran past the hang guard")
                return (false, read)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    func testAQuickTouchChangesEverySwitchOnce() throws { try probeSwallowed() }
    func testATapOnTheRowsNameChangesItsSwitch() throws { try probeSwallowed() }
}
