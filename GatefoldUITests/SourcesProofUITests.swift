import XCTest

/// Scratch proof for the more-sources PRs (proof branch only, never merged): the empty shelf without an account,
/// the Add menu and the Apple Books guide, each kept as an attachment. Public-domain books only.
@MainActor
final class SourcesProofUITests: XCTestCase {
    private var app: XCUIApplication!

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testCapture() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldReset", "YES", "-GatefoldNoLatency", "YES", "-GatefoldNoWarm", "YES"]
        app.launch()
        XCTAssertTrue(el("library.empty").waitForExistence(timeout: 120))
        sleep(3)
        shot("01-empty-shelf")

        el("library.empty.appleBooks").tap()
        sleep(3)
        shot("02-apple-books-guide")
        if app.buttons["Close"].exists { app.buttons["Close"].tap() } else { app.swipeDown() }
        sleep(2)

        el("library.import").tap()
        sleep(2)
        shot("03-add-menu")
    }
}
