import XCTest

/// Page numbers, the position in the book and pages left are his to show; he usually prefers them
/// off, so they start off. Turning one on never moves the words, and the choice is kept.
@MainActor
final class PageFurnitureUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }
    private var pageNumber: XCUIElement { app.descendants(matching: .any)["reader.pageNumber"].firstMatch }

    private func openCounted() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        // Counted: with the numbers off, nothing to see changes when counting ends, so wait on the probe.
        let count = app.descendants(matching: .any)["reader.pageCount"]
        let counted = NSPredicate(format: "value != nil AND value != ''")
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: counted, evaluatedWith: count)], timeout: 300), .completed,
                       "the book was counted")
        let up = Date().addingTimeInterval(30)
        while visibleText.isEmpty, Date() < up { RunLoop.current.run(until: Date().addingTimeInterval(0.2)) }
        sleep(2)
    }

    private func showChrome() {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["reader.appearance"].waitForExistence(timeout: 5))
    }

    func testOffByDefaultYetVoiceOverStillHearsWhereHeIs() {
        openCounted()
        XCTAssertFalse(pageNumber.exists, "no page number on a fresh install")
        showChrome()
        XCTAssertFalse(app.descendants(matching: .any)["reader.positionLine"].exists, "no position or pages left in the capsule")
        let scrubber = app.descendants(matching: .any)["reader.scrubber"]
        XCTAssertTrue(scrubber.exists)
        let said = scrubber.value as? String ?? ""
        XCTAssertTrue(said.hasPrefix("Page ") || said.hasSuffix(" percent"), "the scrubber still says where he is (\(said))")
    }

    func testTurningNumbersOnKeepsTheWordsAndIsKept() {
        openCounted()
        showChrome()
        app.buttons["reader.appearance"].tap()
        let fineTune = app.buttons["appearance.customize"]
        XCTAssertTrue(fineTune.waitForExistence(timeout: 10))
        if !fineTune.isHittable { app.descendants(matching: .any)["appearance.panel"].firstMatch.swipeUp() }
        fineTune.tap()
        let toggle = app.switches["appearance.pageNumbers"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        for _ in 0..<4 where !toggle.isHittable { app.descendants(matching: .any)["appearance.panel"].firstMatch.swipeUp() }
        XCTAssertEqual(toggle.value as? String, "0", "Page Numbers starts off")
        sleep(2)
        let before = visibleText
        XCTAssertFalse(before.isEmpty)
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 10), "the number shows as soon as it's on")
        sleep(2)
        XCTAssertEqual(visibleText, before, "turning page numbers on doesn't move the words")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(pageNumber.waitForNonExistence(timeout: 10), "and goes as soon as it's off")
        sleep(2)
        XCTAssertEqual(visibleText, before, "turning them off doesn't move the words")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 10))

        // Kept across a relaunch: the book reopens on his page with its numbers on.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.terminate()
        app.launchArguments = common
        app.launch()
        XCTAssertTrue(pageNumber.waitForExistence(timeout: 120), "page numbers are still on after a relaunch")
    }
}
