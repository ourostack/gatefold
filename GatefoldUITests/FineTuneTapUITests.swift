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
    private func tapRate(_ shown: String) {
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
        let before = value(toggle)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5)).tap()
        assertChangedOnce(toggle, from: before, "a tap on the row's name changes it")
    }

    /// A tap or a swipe on the page beside the Appearance panel puts it away, as any overlay goes, and never reaches
    /// the page beneath: the words stay and the controls stay up (gatefold#62, seen on the folded Duo and the iPad).
    func testATapBesideAppearancePutsItAwayAndLeavesThePage() {
        launchReader()
        let page = app.descendants(matching: .any)["reader.page"]
        let words = { (self.app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }
        // Taps and swipes, each the turn's way: a swipe that reached the page would turn it.
        for (round, how) in ["a tap", "a swipe forward", "a tap", "a swipe back"].enumerated() {
            for _ in 0..<4 where !app.buttons["reader.appearance"].waitForExistence(timeout: 5) {
                page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
            app.buttons["reader.appearance"].tap()
            let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
            XCTAssertTrue(panel.waitForExistence(timeout: 10), "Appearance opened (\(round))")
            sleep(1)
            let before = words()
            XCTAssertFalse(before.isEmpty, "the page reports its words before \(how) (\(round))")
            // Between the top bar and the panel, clear of both.
            let barFoot = max(app.buttons["reader.close"].frame.maxY, page.frame.minY)
            let gap = panel.frame.minY - barFoot
            guard gap > 60 else { XCTFail("no page between the bar (\(barFoot)) and the panel (\(panel.frame.minY))"); return }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let y = barFoot + gap / 2, f = page.frame
            switch how {
            case "a tap":
                origin.withOffset(CGVector(dx: f.midX, dy: y)).tap()
            case "a swipe forward":
                origin.withOffset(CGVector(dx: f.minX + f.width * 0.85, dy: y))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: f.minX + f.width * 0.15, dy: y)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            default:
                origin.withOffset(CGVector(dx: f.minX + f.width * 0.15, dy: y))
                    .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: f.minX + f.width * 0.85, dy: y)),
                           withVelocity: .fast, thenHoldForDuration: 0)
            }
            XCTAssertTrue(panel.waitForNonExistence(timeout: 5), "\(how) beside Appearance put it away (\(round))")
            // A touch that reached the page would also have put the controls down.
            XCTAssertTrue(app.buttons["reader.close"].exists, "\(how) beside Appearance left the controls up (\(round))")
            sleep(2)
            XCTAssertTrue(words() == before, "\(how) beside Appearance left the page as it was (\(round))")
            if panel.exists, app.buttons["appearance.close"].exists { app.buttons["appearance.close"].tap() }
        }
    }
}
