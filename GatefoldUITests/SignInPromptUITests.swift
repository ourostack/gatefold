import XCTest

/// Ari, build 53: the Cloud wanted him to sign in again while he read, only the shelf said so, and his place never
/// reached the InkPad. The reader says it too: one tap to sign in, his email filled in, and the slip is gone once he has.
@MainActor
final class SignInPromptUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Opens a book and turns a page: the Cloud turns the place away (fetched or sent) and wants him to sign in again.
    private func readUntilTheCloudAsks() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldFakeScenario", "expiresWhileReading", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-alice-in-wonderland", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "slide",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        sleep(3)
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        return app
    }

    func testTheReaderAsksToSignInAgainAndOneTapOpensSignIn() {
        let app = readUntilTheCloudAsks()
        let slip = app.descendants(matching: .any)["reader.signInSlip"]
        XCTAssertTrue(slip.waitForExistence(timeout: 30), "the reader asks him to sign in again")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "reader-sign-in-slip"
        shot.lifetime = .keepAlways
        add(shot)
        let signIn = app.buttons["reader.signIn"]
        XCTAssertTrue(signIn.isHittable, "Sign In answers a tap")
        signIn.tap()
        let email = app.textFields["signIn.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15) || app.secureTextFields.firstMatch.waitForExistence(timeout: 5), "sign-in opened")
        let sheet = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        sheet.name = "reader-sign-in-sheet"
        sheet.lifetime = .keepAlways
        add(sheet)
    }

    func testLaterPutsTheSlipAwayForThisOpen() {
        let app = readUntilTheCloudAsks()
        let slip = app.descendants(matching: .any)["reader.signInSlip"]
        XCTAssertTrue(slip.waitForExistence(timeout: 30))
        app.buttons["reader.signInLater"].tap()
        XCTAssertTrue(slip.waitForNonExistence(timeout: 10), "Later puts it away")
    }
}
