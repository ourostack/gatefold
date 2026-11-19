import OuroFeel
import OuroFeelCore
import OuroHXTesting
import XCTest

/// Ouro Feel (ourostack/ouro-ui-apple) over the reader on the iPhone Duo: closed, open in portrait and open on its
/// side, in scroll mode and in paged (curl) mode. In each it checks, with Feel's own checks:
///
/// - **still while idle:** with no touch, no control or the running head appears, goes or moves, and the status bar
///   neither shows nor hides, with the controls away and with them up;
/// - **covered content:** the running heads cover no line of the page;
/// - **inside the window:** every control and the page itself lie inside the window;
/// - **place kept through stray input:** a tap on the page, a tap at the top edge (the status bar), a swipe across
///   and back (scroll mode; in paged mode a swipe turns the page) and a trip to the Home Screen leave the place
///   where it was.
///
/// Every one of these is something Ari met in build 39 on his Duo that no test caught (Ari, 2026-11-15). The place is
/// `reader.visibleText`, compared as a SHA-256 prefix only, so no book text reaches a report.
///
/// The open postures need the hinge: Device Hub moves it, driven through `OuroDuoHinge` by the `duo-feel-open` shard
/// (`hinge: true` in app.yml), which passes `TEST_RUNNER_OURO_DUO_POSTURE_DIR`. Without it those tests skip, and that
/// shard fails on any skip, so the open postures are never passed quietly.
@MainActor
final class FeelReaderUITests: XCTestCase {
    private var app: XCUIApplication!
    private var feel: OuroFeel!
    private var hinge: OuroDuoHinge?
    private var turned = false

    private enum Posture: String { case closed, openPortrait = "open, portrait", openLandscape = "open, on its side" }
    private enum Mode: String { case scroll, paged = "curl" }

    override func setUp() async throws {
        continueAfterFailure = true
    }

    override func tearDown() async throws {
        app?.terminate()
        // Leave the Duo as the next test expects it: upright and closed. Three quarter turns right, since Device Hub
        // could not press its Rotate Left (run 43759594068), which left the next tests on their side.
        if turned { for _ in 0..<3 { try? hinge?.rotateRight() } }
        if hinge != nil { try? hinge?.set(.closed) }
    }

    func testClosedScroll() throws { try walk(.closed, .scroll) }
    func testClosedPaged() throws { try walk(.closed, .paged) }
    func testOpenPortraitScroll() throws { try walk(.openPortrait, .scroll) }
    func testOpenPortraitPaged() throws { try walk(.openPortrait, .paged) }
    func testOpenLandscapeScroll() throws { try walk(.openLandscape, .scroll) }
    func testOpenLandscapePaged() throws { try walk(.openLandscape, .paged) }

    // MARK: The walk

    private func walk(_ posture: Posture, _ mode: Mode) throws {
        try pose(posture)
        launch(mode)
        let at = "\(posture.rawValue), \(mode == .scroll ? "scroll" : "paged")"
        print("FEEL: \(name) window \(app.windows.firstMatch.frame) (\(at))")

        // Reading, with the controls away. Ten seconds, since a look at the reader's tree can take over a second
        // on a loaded runner and the check needs at least three.
        let heads = ["reader.runningHead", "reader.runningHead.book"].filter { el($0).exists }
        check(feel.stillWhileIdle(for: 10, watch: heads), "still while idle, reading", at)
        if heads.isEmpty {
            print("FEEL: \(name) no running head is drawn (\(at)), so none can cover the text")
        } else {
            check(feel.uncovered(by: heads, within: "reader.page"), "the running heads cover no text", at)
        }
        check(feel.insideWindow(poses: [.current], also: ["reader.page"]), "inside the window, reading", at)

        // The controls up: they too must hold still with no touch, and lie inside the window.
        guard controls(up: true, at) else { return }
        check(feel.stillWhileIdle(for: 10), "still while idle, controls up", at)
        check(feel.insideWindow(poses: [.current]), "inside the window, controls up", at)
        guard controls(up: false, at) else { return }

        // Stray input, read a quarter second apart (Feel's default), so a place that jumps away and comes back is
        // still seen. Not the edge swipe, nor in paged mode the swipe across: on a page a swipe turns it, his move.
        var stray: [FeelPlaceStep] = [.strayTap(at: Self.onThePage), .topEdgeTap()]
        if mode == .scroll { stray.append(.swipeAcrossAndBack) }
        stray.append(.background)
        check(feel.placeHeld(across: stray, reads: 8, read: { self.words }), "place kept through stray input", at)
    }

    /// Where a tap lands on the page and not on the open Duo's hinge, which runs down the middle upright and across
    /// it on its side; a tap at the very middle fell in the hinge and the controls never came up (run 43759594068).
    private static let onThePage = CGPoint(x: 0.35, y: 0.35)

    /// A tap on the page, then waits (in reads) until the controls are up, or away; fails if they never
    /// get there, so the checks after it never judge the wrong screen.
    private func controls(up: Bool, _ at: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        app.coordinate(withNormalizedOffset: CGVector(dx: Self.onThePage.x, dy: Self.onThePage.y)).tap()
        let close = el("reader.close")
        let guardUntil = Date().addingTimeInterval(HangGuard.seconds(reads: 40))
        var came = false
        for _ in 0..<40 where Date() < guardUntil {
            if close.exists == up { came = true; break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        if came { RunLoop.current.run(until: Date().addingTimeInterval(1)) }
        judge(came, up ? "the controls come up" : "the controls go away", at,
              "not within 40 reads of a tap on the page", file: file, line: line)
        print("FEEL: \(name) the controls \(up ? "come up" : "go away") (\(at)) \(came ? "passed" : "FAILED")")
        return came
    }

    /// Reds the app still has, each with its issue: `what` and where (`at`) to the issue and whether a pass must fail
    /// (strict). A strict mark fails once the check passes, so the fix removes it here; a mark seen only once is not
    /// strict, so a lucky pass doesn't turn main red. Never a skip.
    private static let known: [String: (issue: String, strict: Bool)] = {
        let headOverText = (issue: "https://github.com/ourostack/gatefold/issues/417", strict: true)
        let noControls = (issue: "https://github.com/ourostack/gatefold/issues/418", strict: true)
        var marks = [
            "the running heads cover no text|closed, scroll": headOverText,
            "the running heads cover no text|open, portrait, scroll": headOverText,
            "the running heads cover no text|open, on its side, scroll": headOverText,
            "still while idle, reading|open, portrait, scroll": (issue: "https://github.com/ourostack/gatefold/issues/419", strict: false),
        ]
        for posture in ["open, portrait", "open, on its side"] {
            for mode in ["scroll", "paged"] { marks["the controls come up|\(posture), \(mode)"] = noControls }
        }
        return marks
    }()

    /// Fails the test on a red, unless it is a known red (``known``), which is expected and named with its issue.
    private func judge(_ passed: Bool, _ what: String, _ at: String, _ detail: String, file: StaticString, line: UInt) {
        guard let mark = Self.known["\(what)|\(at)"] else {
            if !passed { XCTFail("\(what) (\(at)):\n\(detail)", file: file, line: line) }
            return
        }
        if passed {
            if mark.strict {
                XCTFail("\(what) (\(at)) now passes: remove its mark for \(mark.issue) in FeelReaderUITests.known", file: file, line: line)
            }
            return
        }
        XCTExpectFailure("known: \(mark.issue)") {
            XCTFail("\(what) (\(at)):\n\(detail)", file: file, line: line)
        }
    }

    /// Records the check and fails the test on it, naming where it ran.
    private func check(_ result: FeelResult, _ what: String, _ at: String, file: StaticString = #filePath, line: UInt = #line) {
        feel.record(result, name: "\(what) (\(at))")
        judge(result.passed, what, at, result.text, file: file, line: line)
        print("FEEL: \(name) \(what) (\(at)) \(result.passed ? "passed" : "FAILED")")
    }

    // MARK: Posture, launch and the page

    private func pose(_ posture: Posture) throws {
        guard posture != .closed else { return }
        guard ProcessInfo.processInfo.environment["OURO_DUO_POSTURE_DIR"] != nil else {
            throw XCTSkip("The open Duo needs the hinge: run in the duo-feel-open shard (TEST_RUNNER_OURO_DUO_POSTURE_DIR)")
        }
        let hinge = try OuroDuoHinge()
        self.hinge = hinge
        try hinge.set(.open)
        if posture == .openLandscape {
            try hinge.rotateRight()
            turned = true
        }
    }

    private static let book = "gutenberg-pride-and-prejudice"

    /// A fresh library, signed in to the fake cloud, opened straight into the book at 12% (past its front matter) in `mode`.
    private func launch(_ mode: Mode) {
        app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", Self.book, "-GatefoldGoTo", "0.12",
                               "-GatefoldPageTurn", mode.rawValue]
        app.launch()
        feel = OuroFeel(app)
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        _ = settled()
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var words: String { (el("reader.visibleText").value as? String) ?? "" }
    private var ready: Bool { (el("reader.pageReady").value as? String) == "1" }

    /// The words once the reader says its page is ready and eight reads in a row agree, counted in reads rather than
    /// seconds (a loaded runner reads less often and the rule still holds); at most 240 reads, with HangGuard's wall
    /// time as the guard against a hang.
    @discardableResult
    private func settled() -> String {
        var last = "", same = 0
        let guardUntil = Date().addingTimeInterval(HangGuard.seconds(reads: 240))
        for read in 0..<240 {
            guard Date() < guardUntil else {
                XCTFail("the page never settled: \(read) reads, ready \(ready)")
                break
            }
            let now = words
            same = (now == last && ready && !now.isEmpty) ? same + 1 : 0
            last = now
            if same >= 8 { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return last
    }
}
