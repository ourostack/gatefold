import XCTest

/// A fresh install with no PocketBook account, the way App Review meets it: the real Cloud, signed out. The welcome
/// lets him in without an account, the empty shelf offers the bundled classics, and one opens to its page.
@MainActor
final class NoAccountUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testAFreshInstallReadsAClassicWithoutAnAccount() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldReset", "YES"]
        app.launch()
        let skip = app.buttons["welcome.skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 60), "the welcome offers a way in without an account")
        skip.tap()
        let classics = app.buttons["library.sampleShelf"]
        XCTAssertTrue(classics.waitForExistence(timeout: 30), "the empty shelf offers the bundled classics")
        classics.tap()
        let book = app.descendants(matching: .any)["book.sample-frankenstein"].firstMatch
        XCTAssertTrue(book.waitForExistence(timeout: 60), "the classics are on the shelf")
        XCTAssertFalse(classics.exists, "the offer goes once the shelf has books")
        book.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].firstMatch.waitForExistence(timeout: 60),
                      "a classic opens to its page with no account and no download")
        XCTAssertEqual(app.state, .runningForeground, "still running: no crash on the way")
        app.terminate()
    }
}
