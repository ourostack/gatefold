import XCTest

/// The note that says books came aboard never hides the shelf's title or its buttons.
///
/// It was a toast over the top of the screen: "2 books added" sat on the large "Library" title and the Add
/// button for as long as it showed. Two sample books arrive at launch (`-GatefoldArrive`, as if chosen in
/// Files) a few seconds after launch, once the test is watching, and while the note is up its frame must miss the
/// title, Add and the account button.
@MainActor
final class ArrivalNoteUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTheArrivalNoteCoversNeitherTheTitleNorTheButtons() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldReset", "YES",
                               "-GatefoldNoLatency", "YES", "-GatefoldArrive", "emma,dracula", "-GatefoldArriveAfter", "10"]
        app.relaunch()
        let any = app.descendants(matching: .any)
        let title = app.staticTexts["Library"].firstMatch
        let add = any["library.import"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 60), "the shelf's title")
        XCTAssertTrue(add.waitForExistence(timeout: 10), "the Add button")
        // Watching before the books come, so the note can't have come and gone unseen.
        let count = any["library.bookCount"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout: 10), "the shelf's count")
        XCTAssertEqual(count.label, "0", "watching before the books arrive")
        // The shelf's own note, or the toast it used to be.
        let inline = any["library.arrival"].firstMatch, toast = any["ouro.toast"].firstMatch
        var looks = 0
        while !(inline.exists && inline.frame.height > 1) && !toast.exists {
            looks += 1
            XCTAssertLessThan(looks, 300, "a note says the books came aboard")
            usleep(200_000)
        }
        let note = inline.exists ? inline : toast
        let words = (note.label + " " + note.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " "))
        XCTAssertTrue(words.contains("2 books added"), "the note says what came aboard: \(words)")
        let frame = note.frame
        if let dir = ProcessInfo.processInfo.environment["GATEFOLD_PROOF_SHOTS"] {
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let shot = XCUIScreen.main.screenshot().pngRepresentation
            try? shot.write(to: URL(fileURLWithPath: dir).appendingPathComponent("arrival-note-\(Int(app.windows.firstMatch.frame.width)).png"))
        }
        XCTAssertFalse(frame.intersects(title.frame), "the note \(frame) covers the title \(title.frame)")
        XCTAssertFalse(frame.intersects(add.frame), "the note \(frame) covers Add \(add.frame)")
        let account = any["library.account"].firstMatch
        if account.exists {
            XCTAssertFalse(frame.intersects(account.frame), "the note \(frame) covers the account button \(account.frame)")
        }
        // Both books are on the shelf, and the note sits on the screen, not scrolled out of sight.
        XCTAssertTrue(any["book.emma"].firstMatch.exists || any.matching(NSPredicate(format: "identifier BEGINSWITH 'book.'")).count >= 2,
                      "the books on the shelf")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(frame), "the note \(frame) is on screen")
        // Add still answers while the note shows.
        XCTAssertTrue(add.isHittable, "Add is reachable while the note shows")
        app.quit()
    }
}
