import XCTest

/// The reader keeps your place: rotation, posture and type changes never lose the words you were on.
/// The app exposes a hidden probe, `reader.anchorCheck`, which reads "anchor-visible" once a reflow
/// settles with the first words of the page you were on still on screen.
///
/// The tests don't depend on how the device starts: each launch forces the posture it needs
/// (`-GatefoldForcePosture`) and checks the reader's `reader.posture` probe before going on, so a Duo
/// left open, half open or folded runs them the same way.
@MainActor
final class PositionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(posture: String = "single", _ extra: [String] = []) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
            "-GatefoldTheme", "vellum", "-GatefoldForcePosture", posture,
        ] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 30))
        expectPosture(posture)
        // Wait until the book has laid out and the reader has a place (the first words on the page).
        // An unfolded Duo can reflow before the first place is taken, so the number may not be 0.
        waitForProbe(prefix: "ready", timeout: 90, what: "first page")
        // Turn a page so the place is the reader's own.
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        sleep(2)
    }

    /// Reads `element`'s label until `ok` holds or `timeout` passes, timing each read: a read that
    /// takes seconds means the app's main thread was busy, not that the reader was in the wrong state.
    private func poll(_ element: XCUIElement, timeout: TimeInterval, until ok: (String) -> Bool) -> (Bool, String, String) {
        let start = Date()
        var label = "", slowest = 0.0, reads = 0
        while true {
            let t = Date()
            label = element.label
            slowest = max(slowest, Date().timeIntervalSince(t)); reads += 1
            if ok(label) {
                if slowest > 1 { print(String(format: "probe timing: %d reads in %.1f s, slowest %.1f s", reads, Date().timeIntervalSince(start), slowest)) }
                return (true, label, "")
            }
            if Date().timeIntervalSince(start) > timeout { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return (false, label, String(format: " (%d reads in %.0f s, slowest %.1f s)", reads, Date().timeIntervalSince(start), slowest))
    }

    private func waitForProbe(prefix: String, timeout: TimeInterval, what: String, file: StaticString = #filePath, line: UInt = #line) {
        let (ok, label, timing) = poll(probe, timeout: timeout) { $0.hasPrefix(prefix + " ") }
        XCTAssertTrue(ok, "\(what): probe says \(label)\(timing)", file: file, line: line)
    }

    private var probe: XCUIElement { app.descendants(matching: .any)["reader.anchorCheck"] }

    /// The layout the reader is showing, whatever the device's own posture.
    private func expectPosture(_ posture: String, file: StaticString = #filePath, line: UInt = #line) {
        let (ok, label, timing) = poll(app.descendants(matching: .any)["reader.posture"], timeout: 20) { $0 == posture }
        XCTAssertTrue(ok, "posture: probe says \(label), wanted \(posture)\(timing)", file: file, line: line)
    }

    /// The probe reads "<state> <reflow number>". Returns the reflow number now on screen.
    private func reflowNumber() -> Int {
        Int(probe.label.split(separator: " ").last ?? "") ?? 0
    }

    /// Runs `action`, then waits for the reflows it causes to settle and checks the anchor is on screen.
    private func expectAnchorKept(_ what: String, file: StaticString = #filePath, line: UInt = #line, after action: () -> Void) {
        let before = reflowNumber()
        action()
        // Counted in reads of the probe, not seconds: on a starved runner one read took 22 s, so a 40 s
        // deadline saw a reflow twice and called it stuck (main at 379fda7, "settling 2").
        // Done once the new reflow's verdict has read the same 5 times in a row (2 s of 0.5 s beats).
        var last = ""
        var same = 0
        // A backstop, not the verdict: a runner that slow is broken, whatever the probe says.
        let cap = Date().addingTimeInterval(600)
        for _ in 0..<80 where Date() < cap {
            let label = probe.label
            if label != last { last = label; same = 0 } else { same += 1 }
            let n = Int(label.split(separator: " ").last ?? "") ?? 0
            if n > before, !label.hasPrefix("settling"), same >= 4 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(last.hasPrefix("anchor-visible"), "\(what): probe says \(last) (was reflow \(before)) — \(probe.value as? String ?? "")", file: file, line: line)
    }

    /// Posture changes at a width where a reader can see them. A folded Duo's 466 pt cover screen can
    /// never show a spread (`ReaderLayout.minimumSpreadWidth` is 700), and forcing one there, two
    /// 233 pt pages, failed most runs on a layout no reader reaches. The real hinge (folded cover to
    /// the 951 pt inner screen and back) is judged by the Real unfold workflow on every reader change.
    func testEveryPostureKeepsThePlace() throws {
        launch()
        let width = app.windows.firstMatch.frame.width
        try XCTSkipIf(width < 700,
                      "a \(Int(width)) pt screen can't show a spread; the Real unfold workflow moves the Duo's hinge")
        for posture in ["spread", "tabletop", "single", "spread", "single"] {
            expectAnchorKept("into \(posture)") { app.buttons["debug.posture.\(posture)"].tap() }
            expectPosture(posture)
        }
    }

    func testRotationKeepsThePlace() throws {
        launch()
        let before = app.windows.firstMatch.frame.size
        let reflows = reflowNumber()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        if app.windows.firstMatch.frame.size == before && reflowNumber() == reflows {
            throw XCTSkip("This display does not rotate (the folded Duo's cover screen is portrait only)")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        expectAnchorKept("rotate to landscape") { XCUIDevice.shared.orientation = .landscapeLeft }
        expectAnchorKept("rotate back to portrait") { XCUIDevice.shared.orientation = .portrait }
    }

    func testFontChangeKeepsThePlace() {
        // Your Page opens after the turn that makes the place his: opened at launch, the turn's tap in
        // the page's margin would close it (a tap outside a panel closes it and turns nothing).
        launch()
        // A centre tap shows the controls; one that lands before the page takes taps is tried again.
        let centre = app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        for _ in 0..<3 where !app.buttons["reader.appearance"].exists {
            centre.tap()
            _ = app.buttons["reader.appearance"].waitForExistence(timeout: 4)
        }
        XCTAssertTrue(app.buttons["reader.appearance"].exists)
        app.buttons["reader.appearance"].tap()
        let larger = app.buttons["appearance.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        expectAnchorKept("larger text") { larger.tap() }
        expectAnchorKept("much larger text") {
            larger.tap()
            larger.tap()
        }
        expectAnchorKept("smaller text") { app.buttons["appearance.smaller"].tap() }
    }

    func testTabletopDeckTurnsAndResizes() {
        launch()
        expectAnchorKept("into tabletop") { app.buttons["debug.posture.tabletop"].tap() }
        expectPosture("tabletop")
        let larger = app.buttons["deck.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        expectAnchorKept("tabletop, larger text") { larger.tap() }
        app.buttons["deck.next"].tap()
        app.buttons["deck.previous"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].exists)
    }

    /// Every control in the top bar does its own job, wherever the camera sits (on the folded Duo's
    /// cover screen Bookmark moves beside Close, clear of the camera and status column).
    func testBookmarkInTheTopBarBookmarks() {
        launch()
        let page = app.descendants(matching: .any)["reader.page"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let bookmark = app.buttons["reader.bookmark"]
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5))
        XCTAssertTrue(bookmark.isHittable)
        let before = (bookmark.value as? String) ?? "?"
        XCTAssertNotEqual(before, "Bookmarked", "the page isn't bookmarked before the tap")
        bookmark.tap()
        let (marked, reads, hung) = readsUntilBookmarked(bookmark)
        print("TAPRATE bookmark: marked=\(marked) after \(reads) reads\(hung ? " (hang guard)" : "")")
        XCTAssertTrue(marked, hung ? "the hang guard ran out after \(reads) reads"
                                   : "tapping the top bar's bookmark bookmarks the page (not in \(reads) reads)")
        XCTAssertEqual(bookmark.label, "Remove Bookmark")
    }

    /// The bookmark is judged in reads of its value, never seconds (gatefold#159, as FineTuneTap in #121): each read
    /// is a round trip to the app, so a starved runner makes reads slower instead of failing a tap that landed late.
    /// A tap that never bookmarks still fails, after 40 reads (at least 4 s). The 3-minute limit only catches a hang.
    private func readsUntilBookmarked(_ bookmark: XCUIElement) -> (marked: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(180)
        for read in 1...40 {
            if (bookmark.value as? String) == "Bookmarked" { return (true, read, false) }
            if Date() > hung { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, 40, false)
    }
}
