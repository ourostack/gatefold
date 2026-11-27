import XCTest

/// The note that says books came aboard never hides the shelf's title or its buttons.
///
/// It was a toast over the top of the screen: "2 books added" sat on the large "Library" title and the Add
/// button for as long as it showed. Two sample books arrive just after launch (`-GatefoldArrive`, as if chosen in
/// Files), and while the note is up its frame must miss the title, Add and the account button.
@MainActor
final class ArrivalNoteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheArrivalNoteCoversNeitherTheTitleNorTheButtons() throws {
        let app = XCUIApplication()
        // The note stays until closed in UI tests (-GatefoldHoldNotes), so a slow runner still finds it.
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldReset", "YES",
                               "-GatefoldNoLatency", "YES", "-GatefoldHoldNotes", "YES",
                               "-GatefoldArrive", "emma,dracula", "-GatefoldArriveAfter", "2"]
        app.relaunch()
        let any = app.descendants(matching: .any)
        let title = app.staticTexts["Library"].firstMatch
        let add = any["library.import"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the shelf's title")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the Add button")
        // The shelf's own note, or the toast it used to be. Its frame is read once it has stopped unfolding, and
        // within the same look, so it can't go between finding it and measuring it.
        let inline = any["library.arrival"].firstMatch, toast = any["ouro.toast"].firstMatch
        var looks = 0
        var seen: (frame: CGRect, words: String)?
        var last = CGRect.null
        while seen == nil {
            looks += 1
            XCTAssertLessThan(looks, 150, "a note says the books came aboard")
            let note = inline.exists ? inline : (toast.exists ? toast : nil)
            if let note {
                let frame = note.frame
                if frame.height > 1, frame == last {
                    seen = (frame, note.label + " " + note.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))
                }
                last = frame
            }
            if seen == nil { usleep(200_000) }
        }
        let frame = try XCTUnwrap(seen).frame, words = try XCTUnwrap(seen).words
        if let dir = ProcessInfo.processInfo.environment["GATEFOLD_PROOF_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let shot = XCUIScreen.main.screenshot().pngRepresentation
            try? shot.write(to: URL(fileURLWithPath: dir).appendingPathComponent("arrival-note-\(Int(app.windows.firstMatch.frame.width)).png"))
        }
        XCTAssertTrue(words.contains("2 books added"), "the note says what came aboard: \(words)")
        XCTAssertFalse(frame.intersects(title.frame), "the note \(frame) covers the title \(title.frame)")
        XCTAssertFalse(frame.intersects(add.frame), "the note \(frame) covers Add \(add.frame)")
        let account = any["library.account"].firstMatch
        if account.exists {
            XCTAssertFalse(frame.intersects(account.frame), "the note \(frame) covers the account button \(account.frame)")
        }
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "the note \(frame) is on screen")
        XCTAssertTrue(add.isHittable, "Add is reachable while the note shows")
        // Both books came aboard.
        XCTAssertEqual(any["library.bookCount"].firstMatch.label, "2", "both books on the shelf")
        // Close folds it away.
        if inline.exists {
            let close = inline.buttons["Close"].firstMatch
            XCTAssertTrue(close.exists, "the note has Close")
            close.tap()
            var gone = 0
            while inline.exists { gone += 1; XCTAssertLessThan(gone, 50, "Close folds the note away"); usleep(100_000) }
        }
        app.quit()
    }

    /// A reader scrolled down the shelf still sees the note: the shelf scrolls back up to it.
    func testANoteScrollsTheShelfBackUpToIt() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES",
                               "-GatefoldHoldNotes", "YES", "-GatefoldArrive", "emma,dracula", "-GatefoldArriveAfter", "15"]
        app.relaunch()
        let any = app.descendants(matching: .any)
        XCTAssertTrue(any["library.grid"].firstMatch.waitForExistence(timeout: 60), "the shelf")
        let title = app.staticTexts["Library"].firstMatch
        let window = app.windows.firstMatch.frame
        // Down the shelf, past the title, before the books arrive.
        for _ in 0..<3 where title.exists && title.frame.maxY > window.minY {
            app.swipeUp(velocity: .fast)
        }
        let scrolled = !title.exists || title.frame.maxY <= window.minY
        let inline = any["library.arrival"].firstMatch
        XCTAssertTrue(inline.waitForExistence(timeout: 60), "a note says the books came aboard")
        var looks = 0, last = CGRect.null, frame = CGRect.null
        while frame.isNull {
            looks += 1
            XCTAssertLessThan(looks, 100, "the note settles")
            let now = inline.frame
            if now.height > 1, now == last { frame = now }
            last = now
            usleep(200_000)
        }
        XCTAssertTrue(window.contains(frame), "the note \(frame) is on screen (shelf scrolled first: \(scrolled))")
        XCTAssertTrue(title.exists && window.contains(title.frame), "the title is back in view above it")
        XCTAssertLessThan(title.frame.maxY, frame.minY + 1, "the title sits above the note")
        app.quit()
    }
}
