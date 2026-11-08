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
/// Sheets and panels are filmed frame by frame by Ouro Feel's recorder, injected from this bundle on the simulator
/// (`OuroFeelRecorderInjectable`), so Release never links it.
@MainActor
final class FeelUITests: XCTestCase {
    private var app: XCUIApplication!
    private var feel: OuroFeel!
    private var pad: Bool { UIDevice.current.userInterfaceIdiom == .pad }
    /// Film checks the recorder could not judge in this run (a busy frame), printed as `FEEL-NOTCHECKED`.
    private static var notChecked = 0
    /// This test's judged checks, failed checks (known failures included) and not-checked films, for its `FEEL:` line.
    private var tally = (checks: 0, failed: 0, notChecked: 0)

    override func setUp() async throws {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() async throws {
        // One line per test, so a Feel miss is easy to find in a job log that runs other suites too.
        // Failures so far (expected failures are not counted); `hasSucceeded` is not final until after tearDown.
        let verdict = (testRun?.totalFailureCount ?? 0) == 0 ? "passed" : "FAILED"
        print("FEEL: \(name) \(verdict) checks=\(tally.checks) failed=\(tally.failed) notChecked=\(tally.notChecked)")
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
        injectRecorder()
        app.launch()
        feel = OuroFeel(app)
        if open { waitForPage() }
    }

    /// Ouro Feel's recorder, loaded into the app from this test bundle, for films of a sheet or a panel frame by frame.
    private func injectRecorder() {
        let recorder = OuroFeel.injectedRecorderEnvironment
        XCTAssertNotNil(recorder, "the UI test bundle carries OuroFeelRecorderInjectable")
        app.launchEnvironment.merge(recorder ?? [:]) { _, new in new }
    }

    /// The arguments a reopen or relaunch uses: no reset, so the place he left is the place that comes back.
    private func keepLibraryOnRelaunch() { app.launchArguments = Self.signedIn }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    /// The running head (the contents entry he is in), as a hash only since it is the book's own title; nil when the
    /// head is not in the tree. A turn whose head changes crossed into another contents entry.
    private var chapter: String? {
        let head = el("reader.runningHead")
        return head.exists ? FeelPlace.fingerprint(head.label) : nil
    }
    /// The reader's own word that its page is laid out and showing (`reader.pageReady`).
    private var ready: Bool { (el("reader.pageReady").value as? String) == "1" }
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
    /// With `away`, also the read on which the words first showed something other than `away` (and not empty).
    private func watch(away: String? = nil) -> (hashes: [String], settled: Bool, reads: Int, firstChange: Int?) {
        var seq: [String] = [], same = 0, reads = 0, firstChange: Int?
        while reads < Self.readBudget {
            reads += 1
            let h = FeelPlace.fingerprint(words)
            if firstChange == nil, let away, h != away, h != FeelPlace.empty { firstChange = reads }
            if seq.last == h { same += 1 } else { seq.append(h); same = 1 }
            // Only reads taken once the reader says its page is ready count towards agreement.
            if !ready { same = 0 }
            if h != FeelPlace.empty, same >= Self.agreeingReads { return (seq, true, reads, firstChange) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (seq, false, reads, firstChange)
    }

    /// The words once settled (or what is there when the read budget runs out).
    @discardableResult
    private func settled() -> String {
        _ = watch()
        return words
    }

    /// A step for ``placeAcross(_:read:)``: its name and what it does.
    private typealias Step = (name: String, run: () -> Void)

    private var homeScreen: Step {
        ("the Home Screen and back", {
            XCUIDevice.shared.press(.home)
            _ = self.app.wait(for: .runningBackground, timeout: 10)
            self.app.activate()
            _ = self.app.wait(for: .runningForeground, timeout: 30)
        })
    }

    private var relaunch: Step {
        ("relaunch", {
            self.app.terminate()
            self.keepLibraryOnRelaunch()
            self.app.launch()
            self.waitForPage()
            self.hideChrome()
        })
    }

    /// Feel's place stability, read by events: the place is read once the words have settled (``watch()``) before
    /// and after each step, and compared as SHA-256 prefixes (`FeelPlace`). Feel's own `place(across:)` settles on the
    /// runner's clock, which a slow reopen outlasts.
    private func placeAcross(_ steps: [Step], read: () -> String) -> FeelResult {
        _ = watch()
        let start = FeelPlace.fingerprint(read())
        var after: [String: String] = [:]
        for step in steps {
            step.run()
            _ = watch()
            after[step.name] = FeelPlace.fingerprint(read())
        }
        return FeelPlace.compare(start: start, after: after)
    }

    // Ouro Feel 0.3.6's place trails (`placeHeld`, `placeFights`) judge stray input and his own moves in
    // ``testStrayInputKeepsThePlaceAndMovesHold``; `judgeGesture` stays for what they do not cover: a turn that must
    // move exactly once (a spazz), and a turn that comes late. Screen-pixel flicker (`screenFilm`) needs an app clock
    // Gatefold does not have, and its pictures are of the page, so it is not used.

    /// For a place trail's `between`: each read waits for the words to settle (counted reads, ``watch()``), never a pause.
    private func settleRead() { _ = watch() }

    /// Refreshes in a row an element must hold still (within half a point) to count as landed: counted in the app's own
    /// drawn frames, never in time, so a starved runner that draws less often still judges the same way.
    private static let restRefreshes = 12
    /// The most refreshes a sheet may travel before it lands: 36 is 0.6 s at 60 Hz, a little over UIKit's own sheet.
    private static let landingRefreshes = 36

    /// Films `key` with no input until its last `restRefreshes` refreshes held still (at most ten films). False, with a
    /// `FEEL-NOTCHECKED` line, when it never did or the recorder gave no film, so what follows was not on a landed sheet.
    @discardableResult
    private func waitUntilStill(_ key: String) -> Bool {
        for _ in 0..<10 {
            let film = feel.recordedFilm([key]) {}
            let track = film.track(key)
            guard let last = track.last else {
                if film.stalledAt != nil { break }
                continue
            }
            if track.reversed().prefix(while: { FeelFilm.distance($0.frame, last.frame) <= 0.5 }).count >= Self.restRefreshes { return true }
        }
        tally.notChecked += 1
        print("FEEL-NOTCHECKED \(key): never held still for \(Self.restRefreshes) refreshes in ten films")
        return false
    }

    /// How `key` landed in `film`, in refreshes: from the first that moved it to the first of the run it then held still
    /// for, and how long that run is. Nil when it never moved.
    private func landing(_ film: FeelFilm, _ key: String) -> (travel: Int, still: Int)? {
        let track = film.track(key)
        guard let first = track.first,
              let start = track.firstIndex(where: { FeelFilm.distance($0.frame, first.frame) > 0.5 }) else { return nil }
        let last = track[track.count - 1].frame
        var rest = track.count - 1
        while rest > start, FeelFilm.distance(track[rest - 1].frame, last) <= 0.5 { rest -= 1 }
        return (rest - start, track.count - rest)
    }

    /// What the reader is meant to do after a gesture: move once, or stay.
    private enum Expect { case moveOnce, stay }

    /// A turn's film in one line: the display refresh (frame index from the film's start, which is just before the
    /// gesture) on which the page number first changed, its time, the film's cadence, and its longest gap between
    /// refreshes (a gap well over the cadence is the runner or the app stalling, not the page being slow).
    private func filmed(_ film: FeelFilm) -> String {
        let numbers = film.frames.map { $0.seen.filter { $0.key == "reader.pageNumber" }.map(\.label).joined(separator: ",") }
        let first = numbers.first ?? ""
        let changed = numbers.firstIndex { $0 != first && !$0.isEmpty }
        let gaps = zip(film.frames.dropFirst(), film.frames).map { $0.t - $1.t }
        let at = changed.map { "firstChangedRefresh=\($0) t=\(String(format: "%.3f", film.frames[$0].t))" }
            ?? "firstChangedRefresh=none filmEnd=\(String(format: "%.3f", film.frames.last?.t ?? 0))"
        return "\(at) refreshes=\(film.frames.count) cadence=\(String(format: "%.4f", film.cadence)) maxGap=\(String(format: "%.3f", gaps.max() ?? 0))"
            + (film.stalledAt.map { " stalledAt=\(String(format: "%.3f", $0))" } ?? "")
            + (first.isEmpty ? " number=hidden" : "")
    }

    /// Runs `action` and judges what the words did, by counting changes: a turn moves them exactly once (A→B), a gesture
    /// that is not a turn leaves them alone. Two or more changes is the "spazz" (A→B→A, A→B→C); "empty" frames between
    /// two pages are not a change of their own.
    private func judgeGesture(_ name: String, _ expect: Expect, _ action: () -> Void) -> FeelResult {
        let before = FeelPlace.fingerprint(settled())
        let chapterBefore = chapter
        // A turn is filmed by the app, one sample per display refresh, so when it first shows the new page is read off
        // the app's own clock, not the probe's read speed. The words live in a web view the film cannot see, so it
        // watches the page number (`reader.pageNumber`, digits only), which changes with the page.
        var turnFilm: FeelFilm?
        if expect == .moveOnce {
            turnFilm = feel.recordedFilm(["reader.pageNumber"]) { action() }
        } else {
            action()
        }
        var seen = watch(away: before)
        var firstChange = seen.firstChange
        // A turn that has not shown yet may commit late (a turn into the next chapter waits for it to load): keep
        // watching until the words move or the read budget runs out, so how fast the machine reads never decides it.
        // `reader.pageReady` is set once per open, and `reader.turnSettle` only on the spread's settler, so neither
        // marks every turn's end. A late move passes, with a note saying how late (gatefold#61).
        var lateBy = 0
        while expect == .moveOnce, seen.settled, seen.reads < Self.readBudget,
              Set(seen.hashes.filter { $0 != FeelPlace.empty }).subtracting([before]).isEmpty {
            let more = watch(away: before)
            if firstChange == nil, let at = more.firstChange { firstChange = seen.reads + at }
            lateBy += more.reads
            seen = (seen.hashes + more.hashes, more.settled, seen.reads + more.reads, nil)
        }
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
                findings.append(FeelFinding(what: "\(name): the page did not move in \(seen.reads) reads (\(before) stayed)"))
            } else if changes > 1 {
                findings.append(FeelFinding(what: "\(name): the words changed \(changes) times before settling (\(collapsed.joined(separator: " → ")))"))
            }
        case .stay:
            if changes > 0 {
                findings.append(FeelFinding(what: "\(name): the words changed though nothing should move them (\(collapsed.joined(separator: " → ")))"))
            }
        }
        if expect == .moveOnce {
            // One line per turn for the per-turn table: reads from the gesture to the first new words, and whether the
            // turn crossed a chapter (its running head changed). The probe trails the screen by about 3 reads
            // (gatefold#77), so this is an upper bound on how slow the page was, read on this machine's clock.
            let chapterAfter = chapter
            let crossed = chapterBefore.flatMap { b in chapterAfter.map { "\(b != $0)" } } ?? "unknown"
            print("FEEL-TURN \(name) crossed=\(crossed) \(turnFilm.map { filmed($0) } ?? "film=none") readsAfterFilm=\(firstChange.map { "\($0)" } ?? "none") reads=\(seen.reads)")
        }
        if expect == .moveOnce, changes > 0, lateBy > 0 {
            findings.append(.note("\(name): it moved late, \(lateBy) reads after the first settled watch"))
            print("FEEL-LATE \(name): moved \(lateBy) reads late")
        }
        let genre = expect == .stay ? FeelGenre.placeStability : FeelGenre.jumpAfterLanding
        return FeelResult.judged(check: genre.rawValue,
                                 passing: expect == .stay ? "\(name): the page stayed" : "\(name): the page moved once and held",
                                 failing: { _ in "\(name): \(expect == .stay ? "the page moved" : "the page did not move once and hold")" },
                                 measures: ["changes": Double(changes), "reads": Double(seen.reads)],
                                 findings: findings, environment: feel.environment)
    }

    /// `result` with anything quoted in its findings that is not one of the app's own identifiers (a link's or a title's
    /// label, which can be the book's words) replaced by its fingerprint, so reports and logs hold hashes, never text.
    /// Greedy from the first quote to the last, so a label holding quotes of its own is hashed whole.
    private func safe(_ result: FeelResult) -> FeelResult {
        let quoted = try! NSRegularExpression(pattern: "\"(.*)\"")
        let ours = ["reader.", "appearance.", "signIn.", "library.", "book.", "contents.", "debug."]
        let named: Set<String> = ["Done", "Close", "Sign Out"]
        func scrub(_ text: String) -> String {
            guard let m = quoted.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let r = Range(m.range(at: 1), in: text) else { return text }
            let inner = String(text[r])
            if named.contains(inner) || ours.contains(where: { inner.hasPrefix($0) && !inner.contains(" ") }) { return text }
            var out = text
            out.replaceSubrange(r, with: "#" + FeelPlace.fingerprint(inner))
            return out
        }
        var kept = result
        kept.summary = scrub(kept.summary)
        kept.findings = kept.findings.map { var f = $0; f.what = scrub(f.what); return f }
        return kept
    }

    /// Records `result` under `name`, not judged.
    private func record(_ result: FeelResult, name: String, film: FeelFilm? = nil) {
        _ = feel.record(safe(result), name: name, film: film)
    }

    /// Records `result` (Feel's own `expect`) and fails the test if it failed, counted on the `FEEL:` line.
    private func expectChecked(_ result: FeelResult, file: StaticString = #filePath, line: UInt = #line) {
        let kept = safe(result)
        tally.checks += 1
        if !kept.passed { tally.failed += 1 }
        _ = feel.expect(kept, file: file, line: line)
    }

    /// Records `result` under `name` and fails the test if it failed.
    private func check(_ result: FeelResult, name: String, film: FeelFilm? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let kept = feel.record(safe(result), name: name, film: film)
        tally.checks += 1
        if !kept.passed { tally.failed += 1 }
        if !kept.passed { XCTFail(kept.text, file: file, line: line) }
    }

    /// A film's result, failing the test only on jank it saw. What the app's recorder could not see (a frame the app was
    /// too busy to draw, on a loaded simulator) is kept in the report as not checked rather than turning the check red;
    /// settle times are recorded, never judged, since they measure the machine as much as the app.
    private func judgeSeen(_ result: FeelResult, name: String, film: FeelFilm, file: StaticString = #filePath, line: UInt = #line) {
        let kept = feel.record(safe(result), name: name, film: film)
        let unchecked = kept.findings.filter(\.unchecked).count
        tally.checks += 1
        tally.notChecked += unchecked
        if !kept.detections.isEmpty { tally.failed += 1 }
        if unchecked > 0 {
            // Counted and printed, so a film that never sees anything cannot pass every run in silence.
            Self.notChecked += unchecked
            print("FEEL-NOTCHECKED \(name): \(unchecked) not checked (\(Self.notChecked) so far)")
        }
        if !kept.detections.isEmpty { XCTFail(kept.text, file: file, line: line) }
    }

    private func expectGesture(_ name: String, _ expect: Expect, _ action: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        expectChecked(judgeGesture(name, expect, action), file: file, line: line)
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
        injectRecorder()
        app.launch()
        feel = OuroFeel(app)
        let start = app.buttons["welcome.signIn"]
        XCTAssertTrue(start.waitForExistence(timeout: 60), "the welcome")
        check(feel.insideWindow(poses: [.current]), name: "welcome-inside-window")

        let email = app.textFields["signIn.email"]
        let toEmail = feel.film(["signIn.email", "signIn.continue"], for: 3) { start.tap() }
        // A film samples on the runner's clock, so its jumps are recorded for the reviewers, never judged here.
        record(toEmail.jumps(of: "signIn.continue"), name: "email-step-jumps", film: toEmail)
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
        expectChecked(FeelResult(check: FeelGenre.wayBack.rawValue, passed: wentBack,
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
        record(toShelf.jumps(of: "library.grid"), name: "shelf-jumps", film: toShelf)
        // The shelf's Reading Now row scrolls sideways; Feel's carousel rule misreads it as controls off the window, so
        // the shelf's result is recorded for the reviewers, not judged (reported to ouro-ui-apple).
        record(feel.insideWindow(poses: [.current]), name: "shelf-inside-window")
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
        let reopen: Step = ("close to the shelf and open again", {
            self.toShelf()
            self.openFromShelf()
            self.hideChrome()
        })
        check(placeAcross([homeScreen, reopen, relaunch], read: { words }), name: "open-reopen-place")

        // The reader's way back is Close Book, under a tap (its chrome starts hidden, and an edge swipe turns the page,
        // so Feel's walk cannot judge the reader): it must return to the shelf.
        showChrome()
        let close = app.buttons["reader.close"]
        let backToShelf = close.exists && { close.tap(); return el("library.grid").waitForExistence(timeout: 30) }()
        check(FeelResult(check: FeelGenre.wayBack.rawValue, passed: backToShelf,
                         summary: backToShelf ? "Close Book returned to the shelf" : "Close Book did not return to the shelf",
                         findings: backToShelf ? [] : [FeelFinding(what: "the reader's Close Book did not return to the shelf")],
                         environment: feel.environment), name: "reader-way-back")

        // The shelf's one other way out is the Account menu: a tap outside it puts it away. (Its only items are the
        // account's name, which is not a control, and Sign Out, so nothing in it is safe to pick; Feel's walk picks
        // the name and reads the menu as stuck, so the overlay check is used instead.)
        check(feel.overlays([.button("library.account", overlay: "Sign Out")]), name: "account-menu-dismissal")
    }

    // MARK: Place trails (Ouro Feel 0.3.6)

    /// Stray input never moves his place, even for one read (`placeHeld`): a tap in the middle (controls shown, then
    /// hidden), nothing at all (a late restore or sync), the Home Screen and back, Contents opened and put away. His own
    /// moves land and hold (`placeFights`): no late restore, re-sent jump or sync landing moves them after. Inside a
    /// chapter (0.31), so no move crosses one (gatefold#61 has its own expectation in the turns test).
    ///
    /// Off unless `TEST_RUNNER_OURO_FEEL_PLACE_TRAILS=1`: on a starved host the app restarted mid-trail with no crash
    /// report, so it joins the required jobs after a run on a quiet runner proves it.
    func testStrayInputKeepsThePlaceAndMovesHold() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OURO_FEEL_PLACE_TRAILS"] == "1",
                          "place trails run only when asked (TEST_RUNNER_OURO_FEEL_PLACE_TRAILS=1)")
        launch(open: true, ["-GatefoldGoTo", "0.31", "-GatefoldPageTurn", "curl"])
        hideChrome()
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch
        let contentsAway = FeelPlaceStep("Contents opened and put away") { _ in
            self.showChrome()
            self.app.buttons["reader.contents"].tap()
            guard done.waitForExistence(timeout: 15) else { return }
            done.tap()
            _ = done.waitForNonExistence(timeout: 10)
            self.hideChrome()
        }
        check(feel.placeHeld(across: [.strayTap(), .strayTap(), .noInput, .background, contentsAway],
                             reads: 4, between: { self.settleRead() }, read: { self.words }), name: "stray-input-place-held")

        let turn = FeelPlaceStep("a tap at the right edge") { _ in self.page(0.92, 0.5).tap() }
        let swipe = FeelPlaceStep("a swipe left") { _ in self.el("reader.page").swipeLeft() }
        let curl = FeelPlaceStep("a curl dragged across") { _ in
            self.page(0.9, 0.6).press(forDuration: 0.05, thenDragTo: self.page(0.1, 0.55), withVelocity: .slow, thenHoldForDuration: 0)
        }
        let jump = FeelPlaceStep("a Contents jump") { _ in
            self.showChrome()
            self.app.buttons["reader.contents"].tap()
            guard done.waitForExistence(timeout: 15) else { return }
            let row = self.app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XL")).firstMatch
            for _ in 0..<24 where !(row.exists && row.isHittable) { self.app.swipeUp(velocity: .slow) }
            if row.exists && row.isHittable { row.tap() } else { done.tap() }
            _ = done.waitForNonExistence(timeout: 10)
            self.hideChrome()
        }
        check(feel.placeFights([turn, swipe, curl, jump], reads: 6, between: { self.settleRead() }, read: { self.words }),
              name: "moves-land-and-hold")
    }

    // MARK: Turns

    /// Every turn moves the page once and holds: a tap at either edge, a swipe each way, a curl dragged across; a drag
    /// let go part way springs back without moving; a tap in the middle only shows and hides the controls.
    func testEveryTurnMovesOnceAndADragLetGoStays() {
        launch(open: true, ["-GatefoldGoTo", "0.3", "-GatefoldPageTurn", "curl"])
        hideChrome()
        expectGesture("a tap at the right edge", .moveOnce) { page(0.92, 0.5).tap() }
        // gatefold#61, not strict: the back turn into the previous chapter is late, and how late depends on the runner, so
        // it may or may not miss within the read budget; seen only on the folded Duo. The Contents/link/Back moves below
        // wait the same way.
        XCTExpectFailure("gatefold#61: a tap at the left edge does not turn back, or turns back late", strict: false) {
            expectGesture("a tap at the left edge", .moveOnce) { page(0.08, 0.5).tap() }
        }
        expectGesture("a swipe left", .moveOnce) { el("reader.page").swipeLeft() }
        XCTExpectFailure("gatefold#61: a swipe right does not turn back, or turns back late", strict: false) {
            expectGesture("a swipe right", .moveOnce) { el("reader.page").swipeRight() }
        }
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
        let rotate: Step = ("rotate and back", {
            XCUIDevice.shared.orientation = .landscapeLeft
            _ = self.watch()
            XCUIDevice.shared.orientation = .portrait
        })
        var steps: [Step] = [rotate, homeScreen]
        let wide = app.windows.firstMatch.frame.width >= 700
        if !pad, wide, el("debug.posture.spread").exists || app.buttons["debug.posture.spread"].waitForExistence(timeout: 5) {
            for posture in ["spread", "tabletop", "single"] {
                steps.append(("posture \(posture)", {
                    self.app.buttons["debug.posture.\(posture)"].tap()
                    let probe = self.el("reader.posture")
                    _ = XCTWaiter.wait(for: [self.expectation(for: NSPredicate(format: "label == %@", posture), evaluatedWith: probe)], timeout: 60)
                }))
            }
        }
        let result = placeAcross(steps, read: read)
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
        // The sheet is up while its Done is: a row (even the current one) can scroll out of a lazy list.
        let done = app.buttons.matching(NSPredicate(format: "label == 'Done' OR label == 'Close'")).firstMatch
        func openContents() -> Bool {
            showChrome()
            guard contents.waitForExistence(timeout: 5) else { return false }
            contents.tap()
            return done.waitForExistence(timeout: 15)
        }
        func dismissal(_ how: String, _ gone: Bool) {
            check(FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: gone,
                             summary: gone ? "\(how) put Contents away" : "Contents stayed up after \(how)",
                             findings: gone ? [] : [FeelFinding(what: "Contents stayed up after \(how)")],
                             environment: feel.environment), name: "contents-dismissal-" + how.replacingOccurrences(of: " ", with: "-"))
            if !gone, done.exists { done.tap(); _ = done.waitForNonExistence(timeout: 10) }
        }
        // Contents travels in (no snap) and holds still once up, filmed by the app frame by frame.
        showChrome()
        let film = feel.recordedFilm(["Done"]) { contents.tap() }
        judgeSeen(film.snaps(of: "Done", appearing: true), name: "contents-snaps", film: film)
        judgeSeen(film.jumps(of: "Done"), name: "contents-jumps", film: film)
        judgeSeen(film.flickers(of: ["Done"]), name: "contents-flickers", film: film)
        record(film.settles("Done", within: 1.0), name: "contents-settles")
        // The same landing in refreshes. Recorded, not judged, until a run on a quiet runner (after the web view leak fix)
        // says whether CI's 1.7-2.2 s landings are the app or the runner.
        let landed = landing(film, "Done")
        let landedFindings: [FeelFinding] = {
            guard let landed else { return [.couldNotCheck("Contents: Done never moved in the film")] }
            if landed.still < Self.restRefreshes { return [FeelFinding(what: "Contents was still moving when the film ended (\(landed.travel) refreshes)")] }
            if landed.travel > Self.landingRefreshes { return [FeelFinding(what: "Contents took \(landed.travel) refreshes to land (limit \(Self.landingRefreshes))")] }
            return []
        }()
        record(FeelResult.judged(check: FeelGenre.settleTime.rawValue,
                                 passing: "Contents landed in \(landed?.travel ?? 0) refreshes",
                                 failing: { _ in "Contents did not land within \(Self.landingRefreshes) refreshes" },
                                 measures: ["refreshes": Double(landed?.travel ?? -1), "cadence": film.cadence],
                                 findings: landedFindings, environment: feel.environment),
               name: "contents-landing-refreshes")
        XCTAssertTrue(done.waitForExistence(timeout: 15), "Contents opened, with a visible way back")
        done.tap()
        _ = done.waitForNonExistence(timeout: 10)
        hideChrome()
        expectGesture("Contents opened and closed with Done", .stay) {
            XCTAssertTrue(openContents(), "Contents opened, with a visible way back")
            done.tap()
            dismissal("Done", done.waitForNonExistence(timeout: 10))
        }
        expectGesture("Contents opened and pulled down", .stay) {
            XCTAssertTrue(openContents(), "Contents opened")
            // Pull once Contents has landed, as a person does: UIKit ignores a pull while the sheet is still travelling
            // in, and on CI's starved runners it took 1.7-2.2 s to land (contents-settles), so a pull the moment Done
            // existed sometimes came too early (gatefold#68's Duo, run 42502541231).
            waitUntilStill("Done")
            // From the sheet's bar, so the pull moves the sheet rather than scrolling its list.
            let bar = app.navigationBars.firstMatch
            let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: app.windows.firstMatch.frame.height * 0.6)),
                       withVelocity: .fast, thenHoldForDuration: 0)
            dismissal("a pull down", done.waitForNonExistence(timeout: 10))
        }
        // A chapter well ahead: the list is lazy, so scroll it into view.
        expectGesture("a Contents jump", .moveOnce) {
            XCTAssertTrue(openContents(), "Contents opened")
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Chapter XXX")).firstMatch
            for _ in 0..<20 where !(row.exists && row.isHittable) { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(row.exists && row.isHittable, "Contents lists a chapter ahead")
            row.tap()
            dismissal("a pick", done.waitForNonExistence(timeout: 10))
        }
        func goBack(_ after: String) {
            let back = app.buttons["reader.back"]
            if !back.waitForExistence(timeout: 5) { showChrome() }
            XCTAssertTrue(back.waitForExistence(timeout: 5), "a way back after \(after)")
            back.tap()
        }
        expectGesture("Back after the jump", .moveOnce) { goBack("the jump") }
        check(FeelPlace.compare(start: start, after: ["Back after a Contents jump": FeelPlace.fingerprint(settled())]),
              name: "contents-back-place")

        // A link in the book: the front matter links into the text. The first page is the cover, so turn (counted, at
        // most eight turns) until a page shows a link.
        app.terminate()
        launch(open: true, ["-GatefoldGoTo", "0"])
        hideChrome()
        let link = el("reader.page").links.firstMatch
        var turns = 0
        while !link.exists && turns < 8 {
            turns += 1
            page(0.92, 0.5).tap()
            _ = watch()
        }
        guard link.exists else {
            check(FeelResult(check: FeelGenre.wayBack.rawValue, passed: false, summary: "could not check: no link in the first \(turns + 1) pages",
                             findings: [.couldNotCheck("no link was found in the book's first \(turns + 1) pages")], environment: feel.environment),
                  name: "link-way-back")
            return
        }
        let linkStart = FeelPlace.fingerprint(settled())
        func followAndBack() {
            expectGesture("a link followed", .moveOnce) { link.tap() }
            expectGesture("Back after the link", .moveOnce) { goBack("the link") }
            check(FeelPlace.compare(start: linkStart, after: ["Back after a link": FeelPlace.fingerprint(settled())]),
                  name: "link-back-place")
        }
        // A known failure (seen on the iPad and the folded Duo in CI), strict, so the check goes red the moment a fix lands
        // and the expectation must be restored.
        XCTExpectFailure("gatefold#73: a followed link does not move the page and leaves no Back", strict: true) {
            followAndBack()
        }
    }

    // MARK: Pull-down sheets

    /// Every sheet he can pull down goes away when pulled from its bar once it has landed. Contents is pulled in
    /// ``testContentsJumpDismissLinkAndBack``; Search is pulled here. The Highlights sheets need a highlight and the
    /// shelf's reconnect sheet a lapsed sign-in, which the walk does not set up.
    func testEveryPullDownSheetGoesAway() {
        launch(open: true, ["-GatefoldGoTo", "0.31"])
        hideChrome()
        let done = app.buttons["Done"]
        showChrome()
        let search = app.buttons["reader.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5), "Search is offered")
        search.tap()
        XCTAssertTrue(done.waitForExistence(timeout: 15), "Search opened, with a visible way back")
        waitUntilStill("Done")
        // From the top of the sheet's bar, above its search field, so the pull moves the sheet.
        let bar = app.navigationBars.firstMatch
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: app.windows.firstMatch.frame.height * 0.6)),
                   withVelocity: .fast, thenHoldForDuration: 0)
        let gone = done.waitForNonExistence(timeout: 10)
        expectChecked(FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: gone,
                                 summary: gone ? "a pull down put Search away" : "Search stayed up after a pull down",
                                 findings: gone ? [] : [FeelFinding(what: "Search stayed up after a pull down")],
                                 environment: feel.environment))
        if !gone, done.exists { done.tap() }
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
        // The panel grows out of its pill (no snap) and holds still once up, filmed by the app frame by frame.
        showChrome()
        let film = feel.recordedFilm(["appearance.panel"]) { self.app.buttons["reader.appearance"].tap() }
        let snaps = film.snaps(of: "appearance.panel", appearing: true)
        if pad {
            judgeSeen(snaps, name: "appearance-snaps", film: film)
        } else {
            // Intermittent on the Duo (once in two runs), so not strict.
            XCTExpectFailure("gatefold#84: on the Duo the Appearance panel sometimes appears with no transition", strict: false) {
                judgeSeen(snaps, name: "appearance-snaps", film: film)
            }
        }
        judgeSeen(film.jumps(of: "appearance.panel"), name: "appearance-jumps", film: film)
        judgeSeen(film.flickers(of: ["appearance.panel"]), name: "appearance-flickers", film: film)
        record(film.settles("appearance.panel", within: 1.0), name: "appearance-settles")
        close()
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
            // Between the top bar's controls and the panel, clear of both, in the page's middle third (not a turn zone).
            let panel = el("appearance.panel").frame, pageFrame = el("reader.page").frame
            let barFoot = max(app.buttons["reader.close"].frame.maxY, pageFrame.minY)
            guard panel.minY - barFoot > 60 else {
                // Not judged on this device: counted as not checked, so it can't turn the check red or pass in silence.
                tally.notChecked += 1
                Self.notChecked += 1
                print("FEEL-NOTCHECKED appearance-tap-beside: 1 not checked (\(Self.notChecked) so far)")
                record(FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: false, summary: "could not check: no page between the bar and the panel",
                                 findings: [.couldNotCheck("the panel reaches the top bar, so there is no page to tap beside it")],
                                 environment: feel.environment), name: "appearance-tap-beside")
                close()
                return
            }
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: pageFrame.midX, dy: (barFoot + panel.minY) / 2)).tap()
            let gone = el("appearance.panel").waitForNonExistence(timeout: 5)
            let dismissal = FeelResult(check: FeelGenre.overlayDismissal.rawValue, passed: gone,
                                       summary: gone ? "a tap beside Appearance put it away" : "Appearance stayed after a tap beside it",
                                       findings: gone ? [] : [FeelFinding(what: "a tap on the page above the Appearance panel did not put it away")],
                                       environment: feel.environment)
            // A known failure, strict (seen on the folded Duo and the iPad), so the check goes red the moment a fix lands
            // and the expectation must be restored.
            XCTExpectFailure("gatefold#62: a tap beside the Appearance panel does not put it away", strict: true) {
                check(dismissal, name: "appearance-tap-beside")
            }
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
        if (el("reader.countingShown").value as? String) != "1" && !states.contains("counting") {
            findings.append(.note("Counting pages… never showed on this open (the count was ready first)"))
        }
        if backToCounting { findings.append(FeelFinding(what: "the count went back to Counting pages… after a number showed (\(states.joined(separator: " → ")))")) }
        expectChecked(FeelResult.judged(check: FeelGenre.chrome.rawValue, passing: "Counting pages… handed over to the number once",
                                      failing: { _ in "the page count did not hand over once" },
                                      measures: ["reads": Double(reads), "states": Double(states.count)], findings: findings,
                                      environment: feel.environment))
        let total = (el("reader.pageCount").value as? String) ?? ""
        check(placeAcross([homeScreen], read: { words }), name: "home-screen-place")
        // After the Home Screen the number stays: it never falls back to Counting pages….
        var fellBack = 0, looks = 0
        while looks < Self.agreeingReads * 2 {
            looks += 1
            if el("reader.pageCounting").exists && (el("reader.pageCount").value as? String ?? "").isEmpty { fellBack += 1 }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        check(FeelResult.judged(check: FeelGenre.chrome.rawValue, passing: "the number stayed after the Home Screen",
                                failing: { _ in "Counting pages… came back after the Home Screen" },
                                measures: ["countingReads": Double(fellBack)],
                                findings: fellBack == 0 ? [] : [FeelFinding(what: "Counting pages… showed again in \(fellBack) reads after the Home Screen")],
                                environment: feel.environment), name: "counting-after-home-screen")
        let after = (el("reader.pageCount").value as? String) ?? ""
        let countHeld = !total.isEmpty && after == total
        expectChecked(FeelResult(check: FeelGenre.placeStability.rawValue, passed: countHeld,
                               summary: countHeld ? "the page count held across the Home Screen"
                                   : total.isEmpty ? "no page count to compare across the Home Screen" : "the page count changed across the Home Screen",
                               measures: ["before": Double(total) ?? -1, "after": Double(after) ?? -1],
                               findings: countHeld ? [] : [FeelFinding(what: total.isEmpty ? "no page count had arrived before the Home Screen"
                                                                      : "the page count read \(total) before the Home Screen and \(after) after")],
                               environment: feel.environment))
    }
}
