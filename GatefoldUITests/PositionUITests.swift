import XCTest

/// The reader keeps your place: rotation, posture and type changes never lose the words you were on.
/// The app exposes a hidden probe, `reader.anchorCheck`, which reads "anchor-visible" once a reflow
/// settles with the first words of the page you were on still on screen.
final class PositionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
            "-GatefoldTheme", "vellum",
        ] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 30))
        // Let the first page settle, then turn one so the place is the reader's own.
        sleep(2)
        let page = app.descendants(matching: .any)["reader.page"]
        page.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(2)
    }

    private func expectAnchorKept(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        let kept = NSPredicate(format: "label == 'anchor-visible'")
        let result = XCTWaiter.wait(for: [expectation(for: kept, evaluatedWith: probe)], timeout: 12)
        XCTAssertEqual(result, .completed, "\(what): probe says \(probe.label)", file: file, line: line)
    }

    func testRotationKeepsThePlace() {
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        expectAnchorKept("rotate to landscape")
        XCUIDevice.shared.orientation = .portrait
        expectAnchorKept("rotate back to portrait")
    }

    func testFontChangeKeepsThePlace() {
        launch(["-GatefoldSheet", "appearance"])
        let larger = app.buttons["appearance.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        larger.tap()
        expectAnchorKept("larger text")
        larger.tap()
        larger.tap()
        expectAnchorKept("much larger text")
        app.buttons["appearance.smaller"].tap()
        expectAnchorKept("smaller text")
    }

    func testForcedSpreadKeepsThePlaceAcrossRotation() {
        launch(["-GatefoldForcePosture", "spread"])
        XCUIDevice.shared.orientation = .landscapeLeft
        expectAnchorKept("spread, landscape")
        XCUIDevice.shared.orientation = .portrait
        expectAnchorKept("spread, portrait")
    }

    func testTabletopDeckTurnsAndResizes() {
        launch(["-GatefoldForcePosture", "tabletop"])
        let larger = app.buttons["deck.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        larger.tap()
        expectAnchorKept("tabletop, larger text")
        app.buttons["deck.next"].tap()
        app.buttons["deck.previous"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].exists)
    }
}
