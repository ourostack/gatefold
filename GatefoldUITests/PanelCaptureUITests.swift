import XCTest

/// A review panel's screenshots, never a check: walks the reader's main screens (turns, controls up and down,
/// Contents, Your Page, Fine-Tune, a scrubber jump, search), closes the book onto the library, and keeps a screenshot
/// of each as an attachment: 14 a walk, which panel.yml checks.
/// `.github/workflows/panel.yml` runs it on demand only, once per appearance, and exports the attachments; no main
/// shard runs it. PANEL_TAG names the set (for example "light"), PANEL_THEME the reader theme. Public-domain books only.
@MainActor
final class PanelCaptureUITests: XCTestCase {
    private var app: XCUIApplication!
    private let env = ProcessInfo.processInfo.environment
    private var tag: String { env["PANEL_TAG"] ?? "set" }

    private func el(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(tag)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    private func at(_ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        el("reader.page").coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }
    private func settle() { _ = ReaderReads.settle(app, "panel") { print("PANEL \($0)") }; sleep(1) }
    private func controlsUp() {
        for _ in 0..<4 where !app.buttons["reader.contents"].exists {
            at(0.5, 0.5).tap(); sleep(2)
        }
    }
    private func controlsDown() {
        for _ in 0..<4 where app.buttons["reader.contents"].exists {
            at(0.5, 0.5).tap(); sleep(2)
        }
    }

    func testCapture() throws {
        continueAfterFailure = true
        let theme = env["PANEL_THEME"] ?? "daylight"
        let landscape = env["PANEL_LANDSCAPE"] != nil
        XCUIDevice.shared.orientation = landscape ? .landscapeLeft : .portrait
        let common = ["-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
                      "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldNoLatency", "YES",
                      "-GatefoldTheme", theme,
                      "-GatefoldFakeShelf",
                      "moby-dick,pride-and-prejudice,frankenstein,dracula,alice-in-wonderland,sherlock-holmes,emma"]
        // One launch, the book first and the shelf last by Close Book: no terminate. Ended in front on the shelf
        // while it warms books, the app fails XCTest's terminate (gatefold#363, Review panel shots run 45056636210),
        // and on the Duo a Home press before it left the relaunched walk with no shots after the shelf (run 45062075206).
        app = XCUIApplication()
        app.launchArguments = common + ["-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
                                        "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31"]
        app.launch()
        XCTAssertTrue(el("reader.page").waitForExistence(timeout: 300))
        settle()
        shot("01-open-book")
        at(0.93, 0.5).tap(); settle(); shot("02-page-turn-forward")
        at(0.93, 0.5).tap(); settle(); shot("03-page-turn-forward-2")
        at(0.07, 0.5).tap(); settle(); shot("04-page-turn-back")

        controlsUp(); shot("05-controls-up")

        app.buttons["reader.contents"].tap(); sleep(3); shot("06-contents")
        if el("contents.close").exists { el("contents.close").tap(); sleep(2) }

        controlsUp()
        app.buttons["reader.appearance"].tap(); sleep(3); shot("07-your-page")
        let fineTune = app.buttons["appearance.customize"]
        if fineTune.waitForExistence(timeout: 10) {
            if !HitCheck.hittable(fineTune, in: app) { el("appearance.panel").swipeUp(); sleep(1) }
            fineTune.tap(); sleep(3); shot("08-fine-tune")
        }
        if el("appearance.back").exists { el("appearance.back").tap(); sleep(1) }
        if el("appearance.close").exists { el("appearance.close").tap(); sleep(2) }

        controlsUp()
        let scrubber = el("reader.scrubber")
        if scrubber.waitForExistence(timeout: 5) {
            scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
                .press(forDuration: 0.1, thenDragTo: scrubber.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5)))
            settle(); shot("09-after-scrubber-jump")
            controlsUp(); shot("10-scrubber-controls-after-jump")
        }

        controlsUp()
        if app.buttons["reader.search"].exists {
            app.buttons["reader.search"].tap(); sleep(3)
            let field = app.searchFields.firstMatch
            if field.waitForExistence(timeout: 10) {
                field.tap(); field.typeText("Darcy"); sleep(6)
                shot("11-search-results")
                let result = app.buttons["search.result"].firstMatch
                if result.exists { result.tap(); settle(); shot("12-after-search-jump") }
            }
        }
        controlsDown(); shot("13-page-controls-down")

        controlsUp()
        let close = app.buttons["reader.close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "Close Book is there")
        close.tap()
        XCTAssertTrue(el("library.grid").waitForExistence(timeout: 60), "the shelf came back")
        sleep(8)
        shot("14-library")
        XCUIDevice.shared.orientation = .portrait
    }
}
