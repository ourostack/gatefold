import XCTest

/// The catch-up tab ("InkPad +56") hangs in the page's top margin, where the status bar prints. With
/// the reader's chrome up, build 14 on the iPad printed the time and date over it. The status bar
/// stays hidden while the tab is up, as Apple Books keeps its page top clear.
@MainActor
final class CatchUpTabUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheStatusBarNeverPrintsOverTheCatchUpTab() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "slide",
            // The InkPad reads on once the page has settled: the Duo takes about 4.5 s to its first
            // page, and the debug jump's own save, newer than an earlier read, would hide the offer.
            "-GatefoldRemoteAheadAfter", "12", "-GatefoldRemoteAheadTo", "0.4",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        XCTAssertTrue(app.descendants(matching: .any)["banner"].waitForExistence(timeout: 60), "the InkPad's place was offered")
        // Reading on folds the offer into its tab.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
        let tab = app.descendants(matching: .any)["banner.tab"]
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "the catch-up tab is up")
        let statusBar = app.descendants(matching: .any)["reader.statusBar"]
        sleep(1)
        XCTAssertEqual(statusBar.label, "hidden", "reading, the status bar is hidden")
        // The chrome comes up; the status bar still keeps off the tab.
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.close"].firstMatch.waitForExistence(timeout: 10) || app.descendants(matching: .any)["reader.close"].waitForExistence(timeout: 5), "the chrome is up")
        sleep(1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "catch-up-tab-with-chrome"
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertTrue(tab.exists, "the tab is still up")
        XCTAssertEqual(statusBar.label, "hidden", "with the chrome up and the tab showing, the status bar stays hidden")
    }
}
