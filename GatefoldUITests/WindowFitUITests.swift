import XCTest

/// The reader lays out to its window: Your Page and its Fine-Tune panel sit wholly inside it, upright
/// and on its side, on the iPad and the Duo. Build 19's iPad portrait put the panel at x 880 (312 of
/// its 560 pt on screen) and Your Page at x 1048, in a 1032-pt window: a fresh iPad Pro 13-inch reports
/// a band across the top of the window, and the chrome took it for a corner to clear sideways.
@MainActor
final class WindowFitUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUp() { continueAfterFailure = true; app = XCUIApplication() }
    override func tearDown() async throws { XCUIDevice.shared.orientation = .portrait }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func launch() {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldReset", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldDownloadAll", "YES", "-GatefoldNoLatency", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice",
        ]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 120), "the book opened")
        sleep(4)
    }

    private func inside(_ e: XCUIElement, _ what: String, _ shape: String) {
        let window = app.windows.firstMatch.frame
        print("WINDOWFIT \(shape) \(what) \(e.frame) in \(window)")
        XCTAssertTrue(window.insetBy(dx: -0.5, dy: -0.5).contains(e.frame), "\(shape): \(what) \(e.frame) is outside the window \(window)")
    }

    private func check(_ shape: String) {
        let appearance = app.buttons["reader.appearance"]
        for _ in 0..<4 where !appearance.exists {
            el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            _ = appearance.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(appearance.exists, "\(shape): Your Page is up")
        sleep(1)
        // Inside the window, not merely hittable: the simulator delivers taps past its edge, so build 19's
        // controls at x 1048 of 1032 still took taps and CI stayed green.
        for (id, name) in [("reader.close", "Close"), ("reader.bookmark", "Bookmark"), ("reader.contents", "Contents"),
                           ("reader.share", "Share"), ("reader.search", "Search")] where el(id).exists {
            inside(el(id), name, shape)
        }
        inside(appearance, "Your Page", shape)
        XCTAssertTrue(appearance.isHittable, "\(shape): Your Page can be tapped")
        appearance.tap()
        let fine = app.buttons["appearance.customize"]
        XCTAssertTrue(fine.waitForExistence(timeout: 10), "\(shape): the panel opened")
        sleep(1)
        inside(el("appearance.panel"), "the panel", shape)
        if !fine.isHittable { el("appearance.panel").swipeUp() }
        fine.tap()
        sleep(2)
        inside(el("appearance.panel"), "Fine-Tune", shape)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "fine-tune-\(shape)"; shot.lifetime = .keepAlways; add(shot)
    }

    /// A plain launch, no orientation set: how the reviewers met it.
    func testUpright() {
        launch()
        check("upright")
    }

    func testOnItsSide() {
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(1)
        launch()
        check("on its side")
    }
}
