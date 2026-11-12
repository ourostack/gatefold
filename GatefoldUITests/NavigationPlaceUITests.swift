import XCTest
import UIKit

/// Every way of moving that isn't a page turn keeps the place: he jumps, leaves without turning, and
/// the book reopens where he jumped to. Build 17 lost a move reported while the iPad's first layout
/// was still settling (it reopened at the start, then landed on the Cloud's older place).
@MainActor
final class NavigationPlaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // The iPad on its side lays out a spread after a portrait first layout: the reflow that held the move.
        if UIDevice.current.userInterfaceIdiom == .pad { XCUIDevice.shared.orientation = .landscapeLeft }
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private func waitForWords(changingFrom old: String? = nil, timeout: TimeInterval = 60) -> String {
        let up = Date().addingTimeInterval(timeout)
        while Date() < up {
            let now = visibleText
            if !now.isEmpty, now != old { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return visibleText
    }

    /// The words that open the page: a spread's right page can still be drawing when it is read.
    private func opening(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).prefix(12).joined(separator: " ")
    }

    private func openFresh(_ extra: [String] = []) -> String {
        app.launchArguments = common + extra + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        return waitForWords()
    }

    private func showChrome() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.contents"].waitForExistence(timeout: 5))
    }

    /// Leaves without a turn and comes back: the reopen shows `words`.
    private func leaveAndReturn(expecting words: String, _ how: String) {
        sleep(2)
        let settled = visibleText
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(3)
        app.quit()
        app.launchArguments = common
        app.relaunch()
        _ = waitForWords()
        sleep(4)
        XCTAssertEqual(opening(visibleText), opening(settled), "after a \(how) and no turn, the reopen is on the page he jumped to")
        XCTAssertNotEqual(opening(settled), opening(words), "the \(how) moved the page")
    }

    func testAContentsJumpKeepsThePlace() {
        let first = openFresh()
        showChrome()
        app.buttons["reader.contents"].tap()
        // The list is lazy: chapter XXX is only built once it scrolls into view.
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10),
                      "the contents opened")
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list chapter XXX")
        _ = waitForWords(changingFrom: first, timeout: 20)
        XCTAssertTrue(keptWhatIsShown(), "the jump kept a place other than the page shown")
        leaveAndReturn(expecting: first, "contents jump")
    }

    /// A Contents jump whose chapter is still loading keeps the old page veiled until it has loaded, and
    /// the veil lifts onto words, never onto a blank page and Readium's spinner (#38). The load is held
    /// open for a set number of looks (`-GatefoldHoldChapterLoad`), as a slow device does: the old veil
    /// gave up after 160 looks (8 s) and lifted while the chapter still loaded.
    func testAJumpsVeilHoldsWhileTheChapterLoads() {
        let first = openFresh(["-GatefoldHoldChapterLoad", "400"])
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10),
                      "the contents opened")
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list chapter XXX")
        let held = app.descendants(matching: .any)["reader.loadingHeld"]
        let veil = app.descendants(matching: .any)["reader.veil"]
        XCTAssertTrue(held.waitForExistence(timeout: 10), "the chapter's load is held open")
        // Sampled until the held load ends: every sample while it is held must find the veil up.
        var samples = 0, bare = 0
        let up = Date().addingTimeInterval(120)
        while held.exists, Date() < up {
            samples += 1
            if !veil.exists, held.exists { bare += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("VEIL samples=\(samples) bareWhileLoading=\(bare) heldAtEnd=\(held.exists)")
        XCTAssertEqual(bare, 0, "the veil stayed up while the chapter loaded")
        XCTAssertFalse(held.exists, "the held load ended (the veil kept looking)")
        XCTAssertTrue(veil.waitForNonExistence(timeout: 15), "the veil lifted once the chapter had loaded")
        let words = waitForWords(changingFrom: first, timeout: 15)
        XCTAssertFalse(words.isEmpty, "the veil lifted onto words")
        XCTAssertNotEqual(opening(words), opening(first), "the jump moved the page")
        XCTAssertTrue(keptWhatIsShown(), "the jump kept a place other than the page shown")
    }

    /// A Contents jump made while the page he leaves is still loading starts at once: the old page is
    /// pictured as it is, never waited on (the wait held the jump back about 60 s on CI's iPad, and the
    /// page never moved: gatefold#73). What the held load (1200 looks, about a minute) could hold back is
    /// the jump's start, so that is what is judged: the old page gets the one look a page still loading
    /// gets (`OldPagePicture.tries`), counted by the app in looks, and the veil is up within 10 probe
    /// reads of where the same jump from a loaded page has it, on the same runner. Both jumps then move
    /// the page and put up Back within `jumpReadCeiling` reads.
    ///
    /// The far chapter's load after the start is the same code for both and is not compared: on CI's
    /// iPad, at a load average near 400, it took 5.8 to 26.8 s run to run, with or without the hold,
    /// either one the slower (#73: loaded 22 and still loading 11 reads at e8d5ae1, 14 and 33 at
    /// d2534bd; run 43188075650, held first and last: held 10, loaded 27, loaded 26, held 11). In every
    /// one of those runs the jump pictured its old page in one look, under 0.7 s.
    func testAJumpFromAPageStillLoadingStartsAtOnce() {
        let plain = contentsJumpReads([])
        let held = contentsJumpReads(["-GatefoldHoldOldPageLoad", "1200"])
        print("OLDPAGEHELD reads to start: loaded \(plain.start), still loading \(held.start); old page looks: loaded \(plain.looks.map(String.init) ?? "none"), still loading \(held.looks.map(String.init) ?? "none"); to move: loaded \(plain.move), still loading \(held.move); to Back: loaded \(plain.back), still loading \(held.back)")
        // At once, everywhere: neither jump may take more than `jumpReadCeiling` reads, whatever the
        // runner. Baselines on CI's iPad: loaded 9 and 81, still loading 12 (runs 42484222632 and
        // 42490481581); the 81 was a 37 s jump, which is not at once.
        XCTAssertLessThanOrEqual(plain.move, Self.jumpReadCeiling, "the jump from a loaded page moved the page only after \(plain.move) reads")
        XCTAssertLessThanOrEqual(held.move, Self.jumpReadCeiling, "the jump from a page still loading moved the page only after \(held.move) reads")
        XCTAssertLessThanOrEqual(plain.back, Self.jumpReadCeiling, "the jump from a loaded page put up Back only after \(plain.back) reads")
        XCTAssertLessThanOrEqual(held.back, Self.jumpReadCeiling, "the jump from a page still loading put up Back only after \(held.back) reads")
        // The start. Both jumps ran under a veil, and the app kept the looks its old page took.
        XCTAssertNotNil(plain.looks, "the jump from a loaded page ran under a veil")
        XCTAssertNotNil(held.looks, "the jump from a page still loading ran under a veil")
        // One look for a page still loading (gatefold#155 took ten; waiting on it would take the 1200).
        XCTAssertEqual(held.looks, 1, "the jump from a page still loading looked at its old page \(held.looks ?? -1) times before it began")
        XCTAssertLessThanOrEqual(plain.looks ?? .max, 10, "the jump from a loaded page looked at its old page \(plain.looks ?? -1) times before it began")
        XCTAssertLessThanOrEqual(held.start, plain.start + 10, "a jump from a page still loading started only after \(held.start) reads (\(plain.start) from a loaded one)")
    }

    private static let jumpReadLimit = 400
    /// About 30 s of probe reads on CI's iPad (about 0.5 s a read there).
    private static let jumpReadCeiling = 60

    /// Opens fresh, jumps to chapter XXX through Contents, and counts probe reads from the tap until
    /// the jump starts (its veil is up), until the words change, and until Back is up (the limit when
    /// they never do); with the looks the app says the jump's old page took (nil when it ran unveiled).
    private func contentsJumpReads(_ extra: [String]) -> (start: Int, looks: Int?, move: Int, back: Int) {
        let first = openFresh(extra)
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10),
                      "the contents opened")
        let marker = app.descendants(matching: .any)["reader.jumpStartLooks"]
        XCTAssertFalse(marker.exists, "no veiled jump ran before the Contents jump")
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list chapter XXX")
        // All counted from the tap: the reads until the veil is up, until the words change, and until
        // Back is up. A jump that moved the page with no veil seen started no later than it moved.
        let veil = app.descendants(matching: .any)["reader.veil"]
        var reads = 0, start: Int?, move: Int?, back: Int?
        while reads < Self.jumpReadLimit, move == nil || back == nil {
            reads += 1
            if start == nil, veil.exists { start = reads }
            let now = visibleText
            if move == nil, !now.isEmpty, opening(now) != opening(first) { move = reads; start = start ?? reads }
            if back == nil, app.buttons["reader.back"].exists { back = reads }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let looks = marker.exists ? (marker.value as? String).flatMap { Int($0) } : nil
        XCTAssertTrue(keptWhatIsShown(), "the jump kept a place other than the page shown")
        if extra.contains("-GatefoldHoldOldPageLoad") {
            XCTAssertTrue(app.descendants(matching: .any)["reader.oldPageHeld"].exists, "the old page's held load armed")
        }
        app.quit()
        return (start ?? reads, looks, move ?? reads, back ?? reads)
    }

    /// While the first page is still loading behind the opening cover, a tap still brings up the
    /// controls and Close still closes the book (#104): the cover took every tap, Close among them, for
    /// over a minute while a load hung (#94). The load is held open (`-GatefoldHoldOpeningLoad`), and
    /// each answer is judged in reads, never seconds.
    func testTheOpeningCoverLetsTheControlsThrough() {
        app.launchArguments = common + ["-GatefoldHoldOpeningLoad", "2400", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice"]
        app.launch()
        let held = app.descendants(matching: .any)["reader.loadingHeld"]
        let cover = app.descendants(matching: .any)["reader.opening"]
        let ready = app.descendants(matching: .any)["reader.pageReady"]
        XCTAssertTrue(held.waitForExistence(timeout: 60), "the first page's load is held open")
        XCTAssertTrue(cover.waitForExistence(timeout: 10), "the opening cover is up")

        // A tap in the middle of the cover: the controls come up within a few reads.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = app.buttons["reader.close"].firstMatch
        var reads = 0, up = false
        while reads < 15 {
            reads += 1
            if close.exists, close.isHittable { up = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        let stillLoading = held.exists && (ready.value as? String) == "0"
        print("PLACEHOLDER controls up=\(up) after \(reads) reads; still loading=\(stillLoading)")
        XCTAssertTrue(stillLoading, "the page was still loading when the controls were judged")
        XCTAssertTrue(up, "a tap on the opening cover brings up the controls")
        guard up else { return }

        // Close still closes the book while it loads.
        close.tap()
        let shelf = app.descendants(matching: .any)["library.grid"]
        reads = 0
        while reads < 25, !shelf.exists {
            reads += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        print("PLACEHOLDER shelf=\(shelf.exists) after \(reads) reads")
        XCTAssertTrue(shelf.exists, "Close on the opening cover goes back to the shelf")
    }

    /// The Cloud's offer, shown while the first page is still loading behind the opening cover, takes
    /// his tap: Catch up was drawn beneath the cover, which took the tap as a call for the controls, so
    /// the offer was never taken and the book stayed on its wordless cover (#46 at c8d3084, CI's iPad:
    /// ReopenAfterControls round 1, no words for 120 s after Catch up). Judged in reads, never seconds.
    func testTheCloudsOfferOverTheOpeningCoverTakesHisTap() {
        // The first page loads until Catch up is taken, however slow the runner (gatefold#277: 2400 looks ran out first).
        app.launchArguments = common + ["-GatefoldHoldOpeningLoadUntilCatchUp", "YES", "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
                                        // This host's queries take seconds; the offer mustn't fold between seeing it and the tap.
                                        "-GatefoldOfferFoldSeconds", "600"]
        app.launch()
        let held = app.descendants(matching: .any)["reader.loadingHeld"]
        let cover = app.descendants(matching: .any)["reader.opening"]
        let ready = app.descendants(matching: .any)["reader.pageReady"]
        let offer = app.buttons["banner.jump"], tab = app.descendants(matching: .any)["banner.tab"]
        // If it is folded into its tab anyway, the tab opens it again.
        let up = Date().addingTimeInterval(90)
        while !offer.exists, Date() < up {
            if tab.exists { tab.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertTrue(offer.exists, "the Cloud's place is offered while the first page loads")
        guard offer.exists else { return }
        let coverUp = cover.exists
        // Read as the tap is made, as the cover is: taking it lets the held load go on.
        let stillLoading = held.exists && (ready.value as? String) == "0"
        offer.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Taken: the offer and its tab are gone at once. Missed: the offer stays, or folds into its tab.
        var reads = 0, taken = false
        while reads < 10 {
            reads += 1
            if !offer.exists, !tab.exists { taken = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        print("PLACEHOLDER offer taken=\(taken) after \(reads) reads; cover up=\(coverUp); still loading=\(stillLoading)")
        XCTAssertTrue(coverUp, "the opening cover was up when Catch up was tapped")
        XCTAssertTrue(stillLoading, "the page was still loading when Catch up was tapped")
        XCTAssertTrue(taken, "Catch up over the opening cover takes the tap")
        // And it lands: once the page shows, it is on words (the round that missed showed none for 120 s).
        XCTAssertFalse(waitForWords(timeout: 180).isEmpty, "the page never showed words after Catch up")
    }

    func testAScrubberJumpKeepsThePlace() {
        let first = openFresh()
        showChrome()
        let scrubber = app.descendants(matching: .any)["reader.scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        // A deliberate drag along the bar: a tap on it never jumps (PlaceUndoUITests).
        let from = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)))
        _ = waitForWords(changingFrom: first, timeout: 20)
        leaveAndReturn(expecting: first, "scrubber jump")
    }

    /// The same jump left while its chapter still loads (`-GatefoldHoldJumpSends`: the jump never reaches
    /// the page, so Readium never reports it, as on a slow runner's iPad): nothing was written, and the
    /// reopen came back at the book's start (gatefold#279). The reopen is on the jump's page, never the
    /// opening one.
    func testAScrubberJumpLeftWhileItsChapterLoadsKeepsItsTarget() {
        let first = openFresh(["-GatefoldHoldJumpSends", "YES"])
        showChrome()
        let scrubber = app.descendants(matching: .any)["reader.scrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 5))
        let from = scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5))
        from.press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)))
        let held = app.descendants(matching: .any)["reader.loadingHeld"]
        XCTAssertTrue(held.waitForExistence(timeout: 10), "the jump is held, never sent")
        // He leaves while it is still held: no turn, no wait for the page.
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(3)
        app.quit()
        app.launchArguments = common
        app.relaunch()
        let back = waitForWords()
        sleep(4)
        XCTAssertFalse(back.isEmpty, "the reopen shows words")
        XCTAssertNotEqual(opening(visibleText), opening(first), "after a scrubber jump left while its chapter loaded, the reopen is on the jump's page, not the opening one")
    }

    private func turn(forward: Bool) {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: forward ? 0.97 : 0.03, dy: 0.5)).tap()
    }

    private func leaveAndRelaunch() {
        XCUIDevice.shared.press(.home)
        if !app.wait(for: .runningBackground, timeout: 3) {
            XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        }
        sleep(3)
        app.quit()
        app.launchArguments = common + relaunchExtra
        app.relaunch()
    }

    private var relaunchExtra: [String] = []

    /// The review's path on the iPad spread: his place is saved (a turn there and back), he closes the
    /// book, opens it from the shelf, and leaves twice without turning. Build 17 reopened chapter X,
    /// then XI, from chapter XIX.
    func testOpenedFromTheShelfThenLeftTwiceWithoutATurnKeepsThePlace() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        let first = waitForWords()
        sleep(3)
        turn(forward: true)
        _ = waitForWords(changingFrom: first, timeout: 10)
        sleep(2)
        turn(forward: false)
        sleep(3)
        let saved = opening(visibleText)
        XCTAssertFalse(saved.isEmpty)

        showChrome()
        app.buttons["reader.close"].firstMatch.tap()
        let cover = app.descendants(matching: .any)["book.gutenberg-pride-and-prejudice"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 15), "back on the shelf")
        sleep(2)
        app.quit()
        app.launchArguments = common
        app.relaunch()
        XCTAssertTrue(cover.waitForExistence(timeout: 30), "the shelf after a relaunch")
        cover.tap()
        _ = waitForWords()
        sleep(4)
        XCTAssertEqual(opening(visibleText), saved, "opened from the shelf on his saved page")

        for round in 1...2 {
            leaveAndRelaunch()
            _ = waitForWords()
            sleep(5)
            XCTAssertEqual(opening(visibleText), saved, "reopen \(round) after leaving without a turn is on his page")
        }
    }

    private func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }

    /// The review's rotation path: a Contents jump, two pages read in portrait, a turn to landscape and
    /// out without a turn. Build 17 reopened a page early each time (his first line on the right-hand
    /// page, the saved place rewritten to the spread's left edge). A layout change never moves the place:
    /// every reopen shows his first words, however many times he leaves.
    func testReadInPortraitRotatedThenLeftKeepsHisFirstWords() throws {
        try rotateThenLeave(furniture: false)
    }

    /// The same with page numbers on, as he reads: the count runs while he reads and rotates.
    func testWithPageNumbersOnReadInPortraitRotatedThenLeftKeepsHisFirstWords() throws {
        try rotateThenLeave(furniture: true)
    }

    private func rotateThenLeave(furniture: Bool) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a spread on rotation is an iPad path")
        XCUIDevice.shared.orientation = .portrait
        relaunchExtra = furniture ? ["-GatefoldPageFurniture", "YES"] : []
        let first = openFresh(relaunchExtra)
        showChrome()
        app.buttons["reader.contents"].tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter I")).firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(ContentsRow.tap(row, in: app).ok, "the contents list chapter XXX")
        var words = waitForWords(changingFrom: first, timeout: 20)
        XCTAssertTrue(keptWhatIsShown(), "the jump kept a place other than the page shown")
        sleep(3)
        for _ in 0..<2 {
            turn(forward: true)
            words = waitForWords(changingFrom: words, timeout: 10)
            sleep(2)
        }
        let his = opening(visibleText)
        XCTAssertFalse(his.isEmpty)

        XCUIDevice.shared.orientation = .landscapeLeft
        // He stays a while on the new spread: long enough for the page count to finish behind it.
        sleep(45)
        XCTAssertTrue(flat(visibleText).contains(his), "the spread shows his first words")
        let spread = opening(visibleText)
        for round in 1...3 {
            leaveAndRelaunch()
            _ = waitForWords()
            sleep(6)
            XCTAssertTrue(flat(visibleText).contains(his), "reopen \(round) after a rotation and no turn shows his first words")
            XCTAssertEqual(opening(visibleText), spread, "reopen \(round) is the spread he left, not one a page early")
        }
    }

    /// Scroll mode: a scroll is his move even after the launch reflow, through all of a long scroll's
    /// reports, so a reopen shows where he scrolled to, not where the scroll began. Every wait is a
    /// count of reads of the page, never seconds (#171).
    func testScrolledAfterTheLaunchReflowThenLeftKeepsWhereHeScrolled() {
        var first = openFresh()
        // A fresh install offers the Cloud's place and never lands on it (#46): the book opens on its
        // cover, which has no words to scroll through. He takes the offer, as he would.
        if first.isEmpty { first = takeTheCloudsOffer() }
        XCTAssertFalse(first.isEmpty, "the page he scrolls from shows words")
        // The controls: a tap of the offer's that met the page as it folded may have brought them up already,
        // and then a tap would put them away (#171's probe 42969303572). Up to three taps, each looked for.
        let contents = app.buttons["reader.contents"]
        var taps = 0
        while !contents.waitForExistence(timeout: 5), taps < 3 {
            taps += 1
            app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertTrue(contents.exists, "a tap brings up the controls")
        let appearance = app.descendants(matching: .any)["reader.appearance"].firstMatch
        appearance.tap()
        let turnStyle = app.descendants(matching: .any)["appearance.pageTurn"].firstMatch
        XCTAssertTrue(turnStyle.waitForExistence(timeout: 5))
        turnStyle.tap()
        let scroll = app.buttons["Scroll"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "the page turn menu offers Scroll")
        scroll.tap()
        let close = app.buttons["appearance.close"].exists ? app.buttons["appearance.close"] : app.buttons["appearance.back"]
        if close.exists { close.tap() } else { app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap() }
        // The switch to Scroll reflows the book: he swipes once the page has held still (the old 4 s).
        let before = steadyWords()
        let page = app.descendants(matching: .any)["reader.page"]
        let savedBefore = savedWords
        for _ in 0..<6 { page.swipeUp(velocity: .fast) }
        let scrolled = steadyWords()
        XCTAssertNotEqual(opening(scrolled), opening(first), "the scroll moved the words")
        XCTAssertNotEqual(opening(scrolled), opening(before), "the scroll moved the words from where Scroll began")
        // He leaves once his scroll's place is written, not after a guessed number of seconds: the saved
        // words are words of the page he scrolled to. A gate, not a check: the reopen below judges.
        let lead = flat(opening(scrolled)).split(separator: " ").prefix(4).joined(separator: " ")
        var looks = 0
        while looks < 150 {
            let saved = flat(savedWords)
            if saved != flat(savedBefore), !saved.isEmpty, flat(scrolled).contains(saved.split(separator: " ").prefix(4).joined(separator: " ")) || saved.contains(lead) { break }
            looks += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        print("SCROLL his place written \(looks < 150) after \(looks) looks")
        leaveAndRelaunch()
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let ready = app.descendants(matching: .any)["reader.pageReady"]
        looks = 0
        while looks < 300, (ready.value as? String) != "1" {
            looks += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        print("SCROLL reopen page ready \(looks < 300) after \(looks) looks")
        let back = steadyWords()
        let words = opening(scrolled).split(separator: " ").prefix(6).joined(separator: " ")
        XCTAssertTrue(flat(back).contains(words), "reopened where he scrolled to")
    }

    private var savedWords: String { (app.descendants(matching: .any)["reader.savedWords"].value as? String) ?? "" }

    /// The page's words once the same non-empty words have been read `hold` times in a row. The bound
    /// is a count of reads, generous enough for a slow iPad's restarting reflow.
    private func steadyWords(hold: Int = 20, reads limit: Int = 600) -> String {
        var last = "", same = 0, reads = 0
        while reads < limit {
            reads += 1
            let now = visibleText
            if now == last { same += 1 } else { last = now; same = 1 }
            if !now.isEmpty, same >= hold { return now }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return visibleText
    }

    /// Takes the Cloud's offer on a fresh install's wordless cover, and returns the page's words.
    /// Unanswered, the offer folds into its tab, and it can fold between a look and the tap: this
    /// test's own lookup timed out on the tab (#171 at :392) and tapped an offer gone by the tap
    /// ("Failed to tap banner.jump"). So every look opens the tab if the offer has folded and taps the
    /// offer where it was just seen, until the page shows words (as `takeTheOffer` does since #178).
    /// The tap goes to the point, so an offer that folded in between makes no failed tap. Bounded by
    /// looks, not seconds.
    /// Where to tap `element`, read from its frame. Never `isHittable`: asked of an offer in the middle of
    /// folding, XCTest fails the test ("Activation point invalid", #171's probe 42966309493).
    private func tappable(_ element: XCUIElement) -> CGRect? {
        let f = element.frame
        return f.isEmpty || f.width < 1 || f.height < 1 || !app.frame.contains(CGPoint(x: f.midX, y: f.midY)) ? nil : f
    }

    private func takeTheCloudsOffer() -> String {
        let offer = app.descendants(matching: .any)["banner.jump"].firstMatch
        let tab = app.descendants(matching: .any)["banner.tab"].firstMatch
        let origin = app.coordinate(withNormalizedOffset: .zero)
        var looks = 0, offers = 0, tabs = 0, quiet = 0
        while looks < 400, visibleText.isEmpty {
            looks += 1
            // After a tap the page gets some looks to answer before another: a second tap on a page that has
            // just landed would turn it or bring up the controls.
            if quiet > 0 {
                quiet -= 1
            } else if offer.exists, let f = tappable(offer) {
                origin.withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
                offers += 1
                quiet = 10
            } else if tab.exists, let f = tappable(tab) {
                origin.withOffset(CGVector(dx: f.midX, dy: f.midY)).tap()
                tabs += 1
                quiet = 2
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        print("SCROLL offer taps \(offers), tab taps \(tabs), looks \(looks), words \(!visibleText.isEmpty)")
        XCTAssertGreaterThan(offers, 0, "a fresh install on the cover offers the Cloud's place")
        return waitForWords()
    }

    /// The place kept is the page Readium shows: same file, near the same place in it (gatefold#166: a
    /// Contents jump kept its file's first page while the page went on to the chapter 0.79 into it).
    /// Judged in reads; a mismatch that lasts all of them is a wrong place kept.
    private func keptWhatIsShown(reads: Int = 40) -> Bool {
        let saved = app.descendants(matching: .any)["reader.savedPlace"], shown = app.descendants(matching: .any)["reader.shownPlace"]
        func tag(_ e: XCUIElement) -> (String, Double)? {
            let parts = ((e.value as? String) ?? "").split(separator: "@")
            guard parts.count == 2, let p = Double(parts[1]) else { return nil }
            return (String(parts[0]), p)
        }
        for _ in 0..<reads {
            if let a = tag(saved), let b = tag(shown), a.0 == b.0, abs(a.1 - b.1) < 0.1 { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return false
    }
}
