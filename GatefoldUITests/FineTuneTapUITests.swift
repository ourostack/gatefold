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

    private func openFineTune() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        sleep(3)
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

    /// Changed once: it moved off its old value and, a moment later, hasn't moved back.
    private func assertChangedOnce(_ toggle: XCUIElement, from before: String, _ what: String) {
        let up = Date().addingTimeInterval(2)
        while value(toggle) == before, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        XCTAssertNotEqual(value(toggle), before, what)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertNotEqual(value(toggle), before, "\(what), and stays changed")
    }

    private func quickTouches() {
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        for id in switches {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
            for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
            for i in 0..<4 {
                let before = value(toggle)
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
    private func tapRate(landscape: Bool) {
        // The app's window, not the runner's device: that's where the taps land.
        let frame = app.windows.firstMatch.frame
        let shown = frame.width > frame.height ? "landscape" : "portrait"
        // The Duo opened out is near square whichever way up it is, so only the iPad's shape says.
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertEqual(shown, landscape ? "landscape" : "portrait", "the window is the way it was turned")
        }
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        var trials = 0, misses = 0
        for id in switches {
            let toggle = app.switches[id].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 10), id)
            for _ in 0..<4 where !toggle.isHittable { panel.swipeUp() }
            for _ in 0..<25 {
                let before = value(toggle)
                toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
                RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                trials += 1
                if value(toggle) == before { misses += 1; print("TAPRATE miss on \(id) at trial \(trials)") }
            }
        }
        print("TAPRATE \(shown) trials=\(trials) misses=\(misses)")
        XCTAssertEqual(misses, 0, "every one of \(trials) taps flipped its switch")
    }

    func testEveryTapFlipsItsSwitchPortrait() {
        openFineTune()
        tapRate(landscape: false)
    }

    func testEveryTapFlipsItsSwitchLandscape() {
        XCUIDevice.shared.orientation = .landscapeLeft
        openFineTune()
        tapRate(landscape: true)
    }

    /// The whole row is the control: a tap on its name changes the switch too.
    func testATapOnTheRowsNameChangesItsSwitch() {
        openFineTune()
        let toggle = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        let before = value(toggle)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        assertChangedOnce(toggle, from: before, "a tap on the row's name changes it")
    }
}
