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
        let close = inline.buttons["Close"].firstMatch
        if close.exists {
            close.tap()
            var gone = 0
            while inline.exists { gone += 1; XCTAssertLessThan(gone, 50, "Close folds the note away"); usleep(100_000) }
        }
        app.quit()
    }
}
