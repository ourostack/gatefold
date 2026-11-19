import XCTest

extension XCUIApplication {
    /// The words on the reader's page (`reader.visibleText`); empty until the reader is up.
    ///
    /// `value` on an element not there yet fails the test on the spot, a few retries in, so it is read only once it
    /// exists. A launch with `-GatefoldOpenBook` shows the shelf first: on a starved iPad the reader came up 3 s after
    /// PageNumberUITests' first read (main at a38081a, job 134174750307), and NavigationPlaceUITests met it before
    /// (gatefold#407).
    var readerVisibleText: String {
        let e = descendants(matching: .any)["reader.visibleText"]
        return e.exists ? (e.value as? String) ?? "" : ""
    }
}

/// `readerVisibleText` before the reader is up reads empty, so a test can wait on it from the moment of launch.
@MainActor
final class ReaderVisibleTextUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    /// On the shelf there is no reader yet: the read is empty, never a failed query.
    func testTheShelfReadsNoWords() {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES", "-GatefoldReset", "YES"]
        app.relaunch()
        XCTAssertTrue(app.descendants(matching: .any)["library.grid"].firstMatch.waitForExistence(timeout: 60), "the shelf")
        XCTAssertEqual(app.readerVisibleText, "", "words read on the shelf")
        app.quit()
    }
}
