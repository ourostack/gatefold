import XCTest

/// On a freshly opened landscape spread, a tap in a page's outer margin turns it, every time, and a tap on the
/// middle of a page shows the controls. Build 25's reviewers tapped the iPad spread at 7% and 93% of its width and
/// got the controls 9 times out of 9: the turn zone stopped 88 pt in, inside the 69 pt margin and 19 pt of text
/// (gatefold#304). Judged in counted turns (`reader.turnPlacement`'s `landed N`) and reads, never in seconds.
@MainActor
final class MarginTapUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    func testEveryMarginTapOnAFreshSpreadTurns() throws {
        // The Duo's spread needs a hinge the UI test can't move (real-unfold.yml); its 951 pt spread's zone is in
        // GatefoldCore's TapZonesTests.
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The landscape spread runs on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "curl",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(readsUntil(reads: Self.reads, "the reader opens") { page.exists }.ok, "the reader opens")
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        let ready = readsUntil(reads: Self.reads, "the reader is ready") { probe.exists && probe.label.hasPrefix("ready") }
        XCTAssertTrue(ready.ok, "the reader is ready within \(Self.reads) reads: \(probe.label)")
        let posture = app.descendants(matching: .any)["reader.posture"]
        XCTAssertEqual(posture.label, "spread", "the iPad on its side lays out a spread")

        let report = app.descendants(matching: .any)["reader.turnPlacement"]
        let close = app.buttons["reader.close"].firstMatch
        func landed() -> Int {
            let words = report.label.split(separator: " ")
            return words.first == "landed" && words.count > 1 ? Int(words[1]) ?? 0 : 0
        }
        func hideControls(_ what: String) {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(readsUntil(reads: Self.reads, "the controls go after \(what)") { !close.exists }.ok, "the controls go after \(what)")
        }

        // The reviewers' margin taps (7%, 93%, and the spazz runs' 3%, 90% and 97%), forward then back, from the
        // first tap after the page is ready.
        let taps: [CGFloat] = [0.93, 0.90, 0.97, 0.93, 0.07, 0.03, 0.07]
        var turned = 0
        for (i, x) in taps.enumerated() {
            let before = landed()
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            // A verdict either way: the turn lands, or the controls come up in its place.
            let verdict = readsUntil(reads: Self.reads, "margin tap \(i + 1) at \(x)") { landed() > before || close.exists }
            let didTurn = landed() == before + 1
            if didTurn { turned += 1 }
            print("MARGINTAP \(i + 1) at \(x): turned=\(didTurn) controls=\(close.exists) after \(verdict.reads) reads (\(report.label))")
            // No verdict at all: the tap never reached the page. Counted as a miss, and the rest would only wait as long.
            if !verdict.ok { break }
            if close.exists { hideControls("margin tap \(i + 1)") }
        }
        print("MARGINTAPS turned \(turned) of \(taps.count)")

        // The middle of either page still shows the controls, and turns nothing.
        for x in [0.5, 0.3, 0.7] as [CGFloat] {
            let before = landed()
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            let up = readsUntil(reads: Self.reads, "the controls come up at \(x)") { close.exists || landed() > before }
            print("MIDDLETAP at \(x): controls=\(close.exists) landed \(before)->\(landed()) after \(up.reads) reads")
            XCTAssertTrue(close.exists, "a tap at \(x) of the width shows the controls")
            XCTAssertEqual(landed(), before, "a tap at \(x) of the width turns nothing")
            hideControls("the tap at \(x)")
        }

        XCTAssertEqual(turned, taps.count, "every margin tap on a fresh spread turns: \(turned) of \(taps.count) did")
    }

    /// Build 46's spazz run on the 13-inch iPad (gatefold#536): a 20-pt sideways brush across the middle of the page
    /// turned it, where Apple Books ignores one.
    func testABrushNeverTurnsInPortrait() throws { try brush(.portrait, posture: "single") }
    func testABrushNeverTurnsOnItsSide() throws { try brush(.landscapeLeft, posture: "spread") }

    /// The same run's taps at 3% and 97% of the window's width did nothing at all in portrait. The window's width,
    /// not the page's: the portrait page is inset to a book's measure, and those taps land in the margin beside it.
    func testAnEdgeTapAlwaysTurnsInPortrait() throws { try edgeTaps(.portrait, posture: "single") }
    func testAnEdgeTapAlwaysTurnsOnItsSide() throws { try edgeTaps(.landscapeLeft, posture: "spread") }

    /// The reader's probes, on a freshly opened Alice at 12%.
    private struct Reader {
        let app: XCUIApplication
        func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }
        func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate { app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)) }
        var close: XCUIElement { app.buttons["reader.close"].firstMatch }
        func landed() -> Int {
            let words = el("reader.turnPlacement").label.split(separator: " ")
            return words.first == "landed" && words.count > 1 ? Int(words[1]) ?? 0 : 0
        }
        func place() -> String { (el("reader.shownPlace").value as? String) ?? "" }
        /// The place last written (`reader.savedPlace`), what a reopen shows, and its words (`reader.savedWords`):
        /// empty when it was written with none.
        func savedPlace() -> String { (el("reader.savedPlace").value as? String) ?? "" }
        func savedWords() -> String { (el("reader.savedWords").value as? String) ?? "" }
    }

    private func open(_ orientation: UIDeviceOrientation, posture expected: String) throws -> Reader {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The iPad's margins and spread run on the iPad") }
        XCUIDevice.shared.orientation = orientation
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "curl",
        ]
        app.launch()
        let reader = Reader(app: app)
        XCTAssertTrue(readsUntil(reads: Self.reads, "the reader opens") { reader.el("reader.page").exists }.ok, "the reader opens")
        let probe = reader.el("reader.anchorCheck")
        let ready = readsUntil(reads: Self.reads, "the reader is ready") { probe.exists && probe.label.hasPrefix("ready") }
        XCTAssertTrue(ready.ok, "the reader is ready within \(Self.reads) reads: \(probe.label)")
        XCTAssertEqual(reader.el("reader.posture").label, expected, "the iPad lays out its \(expected) page")
        // The opening cover answers a tap with the controls (#104) until it has gone: the margins are judged after.
        let cover = reader.el("reader.opening")
        XCTAssertTrue(readsUntil(reads: Self.reads, "the opening cover goes") { !cover.exists }.ok, "the opening cover goes")
        return reader
    }

    /// The spazz run's brush, both ways: pressed for 0.05 s, then dragged 20 pt across the middle of the window and
    /// let go still moving, at `brushSpeed`. Given more reads than a committed swipe takes to land, neither the turn
    /// count nor the place moves, and the page's opening words stay as they were.
    ///
    /// A place written with no words is judged against the page he sees. A brush lifts the leaf and lays it back
    /// (`finish(complete: false)`), and Readium then reports the page shown. A wordless place was not taken from that
    /// page: on a starved runner the launch jump to 0.12 runs out of reads, and its target is kept as the place
    /// (`ReaderModel.load`). The spread showed 0.125 of the chapter, the place said 0.16, and the brush's report
    /// wrote his first words in its stead, on the same page (run 44699693594, gatefold#536). That is the place
    /// catching up with his page, not a move: a written place must then name words on the page he saw.
    private func brush(_ orientation: UIDeviceOrientation, posture: String) throws {
        let r = try open(orientation, posture: posture)
        for dx in [-20, 20] as [CGFloat] {
            let shown = ReaderReads.settle(r.app, "the page before the \(dx)-pt brush") { print("BRUSH \($0)") }.words
            let before = (landed: r.landed(), place: r.place(), saved: r.savedPlace(), words: r.savedWords())
            r.at(0.5, 0.5).press(forDuration: 0.05, thenDragTo: r.at(0.5, 0.5).withOffset(CGVector(dx: dx, dy: 0)),
                                 withVelocity: Self.brushSpeed, thenHoldForDuration: 0)
            let moved = readsUntil(reads: Self.brushReads, "the \(dx)-pt brush") { r.landed() > before.landed || r.place() != before.place }
            _ = readsUntil(reads: Self.reads, "the page stands still after the \(dx)-pt brush") { (r.el("reader.turning").value as? String) == "0" }
            let after = ReaderReads.settle(r.app, "the page after the \(dx)-pt brush") { print("BRUSH \($0)") }.words
            print("BRUSH \(dx) pt: landed \(before.landed)->\(r.landed()) place \(before.place)->\(r.place()) words \(before.words.isEmpty ? "none" : "his")->\(r.savedWords().isEmpty ? "none" : "his") page same \(Self.opening(after) == Self.opening(shown)) after \(moved.reads) reads")
            XCTAssertEqual(r.landed(), before.landed, "a \(dx)-pt brush turns no page")
            XCTAssertEqual(Self.opening(after), Self.opening(shown), "a \(dx)-pt brush leaves the page he sees where it was")
            if before.words.isEmpty {
                // The catch-up's write comes after its words are read, which a starved runner can hold for seconds.
                let caught = readsUntil(reads: Self.brushReads, "a place for the page after the \(dx)-pt brush") { !r.savedWords().isEmpty }
                print("BRUSH \(dx) pt: wordless place \(before.saved)->\(r.savedPlace()), words written \(caught.ok) after \(caught.reads) reads")
                if r.savedPlace() != before.saved {
                    let words = Self.opening(r.savedWords())
                    XCTAssertFalse(words.isEmpty, "a \(dx)-pt brush wrote a place with no words over one with none")
                    XCTAssertTrue(Self.flat(shown).contains(words), "a \(dx)-pt brush moved the place off the page he saw")
                }
            } else {
                XCTAssertEqual(r.place(), before.place, "a \(dx)-pt brush leaves the place where it was")
            }
            XCTAssertFalse(r.close.exists, "a \(dx)-pt brush brings up no controls")
        }
        // A quick flick a little longer than a fingertip still turns, as does half the window (the spazz run's swipes).
        var before = r.landed()
        r.at(0.6, 0.5).press(forDuration: 0.05, thenDragTo: r.at(0.6, 0.5).withOffset(CGVector(dx: -60, dy: 0)),
                             withVelocity: Self.flickSpeed, thenHoldForDuration: 0)
        XCTAssertTrue(readsUntil(reads: Self.reads, "a quick 60-pt flick turns") { r.landed() > before }.ok, "a quick 60-pt flick turns the page")
        _ = readsUntil(reads: Self.reads, "the page stands still after the flick") { (r.el("reader.turning").value as? String) == "0" }
        before = r.landed()
        r.at(0.75, 0.5).press(forDuration: 0.05, thenDragTo: r.at(0.25, 0.5))
        XCTAssertTrue(readsUntil(reads: Self.reads, "a full swipe turns") { r.landed() > before }.ok, "a full swipe still turns the page")
    }

    private static func flat(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    /// The words that open a page or a place: enough to tell two pages apart.
    private static func opening(_ text: String) -> String { flat(text).split(separator: " ").prefix(12).joined(separator: " ") }

    /// The spazz run's edge taps, forward at 97% then back at 3% of the window, twice.
    private func edgeTaps(_ orientation: UIDeviceOrientation, posture: String) throws {
        let r = try open(orientation, posture: posture)
        var turned = 0
        let taps: [CGFloat] = [0.97, 0.03, 0.97, 0.03]
        for (i, x) in taps.enumerated() {
            let before = r.landed()
            r.at(x, 0.5).tap()
            let verdict = readsUntil(reads: Self.reads, "edge tap \(i + 1) at \(x)") { r.landed() > before || r.close.exists }
            let didTurn = r.landed() == before + 1
            if didTurn { turned += 1 }
            print("EDGETAP \(i + 1) at \(x): turned=\(didTurn) controls=\(r.close.exists) after \(verdict.reads) reads")
            // No verdict: the tap reached nothing (gatefold#536's margins). The rest would only wait as long.
            if !verdict.ok { break }
            if r.close.exists {
                r.at(0.5, 0.5).tap()
                XCTAssertTrue(readsUntil(reads: Self.reads, "the controls go after edge tap \(i + 1)") { !r.close.exists }.ok)
            }
        }
        XCTAssertEqual(turned, taps.count, "every tap at 3% or 97% of the window turns: \(turned) of \(taps.count) did")
    }

    /// A quick finger that the page always hears. XCUITest's own drag speed lifted at 170 to 460 pt/s, either side of
    /// the 250 pt/s that makes a swipe quick, so the old page turned on its brush in some runs and not others; at 450
    /// and 600 pt/s a 20-pt drag often began no swipe at all. At 300 pt/s with no hold, main's page turned on all four
    /// brushes of a calibration run (gatefold#536).
    private static let brushSpeed = XCUIGestureVelocity(300)

    /// The flick's speed: 600 pt/s, twice `brushSpeed`. At `brushSpeed` two of nine local runs of the 60-pt flick
    /// lifted under `PageSwipe.flickSpeed` (234 and 237 pt/s; another at 253), so they were slow 60-pt drags, which
    /// rightly turn nothing. The warning above about 450 and 600 pt/s is about 20-pt drags: at 600 the 60-pt flick began
    /// its swipe, lifted at 611 to 668 pt/s and turned in six of six local runs.
    private static let flickSpeed = XCUIGestureVelocity(600)

    /// The reads a brush gets to move the page: more than a committed swipe takes to land (the spazz run's moved
    /// within its step).
    private static let brushReads = 60

    /// The reads a wait may take. Each read waits at least 0.1 s, so a fast runner gets at least 30 s; a slow one
    /// gets as many reads, however long each takes.
    private static let reads = 300

    /// As SpreadTurnSettleUITests: the hang guard (`HangGuard`, sized from `reads`) ends only a hang, and fails naming
    /// the wait (`what`).
    private func readsUntil(reads: Int, _ what: String, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
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
}
