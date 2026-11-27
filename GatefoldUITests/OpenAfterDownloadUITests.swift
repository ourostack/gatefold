import XCTest

/// One tap on a book still in the Cloud reads it (Ari, 2026-11-27: it took a tap to download and a second to open).
/// Each test is one intent and what finishing it looks like, so an Ouro Feel check of "an intent that needs repeating"
/// can stand in for them later: tap once, and the reader is up; tap a book on its way, and it stops; leave while it
/// downloads, and it waits Ready instead of opening behind his back. The fake Cloud's downloads take
/// `-GatefoldDownloadSeconds`, in ten steps. Screenshots go to `GATEFOLD_SHOTS` when set.
@MainActor
final class OpenAfterDownloadUITests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var app: XCUIApplication!
    /// Books with no place on the e-reader, so each one sits on the shelf's grid, In Cloud.
    private static let shelf = "emma,alice-in-wonderland,sherlock-holmes"
    private let emma = "book.gutenberg-emma"

    override func setUp() {
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

    private func launchShelf(downloadSeconds: Double) -> XCUIElement {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldFakeShelf", Self.shelf, "-GatefoldNoWarm", "YES",
            "-GatefoldDownloadSeconds", "\(downloadSeconds)", "-GatefoldTheme", "vellum",
        ]
        app.launch()
        let book = element(emma)
        XCTAssertTrue(book.waitForExistence(timeout: 60), "the shelf arrived")
        XCTAssertTrue(waitForValue(book, contains: "in PocketBook Cloud", timeout: 30), "Emma waits in the Cloud: \(value(book))")
        return book
    }

    private func value(_ e: XCUIElement) -> String { (e.value as? String) ?? "" }

    private func waitForValue(_ e: XCUIElement, contains text: String, timeout: TimeInterval) -> Bool {
        let p = NSPredicate(format: "value CONTAINS %@", text)
        return XCTWaiter.wait(for: [expectation(for: p, evaluatedWith: e)], timeout: timeout) == .completed
    }

    func testOneTapOnABookInTheCloudOpensIt() {
        let book = launchShelf(downloadSeconds: 4)
        book.tap()
        XCTAssertTrue(waitForValue(book, contains: "percent downloaded", timeout: 10), "the tile tells how far it has got: \(value(book))")
        shot("open-after-download-1-downloading")
        // No second tap: the reader comes up on its own.
        XCTAssertTrue(element("reader.page").waitForExistence(timeout: 120), "one tap opened the book")
        // The picture once the page is up, not mid-zoom.
        let ready = element("reader.pageReady")
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: ready)], timeout: 60)
        shot("open-after-download-2-open")
    }

    func testATapOnABookOnItsWayStopsIt() {
        let book = launchShelf(downloadSeconds: 60)
        book.tap()
        XCTAssertTrue(waitForValue(book, contains: "downloading", timeout: 10), "downloading: \(value(book))")
        book.tap()
        XCTAssertTrue(waitForValue(book, contains: "in PocketBook Cloud", timeout: 10), "a second tap stopped it: \(value(book))")
        XCTAssertFalse(value(book).contains("failed"), "a stop is no failure: \(value(book))")
        // And it stays stopped: nothing lands and nothing opens.
        sleep(3)
        XCTAssertFalse(element("reader.page").exists, "a stopped book doesn't open")
        XCTAssertTrue(value(book).contains("in PocketBook Cloud"), "still in the Cloud: \(value(book))")
    }

    func testABookThatLandsWhileHeIsAwayWaitsReady() {
        let book = launchShelf(downloadSeconds: 4)
        book.tap()
        XCTAssertTrue(waitForValue(book, contains: "downloading", timeout: 10), "downloading: \(value(book))")
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        XCTAssertTrue(waitForValue(book, contains: "ready", timeout: 30), "it landed Ready while he was away: \(value(book))")
        XCTAssertFalse(element("reader.page").exists, "nothing opened behind his back")
        shot("open-after-download-3-ready")
        book.tap()
        XCTAssertTrue(element("reader.page").waitForExistence(timeout: 120), "the next tap opens it")
    }
}
