import XCTest

/// After a wrong password the Password step keeps its layout: Back stays on the screen and answers a
/// tap, keyboard up or down (build 14 left it half above the screen, dead). The error goes once the
/// password is edited.
@MainActor
final class SignInErrorUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func toPassword() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldNoLatency", "YES"]
        app.launch()
        let start = app.buttons["welcome.signIn"]
        XCTAssertTrue(start.waitForExistence(timeout: 30))
        start.tap()
        let email = app.textFields["signIn.email"]
        XCTAssertTrue(email.waitForExistence(timeout: 15))
        email.tap()
        email.typeText("reader@example.com")
        app.buttons["signIn.continue"].tap()
        let store = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'signIn.store.'")).firstMatch
        if store.waitForExistence(timeout: 5) { store.tap() }
        XCTAssertTrue(app.secureTextFields.firstMatch.waitForExistence(timeout: 15), "the Password step")
        sleep(1)
        return app
    }

    private func failOnce(_ app: XCUIApplication) {
        let field = app.secureTextFields.firstMatch
        field.tap()
        field.typeText("wrong")
        app.buttons["signIn.continue"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["signIn.error"].waitForExistence(timeout: 15), "the wrong-password word")
        sleep(1)
    }

    private func expectBackInReach(_ app: XCUIApplication, _ what: String) {
        let back = app.buttons["signIn.back"]
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(back.exists, what)
        XCTAssertGreaterThanOrEqual(back.frame.minY, window.minY, "\(what): Back is on the screen (\(back.frame))")
        XCTAssertTrue(back.isHittable, "\(what): Back answers a tap (\(back.frame))")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = what
        shot.lifetime = .keepAlways
        add(shot)
    }

    func testBackStaysInReachAfterAWrongPassword() {
        let app = toPassword()
        failOnce(app)
        expectBackInReach(app, "after-wrong-password-keyboard-up")
        // Keyboard down: the field let go.
        app.staticTexts["Password"].firstMatch.tap()
        sleep(1)
        expectBackInReach(app, "after-wrong-password-keyboard-down")
        app.buttons["signIn.back"].tap()
        // Back steps to the store choice (two stores answered for this address) or the email.
        let previous = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'signIn.store.'")).firstMatch
        XCTAssertTrue(previous.waitForExistence(timeout: 10) || app.textFields["signIn.email"].exists, "Back went back a step")
        XCTAssertFalse(app.secureTextFields.firstMatch.exists, "the Password step has gone")
    }

    func testTheErrorGoesOnceThePasswordChanges() {
        let app = toPassword()
        failOnce(app)
        let field = app.secureTextFields.firstMatch
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertTrue(app.descendants(matching: .any)["signIn.error"].waitForNonExistence(timeout: 5), "cleared, the error goes")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "error-cleared"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
