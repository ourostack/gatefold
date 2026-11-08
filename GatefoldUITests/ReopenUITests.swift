import XCTest

/// Reopening at his page: a page turn tapped on the picture of his page, before the live page is up,
/// is kept and played once it lands, so the first tap after launch is never lost.
@MainActor
final class ReopenUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    private let common = [
        "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
        "-GatefoldSignedIn", "YES", "-GatefoldTheme", "vellum", "-GatefoldAllowReopen", "YES",
    ] + (ProcessInfo.processInfo.environment["GATEFOLD_FONT_SCALE"].map { ["-GatefoldFontScale", $0] } ?? [])

    /// Forty characters from the middle of a page's words.
    private static func middle(of text: String) -> String {
        let start = text.index(text.startIndex, offsetBy: max(0, text.count / 2 - 20))
        return String(text[start...].prefix(40))
    }

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private func waitForText(timeout: TimeInterval, _ isDone: @escaping (String) -> Bool) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = visibleText
            if isDone(text) { return text }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return visibleText
    }

    func testATurnTappedOnThePictureIsPlayedWhenThePageLands() throws {
        // Reading: open the book at a place, and let it settle.
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        let before = waitForText(timeout: 90) { !$0.isEmpty }
        XCTAssertFalse(before.isEmpty, "the page never came up")
        sleep(3)
        let left = visibleText
        // He leaves (the picture of the page is kept), and iOS ends Gatefold.
        XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
        sleep(3)
        app.quit()

        // Back to Gatefold, no book asked for: it reopens on the picture of his page.
        app.launchArguments = common
        let launched = Date()
        app.launch()  // not relaunch(): its wait for the foreground would spend the picture's 5 s window (gatefold#76)
        let picture = app.descendants(matching: .any)["reader.reopenPicture"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 5), "no picture of his page at launch")
        // A tap on the right edge of the picture, before the live page is up.
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        let tapped = Date().timeIntervalSince(launched)
        XCTAssertTrue(picture.exists, "the live page was already up when the picture was tapped")
        print("REOPEN tapped the picture \(String(format: "%.2f", tapped)) s after the launch began")

        // The live page lands on his page, then turns on: it settles on a page that is not his.
        _ = waitForText(timeout: 40) { !$0.isEmpty && $0 != left }
        var settled = visibleText
        var still = Date()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, Date().timeIntervalSince(still) < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            if visibleText != settled { settled = visibleText; still = Date() }
        }
        XCTAssertFalse(settled.isEmpty)
        XCTAssertNotEqual(settled, left, "the tap on the picture was lost: still on his page")
        XCTAssertFalse(picture.exists)
        print("REOPEN on the next page \(String(format: "%.2f", Date().timeIntervalSince(launched) - 2)) s after the launch began")
        // Forward, not back: the page he left is not the one now showing, and a back turn shows it again.
        app.descendants(matching: .any)["reader.page"].coordinate(withNormalizedOffset: CGVector(dx: 0.03, dy: 0.5)).tap()
        // His page may break a line or two differently once relaid, so "his page" means the same words
        // in the middle of it, not the same first and last words.
        let middle = Self.middle(of: left)
        let back = waitForText(timeout: 10) { $0.contains(middle) }
        XCTAssertTrue(back.contains(middle), "one turn back did not return to his page: the kept turn was not one page forward")
        XCTAssertFalse(settled.contains(middle), "the kept turn did not leave his page")
    }

    /// For the film only (skipped otherwise): Gatefold is launched by the host as it would be from the
    /// Home Screen (no test launch, no waiting for it to idle), and this taps the picture of his page
    /// as soon as it is on screen, about a second after launch.
    func testTapsThePictureAsSoonAsItIsUp() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GATEFOLD_TAP_GO"] != nil, "film only")
        let go = try XCTUnwrap(ProcessInfo.processInfo.environment["GATEFOLD_TAP_GO"].map { $0 }, "film only")
        // The film's script reads the book, leaves and ends Gatefold first; it drops this file just
        // before the relaunch.
        let deadline = Date().addingTimeInterval(240)
        while !FileManager.default.fileExists(atPath: go), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        let running = XCUIApplication(bundleIdentifier: "bot.ouro.gatefold")
        XCTAssertTrue(running.wait(for: .runningForeground, timeout: 30), "Gatefold was not relaunched")
        let picture = running.descendants(matching: .any)["reader.reopenPicture"].firstMatch
        // Tap the screen, not the found element: finding it costs a second of accessibility snapshots.
        // The picture is up from Gatefold's first frame, so a tap a moment after it is foreground lands on it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        running.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: 0.5)).tap()
        XCTAssertTrue(picture.exists, "the tap came after the picture was gone")
        print("REOPEN tapped the running app's picture")
    }
}
