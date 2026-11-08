import XCTest

/// Contents goes away under a pull down from its bar, wherever on the bar the pull starts (gatefold#118).
@MainActor
final class ContentsPullUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldReset", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
        ]
    }

    override func tearDown() async throws {
        app.terminate()
    }

    private var done: XCUIElement { app.buttons["contents.done"] }

    private func openContents() -> Bool {
        let contents = app.buttons["reader.contents"]
        // The controls may already be up (a tap would put them down): tap only until Contents' button shows.
        for _ in 0..<4 where !contents.waitForExistence(timeout: 3) {
            app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        guard contents.exists else { return false }
        contents.tap()
        return app.navigationBars.firstMatch.waitForExistence(timeout: 15) && done.waitForExistence(timeout: 15)
    }

    /// A pull from the middle of the bar (the book's title) and from its top edge, three times each, as soon
    /// as the bar shows: every one puts Contents away.
    func testAPullFromTheBarsMiddlePutsContentsAway() {
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 120), "the book opened")
        let window = app.windows.firstMatch.frame
        // The sheet as it opened, for the visual check (Contents' rows are the book's chapter list, no page text).
        XCTAssertTrue(openContents(), "Contents opened")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "contents-open"
        shot.lifetime = .keepAlways
        add(shot)
        done.tap()
        XCTAssertTrue(done.waitForNonExistence(timeout: 10), "Done put Contents away")
        for round in 1...3 {
            for (name, dy) in [("middle", 0.5), ("top edge", 0.05)] {
                XCTAssertTrue(openContents(), "round \(round): Contents opened")
                let bar = app.navigationBars.firstMatch
                let from = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: dy))
                from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: window.height * 0.6)),
                           withVelocity: .fast, thenHoldForDuration: 0)
                let gone = done.waitForNonExistence(timeout: 10)
                print("CONTENTSPULL round \(round) \(name): gone=\(gone)")
                XCTAssertTrue(gone, "round \(round): a pull from the bar's \(name) put Contents away")
                if !gone, done.exists { done.tap(); _ = done.waitForNonExistence(timeout: 10) }
            }
        }
    }
}
