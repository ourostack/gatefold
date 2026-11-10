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
    /// Only a hang guard, not the bar: reads so slow that `landReads` of them take over 3 minutes. (A single
    /// read that never returns is ended by XCTest's own query timeout.)
    private static let hangGuard: TimeInterval = 180

    /// Reads until the value is a real one other than `before`, or `landReads` run out (or the hang guard).
    private func readsUntilChanged(_ toggle: XCUIElement, from before: String)
        -> (changed: Bool, reads: Int, hung: Bool) {
        let hung = Date().addingTimeInterval(Self.hangGuard)
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
    private func assertChangedOnce(_ toggle: XCUIElement, from before: String, _ what: String) {
        let (changed, reads, hung) = readsUntilChanged(toggle, from: before)
        print("TAPRATE \(what): changed=\(changed) after \(reads) reads\(hung ? " (hang guard)" : "")")
        XCTAssertTrue(changed, hung ? "\(what): the hang guard ran out after \(reads) reads"
                                    : "\(what) (no change in \(reads) reads)")
        guard changed else { return }
        let back = readsBack(toggle, to: before)
        XCTAssertEqual(back, 0, "\(what), and stays changed (back on \(back) of \(Self.stayReads) reads)")
    }

    private func quickTouches() {
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        for id in switches {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
            for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
            for i in 0..<4 {
                let before = valueBefore(toggle, "a quick touch on \(id) (\(i))")
                toggle.press(forDuration: 0)
                assertChangedOnce(toggle, from: before, "a quick touch on \(id) changes it (\(i))")
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
    /// 25 on each of the four switches, no retry, every tap counted.
    private func tapRate(_ shown: String) {
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        var trials = 0, misses = 0
        for id in switches {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
            for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
            for _ in 0..<25 {
                let before = valueBefore(toggle, "a tap on \(id)")
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                trials += 1
                let (changed, reads, hung) = readsUntilChanged(toggle, from: before)
                if !changed {
                    misses += 1
                    print("TAPRATE miss on \(id) at trial \(trials) (no change in \(reads) reads\(hung ? ", hang guard" : ""))")
                } else if readsBack(toggle, to: before) > 0 {
                    // Changed twice: as much a miss as no change, as the old 1 s wait then one read counted it.
                    misses += 1
                    print("TAPRATE miss on \(id) at trial \(trials) (changed, then back)")
                }
            }
        }
        print("TAPRATE \(shown) trials=\(trials) misses=\(misses)")
        XCTAssertEqual(misses, 0, "every one of \(trials) taps flipped its switch")
    }

    func testEveryTapFlipsItsSwitchPortrait() {
        openFineTune()
        tapRate("portrait")
    }

    /// Turned for real: the app's window (where the taps land, not the runner's idea of the device)
    /// swaps its width and height. The opened-out Duo is near square, so its shape alone can't say.
    func testEveryTapFlipsItsSwitchLandscape() throws {
        launchReader()
        let upright = app.windows.firstMatch.frame
        XCUIDevice.shared.orientation = .landscapeLeft
        let up = Date().addingTimeInterval(10)
        while app.windows.firstMatch.frame.size == upright.size, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.25)) }
        sleep(3)
        let turned = app.windows.firstMatch.frame
        print("TAPRATE window upright=\(upright.size) turned=\(turned.size)")
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
        openFineTune(launching: false)
        tapRate("landscape")
    }

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
