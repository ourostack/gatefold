import UIKit
import XCTest

/// Every tap on a Fine-Tune switch changes it exactly once, every time. Build 18's switches were the
/// system's, which act only on a touch held long enough for their press recognizer to begin: a quick
/// tap (2–11 ms) did nothing, and XCUITest's ordinary tap sometimes lands that short (10 of 72 lost in
/// the build 18 review, on every switch). A zero-length press makes that tap on purpose.
@MainActor
final class FineTuneTapUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private let switches = ["appearance.justify", "appearance.pageNumbers", "appearance.positionLabel", "appearance.pagesLeft"]

    private func launchReader() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        sleep(3)
    }

    private func openFineTune(launching: Bool = true) {
        if launching { launchReader() }
        for _ in 0..<4 where !app.buttons["reader.appearance"].waitForExistence(timeout: 5) {
            app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        app.buttons["reader.appearance"].tap()
        let fineTune = app.buttons["appearance.customize"]
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        if !fineTune.isHittable { app.descendants(matching: .any)["appearance.panel"].firstMatch.swipeUp() }
        fineTune.tap()
        sleep(2)
    }

    private func value(_ e: XCUIElement) -> String { (e.value as? String) ?? "?" }

    /// A switch's change is judged in reads of its value, never seconds (gatefold#119). Each read is a round
    /// trip to the app, so a runner starved by #109 makes every read slower instead of counting a touch that
    /// lands late as one that never landed. A touch that never lands still fails, after `landReads`.
    private static let landReads = 40
    /// Reads after the change in which it must not go back: a touch that changed it twice shows here.
    private static let stayReads = 5
    /// Only a hang guard, not the bar: `HangGuard` sizes it from `landReads` (gatefold#221; a fixed 180 s would trip
    /// after about 10 reads at the slowest read seen, long before the cap). A single read that never returns is
    /// ended by XCTest's own query timeout.

    /// Reads until the value is a real one other than `before`, or `landReads` run out (or the hang guard).
    private func readsUntilChanged(_ toggle: XCUIElement, from before: String)
        -> (changed: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(HangGuard.seconds(reads: Self.landReads))
        for read in 1...Self.landReads {
            let now = value(toggle)
            if now != before, now != "?" { return (true, read, false) }
            if Date() > hung { return (false, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return (false, Self.landReads, false)
    }

    /// Reads, after a change, on which the switch showed its old value again (it changed twice).
    private func readsBack(_ toggle: XCUIElement, to before: String) -> Int {
        var back = 0
        for _ in 0..<Self.stayReads {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if value(toggle) == before { back += 1 }
        }
        return back
    }

    /// The switch's value before a touch: a real one, or the touch is not judged against "?".
    private func valueBefore(_ toggle: XCUIElement, _ what: String) -> String {
        let now = value(toggle)
        XCTAssertNotEqual(now, "?", "\(what): the switch's value can be read before the touch")
        return now
    }

    /// Changed once: it moved off its old value within `landReads`, and in the `stayReads` after it never
    /// moved back.
    /// False when the hang guard ran out: the caller stops there, so one hang doesn't spend the step on the rest.
    @discardableResult
    private func assertChangedOnce(_ toggle: XCUIElement, from before: String, _ what: String) -> Bool {
        let (changed, reads, hung) = readsUntilChanged(toggle, from: before)
        print("TAPRATE \(what): changed=\(changed) after \(reads) reads\(hung ? " (hang guard)" : "")")
        XCTAssertTrue(changed, hung ? "\(what): the hang guard ran out after \(reads) reads"
                                    : "\(what) (no change in \(reads) reads)")
        guard changed else { return !hung }
        let back = readsBack(toggle, to: before)
        XCTAssertEqual(back, 0, "\(what), and stays changed (back on \(back) of \(Self.stayReads) reads)")
        return true
    }

    /// The reflow's number now (0 before any): read before a turn or a touch, so its own reflow can be told from
    /// an older one, which may still read "N settled".
    private func reflowNumber() -> Int {
        let now = (app.descendants(matching: .any)["reader.reflow"].firstMatch.value as? String) ?? ""
        return Int(now.split(separator: " ").first ?? "") ?? 0
    }

    /// Reads until a reflow newer than `before` has settled, its page fully shown (gatefold#175: touches sent
    /// just after a reflow placed its words were lost before they reached the app), or `landReads` run out. A
    /// reflow that never settles is not judged here; the touch after it still is. `expected` false (a switch that
    /// doesn't reflow the book): with no newer reflow begun, it waits only while an older one is still running.
    private func awaitReflowSettled(since before: Int, expected: Bool = true, _ what: String) {
        let reflow = app.descendants(matching: .any)["reader.reflow"].firstMatch
        var now = ""
        for read in 1...Self.landReads {
            now = (reflow.value as? String) ?? ""
            if (Int(now.split(separator: " ").first ?? "") ?? 0) > before {
                if now.hasSuffix("settled") {
                    print("TAPRATE \(what): reflow \(now) after \(read) reads")
                    return
                }
            } else if !expected, now.isEmpty || now.hasSuffix("settled") {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        print("TAPRATE \(what): no newer reflow settled in \(Self.landReads) reads (was \(before), now \(now))")
    }

    private func quickTouches() {
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        for id in switches {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
            for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
            var reflowBefore = 0
            for i in 0..<4 {
                // Touch (0)'s reflow settles before touch (1): XCUITest's synthesizer lost touches sent 0.1 to 0.3 s
                // after a reflow placed its words, and the app's UIApplication.sendEvent never saw them (gatefold#175,
                // runs 42881927745 and 42891025460). Touches (2) and (3) go in while their reflows run.
                if i == 1 { awaitReflowSettled(since: reflowBefore, expected: id == "appearance.justify", "before a quick touch on \(id) (1)") }
                let before = valueBefore(toggle, "a quick touch on \(id) (\(i))")
                if i == 0 { reflowBefore = reflowNumber() }
                toggle.press(forDuration: 0)
                guard assertChangedOnce(toggle, from: before, "a quick touch on \(id) changes it (\(i))") else { return }
            }
        }
    }

    func testAQuickTouchChangesEverySwitchOnce() {
        openFineTune()
        quickTouches()
    }

    /// On its side (a shorter panel, which may take the scrolling branch): a quick touch still lands.
    func testAQuickTouchChangesEverySwitchOnceInLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFineTune()
        quickTouches()
    }

    /// The review's bar: one ordinary tap at the switch's centre, then the switch must have flipped.
    /// 25 on each of the four switches, no retry, every tap counted. Each method below takes one switch's
    /// 25 taps in a row, in one launch, in one posture, so a method fits one CI shard; together they are the
    /// old two methods' 4 x 25 taps in each posture, each judged the same way. One difference, accepted: each
    /// switch now starts on a freshly opened reader, not one still busy from the switches tapped before it.
    /// A tap that reflows the book (Justify) lets its reflow settle before the next tap (gatefold#175): the
    /// switch's value changes before the reflow ends, and on a spread a tap sent as the reflow placed its words
    /// and faded its cover never reached the app (its UIApplication.sendEvent saw nothing).
    private func tapRate(_ shown: String, _ id: String) {
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        var trials = 0, misses = 0
        let toggle = app.switches[id].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
        for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
        for tap in 1...25 {
            let before = valueBefore(toggle, "a tap on \(id)")
            let reflowBefore = reflowNumber()
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            trials += 1
            let (changed, reads, hung) = readsUntilChanged(toggle, from: before)
            if !changed {
                misses += 1
                print("TAPRATE miss on \(id) at tap \(tap) (no change in \(reads) reads\(hung ? ", hang guard" : ""))")
                // A hang ends the method: its other taps would each wait out the guard too.
                if hung { XCTFail("hang: tap \(tap) on \(id) ran \(reads) reads past the hang guard"); break }
            } else if readsBack(toggle, to: before) > 0 {
                // Changed twice: as much a miss as no change, as the old 1 s wait then one read counted it.
                misses += 1
                print("TAPRATE miss on \(id) at tap \(tap) (changed, then back)")
            }
            awaitReflowSettled(since: reflowBefore, expected: id == "appearance.justify", "after tap \(tap) on \(id)")
        }
        print("TAPRATE \(shown) \(id) trials=\(trials) misses=\(misses) hangGuard=\(Int(HangGuard.seconds(reads: Self.landReads))) s, step end \(ProcessInfo.processInfo.environment["GATEFOLD_STEP_UNTIL"] == nil ? "not passed" : "passed")")
        XCTAssertEqual(misses, 0, "every one of \(trials) taps on \(id) flipped its switch")
    }

    private func portrait(_ id: String) {
        openFineTune()
        tapRate("portrait", id)
    }

    /// Reads of the app window's frame for a turn to show (gatefold#224): 40 at 0.25 s, the old 10 s at a quick
    /// read, but counted, so a slow simulator (one look took 18.6 s in #207's green probe, run 42973604069,
    /// job 130368394864) still gets all 40 before the shape is judged.
    private static let turnReads = 40
    /// Reads in a row on which the turned frame must not move before it's judged, in place of a fixed sleep(3).
    private static let holdReads = 3

    /// Reads the window's frame until its size is no longer `upright`'s (up to `turnReads`), then until it
    /// reads the same size `holdReads` times in a row (within `2 * turnReads` in all). No change in `turnReads` is an
    /// answer, not a failure: the folded Duo's cover screen doesn't turn, and the caller decides. Only a hang
    /// guard, sized by `HangGuard` from the most reads this can take.
    private func readsUntilTurned(from upright: CGRect)
        -> (frame: CGRect, turnedAfter: Int?, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(HangGuard.seconds(reads: 2 * Self.turnReads))
        var frame = upright, turnedAfter: Int?, held = 0
        for read in 1...(2 * Self.turnReads) {
            let now = app.windows.firstMatch.frame
            if let at = turnedAfter {
                held = now.size == frame.size ? held + 1 : 0
                frame = now
                if held >= Self.holdReads { return (frame, at, read, false) }
            } else if now.size != upright.size {
                turnedAfter = read; frame = now
            } else if read >= Self.turnReads {
                return (now, nil, read, false)
            }
            if Date() > hung { return (now, turnedAfter, read, true) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        // Turned but never held still for `holdReads`: judged on the last frame, said so in the log.
        print("TAPRATE window turned but still moving after \(2 * Self.turnReads) reads")
        return (frame, turnedAfter, 2 * Self.turnReads, false)
    }

    /// Turned for real: the app's window (where the taps land, not the runner's idea of the device)
    /// swaps its width and height. The opened-out Duo is near square, so its shape alone can't say.
    private func landscape(_ id: String) throws {
        launchReader()
        let upright = app.windows.firstMatch.frame
        let reflowBefore = reflowNumber()
        XCUIDevice.shared.orientation = .landscapeLeft
        let (turned, turnedAfter, reads, hung) = readsUntilTurned(from: upright)
        print("TAPRATE window upright=\(upright.size) turned=\(turned.size) "
              + (turnedAfter.map { "changed after \($0) reads, " } ?? "no change, ")
              + "\(reads) reads in all\(hung ? " (hang guard)" : "")")
        if hung { XCTFail("hang: the window's frame ran \(reads) reads past the hang guard"); return }
        // The folded Duo's cover screen is portrait only (as `PositionUITests` finds); the iPad must turn.
        if turned.size == upright.size, UIDevice.current.userInterfaceIdiom != .pad {
            throw XCTSkip("This display does not rotate (the folded Duo's cover screen is portrait only)")
        }
        if abs(upright.width - upright.height) > 20 {
            XCTAssertEqual(turned.width, upright.height, accuracy: 2, "the window turned: its width is its old height")
            XCTAssertEqual(turned.height, upright.width, accuracy: 2, "and its height its old width")
        } else {
            // A square window looks the same either way round: the turn can't be proved by shape.
            print("TAPRATE window is square: the turn is not provable by its shape")
        }
        // A turn that changes the columns reflows the book, which the window's frame doesn't show.
        awaitReflowSettled(since: reflowBefore, "after the turn")
        openFineTune(launching: false)
        tapRate("landscape", id)
    }

    // Portrait: each switch's 25 taps.
    func testEveryTapFlipsJustifyPortrait() { portrait("appearance.justify") }
    func testEveryTapFlipsPageNumbersPortrait() { portrait("appearance.pageNumbers") }
    func testEveryTapFlipsPositionLabelPortrait() { portrait("appearance.positionLabel") }
    func testEveryTapFlipsPagesLeftPortrait() { portrait("appearance.pagesLeft") }

    // Landscape: the same, turned.
    func testEveryTapFlipsJustifyLandscape() throws { try landscape("appearance.justify") }
    func testEveryTapFlipsPageNumbersLandscape() throws { try landscape("appearance.pageNumbers") }
    func testEveryTapFlipsPositionLabelLandscape() throws { try landscape("appearance.positionLabel") }
    func testEveryTapFlipsPagesLeftLandscape() throws { try landscape("appearance.pagesLeft") }

    /// The whole row is the control: a tap on its name changes the switch too.
    func testATapOnTheRowsNameChangesItsSwitch() {
        openFineTune()
        let toggle = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let before = valueBefore(toggle, "a tap on the row's name")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        assertChangedOnce(toggle, from: before, "a tap on the row's name changes it")
    }
}
