import XCTest

/// Probe for gatefold#118 (not for merge): which pulls on Contents' bar put it away on this device.
@MainActor
final class Probe118UITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES",
    ]

    // Contents' own Done (an xmark); the reader's Close also reads "Close", so not matched by label.
    private var done: XCUIElement { app.navigationBars.buttons["xmark"].firstMatch }

    private func openContents() -> Bool {
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        guard app.buttons["reader.contents"].waitForExistence(timeout: 5) else { return false }
        app.buttons["reader.contents"].tap()
        guard done.waitForExistence(timeout: 15) else { print("PROBE118 no Done: bars \(app.navigationBars.count)"); return false }
        // Landed: Done's frame the same for ten reads in a row.
        var last = CGRect.null, same = 0
        for _ in 0..<200 where same < 10 {
            let f = done.frame
            same = f == last ? same + 1 : 0
            last = f
        }
        return true
    }

    private func pull(_ name: String, from dx: CGFloat, _ dy: CGFloat, by fraction: CGFloat, velocity: XCUIGestureVelocity) {
        guard openContents() else { print("PROBE118 \(name): Contents did not open"); return }
        let bars = app.navigationBars.allElementsBoundByIndex.map { "\($0.identifier) \($0.frame)" }
        let window = app.windows.firstMatch.frame
        let bar = app.navigationBars.firstMatch
        let from = bar.coordinate(withNormalizedOffset: CGVector(dx: dx, dy: dy))
        from.press(forDuration: 0.05, thenDragTo: from.withOffset(CGVector(dx: 0, dy: window.height * fraction)),
                   withVelocity: velocity, thenHoldForDuration: 0)
        let gone = done.waitForNonExistence(timeout: 10)
        print("PROBE118 \(name): gone=\(gone) window=\(window) bars=\(bars) start=\(from.screenPoint)")
        if !gone { done.tap(); _ = done.waitForNonExistence(timeout: 10) }
    }

    func testWhichPullsPutContentsAway() {
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(app.descendants(matching: .any)["reader.page"].waitForExistence(timeout: 60))
        sleep(3)
        for round in 1...2 {
            pull("r\(round) leading 0.05 by 0.6 fast", from: 0.05, 0.5, by: 0.6, velocity: .fast)
            pull("r\(round) leading 0.05 by 0.9 fast", from: 0.05, 0.5, by: 0.9, velocity: .fast)
            pull("r\(round) leading 0.05 by 0.6 3000", from: 0.05, 0.5, by: 0.6, velocity: XCUIGestureVelocity(3000))
            pull("r\(round) leading 0.10 by 0.6 fast", from: 0.10, 0.5, by: 0.6, velocity: .fast)
            pull("r\(round) trailing 0.80 by 0.6 fast", from: 0.80, 0.5, by: 0.6, velocity: .fast)
            pull("r\(round) top 0.5,0.05 by 0.6 fast", from: 0.5, 0.05, by: 0.6, velocity: .fast)
        }
    }
}
