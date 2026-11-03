import XCTest

/// On a two-page spread, the turned leaf lands exactly on the page and stays there: no slide toward
/// the outer edge with the old page showing in the gap, and no jerk back when the overlay lifts.
/// Build 14 on the iPad spread landed about 55 pt out and snapped back (Ari: "page turn animation
/// ends with the page off to the side and is pretty janky before it jerks into the correct
/// position"). The landing report measured only after the snap; `reader.turnSettle` watches the
/// outer page in every frame from the turn's last leg until 0.5 s after it lands.
@MainActor
final class SpreadTurnSettleUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    func testSpreadTurnsLandWithoutSliding() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The spread runs on the iPad") }
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", "curl", "-GatefoldForcePosture", "spread",
            "-GatefoldDumpSettle", "YES",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'ready'"), evaluatedWith: probe)], timeout: 90)
        sleep(3)
        let settle = app.descendants(matching: .any)["reader.turnSettle"]
        let turns: [(String, CGFloat)] = [("forward", 0.95), ("forward", 0.95), ("forward", 0.95), ("back", 0.05), ("back", 0.05)]
        for (i, (way, x)) in turns.enumerated() {
            page.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5)).tap()
            XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'settle \(i + 1) '"), evaluatedWith: settle)], timeout: 30) == .completed,
                          "turn \(i + 1) (\(way)) was watched: \(settle.label)")
            let words = settle.label.split(separator: " ")
            let frames = Int(words[3]) ?? 0, worst = Int(words[5]) ?? 999
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "spread-\(i + 1)-\(way)"
            shot.lifetime = .keepAlways
            add(shot)
            XCTAssertGreaterThanOrEqual(frames, 5, "enough frames were watched (\(settle.label))")
            XCTAssertLessThanOrEqual(worst, 2, "turn \(i + 1) (\(way)): the outer page never strays from its rest (\(settle.label))")
            sleep(1)
        }
    }

    /// The default spread as a new reader first sees it (no size, margin or theme chosen): kept as a
    /// picture to set beside Apple Books' default spread (aris-device/4). It asserts nothing, so it runs
    /// only when asked (GATEFOLD_CAPTURE).
    func testDefaultSpreadPicture() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else { throw XCTSkip("The spread runs on the iPad") }
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GATEFOLD_CAPTURE"] != nil, "capture only")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12",
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'ready'"), evaluatedWith: probe)], timeout: 90)
        sleep(3)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "default-spread"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
