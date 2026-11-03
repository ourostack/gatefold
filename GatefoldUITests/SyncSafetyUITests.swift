import XCTest

/// Build 14: what Ari met on his Duo in build 13. A pull-to-refresh that is called off, meets server
/// trouble, or gets a blank listing leaves the shelf and the account alone and never shows raw error
/// text; sign-in gives a gentle word for a mistyped email and lets him peek at the password.
/// Screenshots go to `GATEFOLD_SHOTS` when set (pass `TEST_RUNNER_GATEFOLD_SHOTS`).
@MainActor
final class SyncSafetyUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    /// Words that only ever come from a raw Swift or Foundation error.
    private let rawFragments = ["CancellationError", "operation couldn", "Swift.", "NSURLError", "error 1."]

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["GATEFOLD_SHOTS"] {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func launchShelf(scenario: String) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldFakeScenario", scenario, "-GatefoldTheme", "vellum",
        ]
        app.launch()
        XCTAssertTrue(element("book.gutenberg-moby-dick").waitForExistence(timeout: 30), "the shelf arrived")
        let health = element("library.syncHealth")
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label CONTAINS 'In step'"), evaluatedWith: health)], timeout: 20)
        sleep(1)
    }

    private var bookCount: Int { app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'book.'")).count }

    private func pullToRefresh() {
        let top = app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        top.press(forDuration: 0.1, thenDragTo: app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75)),
                  withVelocity: 600, thenHoldForDuration: 0.4)
        sleep(2)
    }

    private func assertNoRawErrorText(_ context: String) {
        for fragment in rawFragments {
            let raw = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", fragment))
            XCTAssertEqual(raw.count, 0, "\(context): raw error text \"\(fragment)\" on screen")
        }
    }

    private func assertStillSignedIn(_ context: String) {
        XCTAssertEqual(element("library.account").label, "Account, reader@example.com", "\(context): the avatar keeps his account")
    }

    func testACancelledRefreshShowsNothingAndKeepsTheShelf() {
        launchShelf(scenario: "cancelledOnRefresh")
        let before = bookCount
        assertStillSignedIn("before")
        pullToRefresh()
        assertNoRawErrorText("after a cancelled refresh")
        XCTAssertFalse(element("library.syncTrouble").exists, "a cancelled refresh is not trouble")
        XCTAssertEqual(bookCount, before, "no book left the shelf")
        assertStillSignedIn("after")
        shot("sync-01-cancelled-refresh-quiet")
    }

    func testServerTroubleIsSaidKindlyWithATryAgain() {
        launchShelf(scenario: "serverTroubleOnRefresh")
        let before = bookCount
        pullToRefresh()
        let trouble = element("library.syncTrouble")
        XCTAssertTrue(trouble.waitForExistence(timeout: 10))
        XCTAssertTrue(trouble.label.contains("PocketBook Cloud is having a little lie-down"), trouble.label)
        XCTAssertTrue(element("library.syncRetry").exists, "a way to try again")
        assertNoRawErrorText("server trouble")
        XCTAssertEqual(bookCount, before, "no book left the shelf")
        assertStillSignedIn("server trouble")
        shot("sync-02-server-trouble-friendly")
    }

    func testABlankListingOnRefreshKeepsTheShelf() {
        launchShelf(scenario: "emptyOnRefresh")
        let before = bookCount
        pullToRefresh()
        XCTAssertTrue(element("book.gutenberg-moby-dick").exists)
        XCTAssertEqual(bookCount, before, "a blank listing is asked again, and the books stay")
        XCTAssertFalse(element("library.empty").exists)
        assertStillSignedIn("blank listing")
        shot("sync-03-blank-listing-shelf-kept")
    }

    /// The simulator's password AutoFill bar sometimes lowers and raises the keyboard just after typing in a
    /// `.password` field, moving the layout under a waiting tap; let it land before the next tap.
    private func settleKeyboard() {
        sleep(2)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5), "the keyboard is up")
        sleep(1)
    }

    func testSignInHintsAtAMistypedEmailAndShowsThePassword() {
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldNoLatency", "YES"]
        app.launch()
        let signIn = element("welcome.signIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 20))
        signIn.tap()

        // His typo, exactly: the button says nothing and spins forever in build 13.
        let email = element("signIn.email")
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText("ari@mendelow@me")
        let hint = element("signIn.emailHint")
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "a gentle word appears once he pauses")
        XCTAssertTrue(hint.label.contains("One @ is plenty"), hint.label)
        element("signIn.continue").tap()
        sleep(1)
        XCTAssertEqual(app.activityIndicators.count, 0, "an email that can't be one is never sent, so nothing spins")
        XCTAssertFalse(element("signIn.password").exists, "still on the email step")
        shot("signin-01-email-hint")

        // Fix it: the hint leaves as soon as the address is fine.
        // Tap past the end of the text so the caret lands after the last character.
        email.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        email.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 24))
        email.typeText("ari@mendelow.me")
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
        XCTAssertEqual(email.value as? String, "ari@mendelow.me")
        element("signIn.continue").tap()
        let store = element("signIn.store.pbookde")
        XCTAssertTrue(store.waitForExistence(timeout: 10))
        store.tap()

        let password = element("signIn.password")
        XCTAssertTrue(password.waitForExistence(timeout: 10))
        sleep(1)
        password.tap()
        password.typeText("hunter2")
        settleKeyboard()
        let reveal = element("signIn.revealPassword")
        XCTAssertEqual(reveal.label, "Show password")
        XCTAssertEqual((password.value as? String)?.count, 7)
        XCTAssertNotEqual(password.value as? String, "hunter2", "hidden at first")

        reveal.tap()
        settleKeyboard()
        XCTAssertEqual(reveal.label, "Hide password")
        XCTAssertEqual(password.value as? String, "hunter2", "shown")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: focus kept")
        app.typeText("x")
        XCTAssertEqual(password.value as? String, "hunter2x", "typing carries on where it was")
        settleKeyboard()
        shot("signin-02-password-shown")

        reveal.tap()
        settleKeyboard()
        XCTAssertEqual(reveal.label, "Show password")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "the keyboard stays up: focus kept")
        app.typeText("y")
        XCTAssertEqual((password.value as? String)?.count, 9, "hiding again keeps every character (no secure-field wipe)")
        settleKeyboard()
        // After hiding again, simulator screen captures blank the secure field and its keyboard; the value
        // check above is the proof that every character is still there.
        shot("signin-03-password-hidden")
    }
}
