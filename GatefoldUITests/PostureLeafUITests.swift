import XCTest

/// A change of posture re-lays out the page where it is (Ari, 2026-11-27). Unfolding the Duo from half open to flat
/// played the unfold's leaf over the page, even in scroll mode: a grey page-curl wedge that rose and stood frozen
/// over a white page. Only the book opening from its cover, or shutting back to it, plays a leaf, and only on a page
/// of pages (`PostureLeaf`).
///
/// The check counts the leaves a change of posture plays (`reader.postureLeaves`) and waits for the new posture's
/// reflow to settle (`reader.anchorCheck`), in reads, never seconds. An upright screen never lays out a spread
/// (gatefold#303), and the folded Duo's cover is too narrow for one, so the iPad walks the postures on its side, as
/// `PositionUITests.testEveryPostureKeepsThePlace` does; a forced posture counts as a device with a fold.
@MainActor
final class PostureLeafUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Half open to flat and back, on a page of pages: no leaf either way.
    func testHalfOpenToFlatPlaysNoLeaf() throws {
        try walk(pageTurn: "curl", from: "tabletop", through: ["spread", "tabletop", "spread"], leaves: 0)
    }

    /// Scroll mode: no posture change plays a leaf, the book opening from its cover included.
    func testScrollModeChangesPostureWithNoLeaf() throws {
        try walk(pageTurn: "scroll", from: "single", through: ["spread", "tabletop", "spread", "single"], leaves: 0)
    }

    /// The book opening and shutting on a page of pages still plays its two leaves, so the count above is a count.
    func testOpeningAndShuttingTheBookPlaysItsLeaves() throws {
        try walk(pageTurn: "curl", from: "single", through: ["spread", "single"], leaves: 2)
    }

    /// Turning a device with a fold on its side and back: the spread becomes one page and comes back, laid out again
    /// where it is, with no leaf, because nothing opened or shut (Ari, 2026-11-27: nothing moves that he didn't move).
    /// On the Duo's inner screen a turn took the spread to one page and back, and played the fold's leaf and then the
    /// unfold's. The forced spread stands for the open Duo; upright, it can't fit, so it lays out one page.
    func testTurningTheDevicePlaysNoLeaf() throws {
        try walk(pageTurn: "curl", from: "spread", through: ["turn:portrait", "turn:landscapeLeft"], leaves: 0)
    }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private var hung = false
    private func readsUntil(reads: Int, _ done: () -> Bool) -> (ok: Bool, reads: Int) {
        if hung { return (false, 0) }
        let guardEnds = Date().addingTimeInterval(HangGuard.seconds(reads: reads))
        for read in 1...reads {
            if done() { return (true, read) }
            if Date() > guardEnds { hung = true; return (false, read) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return (false, reads)
    }

    private var leaves: Int { Int((el("reader.postureLeaves").value as? String) ?? "") ?? -1 }
    private var anchor: String { el("reader.anchorCheck").label }

    /// The posture's reflow has settled: the anchor check reads a verdict for a newer reflow than `after`, the same
    /// five reads running.
    private func settled(after reflow: Int, _ step: String) {
        var last = "", same = 0
        let done = readsUntil(reads: 240) {
            let now = anchor
            let number = Int(now.split(separator: " ").last ?? "") ?? 0
            same = now == last && number > reflow && !now.hasPrefix("settling") ? same + 1 : 0
            last = now
            return same >= 5
        }
        XCTAssertTrue(done.ok, "\(step): the page re-laid out and settled within \(done.reads) reads (\(last))")
    }

    private func reflowNumber() -> Int { Int(anchor.split(separator: " ").last ?? "") ?? 0 }

    private func walk(pageTurn: String, from start: String, through postures: [String], leaves expected: Int) throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31", "-GatefoldTheme", "daylight",
            "-GatefoldPageTurn", pageTurn, "-GatefoldForcePosture", start, "-GatefoldPostureSwitches", "YES",
        ]
        app.launch()
        let size = app.windows.firstMatch.frame.size
        try XCTSkipIf(size.width < 700 || size.width <= size.height,
                      "a \(Int(size.width)) x \(Int(size.height)) pt screen can't show a spread; the Real unfold workflow moves the Duo's hinge")
        let ready = readsUntil(reads: 360) { anchor.hasPrefix("ready ") || anchor.hasPrefix("anchor-visible ") }
        XCTAssertTrue(ready.ok, "the book opened in \(start) (\(ready.reads) reads, \(anchor))")
        let before = leaves
        XCTAssertEqual(before, 0, "the book opened with no leaf played (\(pageTurn))")
        var from = start
        for step in postures {
            let reflow = reflowNumber()
            let posture: String
            switch step {
            case "turn:portrait":
                XCUIDevice.shared.orientation = .portrait
                posture = "single"
            case "turn:landscapeLeft":
                XCUIDevice.shared.orientation = .landscapeLeft
                posture = start
            default:
                app.buttons["debug.posture.\(step)"].tap()
                posture = step
            }
            let shown = readsUntil(reads: 80) { el("reader.posture").label == posture }
            XCTAssertTrue(shown.ok, "\(from) to \(posture): the reader shows \(posture) (\(el("reader.posture").label))")
            let moving = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            moving.name = "\(name)-\(from)-to-\(posture)-moving"
            moving.lifetime = .keepAlways
            add(moving)
            settled(after: reflow, "\(from) to \(posture), \(pageTurn)")
            if step.hasPrefix("turn:") {
                // Every frame from the turn until its new layout is shown is a whole page (gatefold#537, #648): the
                // app judges each one (`reader.turnFrames`), as `RotationFrameUITests` does on the iPad.
                func turnFrames() -> String { (el("reader.turnFrames").value as? String) ?? "" }
                let judged = readsUntil(reads: 200) { turnFrames().contains("broken") }
                let verdict = turnFrames()
                print("TURNFRAMES \(from) to \(posture): \(verdict)")
                XCTAssertTrue(judged.ok && verdict.hasPrefix("0 broken of ") && !verdict.contains("("),
                              "\(step) from \(from): frames that weren't a whole page: \(verdict)")
            }
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "\(name)-\(from)-to-\(posture)"
            shot.lifetime = .keepAlways
            add(shot)
            from = posture
        }
        print("POSTURELEAVES \(pageTurn) \(start) -> \(postures.joined(separator: " -> ")): \(leaves) leaves")
        XCTAssertEqual(leaves - before, expected,
                       "\(start) -> \(postures.joined(separator: " -> ")) in \(pageTurn) played \(leaves - before) leaves, wanted \(expected)")
    }
}
