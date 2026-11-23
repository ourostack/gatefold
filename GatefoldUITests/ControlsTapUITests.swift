import XCTest

/// He taps the middle of the page to bring the controls up, then taps Contents as soon as it shows, and Contents opens
/// (gatefold#614). On main's App run 45108945628 that tap reached the page under the controls instead: the app logged
/// "tap: middle at x 594 of 900, controls true", 1.2 s after the controls came up, and put them down, so Contents never
/// opened. Each try taps for the controls, waits for Contents to show and be hittable, as XCTest judges it, taps it, and
/// counts what happened: Contents opened, the controls went down, or neither, and where Contents stood when tapped. The
/// first show after a launch is counted apart from the later ones: on a first show the bottom bar stood up to 24 points
/// low and then stepped up into place (Ouro HX placed it by a height it had not yet measured; ouro-ui-apple#281), on 4
/// of 8 first shows on the iPad and 5 of 8 on the Duo in probe run 45125426107. That x is Contents's own (it stands at
/// x 660 on the iPad's screen, the page starting at 66). `GATEFOLD_PROBE_LAUNCHES` and `GATEFOLD_PROBE_SHOWS` (as
/// `TEST_RUNNER_` variables) raise the tries for a probe run. Judged in reads, never seconds; `HangGuard` only catches
/// a hang.
@MainActor
final class ControlsTapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() { app.terminate() }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES",
    ]

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private var contents: XCUIElement { el("reader.contents") }
    /// The Contents list's chapter rows, his current one included.
    private var contentsRows: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ OR identifier BEGINSWITH %@", "contents.current", "contents.entry."))
    }

    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { hung = true; XCTFail("hang: a wait ran \(read) of its \(reads) reads past its hang guard"); return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, reads)
    }

    private func env(_ name: String, _ fallback: Int) -> Int {
        ProcessInfo.processInfo.environment[name].flatMap(Int.init) ?? fallback
    }

    private func open() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
            + (ProcessInfo.processInfo.environment["GATEFOLD_POSTURE"].map { ["-GatefoldForcePosture", $0] } ?? [])
        app.launch()
        XCTAssertNotNil(ReaderReads.opened(app, "the book") { print("CONTROLSTAP \($0)") }, "the book opened")
        XCTAssertFalse(ReaderReads.settle(app, "the opened page") { print("CONTROLSTAP \($0)") }.words.isEmpty, "the opened page showed words")
    }

    private enum Outcome: String { case opened, down, neither }

    /// One try: the controls down, a tap in the middle of the page, Contents tapped once it shows, and what came of it,
    /// with where Contents stood when it was tapped.
    private func tryOnce(_ name: String) -> (outcome: Outcome, y: Int?) {
        // Start from the page alone: the controls down, nothing over it.
        if contents.exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            XCTAssertTrue(readsUntil(reads: 50) { !contents.exists }.ok, "\(name): the controls went down before the try")
        }
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // As PlaceUndoUITests' showChrome waits before it taps Contents: there and hittable.
        let shown = readsUntil(reads: 50) { contents.exists && contents.isHittable }
        guard shown.ok else {
            XCTFail("\(name): a tap in the middle brought up the controls")
            return (.neither, nil)
        }
        let frame = contents.frame
        contents.tap()
        let up = readsUntil(reads: 60) { contentsRows.firstMatch.exists || !contents.exists }
        let outcome: Outcome = contentsRows.firstMatch.exists ? .opened : !contents.exists ? .down : .neither
        print("CONTROLSTAP \(name): \(outcome.rawValue) after \(shown.reads) reads for the controls, \(up.reads) after the tap; Contents at x \(Int(frame.midX)) y \(Int(frame.midY))")
        if outcome == .opened {
            el("contents.close").tap()
            XCTAssertTrue(readsUntil(reads: 60) { !contentsRows.firstMatch.exists }.ok, "\(name): Contents closed")
        }
        return (outcome, Int(frame.midY.rounded()))
    }

    func testContentsOpensWhenTappedAsTheControlsComeUp() {
        let launches = env("GATEFOLD_PROBE_LAUNCHES", 3), shows = env("GATEFOLD_PROBE_SHOWS", 2)
        var first: [Outcome: Int] = [:], later: [Outcome: Int] = [:]
        // Where Contents stood when tapped, first shows apart: on a first show it stood up to 24 points low and then
        // stepped up into place (probe run 45125426107), and a tap where it had shown reached the page.
        var firstYs: [Int] = [], laterYs: [Int] = []
        for launch in 1...launches {
            open()
            for show in 1...shows {
                let (outcome, y) = tryOnce("launch \(launch) show \(show)")
                if show == 1 { first[outcome, default: 0] += 1 } else { later[outcome, default: 0] += 1 }
                if let y { if show == 1 { firstYs.append(y) } else { laterYs.append(y) } }
                if hung { break }
            }
            app.terminate()
            if hung { break }
        }
        func counts(_ c: [Outcome: Int]) -> String { "opened \(c[.opened] ?? 0), down \(c[.down] ?? 0), neither \(c[.neither] ?? 0)" }
        // Its resting place: where it stood most often.
        let ys = firstYs + laterYs
        let resting = Dictionary(grouping: ys, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        func offRest(_ ys: [Int]) -> Int { ys.filter { y in resting.map { abs(y - $0) > 1 } ?? false }.count }
        print("CONTROLSTAP counts: first show after a launch \(counts(first)); later shows \(counts(later))")
        print("CONTROLSTAP placement: resting at y \(resting.map(String.init) ?? "-"); off it on \(offRest(firstYs)) of \(firstYs.count) first shows \(firstYs), \(offRest(laterYs)) of \(laterYs.count) later shows")
        let missed = first.merging(later, uniquingKeysWith: +).filter { $0.key != .opened }.values.reduce(0, +)
        XCTAssertEqual(missed, 0, "Contents opened on every tap (first shows \(counts(first)); later \(counts(later)))")
        XCTAssertEqual(offRest(ys), 0, "Contents stood in its place whenever it could be tapped (first shows at \(firstYs), resting \(resting ?? -1))")
    }
}
