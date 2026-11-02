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
        // Read on three pages: the shelf and the Cloud must not fall below the InkPad's percent.
        let page = element("reader.page")
        for _ in 0..<3 {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.6)).tap()
            sleep(2)
        }
        shot("live-10b-read-on")
        close()
        sleep(4)
        shot("live-10c-shelf-after-reading-on")
        if let tile = app.descendants(matching: .any).matching(identifier: frankenstein).allElementsBoundByIndex.first {
            print("LIVE shelf after reading on: \(tile.label)")
        }
    }

    /// Highlights both ways (driver steps around it): a note written through the Cloud API is listed
    /// and drawn with its words, and a highlight made here is sent to the Cloud.
    func test3_highlightsRoundTrip() throws {
        let marker = try XCTUnwrap(env["GATEFOLD_LIVE_NOTE_MARKER"].flatMap { $0.isEmpty ? nil : $0 }, "the seeded note's marker")
        launch(reset: false)
        let book = element(frankenstein)
        XCTAssertTrue(book.waitForExistence(timeout: 30))
        book.tap()
        let page = element("reader.page")
        XCTAssertTrue(page.waitForExistence(timeout: 30))
        waitForSettled()

        page.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let contents = element("reader.contents")
        XCTAssertTrue(contents.waitForExistence(timeout: 5))
        contents.tap()
        let tab = app.buttons["Highlights"]
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        let seeded = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", marker)).firstMatch
        XCTAssertTrue(seeded.waitForExistence(timeout: 60), "the API's note is listed")
        shot("live-11-highlights-list")
        seeded.tap()

        let probe = element("reader.highlights")
        let drawn = NSPredicate(format: "label MATCHES 'drawn [1-9][0-9]* of [0-9]+' AND value CONTAINS 'note='")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: drawn, evaluatedWith: probe)], timeout: 60), .completed,
                       "the API's note is drawn: \(probe.label) [\(probe.value as? String ?? "")]")
        let before = probe.label
        print("LIVE highlights probe: \(before) [\(probe.value as? String ?? "")]")
        sleep(1)
        shot("live-12-note-drawn")

        // Tap the drawn note: its card shows the words written through the API.
        let value = probe.value as? String ?? ""
        let note = value.split(separator: ";").first { $0.hasPrefix("note=") }.map { $0.dropFirst(5).split(separator: ",").compactMap { Double($0) } } ?? []
        XCTAssertEqual(note.count, 2)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: note[0], dy: note[1])).tap()
        let card = element("highlight.note")
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        XCTAssertTrue(card.label.hasPrefix(marker), card.label)
        print("LIVE note card: \(card.label) / \(element("highlight.provenance").label)")
        shot("live-13-note-card")
        app.swipeDown(velocity: .fast)
        XCTAssertTrue(card.waitForNonExistence(timeout: 10))

        // Highlight a word lower on the page.
        let total = Int(before.split(separator: " ").last ?? "") ?? 0
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.8)).press(forDuration: 1.2)
        let highlight = app.menuItems["Highlight"].exists ? app.menuItems["Highlight"] : app.buttons["Highlight"]
        XCTAssertTrue(highlight.waitForExistence(timeout: 10))
        shot("live-14-selection")
        highlight.tap()
        let more = NSPredicate(format: "label ENDSWITH %@", " of \(total + 1)")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: more, evaluatedWith: probe)], timeout: 20), .completed, probe.label)
        print("LIVE after highlighting: \(probe.label)")
        sleep(2)
        shot("live-15-highlighted")
        sleep(6) // the Cloud write goes out
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
        let close = element("reader.close")
        // A jump leaves the chrome up; only tap the page when it's hidden.
        if !close.isHittable { element("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() }
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
    }

    private func normalize(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
    }
}
