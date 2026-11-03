import XCTest

/// A page turn ends exactly where the page rests, with no slide or snap afterwards, on a screen whose
/// system insets sit at a side edge (Ari's folded Duo, build 13: "the page turn animation ends with
/// the page off to the side ... before it jerks into the correct position").
@MainActor
final class PageTurnPlacementUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func openBook(insets: String, turn: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES", "-GatefoldSignedIn", "YES",
            "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES", "-GatefoldOpenBook", "gutenberg-alice-in-wonderland",
            "-GatefoldGoTo", "0.12", "-GatefoldTheme", "daylight", "-GatefoldPageTurn", turn, "-GatefoldSystemInsets", insets,
        ]
        app.launch()
        let page = app.descendants(matching: .any)["reader.page"]
        XCTAssertTrue(page.waitForExistence(timeout: 60))
        let probe = app.descendants(matching: .any)["reader.anchorCheck"]
        _ = XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label == 'ready 0'"), evaluatedWith: probe)], timeout: 90)
        sleep(2)
        return app
    }

    /// The turn's own report: where the overlay drew the page and where the page itself sits, in the
    /// window's points, for the last turn that landed (`reader.turnPlacement`).
    private func placement(_ app: XCUIApplication) -> String {
        app.descendants(matching: .any)["reader.turnPlacement"].label
    }

    private func checkTurns(insets: String, turn: String) {
        let app = openBook(insets: insets, turn: turn)
        let page = app.descendants(matching: .any)["reader.page"]
        let report = app.descendants(matching: .any)["reader.turnPlacement"]
        for i in 0..<3 {
            page.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertTrue(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "label BEGINSWITH 'landed \(i + 1) '"), evaluatedWith: report)], timeout: 25) == .completed,
                          "turn \(i + 1) landed (\(placement(app)))")
            // Landed: the leaf's last frame and the page beneath are the same rectangle, and the
            // page didn't move after the overlay lifted.
            XCTAssertTrue(placement(app).hasSuffix("in place"), placement(app))
            let landed = XCUIScreen.main.screenshot().pngRepresentation
            usleep(700_000)
            let later = XCUIScreen.main.screenshot().pngRepresentation
            let a = XCTAttachment(data: landed, uniformTypeIdentifier: "public.png")
            a.name = "turn-\(turn)-\(insets)-\(i + 1)-landed"
            a.lifetime = .keepAlways
            add(a)
            let b = XCTAttachment(data: later, uniformTypeIdentifier: "public.png")
            b.name = "turn-\(turn)-\(insets)-\(i + 1)-later"
            b.lifetime = .keepAlways
            add(b)
        }
        app.terminate()
    }

    /// The folded Duo's status column, reported as a trailing inset.
    func testCurlLandsInPlaceBesideATrailingInset() { checkTurns(insets: "0,0,0,71", turn: "curl") }
    func testSlideLandsInPlaceBesideATrailingInset() { checkTurns(insets: "0,0,0,71", turn: "slide") }
    /// A camera at the leading edge.
    func testCurlLandsInPlaceBesideALeadingInset() { checkTurns(insets: "0,60,0,0", turn: "curl") }
}
