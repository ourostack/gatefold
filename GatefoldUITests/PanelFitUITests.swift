import XCTest

/// Your Page fits a short screen (an iPhone on its side, the folded Duo's cover screen): Close stays
/// on screen and the panel's last control can be reached, scrolling if it has to.
@MainActor
final class PanelFitUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    func testPanelFitsLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldSheet", "appearance",
        ]
        app.launch()
        let close = app.buttons["appearance.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 60), "the panel opened")
        sleep(2)
        let window = app.windows.firstMatch.frame
        let panel = app.descendants(matching: .any)["appearance.panel"].firstMatch
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "panel-landscape"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertGreaterThanOrEqual(panel.frame.minY, window.minY, "the panel's top is on screen (\(panel.frame) in \(window))")
        XCTAssertLessThanOrEqual(panel.frame.maxY, window.maxY, "the panel's bottom is on screen (\(panel.frame) in \(window))")
        XCTAssertTrue(close.isHittable, "Close is in reach")
        let fineTune = app.buttons["Fine-Tune"].firstMatch
        if !fineTune.isHittable { panel.swipeUp() }
        XCTAssertTrue(fineTune.isHittable, "Fine-Tune can be reached")
        let after = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); after.name = "panel-landscape-scrolled"; after.lifetime = .keepAlways; add(after)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5), "Close closes the panel")
    }
}
