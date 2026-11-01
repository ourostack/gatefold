import XCTest

/// The reader keeps your place: rotation, posture and type changes never lose the words you were on.
/// The app exposes a hidden probe, `reader.anchorCheck`, which reads "anchor-visible" once a reflow
/// settles with the first words of the page you were on still on screen.
@MainActor
final class PositionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ extra: [String] = []) {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
            "-GatefoldTheme", "vellum",
        ] + extra
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 30))
        // Wait until the book has laid out and the reader has a place (the first words on the page).
        waitForProbe("ready 0", timeout: 90, what: "first page")
        // Turn a page so the place is the reader's own.
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        sleep(2)
    }

    private func waitForProbe(_ value: String, timeout: TimeInterval, what: String, file: StaticString = #filePath, line: UInt = #line) {
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        let matches = NSPredicate(format: "label == %@", value)
        let result = XCTWaiter.wait(for: [expectation(for: matches, evaluatedWith: probe)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(what): probe says \(probe.label)", file: file, line: line)
    }

    private var probe: XCUIElement { app.descendants(matching: .any)["reader.anchorCheck"] }

    /// The probe reads "<state> <reflow number>". Returns the reflow number now on screen.
    private func reflowNumber() -> Int {
        Int(probe.label.split(separator: " ").last ?? "") ?? 0
    }

    /// Runs `action`, then waits for the reflows it causes to settle and checks the anchor is on screen.
    private func expectAnchorKept(_ what: String, file: StaticString = #filePath, line: UInt = #line, after action: () -> Void) {
        let before = reflowNumber()
        action()
        let deadline = Date().addingTimeInterval(40)
        var last = ""
        var stableSince = Date()
        while Date() < deadline {
            let label = probe.label
            if label != last { last = label; stableSince = Date() }
            let n = Int(label.split(separator: " ").last ?? "") ?? 0
            if n > before, !label.hasPrefix("settling"), Date().timeIntervalSince(stableSince) > 2 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(last.hasPrefix("anchor-visible"), "\(what): probe says \(last) (was reflow \(before)) — \(probe.value as? String ?? "")", file: file, line: line)
    }

    func testEveryPostureKeepsThePlace() {
        launch()
        for posture in ["spread", "tabletop", "single", "spread", "single"] {
            expectAnchorKept("into \(posture)") { app.buttons["debug.posture.\(posture)"].tap() }
        }
    }

    func testRotationKeepsThePlace() throws {
        launch()
        let before = app.windows.firstMatch.frame.size
        let reflows = reflowNumber()
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(2)
        if app.windows.firstMatch.frame.size == before && reflowNumber() == reflows {
            throw XCTSkip("This display does not rotate (the folded Duo's cover screen is portrait only)")
        }
        XCUIDevice.shared.orientation = .portrait
        sleep(3)
        expectAnchorKept("rotate to landscape") { XCUIDevice.shared.orientation = .landscapeLeft }
        expectAnchorKept("rotate back to portrait") { XCUIDevice.shared.orientation = .portrait }
    }

    func testFontChangeKeepsThePlace() {
        launch(["-GatefoldSheet", "appearance"])
        let larger = app.buttons["appearance.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        expectAnchorKept("larger text") { larger.tap() }
        expectAnchorKept("much larger text") {
            larger.tap()
            larger.tap()
        }
        expectAnchorKept("smaller text") { app.buttons["appearance.smaller"].tap() }
    }

    func testTabletopDeckTurnsAndResizes() {
        launch()
        expectAnchorKept("into tabletop") { app.buttons["debug.posture.tabletop"].tap() }
        let larger = app.buttons["deck.larger"]
        XCTAssertTrue(larger.waitForExistence(timeout: 10))
        expectAnchorKept("tabletop, larger text") { larger.tap() }
        app.buttons["deck.next"].tap()
        app.buttons["deck.previous"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].exists)
    }
}
