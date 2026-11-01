import XCTest

/// Drives the reader slowly for screen recordings (page curl, posture changes). Not an assertion
/// suite: run it on its own with `-only-testing:GatefoldUITests/DemoUITests` while recording.
@MainActor
final class DemoUITests: XCTestCase {
    func testCurlDemo() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
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
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        sleep(3)
    }
}
