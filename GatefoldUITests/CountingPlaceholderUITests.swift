import UIKit
import XCTest

/// With page numbers on, a book opened for the first time takes a while to count (half a minute on
/// the Duo and the iPad on its side). The number's slot is never blank meanwhile: a quiet "Counting
/// pages…" sits where the number will be, and neither it nor the number moves the words.
@MainActor
final class CountingPlaceholderUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
    }

    private var visibleText: String { (app.descendants(matching: .any)["reader.visibleText"].value as? String) ?? "" }

    private func freshOpenNeverLeavesTheSlotBlank() {
        app.launchArguments = [
            "-GatefoldUITest", "YES", "-GatefoldFakeCloud", "YES", "-GatefoldSkipWelcome", "YES",
            "-GatefoldSignedIn", "YES", "-GatefoldAllowReopen", "YES", "-GatefoldPageFurniture", "YES",
            "-GatefoldReset", "YES", "-GatefoldDownloadAll", "YES",
            "-GatefoldOpenBook", "gutenberg-pride-and-prejudice", "-GatefoldGoTo", "0.31",
        ]
        app.launch()
        let number = app.descendants(matching: .any)["reader.pageNumber"].firstMatch
        let counting = app.descendants(matching: .any)["reader.pageCounting"].firstMatch
        // From the moment the page is up, the slot holds the placeholder or the number. Only cheap reads
        // while sampling (the page's text takes seconds to read).
        let ready = app.descendants(matching: .any)["reader.pageReady"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: ready)], timeout: 120),
                       .completed, "the page shows")
        var sawCounting = false, samples = 0, words = ""
        let deadline = Date().addingTimeInterval(300)
        while !number.exists, Date() < deadline {
            samples += 1
            if counting.exists {
                if !sawCounting {
                    sawCounting = true
                    XCTAssertEqual(counting.label, "Counting pages", "VoiceOver hears what the slot says")
                    words = visibleText
                }
            } else if !number.exists {
                XCTFail("sample \(samples): the page is up and the number's slot is blank")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        XCTAssertTrue(number.exists, "the number comes")
        XCTAssertTrue(counting.waitForNonExistence(timeout: 2), "and the placeholder goes")
        print("PLACEHOLDER saw counting=\(sawCounting) samples=\(samples) app drew it=\((app.descendants(matching: .any)["reader.countingShown"].firstMatch.value as? String) ?? "?")")
        // A reset leaves nothing counted, so a fresh open always has a moment before its number. On a
        // slow runner one accessibility read can outlast that moment, so the app's own record counts too.
        let shown = app.descendants(matching: .any)["reader.countingShown"].firstMatch
        XCTAssertTrue(sawCounting || (shown.value as? String) == "1", "the placeholder showed while the count ran")
        if sawCounting, !words.isEmpty {
            sleep(1)
            XCTAssertEqual(visibleText, words, "the number taking the placeholder's place doesn't move the words")
        }
    }

    func testAFreshOpenNeverLeavesTheNumbersSlotBlank() {
        freshOpenNeverLeavesTheSlotBlank()
    }

    func testAFreshOpenOnItsSideNeverLeavesTheNumbersSlotBlank() {
        XCUIDevice.shared.orientation = .landscapeLeft
        freshOpenNeverLeavesTheSlotBlank()
    }
}
