import CryptoKit
import OuroFeel
import OuroFeelCore
import UIKit
import XCTest

/// Ouro Feel (ourostack/ouro-ui-apple) over every screen and gesture a reader meets: welcome and sign-in, the shelf,
/// open and reopen, turns by tap, swipe and curl drag (and a drag let go), rotation and the Duo's postures, Contents
/// (a jump, its dismissal, a link and Back), Appearance and Fine-Tune, and "Counting pages…" across a trip to the
/// Home Screen. Each check is judged by counted events and reads, never by elapsed time (a hosted runner is slow).
///
/// Place is the reader's `reader.visibleText`, compared only as a SHA-256 prefix: no book text is printed or kept.
/// Reports go to the result bundle and, with `TEST_RUNNER_OURO_FEEL_REPORT_DIR`, to that folder (gatefold#37).
///
/// TODO(ouro-ui-apple 0.3.5): once v0.3.5 is tagged, link `OuroFeelRecorderInjectable` into this target only, merge
/// `OuroFeel.injectedRecorderEnvironment` into the launch environment, and film the turns and the Contents sheet frame
/// by frame with `feel.recordedFilm` (snaps, settles, double draws). Release never links the recorder.
@MainActor
final class FeelUITests: XCTestCase {
    private var app: XCUIApplication!
    private var feel: OuroFeel!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
    }

    // MARK: Launching

    private static let book = "gutenberg-pride-and-prejudice"
    private static let signedIn = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                                   "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES"]

    /// A fresh library (reset, every book downloaded), signed in to the fake cloud; `open` opens the book from launch.
    private func launch(open: Bool, _ extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = Self.signedIn + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"] + extra
            + (open ? ["-GatefoldOpenBook", Self.book] : [])
        app.launch()
        feel = OuroFeel(app)
        if open { waitForPage() }
    }

    /// The arguments a reopen or relaunch uses: no reset, so the place he left is the place that comes back.
    private func keepLibraryOnRelaunch() { app.launchArguments = Self.signedIn }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private func page(_ x: Double, _ y: Double) -> XCUICoordinate {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func waitForPage() {
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        _ = settled()
    }

    // MARK: Reading the page by events

    /// How many reads in a row must agree before the words count as settled. Counted reads, not seconds: each read
    /// waits on the app, so a slow machine reads less often and the rule still holds.
    private static let agreeingReads = 12
    /// Reads before a watch gives up and reports what it saw.
    private static let readBudget = 600

    /// The distinct readings of the page (as hashes) from now until `agreeingReads` reads in a row agree on words.
    /// An empty read (between chapters) is kept as "empty" so a blank flash shows in the sequence.
    private func watch() -> (hashes: [String], settled: Bool, reads: Int) {
        var seq: [String] = [], same = 0, reads = 0
        while reads < Self.readBudget {
            reads += 1
            let h = FeelPlace.fingerprint(words)
            if seq.last == h { same += 1 } else { seq.append(h); same = 1 }
            if h != FeelPlace.empty, same >= Self.agreeingReads { return (seq, true, reads) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (seq, false, reads)
    }

    /// The words once settled (or what is there when the read budget runs out).
    @discardableResult
    private func settled() -> String {
        _ = watch()
        return words
    }

    // TODO(ouro-ui-apple 0.3.6): when it is tagged, judge the `.stay` gestures with `feel.placeHeld(across:read:)`, the
    // `.moveOnce` turns and jumps with `feel.placeFights(_:read:)` (a late restore or a re-sent jump after his own move),
    // and the turns' films with `film.flickers(of:)`, keeping `judgeGesture` only for what those do not cover.

    /// What the reader is meant to do after a gesture: move once, or stay.
    private enum Expect { case moveOnce, stay }

    /// Runs `action` and judges what the words did, by counting changes: a turn moves them exactly once (A→B), a gesture
    /// that is not a turn leaves them alone. Two or more changes is the "spazz" (A→B→A, A→B→C); "empty" frames between
    /// two pages are not a change of their own.
    private func judgeGesture(_ name: String, _ expect: Expect, _ action: () -> Void) -> FeelResult {
        let before = FeelPlace.fingerprint(settled())
        action()
        let seen = watch()
        let pages = ([before] + seen.hashes).filter { $0 != FeelPlace.empty }
        var collapsed: [String] = []
        for h in pages where collapsed.last != h { collapsed.append(h) }
        let changes = collapsed.count - 1
        let after = collapsed.last ?? FeelPlace.empty
        var findings: [FeelFinding] = []
        if !seen.settled {
            findings.append(.couldNotCheck("\(name): the words had not settled after \(seen.reads) reads"))
        }
        switch expect {
        case .moveOnce:
            if changes == 0 {
                findings.append(FeelFinding(what: "\(name): the page did not move (\(before) stayed)"))
            } else if changes > 1 {
                findings.append(FeelFinding(what: "\(name): the words changed \(changes) times before settling (\(collapsed.joined(separator: " → ")))"))
            }
        case .stay:
            if changes > 0 {
                findings.append(FeelFinding(what: "\(name): the words changed though nothing should move them (\(collapsed.joined(separator: " → ")))"))
            }
        }
        let genre = expect == .stay ? FeelGenre.placeStability : FeelGenre.jumpAfterLanding
        return FeelResult.judged(check: genre.rawValue,
                                 passing: expect == .stay ? "\(name): the page stayed" : "\(name): the page moved once and held",
                                 failing: { _ in "\(name): \(expect == .stay ? "the page moved" : "the page did not move once and hold")" },
                                 measures: ["changes": Double(changes), "reads": Double(seen.reads)],
                                 findings: findings, environment: feel.environment)
    }

    /// Records `result` under `name` and fails the test if it failed.
    private func check(_ result: FeelResult, name: String, film: FeelFilm? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let kept = feel.record(result, name: name, film: film)
        if !kept.passed { XCTFail(kept.text, file: file, line: line) }
    }

    private func expectGesture(_ name: String, _ expect: Expect, _ action: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        feel.expect(judgeGesture(name, expect, action), file: file, line: line)
    }

    // MARK: Chrome

    private func showChrome() {
        let close = app.buttons["reader.close"]
        for _ in 0..<4 where !(close.exists && close.isHittable) {
            page(0.5, 0.5).tap()
            _ = close.waitForExistence(timeout: 3)
        }
    }

    private func hideChrome() {
        for _ in 0..<3 where app.buttons["reader.close"].exists && app.buttons["reader.close"].isHittable {
            page(0.5, 0.5).tap()
            _ = app.buttons["reader.close"].waitForNonExistence(timeout: 3)
        }
    }

    private func toShelf() {
        showChrome()
        app.buttons["reader.close"].tap()
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 30), "back on the shelf")
    }

    private func openFromShelf() {
        let cover = el("book.\(Self.book)")
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 60), "the shelf")
        for _ in 0..<8 where !(cover.exists && cover.isHittable) { el("library.grid").swipeUp() }
        cover.tap()
        waitForPage()
    }

    // MARK: Welcome and sign-in

    /// Welcome, email, store and password each sit inside the window and hold still once landed; each step's Back
    /// goes back a step; signing in to the fake cloud lands on the shelf, which holds still.
    func testWelcomeAndSignInLandStillWithAWayBack() {
        app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldNoLatency", "YES"]
        app.launch()
        feel = OuroFeel(app)
        let start = app.buttons["welcome.signIn"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "the welcome")
        check(feel.insideWindow(poses: [.current]), name: "welcome-inside-window")

        let email = app.textFields["signIn.email"]
        let toEmail = feel.film(["signIn.email", "signIn.continue"], for: 3) { start.tap() }
        check(toEmail.jumps(of: "signIn.continue"), name: "email-step-jumps", film: toEmail)
        XCTAssertTrue(email.waitForExistence(timeout: 15), "the email step")
        check(feel.insideWindow(poses: [.current]), name: "email-inside-window")

        email.tap()
        email.typeText("reader@example.com")
        app.buttons["signIn.continue"].tap()
        let store = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'signIn.store.'")).firstMatch
        if store.waitForExistence(timeout: 10) { store.tap() }
        let password = app.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout: 15), "the password step")
        check(feel.insideWindow(poses: [.current]), name: "password-inside-window")

        // The way back: Back leaves the password step, and the way forward comes back to it.
        let back = app.buttons["signIn.back"]
        let wentBack = back.waitForExistence(timeout: 5) && { back.tap(); return password.waitForNonExistence(timeout: 10) }()
        feel.expect(FeelResult(check: FeelGenre.wayBack.rawValue, passed: wentBack,
                               summary: wentBack ? "Back left the password step" : "Back did not leave the password step",
                               findings: wentBack ? [] : [FeelFinding(what: "the password step's Back did not go back a step")],
                               environment: feel.environment))
        if store.waitForExistence(timeout: 5) { store.tap() } else if email.exists { app.buttons["signIn.continue"].tap() }
        if store.waitForExistence(timeout: 5) { store.tap() }
        XCTAssertTrue(password.waitForExistence(timeout: 15), "the password step again")

        // Any password but "wrong" signs in to the fake cloud. It is a fixture, never a credential.
        password.tap()
        password.typeText("feel-fixture")
        let toShelf = feel.film(["library.grid"], for: 4) { self.app.buttons["signIn.continue"].tap() }
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 60), "signed in, on the shelf")
        check(toShelf.jumps(of: "library.grid"), name: "shelf-jumps", film: toShelf)
        check(feel.insideWindow(poses: [.current]), name: "shelf-inside-window")
    }

    // MARK: The shelf, open and reopen

    /// Opening from the shelf lands still, and the place survives the Home Screen, a reopen from the shelf and a
    /// relaunch. The way back from the reader to the shelf is Close Book.
    func testOpenAndReopenKeepThePlace() {
        launch(open: false)
        openFromShelf()
        hideChrome()
        // Off the first page, so the place is his own.
        expectGesture("turn before the place checks", .moveOnce) { page(0.92, 0.5).tap() }
        expectGesture("a second turn", .moveOnce) { page(0.92, 0.5).tap() }
        keepLibraryOnRelaunch()
        let reopen = FeelPlaceStep("close to the shelf and open again") { _ in
            self.toShelf()
            self.openFromShelf()
            self.hideChrome()
        }
        check(feel.place(across: [.background, reopen, .relaunch], read: { self.words }), name: "open-reopen-place")

        // The way back from the reader (Close Book returns to the shelf), checked by Feel's own walk on the iPhone.
        // On the iPad the walk's edge swipe is unproven (ouro-ui-apple docs), so it is recorded, not judged there.
        app.terminate()
        launch(open: false)
        let shelf = FeelEntry("shelf") { app in _ = app.descendants(matching: .any)["library.grid"].waitForExistence(timeout: 60) }
        let walk = feel.wayBack(from: [shelf], follow: FeelFollow(types: [], prefixes: ["book.\(Self.book)", "library.account"]),
                                depth: 1, limit: 4)
        if pad { feel.record(walk, name: "way-back-ipad-unjudged") } else { check(walk, name: "way-back") }
    }

    // MARK: Turns

    /// Every turn moves the page once and holds: a tap at either edge, a swipe each way, a curl dragged across; a drag
    /// let go part way springs back without moving; a tap in the middle only shows and hides the controls.
    func testEveryTurnMovesOnceAndADragLetGoStays() {
        launch(open: true, ["-GatefoldGoTo", "0.3", "-GatefoldPageTurn", "curl"])
        hideChrome()
        expectGesture("a tap at the right edge", .moveOnce) { page(0.92, 0.5).tap() }
        expectGesture("a tap at the left edge", .moveOnce) { page(0.08, 0.5).tap() }
        expectGesture("a swipe left", .moveOnce) { el("reader.page").swipeLeft() }
        expectGesture("a swipe right", .moveOnce) { el("reader.page").swipeRight() }
        expectGesture("a curl dragged across", .moveOnce) {
            page(0.9, 0.6).press(forDuration: 0.05, thenDragTo: page(0.1, 0.55), withVelocity: .slow, thenHoldForDuration: 0)
        }
        expectGesture("a curl dragged back across", .moveOnce) {
            page(0.1, 0.6).press(forDuration: 0.05, thenDragTo: page(0.9, 0.55), withVelocity: .slow, thenHoldForDuration: 0)
        }
        expectGesture("a drag let go part way", .stay) {
            page(0.85, 0.6).press(forDuration: 0.05, thenDragTo: page(0.72, 0.6), withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        expectGesture("a tap in the middle, twice", .stay) {
            page(0.5, 0.5).tap()
            _ = app.buttons["reader.close"].waitForExistence(timeout: 3)
            page(0.5, 0.5).tap()
        }
    }

    // MARK: Rotation and posture

    /// The words he was reading stay on screen through a rotation and, on a Duo wide enough for a spread, through
    /// opening flat to a spread, standing it as a tabletop and folding back to one page. A reflow changes where the page
    /// starts, so the place read here is whether the first words he was on are still on screen (by hash of whether,
    /// never the words). The real hinge is moved by the Real unfold workflow; here the reader's own posture switch.
    func testRotationAndPostureKeepTheWordsInView() {
        launch(open: true, ["-GatefoldGoTo", "0.31"])
        hideChrome()
        expectGesture("a turn before rotating", .moveOnce) { page(0.92, 0.5).tap() }
        let anchor = words.split(whereSeparator: \.isWhitespace).prefix(8).joined(separator: " ")
        XCTAssertFalse(anchor.isEmpty, "the page has words to keep")
        let read = { () -> String in
            let now = self.words.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return now.isEmpty ? "" : (now.contains(anchor) ? "the first words he was on are in view" : FeelPlace.fingerprint(now))
        }
        var steps: [FeelPlaceStep] = [.rotate, .background]
        let wide = app.windows.firstMatch.frame.width >= 700
        if !pad, wide, el("debug.posture.spread").exists || app.buttons["debug.posture.spread"].waitForExistence(timeout: 5) {
            for posture in ["spread", "tabletop", "single"] {
                steps.append(FeelPlaceStep("posture \(posture)") { feel in
                    feel.app.buttons["debug.posture.\(posture)"].tap()
                    _ = feel.app.descendants(matching: .any)["reader.posture"].waitForExistence(timeout: 10)
                })
            }
        }
        let result = feel.place(across: steps, read: read)
        var noted = result
        if !wide && !pad {
            noted.findings.append(.note("the folded cover screen (\(Int(app.windows.firstMatch.frame.width)) pt) shows no spread, so posture was not walked here"))
        }
        check(noted, name: "rotation-posture-place")
    }

    // MARK: Contents, a link and Back

    /// Opening Contents and putting it away (Done, or a swipe down) leaves the page alone; a chapter picked there
    /// moves the page once and closes Contents; Back returns to the page he left. A link in the book does the same.
    func testContentsJumpDismissLinkAndBack() {
        launch(open: true, ["-GatefoldGoTo", "0.31"])
        hideChrome()
        let start = FeelPlace.fingerprint(settled())
        let contents = app.buttons["reader.contents"]
        let current = el("contents.current")
        func openContents() -> Bool {
            showChrome()
            guard contents.waitForExistence(timeout: 5) else { return false }
            contents.tap()
            return app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'contents.'")).firstMatch.waitForExistence(timeout: 15)
        }
        expectGesture("Contents opened and closed with Done", .stay) {
            XCTAssertTrue(openContents(), "Contents opened")
            let done = app.navigationBars.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch
            XCTAssertTrue(done.waitForExistence(timeout: 5), "Contents has a visible way back")
            done.tap()
            _ = current.waitForNonExistence(timeout: 10)
        }
        expectGesture("Contents opened and swiped down", .stay) {
            XCTAssertTrue(openContents(), "Contents opened")
            app.swipeDown(velocity: .fast)
            _ = current.waitForNonExistence(timeout: 10)
        }
        // A chapter well ahead: the list is lazy, so scroll it into view.
        expectGesture("a Contents jump", .moveOnce) {
            XCTAssertTrue(openContents(), "Contents opened")
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
            for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists && row.isHittable, "Contents lists a chapter ahead")
            row.tap()
        }
        let closed = current.waitForNonExistence(timeout: 10)
        feel.expect(FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: closed,
                               summary: closed ? "picking a chapter closed Contents" : "Contents stayed open after a pick",
                               findings: closed ? [] : [FeelFinding(what: "Contents stayed open after a chapter was picked")],
                               environment: feel.environment))
        expectGesture("Back after the jump", .moveOnce) {
            let back = app.buttons["reader.back"]
            if !back.waitForExistence(timeout: 5) { showChrome() }
            XCTAssertTrue(back.waitForExistence(timeout: 5), "a way back after the jump")
            back.tap()
        }
        let returned = FeelPlace.compare(start: start, after: ["Back after a Contents jump": FeelPlace.fingerprint(settled())])
        check(returned, name: "contents-back-place")

        // A link in the book: the front matter's own contents links into the text.
        app.terminate()
        launch(open: true, ["-GatefoldGoTo", "0"])
        hideChrome()
        let linkStart = FeelPlace.fingerprint(settled())
        let link = el("reader.page").links.firstMatch
        guard link.waitForExistence(timeout: 10) else {
            feel.expect(FeelResult(check: FeelGenre.wayBack.rawValue, passed: false, summary: "could not check: no link on the opening page",
                                   findings: [.couldNotCheck("no link was found on the book's opening page")], environment: feel.environment))
            return
        }
        expectGesture("a link followed", .moveOnce) { link.tap() }
        expectGesture("Back after the link", .moveOnce) {
            let back = app.buttons["reader.back"]
            if !back.waitForExistence(timeout: 5) { showChrome() }
            XCTAssertTrue(back.waitForExistence(timeout: 5), "a way back after the link")
            back.tap()
        }
        check(FeelPlace.compare(start: linkStart, after: ["Back after a link": FeelPlace.fingerprint(settled())]),
              name: "link-back-place")
    }

    // MARK: Appearance and Fine-Tune

    /// Appearance and its Fine-Tune page sit inside the window, go away with Close, and leave the page alone; a tap
    /// on the page beside the panel puts it away too.
    func testAppearanceAndFineTuneLeaveThePageAlone() {
        launch(open: true, ["-GatefoldGoTo", "0.31"])
        hideChrome()
        func openAppearance() {
            showChrome()
            let appearance = app.buttons["reader.appearance"]
            XCTAssertTrue(appearance.waitForExistence(timeout: 5), "Appearance is offered")
            appearance.tap()
            XCTAssertTrue(el("appearance.panel").waitForExistence(timeout: 10), "the Appearance panel")
        }
        func close() {
            let close = app.buttons["appearance.close"]
            if close.waitForExistence(timeout: 5) { close.tap() }
            _ = el("appearance.panel").waitForNonExistence(timeout: 10)
            hideChrome()
        }
        expectGesture("Appearance opened and closed", .stay) {
            openAppearance()
            check(feel.insideWindow(poses: [.current]), name: "appearance-inside-window")
            close()
        }
        expectGesture("Fine-Tune opened, Back, and closed", .stay) {
            openAppearance()
            let fine = app.buttons["appearance.customize"]
            XCTAssertTrue(fine.waitForExistence(timeout: 10), "Fine-Tune is offered")
            if !fine.isHittable { el("appearance.panel").swipeUp() }
            fine.tap()
            XCTAssertTrue(app.buttons["appearance.back"].waitForExistence(timeout: 10), "Fine-Tune has a way back")
            check(feel.insideWindow(poses: [.current]), name: "fine-tune-inside-window")
            app.buttons["appearance.back"].tap()
            XCTAssertTrue(fine.waitForExistence(timeout: 10), "Back returns to Appearance")
            close()
        }
        // A tap on the page above the panel puts it away, as any overlay should, and does not turn the page.
        expectGesture("Appearance put away by a tap beside it", .stay) {
            openAppearance()
            let panel = el("appearance.panel").frame, window = app.windows.firstMatch.frame
            let y = max(window.minY + 120, panel.minY - 60)
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: window.midX, dy: y)).tap()
            let gone = el("appearance.panel").waitForNonExistence(timeout: 5)
            feel.expect(FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: gone,
                                   summary: gone ? "a tap beside Appearance put it away" : "Appearance stayed after a tap beside it",
                                   findings: gone ? [] : [FeelFinding(what: "a tap on the page above the Appearance panel did not put it away")],
                                   environment: feel.environment))
            if !gone { close() }
            hideChrome()
        }
    }

    // MARK: Counting pages, and the Home Screen

    /// A fresh open counts the book's pages: once a number shows it never goes back to "Counting pages…", and a trip to
    /// the Home Screen keeps both the number and the page.
    func testCountingPagesThenTheHomeScreen() {
        launch(open: true, ["-GatefoldGoTo", "0.31", "-GatefoldPageFurniture", "YES"])
        hideChrome()
        var states: [String] = [], reads = 0, held = 0
        while reads < Self.readBudget {
            reads += 1
            let count = (el("reader.pageCount").value as? String) ?? ""
            let state = !count.isEmpty ? "number" : (el("reader.pageCounting").exists ? "counting" : "none")
            if states.last != state { states.append(state); held = 0 }
            held += 1
            // Settled once the number has held for as many reads as the words need.
            if state == "number" && held >= Self.agreeingReads { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        let backToCounting = states.drop { $0 != "number" }.contains("counting")
        var findings: [FeelFinding] = []
        if !states.contains("number") { findings.append(.couldNotCheck("no page count arrived in \(reads) reads")) }
        if backToCounting { findings.append(FeelFinding(what: "the count went back to Counting pages… after a number showed (\(states.joined(separator: " → ")))")) }
        feel.expect(FeelResult.judged(check: FeelGenre.chrome.rawValue, passing: "Counting pages… handed over to the number once",
                                      failing: { _ in "the page count did not hand over once" },
                                      measures: ["reads": Double(reads), "states": Double(states.count)], findings: findings,
                                      environment: feel.environment))
        let total = (el("reader.pageCount").value as? String) ?? ""
        keepLibraryOnRelaunch()
        check(feel.place(across: [.background], read: { self.words }), name: "home-screen-place")
        let after = (el("reader.pageCount").value as? String) ?? ""
        feel.expect(FeelResult(check: FeelGenre.placeStability.rawValue, passed: !total.isEmpty && after == total,
                               summary: after == total ? "the page count held across the Home Screen" : "the page count changed across the Home Screen",
                               measures: ["before": Double(total) ?? -1, "after": Double(after) ?? -1],
                               findings: after == total ? [] : [FeelFinding(what: "the page count read \(total) before the Home Screen and \(after) after")],
                               environment: feel.environment))
    }
}
