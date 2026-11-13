import XCTest

/// The books waiting open behind the shelf, and their page counters, stay out of accessibility (gatefold#357).
///
/// Their pages are laid out behind the shelf so a tap shows a page already there, but VoiceOver must never read
/// them, and every query of the shelf walked them: about 900 elements across 27 web views against the shelf's own
/// 260, read from each page's own process. On a loaded runner one query outlived the test's limit while those
/// processes ran flat out (ReopenAfterControlsUITests, run 43384467106). Judged in looks, never seconds.
@MainActor
final class ShelfAccessibilityUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    func testNoPageBehindTheShelfReachesAccessibility() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                               "-GatefoldSignedIn", "YES", "-GatefoldNoLatency", "YES",
                               "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES"]
        app.relaunch()
        XCTAssertTrue(app.descendants(matching: .any)["library.grid"].firstMatch.waitForExistence(timeout: 60), "the shelf")
        // Every book behind the shelf has its page up.
        let warm = app.descendants(matching: .any)["library.warmReady"].firstMatch
        var looks = 0
        while true {
            let parts = ((warm.value as? String) ?? "").components(separatedBy: " of ").compactMap { Int($0) }
            if parts.count == 2, parts[1] > 0, parts[0] == parts[1] { break }
            looks += 1
            XCTAssertLessThan(looks, 600, "every page ready behind the shelf; \(warm.value as? String ?? "none") after \(looks) looks")
            usleep(300_000)
        }
        // Then for 20 looks, while their pages count: the shelf's tree holds no page at all.
        for look in 1...20 {
            let pages = app.webViews.count
            XCTAssertEqual(pages, 0, "look \(look): \(pages) web views reach accessibility behind the shelf")
            usleep(500_000)
        }
        // A tapped book's page comes back within reach: VoiceOver reads the open book.
        let cover = app.descendants(matching: .any)["book.gutenberg-pride-and-prejudice"].firstMatch
        XCTAssertTrue(cover.waitForExistence(timeout: 60), "the book's cover")
        cover.tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].firstMatch.waitForExistence(timeout: 60), "the book opened")
        looks = 0
        while app.webViews.count == 0 {
            looks += 1
            XCTAssertLessThan(looks, 200, "the open book's page reaches accessibility; none after \(looks) looks")
            usleep(300_000)
        }
        app.quit()
    }
}
