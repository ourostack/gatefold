import XCTest

/// End to end against the real PocketBook Cloud, on a test account. Off unless the runner sets
/// `GATEFOLD_LIVE_EMAIL` (pass `TEST_RUNNER_GATEFOLD_LIVE_EMAIL` to xcodebuild).
///
/// The password never passes through the test: the driver script writes it to a private scratch file
/// and passes only its path (`GATEFOLD_LIVE_CREDENTIAL_FILE`); a DEBUG-only control reads it into the
/// secure field and deletes the file.
/// Run the steps in order; the driver moves the place in PocketBook's web reader between them.
@MainActor
final class LiveSyncUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    /// Frankenstein (Project Gutenberg #84) on test account 1.
    private let frankenstein = "book.56f8619536655be4a1541a40c5702d32"

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipIf(env["GATEFOLD_LIVE_EMAIL"] == nil, "live Cloud tests are opt-in")
        app = XCUIApplication()
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = env["GATEFOLD_SHOTS"] {
            try? XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    private func launch(reset: Bool) {
        app.launchArguments = ["-GatefoldUITest", "YES"] + (reset ? ["-GatefoldReset", "YES"] : [])
        // Only the file's path crosses over; the app reads the secret and deletes the file.
        if let file = env["GATEFOLD_LIVE_CREDENTIAL_FILE"] { app.launchEnvironment["GATEFOLD_LIVE_CREDENTIAL_FILE"] = file }
        app.launch()
    }

    /// Sign in from a clean install, find Frankenstein, download it, read a few pages, close.
    func test1_signInReadAndClose() throws {
        launch(reset: true)
        let signIn = element("welcome.signIn")
        XCTAssertTrue(signIn.waitForExistence(timeout: 20))
        shot("live-01-welcome")
        signIn.tap()

        let email = element("signIn.email")
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap()
        email.typeText(env["GATEFOLD_LIVE_EMAIL"]!)
        shot("live-02-email")
        element("signIn.continue").tap()

        // One store for this email goes straight to the password; several show the picker.
        let password = element("signIn.password")
        let store = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'signIn.store.'")).firstMatch
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline, !password.exists, !store.exists { usleep(250_000) }
        if store.exists {
            shot("live-03-store-picker")
            store.tap()
        }
        XCTAssertTrue(password.waitForExistence(timeout: 15))
        password.tap()
        // The driver left the password in a private file; DEBUG-only code reads it in,
        // so it never appears in the test's log (simctl's pasteboard is broken on Xcode 27.1).
        let fill = element("debug.fillPassword")
        XCTAssertTrue(fill.waitForExistence(timeout: 5))
        XCTAssertEqual(fill.label, "filled", "the app read the driver's credential file")
        shot("live-04-password")
        element("signIn.continue").tap()

        let book = element(frankenstein)
        XCTAssertTrue(book.waitForExistence(timeout: 60), "Frankenstein on the shelf from the Cloud")
        sleep(3) // covers
        shot("live-05-library")
        XCTAssertFalse(element("book.gutenberg-moby-dick").exists, "no demo books on a real account")

        // In the Cloud: the first tap downloads, the next opens.
        book.tap()
        let onDevice = NSPredicate(format: "NOT (value CONTAINS 'Cloud') AND NOT (value CONTAINS 'downloading')")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: onDevice, evaluatedWith: book)], timeout: 120), .completed, "downloaded")
        shot("live-05b-downloaded")
        book.tap()
        let opened = element("reader.page")
        XCTAssertTrue(opened.waitForExistence(timeout: 30))
        waitForSettled()
        shot("live-06-opened")

        for _ in 0..<6 {
            opened.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            sleep(2)
        }
        waitForSettled()
        let words = element("reader.visibleText").value as? String ?? ""
        print("LIVE gatefold page: \(words.prefix(160))")
        shot("live-07-after-turning")
        close()
        sleep(4) // the service sends the place on close
        shot("live-08-closed")
    }

    /// The web reader moved the place (driver step); reopening offers the jump and lands on that passage.
    func test2_reopenOffersTheJump() throws {
        let expected = try XCTUnwrap(env["GATEFOLD_LIVE_EXPECT_TEXT"], "the web reader's first words")
        launch(reset: false)
        let book = element(frankenstein)
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        XCTAssertTrue(element("reader.page").waitForExistence(timeout: 30))
        let banner = element("banner")
        XCTAssertTrue(banner.waitForExistence(timeout: 60), "the further-ahead banner")
        sleep(1)
        shot("live-09-banner")
        element("banner.jump").tap()
        sleep(3)
        waitForSettled()
        let words = element("reader.visibleText").value as? String ?? ""
        print("LIVE after jump: \(words.prefix(200))")
        shot("live-10-after-jump")
        XCTAssertTrue(normalize(words).contains(normalize(expected)), "landed on the web reader's passage: \(words.prefix(200))")
        close()
        sleep(4)
    }

    private func waitForSettled() {
        let probe = element("reader.visibleText")
        let deadline = Date().addingTimeInterval(60)
        var last = ""
        var stable = 0
        while Date() < deadline {
            let now = probe.value as? String ?? ""
            stable = (!now.isEmpty && now == last) ? stable + 1 : 0
            if stable >= 3 { return }
            last = now
            sleep(1)
        }
    }

    private func close() {
        element("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let close = element("reader.close")
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
    }

    private func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
