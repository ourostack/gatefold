import XCTest

/// Drives the reader slowly for screen recordings (page curl, posture changes). Not an assertion
/// suite: run it on its own with `-only-testing:GatefoldUITests/DemoUITests` while recording.
@MainActor
final class DemoUITests: XCTestCase {
    func testCurlDemo() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "vellum",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == 'ready 0'"), evaluatedWith: probe)], timeout: 90)
        sleep(2)
        // A slow, deliberate lift from the lower right corner, then a release that completes the turn.
        let start = page.coordinate(withNormalizedOffset: CGVector(dx: 0.96, dy: 0.86))
        start.press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.7)), withVelocity: 260, thenHoldForDuration: 0.6)
        sleep(2)
        // A quick flick forward.
        start.press(forDuration: 0.02, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8)), withVelocity: 1400, thenHoldForDuration: 0)
        sleep(2)
        // A backward turn from the left edge.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.04, dy: 0.5)).press(forDuration: 0.05, thenDragTo: page.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.55)), withVelocity: 500, thenHoldForDuration: 0.2)
        sleep(2)
        // Taps on the edge turn too.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        sleep(3)
    }

    /// The library at a glance: the shelf arrives, the sync line settles on "In step", and a
    /// relaunch puts the cached shelf back at once, without an empty or dusting shelf in between.
    func testShelfDemo() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldTheme", "vellum",
        ]
        app.launch()
        let health = app.descendants(matching: .any)["library.syncHealth"]
        XCTAssertTrue(health.waitForExistence(timeout: 30))
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'In step'"), evaluatedWith: health)], timeout: 30)
        XCTAssertTrue(health.label.contains("In step with your e-reader"), health.label)
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 10))
        sleep(2)

        app.quit()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES", "-GatefoldTheme", "vellum",
        ]
        app.relaunch()
        XCTAssertTrue(app.staticTexts["Moby-Dick"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["library.empty"].exists, "a cached shelf never shows as empty")
        XCTAssertFalse(app.descendants(matching: .any)["library.dusting"].exists, "a cached shelf never waits on the fetch")
        sleep(2)
    }
}
