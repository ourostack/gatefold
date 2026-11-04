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
        sleep(1)
        // Sign In stays where his finger is: the error leaving moves nothing (build 15 lifted it 56 pt,
        // and a quick tap after retyping missed it).
        let button = app.buttons["signIn.continue"]
        let before = button.frame
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        XCTAssertTrue(app.descendants(matching: .any)["signIn.error"].waitForNonExistence(timeout: 5), "cleared, the error goes")
        sleep(1)
        XCTAssertEqual(button.frame.minY, before.minY, accuracy: 1, "Sign In moved when the error cleared (\(before) → \(button.frame))")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "error-cleared-sign-in-in-place"
        shot.lifetime = .keepAlways
        add(shot)
        // Typing again and tapping Sign In at once (a retry) reaches it: the review's quick tap missed
        // and nothing happened. The fake cloud turns "wrong" down again, so the error comes back.
        field.typeText("wrong")
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(button.frame.maxY, keyboard.frame.minY + 1, "Sign In is above the keyboard, not under it (\(button.frame), keyboard \(keyboard.frame))")
        }
        button.tap()
        XCTAssertTrue(app.descendants(matching: .any)["signIn.error"].waitForExistence(timeout: 10), "the quick retry tap reached Sign In")
    }
}
